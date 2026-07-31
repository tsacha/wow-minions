const std = @import("std");
const geo = @import("geo.zig");

pub const base_meleerange_offset: f32 = 1.33;
pub const attack_distance: f32 = 5.0;
pub const melee_inner_bound_yards: f32 = 0.0;
pub const melee_rear_inner_collision_factor: f32 = 1.0;
pub const melee_contact_facing_distance_factor: f32 = 3.0;
pub const melee_position_factor: f32 = 0.8;
pub const melee_outer_slack_yards: f32 = 1.5;
pub const melee_rear_arc_tolerance_rad: f32 = std.math.pi / 2.0;
pub const ranged_max_range_margin_yards: f32 = 2.0;
pub const ranged_ctm_arrival_reserve_yards: f32 = 1.5;
pub const cast_angle_in_front: f32 = 2.0 * std.math.pi / 3.0;
pub const facing_tolerance_rad: f32 = std.math.pi / 3.0;
pub const melee_facing_tolerance_rad: f32 = 0.25;
pub const target_lead_seconds: f32 = 0.35;
pub const min_velocity_for_lead_yards_per_second: f32 = 1.0;
pub const max_velocity_for_lead_yards_per_second: f32 = 14.0;

pub const Unit = struct {
    pos: geo.Vec3,
    orientation: f32,
    combat_reach: f32 = 0.0,
};

pub const Placement = struct {
    relative_angle: f32,
    angle_tolerance: f32 = std.math.pi / 6.0,
    facing_tolerance: f32 = facing_tolerance_rad,
    arc_policy: ArcPolicy = .target_relative,
    range: Range,
};

pub const ArcPolicy = enum {
    target_relative,
    none,
};

pub const Range = union(enum) {
    melee,
    yards: f32,
};

pub const PositioningInput = struct {
    bot: Unit,
    target: Unit,
    target_velocity_yards_per_second: geo.Vec3 = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
    placement: Placement,
};

pub const PositioningResult = struct {
    desired_pos: geo.Vec3,
    target_dist: f32,
    range_lower: f32,
    range_upper: f32,
    bot_dist: f32,
    z_delta: f32,
    target_to_bot: f32,
    bot_to_target: f32,
    arc_delta: f32,
    dist_to_desired: f32,
    in_position: bool,
    rear_arc_ok: bool,
    desired_facing: f32,
    facing_delta: f32,
    facing_ok: bool,
};

const EffectiveRange = struct {
    target_dist: f32,
    lower: f32,
    upper: f32,
};

pub fn computeDesiredPos(input: PositioningInput) PositioningResult {
    const bot = input.bot;
    const placement = input.placement;
    const target = input.target;
    const led_target = leadTarget(target, input.target_velocity_yards_per_second, placement);
    const range = effectiveRange(placement, bot, target);
    const target_to_bot = geo.angleTo2d(target.pos, bot.pos);
    const target_moving = targetIsMoving(input.target_velocity_yards_per_second);

    // For melee .target_relative on a *moving* target, aim along the bot→target
    // line instead of the rear-arc apex. The apex rotates with target.orientation
    // — chasing it makes the bot trace an arc around a target whose facing keeps
    // shifting (typical at start of combat when a mob rotates toward the tank).
    // Pursuing along bot→target collapses to a stable closing path; the rear-arc
    // refinement only matters once the target is stationary.
    const aim_angle = switch (placement.range) {
        .melee => switch (placement.arc_policy) {
            .target_relative => if (target_moving)
                normalizeAngle(target_to_bot)
            else
                normalizeAngle(target.orientation + placement.relative_angle),
            .none => normalizeAngle(target_to_bot),
        },
        .yards => normalizeAngle(target_to_bot),
    };
    const desired_pos = geo.Vec3{
        .x = led_target.pos.x + @cos(aim_angle) * range.target_dist,
        .y = led_target.pos.y + @sin(aim_angle) * range.target_dist,
        .z = bot.pos.z,
    };

    const bot_dist = geo.distance2d(bot.pos, target.pos);
    const z_delta = bot.pos.z - target.pos.z;
    const bot_to_target = geo.angleTo2d(bot.pos, target.pos);
    const arc_delta = absSignedAngleDelta(target_to_bot, aim_angle);
    const dist_to_desired = geo.distance2d(bot.pos, desired_pos);
    const arc_required = switch (placement.range) {
        .melee => placement.arc_policy == .target_relative,
        .yards => false,
    };
    const rear_arc_ok = if (arc_required) arc_delta <= placement.angle_tolerance else true;
    const in_position = bot_dist >= range.lower and bot_dist <= range.upper and rear_arc_ok;

    const desired_facing = bot_to_target;
    const facing_delta = absSignedAngleDelta(bot.orientation, desired_facing);
    const facing_ok = facing_delta <= placement.facing_tolerance;

    return .{
        .desired_pos = desired_pos,
        .target_dist = range.target_dist,
        .range_lower = range.lower,
        .range_upper = range.upper,
        .bot_dist = bot_dist,
        .z_delta = z_delta,
        .target_to_bot = target_to_bot,
        .bot_to_target = bot_to_target,
        .arc_delta = arc_delta,
        .dist_to_desired = dist_to_desired,
        .in_position = in_position,
        .rear_arc_ok = rear_arc_ok,
        .desired_facing = desired_facing,
        .facing_delta = facing_delta,
        .facing_ok = facing_ok,
    };
}

