const std = @import("std");
const net = std.Io.net;

const build_options = @import("build_options");

const proto = @import("protocol");
const connection = @import("net/connection.zig");
const brain = @import("brain/mod.zig");
const fight_log = @import("fight_log.zig");
const Registry = @import("registry").Registry;
const WorldMemory = @import("world/memory.zig").WorldMemory;
const SpellEventStore = @import("world/spell_events.zig").SpellEventStore;

const gui_app = if (!build_options.gui) struct {} else @import("gui/app.zig");
const gui_snapshot = @import("gui/snapshot.zig");
const gui_command = @import("gui_command");
const repl = @import("repl.zig");
const lua_output_mod = @import("lua_output.zig");

pub const std_options: std.Options = .{
    .logFn = fight_log.logFn,
};

/// When `WOW_MINIONS_NO_AUTO_ENTERWORLD` is set to any non-empty value, mastermind
/// skips queueing auto EnterWorld Lua (character select only; autologin unchanged).
fn autoEnterWorldFromEnv(init: std.process.Init) bool {
    const v = init.environ_map.get("WOW_MINIONS_NO_AUTO_ENTERWORLD") orelse return true;
    return v.len == 0;
}

/// Verbose glue / EnterWorld tracing to stderr (`std.log.info`).
fn glueLogFromEnv(init: std.process.Init) bool {
    return envFlag(init, "MASTERMIND_GLUE_LOG");
}

fn spellLogFromEnv(init: std.process.Init) bool {
    return envFlag(init, "MASTERMIND_LOG_SPELLS");
}

fn spellLaunchLogFromEnv(init: std.process.Init) bool {
    return envFlag(init, "MASTERMIND_LOG_SPELL_LAUNCHES");
}

fn combatDecisionLogFromEnv(init: std.process.Init) bool {
    return envFlag(init, "MASTERMIND_LOG_COMBAT_DECISIONS");
}

fn intentPreemptLogFromEnv(init: std.process.Init) bool {
    return envFlag(init, "MASTERMIND_LOG_INTENT_PREEMPTIONS");
}

fn combatArbitrationLogFromEnv(init: std.process.Init) bool {
    return envFlag(init, "MASTERMIND_LOG_COMBAT_ARBITRATIONS");
}

fn combatDispatchLogFromEnv(init: std.process.Init) bool {
    return envFlag(init, "MASTERMIND_LOG_COMBAT_DISPATCHES");
}

fn combatSampleLogFromEnv(init: std.process.Init) bool {
    return envFlag(init, "MASTERMIND_LOG_COMBAT_SAMPLES");
}

fn threatTableLogFromEnv(init: std.process.Init) bool {
    return envFlag(init, "MASTERMIND_LOG_THREAT_TABLES");
}

fn polarityChargeLogFromEnv(init: std.process.Init) bool {
    return envFlag(init, "MASTERMIND_LOG_POLARITY_CHARGES");
}

fn envFlag(init: std.process.Init, name: []const u8) bool {
    const v = init.environ_map.get(name) orelse return false;
    return v.len > 0;
}

