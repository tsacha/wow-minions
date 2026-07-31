const std = @import("std");

pub const SpellGoPrefix = struct {
    cast_item_guid: u64,
    caster_guid: u64,
    extra_casts: u8,
    spell_id: u32,
    flags: u32,
    timestamp: u32,
};

pub const SpellStartPrefix = struct {
    cast_item_guid: u64,
    caster_guid: u64,
    cast_count: u8,
    spell_id: u32,
    flags: u32,
    timer_ms: u32,
};

pub const SpellFailurePrefix = struct {
    caster_guid: u64,
    cast_count: u8,
    spell_id: u32,
    reason: u8,
};

pub const SpellFailedOtherPrefix = struct {
    caster_guid: u64,
    cast_count: u8,
    spell_id: u32,
};

pub const SpellBreakPrefix = struct {
    caster_guid: u64,
    spell_id: u32,
};

pub const ChannelUpdate = struct {
    caster_guid: u64,
    remaining_ms: u32,
};

const Reader = struct {
    buf: []const u8,
    off: usize = 0,

    fn readInt(self: *Reader, comptime T: type) ?T {
        const size = @sizeOf(T);
        if (self.off + size > self.buf.len) return null;
        const value = std.mem.readInt(T, self.buf[self.off..][0..size], .little);
        self.off += size;
        return value;
    }

    fn readByte(self: *Reader) ?u8 {
        return self.readInt(u8);
    }
};

pub fn readPackedGuid(reader: *Reader) ?u64 {
    const mask = reader.readByte() orelse return null;

    var guid: u64 = 0;
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        const bit: u3 = @intCast(i);
        if ((mask & (@as(u8, 1) << bit)) == 0) continue;
        const b = reader.readByte() orelse return null;
        guid |= @as(u64, b) << (@as(u6, i) * 8);
    }
    return guid;
}

pub fn parseSmsgSpellGoPrefix(payload: []const u8) ?SpellGoPrefix {
    var reader = Reader{ .buf = payload };
    const cast_item_guid = readPackedGuid(&reader) orelse return null;
    const caster_guid = readPackedGuid(&reader) orelse return null;
    const extra_casts = reader.readByte() orelse return null;
    const spell_id = reader.readInt(u32) orelse return null;
    const flags = reader.readInt(u32) orelse return null;
    const timestamp = reader.readInt(u32) orelse return null;

    if (spell_id == 0) return null;

    return .{
        .cast_item_guid = cast_item_guid,
        .caster_guid = caster_guid,
        .extra_casts = extra_casts,
        .spell_id = spell_id,
        .flags = flags,
        .timestamp = timestamp,
    };
}

pub fn parseSmsgSpellStartPrefix(payload: []const u8) ?SpellStartPrefix {
    var reader = Reader{ .buf = payload };
    const cast_item_guid = readPackedGuid(&reader) orelse return null;
    const caster_guid = readPackedGuid(&reader) orelse return null;
    const cast_count = reader.readByte() orelse return null;
    const spell_id = reader.readInt(u32) orelse return null;
    const flags = reader.readInt(u32) orelse return null;
    const timer_ms = reader.readInt(u32) orelse return null;

    if (spell_id == 0) return null;

    return .{
        .cast_item_guid = cast_item_guid,
        .caster_guid = caster_guid,
        .cast_count = cast_count,
        .spell_id = spell_id,
        .flags = flags,
        .timer_ms = timer_ms,
    };
}

pub fn parseSmsgSpellFailurePrefix(payload: []const u8) ?SpellFailurePrefix {
    var reader = Reader{ .buf = payload };
    const caster_guid = readPackedGuid(&reader) orelse return null;
    const cast_count = reader.readByte() orelse return null;
    const spell_id = reader.readInt(u32) orelse return null;
    const reason = reader.readByte() orelse return null;
    if (spell_id == 0) return null;

    return .{
        .caster_guid = caster_guid,
        .cast_count = cast_count,
        .spell_id = spell_id,
        .reason = reason,
    };
}

pub fn parseSmsgSpellFailedOtherPrefix(payload: []const u8) ?SpellFailedOtherPrefix {
    var reader = Reader{ .buf = payload };
    const caster_guid = readPackedGuid(&reader) orelse return null;
    const cast_count = reader.readByte() orelse return null;
    const spell_id = reader.readInt(u32) orelse return null;
    if (spell_id == 0) return null;

    return .{
        .caster_guid = caster_guid,
        .cast_count = cast_count,
        .spell_id = spell_id,
    };
}

pub fn parseSmsgSpellBreakPrefix(payload: []const u8) ?SpellBreakPrefix {
    var reader = Reader{ .buf = payload };
    const caster_guid = readPackedGuid(&reader) orelse return null;
    const spell_id = reader.readInt(u32) orelse return null;
    if (spell_id == 0) return null;

    return .{
        .caster_guid = caster_guid,
        .spell_id = spell_id,
    };
}

