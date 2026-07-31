//! Writes `wire_layout.json` for non-Zig consumers. Single source of truth remains
//! `protocol.zig` (`wireSize` / `readWire`); keep `writeWireSchema` in sync with
//! `wireReadWalk` / `wireSize` branches there.

const std = @import("std");
const protocol = @import("protocol");
const Dir = std.Io.Dir;
const IoWriter = std.Io.Writer;

fn writeWireSchema(w: *IoWriter, comptime T: type) IoWriter.Error!void {
    const info = @typeInfo(T);
    switch (info) {
        .int => |ii| {
            try w.print(
                "{{\"kind\":\"int\",\"signed\":{},\"bits\":{d},\"wire_bytes\":{d}}}",
                .{ ii.signedness == .signed, ii.bits, @sizeOf(T) },
            );
        },
        .float => |fi| {
            try w.print("{{\"kind\":\"float\",\"bits\":{d},\"wire_bytes\":{d}}}", .{ fi.bits, @sizeOf(T) });
        },
        .array => |a| {
            try w.print("{{\"kind\":\"array\",\"len\":{d},\"element\":", .{a.len});
            try writeWireSchema(w, a.child);
            try w.print("}}", .{});
        },
        .@"struct" => |s| {
            try w.print("{{\"kind\":\"struct\",\"wire_bytes\":{d},\"fields\":[", .{protocol.wireSize(T)});
            inline for (s.fields, 0..) |f, i| {
                if (i != 0) try w.writeByte(',');
                try w.print("{{\"name\":\"{s}\",\"schema\":", .{f.name});
                try writeWireSchema(w, f.type);
                try w.print("}}", .{});
            }
            try w.print("]}}", .{});
        },
        .void => try w.writeAll("{\"kind\":\"void\",\"wire_bytes\":0}"),
        .@"enum" => |e| try writeWireSchema(w, e.tag_type),
        else => @compileError("writeWireSchema: unsupported " ++ @typeName(T)),
    }
}

fn writeEnumValues(w: *IoWriter, comptime E: type) IoWriter.Error!void {
    try w.writeByte('[');
    inline for (std.meta.fields(E), 0..) |f, i| {
        if (i != 0) try w.writeByte(',');
        const ev: E = @field(E, f.name);
        try w.print("{{\"name\":\"{s}\",\"value\":{d}}}", .{ f.name, @intFromEnum(ev) });
    }
    try w.writeByte(']');
}

