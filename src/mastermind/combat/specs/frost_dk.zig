//! Frost DK: Cryoclé (G5). Roster: assets/setup.md

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const cooldown = @import("../cooldown.zig");
const spells_db = @import("../spells.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

const death_rune_type: u32 = 4;
const frost_presence_id: u32 = 48263;
const blood_tap_id: u32 = 45529;
const frost_fever_id: u32 = 55095;
const blood_plague_id: u32 = 55078;

const rune_type_blood: u32 = 1;
const rune_type_frost: u32 = 2;
const rune_type_unholy: u32 = 3;

const death_coil_min_power: u32 = 40;
pub const data = struct {
    pub const spells = struct {
        pub const frost_presence = spells_db.get(frost_presence_id);
        pub const blood_tap = spells_db.get(blood_tap_id);
        pub const icy_touch = spells_db.get(49909);
        pub const plague_strike = spells_db.get(49921);
        pub const blood_strike = spells_db.get(49930);
        pub const frost_strike = spells_db.get(55268);
        pub const obliterate = spells_db.get(51425);
        pub const howling_blast = spells_db.get(51411);
        pub const unbreakable_armor = spells_db.get(51271);
        pub const frost_fever = spells_db.get(frost_fever_id);
        pub const blood_plague = spells_db.get(blood_plague_id);
        pub const rime = spells_db.get(59057);
        pub const killing_machine = spells_db.get(51130);
        pub const blood_of_the_north = spells_db.get(54638);
        pub const epidemic = spells_db.get(49562);
        pub const glacier_rot = spells_db.get(49791);
        pub const tundra_stalker = spells_db.get(50130);
    };

    pub const resources = struct {};
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.frost_presence.spell_id };
}

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

fn hasAnyRuneSpend(state: proto.State) bool {
    return hasReadyRuneOfType(state, rune_type_blood) or
        hasReadyRuneOfType(state, rune_type_frost) or
        hasReadyRuneOfType(state, rune_type_unholy);
}

fn diseasesUp(state: proto.State) bool {
    return targetHasAura(state, data.spells.frost_fever.spell_id) and
        targetHasAura(state, data.spells.blood_plague.spell_id);
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!selfHasAura(bot.state, data.spells.frost_presence.spell_id)) {
        return .{ .cast_instant = data.spells.frost_presence.spell_id };
    }

    const target = hostileTarget(bot, world) orelse return .none;
    const g = target.guid;

    const blood_ready = hasReadyRuneOfType(bot.state, rune_type_blood);
    const frost_ready = hasReadyRuneOfType(bot.state, rune_type_frost);
    const unholy_ready = hasReadyRuneOfType(bot.state, rune_type_unholy);
    const diseases_up = diseasesUp(bot.state);
    const rime_up = selfHasAura(bot.state, data.spells.rime.spell_id);
    const killing_machine_up = selfHasAura(bot.state, data.spells.killing_machine.spell_id);

    if (cooldown.spellReady(bot.state, data.spells.blood_tap.spell_id) and
        cooldown.spellReady(bot.state, data.spells.unbreakable_armor.spell_id))
    {
        return .{ .cast_instant = data.spells.blood_tap.spell_id };
    }

    if (cooldown.spellReady(bot.state, data.spells.unbreakable_armor.spell_id) and
        selfHasAura(bot.state, data.spells.blood_tap.spell_id))
    {
        return .{ .cast_instant = data.spells.unbreakable_armor.spell_id };
    }

    if (!diseases_up and !targetHasAura(bot.state, data.spells.frost_fever.spell_id) and frost_ready) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.icy_touch.spell_id, .target_guid = g } };
    }

    if (!diseases_up and !targetHasAura(bot.state, data.spells.blood_plague.spell_id) and unholy_ready) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.plague_strike.spell_id, .target_guid = g } };
    }

    if (frost_ready and unholy_ready) {
        if (killing_machine_up or !rime_up) {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.obliterate.spell_id, .target_guid = g } };
        }
        return .{ .cast_target_instant = .{ .spell_id = data.spells.howling_blast.spell_id, .target_guid = g } };
    }

    if (rime_up and diseases_up)
    {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.howling_blast.spell_id, .target_guid = g } };
    }

    if (blood_ready and cooldown.spellReady(bot.state, data.spells.blood_strike.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.blood_strike.spell_id, .target_guid = g } };
    }

    if (killing_machine_up and bot.state.active_power >= death_coil_min_power) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.frost_strike.spell_id, .target_guid = g } };
    }

    if (hasAnyRuneSpend(bot.state)) {
        if (bot.state.active_power >= death_coil_min_power) {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.frost_strike.spell_id, .target_guid = g } };
        }
        return .{ .cast_target_instant = .{ .spell_id = data.spells.obliterate.spell_id, .target_guid = g } };
    }

    if (bot.state.active_power >= death_coil_min_power) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.frost_strike.spell_id, .target_guid = g } };
    }

    return .none;
}
