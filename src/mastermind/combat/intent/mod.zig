// Intent system: each bot has exactly one ActiveIntent at any moment.
// An intent describes WHAT the bot should accomplish, not WHAT to dispatch this tick.
// The dispatcher derives a concrete Action from (Intent, CombatContext) each tick.

const std = @import("std");
const proto = @import("protocol");
const types = @import("types");
const geo = @import("../geo.zig");
const dispatch_store_mod = @import("../dispatch_store.zig");
const intent_confirm = @import("confirm.zig");
const brain_log = @import("../../brain/log.zig");
pub const BotId = types.BotId;
pub const DispatchStore = dispatch_store_mod.DispatchStore;
pub const Confirm = intent_confirm.Confirm;
pub const Vec3 = geo.Vec3;

// ─── Priority ─────────────────────────────────────────────────────────────────
pub const Priority = enum(u8) {
    idle = 0,
    role = 1,
    spec = 2,
    encounter = 3,
    operator = 4,

    pub fn supersedes(self: Priority, other: Priority) bool {
        return @intFromEnum(self) > @intFromEnum(other);
    }
};

// ─── Predicate ────────────────────────────────────────────────────────────────
pub const Predicate = union(enum) {
    aura_present: struct { spell_id: u32, on_self: bool },
    aura_absent: struct { spell_id: u32, on_self: bool },
    ctm_idle,
    target_cleared,
    arrived_at: struct { x: f32, y: f32, z: f32, within_yards: f32 },
    z_above: f32,
    game_time_at_least_ms: u32,
    sequenced_step_elapsed_ms: u32,
    always_true,
};

// ─── Reason (for logging) ─────────────────────────────────────────────────────
pub const Reason = enum {
    encounter_route,
    encounter_pull,
    encounter_swap,
    encounter_stack,
    encounter_transition,
    role_follow,
    role_stack,
    role_heal_move,
    role_facing,
    role_start_attack,
    tank_rescue,
    tank_engage,
    spec_attack,
    spec_threat,
    operator_raid_buff,
    operator_burst,
    operator_nav,
    operator_reset,
};

// ─── Intent variants ─────────────────────────────────────────────────────────
pub const max_seq_steps: usize = 24;

pub const IntentTag = enum {
    idle,
    moving_to,
    following,
    stacking,
    targeting,
    attacking,
    casting_scripted,
    casting_scripted_ground,
    facing,
    start_attack,
    stop_attack,
    jump,
    use_inventory_item,
    apply_poison,
    jump_near,
    waiting_for,
    sequenced,
};

pub const MovingTo = struct {
    pos: Vec3,
    arrival_yards: f32 = 3.0,
    reason: Reason,
    /// When true, use non-blocking `move_to_nb`; the intent advances even if CTM is running.
    non_blocking: bool = false,
};

pub const Following = struct {
    target_guid: u64,
};

pub const Stacking = struct {
    x: f32,
    y: f32,
    z: f32,
    tolerance: f32 = 3.0,
    reason: Reason = .encounter_stack,
};

pub const Targeting = struct {
    target_guid: u64,
};

pub const Attacking = struct {
    target_guid: u64,
};

pub const CastingScripted = struct {
    spell_id: u32,
    target_guid: u64,
    allow_cancel: bool = false,
    instant: bool = false,
    one_shot: bool = false,
};

pub const CastingScriptedGround = struct {
    spell_id: u32,
    x: f32,
    y: f32,
    z: f32,
    allow_cancel: bool = false,
    instant: bool = false,
    one_shot: bool = false,
};

pub const Facing = struct {
    radians: f32,
};

pub const JumpNear = struct {
    x: f32,
    y: f32,
    tolerance_yards: f32,
};

pub const WaitingFor = struct {
    until: Predicate,
    max_age_ms: u32 = 6000,
};

/// A sequence of simpler intents executed in order.
/// Each step advances when its completion predicate is satisfied.
pub const IntentSlot = struct {
    intent: SimpleIntent,
    /// If null, the slot completes after the action is dispatched once.
    done_when: ?Predicate = null,
    trigger_once: ?StepTrigger = null,
};

/// Subset of Intent that may appear inside a Sequenced (no recursive sequences).
pub const SimpleIntent = union(IntentTag) {
    idle,
    moving_to: MovingTo,
    following: Following,
    stacking: Stacking,
    targeting: Targeting,
    attacking: Attacking,
    casting_scripted: CastingScripted,
    casting_scripted_ground: CastingScriptedGround,
    facing: Facing,
    start_attack,
    stop_attack,
    jump,
    use_inventory_item: u8,
    apply_poison: u32,
    jump_near: JumpNear,
    waiting_for: WaitingFor,
    sequenced: void,
};

