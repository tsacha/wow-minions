const std = @import("std");
const types = @import("types");

pub const capacity: usize = 64;

pub const max_ctm_targets: usize = types.max_bots;
pub const BotId = types.BotId;

// Must match proto.lua_str_max — asserted in brain.zig at comptime.
pub const lua_code_max: usize = 256;

pub const GuiCommand = union(enum) {
    navigate_to: struct {
        bot_ids: [max_ctm_targets]BotId,
        bot_count: u8,
        append: bool,
        map_id: u32,
        x: f32,
        y: f32,
        z: f32,
    },
    /// User submitted a Lua snippet from the in-GUI console.
    /// `is_get = true`  → lua_get  (expression, result expected)
    /// `is_get = false` → lua_exec (statement, fire-and-forget)
    lua_exec: struct {
        bot_ids: [max_ctm_targets]BotId,
        bot_count: u8,
        code: [lua_code_max]u8,
        is_get: bool,
    },
    operator_spec_action: struct {
        kind: OperatorSpellKind,
        map_id: u32,
        bot_ids: [max_ctm_targets]BotId,
        bot_count: u8,
    },
};

pub const OperatorSpellKind = enum {
    raid_buff,
    burst,
};

pub const Queue = struct {
    buf: [capacity]GuiCommand = undefined,
    tail: std.atomic.Value(usize) = .init(0),
    head: std.atomic.Value(usize) = .init(0),
    /// Set by GUI when the operator clicks Start fight; cleared by brain after reading.
    start_fight: std.atomic.Value(bool) = .init(false),
    /// Set by GUI when the operator clicks Clean orders; cleared by brain after reading.
    clean_orders: std.atomic.Value(bool) = .init(false),
    /// Set by GUI when the operator clicks Reset fight; cleared by brain after reading.
    reset_fight: std.atomic.Value(bool) = .init(false),
    /// Set by GUI when the operator clicks Test jump; cleared by brain after reading.
    test_jump: std.atomic.Value(bool) = .init(false),
    /// Set by GUI when the operator clicks Start formation; cleared by brain after reading.
    start_formation: std.atomic.Value(bool) = .init(false),

    pub fn pushStartFight(self: *Queue) void {
        self.start_fight.store(true, .release);
    }

    pub fn pushCleanOrders(self: *Queue) void {
        self.clean_orders.store(true, .release);
    }

    pub fn pushResetFight(self: *Queue) void {
        self.reset_fight.store(true, .release);
    }

    pub fn pushTestJump(self: *Queue) void {
        self.test_jump.store(true, .release);
    }

    pub fn pushStartFormation(self: *Queue) void {
        self.start_formation.store(true, .release);
    }

    /// Returns true if a start_fight was pending (clears the flag).
    pub fn consumeStartFight(self: *Queue) bool {
        return self.start_fight.swap(false, .acq_rel);
    }

    /// Returns true if a clean_orders was pending (clears the flag).
    pub fn consumeCleanOrders(self: *Queue) bool {
        return self.clean_orders.swap(false, .acq_rel);
    }

    /// Returns true if a reset_fight was pending (clears the flag).
    pub fn consumeResetFight(self: *Queue) bool {
        return self.reset_fight.swap(false, .acq_rel);
    }

    /// Returns true if a test_jump was pending (clears the flag).
    pub fn consumeTestJump(self: *Queue) bool {
        return self.test_jump.swap(false, .acq_rel);
    }

    /// Returns true if a start_formation was pending (clears the flag).
    pub fn consumeStartFormation(self: *Queue) bool {
        return self.start_formation.swap(false, .acq_rel);
    }

    pub fn push(self: *Queue, cmd: GuiCommand) bool {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        const next = (tail + 1) % capacity;
        if (next == head) return false;
        self.buf[tail] = cmd;
        self.tail.store(next, .release);
        return true;
    }

    pub fn drain(self: *Queue, out: *[capacity]GuiCommand) []const GuiCommand {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        var n: usize = 0;
        var h = head;
        while (h != tail and n < out.len) {
            out[n] = self.buf[h];
            h = (h + 1) % capacity;
            n += 1;
        }
        self.head.store(h, .release);
        return out[0..n];
    }
};
