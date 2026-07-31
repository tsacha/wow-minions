// Pure function: derives a concrete Action from an ActiveIntent + CombatContext.
// Called once per bot per brain tick after intent proposers have run.

const std = @import("std");
const proto = @import("protocol");
const intent = @import("mod.zig");
const context = @import("../context.zig");
const action_mod = @import("../action.zig");
const role_mod = @import("../role.zig");

pub const predicateTrue = intent.predicateTrue;

const Intent = intent.Intent;
const ActiveIntent = intent.ActiveIntent;
const CombatContext = context.CombatContext;
const Action = action_mod.Action;
const FollowStore = role_mod.FollowStore;

fn sequencedStepPredicateTrue(pred: intent.Predicate, seq: *const intent.Sequenced, ctx: *const CombatContext) bool {
    return switch (pred) {
        .sequenced_step_elapsed_ms => |elapsed_ms| ctx.game_time_ms >= seq.step_started_at_ms +| elapsed_ms,
        else => predicateTrue(pred, ctx.bot.state),
    };
}

fn withinJumpNearXY(state: proto.State, target_x: f32, target_y: f32, tolerance_yards: f32) bool {
    const tol = @max(tolerance_yards, 0.0);
    const dx = state.x - target_x;
    const dy = state.y - target_y;
    return dx * dx + dy * dy <= tol * tol;
}

fn actionForStepTrigger(trigger: intent.StepTrigger) Action {
    return switch (trigger.action) {
        .jump => .jump,
    };
}

fn actionMatchesStepTrigger(trigger: intent.StepTrigger, action: Action) bool {
    return switch (trigger.action) {
        .jump => action == .jump,
    };
}

/// Advance the current step of a Sequenced intent when the step has dispatched and completed.
/// Skipped while `confirm.active` (blocking step in flight).
/// Returns true if the sequence is now exhausted.
pub fn advanceSequenced(ai: *ActiveIntent, ctx: *const CombatContext) bool {
    if (ai.confirm.active) return false;

    const seq = switch (ai.intent) {
        .sequenced => |*s| s,
        else => return false,
    };
    if (seq.current >= seq.len) return true;

    const slot = &seq.steps[seq.current];

    // waiting_for slots complete on predicate satisfaction — no dispatch required.
    if (slot.intent == .waiting_for) {
        if (!sequencedStepPredicateTrue(slot.intent.waiting_for.until, seq, ctx)) return false;
        seq.current += 1;
        seq.step_dispatched = false;
        seq.step_started_at_ms = ctx.game_time_ms;
        std.log.info("dispatch: seq [{s}] step {}/{} done (wait) → {}/{}", .{
            @tagName(ai.source), seq.current, seq.len, seq.current + 1, seq.len,
        });
        return seq.current >= seq.len;
    }

    if (!seq.step_dispatched) {
        if (slot.done_when) |pred| {
            switch (pred) {
                .arrived_at => {},
                .ctm_idle => switch (slot.intent) {
                    .moving_to => |mv| {
                        const dx = ctx.bot.state.x - mv.pos.x;
                        const dy = ctx.bot.state.y - mv.pos.y;
                        const dz = ctx.bot.state.z - mv.pos.z;
                        if (dx * dx + dy * dy + dz * dz > mv.arrival_yards * mv.arrival_yards) return false;
                    },
                    else => return false,
                },
                else => return false,
            }
            if (!sequencedStepPredicateTrue(pred, seq, ctx)) return false;
        } else {
            return false;
        }
    }
    if (slot.done_when) |pred| {
        if (!sequencedStepPredicateTrue(pred, seq, ctx)) return false;
    }

    const old_step = seq.current;
    seq.current += 1;
    seq.step_dispatched = false;
    seq.step_started_at_ms = ctx.game_time_ms;
    std.log.info("dispatch: seq [{s}] step {}/{} done → {}/{}", .{
        @tagName(ai.source), old_step + 1, seq.len, seq.current + 1, seq.len,
    });
    return seq.current >= seq.len;
}

