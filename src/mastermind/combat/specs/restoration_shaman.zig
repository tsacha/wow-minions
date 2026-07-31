//! Restoration Shaman: Maréelue (Group 5). Roster: assets/setup.md

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

pub const data = struct {
    pub const spells = struct {
        pub const call_of_the_elements = spells_db.get(66842);
        pub const wrath_of_air_totem = spells_db.get(37380);
        pub const strength_of_earth_totem = spells_db.get(58643);
        pub const flametongue_totem = spells_db.get(58656);
        pub const mana_spring_totem = spells_db.get(58774);
        pub const water_shield = spells_db.get(57960);
        pub const tidal_waves = spells_db.get(53390);
        pub const riptide = spells_db.get(61299);
        pub const lesser_healing_wave = spells_db.get(49276);
        pub const healing_wave = spells_db.get(49273);
        pub const chain_heal = spells_db.get(55459);
        pub const earth_shield = spells_db.get(32594);
    };
    pub const resources = struct {
        pub const wrath_of_air_totem_aura: u32 = 2895;
        pub const strength_of_earth_totem_aura: u32 = 58646;
        pub const flametongue_totem_aura: u32 = 58655;
        pub const mana_spring_totem_aura: u32 = 58777;
    };
};

pub fn maintenance(ctx: *const CombatContext) Action {
    if (inCombat(ctx.bot.state)) {
        if (needsTotem(ctx, .air, data.resources.wrath_of_air_totem_aura, data.spells.wrath_of_air_totem.spell_id)) {
            return .{ .cast_instant = data.spells.call_of_the_elements.spell_id };
        }
        if (needsTotem(ctx, .earth, data.resources.strength_of_earth_totem_aura, data.spells.strength_of_earth_totem.spell_id)) {
            return .{ .cast_instant = data.spells.call_of_the_elements.spell_id };
        }
        if (needsTotem(ctx, .fire, data.resources.flametongue_totem_aura, data.spells.flametongue_totem.spell_id)) {
            return .{ .cast_instant = data.spells.call_of_the_elements.spell_id };
        }
        if (needsTotem(ctx, .water, data.resources.mana_spring_totem_aura, data.spells.mana_spring_totem.spell_id)) {
            return .{ .cast_instant = data.spells.call_of_the_elements.spell_id };
        }
    }

    const target_guid = maintenanceTarget(ctx) orelse return .none;
    if (!targetHasAuraFromSelf(ctx, target_guid, data.spells.earth_shield.spell_id)) {
        return .{ .cast_target_instant = .{
            .spell_id = data.spells.earth_shield.spell_id,
            .target_guid = target_guid,
        } };
    }
    if (shouldRiptide(ctx, target_guid) and
        !targetHasAuraFromSelf(ctx, target_guid, data.spells.riptide.spell_id))
    {
        return .{ .cast_target_instant = .{
            .spell_id = data.spells.riptide.spell_id,
            .target_guid = target_guid,
        } };
    }
    if (shouldChainHeal(ctx, target_guid) and
        targetHasAuraFromSelf(ctx, target_guid, data.spells.riptide.spell_id))
    {
        return .{ .cast_target_instant = .{
            .spell_id = data.spells.chain_heal.spell_id,
            .target_guid = target_guid,
        } };
    }
    return .none;
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!selfHasAura(bot.state, data.spells.water_shield.spell_id)) {
        return .{ .cast_instant = data.spells.water_shield.spell_id };
    }

    _ = world;
    return .none;
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

fn inCombat(state: proto.State) bool {
    return proto.hasUnitFlag(state.unit_flags, .in_combat);
}

fn needsTotem(ctx: *const CombatContext, element: proto.TotemElement, aura_id: u32, spell_id: u32) bool {
    const slot = proto.totemSlot(&ctx.bot.state.totems, element);
    if (slot.remaining_ms > 0 or selfHasAura(ctx.bot.state, aura_id)) return false;
    return ctx.spellReady(spell_id);
}

fn seedActiveTotems(state: *proto.State, caster_guid: u64) void {
    state.totems[@intFromEnum(proto.TotemElement.fire)].remaining_ms = 30_000;
    state.totems[@intFromEnum(proto.TotemElement.earth)].remaining_ms = 30_000;
    state.totems[@intFromEnum(proto.TotemElement.water)].remaining_ms = 30_000;
    state.totems[@intFromEnum(proto.TotemElement.air)].remaining_ms = 30_000;
    state.player_aura_count = 4;
    state.player_auras[0] = .{ .spell_id = data.resources.flametongue_totem_aura, .caster_guid = caster_guid, .remaining_ms = 30_000 };
    state.player_auras[1] = .{ .spell_id = data.resources.strength_of_earth_totem_aura, .caster_guid = caster_guid, .remaining_ms = 30_000 };
    state.player_auras[2] = .{ .spell_id = data.resources.mana_spring_totem_aura, .caster_guid = caster_guid, .remaining_ms = 30_000 };
    state.player_auras[3] = .{ .spell_id = data.resources.wrath_of_air_totem_aura, .caster_guid = caster_guid, .remaining_ms = 30_000 };
}

