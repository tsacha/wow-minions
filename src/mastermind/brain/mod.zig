const std = @import("std");
const proto = @import("protocol");
const types = @import("types");
const registry_mod = @import("registry");
const world_memory_mod = @import("../world/memory.zig");
const spell_event_store = @import("../world/spell_events.zig");
const scene = @import("../gui/scene.zig");
const gui_snapshot = @import("../gui/snapshot.zig");
const gui_command = @import("gui_command");
const combat = @import("../combat/mod.zig");
const aggro = @import("../combat/aggro.zig");
const class_spec = @import("../combat/class_spec.zig");
const world_query = @import("../combat/world_query.zig");
const TargetStore = @import("../combat/target_store.zig");
const formation = @import("../formation.zig");
const nav = @import("nav");
const repl = @import("../repl.zig");
const intent = @import("../combat/intent/mod.zig");
const context = @import("../combat/context.zig");
const encounter = @import("../combat/encounters/mod.zig");
const intent_encounter = @import("../combat/proposers/encounter.zig");
const intent_heal = @import("../combat/proposers/heal.zig");
const intent_role = @import("../combat/proposers/role.zig");
const intent_spec = @import("../combat/proposers/spec.zig");
const intent_tank_engage = @import("../combat/proposers/tank_engage.zig");
const intent_tank_rescue = @import("../combat/proposers/tank_rescue.zig");
const intent_dispatch = @import("../combat/intent/dispatch.zig");
const intent_confirm = @import("../combat/intent/confirm.zig");
const geo = @import("../combat/geo.zig");
const spec_registry = @import("../combat/specs/spec_registry.zig");
const action_msg = @import("action_msg.zig");
const combat_debug = @import("combat_debug.zig");
const order_label = @import("../gui/order_label.zig");
const brain_log = @import("log.zig");
const fight_log = @import("../fight_log.zig");
const brain_gui_dispatch = @import("../gui/brain_dispatch.zig");

const lua_output_mod = @import("../lua_output.zig");

const Registry = registry_mod.Registry;
const BotSnapshot = registry_mod.BotSnapshot;
const WorldMemory = world_memory_mod.WorldMemory;
const WorldSnapshot = world_memory_mod.WorldSnapshot;
const SpellEventStore = spell_event_store.SpellEventStore;
const BotId = types.BotId;
const DispatchStore = combat.DispatchStore;
const IntentStore = intent.IntentStore;
pub const test_sequence_wait_max_age_ms: u32 = 3000;
pub const RoleProposeFn = *const fn (*const context.CombatContext, *combat.FollowStore) ?intent.ActiveIntent;
pub const SpecProposeFn = *const fn (*const context.CombatContext) ?intent.ActiveIntent;

comptime {
    std.debug.assert(gui_command.lua_code_max == proto.lua_str_max);
}

const tick_interval_ns: u64 = proto.brain_tick_ms * std.time.ns_per_ms;
const prune_interval_ns: u64 = proto.brain_prune_period_ms * std.time.ns_per_ms;
const cast_facing_tol_rad: f32 = 0.25;
const deadly_poison_item_id: u32 = 43233;
const poison_recheck_interval_ms: u32 = 5000;
var poison_last_check_ms: [types.max_bots]u64 = .{0} ** types.max_bots;
var arbitration_dedupe_store: combat_debug.CombatDebugStore = .{};

pub const setCombatDecisionLogEnabled = brain_log.setCombatDecisionLogEnabled;
pub const setIntentPreemptLogEnabled = brain_log.setIntentPreemptLogEnabled;
pub const setCombatArbitrationLogEnabled = brain_log.setCombatArbitrationLogEnabled;
pub const setCombatSampleLogEnabled = brain_log.setCombatSampleLogEnabled;
pub const setThreatTableLogEnabled = brain_log.setThreatTableLogEnabled;
pub const setSpellLaunchLogEnabled = brain_log.setSpellLaunchLogEnabled;
pub const setCombatDispatchLogEnabled = brain_log.setCombatDispatchLogEnabled;
pub const setPolarityChargeLogEnabled = combat.setPolarityChargeLogEnabled;

// One Order ≈ "bot X should do action Y this tick". The plan is just a
// list of these. At most one per bot per tick keeps things simple — if a
// bot needs a sequence, queue it across successive ticks.
pub const Order = order_label.Order;

