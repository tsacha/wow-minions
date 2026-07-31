const std = @import("std");
const win32 = @import("win32");
const windows = std.os.windows;
const types = @import("types.zig");
const world = @import("world.zig");
const ctm = @import("ctm.zig");
const hooks = @import("hooks.zig");
const gameplay_log = @import("gameplay_log.zig");
const control = @import("control.zig");
const log_mod = @import("log.zig");

var threads: [3]std.Thread = undefined;
var runtime_started: std.atomic.Value(bool) = .init(false);

fn initBotId() void {
    @memset(&types.bot_id, 0);

    var buf: [64:0]u8 = std.mem.zeroes([64:0]u8);
    if (win32.GetEnvironmentVariableA("BOT_ID", @ptrCast(&buf), buf.len) == 0) return;

    const env = std.mem.sliceTo(&buf, 0);
    const n = @min(types.bot_id.len, env.len);
    @memcpy(types.bot_id[0..n], env[0..n]);
}

fn initHookFlags() void {
    hooks.combat_command_log_enabled = log_mod.envFlag("MINION_LOG_COMBAT_COMMANDS");
    hooks.spell_range_log_enabled = log_mod.envFlag("MINION_LOG_SPELL_RANGES");
    hooks.pet_guid_log_enabled = log_mod.envFlag("MINION_LOG_PET_GUID");
    hooks.crash_on_world_ready_enabled = log_mod.envFlag("MINION_CRASH_ON_WORLD_READY");
}

fn initGameplayLogging() void {
    gameplay_log.enabled = log_mod.envFlag("MINION_LOG_GAMEPLAY");
}

fn initLogLevel() void {
    if (log_mod.envLevel("MINION_LOG_LEVEL")) |level| {
        log_mod.setMinLevel(level);
    }
}

pub fn DllMain(hModule: windows.HINSTANCE, dwReason: windows.DWORD, lpReserved: windows.LPVOID) windows.BOOL {
    _ = lpReserved;

    switch (dwReason) {
        win32.DLL_PROCESS_ATTACH => attach(hModule) catch return .FALSE,
        win32.DLL_PROCESS_DETACH => detach(),
        else => {},
    }

    return .TRUE;
}

fn attach(hModule: windows.HINSTANCE) !void {
    if (runtime_started.swap(true, .acq_rel)) {
        return;
    }

    const hmod: win32.HMODULE = @ptrCast(@alignCast(hModule));
    _ = win32.DisableThreadLibraryCalls(hmod);

    const pipe = win32.CreateFileA(
        types.pipe_name,
        win32.GENERIC_WRITE,
        0,
        null,
        win32.OPEN_EXISTING,
        0,
        null,
    );
    if (pipe == win32.INVALID_HANDLE_VALUE) return error.OpenPipeFailed;

    world.shutdown.store(false, .release);
    control.shutdown.store(false, .release);

    var started_threads: usize = 0;
    var logger_ready = false;
    errdefer {
        runtime_started.store(false, .release);
        world.shutdown.store(true, .release);
        control.shutdown.store(true, .release);
        for (threads[0..started_threads]) |*t| t.join();
        if (logger_ready) log_mod.deinit();
    }

    initBotId();
    initLogLevel();
    initHookFlags();
    initGameplayLogging();
    log_mod.init(pipe);
    logger_ready = true;
    log_mod.info("DLL loaded bot_id={s} log_level={s} log_cmd={} log_ranges={} log_gameplay={}\n", .{
        std.mem.sliceTo(&types.bot_id, 0),
        @tagName(log_mod.getMinLevel()),
        hooks.combat_command_log_enabled,
        hooks.spell_range_log_enabled,
        gameplay_log.enabled,
    });

    threads[0] = try std.Thread.spawn(.{}, world.monitorThread, .{});
    started_threads += 1;
    threads[1] = try std.Thread.spawn(.{}, hooks.hookThread, .{});
    started_threads += 1;
    threads[2] = try std.Thread.spawn(.{}, control.controlThread, .{});
    started_threads += 1;
}

fn detach() void {
    if (!runtime_started.swap(false, .acq_rel)) return;

    world.shutdown.store(true, .release);
    control.shutdown.store(true, .release);

    for (&threads) |*t| t.join();
    log_mod.info("DLL detached\n", .{});
    log_mod.deinit();
}
