//! Soutane (Groupe 5). Roster : assets/setup.md

const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const assignments = @import("../assignments.zig");
const class_spec = @import("../class_spec.zig");
const context = @import("../context.zig");
const role_mod = @import("../role.zig");
const spells_db = @import("../spells.zig");
const world_query = @import("../world_query.zig");
const Action = @import("../action.zig").Action;

const BotSnapshot = registry_mod.BotSnapshot;
const CombatContext = context.CombatContext;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

const shield_spell_id: u32 = 48066;
const prayer_of_mending_spell_id: u32 = 33076;
const prayer_of_spirit_spell_id: u32 = 48074;

pub const data = struct {
    pub const spells = struct {
        pub const inner_fire = spells_db.get(48168);
        pub const power_word_shield = spells_db.get(shield_spell_id);
        pub const prayer_of_mending = spells_db.get(prayer_of_mending_spell_id);
        pub const flash_heal = spells_db.get(48071);
        pub const greater_heal = spells_db.get(48072);
        pub const prayer_of_fortitude = spells_db.get(48162);
        pub const prayer_of_spirit = spells_db.get(prayer_of_spirit_spell_id);
        pub const pain_suppression = spells_db.get(33206);
        pub const renew = spells_db.get(48068);
        pub const penance = spells_db.get(53007);
        pub const divine_hymn = spells_db.get(64843);
    };
    pub const resources = struct {};
};

const raid_buff_actions = [_]Action{
    .{ .cast = data.spells.prayer_of_fortitude.spell_id },
    .{ .cast = data.spells.prayer_of_spirit.spell_id },
};

pub fn raidBuffActions() []const Action {
    return raid_buff_actions[0..];
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!selfHasAura(bot.state, data.spells.inner_fire.spell_id)) {
        return .{ .cast_instant = data.spells.inner_fire.spell_id };
    }

    _ = world;
    return .none;
}

pub fn maintenance(ctx: *const CombatContext) Action {
    const target_guid = maintenanceTarget(ctx) orelse return .none;

    if (ctx.spellReady(data.spells.penance.spell_id)) {
        const scan = world_query.scanForGuidOnMap(ctx.world, target_guid, ctx.bot.state.map_id) orelse return .none;
        if (scan.hp < scan.hp_max) {
            return .{ .cast_target_instant = .{
                .spell_id = data.spells.penance.spell_id,
                .target_guid = target_guid,
            } };
        }
    }

    if (!targetHasAuraFromSelf(ctx, target_guid, data.spells.power_word_shield.spell_id)) {
        return .{ .cast_target_instant = .{
            .spell_id = data.spells.power_word_shield.spell_id,
            .target_guid = target_guid,
        } };
    }
    return .none;
}

pub fn fallback(ctx: *const CombatContext) Action {
    const target_guid = maintenanceTarget(ctx) orelse return .none;
    if (!targetHasAuraFromSelf(ctx, target_guid, data.spells.prayer_of_mending.spell_id)) {
        return .{ .cast_target_instant = .{
            .spell_id = data.spells.prayer_of_mending.spell_id,
            .target_guid = target_guid,
        } };
    }
    return .none;
}

fn maintenanceTarget(ctx: *const CombatContext) ?u64 {
    if (assignedTankGuid(ctx)) |guid| return guid;
    if (bestTankGuid(ctx)) |guid| return guid;
    return if (ctx.heal_priority) |target| target.guid else null;
}

fn assignedTankGuid(ctx: *const CombatContext) ?u64 {
    const target_guid = if (ctx.assigned_tank_guid != 0) ctx.assigned_tank_guid else return null;
    if (!eligibleTank(ctx, target_guid)) return null;
    return target_guid;
}

fn bestTankGuid(ctx: *const CombatContext) ?u64 {
    var first_tank: ?u64 = null;
    for (ctx.bots) |ally| {
        if (ally.state.map_id != ctx.bot.state.map_id) continue;
        if (ally.state.guid == 0 or ally.state.guid == ctx.bot.state.guid) continue;
        if (role_mod.roleForBot(ally) != .tank) continue;
        const scan = world_query.scanForGuidOnMap(ctx.world, ally.state.guid, ctx.bot.state.map_id) orelse continue;
        if (scan.hp == 0) continue;
        if (first_tank == null) first_tank = ally.state.guid;
    }
    return first_tank;
}

fn eligibleTank(ctx: *const CombatContext, guid: u64) bool {
    for (ctx.bots) |ally| {
        if (ally.state.guid != guid) continue;
        if (ally.state.map_id != ctx.bot.state.map_id) return false;
        if (role_mod.roleForBot(ally) != .tank) return false;
        const scan = world_query.scanForGuidOnMap(ctx.world, guid, ctx.bot.state.map_id) orelse return false;
        return scan.hp > 0;
    }
    return false;
}

