//! Sousbois (Groupe 5). Roster : assets/setup.md

const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const class_spec = @import("../class_spec.zig");
const context = @import("../context.zig");
const spells_db = @import("../spells.zig");
const world_query = @import("../world_query.zig");
const Action = @import("../action.zig").Action;

const BotSnapshot = registry_mod.BotSnapshot;
const CombatContext = context.CombatContext;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

const wild_growth_min_injured_allies: u32 = 3;
const swiftmend_hp_ratio: f32 = 0.40;
const regrowth_hp_ratio: f32 = 0.60;
const emergency_ht_hp_ratio: f32 = 0.25;
const lifebloom_hp_ratio: f32 = 0.70;
const clearcasting_spell_id: u32 = 16870;

pub const data = struct {
    pub const spells = struct {
        pub const rejuvenation = spells_db.get(48441);
        pub const healing_touch = spells_db.get(48443);
        pub const wild_growth = spells_db.get(53251);
        pub const lifebloom = spells_db.get(33763);
        pub const regrowth = spells_db.get(48438);
        pub const nourish = spells_db.get(50464);
        pub const swiftmend = spells_db.get(18562);
        pub const nature_swiftness = spells_db.get(17116);
        pub const tranquility = spells_db.get(48447);
        pub const tree_of_life = spells_db.get(33891);
        pub const gift_of_the_wild = spells_db.get(48470);
    };
    pub const resources = struct {};
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.gift_of_the_wild.spell_id };
}

pub fn maintenance(ctx: *const CombatContext) Action {
    const target = ctx.heal_priority orelse return .none;

    if (target.hp_ratio <= swiftmend_hp_ratio and targetHasAuraFromSelf(ctx, target.guid, data.spells.rejuvenation.spell_id)) {
        if (ctx.spellReady(data.spells.swiftmend.spell_id)) {
            return .{ .cast_target_instant = .{
                .spell_id = data.spells.swiftmend.spell_id,
                .target_guid = target.guid,
            } };
        }
    }

    if (target.hp_ratio <= lifebloom_hp_ratio and ctx.auraOnSelf(clearcasting_spell_id) != null and
        ctx.spellReady(data.spells.lifebloom.spell_id))
    {
        return .{ .cast_target_instant = .{
            .spell_id = data.spells.lifebloom.spell_id,
            .target_guid = target.guid,
        } };
    }

    if (target.hp_ratio <= emergency_ht_hp_ratio and
        ctx.spellReady(data.spells.nature_swiftness.spell_id) and
        ctx.spellReady(data.spells.healing_touch.spell_id))
    {
        return .{ .cast_instant = data.spells.nature_swiftness.spell_id };
    }

    if (target.hp_ratio <= regrowth_hp_ratio and
        countInjuredAllies(ctx, data.spells.wild_growth.range_yards) < wild_growth_min_injured_allies and
        ctx.spellReady(data.spells.regrowth.spell_id))
    {
        return .{ .cast_target_instant = .{
            .spell_id = data.spells.regrowth.spell_id,
            .target_guid = target.guid,
        } };
    }

    if (countInjuredAllies(ctx, data.spells.wild_growth.range_yards) >= wild_growth_min_injured_allies and
        ctx.spellReady(data.spells.wild_growth.spell_id))
    {
        return .{ .cast_target_instant = .{
            .spell_id = data.spells.wild_growth.spell_id,
            .target_guid = target.guid,
        } };
    }

    return .none;
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!proto.hasUnitFlag(bot.state.unit_flags, .in_combat) and
        !selfHasAura(bot.state, data.spells.tree_of_life.spell_id))
    {
        return .{ .cast_instant = data.spells.tree_of_life.spell_id };
    }

    _ = world;
    return .none;
}

