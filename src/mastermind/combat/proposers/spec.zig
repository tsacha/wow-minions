// Spec proposer: priority .spec.
// Calls the spec rotation once per tick and maps the resulting Action to an intent.

const std = @import("std");
const proto = @import("protocol");
const action_mod = @import("../action.zig");
const cast_range = @import("../cast_range.zig");
const context = @import("../context.zig");
const dispatch = @import("../dispatch.zig");
const encounter = @import("../encounters/mod.zig");
const intent = @import("../intent/mod.zig");
const prep_gate = @import("../prep_gate.zig");
const spec_routine = @import("../spec_routine.zig");
const spec_registry = @import("../specs/spec_registry.zig");
const spells_db = @import("../spells.zig");

const Action = action_mod.Action;
const ActiveIntent = intent.ActiveIntent;
const CombatContext = context.CombatContext;

// Safety-net TTL: if the spec proposer skips several ticks (e.g. threat_high),
// the intent expires rather than driving a stale dispatch. Primary eviction is
// clearByPriority in compute() — this TTL is a secondary guard.
const spec_intent_stale_ticks: u32 = 5;
const spec_intent_ttl_ms: u32 = spec_intent_stale_ticks * proto.brain_tick_ms;

pub fn proposeIntent(ctx: *const CombatContext) ?ActiveIntent {
    const meta = spec_registry.meta(ctx.spec);
    if (ctx.threat_high) {
        const threat_plan = meta.threat_plan orelse return null;
        const spec_action = threat_plan(ctx);
        if (spec_action == .none) return null;
        return intentFromActionWithSource(ctx, spec_action, .spec_threat);
    }

    const spec_action = spec_routine.planSpecRoutineWithContext(ctx);
    if (spec_action == .none) return null;

    if (ctx.spec == .unknown and isSelfBuffAction(spec_action)) return null;

    // A targeted cast that is currently out of range must not become the active
    // intent: it would preempt the role's positioning intent (moving_to) yet the
    // dispatcher would refuse to send the cast, leaving the bot frozen with no
    // movement and no auto-attack. Returning null here lets the role drive
    // placement until the bot reaches melee/casting range.
    // `blocked_missing_client_range` is tolerated: the dispatcher still blocks
    // and logs, but yielding here would silently mute the spec for any spell
    // whose client range is not populated yet.
    switch (cast_range.dispatchRangeResult(ctx.bot, ctx.world, ctx.spec, spec_action)) {
        .blocked_out_of_range => return null,
        .allowed, .blocked_missing_client_range => {},
    }

    const on_prep_map = !ctx.operator_fight_started and
        encounter.mapUsesOperatorPrepGate(ctx.bot.state.map_id);

    if (on_prep_map) {
        if (!prep_gate.actionAllowed(ctx.operator_fight_started, ctx.bot.state, spec_action, ctx.spec)) {
            return null;
        }
        return intentFromAction(ctx, spec_action);
    }

    return intentFromAction(ctx, spec_action);
}

fn isSelfBuffAction(action: Action) bool {
    const spell_id = switch (action) {
        .cast => |id| id,
        .cast_instant => |id| id,
        .cast_target => |ct| ct.spell_id,
        .cast_target_instant => |ct| ct.spell_id,
        else => return false,
    };
    const spell = spells_db.lookup(spell_id) orelse return false;
    return spell.self_aura;
}

fn intentFromAction(ctx: *const CombatContext, action: Action) ?ActiveIntent {
    return intentFromActionWithSource(ctx, action, .spec_attack);
}

fn intentFromActionWithSource(ctx: *const CombatContext, action: Action, source: intent.Reason) ?ActiveIntent {
    const result: intent.Intent = switch (action) {
        .none => return null,
        .attack => |guid| .{ .attacking = .{ .target_guid = guid } },
        .start_attack => .{
            .attacking = .{
                .target_guid = ctx.primary_target orelse ctx.bot.state.target_guid,
            },
        },
        .cast => |spell_id| .{
            .casting_scripted = .{
                .spell_id = spell_id,
                .target_guid = ctx.bot.state.guid,
                .instant = false,
            },
        },
        .cast_instant => |spell_id| .{
            .casting_scripted = .{
                .spell_id = spell_id,
                .target_guid = ctx.bot.state.guid,
                .instant = true,
            },
        },
        .cast_target => |ct| .{
            .casting_scripted = .{
                .spell_id = ct.spell_id,
                .target_guid = ct.target_guid,
                .instant = false,
            },
        },
        .cast_target_instant => |ct| .{
            .casting_scripted = .{
                .spell_id = ct.spell_id,
                .target_guid = ct.target_guid,
                .instant = true,
            },
        },
        .cast_ground => |cg| .{
            .casting_scripted_ground = .{
                .spell_id = cg.spell_id,
                .x = cg.x,
                .y = cg.y,
                .z = cg.z,
                .instant = true,
            },
        },
        .move_to => |p| .{
            .moving_to = .{
                .pos = .{ .x = p.x, .y = p.y, .z = p.z },
                .reason = .spec_attack,
                .non_blocking = false,
            },
        },
        .move_to_nb => |p| .{
            .moving_to = .{
                .pos = .{ .x = p.x, .y = p.y, .z = p.z },
                .reason = .spec_attack,
                .non_blocking = true,
            },
        },
        .apply_poison => |item_id| .{ .apply_poison = item_id },
        else => return null,
    };

    switch (result) {
        .attacking => |atk| if (atk.target_guid == 0) return null,
        else => {},
    }

    return ActiveIntent{
        .intent = result,
        .priority = .spec,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = spec_intent_ttl_ms,
        .source = source,
    };
}

