const std = @import("std");
const proto = @import("protocol");
const aggro = @import("../aggro.zig");
const context = @import("../context.zig");
const encounter = @import("../encounters/mod.zig");
const intent = @import("../intent/mod.zig");
const spec_registry = @import("../specs/spec_registry.zig");
const world_query = @import("../world_query.zig");

const ActiveIntent = intent.ActiveIntent;
const CombatContext = context.CombatContext;

const rescue_intent_age_ms: u32 = proto.brain_tick_ms * 5;

pub fn proposeIntent(ctx: *const CombatContext) ?ActiveIntent {
    if (ctx.role != .tank) return null;
    if (!ctx.operator_fight_started and encounter.mapUsesOperatorPrepGate(ctx.bot.state.map_id)) return null;
    if (!ctx.operator_fight_started and !encounter.mapUsesOperatorPrepGate(ctx.bot.state.map_id)) return null;

    const spell = spec_registry.meta(ctx.spec).taunt_spell orelse return null;
    if (!ctx.spellReady(spell.spell_id)) return null;

    const candidate = aggro.rescueCandidateForTank(ctx.bot, ctx.bots, ctx.world) orelse return null;
    if (candidate.decision != .rescue) return null;
    const target = world_query.scanForGuidOnMap(ctx.world, candidate.hostile_guid, ctx.bot.state.map_id) orelse return null;
    const client_range = clientSpellRange(ctx.bot.state, spell.spell_id) orelse return null;
    if (!targetInRange(ctx.bot.state, target, client_range)) return null;

    std.log.debug("tank_rescue bot={s} hostile=0x{x} holder=0x{x} holder_role={s} owner=0x{x} owner_threat={} holder_threat={} holder_pct={} spell={} decision={s}", .{
        std.mem.sliceTo(&ctx.bot.state.player_name, 0),
        candidate.hostile_guid,
        candidate.holder_guid,
        @tagName(candidate.holder_role),
        candidate.owner_bot_id[0],
        candidate.owner_threat,
        candidate.holder_threat,
        candidate.holder_pct,
        spell.spell_id,
        @tagName(candidate.decision),
    });

    return .{
        .intent = .{ .casting_scripted = .{
            .spell_id = spell.spell_id,
            .target_guid = candidate.hostile_guid,
            .instant = true,
            .one_shot = true,
        } },
        .priority = .spec,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = rescue_intent_age_ms,
        .source = .tank_rescue,
    };
}

fn clientSpellRange(state: proto.State, spell_id: u32) ?f32 {
    const n = @min(state.spell_range_count, state.spell_ranges.len);
    for (state.spell_ranges[0..n]) |entry| {
        if (entry.spell_id != spell_id) continue;
        if (entry.max_range_yards <= 0) return null;
        return entry.max_range_yards;
    }
    return null;
}

fn targetInRange(state: proto.State, target: proto.ScanEntry, client_range: f32) bool {
    const dx = target.x - state.x;
    const dy = target.y - state.y;
    const dz = target.z - state.z;
    const effective_range = client_range + target.combat_reach;
    return dx * dx + dy * dy + dz * dz <= effective_range * effective_range;
}

