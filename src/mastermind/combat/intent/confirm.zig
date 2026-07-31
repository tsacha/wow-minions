//! Per-intent dispatch confirmation (latency guards) for the intent path in `brain.compute`.

const std = @import("std");
const proto = @import("protocol");
const action_mod = @import("../action.zig");
const dispatch = @import("../dispatch.zig");
const intent = @import("mod.zig");
const intent_dispatch = @import("dispatch.zig");
const context = @import("../context.zig");
const aura_mod = @import("../aura.zig");
const spells_db = @import("../spells.zig");
const world_query = @import("../world_query.zig");
const Action = action_mod.Action;
const ActiveIntent = intent.ActiveIntent;
const CombatContext = context.CombatContext;

const ctm_stop_settle_ticks: u32 = 3;
pub const ctm_stop_settle_ms: u32 = proto.brain_tick_ms * ctm_stop_settle_ticks;
const non_instant_event_confirm_grace_ticks: u32 = 2;
const non_instant_event_confirm_grace_ms: u32 = proto.brain_tick_ms * non_instant_event_confirm_grace_ticks;
// A blocking `.move_to` only completes once the engine reports motion
// (`move_started`) and then a stop. A CTM the engine never acted on — e.g.
// issued while the bot was channeling — leaves `move_started` false forever and
// the step holds indefinitely. After this grace with no observed motion we treat
// the order as not received and re-dispatch it.
const move_start_grace_ticks: u32 = 4;
const move_start_grace_ms: u32 = proto.brain_tick_ms * move_start_grace_ticks;
const hunger_for_blood_spell_id: u32 = 51662;
const hunger_for_blood_aura_id: u32 = 63848;

pub const Confirm = struct {
    active: bool = false,
    move_started: bool = false,
    cast_stop_sent: bool = false,
    last_action: Action = .none,
    pending: ?Action = null,
    expected_spell_id: u32 = 0,
    dispatched_at_ms: u32 = 0,
    spell_phase: SpellPhase = .none,

    pub fn clear(c: *Confirm) void {
        c.* = .{};
    }

    pub fn begin(c: *Confirm, action: Action) void {
        c.* = .{
            .active = true,
            .last_action = action,
        };
    }
};

const SpellPhase = enum {
    none,
    waiting_go,
    waiting_channel_end,
};

const SpellTickResult = enum {
    pending,
    complete,
    retry,
};

fn withinJumpNearXY(state: proto.State, target_x: f32, target_y: f32, tolerance_yards: f32) bool {
    const tol = @max(tolerance_yards, 0.0);
    const dx = state.x - target_x;
    const dy = state.y - target_y;
    return dx * dx + dy * dy <= tol * tol;
}

fn withinMoveArrival(state: proto.State, target_x: f32, target_y: f32, target_z: f32, arrival_yards: f32) bool {
    const tol = @max(arrival_yards, 0.0);
    const dx = state.x - target_x;
    const dy = state.y - target_y;
    const dz = state.z - target_z;
    return dx * dx + dy * dy + dz * dz <= tol * tol;
}

pub fn needsLatencyGuard(action: Action) bool {
    return switch (action) {
        .none, .attack, .target_guid, .interact, .jump, .walk, .start_attack, .stop_attack, .stop_cast, .clear_target, .set_facing_rad, .use_inventory_item, .apply_poison => false,
        .ctm_stop => true,
        .cast_instant, .cast_target_instant, .cast_ground, .move_to_nb, .cast, .cast_target, .move_to, .jump_near_xy => true,
    };
}

pub fn isInstantAction(action: Action) bool {
    return switch (action) {
        .none, .attack, .target_guid, .interact, .jump, .walk, .start_attack, .stop_attack, .stop_cast, .ctm_stop, .clear_target, .set_facing_rad, .move_to_nb, .cast_instant, .cast_target_instant, .use_inventory_item, .apply_poison => true,
        .cast_ground => true,
        .cast, .cast_target, .move_to, .jump_near_xy => false,
    };
}