test "intentFromAction: maps cast_target_instant to casting_scripted" {
    const BotSnapshot = @import("registry").BotSnapshot;
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    const ctx = CombatContext.build(bot, &.{bot}, &.{}, &.{}, false);
    const ai = intentFromAction(&ctx, .{
        .cast_target_instant = .{ .spell_id = 49909, .target_guid = 0xdead },
    }).?;
    try std.testing.expect(ai.intent == .casting_scripted);
    try std.testing.expect(ai.source == .spec_attack);
    try std.testing.expect(ai.intent.casting_scripted.instant);
    try std.testing.expectEqual(@as(u32, 49909), ai.intent.casting_scripted.spell_id);
}

test "proposeIntent: skips spec intent when targeted cast is out of range" {
    const BotSnapshot = @import("registry").BotSnapshot;
    const world_memory_mod = @import("../../world/memory.zig");
    const WorldSnapshot = world_memory_mod.WorldSnapshot;

    // Stub spec routine: arms-like, proposes Sunder Armor against the bot's target.
    const sunder_armor_id: u32 = 7386;
    const target_guid: u64 = 0xabc;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    bot.state.map_id = 1;
    bot.state.target_guid = target_guid;
    bot.state.target_unit_reaction = 2;
    bot.state.x = 0;
    bot.state.y = 0;
    bot.state.z = 0;
    // Warrior class so the spec resolves to arms (default talent layout).
    bot.state.class = 1;
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.shapeshift_form = 17; // battle_stance, prevents stance dance branch
    bot.state.active_power = 300; // enough rage for sunder armor
    bot.state.spell_range_count = 3;
    bot.state.spell_ranges[0] = .{ .spell_id = 47465, .max_range_yards = 5.0 };
    bot.state.spell_ranges[1] = .{ .spell_id = sunder_armor_id, .max_range_yards = 5.0 };
    bot.state.spell_ranges[2] = .{ .spell_id = 47486, .max_range_yards = 5.0 };
    bot.state.target_aura_count = 1;
    bot.state.target_auras[0] = .{ .caster_guid = 0x100, .spell_id = 47465, .remaining_ms = 15000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = target_guid;
    scan.hp = 100;
    scan.x = 12.0; // 12 yards away, well out of 5y + combat_reach
    scan.combat_reach = 1.0;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    try std.testing.expect(proposeIntent(&ctx) == null);

    // Move the target into melee → spec should propose an intent again.
    var scan_in_range = scan;
    scan_in_range.x = 3.0;
    const world_in_range = [_]WorldSnapshot{.{
        .scan = scan_in_range,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};
    const ctx_in_range = CombatContext.build(bot, &.{bot}, &world_in_range, &.{}, true);
    const ai = proposeIntent(&ctx_in_range) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ai.intent == .casting_scripted);
    try std.testing.expectEqual(sunder_armor_id, ai.intent.casting_scripted.spell_id);
}

test "proposeIntent: blocks self buff when spec is unknown" {
    const BotSnapshot = @import("registry").BotSnapshot;
    const world_memory_mod = @import("../../world/memory.zig");
    const WorldSnapshot = world_memory_mod.WorldSnapshot;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    bot.state.map_id = 1;
    bot.state.class = 0;

    const world = [_]WorldSnapshot{};
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    try std.testing.expect(ctx.spec == .unknown);
    try std.testing.expect(proposeIntent(&ctx) == null);
}

test "proposeIntent: survival threat high uses Feign Death" {
    const BotSnapshot = @import("registry").BotSnapshot;
    const WorldSnapshot = @import("../../world/memory.zig").WorldSnapshot;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    bot.state.map_id = 1;
    bot.state.class = @intFromEnum(@import("../class_spec.zig").Class.hunter);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    var ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    ctx.threat_high = true;

    const ai = proposeIntent(&ctx) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ai.intent == .casting_scripted);
    try std.testing.expect(ai.source == .spec_threat);
    try std.testing.expect(ai.intent.casting_scripted.instant);
    try std.testing.expectEqual(@as(u32, 5384), ai.intent.casting_scripted.spell_id);
}

