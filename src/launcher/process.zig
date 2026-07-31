const std = @import("std");
const win32 = @import("win32");
const constants = @import("constants.zig");

pub const SuspendedProcess = struct {
    info: win32.PROCESS_INFORMATION,

    pub fn create(client_path: []const u8, envs: ?[*]u8) !SuspendedProcess {
        const client_path_z = try std.heap.page_allocator.dupeSentinel(u8, client_path, 0);
        defer std.heap.page_allocator.free(client_path_z);

        var si: win32.STARTUPINFOA = .{
            .cb = @sizeOf(win32.STARTUPINFOA),
            .dwFlags = win32.STARTF_USESHOWWINDOW,
            .wShowWindow = win32.SW_SHOW,
        };
        var pi: win32.PROCESS_INFORMATION = undefined;

        std.debug.print("Creating suspended process...\n", .{});

        if (win32.CreateProcessA(null, client_path_z.ptr, null, null, 0, win32.CREATE_SUSPENDED, envs, null, &si, &pi) == 0) {
            std.debug.print("CreateProcess failed: {}\n", .{win32.GetLastError()});
            return error.CreateProcess;
        }

        return .{ .info = pi };
    }

    pub fn deinit(self: SuspendedProcess) void {
        _ = win32.CloseHandle(self.info.hProcess);
        _ = win32.CloseHandle(self.info.hThread);
    }

    pub fn resumeMainThread(self: SuspendedProcess) !void {
        std.debug.print("Resuming process...\n", .{});
        if (win32.ResumeThread(self.info.hThread) == 0) {
            std.debug.print("ResumeThread failed: {}\n", .{win32.GetLastError()});
            return error.ResumeThread;
        }
    }

    pub fn terminate(self: SuspendedProcess) void {
        _ = win32.TerminateProcess(self.info.hProcess, constants.crash_cleanup_exit_code);
    }

    pub fn handle(self: SuspendedProcess) win32.HANDLE {
        return self.info.hProcess;
    }

    pub fn pid(self: SuspendedProcess) win32.DWORD {
        return self.info.dwProcessId;
    }
};

pub fn deployDll() !void {
    const h = win32.CreateFileA(
        constants.dll_path,
        win32.GENERIC_WRITE,
        0,
        null,
        win32.CREATE_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == win32.INVALID_HANDLE_VALUE) return error.OpenFileFailed;
    defer _ = win32.CloseHandle(h);

    const dll_bytes = @embedFile("minion.dll");
    var written: win32.DWORD = 0;
    if (win32.WriteFile(h, dll_bytes.ptr, @intCast(dll_bytes.len), &written, null) == 0) {
        return error.WriteFileFailed;
    }
}

pub fn injectDll(target_process: win32.HANDLE) !void {
    const remote_mem = win32.VirtualAllocEx(
        target_process,
        null,
        constants.dll_path.len + 1,
        win32.MEM_RESERVE | win32.MEM_COMMIT,
        win32.PAGE_READWRITE,
    ) orelse return error.VirtualAllocFailed;
    defer _ = win32.VirtualFreeEx(target_process, remote_mem, 0, win32.MEM_RELEASE);

    if (win32.WriteProcessMemory(target_process, remote_mem, constants.dll_path, constants.dll_path.len + 1, null) == 0) {
        return error.WriteProcessMemory;
    }

    const kernel32 = win32.GetModuleHandleA("kernel32.dll") orelse return error.GetModuleHandle;
    const load_lib_addr = win32.GetProcAddress(kernel32, "LoadLibraryA") orelse return error.GetProcAddress;
    const load_lib: win32.LPTHREAD_START_ROUTINE = @ptrCast(load_lib_addr);

    const remote_thread = win32.CreateRemoteThread(
        target_process,
        null,
        0,
        load_lib,
        remote_mem,
        0,
        null,
    ) orelse return error.CreateRemoteThread;
    defer _ = win32.CloseHandle(remote_thread);

    const wait_result = win32.WaitForSingleObject(remote_thread, constants.injection_timeout_ms);
    if (wait_result == win32.WAIT_FAILED) return error.WaitForSingleObject;

    var thread_result: u32 = undefined;
    if (win32.GetExitCodeThread(remote_thread, &thread_result) == 0) return error.GetExitCodeThread;
    if (thread_result == 0) return error.LoadLibraryFailed;
}
