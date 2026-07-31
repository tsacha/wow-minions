const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const spells_db = @import("../spells.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const data = struct {
    pub const spells = struct {
        pub const frost_presence = spells_db.get(48263);
        pub const dark_command = spells_db.get(56222);
        pub const death_grip = spells_db.get(49576);
        pub const icy_touch = spells_db.get(49909);
        pub const plague_strike = spells_db.get(49921);
        pub const death_strike = spells_db.get(49924);
        pub const blood_strike = spells_db.get(49930);
        pub const death_coil = spells_db.get(49895);
        pub const frost_fever = spells_db.get(55095);
        pub const blood_plague = spells_db.get(55078);
        pub const pestilence = spells_db.get(50842);
    };

    pub const resources = struct {
        pub const rune_type_blood: u32 = 1;
        pub const rune_type_frost: u32 = 2;
        pub const rune_type_unholy: u32 = 3;
        pub const rune_type_death: u32 = 4;
    };
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.frost_presence.spell_id };
}

fn runeReady(state: proto.State, rune_index: usize) bool {
    const regen_ms = state.rune_regen_ms[rune_index];
    return regen_ms == 0 or regen_ms <= state.game_time_ms;
}

fn targetHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(state.target_auras[0..], state.target_aura_count, spell_id);
}

fn targetAuraRemaining(state: proto.State, spell_id: u32) u32 {
    for (state.target_auras[0..state.target_aura_count]) |aura| {
        if (aura.spell_id == spell_id) return aura.remaining_ms;
    }
    return 0;
}

fn deathGripOnCooldown(state: proto.State) bool {
    for (state.cooldowns[0..state.cooldown_count]) |cd| {
        if (cd.spell_id == data.spells.death_grip.spell_id and cd.remaining_ms > 0) return true;
    }
    return false;
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

const disease_refresh_threshold_ms: u32 = 6_000;

fn hostileTarget(bot: BotSnapshot, world: []const WorldSnapshot) ?proto.ScanEntry {
    const guid = bot.state.target_guid;
    if (guid == 0) return null;

    const scan = (if (bot.state.map_id == 0)
        world_query.scanForGuid(world, guid)
    else
        world_query.scanForGuidOnMap(world, guid, bot.state.map_id)) orelse return null;
    if (!world_query.isHostileAttackTarget(scan, bot.state.target_unit_reaction)) return null;
    return scan;
}

fn hasReadyRuneOfType(state: proto.State, rune_type: u32) bool {
    for (state.rune_types, 0..) |slot_type, i| {
        if (!runeReady(state, i)) continue;
        if (slot_type == rune_type or slot_type == data.resources.rune_type_death) return true;
    }
    return false;
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!selfHasAura(bot.state, data.spells.frost_presence.spell_id))
    {
        return .{ .cast_instant = data.spells.frost_presence.spell_id };
    }

    const target = hostileTarget(bot, world) orelse return .none;
    const g = target.guid;

    const has_frost_rune = hasReadyRuneOfType(bot.state, data.resources.rune_type_frost);
    const has_unholy_rune = hasReadyRuneOfType(bot.state, data.resources.rune_type_unholy);
    const has_blood_rune = hasReadyRuneOfType(bot.state, data.resources.rune_type_blood);

    const has_frost_fever = targetHasAura(bot.state, data.spells.frost_fever.spell_id);
    const has_blood_plague = targetHasAura(bot.state, data.spells.blood_plague.spell_id);

    if (!has_frost_fever) {
        if (has_frost_rune) {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.icy_touch.spell_id, .target_guid = g } };
        }
    }

    if (!has_blood_plague) {
        if (has_unholy_rune) {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.plague_strike.spell_id, .target_guid = g } };
        }
    }

    // Dark Command as backup taunt when Death Grip is on cooldown and we cannot apply diseases
    // because both disease runes are spent. Generates threat and recovers aggro during rune downtime.
    if (!has_frost_fever and !has_blood_plague and !has_frost_rune and !has_unholy_rune and deathGripOnCooldown(bot.state)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.dark_command.spell_id, .target_guid = g } };
    }

    // Refresh both diseases via Pestilence (Glyph of Disease) when either is about to expire.
    if (has_frost_fever and has_blood_plague and has_blood_rune) {
        const ff_remaining = targetAuraRemaining(bot.state, data.spells.frost_fever.spell_id);
        const bp_remaining = targetAuraRemaining(bot.state, data.spells.blood_plague.spell_id);
        if (ff_remaining <= disease_refresh_threshold_ms or bp_remaining <= disease_refresh_threshold_ms) {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.pestilence.spell_id, .target_guid = g } };
        }
    }

    if (bot.state.hp_max != 0 and bot.state.hp * 100 <= bot.state.hp_max * 80 and has_frost_rune and has_unholy_rune) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.death_strike.spell_id, .target_guid = g } };
    }

    if (has_blood_rune) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.blood_strike.spell_id, .target_guid = g } };
    }

    if (has_frost_rune and has_unholy_rune) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.death_strike.spell_id, .target_guid = g } };
    }

    if (bot.state.active_power >= 40) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.death_coil.spell_id, .target_guid = g } };
    }

    return .none;
}

