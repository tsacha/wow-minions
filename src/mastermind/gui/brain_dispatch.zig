//! Drains operator commands from the GUI / repl queue and translates them to
//! wire-level dispatches. Plumbing only: every actual decision lives in the
//! combat planner.

const std = @import("std");
const proto = @import("protocol");
const types = @import("types");
const registry_mod = @import("registry");
const nav = @import("nav");
const repl = @import("../repl.zig");
const fight_log = @import("../fight_log.zig");
const gui_command = @import("gui_command");
const combat = @import("../combat/mod.zig");
const intent = @import("../combat/intent/mod.zig");
const class_spec = @import("../combat/class_spec.zig");
const spec_registry = @import("../combat/specs/spec_registry.zig");
const order_label = @import("order_label.zig");
const gui_log = @import("log.zig");

const BotId = types.BotId;
const BotSnapshot = registry_mod.BotSnapshot;
const Registry = registry_mod.Registry;
const DispatchStore = combat.DispatchStore;
const IntentStore = intent.IntentStore;
const ActiveIntent = intent.ActiveIntent;
const Priority = intent.Priority;
const Reason = intent.Reason;

const operator_intent_ttl_ms: u32 = 15_000;

pub fn dispatchGuiCommands(
    io: std.Io,
    registry: *Registry,
    bots: []const BotSnapshot,
    world: []const @import("../world/memory.zig").WorldSnapshot,
    cmd_queue: *gui_command.Queue,
    gui_buf: *[gui_command.capacity]gui_command.GuiCommand,
    navigator: *nav.Navigator,
    dispatch_store: *DispatchStore,
    follow_store: *combat.FollowStore,
    intent_store: *IntentStore,
    is_fighting: *bool,
) void {
    // start_fight / clean_orders bypass the ring-buffer queue via dedicated atomics so they
    // are never dropped when the queue is full (e.g. after a burst of navigate_to commands).
    if (cmd_queue.consumeStartFight()) {
        is_fighting.* = true;
        fight_log.start();
        if (gui_log.commandLogEnabled()) std.log.info("brain: start_fight", .{});
        combat.onStartFight(io, registry, bots, intent_store, dispatch_store, follow_store);
    }
    if (cmd_queue.consumeCleanOrders()) {
        if (gui_log.commandLogEnabled()) std.log.info("brain: clean_orders", .{});
        is_fighting.* = false;
        cancelAllRoutes(bots, navigator);
        combat.onCleanOrders(io, registry, bots, intent_store, dispatch_store, follow_store);
        fight_log.stop();
    }
    if (cmd_queue.consumeResetFight()) {
        if (gui_log.commandLogEnabled()) std.log.info("brain: reset_fight", .{});
        is_fighting.* = false;
        cancelAllRoutes(bots, navigator);
        combat.onCleanOrders(io, registry, bots, intent_store, dispatch_store, follow_store);
        fight_log.stop();
        dispatchResetFightSequence(io, registry);
    }
    if (cmd_queue.consumeTestJump()) {
        is_fighting.* = true;
        fight_log.start();
        if (gui_log.commandLogEnabled()) std.log.info("brain: test_jump", .{});
        combat.onTestJump(io, registry, bots, intent_store, dispatch_store, follow_store);
    }

    const cmds = cmd_queue.drain(gui_buf);
    if (cmds.len > 0 and gui_log.commandLogEnabled()) {
        std.log.info("brain: dispatch {} gui command(s)", .{cmds.len});
    }
    for (cmds) |cmd| {
        switch (cmd) {
            .navigate_to => |m| {
                if (nav.pathfinding_enabled) {
                    navigator.setDestinations(io, registry, bots, m);
                } else {
                    dispatchNavigateDirectCtm(io, registry, bots, m);
                }
            },
            .lua_exec => |m| {
                const count = @min(@as(usize, @intCast(m.bot_count)), m.bot_ids.len);
                // lua_get expects one response per target — limit to first bot when
                // no selection is active to avoid duplicate results.
                var first_bot_id: [1]BotId = undefined;
                const targets: ?[]const BotId = if (count > 0)
                    m.bot_ids[0..count]
                else if (m.is_get and bots.len > 0) blk: {
                    first_bot_id[0] = bots[0].bot_id;
                    break :blk &first_bot_id;
                } else null;
                const msg: proto.MastermindMsg = if (m.is_get)
                    .{ .lua_get = m.code }
                else
                    .{ .lua_exec = m.code };
                _ = registry.dispatch(io, msg, targets);
            },
            .operator_spec_action => |m| {
                const count = @min(@as(usize, @intCast(m.bot_count)), m.bot_ids.len);
                const bot_slice = m.bot_ids[0..count];
                switch (m.kind) {
                    .raid_buff => dispatchOperatorRaidBuff(io, registry, bots, bot_slice, m.map_id, intent_store, dispatch_store),
                    .burst => dispatchOperatorBurst(io, registry, bots, world, bot_slice, m.map_id, intent_store, dispatch_store),
                }
            },
        }
    }
}

