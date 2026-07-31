const std = @import("std");
const win32 = @import("win32");
const types = @import("types.zig");
const offsets = @import("offsets.zig");
const log = @import("log.zig").log;
const Offsets = offsets.Offsets;

// ─── Raw memory access ────────────────────────────────────────────────────────
//
// readObject / writeObject are the only entry points for touching WoW's address
// space.  Every caller must go through these so range and alignment checks are
// never skipped.
//
// The u64 split exists because GUIDs sit at 4-byte-aligned addresses inside
// WoW's descriptor arrays.  A single 8-byte load can AV when the upper half
// lands on a guard page whose address still falls inside [ptr_min, ptr_max).

pub fn readObject(comptime T: type, address: usize) ?T {
    if (!isAddressRangeReadable(address, @sizeOf(T))) return null;
    if (T == u64 and address % @alignOf(u64) != 0) {
        if (address % @alignOf(u32) != 0) return null;
        const lo = readObject(u32, address) orelse return null;
        const hi = readObject(u32, address + 4) orelse return null;
        return (@as(u64, hi) << 32) | lo;
    }
    if (address % @alignOf(T) != 0) return null;
    const ptr: *const T = @ptrFromInt(address);
    return ptr.*;
}

pub fn writeObject(comptime T: type, address: usize, value: T) !void {
    if (!isAddressRangeReadable(address, @sizeOf(T))) return error.InvalidAddress;
    if (address % @alignOf(T) != 0) return error.UnalignedAddress;
    const ptr: *T = @ptrFromInt(address);
    ptr.* = value;
}

pub var world_player_obj: std.atomic.Value(u32) = .init(0);
pub var world_object_manager: std.atomic.Value(u32) = .init(0);

pub fn setPlayerObj(obj: u32) void {
    world_player_obj.store(obj, .release);
}

pub fn setObjectManager(obj_mgr: u32) void {
    world_object_manager.store(obj_mgr, .release);
}

pub fn isWorldReady() bool {
    return world_player_obj.load(.acquire) != 0;
}

/// WoW glue checks last input time; refresh before mastermind-driven `FrameScriptExecute`.
/// Same mask as `Environment.TickCount & int.MaxValue` (tick is u32 `GetTickCount()`).
pub fn pokeLastHardwareAction() void {
    if (!@hasDecl(Offsets, "LAST_HARDWARE_ACTION")) return;

    const ticks: u32 = win32.GetTickCount() & 0x7fff_ffff;
    writeObject(u32, Offsets.LAST_HARDWARE_ACTION, ticks) catch {};
}

pub const ObjRef = struct { ptr: u32, obj_type: u16 };

const ptr_min: usize = 0x00400000;
const ptr_max: usize = 0x7F000000;

inline fn ptrValid(p: u32) bool {
    const addr = @as(usize, p);
    return addr > ptr_min and addr < ptr_max;
}

inline fn isAddressRangeReadable(address: usize, len: usize) bool {
    if (len == 0) return false;
    if (address < ptr_min or address >= ptr_max) return false;
    const end = std.math.add(usize, address, len) catch return false;
    return end <= ptr_max;
}

const max_world_coord_yards: f32 = 100_000.0;

pub inline fn coordLooksValid(v: f32) bool {
    return std.math.isFinite(v) and @abs(v) < max_world_coord_yards;
}

pub inline fn vec3LooksValid(v: types.Vec3) bool {
    return coordLooksValid(v.x) and coordLooksValid(v.y) and coordLooksValid(v.z);
}

const death_knight_class_id: u32 = 6;
const shaman_class_id: u32 = 7;
const rune_rate_min: f32 = 0.01;
const rune_ms_per_second: f32 = 1000.0;
const rune_type_count: u32 = 4;
const talent_tree_count: usize = 3;
const talent_state_tab_count: usize = 0x30;
const talent_state_tab_entries: usize = 0x34;
const talent_tab_entry_stride: usize = 0x1c;
const talent_tab_entry_points_spent: usize = 0x04;
const talent_tab_count_max: u32 = 10;

