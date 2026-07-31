const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const context = @import("../context.zig");
const spells_db = @import("../spells.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");
const cooldown = @import("../cooldown.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;
const CombatContext = context.CombatContext;

pub const data = struct {
    pub const spells = struct {
        pub const cat_form = spells_db.get(768);
        pub const clearcasting = spells_db.get(16870);
        pub const mangle_cat = spells_db.get(48566);
        pub const shred = spells_db.get(48572);
        pub const rake = spells_db.get(48574);
        pub const rip = spells_db.get(49800);
        pub const tigers_fury = spells_db.get(50213);
        pub const berserk = spells_db.get(50334);
        pub const savage_roar = spells_db.get(52610);
        pub const cower = spells_db.get(48575);
    };
    pub const resources = struct {};
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.cat_form.spell_id };
}

pub fn threatPlan(ctx: *const CombatContext) Action {
    if (!ctx.threat_high) return .none;
    if (ctx.bot.state.is_casting != 0 or ctx.bot.state.is_channeling != 0) return .none;
    if (ctx.bot.state.shapeshift_form != cat_shapeshift_form) return .none;
    if (!cooldown.spellReady(ctx.bot.state, data.spells.cower.spell_id)) return .none;
    return .{ .cast_instant = data.spells.cower.spell_id };
}

const energy_threshold_tigers_fury: u32 = 40;
const tigers_fury_cooldown_sec_ms: u32 = 15_000;
const energy_regen_per_sec: u32 = 10;
const energy_shred: u32 = 42;
const energy_rake: u32 = 35;
const energy_rip: u32 = 30;
const energy_mangle: u32 = 45;
const energy_savage_roar: u32 = 25;

const cat_shapeshift_form: u32 = 1;

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!proto.hasUnitFlag(bot.state.unit_flags, .in_combat) and
        bot.state.shapeshift_form != cat_shapeshift_form)
    {
        return .{ .cast_instant = data.spells.cat_form.spell_id };
    }

    if (bot.state.active_power < energy_threshold_tigers_fury and
        cooldown.spellReady(bot.state, data.spells.tigers_fury.spell_id))
    {
        return .{ .cast_instant = data.spells.tigers_fury.spell_id };
    }

    if (cooldown.spellReady(bot.state, data.spells.berserk.spell_id) and
        isTigersFuryOnCooldown(bot.state))
    {
        return .{ .cast_instant = data.spells.berserk.spell_id };
    }

    const g = world_query.primaryHostileAttackGuid(bot.state, world) orelse return .none;

    if (comboPointsOnTarget(bot, g) >= 1 and
        !hasSelfAura(bot.state, data.spells.savage_roar.spell_id))
    {
        if (bot.state.active_power >= energy_savage_roar) {
            return .{ .cast_instant = data.spells.savage_roar.spell_id };
        }
        return .none;
    }

    if (hasSelfAura(bot.state, data.spells.clearcasting.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.shred.spell_id, .target_guid = g } };
    }

    if (comboPointsOnTarget(bot, g) >= 5 and
        !hasTargetAura(bot.state, data.spells.rip.spell_id))
    {
        if (bot.state.active_power >= energy_rip) {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.rip.spell_id, .target_guid = g } };
        }
        return .none;
    }

    if (!hasTargetAura(bot.state, data.spells.rake.spell_id)) {
        if (bot.state.active_power >= energy_rake) {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.rake.spell_id, .target_guid = g } };
        }
        return .none;
    }

    if (!hasTargetAura(bot.state, data.spells.mangle_cat.spell_id)) {
        if (bot.state.active_power >= energy_mangle) {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.mangle_cat.spell_id, .target_guid = g } };
        }
        return .none;
    }

    if (canAffordShred(bot.state) and bot.state.active_power >= energy_shred) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.shred.spell_id, .target_guid = g } };
    }

    return .none;
}

fn comboPointsOnTarget(bot: BotSnapshot, target_guid: u64) u32 {
    if (bot.state.combo_target_guid != target_guid) return 0;
    return bot.state.combo_points;
}

