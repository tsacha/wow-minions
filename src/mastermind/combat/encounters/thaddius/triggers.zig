// Thaddius encounter trigger handlers.
// Each function produces an ?ActiveIntent for a single bot given its CombatContext.

const std = @import("std");
const proto = @import("protocol");
const context = @import("../../context.zig");
const intent = @import("../../intent/mod.zig");
const world_query = @import("../../world_query.zig");
const state = @import("state.zig");
const pred = @import("predicates.zig");
const arena = @import("arena.zig");

const CombatContext = context.CombatContext;
const ActiveIntent = intent.ActiveIntent;
const Intent = intent.Intent;
const Sequenced = intent.Sequenced;
const IntentSlot = intent.IntentSlot;
const SimpleIntent = intent.SimpleIntent;
const Predicate = intent.Predicate;
const Side = state.Side;
const BotState = state.BotState;
const Polarity = state.Polarity;
const PolarityRoute = state.PolarityRoute;

const map_id = @import("mod.zig").map_id;
const twin_tank_anchor_arrival_yards = @import("mod.zig").twin_tank_anchor_arrival_yards;
const twin_route_arrival_yards: f32 = 3.0;
const twin_rally_arrival_yards: f32 = 5.0;
pub const post_twin_platform_arrival_yards: f32 = 1.0;
pub const post_twin_waypoint_arrival_yards: f32 = 3.0;
pub const post_twin_platform_settle_ms: u32 = 2000;
pub const dps_opening_hold_ms: u32 = 5000;
pub const thaddius_dps_opening_hold_ms: u32 = 5000;
pub const dps_tank_ready_poll_ms: u32 = proto.brain_tick_ms * 3;
pub const dps_swap_hold_ms: u32 = 5000;
pub const dps_sync_hold_ms: u32 = 2000;
pub const dps_sync_hold_50_pct: u32 = 50;
pub const dps_sync_hold_30_pct: u32 = 30;
pub const dps_sync_hold_15_pct: u32 = 15;
pub const dps_sync_release_5_pct: u32 = 5;
pub const transition_poll_ms: u32 = proto.brain_tick_ms * 3;
const twin_pull_intent_max_age_ms: u32 = proto.brain_tick_ms;
const thaddius_tank_engage_max_age_ms: u32 = proto.brain_tick_ms;

// ─── Twin approach ────────────────────────────────────────────────────────────

fn dpsStopThenWaitSequence(release_ms: u32, wait_max_age_ms: u32) Sequenced {
    var seq = Sequenced{ .steps = undefined, .len = 2 };
    seq.steps[0] = .{ .intent = .stop_attack };
    seq.steps[1] = .{ .intent = .{ .waiting_for = .{
        .until = .{ .game_time_at_least_ms = release_ms },
        .max_age_ms = wait_max_age_ms,
    } } };
    return seq;
}

pub fn twinApproachIntent(side: Side) ActiveIntent {
    const a1: SimpleIntent = .{ .moving_to = .{
        .pos = if (side == .left) .{ .x = arena.left_approach_1.x, .y = arena.left_approach_1.y, .z = arena.left_approach_1.z } else .{ .x = arena.right_approach_1.x, .y = arena.right_approach_1.y, .z = arena.right_approach_1.z },
        .arrival_yards = twin_route_arrival_yards,
        .reason = .encounter_route,
    } };
    const a2: SimpleIntent = .{ .moving_to = .{
        .pos = if (side == .left) .{ .x = arena.left_approach_2.x, .y = arena.left_approach_2.y, .z = arena.left_approach_2.z } else .{ .x = arena.right_approach_2.x, .y = arena.right_approach_2.y, .z = arena.right_approach_2.z },
        .arrival_yards = twin_route_arrival_yards,
        .reason = .encounter_route,
    } };
    const center = if (side == .left) arena.stalagg_initial else arena.feugen_initial;
    const rally: SimpleIntent = .{ .moving_to = .{
        .pos = .{ .x = center.x, .y = center.y, .z = center.z },
        .arrival_yards = twin_rally_arrival_yards,
        .reason = .encounter_route,
    } };

    var seq = Sequenced{ .steps = undefined, .len = 3 };
    seq.steps[0] = .{ .intent = a1, .done_when = .ctm_idle };
    seq.steps[1] = .{ .intent = a2, .done_when = .ctm_idle };
    seq.steps[2] = .{ .intent = rally, .done_when = .ctm_idle };

    return ActiveIntent{
        .intent = .{ .sequenced = seq },
        .priority = .encounter,
        .created_at_ms = 0,
        .source = .encounter_route,
    };
}

