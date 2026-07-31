const std = @import("std");
const proto = @import("protocol");
const types = @import("types");
const dispatch = @import("dispatch.zig");

pub const BotId = types.BotId;
pub const ActionClass = dispatch.ActionClass;
pub const DispatchThrottleKey = dispatch.DispatchThrottleKey;
pub const debounceMsForClass = dispatch.debounceMsForClass;
pub const hard_stop_quiet_ms = dispatch.hard_stop_quiet_ms;
pub const threat_hold_unknown_ms: u32 = proto.brain_tick_ms * 3;

pub const DispatchThrottleEntry = struct {
    bot_id: BotId,
    key: DispatchThrottleKey,
    not_before_game_time_ms: u32,
};

const ThreatHoldEntry = struct {
    bot_id: BotId,
    hostile_guid: u64,
    active_until_game_time_ms: u32 = 0,
};

// ~16 throttle slots per bot: 6 hardStop classes + several spell/facing/attack entries.
const throttle_capacity = types.max_bots * 16;

pub const DispatchStore = struct {
    throttles: [throttle_capacity]?DispatchThrottleEntry = .{null} ** throttle_capacity,
    threat_holds: [types.max_bots]?ThreatHoldEntry = .{null} ** types.max_bots,

    pub fn dispatchAllowed(self: *DispatchStore, bot_id: BotId, key: DispatchThrottleKey, state: proto.State) bool {
        if (state.game_time_ms == 0) return true;
        for (&self.throttles) |*entry_opt| {
            if (entry_opt.*) |entry| {
                if (!std.mem.eql(u8, &entry.bot_id, &bot_id)) continue;
                if (!entry.key.eql(key)) continue;
                return state.game_time_ms >= entry.not_before_game_time_ms;
            }
        }
        return true;
    }

    pub fn recordDispatch(self: *DispatchStore, bot_id: BotId, key: DispatchThrottleKey, state: proto.State) void {
        if (state.game_time_ms == 0) return;
        const entry = self.findOrInsertThrottle(bot_id, key, state.game_time_ms) orelse return;
        entry.not_before_game_time_ms = state.game_time_ms +| debounceMsForClass(key.class);
    }

    /// Drop in-flight confirmation work and suppress move/attack/facing re-dispatch briefly.
    pub fn hardStop(self: *DispatchStore, bot_id: BotId, game_time_ms: u32) void {
        if (game_time_ms == 0) return;
        const not_before = game_time_ms +| hard_stop_quiet_ms;
        const classes_to_block = [_]ActionClass{
            .move,
            .ctm_stop,
            .start_attack,
            .clear_target,
            .attack_guid,
            .set_facing,
        };
        for (classes_to_block) |cls| {
            const key: DispatchThrottleKey = .{ .class = cls };
            const entry = self.findOrInsertThrottle(bot_id, key, game_time_ms) orelse continue;
            if (entry.not_before_game_time_ms < not_before)
                entry.not_before_game_time_ms = not_before;
        }
    }

    pub fn threatBlocked(self: *DispatchStore, bot_id: BotId, hostile_guid: u64, unsafe: bool, recovered: bool, threat_ready: bool, game_time_ms: u32) bool {
        if (hostile_guid == 0 or game_time_ms == 0) {
            self.clearThreatHold(bot_id);
            return false;
        }

        if (!threat_ready) {
            const entry = self.findOrInsertThreatHold(bot_id) orelse return true;
            entry.* = .{
                .bot_id = bot_id,
                .hostile_guid = hostile_guid,
                .active_until_game_time_ms = game_time_ms +| threat_hold_unknown_ms,
            };
            return true;
        }

        if (unsafe) {
            const entry = self.findOrInsertThreatHold(bot_id) orelse return true;
            entry.* = .{
                .bot_id = bot_id,
                .hostile_guid = hostile_guid,
                .active_until_game_time_ms = game_time_ms +| threat_hold_unknown_ms,
            };
            return true;
        }

        const entry = self.findThreatHold(bot_id) orelse return false;
        if (entry.hostile_guid != hostile_guid) {
            self.clearThreatHold(bot_id);
            return false;
        }
        if (recovered) {
            self.clearThreatHold(bot_id);
            return false;
        }
        self.clearThreatHold(bot_id);
        return false;
    }

    pub fn hasThreatHold(self: *DispatchStore, bot_id: BotId) bool {
        return self.findThreatHold(bot_id) != null;
    }

    pub fn clearThreatHolds(self: *DispatchStore) void {
        for (&self.threat_holds) |*entry_opt| {
            entry_opt.* = null;
        }
    }

    fn findOrInsertThrottle(self: *DispatchStore, bot_id: BotId, key: DispatchThrottleKey, game_time_ms: u32) ?*DispatchThrottleEntry {
        for (&self.throttles) |*entry_opt| {
            if (entry_opt.*) |*entry| {
                if (std.mem.eql(u8, &entry.bot_id, &bot_id) and entry.key.eql(key)) return entry;
            }
        }
        for (&self.throttles) |*entry_opt| {
            if (entry_opt.* == null) {
                entry_opt.* = .{
                    .bot_id = bot_id,
                    .key = key,
                    .not_before_game_time_ms = 0,
                };
                return &entry_opt.*.?;
            }
        }
        // Table full: reclaim the most-stale expired entry. An entry whose window
        // has elapsed (not_before <= now) is indistinguishable from an absent one —
        // dispatchAllowed returns true for both — so reusing it is behavior-neutral
        // and bounds the live table to currently-active debounce windows. Without
        // this, transient `move` keys (one per visited yard cell) fill the table
        // permanently and silently disable every debounce.
        var evict: ?*?DispatchThrottleEntry = null;
        var oldest_not_before: u32 = game_time_ms;
        for (&self.throttles) |*entry_opt| {
            const entry = entry_opt.*.?;
            if (entry.not_before_game_time_ms <= oldest_not_before) {
                oldest_not_before = entry.not_before_game_time_ms;
                evict = entry_opt;
            }
        }
        // All entries are live windows — never clobber one.
        const slot = evict orelse return null;
        slot.* = .{
            .bot_id = bot_id,
            .key = key,
            .not_before_game_time_ms = 0,
        };
        return &slot.*.?;
    }

    fn findThreatHold(self: *DispatchStore, bot_id: BotId) ?*ThreatHoldEntry {
        for (&self.threat_holds) |*entry_opt| {
            if (entry_opt.*) |*entry| {
                if (std.mem.eql(u8, &entry.bot_id, &bot_id)) return entry;
            }
        }
        return null;
    }

    fn findOrInsertThreatHold(self: *DispatchStore, bot_id: BotId) ?*ThreatHoldEntry {
        if (self.findThreatHold(bot_id)) |entry| return entry;
        for (&self.threat_holds) |*entry_opt| {
            if (entry_opt.* == null) {
                entry_opt.* = .{
                    .bot_id = bot_id,
                    .hostile_guid = 0,
                    .active_until_game_time_ms = 0,
                };
                return &entry_opt.*.?;
            }
        }
        return null;
    }

    fn clearThreatHold(self: *DispatchStore, bot_id: BotId) void {
        for (&self.threat_holds) |*entry_opt| {
            if (entry_opt.*) |entry| {
                if (std.mem.eql(u8, &entry.bot_id, &bot_id)) {
                    entry_opt.* = null;
                    return;
                }
            }
        }
    }
};

