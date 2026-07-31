const std = @import("std");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

pub fn distance2d(a: Vec3, b: Vec3) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

pub fn angleTo2d(from: Vec3, to: Vec3) f32 {
    const raw = std.math.atan2(to.y - from.y, to.x - from.x);
    return if (raw < 0) raw + 2.0 * std.math.pi else raw;
}

/// Smallest angular difference between two yaws on `[0, 2π)`, in radians.
pub fn absAngleDeltaRad(a: f32, b: f32) f32 {
    const diff = @abs(a - b);
    return if (diff > std.math.pi) 2.0 * std.math.pi - diff else diff;
}