fn dispatchOperatorRaidBuff(
    io: std.Io,
    registry: *Registry,
    bots: []const BotSnapshot,
    bot_ids: []const BotId,
    map_id: u32,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
) void {
    for (bot_ids) |bot_id| {
        const bot = validateTarget(bot_id, bots, map_id, "operator spell") orelse continue;
        const spec = class_spec.primarySpecFromState(bot.state);
        if (spec_registry.raidBuffPlan(spec)) |plan| {
            _ = dispatchOperatorRaidBuffSequence(io, registry, bot, bot_id, intent_store, dispatch_store, plan);
        } else {
            var blessing_buf: [spec_registry.max_blessing_actions]combat.Action = undefined;
            if (spec_registry.raidBuffPlanDynamic(spec, bot, bots, &blessing_buf)) |plan| {
                _ = dispatchOperatorRaidBuffSequence(io, registry, bot, bot_id, intent_store, dispatch_store, plan);
            }
        }
    }
}

fn dispatchOperatorRaidBuffSequence(
    io: std.Io,
    registry: *Registry,
    bot: BotSnapshot,
    bot_id: BotId,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    plan: spec_registry.RaidBuffPlan,
) bool {
    if (plan.actions.len == 0 or plan.actions.len > intent.max_seq_steps) return false;

    var seq: intent.Sequenced = .{
        .steps = undefined,
        .len = 0,
        .current = 0,
        .step_dispatched = false,
    };

    const StepInfo = struct { spell_id: u32, target_guid: u64, instant: bool };

    var step_index: usize = 0;
    for (plan.actions, 0..) |action, i| {
        const si: StepInfo = switch (action) {
            .cast_instant => |id| .{ .spell_id = id, .target_guid = bot.state.guid, .instant = true },
            .cast => |id| .{ .spell_id = id, .target_guid = bot.state.guid, .instant = true },
            .cast_target_instant => |ct| .{ .spell_id = ct.spell_id, .target_guid = ct.target_guid, .instant = true },
            .cast_target => |ct| .{ .spell_id = ct.spell_id, .target_guid = ct.target_guid, .instant = false },
            else => return false,
        };

        seq.steps[step_index] = .{ .intent = .{ .casting_scripted = .{
            .spell_id = si.spell_id,
            .target_guid = si.target_guid,
            .instant = si.instant,
            .one_shot = true,
        } } };
        step_index += 1;

        if (i + 1 < plan.actions.len) {
            seq.steps[step_index] = .{ .intent = .{ .waiting_for = .{
                .until = .{ .game_time_at_least_ms = bot.state.game_time_ms +| plan.inter_step_delay_ms * @as(u32, @intCast(i + 1)) },
            } } };
            step_index += 1;
        }
    }

    seq.len = @intCast(step_index);

    const ai: intent.ActiveIntent = .{
        .intent = .{ .sequenced = seq },
        .priority = .operator,
        .cancellable_by_priority = .operator,
        .created_at_ms = bot.state.game_time_ms,
        .max_age_ms = operator_intent_ttl_ms,
        .source = .operator_raid_buff,
    };
    _ = intent_store.replace(bot_id, ai, true, dispatch_store, bot.state.game_time_ms);
    _ = registry.dispatch(io, .ctm_stop, &.{bot_id});
    return true;
}

