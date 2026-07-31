const std = @import("std");
const net = std.Io.net;
const proto = @import("protocol");
const types = @import("types");

const BotId = types.BotId;
const MsgQueue = types.MsgQueue;

const autologin_password_quoted = "\"bot\"";

// Minion state cadence matches `proto.minion_tick_ms` (67 ms). Durations below
// are expressed as tick counts × that interval.

// Ticks on the login glue screen before re-sending the autologin Lua (~1.7 s).
const login_retry_ticks: u32 = 25;

// Ticks after sending EnterWorld before giving up (loading failed / DC during load).
// 150 × 67 ms ≈ 10 s.
const enterworld_timeout_ticks: u32 = 150;

// Consecutive ticks of world_ready=1 required before considering the character
// truly in-world. Guards against a one-frame world_ready flicker that would
// clear enterworld_sent too early and trigger a second EnterWorld call.
const world_ready_confirm_ticks: u32 = 10;

// Ticks on character select before attempting auto EnterWorld.
// 3 × 67 ms ≈ 200 ms — enough for GetNumCharacters() to stabilise.
const char_select_enterworld_min_ticks: u32 = 3;

const glue_screen_log_repeat_interval: u32 = 15;
const glue_unknown_log_throttle_ns: u64 = 2 * std.time.ns_per_s;

// Stable reference to a slot. The generation guards against the slot being
// freed and reassigned to another connection between handle handoffs —
// a stale handle's generation will no longer match.
pub const Handle = struct {
    index: usize,
    generation: u64,
};

// A frozen view of one bot at a point in time. The brain works on a slice
// of these instead of touching the live slots — no shared mutation while
// it plans.
pub const BotSnapshot = struct {
    bot_id: BotId,
    state: proto.State,
};

pub fn findBotSnapshot(bots: []const BotSnapshot, bot_id: *const BotId) ?BotSnapshot {
    for (bots) |bot| {
        if (std.mem.eql(u8, &bot.bot_id, bot_id)) return bot;
    }
    return null;
}

pub fn botForGuid(bots: []const BotSnapshot, guid: u64) ?BotSnapshot {
    if (guid == 0) return null;
    for (bots) |bot| {
        if (bot.state.guid == guid) return bot;
    }
    return null;
}

const Slot = struct {
    queue: ?*MsgQueue = null,
    stream: ?net.Stream = null,
    bot_id: ?BotId = null,
    world_ready: bool = false,
    generation: u64 = 0,
    last_state: ?proto.State = null,
    prev_glue_screen: u32 = 0,
    glue_screen_repeats: u32 = 0,
    enterworld_sent: bool = false,
    enterworld_ticks: u32 = 0,
    world_ready_streak: u32 = 0,
    glue_unknown_log_last_ns: u64 = 0,
};

const StaleConn = struct { queue: *MsgQueue, stream: net.Stream };

pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    slots: [types.max_bots]Slot = [_]Slot{.{}} ** types.max_bots,
    next_generation: u64 = 1,
    /// When false, mastermind never queues auto EnterWorld (login autofill unchanged).
    /// Set from `WOW_MINIONS_NO_AUTO_ENTERWORLD` in main (any non-empty value disables).
    auto_enterworld: bool = true,
    /// Set from `MASTERMIND_GLUE_LOG` in main (any non-empty value enables).
    glue_log: bool = false,

    pub fn register(self: *Registry, io: std.Io, conn: net.Stream, queue: *MsgQueue) ?Handle {
        self.mutex.lock(io) catch return null;
        defer self.mutex.unlock(io);

        const index = self.findFreeSlot() orelse return null;
        const generation = self.takeGeneration();
        self.slots[index] = .{
            .queue = queue,
            .stream = conn,
            .generation = generation,
        };
        if (self.glue_log) {
            std.log.info("glue: new minion connection slot={d} gen={d}", .{ index, generation });
        }
        return .{ .index = index, .generation = generation };
    }

    pub fn unregister(self: *Registry, io: std.Io, handle: Handle) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);

        if (self.slotMatches(handle)) self.slots[handle.index] = .{};
    }

    // Reconnection: a new socket claims an existing bot_id, so the previous
    // slot is evicted. Its queue/stream are returned and closed outside the
    // critical section to avoid blocking other registry users on socket I/O.
    pub fn identify(self: *Registry, io: std.Io, handle: Handle, bot_id: BotId, world_ready: bool) void {
        if (types.isZeroBotId(&bot_id)) return;

        var stale: ?StaleConn = null;

        self.mutex.lock(io) catch return;
        if (self.slotMatches(handle)) {
            stale = self.evictDuplicate(handle.index, bot_id);
            const slot = &self.slots[handle.index];
            slot.bot_id = bot_id;
            slot.world_ready = world_ready;
        }
        self.mutex.unlock(io);

        if (stale) |s| {
            if (self.glue_log) {
                const bid = std.mem.sliceTo(&bot_id, 0);
                std.log.info("glue: identify evicted duplicate connection (same bot_id={s}); closing stale socket", .{bid});
            }
            s.queue.close(io);
            s.stream.close(io);
        }
    }

    pub fn storeState(self: *Registry, io: std.Io, handle: Handle, state: proto.State) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        if (!self.slotMatches(handle)) return;

        const slot = &self.slots[handle.index];
        slot.last_state = state;

        if (types.isZeroBotId(&state.bot_id)) {
            slot.prev_glue_screen = 0;
            slot.glue_screen_repeats = 0;
            slot.enterworld_sent = false;
            slot.enterworld_ticks = 0;
            slot.world_ready_streak = 0;
            slot.glue_unknown_log_last_ns = 0;
            return;
        }

        if (state.world_ready != 0) {
            slot.world_ready_streak += 1;
            if (self.glue_log and (slot.world_ready_streak == 1 or slot.world_ready_streak == world_ready_confirm_ticks)) {
                const bid = std.mem.sliceTo(&state.bot_id, 0);
                std.log.info("glue: slot={d} bot_id={s} world_ready streak={d}/{d}", .{
                    handle.index,
                    bid,
                    slot.world_ready_streak,
                    world_ready_confirm_ticks,
                });
            }
            if (slot.world_ready_streak >= world_ready_confirm_ticks) {
                if (self.glue_log) {
                    const bid = std.mem.sliceTo(&state.bot_id, 0);
                    std.log.info("glue: slot={d} bot_id={s} stable in-world; enterworld_sent cleared", .{ handle.index, bid });
                }
                slot.enterworld_sent = false;
                slot.enterworld_ticks = 0;
            }
            return;
        }
        slot.world_ready_streak = 0;

        // Tick the enterworld timeout while waiting for world_ready.
        // If loading takes too long (DC during load), unblock so we can retry.
        if (slot.enterworld_sent) {
            slot.enterworld_ticks += 1;
            if (slot.enterworld_ticks < enterworld_timeout_ticks) return;
            if (self.glue_log) {
                const bid = std.mem.sliceTo(&state.bot_id, 0);
                const approx_ms = @as(u64, enterworld_timeout_ticks) * @as(u64, proto.minion_tick_ms);
                std.log.info("glue: slot={d} bot_id={s} enterworld TIMEOUT after {d} ticks (~{d} ms) glue_screen={s}; retrying", .{
                    handle.index,
                    bid,
                    enterworld_timeout_ticks,
                    approx_ms,
                    glueScreenTag(state.glue_screen),
                });
            }
            slot.enterworld_sent = false;
            slot.enterworld_ticks = 0;
        }

        // Unknown/loading screen: don't update prev so a brief flicker back
        // to a known screen doesn't re-trigger the command.
        if (state.glue_screen != proto.glue_screen_unknown) {
            slot.glue_unknown_log_last_ns = 0;
        }

        if (state.glue_screen == proto.glue_screen_unknown) {
            if (self.glue_log) {
                const now_ns: u64 = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
                if (slot.glue_unknown_log_last_ns == 0 or
                    now_ns -% slot.glue_unknown_log_last_ns >= glue_unknown_log_throttle_ns)
                {
                    slot.glue_unknown_log_last_ns = now_ns;
                    const bid = std.mem.sliceTo(&state.bot_id, 0);
                    std.log.info("glue: slot={d} bot_id={s} glue_screen=unknown (log ≤1/2s) enterworld_sent={} ew_ticks={} registry_world_ready={}", .{
                        handle.index,
                        bid,
                        slot.enterworld_sent,
                        slot.enterworld_ticks,
                        slot.world_ready,
                    });
                }
            }
            return;
        }

        const prev = slot.prev_glue_screen;
        const screen_changed = prev != state.glue_screen;
        slot.prev_glue_screen = state.glue_screen;

        if (self.glue_log and screen_changed) {
            const bid = std.mem.sliceTo(&state.bot_id, 0);
            std.log.info("glue: slot={d} bot_id={s} glue_screen {s} -> {s} (repeats=0)", .{
                handle.index,
                bid,
                glueScreenTag(prev),
                glueScreenTag(state.glue_screen),
            });
        }

        if (screen_changed) {
            slot.glue_screen_repeats = 0;
            if (state.glue_screen == proto.glue_screen_character_select) return;
        } else {
            slot.glue_screen_repeats += 1;
            const threshold: u32 = if (state.glue_screen == proto.glue_screen_character_select)
                char_select_enterworld_min_ticks
            else
                login_retry_ticks;
            if (self.glue_log and state.world_ready == 0) {
                const near = slot.glue_screen_repeats == threshold -| 1;
                const every15 = slot.glue_screen_repeats % glue_screen_log_repeat_interval == 0;
                if (every15 or near) {
                    const bid = std.mem.sliceTo(&state.bot_id, 0);
                    std.log.info("glue: slot={d} bot_id={s} glue={s} repeats={d}/{d} near_send={} enterworld_sent={} ew_ticks={}", .{
                        handle.index,
                        bid,
                        glueScreenTag(state.glue_screen),
                        slot.glue_screen_repeats,
                        threshold,
                        near,
                        slot.enterworld_sent,
                        slot.enterworld_ticks,
                    });
                }
            }
            if (slot.glue_screen_repeats < threshold) return;
            slot.glue_screen_repeats = 0;
        }

        const queue = slot.queue orelse return;
        var msg: proto.MastermindMsg = .{ .lua_exec = std.mem.zeroes([proto.lua_str_max]u8) };

        switch (state.glue_screen) {
            proto.glue_screen_login => {
                _ = fillAutologinLua(&msg.lua_exec, std.mem.sliceTo(&state.bot_id, 0)) orelse return;
                if (self.glue_log) {
                    const bid = std.mem.sliceTo(&state.bot_id, 0);
                    std.log.info("glue: slot={d} bot_id={s} queue autologin Lua", .{ handle.index, bid });
                }
            },
            proto.glue_screen_character_select => {
                if (!self.auto_enterworld) {
                    if (self.glue_log) {
                        const bid = std.mem.sliceTo(&state.bot_id, 0);
                        std.log.info("glue: slot={d} bot_id={s} skip EnterWorld (WOW_MINIONS_NO_AUTO_ENTERWORLD)", .{ handle.index, bid });
                    }
                    return;
                }
                fillEnterWorldLua(&msg.lua_exec);
                slot.enterworld_sent = true;
                slot.enterworld_ticks = 0;
                if (self.glue_log) {
                    const bid = std.mem.sliceTo(&state.bot_id, 0);
                    std.log.info("glue: slot={d} bot_id={s} queue EnterWorld Lua (mastermind char_select threshold reached)", .{ handle.index, bid });
                }
            },
            else => return,
        }
        _ = queue.put(io, &.{msg}, 0) catch {};
    }

    /// Copy the current state of every identified, world-ready bot into `out`.
    /// Taken under a single lock so the brain sees a consistent slice.
    /// Returns the number of snapshots written.
    pub fn snapshot(self: *Registry, io: std.Io, out: *[types.max_bots]BotSnapshot) usize {
        self.mutex.lock(io) catch return 0;
        defer self.mutex.unlock(io);

        var n: usize = 0;
        for (&self.slots) |*slot| {
            const id = slot.bot_id orelse continue;
            if (!slot.world_ready) continue;
            const state = slot.last_state orelse continue;
            out[n] = .{ .bot_id = id, .state = state };
            n += 1;
        }
        return n;
    }

    /// Send `msg` to every identified, world-ready bot. `targets == null`
    /// broadcasts; otherwise only bots whose id is in `targets` receive it.
    /// Returns the number of queues that accepted the message.
    pub fn dispatch(self: *Registry, io: std.Io, msg: proto.MastermindMsg, targets: ?[]const BotId) usize {
        self.mutex.lock(io) catch return 0;
        defer self.mutex.unlock(io);

        var sent: usize = 0;
        const msg_tag = std.meta.activeTag(msg);
        const log_ground_cast = msg_tag == .cast_spell_ground;
        for (&self.slots) |*slot| {
            const queue = slot.queue orelse continue;
            const slot_id = slot.bot_id orelse continue;
            if (!slot.world_ready) continue;
            if (targets) |t| {
                var found = false;
                for (t) |id| {
                    if (std.mem.eql(u8, &id, &slot_id)) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }
            const written = queue.put(io, &.{msg}, 0) catch |err| {
                std.log.warn("registry: dropped {s} for {s}: {}", .{ @tagName(msg_tag), std.mem.sliceTo(&slot_id, 0), err });
                continue;
            };
            if (written == 1) {
                sent += 1;
                if (log_ground_cast) {
                    std.log.debug("registry: queued {s} for {s}", .{ @tagName(msg_tag), std.mem.sliceTo(&slot_id, 0) });
                }
            } else {
                std.log.warn("registry: queue full, dropped {s} for {s}", .{ @tagName(msg_tag), std.mem.sliceTo(&slot_id, 0) });
            }
        }
        return sent;
    }

    fn evictDuplicate(self: *Registry, keep_index: usize, bot_id: BotId) ?StaleConn {
        for (&self.slots, 0..) |*slot, i| {
            if (i == keep_index or slot.queue == null) continue;
            const id = slot.bot_id orelse continue;
            if (!std.mem.eql(u8, &id, &bot_id)) continue;

            const stale: StaleConn = .{ .queue = slot.queue.?, .stream = slot.stream.? };
            slot.* = .{};
            return stale;
        }
        return null;
    }

    fn findFreeSlot(self: *const Registry) ?usize {
        for (self.slots, 0..) |slot, i| {
            if (slot.queue == null) return i;
        }
        return null;
    }

    fn takeGeneration(self: *Registry) u64 {
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        return generation;
    }

    fn slotMatches(self: *const Registry, handle: Handle) bool {
        if (handle.index >= self.slots.len) return false;
        const slot = self.slots[handle.index];
        return slot.queue != null and slot.generation == handle.generation;
    }
};