pub fn dpsOpeningHoldIntent(ctx: *const CombatContext, release_ms: u32) ActiveIntent {
    const max_age_ms = dps_opening_hold_ms + proto.brain_tick_ms;

    return ActiveIntent{
        .intent = .{ .sequenced = dpsStopThenWaitSequence(release_ms, max_age_ms) },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = max_age_ms,
        .source = .encounter_pull,
    };
}

pub fn dpsTankReadyHoldIntent(ctx: *const CombatContext) ActiveIntent {
    return ActiveIntent{
        .intent = .{ .sequenced = dpsStopThenWaitSequence(ctx.game_time_ms + proto.brain_tick_ms, dps_tank_ready_poll_ms) },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = dps_tank_ready_poll_ms,
        .source = .encounter_pull,
    };
}

pub fn dpsTankPullSequenceHoldIntent(ctx: *const CombatContext) ActiveIntent {
    return ActiveIntent{
        .intent = .{ .sequenced = dpsStopThenWaitSequence(ctx.game_time_ms + proto.brain_tick_ms, dps_tank_ready_poll_ms) },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = dps_tank_ready_poll_ms,
        .source = .encounter_pull,
    };
}

pub fn dpsSwapHoldIntent(ctx: *const CombatContext, release_ms: u32) ActiveIntent {
    const max_age_ms = dps_swap_hold_ms + proto.brain_tick_ms;

    return ActiveIntent{
        .intent = .{ .sequenced = dpsStopThenWaitSequence(release_ms, max_age_ms) },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = max_age_ms,
        .source = .encounter_swap,
    };
}

pub fn thaddiusDpsOpeningHoldIntent(ctx: *const CombatContext, release_ms: u32) ActiveIntent {
    const max_age_ms = thaddius_dps_opening_hold_ms + proto.brain_tick_ms;

    return ActiveIntent{
        .intent = .{ .sequenced = dpsStopThenWaitSequence(release_ms, max_age_ms) },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = max_age_ms,
        .source = .encounter_pull,
    };
}

pub fn thaddiusTankEngageIntent(ctx: *const CombatContext, target_guid: u64) ActiveIntent {
    var seq = Sequenced{ .steps = undefined, .len = 1 };
    seq.steps[0] = .{ .intent = .{ .targeting = .{ .target_guid = target_guid } }, .done_when = null };

    return ActiveIntent{
        .intent = .{ .sequenced = seq },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = thaddius_tank_engage_max_age_ms,
        .source = .encounter_pull,
    };
}

pub fn tankPullPlatformIntent(ctx: *const CombatContext, side: Side) ActiveIntent {
    const platform = if (side == .left) arena.left_platform else arena.right_platform;

    var seq = Sequenced{ .steps = undefined, .len = 1 };
    seq.steps[0] = .{ .intent = .{ .moving_to = .{
        .pos = .{ .x = platform.x, .y = platform.y, .z = platform.z },
        .arrival_yards = twin_tank_anchor_arrival_yards,
        .reason = .encounter_pull,
    } }, .done_when = .ctm_idle };

    return ActiveIntent{
        .intent = .{ .sequenced = seq },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = twin_pull_intent_max_age_ms,
        .source = .encounter_pull,
    };
}

