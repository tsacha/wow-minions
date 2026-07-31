const action_mod = @import("action.zig");
const proto = @import("protocol");
const Action = action_mod.Action;

// Per-class debounce values. Movement and target manipulation need much shorter
// windows than spell casts so corrections still pass through, but long enough
// that the minion has reflected the previous order in a later STATE frame.
pub const instant_cast_debounce_ms: u32 = 1500;
pub const facing_debounce_ms: u32 = 400;
pub const move_debounce_ms: u32 = 300;
pub const ctm_stop_debounce_ms: u32 = 400;
pub const start_attack_debounce_ms: u32 = 600;
pub const stop_attack_debounce_ms: u32 = 600;
pub const stop_cast_debounce_ms: u32 = 400;
pub const clear_target_debounce_ms: u32 = 400;
pub const attack_guid_debounce_ms: u32 = 600;
pub const target_guid_debounce_ms: u32 = 300;
pub const jump_debounce_ms: u32 = 400;
pub const walk_debounce_ms: u32 = proto.brain_tick_ms * 3;
pub const use_item_debounce_ms: u32 = 1000;

pub const hard_stop_quiet_ms: u32 = 800;

// Move destinations are quantized to 1-yard cells so identical re-requests
// collapse onto the same throttle entry while >1-yard corrections still pass.
pub const move_quantize_yards: f32 = 1.0;

pub const ActionClass = enum(u8) {
    cast_instant,
    cast_target_instant,
    set_facing,
    move,
    ctm_stop,
    start_attack,
    stop_attack,
    stop_cast,
    clear_target,
    attack_guid,
    target_guid,
    jump,
    walk,
    use_item,
};

pub fn debounceMsForClass(class: ActionClass) u32 {
    return switch (class) {
        .cast_instant, .cast_target_instant => instant_cast_debounce_ms,
        .set_facing => facing_debounce_ms,
        .move => move_debounce_ms,
        .ctm_stop => ctm_stop_debounce_ms,
        .start_attack => start_attack_debounce_ms,
        .stop_attack => stop_attack_debounce_ms,
        .stop_cast => stop_cast_debounce_ms,
        .clear_target => clear_target_debounce_ms,
        .attack_guid => attack_guid_debounce_ms,
        .target_guid => target_guid_debounce_ms,
        .jump => jump_debounce_ms,
        .walk => walk_debounce_ms,
        .use_item => use_item_debounce_ms,
    };
}

fn quantizeYards(v: f32) i32 {
    return @intFromFloat(@round(v / move_quantize_yards));
}

pub const DispatchThrottleKey = struct {
    class: ActionClass,
    spell_id: u32 = 0,
    target_guid: u64 = 0,
    qx: i32 = 0,
    qy: i32 = 0,

    pub fn eql(self: DispatchThrottleKey, other: DispatchThrottleKey) bool {
        return self.class == other.class and
            self.spell_id == other.spell_id and
            self.target_guid == other.target_guid and
            self.qx == other.qx and
            self.qy == other.qy;
    }
};

const std = @import("std");

pub fn dispatchThrottleKey(action: Action) ?DispatchThrottleKey {
    return switch (action) {
        .none => null,
        // Blocking actions are protected by `ActivePlan` step guards.
        .cast, .cast_target => null,
        .cast_ground => null,
        .move_to, .jump_near_xy => null,

        .cast_instant => |spell_id| .{ .class = .cast_instant, .spell_id = spell_id },
        .cast_target_instant => |ct| .{ .class = .cast_target_instant, .spell_id = ct.spell_id, .target_guid = ct.target_guid },
        .set_facing_rad => |rad| .{ .class = .set_facing, .qx = @intFromFloat(@round(rad * 1000.0)) },
        .move_to_nb => |m| .{ .class = .move, .qx = quantizeYards(m.x), .qy = quantizeYards(m.y) },
        .ctm_stop => .{ .class = .ctm_stop },
        .start_attack => .{ .class = .start_attack },
        .stop_attack => .{ .class = .stop_attack },
        .stop_cast => .{ .class = .stop_cast },
        .clear_target => .{ .class = .clear_target },
        .attack => |guid| .{ .class = .attack_guid, .target_guid = guid },
        .target_guid => |guid| .{ .class = .target_guid, .target_guid = guid },
        .interact => |guid| .{ .class = .attack_guid, .target_guid = guid },
        .jump => .{ .class = .jump },
        .walk => |w| .{ .class = .walk, .spell_id = @intFromEnum(w.direction) },
        .use_inventory_item => |slot| .{ .class = .use_item, .spell_id = slot },
        .apply_poison => |item_id| .{ .class = .use_item, .spell_id = item_id },
    };
}

test "dispatchThrottleKey returns a key for every dispatched action class" {
    try std.testing.expect(dispatchThrottleKey(.ctm_stop).?.class == .ctm_stop);
    try std.testing.expect(dispatchThrottleKey(.start_attack).?.class == .start_attack);
    try std.testing.expect(dispatchThrottleKey(.stop_attack).?.class == .stop_attack);
    try std.testing.expect(dispatchThrottleKey(.stop_cast).?.class == .stop_cast);
    try std.testing.expect(dispatchThrottleKey(.clear_target).?.class == .clear_target);
    try std.testing.expect(dispatchThrottleKey(.{ .attack = 0x123 }).?.class == .attack_guid);
    try std.testing.expect(dispatchThrottleKey(.{ .target_guid = 0x123 }).?.class == .target_guid);
    try std.testing.expect(dispatchThrottleKey(.{ .move_to_nb = .{ .x = 10.0, .y = 20.0, .z = 0.0 } }).?.class == .move);
    try std.testing.expect(dispatchThrottleKey(.{ .walk = .{ .direction = .backward, .duration_ms = proto.brain_tick_ms } }).?.class == .walk);
    try std.testing.expect(dispatchThrottleKey(.none) == null);
    try std.testing.expect(dispatchThrottleKey(.{ .move_to = .{ .x = 0, .y = 0, .z = 0 } }) == null);
}

test "move_to_nb throttle keys quantize to 1-yard cells" {
    const a = dispatchThrottleKey(.{ .move_to_nb = .{ .x = 10.1, .y = 20.4, .z = 0.0 } }).?;
    const b = dispatchThrottleKey(.{ .move_to_nb = .{ .x = 10.3, .y = 20.2, .z = 0.0 } }).?;
    const far = dispatchThrottleKey(.{ .move_to_nb = .{ .x = 12.0, .y = 20.0, .z = 0.0 } }).?;
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(far));
}
