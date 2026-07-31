const std = @import("std");

// ─── Connection ───────────────────────────────────────────────────────────────

pub const mastermind_port: u16 = 9000;
pub const pipe_name = "\\\\.\\pipe\\minion_log";

// ─── Timing ──────────────────────────────────────────────────────────────────
// Suffix = unit. `_ms` = milliseconds, `_ticks` = a count of the reference
// clock named in the prefix. Derived values are written in terms of their
// inputs so the relationship is visible at a glance.

// Minion monitor thread cadence.
pub const minion_tick_ms: u32 = 67;

// Minion → mastermind: full object scan every N monitor ticks.
pub const minion_scan_period_ticks: u32 = 1;
pub const minion_scan_period_ms: u32 = minion_tick_ms * minion_scan_period_ticks; // 2_000 ms

// Mastermind brain: one planning tick every N monitor ticks.
pub const brain_tick_period_ticks: u32 = 1;
pub const brain_tick_ms: u32 = minion_tick_ms * brain_tick_period_ticks;

// Mastermind brain: prune stale world memory every N brain ticks.
pub const brain_prune_period_ticks: u32 = 10;
pub const brain_prune_period_ms: u32 = brain_tick_ms * brain_prune_period_ticks; // 30_000 ms

// Minion DLL: wait for D3D to come up before hooking EndScene.
pub const hook_init_delay_ms: u32 = 2000;

// Minion: render-thread result deadline. Results typically land within one frame
// (~67 ms at 15 fps); the control thread polls once per tick (non-blocking) and
// gives up after this window.
pub const render_poll_timeout_ms: u32 = 500;

// ─── Sizing constants ─────────────────────────────────────────────────────────

pub const bot_id_len: usize = 32;
pub const scan_max_entries: usize = 400;
pub const max_target_threats: usize = 40;

// Minion → mastermind: `State.glue_screen` when `world_ready == 0` (glue UI).
pub const glue_screen_unknown: u32 = 0;
pub const glue_screen_login: u32 = 1;
pub const glue_screen_character_select: u32 = 2;
pub const frame_length_size: usize = 4; // u32 big-endian payload length
pub const frame_header_size: usize = frame_length_size + 1; // + 1 byte type

// ─── Framing ─────────────────────────────────────────────────────────────────
//
// Every frame sent in both directions:
//
//   ┌──────────────────┬──────────┬──────────────────────────────┐
//   │  length (u32 BE) │ type(u8) │  payload (little-endian)     │
//   └──────────────────┴──────────┴──────────────────────────────┘
//    ←─── 4 bytes ────→ ← 1 byte→ ←── length - 1 bytes ────────→
//
// `length` includes the type byte, so payload size = length - 1.
//
// All payload fields are serialized field-by-field with no ABI padding.
// Use readWire(T, buf) / wireSize(T) instead of @sizeOf(T) for this reason.

// ─── Message types (minion → mastermind) ─────────────────────────────────────

pub const MinionMsg = enum(u8) {
    state = 0x00,
    scan = 0x01,
    lua_result = 0x02,
    spell_event = 0x03,
};

// ─── Command types (mastermind → minion) ─────────────────────────────────────
//
// All commands share the common frame header: [u32 BE length][u8 type].
// Variable-length commands (lua_exec, lua_get) carry a null-terminated string
// as payload. Fixed-length commands have a typed struct below.

pub const NetCmd = enum(u8) {
    lua_exec = 0,
    ctm_move = 1,
    lua_get = 2,
    ctm_interact_guid = 3,
    ctm_attack_guid = 4,
    cast_spell_id = 5,
    cast_spell_guid = 6,
    cast_spell_ground = 12,
    jump = 7,
    ctm_stop = 8,
    /// World radians written to the local player `OBJ_FACING` on the render thread.
    set_facing = 9,
    /// Directional walk for a fixed duration using game movement functions.
    walk = 10,
    /// Select a unit by GUID without issuing a click-to-move attack.
    set_target_guid = 11,
};