// ─── Object list iteration ────────────────────────────────────────────────────
//
// WoW's object list is a singly-linked circular list.  The list has no explicit
// sentinel node; termination is inferred from pointer values:
//
//   next_ptr outside [ptr_min, ptr_max)  →  past end / corrupted
//   next_ptr == object_manager           →  circular: wrapped to head node
//   next_ptr == first_obj                →  circular: wrapped to first real obj
//   next_ptr == obj                      →  self-loop: last object points to itself
//
// obj_type is read here (not by the caller) to avoid a double-read race: if we
// returned the raw pointer and the caller read type separately, the object could
// be freed between the two reads.  Type 0 is a WoW placeholder slot; skip it.
// Types > 7 indicate end-of-list or memory corruption; stop iteration.

pub const ObjectIterator = struct {
    next_obj: u32,
    first_obj: u32,
    count: u32,
    object_manager: u32,

    pub fn init(object_manager: u32) ObjectIterator {
        const first = readObject(u32, object_manager + Offsets.FIRST_OBJECT) orelse 0;
        return .{ .next_obj = first, .first_obj = first, .count = 0, .object_manager = object_manager };
    }

    pub fn next(self: *ObjectIterator) ?ObjRef {
        while (self.count < types.object_iteration_limit) {
            const obj = self.next_obj;
            if (obj == 0 or obj == self.object_manager) return null;

            const obj_type = readObject(u16, obj + Offsets.OBJ_TYPE) orelse return null;
            const next_ptr = readObject(u32, obj + Offsets.OBJ_NEXT) orelse return null;
            self.count += 1;

            if (!ptrValid(next_ptr) or next_ptr == obj or
                next_ptr == self.object_manager or next_ptr == self.first_obj)
            {
                self.next_obj = 0;
            } else {
                self.next_obj = next_ptr;
            }

            if (obj_type == 0 or obj_type > 7) continue;
            return .{ .ptr = obj, .obj_type = obj_type };
        }
        return null;
    }
};

// Unit descriptors live in a separate array pointed at by OBJ_UNIT_FIELDS.
// Every unit-field read is "deref the array pointer, then read at field_off".
fn unitFieldsBase(obj: u32) ?u32 {
    const fields = readObject(u32, obj + Offsets.OBJ_UNIT_FIELDS) orelse return null;
    return if (fields == 0) null else fields;
}

fn readUnitField(comptime T: type, obj: u32, field_off: usize) ?T {
    const fields = unitFieldsBase(obj) orelse return null;
    return readObject(T, fields + field_off);
}

fn readPlayerField(comptime T: type, obj: u32, field_index: usize) ?T {
    const fields = unitFieldsBase(obj) orelse return null;
    return readObject(T, fields + field_index * @sizeOf(u32));
}

pub fn readUnitStats(obj: u32) ?types.UnitStats {
    const fields = unitFieldsBase(obj) orelse return null;
    const bytes0 = readObject(u32, fields + Offsets.UNIT_BYTES_0) orelse return null;
    const power_type: u32 = @truncate(bytes0 >> 24);
    // UNIT_FIELD_POWER1..7 / UNIT_FIELD_MAXPOWER1..7 are contiguous u32 slots.
    const power_slot: usize = @as(usize, if (power_type <= 6) power_type else 0) * @sizeOf(u32);
    return .{
        .hp = readObject(u32, fields + Offsets.UNIT_HEALTH) orelse return null,
        .hp_max = readObject(u32, fields + Offsets.UNIT_MAX_HEALTH) orelse return null,
        .level = readObject(u32, fields + Offsets.UNIT_LEVEL) orelse return null,
        // Keep legacy behavior: fixed power lane (POWER1, usually mana).
        .power = readObject(u32, fields + Offsets.UNIT_POWER) orelse return null,
        .power_max = readObject(u32, fields + Offsets.UNIT_MAX_POWER) orelse return null,
        // Extra dynamic lane: follows the current form power type.
        .active_power_type = power_type,
        .active_power = readObject(u32, fields + Offsets.UNIT_POWER + power_slot) orelse return null,
        .active_power_max = readObject(u32, fields + Offsets.UNIT_MAX_POWER + power_slot) orelse return null,
    };
}

