const std = @import("std");
const proto = @import("protocol");
const types = @import("types");
const registry_mod = @import("registry");
const world_memory_mod = @import("../world/memory.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldMemory = world_memory_mod.WorldMemory;
const WorldEntry = world_memory_mod.WorldSnapshot;

pub const max_entities: usize = types.max_bots + world_memory_mod.max_tracked;

pub const EntityKind = enum {
    bot,
    object,
};

pub const Entity = struct {
    map_id: u32,
    data: union(EntityKind) {
        bot: proto.State,
        object: proto.ScanEntry,
    },

    pub fn nameSlice(self: *const Entity) []const u8 {
        return switch (self.data) {
            .bot => |*s| std.mem.sliceTo(&s.player_name, 0),
            .object => |*s| std.mem.sliceTo(&s.name, 0),
        };
    }
};

pub const Scratch = struct {
    world_entries: []WorldEntry,
    entities: []Entity,

    pub fn init(allocator: std.mem.Allocator) !Scratch {
        const world_entries = try allocator.alloc(WorldEntry, world_memory_mod.max_tracked);
        errdefer allocator.free(world_entries);

        const entities = try allocator.alloc(Entity, max_entities);
        return .{
            .world_entries = world_entries,
            .entities = entities,
        };
    }

    pub fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        allocator.free(self.entities);
        allocator.free(self.world_entries);
    }

    pub fn collect(self: *Scratch, io: std.Io, world_memory: *WorldMemory, bots: []const BotSnapshot) []const Entity {
        const world_n = world_memory.snapshot(io, self.world_entries);
        return collectEntities(bots, self.world_entries[0..world_n], self.entities);
    }
};

pub fn collectEntities(bots: []const BotSnapshot, world_entries: []const WorldEntry, out: []Entity) []const Entity {
    var n: usize = 0;

    for (bots) |bot| {
        if (n == out.len) return out[0..n];
        if (bot.state.x == 0.0 and bot.state.y == 0.0) continue;

        out[n] = .{
            .map_id = bot.state.map_id,
            .data = .{ .bot = bot.state },
        };
        n += 1;
    }

    for (world_entries) |entry| {
        if (n == out.len) return out[0..n];
        if (entry.scan.x == 0.0 and entry.scan.y == 0.0) continue;
        if (isBotGuid(bots, entry.scan.guid)) continue;

        out[n] = .{
            .map_id = entry.map_id,
            .data = .{ .object = entry.scan },
        };
        n += 1;
    }

    return out[0..n];
}

fn isBotGuid(bots: []const BotSnapshot, guid: u64) bool {
    for (bots) |bot| {
        if (bot.state.guid == guid) return true;
    }
    return false;
}

test "collectEntities builds scene entities" {
    var state = std.mem.zeroes(proto.State);
    state.guid = 42;
    state.x = 10.0;
    state.y = 20.0;
    state.class = 8;
    state.map_id = 571;
    @memcpy(state.player_name[0..4], "Mage");

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 84;
    scan.x = 30.0;
    scan.y = 40.0;
    scan.obj_type = 3;
    @memcpy(scan.name[0..3], "Mob");

    const bots = [_]BotSnapshot{.{
        .bot_id = std.mem.zeroes(types.BotId),
        .state = state,
    }};
    const world_entries = [_]WorldEntry{.{
        .scan = scan,
        .map_id = 571,
        .last_seen_ts_ns = 1,
    }};

    var out: [2]Entity = undefined;
    const entities = collectEntities(&bots, &world_entries, &out);

    try std.testing.expectEqual(@as(usize, 2), entities.len);
    try std.testing.expectEqual(EntityKind.bot, @as(EntityKind, entities[0].data));
    try std.testing.expectEqualStrings("Mage", entities[0].nameSlice());
    try std.testing.expectEqual(EntityKind.object, @as(EntityKind, entities[1].data));
    try std.testing.expectEqualStrings("Mob", entities[1].nameSlice());
}

test "collectEntities deduplicates scanned players present in state" {
    var state = std.mem.zeroes(proto.State);
    state.guid = 42;
    state.x = 10.0;
    state.y = 20.0;
    state.class = 8;
    state.map_id = 571;
    @memcpy(state.player_name[0..4], "Mage");

    // A scan entry with the same GUID as the bot — this duplicate must be
    // dropped so the entity list stays lean and the state (fresher) wins.
    var scan_duplicate = std.mem.zeroes(proto.ScanEntry);
    scan_duplicate.guid = 42;
    scan_duplicate.x = 11.0;
    scan_duplicate.y = 21.0;
    scan_duplicate.obj_type = 4; // player
    @memcpy(scan_duplicate.name[0..7], "Scanned");

    var scan_other = std.mem.zeroes(proto.ScanEntry);
    scan_other.guid = 99;
    scan_other.x = 50.0;
    scan_other.y = 60.0;
    scan_other.obj_type = 3;
    @memcpy(scan_other.name[0..3], "Mob");

    const bots = [_]BotSnapshot{.{
        .bot_id = std.mem.zeroes(types.BotId),
        .state = state,
    }};
    const world_entries = [_]WorldEntry{
        .{
            .scan = scan_duplicate,
            .map_id = 571,
            .last_seen_ts_ns = 1,
        },
        .{
            .scan = scan_other,
            .map_id = 571,
            .last_seen_ts_ns = 2,
        },
    };

    var out: [3]Entity = undefined;
    const entities = collectEntities(&bots, &world_entries, &out);

    try std.testing.expectEqual(@as(usize, 2), entities.len);
    try std.testing.expectEqual(EntityKind.bot, @as(EntityKind, entities[0].data));
    try std.testing.expectEqualStrings("Mage", entities[0].nameSlice());
    // The duplicate scan entry (guid 42) is dropped; the unrelated mob is kept.
    try std.testing.expectEqual(EntityKind.object, @as(EntityKind, entities[1].data));
    try std.testing.expectEqualStrings("Mob", entities[1].nameSlice());
}
