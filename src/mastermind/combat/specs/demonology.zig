//! Bricosort (G3). Roster : assets/setup.md

const registry_mod = @import("registry");
const proto = @import("protocol");
const world_memory_mod = @import("../../world/memory.zig");
const context = @import("../context.zig");
const spells_db = @import("../spells.zig");
const cooldown = @import("../cooldown.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;
const CombatContext = context.CombatContext;

const melee_meta_distance_yards: f32 = 5.0;
const decimation_hp_pct: u32 = 35;

pub const data = struct {
    pub const spells = struct {
        pub const fel_armor = spells_db.get(47893);
        pub const summon_felguard = spells_db.get(30146);
        pub const life_tap_rank1 = spells_db.get(1454);
        pub const life_tap = spells_db.get(57946);
        pub const shadow_bolt = spells_db.get(47809);
        pub const corruption = spells_db.get(47813);
        pub const immolate = spells_db.get(47811);
        pub const curse_of_doom = spells_db.get(30910);
        pub const incinerate = spells_db.get(32231);
        pub const soul_fire = spells_db.get(6353);
        pub const metamorphosis = spells_db.get(47241);
        pub const demonic_empowerment = spells_db.get(47193);
        pub const soulshatter = spells_db.get(29858);
    };

    pub const resources = struct {
        pub const life_tap_glyph_aura: u32 = 63321;
        pub const molten_core_aura: u32 = 47245;
        pub const decimation_aura: u32 = 63165;
        pub const life_tap_rank1_above_mana_pct: u32 = 30;
        pub const life_tap_max_at_or_below_mana_pct: u32 = 20;
    };
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.fel_armor.spell_id };
}

pub fn threatPlan(ctx: *const CombatContext) Action {
    if (!ctx.threat_high) return .none;
    if (ctx.bot.state.is_casting != 0 or ctx.bot.state.is_channeling != 0) return .none;
    if (!cooldown.spellReady(ctx.bot.state, data.spells.soulshatter.spell_id)) return .none;
    return .{ .cast_instant = data.spells.soulshatter.spell_id };
}

pub fn burstAction(step: usize) ?Action {
    return switch (step) {
        0 => .{ .cast_instant = data.spells.metamorphosis.spell_id },
        else => null,
    };
}

fn hasPet(state: proto.State) bool {
    return state.pet_guid != 0;
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

fn targetHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.target_auras, state.target_aura_count, spell_id);
}

fn manaPercent(state: proto.State) u32 {
    if (state.active_power_max == 0) return 100;
    return (state.active_power * 100) / state.active_power_max;
}

fn lifeTapSpellId(state: proto.State) u32 {
    if (manaPercent(state) > data.resources.life_tap_rank1_above_mana_pct) {
        return data.spells.life_tap_rank1.spell_id;
    }
    return data.spells.life_tap.spell_id;
}

fn shouldLifeTap(state: proto.State) bool {
    return manaPercent(state) <= data.resources.life_tap_max_at_or_below_mana_pct;
}

fn hostileTarget(bot: BotSnapshot, world: []const WorldSnapshot) ?proto.ScanEntry {
    const guid = world_query.primaryHostileAttackGuid(bot.state, world) orelse return null;
    return world_query.scanForGuidOnMap(world, guid, bot.state.map_id);
}

fn targetHealthPct(target: proto.ScanEntry) u32 {
    if (target.hp_max == 0) return 100;
    return (target.hp * 100) / target.hp_max;
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!selfHasAura(bot.state, data.spells.fel_armor.spell_id)) {
        return .{ .cast_instant = data.spells.fel_armor.spell_id };
    }

    if (!hasPet(bot.state)) {
        return .{ .cast_instant = data.spells.summon_felguard.spell_id };
    }

    const target = hostileTarget(bot, world) orelse return .none;
    const g = target.guid;
    const target_hp_pct = targetHealthPct(target);

    if (bot.state.is_casting == 0 and bot.state.is_channeling == 0 and
        cooldown.spellReady(bot.state, data.spells.demonic_empowerment.spell_id))
    {
        return .{ .cast_instant = data.spells.demonic_empowerment.spell_id };
    }

    if (!selfHasAura(bot.state, data.resources.life_tap_glyph_aura)) {
        return .{ .cast_instant = lifeTapSpellId(bot.state) };
    }

    if (shouldLifeTap(bot.state)) {
        return .{ .cast_instant = data.spells.life_tap.spell_id };
    }

    if (!targetHasAura(bot.state, data.spells.corruption.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.corruption.spell_id, .target_guid = g } };
    }

    if (!targetHasAura(bot.state, data.spells.immolate.spell_id)) {
        return .{ .cast_target = .{ .spell_id = data.spells.immolate.spell_id, .target_guid = g } };
    }

    if (target_hp_pct <= decimation_hp_pct and selfHasAura(bot.state, data.resources.decimation_aura)) {
        return .{ .cast_target = .{ .spell_id = data.spells.soul_fire.spell_id, .target_guid = g } };
    }

    if (selfHasAura(bot.state, data.resources.molten_core_aura)) {
        return .{ .cast_target = .{ .spell_id = data.spells.incinerate.spell_id, .target_guid = g } };
    }

    if (target_hp_pct <= decimation_hp_pct) {
        return .{ .cast_target = .{ .spell_id = data.spells.soul_fire.spell_id, .target_guid = g } };
    }

    return .{ .cast_target = .{ .spell_id = data.spells.shadow_bolt.spell_id, .target_guid = g } };
}

test "plan: casts Fel Armor when missing" {
    const std = @import("std");

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    const world: []const WorldSnapshot = &.{};

    const a = plan(bot, world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.fel_armor.spell_id, a.cast_instant);
}

test "burstAction: metamorphosis is the burst opener" {
    const std = @import("std");

    const a = burstAction(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(data.spells.metamorphosis.spell_id, a.cast_instant);
    try std.testing.expect(burstAction(1) == null);
}

test "hasPet: pet guid zero means absent" {
    const std = @import("std");

    var state: proto.State = std.mem.zeroes(proto.State);
    try std.testing.expect(!hasPet(state));

    state.pet_guid = 0xfeed;
    try std.testing.expect(hasPet(state));
}

test "plan: opens with Curse of Doom on target" {
    const std = @import("std");

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.pet_guid = 0xfeed;
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.demonic_empowerment.spell_id, .category = 0, .remaining_ms = 1000, .duration_ms = 1000 };
    bot.state.player_aura_count = 3;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };
    bot.state.player_auras[2] = .{ .caster_guid = 0, .spell_id = data.resources.molten_core_aura, .remaining_ms = 0 };

    var scan: proto.ScanEntry = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.corruption.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}