pub fn readCombatReach(obj: u32) ?f32 {
    return readUnitField(f32, obj, Offsets.UNIT_COMBAT_REACH);
}

pub fn readBoundingRadius(obj: u32) ?f32 {
    return readUnitField(f32, obj, Offsets.UNIT_BOUNDING_RADIUS);
}

pub fn readIsChanneling(obj: u32) ?u32 {
    const channel_spell = readUnitField(u32, obj, Offsets.UNIT_CHANNEL_SPELL) orelse return null;
    return @intFromBool(channel_spell != 0);
}

pub fn readIsCasting(obj: u32) ?u32 {
    const casting_spell = readObject(u32, obj + Offsets.OBJ_CASTING_SPELL) orelse return null;
    return @intFromBool(casting_spell != 0);
}

pub fn readCastingSpellId(obj: u32) ?u32 {
    return readObject(u32, obj + Offsets.OBJ_CASTING_SPELL);
}

pub fn readChannelSpellId(obj: u32) ?u32 {
    return readUnitField(u32, obj, Offsets.UNIT_CHANNEL_SPELL);
}

pub fn readSummonedByGuid(obj: u32) ?u64 {
    return readUnitField(u64, obj, Offsets.UNIT_FIELD_SUMMONEDBY);
}

pub fn readCastEndTime(obj: u32) ?u32 {
    return readObject(u32, obj + Offsets.OBJ_CAST_END_TIME);
}

pub fn readCastStartTime(obj: u32) ?u32 {
    return readObject(u32, obj + Offsets.OBJ_CAST_START_TIME);
}

pub fn readChannelEndTime(obj: u32) ?u32 {
    return readObject(u32, obj + Offsets.OBJ_CHANNEL_END_TIME);
}

pub fn readChannelStartTime(obj: u32) ?u32 {
    return readObject(u32, obj + Offsets.OBJ_CHANNEL_START_TIME);
}

pub fn readUnitFlags(obj: u32) ?u32 {
    return readUnitField(u32, obj, Offsets.UNIT_FLAGS);
}

pub fn readUnitFlags2(obj: u32) ?u32 {
    return readUnitField(u32, obj, Offsets.UNIT_FLAGS_2);
}

pub fn readClass(obj: u32) ?u32 {
    const bytes0 = readUnitField(u32, obj, Offsets.UNIT_BYTES_0) orelse return null;
    return @truncate((bytes0 >> 8) & 0xFF);
}

pub fn readShapeshiftForm(obj: u32) ?u32 {
    const suppressed = readObject(u8, obj + Offsets.OBJ_SHAPESHIFT_FORM_SUPPRESSED) orelse return null;
    if (suppressed != 0) return 0;

    const state = readObject(u32, obj + Offsets.OBJ_SHAPESHIFT_STATE_PTR) orelse return null;
    if (state == 0) return null;

    const form = readObject(u8, state + Offsets.SHAPESHIFT_STATE_FORM_ID) orelse return null;
    return form;
}

pub fn readUnitTargetGuid(obj: u32) ?u64 {
    return readUnitField(u64, obj, Offsets.UNIT_FIELD_TARGET);
}

pub fn readChannelTargetGuid(obj: u32) ?u64 {
    return readUnitField(u64, obj, Offsets.UNIT_CHANNEL_OBJECT);
}

pub fn readLocalTargetGuid() ?u64 {
    return readObject(u64, Offsets.LOCAL_TARGET_GUID);
}

pub fn readLocalPlayerGuid() ?u64 {
    return readObject(u64, Offsets.LOCAL_GUID);
}

pub fn readMapId() u32 {
    return readObject(u32, Offsets.MAP_ID) orelse 0;
}

pub fn readComboPoints() u32 {
    return readObject(u8, Offsets.COMBO_POINTS) orelse 0;
}

pub fn readComboTargetGuid() u64 {
    return readObject(u64, Offsets.COMBO_TARGET_GUID) orelse 0;
}

