//! Lumibarbe (Groupe 5). Roster : assets/setup.md

const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const class_spec = @import("../class_spec.zig");
const context = @import("../context.zig");
const assignments = @import("../assignments.zig");
const thaddius_state = @import("../encounters/thaddius/state.zig");
const spells_db = @import("../spells.zig");
const role_mod = @import("../role.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const CombatContext = context.CombatContext;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const data = struct {
    pub const spells = struct {
        pub const greater_blessing_of_wisdom = spells_db.get(48938);
        pub const beacon_of_light = spells_db.get(53563);
        pub const flash_of_light = spells_db.get(48785);
        pub const holy_light = spells_db.get(48782);
        pub const sacred_shield = spells_db.get(53601);
        pub const divine_plea = spells_db.get(54428);
    };
    pub const resources = struct {};
    pub const divine_plea_mana_pct: u32 = 75;
};

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    _ = bot;
    _ = world;
    return .none;
}

pub fn maintenance(ctx: *const CombatContext) Action {
    if (beaconTarget(ctx)) |target_guid| {
        return .{ .cast_target_instant = .{
            .spell_id = data.spells.beacon_of_light.spell_id,
            .target_guid = target_guid,
        } };
    }

    if (primaryTank(ctx)) |tank_guid| {
        const scan = world_query.scanForGuidOnMap(ctx.world, tank_guid, ctx.bot.state.map_id) orelse return .none;
        if (!hasAuraFromCaster(scan, data.spells.sacred_shield.spell_id, ctx.bot.state.guid)) {
            return .{ .cast_target_instant = .{
                .spell_id = data.spells.sacred_shield.spell_id,
                .target_guid = tank_guid,
            } };
        }
    }

    if (ctx.manaPct()) |mana_pct| {
        if (mana_pct < data.divine_plea_mana_pct and
            ctx.auraOnSelf(data.spells.divine_plea.spell_id) == null and
            ctx.spellReady(data.spells.divine_plea.spell_id))
        {
            return .{ .cast_instant = data.spells.divine_plea.spell_id };
        }
    }

    return .none;
}

fn beaconTarget(ctx: *const CombatContext) ?u64 {
    if (assignedBeaconTarget(ctx)) |guid| return guid;

    var first_tank: ?u64 = null;
    for (ctx.bots) |ally| {
        if (ally.state.map_id != ctx.bot.state.map_id) continue;
        if (ally.state.guid == 0 or ally.state.guid == ctx.bot.state.guid) continue;
        if (role_mod.roleForBot(ally) != .tank) continue;
        const scan = world_query.scanForGuidOnMap(ctx.world, ally.state.guid, ctx.bot.state.map_id) orelse continue;
        if (scan.hp == 0) continue;
        if (hasAuraFromCaster(scan, data.spells.beacon_of_light.spell_id, ctx.bot.state.guid)) return null;
        if (first_tank == null) first_tank = ally.state.guid;
    }
    return first_tank;
}

fn assignedBeaconTarget(ctx: *const CombatContext) ?u64 {
    const target_guid = if (ctx.assigned_tank_guid != 0) ctx.assigned_tank_guid else return null;
    if (!eligibleAliveTank(ctx, target_guid)) return null;
    if (tankHasBeaconFrom(ctx, target_guid)) return null;
    return target_guid;
}

fn eligibleAliveTank(ctx: *const CombatContext, guid: u64) bool {
    for (ctx.bots) |ally| {
        if (ally.state.guid != guid) continue;
        if (ally.state.map_id != ctx.bot.state.map_id) return false;
        if (role_mod.roleForBot(ally) != .tank) return false;
        const scan = world_query.scanForGuidOnMap(ctx.world, guid, ctx.bot.state.map_id) orelse return false;
        return scan.hp > 0;
    }
    return false;
}

fn tankHasBeaconFrom(ctx: *const CombatContext, tank_guid: u64) bool {
    const scan = world_query.scanForGuidOnMap(ctx.world, tank_guid, ctx.bot.state.map_id) orelse return false;
    return hasAuraFromCaster(scan, data.spells.beacon_of_light.spell_id, ctx.bot.state.guid);
}

fn primaryTank(ctx: *const CombatContext) ?u64 {
    if (ctx.assigned_tank_guid != 0 and eligibleAliveTank(ctx, ctx.assigned_tank_guid)) {
        return ctx.assigned_tank_guid;
    }
    for (ctx.bots) |ally| {
        if (ally.state.map_id != ctx.bot.state.map_id) continue;
        if (ally.state.guid == 0 or ally.state.guid == ctx.bot.state.guid) continue;
        if (role_mod.roleForBot(ally) != .tank) continue;
        const scan = world_query.scanForGuidOnMap(ctx.world, ally.state.guid, ctx.bot.state.map_id) orelse continue;
        if (scan.hp == 0) continue;
        return ally.state.guid;
    }
    return null;
}

fn hasAuraFromCaster(scan: proto.ScanEntry, spell_id: u32, caster_guid: u64) bool {
    const n = @min(scan.aura_count, scan.auras.len);
    for (scan.auras[0..n]) |aura| {
        if (aura.spell_id == spell_id and aura.caster_guid == caster_guid) return true;
    }
    return false;
}

test "maintenance: thaddius twins beacon follows platform tank after swap" {
    const std = @import("std");
    thaddius_state.reset();
    defer thaddius_state.reset();

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 533;
    healer.state.class = @intFromEnum(class_spec.Class.paladin);
    healer.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var tank_a: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank_a.bot_id[0] = 2;
    tank_a.state.guid = 0x200;
    tank_a.state.map_id = 533;
    tank_a.state.class = @intFromEnum(class_spec.Class.paladin);
    tank_a.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };

    var tank_b = tank_a;
    tank_b.bot_id = std.mem.zeroes([32]u8);
    tank_b.bot_id[0] = 3;
    tank_b.state.guid = 0x300;

    thaddius_state.beginTankRefresh();
    thaddius_state.refreshTank(tank_a.bot_id, tank_a.state.guid, "tankA", .left);
    thaddius_state.refreshTank(tank_b.bot_id, tank_b.state.guid, "tankB", .right);
    _ = thaddius_state.findOrInsert(healer.bot_id, .left).?;
    assignments.setAssignedTank(healer.bot_id, tank_a.state.guid);
    _ = thaddius_state.applySwap(54517, 0, healer.state.guid, 1000);

    var scan_a = std.mem.zeroes(proto.ScanEntry);
    scan_a.guid = tank_a.state.guid;
    scan_a.hp = 1000;
    scan_a.hp_max = 1000;
    scan_a.aura_count = 1;
    scan_a.auras[0] = .{ .spell_id = data.spells.beacon_of_light.spell_id, .caster_guid = healer.state.guid, .remaining_ms = 30_000 };

    var scan_b = std.mem.zeroes(proto.ScanEntry);
    scan_b.guid = tank_b.state.guid;
    scan_b.hp = 1000;
    scan_b.hp_max = 1000;

    const bots = [_]BotSnapshot{ healer, tank_a, tank_b };
    const world = [_]WorldSnapshot{
        .{ .scan = scan_a, .map_id = 533, .last_seen_ts_ns = 0 },
        .{ .scan = scan_b, .map_id = 533, .last_seen_ts_ns = 0 },
    };

    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const action = maintenance(&ctx);
    try std.testing.expect(action == .cast_target_instant);
    try std.testing.expectEqual(data.spells.beacon_of_light.spell_id, action.cast_target_instant.spell_id);
    try std.testing.expectEqual(tank_b.state.guid, action.cast_target_instant.target_guid);
}
