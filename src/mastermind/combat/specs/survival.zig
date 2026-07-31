//! Fusilroc, Traquenard (G2). Roster : assets/setup.md

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const spells_db = @import("../spells.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");
const aggro = @import("../aggro.zig");
const cooldown = @import("../cooldown.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;
const CombatContext = @import("../context.zig").CombatContext;

pub const data = struct {
    pub const spells = struct {
        pub const feign_death = spells_db.get(5384);
        pub const kill_shot = spells_db.get(61006);
        pub const explosive_shot = spells_db.get(60052);
        pub const serpent_sting = spells_db.get(49001);
        pub const black_arrow = spells_db.get(63672);
        pub const aimed_shot = spells_db.get(49050);
        pub const steady_shot = spells_db.get(49052);
        pub const misdirection = spells_db.get(34477);
    };
    pub const resources = struct {};
};

const kill_shot_hp_pct: u32 = 20;

fn spellReady(state: proto.State, spell_id: u32) bool {
    return !world_query.hasCooldown(&state.cooldowns, state.cooldown_count, spell_id);
}

fn targetHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.target_auras, state.target_aura_count, spell_id);
}

fn targetHealthPct(bot: BotSnapshot, world: []const WorldSnapshot, guid: u64) ?u32 {
    const scan = world_query.scanForGuidOnMap(world, guid, bot.state.map_id) orelse return null;
    if (scan.hp_max == 0) return null;
    return @as(u32, @intCast((scan.hp * 100) / scan.hp_max));
}

fn castTargetInstant(spell_id: u32, target_guid: u64) Action {
    return .{ .cast_target_instant = .{ .spell_id = spell_id, .target_guid = target_guid } };
}

fn castTarget(spell_id: u32, target_guid: u64) Action {
    return .{ .cast_target = .{ .spell_id = spell_id, .target_guid = target_guid } };
}

pub fn planWithContext(ctx: *const CombatContext) Action {
    const g = ctx.primary_target orelse return .none;
    if (cooldown.spellReady(ctx.bot.state, data.spells.misdirection.spell_id)) {
        if (aggro.tankOwner(ctx.bots, ctx.world, g, ctx.bot.state.map_id)) |tank| {
            if (tank.state.guid != ctx.bot.state.guid) {
                return castTargetInstant(data.spells.misdirection.spell_id, tank.state.guid);
            }
        }
    }
    return plan(ctx.bot, ctx.world);
}

pub fn threatPlan(ctx: *const CombatContext) Action {
    if (!ctx.threat_high) return .none;
    if (ctx.bot.state.is_casting != 0 or ctx.bot.state.is_channeling != 0) return .none;
    if (!spellReady(ctx.bot.state, data.spells.feign_death.spell_id)) return .none;
    return .{ .cast_instant = data.spells.feign_death.spell_id };
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (bot.state.is_casting != 0 or bot.state.is_channeling != 0) return .none;

    const g = world_query.primaryHostileAttackGuid(bot.state, world) orelse return .none;

    const hp_pct = targetHealthPct(bot, world, g) orelse 100;

    if (hp_pct <= kill_shot_hp_pct and spellReady(bot.state, data.spells.kill_shot.spell_id)) {
        return castTargetInstant(data.spells.kill_shot.spell_id, g);
    }

    if (spellReady(bot.state, data.spells.explosive_shot.spell_id)) {
        return castTargetInstant(data.spells.explosive_shot.spell_id, g);
    }

    if (!targetHasAura(bot.state, data.spells.serpent_sting.spell_id)) {
        return castTargetInstant(data.spells.serpent_sting.spell_id, g);
    }

    if (!targetHasAura(bot.state, data.spells.black_arrow.spell_id) and
        spellReady(bot.state, data.spells.black_arrow.spell_id))
    {
        return castTargetInstant(data.spells.black_arrow.spell_id, g);
    }

    if (spellReady(bot.state, data.spells.aimed_shot.spell_id)) {
        return castTarget(data.spells.aimed_shot.spell_id, g);
    }

    return castTarget(data.spells.steady_shot.spell_id, g);
}

test "plan: Kill Shot at execute HP" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 19;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.kill_shot.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}

test "plan: Explosive Shot when target above execute HP" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.explosive_shot.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}

test "plan: Serpent Sting when debuff missing" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.explosive_shot.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 5000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.serpent_sting.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}

test "plan: skips Serpent Sting when debuff present" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.explosive_shot.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 5000 };

    bot.state.target_aura_count = 1;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.serpent_sting.spell_id, .remaining_ms = 15000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.black_arrow.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}

test "plan: Black Arrow when debuff missing and off cooldown" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.explosive_shot.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 5000 };

    bot.state.target_aura_count = 1;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.serpent_sting.spell_id, .remaining_ms = 15000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.black_arrow.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}

test "plan: skips Black Arrow when debuff present" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.explosive_shot.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 5000 };

    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.serpent_sting.spell_id, .remaining_ms = 15000 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.black_arrow.spell_id, .remaining_ms = 28000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.aimed_shot.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target.target_guid);
}

test "threatPlan: Feign Death when threat is high" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    const ctx = CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    var high_threat_ctx = ctx;
    high_threat_ctx.threat_high = true;

    const a = threatPlan(&high_threat_ctx);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.feign_death.spell_id, a.cast_instant);
}

test "threatPlan: no action when threat is not high" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    const ctx = CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    try std.testing.expect(threatPlan(&ctx) == .none);
}

test "plan: Aimed Shot when all others satisfied" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.explosive_shot.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 5000 };

    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.serpent_sting.spell_id, .remaining_ms = 15000 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.black_arrow.spell_id, .remaining_ms = 28000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.aimed_shot.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target.target_guid);
}

test "plan: Steady Shot filler when all others on cooldown" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    bot.state.cooldown_count = 2;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.explosive_shot.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 5000 };
    bot.state.cooldowns[1] = .{ .spell_id = data.spells.aimed_shot.spell_id, .category = 0, .remaining_ms = 8000, .duration_ms = 8000 };

    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.serpent_sting.spell_id, .remaining_ms = 15000 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.black_arrow.spell_id, .remaining_ms = 28000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.steady_shot.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target.target_guid);
}

test "plan: no target returns none" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    const world: []const WorldSnapshot = &.{};
    try std.testing.expectEqual(Action.none, plan(bot, world));
}

test "plan: returns none while casting" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.is_casting = 1;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    try std.testing.expectEqual(Action.none, plan(bot, &world));
}

test "plan: returns none while channeling" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.is_channeling = 1;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    try std.testing.expectEqual(Action.none, plan(bot, &world));
}

test "plan: Kill Shot on cooldown falls through to Explosive Shot" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.kill_shot.spell_id, .category = 0, .remaining_ms = 10000, .duration_ms = 10000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 10;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.explosive_shot.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}

test "plan: Black Arrow on cooldown and debuff missing falls through to Aimed Shot" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    bot.state.cooldown_count = 2;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.explosive_shot.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 5000 };
    bot.state.cooldowns[1] = .{ .spell_id = data.spells.black_arrow.spell_id, .category = 0, .remaining_ms = 20000, .duration_ms = 20000 };

    bot.state.target_aura_count = 1;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.serpent_sting.spell_id, .remaining_ms = 15000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.aimed_shot.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target.target_guid);
}
