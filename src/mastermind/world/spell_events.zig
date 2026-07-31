const std = @import("std");
const proto = @import("protocol");

const event_ttl_ns: u64 = 5 * std.time.ns_per_s;
const launch_duplicate_window_ticks: u32 = 2;
const launch_duplicate_window_ms: u32 = proto.brain_tick_ms * launch_duplicate_window_ticks;

pub const capacity: usize = 4096;

const Entry = struct {
    event: proto.SpellEvent,
    received_ts_ns: u64,
};

pub const SpellEventStore = struct {
    mutex: std.Io.Mutex = .init,
    entries: [capacity]Entry = undefined,
    head: usize = 0,
    count: usize = 0,
    log_enabled: bool = false,

    pub fn push(self: *SpellEventStore, io: std.Io, event: proto.SpellEvent, now_ns: u64) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);

        self.pruneLocked(now_ns);
        if (self.containsLocked(event)) return;

        const idx = (self.head + self.count) % capacity;
        self.entries[idx] = .{ .event = event, .received_ts_ns = now_ns };
        if (self.count < capacity) {
            self.count += 1;
        } else {
            self.head = (self.head + 1) % capacity;
        }
    }

    pub fn snapshot(self: *SpellEventStore, io: std.Io, out: []proto.SpellEvent) usize {
        self.mutex.lock(io) catch return 0;
        defer self.mutex.unlock(io);

        const n = @min(self.count, out.len);
        for (0..n) |i| {
            out[i] = self.entries[(self.head + i) % capacity].event;
        }
        return n;
    }

    pub fn prune(self: *SpellEventStore, io: std.Io, now_ns: u64) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);

        self.pruneLocked(now_ns);
    }

    fn containsLocked(self: *const SpellEventStore, event: proto.SpellEvent) bool {
        for (0..self.count) |i| {
            const existing = self.entries[(self.head + i) % capacity].event;
            if (sameStoredEvent(existing, event)) return true;
        }
        return false;
    }

    fn pruneLocked(self: *SpellEventStore, now_ns: u64) void {
        while (self.count > 0) {
            const age_ns = now_ns -| self.entries[self.head].received_ts_ns;
            if (age_ns < event_ttl_ns) break;
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
        }
    }
};

fn launchDuplicateCandidate(event: proto.SpellEvent) bool {
    const kind = std.enums.fromInt(proto.SpellEventKind, event.kind) orelse return false;
    return switch (kind) {
        .start, .go => true,
        .failed, .interrupted, .channel_update, .channel_end => false,
    };
}

fn sameLaunchEvent(a: proto.SpellEvent, b: proto.SpellEvent) bool {
    if (!launchDuplicateCandidate(a) or !launchDuplicateCandidate(b)) return false;
    if (a.kind != b.kind) return false;
    if (a.caster_guid != b.caster_guid) return false;
    if (a.spell_id != b.spell_id) return false;

    const lo = @min(a.game_time_ms, b.game_time_ms);
    const hi = @max(a.game_time_ms, b.game_time_ms);
    return hi - lo <= launch_duplicate_window_ms;
}

fn sameExactEvent(a: proto.SpellEvent, b: proto.SpellEvent) bool {
    return a.kind == b.kind and
        a.caster_guid == b.caster_guid and
        a.spell_id == b.spell_id and
        a.value_ms == b.value_ms and
        a.game_time_ms == b.game_time_ms;
}

fn sameStoredEvent(a: proto.SpellEvent, b: proto.SpellEvent) bool {
    return sameExactEvent(a, b) or sameLaunchEvent(a, b);
}

test "push snapshot and deduplicate" {
    var store: SpellEventStore = .{};
    const event: proto.SpellEvent = .{
        .kind = @intFromEnum(proto.SpellEventKind.go),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x1,
        .caster_guid = 0x2,
        .spell_id = 123,
        .flags = 0x10,
        .value_ms = 456,
        .game_time_ms = 789,
    };

    store.push(std.testing.io, event, 100);
    store.push(std.testing.io, event, 200);

    var out: [capacity]proto.SpellEvent = undefined;
    const n = store.snapshot(std.testing.io, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(event.spell_id, out[0].spell_id);
}

test "push deduplicates launch events inside launch duplicate window" {
    var store: SpellEventStore = .{};
    const first: proto.SpellEvent = .{
        .kind = @intFromEnum(proto.SpellEventKind.go),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x1,
        .caster_guid = 0xCAFE,
        .spell_id = 54517,
        .flags = 0x10,
        .value_ms = 0,
        .game_time_ms = 1000,
    };
    var second = first;
    second.observer_guid = 0x2;
    second.flags = 0x20;
    second.game_time_ms = 1000 + proto.brain_tick_ms + 1;

    store.push(std.testing.io, first, 100);
    store.push(std.testing.io, second, 200);

    var out: [capacity]proto.SpellEvent = undefined;
    const n = store.snapshot(std.testing.io, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(first.game_time_ms, out[0].game_time_ms);
}

test "push keeps launch events outside launch duplicate window" {
    var store: SpellEventStore = .{};
    const first: proto.SpellEvent = .{
        .kind = @intFromEnum(proto.SpellEventKind.go),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x1,
        .caster_guid = 0xCAFE,
        .spell_id = 54517,
        .flags = 0x10,
        .value_ms = 0,
        .game_time_ms = 1000,
    };
    var second = first;
    second.observer_guid = 0x2;
    second.game_time_ms = 1000 + launch_duplicate_window_ms + 1;

    store.push(std.testing.io, first, 100);
    store.push(std.testing.io, second, 200);

    var out: [capacity]proto.SpellEvent = undefined;
    const n = store.snapshot(std.testing.io, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "push does not collapse channel updates by launch window" {
    var store: SpellEventStore = .{};
    const first: proto.SpellEvent = .{
        .kind = @intFromEnum(proto.SpellEventKind.channel_update),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x1,
        .caster_guid = 0xCAFE,
        .spell_id = 12345,
        .flags = 0,
        .value_ms = 1000,
        .game_time_ms = 1000,
    };
    var second = first;
    second.observer_guid = 0x2;
    second.value_ms = 900;
    second.game_time_ms = 1017;

    store.push(std.testing.io, first, 100);
    store.push(std.testing.io, second, 200);

    var out: [capacity]proto.SpellEvent = undefined;
    const n = store.snapshot(std.testing.io, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "prune removes old events" {
    var store: SpellEventStore = .{};
    const event: proto.SpellEvent = .{
        .kind = @intFromEnum(proto.SpellEventKind.start),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x1,
        .caster_guid = 0x2,
        .spell_id = 123,
        .flags = 0,
        .value_ms = 1500,
        .game_time_ms = 10,
    };

    store.push(std.testing.io, event, 0);
    store.prune(std.testing.io, event_ttl_ns);

    var out: [1]proto.SpellEvent = undefined;
    const n = store.snapshot(std.testing.io, &out);
    try std.testing.expectEqual(@as(usize, 0), n);
}
