const std = @import("std");
const win32 = @import("win32");

var pipe_handle: win32.HANDLE = win32.INVALID_HANDLE_VALUE;
var pipe_cs: win32.CRITICAL_SECTION = undefined;
var is_initialized = false;

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
    trace = 4,
};

var min_level: Level = .info;

pub fn setMinLevel(level: Level) void {
    min_level = level;
}

pub fn getMinLevel() Level {
    return min_level;
}

pub fn parseLevel(raw: []const u8) ?Level {
    if (std.ascii.eqlIgnoreCase(raw, "err") or std.ascii.eqlIgnoreCase(raw, "error")) return .err;
    if (std.ascii.eqlIgnoreCase(raw, "warn") or std.ascii.eqlIgnoreCase(raw, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(raw, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(raw, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(raw, "trace")) return .trace;
    return null;
}

pub fn init(handle: win32.HANDLE) void {
    if (is_initialized) deinit();
    pipe_handle = handle;
    win32.InitializeCriticalSection(&pipe_cs);
    is_initialized = true;
}

pub fn deinit() void {
    if (is_initialized) {
        win32.DeleteCriticalSection(&pipe_cs);
        is_initialized = false;
    }
    if (pipe_handle != win32.INVALID_HANDLE_VALUE) {
        _ = win32.CloseHandle(pipe_handle);
    }
    pipe_handle = win32.INVALID_HANDLE_VALUE;
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!is_initialized or pipe_handle == win32.INVALID_HANDLE_VALUE) return;
    win32.EnterCriticalSection(&pipe_cs);
    defer win32.LeaveCriticalSection(&pipe_cs);

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;

    var written: win32.DWORD = undefined;
    if (win32.WriteFile(pipe_handle, msg.ptr, @intCast(msg.len), &written, null) == 0) return;
    if (written != msg.len) return;
}

pub fn enabled(comptime level: Level) bool {
    return @intFromEnum(level) <= @intFromEnum(min_level);
}

pub fn at(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    if (enabled(level)) log(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    at(.warn, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    at(.info, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    at(.debug, fmt, args);
}

pub fn trace(comptime fmt: []const u8, args: anytype) void {
    at(.trace, fmt, args);
}

pub fn envFlag(comptime name: [*:0]const u8) bool {
    var buf: [8:0]u8 = std.mem.zeroes([8:0]u8);
    const n = win32.GetEnvironmentVariableA(name, @ptrCast(&buf), buf.len);
    if (n == 0) return false;

    const value = std.mem.sliceTo(&buf, 0);
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return true;
}

pub fn envLevel(comptime name: [*:0]const u8) ?Level {
    var buf: [16:0]u8 = std.mem.zeroes([16:0]u8);
    const n = win32.GetEnvironmentVariableA(name, @ptrCast(&buf), buf.len);
    if (n == 0) return null;

    return parseLevel(std.mem.sliceTo(&buf, 0));
}
