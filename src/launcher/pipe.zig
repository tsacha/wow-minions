const win32 = @import("win32");
const constants = @import("constants.zig");

pub const NamedPipe = struct {
    handle: win32.HANDLE,

    pub fn create() !NamedPipe {
        const handle = win32.CreateNamedPipeA(
            constants.pipe_name,
            win32.PIPE_ACCESS_INBOUND,
            win32.PIPE_TYPE_MESSAGE | win32.PIPE_READMODE_MESSAGE | win32.PIPE_WAIT,
            win32.PIPE_UNLIMITED_INSTANCES,
            constants.pipe_buffer_size,
            constants.pipe_buffer_size,
            0,
            null,
        );
        if (handle == win32.INVALID_HANDLE_VALUE) return error.CreateNamedPipe;

        return .{ .handle = handle };
    }

    pub fn deinit(self: NamedPipe) void {
        _ = win32.CloseHandle(self.handle);
    }

    pub fn waitForClient(self: NamedPipe) void {
        _ = win32.ConnectNamedPipe(self.handle, null);
    }
};

pub fn reader(pipe_handle: win32.HANDLE, log_filename: [:0]const u8) void {
    const stdout = win32.GetStdHandle(win32.STD_OUTPUT_HANDLE);
    const log_file = win32.CreateFileA(
        log_filename.ptr,
        win32.FILE_APPEND_DATA,
        0,
        null,
        win32.OPEN_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    const has_log = log_file != win32.INVALID_HANDLE_VALUE;
    defer if (has_log) {
        _ = win32.CloseHandle(log_file);
    };

    var buf: [constants.pipe_reader_buffer_size]u8 = undefined;
    var read: win32.DWORD = 0;
    while (win32.ReadFile(pipe_handle, &buf, buf.len, &read, null) != 0) {
        const msg = buf[0..read];
        var stdout_written: win32.DWORD = 0;
        _ = win32.WriteFile(stdout, msg.ptr, @intCast(msg.len), &stdout_written, null);
        if (has_log) {
            var written: win32.DWORD = 0;
            _ = win32.WriteFile(log_file, msg.ptr, @intCast(msg.len), &written, null);
        }
    }
}
