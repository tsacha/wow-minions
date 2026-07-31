const std = @import("std");
const win32 = @import("win32");
const types = @import("types.zig");
const offsets = @import("offsets.zig");
const ctm = @import("ctm.zig");
const world = @import("world.zig");
const inline_hook = @import("inline_hook.zig");
const hook_commands = @import("hook_commands.zig");
const hook_state = @import("hook_state.zig");
const hook_spell_events = @import("hook_spell_events.zig");
const log_mod = @import("log.zig");
const proto = @import("protocol");

const Offsets = offsets.Offsets;

var orig_end_scene: ?types.EndSceneFn = null;
var packet_spell_go_hook: ?inline_hook.Hook = null;
var packet_spell_failed_other_hook: ?inline_hook.Hook = null;
var packet_spell_failure_hook: ?inline_hook.Hook = null;
var packet_spell_break_hook: ?inline_hook.Hook = null;
var packet_channel_update_hook: ?inline_hook.Hook = null;
var orig_spell_go: ?types.PacketHandlerFn = null;
var orig_spell_failed_other: ?types.PacketHandlerFn = null;
var orig_spell_failure: ?types.PacketHandlerFn = null;
var orig_spell_break: ?types.PacketHandlerFn = null;
var orig_channel_update: ?types.PacketHandlerFn = null;

var exec_pending: std.atomic.Value(bool) = .init(false);
var exec_code: [1024:0]u8 = std.mem.zeroes([1024:0]u8);

var eval_pending: std.atomic.Value(bool) = .init(false);
var eval_expr: [1024:0]u8 = std.mem.zeroes([1024:0]u8);
var eval_ready: std.atomic.Value(bool) = .init(false);
var eval_result: [1024:0]u8 = std.mem.zeroes([1024:0]u8);

var scan_pending: std.atomic.Value(bool) = .init(false);
var scan_ready: std.atomic.Value(bool) = .init(false);
var scan_count_val: u32 = 0;
pub var scan_buf: [types.scan_max_entries]types.ScanEntry = undefined;

const talent_refresh_interval: u32 = 150;
var talent_frame_tick: u32 = 0;
var talent_cache: proto.TalentPoints = std.mem.zeroes(proto.TalentPoints);

var state_buf: types.State = std.mem.zeroes(types.State);
var state_ready: std.atomic.Value(bool) = .init(false);

pub var combat_command_log_enabled: bool = false;
pub var spell_range_log_enabled: bool = false;
pub var pet_guid_log_enabled: bool = false;
pub var crash_on_world_ready_enabled: bool = false;

var walk_stop_tick: u32 = 0;
var walk_active_mask: u8 = 0;

var glue_screen_cache: u32 = 0;
var glue_screen_tick: u32 = 0;
const glue_screen_poll_interval: u32 = 1;

const crash_test_invalid_address: usize = 0x1;
var crash_on_world_ready_fired: bool = false;

const eval_result_global = "minionResult";
const lua_execute: types.FrameScriptExecuteFn = @ptrFromInt(Offsets.FRAME_SCRIPT_EXECUTE);
const lua_get_text: types.FrameScriptGetLocalizedTextFn = @ptrFromInt(Offsets.FRAME_SCRIPT_GET_LOCALIZED_TEXT);
const has_spell: types.HasSpellFn = @ptrFromInt(Offsets.HAS_SPELL);
const cast_spell_by_id: types.CastSpellByIdFn = @ptrFromInt(Offsets.CAST_SPELL_BY_ID);
const handle_terrain_click: types.HandleTerrainClickFn = @ptrFromInt(Offsets.HANDLE_TERRAIN_CLICK);

var local_player_name_buf: [32]u8 = std.mem.zeroes([32]u8);

fn origPacketHandler(opcode: u32) ?types.PacketHandlerFn {
    return switch (opcode) {
        hook_spell_events.opcode_smsg_spell_start,
        hook_spell_events.opcode_smsg_spell_go,
        => orig_spell_go,
        hook_spell_events.opcode_smsg_spell_failed_other => orig_spell_failed_other,
        hook_spell_events.opcode_smsg_spell_failure => orig_spell_failure,
        hook_spell_events.opcode_smsg_spell_breaklog => orig_spell_break,
        hook_spell_events.opcode_msg_channel_update => orig_channel_update,
        else => null,
    };
}