pub const lua_str_max: usize = 256;

pub const MastermindMsg = union(NetCmd) {
    lua_exec: [lua_str_max]u8, // null-terminated
    ctm_move: CtmMoveCmd,
    lua_get: [lua_str_max]u8, // null-terminated
    ctm_interact_guid: CtmGuidCmd,
    ctm_attack_guid: CtmGuidCmd,
    cast_spell_id: CastSpellIdCmd,
    cast_spell_guid: CastSpellGuidCmd,
    cast_spell_ground: CastSpellGroundCmd,
    jump: u8, // no args
    ctm_stop: void, // no args
    set_facing: f32,
    walk: WalkCmd,
    set_target_guid: CtmGuidCmd,
};

// CtmMoveCmd — 12 bytes on the wire
//
//   ┌───────────────┬───────────────┬───────────────┐
//   │   x (f32)     │   y (f32)     │   z (f32)     │
//   └───────────────┴───────────────┴───────────────┘
//    ←── 4 bytes ──→ ←── 4 bytes ──→ ←── 4 bytes ──→

pub const CtmMoveCmd = extern struct {
    x: f32,
    y: f32,
    z: f32,
};

// CtmGuidCmd — 8 bytes on the wire (used by GUID-targeted commands)
//
//   ┌──────────────────────┐
//   │      guid (u64)      │
//   └──────────────────────┘
//    ←────── 8 bytes ──────→

pub const CtmGuidCmd = extern struct {
    guid: u64,
};

// CastSpellIdCmd — 4 bytes on the wire
//
//   ┌───────────────────┐
//   │  spell_id (u32)   │
//   └───────────────────┘
//    ←──── 4 bytes ─────→

pub const CastSpellIdCmd = extern struct {
    spell_id: u32,
};

// CastSpellGuidCmd — 12 bytes on the wire
//
//   ┌───────────────────┬──────────────────────┐
//   │  spell_id (u32)   │   target_guid (u64)  │
//   └───────────────────┴──────────────────────┘
//    ←──── 4 bytes ─────→ ←────── 8 bytes ─────→

pub const CastSpellGuidCmd = extern struct {
    spell_id: u32,
    target_guid: u64,
};

// CastSpellGroundCmd — 16 bytes on the wire
//
//   ┌───────────────────┬───────────────┬───────────────┬───────────────┐
//   │  spell_id (u32)   │   x (f32)     │   y (f32)     │   z (f32)     │
//   └───────────────────┴───────────────┴───────────────┴───────────────┘
//    ←──── 4 bytes ─────→ ←── 4 bytes ─→ ←── 4 bytes ─→ ←── 4 bytes ─→

pub const CastSpellGroundCmd = extern struct {
    spell_id: u32,
    x: f32,
    y: f32,
    z: f32,
};

// WalkDir / WalkCmd — 8 bytes on the wire
//
//   ┌───────────┬────────────┬───────────────────┐
//   │ dir (u8)  │  pad (3B)  │ duration_ms (u32) │
//   └───────────┴────────────┴───────────────────┘
//    ← 1 byte → ← 3 bytes → ←──── 4 bytes ──────→

pub const WalkDir = enum(u8) { forward, backward, strafe_left, strafe_right };

pub const WalkCmd = extern struct {
    direction: WalkDir,
    _pad: [3]u8 = .{0} ** 3,
    duration_ms: u32,
};

// TalentPoints — 12 bytes on the wire (one entry per talent tree)
//
//   ┌───────────────┬───────────────┬───────────────┐
//   │  tab1 (u32)   │  tab2 (u32)   │  tab3 (u32)   │
//   └───────────────┴───────────────┴───────────────┘

pub const TalentPoints = extern struct {
    tab1: u32,
    tab2: u32,
    tab3: u32,
};

