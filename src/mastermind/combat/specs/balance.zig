//! Astrefeuille (G3). Roster : assets/setup.md

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

const moonkin_form_aura_id: u32 = 24858;
const solar_eclipse_aura_id: u32 = 48517;
const lunar_eclipse_aura_id: u32 = 48518;

pub const data = struct {
    pub const spells = struct {
        pub const moonkin_form = spells_db.get(24858);
        pub const wrath = spells_db.get(48461);
        pub const starfire = spells_db.get(48465);
        pub const insect_swarm = spells_db.get(27013);
        pub const faerie_fire = spells_db.get(770);
        pub const force_of_nature = spells_db.get(33831);
        pub const starfall = spells_db.get(48505);
        pub const gift_of_the_wild = spells_db.get(48470);
    };
    pub const resources = struct {};
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.gift_of_the_wild.spell_id };
}

pub fn burstGroundAction(bot: BotSnapshot, world: []const WorldSnapshot) ?Action {
    const g = world_query.primaryHostileAttackGuid(bot.state, world) orelse return null;
    const scan = world_query.scanForGuidOnMap(world, g, bot.state.map_id) orelse return null;
    return .{ .cast_ground = .{
        .spell_id = data.spells.force_of_nature.spell_id,
        .x = scan.x,
        .y = scan.y,
        .z = scan.z,
    } };
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

fn targetHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.target_auras, state.target_aura_count, spell_id);
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!selfHasAura(bot.state, moonkin_form_aura_id)) {
        return .{ .cast_instant = data.spells.moonkin_form.spell_id };
    }

    const g = world_query.primaryHostileAttackGuid(bot.state, world) orelse return .none;
    const target_lunar = selfHasAura(bot.state, lunar_eclipse_aura_id);
    const target_solar = selfHasAura(bot.state, solar_eclipse_aura_id);

    if (!targetHasAura(bot.state, data.spells.faerie_fire.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.faerie_fire.spell_id, .target_guid = g } };
    }

    if (cooldown.spellReady(bot.state, data.spells.starfall.spell_id)) {
        return .{ .cast_instant = data.spells.starfall.spell_id };
    }

    if (!targetHasAura(bot.state, data.spells.insect_swarm.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.insect_swarm.spell_id, .target_guid = g } };
    }

    if (target_lunar) {
        return .{ .cast_target = .{ .spell_id = data.spells.starfire.spell_id, .target_guid = g } };
    }

    if (target_solar) {
        return .{ .cast_target = .{ .spell_id = data.spells.wrath.spell_id, .target_guid = g } };
    }

    return .{ .cast_target = .{ .spell_id = data.spells.wrath.spell_id, .target_guid = g } };
}

test "plan: Faerie Fire before filler" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = moonkin_form_aura_id, .remaining_ms = 10_000 };

    var scan: proto.ScanEntry = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.faerie_fire.spell_id, a.cast_target_instant.spell_id);
}

test "plan: Lunar Eclipse uses Starfire" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = moonkin_form_aura_id, .remaining_ms = 10_000 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = lunar_eclipse_aura_id, .remaining_ms = 10_000 };
    bot.state.cooldown_count = 2;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.force_of_nature.spell_id, .category = 0, .remaining_ms = 10_000, .duration_ms = 10_000 };
    bot.state.cooldowns[1] = .{ .spell_id = data.spells.starfall.spell_id, .category = 0, .remaining_ms = 10_000, .duration_ms = 10_000 };
    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.faerie_fire.spell_id, .remaining_ms = 10_000 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.insect_swarm.spell_id, .remaining_ms = 10_000 };

    var scan: proto.ScanEntry = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.starfire.spell_id, a.cast_target.spell_id);
}
