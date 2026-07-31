const std = @import("std");
const types = @import("types.zig");
const offsets = @import("offsets.zig");
const world = @import("world.zig");
const spell_packets = @import("spell_packets.zig");
const log_mod = @import("log.zig");
const gameplay_log = @import("gameplay_log.zig");

const Offsets = offsets.Offsets;

pub const opcode_msg_channel_update: u32 = 0x13A;
pub const opcode_smsg_spell_start: u32 = 0x131;
pub const opcode_smsg_spell_go: u32 = 0x132;
pub const opcode_smsg_spell_failed_other: u32 = 0x2A6;
pub const opcode_smsg_spell_failure: u32 = 0x133;
pub const opcode_smsg_spell_breaklog: u32 = 0x16C;

const capacity: usize = 1024;
const max_packet_payload_size: u32 = 4096;

const cdatastore_get_buffer_params: types.CDataStoreGetBufferParamsFn = @ptrFromInt(Offsets.CDATASTORE_GET_BUFFER_PARAMS);

pub var log_enabled: bool = false;

var lock: std.atomic.Value(bool) = .init(false);
var buf: [capacity]types.SpellEvent = undefined;
var head: usize = 0;
var count: usize = 0;
var local_player_name_buf: [32]u8 = std.mem.zeroes([32]u8);

pub fn readPacketPayload(store: *anyopaque) ?[]const u8 {
    var data: ?[*]const u8 = null;
    var size: u32 = 0;
    var alloc: u32 = 0;

    cdatastore_get_buffer_params(store, &data, &size, &alloc);
    const ptr = data orelse return null;
    if (size == 0 or size > max_packet_payload_size) return null;
    if (alloc != std.math.maxInt(u32) and size > alloc) return null;

    const words: [*]const u32 = @ptrCast(@alignCast(store));
    const base = words[2];
    const read = words[5];
    if (read == std.math.maxInt(u32) or read < base or read > size) return null;

    const off: usize = @intCast(read - base);
    const len: usize = @intCast(size - read);
    return ptr[off..][0..len];
}

pub fn handlePacket(opcode: u32, payload: []const u8) void {
    switch (opcode) {
        opcode_smsg_spell_start => {
            if (spell_packets.parseSmsgSpellStartPrefix(payload)) |event| {
                const spell_event = makeSpellEvent(.start, event.caster_guid, event.spell_id, event.flags, event.timer_ms);
                push(spell_event);
                logSpellEvent(.start, spell_event, event.cast_count, payload.len);
            } else {
                const show = @min(payload.len, 16);
                log_mod.trace("[packet] name={s} smsg_spell_start parse_failed unread={} head={any}\n", .{ localPlayerName(), payload.len, payload[0..show] });
            }
        },
        opcode_smsg_spell_go => {
            if (spell_packets.parseSmsgSpellGoPrefix(payload)) |event| {
                const spell_event = makeSpellEvent(.go, event.caster_guid, event.spell_id, event.flags, event.timestamp);
                push(spell_event);
                logSpellEvent(.go, spell_event, event.extra_casts, payload.len);
            } else {
                const show = @min(payload.len, 16);
                log_mod.trace("[packet] name={s} smsg_spell_go parse_failed unread={} head={any}\n", .{ localPlayerName(), payload.len, payload[0..show] });
            }
        },
        opcode_smsg_spell_failure => {
            if (spell_packets.parseSmsgSpellFailurePrefix(payload)) |event| {
                const spell_event = makeSpellEvent(.failed, event.caster_guid, event.spell_id, event.reason, 0);
                push(spell_event);
                logSpellEvent(.failed, spell_event, event.cast_count, payload.len);
            }
        },
        opcode_smsg_spell_failed_other => {
            if (spell_packets.parseSmsgSpellFailedOtherPrefix(payload)) |event| {
                const spell_event = makeSpellEvent(.failed, event.caster_guid, event.spell_id, 0, 0);
                push(spell_event);
                logSpellEvent(.failed, spell_event, event.cast_count, payload.len);
            }
        },
        opcode_smsg_spell_breaklog => {
            if (spell_packets.parseSmsgSpellBreakPrefix(payload)) |event| {
                const spell_event = makeSpellEvent(.interrupted, event.caster_guid, event.spell_id, 0, 0);
                push(spell_event);
                logSpellEvent(.interrupted, spell_event, 0, payload.len);
            }
        },
        opcode_msg_channel_update => {
            if (spell_packets.parseMsgChannelUpdate(payload)) |event| {
                const kind: types.SpellEventKind = if (event.remaining_ms == 0) .channel_end else .channel_update;
                const spell_event = makeSpellEvent(kind, event.caster_guid, 0, 0, event.remaining_ms);
                push(spell_event);
                logSpellEvent(kind, spell_event, 0, payload.len);
            } else {
                const show = @min(payload.len, 16);
                log_mod.info("[packet] name={s} channel_update parse_failed len={} head={any}\n", .{ localPlayerName(), payload.len, payload[0..show] });
            }
        },
        else => {},
    }
}