test "recordDispatch debounces by class" {
    const ctm_stop_debounce_ms = dispatch.ctm_stop_debounce_ms;
    var store: DispatchStore = .{};
    var state = std.mem.zeroes(proto.State);
    state.game_time_ms = 10_000;
    const bot_id = std.mem.zeroes(BotId);

    const stop_key = DispatchThrottleKey{ .class = .ctm_stop };
    try std.testing.expect(store.dispatchAllowed(bot_id, stop_key, state));
    store.recordDispatch(bot_id, stop_key, state);
    try std.testing.expect(!store.dispatchAllowed(bot_id, stop_key, state));

    state.game_time_ms += ctm_stop_debounce_ms;
    try std.testing.expect(store.dispatchAllowed(bot_id, stop_key, state));
}

test "findOrInsertThrottle reclaims an expired slot when the table is full" {
    const move_debounce_ms = dispatch.move_debounce_ms;
    var store: DispatchStore = .{};
    const bot_id = std.mem.zeroes(BotId);
    const fill_time_ms: u32 = 10_000;

    // Fill every slot with a distinct move key (transient yard cells), all
    // recorded at fill_time_ms.
    var state = std.mem.zeroes(proto.State);
    state.game_time_ms = fill_time_ms;
    var i: u32 = 0;
    while (i < throttle_capacity) : (i += 1) {
        store.recordDispatch(bot_id, .{ .class = .move, .qx = @intCast(i) }, state);
    }

    // While every window is still live, a brand-new key cannot fit.
    const new_key = DispatchThrottleKey{ .class = .attack_guid, .target_guid = 0xabc };
    try std.testing.expect(store.findOrInsertThrottle(bot_id, new_key, fill_time_ms) == null);

    // Once all windows have elapsed, the new key reclaims a stale slot.
    const late_ms: u32 = fill_time_ms + move_debounce_ms + 1;
    try std.testing.expect(store.findOrInsertThrottle(bot_id, new_key, late_ms) != null);
}

