const std = @import("std");
const win32 = @import("win32");
const proto = @import("protocol");
const CallingConvention = std.builtin.CallingConvention;

pub const pipe_name = proto.pipe_name;

// Re-export protocol symbols so existing minion code needs no changes.
pub const MinionMsg = proto.MinionMsg;
pub const NetCmd = proto.NetCmd;
pub const AuraEntry = proto.AuraEntry;
pub const CooldownEntry = proto.CooldownEntry;
pub const SpellRangeEntry = proto.SpellRangeEntry;
pub const ThreatEntry = proto.ThreatEntry;
pub const SpellEvent = proto.SpellEvent;
pub const SpellEventKind = proto.SpellEventKind;
pub const State = proto.State;
pub const ScanEntry = proto.ScanEntry;
pub const TotemSlot = proto.TotemSlot;
pub const TalentPoints = proto.TalentPoints;
pub const mastermind_port = proto.mastermind_port;
pub const max_auras = proto.max_auras;
pub const max_scan_auras = proto.max_scan_auras;
pub const max_cooldowns = proto.max_cooldowns;
pub const max_spell_ranges = proto.max_spell_ranges;
pub const max_target_threats = proto.max_target_threats;

pub const COM: CallingConvention = .{ .x86_stdcall = .{} };

pub const D3DPRESENT_PARAMETERS = extern struct {
    BackBufferWidth: win32.UINT,
    BackBufferHeight: win32.UINT,
    BackBufferFormat: win32.UINT,
    BackBufferCount: win32.UINT,
    MultiSampleType: win32.UINT,
    MultiSampleQuality: win32.DWORD,
    SwapEffect: win32.UINT,
    hDeviceWindow: win32.HWND,
    Windowed: win32.WINBOOL,
    EnableAutoDepthStencil: win32.WINBOOL,
    AutoDepthStencilFormat: win32.UINT,
    Flags: win32.DWORD,
    FullScreen_RefreshRateInHz: win32.UINT,
    PresentationInterval: win32.UINT,
};

pub const Direct3DCreate9Fn = *const fn (sdk_version: win32.UINT) callconv(COM) ?*anyopaque;
pub const CreateDeviceFn = *const fn (
    iface: *anyopaque,
    adapter: win32.UINT,
    device_type: win32.UINT,
    focus_window: win32.HWND,
    behavior_flags: win32.DWORD,
    present_params: *D3DPRESENT_PARAMETERS,
    out_device: **anyopaque,
) callconv(COM) win32.LONG;
pub const ReleaseFn = *const fn (iface: *anyopaque) callconv(COM) win32.LONG;
pub const EndSceneFn = *const fn (device: *anyopaque) callconv(COM) win32.LONG;

pub const FrameScriptExecuteFn = *const fn (
    code: [*:0]const u8,
    source: [*:0]const u8,
    flags: i32,
) callconv(.c) void;
pub const FrameScriptGetLocalizedTextFn = *const fn (
    varname: [*:0]const u8,
    idx: i32,
) callconv(.c) [*:0]const u8;
pub const HasSpellFn = *const fn (spell_id: u32) callconv(.c) bool;
pub const CastSpellByIdFn = *const fn (
    spell_id: u32,
    flags: u32,
    target_guid_low: u32,
    target_guid_high: u32,
) callconv(.c) void;
pub const TerrainClickData = extern struct {
    mover_guid: u64,
    x: f32,
    y: f32,
    z: f32,
    click_type: u32,
};

pub const HandleTerrainClickFn = *const fn (
    terrain_click: *const TerrainClickData,
) callconv(.c) u32;
pub const SpellGetCooldownProxyFn = *const fn (
    spell_id: u32,
    cooldown_list_idx: u32,
    out_duration_ms: *u32,
    out_start_ms: *u32,
    out_enabled: *u32,
) callconv(.c) bool;
pub const SpellGetRangeFn = *const fn (
    unit_obj: u32,
    spell_id: u32,
    out_min_range_yards: *f32,
    out_max_range_yards: *f32,
    assist_obj: u32,
) callconv(.c) void;
pub const CDataStoreGetBufferParamsFn = *const fn (
    store: *anyopaque,
    out_data: *?[*]const u8,
    out_size: *u32,
    out_alloc: *u32,
) callconv(.{ .x86_thiscall = .{} }) void;
pub const PacketHandlerFn = *const fn (
    param_1: u32,
    opcode: u32,
    param_3: u32,
    store: *anyopaque,
) callconv(.c) u32;
pub const GetTalentGroupStateFn = *const fn (
    group_index: u32,
    is_inspect: u32,
    is_pet: u32,
) callconv(.c) u32;
pub const ClickToMoveFn = *const fn (
    player_obj: u32,
    action: u32,
    guid: *u64,
    pos: *[3]f32,
    stop_distance: f32,
) callconv(.{ .x86_thiscall = .{} }) void;

/// `CGPlayer_C::CTMFace` — world yaw in radians (same convention as `OBJ_FACING` / `State.orientation`).
pub const CtmFaceFn = *const fn (player_obj: u32, radians: f32) callconv(.{ .x86_thiscall = .{} }) void;
/// `this` = first unit (typically player), `other` = second unit (e.g. target). Matches client CGUnit_C::UnitReaction.
pub const UnitReactionFn = *const fn (this_unit: u32, other_unit: u32) callconv(.{ .x86_thiscall = .{} }) i32;
pub const CalculateThreatFn = *const fn (
    target_obj: u32,
    unit_guid: *const u64,
    out_status: *u8,
    out_status_secondary: *u8,
    out_percent: *f32,
    out_raw_threat: *u32,
) callconv(.{ .x86_thiscall = .{} }) bool;
pub const JumpOrAscendStartFn = *const fn () callconv(.c) void;

pub const Vec3 = struct { x: f32, y: f32, z: f32 };

pub const UnitStats = struct {
    hp: u32,
    hp_max: u32,
    level: u32,
    power: u32,
    power_max: u32,
    active_power_type: u32,
    active_power: u32,
    active_power_max: u32,
};

pub const CtmState = struct { action: u32, x: f32, y: f32, z: f32, guid: u64 };
pub const GroupState = struct { group_size: u32, is_in_raid: u32 };

pub const CtmAction = proto.CtmAction;

pub const Cmd = enum(u8) { none, move, stop, guid_action, cast_spell_id, cast_spell_guid, cast_spell_ground, jump, set_facing, walk, walk_stop_all, set_target_guid };

pub const WalkDir = proto.WalkDir;
pub const WalkCmd = proto.WalkCmd;
pub const WalkFn = *const fn () callconv(.c) void;

pub const tick_ms: u32 = proto.minion_tick_ms;
pub const hook_init_delay_ms: u32 = proto.hook_init_delay_ms;
pub const object_iteration_limit: usize = 4096;
pub const scan_max_entries: usize = proto.scan_max_entries;
pub const scan_max_go_entries: usize = scan_max_entries / 2;

pub var bot_id: [proto.bot_id_len]u8 = std.mem.zeroes([proto.bot_id_len]u8);
