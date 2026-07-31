//! Pesterouage (G2). Roster : assets/setup.md

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const spells_db = @import("../spells.zig");
const Action = @import("../action.zig").Action;
const cooldown = @import("../cooldown.zig");
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const data = struct {
    pub const spells = struct {
        pub const death_and_decay = spells_db.get(49938);
        pub const scourge_strike = spells_db.get(55271);
        pub const icy_touch = spells_db.get(49909);
        pub const plague_strike = spells_db.get(49921);
        pub const death_coil = spells_db.get(49895);
        pub const blood_strike = spells_db.get(49930);
        pub const blood_boil = spells_db.get(49941);
        pub const pestilence = spells_db.get(50842);
        pub const horn_of_winter = spells_db.get(57623);
        pub const blood_presence = spells_db.get(48266);
        pub const summon_gargoyle = spells_db.get(49206);
        pub const army_of_the_dead = spells_db.get(42650);
        pub const blood_tap = spells_db.get(45529);
        pub const frost_fever = spells_db.get(55095);
        pub const blood_plague = spells_db.get(55078);
    };
    pub const resources = struct {
        pub const rune_type_blood: u32 = 1;
        pub const rune_type_frost: u32 = 2;
        pub const rune_type_unholy: u32 = 3;
        pub const rune_type_death: u32 = 4;
    };
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.horn_of_winter.spell_id };
}

const death_rune_type: u32 = 4;
const death_coil_min_power: u32 = 40;

fn targetHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(state.target_auras[0..], state.target_aura_count, spell_id);
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

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

fn runeReady(state: proto.State, rune_index: usize) bool {
    const regen_ms = state.rune_regen_ms[rune_index];
    return regen_ms == 0 or regen_ms <= state.game_time_ms;
}

fn hasReadyRuneOfType(state: proto.State, rune_type: u32) bool {
    for (state.rune_types, 0..) |slot_type, i| {
        if (!runeReady(state, i)) continue;
        if (slot_type == rune_type or slot_type == death_rune_type) return true;
    }
    return false;
}

fn spellReady(state: proto.State, spell_id: u32) bool {
    return cooldown.spellReady(state, spell_id);
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!selfHasAura(bot.state, data.spells.blood_presence.spell_id)) {
        return .{ .cast_instant = data.spells.blood_presence.spell_id };
    }

    if (spellReady(bot.state, data.spells.horn_of_winter.spell_id) and
        !proto.hasUnitFlag(bot.state.unit_flags, .in_combat))
    {
        return .{ .cast_instant = data.spells.horn_of_winter.spell_id };
    }

    const target = hostileTarget(bot, world) orelse return .none;
    const g = target.guid;

    const frost_ready = hasReadyRuneOfType(bot.state, data.resources.rune_type_frost);
    const unholy_ready = hasReadyRuneOfType(bot.state, data.resources.rune_type_unholy);
    const blood_ready = hasReadyRuneOfType(bot.state, data.resources.rune_type_blood);
    if (!targetHasAura(bot.state, data.spells.frost_fever.spell_id) and frost_ready) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.icy_touch.spell_id, .target_guid = g } };
    }

    if (!targetHasAura(bot.state, data.spells.blood_plague.spell_id) and unholy_ready) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.plague_strike.spell_id, .target_guid = g } };
    }

    if ((!targetHasAura(bot.state, data.spells.frost_fever.spell_id) or
        !targetHasAura(bot.state, data.spells.blood_plague.spell_id)) and
        frost_ready)
    {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.icy_touch.spell_id, .target_guid = g } };
    }

    if (spellReady(bot.state, data.spells.scourge_strike.spell_id) and
        frost_ready and unholy_ready)
    {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.scourge_strike.spell_id, .target_guid = g } };
    }

    if (blood_ready and spellReady(bot.state, data.spells.blood_strike.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.blood_strike.spell_id, .target_guid = g } };
    }

    if (blood_ready and spellReady(bot.state, data.spells.blood_boil.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.blood_boil.spell_id, .target_guid = g } };
    }

    if (spellReady(bot.state, data.spells.pestilence.spell_id) and
        targetHasAura(bot.state, data.spells.frost_fever.spell_id) and
        targetHasAura(bot.state, data.spells.blood_plague.spell_id))
    {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.pestilence.spell_id, .target_guid = g } };
    }

    if (bot.state.active_power >= death_coil_min_power) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.death_coil.spell_id, .target_guid = g } };
    }

    if (spellReady(bot.state, data.spells.horn_of_winter.spell_id)) {
        return .{ .cast_instant = data.spells.horn_of_winter.spell_id };
    }
    return .none;
}

pub fn burstAction(step: usize) ?Action {
    return switch (step) {
        0 => .{ .cast_instant = data.spells.summon_gargoyle.spell_id },
        1 => .{ .cast = data.spells.army_of_the_dead.spell_id },
        2 => .{ .cast_instant = data.spells.blood_tap.spell_id },
        else => null,
    };
}

fn makeScan(guid: u64, hp: u32, map_id: u32) WorldSnapshot {
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = guid;
    scan.hp = hp;
    return .{ .scan = scan, .map_id = map_id, .last_seen_ts_ns = 0 };
}

fn makeBot(guid: u64, target_guid: u64, map_id: u32) BotSnapshot {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = guid;
    bot.state.map_id = map_id;
    bot.state.target_guid = target_guid;
    bot.state.target_unit_reaction = 2;
    bot.state.game_time_ms = 1000;
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 0, 0, 5000, 5000 };
    return bot;
}

test "plan: opens with icy touch when diseases are missing" {
    const g: u64 = 0xabc;
    var bot = makeBot(0x100, g, 1);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.blood_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.icy_touch.spell_id, a.cast_target_instant.spell_id);
}