fn configureMastermindLogs(init: std.process.Init) void {
    const spell_launch_log = spellLaunchLogFromEnv(init);
    brain.setSpellLaunchLogEnabled(spell_launch_log);
    if (spell_launch_log) std.log.info("mastermind: MASTERMIND_LOG_SPELL_LAUNCHES enabled", .{});

    const combat_decision_log = combatDecisionLogFromEnv(init);
    brain.setCombatDecisionLogEnabled(combat_decision_log);
    if (combat_decision_log) std.log.info("mastermind: MASTERMIND_LOG_COMBAT_DECISIONS enabled", .{});

    const intent_preempt_log = intentPreemptLogFromEnv(init);
    brain.setIntentPreemptLogEnabled(intent_preempt_log);
    if (intent_preempt_log) std.log.info("mastermind: MASTERMIND_LOG_INTENT_PREEMPTIONS enabled", .{});

    const combat_arbitration_log = combatArbitrationLogFromEnv(init);
    brain.setCombatArbitrationLogEnabled(combat_arbitration_log);
    if (combat_arbitration_log) std.log.info("mastermind: MASTERMIND_LOG_COMBAT_ARBITRATIONS enabled", .{});

    const combat_dispatch_log = combatDispatchLogFromEnv(init);
    brain.setCombatDispatchLogEnabled(combat_dispatch_log);
    if (combat_dispatch_log) std.log.info("mastermind: MASTERMIND_LOG_COMBAT_DISPATCHES enabled", .{});

    const combat_sample_log = combatSampleLogFromEnv(init);
    brain.setCombatSampleLogEnabled(combat_sample_log);
    if (combat_sample_log) std.log.info("mastermind: MASTERMIND_LOG_COMBAT_SAMPLES enabled", .{});

    const threat_table_log = threatTableLogFromEnv(init);
    brain.setThreatTableLogEnabled(threat_table_log);
    if (threat_table_log) std.log.info("mastermind: MASTERMIND_LOG_THREAT_TABLES enabled", .{});

    const polarity_charge_log = polarityChargeLogFromEnv(init);
    brain.setPolarityChargeLogEnabled(polarity_charge_log);
    if (polarity_charge_log) std.log.info("mastermind: MASTERMIND_LOG_POLARITY_CHARGES enabled", .{});
}

fn configureThreadedIo(io: std.Io) void {
    const opaque_ptr = io.userdata orelse {
        // Non-Threaded backend (e.g. std.testing.io): no async limit to configure.
        std.log.warn("mastermind: Io backend has no userdata; skipping async limit configuration", .{});
        return;
    };
    const threaded: *std.Io.Threaded = @ptrCast(@alignCast(opaque_ptr));
    // Default is logical_cpus - 1; past that, Io.async / group.async run eagerly on
    // the caller stack. Mastermind holds brain.run plus per-connection serve + sendLoop
    // work for a long time; a finite budget underestimates Zig's internal accounting and
    // stalls accept() again once enough minions connect (e.g. low 20s on large hosts).
    threaded.setAsyncLimit(.unlimited);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var registry: Registry = .{};
    registry.auto_enterworld = autoEnterWorldFromEnv(init);
    registry.glue_log = glueLogFromEnv(init);
    if (registry.glue_log) {
        std.log.info("mastermind: MASTERMIND_GLUE_LOG enabled (glue_screen / EnterWorld / identify)", .{});
    }

    var world_memory = WorldMemory.init(gpa.allocator());
    defer world_memory.deinit();
    var spell_events: SpellEventStore = .{};
    spell_events.log_enabled = spellLogFromEnv(init);
    if (spell_events.log_enabled) {
        std.log.info("mastermind: MASTERMIND_LOG_SPELLS enabled", .{});
    }
    configureMastermindLogs(init);

    if (!build_options.gui) {
        try runServer(io, gpa.allocator(), &registry, &world_memory, &spell_events, null, null, null);
        return;
    }

    var publisher = try gui_snapshot.Publisher.init(gpa.allocator());
    defer publisher.deinit();

    var cmd_queue: gui_command.Queue = .{};
    var lua_output_buf: lua_output_mod.Buffer = .{};

    const server_thread = try std.Thread.spawn(.{}, runServerThreadWithGui, .{ io, gpa.allocator(), &registry, &world_memory, &spell_events, &publisher, &cmd_queue, &lua_output_buf });
    server_thread.detach();

    gui_app.run(&publisher, &cmd_queue, &lua_output_buf);
    std.process.exit(0);
}

fn runServerThreadWithGui(io: std.Io, allocator: std.mem.Allocator, registry: *Registry, world_memory: *WorldMemory, spell_events: *SpellEventStore, publisher: *gui_snapshot.Publisher, cmd_queue: *gui_command.Queue, lua_output: *lua_output_mod.Buffer) void {
    runServer(io, allocator, registry, world_memory, spell_events, publisher, cmd_queue, lua_output) catch |err| {
        std.log.err("mastermind server failed: {}", .{err});
        std.process.exit(1);
    };
}

