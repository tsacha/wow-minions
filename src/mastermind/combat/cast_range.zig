const registry_mod = @import("registry");
const proto = @import("protocol");
const world_memory_mod = @import("../world/memory.zig");
const class_spec = @import("class_spec.zig");
const Action = @import("action.zig").Action;
const world_query = @import("world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const CastRangeCheck = struct {
    spell_id: u32,
    target_guid: u64,
    target: proto.ScanEntry,
    dist_yards: f32,
    max_range_yards: f32,
    effective_range_yards: f32,
    in_range: bool,
};

pub const DispatchRangeResult = union(enum) {
    allowed,
    blocked_missing_client_range: CastTarget,
    blocked_out_of_range: CastRangeCheck,
};

pub const CastTarget = struct {
    spell_id: u32,
    target_guid: u64,
};

fn castTargetFromAction(action: Action) ?CastTarget {
    return switch (action) {
        .cast_target => |ct| .{ .spell_id = ct.spell_id, .target_guid = ct.target_guid },
        .cast_target_instant => |ct| .{ .spell_id = ct.spell_id, .target_guid = ct.target_guid },
        else => null,
    };
}

fn distSqToScan(bot: BotSnapshot, scan: proto.ScanEntry) f32 {
    const dx = scan.x - bot.state.x;
    const dy = scan.y - bot.state.y;
    const dz = scan.z - bot.state.z;
    return dx * dx + dy * dy + dz * dz;
}

fn distSqToTarget(bot: BotSnapshot, world: []const WorldSnapshot, target_guid: u64) ?f32 {
    const scan = world_query.scanForGuidOnMap(world, target_guid, bot.state.map_id) orelse return null;
    return distSqToScan(bot, scan);
}

fn clientSpellRange(state: proto.State, spell_id: u32) ?f32 {
    const n = @min(state.spell_range_count, state.spell_ranges.len);
    for (state.spell_ranges[0..n]) |entry| {
        if (entry.spell_id != spell_id) continue;
        if (entry.max_range_yards <= 0) return null;
        return entry.max_range_yards;
    }
    return null;
}

pub fn castRangeCheck(bot: BotSnapshot, world: []const WorldSnapshot, spec: class_spec.Spec, action: Action) ?CastRangeCheck {
    _ = spec;
    const cast_target = castTargetFromAction(action) orelse return null;
    const scan = world_query.scanForGuidOnMap(world, cast_target.target_guid, bot.state.map_id) orelse return null;
    const max_range = clientSpellRange(bot.state, cast_target.spell_id) orelse return null;
    const effective_range = max_range + scan.combat_reach;
    const dist_sq = distSqToScan(bot, scan);

    return .{
        .spell_id = cast_target.spell_id,
        .target_guid = cast_target.target_guid,
        .target = scan,
        .dist_yards = @sqrt(dist_sq),
        .max_range_yards = max_range,
        .effective_range_yards = effective_range,
        .in_range = dist_sq <= effective_range * effective_range,
    };
}

pub fn dispatchRangeResult(bot: BotSnapshot, world: []const WorldSnapshot, spec: class_spec.Spec, action: Action) DispatchRangeResult {
    const cast_target = castTargetFromAction(action) orelse return .allowed;
    if (world_query.scanForGuidOnMap(world, cast_target.target_guid, bot.state.map_id) == null) return .allowed;
    const check = castRangeCheck(bot, world, spec, action) orelse return .{ .blocked_missing_client_range = cast_target };
    return if (check.in_range) .allowed else .{ .blocked_out_of_range = check };
}

pub fn canDispatchAction(bot: BotSnapshot, world: []const WorldSnapshot, spec: class_spec.Spec, action: Action) bool {
    return dispatchRangeResult(bot, world, spec, action) == .allowed;
}

test "canDispatchAction allows non-targeted actions" {
    const std = @import("std");

    const bot = std.mem.zeroes(BotSnapshot);
    try std.testing.expect(canDispatchAction(bot, &.{}, .unknown, .none));
    try std.testing.expect(canDispatchAction(bot, &.{}, .unknown, .{ .cast = 1 }));
    try std.testing.expect(canDispatchAction(bot, &.{}, .unknown, .{ .cast_instant = 1 }));
}

test "castRangeCheck reports targeted cast range" {
    const std = @import("std");

    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.x = 0;
    bot.state.y = 0;
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = 58381, .max_range_yards = 20.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.x = 10;
    scan.y = 0;
    scan.combat_reach = 1.0;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const check = castRangeCheck(bot, &world, .shadow, .{
        .cast_target = .{ .spell_id = 58381, .target_guid = 0xabc },
    }) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u32, 58381), check.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), check.target_guid);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), check.dist_yards, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), check.effective_range_yards, 0.001);
    try std.testing.expect(check.in_range);
}

test "canDispatchAction uses client spell range with target combat reach" {
    const std = @import("std");

    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = 42897, .max_range_yards = 30.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.x = 31.0;
    scan.combat_reach = 1.5;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    try std.testing.expect(canDispatchAction(bot, &world, .arcane, .{
        .cast_target = .{ .spell_id = 42897, .target_guid = 0xabc },
    }));
}

test "canDispatchAction blocks targeted casts when client spell range is missing" {
    const std = @import("std");

    var bot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.x = 100.0;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    try std.testing.expect(!canDispatchAction(bot, &world, .arcane, .{
        .cast_target = .{ .spell_id = 42897, .target_guid = 0xabc },
    }));
}
