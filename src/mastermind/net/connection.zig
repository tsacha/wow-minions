const std = @import("std");
const net = std.Io.net;
const proto = @import("protocol");
const types = @import("types");
const registry_mod = @import("registry");
const world_memory_mod = @import("../world/memory.zig");
const spell_event_store = @import("../world/spell_events.zig");

const lua_output_mod = @import("../lua_output.zig");

const Registry = registry_mod.Registry;
const Handle = registry_mod.Handle;
const WorldMemory = world_memory_mod.WorldMemory;
const SpellEventStore = spell_event_store.SpellEventStore;
const MsgQueue = types.MsgQueue;

const send_frame_size: usize = proto.frame_header_size + proto.wireSize(proto.MastermindMsg);

// Per-connection entry point. Spawns a sender fiber for outbound messages
// and runs the receiver in this fiber. `defer` guarantees both the
// registry slot and the socket are released even on error.
pub fn serve(io: std.Io, allocator: std.mem.Allocator, conn: net.Stream, registry: *Registry, world_memory: *WorldMemory, spell_events: *SpellEventStore, lua_output: ?*lua_output_mod.Buffer) void {
    var backing: [types.queue_capacity]proto.MastermindMsg = undefined;
    var queue: MsgQueue = .init(&backing);

    const handle = registry.register(io, conn, &queue) orelse {
        std.log.err("mastermind: registry full (max {}); {f}", .{ types.max_bots, conn.socket.address });
        conn.close(io);
        return;
    };
    defer registry.unregister(io, handle);

    const scan_cap = proto.scan_payload_size;
    const read_buf = allocator.alloc(u8, scan_cap) catch {
        logOomClose(io, conn);
        return;
    };
    defer allocator.free(read_buf);
    const payload_buf = allocator.alloc(u8, scan_cap) catch {
        logOomClose(io, conn);
        return;
    };
    defer allocator.free(payload_buf);

    var send_future = std.Io.async(io, sendLoop, .{ io, conn, &queue, registry });

    recvLoop(io, conn, registry, handle, world_memory, spell_events, lua_output, read_buf, payload_buf) catch |err| {
        std.log.debug("recvLoop ended for {f}: {}", .{ conn.socket.address, err });
    };

    queue.close(io);
    conn.close(io);
    _ = send_future.await(io) catch {};
}

// Frames are decoded before any lock is taken. Locks protect mutation of
// shared state only — never network I/O — to keep contention minimal.
fn recvLoop(
    io: std.Io,
    conn: net.Stream,
    registry: *Registry,
    handle: Handle,
    world_memory: *WorldMemory,
    spell_events: *SpellEventStore,
    lua_output: ?*lua_output_mod.Buffer,
    read_buf: []u8,
    payload_buf: []u8,
) !void {
    var reader = conn.reader(io, read_buf);
    var current_bot_id: types.BotId = std.mem.zeroes(types.BotId);

    while (true) {
        const frame = try readFrame(&reader.interface, payload_buf);

        const msg_type = std.enums.fromInt(proto.MinionMsg, frame.msg_type) orelse continue;
        switch (msg_type) {
            .state => {
                handleState(io, registry, handle, frame.payload);
                if (frame.payload.len == proto.state_payload_size) {
                    const state = proto.readWire(proto.State, frame.payload);
                    current_bot_id = state.bot_id;
                }
            },
            .scan => handleScan(io, world_memory, frame.payload),
            .spell_event => handleSpellEvent(io, spell_events, frame.payload),
            .lua_result => {
                if (lua_output) |buf| {
                    const text = std.mem.sliceTo(frame.payload, 0);
                    buf.push(current_bot_id, text);
                }
            },
        }
    }
}

fn handleSpellEvent(io: std.Io, spell_events: *SpellEventStore, payload: []const u8) void {
    if (payload.len != proto.wireSize(proto.SpellEvent)) return;

    const event = proto.readWire(proto.SpellEvent, payload);
    const kind = std.enums.fromInt(proto.SpellEventKind, event.kind) orelse return;
    const ts_ns: u64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
    spell_events.push(io, event, ts_ns);

    if (spell_events.log_enabled) {
        std.log.info(
            "spell_event: {s} caster=0x{x} spell={} flags=0x{x} value_ms={} game_time_ms={} observer=0x{x}",
            .{ @tagName(kind), event.caster_guid, event.spell_id, event.flags, event.value_ms, event.game_time_ms, event.observer_guid },
        );
    }
}