pub fn readRuneRegenMs(obj: u32, out: *[6]u32) bool {
    const class_id = readClass(obj) orelse return false;
    if (class_id != death_knight_class_id) return false;

    const rune_rate_base = readObject(u32, obj + Offsets.PLAYER_RUNE_RATE_PTR) orelse return false;
    if (rune_rate_base == 0) return false;

    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const timer_ms = readObject(u32, Offsets.RUNE_TIMER + i * @sizeOf(u32)) orelse return false;
        if (timer_ms == 0) {
            out[i] = 0;
            continue;
        }

        const rune_type = readObject(u32, Offsets.RUNE_TYPE_CURRENT + i * @sizeOf(u32)) orelse return false;
        if (rune_type >= rune_type_count) return false;
        const rate_addr = @as(usize, rune_rate_base) + Offsets.PLAYER_RUNE_RATE_BASE + @as(usize, rune_type) * @sizeOf(f32);
        const rate = readObject(f32, rate_addr) orelse return false;
        if (!std.math.isFinite(rate)) return false;
        const duration_ms: u32 = if (rate <= rune_rate_min)
            0
        else
            @intFromFloat(@round((1.0 / rate) * rune_ms_per_second));
        out[i] = timer_ms +| duration_ms;
    }
    return true;
}

pub fn readRuneTypes(obj: u32, out: *[6]u32) bool {
    const class_id = readClass(obj) orelse return false;
    if (class_id != death_knight_class_id) return false;

    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const rune_type = readObject(u32, Offsets.RUNE_TYPE_CURRENT + i * @sizeOf(u32)) orelse return false;
        if (rune_type >= rune_type_count) return false;
        out[i] = rune_type + 1;
    }
    return true;
}

pub fn readTotemSlots(obj: u32, now: u32) [4]types.TotemSlot {
    var slots = std.mem.zeroes([4]types.TotemSlot);
    const class_id = readClass(obj) orelse return slots;
    if (class_id != shaman_class_id) return slots;

    for (0..4) |i| {
        const base = Offsets.TOTEM_SLOT_BASE + i * Offsets.TOTEM_SLOT_STRIDE;
        const guid_lo = readObject(u32, base + Offsets.TOTEM_GUID_LOW) orelse continue;
        const guid_hi = readObject(u32, base + Offsets.TOTEM_GUID_HIGH) orelse continue;
        if (guid_lo == 0 and guid_hi == 0) continue;
        const duration_ms = readObject(i32, base + Offsets.TOTEM_DURATION_MS) orelse continue;
        const start_ms = readObject(u32, base + Offsets.TOTEM_START_TIME_MS) orelse continue;
        if (duration_ms <= 0) continue;
        const end_ms = start_ms +% @as(u32, @intCast(duration_ms));
        slots[i].remaining_ms = if (end_ms > now) end_ms - now else 0;
    }
    return slots;
}

pub fn readTalentPoints() ?types.TalentPoints {
    const group_index = readObject(u32, Offsets.TALENT_ACTIVE_GROUP) orelse return null;
    const get_talent_group_state: types.GetTalentGroupStateFn = @ptrFromInt(Offsets.GET_TALENT_GROUP_STATE);
    const state = get_talent_group_state(group_index, 0, 0);
    if (state == 0) return null;

    const tab_count = readObject(u32, state + talent_state_tab_count) orelse return null;
    if (tab_count < talent_tree_count or tab_count > talent_tab_count_max) return null;

    const entries = readObject(u32, state + talent_state_tab_entries) orelse return null;
    if (entries == 0) return null;

    var points = std.mem.zeroes([talent_tree_count]u32);
    var i: usize = 0;
    while (i < points.len) : (i += 1) {
        const entry = @as(usize, entries) + i * talent_tab_entry_stride;
        points[i] = readObject(u32, entry + talent_tab_entry_points_spent) orelse return null;
    }

    return .{ .tab1 = points[0], .tab2 = points[1], .tab3 = points[2] };
}

