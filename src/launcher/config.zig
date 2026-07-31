const std = @import("std");
const win32 = @import("win32");
const constants = @import("constants.zig");

fn getEnv(comptime cap: usize, name: [*:0]const u8, buf: *[cap:0]u8) ?[]const u8 {
    const len = win32.GetEnvironmentVariableA(name, @ptrCast(buf), cap);
    return if (len != 0) buf[0..@as(usize, len)] else null;
}

pub const BotIdEnv = struct {
    buf: [constants.bot_id_capacity:0]u8 = std.mem.zeroes([constants.bot_id_capacity:0]u8),
    len: usize = 0,

    fn load() BotIdEnv {
        var env = BotIdEnv{};
        if (getEnv(env.buf.len, "BOT_ID", &env.buf)) |val| {
            env.len = val.len;
            std.debug.print("BOT_ID={s}\n", .{val});
        } else {
            std.debug.print("BOT_ID not set\n", .{});
        }
        return env;
    }

    pub fn isSet(self: BotIdEnv) bool {
        return self.len != 0;
    }

    pub fn slice(self: *const BotIdEnv) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const ClientPathEnv = struct {
    buf: [constants.client_path_capacity:0]u8 = std.mem.zeroes([constants.client_path_capacity:0]u8),
    len: usize = 0,

    fn load() ClientPathEnv {
        var env = ClientPathEnv{};
        if (getEnv(env.buf.len, "WOW_CLIENTPATH", &env.buf)) |val| {
            env.len = val.len;
        }
        std.debug.print("WOW_CLIENTPATH={s}\n", .{env.path()});
        return env;
    }

    pub fn path(self: *const ClientPathEnv) []const u8 {
        if (self.len == 0) return constants.default_client_path;
        return self.buf[0..self.len];
    }
};

pub const Resolution = struct {
    width: i32,
    height: i32,
};

pub const LogFilename = struct {
    buf: [constants.log_filename_capacity:0]u8 = undefined,
    len: usize = 0,

    pub fn init(bot_id: *const BotIdEnv) LogFilename {
        var filename = LogFilename{};
        if (bot_id.isSet()) {
            const printed = std.fmt.bufPrintSentinel(
                &filename.buf,
                "{s}\\{s}.log",
                .{ constants.minion_logs_dir, bot_id.slice() },
                0,
            ) catch return filename;
            filename.len = printed.len;
        }
        return filename;
    }

    pub fn path(self: *const LogFilename) [:0]const u8 {
        if (self.len == 0) return "logs\\minion.log";
        return self.buf[0..self.len :0];
    }
};

fn parseResolution(raw: []const u8) ?Resolution {
    const sep = std.mem.indexOfScalar(u8, raw, 'x') orelse return null;
    if (sep == 0 or sep == raw.len - 1) return null;

    const width = std.fmt.parseInt(i32, raw[0..sep], 10) catch return null;
    const height = std.fmt.parseInt(i32, raw[sep + 1 ..], 10) catch return null;
    if (width <= 0 or height <= 0) return null;

    return .{ .width = width, .height = height };
}

fn loadResolution() Resolution {
    var buf: [constants.resolution_env_capacity:0]u8 = std.mem.zeroes([constants.resolution_env_capacity:0]u8);
    const resolution = if (getEnv(buf.len, "WOW_RESOLUTION", &buf)) |raw|
        parseResolution(raw) orelse blk: {
            std.debug.print("WOW_RESOLUTION invalide: {s}\n", .{raw});
            break :blk Resolution{ .width = constants.default_window_width, .height = constants.default_window_height };
        }
    else
        Resolution{ .width = constants.default_window_width, .height = constants.default_window_height };

    std.debug.print("WOW_RESOLUTION={}x{}\n", .{ resolution.width, resolution.height });
    return resolution;
}

pub const LauncherConfig = struct {
    bot_id: BotIdEnv,
    client_path: ClientPathEnv,
    resolution: Resolution,

    pub fn load() LauncherConfig {
        return .{
            .bot_id = BotIdEnv.load(),
            .client_path = ClientPathEnv.load(),
            .resolution = loadResolution(),
        };
    }
};

pub fn ensureMinionLogsDir() void {
    if (win32.CreateDirectoryA(constants.minion_logs_dir, null) != 0) return;

    const err = win32.GetLastError();
    if (err == win32.ERROR_ALREADY_EXISTS) return;

    std.debug.print("CreateDirectory {s} failed: {}\n", .{ constants.minion_logs_dir, err });
}
