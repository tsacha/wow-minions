// TargetStore: encounters and roles write a forced target GUID per bot.
// The writer chooses whether divergence means target-only selection or a CTM
// attack/chase.
// Reset at the start of each propose phase — writers must re-write every tick.

const std = @import("std");
const types = @import("types");

const BotId = types.BotId;
const max_bots = types.max_bots;

pub const Mode = enum {
    select_only,
    attack,
};

pub const Target = struct {
    guid: u64,
    mode: Mode,
};

const Entry = struct {
    active: bool = false,
    bot_id: BotId = std.mem.zeroes(BotId),
    guid: u64 = 0,
    mode: Mode = .attack,
};

entries: [max_bots]Entry = [_]Entry{.{}} ** max_bots,

const TargetStore = @This();

pub fn set(self: *TargetStore, bot_id: BotId, guid: u64) void {
    self.setWithMode(bot_id, guid, .attack);
}

pub fn setSelectOnly(self: *TargetStore, bot_id: BotId, guid: u64) void {
    self.setWithMode(bot_id, guid, .select_only);
}

fn setWithMode(self: *TargetStore, bot_id: BotId, guid: u64, mode: Mode) void {
    for (&self.entries) |*e| {
        if (e.active and std.mem.eql(u8, &e.bot_id, &bot_id)) {
            e.guid = guid;
            e.mode = mode;
            return;
        }
    }
    for (&self.entries) |*e| {
        if (!e.active) {
            e.* = .{ .active = true, .bot_id = bot_id, .guid = guid, .mode = mode };
            return;
        }
    }
}

pub fn get(self: *const TargetStore, bot_id: BotId) ?u64 {
    const target = self.getTarget(bot_id) orelse return null;
    return target.guid;
}

pub fn getTarget(self: *const TargetStore, bot_id: BotId) ?Target {
    for (&self.entries) |e| {
        if (e.active and std.mem.eql(u8, &e.bot_id, &bot_id)) return .{ .guid = e.guid, .mode = e.mode };
    }
    return null;
}

pub fn reset(self: *TargetStore) void {
    self.entries = [_]Entry{.{}} ** max_bots;
}