/// Mark the current sequenced step as dispatched (call from `intent_confirm.onDispatched`).
pub fn markSequencedStepDispatched(ai: *ActiveIntent) void {
    const seq = switch (ai.intent) {
        .sequenced => |*s| s,
        else => return,
    };
    seq.step_dispatched = true;
}

pub fn markSequencedStepTriggerFired(ai: *ActiveIntent, action: Action, ctx: *const CombatContext) void {
    const seq = switch (ai.intent) {
        .sequenced => |*s| s,
        else => return,
    };
    if (seq.current >= seq.len) return;

    if (seq.steps[seq.current].trigger_once) |*trigger| {
        if (trigger.fired) return;
        if (!sequencedStepPredicateTrue(trigger.when, seq, ctx)) return;
        if (!actionMatchesStepTrigger(trigger.*, action)) return;

        trigger.fired = true;
    }
}

/// Skip undispatched spell steps whose spell is currently unavailable.
/// Returns true when the sequence becomes exhausted.
pub fn skipUnavailableSequenced(ai: *ActiveIntent, ctx: *const CombatContext) bool {
    if (ai.confirm.active) return false;
    if (ai.source == .operator_burst or ai.source == .operator_raid_buff) return false;

    const seq = switch (ai.intent) {
        .sequenced => |*s| s,
        else => return false,
    };

    while (seq.current < seq.len) {
        const slot = seq.steps[seq.current];
        if (slot.intent != .casting_scripted) return false;
        if (seq.step_dispatched) return false;

        const cast = slot.intent.casting_scripted;
        if (ctx.spellReady(cast.spell_id)) return false;

        const old_step = seq.current;
        seq.current += 1;
        std.log.info("dispatch: seq [{s}] step {}/{} skipped (cooldown spell={}) → {}/{}", .{
            @tagName(ai.source), old_step + 1, seq.len, cast.spell_id, seq.current + 1, seq.len,
        });
    }

    return seq.current >= seq.len;
}