test "plan: opens with disease rotation instead of death grip" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.frost_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.game_time_ms = 1000;
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.x = 15.0; // target is at range, not in melee

    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.icy_touch.spell_id, a.cast_target_instant.spell_id);
}

test "plan: does not use death grip even when target is out of range" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.frost_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.game_time_ms = 1000;
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.x = 45.0;

    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.icy_touch.spell_id, a.cast_target_instant.spell_id);
}

test "plan: opens with diseases when death grip on cooldown" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.frost_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.game_time_ms = 1000;
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.death_grip.spell_id, .category = 0, .remaining_ms = 25000, .duration_ms = 35000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.icy_touch.spell_id, a.cast_target_instant.spell_id);
}

test "plan: no action on friendly target" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.frost_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 5;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.game_time_ms = 1000;
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    try std.testing.expectEqual(Action.none, plan(bot, &world));
}

test "plan: falls through to blood plague when frost rune is not ready" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.frost_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.game_time_ms = 1000;
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 5000, 0, 5000, 5000, 5000, 5000 };
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.death_grip.spell_id, .category = 0, .remaining_ms = 25000, .duration_ms = 35000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.plague_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: uses dark command when disease runes are spent and death grip is on cooldown" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.frost_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.game_time_ms = 1000;
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 5000, 5000, 0, 5000, 5000, 5000 };
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.death_grip.spell_id, .category = 0, .remaining_ms = 25000, .duration_ms = 35000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.dark_command.spell_id, a.cast_target_instant.spell_id);
}

test "plan: falls through to blood strike when diseases are up and no disease runes are ready" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.frost_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.game_time_ms = 1000;
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 5000, 5000, 0, 5000, 5000, 5000 };

    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .spell_id = data.spells.frost_fever.spell_id, .caster_guid = 1, .remaining_ms = 10_000 };
    bot.state.target_auras[1] = .{ .spell_id = data.spells.blood_plague.spell_id, .caster_guid = 1, .remaining_ms = 10_000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.blood_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: uses pestilence to refresh diseases before spending blood rune on blood strike" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.frost_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.game_time_ms = 1000;
    bot.state.active_power = 80;
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.death_grip.spell_id, .category = 0, .remaining_ms = 25000, .duration_ms = 35000 };

    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .spell_id = data.spells.frost_fever.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_auras[1] = .{ .spell_id = data.spells.blood_plague.spell_id, .caster_guid = 1, .remaining_ms = 1000 };

    bot.state.rune_types = .{ 1, 2, 3, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 0, 0, 5000, 5000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.pestilence.spell_id, a.cast_target_instant.spell_id);
}

test "plan: spends blood rune on blood strike when diseases are healthy" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.frost_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.game_time_ms = 1000;
    bot.state.active_power = 80;
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.death_grip.spell_id, .category = 0, .remaining_ms = 25000, .duration_ms = 35000 };

    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .spell_id = data.spells.frost_fever.spell_id, .caster_guid = 1, .remaining_ms = 10_000 };
    bot.state.target_auras[1] = .{ .spell_id = data.spells.blood_plague.spell_id, .caster_guid = 1, .remaining_ms = 10_000 };

    bot.state.rune_types = .{ 1, 2, 3, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 0, 0, 5000, 5000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.blood_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: uses death strike when no blood rune is ready" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.frost_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.game_time_ms = 1000;
    bot.state.rune_types = .{ 1, 2, 3, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 5000, 0, 0, 5000, 5000, 5000 };
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.death_grip.spell_id, .category = 0, .remaining_ms = 25000, .duration_ms = 35000 };

    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .spell_id = data.spells.frost_fever.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_auras[1] = .{ .spell_id = data.spells.blood_plague.spell_id, .caster_guid = 1, .remaining_ms = 1000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.death_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: frost presence is cast when missing" {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.game_time_ms = 1000;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.frost_presence.spell_id, a.cast_instant);
}