pub const GuiCtx = struct {
    publisher: *gui_snapshot.Publisher,
    cmd_queue: *gui_command.Queue,
    lua_output: *lua_output_mod.Buffer,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, registry: *Registry, world_memory: *WorldMemory, spell_events: *SpellEventStore, gui: ?GuiCtx, repl_queue: ?*repl.ReplQueue) void {
    var bots_buf: [types.max_bots]BotSnapshot = undefined;
    var gui_cmd_buf: [gui_command.capacity]gui_command.GuiCommand = undefined;
    var route_buf: [types.max_bots]nav.RouteSnapshot = undefined;
    var last_prune_ns: u64 = 0;
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var combat_debug_store: combat_debug.CombatDebugStore = .{};
    // Idle until operator triggers formation (GUI button or repl `reform`).
    var formation_store: formation.FormationStore = .{ .done = true };
    var is_fighting: bool = false;
    var was_in_combat: bool = false;

    const world_cap = world_memory_mod.max_tracked;
    const world_buf = allocator.alloc(WorldSnapshot, world_cap) catch |err| {
        std.log.err("brain: alloc world snapshot scratch ({} entries): {}", .{ world_cap, err });
        return;
    };
    defer allocator.free(world_buf);

    var event_buf: [spell_event_store.capacity]proto.SpellEvent = undefined;

    var scene_scratch_opt: ?scene.Scratch = if (gui != null)
        scene.Scratch.init(allocator) catch |err| {
            std.log.err("brain: failed to allocate scene scratch: {}", .{err});
            return;
        }
    else
        null;
    var navigator_opt: ?nav.Navigator = if (gui != null) nav.Navigator.init(allocator) else null;
    defer {
        if (scene_scratch_opt) |*s| s.deinit(allocator);
        if (navigator_opt) |*n| n.deinit();
    }

    var repl_line_storage: [repl.drain_max_per_tick][proto.lua_str_max]u8 = undefined;
    var repl_line_slices: [repl.drain_max_per_tick][]const u8 = undefined;
    var repl_target_buf: [types.max_bots]types.BotId = undefined;
    var prev_n: usize = 0;

    while (true) {
        if (repl_queue) |rq| {
            const drained = rq.drain(&repl_line_storage, &repl_line_slices);
            for (0..drained) |i| {
                if (i > 0) io.sleep(.{ .nanoseconds = repl.repl_cmd_spacing_ns }, .real) catch return;
                const line = repl_line_slices[i];
                if (std.mem.eql(u8, line, "reform")) {
                    std.log.info("repl: resetting formation", .{});
                    formation.reset(&formation_store);
                    continue;
                }
                if (repl.parseCommand(line)) |cmd| {
                    const targets = resolveTarget(cmd.target, bots_buf[0..prev_n], &repl_target_buf);
                    if (cmd.target != null and targets == null) {
                        std.log.warn("repl: no bot matching '{s}'", .{cmd.target.?});
                    }
                    _ = registry.dispatch(io, cmd.msg, targets);
                    continue;
                }
                const stripped = repl.stripTarget(line);
                var lua_buf: [proto.lua_str_max]u8 = undefined;
                if (!repl.lineToLuaExecChat(&lua_buf, stripped.rest)) {
                    std.log.err("repl: line too long for lua_exec (max {} bytes script)", .{proto.lua_str_max - 1});
                    continue;
                }
                const lua_targets = resolveTarget(stripped.target, bots_buf[0..prev_n], &repl_target_buf);
                if (stripped.target != null and lua_targets == null) {
                    std.log.warn("repl: no bot matching '{s}'", .{stripped.target.?});
                }
                _ = registry.dispatch(io, .{ .lua_exec = lua_buf }, lua_targets);
            }
        }

        const n = registry.snapshot(io, &bots_buf);
        prev_n = n;
        const bots = bots_buf[0..n];
        brain_log.logThreatTables(bots);

        const world_n = world_memory.snapshot(io, world_buf);
        const world = world_buf[0..world_n];
        const event_n = spell_events.snapshot(io, &event_buf);
        const events = event_buf[0..event_n];
        const in_combat = anyBotInCombat(bots);

        // Raid invites only — orthogonal to combat (formation.zig; no combat/ imports).
        if (gui) |g| {
            if (g.cmd_queue.consumeStartFormation()) {
                std.log.info("brain: start_formation", .{});
                formation.reset(&formation_store);
            }
        }
        formation.tick(&formation_store, io, registry, bots);

        if (in_combat) {
            if (!was_in_combat) fight_log.startCombat();
        } else if (was_in_combat or !is_fighting) {
            fight_log.stopCombat();
        }
        was_in_combat = in_combat;

        const combat_status = dispatchCombatOrders(io, registry, bots, world, events, &dispatch_store, &follow_store, &intent_store, &combat_debug_store, is_fighting);

        if (gui) |g| {
            const entities = scene_scratch_opt.?.collect(io, world_memory, bots);
            if (nav.pathfinding_enabled) {
                navigator_opt.?.ensureOverlayForBots(io, bots);
            }
            brain_gui_dispatch.dispatchGuiCommands(io, registry, bots, world, g.cmd_queue, &gui_cmd_buf, &navigator_opt.?, &dispatch_store, &follow_store, &intent_store, &is_fighting);
            const route_n: usize = if (nav.pathfinding_enabled)
                navigator_opt.?.snapshotRoutes(&route_buf)
            else
                0;
            g.publisher.publish(entities, route_buf[0..route_n], combat_status);
            if (nav.pathfinding_enabled) {
                navigator_opt.?.tick(io, registry, bots);
            }
        }
        pruneIfDue(io, world_memory, spell_events, &last_prune_ns);
        io.sleep(.{ .nanoseconds = tick_interval_ns }, .real) catch return;
    }
}

const copyLabel = order_label.copyLabel;
const actionLabel = order_label.actionLabel;
const formatOrderLabel = order_label.formatOrderLabel;

fn dispatchCombatOrders(io: std.Io, registry: *Registry, bots: []const BotSnapshot, world: []const WorldSnapshot, events: []const proto.SpellEvent, dispatch_store: *DispatchStore, follow_store: *combat.FollowStore, intent_store: *IntentStore, combat_debug_store: *combat_debug.CombatDebugStore, operator_fight_started: bool) gui_snapshot.CombatStatus {
    var orders_buf: [types.max_bots]Order = undefined;
    var trace_buf: combat_debug.TraceBuffer = .{};
    const trace_opt: ?*combat_debug.TraceBuffer = if (brain_log.combatDecisionLogEnabled() or brain_log.combatSampleLogEnabled()) &trace_buf else null;
    if (!operator_fight_started) {
        dispatch_store.clearThreatHolds();
    }
    const orders = computeWithTrace(bots, world, events, &orders_buf, dispatch_store, follow_store, intent_store, operator_fight_started, trace_opt);
    if (trace_opt) |traces| appendRoleDecisionTraces(bots, world, events, follow_store, operator_fight_started, combat_debug_store, traces);
    if (trace_opt) |traces| combat_debug.logTraces(traces);

    var status: gui_snapshot.CombatStatus = .{
        .orders_planned = @intCast(orders.len),
    };
    for (bots) |bot| {
        if (status.bot_intent_count >= types.max_bots) break;
        const ai = intent_store.current(bot.bot_id) orelse continue;
        const idx = status.bot_intent_count;
        status.bot_intents[idx].bot_id = bot.bot_id;
        const prefix = intentReasonPrefix(ai.source);
        const tag = intentTagName(ai.intent);
        _ = std.fmt.bufPrintZ(&status.bot_intents[idx].label, "[{s}] {s}", .{ prefix, tag }) catch {};
        status.bot_intent_count += 1;
    }

    var label_buf: [gui_snapshot.combat_order_label_len]u8 = undefined;
    for (orders[0..@min(orders.len, gui_snapshot.combat_order_history_len)], 0..) |order, i| {
        const label = formatOrderLabel(&label_buf, order, bots, world);
        copyLabel(&status.order_labels[i], label);
        status.order_label_count += 1;
    }

    for (orders, 0..) |order, i| {
        if (order.msg == .walk) continue;
        if (order.msg == .set_facing) continue;
        const label = formatOrderLabel(&label_buf, order, bots, world);
        if (brain_log.combatDispatchLogEnabled()) {
            std.log.debug("brain: combat order {}/{}: {s}", .{ i + 1, orders.len, label });
        }
    }

    var accepted: usize = 0;
    for (orders) |order| {
        const dispatched = registry.dispatch(io, order.msg, &.{order.bot_id});
        accepted += dispatched;
        if (dispatched != 0 and brain_log.spellLaunchLogEnabled()) {
            switch (order.msg) {
                .cast_spell_id, .cast_spell_guid => {
                    const label = formatOrderLabel(&label_buf, order, bots, world);
                    std.log.info("brain: spell_launch {s}", .{label});
                },
                else => {},
            }
        }
    }
    status.orders_accepted = @intCast(accepted);
    status.orders_dropped = @intCast(orders.len - accepted);
    return status;
}

fn anyBotInCombat(bots: []const BotSnapshot) bool {
    for (bots) |bot| {
        if (proto.hasUnitFlag(bot.state.unit_flags, .in_combat)) return true;
    }
    return false;
}

fn pruneIfDue(io: std.Io, world_memory: *WorldMemory, spell_events: *SpellEventStore, last_prune_ns: *u64) void {
    const now_ns: u64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
    if (now_ns -| last_prune_ns.* >= prune_interval_ns) {
        world_memory.prune(io, now_ns);
        spell_events.prune(io, now_ns);
        last_prune_ns.* = now_ns;
    }
}