fn hasSelfAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(state.player_auras[0..], state.player_aura_count, spell_id);
}

fn hasTargetAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(state.target_auras[0..], state.target_aura_count, spell_id);
}

fn remainingOnSelf(state: proto.State, spell_id: u32) u32 {
    const n = @min(state.player_aura_count, state.player_auras.len);
    for (state.player_auras[0..n]) |a| {
        if (a.spell_id == spell_id) return a.remaining_ms;
    }
    return 0;
}

fn remainingOnTarget(state: proto.State, spell_id: u32) u32 {
    const n = @min(state.target_aura_count, state.target_auras.len);
    for (state.target_auras[0..n]) |a| {
        if (a.spell_id == spell_id) return a.remaining_ms;
    }
    return 0;
}

fn isTigersFuryOnCooldown(state: proto.State) bool {
    const n = @min(state.cooldown_count, state.cooldowns.len);
    for (state.cooldowns[0..n]) |cd| {
        if (cd.spell_id == data.spells.tigers_fury.spell_id and cd.remaining_ms >= tigers_fury_cooldown_sec_ms) {
            return true;
        }
    }
    return false;
}

fn canAffordShred(state: proto.State) bool {
    const sr = remainingOnSelf(state, data.spells.savage_roar.spell_id);
    const rip = remainingOnTarget(state, data.spells.rip.spell_id);
    const rake = remainingOnTarget(state, data.spells.rake.spell_id);
    const mangle = remainingOnTarget(state, data.spells.mangle_cat.spell_id);

    var soonest: u32 = std.math.maxInt(u32);
    var reapply_cost: u32 = 0;

    if (sr > 0 and sr < soonest) {
        soonest = sr;
        reapply_cost = energy_savage_roar;
    }
    if (rip > 0 and rip < soonest) {
        soonest = rip;
        reapply_cost = energy_rip;
    }
    if (rake > 0 and rake < soonest) {
        soonest = rake;
        reapply_cost = energy_rake;
    }
    if (mangle > 0 and mangle < soonest) {
        soonest = mangle;
        reapply_cost = energy_mangle;
    }

    if (reapply_cost == 0) return true;

    const regen_energy = (soonest / 1000) * energy_regen_per_sec;
    return state.active_power + regen_energy >= energy_shred + reapply_cost;
}

fn makeScan(guid: u64, hp: u32, map_id: u32) WorldSnapshot {
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = guid;
    scan.hp = hp;
    scan.x = 10;
    scan.y = 0;
    scan.z = 0;
    return .{ .scan = scan, .map_id = map_id, .last_seen_ts_ns = 0 };
}

fn addCooldown(state: *proto.State, spell_id: u32, remaining_ms: u32, duration_ms: u32) void {
    const i = state.cooldown_count;
    state.cooldowns[i] = .{ .spell_id = spell_id, .category = 0, .remaining_ms = remaining_ms, .duration_ms = duration_ms };
    state.cooldown_count = i + 1;
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

test "plan: Cat Form out of combat when not in cat form" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.unit_flags = 0;
    bot.state.shapeshift_form = 0;

    const a = plan(bot, &.{});
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.cat_form.spell_id, a.cast_instant);
}

test "plan: no Cat Form when already in cat form" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = 0;
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 100;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.rake.spell_id, a.cast_target_instant.spell_id);
}

test "plan: no Cat Form when in combat" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = 0;
    bot.state.active_power = 100;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.rake.spell_id, a.cast_target_instant.spell_id);
}

test "plan: Tiger's Fury when energy below threshold and off cooldown" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 20;
    bot.state.active_power_max = 100;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 0)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.tigers_fury.spell_id, a.cast_instant);
}

test "plan: no Tiger's Fury when energy at threshold" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = energy_threshold_tigers_fury;
    bot.state.active_power_max = 100;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.rake.spell_id, a.cast_target_instant.spell_id);
}

test "plan: Tiger's Fury blocked when on cooldown falls to Rake" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.rake.spell_id, a.cast_target_instant.spell_id);
}

