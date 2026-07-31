const std = @import("std");

pub fn commandLogEnabled() bool {
    const v = std.c.getenv("MASTERMIND_LOG_GUI_COMMANDS") orelse return false;
    return std.mem.span(v).len > 0;
}
