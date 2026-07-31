const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../world/memory.zig");
const class_spec = @import("class_spec.zig");
const role_mod = @import("role.zig");
const world_query = @import("world_query.zig");
const encounters = @import("encounters/mod.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;
const BotId = @import("types").BotId;

pub const melee_unsafe_threat_pct: u32 = 90;
pub const ranged_unsafe_threat_pct: u32 = 95;
pub const melee_recover_threat_pct: u32 = 80;
pub const ranged_recover_threat_pct: u32 = 80;

pub const RescueDecision = enum {
    skip_no_holder,
    skip_self_holder,
    skip_no_threat,
    skip_holder_is_tank,
    skip_not_owner,
    rescue,
};

pub const RescueCandidate = struct {
    hostile_guid: u64,
    holder_guid: u64,
    holder_role: role_mod.CombatRole,
    owner_bot_id: BotId,
    owner_threat: u32,
    holder_threat: u32,
    holder_pct: u32,
    decision: RescueDecision,
};

pub fn holderGuid(world: []const WorldSnapshot, hostile_guid: u64) ?u64 {
    const scan = world_query.scanForGuid(world, hostile_guid) orelse return null;
    return if (scan.target_guid != 0) scan.target_guid else null;
}

pub fn threatForGuidOnHostile(bots: []const BotSnapshot, hostile_guid: u64, unit_guid: u64) u32 {
    var best: u32 = 0;
    for (bots) |bot| {
        if (bot.state.target_guid != hostile_guid) continue;
        const n = @min(bot.state.target_threat_count, bot.state.target_threats.len);
        for (bot.state.target_threats[0..n]) |entry| {
            if (entry.unit_guid != unit_guid) continue;
            if (entry.threat > best) best = entry.threat;
        }
        if (bot.state.guid == unit_guid and bot.state.threat_on_target > best) {
            best = bot.state.threat_on_target;
        }
    }
    return best;
}

pub fn tankOwner(bots: []const BotSnapshot, world: []const WorldSnapshot, hostile_guid: u64, map_id: u32) ?BotSnapshot {
    if (encounters.encounterTankOwner(bots, world, hostile_guid, map_id)) |owner| return owner;
    return genericTankOwner(bots, hostile_guid, map_id);
}

pub fn threatPct(bot_threat: u32, owner_threat: u32) u32 {
    if (owner_threat == 0) return 0;
    return @intCast((@as(u64, bot_threat) * 100) / owner_threat);
}

pub fn unsafeThreatForProfile(profile: role_mod.RangeProfile, pct: u32) bool {
    return switch (profile) {
        .melee => pct >= melee_unsafe_threat_pct,
        .caster, .ranged => pct >= ranged_unsafe_threat_pct,
    };
}

pub fn recoveredThreatForProfile(profile: role_mod.RangeProfile, pct: u32) bool {
    return switch (profile) {
        .melee => pct < melee_recover_threat_pct,
        .caster, .ranged => pct < ranged_recover_threat_pct,
    };
}

/// True when at least one bot in the roster has the tank role. When false,
/// threat-management has no anchor (no tank to compare against) and DPS bots
/// must act as their own implicit tank — typical of solo open-world play.
pub fn rosterHasTank(bots: []const BotSnapshot) bool {
    for (bots) |bot| {
        if (role_mod.roleForBot(bot) == .tank) return true;
    }
    return false;
}

pub fn threatPctForBot(bot: BotSnapshot, bots: []const BotSnapshot, world: []const WorldSnapshot, spec: class_spec.Spec) ?u32 {
    const role = role_mod.roleForSpec(spec);
    if (role == .tank or role == .healer) return null;

    const hostile_guid = bot.state.target_guid;
    if (hostile_guid == 0) return null;
    const owner = tankOwner(bots, world, hostile_guid, bot.state.map_id) orelse return null;
    const owner_threat = threatForGuidOnHostile(bots, hostile_guid, owner.state.guid);
    if (owner_threat == 0) return null;
    const bot_threat = threatForGuidOnHostile(bots, hostile_guid, bot.state.guid);
    return threatPct(bot_threat, owner_threat);
}

pub fn threatReadyForBot(bot: BotSnapshot, bots: []const BotSnapshot, world: []const WorldSnapshot, spec: class_spec.Spec) bool {
    const role = role_mod.roleForSpec(spec);
    if (role == .tank or role == .healer) return true;

    const hostile_guid = bot.state.target_guid;
    if (hostile_guid == 0) return false;

    // Threat handoff only makes sense in scripted encounters where a designated
    // tank is supposed to hold aggro for the group. Outside those maps (open
    // world questing, dailies, leveling) the bot acts on its own and must not
    // be gated by the absence of a tank lead — otherwise `threatBlocked` would
    // clear the spec intent every tick and freeze the bot.
    if (!encounters.mapUsesOperatorPrepGate(bot.state.map_id)) return true;

    // Encounter map but no tank present in the roster: same reasoning — no
    // anchor to compare threat against.
    if (!rosterHasTank(bots)) return true;

    const owner = tankOwner(bots, world, hostile_guid, bot.state.map_id) orelse return false;
    return threatForGuidOnHostile(bots, hostile_guid, owner.state.guid) > 0;
}

pub fn highThreat(bot: BotSnapshot, bots: []const BotSnapshot, world: []const WorldSnapshot, spec: class_spec.Spec) bool {
    const role = role_mod.profileForSpec(spec);
    const pct = threatPctForBot(bot, bots, world, spec) orelse return false;
    const unsafe = unsafeThreatForProfile(role, pct);

    if (pct >= 120) {
        const hostile_guid = bot.state.target_guid;
        const owner = tankOwner(bots, world, hostile_guid, bot.state.map_id);
        const owner_threat = if (owner) |o| threatForGuidOnHostile(bots, hostile_guid, o.state.guid) else 0;
        const bot_threat = threatForGuidOnHostile(bots, hostile_guid, bot.state.guid);
        const bot_name = std.mem.sliceTo(&bot.state.player_name, 0);

        std.log.debug("threat_check bot={s} spec={s} role={s} map={} target=0x{x} bot_threat={} owner_threat={} pct={} threshold={} highThreat={}", .{
            bot_name,
            @tagName(spec),
            @tagName(role),
            bot.state.map_id,
            hostile_guid,
            bot_threat,
            owner_threat,
            pct,
            switch (role) {
                .melee => melee_unsafe_threat_pct,
                .caster, .ranged => ranged_unsafe_threat_pct,
            },
            unsafe,
        });
    }

    return unsafe;
}

pub fn recoveredThreat(bot: BotSnapshot, bots: []const BotSnapshot, world: []const WorldSnapshot, spec: class_spec.Spec) bool {
    const pct = threatPctForBot(bot, bots, world, spec) orelse return false;
    return recoveredThreatForProfile(role_mod.profileForSpec(spec), pct);
}

pub fn rescueCandidateForTank(bot: BotSnapshot, bots: []const BotSnapshot, world: []const WorldSnapshot) ?RescueCandidate {
    if (role_mod.roleForBot(bot) != .tank) return null;

    var best: ?RescueCandidate = null;
    for (world) |entry| {
        if (entry.map_id != bot.state.map_id) continue;
        if (entry.scan.hp == 0) continue;
        if (entry.scan.target_guid == 0) continue;

        const candidate = rescueCandidateForHostile(bot, bots, world, entry.scan.guid) orelse continue;
        if (candidate.decision != .rescue) continue;
        if (best == null or rescuePriority(candidate.holder_role) > rescuePriority(best.?.holder_role)) {
            best = candidate;
        }
    }
    return best;
}

fn rescueCandidateForHostile(bot: BotSnapshot, bots: []const BotSnapshot, world: []const WorldSnapshot, hostile_guid: u64) ?RescueCandidate {
    const hostile_holder = holderGuid(world, hostile_guid) orelse return .{
        .hostile_guid = hostile_guid,
        .holder_guid = 0,
        .holder_role = .ranged_dps,
        .owner_bot_id = bot.bot_id,
        .owner_threat = 0,
        .holder_threat = 0,
        .holder_pct = 0,
        .decision = .skip_no_holder,
    };
    if (hostile_holder == hostile_guid) return .{
        .hostile_guid = hostile_guid,
        .holder_guid = hostile_holder,
        .holder_role = .ranged_dps,
        .owner_bot_id = bot.bot_id,
        .owner_threat = 0,
        .holder_threat = 0,
        .holder_pct = 0,
        .decision = .skip_self_holder,
    };
    const holder = registry_mod.botForGuid(bots, hostile_holder) orelse return null;
    const holder_role = role_mod.roleForBot(holder);
    const owner = tankOwner(bots, world, hostile_guid, bot.state.map_id) orelse return null;
    const owner_threat = threatForGuidOnHostile(bots, hostile_guid, owner.state.guid);
    const holder_threat = threatForGuidOnHostile(bots, hostile_guid, holder.state.guid);
    const pct = threatPct(holder_threat, owner_threat);

    var decision: RescueDecision = .rescue;
    if (owner_threat == 0 and holder_threat == 0) {
        decision = .skip_no_threat;
    } else if (holder_role == .tank) {
        decision = .skip_holder_is_tank;
    } else if (!std.mem.eql(u8, &owner.bot_id, &bot.bot_id)) {
        decision = .skip_not_owner;
    }

    return .{
        .hostile_guid = hostile_guid,
        .holder_guid = hostile_holder,
        .holder_role = holder_role,
        .owner_bot_id = owner.bot_id,
        .owner_threat = owner_threat,
        .holder_threat = holder_threat,
        .holder_pct = pct,
        .decision = decision,
    };
}

fn rescuePriority(role: role_mod.CombatRole) u8 {
    return switch (role) {
        .healer => 2,
        .melee_dps, .ranged_dps => 1,
        .tank => 0,
    };
}

fn genericTankOwner(bots: []const BotSnapshot, hostile_guid: u64, map_id: u32) ?BotSnapshot {
    var best: ?BotSnapshot = null;
    var best_threat: u32 = 0;
    for (bots) |bot| {
        if (bot.state.map_id != map_id) continue;
        if (role_mod.roleForBot(bot) != .tank) continue;
        const t = threatForGuidOnHostile(bots, hostile_guid, bot.state.guid);
        if (best == null or t > best_threat) {
            best = bot;
            best_threat = t;
        }
    }
    return best;
}

test "threatReadyForBot: open world bypasses threat gate" {
    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.state.guid = 0xd05;
    dps.state.target_guid = 0xabc;
    dps.state.map_id = 1; // Kalimdor (any non-encounter map)
    dps.state.class = @intFromEnum(class_spec.Class.warrior);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    // Solo open world.
    const bots_solo = [_]BotSnapshot{dps};
    try std.testing.expect(threatReadyForBot(dps, &bots_solo, &.{}, .arms));

    // Even with a tank present in the roster, open world questing should not
    // be threat-gated — the tank may be off doing something else.
    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.state.guid = 0xaaa;
    tank.state.target_guid = 0xabc;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    const bots_team_open_world = [_]BotSnapshot{ dps, tank };
    try std.testing.expect(threatReadyForBot(dps, &bots_team_open_world, &.{}, .arms));
}

test "threatReadyForBot: encounter map without tank still bypasses" {
    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.state.guid = 0xd05;
    dps.state.target_guid = 0xabc;
    dps.state.map_id = encounters.thaddius_map_id;
    dps.state.class = @intFromEnum(class_spec.Class.warrior);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    const bots_solo = [_]BotSnapshot{dps};
    try std.testing.expect(threatReadyForBot(dps, &bots_solo, &.{}, .arms));
}

test "threatReadyForBot: encounter map with tank gates DPS until tank has threat" {
    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.state.guid = 0xd05;
    dps.state.target_guid = 0xabc;
    dps.state.map_id = encounters.thaddius_map_id;
    dps.state.class = @intFromEnum(class_spec.Class.warrior);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.state.guid = 0xaaa;
    tank.state.target_guid = 0xabc;
    tank.state.map_id = encounters.thaddius_map_id;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    const bots_team = [_]BotSnapshot{ dps, tank };
    // Tank present but no threat established yet → DPS must hold.
    try std.testing.expect(!threatReadyForBot(dps, &bots_team, &.{}, .arms));
}

test "highThreat uses conservative melee threshold against tank owner" {
    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.state.guid = 0xd05;
    dps.state.target_guid = 0xabc;
    dps.state.class = @intFromEnum(class_spec.Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.target_threat_count = 2;
    dps.state.target_threats[0] = .{ .unit_guid = 0xd05, .threat = melee_unsafe_threat_pct * 10 };
    dps.state.target_threats[1] = .{ .unit_guid = 0xaaa, .threat = 1000 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.state.guid = 0xaaa;
    tank.state.target_guid = 0xabc;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    const bots = [_]BotSnapshot{ dps, tank };
    try std.testing.expect(highThreat(dps, &bots, &.{}, .assassination));

    dps.state.target_threats[0].threat = melee_unsafe_threat_pct * 10 - 1;
    const safe_bots = [_]BotSnapshot{ dps, tank };
    try std.testing.expect(!highThreat(dps, &safe_bots, &.{}, .assassination));
}

test "highThreat uses conservative ranged threshold against tank owner" {
    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.state.guid = 0xd06;
    dps.state.target_guid = 0xabc;
    dps.state.class = @intFromEnum(class_spec.Class.hunter);
    dps.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    dps.state.target_threat_count = 2;
    dps.state.target_threats[0] = .{ .unit_guid = 0xd06, .threat = ranged_unsafe_threat_pct * 10 };
    dps.state.target_threats[1] = .{ .unit_guid = 0xaaa, .threat = 1000 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.state.guid = 0xaaa;
    tank.state.target_guid = 0xabc;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    const bots = [_]BotSnapshot{ dps, tank };
    try std.testing.expect(highThreat(dps, &bots, &.{}, .survival));

    dps.state.target_threats[0].threat = ranged_unsafe_threat_pct * 10 - 1;
    const safe_bots = [_]BotSnapshot{ dps, tank };
    try std.testing.expect(!highThreat(dps, &safe_bots, &.{}, .survival));
}

test "rescueCandidateForTank prefers healer holder" {
    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id[0] = 1;
    tank.state.guid = 0x100;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    tank.state.target_guid = 0xabc;
    tank.state.target_threat_count = 2;
    tank.state.target_threats[0] = .{ .unit_guid = tank.state.guid, .threat = 1000 };
    tank.state.target_threats[1] = .{ .unit_guid = 0x200, .threat = 900 };

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 2;
    healer.state.guid = 0x200;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.priest);
    healer.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.target_guid = healer.state.guid;

    const bots = [_]BotSnapshot{ tank, healer };
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const candidate = rescueCandidateForTank(tank, &bots, &world).?;
    try std.testing.expectEqual(RescueDecision.rescue, candidate.decision);
    try std.testing.expectEqual(scan.guid, candidate.hostile_guid);
}

test "rescueCandidateForTank skips invalid self-holder scan" {
    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id[0] = 1;
    tank.state.guid = 0x100;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.paladin);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xc;
    scan.hp = 1000;
    scan.target_guid = scan.guid;

    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    try std.testing.expect(rescueCandidateForTank(tank, &.{tank}, &world) == null);
}

test "rescueCandidateForTank skips empty owner and holder threat" {
    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id[0] = 1;
    tank.state.guid = 0x100;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.paladin);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };

    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.bot_id[0] = 2;
    dps.state.guid = 0x200;
    dps.state.map_id = 1;
    dps.state.class = @intFromEnum(class_spec.Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.target_guid = dps.state.guid;

    const bots = [_]BotSnapshot{ tank, dps };
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    try std.testing.expect(rescueCandidateForTank(tank, &bots, &world) == null);
}

test "thaddius twins only side owner rescues its twin" {
    const thaddius_state = @import("encounters/thaddius/state.zig");
    thaddius_state.reset();
    defer thaddius_state.reset();

    var left_tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    left_tank.bot_id[0] = 1;
    left_tank.state.guid = 0x100;
    left_tank.state.map_id = 533;
    left_tank.state.class = @intFromEnum(class_spec.Class.paladin);
    left_tank.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    left_tank.state.target_guid = 0xaaa;
    left_tank.state.target_threat_count = 3;
    left_tank.state.target_threats[0] = .{ .unit_guid = left_tank.state.guid, .threat = 1000 };
    left_tank.state.target_threats[1] = .{ .unit_guid = 0x200, .threat = 5000 };
    left_tank.state.target_threats[2] = .{ .unit_guid = 0x300, .threat = 900 };

    var right_tank = left_tank;
    right_tank.bot_id = std.mem.zeroes(BotId);
    right_tank.bot_id[0] = 2;
    right_tank.state.guid = 0x200;

    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.bot_id[0] = 3;
    dps.state.guid = 0x300;
    dps.state.map_id = 533;
    dps.state.class = @intFromEnum(class_spec.Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    thaddius_state.beginTankRefresh();
    thaddius_state.refreshTank(left_tank.bot_id, left_tank.state.guid, "left", .left);
    thaddius_state.refreshTank(right_tank.bot_id, right_tank.state.guid, "right", .right);

    var stalagg = std.mem.zeroes(proto.ScanEntry);
    stalagg.guid = 0xaaa;
    stalagg.hp = 1000;
    stalagg.target_guid = dps.state.guid;
    std.mem.copyForwards(u8, stalagg.name[0.."Stalagg".len], "Stalagg");

    const bots = [_]BotSnapshot{ left_tank, right_tank, dps };
    const world = [_]WorldSnapshot{.{ .scan = stalagg, .map_id = 533, .last_seen_ts_ns = 0 }};

    try std.testing.expectEqual(RescueDecision.rescue, rescueCandidateForTank(left_tank, &bots, &world).?.decision);
    try std.testing.expect(rescueCandidateForTank(right_tank, &bots, &world) == null);
}

test "thaddius phase two chooses highest threat tank owner" {
    var low_tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    low_tank.bot_id[0] = 1;
    low_tank.state.guid = 0x100;
    low_tank.state.map_id = 533;
    low_tank.state.class = @intFromEnum(class_spec.Class.paladin);
    low_tank.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    low_tank.state.target_guid = 0xbbb;
    low_tank.state.target_threat_count = 3;
    low_tank.state.target_threats[0] = .{ .unit_guid = low_tank.state.guid, .threat = 1000 };
    low_tank.state.target_threats[1] = .{ .unit_guid = 0x200, .threat = 2000 };
    low_tank.state.target_threats[2] = .{ .unit_guid = 0x300, .threat = 1500 };

    var high_tank = low_tank;
    high_tank.bot_id = std.mem.zeroes(BotId);
    high_tank.bot_id[0] = 2;
    high_tank.state.guid = 0x200;

    var healer: BotSnapshot = std.mem.zeroes(BotSnapshot);
    healer.bot_id[0] = 3;
    healer.state.guid = 0x300;
    healer.state.map_id = 533;
    healer.state.class = @intFromEnum(class_spec.Class.priest);
    healer.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var thaddius = std.mem.zeroes(proto.ScanEntry);
    thaddius.guid = 0xbbb;
    thaddius.hp = 1000;
    thaddius.target_guid = healer.state.guid;
    std.mem.copyForwards(u8, thaddius.name[0.."Thaddius".len], "Thaddius");

    const bots = [_]BotSnapshot{ low_tank, high_tank, healer };
    const world = [_]WorldSnapshot{.{ .scan = thaddius, .map_id = 533, .last_seen_ts_ns = 0 }};

    try std.testing.expect(rescueCandidateForTank(low_tank, &bots, &world) == null);
    try std.testing.expectEqual(RescueDecision.rescue, rescueCandidateForTank(high_tank, &bots, &world).?.decision);
}