fn dispatchOperatorBurst(
    io: std.Io,
    registry: *Registry,
    bots: []const BotSnapshot,
    world: []const @import("../world/memory.zig").WorldSnapshot,
    bot_ids: []const BotId,
    map_id: u32,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
) void {
    for (bot_ids) |bot_id| {
        const bot = validateTarget(bot_id, bots, map_id, "operator spell") orelse continue;
        const spec = class_spec.primarySpecFromState(bot.state);
        if (spec == .balance) {
            const action = @import("../combat/specs/balance.zig").burstGroundAction(bot, world) orelse continue;
            switch (action) {
                .cast_ground => |cg| {
                    _ = registry.dispatch(io, .{ .cast_spell_ground = .{
                        .spell_id = cg.spell_id,
                        .x = cg.x,
                        .y = cg.y,
                        .z = cg.z,
                    } }, &.{bot_id});
                },
                .cast_instant => |id| _ = registry.dispatch(io, .{ .cast_spell_id = .{ .spell_id = id } }, &.{bot_id}),
                .cast => |id| _ = registry.dispatch(io, .{ .cast_spell_id = .{ .spell_id = id } }, &.{bot_id}),
                else => {},
            }
            continue;
        }

        const max_steps = @import("../combat/intent/mod.zig").max_seq_steps;
        var actions: [max_steps]combat.Action = undefined;
        var n: usize = 0;
        while (n < max_steps) {
            const a = spec_registry.burstAction(spec, n) orelse break;
            actions[n] = a;
            n += 1;
        }
        if (n == 0) continue;
        _ = dispatchOperatorSequence(io, registry, bot, bot_id, intent_store, dispatch_store, .operator_burst, actions[0..n]);
    }
}

fn dispatchOperatorSequence(
    io: std.Io,
    registry: *Registry,
    bot: BotSnapshot,
    bot_id: BotId,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    source: Reason,
    actions: []const combat.Action,
) bool {
    if (actions.len == 0 or actions.len > intent.max_seq_steps) return false;
    var seq: intent.Sequenced = .{
        .steps = undefined,
        .len = @intCast(actions.len),
        .current = 0,
        .step_dispatched = false,
    };
    for (actions, 0..) |action, i| {
        seq.steps[i] = .{ .intent = switch (action) {
            .cast_instant => |id| .{ .casting_scripted = .{
                .spell_id = id,
                .target_guid = bot.state.guid,
                .instant = true,
                .one_shot = true,
            } },
            .cast => |id| .{ .casting_scripted = .{
                .spell_id = id,
                .target_guid = bot.state.guid,
                .instant = true,
                .one_shot = true,
            } },
            .cast_ground => |cg| .{ .casting_scripted_ground = .{
                .spell_id = cg.spell_id,
                .x = cg.x,
                .y = cg.y,
                .z = cg.z,
                .instant = true,
                .one_shot = true,
            } },
            else => return false,
        } };
    }
    const ai: ActiveIntent = .{
        .intent = .{ .sequenced = seq },
        .priority = .operator,
        .cancellable_by_priority = .operator,
        .created_at_ms = bot.state.game_time_ms,
        .max_age_ms = operator_intent_ttl_ms,
        .source = source,
    };
    _ = intent_store.replace(bot_id, ai, true, dispatch_store, bot.state.game_time_ms);
    _ = registry.dispatch(io, .ctm_stop, &.{bot_id});
    return true;
}

fn cancelAllRoutes(bots: []const BotSnapshot, navigator: *nav.Navigator) void {
    if (!nav.pathfinding_enabled) return;
    var nav_cancel_ids: [types.max_bots]BotId = undefined;
    var nav_cancel_n: usize = 0;
    for (bots) |b| {
        if (nav_cancel_n >= nav_cancel_ids.len) break;
        nav_cancel_ids[nav_cancel_n] = b.bot_id;
        nav_cancel_n += 1;
    }
    navigator.cancelRoutesForBots(nav_cancel_ids[0..nav_cancel_n]);
}