fn hookedSpellPacket(param_1: u32, opcode: u32, param_3: u32, store: *anyopaque) callconv(.c) u32 {
    if (hook_spell_events.readPacketPayload(store)) |payload| {
        hook_spell_events.handlePacket(opcode, payload);
    } else {
        log_mod.info("[packet] name={s} opcode=0x{x} no_payload param1=0x{x} param3=0x{x} store=0x{x}\n", .{ localPlayerName(), opcode, param_1, param_3, @intFromPtr(store) });
    }

    if (origPacketHandler(opcode)) |orig| return orig(param_1, opcode, param_3, store);
    return 1;
}

fn readGlueScreenLua() u32 {
    const glue_detect_lua =
        "_mgscr=((AccountLogin and AccountLogin:IsVisible()) and 1) or ((CharacterSelect and CharacterSelect:IsVisible() and GetNumCharacters()>0) and 2) or ((CharSelect and CharSelect:IsVisible() and GetNumCharacters()>0) and 2) or 0";
    lua_execute(glue_detect_lua, "minion", 0);
    const txt = std.mem.span(lua_get_text("_mgscr", -1));
    return std.fmt.parseInt(u32, txt, 10) catch proto.glue_screen_unknown;
}

fn dispatchLuaExec() void {
    world.pokeLastHardwareAction();
    lua_execute(&exec_code, "minion", 0);
}

fn copyToSentinel(dst: []u8, src: []const u8) void {
    if (dst.len == 0) return;
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

fn localPlayerName() []const u8 {
    world.readLocalPlayerName(&local_player_name_buf);
    return std.mem.sliceTo(&local_player_name_buf, 0);
}

fn dispatchCastSpellId(spell_id: u32) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=exec cast_spell_id spell={} world_ready={}\n", .{
            localPlayerName(),
            spell_id,
            world.isWorldReady(),
        });
    }
    if (!world.isWorldReady()) return;
    if (!has_spell(spell_id)) {
        log_mod.warn("[cast] name={s} unknown spell_id={}\n", .{ localPlayerName(), spell_id });
        return;
    }
    cast_spell_by_id(spell_id, 0, 0, 0);
}

fn dispatchCastSpellGuid(spell_id: u32, target_guid: u64) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=exec cast_spell_guid spell={} target=0x{x} world_ready={}\n", .{
            localPlayerName(),
            spell_id,
            target_guid,
            world.isWorldReady(),
        });
    }
    if (!world.isWorldReady()) return;
    if (!has_spell(spell_id)) {
        log_mod.warn("[cast] name={s} unknown spell_id={}\n", .{ localPlayerName(), spell_id });
        return;
    }
    const guid_low: u32 = @truncate(target_guid);
    const guid_high: u32 = @intCast(target_guid >> 32);
    cast_spell_by_id(spell_id, 0, guid_low, guid_high);
}

fn dispatchCastSpellGround(spell_id: u32, x: f32, y: f32, z: f32) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=exec cast_spell_ground spell={} pos=({d:.2},{d:.2},{d:.2}) world_ready={}\n", .{
            localPlayerName(),
            spell_id,
            x,
            y,
            z,
            world.isWorldReady(),
        });
    }
    if (!world.isWorldReady()) return;
    if (!has_spell(spell_id)) {
        log_mod.warn("[cast] name={s} unknown spell_id={}\n", .{ localPlayerName(), spell_id });
        return;
    }
    cast_spell_by_id(spell_id, 0, 0, 0);
    const terrain_click = types.TerrainClickData{
        .mover_guid = 0,
        .x = x,
        .y = y,
        .z = z,
        .click_type = 1,
    };
    _ = handle_terrain_click(&terrain_click);
}

