const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const spells_db = @import("../spells.zig");
const spell_range = @import("../spell_range.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const data = struct {
    pub const spells = struct {
        pub const righteous_fury = spells_db.get(25780);
        pub const greater_blessing_of_sanctuary = spells_db.get(25899);
        pub const greater_blessing_of_kings = spells_db.get(25898);
        pub const seal_of_vengeance = spells_db.get(31801);
        pub const hand_of_reckoning = spells_db.get(62124);
        pub const avengers_shield = spells_db.get(48827);
        pub const shield_of_righteousness = spells_db.get(61411);
        pub const hammer_of_the_righteous = spells_db.get(53595);
        pub const judgement_of_wisdom = spells_db.get(53408);
        pub const hammer_of_wrath = spells_db.get(48806);
        pub const consecration = spells_db.get(48819);
        pub const divine_plea = spells_db.get(54428);
        pub const holy_shield = spells_db.get(48952);
    };
    pub const resources = struct {};
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.righteous_fury.spell_id };
}

const holy_shield_refresh_ms: u32 = 2000;
const execute_hp_pct: u32 = 20;
const mana_power_type: u32 = 0;
const divine_plea_mana_pct: u32 = 75;

fn spellReady(state: proto.State, spell_id: u32) bool {
    return !world_query.hasCooldown(&state.cooldowns, state.cooldown_count, spell_id);
}

fn auraRemainingMs(auras: []const proto.AuraEntry, count: u32, spell_id: u32) ?u32 {
    const n = @min(count, auras.len);
    for (auras[0..n]) |a| {
        if (a.spell_id == spell_id) return a.remaining_ms;
    }
    return null;
}

fn targetHealthPct(bot: BotSnapshot, world: []const WorldSnapshot, guid: u64) ?u32 {
    const scan = world_query.scanForGuidOnMap(world, guid, bot.state.map_id) orelse return null;
    if (scan.hp_max == 0) return null;
    return @as(u32, @intCast((scan.hp * 100) / scan.hp_max));
}

fn manaPct(state: proto.State) ?u32 {
    if (state.active_power_type != mana_power_type) return null;
    if (state.active_power_max == 0) return null;
    return @as(u32, @intCast((state.active_power * 100) / state.active_power_max));
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    const righteous_fury_up = world_query.hasAura(bot.state.player_auras[0..], bot.state.player_aura_count, data.spells.righteous_fury.spell_id);
    if (!righteous_fury_up) {
        return .{ .cast_instant = data.spells.righteous_fury.spell_id };
    }

    const sanctuary_up = world_query.hasAura(bot.state.player_auras[0..], bot.state.player_aura_count, data.spells.greater_blessing_of_sanctuary.spell_id);
    if (!sanctuary_up) {
        return .{ .cast_instant = data.spells.greater_blessing_of_sanctuary.spell_id };
    }

    const seal_up = world_query.hasAura(bot.state.player_auras[0..], bot.state.player_aura_count, data.spells.seal_of_vengeance.spell_id);
    if (!seal_up) {
        return .{ .cast_instant = data.spells.seal_of_vengeance.spell_id };
    }

    const divine_plea_active = world_query.hasAura(bot.state.player_auras[0..], bot.state.player_aura_count, data.spells.divine_plea.spell_id);
    const current_mana_pct = manaPct(bot.state);
    if (!divine_plea_active and spellReady(bot.state, data.spells.divine_plea.spell_id) and
        current_mana_pct != null and current_mana_pct.? < divine_plea_mana_pct)
    {
        return .{ .cast_instant = data.spells.divine_plea.spell_id };
    }

    const g = world_query.primaryHostileAttackGuid(bot.state, world) orelse return .none;
    const holy_shield_rem_ms = auraRemainingMs(bot.state.player_auras[0..], bot.state.player_aura_count, data.spells.holy_shield.spell_id);
    const execute = targetHealthPct(bot, world, g) orelse 100;

    if (holy_shield_rem_ms == null or holy_shield_rem_ms.? <= holy_shield_refresh_ms) {
        return .{ .cast_instant = data.spells.holy_shield.spell_id };
    }

    if (spellReady(bot.state, data.spells.avengers_shield.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.avengers_shield.spell_id, .target_guid = g } };
    }

    if (execute <= execute_hp_pct and spellReady(bot.state, data.spells.hammer_of_wrath.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.hammer_of_wrath.spell_id, .target_guid = g } };
    }

    if (spellReady(bot.state, data.spells.shield_of_righteousness.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.shield_of_righteousness.spell_id, .target_guid = g } };
    }

    if (spellReady(bot.state, data.spells.hammer_of_the_righteous.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.hammer_of_the_righteous.spell_id, .target_guid = g } };
    }

    if (spellReady(bot.state, data.spells.consecration.spell_id)) {
        return .{ .cast_instant = data.spells.consecration.spell_id };
    }

    if (spellReady(bot.state, data.spells.judgement_of_wisdom.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.judgement_of_wisdom.spell_id, .target_guid = g } };
    }

    return .none;
}

