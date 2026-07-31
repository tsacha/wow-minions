const std = @import("std");
const proto = @import("protocol");
const types = @import("types");

pub const queue_capacity: usize = 48;
pub const drain_max_per_tick: usize = 6;
pub const repl_cmd_spacing_ms: u32 = 75;
pub const repl_cmd_spacing_ns: u64 = repl_cmd_spacing_ms * std.time.ns_per_ms;

const stdin_read_max: usize = 512;
const prompt_str: []const u8 = "mastermind> ";
const max_lua_bracket_level: u8 = 8;

pub const ParsedCommand = struct {
    msg: proto.MastermindMsg,
    target: ?[]const u8 = null,
};

pub const ReplQueue = struct {
    /// Simple spinlock between the stdin OS thread and the Io brain fiber (short critical sections).
    lock: std.atomic.Value(u32) = .init(0),
    buf: [queue_capacity][proto.lua_str_max]u8 = undefined,
    len: [queue_capacity]u16 = [_]u16{0} ** queue_capacity,
    head: usize = 0,
    count: usize = 0,

    pub fn startStdinThread(self: *ReplQueue) !void {
        const t = try std.Thread.spawn(.{}, stdinLoop, .{self});
        t.detach();
    }

    pub fn pushLine(self: *ReplQueue, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;
        const first = for (trimmed) |c| break c else return;
        if (first == '#') return;

        qlock(self);
        defer qunlock(self);

        if (self.count >= queue_capacity) {
            std.log.warn("repl: queue full, dropping line", .{});
            return;
        }

        const slot = (self.head + self.count) % queue_capacity;
        const n = @min(trimmed.len, proto.lua_str_max - 1);
        @memcpy(self.buf[slot][0..n], trimmed[0..n]);
        self.buf[slot][n] = 0;
        self.len[slot] = @intCast(n);
        self.count += 1;
    }

    /// Copies at most `drain_max_per_tick` lines into `storage`; returns slices into `storage`.
    pub fn drain(self: *ReplQueue, storage: *[drain_max_per_tick][proto.lua_str_max]u8, outs: *[drain_max_per_tick][]const u8) usize {
        qlock(self);
        defer qunlock(self);

        const k = @min(self.count, drain_max_per_tick);
        var i: usize = 0;
        while (i < k) : (i += 1) {
            const slot = (self.head + i) % queue_capacity;
            const L = self.len[slot];
            @memcpy(storage[i][0..L], self.buf[slot][0..L]);
            storage[i][L] = 0;
            outs[i] = storage[i][0..L];
        }
        self.head = (self.head + k) % queue_capacity;
        self.count -= k;
        return k;
    }
};

fn qlock(q: *ReplQueue) void {
    while (q.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.Thread.yield() catch {};
    }
}

fn qunlock(q: *ReplQueue) void {
    q.lock.store(0, .release);
}

const ReadByteError = error{ EndOfStream, ReadFailed };

fn readStdinByte() ReadByteError!u8 {
    var b: [1]u8 = undefined;
    const n = std.c.read(std.c.STDIN_FILENO, &b, 1);
    if (n < 0) return error.ReadFailed;
    if (n == 0) return error.EndOfStream;
    return b[0];
}

fn writePrompt() void {
    _ = std.c.write(std.c.STDOUT_FILENO, prompt_str.ptr, prompt_str.len);
}

fn stdinLoop(q: *ReplQueue) void {
    var line_buf: [stdin_read_max]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        if (line_len == 0) {
            writePrompt();
        }
        const b = readStdinByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (line_len > 0) q.pushLine(line_buf[0..line_len]);
                return;
            },
            else => {
                std.log.err("repl: stdin read failed: {}", .{err});
                return;
            },
        };
        if (b == '\n') {
            q.pushLine(line_buf[0..line_len]);
            line_len = 0;
            continue;
        }
        if (line_len >= line_buf.len) {
            std.log.warn("repl: line exceeds {} bytes, discarding remainder until newline", .{line_buf.len});
            line_len = 0;
            if (b != '\n') {
                while (true) {
                    const b2 = readStdinByte() catch return;
                    if (b2 == '\n') break;
                }
            }
            continue;
        }
        line_buf[line_len] = b;
        line_len += 1;
    }
}

