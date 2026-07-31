// All Thaddius arena coordinates (WotLK 3.3.5a / Naxxramas map 533).

const geo = @import("../../geo.zig");
const role_mod = @import("../../role.zig");

pub const Vec3 = geo.Vec3;
pub const PositionOverride = role_mod.PositionOverride;

// ─── Twin approach waypoints ──────────────────────────────────────────────────

pub const left_approach_1 = Vec3{ .x = 3426.19, .y = -3003.00, .z = 295.6 };
pub const left_approach_2 = Vec3{ .x = 3405.77, .y = -2979.59, .z = 295.6 };
pub const stalagg_initial = Vec3{ .x = 3433.61, .y = -2948.11, .z = 312.0 };

pub const right_approach_1 = Vec3{ .x = 3437.86, .y = -3013.18, .z = 295.6 };
pub const right_approach_2 = Vec3{ .x = 3458.9, .y = -3031.4, .z = 295.6 };
pub const feugen_initial = Vec3{ .x = 3489.61, .y = -3002.40, .z = 312.0 };

// ─── Post-twin transition ─────────────────────────────────────────────────────

pub const left_platform = Vec3{ .x = 3455.5, .y = -2931.4, .z = 312.0 };
pub const right_platform = Vec3{ .x = 3513.1, .y = -2988.7, .z = 312.0 };
pub const post_twin_jump_z_threshold: f32 = 312.1;

pub const left_waypoint = Vec3{ .x = 3484.5, .y = -2906.8, .z = 303.2 };
pub const right_waypoint = Vec3{ .x = 3536.6, .y = -2961.8, .z = 303.3 };

// ─── Polarity stack points ────────────────────────────────────────────────────

// Thaddius (Centre)
pub const thaddius_center = Vec3{ .x = 3510.1, .y = -2930.2, .z = 303.06 };

// Tolerance used for every polarity stack/waypoint. Tight enough that bots end
// stationary at the geometric center of the stack; loose enough that combat
// reach / minor drift doesn't drop them out of "arrived".
pub const polarity_stack_arrival_yards: f32 = 1.5;

// Stack points (SE / NW)
pub const stack_melee_positive = PositionOverride{ .x = 3515.5, .y = -2937.9, .z = 303.0, .arrival_yards = polarity_stack_arrival_yards };

pub const stack_melee_negative = PositionOverride{ .x = 3501.8, .y = -2925.3, .z = 303.1, .arrival_yards = polarity_stack_arrival_yards };

pub const polarity_waypoint_count: usize = 2;

pub const stack_melee_waypoints_positive_to_negative: [polarity_waypoint_count]PositionOverride = .{
    PositionOverride{ .x = 3500.9, .y = -2940.2, .z = 303.7, .arrival_yards = polarity_stack_arrival_yards },
    PositionOverride{ .x = 3499.1, .y = -2934.7, .z = 303.3, .arrival_yards = polarity_stack_arrival_yards },
};
pub const stack_melee_waypoints_negative_to_positive: [polarity_waypoint_count]PositionOverride = .{
    PositionOverride{ .x = 3511.9, .y = -2922.8, .z = 302.8, .arrival_yards = polarity_stack_arrival_yards },
    PositionOverride{ .x = 3516.57, .y = -2923.38, .z = 302.7, .arrival_yards = polarity_stack_arrival_yards },
};

pub const boots_inventory_slot: u8 = 8;