pub fn tankPullFacingIntent(ctx: *const CombatContext, radians: f32) ActiveIntent {
    var seq = Sequenced{ .steps = undefined, .len = 1 };
    seq.steps[0] = .{ .intent = .{ .facing = .{ .radians = radians } }, .done_when = null };

    return ActiveIntent{
        .intent = .{ .sequenced = seq },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = twin_pull_intent_max_age_ms,
        .source = .encounter_pull,
    };
}

// ─── Tank swap ────────────────────────────────────────────────────────────────

pub fn tankSwapIntent(ctx: *const CombatContext, new_side: Side) ?ActiveIntent {
    const twin_name: []const u8 = if (new_side == .left) "Stalagg" else "Feugen";
    const twin = world_query.scanByNameOnMap(ctx.world, twin_name, map_id) orelse return null;
    if (state.twinDefeatedHp(twin.hp)) return null;

    const platform = if (new_side == .left) arena.left_platform else arena.right_platform;

    var seq = Sequenced{ .steps = undefined, .len = 3 };
    seq.steps[0] = .{ .intent = .{ .targeting = .{ .target_guid = twin.guid } }, .done_when = null };
    seq.steps[1] = .{ .intent = .{ .moving_to = .{
        .pos = .{ .x = platform.x, .y = platform.y, .z = platform.z },
        .arrival_yards = twin_tank_anchor_arrival_yards,
        .reason = .encounter_swap,
    } }, .done_when = .ctm_idle };
    seq.steps[2] = .{ .intent = .{ .targeting = .{ .target_guid = twin.guid } }, .done_when = null };

    return ActiveIntent{
        .intent = .{ .sequenced = seq },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .source = .encounter_swap,
    };
}

// ─── Post-twin transition ─────────────────────────────────────────────────────

pub fn postTwinIntent(ctx: *const CombatContext, side: Side) ActiveIntent {
    return postTwinIntentWithStop(ctx, side, false);
}

pub fn postTwinTransitionIntent(ctx: *const CombatContext, side: Side) ActiveIntent {
    return postTwinIntentWithStop(ctx, side, true);
}

fn postTwinIntentWithStop(ctx: *const CombatContext, side: Side, stop_first: bool) ActiveIntent {
    const platform = if (side == .left) arena.left_platform else arena.right_platform;
    const waypoint = if (side == .left) arena.left_waypoint else arena.right_waypoint;
    const stack = if (side == .left) arena.stack_melee_positive else arena.stack_melee_negative;
    const release_ms = ctx.game_time_ms + dps_opening_hold_ms;
    const stop_steps: u8 = if (stop_first) 2 else 0;
    const dps_steps: u8 = if (ctx.role == .tank) 0 else 1;

    var seq = Sequenced{ .steps = undefined, .len = stop_steps + 5 + dps_steps };
    var step: u8 = 0;
    if (stop_first) {
        seq.steps[step] = .{ .intent = .stop_attack, .done_when = null };
        step += 1;
        seq.steps[step] = .{ .intent = .{ .waiting_for = .{
            .until = .ctm_idle,
            .max_age_ms = transition_poll_ms,
        } } };
        step += 1;
    }
    seq.steps[step] = .{ .intent = .{ .moving_to = .{
        .pos = .{ .x = platform.x, .y = platform.y, .z = platform.z },
        .arrival_yards = post_twin_platform_arrival_yards,
        .reason = .encounter_transition,
    } }, .done_when = .ctm_idle };
    step += 1;
    seq.steps[step] = .{ .intent = .{ .waiting_for = .{
        .until = .{ .sequenced_step_elapsed_ms = post_twin_platform_settle_ms },
        .max_age_ms = post_twin_platform_settle_ms + proto.brain_tick_ms,
    } } };
    step += 1;
    seq.steps[step] = .{ .intent = .{ .use_inventory_item = arena.boots_inventory_slot }, .done_when = null };
    step += 1;
    seq.steps[step] = .{ .intent = .{ .moving_to = .{
        .pos = .{ .x = waypoint.x, .y = waypoint.y, .z = waypoint.z },
        .arrival_yards = post_twin_waypoint_arrival_yards,
        .reason = .encounter_transition,
        .non_blocking = true,
    } }, .done_when = .{ .arrived_at = .{
        .x = waypoint.x,
        .y = waypoint.y,
        .z = waypoint.z,
        .within_yards = post_twin_waypoint_arrival_yards,
    } }, .trigger_once = .{
        .when = .{ .z_above = arena.post_twin_jump_z_threshold },
        .action = .jump,
    } };
    step += 1;
    seq.steps[step] = .{ .intent = .{ .moving_to = .{
        .pos = .{ .x = stack.x, .y = stack.y, .z = stack.z },
        .arrival_yards = stack.arrival_yards,
        .reason = .encounter_transition,
        .non_blocking = true,
    } }, .done_when = .{ .arrived_at = .{
        .x = stack.x,
        .y = stack.y,
        .z = stack.z,
        .within_yards = stack.arrival_yards,
    } } };
    step += 1;
    if (ctx.role != .tank) {
        seq.steps[step] = .{ .intent = .{ .waiting_for = .{
            .until = .{ .game_time_at_least_ms = release_ms },
            .max_age_ms = dps_opening_hold_ms + proto.brain_tick_ms,
        } } };
    }

    return ActiveIntent{
        .intent = .{ .sequenced = seq },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .source = .encounter_transition,
    };
}