// ─── Command parser ───────────────────────────────────────────────────────────
//
// Parses a REPL line into a ParsedCommand when the line matches a known
// command keyword. Returns null for unrecognized input (caller falls back to
// lua_exec via chat).
//
// An optional `@<name>` prefix targets a specific bot by name (bot_id or
// player_name, case-insensitive prefix match). Examples:
//   @Sangboulon ctm_move 1 2 3
//   @mage1 cast 12345
//   ctm_stop              (no prefix = broadcast)
//
// Supported commands:
//   ctm_stop
//   jump
//   ctm_move <x> <y> <z>
//   ctm_attack <guid_hex>
//   ctm_interact <guid_hex>
//   cast <spell_id> [<guid_hex>]
//   cast_ground <spell_id> <x> <y> <z>
//   face <radians>
//   walk <forward|backward|strafe_left|strafe_right> <duration_ms>
//   lua <code…>         (lua_exec sent directly, not via chat)

fn nextToken(rest: *[]const u8) ?[]const u8 {
    const s = std.mem.trimStart(u8, rest.*, " \t");
    if (s.len == 0) return null;
    const end = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
    rest.* = s[end..];
    return s[0..end];
}

fn parseF32(s: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, s) catch null;
}

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn parseGuid(s: []const u8) ?u64 {
    const stripped = if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X"))
        s[2..]
    else
        s;
    return std.fmt.parseInt(u64, stripped, 16) catch null;
}

/// Strip an optional `@<name>` prefix, returning the target name (if any) and
/// the remainder of the line. If no `@` prefix, target is null and rest is
/// the trimmed original line. A bare `@` followed by whitespace is treated as
/// no target (broadcast).
pub fn stripTarget(line: []const u8) struct { target: ?[]const u8, rest: []const u8 } {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len > 0 and trimmed[0] == '@') {
        const after_at = trimmed[1..];
        if (after_at.len == 0 or after_at[0] == ' ' or after_at[0] == '\t') {
            return .{ .target = null, .rest = trimmed };
        }
        const space_idx = std.mem.indexOfAny(u8, after_at, " \t") orelse return .{
            .target = after_at,
            .rest = "",
        };
        return .{
            .target = after_at[0..space_idx],
            .rest = std.mem.trimStart(u8, after_at[space_idx..], " \t"),
        };
    }
    return .{ .target = null, .rest = trimmed };
}

