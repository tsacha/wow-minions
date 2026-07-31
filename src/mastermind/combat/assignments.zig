const std = @import("std");
const types = @import("types");

const BotId = types.BotId;

const Assignment = struct {
    bot_id: BotId = std.mem.zeroes(BotId),
    tank_guid: u64 = 0,
};

var entries: [types.max_bots]Assignment = .{Assignment{}} ** types.max_bots;

pub fn assignedTankGuid(bot_id: BotId) ?u64 {
    for (&entries) |*entry| {
        if (!std.mem.eql(u8, &entry.bot_id, &bot_id)) continue;
        return if (entry.tank_guid != 0) entry.tank_guid else null;
    }
    return null;
}

pub fn setAssignedTank(bot_id: BotId, tank_guid: u64) void {
    for (&entries) |*entry| {
        if (std.mem.eql(u8, &entry.bot_id, &bot_id)) {
            entry.tank_guid = tank_guid;
            return;
        }
    }
    for (&entries) |*entry| {
        if (!types.isZeroBotId(&entry.bot_id)) continue;
        entry.* = .{ .bot_id = bot_id, .tank_guid = tank_guid };
        return;
    }
}

pub fn clearAssignedTank(bot_id: BotId) void {
    for (&entries) |*entry| {
        if (std.mem.eql(u8, &entry.bot_id, &bot_id)) {
            entry.tank_guid = 0;
            return;
        }
    }
}

pub fn reset() void {
    entries = .{Assignment{}} ** types.max_bots;
}

test "assigned tank set and reset" {
    var bot = std.mem.zeroes(BotId);
    bot[0] = 1;
    reset();
    try std.testing.expect(assignedTankGuid(bot) == null);
    setAssignedTank(bot, 0xabc);
    try std.testing.expectEqual(@as(u64, 0xabc), assignedTankGuid(bot).?);
    clearAssignedTank(bot);
    try std.testing.expect(assignedTankGuid(bot) == null);
}