pub fn readGroupState() types.GroupState {
    const raid_members = readObject(u32, Offsets.RAID_MEMBER_COUNT) orelse 0;
    if (raid_members > 0) {
        return .{
            .group_size = raid_members - 1,
            .is_in_raid = 1,
        };
    }

    var party_members: u32 = 0;
    var i: usize = 0;
    while (i < Offsets.PARTY_MEMBER_GUID_SLOTS) : (i += 1) {
        const guid = readObject(u64, Offsets.PARTY_MEMBER_GUIDS + i * Offsets.PARTY_MEMBER_GUID_STRIDE) orelse 0;
        if (guid != 0) party_members += 1;
    }

    return .{
        .group_size = party_members,
        .is_in_raid = 0,
    };
}

pub fn setLocalTargetGuid(guid: u64) !void {
    return writeObject(u64, Offsets.LOCAL_TARGET_GUID, guid);
}

pub fn findObjectByGuid(object_manager: u32, guid: u64) ?u32 {
    var it = ObjectIterator.init(object_manager);
    while (it.next()) |ref| {
        const obj_guid = readObject(u64, ref.ptr + Offsets.OBJ_GUID) orelse continue;
        if (obj_guid == guid) return ref.ptr;
    }
    return null;
}

/// Player→other from `CGUnit_C::UnitReaction` (WotLK 3.3.5a 12340). Same integer as Lua `UnitReaction` when defined (1–7 typical; 8 for rep Exalted); omit/0 when nil. Call from the render thread only.
pub fn readUnitReaction(player_obj: u32, other_obj: u32) ?u32 {
    if (!ptrValid(player_obj) or !ptrValid(other_obj)) return null;
    const f: types.UnitReactionFn = @ptrFromInt(Offsets.CG_UNIT_UNIT_REACTION);
    const raw = f(player_obj, other_obj);
    if (raw < 0) return null;
    return @intCast(raw);
}

pub fn readPlayerPosition(obj: u32) ?types.Vec3 {
    return .{
        .x = readObject(f32, obj + Offsets.OBJ_X) orelse return null,
        .y = readObject(f32, obj + Offsets.OBJ_Y) orelse return null,
        .z = readObject(f32, obj + Offsets.OBJ_Z) orelse return null,
    };
}

pub fn readPlayerFacing(obj: u32) f32 {
    return readObject(f32, obj + Offsets.OBJ_FACING) orelse 0;
}

pub fn readCtmState() types.CtmState {
    return .{
        .action = readObject(u32, Offsets.CTM_ACTION) orelse 0,
        .x = readObject(f32, Offsets.CTM_POS_X) orelse 0,
        .y = readObject(f32, Offsets.CTM_POS_Y) orelse 0,
        .z = readObject(f32, Offsets.CTM_POS_Z) orelse 0,
        .guid = readObject(u64, Offsets.CTM_GUID) orelse 0,
    };
}

pub fn readMsTime() u32 {
    return readObject(u32, Offsets.GET_MS_TIME) orelse 0;
}

fn readStr(address: u32, buf: []u8) void {
    if (buf.len == 0) return;
    const base = @as(usize, address);
    var i: usize = 0;
    while (i < buf.len - 1) : (i += 1) {
        const c = readObject(u8, base + i) orelse break;
        buf[i] = c;
        if (c == 0) return;
    }
    buf[i] = 0;
}

inline fn isPrintableAscii(b: u8) bool {
    return b >= 32 and b <= 126;
}

fn nameLooksUsable(buf: []const u8) bool {
    if (buf.len == 0 or buf[0] == 0 or !isPrintableAscii(buf[0])) return false;
    var i: usize = 0;
    while (i < buf.len and buf[i] != 0) : (i += 1) {
        if (!isPrintableAscii(buf[i])) return false;
    }
    return i >= 2;
}

fn readPtrChainedNameInto(obj: u32, ptr_off: usize, str_off: usize, buf: []u8) void {
    if (buf.len > 0) buf[0] = 0;
    const p1 = readObject(u32, obj + ptr_off) orelse return;
    const p2 = readObject(u32, p1 + str_off) orelse return;
    readStr(p2, buf);
}