test "proposeIntent: arcane threat high uses Mirror Image" {
    const BotSnapshot = @import("registry").BotSnapshot;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    bot.state.map_id = 1;
    bot.state.class = @intFromEnum(@import("../class_spec.zig").Class.mage);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var ctx = CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    ctx.threat_high = true;

    const ai = proposeIntent(&ctx) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ai.intent == .casting_scripted);
    try std.testing.expect(ai.source == .spec_threat);
    try std.testing.expect(ai.intent.casting_scripted.instant);
    try std.testing.expectEqual(@as(u32, 55342), ai.intent.casting_scripted.spell_id);
}

test "proposeIntent: shadow threat high uses Fade" {
    const BotSnapshot = @import("registry").BotSnapshot;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    bot.state.map_id = 1;
    bot.state.class = @intFromEnum(@import("../class_spec.zig").Class.priest);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var ctx = CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    ctx.threat_high = true;

    const ai = proposeIntent(&ctx) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ai.intent == .casting_scripted);
    try std.testing.expect(ai.source == .spec_threat);
    try std.testing.expect(ai.intent.casting_scripted.instant);
    try std.testing.expectEqual(@as(u32, 586), ai.intent.casting_scripted.spell_id);
}

test "proposeIntent: warlock threat high uses Soulshatter" {
    const BotSnapshot = @import("registry").BotSnapshot;

    var affliction_bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    affliction_bot.state.guid = 0x100;
    affliction_bot.state.map_id = 1;
    affliction_bot.state.class = @intFromEnum(@import("../class_spec.zig").Class.warlock);
    affliction_bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var affliction_ctx = CombatContext.build(affliction_bot, &.{affliction_bot}, &.{}, &.{}, true);
    affliction_ctx.threat_high = true;
    const affliction_ai = proposeIntent(&affliction_ctx) orelse return error.TestUnexpectedResult;
    try std.testing.expect(affliction_ai.intent == .casting_scripted);
    try std.testing.expectEqual(@as(u32, 29858), affliction_ai.intent.casting_scripted.spell_id);

    var demonology_bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    demonology_bot.state.guid = 0x100;
    demonology_bot.state.map_id = 1;
    demonology_bot.state.class = @intFromEnum(@import("../class_spec.zig").Class.warlock);
    demonology_bot.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };

    var demonology_ctx = CombatContext.build(demonology_bot, &.{demonology_bot}, &.{}, &.{}, true);
    demonology_ctx.threat_high = true;
    const demonology_ai = proposeIntent(&demonology_ctx) orelse return error.TestUnexpectedResult;
    try std.testing.expect(demonology_ai.intent == .casting_scripted);
    try std.testing.expectEqual(@as(u32, 29858), demonology_ai.intent.casting_scripted.spell_id);

    var destruction_bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    destruction_bot.state.guid = 0x100;
    destruction_bot.state.map_id = 1;
    destruction_bot.state.class = @intFromEnum(@import("../class_spec.zig").Class.warlock);
    destruction_bot.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var destruction_ctx = CombatContext.build(destruction_bot, &.{destruction_bot}, &.{}, &.{}, true);
    destruction_ctx.threat_high = true;
    const destruction_ai = proposeIntent(&destruction_ctx) orelse return error.TestUnexpectedResult;
    try std.testing.expect(destruction_ai.intent == .casting_scripted);
    try std.testing.expectEqual(@as(u32, 29858), destruction_ai.intent.casting_scripted.spell_id);
}

test "proposeIntent: feral threat high uses Cower" {
    const BotSnapshot = @import("registry").BotSnapshot;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    bot.state.map_id = 1;
    bot.state.class = @intFromEnum(@import("../class_spec.zig").Class.druid);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    bot.state.shapeshift_form = 1;

    var ctx = CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    ctx.threat_high = true;

    const ai = proposeIntent(&ctx) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ai.intent == .casting_scripted);
    try std.testing.expect(ai.source == .spec_threat);
    try std.testing.expect(ai.intent.casting_scripted.instant);
    try std.testing.expectEqual(@as(u32, 48575), ai.intent.casting_scripted.spell_id);
}

test "proposeIntent: threat high without threat action stops spec rotation" {
    const BotSnapshot = @import("registry").BotSnapshot;
    const WorldSnapshot = @import("../../world/memory.zig").WorldSnapshot;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    bot.state.map_id = 1;
    bot.state.class = @intFromEnum(@import("../class_spec.zig").Class.rogue);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    var ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    ctx.threat_high = true;

    try std.testing.expect(proposeIntent(&ctx) == null);
}