pub fn transitionHoldIntent(ctx: *const CombatContext) ActiveIntent {
    return ActiveIntent{
        .intent = .{ .waiting_for = .{
            .until = .{ .game_time_at_least_ms = ctx.game_time_ms + proto.brain_tick_ms },
            .max_age_ms = transition_poll_ms,
        } },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = transition_poll_ms,
        .source = .encounter_transition,
    };
}

// ─── Polarity stacking ────────────────────────────────────────────────────────

fn positionDistanceSqXY(pos: arena.PositionOverride, x: f32, y: f32) f32 {
    const dx = pos.x - x;
    const dy = pos.y - y;
    return dx * dx + dy * dy;
}

fn withinPositionXY(pos: arena.PositionOverride, x: f32, y: f32) bool {
    return positionDistanceSqXY(pos, x, y) <= pos.arrival_yards * pos.arrival_yards;
}

fn currentPolarity(ctx: *const CombatContext) Polarity {
    if (pred.hasPolarityPositive(ctx)) return .positive;
    if (pred.hasPolarityNegative(ctx)) return .negative;
    return .none;
}

fn finalStackForPolarity(polarity: Polarity) arena.PositionOverride {
    return switch (polarity) {
        .positive => arena.stack_melee_positive,
        .negative => arena.stack_melee_negative,
        .none => unreachable,
    };
}

fn waypointsForRoute(route: PolarityRoute) []const arena.PositionOverride {
    return switch (route) {
        .positive_to_negative => &arena.stack_melee_waypoints_positive_to_negative,
        .negative_to_positive => &arena.stack_melee_waypoints_negative_to_positive,
        .none => unreachable,
    };
}

fn routeDirectionForPolarity(polarity: Polarity) PolarityRoute {
    return switch (polarity) {
        .positive => .negative_to_positive,
        .negative => .positive_to_negative,
        .none => unreachable,
    };
}

/// signed scalar on the p_to_n[0]–n_to_p[1] diagonal. Positive → bot is on the same
/// side as `stack_melee_positive` (SE). Negative → NW side. Zero → exactly on
/// the line, which includes both crossing-line waypoints and the boss centre. The line is
/// the only crossing where opposite charges chain-explode; staying on one
/// side keeps the path away from the centre.
fn polarityHalfPlaneSignedScalar(x: f32, y: f32) f32 {
    const line_a = arena.stack_melee_waypoints_positive_to_negative[0];
    const line_b = arena.stack_melee_waypoints_negative_to_positive[1];
    const dir_x = line_a.x - line_b.x;
    const dir_y = line_a.y - line_b.y;
    // 90° CCW rotation of (dir_x, dir_y) yields a normal pointing toward the
    // positive stack (verified by construction: stack_melee_positive's offset
    // from the centre dotted with this normal is > 0).
    const normal_x = -dir_y;
    const normal_y = dir_x;
    const dx = x - arena.thaddius_center.x;
    const dy = y - arena.thaddius_center.y;
    return dx * normal_x + dy * normal_y;
}