fn baseBot() BotSnapshot {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 4;
    bot.state.player_auras[0] = .{ .caster_guid = 1, .spell_id = data.spells.righteous_fury.spell_id, .remaining_ms = 9999999 };
    bot.state.player_auras[1] = .{ .caster_guid = 1, .spell_id = data.spells.greater_blessing_of_sanctuary.spell_id, .remaining_ms = 9999999 };
    bot.state.player_auras[2] = .{ .caster_guid = 1, .spell_id = data.spells.seal_of_vengeance.spell_id, .remaining_ms = 9999999 };
    bot.state.player_auras[3] = .{ .caster_guid = 1, .spell_id = data.spells.divine_plea.spell_id, .remaining_ms = 10000 };
    bot.state.cooldown_count = 2;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.divine_plea.spell_id, .category = 0, .remaining_ms = 45000, .duration_ms = 60000 };
    bot.state.cooldowns[1] = .{ .spell_id = data.spells.avengers_shield.spell_id, .category = 0, .remaining_ms = 25000, .duration_ms = 25000 };
    return bot;
}

test "out_of_combat tag: greater blessing and seal tagged, divine plea not" {
    try std.testing.expect(spell_range.hasOutOfCombatTag(data.spells, data.spells.greater_blessing_of_sanctuary.spell_id));
    try std.testing.expect(spell_range.hasOutOfCombatTag(data.spells, data.spells.seal_of_vengeance.spell_id));
    try std.testing.expect(!spell_range.hasOutOfCombatTag(data.spells, data.spells.divine_plea.spell_id));
    try std.testing.expect(!spell_range.hasOutOfCombatTag(data.spells, 99999));
}

test "plan: casts righteous fury when missing even without target" {
    const bot = std.mem.zeroes(BotSnapshot);
    const a = plan(bot, &.{});
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.righteous_fury.spell_id, a.cast_instant);
}

test "plan: casts righteous fury before other buffs" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{
        .caster_guid = 1,
        .spell_id = data.spells.greater_blessing_of_sanctuary.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.player_auras[1] = .{
        .caster_guid = 1,
        .spell_id = data.spells.seal_of_vengeance.spell_id,
        .remaining_ms = 9999999,
    };
    const a = plan(bot, &.{});
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.righteous_fury.spell_id, a.cast_instant);
}