pub const StepTriggerAction = enum {
    jump,
};

pub const StepTrigger = struct {
    when: Predicate,
    action: StepTriggerAction,
    fired: bool = false,
};

pub const Sequenced = struct {
    steps: [max_seq_steps]IntentSlot,
    len: u8,
    current: u8 = 0,
    /// Set after the current step dispatches; required before `advanceSequenced` may advance.
    step_dispatched: bool = false,
    step_started_at_ms: u32 = 0,
};

pub const Intent = union(IntentTag) {
    idle,
    moving_to: MovingTo,
    following: Following,
    stacking: Stacking,
    targeting: Targeting,
    attacking: Attacking,
    casting_scripted: CastingScripted,
    casting_scripted_ground: CastingScriptedGround,
    facing: Facing,
    start_attack,
    stop_attack,
    jump,
    use_inventory_item: u8,
    apply_poison: u32,
    jump_near: JumpNear,
    waiting_for: WaitingFor,
    sequenced: Sequenced,
};

// ─── Predicate evaluation ─────────────────────────────────────────────────────

const aura = @import("../aura.zig");

pub fn predicateTrue(pred: Predicate, state: proto.State) bool {
    return switch (pred) {
        .ctm_idle => state.ctm_action == @intFromEnum(proto.CtmAction.idle),
        .target_cleared => state.target_guid == 0,
        .always_true => true,
        .aura_present => |a| if (a.on_self)
            aura.remainingMsOnSelf(state, a.spell_id) != null
        else
            false,
        .aura_absent => |a| if (a.on_self)
            aura.remainingMsOnSelf(state, a.spell_id) == null
        else
            true,
        .arrived_at => |p| blk: {
            const dx = state.x - p.x;
            const dy = state.y - p.y;
            const dz = state.z - p.z;
            break :blk dx * dx + dy * dy + dz * dz <= p.within_yards * p.within_yards;
        },
        .z_above => |z| state.z > z,
        .game_time_at_least_ms => |t| state.game_time_ms >= t,
        .sequenced_step_elapsed_ms => false,
    };
}

// ─── ActiveIntent ─────────────────────────────────────────────────────────────
pub const ActiveIntent = struct {
    intent: Intent,
    priority: Priority,
    /// Priorities that are allowed to preempt this intent (force=false path).
    cancellable_by_priority: Priority = .operator,
    created_at_ms: u32,
    max_age_ms: u32 = 0, // 0 = no auto-expire
    source: Reason,
    confirm: Confirm = .{},
};

pub const ReplaceResult = enum { installed, replaced, rejected_priority };

/// True while a bot is moving (or holding) on the polarity-stack encounter intent.
/// While this holds, the brain must not dispatch any non-movement action for the
/// bot — including auto-attack chase — so opposite charges never cross paths.
pub fn isPolarityTransit(ai: ActiveIntent) bool {
    if (ai.source != .encounter_stack) return false;
    return switch (ai.intent) {
        .stacking, .waiting_for => true,
        else => false,
    };
}

// ─── IntentStore ──────────────────────────────────────────────────────────────
pub const IntentEntry = struct {
    bot_id: BotId,
    active: ActiveIntent,
};