fn glueScreenTag(v: u32) []const u8 {
    return switch (v) {
        proto.glue_screen_unknown => "unknown",
        proto.glue_screen_login => "login",
        proto.glue_screen_character_select => "char_select",
        else => "other",
    };
}

fn fillEnterWorldLua(out: *[proto.lua_str_max]u8) void {
    // Resync first slot then EnterWorld. Do not gate on IsConnectedToServer() or the
    // Enter World button — private realms often leave those in states that would block
    // forever while GetNumCharacters()>0 is already true (glue detect in hooks.zig).
    const lua =
        "if CharacterSelect_SelectCharacter and GetNumCharacters()>0 then CharacterSelect_SelectCharacter(1,1)end CharacterSelect_EnterWorld();";
    comptime std.debug.assert(lua.len < proto.lua_str_max);
    @memcpy(out[0..lua.len], lua);
    out[lua.len] = 0;
}

fn fillAutologinLua(out: *[proto.lua_str_max]u8, bot_login: []const u8) ?usize {
    const prefix = "AccountLoginAccountEdit:SetText(";
    const suffix = ");AccountLoginPasswordEdit:SetText(" ++ autologin_password_quoted ++ ");AccountLogin_Login();";

    var w: usize = 0;
    if (w + prefix.len > out.len) return null;
    @memcpy(out[w..][0..prefix.len], prefix);
    w += prefix.len;

    const quoted = appendLuaDoubleQuoted(bot_login, out[w..]) orelse return null;
    w += quoted.len;

    if (w + suffix.len >= out.len) return null;
    @memcpy(out[w..][0..suffix.len], suffix);
    w += suffix.len;
    out[w] = 0;
    w += 1;
    return w;
}

fn appendLuaDoubleQuoted(src: []const u8, dst: []u8) ?[]const u8 {
    var w: usize = 0;
    if (w + 1 > dst.len) return null;
    dst[w] = '"';
    w += 1;

    for (src) |c| {
        switch (c) {
            '\\', '"' => {
                if (w + 2 > dst.len) return null;
                dst[w] = '\\';
                dst[w + 1] = c;
                w += 2;
            },
            '\n', '\r' => {
                if (w + 1 > dst.len) return null;
                dst[w] = '_';
                w += 1;
            },
            else => {
                if (c < 32) continue;
                if (w + 1 > dst.len) return null;
                dst[w] = c;
                w += 1;
            },
        }
    }

    if (w + 1 > dst.len) return null;
    dst[w] = '"';
    w += 1;
    return dst[0..w];
}