/// Tolerance around the crossing-line diagonal expressed in scalar units. The
/// normal length is sqrt(16.82² + 15.67²) ≈ 22.8, so 1.0 scalar unit ≈ 0.044 yards
/// of perpendicular distance from the line. Crossing-line waypoints land on the
/// diagonal at ≈ 2.0 scalar units (≈ 0.09 yards); the tolerance must cover
/// them so bots standing on a waypoint are treated as "on the line".
const polarity_half_plane_epsilon: f32 = 3.0;

/// Compute the route a bot at `(x, y)` should take to reach the stack matching
/// `polarity`. Purely positional — does not depend on previous polarity or
/// stored state, so it survives aura blinks and bots drifting mid-fight.
///
/// A bot strictly inside the opposite half-plane must detour through the
/// alpha or beta waypoint. A bot on the line (e.g. exactly at alpha or beta)
/// is treated as already on the safe perimeter and can head directly to its
/// stack — the alternative would force it across the centre to the *other*
/// waypoint, which is exactly the explosion path we want to avoid.
pub fn routeForPolarity(polarity: Polarity, x: f32, y: f32) PolarityRoute {
    if (polarity == .none) return .none;
    const scalar = polarityHalfPlaneSignedScalar(x, y);
    return switch (polarity) {
        .positive => if (scalar >= -polarity_half_plane_epsilon) .none else .negative_to_positive,
        .negative => if (scalar <= polarity_half_plane_epsilon) .none else .positive_to_negative,
        .none => unreachable,
    };
}

fn updatePolarityRoute(bs: *BotState, polarity: Polarity, x: f32, y: f32, name: []const u8) void {
    if (polarity == .none) {
        // Sticky: keep last_polarity / polarity_waypoint_step. An aura blink
        // during Polarity Shift recast briefly drops the charge before the new
        // one is applied; we don't want that ~67 ms window to forget which
        // stack the bot was anchored to.
        return;
    }

    if (bs.last_polarity != polarity) {
        std.log.info("thaddius: [{s}] polarity {s}→{s} pos=({d:.1},{d:.1})", .{
            name, @tagName(bs.last_polarity), @tagName(polarity), x, y,
        });
        bs.last_polarity = polarity;
        bs.polarity_waypoint_step = 0;
        return;
    }

    // Same polarity. Once the bot has landed on its final stack, clear the
    // waypoint step so a future polarity change re-evaluates from scratch.
    if (withinPositionXY(finalStackForPolarity(polarity), x, y)) {
        bs.polarity_waypoint_step = 0;
    }
}

