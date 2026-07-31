const std = @import("std");
const types = @import("types.zig");
const offsets = @import("offsets.zig");
const world = @import("world.zig");
const log_mod = @import("log.zig");
const Offsets = offsets.Offsets;

pub var enabled: bool = false;

var last_ms: u32 = 0;
var last_pos: types.Vec3 = .{ .x = 0, .y = 0, .z = 0 };

const state_interval_ms: u32 = 200;
const moving_threshold_yards: f32 = 0.05;
const class_rogue: u32 = 4;
const class_death_knight: u32 = 6;
const class_druid: u32 = 11;

const calculate_threat: types.CalculateThreatFn = @ptrFromInt(Offsets.CG_UNIT_CALCULATE_THREAT);

fn threatPct(target_obj: u32, unit_guid: u64) f32 {
    if (target_obj == 0 or unit_guid == 0) return 0;
    var status: u8 = 0;
    var status_secondary: u8 = 0;
    var percent: f32 = 0;
    var raw: u32 = 0;
    if (!calculate_threat(target_obj, &unit_guid, &status, &status_secondary, &percent, &raw)) return 0;
    return percent;
}

fn logState(state: types.State, player_name: []const u8, threat_pct: f32, target_yaw: f32, target_dist: f32, angle_to_target: f32, target_name: []const u8, moving: bool, speed_yps: f32) void {
    const pname = std.mem.sliceTo(player_name, 0);
    const tname = std.mem.sliceTo(target_name, 0);
    var buf: [512]u8 = undefined;
    var len: usize = 0;

    const base = std.fmt.bufPrint(buf[len..], "[play] name={s} t={} pos={d:.1},{d:.1},{d:.1},{d:.2} mv={},{d:.1} tgt=0x{x}:{s},{d:.2},{d:.1},{d:.2},{d:.1} hp={}/{} mp={}/{} ap={}/{}", .{
        pname,
        state.game_time_ms,
        state.x,
        state.y,
        state.z,
        state.orientation,
        @intFromBool(moving),
        speed_yps,
        state.target_guid,
        tname,
        target_yaw,
        target_dist,
        angle_to_target,
        threat_pct,
        state.hp,
        state.hp_max,
        state.power,
        state.power_max,
        state.active_power,
        state.active_power_max,
    }) catch return;
    len += base.len;

    if (state.class == class_rogue or state.class == class_druid) {
        const s = std.fmt.bufPrint(buf[len..], " cp={}", .{state.combo_points}) catch return;
        len += s.len;
    }

    if (state.class == class_death_knight) {
        const r = state.rune_regen_ms;
        const s = std.fmt.bufPrint(buf[len..], " rn={},{},{},{},{},{}", .{ r[0], r[1], r[2], r[3], r[4], r[5] }) catch return;
        len += s.len;
    }

    const tail = std.fmt.bufPrint(buf[len..], " cs={},{}\n", .{ state.casting_spell_id, state.channel_spell_id }) catch return;
    len += tail.len;

    log_mod.info("{s}", .{buf[0..len]});
}

pub fn tick(state: types.State, obj_mgr: u32, target_guid: u64, player_guid: u64, now: u32) void {
    if (!enabled) return;
    if (now -% last_ms < state_interval_ms) return;

    const elapsed_ms = now -% last_ms;
    last_ms = now;

    const pdx = state.x - last_pos.x;
    const pdy = state.y - last_pos.y;
    const pdz = state.z - last_pos.z;
    const dist_moved = @sqrt(pdx * pdx + pdy * pdy + pdz * pdz);
    const speed_yps = if (elapsed_ms > 0) dist_moved / (@as(f32, @floatFromInt(elapsed_ms)) / 1000.0) else 0;
    const moving = dist_moved > moving_threshold_yards;
    last_pos = .{ .x = state.x, .y = state.y, .z = state.z };

    var threat_pct: f32 = 0;
    var target_yaw: f32 = 0;
    var target_dist: f32 = 0;
    var angle_to_target: f32 = 0;
    var target_name: [32]u8 = std.mem.zeroes([32]u8);

    if (target_guid != 0 and obj_mgr != 0) {
        if (world.findObjectByGuid(obj_mgr, target_guid)) |tgt_obj| {
            threat_pct = threatPct(tgt_obj, player_guid);
            target_yaw = world.readPlayerFacing(tgt_obj);
            world.readUnitNameInto(tgt_obj, target_guid, &target_name);
            if (world.readPlayerPosition(tgt_obj)) |tgt_pos| {
                const dx = tgt_pos.x - state.x;
                const dy = tgt_pos.y - state.y;
                const dz = tgt_pos.z - state.z;
                target_dist = @sqrt(dx * dx + dy * dy + dz * dz);
                const bearing = std.math.atan2(dy, dx);
                angle_to_target = bearing - state.orientation;
                if (angle_to_target > std.math.pi) angle_to_target -= 2.0 * std.math.pi;
                if (angle_to_target < -std.math.pi) angle_to_target += 2.0 * std.math.pi;
            }
        }
    }

    logState(state, &state.player_name, threat_pct, target_yaw, target_dist, angle_to_target, &target_name, moving, speed_yps);
}

pub fn onSpellCast(kind: types.SpellEventKind, event: types.SpellEvent, player_name: []const u8) void {
    if (!enabled) return;
    if (event.caster_guid != event.observer_guid) return;
    switch (kind) {
        .start => log_mod.info("[play:cast] name={s} t={} spell={} kind=start timer={}ms\n", .{
            player_name, event.game_time_ms, event.spell_id, event.value_ms,
        }),
        .go => log_mod.info("[play:cast] name={s} t={} spell={} kind=go\n", .{
            player_name, event.game_time_ms, event.spell_id,
        }),
        else => {},
    }
}