fn countInjuredAllies(ctx: *const CombatContext, range_yards: f32) u32 {
    var count: u32 = 0;
    const max_range_sq = range_yards * range_yards;

    for (ctx.bots) |ally| {
        if (ally.state.map_id != ctx.bot.state.map_id) continue;
        if (ally.state.guid == 0 or ally.state.guid == ctx.bot.state.guid) continue;
        const scan = world_query.scanForGuidOnMap(ctx.world, ally.state.guid, ctx.bot.state.map_id) orelse continue;
        if (scan.hp == 0) continue;
        const hp_max = if (scan.hp_max == 0) 1 else scan.hp_max;
        if (@as(f32, @floatFromInt(scan.hp)) / @as(f32, @floatFromInt(hp_max)) >= 1.0) continue;

        const dx = scan.x - ctx.bot.state.x;
        const dy = scan.y - ctx.bot.state.y;
        const dz = scan.z - ctx.bot.state.z;
        if (dx * dx + dy * dy + dz * dz > max_range_sq) continue;
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

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

test "maintenance: swiftmend lowest injured raid target when rejuvenation is present" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.druid);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    healer.state.spell_range_count = 2;
    healer.state.spell_ranges[0] = .{ .spell_id = data.spells.swiftmend.spell_id, .max_range_yards = 40.0 };
    healer.state.spell_ranges[1] = .{ .spell_id = data.spells.rejuvenation.spell_id, .max_range_yards = 40.0 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id[0] = 2;
    tank.state.guid = 0x200;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var raid: [3]BotSnapshot = .{ healer, tank, tank };
    raid[2].state.guid = 0x300;
    raid[2].state.class = @intFromEnum(class_spec.Class.rogue);

    var tank_scan = std.mem.zeroes(proto.ScanEntry);
    tank_scan.guid = tank.state.guid;
    tank_scan.hp = 350;
    tank_scan.hp_max = 1000;
    tank_scan.aura_count = 1;
    tank_scan.auras[0] = .{ .spell_id = data.spells.rejuvenation.spell_id, .caster_guid = healer.state.guid, .remaining_ms = 8_000 };

    var rogue_scan = std.mem.zeroes(proto.ScanEntry);
    rogue_scan.guid = raid[2].state.guid;
    rogue_scan.hp = 900;
    rogue_scan.hp_max = 1000;

    const world = [_]WorldSnapshot{
        .{ .scan = tank_scan, .map_id = 1, .last_seen_ts_ns = 0 },
        .{ .scan = rogue_scan, .map_id = 1, .last_seen_ts_ns = 0 },
    };
    const ctx = CombatContext.build(healer, &raid, &world, &.{}, true);
    const action = maintenance(&ctx);
    try std.testing.expect(action == .cast_target_instant);
    try std.testing.expectEqual(data.spells.swiftmend.spell_id, action.cast_target_instant.spell_id);
    try std.testing.expectEqual(tank.state.guid, action.cast_target_instant.target_guid);
}

test "maintenance: wild growth when enough allies are injured" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.druid);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    healer.state.spell_range_count = 1;
    healer.state.spell_ranges[0] = .{ .spell_id = data.spells.wild_growth.spell_id, .max_range_yards = 40.0 };

    var ally1: BotSnapshot = std.mem.zeroes(BotSnapshot);
    ally1.bot_id[0] = 2;
    ally1.state.guid = 0x200;
    ally1.state.map_id = 1;
    ally1.state.class = @intFromEnum(class_spec.Class.warrior);

    var ally2: BotSnapshot = std.mem.zeroes(BotSnapshot);
    ally2.bot_id[0] = 3;
    ally2.state.guid = 0x300;
    ally2.state.map_id = 1;
    ally2.state.class = @intFromEnum(class_spec.Class.rogue);

    var ally3: BotSnapshot = std.mem.zeroes(BotSnapshot);
    ally3.bot_id[0] = 4;
    ally3.state.guid = 0x400;
    ally3.state.map_id = 1;
    ally3.state.class = @intFromEnum(class_spec.Class.priest);

    var scan1 = std.mem.zeroes(proto.ScanEntry);
    scan1.guid = ally1.state.guid;
    scan1.hp = 600;
    scan1.hp_max = 1000;

    var scan2 = std.mem.zeroes(proto.ScanEntry);
    scan2.guid = ally2.state.guid;
    scan2.hp = 700;
    scan2.hp_max = 1000;

    var scan3 = std.mem.zeroes(proto.ScanEntry);
    scan3.guid = ally3.state.guid;
    scan3.hp = 500;
    scan3.hp_max = 1000;

    const bots = [_]BotSnapshot{ healer, ally1, ally2, ally3 };
    const world = [_]WorldSnapshot{
        .{ .scan = scan1, .map_id = 1, .last_seen_ts_ns = 0 },
        .{ .scan = scan2, .map_id = 1, .last_seen_ts_ns = 0 },
        .{ .scan = scan3, .map_id = 1, .last_seen_ts_ns = 0 },
    };
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const action = maintenance(&ctx);
    try std.testing.expect(action == .cast_target_instant);
    try std.testing.expectEqual(data.spells.wild_growth.spell_id, action.cast_target_instant.spell_id);
}

test "maintenance: nature's swiftness when emergency heal is needed" {
    const std = @import("std");

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.druid);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    healer.state.spell_range_count = 2;
    healer.state.spell_ranges[0] = .{ .spell_id = data.spells.nature_swiftness.spell_id, .max_range_yards = 0.0 };
    healer.state.spell_ranges[1] = .{ .spell_id = data.spells.healing_touch.spell_id, .max_range_yards = 40.0 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id[0] = 2;
    tank.state.guid = 0x200;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    const bots = [_]BotSnapshot{ healer, tank };

    var tank_scan = std.mem.zeroes(proto.ScanEntry);
    tank_scan.guid = tank.state.guid;
    tank_scan.hp = 150;
    tank_scan.hp_max = 1000;

    const world = [_]WorldSnapshot{.{ .scan = tank_scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const action = maintenance(&ctx);
    try std.testing.expect(action == .cast_instant);
    try std.testing.expectEqual(data.spells.nature_swiftness.spell_id, action.cast_instant);
}
