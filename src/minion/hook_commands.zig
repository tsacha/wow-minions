const std = @import("std");
const types = @import("types.zig");

pub const Payload = union(types.Cmd) {
    none: void,
    move: types.Vec3,
    stop: void,
    guid_action: struct { action: types.CtmAction, guid: u64 },
    cast_spell_id: u32,
    cast_spell_guid: struct { spell_id: u32, target_guid: u64 },
    cast_spell_ground: struct { spell_id: u32, x: f32, y: f32, z: f32 },
    jump: void,
    set_facing: f32,
    walk: types.WalkCmd,
    walk_stop_all: void,
    set_target_guid: u64,
};

const seq_writing_bit: u32 = 1;
const seq_max_read_retries: u32 = 8;

var seq: std.atomic.Value(u32) = .init(0);
var publish_gen: u32 = 0;
var consumed_gen: u32 = 0;
var slot_gen: u32 = 0;
var slot: Payload = .{ .none = {} };

pub fn publish(payload: Payload) void {
    publish_gen +%= 1;
    _ = seq.fetchAdd(1, .acq_rel);
    slot_gen = publish_gen;
    slot = payload;
    _ = seq.fetchAdd(1, .acq_rel);
}

pub fn poll() ?Payload {
    var attempt: u32 = 0;
    while (attempt < seq_max_read_retries) : (attempt += 1) {
        const s1 = seq.load(.acquire);
        if (s1 & seq_writing_bit != 0) continue;
        const gen = slot_gen;
        const snap = slot;
        const s2 = seq.load(.acquire);
        if (s1 != s2) continue;
        if (gen == consumed_gen) return null;
        consumed_gen = gen;
        return snap;
    }
    return null;
}