pub const IntentStore = struct {
    entries: [types.max_bots]?IntentEntry = .{null} ** types.max_bots,

    pub fn current(self: *const IntentStore, bot_id: BotId) ?ActiveIntent {
        for (&self.entries) |*slot| {
            if (slot.*) |entry| {
                if (std.mem.eql(u8, &entry.bot_id, &bot_id)) return entry.active;
            }
        }
        return null;
    }

    /// Install or refresh an intent. Equal priority replaces in place (spec/role/encounter
    /// proposers run every tick). Higher priority preempts; lower is rejected.
    pub fn replaceAt(
        self: *IntentStore,
        bot_id: BotId,
        next: ActiveIntent,
        dispatch_store: *DispatchStore,
        game_time_ms: u32,
    ) ReplaceResult {
        if (self.findEntry(bot_id)) |entry| {
            const old = entry.active;
            const old_seq_done = old.intent == .sequenced and
                old.intent.sequenced.current >= old.intent.sequenced.len;
            const can_replace = old_seq_done or
                next.priority.supersedes(old.priority) or
                @intFromEnum(next.priority) == @intFromEnum(old.priority);
            if (!can_replace) return .rejected_priority;

            if (!next.priority.supersedes(old.priority) and old.confirm.active) {
                return .installed;
            }

            const preempted = next.priority.supersedes(old.priority);
            const type_changed = !std.mem.eql(u8, @tagName(next.intent), @tagName(old.intent));
            if ((preempted or type_changed) and brain_log.intentPreemptLogEnabled()) {
                std.log.debug("intent: {s} {s} {s} [{s}→{s}] (prio {}→{})", .{
                    @tagName(next.source),
                    if (preempted) "preempts" else "changes",
                    @tagName(old.source),
                    @tagName(old.intent),
                    @tagName(next.intent),
                    @intFromEnum(old.priority),
                    @intFromEnum(next.priority),
                });
            }
            entry.active = next;
            if (preempted) dispatch_store.hardStop(bot_id, game_time_ms);
            return if (preempted) .replaced else .installed;
        }

        for (&self.entries) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .bot_id = bot_id, .active = next };
                return .installed;
            }
        }
        return .rejected_priority;
    }

    /// Replace the current intent. Returns the outcome.
    /// `force=true` bypasses the priority check.
    /// On replacement, calls `dispatch_store_mod.hardStop` to cancel in-flight dispatches.
    pub fn replace(
        self: *IntentStore,
        bot_id: BotId,
        next: ActiveIntent,
        force: bool,
        dispatch_store: *DispatchStore,
        game_time_ms: u32,
    ) ReplaceResult {
        if (self.findEntry(bot_id)) |entry| {
            const old = entry.active;
            const can_replace = force or
                next.priority.supersedes(old.priority) or
                next.priority.supersedes(old.cancellable_by_priority);
            if (!can_replace) return .rejected_priority;

            if (brain_log.intentPreemptLogEnabled()) {
                std.log.debug("intent: {s} preempts {s} [{s}→{s}] (prio {}→{})", .{
                    @tagName(next.source),
                    @tagName(old.source),
                    @tagName(old.intent),
                    @tagName(next.intent),
                    @intFromEnum(old.priority),
                    @intFromEnum(next.priority),
                });
            }
            entry.active = next;
            dispatch_store.hardStop(bot_id, game_time_ms);
            return .replaced;
        }

        // No current entry — find a free slot.
        for (&self.entries) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .bot_id = bot_id, .active = next };
                return .installed;
            }
        }
        return .rejected_priority; // store full (should not happen; max_bots slots)
    }

    pub fn clear(self: *IntentStore, bot_id: BotId, dispatch_store: *DispatchStore, game_time_ms: u32) void {
        if (self.findEntry(bot_id)) |entry| {
            entry.active = .{
                .intent = .idle,
                .priority = .idle,
                .created_at_ms = game_time_ms,
                .source = .operator_reset,
            };
        }
        dispatch_store.hardStop(bot_id, game_time_ms);
    }

    /// Clear the intent for `bot_id` only if its current priority matches `priority`.
    /// Resets to idle(prio=0) so lower-priority proposers (e.g. role) can install next tick.
    /// Does NOT call hardStop — callers that want to yield a slot should not suppress movement.
    pub fn clearByPriority(self: *IntentStore, bot_id: BotId, priority: Priority, source: Reason, game_time_ms: u32) void {
        if (self.findEntry(bot_id)) |entry| {
            if (entry.active.priority == priority) {
                entry.active = .{
                    .intent = .idle,
                    .priority = .idle,
                    .created_at_ms = game_time_ms,
                    .source = source,
                };
            }
        }
    }

    /// Expire intents that have outlived their max_age_ms.
    pub fn pruneExpired(self: *IntentStore, game_time_ms: u32) void {
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                const ai = entry.active;
                if (ai.max_age_ms == 0) continue;
                if (ai.confirm.active and !intent_confirm.isInstantAction(ai.confirm.last_action)) continue;
                if (game_time_ms -| ai.created_at_ms >= ai.max_age_ms) {
                    entry.active = .{
                        .intent = .idle,
                        .priority = .idle,
                        .created_at_ms = game_time_ms,
                        .source = .operator_reset,
                    };
                }
            }
        }
    }

    pub fn currentMut(self: *IntentStore, bot_id: BotId) ?*ActiveIntent {
        if (self.findEntry(bot_id)) |e| return &e.active;
        return null;
    }

    fn findEntry(self: *IntentStore, bot_id: BotId) ?*IntentEntry {
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (std.mem.eql(u8, &entry.bot_id, &bot_id)) return entry;
            }
        }
        return null;
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "IntentStore: install when empty" {
    var store = IntentStore{};
    var ds = DispatchStore{};
    const bot = std.mem.zeroes(BotId);

    const ai = ActiveIntent{
        .intent = .idle,
        .priority = .spec,
        .created_at_ms = 1000,
        .source = .spec_attack,
    };

    const result = store.replace(bot, ai, false, &ds, 1000);
    try std.testing.expectEqual(ReplaceResult.installed, result);
    try std.testing.expectEqual(Priority.spec, store.current(bot).?.priority);
}