pub fn needsPreCastStop(action: Action) bool {
    return switch (action) {
        .cast, .cast_target, .cast_ground => true,
        else => false,
    };
}

fn shouldCancelStep(action: Action, state: proto.State, move_started: bool) bool {
    return switch (action) {
        .jump_near_xy => |j| move_started and
            state.ctm_action == @intFromEnum(proto.CtmAction.idle) and
            !withinJumpNearXY(state, j.x, j.y, j.tolerance_yards),
        else => false,
    };
}

fn stepIsComplete(state: proto.State, action: Action) bool {
    return switch (action) {
        .none => true,
        .cast, .cast_target => false,
        .cast_instant, .cast_target_instant, .cast_ground, .use_inventory_item, .apply_poison => true,
        .attack, .target_guid, .interact, .jump, .walk, .start_attack, .stop_attack, .stop_cast, .ctm_stop, .clear_target => true,
        .set_facing_rad => |rad| blk: {
            const diff = @abs(rad - state.orientation);
            const err = if (diff > std.math.pi) 2.0 * std.math.pi - diff else diff;
            break :blk err <= 0.1;
        },
        .move_to_nb => true,
        .move_to => state.ctm_action == @intFromEnum(proto.CtmAction.idle),
        .jump_near_xy => |j| withinJumpNearXY(state, j.x, j.y, j.tolerance_yards),
    };
}

fn tickLastAction(c: *Confirm, state: proto.State) bool {
    const action = c.last_action;
    switch (action) {
        .move_to => {
            if (!c.move_started) {
                if (state.ctm_action == @intFromEnum(proto.CtmAction.move))
                    c.move_started = true;
                return false;
            }
            return state.ctm_action == @intFromEnum(proto.CtmAction.idle);
        },
        else => {
            if (action == .ctm_stop) {
                return state.game_time_ms >= c.dispatched_at_ms +| ctm_stop_settle_ms;
            }
            if (shouldCancelStep(action, state, c.move_started)) return true;
            return stepIsComplete(state, action);
        },
    }
}

fn actionSpellId(action: Action) u32 {
    return switch (action) {
        .cast, .cast_instant => |spell_id| spell_id,
        .cast_ground => |cast| cast.spell_id,
        .cast_target => |cast| cast.spell_id,
        .cast_target_instant => |cast| cast.spell_id,
        else => 0,
    };
}

fn isSpellAction(action: Action) bool {
    return switch (action) {
        .cast, .cast_instant, .cast_target, .cast_target_instant, .cast_ground => true,
        else => false,
    };
}

fn selfAuraExpected(spell_id: u32) bool {
    return spell_id == hunger_for_blood_spell_id;
}

fn expectedSelfAuraId(spell_id: u32) ?u32 {
    return switch (spell_id) {
        hunger_for_blood_spell_id => hunger_for_blood_aura_id,
        else => null,
    };
}

fn actionTargetGuid(action: Action) u64 {
    return switch (action) {
        .cast_target => |cast| cast.target_guid,
        .cast_target_instant => |cast| cast.target_guid,
        else => 0,
    };
}

fn targetHasExpectedAura(state: proto.State, spell_id: u32) bool {
    const n = @min(state.target_aura_count, state.target_auras.len);
    for (state.target_auras[0..n]) |aura| {
        if (aura.spell_id == spell_id) return true;
    }
    return false;
}

fn targetHasExpectedAuraOnWorld(ctx: *const CombatContext, spell_id: u32, target_guid: u64) bool {
    const target = world_query.scanForGuidOnMap(ctx.world, target_guid, ctx.bot.state.map_id) orelse return false;
    const n = @min(target.aura_count, target.auras.len);
    for (target.auras[0..n]) |aura| {
        if (aura.spell_id == spell_id) return true;
    }
    return false;
}

fn spellStillCasting(state: proto.State, spell_id: u32) bool {
    return (state.is_casting != 0 and state.casting_spell_id == spell_id) or
        (state.is_channeling != 0 and state.channel_spell_id == spell_id);
}