pub const UnitFlag = enum(u32) {
    server_controlled = 0x00000001,
    non_attackable = 0x00000002,
    remove_client_ctrl = 0x00000004,
    player_controlled = 0x00000008,
    rename = 0x00000010,
    preparation = 0x00000020,
    unk_6 = 0x00000040,
    /// With `player_controlled`, marks a PC that cannot be attacked (e.g. unflagged friendly).
    not_attackable_1 = 0x00000080,
    immune_to_pc = 0x00000100,
    immune_to_npc = 0x00000200,
    pvp_enabling = 0x00001000,
    silenced = 0x00002000,
    cannot_swim = 0x00004000,
    can_swim = 0x00008000,
    non_attackable_2 = 0x00010000,
    pacified = 0x00020000,
    stunned = 0x00040000,
    in_combat = 0x00080000,
    on_taxi = 0x00100000,
    disarmed = 0x00200000,
    confused = 0x00400000,
    fleeing = 0x00800000,
    possessed = 0x01000000,
    uninteractible = 0x02000000,
    skinnable = 0x04000000,
    mounted = 0x08000000,
    immune = 0x80000000,
    _,
};

pub fn hasUnitFlag(flags: u32, flag: UnitFlag) bool {
    return (flags & @intFromEnum(flag)) != 0;
}

/// `UNIT_FIELD_FLAGS_2` — separate bitmask from `UnitFlag`; do not OR the two into one u32.
pub const UnitFlag2 = enum(u32) {
    feign_death = 0x00000001,
    hide_body = 0x00000002,
    mirror_image = 0x00000010,
    _,
};

pub fn hasUnitFlag2(flags: u32, flag: UnitFlag2) bool {
    return (flags & @intFromEnum(flag)) != 0;
}

pub const CtmAction = enum(u32) {
    move = 0x4,
    interact_npc = 0x5,
    loot = 0x6,
    interact_obj = 0x7,
    skin = 0x9,
    attack_pos = 0xA,
    attack = 0xB,
    idle = 0xD,
};

// ─── Wire structs ─────────────────────────────────────────────────────────────
//
// All structs below are declared `extern` to minimize ABI padding, but their
// on-wire size (wireSize) may still differ from @sizeOf due to tail padding.
// Always use readWire / wireSize when reading from or sizing a buffer.

// cmangos `MAX_AURAS` (SpellAuraDefines.h): one shared slot pool of 64 for buffs
// and debuffs combined, allocated first-free from slot 0. A self-reported aura cap
// below 64 silently drops auras parked in high slots (e.g. the Thaddius polarity
// charge marker on a heavily-buffed bot), so both the StateMsg and scan caps match it.
pub const max_server_auras: usize = 64;
pub const max_auras: usize = max_server_auras;
pub const max_scan_auras: usize = max_server_auras;
pub const max_cooldowns: usize = 256;
pub const max_spell_ranges: usize = 256;

pub const SpellEventKind = enum(u8) {
    start = 1,
    go = 2,
    failed = 3,
    interrupted = 4,
    channel_update = 5,
    channel_end = 6,
};

// SpellEvent — 36 bytes on the wire
//
//   ┌─────────┬───────────────┬──────────────────────┬──────────────────────┐
//   │ kind u8 │ _pad [3]u8    │ observer_guid (u64)  │ caster_guid (u64)    │
//   ├─────────┴───────────────┼──────────────────────┼──────────────────────┤
//   │ spell_id (u32)          │ flags (u32)          │ value_ms (u32)       │
//   ├─────────────────────────┴──────────────────────┴──────────────────────┤
//   │ game_time_ms (u32)                                                    │
//   └───────────────────────────────────────────────────────────────────────┘