fn readGameObjectNameInto(obj: u32, buf: []u8) void {
    readPtrChainedNameInto(obj, Offsets.GO_NAME_PTR, Offsets.GO_NAME_STR, buf);
    if (!nameLooksUsable(buf) and buf.len > 0) buf[0] = 0;
}

// ─── Player name cache lookup ─────────────────────────────────────────────────
//
// WoW keeps a 512-bucket open-addressed hash table of player names indexed by
// the low 32 bits of the GUID.  Layout (all u32s, little-endian):
//
//   PLAYER_NAME_STORE + PLAYER_NAME_MASK_OFF  →  mask   (bucket_count - 1)
//   PLAYER_NAME_STORE + PLAYER_NAME_BASE_OFF  →  base   (pointer to bucket array)
//
// Each bucket is a 12-byte slot:
//   [0] next_off   — byte offset from base to the next bucket in the chain
//   [8] current    — pointer to the first name node in this chain
//
// Name node layout (offsets from node pointer):
//   [0]                     low_guid (u32) — used for collision resolution
//   [PLAYER_NAME_NODE_STR]  null-terminated name string
//
// The low bit of `current` is used as a "bucket empty" flag.

const player_name_bucket_size: usize = 12;
const player_name_max_probes: u32 = 32;

fn readPlayerNameInto(guid: u64, buf: []u8) void {
    if (buf.len > 0) buf[0] = 0;
    const short_guid: u32 = @truncate(guid);

    const mask = readObject(u32, Offsets.PLAYER_NAME_STORE + Offsets.PLAYER_NAME_MASK_OFF) orelse return;
    const base = readObject(u32, Offsets.PLAYER_NAME_STORE + Offsets.PLAYER_NAME_BASE_OFF) orelse return;

    const bucket = @as(usize, base) + player_name_bucket_size * @as(usize, mask & short_guid);
    const next_off = readObject(u32, bucket) orelse return;
    var current = readObject(u32, bucket + 8) orelse return;

    var probes: u32 = 0;
    while (probes < player_name_max_probes) : (probes += 1) {
        // Low bit of `current` flags an empty/sentinel bucket.
        if (current & 1 == 1) return;
        const node_guid = readObject(u32, current) orelse return;
        if (node_guid == short_guid) {
            readStr(@as(usize, current) + Offsets.PLAYER_NAME_NODE_STR, buf);
            return;
        }
        current = readObject(u32, @as(usize, current) + next_off + 4) orelse return;
    }
}

pub fn readLocalPlayerName(buf: *[32]u8) void {
    readStr(Offsets.PLAYER_NAME, buf);
}

pub fn readUnitNameInto(obj: u32, guid: u64, buf: []u8) void {
    const obj_type = readObject(u16, obj + Offsets.OBJ_TYPE) orelse {
        if (buf.len > 0) buf[0] = 0;
        return;
    };
    if (obj_type == 3) readPtrChainedNameInto(obj, Offsets.UNIT_NAME_PTR, Offsets.UNIT_NAME_STR, buf) else readPlayerNameInto(guid, buf);
}

// ─── Aura reading ─────────────────────────────────────────────────────────────
//
// WoW 3.3.5a uses a dual-table aura scheme per unit:
//
//   Table 1 (inline): small static array embedded in the unit object.
//     AURA_COUNT_1  →  u32 count  (0xFFFF_FFFF means "use table 2 instead")
//     AURA_TABLE_1  →  first aura slot (offset from obj)
//
//   Table 2 (dynamic): heap-allocated when the unit has many auras.
//     AURA_COUNT_2  →  u32 count
//     AURA_TABLE_2  →  pointer to heap aura array
//
// Each aura slot is AURA_STRUCT_SIZE bytes with fields at:
//   AURA_SPELL_ID, AURA_END_TIME (absolute server ms), AURA_CASTER_GUID,
//   AURA_STACKS.
//
// remaining_ms is computed as end_time - now; 0 when end_time ≤ now (permanent
// or already expired auras not yet removed by the server).