test "IntentStore: higher priority preempts lower" {
    var store = IntentStore{};
    var ds = DispatchStore{};
    const bot = std.mem.zeroes(BotId);

    _ = store.replace(bot, .{
        .intent = .idle,
        .priority = .spec,
        .created_at_ms = 0,
        .source = .spec_attack,
    }, false, &ds, 0);

    const enc = ActiveIntent{
        .intent = .idle,
        .priority = .encounter,
        .created_at_ms = 500,
        .source = .encounter_stack,
    };
    const result = store.replace(bot, enc, false, &ds, 500);
    try std.testing.expectEqual(ReplaceResult.replaced, result);
    try std.testing.expectEqual(Priority.encounter, store.current(bot).?.priority);
}

test "IntentStore: same priority rejected without force" {
    var store = IntentStore{};
    var ds = DispatchStore{};
    const bot = std.mem.zeroes(BotId);

    _ = store.replace(bot, .{
        .intent = .idle,
        .priority = .role,
        .created_at_ms = 0,
        .source = .role_follow,
    }, false, &ds, 0);

    const result = store.replace(bot, .{
        .intent = .idle,
        .priority = .role,
        .created_at_ms = 100,
        .source = .role_stack,
    }, false, &ds, 100);
    try std.testing.expectEqual(ReplaceResult.rejected_priority, result);
}

test "IntentStore: force=true replaces regardless of priority" {
    var store = IntentStore{};
    var ds = DispatchStore{};
    const bot = std.mem.zeroes(BotId);

    _ = store.replace(bot, .{
        .intent = .idle,
        .priority = .encounter,
        .created_at_ms = 0,
        .source = .encounter_stack,
    }, false, &ds, 0);

    const result = store.replace(bot, .{
        .intent = .idle,
        .priority = .spec,
        .created_at_ms = 100,
        .source = .spec_attack,
    }, true, &ds, 100);
    try std.testing.expectEqual(ReplaceResult.replaced, result);
}

test "IntentStore: pruneExpired clears intent past max_age_ms" {
    var store = IntentStore{};
    var ds = DispatchStore{};
    const bot = std.mem.zeroes(BotId);

    _ = store.replace(bot, .{
        .intent = .{ .waiting_for = .{ .until = .always_true, .max_age_ms = 3000 } },
        .priority = .encounter,
        .created_at_ms = 10_000,
        .max_age_ms = 3000,
        .source = .encounter_stack,
    }, false, &ds, 10_000);

    store.pruneExpired(12_999);
    try std.testing.expectEqual(Priority.encounter, store.current(bot).?.priority);

    store.pruneExpired(13_000);
    try std.testing.expectEqual(Priority.idle, store.current(bot).?.priority);
}

test "IntentStore: pruneExpired keeps in-flight confirmed intent" {
    var store = IntentStore{};
    var ds = DispatchStore{};
    const bot = std.mem.zeroes(BotId);

    _ = store.replace(bot, .{
        .intent = .{ .casting_scripted = .{ .spell_id = 47841, .target_guid = 0xabc } },
        .priority = .spec,
        .created_at_ms = 10_000,
        .max_age_ms = 500,
        .source = .spec_attack,
        .confirm = .{
            .active = true,
            .last_action = .{ .cast_target = .{ .spell_id = 47841, .target_guid = 0xabc } },
            .expected_spell_id = 47841,
            .dispatched_at_ms = 10_000,
            .spell_phase = .waiting_go,
        },
    }, true, &ds, 10_000);

    store.pruneExpired(11_000);
    try std.testing.expectEqual(Priority.spec, store.current(bot).?.priority);
    try std.testing.expect(store.current(bot).?.confirm.active);
}