fn polarityStackStepTarget(bs: *BotState, polarity: Polarity, x: f32, y: f32, name: []const u8) arena.PositionOverride {
    const final_stack = finalStackForPolarity(polarity);
    const count = arena.polarity_waypoint_count;

    // All waypoints traversed — head directly to the final stack.
    if (bs.polarity_waypoint_step >= count) return final_stack;

    // Already at the final stack — reset step for next polarity change.
    if (withinPositionXY(final_stack, x, y)) {
        bs.polarity_waypoint_step = 0;
        return final_stack;
    }

    // step > 0: already in transit — keep following the staged waypoints
    // regardless of current half-plane position. Use the polarity direction,
    // not the half-plane route, because the bot may have crossed into the
    // correct half-plane mid-transit.
    if (bs.polarity_waypoint_step > 0) {
        const direction = routeDirectionForPolarity(polarity);
        const waypoints = waypointsForRoute(direction);
        const target_idx = bs.polarity_waypoint_step;
        // Arrived at the current target waypoint — advance step.
        if (withinPositionXY(waypoints[target_idx], x, y)) {
            bs.polarity_waypoint_step += 1;
            if (bs.polarity_waypoint_step >= count) {
                std.log.info("thaddius: [{s}] polarity={s} waypoint step {d}→{d} (all done) pos=({d:.1},{d:.1}) → final stack ({d:.1},{d:.1})", .{
                    name, @tagName(polarity), target_idx, bs.polarity_waypoint_step, x, y,
                    final_stack.x, final_stack.y,
                });
                return final_stack;
            }
            const next_wp = waypoints[bs.polarity_waypoint_step];
            std.log.info("thaddius: [{s}] polarity={s} waypoint step {d}→{d} pos=({d:.1},{d:.1}) → waypoint ({d:.1},{d:.1})", .{
                name, @tagName(polarity), target_idx, bs.polarity_waypoint_step, x, y,
                next_wp.x, next_wp.y,
            });
            return next_wp;
        }
        return waypoints[target_idx];
    }

    // step == 0: bot has not started waypoint traversal yet.
    const route = routeForPolarity(polarity, x, y);
    if (route == .none) return final_stack;

    const waypoints = waypointsForRoute(route);

    // Standing on (or within tolerance of) any staged waypoint is itself a
    // completed detour: advance the step counter past all waypoints the bot
    // has already reached and return the next unconsumed one (or final stack).
    for (waypoints, 0..) |wp, i| {
        if (withinPositionXY(wp, x, y)) {
            bs.polarity_waypoint_step = @as(u8, @intCast(i)) + 1;
            if (bs.polarity_waypoint_step >= count) {
                std.log.info("thaddius: [{s}] polarity={s} waypoint reached ({d:.1},{d:.1}) → final stack ({d:.1},{d:.1})", .{
                    name, @tagName(polarity), x, y, final_stack.x, final_stack.y,
                });
                return final_stack;
            }
        }
    }
    if (bs.polarity_waypoint_step > 0 and bs.polarity_waypoint_step < count) {
        const wp = waypoints[bs.polarity_waypoint_step];
        std.log.info("thaddius: [{s}] polarity={s} detour waypoint step {d}/{d} pos=({d:.1},{d:.1}) → waypoint ({d:.1},{d:.1})", .{
            name, @tagName(polarity), bs.polarity_waypoint_step, count, x, y,
            wp.x, wp.y,
        });
        return wp;
    }

    std.log.info("thaddius: [{s}] polarity={s} detour={s} pos=({d:.1},{d:.1}) scalar={d:.1} → waypoint ({d:.1},{d:.1})", .{
        name, @tagName(polarity), @tagName(route), x, y,
        polarityHalfPlaneSignedScalar(x, y), waypoints[0].x, waypoints[0].y,
    });
    return waypoints[0];
}

pub fn polarityStackIntent(ctx: *const CombatContext, bs: *BotState) ?ActiveIntent {
    if (ctx.bot.state.hp == 0) return null;
    const name = std.mem.sliceTo(&ctx.bot.state.player_name, 0);
    const polarity = currentPolarity(ctx);
    updatePolarityRoute(bs, polarity, ctx.bot.state.x, ctx.bot.state.y, name);
    if (polarity == .none) return null;

    const stack_pos = finalStackForPolarity(polarity);

    const dx = stack_pos.x - ctx.bot.state.x;
    const dy = stack_pos.y - ctx.bot.state.y;
    if (dx * dx + dy * dy <= stack_pos.arrival_yards * stack_pos.arrival_yards) {
        if (ctx.bot.state.ctm_action == @intFromEnum(proto.CtmAction.idle)) return null;
        return polarityCtmStopIntent(ctx);
    }

    const step_pos = polarityStackStepTarget(bs, polarity, ctx.bot.state.x, ctx.bot.state.y, name);

    return ActiveIntent{
        .intent = .{ .stacking = .{
            .x = step_pos.x,
            .y = step_pos.y,
            .z = step_pos.z,
            .tolerance = step_pos.arrival_yards,
            .reason = .encounter_stack,
        } },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        // Expires 6 ticks after the last proposal — long enough to survive the
        // stop_cast throttle window (400 ms) + CTM settle, so the intent doesn't
        // drop out while the bot is mid-transit and the role proposer can't
        // slide in a chase-inducing start_attack.
        .max_age_ms = proto.brain_tick_ms * 6,
        .source = .encounter_stack,
    };
}