pub fn closeMeleeFacingIsUnstable(bot: Unit, target: Unit, placement: Placement) bool {
    if (placement.range != .melee) return false;
    return meleeContactStable(bot, target);
}

pub fn meleeContactStable(bot: Unit, target: Unit) bool {
    const target_reach = if (target.combat_reach > 0.0) target.combat_reach else bot.combat_reach;
    const contact_dist = (bot.combat_reach + target_reach) * melee_contact_facing_distance_factor;
    if (contact_dist <= 0.0) return false;
    return geo.distance2d(bot.pos, target.pos) <= contact_dist;
}

fn targetIsMoving(velocity: geo.Vec3) bool {
    const speed = @sqrt(velocity.x * velocity.x + velocity.y * velocity.y);
    return speed >= min_velocity_for_lead_yards_per_second;
}

fn leadTarget(target: Unit, velocity: geo.Vec3, placement: Placement) Unit {
    if (placement.range != .melee) return target;

    const speed = @sqrt(velocity.x * velocity.x + velocity.y * velocity.y);
    if (speed < min_velocity_for_lead_yards_per_second or speed > max_velocity_for_lead_yards_per_second) return target;

    var out = target;
    out.pos.x += velocity.x * target_lead_seconds;
    out.pos.y += velocity.y * target_lead_seconds;
    out.pos.z += velocity.z * target_lead_seconds;
    return out;
}

fn effectiveRange(placement: Placement, bot: Unit, target: Unit) EffectiveRange {
    return switch (placement.range) {
        .melee => blk: {
            const collision = @max(bot.combat_reach + target.combat_reach, 0.0);
            const melee_max = @max(attack_distance, collision + base_meleerange_offset);
            const inner = switch (placement.arc_policy) {
                .target_relative => collision * melee_rear_inner_collision_factor,
                .none => melee_inner_bound_yards,
            };
            break :blk .{
                .target_dist = clamp(melee_max * melee_position_factor, collision, melee_max),
                .lower = inner,
                .upper = melee_max,
            };
        },
        .yards => |tooltip| blk: {
            const upper = @max(0.0, tooltip + target.combat_reach - ranged_max_range_margin_yards);
            const target_dist = @max(0.0, upper - ranged_ctm_arrival_reserve_yards);
            break :blk .{
                .target_dist = target_dist,
                .lower = 0.0,
                .upper = upper,
            };
        },
    };
}

fn clamp(value: f32, low: f32, high: f32) f32 {
    return @min(@max(value, low), high);
}

fn normalizeAngle(angle: f32) f32 {
    const tau = 2.0 * std.math.pi;
    var out = @mod(angle, tau);
    if (out < 0) out += tau;
    return out;
}

fn signedAngleDelta(a: f32, b: f32) f32 {
    const tau = 2.0 * std.math.pi;
    var delta = @mod(a - b + std.math.pi, tau);
    if (delta < 0) delta += tau;
    return delta - std.math.pi;
}

