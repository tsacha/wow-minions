const std = @import("std");
const types = @import("types");
const intent = @import("../combat/intent/mod.zig");
const intent_role = @import("../combat/proposers/role.zig");
const positioning = @import("../combat/positioning.zig");
const brain_log = @import("log.zig");

pub const combat_sample_period_ms: u32 = 1000;
pub const combat_move_log_period_ms: u32 = 500;
pub const combat_facing_log_period_ms: u32 = 500;
pub const combat_facing_stuck_ms: u32 = 2000;
pub const combat_move_regression_yards: f32 = 0.75;
pub const combat_ctm_dst_change_log_yards: f32 = 1.0;

pub const arbitration_trace_capacity = types.max_bots * 4;
pub const decision_trace_capacity = types.max_bots * 2;

pub const ArbitrationReason = enum {
    role_blocks_spec,
    role_clears_existing_spec,
    role_allows_spec,
    encounter_preempts_role,
};

pub const ArbitrationTrace = struct {
    bot_id: types.BotId,
    target_guid: u64,
    reason: ArbitrationReason,
    encounter_active: bool,
    role_intent: intent.IntentTag,
    blocks_spec: bool,
    spec_skipped: bool,
    old_intent: intent.IntentTag,
    final_intent: intent.IntentTag,
    final_priority: intent.Priority,
};

pub const DecisionTrace = intent_role.DecisionTrace;

const DecisionDebugSlot = struct {
    bot_id: types.BotId = std.mem.zeroes(types.BotId),
    occupied: bool = false,
    last_sample_ms: u32 = 0,
    target_guid: u64 = 0,
    in_position: bool = false,
    facing_ok: bool = false,
    intent: intent.IntentTag = .idle,
    reason: intent_role.DecisionReason = .no_target,
};

pub const CombatDebugStore = struct {
    slots: [types.max_bots]DecisionDebugSlot = .{DecisionDebugSlot{}} ** types.max_bots,
    arbitration_slots: [types.max_bots]?ArbitrationTrace = .{null} ** types.max_bots,

    pub fn shouldLogDecision(self: *CombatDebugStore, trace: DecisionTrace, sample_enabled: bool) bool {
        const slot = self.slotFor(trace.bot.bot_id) orelse return true;
        const result = trace.result;
        const in_position = if (result) |r| r.in_position else false;
        const facing_ok = if (result) |r| r.facing_ok else false;
        const changed = !slot.occupied or
            slot.target_guid != trace.primary_target or
            slot.in_position != in_position or
            slot.facing_ok != facing_ok or
            slot.intent != trace.intent or
            slot.reason != trace.reason;
        const sample_due = sample_enabled and trace.bot.state.game_time_ms -| slot.last_sample_ms >= combat_sample_period_ms;
        if (changed or sample_due) {
            slot.occupied = true;
            slot.bot_id = trace.bot.bot_id;
            slot.target_guid = trace.primary_target;
            slot.in_position = in_position;
            slot.facing_ok = facing_ok;
            slot.intent = trace.intent;
            slot.reason = trace.reason;
            if (sample_due) slot.last_sample_ms = trace.bot.state.game_time_ms;
            return true;
        }
        return false;
    }

    fn slotFor(self: *CombatDebugStore, bot_id: types.BotId) ?*DecisionDebugSlot {
        for (&self.slots) |*slot| {
            if (slot.occupied and std.mem.eql(u8, &slot.bot_id, &bot_id)) return slot;
        }
        for (&self.slots) |*slot| {
            if (!slot.occupied) return slot;
        }
        return null;
    }

    pub fn shouldLogArbitration(self: *CombatDebugStore, trace: ArbitrationTrace) bool {
        const slot = self.arbitrationSlotFor(trace.bot_id) orelse return true;
        if (slot.*) |p| {
            if (arbitrationTraceEqual(p, trace)) return false;
        }
        slot.* = trace;
        return true;
    }

    fn arbitrationSlotFor(self: *CombatDebugStore, bot_id: types.BotId) ?*?ArbitrationTrace {
        for (&self.arbitration_slots) |*slot| {
            if (slot.*) |trace| {
                if (std.mem.eql(u8, &trace.bot_id, &bot_id)) return slot;
            }
        }
        for (&self.arbitration_slots) |*slot| {
            if (slot.* == null) return slot;
        }
        return null;
    }
};

pub const TraceBuffer = struct {
    arbitration: [arbitration_trace_capacity]ArbitrationTrace = undefined,
    arbitration_len: usize = 0,
    decision: [decision_trace_capacity]DecisionTrace = undefined,
    decision_len: usize = 0,

    pub fn appendArbitration(self: *TraceBuffer, trace: ArbitrationTrace) void {
        if (self.arbitration_len >= self.arbitration.len) return;
        self.arbitration[self.arbitration_len] = trace;
        self.arbitration_len += 1;
    }

    pub fn appendDecision(self: *TraceBuffer, trace: DecisionTrace) void {
        if (self.decision_len >= self.decision.len) return;
        self.decision[self.decision_len] = trace;
        self.decision_len += 1;
    }
};

pub fn logTraces(traces: *const TraceBuffer) void {
    for (traces.decision[0..traces.decision_len]) |trace| {
        logDecisionTrace(trace);
    }
    if (!brain_log.combatArbitrationLogEnabled()) return;
    for (traces.arbitration[0..traces.arbitration_len]) |trace| {
        const bot = std.mem.sliceTo(&trace.bot_id, 0);
        std.log.info("combat_arbitration bot={s} target=0x{x} reason={s} encounter_active={} role_intent={s} blocks_spec={} spec_skipped={} old_intent={s} final_intent={s} final_priority={s}", .{
            bot,
            trace.target_guid,
            @tagName(trace.reason),
            trace.encounter_active,
            @tagName(trace.role_intent),
            trace.blocks_spec,
            trace.spec_skipped,
            @tagName(trace.old_intent),
            @tagName(trace.final_intent),
            @tagName(trace.final_priority),
        });
    }
}