fn castFacingGate(bot: BotSnapshot, world: []const WorldSnapshot, action: combat.Action) ?combat.Action {
    const target_guid = switch (action) {
        .cast_target => |ct| ct.target_guid,
        .cast_target_instant => |ct| ct.target_guid,
        else => return null,
    };
    const scan = world_query.scanForGuidOnMap(world, target_guid, bot.state.map_id) orelse return null;
    const raw_angle = std.math.atan2(scan.y - bot.state.y, scan.x - bot.state.x);
    const desired_angle = if (raw_angle < 0) raw_angle + 2.0 * std.math.pi else raw_angle;
    const diff = @abs(desired_angle - bot.state.orientation);
    const err = if (diff > std.math.pi) 2.0 * std.math.pi - diff else diff;
    // Tolerance must be loose enough to converge against moving targets.
    // Twins on Thaddius circle at ~0.5 rad/s; a 0.1 rad threshold is below
    // the per-tick angular delta and causes an infinite face/cast loop.
    if (err > cast_facing_tol_rad) return .{ .set_facing_rad = desired_angle };
    return null;
}

fn buildPoisonLuaMsg() ?proto.MastermindMsg {
    var buf = std.mem.zeroes([proto.lua_str_max]u8);
    _ = std.fmt.bufPrint(&buf,
        \\m,_,_,h=GetWeaponEnchantInfo()if not m or not h then for b=0,4 do for s=1,GetContainerNumSlots(b)do i=GetContainerItemID(b,s)if i=={d} then UseContainerItem(b,s)PickupInventoryItem(m and 17 or 16)return end end end end
    , .{deadly_poison_item_id}) catch return null;
    return proto.MastermindMsg{ .lua_exec = buf };
}

fn isRogueSpec(spec: class_spec.Spec) bool {
    return switch (spec) {
        .assassination, .combat, .subtlety => true,
        else => false,
    };
}

test "buildPoisonLuaMsg produces correct Lua" {
    const msg = buildPoisonLuaMsg() orelse return error.TestFailed;
    try std.testing.expect(msg == .lua_exec);
    const lua = std.mem.sliceTo(&msg.lua_exec, 0);
    try std.testing.expect(std.mem.indexOf(u8, lua, "PickupInventoryItem(m and 17 or 16)") != null);
    try std.testing.expect(std.mem.indexOf(u8, lua, "43233") != null);
}

fn activeSequenceInFlight(ai: intent.ActiveIntent) bool {
    if (ai.confirm.active) return true;
    if (ai.intent != .sequenced) return false;
    return ai.intent.sequenced.current < ai.intent.sequenced.len;
}

fn targetScopedCombatIntent(ai: intent.ActiveIntent, state: proto.State) bool {
    return switch (ai.priority) {
        .role, .spec => switch (ai.intent) {
            .moving_to, .facing, .start_attack => true,
            .targeting => |target| target.target_guid != 0,
            .attacking => |atk| atk.target_guid != 0,
            .casting_scripted => |cast| ai.source != .role_heal_move and cast.target_guid != 0 and cast.target_guid != state.guid,
            else => false,
        },
        else => false,
    };
}

fn actionAfterTargetLoss(ai: intent.ActiveIntent, state: proto.State) TargetLossAction {
    if (!targetScopedCombatIntent(ai, state)) return .none;
    if (ctmActionNeedsStop(state.ctm_action)) return .ctm_stop;
    return .stop_attack;
}

fn appendArbitrationTrace(
    traces: ?*combat_debug.TraceBuffer,
    bot: BotSnapshot,
    reason: combat_debug.ArbitrationReason,
    encounter_active: bool,
    role_ai: intent.ActiveIntent,
    blocks_spec: bool,
    spec_skipped: bool,
    old_ai_opt: ?intent.ActiveIntent,
    final_ai_opt: ?intent.ActiveIntent,
) void {
    const buf = traces orelse return;
    const old_ai = old_ai_opt orelse intent.ActiveIntent{
        .intent = .idle,
        .priority = .idle,
        .created_at_ms = bot.state.game_time_ms,
        .source = .operator_reset,
    };
    const final_ai = final_ai_opt orelse intent.ActiveIntent{
        .intent = .idle,
        .priority = .idle,
        .created_at_ms = bot.state.game_time_ms,
        .source = .operator_reset,
    };
    const trace = combat_debug.ArbitrationTrace{
        .bot_id = bot.bot_id,
        .target_guid = bot.state.target_guid,
        .reason = reason,
        .encounter_active = encounter_active,
        .role_intent = std.meta.activeTag(role_ai.intent),
        .blocks_spec = blocks_spec,
        .spec_skipped = spec_skipped,
        .old_intent = std.meta.activeTag(old_ai.intent),
        .final_intent = std.meta.activeTag(final_ai.intent),
        .final_priority = final_ai.priority,
    };
    if (!arbitration_dedupe_store.shouldLogArbitration(trace)) return;
    buf.appendArbitration(trace);
}

fn appendRoleDecisionTraces(
    bots: []const BotSnapshot,
    world: []const WorldSnapshot,
    events: []const proto.SpellEvent,
    follow_store: *combat.FollowStore,
    operator_fight_started: bool,
    debug_store: *combat_debug.CombatDebugStore,
    traces: *combat_debug.TraceBuffer,
) void {
    for (bots) |bot| {
        const ctx = context.CombatContext.build(bot, bots, world, events, operator_fight_started);
        const trace = intent_role.explainDecision(&ctx, follow_store);
        if (debug_store.shouldLogDecision(trace, brain_log.combatSampleLogEnabled())) {
            traces.appendDecision(trace);
        }
    }
}

fn targetOverrideBlocked(ai: ?intent.ActiveIntent) bool {
    const active = ai orelse return false;
    if (intent.isPolarityTransit(active)) return true;
    return active.priority == .encounter and activeSequenceInFlight(active);
}

fn applyTargetOverride(action: combat.Action, active: ?intent.ActiveIntent, forced_target: ?TargetStore.Target, ctx: *const context.CombatContext) combat.Action {
    if (targetOverrideBlocked(active)) return action;
    const target = forced_target orelse return action;
    const guid = target.guid;
    if (isRangedAutoAttack(ctx) and target.mode == .attack and ctx.bot.state.target_guid != guid) {
        return .{ .target_guid = guid };
    }
    switch (action) {
        .cast_target => |ct| if (ct.target_guid == guid) return action,
        .cast_target_instant => |ct| if (ct.target_guid == guid) return action,
        .target_guid => |target_guid| if (target_guid == guid) return action,
        .attack => |attack_guid| if (attack_guid == guid) return action,
        else => {},
    }
    if (ctx.bot.state.target_guid == guid) return action;
    return switch (target.mode) {
        .select_only => .{ .target_guid = guid },
        .attack => .{ .attack = guid },
    };
}

fn installProposedIntent(bot_id: BotId, proposed: ?intent.ActiveIntent, intent_store: *IntentStore, dispatch_store: *DispatchStore, game_time_ms: u32) bool {
    const ai = proposed orelse return false;
    return intent_store.replaceAt(bot_id, ai, dispatch_store, game_time_ms) != .rejected_priority;
}