test "plan: casts divine plea when off cooldown and not active" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 3;
    bot.state.player_auras[0] = .{
        .caster_guid = 1,
        .spell_id = data.spells.righteous_fury.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.player_auras[1] = .{
        .caster_guid = 1,
        .spell_id = data.spells.greater_blessing_of_sanctuary.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.player_auras[2] = .{
        .caster_guid = 1,
        .spell_id = data.spells.seal_of_vengeance.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.active_power_type = 0;
    bot.state.active_power = 74;
    bot.state.active_power_max = 100;
    const a = plan(bot, &.{});
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.divine_plea.spell_id, a.cast_instant);
}

test "plan: skips divine plea at 75 percent mana" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 3;
    bot.state.player_auras[0] = .{
        .caster_guid = 1,
        .spell_id = data.spells.righteous_fury.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.player_auras[1] = .{
        .caster_guid = 1,
        .spell_id = data.spells.greater_blessing_of_sanctuary.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.player_auras[2] = .{
        .caster_guid = 1,
        .spell_id = data.spells.seal_of_vengeance.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.active_power_type = 0;
    bot.state.active_power = 75;
    bot.state.active_power_max = 100;
    const a = plan(bot, &.{});
    try std.testing.expect(a == .none);
}

test "plan: skips divine plea when already active" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 4;
    bot.state.player_auras[0] = .{
        .caster_guid = 1,
        .spell_id = data.spells.righteous_fury.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.player_auras[1] = .{
        .caster_guid = 1,
        .spell_id = data.spells.greater_blessing_of_sanctuary.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.player_auras[2] = .{
        .caster_guid = 1,
        .spell_id = data.spells.seal_of_vengeance.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.player_auras[3] = .{
        .caster_guid = 1,
        .spell_id = data.spells.divine_plea.spell_id,
        .remaining_ms = 10000,
    };
    const a = plan(bot, &.{});
    try std.testing.expect(a == .none);
}

test "plan: skips divine plea when on cooldown" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 3;
    bot.state.player_auras[0] = .{
        .caster_guid = 1,
        .spell_id = data.spells.righteous_fury.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.player_auras[1] = .{
        .caster_guid = 1,
        .spell_id = data.spells.greater_blessing_of_sanctuary.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.player_auras[2] = .{
        .caster_guid = 1,
        .spell_id = data.spells.seal_of_vengeance.spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{
        .spell_id = data.spells.divine_plea.spell_id,
        .category = 0,
        .remaining_ms = 30000,
        .duration_ms = 60000,
    };
    const a = plan(bot, &.{});
    try std.testing.expect(a == .none);
}

test "plan: casts avengers shield when holy shield is up and AS off cooldown" {
    var bot = baseBot();
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.game_time_ms = 1000;
    // Holy shield healthy — skip refresh.
    bot.state.player_auras[bot.state.player_aura_count] = .{
        .caster_guid = 1,
        .spell_id = data.spells.holy_shield.spell_id,
        .remaining_ms = 6000,
    };
    bot.state.player_aura_count += 1;
    // Remove avengers_shield cooldown so it fires.
    bot.state.cooldown_count = 1; // keep divine_plea only
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.divine_plea.spell_id, .category = 0, .remaining_ms = 45000, .duration_ms = 60000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.hp_max = 1000;
    scan.x = 15.0; // target is at range, not in melee

    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.avengers_shield.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}

test "plan: emits avengers shield even when target is out of range" {
    var bot = baseBot();
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.game_time_ms = 1000;
    bot.state.player_auras[bot.state.player_aura_count] = .{
        .caster_guid = 1,
        .spell_id = data.spells.holy_shield.spell_id,
        .remaining_ms = 6000,
    };
    bot.state.player_aura_count += 1;
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.divine_plea.spell_id, .category = 0, .remaining_ms = 45000, .duration_ms = 60000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.hp_max = 1000;
    scan.x = 45.0;

    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.avengers_shield.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}

test "plan: opens by refreshing holy shield first" {
    var bot = baseBot();
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.game_time_ms = 1000;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.hp_max = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.holy_shield.spell_id, a.cast_instant);
}

test "plan: skips holy shield refresh when buffer is healthy" {
    var bot = baseBot();
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.game_time_ms = 1000;
    bot.state.player_auras[bot.state.player_aura_count] = .{
        .caster_guid = 1,
        .spell_id = data.spells.holy_shield.spell_id,
        .remaining_ms = 6000,
    };
    bot.state.player_aura_count += 1;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.hp_max = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.shield_of_righteousness.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(0xabc, a.cast_target_instant.target_guid);
}

test "plan: uses shield of righteousness before filler" {
    var bot = baseBot();
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.game_time_ms = 1000;
    bot.state.player_auras[bot.state.player_aura_count] = .{
        .caster_guid = 1,
        .spell_id = data.spells.holy_shield.spell_id,
        .remaining_ms = 6000,
    };
    bot.state.player_auras[bot.state.player_aura_count + 1] = .{
        .caster_guid = 1,
        .spell_id = data.spells.seal_of_vengeance.spell_id,
        .remaining_ms = 10000,
    };
    bot.state.player_aura_count += 2;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.hp_max = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.shield_of_righteousness.spell_id, a.cast_target_instant.spell_id);
}

test "plan: uses hammer of wrath at execute" {
    var bot = baseBot();
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.game_time_ms = 1000;
    bot.state.player_auras[bot.state.player_aura_count] = .{
        .caster_guid = 1,
        .spell_id = data.spells.holy_shield.spell_id,
        .remaining_ms = 6000,
    };
    bot.state.player_auras[bot.state.player_aura_count + 1] = .{
        .caster_guid = 1,
        .spell_id = data.spells.seal_of_vengeance.spell_id,
        .remaining_ms = 10000,
    };
    bot.state.player_aura_count += 2;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.hammer_of_wrath.spell_id, a.cast_target_instant.spell_id);
}