pub const SpellEvent = extern struct {
    kind: u8,
    _pad: [3]u8,
    observer_guid: u64,
    caster_guid: u64,
    spell_id: u32,
    /// Packet-specific detail: spell flags for start/go, failure code for failed,
    /// zero for interrupt / channel_end, and zero for channel_update.
    flags: u32,
    /// Packet-specific timing detail: cast/channel timer for start, server timestamp
    /// for go, remaining channel ms for channel_update, zero for terminal events.
    value_ms: u32,
    game_time_ms: u32,
};

// AuraEntry — 20 bytes on the wire
//
//   ┌──────────────────────┬───────────────┬───────────────────┬───────────┐
//   │  caster_guid (u64)   │ spell_id (u32)│ remaining_ms (u32)│ stacks    │
//   └──────────────────────┴───────────────┴───────────────────┴───────────┘
//    ←────── 8 bytes ──────→ ←── 4 bytes ──→ ←─── 4 bytes ────→ ← 4 bytes →

pub const AuraEntry = extern struct {
    caster_guid: u64,
    spell_id: u32,
    remaining_ms: u32,
    stacks: u32 = 1,
};

// CooldownEntry — 16 bytes on the wire
//
//   ┌───────────────────┬───────────────────┬───────────────────┬───────────────────┐
//   │  spell_id (u32)   │ category (u32)    │ remaining_ms (u32)│ duration_ms (u32) │
//   └───────────────────┴───────────────────┴───────────────────┴───────────────────┘

pub const CooldownEntry = extern struct {
    spell_id: u32,
    category: u32,
    remaining_ms: u32,
    duration_ms: u32,
};

// SpellRangeEntry — 8 bytes on the wire
//
//   ┌───────────────────┬───────────────────┐
//   │  spell_id (u32)   │ max_range_yards   │
//   └───────────────────┴───────────────────┘

pub const SpellRangeEntry = extern struct {
    spell_id: u32,
    max_range_yards: f32,
};

pub const ThreatEntry = extern struct {
    unit_guid: u64,
    threat: u32,
};

pub const TotemElement = enum(u2) {
    fire = 0,
    earth = 1,
    water = 2,
    air = 3,
};

// TotemSlot — 4 bytes on the wire (one entry per shaman totem slot)
//
//   ┌───────────────────────┐
//   │  remaining_ms (u32)   │  0 = slot empty
//   └───────────────────────┘

pub const TotemSlot = extern struct {
    remaining_ms: u32,
};

pub fn totemSlot(totems: *const [4]TotemSlot, element: TotemElement) TotemSlot {
    return totems[@intFromEnum(element)];
}

// State — wireSize(State) bytes on the wire (MSG_STATE payload)
//
//   ┌─────────────────────────────────────────────────────┐
//   │ bot_id [32]u8          │ world_ready (u32)          │
//   │ player_name [32]u8     │                            │
//   │ guid (u64)             │ class (u32)                │
//   ├─────────────────────────────────────────────────────┤
//   │ map_id (u32)                                        │
//   ├─────────────────────────────────────────────────────┤
//   │ x / y / z / orientation  (4×f32)                    │
//   ├─────────────────────────────────────────────────────┤
//   │ level / hp / hp_max / power / power_max  (5×u32)    │
//   │ active_power_type / active_power / active_power_max │
//   ├─────────────────────────────────────────────────────┤
//   │ unit_flags (u32)  │  unit_flags_2 (u32)             │
//   │ is_casting / is_channeling             (2×u32)      │
//   │ casting_spell_id / channel_spell_id    (2×u32)      │
//   ├─────────────────────────────────────────────────────┤
//   │ target_guid (u64)  │  target_unit_reaction (u32)    │
//   │ combo_points (u32) │  combo_target_guid (u64)       │
//   │ channel_target_guid (u64)                           │
//   ├─────────────────────────────────────────────────────┤
//   │ pet_guid (u64)                                       │
//   ├─────────────────────────────────────────────────────┤
//   │ ctm_action (u32)  │  ctm_x/y/z (3×f32)  │ ctm_guid  │
//   ├─────────────────────────────────────────────────────┤
//   │ player_aura_count (u32)  +  64×AuraEntry            │
//   │ target_aura_count (u32)  +  64×AuraEntry            │
//   ├─────────────────────────────────────────────────────┤
//   │ cooldown_count + cooldowns + target threat table    │
//   │ threat_on_target (legacy/debug)                     │
//   │ glue_screen (u32, glue_screen_* when !world_ready) │
//   └─────────────────────────────────────────────────────┘