pub fn readAuras(obj: u32, out: []types.AuraEntry) u32 {
    const cap: u32 = @intCast(out.len);
    const count1 = readObject(u32, obj + Offsets.AURA_COUNT_1) orelse return 0;
    const count, const table = if (count1 == 0xFFFF_FFFF) .{
        readObject(u32, obj + Offsets.AURA_COUNT_2) orelse return 0,
        readObject(u32, obj + Offsets.AURA_TABLE_2) orelse return 0,
    } else .{
        count1,
        obj + @as(u32, Offsets.AURA_TABLE_1),
    };
    if (table == 0 or count == 0 or count > 0xFFFF) return 0;
    const now = readMsTime();
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < count and n < cap) : (i += 1) {
        const aura_addr = table + i * Offsets.AURA_STRUCT_SIZE;
        const sid = readObject(u32, aura_addr + Offsets.AURA_SPELL_ID) orelse continue;
        const end_time = readObject(u32, aura_addr + Offsets.AURA_END_TIME) orelse 0;
        if (sid > 0) {
            const remaining_ms = if (now > 0 and end_time > now) end_time - now else 0;
            const caster_guid = readObject(u64, aura_addr + Offsets.AURA_CASTER_GUID) orelse 0;
            const stacks = @as(u32, readObject(u8, aura_addr + Offsets.AURA_STACKS) orelse 1);
            out[n] = .{ .caster_guid = caster_guid, .spell_id = sid, .remaining_ms = remaining_ms, .stacks = stacks };
            n += 1;
        }
    }
    if (count > cap) {
        var j: u32 = cap;
        while (j < count) : (j += 1) {
            const addr = table + j * Offsets.AURA_STRUCT_SIZE;
            const sid = readObject(u32, addr + Offsets.AURA_SPELL_ID) orelse continue;
            if (sid == 28059 or sid == 28084) {
                std.log.warn("aura_read: polarity charge truncated spell={} total={} cap={}", .{ sid, count, cap });
                break;
            }
        }
    }
    return n;
}

fn blankEntry(guid: u64, obj_type: u16) types.ScanEntry {
    var e = std.mem.zeroes(types.ScanEntry);
    e.guid = guid;
    e.obj_type = obj_type;
    return e;
}

fn buildGoEntry(obj: u32, guid: u64) ?types.ScanEntry {
    var e = blankEntry(guid, 5);
    e.x = readObject(f32, obj + Offsets.GO_X) orelse 0;
    e.y = readObject(f32, obj + Offsets.GO_Y) orelse 0;
    e.z = readObject(f32, obj + Offsets.GO_Z) orelse 0;
    readGameObjectNameInto(obj, &e.name);
    return e;
}

fn buildUnitEntry(obj: u32, guid: u64, obj_type: u16) ?types.ScanEntry {
    const x = readObject(f32, obj + Offsets.OBJ_X) orelse return null;
    const y = readObject(f32, obj + Offsets.OBJ_Y) orelse return null;
    const z = readObject(f32, obj + Offsets.OBJ_Z) orelse return null;
    if (!coordLooksValid(x) or !coordLooksValid(y) or !coordLooksValid(z)) return null;
    var e = blankEntry(guid, obj_type);
    e.x = x;
    e.y = y;
    e.z = z;
    e.orientation = readObject(f32, obj + Offsets.OBJ_FACING) orelse 0;
    const player_obj = world_player_obj.load(.acquire);
    e.unit_reaction = if (player_obj != 0) readUnitReaction(player_obj, obj) orelse 0 else 0;
    e.casting_spell_id = readObject(u32, obj + Offsets.OBJ_CASTING_SPELL) orelse 0;
    e.cast_start_time_ms = readCastStartTime(obj) orelse 0;
    e.cast_end_time_ms = readCastEndTime(obj) orelse 0;
    e.channel_end_time_ms = readChannelEndTime(obj) orelse 0;
    e.channel_start_time_ms = readChannelStartTime(obj) orelse 0;
    if (unitFieldsBase(obj)) |fields| {
        e.hp = readObject(u32, fields + Offsets.UNIT_HEALTH) orelse 0;
        e.hp_max = readObject(u32, fields + Offsets.UNIT_MAX_HEALTH) orelse 0;
        e.level = readObject(u32, fields + Offsets.UNIT_LEVEL) orelse 0;
        e.unit_flags = readObject(u32, fields + Offsets.UNIT_FLAGS) orelse 0;
        e.unit_flags_2 = readObject(u32, fields + Offsets.UNIT_FLAGS_2) orelse 0;
        e.channel_spell_id = readObject(u32, fields + Offsets.UNIT_CHANNEL_SPELL) orelse 0;
        e.target_guid = readObject(u64, fields + Offsets.UNIT_FIELD_TARGET) orelse 0;
        e.combat_reach = readObject(f32, fields + Offsets.UNIT_COMBAT_REACH) orelse 0;
        e.bounding_radius = readObject(f32, fields + Offsets.UNIT_BOUNDING_RADIUS) orelse 0;
    }
    if (obj_type == 3) readPtrChainedNameInto(obj, Offsets.UNIT_NAME_PTR, Offsets.UNIT_NAME_STR, &e.name) else readPlayerNameInto(guid, &e.name);
    e.aura_count = readAuras(obj, &e.auras);
    return e;
}