fn targetHasAuraFromSelf(ctx: *const CombatContext, target_guid: u64, spell_id: u32) bool {
    const scan = world_query.scanForGuidOnMap(ctx.world, target_guid, ctx.bot.state.map_id) orelse return false;
    const n = @min(scan.aura_count, scan.auras.len);
    for (scan.auras[0..n]) |entry| {
        if (entry.spell_id == spell_id and entry.caster_guid == ctx.bot.state.guid) return true;
    }
    return false;
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

test "maintenance: shield assigned tank first" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.priest);
    healer.state.talent_points = .{ .tab1 = 30, .tab2 = 30, .tab3 = 0 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id[0] = 2;
    tank.state.guid = 0x200;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    assignments.setAssignedTank(healer.bot_id, tank.state.guid);
    defer assignments.clearAssignedTank(healer.bot_id);

    healer.state.cooldown_count = 1;
    healer.state.cooldowns[0] = .{ .spell_id = data.spells.penance.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 10000 };

    var tank_scan = std.mem.zeroes(proto.ScanEntry);
    tank_scan.guid = tank.state.guid;
    tank_scan.hp = 900;
    tank_scan.hp_max = 1000;

    const bots = [_]BotSnapshot{ healer, tank };
    const world = [_]WorldSnapshot{.{ .scan = tank_scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const action = maintenance(&ctx);
    try std.testing.expect(action == .cast_target_instant);
    try std.testing.expectEqual(data.spells.power_word_shield.spell_id, action.cast_target_instant.spell_id);
    try std.testing.expectEqual(tank.state.guid, action.cast_target_instant.target_guid);
}

test "fallback: prayer of mending on shielded tank" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.priest);
    healer.state.talent_points = .{ .tab1 = 30, .tab2 = 30, .tab3 = 0 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id[0] = 2;
    tank.state.guid = 0x200;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    assignments.setAssignedTank(healer.bot_id, tank.state.guid);
    defer assignments.clearAssignedTank(healer.bot_id);

    var tank_scan = std.mem.zeroes(proto.ScanEntry);
    tank_scan.guid = tank.state.guid;
    tank_scan.hp = 900;
    tank_scan.hp_max = 1000;
    tank_scan.aura_count = 1;
    tank_scan.auras[0] = .{ .spell_id = data.spells.power_word_shield.spell_id, .caster_guid = healer.state.guid, .remaining_ms = 15_000 };

    const bots = [_]BotSnapshot{ healer, tank };
    const world = [_]WorldSnapshot{.{ .scan = tank_scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const action = fallback(&ctx);
    try std.testing.expect(action == .cast_target_instant);
    try std.testing.expectEqual(data.spells.prayer_of_mending.spell_id, action.cast_target_instant.spell_id);
    try std.testing.expectEqual(tank.state.guid, action.cast_target_instant.target_guid);
}

test "maintenance: no maintenance when shield already present" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.priest);
    healer.state.talent_points = .{ .tab1 = 30, .tab2 = 30, .tab3 = 0 };
    healer.state.cooldown_count = 1;
    healer.state.cooldowns[0] = .{ .spell_id = data.spells.penance.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 10000 };
    healer.state.spell_range_count = 2;
    healer.state.spell_ranges[0] = .{ .spell_id = data.spells.power_word_shield.spell_id, .max_range_yards = 40.0 };
    healer.state.spell_ranges[1] = .{ .spell_id = data.spells.flash_heal.spell_id, .max_range_yards = 40.0 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id[0] = 2;
    tank.state.guid = 0x200;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var tank_scan = std.mem.zeroes(proto.ScanEntry);
    tank_scan.guid = tank.state.guid;
    tank_scan.hp = 700;
    tank_scan.hp_max = 1000;
    tank_scan.aura_count = 1;
    tank_scan.auras[0] = .{ .spell_id = data.spells.power_word_shield.spell_id, .caster_guid = healer.state.guid, .remaining_ms = 15_000 };

    const bots = [_]BotSnapshot{ healer, tank };
    const world = [_]WorldSnapshot{.{ .scan = tank_scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    try std.testing.expect(maintenance(&ctx) == .none);
}

test "fallback: no fallback when pom already present" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.priest);
    healer.state.talent_points = .{ .tab1 = 30, .tab2 = 30, .tab3 = 0 };
    healer.state.cooldown_count = 1;
    healer.state.cooldowns[0] = .{ .spell_id = data.spells.penance.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 10000 };
    healer.state.spell_range_count = 2;
    healer.state.spell_ranges[0] = .{ .spell_id = data.spells.power_word_shield.spell_id, .max_range_yards = 40.0 };
    healer.state.spell_ranges[1] = .{ .spell_id = data.spells.flash_heal.spell_id, .max_range_yards = 40.0 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id[0] = 2;
    tank.state.guid = 0x200;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var tank_scan = std.mem.zeroes(proto.ScanEntry);
    tank_scan.guid = tank.state.guid;
    tank_scan.hp = 700;
    tank_scan.hp_max = 1000;
    tank_scan.aura_count = 2;
    tank_scan.auras[0] = .{ .spell_id = data.spells.power_word_shield.spell_id, .caster_guid = healer.state.guid, .remaining_ms = 15_000 };
    tank_scan.auras[1] = .{ .spell_id = data.spells.prayer_of_mending.spell_id, .caster_guid = healer.state.guid, .remaining_ms = 8_000 };

    const bots = [_]BotSnapshot{ healer, tank };
    const world = [_]WorldSnapshot{.{ .scan = tank_scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    try std.testing.expect(fallback(&ctx) == .none);
}

test "raidBuffActions: discipline casts fortitude then spirit" {
    const std = @import("std");

    const actions = raidBuffActions();
    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expect(actions[0] == .cast);
    try std.testing.expect(actions[1] == .cast);
    try std.testing.expectEqual(data.spells.prayer_of_fortitude.spell_id, actions[0].cast);
    try std.testing.expectEqual(data.spells.prayer_of_spirit.spell_id, actions[1].cast);
}

test "plan: discipline casts inner fire when missing" {
    const std = @import("std");

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 0;

    const a = plan(bot, &.{});
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.inner_fire.spell_id, a.cast_instant);
}

test "plan: discipline skips inner fire when present" {
    const std = @import("std");

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.inner_fire.spell_id, .remaining_ms = 1 };

    try std.testing.expect(plan(bot, &.{}) == .none);
}

test "plan: discipline skips inner fire when zero remaining aura remains" {
    const std = @import("std");

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.inner_fire.spell_id, .remaining_ms = 0 };

    try std.testing.expect(plan(bot, &.{}) == .none);
}
