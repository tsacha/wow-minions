const std = @import("std");
const proto = @import("protocol");
const build_options = @import("build_options");

pub const max_bots: usize = build_options.max_bots;

pub const queue_capacity: usize = 128;

pub const BotId = [proto.bot_id_len]u8;
pub const MsgQueue = std.Io.Queue(proto.MastermindMsg);

pub fn isZeroBotId(bot_id: *const BotId) bool {
    return std.mem.allEqual(u8, bot_id, 0);
}