fn nonInstantRetryReady(c: *const Confirm, state: proto.State) bool {
    if (state.game_time_ms < c.dispatched_at_ms +| dispatch.instant_cast_debounce_ms) return false;
    if (state.cast_end_time_ms > c.dispatched_at_ms and state.game_time_ms < state.cast_end_time_ms) return false;
    if (state.channel_end_time_ms > c.dispatched_at_ms and state.game_time_ms < state.channel_end_time_ms) return false;
    return true;
}

fn nonInstantEventConfirmReady(c: *const Confirm, state: proto.State) bool {
    return state.game_time_ms >= c.dispatched_at_ms +| non_instant_event_confirm_grace_ms;
}

fn oneShotSpellIntent(ai: *const ActiveIntent) bool {
    return switch (ai.intent) {
        .casting_scripted => |cast| cast.one_shot,
        .casting_scripted_ground => |cast| cast.one_shot,
        .sequenced => |seq| blk: {
            if (seq.current >= seq.len) break :blk false;
            const slot = seq.steps[seq.current];
            break :blk switch (slot.intent) {
                .casting_scripted => |cast| cast.one_shot,
                .casting_scripted_ground => |cast| cast.one_shot,
                else => false,
            };
        },
        else => false,
    };
}

fn eventMatchesSpell(c: *const Confirm, bot_guid: u64, event: proto.SpellEvent) bool {
    if (event.caster_guid != bot_guid) return false;
    if (event.game_time_ms < c.dispatched_at_ms) return false;
    if (event.spell_id != 0 and event.spell_id != c.expected_spell_id) return false;
    return true;
}

fn tickSpellAction(ai: *ActiveIntent, c: *Confirm, ctx: *const CombatContext) SpellTickResult {
    const target_guid = actionTargetGuid(c.last_action);
    if (target_guid != 0 and target_guid == ctx.bot.state.target_guid) {
        // state.target_auras refreshes every State frame (~67 ms) while scan
        // auras come with the slower scan stream. Accept either as confirmation
        // so the bot stops idling in confirm.active longer than necessary.
        if (targetHasExpectedAura(ctx.bot.state, c.expected_spell_id)) return .complete;
        if (targetHasExpectedAuraOnWorld(ctx, c.expected_spell_id, target_guid)) return .complete;
    }
    const self_targeted_instant = isInstantAction(c.last_action) and target_guid == 0;
    if (self_targeted_instant) {
        if (expectedSelfAuraId(c.expected_spell_id)) |aura_id| {
            if (aura_mod.remainingMsOnSelf(ctx.bot.state, aura_id) != null) {
                return .complete;
            }
        }
    }

    if (!isInstantAction(c.last_action) and spellStillCasting(ctx.bot.state, c.expected_spell_id)) {
        return .pending;
    }

    for (ctx.spell_events) |event| {
        if (!eventMatchesSpell(c, ctx.bot.state.guid, event)) continue;

        const kind = std.enums.fromInt(proto.SpellEventKind, event.kind) orelse continue;
        switch (kind) {
            .failed, .interrupted => {
                ai.intent = .idle;
                return .complete;
            },
            .go => {
                if (c.spell_phase == .waiting_go and
                    (isInstantAction(c.last_action) or nonInstantEventConfirmReady(c, ctx.bot.state)))
                {
                    if (self_targeted_instant) {
                        if (expectedSelfAuraId(c.expected_spell_id)) |aura_id| {
                            if (aura_mod.remainingMsOnSelf(ctx.bot.state, aura_id) == null) {
                                return .pending;
                            }
                        }
                    }
                    return .complete;
                }
            },
            .channel_update => {
                if (c.spell_phase == .waiting_channel_end and event.value_ms == 0) return .complete;
            },
            .channel_end => {
                if (c.spell_phase == .waiting_channel_end) return .complete;
            },
            .start => {},
        }
    }
    if (isInstantAction(c.last_action) and
        ctx.game_time_ms >= c.dispatched_at_ms +| dispatch.instant_cast_debounce_ms)
    {
        if (self_targeted_instant and expectedSelfAuraId(c.expected_spell_id) != null) return .pending;
        if (oneShotSpellIntent(ai)) return .complete;
        return .retry;
    }
    if (!isInstantAction(c.last_action) and nonInstantRetryReady(c, ctx.bot.state)) {
        return .retry;
    }
    return .pending;
}