fn handleState(io: std.Io, registry: *Registry, handle: Handle, payload: []const u8) void {
    if (payload.len != proto.state_payload_size) return;

    const state = proto.readWire(proto.State, payload);

    // Evict duplicate BOT_ID before glue automation runs on this slot, so
    // storeState sees the correct generation and bot_id for this connection.
    registry.identify(io, handle, state.bot_id, state.world_ready != 0);
    registry.storeState(io, handle, state);
}

fn handleScan(io: std.Io, world_memory: *WorldMemory, payload: []const u8) void {
    if (payload.len < proto.scan_header_size) return;
    const map_id = std.mem.readInt(u32, payload[0..proto.scan_header_size], .little);

    const entries_payload = payload[proto.scan_header_size..];
    const ts_ns: u64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
    world_memory.upsertScanPayload(io, map_id, ts_ns, entries_payload);
}

fn sendLoop(io: std.Io, conn: net.Stream, queue: *MsgQueue, registry: *Registry) !void {
    var write_buf: [send_frame_size]u8 = undefined;
    var frame_buf: [send_frame_size]u8 = undefined;
    var writer = conn.writer(io, &write_buf);

    while (true) {
        const msg = queue.getOne(io) catch return;
        if (std.meta.activeTag(msg) == .cast_spell_ground) {
            std.log.debug("connection: send cast_spell_ground to {f}", .{conn.socket.address});
        }
        if (registry.glue_log) {
            switch (msg) {
                .lua_exec => |s| {
                    const code = std.mem.sliceTo(&s, 0);
                    const max_show: usize = 200;
                    const shown = if (code.len > max_show) code[0..max_show] else code;
                    std.log.info("glue: -> {f} lua_exec ({d} B): {s}{s}", .{
                        conn.socket.address,
                        code.len,
                        shown,
                        if (code.len > max_show) "…" else "",
                    });
                },
                else => {},
            }
        }
        const frame = proto.writeMastermindFrame(msg, &frame_buf);
        try writer.interface.writeAll(frame);
        try writer.interface.flush();
    }
}

fn readFrame(reader: anytype, payload_buf: []u8) !struct { msg_type: u8, payload: []const u8 } {
    var len_buf: [proto.frame_length_size]u8 = undefined;
    try reader.readSliceAll(&len_buf);

    const frame_len = std.mem.readInt(u32, &len_buf, .big);
    if (frame_len == 0) return error.MalformedFrame;

    var type_buf: [1]u8 = undefined;
    try reader.readSliceAll(&type_buf);

    const payload_len = frame_len - 1;
    if (payload_len > payload_buf.len) return error.MalformedFrame;
    if (payload_len > 0) try reader.readSliceAll(payload_buf[0..payload_len]);

    return .{ .msg_type = type_buf[0], .payload = payload_buf[0..payload_len] };
}

fn logOomClose(io: std.Io, conn: net.Stream) void {
    std.log.err("mastermind: OOM recv buffers ({f})", .{conn.socket.address});
    conn.close(io);
}

test "handleSpellEvent stores valid payload and ignores malformed payload" {
    var store: SpellEventStore = .{};
    const event: proto.SpellEvent = .{
        .kind = @intFromEnum(proto.SpellEventKind.go),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x11,
        .caster_guid = 0x22,
        .spell_id = 333,
        .flags = 0x40100,
        .value_ms = 444,
        .game_time_ms = 555,
    };

    var payload: [proto.wireSize(proto.SpellEvent)]u8 = undefined;
    proto.writeWire(proto.SpellEvent, event, &payload);

    handleSpellEvent(std.testing.io, &store, &payload);
    handleSpellEvent(std.testing.io, &store, payload[0 .. payload.len - 1]);

    var out: [2]proto.SpellEvent = undefined;
    const n = store.snapshot(std.testing.io, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(event.caster_guid, out[0].caster_guid);
    try std.testing.expectEqual(event.spell_id, out[0].spell_id);
}
