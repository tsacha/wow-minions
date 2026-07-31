//! Surinette, Ombreboulon (G2). Roster : assets/setup.md

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const spells_db = @import("../spells.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");
const cooldown = @import("../cooldown.zig");
const aggro = @import("../aggro.zig");
const context = @import("../context.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;
const CombatContext = context.CombatContext;

pub const data = struct {
    pub const spells = struct {
        pub const mutilate = spells_db.get(48666);
        pub const envenom = spells_db.get(57993);
        pub const slice_and_dice = spells_db.get(6774);
        pub const hunger_for_blood = spells_db.get(51662);
        pub const rupture = spells_db.get(48672);
        pub const tricks_of_the_trade = spells_db.get(57934);
    };
    pub const resources = struct {
        pub const envenom_buff: u32 = 57993;
        pub const hunger_for_blood_aura: u32 = 63848;
    };
};

const envenom_combo_points: u32 = 4;
const envenom_pool_energy: u32 = 80;
const energy_mutilate: u32 = 60;
const energy_snd: u32 = 25;
const energy_hfb: u32 = 30;
const energy_rupture: u32 = 25;
const energy_envenom: u32 = 35;

pub fn planWithContext(ctx: *const CombatContext) Action {
    const g = ctx.primary_target orelse return .none;
    if (cooldown.spellReady(ctx.bot.state, data.spells.tricks_of_the_trade.spell_id)) {
        if (aggro.tankOwner(ctx.bots, ctx.world, g, ctx.bot.state.map_id)) |tank| {
            if (tank.state.guid != ctx.bot.state.guid) {
                return .{ .cast_target_instant = .{ .spell_id = data.spells.tricks_of_the_trade.spell_id, .target_guid = tank.state.guid } };
            }
        }
    }
    return plan(ctx.bot, ctx.world);
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    const g = world_query.primaryHostileAttackGuid(bot.state, world) orelse return .none;

    if (!hasSelfAura(bot.state, data.spells.slice_and_dice.spell_id)) {
        if (comboPointsOnTarget(bot, g) >= 1 and
            bot.state.active_power >= energy_snd and
            cooldown.spellReady(bot.state, data.spells.slice_and_dice.spell_id))
        {
            return .{ .cast_instant = data.spells.slice_and_dice.spell_id };
        }
        if (bot.state.active_power >= energy_mutilate) {
            return .{ .cast_target = .{ .spell_id = data.spells.mutilate.spell_id, .target_guid = g } };
        }
        return .none;
    }

    if (!hasSelfAura(bot.state, data.resources.hunger_for_blood_aura)) {
        if (!hasTargetAura(bot.state, data.spells.rupture.spell_id)) {
            if (comboPointsOnTarget(bot, g) >= 1 and bot.state.active_power >= energy_rupture) {
                return .{ .cast_target_instant = .{ .spell_id = data.spells.rupture.spell_id, .target_guid = g } };
            }
            if (bot.state.active_power >= energy_mutilate) {
                return .{ .cast_target = .{ .spell_id = data.spells.mutilate.spell_id, .target_guid = g } };
            }
            return .none;
        }
        if (bot.state.active_power >= energy_hfb and
            cooldown.spellReady(bot.state, data.spells.hunger_for_blood.spell_id))
        {
            return .{ .cast_instant = data.spells.hunger_for_blood.spell_id };
        }
        return .none;
    }

    const cp = comboPointsOnTarget(bot, g);
    if (cp >= envenom_combo_points) {
        if (hasSelfAura(bot.state, data.resources.envenom_buff) and
            bot.state.active_power < envenom_pool_energy)
        {
            return .none;
        }
        if (bot.state.active_power >= energy_envenom) {
            return .{ .cast_target = .{ .spell_id = data.spells.envenom.spell_id, .target_guid = g } };
        }
        return .none;
    }

    if (bot.state.active_power >= energy_mutilate) {
        return .{ .cast_target = .{ .spell_id = data.spells.mutilate.spell_id, .target_guid = g } };
    }
    return .none;
}

fn comboPointsOnTarget(bot: BotSnapshot, target_guid: u64) u32 {
    if (bot.state.combo_target_guid != target_guid) return 0;
    return bot.state.combo_points;
}

fn hasSelfAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

fn hasTargetAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.target_auras, state.target_aura_count, spell_id);
}

fn makeScan(guid: u64, hp: u32, map_id: u32) WorldSnapshot {
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = guid;
    scan.hp = hp;
    return .{ .scan = scan, .map_id = map_id, .last_seen_ts_ns = 0 };
}

fn addSelfAura(state: *proto.State, spell_id: u32, remaining_ms: u32) void {
    const i = state.player_aura_count;
    state.player_auras[i] = .{ .spell_id = spell_id, .caster_guid = 1, .remaining_ms = remaining_ms };
    state.player_aura_count = i + 1;
}