// ─── Object scan ─────────────────────────────────────────────────────────────
//
// Two-pass scan so GameObjects always occupy the front of the buffer and are
// never evicted when there are many units.  The buffer is split logically:
//
//   [0 .. scan_max_go_entries)        →  reserved for type-5 GameObjects
//   [scan_max_go_entries .. buf.len)  →  units (type 3 NPC, type 4 player)
//
// Pass 1 fills GO slots; pass 2 starts writing from the GO high-water mark so
// the two populations never overlap.

pub fn scanObjects(buf: *[types.scan_max_entries]types.ScanEntry) u32 {
    const obj_mgr = world_object_manager.load(.acquire);
    if (obj_mgr == 0) return 0;
    var count: u32 = 0;

    var it = ObjectIterator.init(obj_mgr);
    while (it.next()) |ref| {
        if (ref.obj_type != 5) continue;
        if (count >= types.scan_max_go_entries) continue;
        const guid = readObject(u64, ref.ptr + Offsets.OBJ_GUID) orelse continue;
        if (guid == 0) continue;
        buf[count] = buildGoEntry(ref.ptr, guid) orelse continue;
        count += 1;
    }

    it = ObjectIterator.init(obj_mgr);
    while (it.next()) |ref| {
        if (ref.obj_type != 3 and ref.obj_type != 4) continue;
        if (count >= buf.len) break;
        const guid = readObject(u64, ref.ptr + Offsets.OBJ_GUID) orelse continue;
        if (guid == 0) continue;
        buf[count] = buildUnitEntry(ref.ptr, guid, ref.obj_type) orelse continue;
        count += 1;
    }

    return count;
}

pub var shutdown: std.atomic.Value(bool) = .init(false);

// Any early return must clear world_player_obj. During a zone transition the
// loading screen briefly nulls LOCAL_GUID and the object manager rebuilds its
// list — without the clear, isWorldReady() keeps returning true on a stale
// player pointer and the next dispatched command (CTM, Lua) crashes WoW.
pub fn update() void {
    var obj_mgr: u32 = 0;
    var player_obj: u32 = 0;
    defer {
        setObjectManager(obj_mgr);
        setPlayerObj(player_obj);
    }

    const client_connection = readObject(u32, Offsets.CLIENT_CONNECTION) orelse return;
    if (client_connection == 0) return;

    obj_mgr = readObject(u32, client_connection + Offsets.OBJECT_MANAGER) orelse return;
    if (obj_mgr == 0) return;

    const local_guid = readObject(u64, Offsets.LOCAL_GUID) orelse return;
    if (local_guid == 0) return;

    player_obj = findObjectByGuid(obj_mgr, local_guid) orelse return;
}

pub fn monitorThread() void {
    while (!shutdown.load(.acquire)) : (win32.Sleep(types.tick_ms)) {
        update();
    }
}