fn maintenanceTarget(ctx: *const CombatContext) ?u64 {
    if (ctx.assigned_tank_guid != 0) {
        const assigned = ctx.assigned_tank_guid;
        if (eligibleTank(ctx, assigned)) return assigned;
    }

    for (ctx.bots) |ally| {
        if (ally.state.guid == 0 or ally.state.guid == ctx.bot.state.guid) continue;
        if (ally.state.map_id != ctx.bot.state.map_id) continue;
        if (role_mod.roleForBot(ally) != .tank) continue;
        const scan = world_query.scanForGuidOnMap(ctx.world, ally.state.guid, ctx.bot.state.map_id) orelse continue;
        if (scan.hp == 0) continue;
        return ally.state.guid;
    }

    return null;
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

fn shouldRiptide(ctx: *const CombatContext, target_guid: u64) bool {
    const scan = world_query.scanForGuidOnMap(ctx.world, target_guid, ctx.bot.state.map_id) orelse return false;
    const hp_max = if (scan.hp_max == 0) 1 else scan.hp_max;
    const hp_ratio = @as(f32, @floatFromInt(scan.hp)) / @as(f32, @floatFromInt(hp_max));
    return hp_ratio <= riptide_steady_damage_hp_ratio and ctx.spellReady(data.spells.riptide.spell_id);
}

fn shouldChainHeal(ctx: *const CombatContext, target_guid: u64) bool {
    return countInjuredAlliesAroundTarget(ctx, target_guid, chain_heal_clump_radius_yards) >= chain_heal_injured_allies_threshold and
        ctx.spellReady(data.spells.chain_heal.spell_id);
}

fn countInjuredAlliesAroundTarget(ctx: *const CombatContext, target_guid: u64, radius_yards: f32) u32 {
    const target_scan = world_query.scanForGuidOnMap(ctx.world, target_guid, ctx.bot.state.map_id) orelse return 0;
    var count: u32 = 0;
    const radius_sq = radius_yards * radius_yards;

    for (ctx.bots) |ally| {
        if (ally.state.map_id != ctx.bot.state.map_id) continue;
        if (ally.state.guid == 0 or ally.state.guid == ctx.bot.state.guid) continue;
        const scan = world_query.scanForGuidOnMap(ctx.world, ally.state.guid, ctx.bot.state.map_id) orelse continue;
        if (scan.hp == 0) continue;
        if (scan.guid == target_scan.guid) {
            count += 1;
            continue;
        }
        const dx = scan.x - target_scan.x;
        const dy = scan.y - target_scan.y;
        const dz = scan.z - target_scan.z;
        if (dx * dx + dy * dy + dz * dz > radius_sq) continue;
        const hp_max = if (scan.hp_max == 0) 1 else scan.hp_max;
        if (@as(f32, @floatFromInt(scan.hp)) / @as(f32, @floatFromInt(hp_max)) >= 1.0) continue;
        count += 1;
    }

    return count;
}

fn targetHasAuraFromSelf(ctx: *const CombatContext, target_guid: u64, spell_id: u32) bool {
    const scan = world_query.scanForGuidOnMap(ctx.world, target_guid, ctx.bot.state.map_id) orelse return false;
    const n = @min(scan.aura_count, scan.auras.len);
    for (scan.auras[0..n]) |entry| {
        if (entry.spell_id == spell_id and entry.caster_guid == ctx.bot.state.guid) return true;
    }
    return false;
}

const riptide_steady_damage_hp_ratio: f32 = 0.90;
const chain_heal_clump_radius_yards: f32 = 12.0;
const chain_heal_injured_allies_threshold: u32 = 2;

test "maintenance: earth shield assigned tank first" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.shaman);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    healer.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    seedActiveTotems(&healer.state, healer.state.guid);

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

    const bots = [_]BotSnapshot{ healer, tank };
    const world = [_]WorldSnapshot{.{ .scan = tank_scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const action = maintenance(&ctx);
    try std.testing.expect(action == .cast_target_instant);
    try std.testing.expectEqual(data.spells.earth_shield.spell_id, action.cast_target_instant.spell_id);
    try std.testing.expectEqual(tank.state.guid, action.cast_target_instant.target_guid);
}

test "maintenance: totems have priority before heals" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.shaman);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    healer.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    seedActiveTotems(&healer.state, healer.state.guid);
    healer.state.totems[@intFromEnum(proto.TotemElement.air)].remaining_ms = 0;
    healer.state.player_aura_count = 3;
    healer.state.player_auras[0] = .{ .spell_id = data.resources.flametongue_totem_aura, .caster_guid = healer.state.guid, .remaining_ms = 30_000 };
    healer.state.player_auras[1] = .{ .spell_id = data.resources.strength_of_earth_totem_aura, .caster_guid = healer.state.guid, .remaining_ms = 30_000 };
    healer.state.player_auras[2] = .{ .spell_id = data.resources.mana_spring_totem_aura, .caster_guid = healer.state.guid, .remaining_ms = 30_000 };
    healer.state.spell_range_count = 1;
    healer.state.spell_ranges[0] = .{ .spell_id = data.spells.call_of_the_elements.spell_id, .max_range_yards = 0.0 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id[0] = 2;
    tank.state.guid = 0x200;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    const bots = [_]BotSnapshot{ healer, tank };
    const world = [_]WorldSnapshot{};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const action = maintenance(&ctx);
    try std.testing.expect(action == .cast_instant);
    try std.testing.expectEqual(data.spells.call_of_the_elements.spell_id, action.cast_instant);
}