test "proposeIntent: blood dk uses dark command only" {
    var tank = std.mem.zeroes(@import("registry").BotSnapshot);
    tank.bot_id[0] = 1;
    tank.state.guid = 0x100;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(@import("../class_spec.zig").Class.death_knight);
    tank.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    tank.state.spell_range_count = 1;
    tank.state.spell_ranges[0] = .{ .spell_id = 56222, .max_range_yards = 30.0 };
    tank.state.target_guid = 0xabc;
    tank.state.target_threat_count = 2;
    tank.state.target_threats[0] = .{ .unit_guid = 0x100, .threat = 1000 };
    tank.state.target_threats[1] = .{ .unit_guid = 0x200, .threat = 900 };

    var dps = std.mem.zeroes(@import("registry").BotSnapshot);
    dps.state.guid = 0x200;
    dps.state.map_id = 1;
    dps.state.class = @intFromEnum(@import("../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.target_guid = dps.state.guid;
    scan.x = 10;

    const bots = [_]@import("registry").BotSnapshot{ tank, dps };
    const world = [_]@import("../../world/memory.zig").WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(tank, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;
    try std.testing.expectEqual(intent.Reason.tank_rescue, ai.source);
    try std.testing.expectEqual(@as(u32, 56222), ai.intent.casting_scripted.spell_id);
}

test "proposeIntent: protection paladin uses hand of reckoning only" {
    var tank = std.mem.zeroes(@import("registry").BotSnapshot);
    tank.bot_id[0] = 1;
    tank.state.guid = 0x100;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(@import("../class_spec.zig").Class.paladin);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    tank.state.spell_range_count = 1;
    tank.state.spell_ranges[0] = .{ .spell_id = 62124, .max_range_yards = 30.0 };
    tank.state.target_guid = 0xabc;
    tank.state.target_threat_count = 2;
    tank.state.target_threats[0] = .{ .unit_guid = 0x100, .threat = 1000 };
    tank.state.target_threats[1] = .{ .unit_guid = 0x200, .threat = 900 };

    var dps = std.mem.zeroes(@import("registry").BotSnapshot);
    dps.state.guid = 0x200;
    dps.state.map_id = 1;
    dps.state.class = @intFromEnum(@import("../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.target_guid = dps.state.guid;
    scan.x = 10;

    const bots = [_]@import("registry").BotSnapshot{ tank, dps };
    const world = [_]@import("../../world/memory.zig").WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(tank, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;
    try std.testing.expectEqual(intent.Reason.tank_rescue, ai.source);
    try std.testing.expectEqual(@as(u32, 62124), ai.intent.casting_scripted.spell_id);
}

test "proposeIntent: no fallback when taunt is unavailable" {
    var tank = std.mem.zeroes(@import("registry").BotSnapshot);
    tank.bot_id[0] = 1;
    tank.state.guid = 0x100;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(@import("../class_spec.zig").Class.death_knight);
    tank.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    tank.state.spell_range_count = 1;
    tank.state.spell_ranges[0] = .{ .spell_id = 49576, .max_range_yards = 30.0 };
    tank.state.target_guid = 0xabc;
    tank.state.target_threat_count = 2;
    tank.state.target_threats[0] = .{ .unit_guid = 0x100, .threat = 1000 };
    tank.state.target_threats[1] = .{ .unit_guid = 0x200, .threat = 900 };

    var dps = std.mem.zeroes(@import("registry").BotSnapshot);
    dps.state.guid = 0x200;
    dps.state.map_id = 1;
    dps.state.class = @intFromEnum(@import("../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.target_guid = dps.state.guid;
    scan.x = 10;

    const bots = [_]@import("registry").BotSnapshot{ tank, dps };
    const world = [_]@import("../../world/memory.zig").WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(tank, &bots, &world, &.{}, true);
    try std.testing.expect(proposeIntent(&ctx) == null);
}

test "proposeIntent: prep gated encounter does not rescue before start fight" {
    var tank = std.mem.zeroes(@import("registry").BotSnapshot);
    tank.bot_id[0] = 1;
    tank.state.guid = 0x100;
    tank.state.map_id = encounter.thaddius_map_id;
    tank.state.class = @intFromEnum(@import("../class_spec.zig").Class.paladin);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    tank.state.spell_range_count = 1;
    tank.state.spell_ranges[0] = .{ .spell_id = 62124, .max_range_yards = 30.0 };
    tank.state.target_guid = 0xabc;
    tank.state.target_threat_count = 2;
    tank.state.target_threats[0] = .{ .unit_guid = tank.state.guid, .threat = 1000 };
    tank.state.target_threats[1] = .{ .unit_guid = 0x200, .threat = 900 };

    var dps = std.mem.zeroes(@import("registry").BotSnapshot);
    dps.state.guid = 0x200;
    dps.state.map_id = encounter.thaddius_map_id;
    dps.state.class = @intFromEnum(@import("../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.target_guid = dps.state.guid;
    scan.x = 10;

    const bots = [_]@import("registry").BotSnapshot{ tank, dps };
    const world = [_]@import("../../world/memory.zig").WorldSnapshot{.{ .scan = scan, .map_id = encounter.thaddius_map_id, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(tank, &bots, &world, &.{}, false);
    try std.testing.expect(proposeIntent(&ctx) == null);
}