/// Derive a wire action from the current intent. Returns `.none` when the intent
/// produces no action this tick (e.g. already arrived, waiting predicate not met).
pub fn actionForIntent(ai: ActiveIntent, ctx: *const CombatContext, follow: *FollowStore) Action {
    return switch (ai.intent) {
        .idle => .none,

        .moving_to => |mv| blk: {
            const dx = mv.pos.x - ctx.bot.state.x;
            const dy = mv.pos.y - ctx.bot.state.y;
            const dz = mv.pos.z - ctx.bot.state.z;
            const dist_sq = dx * dx + dy * dy + dz * dz;
            const thresh = mv.arrival_yards * mv.arrival_yards;
            if (dist_sq <= thresh) break :blk .none;
            if (mv.non_blocking) {
                break :blk Action{ .move_to_nb = .{ .x = mv.pos.x, .y = mv.pos.y, .z = mv.pos.z, .arrival_yards = mv.arrival_yards } };
            }
            break :blk Action{ .move_to = .{ .x = mv.pos.x, .y = mv.pos.y, .z = mv.pos.z, .arrival_yards = mv.arrival_yards } };
        },

        .following => .none,

        .stacking => |st| blk: {
            const dx = st.x - ctx.bot.state.x;
            const dy = st.y - ctx.bot.state.y;
            const dz = st.z - ctx.bot.state.z;
            const dist_sq = dx * dx + dy * dy + dz * dz;
            const thresh = st.tolerance * st.tolerance;
            if (dist_sq <= thresh) break :blk .none;
            break :blk Action{ .move_to = .{ .x = st.x, .y = st.y, .z = st.z, .arrival_yards = st.tolerance } };
        },

        .targeting => |target| Action{ .target_guid = target.target_guid },
        .attacking => |atk| Action{ .attack = atk.target_guid },

        .casting_scripted => |cs| blk: {
            if (cs.instant) {
                if (cs.target_guid == ctx.bot.state.guid or cs.target_guid == 0) {
                    break :blk Action{ .cast_instant = cs.spell_id };
                }
                break :blk Action{ .cast_target_instant = .{
                    .spell_id = cs.spell_id,
                    .target_guid = cs.target_guid,
                } };
            }
            if (cs.target_guid == ctx.bot.state.guid or cs.target_guid == 0) {
                break :blk Action{ .cast = cs.spell_id };
            }
            break :blk Action{ .cast_target = .{
                .spell_id = cs.spell_id,
                .target_guid = cs.target_guid,
            } };
        },

        .casting_scripted_ground => |cs| Action{ .cast_ground = .{
            .spell_id = cs.spell_id,
            .x = cs.x,
            .y = cs.y,
            .z = cs.z,
        } },

        .facing => |f| Action{ .set_facing_rad = f.radians },
        .start_attack => .start_attack,
        .stop_attack => .stop_attack,

        .jump => .jump,
        .use_inventory_item => |slot| Action{ .use_inventory_item = slot },
        .apply_poison => |item_id| Action{ .apply_poison = item_id },

        .jump_near => |j| Action{ .jump_near_xy = .{
            .x = j.x,
            .y = j.y,
            .tolerance_yards = j.tolerance_yards,
        } },

        .waiting_for => |wf| blk: {
            if (wf.until == .ctm_idle) {
                if (ctx.bot.state.ctm_action != @intFromEnum(proto.CtmAction.idle)) {
                    break :blk .ctm_stop;
                }
            }
            break :blk .none;
        },

        .sequenced => |*seq| blk: {
            if (seq.current >= seq.len) break :blk .none;
            const step = seq.steps[seq.current];
            if (step.trigger_once) |trigger| {
                if (!trigger.fired and sequencedStepPredicateTrue(trigger.when, seq, ctx)) {
                    if (seq.step_dispatched) break :blk actionForStepTrigger(trigger);
                }
            }
            const result: intent.Intent = switch (step.intent) {
                .idle => .idle,
                .moving_to => |v| .{ .moving_to = v },
                .following => |v| .{ .following = v },
                .stacking => |v| .{ .stacking = v },
                .targeting => |v| .{ .targeting = v },
                .attacking => |v| .{ .attacking = v },
                .casting_scripted => |v| .{ .casting_scripted = v },
                .casting_scripted_ground => |v| .{ .casting_scripted_ground = v },
                .facing => |v| .{ .facing = v },
                .start_attack => .start_attack,
                .stop_attack => .stop_attack,
                .jump => .jump,
                .use_inventory_item => |item_slot| .{ .use_inventory_item = item_slot },
                .apply_poison => |item_id| .{ .apply_poison = item_id },
                .jump_near => |v| .{ .jump_near = v },
                .waiting_for => |v| .{ .waiting_for = v },
                .sequenced => .idle,
            };
            const sub_ai = ActiveIntent{
                .intent = result,
                .priority = ai.priority,
                .created_at_ms = ai.created_at_ms,
                .source = ai.source,
            };
            break :blk actionForIntent(sub_ai, ctx, follow);
        },
    };
}

test "actionForIntent: facing and start_attack" {
    const registry_mod = @import("registry");
    var bot: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.game_time_ms = 1000;
    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    var follow: FollowStore = .{};

    const facing = actionForIntent(.{
        .intent = .{ .facing = .{ .radians = 2.5 } },
        .priority = .role,
        .created_at_ms = 1000,
        .source = .role_facing,
    }, &ctx, &follow);
    try std.testing.expectEqual(Action{ .set_facing_rad = 2.5 }, facing);

    const atk = actionForIntent(.{
        .intent = .start_attack,
        .priority = .role,
        .created_at_ms = 1000,
        .source = .role_start_attack,
    }, &ctx, &follow);
    try std.testing.expect(atk == .start_attack);
}