pub const State = extern struct {
    // identity
    bot_id: [bot_id_len]u8,
    world_ready: u32,
    player_name: [bot_id_len]u8,
    guid: u64,
    class: u32,
    // map
    map_id: u32,
    // position
    x: f32,
    y: f32,
    z: f32,
    orientation: f32,
    // stats
    level: u32,
    hp: u32,
    hp_max: u32,
    power: u32,
    power_max: u32,
    active_power_type: u32,
    active_power: u32,
    active_power_max: u32,
    shapeshift_form: u32,
    // combat
    unit_flags: u32,
    unit_flags_2: u32,
    is_casting: u32,
    is_channeling: u32,
    casting_spell_id: u32,
    channel_spell_id: u32,
    cast_start_time_ms: u32,
    cast_end_time_ms: u32,
    channel_start_time_ms: u32,
    channel_end_time_ms: u32,
    // target — `UnitReaction(player, target)` (1–7 typical; 8 Exalted when rep-based); 0 = nil / unknown / no target.
    target_guid: u64,
    target_unit_reaction: u32,
    combo_points: u32,
    combo_target_guid: u64,
    channel_target_guid: u64,
    pet_guid: u64,
    game_time_ms: u32,
    // click-to-move
    ctm_action: u32,
    ctm_x: f32,
    ctm_y: f32,
    ctm_z: f32,
    ctm_guid: u64,
    // auras
    player_aura_count: u32,
    player_auras: [max_auras]AuraEntry,
    target_aura_count: u32,
    target_auras: [max_auras]AuraEntry,
    rune_regen_ms: [6]u32,
    rune_types: [6]u32,
    // cooldowns
    cooldown_count: u32,
    cooldowns: [max_cooldowns]CooldownEntry,
    spell_range_count: u32,
    spell_ranges: [max_spell_ranges]SpellRangeEntry,
    target_threat_count: u32,
    target_threats: [max_target_threats]ThreatEntry,
    threat_on_target: u32,
    glue_screen: u32,
    talent_points: TalentPoints,
    // group
    group_size: u32,
    is_in_raid: u32,
    // passive hitbox telemetry
    combat_reach: f32,
    bounding_radius: f32,
    // shaman totem slots: [0]=fire [1]=earth [2]=water [3]=air; remaining_ms=0 → empty
    totems: [4]TotemSlot,
};

// ScanEntry — wireSize(ScanEntry) bytes on the wire (one entry in MSG_SCAN payload)
//
//   ┌─────────────────────────────────────────────────────────────────┐
//   │ guid (u64)  │ obj_type (u16)  │ _pad (u16)                      │
//   │ name [48]u8                                                     │
//   ├─────────────────────────────────────────────────────────────────┤
//   │ x / y / z / orientation  (4×f32)                                │
//   ├─────────────────────────────────────────────────────────────────┤
//   │ level / hp / hp_max  (3×u32)                                    │
//   ├─────────────────────────────────────────────────────────────────┤
//   │ unit_flags / unit_flags_2 / unit_reaction                       │
//   │ casting_spell_id / channel_spell_id                             │
//   │ target_guid (u64)                                               │
//   ├─────────────────────────────────────────────────────────────────┤
//   │ aura_count (u32)  +  64×AuraEntry                               │
//   └─────────────────────────────────────────────────────────────────┘
//
// MSG_SCAN payload = N×ScanEntry, with N = (length - 1) / wireSize(ScanEntry).