fn installEncounterIntent(bot_id: BotId, proposed: intent.ActiveIntent, intent_store: *IntentStore, dispatch_store: *DispatchStore, game_time_ms: u32) void {
    const current = intent_store.current(bot_id);
    const force_transition = proposed.source == .encounter_transition and
        current != null and
        current.?.priority == .encounter and
        current.?.source != .encounter_transition;

    if (force_transition) {
        _ = intent_store.replace(bot_id, proposed, true, dispatch_store, game_time_ms);
        return;
    }

    _ = intent_store.replaceAt(bot_id, proposed, dispatch_store, game_time_ms);
}

fn clearPrepGatedEncounterIntents(bots: []const BotSnapshot, intent_store: *IntentStore) void {
    for (bots) |bot| {
        if (!encounter.mapUsesOperatorPrepGate(bot.state.map_id)) continue;
        intent_store.clearByPriority(bot.bot_id, .encounter, .operator_reset, bot.state.game_time_ms);
    }
}

fn isRangedAutoAttack(ctx: *const context.CombatContext) bool {
    return ctx.role == .ranged_dps and spec_registry.meta(ctx.spec).profile == .ranged;
}

pub fn compute(bots: []const BotSnapshot, world: []const WorldSnapshot, events: []const proto.SpellEvent, out: *[types.max_bots]Order, dispatch_store: *DispatchStore, follow_store: *combat.FollowStore, intent_store: *IntentStore, operator_fight_started: bool) []const Order {
    return computeWithTrace(
        bots,
        world,
        events,
        out,
        dispatch_store,
        follow_store,
        intent_store,
        operator_fight_started,
        null,
    );
}

fn computeWithTrace(
    bots: []const BotSnapshot,
    world: []const WorldSnapshot,
    events: []const proto.SpellEvent,
    out: *[types.max_bots]Order,
    dispatch_store: *DispatchStore,
    follow_store: *combat.FollowStore,
    intent_store: *IntentStore,
    operator_fight_started: bool,
    traces: ?*combat_debug.TraceBuffer,
) []const Order {
    return computeWithProposers(
        bots,
        world,
        events,
        out,
        dispatch_store,
        follow_store,
        intent_store,
        operator_fight_started,
        intent_role.proposeIntent,
        intent_spec.proposeIntent,
        traces,
    );
}

fn proposeIntentsForBot(
    bot: BotSnapshot,
    bot_index: usize,
    bots: []const BotSnapshot,
    world: []const WorldSnapshot,
    events: []const proto.SpellEvent,
    operator_fight_started: bool,
    role_propose: RoleProposeFn,
    spec_propose: SpecProposeFn,
    target_store: *TargetStore,
    target_loss_actions: *[types.max_bots]TargetLossAction,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    follow_store: *combat.FollowStore,
    traces: ?*combat_debug.TraceBuffer,
) void {
    const ctx = context.CombatContext.build(bot, bots, world, events, operator_fight_started);
    const game_time_ms = bot.state.game_time_ms;

    if (botIsDead(bot.state)) {
        intent_store.clear(bot.bot_id, dispatch_store, game_time_ms);
        return;
    }

    if (intent_encounter.proposeIntent(&ctx, target_store, follow_store)) |ai| {
        installEncounterIntent(bot.bot_id, ai, intent_store, dispatch_store, game_time_ms);
    }

    const forced_target = target_store.getTarget(bot.bot_id);
    const forced_target_guid = if (forced_target) |target| target.guid else null;
    if (ctx.primary_target == null and forced_target_guid == null) {
        if (intent_store.current(bot.bot_id)) |ai| {
            if (targetScopedCombatIntent(ai, bot.state)) {
                target_loss_actions[bot_index] = actionAfterTargetLoss(ai, bot.state);
                intent_store.clearByPriority(bot.bot_id, ai.priority, .operator_reset, game_time_ms);
                return;
            }
        }
    }

    const tank_engage_active = if (intent_store.current(bot.bot_id)) |ai| ai.source == .tank_engage else false;

    const dispatch_locked = if (intent_store.current(bot.bot_id)) |ai| activeSequenceInFlight(ai) else false;
    if (dispatch_locked) return;

    const current = intent_store.current(bot.bot_id);
    const encounter_active = if (current) |ai|
        ai.priority == .encounter and activeSequenceInFlight(ai)
    else
        false;

    if (!encounter_active and
        installProposedIntent(bot.bot_id, intent_tank_rescue.proposeIntent(&ctx), intent_store, dispatch_store, game_time_ms))
    {
        return;
    }

    if (!tank_engage_active and !encounter_active and
        installProposedIntent(bot.bot_id, intent_tank_engage.proposeIntentForTarget(&ctx, forced_target_guid), intent_store, dispatch_store, game_time_ms))
    {
        return;
    }

    if (installProposedIntent(bot.bot_id, intent_heal.proposeIntent(&ctx), intent_store, dispatch_store, game_time_ms)) {
        return;
    }

    proposeRoleAndSpecIntents(
        bot,
        &ctx,
        game_time_ms,
        tank_engage_active,
        role_propose,
        spec_propose,
        intent_store,
        dispatch_store,
        follow_store,
        traces,
    );
}

fn proposeRoleAndSpecIntents(
    bot: BotSnapshot,
    ctx: *const context.CombatContext,
    game_time_ms: u32,
    tank_engage_active: bool,
    role_propose: RoleProposeFn,
    spec_propose: SpecProposeFn,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    follow_store: *combat.FollowStore,
    traces: ?*combat_debug.TraceBuffer,
) void {
    var role_allows_spec: ?intent.ActiveIntent = null;

    if (role_propose(ctx, follow_store)) |ai| {
        if (tank_engage_active and (intent_role.blocksSpec(ai) or roleStartNeedsMovementStop(ai, bot.state) or roleStartMustPrecedeSpec(ai, ctx, follow_store))) {
            return;
        }
        if (intent_role.blocksSpec(ai) or roleStartNeedsMovementStop(ai, bot.state) or roleStartMustPrecedeSpec(ai, ctx, follow_store)) {
            if (!tank_engage_active) {
                const previous = intent_store.current(bot.bot_id);
                const old_spec = if (previous) |old| old.priority == .spec else false;
                const encounter_active = if (previous) |old| old.priority == .encounter else false;
                intent_store.clearByPriority(bot.bot_id, .spec, .spec_attack, game_time_ms);
                _ = intent_store.replaceAt(bot.bot_id, ai, dispatch_store, game_time_ms);
                appendArbitrationTrace(
                    traces,
                    bot,
                    if (encounter_active) .encounter_preempts_role else if (old_spec) .role_clears_existing_spec else .role_blocks_spec,
                    encounter_active,
                    ai,
                    true,
                    true,
                    previous,
                    intent_store.current(bot.bot_id),
                );
                return;
            }
        }
        _ = intent_store.replaceAt(bot.bot_id, ai, dispatch_store, game_time_ms);
        role_allows_spec = ai;
    }

    if (spec_propose(ctx)) |ai| {
        _ = intent_store.replaceAt(bot.bot_id, ai, dispatch_store, game_time_ms);
    } else {
        const current = intent_store.current(bot.bot_id);
        const spec_confirm_active = if (current) |ai|
            ai.priority == .spec and ai.confirm.active
        else
            false;
        if (!spec_confirm_active) {
            intent_store.clearByPriority(bot.bot_id, .spec, .spec_attack, game_time_ms);
        }
    }

    if (role_allows_spec) |ai| {
        appendArbitrationTrace(
            traces,
            bot,
            .role_allows_spec,
            false,
            ai,
            false,
            false,
            null,
            intent_store.current(bot.bot_id),
        );
    }
}

