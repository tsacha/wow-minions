const std = @import("std");
const proto = @import("protocol");
const types = @import("types");

pub const capacity: usize = 32;

pub const Line = struct {
    bot_id: types.BotId,
    text: [proto.lua_str_max]u8,
    len: usize,
};

pub const Buffer = struct {
    lines: [capacity]Line = undefined,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),

    pub fn push(self: *Buffer, bot_id: types.BotId, text: []const u8) void {
        const tail = self.tail.load(.monotonic);
        const next = (tail + 1) % capacity;
        // If full, overwrite oldest (advance head).
        if (next == self.head.load(.acquire)) {
            _ = self.head.fetchAdd(1, .monotonic);
        }
        var line: Line = undefined;
        line.bot_id = bot_id;
        const n = @min(text.len, proto.lua_str_max);
        @memcpy(line.text[0..n], text[0..n]);
        line.len = n;
        self.lines[tail] = line;
        self.tail.store(next, .release);
    }

    pub fn drain(self: *Buffer, out: []Line) []Line {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        var n: usize = 0;
        var h = head;
        while (h != tail and n < out.len) {
            out[n] = self.lines[h];
            h = (h + 1) % capacity;
            n += 1;
        }
        self.head.store(h, .release);
        return out[0..n];
    }
};