test "plan: Berserk when ready and Tiger's Fury on cooldown 15s+" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 20000, 30000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.berserk.spell_id, a.cast_instant);
}

test "plan: no Berserk when Tiger's Fury cooldown below 15s" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.rake.spell_id, a.cast_target_instant.spell_id);
}

test "plan: Savage Roar when combo points and no buff" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 3;
    bot.state.combo_target_guid = 0xabc;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);
    addTargetAura(&bot.state, data.spells.rake.spell_id, 5000);
    addTargetAura(&bot.state, data.spells.mangle_cat.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.savage_roar.spell_id, a.cast_instant);
}

test "plan: pool energy for Savage Roar when insufficient" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 10;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 2;
    bot.state.combo_target_guid = 0xabc;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    try std.testing.expectEqual(Action.none, plan(bot, &world));
}

test "plan: Clearcasting proc spent on Shred" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 2;
    bot.state.combo_target_guid = 0xabc;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);
    addSelfAura(&bot.state, data.spells.savage_roar.spell_id, 20000);
    addSelfAura(&bot.state, data.spells.clearcasting.spell_id, 5000);
    addTargetAura(&bot.state, data.spells.rake.spell_id, 5000);
    addTargetAura(&bot.state, data.spells.mangle_cat.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.shred.spell_id, a.cast_target_instant.spell_id);
}

test "plan: Rip at 5 combo points when not on target" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 5;
    bot.state.combo_target_guid = 0xabc;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);
    addSelfAura(&bot.state, data.spells.savage_roar.spell_id, 20000);
    addTargetAura(&bot.state, data.spells.rake.spell_id, 5000);
    addTargetAura(&bot.state, data.spells.mangle_cat.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.rip.spell_id, a.cast_target_instant.spell_id);
}

test "plan: Rake when not on target" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 2;
    bot.state.combo_target_guid = 0xabc;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);
    addSelfAura(&bot.state, data.spells.savage_roar.spell_id, 20000);
    addTargetAura(&bot.state, data.spells.mangle_cat.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.rake.spell_id, a.cast_target_instant.spell_id);
}

test "plan: Mangle when not on target" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 2;
    bot.state.combo_target_guid = 0xabc;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);
    addSelfAura(&bot.state, data.spells.savage_roar.spell_id, 20000);
    addTargetAura(&bot.state, data.spells.rake.spell_id, 5000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.mangle_cat.spell_id, a.cast_target_instant.spell_id);
}

test "plan: Shred filler when all debuffs and buffs are up" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 2;
    bot.state.combo_target_guid = 0xabc;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);
    addSelfAura(&bot.state, data.spells.savage_roar.spell_id, 20000);
    addTargetAura(&bot.state, data.spells.rake.spell_id, 8000);
    addTargetAura(&bot.state, data.spells.mangle_cat.spell_id, 10000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.shred.spell_id, a.cast_target_instant.spell_id);
}

test "plan: pool energy when buff about to expire and insufficient reserve" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 50;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 2;
    bot.state.combo_target_guid = 0xabc;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);
    addSelfAura(&bot.state, data.spells.savage_roar.spell_id, 500);
    addTargetAura(&bot.state, data.spells.rake.spell_id, 10000);
    addTargetAura(&bot.state, data.spells.mangle_cat.spell_id, 12000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    try std.testing.expectEqual(Action.none, plan(bot, &world));
}

test "plan: ignores combo points from another target" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;
    bot.state.combo_points = 5;
    bot.state.combo_target_guid = 0xdef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    addCooldown(&bot.state, data.spells.tigers_fury.spell_id, 10000, 30000);
    addSelfAura(&bot.state, data.spells.savage_roar.spell_id, 20000);

    const world = [_]WorldSnapshot{makeScan(0xabc, 100, 1)};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.rake.spell_id, a.cast_target_instant.spell_id);
}

test "plan: none without hostile target" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.shapeshift_form = cat_shapeshift_form;
    bot.state.active_power = 80;
    bot.state.active_power_max = 100;

    try std.testing.expectEqual(Action.none, plan(bot, &.{}));
}