fn resolveIntentAction(
    intent_store: *IntentStore,
    bot_id: BotId,
    ctx: *const context.CombatContext,
    follow_store: *combat.FollowStore,
) combat.Action {
    const ai_ptr = intent_store.currentMut(bot_id) orelse return .none;

    const clearFinishedOperatorSequence = struct {
        fn run(ai: *intent.ActiveIntent, game_time_ms: u32) void {
            const done = ai.intent == .sequenced and ai.intent.sequenced.current >= ai.intent.sequenced.len;
            if (!done or ai.priority != .operator) return;
            ai.* = .{
                .intent = .idle,
                .priority = .idle,
                .created_at_ms = game_time_ms,
                .source = .operator_reset,
            };
        }
    }.run;

    if (!ai_ptr.confirm.active) {
        if (intent_dispatch.skipUnavailableSequenced(ai_ptr, ctx)) {
            clearFinishedOperatorSequence(ai_ptr, ctx.game_time_ms);
            return .none;
        }
        _ = intent_dispatch.advanceSequenced(ai_ptr, ctx);
        clearFinishedOperatorSequence(ai_ptr, ctx.game_time_ms);
    }

    if (ai_ptr.confirm.active) {
        if (intent_confirm.actionWhileConfirming(ai_ptr, &ai_ptr.confirm, ctx)) |held| return held;
        if (ai_ptr.confirm.active) return .none;
        if (intent_dispatch.skipUnavailableSequenced(ai_ptr, ctx)) {
            clearFinishedOperatorSequence(ai_ptr, ctx.game_time_ms);
            return .none;
        }
        _ = intent_dispatch.advanceSequenced(ai_ptr, ctx);
        clearFinishedOperatorSequence(ai_ptr, ctx.game_time_ms);
        return .none;
    }

    const action = intent_dispatch.actionForIntent(ai_ptr.*, ctx, follow_store);
    return if (action != .none) action else .none;
}

const DispatchStep = union(enum) {
    skip,
    stop,
    count: usize,
};

const TargetLossAction = enum {
    none,
    ctm_stop,
    stop_attack,
};

