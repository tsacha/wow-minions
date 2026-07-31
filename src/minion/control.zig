const std = @import("std");
const win32 = @import("win32");
const proto = @import("protocol");
const types = @import("types.zig");
const hooks = @import("hooks.zig");
const world = @import("world.zig");
const ctm = @import("ctm.zig");
const log_mod = @import("log.zig");

pub var shutdown: std.atomic.Value(bool) = .init(false);

const invalid_socket = ~@as(win32.SOCKET, 0); // Win32 INVALID_SOCKET: all bits set
const FIONREAD: c_long = 0x4004667F;
const max_send_len = std.math.maxInt(c_int);
const max_cmd_frame_size: usize = 4096;

// Upper bound on command frames drained per control-thread iteration. Generous
// vs the brain's ~1 order/bot/tick so a normal burst is fully drained in one
// pass, while still bounding a single iteration's command-processing latency.
const max_commands_per_drain: usize = 64;

// ── socket helpers ────────────────────────────────────────────────────────────

const default_mastermind_host = "127.0.0.1";
const port_str = std.fmt.comptimePrint("{d}", .{types.mastermind_port});

fn tryConnect() win32.SOCKET {
    var host_buf: [256]u8 = undefined;
    const host: [*:0]const u8 = blk: {
        const n = win32.GetEnvironmentVariableA(
            "MASTERMIND_HOST",
            &host_buf,
            host_buf.len,
        );
        if (n == 0 or n >= host_buf.len) {
            @memcpy(host_buf[0..default_mastermind_host.len], default_mastermind_host);
            host_buf[default_mastermind_host.len] = 0;
        }
        break :blk @ptrCast(&host_buf);
    };

    var hints = std.mem.zeroes(win32.addrinfo);
    hints.ai_family = win32.AF_UNSPEC;
    hints.ai_socktype = win32.SOCK_STREAM;
    hints.ai_protocol = win32.IPPROTO_TCP;

    var res: ?*win32.addrinfo = null;
    if (win32.getaddrinfo(host, port_str, &hints, &res) != 0) return invalid_socket;
    defer win32.freeaddrinfo(res);

    var it = res;
    while (it) |ai| : (it = ai.ai_next) {
        const sock = win32.socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol);
        if (sock == invalid_socket) continue;
        if (win32.connect(sock, ai.ai_addr, @intCast(ai.ai_addrlen)) == 0) return sock;
        _ = win32.closesocket(sock);
    }
    return invalid_socket;
}

// TCP may deliver fewer bytes than requested in a single send/recv call,
// so both functions loop until the full slice is transferred.
fn sendAll(sock: win32.SOCKET, data: []const u8) !void {
    var sent: usize = 0;

    while (sent < data.len) {
        const chunk = data[sent..][0..@min(data.len - sent, @as(usize, max_send_len))];
        const rc = win32.send(sock, @ptrCast(chunk.ptr), @intCast(chunk.len), 0);
        if (rc <= 0) return error.SendFailed;
        sent += std.math.cast(usize, rc) orelse return error.SendFailed;
    }
}

fn recvExact(sock: win32.SOCKET, buf: []u8) !void {
    var total: usize = 0;

    while (total < buf.len) {
        const chunk = buf[total..][0..@min(buf.len - total, @as(usize, max_send_len))];
        const rc = win32.recv(sock, @ptrCast(chunk.ptr), @intCast(chunk.len), 0);
        if (rc <= 0) return error.RecvFailed;
        total += std.math.cast(usize, rc) orelse return error.RecvFailed;
    }
}

fn disconnect(sock: *win32.SOCKET, err: anyerror) void {
    log_mod.warn("[control] disconnected: {}\n", .{err});
    hooks.scheduleWalkStopAll();
    _ = win32.closesocket(sock.*);
    sock.* = invalid_socket;
}

// ── framing ───────────────────────────────────────────────────────────────────

fn sendFrameHeader(sock: win32.SOCKET, msg_type: types.MinionMsg, payload_len: usize) !void {
    var header: [proto.frame_header_size]u8 = undefined;

    std.mem.writeInt(u32, header[0..proto.frame_length_size], @intCast(1 + payload_len), .big);
    header[proto.frame_length_size] = @intFromEnum(msg_type);

    try sendAll(sock, &header);
}

fn sendState(sock: win32.SOCKET, state: types.State) !void {
    const wire_size = comptime proto.wireSize(types.State);

    var payload: [wire_size]u8 = undefined;
    proto.writeWire(types.State, state, &payload);

    try sendFrameHeader(sock, .state, wire_size);
    try sendAll(sock, &payload);
}

fn sendLuaResult(sock: win32.SOCKET, result: []const u8) !void {
    try sendFrameHeader(sock, .lua_result, result.len);
    if (result.len > 0) try sendAll(sock, result);
}

