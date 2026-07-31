const std = @import("std");

const inactive_start_ns: i64 = 0;

var scripted_start_ns: std.atomic.Value(i64) = .init(inactive_start_ns);
var combat_start_ns: std.atomic.Value(i64) = .init(inactive_start_ns);

fn nowNs() i64 {
    return @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).nanoseconds);
}

pub fn start() void {
    scripted_start_ns.store(nowNs(), .release);
}

pub fn stop() void {
    scripted_start_ns.store(inactive_start_ns, .release);
}

pub fn startCombat() void {
    combat_start_ns.store(nowNs(), .release);
}

pub fn stopCombat() void {
    combat_start_ns.store(inactive_start_ns, .release);
}

fn elapsedSeconds(now_ns: i64, start_ns: i64) u64 {
    if (start_ns == inactive_start_ns or now_ns <= start_ns) return 0;
    return @intCast(@divTrunc(now_ns - start_ns, std.time.ns_per_s));
}

fn elapsedMilliseconds(now_ns: i64, start_ns: i64) u64 {
    if (start_ns == inactive_start_ns or now_ns <= start_ns) return 0;
    return @intCast(@divTrunc(now_ns - start_ns, std.time.ns_per_ms));
}

fn writeTwoDigits(writer: *std.Io.Writer, value: u64) std.Io.Writer.Error!void {
    const clamped = @min(value, 99);
    try writer.writeByte(@intCast('0' + clamped / 10));
    try writer.writeByte(@intCast('0' + clamped % 10));
}

fn writeThreeDigits(writer: *std.Io.Writer, value: u64) std.Io.Writer.Error!void {
    const clamped = @min(value, 999);
    try writer.writeByte(@intCast('0' + clamped / 100));
    try writer.writeByte(@intCast('0' + (clamped / 10) % 10));
    try writer.writeByte(@intCast('0' + clamped % 10));
}

fn writePrefix(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const start_ns = scripted_start_ns.load(.acquire);
    const combat_ns = combat_start_ns.load(.acquire);
    const active_start_ns = if (start_ns != inactive_start_ns) start_ns else combat_ns;
    if (active_start_ns == inactive_start_ns) return;

    const elapsed_ms = elapsedMilliseconds(nowNs(), active_start_ns);
    const elapsed_s = elapsed_ms / 1000;
    try writer.writeByte('[');
    try writeTwoDigits(writer, elapsed_s / 60);
    try writer.writeByte(':');
    try writeTwoDigits(writer, elapsed_s % 60);
    try writer.writeByte('.');
    try writeThreeDigits(writer, elapsed_ms % 1000);
    try writer.writeAll("] ");
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);

    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();

    stderr.setColor(switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};
    stderr.setColor(.bold) catch {};
    stderr.writer.writeAll(level.asText()) catch return;
    stderr.setColor(.reset) catch {};
    stderr.setColor(.dim) catch {};
    stderr.setColor(.bold) catch {};
    if (scope != .default) stderr.writer.print("({t})", .{scope}) catch return;
    stderr.writer.writeAll(": ") catch return;
    stderr.setColor(.reset) catch {};
    writePrefix(stderr.writer) catch return;
    stderr.writer.print(format ++ "\n", args) catch return;
}

test "elapsedSeconds clamps inactive and pre-start times to zero" {
    try std.testing.expectEqual(@as(u64, 0), elapsedSeconds(1000, inactive_start_ns));
    try std.testing.expectEqual(@as(u64, 0), elapsedSeconds(1000, 2000));
}

test "elapsedSeconds returns whole seconds" {
    try std.testing.expectEqual(@as(u64, 0), elapsedSeconds(1999, 1000));
    try std.testing.expectEqual(@as(u64, 1), elapsedSeconds(std.time.ns_per_s + 1000, 1000));
    try std.testing.expectEqual(@as(u64, 61), elapsedSeconds(61 * std.time.ns_per_s + 1000, 1000));
}

test "elapsedMilliseconds returns whole milliseconds" {
    try std.testing.expectEqual(@as(u64, 0), elapsedMilliseconds(1999, 1000));
    try std.testing.expectEqual(@as(u64, 1), elapsedMilliseconds(std.time.ns_per_ms + 1000, 1000));
    try std.testing.expectEqual(@as(u64, 61_000), elapsedMilliseconds(61 * std.time.ns_per_s + 1000, 1000));
}