fn netCmdVariantWireBytes(comptime tag: protocol.NetCmd) usize {
    const Field = @FieldType(protocol.MastermindMsg, @tagName(tag));
    return protocol.wireSize(Field);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var args_it = try init.minimal.args.iterateAllocator(init.gpa);
    defer args_it.deinit();
    _ = args_it.skip();
    const out_path = args_it.next() orelse {
        std.debug.print("usage: gen-wire-manifest <path/to/wire_layout.json>\n", .{});
        return error.Usage;
    };

    const path_slice: []const u8 = out_path;
    if (std.fs.path.dirname(path_slice)) |parent| {
        try Dir.cwd().createDirPath(io, parent);
    }

    var file = try Dir.cwd().createFile(io, path_slice, .{});
    defer file.close(io);

    var stack_buf: [786432]u8 = undefined;
    var fw = file.writer(io, &stack_buf);
    const w: *IoWriter = &fw.interface;

    try w.writeAll(
        \\{"format_version":1
    );

    try w.writeAll(",\"frame\":{");
    try w.print("\"length_field_be\":true,\"length_bytes\":{d}", .{protocol.frame_length_size});
    try w.print(",\"type_byte_offset\":{d}", .{protocol.frame_length_size});
    try w.writeAll(",\"length_includes_type_byte\":true");
    try w.writeAll(",\"payload_endian\":\"little\"");
    try w.writeAll("}");

    try w.writeAll(",\"constants\":{");
    try w.print("\"bot_id_len\":{d}", .{protocol.bot_id_len});
    try w.print(",\"lua_str_max\":{d}", .{protocol.lua_str_max});
    try w.print(",\"scan_max_entries\":{d}", .{protocol.scan_max_entries});
    try w.print(",\"scan_header_size\":{d}", .{protocol.scan_header_size});
    try w.print(",\"frame_header_size\":{d}", .{protocol.frame_header_size});
    try w.print(",\"max_auras\":{d}", .{protocol.max_auras});
    try w.print(",\"max_scan_auras\":{d}", .{protocol.max_scan_auras});
    try w.print(",\"max_cooldowns\":{d}", .{protocol.max_cooldowns});
    try w.print(",\"max_spell_ranges\":{d}", .{protocol.max_spell_ranges});
    try w.print(",\"max_target_threats\":{d}", .{protocol.max_target_threats});
    try w.print(",\"state_payload_size\":{d}", .{protocol.state_payload_size});
    try w.print(",\"scan_entry_wire_bytes\":{d}", .{protocol.wireSize(protocol.ScanEntry)});
    try w.print(",\"scan_max_payload_bytes\":{d}", .{protocol.scan_payload_size});
    try w.print(",\"wire_size_State\":{d}", .{protocol.wireSize(protocol.State)});
    try w.print(",\"wire_size_ScanEntry\":{d}", .{protocol.wireSize(protocol.ScanEntry)});
    try w.print(",\"wire_size_AuraEntry\":{d}", .{protocol.wireSize(protocol.AuraEntry)});
    try w.print(",\"wire_size_CooldownEntry\":{d}", .{protocol.wireSize(protocol.CooldownEntry)});
    try w.print(",\"wire_size_SpellRangeEntry\":{d}", .{protocol.wireSize(protocol.SpellRangeEntry)});
    try w.print(",\"wire_size_SpellEvent\":{d}", .{protocol.wireSize(protocol.SpellEvent)});
    try w.print(",\"wire_size_MastermindMsg_union_max\":{d}", .{protocol.wireSize(protocol.MastermindMsg)});
    try w.print(",\"wire_size_CtmMoveCmd\":{d}", .{protocol.wireSize(protocol.CtmMoveCmd)});
    try w.print(",\"wire_size_CtmGuidCmd\":{d}", .{protocol.wireSize(protocol.CtmGuidCmd)});
    try w.print(",\"wire_size_CastSpellIdCmd\":{d}", .{protocol.wireSize(protocol.CastSpellIdCmd)});
    try w.print(",\"wire_size_CastSpellGuidCmd\":{d}", .{protocol.wireSize(protocol.CastSpellGuidCmd)});
    try w.print(",\"wire_size_TalentPoints\":{d}", .{protocol.wireSize(protocol.TalentPoints)});
    try w.writeAll("}");

    try w.writeAll(",\"enums\":{");
    try w.writeAll("\"MinionMsg\":");
    try writeEnumValues(w, protocol.MinionMsg);
    try w.writeAll(",\"NetCmd\":");
    try writeEnumValues(w, protocol.NetCmd);
    try w.writeAll(",\"SpellEventKind\":");
    try writeEnumValues(w, protocol.SpellEventKind);
    try w.writeAll("}");

    try w.writeAll(",\"schemas\":{");
    try w.writeAll("\"State\":");
    try writeWireSchema(w, protocol.State);
    try w.writeAll(",\"ScanEntry\":");
    try writeWireSchema(w, protocol.ScanEntry);
    try w.writeAll(",\"AuraEntry\":");
    try writeWireSchema(w, protocol.AuraEntry);
    try w.writeAll(",\"CooldownEntry\":");
    try writeWireSchema(w, protocol.CooldownEntry);
    try w.writeAll(",\"SpellRangeEntry\":");
    try writeWireSchema(w, protocol.SpellRangeEntry);
    try w.writeAll(",\"SpellEvent\":");
    try writeWireSchema(w, protocol.SpellEvent);
    try w.writeAll(",\"TalentPoints\":");
    try writeWireSchema(w, protocol.TalentPoints);
    try w.writeAll(",\"CtmMoveCmd\":");
    try writeWireSchema(w, protocol.CtmMoveCmd);
    try w.writeAll(",\"CtmGuidCmd\":");
    try writeWireSchema(w, protocol.CtmGuidCmd);
    try w.writeAll(",\"CastSpellIdCmd\":");
    try writeWireSchema(w, protocol.CastSpellIdCmd);
    try w.writeAll(",\"CastSpellGuidCmd\":");
    try writeWireSchema(w, protocol.CastSpellGuidCmd);
    try w.writeAll("}");

    try w.writeAll(",\"minion_to_mastermind\":{");
    try w.writeAll("\"framing_note\":\"Each frame is [u32 BE length][u8 MinionMsg][payload]. length includes the type byte; payload size = length - 1.\"");
    try w.writeAll(",\"state\":{\"payload_schema\":\"State\",\"fixed_wire_bytes\":");
    try w.print("{d}", .{protocol.state_payload_size});
    try w.writeAll("}");
    try w.writeAll(",\"scan\":{\"map_id\":{\"kind\":\"int\",\"signed\":false,\"bits\":32,\"wire_bytes\":4}");
    try w.writeAll(",\"entries\":{\"kind\":\"array\",\"repeat\":\"until_end_of_payload\"");
    try w.print(",\"element_wire_bytes\":{d}", .{protocol.wireSize(protocol.ScanEntry)});
    try w.writeAll(",\"element_schema\":\"ScanEntry\"}}");
    try w.writeAll(",\"lua_result\":{\"payload_kind\":\"opaque_bytes\",\"note\":\"Variable-length body; minion sends raw bytes after header (UTF-8 or arbitrary).\"}");
    try w.writeAll(",\"spell_event\":{\"payload_schema\":\"SpellEvent\",\"fixed_wire_bytes\":");
    try w.print("{d}", .{protocol.wireSize(protocol.SpellEvent)});
    try w.writeAll("}");
    try w.writeAll("}");

    try w.writeAll(",\"mastermind_to_minion\":{");
    try w.writeAll("\"framing_note\":\"Same outer frame. After the 4-byte length field: [u8 NetCmd][body]. body is readWire(Field); there is no second tag byte inside body.\"");
    try w.writeAll(",\"variants\":[");
    inline for (std.meta.fields(protocol.NetCmd), 0..) |f, vi| {
        if (vi != 0) try w.writeByte(',');
        const tag: protocol.NetCmd = @field(protocol.NetCmd, f.name);
        const wire_body = netCmdVariantWireBytes(tag);
        const Field = @FieldType(protocol.MastermindMsg, f.name);
        try w.print("{{\"cmd\":\"{s}\",\"value\":{d},\"body_wire_bytes\":{d}", .{
            f.name,
            @intFromEnum(tag),
            wire_body,
        });
        try w.writeAll(",\"body_type\":\"");
        try w.writeAll(@typeName(Field));
        try w.writeAll("\",\"body_schema\":");
        try writeWireSchema(w, Field);
        try w.writeAll("}");
    }
    try w.writeAll("]}");

    try w.writeByte('}');
    try w.writeByte('\n');
    try fw.flush();
}