fn addTargetAura(state: *proto.State, spell_id: u32, remaining_ms: u32) void {
    const i = state.target_aura_count;
    state.target_auras[i] = .{ .spell_id = spell_id, .caster_guid = 1, .remaining_ms = remaining_ms };
    state.target_aura_count = i + 1;
}

test "plan: mutilate below 4 combo points" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 3;
    bot.state.combo_target_guid = 0xabc;
    addSelfAura(&bot.state, data.spells.slice_and_dice.spell_id, 20000);
    addSelfAura(&bot.state, data.resources.hunger_for_blood_aura, 20000);
    addTargetAura(&bot.state, data.spells.rupture.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.mutilate.spell_id, a.cast_target.spell_id);
}

test "plan: envenom at 4 combo points" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 4;
    bot.state.combo_target_guid = 0xabc;
    addSelfAura(&bot.state, data.spells.slice_and_dice.spell_id, 20000);
    addSelfAura(&bot.state, data.resources.hunger_for_blood_aura, 20000);
    addTargetAura(&bot.state, data.spells.rupture.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.envenom.spell_id, a.cast_target.spell_id);
}

test "plan: envenom at 5 combo points" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 5;
    bot.state.combo_target_guid = 0xabc;
    addSelfAura(&bot.state, data.spells.slice_and_dice.spell_id, 20000);
    addSelfAura(&bot.state, data.resources.hunger_for_blood_aura, 20000);
    addTargetAura(&bot.state, data.spells.rupture.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.envenom.spell_id, a.cast_target.spell_id);
}

test "plan: pools energy when envenom buff active and energy below threshold" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 60;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 4;
    bot.state.combo_target_guid = 0xabc;
    addSelfAura(&bot.state, data.spells.slice_and_dice.spell_id, 20000);
    addSelfAura(&bot.state, data.resources.hunger_for_blood_aura, 20000);
    addSelfAura(&bot.state, data.resources.envenom_buff, 3000);
    addTargetAura(&bot.state, data.spells.rupture.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    try std.testing.expectEqual(Action.none, plan(bot, &world));
}

test "plan: envenom at high energy even with buff active" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 85;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 4;
    bot.state.combo_target_guid = 0xabc;
    addSelfAura(&bot.state, data.spells.slice_and_dice.spell_id, 20000);
    addSelfAura(&bot.state, data.resources.hunger_for_blood_aura, 20000);
    addSelfAura(&bot.state, data.resources.envenom_buff, 3000);
    addTargetAura(&bot.state, data.spells.rupture.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.envenom.spell_id, a.cast_target.spell_id);
}

test "plan: no mutilate when at 4+ cp and insufficient energy for envenom" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 30;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 5;
    bot.state.combo_target_guid = 0xabc;
    addSelfAura(&bot.state, data.spells.slice_and_dice.spell_id, 20000);
    addSelfAura(&bot.state, data.resources.hunger_for_blood_aura, 20000);
    addTargetAura(&bot.state, data.spells.rupture.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    try std.testing.expectEqual(Action.none, plan(bot, &world));
}

test "plan: slice and dice when no buff and combo points" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 2;
    bot.state.combo_target_guid = 0xabc;

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.slice_and_dice.spell_id, a.cast_instant);
}

test "plan: mutilate to build for slice and dice when no cp" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 0;
    bot.state.combo_target_guid = 0;

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.mutilate.spell_id, a.cast_target.spell_id);
}

test "plan: pool energy for slice and dice when insufficient" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 10;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 1;
    bot.state.combo_target_guid = 0xabc;

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    try std.testing.expectEqual(Action.none, plan(bot, &world));
}

test "plan: hunger for blood opening: rupture first" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 2;
    bot.state.combo_target_guid = 0xabc;
    addSelfAura(&bot.state, data.spells.slice_and_dice.spell_id, 20000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.rupture.spell_id, a.cast_target_instant.spell_id);
}

test "plan: hunger for blood after rupture is up" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 1;
    bot.state.combo_target_guid = 0xabc;
    addSelfAura(&bot.state, data.spells.slice_and_dice.spell_id, 20000);
    addTargetAura(&bot.state, data.spells.rupture.spell_id, 5000);
    addSelfAura(&bot.state, data.resources.hunger_for_blood_aura, 20000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.mutilate.spell_id, a.cast_target.spell_id);
}

test "plan: mutilate to build cp for rupture when starting hfb" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 0;
    bot.state.combo_target_guid = 0;
    addSelfAura(&bot.state, data.spells.slice_and_dice.spell_id, 20000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.mutilate.spell_id, a.cast_target.spell_id);
}

test "plan: ignores combo points from another target" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 5;
    bot.state.combo_target_guid = 0xdef;
    addSelfAura(&bot.state, data.spells.slice_and_dice.spell_id, 20000);
    addSelfAura(&bot.state, data.resources.hunger_for_blood_aura, 20000);
    addTargetAura(&bot.state, data.spells.rupture.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.mutilate.spell_id, a.cast_target.spell_id);
}

test "plan: none without hostile target" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;

    try std.testing.expectEqual(Action.none, plan(bot, &.{}));
}