pub fn parseCommand(line: []const u8) ?ParsedCommand {
    const stripped = stripTarget(line);
    var rest: []const u8 = stripped.rest;
    const cmd = nextToken(&rest) orelse return null;

    var result: ParsedCommand = .{ .msg = undefined, .target = stripped.target };

    if (std.mem.eql(u8, cmd, "ctm_stop")) {
        result.msg = .ctm_stop;
        return result;
    }

    if (std.mem.eql(u8, cmd, "jump")) {
        result.msg = .{ .jump = 0 };
        return result;
    }

    if (std.mem.eql(u8, cmd, "ctm_move")) {
        const xs = nextToken(&rest) orelse return null;
        const ys = nextToken(&rest) orelse return null;
        const zs = nextToken(&rest) orelse return null;
        const x = parseF32(xs) orelse return null;
        const y = parseF32(ys) orelse return null;
        const z = parseF32(zs) orelse return null;
        result.msg = .{ .ctm_move = .{ .x = x, .y = y, .z = z } };
        return result;
    }

    if (std.mem.eql(u8, cmd, "ctm_attack")) {
        const gs = nextToken(&rest) orelse return null;
        const guid = parseGuid(gs) orelse return null;
        result.msg = .{ .ctm_attack_guid = .{ .guid = guid } };
        return result;
    }

    if (std.mem.eql(u8, cmd, "ctm_interact")) {
        const gs = nextToken(&rest) orelse return null;
        const guid = parseGuid(gs) orelse return null;
        result.msg = .{ .ctm_interact_guid = .{ .guid = guid } };
        return result;
    }

    if (std.mem.eql(u8, cmd, "cast")) {
        const ids = nextToken(&rest) orelse return null;
        const spell_id = parseU32(ids) orelse return null;
        if (nextToken(&rest)) |gs| {
            const guid = parseGuid(gs) orelse return null;
            result.msg = .{ .cast_spell_guid = .{ .spell_id = spell_id, .target_guid = guid } };
            return result;
        }
        result.msg = .{ .cast_spell_id = .{ .spell_id = spell_id } };
        return result;
    }

    if (std.mem.eql(u8, cmd, "cast_ground")) {
        const ids = nextToken(&rest) orelse return null;
        const xs = nextToken(&rest) orelse return null;
        const ys = nextToken(&rest) orelse return null;
        const zs = nextToken(&rest) orelse return null;
        const spell_id = parseU32(ids) orelse return null;
        const x = parseF32(xs) orelse return null;
        const y = parseF32(ys) orelse return null;
        const z = parseF32(zs) orelse return null;
        result.msg = .{ .cast_spell_ground = .{ .spell_id = spell_id, .x = x, .y = y, .z = z } };
        return result;
    }

    if (std.mem.eql(u8, cmd, "face")) {
        const rs = nextToken(&rest) orelse return null;
        const rad = parseF32(rs) orelse return null;
        result.msg = .{ .set_facing = rad };
        return result;
    }

    if (std.mem.eql(u8, cmd, "walk")) {
        const ds = nextToken(&rest) orelse return null;
        const ms_s = nextToken(&rest) orelse return null;
        const dir: proto.WalkDir = if (std.mem.eql(u8, ds, "forward"))
            .forward
        else if (std.mem.eql(u8, ds, "backward"))
            .backward
        else if (std.mem.eql(u8, ds, "strafe_left"))
            .strafe_left
        else if (std.mem.eql(u8, ds, "strafe_right"))
            .strafe_right
        else
            return null;
        const duration_ms = parseU32(ms_s) orelse return null;
        result.msg = .{ .walk = .{ .direction = dir, .duration_ms = duration_ms } };
        return result;
    }

    if (std.mem.eql(u8, cmd, "lua")) {
        const code = std.mem.trimStart(u8, rest, " \t");
        if (code.len == 0) return null;
        var buf: [proto.lua_str_max]u8 = std.mem.zeroes([proto.lua_str_max]u8);
        const n = @min(code.len, proto.lua_str_max - 1);
        @memcpy(buf[0..n], code[0..n]);
        result.msg = .{ .lua_exec = buf };
        return result;
    }

    return null;
}



// ─── Tests ────────────────────────────────────────────────────────────────────