/// While `confirm.active`, derive the wire action for this tick (or hold).
pub fn actionWhileConfirming(
    ai: *ActiveIntent,
    c: *Confirm,
    ctx: *const CombatContext,
) ?Action {
    if (!c.active) return null;

    if (c.pending) |pending| {
        if (!c.cast_stop_sent) return .ctm_stop;
        if (ctx.bot.state.ctm_action != @intFromEnum(proto.CtmAction.idle)) return null;
        c.pending = null;
        c.cast_stop_sent = false;
        c.last_action = pending;
        c.move_started = false;
        return pending;
    }

    if (isSpellAction(c.last_action)) {
        switch (tickSpellAction(ai, c, ctx)) {
            .pending => return null,
            .complete => {
                if (oneShotSpellIntent(ai) and ai.intent != .sequenced) ai.intent = .idle;
                c.clear();
                return null;
            },
            .retry => {
                const retry_action = c.last_action;
                c.clear();
                return retry_action;
            },
        }
    }

    if (c.last_action == .move_to and !c.move_started and
        ctx.bot.state.ctm_action == @intFromEnum(proto.CtmAction.idle) and
        ctx.game_time_ms >= c.dispatched_at_ms +| move_start_grace_ms)
    {
        const mv = c.last_action.move_to;
        // Bot already inside the destination's arrival radius: the engine issues
        // no motion for a move-to-current-position, so `move_started` would never
        // latch and this guard would re-dispatch forever, pinning `confirm.active`
        // and starving the next intent. Treat it as complete instead.
        if (withinMoveArrival(ctx.bot.state, mv.x, mv.y, mv.z, mv.arrival_yards)) {
            c.clear();
            return null;
        }
        return c.last_action;
    }

    if (tickLastAction(c, ctx.bot.state)) {
        if (shouldCancelStep(c.last_action, ctx.bot.state, c.move_started)) {
            ai.intent = .idle;
        }
        c.clear();
        return null;
    }

    return null;
}

/// `actionToMsg` returns null while waiting to enter jump range — still track CTM/cancel state.
pub fn trackJumpNearWithoutMsg(ai: ?*ActiveIntent, action: Action, state: proto.State) bool {
    const a = switch (action) {
        .jump_near_xy => action,
        else => return false,
    };
    const ptr = ai orelse return true;
    if (state.ctm_action != @intFromEnum(proto.CtmAction.idle)) {
        ptr.confirm.move_started = true;
    }
    if (shouldCancelStep(a, state, ptr.confirm.move_started)) {
        ptr.intent = .idle;
        ptr.confirm.clear();
    }
    return true;
}

pub fn onDispatched(ai: *ActiveIntent, c: *Confirm, action: Action, game_time_ms: u32) void {
    if (action == .ctm_stop and c.pending != null) {
        c.cast_stop_sent = true;
        return;
    }
    if (needsLatencyGuard(action)) {
        c.begin(action);
        if (action == .ctm_stop) {
            c.dispatched_at_ms = game_time_ms;
            return;
        }
        if (isSpellAction(action)) {
            const spell_id = actionSpellId(action);
            c.expected_spell_id = spell_id;
            c.dispatched_at_ms = game_time_ms;
            c.spell_phase = if (spells_db.isChannel(spell_id)) .waiting_channel_end else .waiting_go;
        } else if (isInstantAction(action) and expectedSelfAuraId(actionSpellId(action)) == null) {
            c.clear();
        } else {
            // Non-instant movement guard (.move_to / .jump_near_xy): stamp the
            // dispatch time so the move-start liveness check can detect a CTM the
            // engine never acted on (e.g. issued mid-channel) and re-dispatch it.
            c.dispatched_at_ms = game_time_ms;
        }
    }
    intent_dispatch.markSequencedStepDispatched(ai);
}

