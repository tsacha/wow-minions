//! Combat decision / dispatch debug logging.
//!
//! All log emission goes through these helpers so the brain's main flow stays
//! readable. Toggled at runtime by the `MASTERMIND_LOG_COMBAT_DECISIONS`
//! environment variable (see `main.zig`).

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../world/memory.zig");
const gui_snapshot = @import("../gui/snapshot.zig");
const combat = @import("../combat/mod.zig");
const intent = @import("../combat/intent/mod.zig");
const world_query = @import("../combat/world_query.zig");
const geo = @import("../combat/geo.zig");
const order_label = @import("../gui/order_label.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

var combat_decision_log_enabled: bool = false;
var intent_preempt_log_enabled: bool = false;
var combat_arbitration_log_enabled: bool = false;
var combat_sample_log_enabled: bool = false;
var threat_table_log_enabled: bool = false;
var spell_launch_log_enabled: bool = false;
var combat_dispatch_log_enabled: bool = false;

pub fn setCombatDecisionLogEnabled(enabled: bool) void {
    combat_decision_log_enabled = enabled;
}

pub fn setIntentPreemptLogEnabled(enabled: bool) void {
    intent_preempt_log_enabled = enabled;
}

pub fn setCombatArbitrationLogEnabled(enabled: bool) void {
    combat_arbitration_log_enabled = enabled;
}

pub fn setCombatSampleLogEnabled(enabled: bool) void {
    combat_sample_log_enabled = enabled;
}

pub fn setThreatTableLogEnabled(enabled: bool) void {
    threat_table_log_enabled = enabled;
}

pub fn setSpellLaunchLogEnabled(enabled: bool) void {
    spell_launch_log_enabled = enabled;
}

pub fn setCombatDispatchLogEnabled(enabled: bool) void {
    combat_dispatch_log_enabled = enabled;
}

pub fn combatDecisionLogEnabled() bool {
    return combat_decision_log_enabled;
}

pub fn intentPreemptLogEnabled() bool {
    return intent_preempt_log_enabled;
}

pub fn combatArbitrationLogEnabled() bool {
    return combat_arbitration_log_enabled;
}

pub fn combatSampleLogEnabled() bool {
    return combat_sample_log_enabled;
}

pub fn threatTableLogEnabled() bool {
    return threat_table_log_enabled;
}

pub fn spellLaunchLogEnabled() bool {
    return spell_launch_log_enabled;
}

pub fn combatDispatchLogEnabled() bool {
    return combat_dispatch_log_enabled;
}

fn appendThreatLog(buf: *[2048]u8, len: *usize, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(buf[len.*..], fmt, args) catch return;
    len.* += written.len;
}

pub fn logThreatTables(bots: []const BotSnapshot) void {
    if (!threat_table_log_enabled) return;

    for (bots) |bot| {
        if (bot.state.target_guid == 0 and bot.state.target_threat_count == 0) continue;

        const bot_name = std.mem.sliceTo(&bot.state.player_name, 0);
        const n = @min(bot.state.target_threat_count, bot.state.target_threats.len);
        var entries_buf: [2048]u8 = undefined;
        var entries_len: usize = 0;

        for (bot.state.target_threats[0..n], 0..) |entry, i| {
            if (i != 0) appendThreatLog(&entries_buf, &entries_len, " ", .{});
            if (registry_mod.botForGuid(bots, entry.unit_guid)) |unit| {
                appendThreatLog(&entries_buf, &entries_len, "0x{x}:{s}:{}", .{
                    entry.unit_guid,
                    std.mem.sliceTo(&unit.state.player_name, 0),
                    entry.threat,
                });
            } else {
                appendThreatLog(&entries_buf, &entries_len, "0x{x}:?:{}", .{ entry.unit_guid, entry.threat });
            }
        }

        std.log.info("combat_threat bot={s} guid=0x{x} target=0x{x} count={} self_threat={} entries=[{s}]", .{
            bot_name,
            bot.state.guid,
            bot.state.target_guid,
            bot.state.target_threat_count,
            bot.state.threat_on_target,
            entries_buf[0..entries_len],
        });
    }
}

pub fn intentReasonPrefix(reason: intent.Reason) []const u8 {
    return switch (reason) {
        .encounter_route, .encounter_pull, .encounter_swap, .encounter_stack, .encounter_transition => "enc",
        .role_follow, .role_stack, .role_heal_move, .role_facing, .role_start_attack => "rol",
        .tank_engage => "eng",
        .tank_rescue => "rsc",
        .spec_attack => "spc",
        .spec_threat => "thr",
        .operator_raid_buff, .operator_burst, .operator_nav, .operator_reset => "op",
    };
}

pub fn intentTagName(value: intent.Intent) []const u8 {
    return switch (value) {
        .idle => "idle",
        .moving_to => "moving",
        .following => "follow",
        .stacking => "stack",
        .targeting => "target",
        .attacking => "attack",
        .casting_scripted => "cast",
        .casting_scripted_ground => "cast_ground",
        .facing => "face",
        .start_attack => "start_atk",
        .stop_attack => "stop_atk",
        .jump => "jump",
        .use_inventory_item => "use_item",
        .apply_poison => "poison",
        .jump_near => "jump_near",
        .waiting_for => "wait",
        .sequenced => "seq",
    };
}

fn actionTargetGuid(action: combat.Action, bot_snap: ?BotSnapshot) u64 {
    return switch (action) {
        .attack, .target_guid, .interact => |guid| guid,
        .cast_target => |ct| ct.target_guid,
        .cast_target_instant => |ct| ct.target_guid,
        .cast, .cast_instant, .start_attack, .stop_attack, .stop_cast => if (bot_snap) |bot| bot.state.target_guid else 0,
        else => 0,
    };
}

fn actionSpellId(action: combat.Action) u32 {
    return switch (action) {
        .cast, .cast_instant => |spell_id| spell_id,
        .cast_target => |ct| ct.spell_id,
        .cast_target_instant => |ct| ct.spell_id,
        else => 0,
    };
}

const MoveDst = struct { x: f32, y: f32, z: f32 };

/// The destination a move/ground action commands — distinct from the engine's
/// reported `ctm_dst` (which lags and goes stale). Logging both is what lets a
/// run distinguish "commanded the wrong/current spot" from "engine ignored a
/// correct command" (the chronic Thaddius polarity-transit gap).
fn actionMoveDst(action: combat.Action) ?MoveDst {
    return switch (action) {
        .move_to => |m| .{ .x = m.x, .y = m.y, .z = m.z },
        .move_to_nb => |m| .{ .x = m.x, .y = m.y, .z = m.z },
        .cast_ground => |g| .{ .x = g.x, .y = g.y, .z = g.z },
        else => null,
    };
}

pub fn logBlocked(
    bot_name: []const u8,
    reason: []const u8,
    action: combat.Action,
    bot_snap: ?BotSnapshot,
    ai_opt: ?intent.ActiveIntent,
) void {
    if (action == .none) return;
    var label_buf: [gui_snapshot.combat_order_label_len]u8 = undefined;
    const label = order_label.actionLabel(&label_buf, action, bot_snap);
    if (ai_opt) |*ai| {
        std.log.debug("brain: [{s}] blocked ({s}): {s} [intent={s}/{s} p={s}]", .{
            bot_name,
            reason,
            label,
            intentReasonPrefix(ai.source),
            intentTagName(ai.intent),
            @tagName(ai.priority),
        });
    } else {
        std.log.debug("brain: [{s}] blocked ({s}): {s}", .{ bot_name, reason, label });
    }
}

pub fn logCombatDispatch(
    phase: []const u8,
    bot_name: []const u8,
    action: combat.Action,
    bot_snap: ?BotSnapshot,
    world: []const WorldSnapshot,
    ai_opt: ?intent.ActiveIntent,
) void {
    if (!combat_dispatch_log_enabled or action == .none) return;

    var label_buf: [gui_snapshot.combat_order_label_len]u8 = undefined;
    const label = order_label.actionLabel(&label_buf, action, bot_snap);
    const target_guid = actionTargetGuid(action, bot_snap);
    const spell_id = actionSpellId(action);
    const intent_source = if (ai_opt) |ai| intentReasonPrefix(ai.source) else "none";
    const intent_tag = if (ai_opt) |ai| intentTagName(ai.intent) else "none";
    const priority = if (ai_opt) |ai| @tagName(ai.priority) else "none";

    const move_dst = actionMoveDst(action);
    const has_move_dst = move_dst != null;
    const mdx = if (move_dst) |m| m.x else 0;
    const mdy = if (move_dst) |m| m.y else 0;
    const mdz = if (move_dst) |m| m.z else 0;
    const confirm_active = if (ai_opt) |ai| ai.confirm.active else false;
    const move_started = if (ai_opt) |ai| ai.confirm.move_started else false;
    const dispatched_at_ms = if (ai_opt) |ai| ai.confirm.dispatched_at_ms else 0;
    // Raw game time so dispatch lines can be correlated 1:1 with the minion's
    // `[play] t=<game_time_ms>` / `[cmd]` stream (the minion log has no fight clock).
    const gt = if (bot_snap) |bot| bot.state.game_time_ms else 0;
    // Pre-rendered as one field so the target-visible branch stays under Zig's
    // 32-argument-per-format-call ceiling.
    var diag_buf: [192]u8 = undefined;
    const diag = std.fmt.bufPrint(&diag_buf, "move_dst=({d:.2},{d:.2},{d:.2}) has_move_dst={} confirm_active={} move_started={} dispatched_at_ms={} gt={}", .{
        mdx, mdy, mdz, has_move_dst, confirm_active, move_started, dispatched_at_ms, gt,
    }) catch "diag_overflow";

    if (bot_snap) |bot| {
        if (target_guid != 0) {
            if (world_query.scanForGuidOnMap(world, target_guid, bot.state.map_id)) |target| {
                const dx = target.x - bot.state.x;
                const dy = target.y - bot.state.y;
                const dz = target.z - bot.state.z;
                const dist = @sqrt(dx * dx + dy * dy + dz * dz);
                const target_to_player = geo.angleTo2d(
                    .{ .x = target.x, .y = target.y, .z = target.z },
                    .{ .x = bot.state.x, .y = bot.state.y, .z = bot.state.z },
                );
                std.log.debug("combat_dispatch phase={s} bot={s} action={s} spell={} target=0x{x} combo={} combo_target=0x{x} dist={d:.2} pos=({d:.2},{d:.2},{d:.2}) yaw={d:.3} target_pos=({d:.2},{d:.2},{d:.2}) target_o={d:.3} target_to_player={d:.3} target_player_delta={d:.3} ctm={} ctm_dst=({d:.2},{d:.2},{d:.2}) intent={s}/{s} priority={s} {s}", .{
                    phase,
                    bot_name,
                    label,
                    spell_id,
                    target_guid,
                    bot.state.combo_points,
                    bot.state.combo_target_guid,
                    dist,
                    bot.state.x,
                    bot.state.y,
                    bot.state.z,
                    bot.state.orientation,
                    target.x,
                    target.y,
                    target.z,
                    target.orientation,
                    target_to_player,
                    geo.absAngleDeltaRad(target.orientation, target_to_player),
                    bot.state.ctm_action,
                    bot.state.ctm_x,
                    bot.state.ctm_y,
                    bot.state.ctm_z,
                    intent_source,
                    intent_tag,
                    priority,
                    diag,
                });
                return;
            }
        }
        std.log.debug("combat_dispatch phase={s} bot={s} action={s} spell={} target=0x{x} combo={} combo_target=0x{x} pos=({d:.2},{d:.2},{d:.2}) yaw={d:.3} ctm={} ctm_dst=({d:.2},{d:.2},{d:.2}) intent={s}/{s} priority={s} {s}", .{
            phase,
            bot_name,
            label,
            spell_id,
            target_guid,
            bot.state.combo_points,
            bot.state.combo_target_guid,
            bot.state.x,
            bot.state.y,
            bot.state.z,
            bot.state.orientation,
            bot.state.ctm_action,
            bot.state.ctm_x,
            bot.state.ctm_y,
            bot.state.ctm_z,
            intent_source,
            intent_tag,
            priority,
            diag,
        });
        return;
    }

    std.log.debug("combat_dispatch phase={s} bot={s} action={s} spell={} target=0x{x} intent={s}/{s} priority={s} {s}", .{
        phase,
        bot_name,
        label,
        spell_id,
        target_guid,
        intent_source,
        intent_tag,
        priority,
        diag,
    });
}

pub fn logCombatDispatchRangeMissing(
    bot_name: []const u8,
    action: combat.Action,
    bot_snap: ?BotSnapshot,
    world: []const WorldSnapshot,
    ai_opt: ?intent.ActiveIntent,
    spell_id: u32,
    target_guid: u64,
) void {
    if (!combat_decision_log_enabled) return;
    logCombatDispatch("blocked_range_missing", bot_name, action, bot_snap, world, ai_opt);
    if (bot_snap) |bot| {
        std.log.info("combat_range phase=missing_client_range bot={s} spell={} target=0x{x} spell_range_count={} map={}", .{
            bot_name,
            spell_id,
            target_guid,
            bot.state.spell_range_count,
            bot.state.map_id,
        });
    }
}

pub fn logCombatDispatchRangeBlocked(
    bot_name: []const u8,
    action: combat.Action,
    bot_snap: ?BotSnapshot,
    world: []const WorldSnapshot,
    ai_opt: ?intent.ActiveIntent,
    check: combat.CastRangeCheck,
) void {
    if (!combat_decision_log_enabled) return;
    logCombatDispatch("blocked_range", bot_name, action, bot_snap, world, ai_opt);
    std.log.info("combat_range phase=out_of_range bot={s} spell={} target=0x{x} dist={d:.2} max={d:.2} effective={d:.2} target_cr={d:.2}", .{
        bot_name,
        check.spell_id,
        check.target_guid,
        check.dist_yards,
        check.max_range_yards,
        check.effective_range_yards,
        check.target.combat_reach,
    });
}