/// Returns true if `line` contains the Lua long-string closing for bracket level `level`
/// (closing is `]` + `level` times `=` + `]`).
fn longBracketCloseInLine(line: []const u8, level: u8) bool {
    const eq_n: usize = @intCast(level);
    const need: usize = 2 + eq_n;
    if (line.len < need) return false;

    var i: usize = 0;
    while (i + need <= line.len) : (i += 1) {
        if (line[i] != ']') continue;
        var ok = true;
        for (0..eq_n) |k| {
            if (line[i + 1 + k] != '=') {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        if (line[i + 1 + eq_n] == ']') return true;
    }
    return false;
}

fn minLongBracketLevel(line: []const u8) ?u8 {
    var level: u8 = 0;
    while (level <= max_lua_bracket_level) : (level += 1) {
        if (!longBracketCloseInLine(line, level)) return level;
    }
    return null;
}

fn append(out: *[proto.lua_str_max]u8, w: *usize, chunk: []const u8) bool {
    if (w.* + chunk.len >= proto.lua_str_max) return false;
    @memcpy(out[w.*..][0..chunk.len], chunk);
    w.* += chunk.len;
    return true;
}

fn appendByte(out: *[proto.lua_str_max]u8, w: *usize, b: u8) bool {
    if (w.* + 1 >= proto.lua_str_max) return false;
    out[w.*] = b;
    w.* += 1;
    return true;
}

fn appendLongBracketOpen(out: *[proto.lua_str_max]u8, w: *usize, level: u8) bool {
    if (!appendByte(out, w, '[')) return false;
    for (0..level) |_| {
        if (!appendByte(out, w, '=')) return false;
    }
    return appendByte(out, w, '[');
}

fn appendLongBracketClose(out: *[proto.lua_str_max]u8, w: *usize, level: u8) bool {
    if (!appendByte(out, w, ']')) return false;
    for (0..level) |_| {
        if (!appendByte(out, w, '=')) return false;
    }
    return appendByte(out, w, ']');
}

/// Builds Lua that pastes `line` into the default chat edit box and sends it (GM slash, etc.).
/// Writes a null-terminated script into `out`. Returns false if the script does not fit.
pub fn lineToLuaExecChat(out: *[proto.lua_str_max]u8, line: []const u8) bool {
    if (line.len == 0) return false;

    const prefix = "local e=ChatFrame1EditBox;e:SetText(";
    const suffix = ");ChatEdit_SendText(e,0)";

    var w: usize = 0;

    if (minLongBracketLevel(line)) |level| {
        if (!append(out, &w, prefix)) return false;
        if (!appendLongBracketOpen(out, &w, level)) return false;
        if (!append(out, &w, line)) return false;
        if (!appendLongBracketClose(out, &w, level)) return false;
        if (!append(out, &w, suffix)) return false;
        out[w] = 0;
        return true;
    }

    if (!append(out, &w, prefix)) return false;
    if (!appendByte(out, &w, '"')) return false;
    for (line) |c| {
        switch (c) {
            '\\' => {
                if (!append(out, &w, "\\\\")) return false;
            },
            '"' => {
                if (!append(out, &w, "\\\"")) return false;
            },
            '\n' => {
                if (!append(out, &w, "\\n")) return false;
            },
            '\r' => {},
            else => {
                if (!appendByte(out, &w, c)) return false;
            },
        }
    }
    if (!append(out, &w, "\");ChatEdit_SendText(e,0)")) return false;
    out[w] = 0;
    return true;
}

test "parseCommand ctm_stop" {
    const cmd = parseCommand("ctm_stop").?;
    try std.testing.expectEqual(proto.MastermindMsg.ctm_stop, cmd.msg);
    try std.testing.expect(cmd.target == null);
}

test "parseCommand jump" {
    const cmd = parseCommand("jump").?;
    try std.testing.expect(cmd.msg == .jump);
    try std.testing.expect(cmd.target == null);
}

test "parseCommand ctm_move" {
    const cmd = parseCommand("ctm_move 1.5 2.5 3.5").?;
    try std.testing.expectApproxEqAbs(cmd.msg.ctm_move.x, 1.5, 0.001);
    try std.testing.expectApproxEqAbs(cmd.msg.ctm_move.y, 2.5, 0.001);
    try std.testing.expectApproxEqAbs(cmd.msg.ctm_move.z, 3.5, 0.001);
    try std.testing.expect(cmd.target == null);
}

test "parseCommand cast spell only" {
    const cmd = parseCommand("cast 12345").?;
    try std.testing.expectEqual(@as(u32, 12345), cmd.msg.cast_spell_id.spell_id);
}

test "parseCommand cast spell with guid" {
    const cmd = parseCommand("cast 12345 0xdeadbeef").?;
    try std.testing.expectEqual(@as(u32, 12345), cmd.msg.cast_spell_guid.spell_id);
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), cmd.msg.cast_spell_guid.target_guid);
}