test "spell confirm completes cast on go event" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0x44;
    bot.state.game_time_ms = 1400;

    const events = [_]proto.SpellEvent{.{
        .kind = @intFromEnum(proto.SpellEventKind.go),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x44,
        .caster_guid = 0x44,
        .spell_id = 42897,
        .flags = 0,
        .value_ms = 1401,
        .game_time_ms = 1401,
    }};
    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &events, true);

    var ai = ActiveIntent{
        .intent = .{ .casting_scripted = .{ .spell_id = 42897, .target_guid = 0 } },
        .priority = .spec,
        .created_at_ms = 1000,
        .source = .spec_attack,
    };
    onDispatched(&ai, &ai.confirm, .{ .cast = 42897 }, 1000);

    try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx) == null);
    try std.testing.expect(!ai.confirm.active);
}

test "spell confirm waits for channel end event" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0x55;
    bot.state.game_time_ms = 2000;

    const events = [_]proto.SpellEvent{
        .{
            .kind = @intFromEnum(proto.SpellEventKind.channel_update),
            ._pad = .{ 0, 0, 0 },
            .observer_guid = 0x55,
            .caster_guid = 0x55,
            .spell_id = 0,
            .flags = 0,
            .value_ms = 1200,
            .game_time_ms = 2001,
        },
        .{
            .kind = @intFromEnum(proto.SpellEventKind.channel_end),
            ._pad = .{ 0, 0, 0 },
            .observer_guid = 0x55,
            .caster_guid = 0x55,
            .spell_id = 0,
            .flags = 0,
            .value_ms = 0,
            .game_time_ms = 2002,
        },
    };

    var ai = ActiveIntent{
        .intent = .{ .casting_scripted = .{ .spell_id = 58381, .target_guid = 0xabc } },
        .priority = .spec,
        .created_at_ms = 2000,
        .source = .spec_attack,
    };
    onDispatched(&ai, &ai.confirm, .{ .cast_target = .{ .spell_id = 58381, .target_guid = 0xabc } }, 2000);

    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, events[0..1], true);
    try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx) == null);
    try std.testing.expect(ai.confirm.active);

    const ctx_end = context.CombatContext.build(bot, &.{bot}, &.{}, &events, true);
    try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx_end) == null);
    try std.testing.expect(!ai.confirm.active);
}

test "spell confirm cancels intent on failure event" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0x66;
    bot.state.game_time_ms = 3000;

    const events = [_]proto.SpellEvent{.{
        .kind = @intFromEnum(proto.SpellEventKind.failed),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x66,
        .caster_guid = 0x66,
        .spell_id = 49238,
        .flags = 5,
        .value_ms = 0,
        .game_time_ms = 3001,
    }};

    var ai = ActiveIntent{
        .intent = .{ .casting_scripted = .{ .spell_id = 49238, .target_guid = 0xdef } },
        .priority = .spec,
        .created_at_ms = 3000,
        .source = .spec_attack,
    };
    onDispatched(&ai, &ai.confirm, .{ .cast_target = .{ .spell_id = 49238, .target_guid = 0xdef } }, 3000);

    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &events, true);
    try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx) == null);
    try std.testing.expect(ai.intent == .idle);
    try std.testing.expect(!ai.confirm.active);
}

test "spell confirm holds self-targeted instant casts until self aura appears" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0x77;
    bot.state.game_time_ms = 3000;

    var ai = ActiveIntent{
        .intent = .{ .casting_scripted = .{ .spell_id = 51662, .target_guid = 0 } },
        .priority = .spec,
        .created_at_ms = 3000,
        .source = .spec_attack,
    };
    onDispatched(&ai, &ai.confirm, .{ .cast_instant = 51662 }, 3000);

    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx) == null);
    try std.testing.expect(ai.confirm.active);

    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0x77, .spell_id = 63848, .remaining_ms = 20000 };
    const ctx_with_aura = context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx_with_aura) == null);
    try std.testing.expect(!ai.confirm.active);
}

