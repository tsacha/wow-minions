const std = @import("std");
const win32 = @import("win32");
const config = @import("config.zig");
const constants = @import("constants.zig");

const FindWindowCtx = struct {
    pid: win32.DWORD,
    hwnd: win32.HWND,
};

fn enumWindowsCallback(hwnd: win32.HWND, lparam: win32.LPARAM) callconv(.c) win32.BOOL {
    const ctx: *FindWindowCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var pid: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(hwnd, &pid);
    if (pid == ctx.pid and win32.IsWindowVisible(hwnd) != 0) {
        ctx.hwnd = hwnd;
        return 0;
    }
    return 1;
}

fn stripWindowDecorations(hwnd: win32.HWND, resolution: config.Resolution) void {
    const style = win32.GetWindowLongA(hwnd, constants.gwl_style_index);
    _ = win32.SetWindowLongA(hwnd, constants.gwl_style_index, style & ~constants.strip_window_style_mask);
    _ = win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, constants.refresh_frame_flags);
    _ = win32.SetWindowPos(hwnd, null, 0, 0, resolution.width, resolution.height, constants.resize_borderless_flags);
}

pub fn setWowWindowTitle(pid: win32.DWORD, bot_id: []const u8, resolution: config.Resolution) void {
    var title_buf: [constants.window_title_capacity:0]u8 = std.mem.zeroes([constants.window_title_capacity:0]u8);
    _ = std.fmt.bufPrintZ(&title_buf, "WoW - {s}", .{bot_id}) catch {};

    var ctx = FindWindowCtx{ .pid = pid, .hwnd = null };
    var attempt: u32 = 0;
    while (attempt < constants.window_poll_attempts) : (attempt += 1) {
        ctx.hwnd = null;
        _ = win32.EnumWindows(enumWindowsCallback, @bitCast(@intFromPtr(&ctx)));
        if (ctx.hwnd != null) {
            _ = win32.SetWindowTextA(ctx.hwnd, &title_buf);
            stripWindowDecorations(ctx.hwnd, resolution);
            return;
        }
        _ = win32.Sleep(constants.window_poll_interval_ms);
    }
    std.debug.print("setWowWindowTitle: window not found after {}ms\n", .{constants.window_poll_max_ms});
}