test "findOrInsertThrottle never evicts a live throttle window" {
    var store: DispatchStore = .{};
    const bot_id = std.mem.zeroes(BotId);
    var state = std.mem.zeroes(proto.State);
    state.game_time_ms = 50_000;

    var i: u32 = 0;
    while (i < throttle_capacity) : (i += 1) {
        store.recordDispatch(bot_id, .{ .class = .move, .qx = @intCast(i) }, state);
    }

    // A distinct new key finds no expired slot to reclaim.
    const new_key = DispatchThrottleKey{ .class = .attack_guid, .target_guid = 0xabc };
    try std.testing.expect(store.findOrInsertThrottle(bot_id, new_key, state.game_time_ms) == null);

    // The first live window was not clobbered — it still throttles.
    try std.testing.expect(!store.dispatchAllowed(bot_id, .{ .class = .move, .qx = 0 }, state));
}

test "hardStop suppresses move/attack/facing for hard_stop_quiet_ms" {
    var store: DispatchStore = .{};
    var state = std.mem.zeroes(proto.State);
    state.game_time_ms = 50_000;
    const bot_id = std.mem.zeroes(BotId);

    store.hardStop(bot_id, state.game_time_ms);

    const blocked_classes = [_]ActionClass{ .move, .ctm_stop, .start_attack, .clear_target, .attack_guid, .set_facing };
    for (blocked_classes) |cls| {
        const key = DispatchThrottleKey{ .class = cls };
        try std.testing.expect(!store.dispatchAllowed(bot_id, key, state));
    }

    state.game_time_ms += hard_stop_quiet_ms;
    for (blocked_classes) |cls| {
        const key = DispatchThrottleKey{ .class = cls };
        try std.testing.expect(store.dispatchAllowed(bot_id, key, state));
    }
}

test "threatBlocked holds when threat is not yet resolved" {
    var store: DispatchStore = .{};
    var state = std.mem.zeroes(proto.State);
    state.game_time_ms = 10_000;
    const bot_id = std.mem.zeroes(BotId);

    try std.testing.expect(store.threatBlocked(bot_id, 0xabc, false, false, false, state.game_time_ms));
    state.game_time_ms += 60_000;
    try std.testing.expect(store.threatBlocked(bot_id, 0xabc, false, false, false, state.game_time_ms));

    state.game_time_ms += 1;
    try std.testing.expect(!store.threatBlocked(bot_id, 0xabc, false, false, true, state.game_time_ms));
}

test "hasThreatHold tracks active threat holds" {
    var store: DispatchStore = .{};
    var state = std.mem.zeroes(proto.State);
    state.game_time_ms = 10_000;
    const bot_id = std.mem.zeroes(BotId);

    try std.testing.expect(!store.hasThreatHold(bot_id));
    try std.testing.expect(store.threatBlocked(bot_id, 0xabc, false, false, false, state.game_time_ms));
    try std.testing.expect(store.hasThreatHold(bot_id));
    state.game_time_ms += 1;
    try std.testing.expect(store.threatBlocked(bot_id, 0xabc, false, false, false, state.game_time_ms));
    try std.testing.expect(store.hasThreatHold(bot_id));
}

test "clearThreatHolds removes all holds" {
    var store: DispatchStore = .{};
    var state = std.mem.zeroes(proto.State);
    state.game_time_ms = 10_000;
    const bot_id = std.mem.zeroes(BotId);

    try std.testing.expect(store.threatBlocked(bot_id, 0xabc, false, false, false, state.game_time_ms));
    try std.testing.expect(store.hasThreatHold(bot_id));
    store.clearThreatHolds();
    try std.testing.expect(!store.hasThreatHold(bot_id));
}