fn runServer(
    io: std.Io,
    allocator: std.mem.Allocator,
    registry: *Registry,
    world_memory: *WorldMemory,
    spell_events: *SpellEventStore,
    publisher: ?*gui_snapshot.Publisher,
    cmd_queue: ?*gui_command.Queue,
    lua_output: ?*lua_output_mod.Buffer,
) !void {
    configureThreadedIo(io);

    const bind_host = if (std.c.getenv("MASTERMIND_BIND")) |p| std.mem.span(p) else "::";
    const addr = try net.IpAddress.parse(bind_host, proto.mastermind_port);

    var srv = try addr.listen(io, .{});
    defer srv.deinit(io);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    const gui_ctx: ?brain.GuiCtx = if (build_options.gui)
        .{ .publisher = publisher.?, .cmd_queue = cmd_queue.?, .lua_output = lua_output.? }
    else
        null;

    var repl_storage: repl.ReplQueue = .{};
    try repl_storage.startStdinThread();
    const repl_ptr: *repl.ReplQueue = &repl_storage;

    group.async(io, brain.run, .{ io, allocator, registry, world_memory, spell_events, gui_ctx, repl_ptr });

    while (true) {
        const conn = try srv.accept(io);
        std.log.debug("Connection accepted from {f}", .{conn.socket.address});
        group.async(io, connection.serve, .{ io, allocator, conn, registry, world_memory, spell_events, lua_output });
    }
}
test {
    _ = @import("net/connection.zig");
    _ = @import("brain/mod.zig");
    _ = @import("brain/action_msg.zig");
    _ = @import("gui/order_label.zig");
    _ = @import("brain/log.zig");
    _ = @import("gui/brain_dispatch.zig");
    _ = @import("brain/compute_tests.zig");
    _ = @import("world/memory.zig");
    _ = @import("world/spell_events.zig");
    _ = @import("repl.zig");
    _ = @import("combat/mod.zig");
    _ = @import("minion_spell_packets");
}

test "minion spell packet parser: smsg spell go prefix" {
    const spell_packets = @import("minion_spell_packets");
    const payload = [_]u8{
        0xff, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        0xff, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x00, 0x45, 0x23, 0x01, 0x00, 0x20, 0x00, 0x00, 0x00,
        0xef, 0xcd, 0xab, 0x00,
    };

    const parsed = spell_packets.parseSmsgSpellGoPrefix(&payload).?;
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), parsed.cast_item_guid);
    try std.testing.expectEqual(@as(u64, 0x8877665544332211), parsed.caster_guid);
    try std.testing.expectEqual(@as(u32, 0x12345), parsed.spell_id);
    try std.testing.expectEqual(@as(u32, 0x20), parsed.flags);
    try std.testing.expectEqual(@as(u32, 0xabcdef), parsed.timestamp);
}

test "minion spell packet parser: rejects truncated prefix" {
    const spell_packets = @import("minion_spell_packets");
    const payload = [_]u8{ 0xff, 0x88, 0x77 };

    try std.testing.expect(spell_packets.parseSmsgSpellGoPrefix(&payload) == null);
}

test "minion spell packet parser: smsg spell start prefix" {
    const spell_packets = @import("minion_spell_packets");
    const payload = [_]u8{
        0xff, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        0xff, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x03, 0x45, 0x23, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
        0xc4, 0x09, 0x00, 0x00,
    };

    const parsed = spell_packets.parseSmsgSpellStartPrefix(&payload).?;
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), parsed.cast_item_guid);
    try std.testing.expectEqual(@as(u64, 0x8877665544332211), parsed.caster_guid);
    try std.testing.expectEqual(@as(u8, 3), parsed.cast_count);
    try std.testing.expectEqual(@as(u32, 0x12345), parsed.spell_id);
    try std.testing.expectEqual(@as(u32, 0x100), parsed.flags);
    try std.testing.expectEqual(@as(u32, 2500), parsed.timer_ms);
}