fn dispatchSetTargetGuid(target_guid: u64) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=exec set_target_guid target=0x{x} world_ready={}\n", .{
            localPlayerName(),
            target_guid,
            world.isWorldReady(),
        });
    }
    if (!world.isWorldReady()) return;
    world.setLocalTargetGuid(target_guid) catch |err| {
        log_mod.warn("[target] set local target failed guid=0x{x} err={s}\n", .{ target_guid, @errorName(err) });
    };
}

fn dispatchLuaGet() void {
    const fmt = eval_result_global ++
        "=(function(...) local t={{}} for i=1,select('#',...) do t[i]=tostring(select(i,...)) end return table.concat(t,'\\t') end)({s})";
    var store_result: [fmt.len + eval_expr.len:0]u8 = undefined;
    _ = std.fmt.bufPrintSentinel(&store_result, fmt, .{std.mem.sliceTo(&eval_expr, 0)}, 0) catch {
        eval_result[0] = 0;
        eval_ready.store(true, .release);
        return;
    };
    lua_execute(&store_result, "minion", 0);
    const result = std.mem.span(lua_get_text(eval_result_global, -1));
    const len = @min(result.len, eval_result.len - 1);
    @memcpy(eval_result[0..len], result[0..len]);
    eval_result[len] = 0;
    eval_ready.store(true, .release);
}

fn refreshTalentCache() void {
    talent_cache = world.readTalentPoints() orelse talent_cache;
}

fn maybeCrashOnWorldReady() void {
    if (!crash_on_world_ready_enabled or crash_on_world_ready_fired) return;

    crash_on_world_ready_fired = true;
    log_mod.info("[crash-test] MINION_CRASH_ON_WORLD_READY triggered\n", .{});

    const bad: *volatile u8 = @ptrFromInt(crash_test_invalid_address);
    _ = bad.*;
    @trap();
}

fn walkDirMask(dir: types.WalkDir) u8 {
    return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(dir)));
}

fn walkStopDirIfActive(dir: types.WalkDir) void {
    const mask = walkDirMask(dir);
    if (walk_active_mask & mask == 0) return;
    ctm.walkStop(dir);
    walk_active_mask &= ~mask;
}

fn walkStopAll() void {
    walkStopDirIfActive(.forward);
    walkStopDirIfActive(.backward);
    walkStopDirIfActive(.strafe_left);
    walkStopDirIfActive(.strafe_right);
    walk_stop_tick = 0;
}

fn walkStartExclusive(dir: types.WalkDir, duration_ms: u32) void {
    const mask = walkDirMask(dir);
    if (walk_active_mask & ~mask != 0) walkStopAll();
    if (walk_active_mask & mask == 0) {
        ctm.walkStart(dir);
        walk_active_mask |= mask;
    }
    walk_stop_tick = win32.GetTickCount() +% duration_ms;
}

fn clearTargetForMove() void {
    // Stop auto-attacking before clearing the target so that subsequent
    // target re-selection by spec rotation does not re-trigger attack_pos CTM.
    const stop_attack_lua = "StopAttack()";
    lua_execute(stop_attack_lua, "minion", 0);
    const clear_lua = "ClearTarget()";
    lua_execute(clear_lua, "minion", 0);
}