test "spell confirm completes targeted dot when target aura becomes visible" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0x77;
    bot.state.target_guid = 0xabc;
    bot.state.game_time_ms = 4000;
    bot.state.target_aura_count = 1;
    bot.state.target_auras[0] = .{
        .caster_guid = 0x77,
        .spell_id = 47813,
        .remaining_ms = 18_000,
    };

    var ai = ActiveIntent{
        .intent = .{ .casting_scripted = .{ .spell_id = 47813, .target_guid = 0xabc } },
        .priority = .spec,
        .created_at_ms = 4000,
        .source = .spec_attack,
    };
    onDispatched(&ai, &ai.confirm, .{ .cast_target_instant = .{ .spell_id = 47813, .target_guid = 0xabc } }, 4000);

    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx) == null);
    try std.testing.expect(!ai.confirm.active);
}

test "spell confirm does not retry while cast is still in progress" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0x88;
    bot.state.game_time_ms = 6000;
    bot.state.is_casting = 1;
    bot.state.casting_spell_id = 47841;
    bot.state.cast_end_time_ms = 7000;

    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);

    var ai = ActiveIntent{
        .intent = .{ .casting_scripted = .{ .spell_id = 47841, .target_guid = 0xabc } },
        .priority = .spec,
        .created_at_ms = 4000,
        .source = .spec_attack,
    };
    onDispatched(&ai, &ai.confirm, .{ .cast_target = .{ .spell_id = 47841, .target_guid = 0xabc } }, 4000);

    try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx) == null);
    try std.testing.expect(ai.confirm.active);
}

test "spell confirm retries non-instant cast after cast window with no event" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0x99;
    bot.state.game_time_ms = 7000;
    bot.state.cast_end_time_ms = 6500;

    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);

    var ai = ActiveIntent{
        .intent = .{ .casting_scripted = .{ .spell_id = 47841, .target_guid = 0xabc } },
        .priority = .spec,
        .created_at_ms = 5000,
        .source = .spec_attack,
    };
    onDispatched(&ai, &ai.confirm, .{ .cast_target = .{ .spell_id = 47841, .target_guid = 0xabc } }, 5000);

    const next = actionWhileConfirming(&ai, &ai.confirm, &ctx) orelse return error.TestUnexpectedResult;
    try std.testing.expect(next == .cast_target);
    try std.testing.expectEqual(@as(u32, 47841), next.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), next.cast_target.target_guid);
}

test "spell confirm ignores early go for non-instant cast until grace window" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0xaa;
    bot.state.game_time_ms = 5_100;

    const events = [_]proto.SpellEvent{.{
        .kind = @intFromEnum(proto.SpellEventKind.go),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0xaa,
        .caster_guid = 0xaa,
        .spell_id = 47809,
        .flags = 0,
        .value_ms = 0,
        .game_time_ms = 5_100,
    }};

    var ai = ActiveIntent{
        .intent = .{ .casting_scripted = .{ .spell_id = 47809, .target_guid = 0xabc } },
        .priority = .spec,
        .created_at_ms = 5_000,
        .source = .spec_attack,
    };
    onDispatched(&ai, &ai.confirm, .{ .cast_target = .{ .spell_id = 47809, .target_guid = 0xabc } }, 5_000);

    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &events, true);
    try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx) == null);
    try std.testing.expect(ai.confirm.active);
}

test "move_to re-dispatches when the bot never starts moving (CTM not received)" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0x77;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    var ai = ActiveIntent{
        .intent = .{ .stacking = .{ .x = 10, .y = 20, .z = 0, .tolerance = 1.5 } },
        .priority = .encounter,
        .created_at_ms = 1_000,
        .source = .encounter_stack,
    };
    onDispatched(&ai, &ai.confirm, .{ .move_to = .{ .x = 10, .y = 20, .z = 0 } }, 1_000);
    try std.testing.expect(ai.confirm.active);
    try std.testing.expectEqual(@as(u32, 1_000), ai.confirm.dispatched_at_ms);

    // Within grace, still idle: hold (the bot may simply be about to move).
    {
        var b = bot;
        b.state.game_time_ms = 1_000 + move_start_grace_ms - 1;
        const ctx = context.CombatContext.build(b, &.{b}, &.{}, &.{}, true);
        try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx) == null);
    }

    // Past grace, never moved: treat the CTM as lost and re-dispatch the move_to.
    {
        var b = bot;
        b.state.game_time_ms = 1_000 + move_start_grace_ms;
        const ctx = context.CombatContext.build(b, &.{b}, &.{}, &.{}, true);
        const out = actionWhileConfirming(&ai, &ai.confirm, &ctx);
        try std.testing.expect(out != null);
        try std.testing.expect(std.meta.activeTag(out.?) == .move_to);
    }
}