pub fn parseMsgChannelUpdate(payload: []const u8) ?ChannelUpdate {
    var reader = Reader{ .buf = payload };
    const caster_guid = readPackedGuid(&reader) orelse return null;
    const remaining_ms = reader.readInt(u32) orelse return null;

    return .{
        .caster_guid = caster_guid,
        .remaining_ms = remaining_ms,
    };
}

fn appendPackedGuid(out: *std.ArrayList(u8), guid: u64) !void {
    var mask: u8 = 0;
    var bytes: [8]u8 = undefined;
    var n: usize = 0;

    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        const b: u8 = @truncate(guid >> (@as(u6, i) * 8));
        if (b == 0) continue;
        const bit: u3 = @intCast(i);
        mask |= @as(u8, 1) << bit;
        bytes[n] = b;
        n += 1;
    }

    try out.append(mask);
    try out.appendSlice(bytes[0..n]);
}

test "readPackedGuid decodes sparse mask" {
    const payload = [_]u8{ 0b1000_0101, 0x34, 0x12, 0xab };
    var reader = Reader{ .buf = &payload };

    try std.testing.expectEqual(@as(u64, 0xab000000001234), readPackedGuid(&reader).?);
    try std.testing.expectEqual(@as(usize, payload.len), reader.off);
}

test "readPackedGuid rejects truncated payload" {
    const payload = [_]u8{ 0b0000_0011, 0xaa };
    var reader = Reader{ .buf = &payload };

    try std.testing.expect(readPackedGuid(&reader) == null);
}

test "parseSmsgSpellGoPrefix decodes 3.3.5 prefix" {
    var payload = std.ArrayList(u8).init(std.testing.allocator);
    defer payload.deinit();

    try appendPackedGuid(&payload, 0x1122334455667788);
    try appendPackedGuid(&payload, 0x8877665544332211);
    try payload.append(0);
    try payload.writer().writeInt(u32, 0x12345, .little);
    try payload.writer().writeInt(u32, 0x20, .little);
    try payload.writer().writeInt(u32, 0xabcdef, .little);

    const parsed = parseSmsgSpellGoPrefix(payload.items).?;
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), parsed.cast_item_guid);
    try std.testing.expectEqual(@as(u64, 0x8877665544332211), parsed.caster_guid);
    try std.testing.expectEqual(@as(u8, 0), parsed.extra_casts);
    try std.testing.expectEqual(@as(u32, 0x12345), parsed.spell_id);
    try std.testing.expectEqual(@as(u32, 0x20), parsed.flags);
    try std.testing.expectEqual(@as(u32, 0xabcdef), parsed.timestamp);
}

test "parseSmsgSpellStartPrefix decodes 3.3.5 prefix" {
    var payload = std.ArrayList(u8).init(std.testing.allocator);
    defer payload.deinit();

    try appendPackedGuid(&payload, 0x1122334455667788);
    try appendPackedGuid(&payload, 0x8877665544332211);
    try payload.append(3);
    try payload.writer().writeInt(u32, 0x12345, .little);
    try payload.writer().writeInt(u32, 0x100, .little);
    try payload.writer().writeInt(u32, 2500, .little);

    const parsed = parseSmsgSpellStartPrefix(payload.items).?;
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), parsed.cast_item_guid);
    try std.testing.expectEqual(@as(u64, 0x8877665544332211), parsed.caster_guid);
    try std.testing.expectEqual(@as(u8, 3), parsed.cast_count);
    try std.testing.expectEqual(@as(u32, 0x12345), parsed.spell_id);
    try std.testing.expectEqual(@as(u32, 0x100), parsed.flags);
    try std.testing.expectEqual(@as(u32, 2500), parsed.timer_ms);
}

test "parseSmsgSpellGoPrefix rejects truncated prefix" {
    const payload = [_]u8{ 0, 0, 0 };

    try std.testing.expect(parseSmsgSpellGoPrefix(&payload) == null);
}

test "parseSmsgSpellFailurePrefix decodes minimal payload" {
    var payload = std.ArrayList(u8).init(std.testing.allocator);
    defer payload.deinit();

    try appendPackedGuid(&payload, 0x8877665544332211);
    try payload.append(4);
    try payload.writer().writeInt(u32, 0x12345, .little);
    try payload.append(0x61);

    const parsed = parseSmsgSpellFailurePrefix(payload.items).?;
    try std.testing.expectEqual(@as(u64, 0x8877665544332211), parsed.caster_guid);
    try std.testing.expectEqual(@as(u8, 4), parsed.cast_count);
    try std.testing.expectEqual(@as(u32, 0x12345), parsed.spell_id);
    try std.testing.expectEqual(@as(u8, 0x61), parsed.reason);
}

test "parseMsgChannelUpdate decodes caster and remaining ms" {
    var payload = std.ArrayList(u8).init(std.testing.allocator);
    defer payload.deinit();

    try appendPackedGuid(&payload, 0x1122334455667788);
    try payload.writer().writeInt(u32, 900, .little);

    const parsed = parseMsgChannelUpdate(payload.items).?;
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), parsed.caster_guid);
    try std.testing.expectEqual(@as(u32, 900), parsed.remaining_ms);
}