export fn myEndScene(device: *anyopaque) callconv(types.COM) win32.LONG {
    const cmd = hook_commands.poll() orelse hook_commands.Payload{ .none = {} };
    switch (cmd) {
        .none => {},
        .move => |pos| {
            const ctm_before = ctm.readCtmState();
            clearTargetForMove();
            ctm.ctmMoveTo(pos);
            const ctm_after = ctm.readCtmState();
            if (combat_command_log_enabled) {
                log_mod.info("[cmd] name={s} phase=exec move pos=({d:.2},{d:.2},{d:.2}) ctm_before={} ctm_after={}\n", .{
                    localPlayerName(),
                    pos.x,
                    pos.y,
                    pos.z,
                    ctm_before.action,
                    ctm_after.action,
                });
            }
        },
        .stop => {
            if (combat_command_log_enabled) {
                log_mod.info("[cmd] name={s} phase=exec stop\n", .{localPlayerName()});
            }
            ctm.ctmStop();
        },
        .guid_action => |c| {
            if (combat_command_log_enabled) {
                log_mod.info("[cmd] name={s} phase=exec guid_action action={} guid=0x{x}\n", .{
                    localPlayerName(),
                    @intFromEnum(c.action),
                    c.guid,
                });
            }
            ctm.ctmGuidAction(c.action, c.guid);
        },
        .cast_spell_id => |spell_id| dispatchCastSpellId(spell_id),
        .cast_spell_guid => |c| dispatchCastSpellGuid(c.spell_id, c.target_guid),
        .cast_spell_ground => |c| dispatchCastSpellGround(c.spell_id, c.x, c.y, c.z),
        .set_target_guid => |guid| dispatchSetTargetGuid(guid),
        .jump => {
            if (combat_command_log_enabled) {
                log_mod.info("[cmd] name={s} phase=exec jump\n", .{localPlayerName()});
            }
            ctm.jump();
        },
        .set_facing => |rad| {
            if (combat_command_log_enabled) {
                log_mod.info("[cmd] name={s} phase=exec set_facing radians={d:.3}\n", .{ localPlayerName(), rad });
            }
            ctm.ctmFace(rad);
        },
        .walk => |c| {
            if (combat_command_log_enabled) {
                log_mod.info("[cmd] name={s} phase=exec walk direction={} duration_ms={}\n", .{
                    localPlayerName(),
                    @intFromEnum(c.direction),
                    c.duration_ms,
                });
            }
            walkStartExclusive(c.direction, c.duration_ms);
        },
        .walk_stop_all => {
            if (combat_command_log_enabled) {
                log_mod.info("[cmd] name={s} phase=exec walk_stop_all\n", .{localPlayerName()});
            }
            walkStopAll();
        },
    }
    if (walk_stop_tick != 0 and win32.GetTickCount() -% walk_stop_tick < 0x8000_0000) {
        walkStopAll();
    }
    if (exec_pending.swap(false, .acq_rel)) dispatchLuaExec();
    if (eval_pending.swap(false, .acq_rel)) dispatchLuaGet();
    talent_frame_tick += 1;
    if (talent_frame_tick >= talent_refresh_interval and world.isWorldReady()) {
        talent_frame_tick = 0;
        refreshTalentCache();
    }
    if (scan_pending.swap(false, .acq_rel) and world.isWorldReady()) {
        scan_count_val = world.scanObjects(&scan_buf);
        scan_ready.store(true, .release);
    }
    if (world.isWorldReady()) {
        maybeCrashOnWorldReady();
        hook_state.spell_range_log_enabled = spell_range_log_enabled;
        hook_state.pet_guid_log_enabled = pet_guid_log_enabled;
        const obj = world.world_player_obj.load(.acquire);
        state_buf = hook_state.build(obj, talent_cache) orelse hook_state.buildUnready();
    } else {
        state_buf = hook_state.buildUnready();
        glue_screen_tick +%= 1;
        if (glue_screen_tick % glue_screen_poll_interval == 0)
            glue_screen_cache = readGlueScreenLua();
        state_buf.glue_screen = glue_screen_cache;
    }
    state_ready.store(true, .release);
    const original = orig_end_scene orelse return 0;
    return original(device);
}

pub fn scheduleMove(pos: types.Vec3) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=recv move pos=({d:.2},{d:.2},{d:.2})\n", .{
            localPlayerName(),
            pos.x,
            pos.y,
            pos.z,
        });
    }
    hook_commands.publish(.{ .move = pos });
}

pub fn scheduleGuidAction(action: types.CtmAction, guid: u64) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=recv guid_action action={} guid=0x{x}\n", .{
            localPlayerName(),
            @intFromEnum(action),
            guid,
        });
    }
    hook_commands.publish(.{ .guid_action = .{ .action = action, .guid = guid } });
}

pub fn scheduleCastSpellId(spell_id: u32) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=recv cast_spell_id spell={}\n", .{ localPlayerName(), spell_id });
    }
    hook_commands.publish(.{ .cast_spell_id = spell_id });
}