test "parseCommand: cast_ground" {
    const cmd = parseCommand("cast_ground 12345 1.5 2.5 3.5") orelse return error.TestUnexpectedResult;
    try std.testing.expect(cmd.msg == .cast_spell_ground);
    try std.testing.expectEqual(@as(u32, 12345), cmd.msg.cast_spell_ground.spell_id);
    try std.testing.expectEqual(@as(f32, 1.5), cmd.msg.cast_spell_ground.x);
    try std.testing.expectEqual(@as(f32, 2.5), cmd.msg.cast_spell_ground.y);
    try std.testing.expectEqual(@as(f32, 3.5), cmd.msg.cast_spell_ground.z);
}

test "parseCommand walk backward" {
    const cmd = parseCommand("walk backward 2000").?;
    try std.testing.expectEqual(proto.WalkDir.backward, cmd.msg.walk.direction);
    try std.testing.expectEqual(@as(u32, 2000), cmd.msg.walk.duration_ms);
}

test "parseCommand unknown returns null" {
    try std.testing.expectEqual(@as(?ParsedCommand, null), parseCommand("/say hello"));
}

test "parseCommand lua direct" {
    const cmd = parseCommand("lua print('hi')").?;
    const code = std.mem.sliceTo(&cmd.msg.lua_exec, 0);
    try std.testing.expectEqualStrings("print('hi')", code);
}

test "parseCommand @target prefix" {
    const cmd = parseCommand("@Sangboulon ctm_move 1 2 3").?;
    try std.testing.expect(cmd.target != null);
    try std.testing.expectEqualStrings("Sangboulon", cmd.target.?);
    try std.testing.expectApproxEqAbs(cmd.msg.ctm_move.x, 1.0, 0.001);
}

test "parseCommand @target with ctm_stop" {
    const cmd = parseCommand("@mage1 ctm_stop").?;
    try std.testing.expect(cmd.target != null);
    try std.testing.expectEqualStrings("mage1", cmd.target.?);
    try std.testing.expectEqual(proto.MastermindMsg.ctm_stop, cmd.msg);
}

test "parseCommand @target with spaces" {
    const cmd = parseCommand("  @mage1   cast 12345  ").?;
    try std.testing.expect(cmd.target != null);
    try std.testing.expectEqualStrings("mage1", cmd.target.?);
    try std.testing.expectEqual(@as(u32, 12345), cmd.msg.cast_spell_id.spell_id);
}

test "stripTarget no prefix" {
    const result = stripTarget("ctm_stop");
    try std.testing.expect(result.target == null);
    try std.testing.expectEqualStrings("ctm_stop", result.rest);
}

test "stripTarget with prefix" {
    const result = stripTarget("@Sangboulon ctm_move 1 2 3");
    try std.testing.expect(result.target != null);
    try std.testing.expectEqualStrings("Sangboulon", result.target.?);
    try std.testing.expectEqualStrings("ctm_move 1 2 3", result.rest);
}

test "stripTarget @only falls back to broadcast" {
    const result = stripTarget("@ ctm_stop");
    try std.testing.expect(result.target == null);
    try std.testing.expectEqualStrings("@ ctm_stop", result.rest);
}

test "stripTarget bare @ falls back to broadcast" {
    const result = stripTarget("@");
    try std.testing.expect(result.target == null);
    try std.testing.expectEqualStrings("@", result.rest);
}

test "lineToLuaExecChat bracket form" {
    var out: [proto.lua_str_max]u8 = undefined;
    try std.testing.expect(lineToLuaExecChat(&out, ".additem 1 1"));
    const s = std.mem.sliceTo(&out, 0);
    try std.testing.expect(std.mem.indexOf(u8, s, "ChatEdit_SendText") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, ".additem 1 1") != null);
}

test "lineToLuaExecChat long string keeps embedded quotes" {
    var out: [proto.lua_str_max]u8 = undefined;
    try std.testing.expect(lineToLuaExecChat(&out, "say \"hi\""));
    const s = std.mem.sliceTo(&out, 0);
    try std.testing.expect(std.mem.indexOf(u8, s, "say \"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ChatEdit_SendText") != null);
}