test "move_to to a destination the bot already occupies completes instead of re-dispatching forever" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0x79;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    // Bot is standing 0.1 yd from the commanded destination — well inside the
    // 1.5 yd arrival radius. The engine issues no motion, so move_started never
    // latches; without the arrival check this guard would re-dispatch forever.
    bot.state.x = 10.1;
    bot.state.y = 20.0;
    bot.state.z = 0.0;

    var ai = ActiveIntent{
        .intent = .{ .stacking = .{ .x = 10, .y = 20, .z = 0, .tolerance = 1.5 } },
        .priority = .encounter,
        .created_at_ms = 1_000,
        .source = .encounter_stack,
    };
    onDispatched(&ai, &ai.confirm, .{ .move_to = .{ .x = 10, .y = 20, .z = 0, .arrival_yards = 1.5 } }, 1_000);
    try std.testing.expect(ai.confirm.active);

    bot.state.game_time_ms = 1_000 + move_start_grace_ms;
    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx) == null);
    try std.testing.expect(!ai.confirm.active);
}

test "move_to does not re-dispatch once the bot has started moving" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0x78;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    bot.state.game_time_ms = 1_000 + move_start_grace_ms;

    var ai = ActiveIntent{
        .intent = .{ .stacking = .{ .x = 10, .y = 20, .z = 0, .tolerance = 1.5 } },
        .priority = .encounter,
        .created_at_ms = 1_000,
        .source = .encounter_stack,
    };
    onDispatched(&ai, &ai.confirm, .{ .move_to = .{ .x = 10, .y = 20, .z = 0 } }, 1_000);

    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    // Observing motion latches move_started and holds; no re-dispatch even past grace.
     try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx) == null);
    try std.testing.expect(ai.confirm.move_started);
}

test "move_to does not latch move_started on attack_pos CTM" {
    const registry_mod = @import("registry");

    var bot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.guid = 0x79;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.attack_pos);
    bot.state.game_time_ms = 1_000 + move_start_grace_ms;

    var ai = ActiveIntent{
        .intent = .{ .stacking = .{ .x = 10, .y = 20, .z = 0, .tolerance = 1.5 } },
        .priority = .encounter,
        .created_at_ms = 1_000,
        .source = .encounter_stack,
    };
    onDispatched(&ai, &ai.confirm, .{ .move_to = .{ .x = 10, .y = 20, .z = 0 } }, 1_000);

    // attack_pos is not a command movement — the engine is chasing, not
    // executing our move_to. move_started must stay false so the brain's
    // polarity-transit-target-clear can fire on the holding ticks, and the
    // grace-gate can re-dispatch once CTM returns to idle.
    const ctx = context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true);
    try std.testing.expect(actionWhileConfirming(&ai, &ai.confirm, &ctx) == null);
    try std.testing.expect(!ai.confirm.move_started);

    // Once the chase is cleared (CTM idle, past grace, move not started),
    // the confirm re-dispatches the lost move.
    {
        var b = bot;
        b.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
        b.state.game_time_ms = 1_000 + move_start_grace_ms;
        const ctx2 = context.CombatContext.build(b, &.{b}, &.{}, &.{}, true);
        const retry = actionWhileConfirming(&ai, &ai.confirm, &ctx2);
        try std.testing.expect(retry != null);
        try std.testing.expect(std.meta.activeTag(retry.?) == .move_to);
    }
}