fn absSignedAngleDelta(a: f32, b: f32) f32 {
    return @abs(signedAngleDelta(a, b));
}

fn expectApprox(actual: f32, expected: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.01);
}

test "computeDesiredPos: tank face and melee rear placements differ" {
    const bot = Unit{ .pos = .{ .x = 0, .y = 0, .z = 7 }, .orientation = 0, .combat_reach = 1 };
    const target = Unit{ .pos = .{ .x = 10, .y = 10, .z = 3 }, .orientation = 0, .combat_reach = 1 };

    const tank = computeDesiredPos(.{
        .bot = bot,
        .target = target,
        .placement = .{ .relative_angle = 0, .range = .melee },
    });
    const melee = computeDesiredPos(.{
        .bot = bot,
        .target = target,
        .placement = .{ .relative_angle = std.math.pi, .range = .melee },
    });

    try expectApprox(tank.desired_pos.x, 14.0);
    try expectApprox(tank.desired_pos.y, 10.0);
    try expectApprox(melee.desired_pos.x, 6.0);
    try expectApprox(melee.desired_pos.y, 10.0);
    try expectApprox(tank.desired_pos.z, bot.pos.z);
}

test "computeDesiredPos: melee floor and swing reach bonus" {
    const target = Unit{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 1 };

    const floor = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 1 },
        .target = target,
        .placement = .{ .relative_angle = 0, .range = .melee },
    });
    const bonus = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 2.5 },
        .target = .{ .pos = target.pos, .orientation = 0, .combat_reach = 1.5 },
        .placement = .{ .relative_angle = 0, .range = .melee },
    });

    try expectApprox(geo.distance2d(floor.desired_pos, target.pos), attack_distance * melee_position_factor);
    try expectApprox(geo.distance2d(bonus.desired_pos, target.pos), (2.5 + 1.5 + base_meleerange_offset) * melee_position_factor);
}

test "computeDesiredPos: ranged range scales with target combat reach" {
    const result = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0 },
        .target = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 5 },
        .placement = .{ .relative_angle = std.math.pi, .range = .{ .yards = 30 } },
    });

    try expectApprox(geo.distance2d(result.desired_pos, .{ .x = 0, .y = 0, .z = 0 }), 31.5);
}

test "computeDesiredPos: range band and arc decide in_position" {
    const target = Unit{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 1 };
    const placement = Placement{ .relative_angle = std.math.pi, .range = .melee };

    const inside = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = -4, .y = 0, .z = 0 }, .orientation = 0 },
        .target = target,
        .placement = placement,
    });
    const too_far = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = -7, .y = 0, .z = 0 }, .orientation = 0 },
        .target = target,
        .placement = placement,
    });
    const wrong_arc = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 1, .y = 4, .z = 0 }, .orientation = -std.math.pi / 2.0 },
        .target = target,
        .placement = placement,
    });

    try std.testing.expect(inside.in_position);
    try std.testing.expect(!too_far.in_position);
    try std.testing.expect(!wrong_arc.rear_arc_ok);
    try std.testing.expect(!wrong_arc.in_position);
}

test "computeDesiredPos: melee upper bound is strict swing range" {
    const target = Unit{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 0 };
    const placement = Placement{ .relative_angle = std.math.pi, .range = .melee };

    const just_outside = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = -5.4, .y = 0, .z = 0 }, .orientation = 0 },
        .target = target,
        .placement = placement,
    });

    try expectApprox(just_outside.range_upper, attack_distance);
    try std.testing.expect(!just_outside.in_position);
}

test "computeDesiredPos: melee rear arc accepts half-plane behind target" {
    const result = computeDesiredPos(.{
        .bot = .{
            .pos = .{ .x = 0.0, .y = -4.0, .z = 0.0 },
            .orientation = 0.0,
            .combat_reach = 1.5,
        },
        .target = .{
            .pos = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
            .orientation = 0.0,
            .combat_reach = 1.5,
        },
        .placement = .{
            .relative_angle = std.math.pi,
            .angle_tolerance = melee_rear_arc_tolerance_rad,
            .facing_tolerance = melee_facing_tolerance_rad,
            .range = .melee,
        },
    });

    try std.testing.expect(result.rear_arc_ok);
}

