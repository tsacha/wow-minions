const std = @import("std");
const win32 = @import("win32");
const constants = @import("constants.zig");

const CrashWindow = struct {
    hwnd: win32.HWND,
    pid: win32.DWORD,
};

const CrashWindowScan = struct {
    game_pid: win32.DWORD,
    game_hwnd: win32.HWND = null,
    crash_windows: [constants.max_crash_windows]CrashWindow = undefined,
    crash_count: usize = 0,

    fn addCrashWindow(self: *CrashWindowScan, hwnd: win32.HWND, pid: win32.DWORD) void {
        if (self.crash_count >= self.crash_windows.len) return;
        self.crash_windows[self.crash_count] = .{ .hwnd = hwnd, .pid = pid };
        self.crash_count += 1;
    }
};

fn windowTitle(hwnd: win32.HWND, buf: *[constants.crash_window_title_capacity:0]u8) []const u8 {
    @memset(buf, 0);
    const len = win32.GetWindowTextA(hwnd, @ptrCast(buf), buf.len);
    if (len <= 0) return "";
    return buf[0..@intCast(len)];
}

fn isCrashWindowTitle(title: []const u8) bool {
    return std.ascii.eqlIgnoreCase(title, "WowError") or
        std.ascii.eqlIgnoreCase(title, "Wow");
}

fn enumCrashWindowsCallback(hwnd: win32.HWND, lparam: win32.LPARAM) callconv(.c) win32.BOOL {
    const scan: *CrashWindowScan = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (win32.IsWindowVisible(hwnd) == 0) return 1;

    var pid: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(hwnd, &pid);
    if (pid == scan.game_pid) scan.game_hwnd = hwnd;

    var title_buf: [constants.crash_window_title_capacity:0]u8 = std.mem.zeroes([constants.crash_window_title_capacity:0]u8);
    const title = windowTitle(hwnd, &title_buf);
    if (isCrashWindowTitle(title)) scan.addCrashWindow(hwnd, pid);

    return 1;
}

fn scanCrashWindows(game_pid: win32.DWORD) CrashWindowScan {
    var scan = CrashWindowScan{ .game_pid = game_pid };
    _ = win32.EnumWindows(enumCrashWindowsCallback, @bitCast(@intFromPtr(&scan)));
    return scan;
}

fn closeWindow(hwnd: win32.HWND) void {
    if (hwnd == null) return;
    _ = win32.PostMessageA(hwnd, win32.WM_CLOSE, 0, 0);
}

fn terminatePid(pid: win32.DWORD) void {
    if (pid == 0) return;
    const process_handle = win32.OpenProcess(win32.PROCESS_TERMINATE, 0, pid);
    if (process_handle == null) return;
    defer _ = win32.CloseHandle(process_handle);
    _ = win32.TerminateProcess(process_handle, constants.crash_cleanup_exit_code);
}

fn cleanupCrashWindows(game_process: win32.HANDLE, game_pid: win32.DWORD, scan: CrashWindowScan) void {
    std.debug.print("launcher: WoW crash window detected; cleaning up game_pid={} crash_windows={}\n", .{ game_pid, scan.crash_count });

    closeWindow(scan.game_hwnd);
    for (scan.crash_windows[0..scan.crash_count]) |crash_window| closeWindow(crash_window.hwnd);

    _ = win32.TerminateProcess(game_process, constants.crash_cleanup_exit_code);
    _ = win32.Sleep(constants.crash_window_poll_interval_ms);

    for (scan.crash_windows[0..scan.crash_count]) |crash_window| {
        if (crash_window.pid != game_pid) terminatePid(crash_window.pid);
    }
}

fn cleanupResidualCrashWindows(game_pid: win32.DWORD) void {
    var elapsed_ms: u32 = 0;
    while (elapsed_ms < constants.crash_window_cleanup_grace_ms) : (elapsed_ms += constants.crash_window_poll_interval_ms) {
        const scan = scanCrashWindows(game_pid);
        if (scan.crash_count == 0) {
            _ = win32.Sleep(constants.crash_window_poll_interval_ms);
            continue;
        }
        for (scan.crash_windows[0..scan.crash_count]) |crash_window| {
            closeWindow(crash_window.hwnd);
            terminatePid(crash_window.pid);
        }
        _ = win32.Sleep(constants.crash_window_poll_interval_ms);
    }
}

pub fn monitorWowProcess(game_process: win32.HANDLE, game_pid: win32.DWORD) void {
    while (true) {
        const scan = scanCrashWindows(game_pid);
        if (scan.crash_count > 0) {
            cleanupCrashWindows(game_process, game_pid, scan);
            break;
        }

        const wait_result = win32.WaitForSingleObject(game_process, constants.crash_window_poll_interval_ms);
        if (wait_result == win32.WAIT_OBJECT_0) break;
        if (wait_result == win32.WAIT_FAILED) {
            std.debug.print("launcher: WaitForSingleObject(game) failed: {}\n", .{win32.GetLastError()});
            _ = win32.TerminateProcess(game_process, constants.crash_cleanup_exit_code);
            break;
        }
    }

    cleanupResidualCrashWindows(game_pid);
}