test "plan: uses plague strike when blood plague is missing but frost fever is up" {
    const g: u64 = 0xabc;
    var bot = makeBot(0x100, g, 1);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.blood_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_aura_count = 1;
    bot.state.target_auras[0] = .{ .spell_id = data.spells.frost_fever.spell_id, .caster_guid = 1, .remaining_ms = 8000 };
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.plague_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: uses scourge strike before death and decay when both are available" {
    const g: u64 = 0xabc;
    var bot = makeBot(0x100, g, 1);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.blood_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .spell_id = data.spells.frost_fever.spell_id, .caster_guid = 1, .remaining_ms = 8000 };
    bot.state.target_auras[1] = .{ .spell_id = data.spells.blood_plague.spell_id, .caster_guid = 1, .remaining_ms = 8000 };
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.scourge_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: uses blood strike when scourge strike is unavailable" {
    const g: u64 = 0xabc;
    var bot = makeBot(0x100, g, 1);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.blood_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .spell_id = data.spells.frost_fever.spell_id, .caster_guid = 1, .remaining_ms = 8000 };
    bot.state.target_auras[1] = .{ .spell_id = data.spells.blood_plague.spell_id, .caster_guid = 1, .remaining_ms = 8000 };
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.scourge_strike.spell_id, .category = 0, .remaining_ms = 1000, .duration_ms = 0 };
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.blood_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: uses scourge strike when diseases are active and dnd is unavailable" {
    const g: u64 = 0xabc;
    var bot = makeBot(0x100, g, 1);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.blood_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .spell_id = data.spells.frost_fever.spell_id, .caster_guid = 1, .remaining_ms = 8000 };
    bot.state.target_auras[1] = .{ .spell_id = data.spells.blood_plague.spell_id, .caster_guid = 1, .remaining_ms = 8000 };
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.death_and_decay.spell_id, .category = 0, .remaining_ms = 1000, .duration_ms = 0 };
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.scourge_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: dumps death coil when no rune spender is ready" {
    const g: u64 = 0xabc;
    var bot = makeBot(0x100, g, 1);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.blood_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .spell_id = data.spells.frost_fever.spell_id, .caster_guid = 1, .remaining_ms = 8000 };
    bot.state.target_auras[1] = .{ .spell_id = data.spells.blood_plague.spell_id, .caster_guid = 1, .remaining_ms = 8000 };
    bot.state.rune_regen_ms = .{ 5000, 5000, 5000, 5000, 5000, 5000 };
    bot.state.active_power = 45;
    bot.state.cooldown_count = 3;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.death_and_decay.spell_id, .category = 0, .remaining_ms = 1000, .duration_ms = 0 };
    bot.state.cooldowns[1] = .{ .spell_id = data.spells.scourge_strike.spell_id, .category = 0, .remaining_ms = 1000, .duration_ms = 0 };
    bot.state.cooldowns[2] = .{ .spell_id = data.spells.pestilence.spell_id, .category = 0, .remaining_ms = 1000, .duration_ms = 0 };
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.death_coil.spell_id, a.cast_target_instant.spell_id);
}

test "plan: no action on friendly target" {
    var bot = makeBot(0x100, 0xabc, 1);
    bot.state.target_unit_reaction = 5;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.blood_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};
    try std.testing.expectEqual(Action.none, plan(bot, &world));
}

test "plan: horn of winter fills empty global" {
    const g: u64 = 0xabc;
    var bot = makeBot(0x100, g, 1);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.blood_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .spell_id = data.spells.frost_fever.spell_id, .caster_guid = 1, .remaining_ms = 8000 };
    bot.state.target_auras[1] = .{ .spell_id = data.spells.blood_plague.spell_id, .caster_guid = 1, .remaining_ms = 8000 };
    bot.state.rune_regen_ms = .{ 5000, 5000, 5000, 5000, 5000, 5000 };
    bot.state.active_power = 20;
    bot.state.cooldown_count = 3;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.death_and_decay.spell_id, .category = 0, .remaining_ms = 1000, .duration_ms = 0 };
    bot.state.cooldowns[1] = .{ .spell_id = data.spells.scourge_strike.spell_id, .category = 0, .remaining_ms = 1000, .duration_ms = 0 };
    bot.state.cooldowns[2] = .{ .spell_id = data.spells.pestilence.spell_id, .category = 0, .remaining_ms = 1000, .duration_ms = 0 };
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.horn_of_winter.spell_id, a.cast_instant);
}

test "plan: horn of winter can be cast out of combat without a target" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.game_time_ms = 1000;
    bot.state.unit_flags = 0;
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = data.spells.blood_presence.spell_id, .caster_guid = 1, .remaining_ms = 1000 };
    const world: []const WorldSnapshot = &.{};

    const a = plan(bot, world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.horn_of_winter.spell_id, a.cast_instant);
}

test "burstAction: unholy burst sequence" {
    const a0 = burstAction(0) orelse return error.TestUnexpectedResult;
    const a1 = burstAction(1) orelse return error.TestUnexpectedResult;
    const a2 = burstAction(2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(a0 == .cast_instant);
    try std.testing.expectEqual(data.spells.summon_gargoyle.spell_id, a0.cast_instant);
    try std.testing.expect(a1 == .cast);
    try std.testing.expectEqual(data.spells.army_of_the_dead.spell_id, a1.cast);
    try std.testing.expect(a2 == .cast_instant);
    try std.testing.expectEqual(data.spells.blood_tap.spell_id, a2.cast_instant);
    try std.testing.expect(burstAction(3) == null);
}