pub fn scheduleCastSpellGuid(spell_id: u32, target_guid: u64) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=recv cast_spell_guid spell={} target=0x{x}\n", .{
            localPlayerName(),
            spell_id,
            target_guid,
        });
    }
    hook_commands.publish(.{ .cast_spell_guid = .{ .spell_id = spell_id, .target_guid = target_guid } });
}

pub fn scheduleCastSpellGround(spell_id: u32, x: f32, y: f32, z: f32) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=recv cast_spell_ground spell={} pos=({d:.2},{d:.2},{d:.2})\n", .{
            localPlayerName(),
            spell_id,
            x,
            y,
            z,
        });
    }
    hook_commands.publish(.{ .cast_spell_ground = .{ .spell_id = spell_id, .x = x, .y = y, .z = z } });
}

pub fn scheduleJump() void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=recv jump\n", .{localPlayerName()});
    }
    hook_commands.publish(.{ .jump = {} });
}

pub fn scheduleWalk(cmd: types.WalkCmd) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=recv walk direction={} duration_ms={}\n", .{
            localPlayerName(),
            @intFromEnum(cmd.direction),
            cmd.duration_ms,
        });
    }
    hook_commands.publish(.{ .walk = cmd });
}

pub fn scheduleWalkStopAll() void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=recv walk_stop_all\n", .{localPlayerName()});
    }
    hook_commands.publish(.{ .walk_stop_all = {} });
}

pub fn scheduleSetFacing(radians: f32) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=recv set_facing radians={d:.3}\n", .{ localPlayerName(), radians });
    }
    hook_commands.publish(.{ .set_facing = radians });
}

pub fn scheduleSetTargetGuid(target_guid: u64) void {
    if (combat_command_log_enabled) {
        log_mod.info("[cmd] name={s} phase=recv set_target_guid target=0x{x}\n", .{ localPlayerName(), target_guid });
    }
    hook_commands.publish(.{ .set_target_guid = target_guid });
}

pub fn scheduleLuaExec(code: []const u8) void {
    copyToSentinel(exec_code[0..], code);
    exec_pending.store(true, .release);
}

pub fn execPending() bool {
    return exec_pending.load(.acquire);
}

pub fn scheduleLuaGet(expr: []const u8) void {
    copyToSentinel(eval_expr[0..], expr);
    eval_ready.store(false, .release);
    eval_pending.store(true, .release);
}

pub fn pollLuaGetReady() ?[]const u8 {
    if (!eval_ready.load(.acquire)) return null;
    eval_ready.store(false, .release);
    return std.mem.sliceTo(&eval_result, 0);
}

pub fn pollStateReady() ?types.State {
    if (!state_ready.load(.acquire)) return null;
    return state_buf;
}

pub fn scheduleScan() void {
    scan_ready.store(false, .release);
    scan_pending.store(true, .release);
}

pub fn pollScanReady() ?u32 {
    if (!scan_ready.load(.acquire)) return null;
    scan_ready.store(false, .release);
    return scan_count_val;
}

pub fn pollSpellEvent() ?types.SpellEvent {
    return hook_spell_events.poll();
}

