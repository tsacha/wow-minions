const std = @import("std");
const state = @import("state.zig");

pub const Side = state.Side;

const right_group = [_][]const u8{
    "Sangboulon",  "Sousbois",       "Lumibarbe",    "Griffeplume",
    "Chocazur",    "Microchoc",      "Surinette",    "Ombreboulon",
    "Pesterouage", "Cryocl\xc3\xa9", "Marteaulourd",
};

pub fn sideFromName(name: []const u8) Side {
    for (right_group) |n| {
        if (std.mem.eql(u8, name, n)) return .right;
    }
    return .left;
}