test "maintenance: riptide follows earth shield on injured tank" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.shaman);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    seedActiveTotems(&healer.state, healer.state.guid);

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
    tank_scan.auras[0] = .{ .spell_id = data.spells.earth_shield.spell_id, .caster_guid = healer.state.guid, .remaining_ms = 600_000 };

    const bots = [_]BotSnapshot{ healer, tank };
    const world = [_]WorldSnapshot{.{ .scan = tank_scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const action = maintenance(&ctx);
    try std.testing.expect(action == .cast_target_instant);
    try std.testing.expectEqual(data.spells.riptide.spell_id, action.cast_target_instant.spell_id);
    try std.testing.expectEqual(tank.state.guid, action.cast_target_instant.target_guid);
}

test "maintenance: earth shield falls back to first living tank" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.shaman);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    seedActiveTotems(&healer.state, healer.state.guid);

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id[0] = 2;
    tank.state.guid = 0x200;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var tank_scan = std.mem.zeroes(proto.ScanEntry);
    tank_scan.guid = tank.state.guid;
    tank_scan.hp = 900;
    tank_scan.hp_max = 1000;

    const bots = [_]BotSnapshot{ healer, tank };
    const world = [_]WorldSnapshot{.{ .scan = tank_scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const action = maintenance(&ctx);
    try std.testing.expect(action == .cast_target_instant);
    try std.testing.expectEqual(data.spells.earth_shield.spell_id, action.cast_target_instant.spell_id);
    try std.testing.expectEqual(tank.state.guid, action.cast_target_instant.target_guid);
}

test "plan: water shield missing casts it" {
    const std = @import("std");

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    bot.state.class = @intFromEnum(class_spec.Class.shaman);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    const a = plan(bot, &.{});
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.water_shield.spell_id, a.cast_instant);
}

test "maintenance: riptide on injured tank after earth shield" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.shaman);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    seedActiveTotems(&healer.state, healer.state.guid);
    healer.state.spell_range_count = 3;
    healer.state.spell_ranges[0] = .{ .spell_id = data.spells.earth_shield.spell_id, .max_range_yards = 40.0 };
    healer.state.spell_ranges[1] = .{ .spell_id = data.spells.riptide.spell_id, .max_range_yards = 40.0 };
    healer.state.spell_ranges[2] = .{ .spell_id = data.spells.chain_heal.spell_id, .max_range_yards = 40.0 };

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
    tank_scan.hp = 700;
    tank_scan.hp_max = 1000;
    tank_scan.aura_count = 1;
    tank_scan.auras[0] = .{ .spell_id = data.spells.earth_shield.spell_id, .caster_guid = healer.state.guid, .remaining_ms = 600_000 };

    const bots = [_]BotSnapshot{ healer, tank };
    const world = [_]WorldSnapshot{.{ .scan = tank_scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const action = maintenance(&ctx);
    try std.testing.expect(action == .cast_target_instant);
    try std.testing.expectEqual(data.spells.riptide.spell_id, action.cast_target_instant.spell_id);
    try std.testing.expectEqual(tank.state.guid, action.cast_target_instant.target_guid);
}
