//! Cristorage (G3). Roster : assets/setup.md

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const spells_db = @import("../spells.zig");
const cooldown = @import("../cooldown.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const data = struct {
    pub const spells = struct {
        pub const lightning_bolt = spells_db.get(49238);
        pub const lava_burst = spells_db.get(60043);
        pub const flame_shock = spells_db.get(49233);
        pub const bloodlust = spells_db.get(2825);
        pub const elemental_mastery = spells_db.get(16166);
        pub const water_shield = spells_db.get(57960);
        pub const searing_totem = spells_db.get(58704);
        pub const frost_shock = spells_db.get(49236);
        pub const thunderstorm = spells_db.get(59159);
        pub const fire_elemental_totem = spells_db.get(2894);
    };
    pub const resources = struct {
        pub const water_shield_aura: u32 = 57960;
    };
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.water_shield.spell_id };
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

fn targetHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.target_auras, state.target_aura_count, spell_id);
}

fn fireTotemEmpty(state: proto.State) bool {
    return proto.totemSlot(&state.totems, .fire).remaining_ms == 0;
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!selfHasAura(bot.state, data.resources.water_shield_aura)) {
        return .{ .cast_instant = data.spells.water_shield.spell_id };
    }

    const g = world_query.primaryHostileAttackGuid(bot.state, world) orelse return .none;

    if (fireTotemEmpty(bot.state)) {
        return .{ .cast_instant = data.spells.searing_totem.spell_id };
    }

    if (!targetHasAura(bot.state, data.spells.flame_shock.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.flame_shock.spell_id, .target_guid = g } };
    }

    return if (cooldown.spellReady(bot.state, data.spells.lava_burst.spell_id))
        .{ .cast_target = .{ .spell_id = data.spells.lava_burst.spell_id, .target_guid = g } }
    else if (cooldown.spellReady(bot.state, data.spells.thunderstorm.spell_id)) .{ .cast_instant = data.spells.thunderstorm.spell_id } else if (cooldown.spellReady(bot.state, data.spells.frost_shock.spell_id)) .{ .cast_target_instant = .{ .spell_id = data.spells.frost_shock.spell_id, .target_guid = g } } else .{ .cast_target = .{ .spell_id = data.spells.lightning_bolt.spell_id, .target_guid = g } };
}

pub fn burstAction(step: usize) ?Action {
    return switch (step) {
        0 => .{ .cast_instant = data.spells.bloodlust.spell_id },
        1 => .{ .cast_instant = data.spells.elemental_mastery.spell_id },
        2 => .{ .cast_instant = data.spells.fire_elemental_totem.spell_id },
        else => null,
    };
}

test "plan: casts Water Shield when missing" {
    const bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    const a = plan(bot, &.{});
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.water_shield.spell_id, a.cast_instant);
}

test "plan: Flame Shock then Lava Burst" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.resources.water_shield_aura, .remaining_ms = 0 };
    bot.state.totems[@intFromEnum(proto.TotemElement.fire)].remaining_ms = 30_000;

    var scan: proto.ScanEntry = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.flame_shock.spell_id, a.cast_target_instant.spell_id);
}

test "burstAction: bloodlust then elemental mastery then fire elemental totem" {
    const a0 = burstAction(0) orelse return error.TestUnexpectedResult;
    const a1 = burstAction(1) orelse return error.TestUnexpectedResult;
    const a2 = burstAction(2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(data.spells.bloodlust.spell_id, a0.cast_instant);
    try std.testing.expectEqual(data.spells.elemental_mastery.spell_id, a1.cast_instant);
    try std.testing.expectEqual(data.spells.fire_elemental_totem.spell_id, a2.cast_instant);
    try std.testing.expect(burstAction(3) == null);
}

test "plan: fire totem slot empty casts Searing Totem" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.resources.water_shield_aura, .remaining_ms = 0 };

    var scan: proto.ScanEntry = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.searing_totem.spell_id, a.cast_instant);
}