pub fn poll() ?types.SpellEvent {
    acquire();
    defer release();

    if (count == 0) return null;
    const event = buf[head];
    head = (head + 1) % capacity;
    count -= 1;
    return event;
}

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn release() void {
    lock.store(false, .release);
}

fn push(event: types.SpellEvent) void {
    acquire();
    defer release();

    const idx = (head + count) % capacity;
    buf[idx] = event;
    if (count < capacity) {
        count += 1;
    } else {
        head = (head + 1) % capacity;
    }
}

fn makeSpellEvent(kind: types.SpellEventKind, caster_guid: u64, spell_id: u32, flags: u32, value_ms: u32) types.SpellEvent {
    return .{
        .kind = @intFromEnum(kind),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = world.readLocalPlayerGuid() orelse 0,
        .caster_guid = caster_guid,
        .spell_id = spell_id,
        .flags = flags,
        .value_ms = value_ms,
        .game_time_ms = world.readMsTime(),
    };
}

fn logSpellEvent(kind: types.SpellEventKind, event: types.SpellEvent, extra: u32, payload_len: usize) void {
    gameplay_log.onSpellCast(kind, event, localPlayerName());
    if (!log_enabled) return;
    switch (kind) {
        .start => log_mod.info("[spell] start caster=0x{x} spell={} flags=0x{x} timer={} extra={} unread={}\n", .{
            event.caster_guid,
            event.spell_id,
            event.flags,
            event.value_ms,
            extra,
            payload_len,
        }),
        .go => log_mod.info("[spell] go caster=0x{x} spell={} flags=0x{x} ts={} extra={} unread={}\n", .{
            event.caster_guid,
            event.spell_id,
            event.flags,
            event.value_ms,
            extra,
            payload_len,
        }),
        .failed => log_mod.info("[spell] failed caster=0x{x} spell={} reason={} unread={}\n", .{
            event.caster_guid,
            event.spell_id,
            event.flags,
            payload_len,
        }),
        .interrupted => log_mod.info("[spell] interrupted caster=0x{x} spell={} unread={}\n", .{
            event.caster_guid,
            event.spell_id,
            payload_len,
        }),
        .channel_update => log_mod.info("[spell] channel_update caster=0x{x} remaining={} unread={}\n", .{
            event.caster_guid,
            event.value_ms,
            payload_len,
        }),
        .channel_end => log_mod.info("[spell] channel_end caster=0x{x} unread={}\n", .{
            event.caster_guid,
            payload_len,
        }),
    }
}

fn localPlayerName() []const u8 {
    world.readLocalPlayerName(&local_player_name_buf);
    return std.mem.sliceTo(&local_player_name_buf, 0);
}

test {
    _ = @import("spell_packets.zig");
}