pub const ScanEntry = extern struct {
    // identity
    guid: u64,
    obj_type: u16,
    _pad: u16,
    name: [48]u8,
    // position
    x: f32,
    y: f32,
    z: f32,
    orientation: f32,
    // stats
    level: u32,
    hp: u32,
    hp_max: u32,
    // combat
    unit_flags: u32,
    unit_flags_2: u32,
    // `UnitReaction(player, unit)` for scanned units; 0 = nil / unknown / non-unit.
    unit_reaction: u32,
    casting_spell_id: u32,
    channel_spell_id: u32,
    // target
    target_guid: u64,
    cast_start_time_ms: u32,
    cast_end_time_ms: u32,
    channel_start_time_ms: u32,
    channel_end_time_ms: u32,
    // auras
    aura_count: u32,
    auras: [max_scan_auras]AuraEntry,
    // passive hitbox telemetry
    combat_reach: f32,
    bounding_radius: f32,
};

// ─── Max payload / frame sizes ────────────────────────────────────────────────

pub const state_payload_size: usize = wireSize(State);
// SCAN payload: [u32 map_id][N × ScanEntry]
pub const scan_header_size: usize = @sizeOf(u32);
pub const scan_payload_size: usize = scan_header_size + scan_max_entries * wireSize(ScanEntry);

// ─── Wire serialization helpers ───────────────────────────────────────────────
//
// wireSize(T) — compile-time byte count of T on the wire (no ABI padding).
// readWire(T, buf) — deserialize T from buf field-by-field, matching the
//   minion's manual writeInt serialization exactly.
//
// Both recurse through int, float, array, and extern struct.

fn wireReadWalk(comptime T: type, ptr: anytype, buf: []const u8, off: *usize) void {
    switch (@typeInfo(T)) {
        .@"enum" => |e| {
            var raw: e.tag_type = undefined;
            wireReadWalk(e.tag_type, &raw, buf, off);
            ptr.* = @enumFromInt(raw);
        },
        .int => {
            const chunk = buf[off.*..][0..@sizeOf(T)];
            ptr.* = std.mem.readInt(T, chunk, .little);
            off.* += @sizeOf(T);
        },
        .float => {
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            const chunk = buf[off.*..][0..@sizeOf(T)];
            const bits = std.mem.readInt(Bits, chunk, .little);
            ptr.* = @bitCast(bits);
            off.* += @sizeOf(T);
        },
        .array => |a| {
            for (ptr) |*elem| wireReadWalk(a.child, elem, buf, off);
        },
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                wireReadWalk(f.type, &@field(ptr.*, f.name), buf, off);
            }
        },
        .void => {},
        else => @compileError("wireReadWalk: unsupported type " ++ @typeName(T)),
    }
}

fn wireWriteWalk(comptime T: type, ptr: anytype, buf: []u8, off: *usize) void {
    switch (@typeInfo(T)) {
        .@"enum" => |e| wireWriteWalk(e.tag_type, &@as(e.tag_type, @intFromEnum(ptr.*)), buf, off),
        .int => {
            const chunk = buf[off.*..][0..@sizeOf(T)];
            std.mem.writeInt(T, chunk, ptr.*, .little);
            off.* += @sizeOf(T);
        },
        .float => {
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            const chunk = buf[off.*..][0..@sizeOf(T)];
            const bits: Bits = @bitCast(ptr.*);
            std.mem.writeInt(Bits, chunk, bits, .little);
            off.* += @sizeOf(T);
        },
        .array => |a| {
            for (ptr) |*elem| wireWriteWalk(a.child, elem, buf, off);
        },
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                wireWriteWalk(f.type, &@field(ptr.*, f.name), buf, off);
            }
        },
        .void => {},
        else => @compileError("wireWriteWalk: unsupported type " ++ @typeName(T)),
    }
}

pub fn writeWire(comptime T: type, value: T, buf: []u8) void {
    var off: usize = 0;
    wireWriteWalk(T, &value, buf, &off);
}