fn dispatchOrderForBot(
    bot: BotSnapshot,
    bot_index: usize,
    bots: []const BotSnapshot,
    world: []const WorldSnapshot,
    events: []const proto.SpellEvent,
    operator_fight_started: bool,
    spec: class_spec.Spec,
    target_store: *const TargetStore,
    target_loss_actions: *const [types.max_bots]TargetLossAction,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    follow_store: *combat.FollowStore,
    out: *[types.max_bots]Order,
    count: usize,
) DispatchStep {
    const bot_name = std.mem.sliceTo(&bot.state.player_name, 0);
    if (botIsDead(bot.state)) {
        intent_store.clear(bot.bot_id, dispatch_store, bot.state.game_time_ms);
        return .skip;
    }

    const ctx = context.CombatContext.build(bot, bots, world, events, operator_fight_started);

    // Out-of-combat poison maintenance for rogue specs.
    if (bot.state.target_guid == 0 and isRogueSpec(spec)) {
        const now_ms = bot.state.game_time_ms;
        const last = poison_last_check_ms[bot_index];
        if (last == 0 or now_ms -| last >= poison_recheck_interval_ms) {
            poison_last_check_ms[bot_index] = now_ms;
            if (buildPoisonLuaMsg()) |msg| {
                out[count] = .{ .bot_id = bot.bot_id, .msg = msg };
                return .{ .count = count + 1 };
            }
        }
    }

    const action = resolveIntentAction(intent_store, bot.bot_id, &ctx, follow_store);

    const active = intent_store.current(bot.bot_id);
    const effective_action = applyTargetOverride(action, active, target_store.getTarget(bot.bot_id), &ctx);
    const bot_snap = registry_mod.findBotSnapshot(bots, &bot.bot_id);

    switch (target_loss_actions[bot_index]) {
        .none => {},
        .ctm_stop => {
            logCombatDispatch("target_lost_stop", bot_name, .ctm_stop, bot_snap, world, active);
            out[count] = .{ .bot_id = bot.bot_id, .msg = .ctm_stop };
            return .{ .count = count + 1 };
        },
        .stop_attack => {
            const stop_action: combat.Action = .stop_attack;
            const msg = actionToMsg(stop_action, bot.state) orelse return .skip;
            logCombatDispatch("target_lost_stop_attack", bot_name, stop_action, bot_snap, world, active);
            out[count] = .{ .bot_id = bot.bot_id, .msg = msg };
            return .{ .count = count + 1 };
        },
    }

    if (polarityTransitBlocksAction(active, effective_action)) {
        logCombatDispatch("polarity_transit_blocked", bot_name, effective_action, bot_snap, world, active);
        return .skip;
    }

    const threat_mitigation_action = urgentThreatMitigationAction(&ctx, active, spec);
    if (threat_mitigation_action != .none) {
        const threat_allowed = switch (combat.dispatchRangeResult(bot, world, spec, threat_mitigation_action)) {
            .allowed => true,
            .blocked_missing_client_range => |ct| blk: {
                logBlocked(bot_name, "range_missing", threat_mitigation_action, bot_snap, active);
                logCombatDispatchRangeMissing(bot_name, threat_mitigation_action, bot_snap, world, active, ct.spell_id, ct.target_guid);
                break :blk false;
            },
            .blocked_out_of_range => |check| blk: {
                logBlocked(bot_name, "range", threat_mitigation_action, bot_snap, active);
                logCombatDispatchRangeBlocked(bot_name, threat_mitigation_action, bot_snap, world, active, check);
                break :blk false;
            },
        };
        if (threat_allowed) {
            const throttle_key = combat.dispatchThrottleKey(threat_mitigation_action);
            if (throttle_key) |key| {
                if (!dispatch_store.dispatchAllowed(bot.bot_id, key, bot.state)) {
                    logCombatDispatch("blocked_throttle", bot_name, threat_mitigation_action, bot_snap, world, active);
                } else if (actionToMsg(threat_mitigation_action, bot.state)) |msg| {
                    if (count >= out.len) return .stop;
                    logCombatDispatch("threat_mitigation", bot_name, threat_mitigation_action, bot_snap, world, active);
                    out[count] = .{ .bot_id = bot.bot_id, .msg = msg };
                    dispatch_store.recordDispatch(bot.bot_id, key, bot.state);
                    return .{ .count = count + 1 };
                }
            }
        }
    }

    const threat_blocked = if (!operator_fight_started and !proto.hasUnitFlag(bot.state.unit_flags, .in_combat))
        false
    else
        dispatch_store.threatBlocked(
            bot.bot_id,
            bot.state.target_guid,
            ctx.threat_high,
            aggro.recoveredThreat(bot, bots, world, spec),
            aggro.threatReadyForBot(bot, bots, world, spec),
            bot.state.game_time_ms,
        );
    const threat_blocked_effective = if (active) |ai|
        if (ai.priority == .encounter or ai.source == .spec_threat) false else threat_blocked
    else
        threat_blocked;
    if (threatNeedsEncounterAutoAttackStop(threat_blocked, active, effective_action, bot.state, spec)) {
        const stop_action: combat.Action = .stop_attack;
        const msg = actionToMsg(stop_action, bot.state) orelse return .skip;
        logCombatDispatch("encounter_threat_stop_attack", bot_name, stop_action, bot_snap, world, active);
        out[count] = .{ .bot_id = bot.bot_id, .msg = msg };
        return .{ .count = count + 1 };
    }
    if (threat_blocked_effective) {
        const should_stop_autoattack = threatNeedsAutoAttackStop(active, effective_action, bot.state);
        if (active) |ai| {
            if (ai.source == .role_start_attack and ai.intent == .start_attack) {
                intent_store.clearByPriority(bot.bot_id, .role, .operator_reset, bot.state.game_time_ms);
            }
        }
        intent_store.clearByPriority(bot.bot_id, .spec, .operator_reset, bot.state.game_time_ms);
        if (!should_stop_autoattack) return .skip;

        const stop_action: combat.Action = .stop_attack;
        const stop_key = combat.dispatchThrottleKey(stop_action).?;
        if (!dispatch_store.dispatchAllowed(bot.bot_id, stop_key, bot.state)) {
            logCombatDispatch("blocked_throttle", bot_name, stop_action, bot_snap, world, active);
            return .skip;
        }
        const msg = actionToMsg(stop_action, bot.state) orelse return .skip;
        logCombatDispatch("threat_stop_attack", bot_name, stop_action, bot_snap, world, active);
        out[count] = .{ .bot_id = bot.bot_id, .msg = msg };
        dispatch_store.recordDispatch(bot.bot_id, stop_key, bot.state);
        return .{ .count = count + 1 };
    }

    if (!combat.actionAllowedEncounterPrep(operator_fight_started, bot.state, effective_action, spec)) {
        logBlocked(bot_name, "prep_gate", effective_action, bot_snap, active);
        logCombatDispatch("blocked_prep_gate", bot_name, effective_action, bot_snap, world, active);
        return .skip;
    }

    switch (combat.dispatchRangeResult(bot, world, spec, effective_action)) {
        .allowed => {},
        .blocked_missing_client_range => |ct| {
            logBlocked(bot_name, "range_missing", effective_action, bot_snap, active);
            logCombatDispatchRangeMissing(bot_name, effective_action, bot_snap, world, active, ct.spell_id, ct.target_guid);
            return .skip;
        },
        .blocked_out_of_range => |check| {
            logBlocked(bot_name, "range", effective_action, bot_snap, active);
            logCombatDispatchRangeBlocked(bot_name, effective_action, bot_snap, world, active, check);
            return .skip;
        },
    }

    const dispatch_action = effective_action;
    if (needsPreCastStop(dispatch_action, active) and bot.state.ctm_action != @intFromEnum(proto.CtmAction.idle)) {
        if (intent_store.currentMut(bot.bot_id)) |ai| {
            ai.confirm.active = true;
            ai.confirm.pending = dispatch_action;
            ai.confirm.cast_stop_sent = true;
        }
        logCombatDispatch("precast_stop", bot_name, dispatch_action, bot_snap, world, active);
        out[count] = .{ .bot_id = bot.bot_id, .msg = .ctm_stop };
        return .{ .count = count + 1 };
    }

    if (needsPreMoveStopCast(dispatch_action, bot.state)) {
        const stop_key = combat.dispatchThrottleKey(.stop_cast).?;
        if (!dispatch_store.dispatchAllowed(bot.bot_id, stop_key, bot.state)) {
            logCombatDispatch("blocked_throttle", bot_name, .stop_cast, bot_snap, world, active);
            return .skip;
        }
        const msg = actionToMsg(.stop_cast, bot.state) orelse return .skip;
        logCombatDispatch("premove_stop_cast", bot_name, dispatch_action, bot_snap, world, active);
        out[count] = .{ .bot_id = bot.bot_id, .msg = msg };
        dispatch_store.recordDispatch(bot.bot_id, stop_key, bot.state);
        return .{ .count = count + 1 };
    }

    const throttle_key = combat.dispatchThrottleKey(dispatch_action);
    if (throttle_key) |key| {
        if (!dispatch_store.dispatchAllowed(bot.bot_id, key, bot.state)) {
            logCombatDispatch("blocked_throttle", bot_name, dispatch_action, bot_snap, world, active);
            return .skip;
        }
    }

    if (castFacingGate(bot, world, dispatch_action)) |facing| {
        const msg = actionToMsg(facing, bot.state) orelse return .skip;
        logCombatDispatch("facing_gate", bot_name, facing, bot_snap, world, active);
        out[count] = .{ .bot_id = bot.bot_id, .msg = msg };
        return .{ .count = count + 1 };
    }

    if (needsRoleStartMovementStop(dispatch_action, active, bot.state)) {
        const stop_key = combat.dispatchThrottleKey(.ctm_stop).?;
        if (!dispatch_store.dispatchAllowed(bot.bot_id, stop_key, bot.state)) {
            logCombatDispatch("blocked_throttle", bot_name, .ctm_stop, bot_snap, world, active);
            return .skip;
        }
        logCombatDispatch("role_start_stop", bot_name, dispatch_action, bot_snap, world, active);
        out[count] = .{ .bot_id = bot.bot_id, .msg = .ctm_stop };
        dispatch_store.recordDispatch(bot.bot_id, stop_key, bot.state);
        if (intent_store.currentMut(bot.bot_id)) |ai| {
            intent_confirm.onDispatched(ai, &ai.confirm, .ctm_stop, bot.state.game_time_ms);
        }
        return .{ .count = count + 1 };
    }

    if (needsAnchorChaseStop(dispatch_action, active, bot.state)) {
        const stop_key = combat.dispatchThrottleKey(.stop_attack).?;
        if (!dispatch_store.dispatchAllowed(bot.bot_id, stop_key, bot.state)) {
            logCombatDispatch("blocked_throttle", bot_name, .stop_attack, bot_snap, world, active);
            return .skip;
        }
        const msg = actionToMsg(.stop_attack, bot.state) orelse return .skip;
        logCombatDispatch("anchor_chase_stop", bot_name, .stop_attack, bot_snap, world, active);
        out[count] = .{ .bot_id = bot.bot_id, .msg = msg };
        dispatch_store.recordDispatch(bot.bot_id, stop_key, bot.state);
        return .{ .count = count + 1 };
    }

    const msg = actionToMsg(dispatch_action, bot.state) orelse {
        if (intent_confirm.trackJumpNearWithoutMsg(intent_store.currentMut(bot.bot_id), dispatch_action, bot.state)) {
            return .skip;
        }
        return .skip;
    };

    if (count >= out.len) return .stop;

    logCombatDispatch("accepted", bot_name, dispatch_action, bot_snap, world, active);
    out[count] = .{ .bot_id = bot.bot_id, .msg = msg };
    const new_count = count + 1;
    if (throttle_key) |key| dispatch_store.recordDispatch(bot.bot_id, key, bot.state);
    if (intent_store.currentMut(bot.bot_id)) |ai| {
        intent_dispatch.markSequencedStepTriggerFired(ai, dispatch_action, &ctx);
        intent_confirm.onDispatched(ai, &ai.confirm, dispatch_action, bot.state.game_time_ms);
        if (!ai.confirm.active) {
            _ = intent_dispatch.advanceSequenced(ai, &ctx);
        }
    }
    markAnchoredStartAttackDispatched(dispatch_action, active, follow_store, bot);
    return .{ .count = new_count };
}