test "computeDesiredPos: melee range has no combat reach inner floor" {
    const result = computeDesiredPos(.{
        .bot = .{
            .pos = .{ .x = 3.6, .y = 0, .z = 0 },
            .orientation = std.math.pi,
            .combat_reach = 1.5,
        },
        .target = .{
            .pos = .{ .x = 0, .y = 0, .z = 0 },
            .orientation = 0,
            .combat_reach = 3.0,
        },
        .placement = .{
            .relative_angle = 0,
            .facing_tolerance = melee_facing_tolerance_rad,
            .arc_policy = .none,
            .range = .melee,
        },
    });

    try expectApprox(result.range_lower, melee_inner_bound_yards);
    try std.testing.expect(result.in_position);
}

test "computeDesiredPos: rear melee placement is not inside target collision" {
    const result = computeDesiredPos(.{
        .bot = .{
            .pos = .{ .x = -2.0, .y = 0, .z = 0 },
            .orientation = 0,
            .combat_reach = 1.5,
        },
        .target = .{
            .pos = .{ .x = 0, .y = 0, .z = 0 },
            .orientation = 0,
            .combat_reach = 4.5,
        },
        .placement = .{
            .relative_angle = std.math.pi,
            .facing_tolerance = melee_facing_tolerance_rad,
            .range = .melee,
        },
    });

    try expectApprox(result.range_lower, 6.0);
    try std.testing.expect(!result.in_position);
    try expectApprox(result.desired_pos.x, -6.0);
    try expectApprox(result.desired_pos.y, 0.0);
}

test "computeDesiredPos: ranged placement ignores arc for in_position" {
    const target = Unit{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 1 };
    const result = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = -22, .y = 0, .z = 0 }, .orientation = 0 },
        .target = target,
        .placement = .{ .relative_angle = std.math.pi, .range = .{ .yards = 30 } },
    });

    try std.testing.expect(result.in_position);
    try std.testing.expect(result.rear_arc_ok);
}

test "computeDesiredPos: ranged placement follows current bot line, not target facing" {
    const target = Unit{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = std.math.pi / 2.0, .combat_reach = 1 };
    const result = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 10, .y = 0, .z = 0 }, .orientation = 0 },
        .target = target,
        .placement = .{ .relative_angle = 0, .range = .{ .yards = 30 } },
    });

    try expectApprox(result.desired_pos.x, 27.5);
    try expectApprox(result.desired_pos.y, 0.0);
    try std.testing.expect(result.in_position);
    try expectApprox(result.desired_facing, std.math.pi);
}

test "computeDesiredPos: wrap around zero keeps arc and facing stable" {
    const tau = 2.0 * std.math.pi;
    const target = Unit{
        .pos = .{ .x = 0, .y = 0, .z = 0 },
        .orientation = tau - 0.05,
        .combat_reach = 1,
    };
    const bot = Unit{
        .pos = .{ .x = -4, .y = 0.2, .z = 0 },
        .orientation = tau - 0.05,
        .combat_reach = 1,
    };

    const result = computeDesiredPos(.{
        .bot = bot,
        .target = target,
        .placement = .{ .relative_angle = std.math.pi, .range = .melee },
    });

    try std.testing.expect(result.rear_arc_ok);
    try std.testing.expect(result.facing_ok);
}

test "computeDesiredPos: desired facing points from bot to target with tolerance" {
    const target = Unit{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0 };

    const ok = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 4, .y = 0, .z = 0 }, .orientation = std.math.pi + std.math.pi / 4.0 },
        .target = target,
        .placement = .{ .relative_angle = std.math.pi, .range = .melee },
    });
    const bad = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 4, .y = 0, .z = 0 }, .orientation = std.math.pi / 2.0 },
        .target = target,
        .placement = .{ .relative_angle = std.math.pi, .range = .melee },
    });

    try expectApprox(ok.desired_facing, std.math.pi);
    try std.testing.expect(ok.facing_ok);
    try std.testing.expect(!bad.facing_ok);
}