fn sendScan(sock: win32.SOCKET, entries: []const types.ScanEntry) !void {
    const entry_size = comptime proto.wireSize(types.ScanEntry);
    const entries_len = entries.len * entry_size;
    const payload_len = proto.scan_header_size + entries_len;

    var header: [proto.scan_header_size]u8 = undefined;
    std.mem.writeInt(u32, &header, world.readMapId(), .little);

    var payload: [types.scan_max_entries * entry_size]u8 = undefined;
    for (entries, 0..) |entry, i|
        proto.writeWire(types.ScanEntry, entry, payload[i * entry_size ..]);

    try sendFrameHeader(sock, .scan, payload_len);
    try sendAll(sock, &header);
    if (entries_len > 0) try sendAll(sock, payload[0..entries_len]);
}

fn sendSpellEvent(sock: win32.SOCKET, event: types.SpellEvent) !void {
    const wire_size = comptime proto.wireSize(types.SpellEvent);

    var payload: [wire_size]u8 = undefined;
    proto.writeWire(types.SpellEvent, event, &payload);

    try sendFrameHeader(sock, .spell_event, wire_size);
    try sendAll(sock, &payload);
}

const max_spell_events_per_drain: usize = 64;

fn drainSpellEvents(sock: win32.SOCKET) !void {
    var i: usize = 0;
    while (i < max_spell_events_per_drain) : (i += 1) {
        const event = hooks.pollSpellEvent() orelse break;
        try sendSpellEvent(sock, event);
    }
}

// ── command dispatch ──────────────────────────────────────────────────────────

// Non-blocking lua_get state. The control thread schedules the render-thread
// evaluation then returns immediately; resolveLuaGet polls for the result on
// subsequent ticks and sends it when ready, avoiding a 500 ms block.
const LuaGetState = struct {
    active: bool = false,
    deadline_ms: u32 = 0,
};

fn resolveLuaGet(sock: win32.SOCKET, state: *LuaGetState) !void {
    if (!state.active) return;
    if (hooks.pollLuaGetReady()) |result| {
        try sendLuaResult(sock, result);
        state.active = false;
        return;
    }
    if (win32.GetTickCount() -% state.deadline_ms < 0x8000_0000) {
        log_mod.warn("[control] lua_get timeout\n", .{});
        state.active = false;
    }
}

// Non-blocking scan state. Mirrors LuaGetState: the control thread schedules a
// render-thread object scan, then polls for the result on later ticks instead
// of blocking the command path for up to render_poll_timeout_ms while it runs.
const ScanState = struct {
    active: bool = false,
    deadline_ms: u32 = 0,
};

fn resolveScan(sock: win32.SOCKET, state: *ScanState) !void {
    if (!state.active) return;
    if (hooks.pollScanReady()) |count| {
        try sendScan(sock, hooks.scan_buf[0..count]);
        state.active = false;
        return;
    }
    if (win32.GetTickCount() -% state.deadline_ms < 0x8000_0000) {
        log_mod.debug("[control] scan timeout\n", .{});
        state.active = false;
    }
}

fn dispatchCommand(payload: []const u8, lua_get: *LuaGetState) void {
    const msg = proto.readMastermindMsg(payload) orelse return;
    switch (msg) {
        .lua_exec => |s| {
            hooks.scheduleLuaExec(std.mem.sliceTo(&s, 0));
        },
        .ctm_move => |c| hooks.scheduleMove(.{ .x = c.x, .y = c.y, .z = c.z }),
        .ctm_interact_guid => |c| hooks.scheduleGuidAction(.interact_npc, c.guid),
        .ctm_attack_guid => |c| hooks.scheduleGuidAction(.attack_pos, c.guid),
        .set_target_guid => |c| hooks.scheduleSetTargetGuid(c.guid),
        .cast_spell_id => |c| hooks.scheduleCastSpellId(c.spell_id),
        .cast_spell_guid => |c| hooks.scheduleCastSpellGuid(c.spell_id, c.target_guid),
        .cast_spell_ground => |c| hooks.scheduleCastSpellGround(c.spell_id, c.x, c.y, c.z),
        .jump => hooks.scheduleJump(),
        .ctm_stop => {
            hooks.scheduleWalkStopAll();
            ctm.ctmStop();
        },
        .set_facing => |rad| hooks.scheduleSetFacing(rad),
        .walk => |c| hooks.scheduleWalk(c),
        .lua_get => |s| {
            if (lua_get.active) {
                log_mod.warn("[control] lua_get dropped: previous still pending\n", .{});
                return;
            }
            hooks.scheduleLuaGet(std.mem.sliceTo(&s, 0));
            lua_get.active = true;
            lua_get.deadline_ms = win32.GetTickCount() +% proto.render_poll_timeout_ms;
        },
    }
}

const RecvResult = enum { dispatched, empty, deferred };