fn dispatchOrdersFromIntents(
    bots: []const BotSnapshot,
    world: []const WorldSnapshot,
    events: []const proto.SpellEvent,
    out: *[types.max_bots]Order,
    dispatch_store: *DispatchStore,
    follow_store: *combat.FollowStore,
    intent_store: *IntentStore,
    operator_fight_started: bool,
    target_store: *const TargetStore,
    target_loss_actions: *const [types.max_bots]TargetLossAction,
) []const Order {
    var count: usize = 0;

    for (bots, 0..) |bot, bot_index| {
        if (count >= out.len) break;

        const spec = if (combat.classFromState(bot.state)) |cls|
            combat.primarySpec(cls, bot.state.talent_points)
        else
            .unknown;

        switch (dispatchOrderForBot(
            bot,
            bot_index,
            bots,
            world,
            events,
            operator_fight_started,
            spec,
            target_store,
            target_loss_actions,
            intent_store,
            dispatch_store,
            follow_store,
            out,
            count,
        )) {
            .skip => {},
            .stop => break,
            .count => |new_count| count = new_count,
        }
    }

    return out[0..count];
}

pub fn computeWithProposers(
    bots: []const BotSnapshot,
    world: []const WorldSnapshot,
    events: []const proto.SpellEvent,
    out: *[types.max_bots]Order,
    dispatch_store: *DispatchStore,
    follow_store: *combat.FollowStore,
    intent_store: *IntentStore,
    operator_fight_started: bool,
    role_propose: RoleProposeFn,
    spec_propose: SpecProposeFn,
    traces: ?*combat_debug.TraceBuffer,
) []const Order {
    var target_store: TargetStore = .{};
    var target_loss_actions: [types.max_bots]TargetLossAction = .{.none} ** types.max_bots;

    if (!operator_fight_started) {
        clearPrepGatedEncounterIntents(bots, intent_store);
    }

    intent_encounter.beginTick(bots, world, events, operator_fight_started, intent_store);

    for (bots, 0..) |bot, bot_index| {
        proposeIntentsForBot(
            bot,
            bot_index,
            bots,
            world,
            events,
            operator_fight_started,
            role_propose,
            spec_propose,
            &target_store,
            &target_loss_actions,
            intent_store,
            dispatch_store,
            follow_store,
            traces,
        );
    }

    intent_store.pruneExpired(if (bots.len > 0) bots[0].state.game_time_ms else 0);

    return dispatchOrdersFromIntents(
        bots,
        world,
        events,
        out,
        dispatch_store,
        follow_store,
        intent_store,
        operator_fight_started,
        &target_store,
        &target_loss_actions,
    );
}

fn roleStartNeedsMovementStop(ai: intent.ActiveIntent, state: proto.State) bool {
    if (ai.source != .role_start_attack) return false;
    if (ai.intent != .start_attack) return false;
    return ctmActionNeedsStop(state.ctm_action);
}

fn roleStartMustPrecedeSpec(ai: intent.ActiveIntent, ctx: *const context.CombatContext, follow_store: *combat.FollowStore) bool {
    if (ai.source != .role_start_attack) return false;
    if (ai.intent != .start_attack) return false;
    if (ctx.role != .tank) return false;
    const target_guid = ctx.primary_target orelse return false;
    const entry = follow_store.get(ctx.bot.bot_id) orelse return false;
    const pos = entry.position_override orelse return false;
    if (!pos.authoritative) return false;
    return entry.target_guid != target_guid or !entry.attack_started;
}

fn markAnchoredStartAttackDispatched(action: combat.Action, active: ?intent.ActiveIntent, follow_store: *combat.FollowStore, bot: BotSnapshot) void {
    if (action != .start_attack) return;
    const ai = active orelse return;
    if (ai.source != .role_start_attack) return;
    const entry = follow_store.get(bot.bot_id) orelse return;
    const pos = entry.position_override orelse return;
    if (!pos.authoritative) return;
    if (bot.state.target_guid == 0) return;
    entry.target_guid = bot.state.target_guid;
    entry.attack_started = true;
}

fn needsRoleStartMovementStop(action: combat.Action, active: ?intent.ActiveIntent, state: proto.State) bool {
    if (action != .start_attack) return false;
    const ai = active orelse return false;
    return roleStartNeedsMovementStop(ai, state);
}

/// Detects the situation where the planner wants the bot to hold position and
/// just face the target (e.g. tank anchored on a Thaddius platform with the
/// twin still walking in via threat) while the WoW client has started an
/// auto-attack chase (`ctm_action == attack_pos`) toward that target. In that
/// inconsistent state we dispatch `stop_attack` to toggle the auto-attack flag
/// off; the engine then stops driving the bot toward the target on its own.
fn needsAnchorChaseStop(action: combat.Action, active: ?intent.ActiveIntent, state: proto.State) bool {
    if (action != .set_facing_rad) return false;
    const ai = active orelse return false;
    if (ai.priority != .role) return false;
    return state.ctm_action == @intFromEnum(proto.CtmAction.attack_pos);
}

fn polarityTransitBlocksAction(active: ?intent.ActiveIntent, dispatch_action: combat.Action) bool {
    const ai = active orelse return false;
    if (!intent.isPolarityTransit(ai)) return false;
    return startsAutoAttack(dispatch_action);
}

fn startsAutoAttack(action: combat.Action) bool {
    return switch (action) {
        .attack, .start_attack => true,
        else => false,
    };
}

fn actionAdvancesEncounterMovement(action: combat.Action) bool {
    return switch (action) {
        .move_to, .move_to_nb, .jump, .jump_near_xy, .walk, .ctm_stop => true,
        else => false,
    };
}

fn encounterHoldWaiting(active: intent.ActiveIntent) bool {
    if (active.intent != .sequenced) return false;
    const seq = active.intent.sequenced;
    if (seq.current >= seq.len) return false;
    return seq.steps[seq.current].intent == .waiting_for;
}

