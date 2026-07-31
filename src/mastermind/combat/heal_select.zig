// Heal target selection, lifted from role.zig.
// CombatContext calls rank() once per healer per tick; the result is cached.

const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../world/memory.zig");
const role_mod = @import("role.zig");
const spec_registry = @import("specs/spec_registry.zig");
const world_query = @import("world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

const heal_threshold_full: f32 = 0.999;
const tank_critical_hp_ratio: f32 = 0.50;
const tank_urgent_hp_ratio: f32 = 0.75;
const tank_active_hp_ratio: f32 = 0.95;
const raid_critical_hp_ratio: f32 = 0.25;
const tank_incoming_heal_score_penalty: f32 = 0.12;
const raid_incoming_heal_score_penalty: f32 = 0.18;

pub const HealTarget = struct {
    guid: u64,
    hp_ratio: f32,
    dist_sq: f32,
    is_tank: bool,
};

const HealChoice = struct {
    scan: proto.ScanEntry,
    is_tank: bool,
    priority: u8,
    score: f32,
    hp_ratio: f32,
    dist_sq: f32,
};

fn isIncomingHealTarget(bot: BotSnapshot, candidate_guid: u64) bool {
    if (candidate_guid == 0) return false;
    if (bot.state.target_guid != candidate_guid) return false;
    if (bot.state.is_casting != 0) return isKnownHealSpell(bot.state.casting_spell_id);
    if (bot.state.is_channeling != 0) return isKnownHealSpell(bot.state.channel_spell_id);
    return false;
}

fn countIncomingHeals(bots: []const BotSnapshot, candidate_guid: u64, self_guid: u64) u32 {
    var count: u32 = 0;
    for (bots) |other| {
        if (other.state.guid == self_guid) continue;
        if (role_mod.roleForBot(other) != .healer) continue;
        if (!isIncomingHealTarget(other, candidate_guid)) continue;
        count += 1;
    }
    return count;
}

fn isKnownHealSpell(spell_id: u32) bool {
    return switch (spell_id) {
        18562, // Swiftmend
        32594, // Earth Shield
        33076, // Prayer of Mending
        33763, // Lifebloom
        53007, // Penance
        48447, // Tranquility
        48066, // Power Word: Shield
        48068, // Renew
        48071, // Flash Heal
        48072, // Greater Heal
        48438, // Regrowth
        48441, // Rejuvenation
        48443, // Healing Touch
        48782, // Holy Light
        48785, // Flash of Light
        49273, // Healing Wave
        49276, // Lesser Healing Wave
        50464, // Nourish
        53251, // Wild Growth
        53563, // Beacon of Light
        55459, // Chain Heal
        61299, // Riptide
        64843, // Divine Hymn
        => true,
        else => false,
    };
}

fn priorityFor(policy: spec_registry.HealPolicy, is_tank: bool, hp_ratio: f32) u8 {
    if (is_tank) {
        if (hp_ratio < tank_critical_hp_ratio) return 0;
        return switch (policy) {
            .tank_primary => if (hp_ratio < tank_active_hp_ratio) 0 else 2,
            .tank_support => if (hp_ratio < tank_urgent_hp_ratio) 0 else if (hp_ratio < tank_active_hp_ratio) 1 else 2,
            .raid_primary => if (hp_ratio < tank_urgent_hp_ratio) 1 else 3,
        };
    }

    return switch (policy) {
        .raid_primary => if (hp_ratio < raid_critical_hp_ratio) 0 else 2,
        .tank_primary, .tank_support => 2,
    };
}

fn betterChoice(candidate: HealChoice, current: ?HealChoice) bool {
    const existing = current orelse return true;
    if (candidate.priority != existing.priority) return candidate.priority < existing.priority;
    if (candidate.score != existing.score) return candidate.score < existing.score;
    if (candidate.hp_ratio != existing.hp_ratio) return candidate.hp_ratio < existing.hp_ratio;
    return candidate.dist_sq < existing.dist_sq;
}

fn incomingHealScorePenalty(is_tank: bool) f32 {
    return if (is_tank) tank_incoming_heal_score_penalty else raid_incoming_heal_score_penalty;
}

/// Returns the best heal candidate among bots, using healer policy, HP, and incoming-heal pressure.
/// Returns null when no one needs healing.
pub fn rank(
    bot: BotSnapshot,
    bots: []const BotSnapshot,
    world: []const WorldSnapshot,
    max_range_yards: f32,
    policy: spec_registry.HealPolicy,
) ?HealTarget {
    var best: ?HealChoice = null;
    const max_range_sq = max_range_yards * max_range_yards;

    for (bots) |ally| {
        if (ally.state.map_id != bot.state.map_id) continue;
        if (ally.state.guid == 0 or ally.state.guid == bot.state.guid) continue;

        const scan = world_query.scanForGuidOnMap(world, ally.state.guid, bot.state.map_id) orelse continue;

        const dx = scan.x - bot.state.x;
        const dy = scan.y - bot.state.y;
        const dz = scan.z - bot.state.z;
        const dist_sq = dx * dx + dy * dy + dz * dz;
        if (dist_sq > max_range_sq) continue;

        const hp_ratio = if (scan.hp_max == 0) 1.0 else @as(f32, @floatFromInt(scan.hp)) / @as(f32, @floatFromInt(scan.hp_max));
        if (hp_ratio >= heal_threshold_full) continue;

        const is_tank = role_mod.roleForBot(ally) == .tank;
        const priority = priorityFor(policy, is_tank, hp_ratio);
        const incoming_count = countIncomingHeals(bots, ally.state.guid, bot.state.guid);
        const score = hp_ratio + @as(f32, @floatFromInt(incoming_count)) * incomingHealScorePenalty(is_tank);
        const choice = HealChoice{ .scan = scan, .is_tank = is_tank, .priority = priority, .score = score, .hp_ratio = hp_ratio, .dist_sq = dist_sq };
        if (betterChoice(choice, best)) best = choice;
    }

    const winner = best orelse return null;
    return .{ .guid = winner.scan.guid, .hp_ratio = winner.hp_ratio, .dist_sq = winner.dist_sq, .is_tank = winner.is_tank };
}

test "rank: tank primary chooses reachable tank below 95% over injured raid" {
    const std = @import("std");
    const class_spec = @import("class_spec.zig");

    const healer = makeBot(1, 0x100, class_spec.Class.paladin, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 0, 0, 0);
    const tank = makeBot(2, 0x200, class_spec.Class.warrior, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 5, 0, 0);
    const raid = makeBot(3, 0x300, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 4, 0, 0);

    const bots = [_]BotSnapshot{ healer, tank, raid };
    const world = [_]WorldSnapshot{
        worldEntry(tank.state.guid, 890, 1000, 5, 0, 0),
        worldEntry(raid.state.guid, 350, 1000, 4, 0, 0),
    };

    const target = rank(healer, &bots, &world, 40.0, .tank_primary).?;
    try std.testing.expectEqual(tank.state.guid, target.guid);
}

test "rank: tank primary keeps tank priority at 94% over more injured raid" {
    const std = @import("std");
    const class_spec = @import("class_spec.zig");

    const healer = makeBot(1, 0x100, class_spec.Class.paladin, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 0, 0, 0);
    const tank = makeBot(2, 0x200, class_spec.Class.warrior, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 5, 0, 0);
    const raid = makeBot(3, 0x300, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 4, 0, 0);

    const bots = [_]BotSnapshot{ healer, tank, raid };
    const world = [_]WorldSnapshot{
        worldEntry(tank.state.guid, 940, 1000, 5, 0, 0),
        worldEntry(raid.state.guid, 350, 1000, 4, 0, 0),
    };

    const target = rank(healer, &bots, &world, 40.0, .tank_primary).?;
    try std.testing.expectEqual(tank.state.guid, target.guid);
}

test "rank: tank primary releases tank priority once above 95%" {
    const std = @import("std");
    const class_spec = @import("class_spec.zig");

    const healer = makeBot(1, 0x100, class_spec.Class.paladin, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 0, 0, 0);
    const tank = makeBot(2, 0x200, class_spec.Class.warrior, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 5, 0, 0);
    const raid = makeBot(3, 0x300, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 4, 0, 0);

    const bots = [_]BotSnapshot{ healer, tank, raid };
    const world = [_]WorldSnapshot{
        worldEntry(tank.state.guid, 960, 1000, 5, 0, 0),
        worldEntry(raid.state.guid, 350, 1000, 4, 0, 0),
    };

    const target = rank(healer, &bots, &world, 40.0, .tank_primary).?;
    try std.testing.expectEqual(raid.state.guid, target.guid);
}

test "rank: tank support chooses urgent tank over injured raid" {
    const std = @import("std");
    const class_spec = @import("class_spec.zig");

    const healer = makeBot(1, 0x100, class_spec.Class.priest, .{ .tab1 = 30, .tab2 = 30, .tab3 = 0 }, 0, 0, 0);
    const tank = makeBot(2, 0x200, class_spec.Class.warrior, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 5, 0, 0);
    const raid = makeBot(3, 0x300, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 4, 0, 0);
    const bots = [_]BotSnapshot{ healer, tank, raid };
    const world = [_]WorldSnapshot{
        worldEntry(tank.state.guid, 740, 1000, 5, 0, 0),
        worldEntry(raid.state.guid, 300, 1000, 4, 0, 0),
    };

    const target = rank(healer, &bots, &world, 40.0, .tank_support).?;
    try std.testing.expectEqual(tank.state.guid, target.guid);
}

test "rank: raid primary chooses critical reachable tank" {
    const std = @import("std");
    const class_spec = @import("class_spec.zig");

    const healer = makeBot(1, 0x100, class_spec.Class.druid, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 0, 0, 0);
    const tank = makeBot(2, 0x200, class_spec.Class.warrior, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 5, 0, 0);
    const raid = makeBot(3, 0x300, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 4, 0, 0);
    const bots = [_]BotSnapshot{ healer, tank, raid };
    const world = [_]WorldSnapshot{
        worldEntry(tank.state.guid, 490, 1000, 5, 0, 0),
        worldEntry(raid.state.guid, 300, 1000, 4, 0, 0),
    };

    const target = rank(healer, &bots, &world, 40.0, .raid_primary).?;
    try std.testing.expectEqual(tank.state.guid, target.guid);
}

test "rank: unreachable tank is ignored instead of causing heal movement" {
    const std = @import("std");
    const class_spec = @import("class_spec.zig");

    const healer = makeBot(1, 0x100, class_spec.Class.paladin, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 0, 0, 0);
    const tank = makeBot(2, 0x200, class_spec.Class.warrior, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 60, 0, 0);
    const raid = makeBot(3, 0x300, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 4, 0, 0);
    const bots = [_]BotSnapshot{ healer, tank, raid };
    const world = [_]WorldSnapshot{
        worldEntry(tank.state.guid, 100, 1000, 60, 0, 0),
        worldEntry(raid.state.guid, 700, 1000, 4, 0, 0),
    };

    const target = rank(healer, &bots, &world, 40.0, .tank_primary).?;
    try std.testing.expectEqual(raid.state.guid, target.guid);
}

test "rank: incoming heal on tank does not exclude the tank" {
    const std = @import("std");
    const class_spec = @import("class_spec.zig");

    const healer = makeBot(1, 0x100, class_spec.Class.paladin, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 0, 0, 0);
    const tank = makeBot(2, 0x200, class_spec.Class.warrior, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 5, 0, 0);
    var other_healer = makeBot(3, 0x300, class_spec.Class.priest, .{ .tab1 = 30, .tab2 = 30, .tab3 = 0 }, 4, 0, 0);
    const raid = makeBot(4, 0x400, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 4, 0, 0);
    other_healer.state.target_guid = tank.state.guid;
    other_healer.state.is_casting = 1;
    other_healer.state.casting_spell_id = 48071;

    const bots = [_]BotSnapshot{ healer, tank, other_healer, raid };
    const world = [_]WorldSnapshot{
        worldEntry(tank.state.guid, 650, 1000, 5, 0, 0),
        worldEntry(other_healer.state.guid, 1000, 1000, 4, 0, 0),
        worldEntry(raid.state.guid, 300, 1000, 4, 0, 0),
    };

    const target = rank(healer, &bots, &world, 40.0, .tank_primary).?;
    try std.testing.expectEqual(tank.state.guid, target.guid);
}

test "rank: incoming heal penalizes raid target more than tank target" {
    const std = @import("std");
    const class_spec = @import("class_spec.zig");

    const healer = makeBot(1, 0x100, class_spec.Class.druid, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 0, 0, 0);
    const raid_with_incoming = makeBot(2, 0x200, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 5, 0, 0);
    const raid_without_incoming = makeBot(3, 0x300, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 4, 0, 0);
    var other_healer = makeBot(4, 0x400, class_spec.Class.priest, .{ .tab1 = 30, .tab2 = 30, .tab3 = 0 }, 3, 0, 0);
    other_healer.state.target_guid = raid_with_incoming.state.guid;
    other_healer.state.is_casting = 1;
    other_healer.state.casting_spell_id = 48071;

    const bots = [_]BotSnapshot{ healer, raid_with_incoming, raid_without_incoming, other_healer };
    const world = [_]WorldSnapshot{
        worldEntry(raid_with_incoming.state.guid, 500, 1000, 5, 0, 0),
        worldEntry(raid_without_incoming.state.guid, 600, 1000, 4, 0, 0),
        worldEntry(other_healer.state.guid, 1000, 1000, 3, 0, 0),
    };

    const target = rank(healer, &bots, &world, 40.0, .raid_primary).?;
    try std.testing.expectEqual(raid_without_incoming.state.guid, target.guid);
}

test "rank: only healer casts of known heal spells count as incoming heals" {
    const std = @import("std");
    const class_spec = @import("class_spec.zig");

    const healer = makeBot(1, 0x100, class_spec.Class.druid, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 0, 0, 0);
    const raid_with_damage_cast = makeBot(2, 0x200, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 5, 0, 0);
    const raid_with_heal = makeBot(3, 0x300, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 4, 0, 0);
    var damage_caster = makeBot(4, 0x400, class_spec.Class.mage, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 3, 0, 0);
    var other_healer = makeBot(5, 0x500, class_spec.Class.priest, .{ .tab1 = 30, .tab2 = 30, .tab3 = 0 }, 3, 0, 0);
    damage_caster.state.target_guid = raid_with_damage_cast.state.guid;
    damage_caster.state.is_casting = 1;
    damage_caster.state.casting_spell_id = 42891;
    other_healer.state.target_guid = raid_with_heal.state.guid;
    other_healer.state.is_casting = 1;
    other_healer.state.casting_spell_id = 48071;

    const bots = [_]BotSnapshot{ healer, raid_with_damage_cast, raid_with_heal, damage_caster, other_healer };
    const world = [_]WorldSnapshot{
        worldEntry(raid_with_damage_cast.state.guid, 500, 1000, 5, 0, 0),
        worldEntry(raid_with_heal.state.guid, 500, 1000, 4, 0, 0),
        worldEntry(damage_caster.state.guid, 1000, 1000, 3, 0, 0),
        worldEntry(other_healer.state.guid, 1000, 1000, 3, 0, 0),
    };

    const target = rank(healer, &bots, &world, 40.0, .raid_primary).?;
    try std.testing.expectEqual(raid_with_damage_cast.state.guid, target.guid);
}

fn makeBot(
    id: u8,
    guid: u64,
    class: anytype,
    talent_points: proto.TalentPoints,
    x: f32,
    y: f32,
    z: f32,
) BotSnapshot {
    var bot = @import("std").mem.zeroes(BotSnapshot);
    bot.bot_id[0] = id;
    bot.state.bot_id[0] = id;
    bot.state.guid = guid;
    bot.state.map_id = 1;
    bot.state.class = @intFromEnum(class);
    bot.state.talent_points = talent_points;
    bot.state.x = x;
    bot.state.y = y;
    bot.state.z = z;
    return bot;
}

fn worldEntry(guid: u64, hp: u32, hp_max: u32, x: f32, y: f32, z: f32) WorldSnapshot {
    var scan = @import("std").mem.zeroes(proto.ScanEntry);
    scan.guid = guid;
    scan.hp = hp;
    scan.hp_max = hp_max;
    scan.x = x;
    scan.y = y;
    scan.z = z;
    return .{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 };
}