pub fn readWire(comptime T: type, buf: []const u8) T {
    var result: T = undefined;
    var off: usize = 0;
    wireReadWalk(T, &result, buf, &off);
    return result;
}

pub fn wireSize(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .int, .float => @sizeOf(T),
        .array => |a| a.len * wireSize(a.child),
        .@"enum" => @sizeOf(T),
        .@"struct" => |s| blk: {
            var total: usize = 0;
            inline for (s.fields) |f| total += wireSize(f.type);
            break :blk total;
        },
        .void => 0,
        .@"union" => |u| blk: {
            var max: usize = 0;
            inline for (u.fields) |f| {
                const size = wireSize(f.type);
                if (size > max) max = size;
            }
            const tag_size = if (u.tag_type) |t| wireSize(t) else 0;
            break :blk tag_size + max;
        },
        else => @compileError("wireSize: unsupported type " ++ @typeName(T)),
    };
}

pub fn readMastermindMsg(payload: []const u8) ?MastermindMsg {
    if (payload.len == 0) return null;
    const tag = std.enums.fromInt(NetCmd, payload[0]) orelse return null;
    const body = payload[1..];
    switch (tag) {
        inline else => |t| {
            const Field = @FieldType(MastermindMsg, @tagName(t));
            if (body.len < wireSize(Field)) return null;
            return @unionInit(MastermindMsg, @tagName(t), readWire(Field, body));
        },
    }
}

// writeMastermindFrame — writes a full [u32 BE length][u8 type][payload] frame
// into buf and returns the written slice. buf must be large enough.
pub fn writeMastermindFrame(msg: MastermindMsg, buf: []u8) []u8 {
    switch (msg) {
        inline else => |val, tag| {
            const payload_len = wireSize(@TypeOf(val));
            std.mem.writeInt(u32, buf[0..frame_length_size], @intCast(1 + payload_len), .big);
            buf[frame_length_size] = @intFromEnum(tag);
            writeWire(@TypeOf(val), val, buf[frame_header_size..]);
            return buf[0 .. frame_header_size + payload_len];
        },
    }
}

fn assertWireSize(comptime T: type, comptime expected: usize) void {
    const actual = wireSize(T);
    if (actual != expected) {
        @compileError(std.fmt.comptimePrint(
            "{s} wire size drift: {} != {}",
            .{ @typeName(T), actual, expected },
        ));
    }
}

// ─── Compile-time size assertions ─────────────────────────────────────────────
//
// If you add or remove a field from any wire struct, these will fail with the
// new computed size — update the mastermind deserializer to match.

comptime {
    assertWireSize(AuraEntry, 20);
    assertWireSize(CooldownEntry, 16);
    assertWireSize(SpellRangeEntry, 8);
    assertWireSize(ThreatEntry, 12);
    assertWireSize(SpellEvent, 36);
    assertWireSize(TotemSlot, 4);
    assertWireSize(State, 9548);
    assertWireSize(MastermindMsg, 257);
    assertWireSize(ScanEntry, 1424);
    assertWireSize(CtmMoveCmd, 12);
    assertWireSize(CtmGuidCmd, 8);
    assertWireSize(CastSpellIdCmd, 4);
    assertWireSize(CastSpellGuidCmd, 12);
    assertWireSize(TalentPoints, 12);
    assertWireSize(WalkCmd, 8);
}

test "ThreatEntry wire roundtrip" {
    const entry = ThreatEntry{ .unit_guid = 0x1122334455667788, .threat = 12345 };
    var buf: [wireSize(ThreatEntry)]u8 = undefined;
    writeWire(ThreatEntry, entry, &buf);
    const decoded = readWire(ThreatEntry, &buf);
    try std.testing.expectEqual(entry.unit_guid, decoded.unit_guid);
    try std.testing.expectEqual(entry.threat, decoded.threat);
}