fn threatNeedsEncounterAutoAttackStop(threat_blocked: bool, active: ?intent.ActiveIntent, action: combat.Action, state: proto.State, spec: class_spec.Spec) bool {
    if (!threat_blocked) return false;
    const ai = active orelse return false;
    if (ai.priority != .encounter) return false;
    if (!activeSequenceInFlight(ai)) return false;
    if (actionAdvancesEncounterMovement(action)) return false;
    if (startsAutoAttack(action)) return true;

    const ctm = std.enums.fromInt(proto.CtmAction, state.ctm_action) orelse return false;
    if (switch (ctm) {
        .attack, .attack_pos => true,
        else => false,
    }) return true;

    if (spec_registry.meta(spec).profile != .ranged) return false;
    if (ctm != .idle) return false;
    return (ai.source == .encounter_swap or ai.source == .encounter_pull) and encounterHoldWaiting(ai);
}

fn urgentThreatMitigationAction(ctx: *const context.CombatContext, active: ?intent.ActiveIntent, spec: class_spec.Spec) combat.Action {
    if (!ctx.threat_high) return .none;

    const ai = active orelse return .none;
    if (ai.priority != .encounter) return .none;

    const threat_plan = spec_registry.meta(spec).threat_plan orelse return .none;
    return threat_plan(ctx);
}

fn threatNeedsAutoAttackStop(active: ?intent.ActiveIntent, action: combat.Action, state: proto.State) bool {
    if (startsAutoAttack(action)) return true;

    const ctm = std.enums.fromInt(proto.CtmAction, state.ctm_action) orelse return false;
    if (switch (ctm) {
        .attack, .attack_pos => true,
        else => false,
    }) return true;

    const ai = active orelse return false;
    return ai.intent == .start_attack;
}

fn needsPreCastStop(action: combat.Action, active: ?intent.ActiveIntent) bool {
    if (intent_confirm.needsPreCastStop(action)) return true;
    _ = active;
    return false;
}

/// Symmetric to `needsPreCastStop`: a click-to-move issued while the bot is
/// mid cast/channel is ignored by the WoW engine, so the move order is lost.
/// When the planner wants to relocate a casting bot (e.g. encounter movement
/// preempting a spec cast), interrupt the cast first; the move re-dispatches the
/// next tick once `is_casting`/`is_channeling` clear.
fn needsPreMoveStopCast(action: combat.Action, state: proto.State) bool {
    return switch (action) {
        .move_to, .move_to_nb => state.is_casting != 0 or state.is_channeling != 0,
        else => false,
    };
}

fn botIsDead(state: proto.State) bool {
    return state.hp_max != 0 and state.hp == 0;
}

const actionToMsg = action_msg.actionToMsg;
const ctmActionNeedsStop = action_msg.ctmActionNeedsStop;

const intentReasonPrefix = brain_log.intentReasonPrefix;
const intentTagName = brain_log.intentTagName;
const logBlocked = brain_log.logBlocked;
const logCombatDispatch = brain_log.logCombatDispatch;
const logCombatDispatchRangeMissing = brain_log.logCombatDispatchRangeMissing;
const logCombatDispatchRangeBlocked = brain_log.logCombatDispatchRangeBlocked;

fn prefixMatchCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..needle.len) |i| {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(needle[i])) return false;
    }
    return true;
}

fn resolveTarget(target: ?[]const u8, bots: []const BotSnapshot, buf: []types.BotId) ?[]const types.BotId {
    const name = target orelse return null;
    var count: usize = 0;
    for (bots) |bot| {
        const bot_id_str = std.mem.sliceTo(&bot.state.bot_id, 0);
        const player_name_str = std.mem.sliceTo(&bot.state.player_name, 0);
        if (prefixMatchCI(bot_id_str, name) or prefixMatchCI(player_name_str, name)) {
            if (count >= buf.len) break;
            buf[count] = bot.bot_id;
            count += 1;
        }
    }
    if (count == 0) return null;
    return buf[0..count];
}

test "applyTargetOverride: survival start_attack prefers target selection over attack_pos" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id[0] = 8;
    bot.state.guid = 0x1008;
    bot.state.class = @intFromEnum(class_spec.Class.hunter);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    bot.state.target_guid = 0;
    bot.state.target_unit_reaction = 2;
    bot.state.game_time_ms = 1000;

    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    const active: intent.ActiveIntent = .{
        .intent = .start_attack,
        .priority = .role,
        .created_at_ms = bot.state.game_time_ms,
        .source = .role_start_attack,
    };
    const target: TargetStore.Target = .{ .guid = 0xabc, .mode = .attack };

    const action = applyTargetOverride(.start_attack, active, target, &ctx);
    try std.testing.expect(action == .target_guid);
    try std.testing.expectEqual(@as(u64, 0xabc), action.target_guid);
}

test "applyTargetOverride: polarity transit movement is not replaced by target" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id[0] = 9;
    bot.state.guid = 0x1009;
    bot.state.class = @intFromEnum(class_spec.Class.rogue);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0;
    bot.state.target_unit_reaction = 2;
    bot.state.game_time_ms = 1000;

    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    const active: intent.ActiveIntent = .{
        .intent = .{ .stacking = .{ .x = 10, .y = 20, .z = 30, .tolerance = 1.5, .reason = .encounter_stack } },
        .priority = .encounter,
        .created_at_ms = bot.state.game_time_ms,
        .source = .encounter_stack,
    };
    const target: TargetStore.Target = .{ .guid = 0xabc, .mode = .attack };

    const move: combat.Action = .{ .move_to = .{ .x = 10, .y = 20, .z = 30 } };
    const action = applyTargetOverride(move, active, target, &ctx);
    try std.testing.expect(action == .move_to);
    try std.testing.expectEqual(@as(f32, 10), action.move_to.x);
}

test "threatNeedsEncounterAutoAttackStop ignores completed encounter sequence" {
    var state: proto.State = std.mem.zeroes(proto.State);
    state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    var seq = intent.Sequenced{ .steps = undefined, .len = 1, .current = 1 };
    seq.steps[0] = .{ .intent = .stop_attack };

    const ai: intent.ActiveIntent = .{
        .intent = .{ .sequenced = seq },
        .priority = .encounter,
        .created_at_ms = 1000,
        .source = .encounter_pull,
    };

    try std.testing.expect(!threatNeedsEncounterAutoAttackStop(true, ai, .{ .attack = 0xabc }, state, .assassination));
}

test "polarityTransitBlocksAction: stacking movement is never blocked by chase state" {
    const ai: intent.ActiveIntent = .{
        .intent = .{ .stacking = .{ .x = 0, .y = 0, .z = 0, .tolerance = 1.5, .reason = .encounter_stack } },
        .priority = .encounter,
        .created_at_ms = 0,
        .source = .encounter_stack,
    };

    try std.testing.expect(!polarityTransitBlocksAction(ai, .{ .move_to = .{ .x = 10, .y = 20, .z = 30 } }));
}

test "polarityTransitBlocksAction: blocks new autoattack during stacking" {
    const ai: intent.ActiveIntent = .{
        .intent = .{ .stacking = .{ .x = 0, .y = 0, .z = 0, .tolerance = 1.5, .reason = .encounter_stack } },
        .priority = .encounter,
        .created_at_ms = 0,
        .source = .encounter_stack,
    };

    try std.testing.expect(polarityTransitBlocksAction(ai, .start_attack));
}