fn polarityCtmStopIntent(ctx: *const CombatContext) ActiveIntent {
    return ActiveIntent{
        .intent = .{ .waiting_for = .{
            .until = .ctm_idle,
            .max_age_ms = proto.brain_tick_ms * 3,
        } },
        .priority = .encounter,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = proto.brain_tick_ms * 3,
        .source = .encounter_stack,
    };
}

pub fn polarityAnchorPosition(ctx: *const CombatContext, bs: *BotState) ?arena.PositionOverride {
    if (ctx.bot.state.hp == 0) return null;
    const name = std.mem.sliceTo(&ctx.bot.state.player_name, 0);
    const polarity = currentPolarity(ctx);
    updatePolarityRoute(bs, polarity, ctx.bot.state.x, ctx.bot.state.y, name);
    if (polarity != .none) {
        return polarityStackStepTarget(bs, polarity, ctx.bot.state.x, ctx.bot.state.y, name);
    }

    // No active charge. Anchor the bot at its last-known polarity stack — or at
    // stack_melee_positive (the post-twin landing point) when the bot hasn't
    // received any polarity yet. Without this anchor, the role proposer would
    // recompute back-arc melee positioning against Thaddius and pull the bot
    // into a cluster around the boss; when the first Polarity Shift then hits,
    // bots would route across the center and chain-explode.
    const anchor = switch (bs.last_polarity) {
        .positive => arena.stack_melee_positive,
        .negative => arena.stack_melee_negative,
        .none => if (bs.side == .left) arena.stack_melee_positive else arena.stack_melee_negative,
    };
    std.log.debug("thaddius: [{s}] polarity=none last={s} anchor=({d:.1},{d:.1}) pos=({d:.1},{d:.1})", .{
        name, @tagName(bs.last_polarity), anchor.x, anchor.y,
        ctx.bot.state.x, ctx.bot.state.y,
    });
    return anchor;
}

// ─── Twin / Thaddius GUID lookups (used by TargetStore writes) ────────────────

pub fn twinGuid(ctx: *const CombatContext, side: Side) ?u64 {
    const twin_name: []const u8 = if (side == .left) "Stalagg" else "Feugen";
    const twin = world_query.scanByNameOnMap(ctx.world, twin_name, map_id) orelse return null;
    if (state.twinDefeatedHp(twin.hp)) return null;
    return twin.guid;
}

pub fn thaddiusGuid(ctx: *const CombatContext) ?u64 {
    const boss = world_query.scanByNameOnMap(ctx.world, "Thaddius", map_id) orelse return null;
    if (proto.hasUnitFlag(boss.unit_flags, .uninteractible)) return null;
    if (proto.hasUnitFlag(boss.unit_flags, .immune_to_pc)) return null;
    return boss.guid;
}

pub fn twinHpPct(ctx: *const CombatContext, side: Side) ?u32 {
    const twin_name: []const u8 = if (side == .left) "Stalagg" else "Feugen";
    const twin = world_query.scanByNameOnMap(ctx.world, twin_name, map_id) orelse return null;
    if (state.twinDefeatedHp(twin.hp)) return 0;
    if (twin.hp_max == 0) return null;
    return @intCast((twin.hp * 100) / twin.hp_max);
}