test "computeDesiredPos: melee contact with large facing error reports facing_ok false" {
    const bot = Unit{
        .pos = .{ .x = 0, .y = 0, .z = 0 },
        .orientation = 0,
        .combat_reach = 1.5,
    };
    const target = Unit{
        .pos = .{ .x = 0.0, .y = 0.5, .z = 0 },
        .orientation = 0,
        .combat_reach = 0.0,
    };
    const result = computeDesiredPos(.{
        .bot = bot,
        .target = target,
        .placement = .{
            .relative_angle = 0,
            .facing_tolerance = melee_facing_tolerance_rad,
            .arc_policy = .none,
            .range = .melee,
        },
    });

    try std.testing.expect(result.in_position);
    try std.testing.expect(meleeContactStable(bot, target));
    try std.testing.expect(result.facing_delta > melee_facing_tolerance_rad);
    try std.testing.expect(!result.facing_ok);
}

test "computeDesiredPos: melee placement leads a moving target" {
    const result = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0 },
        .target = .{ .pos = .{ .x = 10, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 1 },
        .target_velocity_yards_per_second = .{ .x = 10, .y = 0, .z = 0 },
        .placement = .{ .relative_angle = std.math.pi, .range = .melee },
    });

    try expectApprox(result.desired_pos.x, 9.5);
    try expectApprox(result.desired_pos.y, 0.0);
}

test "computeDesiredPos: target lead does not change facing angle" {
    const result = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 10, .y = 0, .z = 0 }, .orientation = std.math.pi },
        .target = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 1 },
        .target_velocity_yards_per_second = .{ .x = 0, .y = 10, .z = 0 },
        .placement = .{ .relative_angle = std.math.pi, .range = .melee },
    });

    try expectApprox(result.desired_facing, std.math.pi);
    try std.testing.expect(result.facing_ok);
}

test "computeDesiredPos: moving target with bot in front uses bot→target chase, not rear apex" {
    // Bot is at +Y above a target moving along +X. The "rear apex" of the target
    // (orientation 0 + π) sits at the target's -X side, which is far from the bot.
    // The chase mode aims at the bot's current angular position so the bot closes
    // distance along the shortest path rather than orbiting around the target.
    const result = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 0, .y = 10, .z = 0 }, .orientation = 0 },
        .target = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 1 },
        .target_velocity_yards_per_second = .{ .x = 5, .y = 0, .z = 0 },
        .placement = .{ .relative_angle = std.math.pi, .range = .melee },
    });

    // Aim is from target toward bot (+Y direction). Led target moves with the
    // velocity, so desired_pos lands roughly +Y from the led position.
    const led_x: f32 = 5.0 * target_lead_seconds;
    try expectApprox(result.desired_pos.x, led_x);
    try expectApprox(result.desired_pos.y, attack_distance * melee_position_factor);
}

test "computeDesiredPos: stationary target preserves rear-arc apex placement" {
    // No velocity → keep the original "exactly behind the target" placement so
    // melee DPS can still slide behind a parked mob for cleave/parry avoidance.
    const result = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 0, .y = 10, .z = 0 }, .orientation = 0 },
        .target = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 1 },
        .placement = .{ .relative_angle = std.math.pi, .range = .melee },
    });

    try expectApprox(result.desired_pos.x, -(attack_distance * melee_position_factor));
    try expectApprox(result.desired_pos.y, 0.0);
}

test "computeDesiredPos: moving target accepts bot already on chase line as in_position" {
    // Bot sits 4y north of the target's center; target moves east. With the new
    // chase aim, arc_delta collapses to 0 and the bot is in_position — the role
    // proposer won't keep dispatching moving_to commands every tick.
    const result = computeDesiredPos(.{
        .bot = .{ .pos = .{ .x = 0, .y = 4, .z = 0 }, .orientation = -std.math.pi / 2.0 },
        .target = .{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .orientation = 0, .combat_reach = 1 },
        .target_velocity_yards_per_second = .{ .x = 5, .y = 0, .z = 0 },
        .placement = .{
            .relative_angle = std.math.pi,
            .angle_tolerance = melee_rear_arc_tolerance_rad,
            .range = .melee,
        },
    });

    try std.testing.expect(result.rear_arc_ok);
    try std.testing.expect(result.arc_delta < 1.0e-3);
}