fn dispatchResetFightSequence(io: std.Io, registry: *Registry) void {
    var lua_buf: [proto.lua_str_max]u8 = undefined;
    const release_spirit = "if UnitIsDead(\"player\") then RepopMe() end";

    _ = registry.dispatch(io, .{ .lua_exec = luaExecText(release_spirit) }, null);
    io.sleep(.{ .nanoseconds = repl.repl_cmd_spacing_ns }, .real) catch return;
    if (repl.lineToLuaExecChat(&lua_buf, ".go xyz 3427.3 -3013.1 295.6 533")) {
        _ = registry.dispatch(io, .{ .lua_exec = lua_buf }, null);
    }
    io.sleep(.{ .nanoseconds = repl.repl_cmd_spacing_ns }, .real) catch return;
    var target_self_buf: [proto.lua_str_max]u8 = @splat(0);
    const target_self = "TargetUnit(\"player\")";
    @memcpy(target_self_buf[0..target_self.len], target_self);
    _ = registry.dispatch(io, .{ .lua_exec = target_self_buf }, null);
    io.sleep(.{ .nanoseconds = repl.repl_cmd_spacing_ns }, .real) catch return;
    if (repl.lineToLuaExecChat(&lua_buf, ".revive")) {
        _ = registry.dispatch(io, .{ .lua_exec = lua_buf }, null);
    }
}

fn luaExecText(code: []const u8) [proto.lua_str_max]u8 {
    var buf: [proto.lua_str_max]u8 = std.mem.zeroes([proto.lua_str_max]u8);
    const n = @min(code.len, proto.lua_str_max - 1);
    @memcpy(buf[0..n], code[0..n]);
    return buf;
}

fn validateTarget(bot_id: BotId, bots: []const BotSnapshot, expected_map_id: u32, label: []const u8) ?BotSnapshot {
    if (types.isZeroBotId(&bot_id)) return null;
    const bot = registry_mod.findBotSnapshot(bots, &bot_id) orelse {
        std.log.warn("brain: {s} bot snapshot not found", .{label});
        return null;
    };
    if (bot.state.map_id != expected_map_id) {
        std.log.warn("brain: {s} map mismatch bot_map={} need {}", .{ label, bot.state.map_id, expected_map_id });
        return null;
    }
    return bot;
}

fn dispatchNavigateDirectCtm(io: std.Io, registry: *Registry, bots: []const BotSnapshot, cmd: nav.NavigateCommand) void {
    const target_count = @min(@as(usize, @intCast(cmd.bot_count)), cmd.bot_ids.len);
    if (target_count == 0) return;

    for (cmd.bot_ids[0..target_count]) |bot_id| {
        _ = validateTarget(bot_id, bots, cmd.map_id, "navigate_to (direct)") orelse continue;

        const one = [_]BotId{bot_id};
        _ = registry.dispatch(io, .ctm_stop, &one);
        _ = registry.dispatch(io, .{ .ctm_move = .{ .x = cmd.x, .y = cmd.y, .z = cmd.z } }, &one);
    }
}

