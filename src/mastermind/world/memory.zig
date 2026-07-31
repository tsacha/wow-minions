const std = @import("std");
const proto = @import("protocol");
const types = @import("types");

// An entry not refreshed within this window is considered gone (dead,
// despawned, or out of every bot's range) and pruned.
const entry_ttl_ns: u64 = 10 * std.time.ns_per_s;
const velocity_min_sample_ns: u64 = 50 * std.time.ns_per_ms;
const velocity_max_sample_ns: u64 = 2 * std.time.ns_per_s;
const ns_per_second_f32: f32 = @floatFromInt(std.time.ns_per_s);

// Worst-case prune scratch size: every connected bot fills its scan slots
// with disjoint guids.
pub const max_tracked: usize = types.max_bots * proto.scan_max_entries;

pub const WorldSnapshot = struct {
    scan: proto.ScanEntry,
    map_id: u32,
    last_seen_ts_ns: u64,
    velocity_x_yards_per_second: f32 = 0.0,
    velocity_y_yards_per_second: f32 = 0.0,
    velocity_z_yards_per_second: f32 = 0.0,
};

// Shared world view fused from every bot's scans, keyed by guid.
// Last-write-wins: the most recent observer of a guid owns its entry.
pub const WorldMemory = struct {
    mutex: std.Io.Mutex = .init,
    map: std.AutoHashMap(u64, WorldSnapshot),

    pub fn init(allocator: std.mem.Allocator) WorldMemory {
        return .{ .map = std.AutoHashMap(u64, WorldSnapshot).init(allocator) };
    }

    pub fn deinit(self: *WorldMemory) void {
        self.map.deinit();
    }

    /// One mutex acquisition per SCAN frame (per-entry upserts contended across recv fibers).
    pub fn upsertScanPayload(self: *WorldMemory, io: std.Io, map_id: u32, ts_ns: u64, entries_payload: []const u8) void {
        const entry_wire_bytes = proto.wireSize(proto.ScanEntry);
        if (entries_payload.len == 0) return;
        if (entries_payload.len % entry_wire_bytes != 0) return;

        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);

        var off: usize = 0;
        while (off < entries_payload.len) : (off += entry_wire_bytes) {
            const entry = proto.readWire(proto.ScanEntry, entries_payload[off..][0..entry_wire_bytes]);
            const result = self.map.getOrPut(entry.guid) catch return;
            const velocity = if (result.found_existing)
                observedVelocity(result.value_ptr.*, map_id, ts_ns, entry)
            else
                Velocity{};
            result.value_ptr.* = .{
                .scan = entry,
                .map_id = map_id,
                .last_seen_ts_ns = ts_ns,
                .velocity_x_yards_per_second = velocity.x,
                .velocity_y_yards_per_second = velocity.y,
                .velocity_z_yards_per_second = velocity.z,
            };
        }
    }

    // AutoHashMap forbids removal during iteration: collect the stale keys
    // in a scratch buffer, then remove them in a second pass.
    pub fn prune(self: *WorldMemory, io: std.Io, now_ns: u64) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);

        var stale: [max_tracked]u64 = undefined;
        var n: usize = 0;

        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (n == stale.len) break;
            const last_seen = kv.value_ptr.*.last_seen_ts_ns;
            const age_ns = now_ns -| last_seen;
            if (age_ns >= entry_ttl_ns) {
                stale[n] = kv.key_ptr.*;
                n += 1;
            }
        }

        for (stale[0..n]) |guid| _ = self.map.remove(guid);
    }

    /// Copy the current fused world view into `out` under a single lock.
    /// Returns the number of entries written; callers can pass a shorter
    /// buffer to take a bounded prefix.
    pub fn snapshot(self: *WorldMemory, io: std.Io, out: []WorldSnapshot) usize {
        self.mutex.lock(io) catch return 0;
        defer self.mutex.unlock(io);

        var n: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (n == out.len) break;
            out[n] = kv.value_ptr.*;
            n += 1;
        }
        return n;
    }
};

const Velocity = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
};

fn observedVelocity(prev: WorldSnapshot, map_id: u32, ts_ns: u64, scan: proto.ScanEntry) Velocity {
    if (prev.map_id != map_id) return .{};

    const dt_ns = ts_ns -| prev.last_seen_ts_ns;
    if (dt_ns < velocity_min_sample_ns or dt_ns > velocity_max_sample_ns) return .{};

    const dt_seconds = @as(f32, @floatFromInt(dt_ns)) / ns_per_second_f32;
    return .{
        .x = (scan.x - prev.scan.x) / dt_seconds,
        .y = (scan.y - prev.scan.y) / dt_seconds,
        .z = (scan.z - prev.scan.z) / dt_seconds,
    };
}

test "prune: no panic when last_seen is after now_ns" {
    var wm = WorldMemory.init(std.testing.allocator);
    defer wm.deinit();

    try wm.map.put(0x42, .{
        .scan = std.mem.zeroes(proto.ScanEntry),
        .map_id = 0,
        .last_seen_ts_ns = std.math.maxInt(u64),
    });

    wm.prune(std.testing.io, 1);
    try std.testing.expect(wm.map.contains(0x42));
}

test "observedVelocity computes yards per second between scan samples" {
    var prev_scan = std.mem.zeroes(proto.ScanEntry);
    prev_scan.x = 10;
    prev_scan.y = 20;
    prev_scan.z = 5;

    var scan = prev_scan;
    scan.x = 15;
    scan.y = 18;
    scan.z = 6;

    const velocity = observedVelocity(.{
        .scan = prev_scan,
        .map_id = 1,
        .last_seen_ts_ns = 1 * std.time.ns_per_s,
    }, 1, 2 * std.time.ns_per_s, scan);

    try std.testing.expectApproxEqAbs(@as(f32, 5.0), velocity.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, -2.0), velocity.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), velocity.z, 0.01);
}