fn arbitrationTraceEqual(a: ArbitrationTrace, b: ArbitrationTrace) bool {
    return std.mem.eql(u8, &a.bot_id, &b.bot_id) and
        a.target_guid == b.target_guid and
        a.reason == b.reason and
        a.encounter_active == b.encounter_active and
        a.role_intent == b.role_intent and
        a.blocks_spec == b.blocks_spec and
        a.spec_skipped == b.spec_skipped and
        a.old_intent == b.old_intent and
        a.final_intent == b.final_intent and
        a.final_priority == b.final_priority;
}

fn placementName(placement: positioning.Placement) []const u8 {
    return switch (placement.range) {
        .melee => "melee",
        .yards => "yards",
    };
}

fn logDecisionTrace(trace: DecisionTrace) void {
    const bot = std.mem.sliceTo(&trace.bot.bot_id, 0);
    const state = trace.bot.state;
    const target_guid = if (trace.target) |target| target.scan.guid else trace.primary_target;
    const target_hp = if (trace.target) |target| target.scan.hp else 0;
    const target_cr = if (trace.target) |target| target.scan.combat_reach else 0.0;
    const target_x = if (trace.target) |target| target.scan.x else 0.0;
    const target_y = if (trace.target) |target| target.scan.y else 0.0;
    const target_z = if (trace.target) |target| target.scan.z else 0.0;
    const target_o = if (trace.target) |target| target.scan.orientation else 0.0;
    const target_vx = if (trace.target) |target| target.velocity_x_yards_per_second else 0.0;
    const target_vy = if (trace.target) |target| target.velocity_y_yards_per_second else 0.0;
    const target_speed = @sqrt(target_vx * target_vx + target_vy * target_vy);
    const r = trace.result orelse positioning.PositioningResult{
        .desired_pos = .{ .x = 0, .y = 0, .z = 0 },
        .target_dist = 0,
        .range_lower = 0,
        .range_upper = 0,
        .bot_dist = 0,
        .z_delta = 0,
        .target_to_bot = 0,
        .bot_to_target = 0,
        .arc_delta = 0,
        .dist_to_desired = 0,
        .in_position = false,
        .rear_arc_ok = false,
        .desired_facing = 0,
        .facing_delta = 0,
        .facing_ok = false,
    };
    var head_buf: [512]u8 = undefined;
    var pos_buf: [512]u8 = undefined;
    var decision_buf: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "combat_decision bot={s} role={s} spec={s} map={} t={} primary_target=0x{x} state_target=0x{x} target=0x{x} target_hp={} target_pos=({d:.2},{d:.2},{d:.2}) target_o={d:.3} target_cr={d:.2} target_v=({d:.2},{d:.2}) target_speed={d:.2} lead_seconds={d:.2}", .{
        bot,
        @tagName(trace.role),
        @tagName(trace.spec),
        state.map_id,
        state.game_time_ms,
        trace.primary_target,
        state.target_guid,
        target_guid,
        target_hp,
        target_x,
        target_y,
        target_z,
        target_o,
        target_cr,
        target_vx,
        target_vy,
        target_speed,
        positioning.target_lead_seconds,
    }) catch "combat_decision format=head_overflow";
    const pos = std.fmt.bufPrint(&pos_buf, " bot_pos=({d:.2},{d:.2},{d:.2}) bot_o={d:.3} bot_cr={d:.2} dist={d:.2} z_delta={d:.2} placement={s} rel_angle={d:.3} desired=({d:.2},{d:.2},{d:.2}) dist_to_desired={d:.2} range=[{d:.2},{d:.2}] target_dist={d:.2} target_to_bot={d:.3} bot_to_target={d:.3} arc_delta={d:.3}", .{
        state.x,
        state.y,
        state.z,
        state.orientation,
        state.combat_reach,
        r.bot_dist,
        r.z_delta,
        placementName(trace.placement),
        trace.placement.relative_angle,
        r.desired_pos.x,
        r.desired_pos.y,
        r.desired_pos.z,
        r.dist_to_desired,
        r.range_lower,
        r.range_upper,
        r.target_dist,
        r.target_to_bot,
        r.bot_to_target,
        r.arc_delta,
    }) catch " pos_format=overflow";
    const decision = std.fmt.bufPrint(&decision_buf, " rear_arc_ok={} desired_facing={d:.3} facing_delta={d:.3} facing_tol={d:.3} facing_ok={} in_position={} ctm={} ctm_dst=({d:.2},{d:.2},{d:.2}) ctm_guid=0x{x} cast={} channel={} uses_autoattack={} intent={s} blocks_spec={} reason={s}", .{
        r.rear_arc_ok,
        r.desired_facing,
        r.facing_delta,
        trace.placement.facing_tolerance,
        r.facing_ok,
        r.in_position,
        state.ctm_action,
        state.ctm_x,
        state.ctm_y,
        state.ctm_z,
        state.ctm_guid,
        state.is_casting,
        state.is_channeling,
        trace.uses_autoattack,
        @tagName(trace.intent),
        trace.blocks_spec,
        @tagName(trace.reason),
    }) catch " decision_format=overflow";
    std.log.debug("{s}{s}{s}", .{ head, pos, decision });
}
