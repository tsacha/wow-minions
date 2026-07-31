const std = @import("std");
const win32 = @import("win32");
const config_mod = @import("config.zig");
const crash_monitor = @import("crash_monitor.zig");
const pipe_mod = @import("pipe.zig");
const process_mod = @import("process.zig");
const window = @import("window.zig");

pub fn main() !void {
    const config = config_mod.LauncherConfig.load();

    const pipe = try pipe_mod.NamedPipe.create();
    defer pipe.deinit();

    const envs = win32.GetEnvironmentStrings();
    defer _ = win32.FreeEnvironmentStringsA(envs);

    const game = try process_mod.SuspendedProcess.create(config.client_path.path(), envs);
    defer game.deinit();

    std.debug.print("Deploying DLL...\n", .{});
    try process_mod.deployDll();

    config_mod.ensureMinionLogsDir();
    const log_filename = config_mod.LogFilename.init(&config.bot_id);

    std.debug.print("Injecting DLL...\n", .{});
    try process_mod.injectDll(game.handle());
    std.debug.print("DLL injected.\n", .{});

    pipe.waitForClient();
    try game.resumeMainThread();

    var pipe_reader = std.Thread.spawn(.{}, pipe_mod.reader, .{ pipe.handle, log_filename.path() }) catch |err| {
        game.terminate();
        return err;
    };

    if (config.bot_id.isSet()) {
        window.setWowWindowTitle(game.pid(), config.bot_id.slice(), config.resolution);
    }

    crash_monitor.monitorWowProcess(game.handle(), game.pid());
    pipe_reader.join();
}