test "dispatchGuiCommands: operator burst uses command map_id, not first snapshot map" {
    const io = std.Options.debug_io;
    const target_bot_id = [_]u8{ 'm', 'a', 'g', 'e', '1' } ++ [_]u8{0} ** (proto.bot_id_len - 5);
    const other_bot_id = [_]u8{ 'o', 't', 'h', 'e', 'r' } ++ [_]u8{0} ** (proto.bot_id_len - 5);

    var registry: Registry = .{};
    var cmd_queue: gui_command.Queue = .{};
    var gui_buf: [gui_command.capacity]gui_command.GuiCommand = undefined;
    var navigator = nav.Navigator.init(std.testing.allocator);
    defer navigator.deinit();
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var is_fighting = false;

    var target = std.mem.zeroes(BotSnapshot);
    target.bot_id = target_bot_id;
    target.state.bot_id = target_bot_id;
    target.state.class = @intFromEnum(class_spec.Class.mage);
    target.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    target.state.map_id = 571;
    target.state.guid = 0xBEEF;
    target.state.game_time_ms = 1234;

    var other = std.mem.zeroes(BotSnapshot);
    other.bot_id = other_bot_id;
    other.state.bot_id = other_bot_id;
    other.state.class = @intFromEnum(class_spec.Class.mage);
    other.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    other.state.map_id = 533;
    other.state.guid = 0xCAFE;
    other.state.game_time_ms = 1234;

    try std.testing.expect(cmd_queue.push(.{ .operator_spec_action = .{
        .kind = .burst,
        .map_id = target.state.map_id,
        .bot_ids = blk: {
            var ids = std.mem.zeroes([gui_command.max_ctm_targets]gui_command.BotId);
            ids[0] = target_bot_id;
            break :blk ids;
        },
        .bot_count = 1,
    } }));

    dispatchGuiCommands(
        io,
        &registry,
        &.{ other, target },
        &.{},
        &cmd_queue,
        &gui_buf,
        &navigator,
        &dispatch_store,
        &follow_store,
        &intent_store,
        &is_fighting,
    );

    const active = intent_store.current(target_bot_id).?;
    try std.testing.expectEqual(intent.Priority.operator, active.priority);
    try std.testing.expectEqual(intent.Reason.operator_burst, active.source);
    try std.testing.expect(active.intent == .sequenced);
    try std.testing.expectEqual(@as(u8, 3), active.intent.sequenced.len);
}

test "dispatchGuiCommands: operator burst accepts multiple bots without GUI selection" {
    const io = std.Options.debug_io;
    const mage1_bot_id = [_]u8{ 'm', 'a', 'g', 'e', '1' } ++ [_]u8{0} ** (proto.bot_id_len - 5);
    const mage2_bot_id = [_]u8{ 'm', 'a', 'g', 'e', '2' } ++ [_]u8{0} ** (proto.bot_id_len - 5);

    var registry: Registry = .{};
    var cmd_queue: gui_command.Queue = .{};
    var gui_buf: [gui_command.capacity]gui_command.GuiCommand = undefined;
    var navigator = nav.Navigator.init(std.testing.allocator);
    defer navigator.deinit();
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var is_fighting = false;

    var mage1 = std.mem.zeroes(BotSnapshot);
    mage1.bot_id = mage1_bot_id;
    mage1.state.bot_id = mage1_bot_id;
    mage1.state.class = @intFromEnum(class_spec.Class.mage);
    mage1.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    mage1.state.map_id = 571;
    mage1.state.guid = 0x1001;
    mage1.state.game_time_ms = 1234;

    var mage2 = std.mem.zeroes(BotSnapshot);
    mage2.bot_id = mage2_bot_id;
    mage2.state.bot_id = mage2_bot_id;
    mage2.state.class = @intFromEnum(class_spec.Class.mage);
    mage2.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    mage2.state.map_id = 571;
    mage2.state.guid = 0x1002;
    mage2.state.game_time_ms = 1234;

    try std.testing.expect(cmd_queue.push(.{ .operator_spec_action = .{
        .kind = .burst,
        .map_id = 571,
        .bot_ids = blk: {
            var ids = std.mem.zeroes([gui_command.max_ctm_targets]gui_command.BotId);
            ids[0] = mage1_bot_id;
            ids[1] = mage2_bot_id;
            break :blk ids;
        },
        .bot_count = 2,
    } }));

    dispatchGuiCommands(
        io,
        &registry,
        &.{ mage1, mage2 },
        &.{},
        &cmd_queue,
        &gui_buf,
        &navigator,
        &dispatch_store,
        &follow_store,
        &intent_store,
        &is_fighting,
    );

    try std.testing.expect(intent_store.current(mage1_bot_id).?.intent == .sequenced);
    try std.testing.expect(intent_store.current(mage2_bot_id).?.intent == .sequenced);
}

test "luaExecText preserves release spirit script" {
    const buf = luaExecText("if UnitIsDead(\"player\") then RepopMe() end");
    try std.testing.expectEqualStrings("if UnitIsDead(\"player\") then RepopMe() end", std.mem.sliceTo(&buf, 0));
}