pub fn installHook() !void {
    const d3d9_sdk_version: win32.UINT = 32;
    const end_scene_vtable_index: usize = 42;
    const D3DDEVTYPE_HAL: win32.UINT = 1;
    const D3DSWAPEFFECT_DISCARD: win32.UINT = 1;
    const D3DCREATE_SOFTWARE_VERTEXPROCESSING: win32.DWORD = 0x0020;
    const D3DCREATE_MULTITHREADED: win32.DWORD = 0x0800;

    const d3d9 = win32.LoadLibraryA("d3d9.dll") orelse return error.LoadD3D9Failed;

    const create9_raw = win32.GetProcAddress(d3d9, "Direct3DCreate9") orelse return error.GetProcFailed;
    const create9: types.Direct3DCreate9Fn = @ptrCast(create9_raw);

    const iface = create9(d3d9_sdk_version) orelse return error.D3DCreateFailed;
    const iface_vt: *[*]*anyopaque = @ptrCast(@alignCast(iface));
    const iface_release: types.ReleaseFn = @ptrCast(iface_vt.*[2]);
    errdefer _ = iface_release(iface);

    const create_device: types.CreateDeviceFn = @ptrCast(iface_vt.*[16]);
    const desktop = win32.GetDesktopWindow();
    var pp = std.mem.zeroes(types.D3DPRESENT_PARAMETERS);
    pp.BackBufferWidth = 1;
    pp.BackBufferHeight = 1;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow = desktop;
    pp.Windowed = 1;

    var device: *anyopaque = undefined;
    const hr = create_device(iface, 0, D3DDEVTYPE_HAL, desktop, D3DCREATE_SOFTWARE_VERTEXPROCESSING | D3DCREATE_MULTITHREADED, &pp, &device);
    if (hr < 0) return error.CreateDeviceFailed;

    const dev_vt: *[*]*anyopaque = @ptrCast(@alignCast(device));
    const dev_release: types.ReleaseFn = @ptrCast(dev_vt.*[2]);
    errdefer _ = dev_release(device);
    const slot: **anyopaque = @ptrCast(&dev_vt.*[end_scene_vtable_index]);
    orig_end_scene = @ptrCast(dev_vt.*[end_scene_vtable_index]);

    var old: win32.DWORD = 0;
    if (win32.VirtualProtect(@ptrCast(slot), @sizeOf(*anyopaque), @as(win32.DWORD, @intCast(win32.PAGE_READWRITE)), &old) == 0)
        return error.VirtualProtectFailed;
    defer _ = win32.VirtualProtect(@ptrCast(slot), @sizeOf(*anyopaque), old, &old);
    slot.* = @ptrCast(@constCast(&myEndScene));

    _ = dev_release(device);
    _ = iface_release(iface);

    log_mod.info("[hook] EndScene hooked\n", .{});
}

fn installPacketHooks() !void {
    if (packet_spell_go_hook != null) return;

    packet_spell_go_hook = try inline_hook.install(Offsets.PACKET_SMSG_SPELL_GO, @intFromPtr(&hookedSpellPacket));
    orig_spell_go = @ptrCast(packet_spell_go_hook.?.trampoline);
    packet_spell_failed_other_hook = try inline_hook.install(Offsets.PACKET_SMSG_SPELL_FAILED_OTHER, @intFromPtr(&hookedSpellPacket));
    orig_spell_failed_other = @ptrCast(packet_spell_failed_other_hook.?.trampoline);
    packet_spell_failure_hook = try inline_hook.install(Offsets.PACKET_SMSG_SPELL_FAILURE, @intFromPtr(&hookedSpellPacket));
    orig_spell_failure = @ptrCast(packet_spell_failure_hook.?.trampoline);
    packet_spell_break_hook = try inline_hook.install(Offsets.PACKET_SMSG_SPELLBREAKLOG, @intFromPtr(&hookedSpellPacket));
    orig_spell_break = @ptrCast(packet_spell_break_hook.?.trampoline);
    packet_channel_update_hook = try inline_hook.install(Offsets.PACKET_MSG_CHANNEL_UPDATE, @intFromPtr(&hookedSpellPacket));
    orig_channel_update = @ptrCast(packet_channel_update_hook.?.trampoline);
    hook_spell_events.log_enabled = log_mod.envFlag("MINION_LOG_SPELLS");
    log_mod.info("[hook] spell packet hooks installed log_spells={}\n", .{hook_spell_events.log_enabled});
}

pub fn hookThread() void {
    win32.Sleep(types.hook_init_delay_ms);
    installHook() catch |err| {
        log_mod.warn("[hook] failed: {}\n", .{err});
    };
    installPacketHooks() catch |err| {
        log_mod.warn("[hook] packet failed: {}\n", .{err});
    };
}

test {
    _ = @import("hook_commands.zig");
    _ = @import("hook_state.zig");
    _ = @import("hook_spell_events.zig");
}