// Reads and dispatches one complete command frame if a whole frame is already
// buffered. Returns `.empty` (without blocking) when fewer than a full frame's
// bytes are available, so the drain loop knows to stop.
//
// Returns `.deferred` — leaving the frame untouched on the socket — when the
// next frame is a lua_exec and a prior lua_exec is still pending on the render
// thread. The exec slot is single-buffered (`hooks.scheduleLuaExec`), so
// draining a second lua_exec in the same tick would overwrite the first before
// the render thread ran it. Leaving it buffered lets the next tick pick it up
// once the slot has drained, serializing back-to-back lua_exec bursts (e.g. the
// reset-fight `.go` teleport sequence) without dropping any.
fn recvOneCommand(sock: win32.SOCKET, lua_get: *LuaGetState) !RecvResult {
    const peek_len = proto.frame_length_size + 1;

    var available_raw: c_ulong = 0;
    var header_buf: [peek_len]u8 = undefined;
    var length_buf: [proto.frame_length_size]u8 = undefined;
    var buf: [max_cmd_frame_size]u8 = undefined;

    // FIONREAD returns the number of bytes readable without blocking.
    if (win32.ioctlsocket(sock, FIONREAD, &available_raw) != 0) {
        log_mod.warn("[control] recvCommands ioctlsocket failed\n", .{});
        return error.IoctlFailed;
    }
    const available: usize = @intCast(available_raw);
    if (available < peek_len) return .empty;
    if (win32.recv(sock, @ptrCast(&header_buf), peek_len, win32.MSG_PEEK) != peek_len) return error.RecvFailed;

    const length: usize = std.mem.readInt(u32, header_buf[0..proto.frame_length_size], .big);
    if (length == 0 or length > max_cmd_frame_size) return error.MalformedFrame;
    if (available < proto.frame_length_size + length) return .empty;

    // The byte after the length prefix is the NetCmd tag (see writeMastermindFrame).
    if (std.enums.fromInt(proto.NetCmd, header_buf[proto.frame_length_size])) |tag| {
        if (tag == .lua_exec and hooks.execPending()) return .deferred;
    }

    try recvExact(sock, &length_buf);
    try recvExact(sock, buf[0..length]);
    dispatchCommand(buf[0..length], lua_get);
    return .dispatched;
}

// Drains every command frame already buffered on the socket this tick. The
// brain can burst orders faster than one per control-thread iteration; draining
// only one frame per tick let a backlog build until stale orders (e.g. an
// attack-pos chase) outran fresh ones by seconds and froze repositioning bots.
fn recvCommands(sock: win32.SOCKET, lua_get: *LuaGetState) !void {
    for (0..max_commands_per_drain) |_| {
        switch (try recvOneCommand(sock, lua_get)) {
            .dispatched => {},
            .empty, .deferred => return,
        }
    }
}

// ── main loop ─────────────────────────────────────────────────────────────────

pub fn controlThread() void {
    var disabled_buf: [4]u8 = undefined;
    if (win32.GetEnvironmentVariableA("MASTERMIND_DISABLED", &disabled_buf, disabled_buf.len) > 0 and
        disabled_buf[0] == '1') return;

    var wsa: win32.WSADATA = undefined;
    var sock: win32.SOCKET = invalid_socket;
    var tick: u32 = 0;
    var lua_get_state: LuaGetState = .{};
    var scan_state: ScanState = .{};

    _ = win32.WSAStartup(0x0202, &wsa);
    defer _ = win32.WSACleanup();
    defer {
        if (sock != invalid_socket) _ = win32.closesocket(sock);
    }

    while (!shutdown.load(.acquire)) : (win32.Sleep(types.tick_ms)) {
        if (sock == invalid_socket) {
            lua_get_state = .{};
            scan_state = .{};
            sock = tryConnect();
            if (sock != invalid_socket) log_mod.info("[control] connected\n", .{});
            continue;
        }

        resolveLuaGet(sock, &lua_get_state) catch |err| {
            disconnect(&sock, err);
            lua_get_state = .{};
            scan_state = .{};
            continue;
        };

        resolveScan(sock, &scan_state) catch |err| {
            disconnect(&sock, err);
            lua_get_state = .{};
            scan_state = .{};
            continue;
        };

        recvCommands(sock, &lua_get_state) catch |err| {
            disconnect(&sock, err);
            lua_get_state = .{};
            scan_state = .{};
            continue;
        };
        const state = hooks.pollStateReady() orelse continue;
        sendState(sock, state) catch |err| {
            disconnect(&sock, err);
            continue;
        };
        drainSpellEvents(sock) catch |err| {
            disconnect(&sock, err);
            continue;
        };

        tick += 1;
        if (tick % proto.minion_scan_period_ticks == 0 and !scan_state.active) {
            hooks.scheduleScan();
            scan_state.active = true;
            scan_state.deadline_ms = win32.GetTickCount() +% proto.render_poll_timeout_ms;
        }
    }
}
