const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const action_mod = @import("../action.zig");
const class_spec = @import("../class_spec.zig");
const context = @import("../context.zig");
const encounter = @import("../encounters/mod.zig");
const geo = @import("../geo.zig");
const intent_dispatch = @import("../intent/dispatch.zig");
const intent = @import("../intent/mod.zig");
const positioning = @import("../positioning.zig");
const role_mod = @import("../role.zig");
const spec_routine = @import("../spec_routine.zig");
const spec_registry = @import("../specs/spec_registry.zig");
const world_query = @import("../world_query.zig");

const Action = action_mod.Action;
const ActiveIntent = intent.ActiveIntent;
const BotSnapshot = registry_mod.BotSnapshot;
const CombatContext = context.CombatContext;
const FollowStore = role_mod.FollowStore;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

const melee_arrival_yards: f32 = 0.75;
const tank_reposition_slack_yards: f32 = positioning.melee_outer_slack_yards + melee_arrival_yards;
const ranged_arrival_yards: f32 = positioning.ranged_ctm_arrival_reserve_yards;

pub const DecisionReason = enum {
    prep_gate,
    no_target,
    target_not_found,
    dead_target,
    out_of_position,
    bad_facing,
    start_attack_heartbeat,
    already_casting,
    already_channeling,
    no_autoattack_profile,
    not_at_desired_pos,
    at_anchor,
    at_anchor_facing,
};

pub const DecisionTrace = struct {
    bot: BotSnapshot,
    role: role_mod.CombatRole,
    spec: class_spec.Spec,
    primary_target: u64,
    target: ?WorldSnapshot,
    placement: positioning.Placement,
    result: ?positioning.PositioningResult,
    uses_autoattack: bool,
    intent: intent.IntentTag,
    blocks_spec: bool,
    reason: DecisionReason,
};

pub fn dispatchAction(ctx: *const CombatContext, follow: *FollowStore) Action {
    const ai = proposeIntent(ctx, follow) orelse return .none;
    return intent_dispatch.actionForIntent(ai, ctx, follow);
}

pub fn proposeIntent(ctx: *const CombatContext, follow: *FollowStore) ?ActiveIntent {
    return decide(ctx, follow).ai;
}

pub fn explainDecision(ctx: *const CombatContext, follow: *FollowStore) DecisionTrace {
    return decide(ctx, follow).trace;
}

const Decision = struct {
    ai: ?ActiveIntent,
    trace: DecisionTrace,
};

fn decide(ctx: *const CombatContext, follow: *FollowStore) Decision {
    const range = dynamicPlacementRange(ctx);
    const placement = placementForRole(ctx.role, range);
    const base_trace = DecisionTrace{
        .bot = ctx.bot,
        .role = ctx.role,
        .spec = ctx.spec,
        .primary_target = ctx.primary_target orelse 0,
        .target = null,
        .placement = placement,
        .result = null,
        .uses_autoattack = usesAutoAttack(ctx),
        .intent = .idle,
        .blocks_spec = false,
        .reason = .no_target,
    };

    if (!ctx.operator_fight_started and encounter.mapUsesOperatorPrepGate(ctx.bot.state.map_id)) {
        var trace = base_trace;
        trace.reason = .prep_gate;
        return .{ .ai = null, .trace = trace };
    }

    const position_override = if (follow.get(ctx.bot.bot_id)) |entry| entry.position_override else null;
    if (position_override) |pos| {
        if (!pos.authoritative) {
            if (positionOverrideIntent(ctx, pos)) |ai| {
                var trace = base_trace;
                trace.intent = std.meta.activeTag(ai.intent);
                trace.blocks_spec = blocksSpec(ai);
                trace.reason = .out_of_position;
                return .{ .ai = ai, .trace = trace };
            }
        }
    }

    const guid = ctx.primary_target orelse return .{ .ai = null, .trace = base_trace };
    const target = world_query.entryForGuidOnMap(ctx.world, guid, ctx.bot.state.map_id) orelse {
        var trace = base_trace;
        trace.primary_target = guid;
        trace.reason = .target_not_found;
        return .{ .ai = null, .trace = trace };
    };
    if (target.scan.hp == 0) {
        var trace = base_trace;
        trace.primary_target = guid;
        trace.target = target;
        trace.reason = .dead_target;
        return .{ .ai = null, .trace = trace };
    }

    const anchor_authoritative = if (position_override) |pos| pos.authoritative else false;

    var trace = base_trace;
    trace.primary_target = guid;
    trace.target = target;

    if (!anchor_authoritative) {
        var result = positioning.computeDesiredPos(.{
            .bot = unitFromState(ctx.bot.state),
            .target = unitFromScan(target.scan),
            .target_velocity_yards_per_second = targetVelocity(target),
            .placement = placement,
        });
        if (position_override) |pos| clampDesiredToAnchor(pos, &result, ctx.bot.state);
        trace.result = result;

        const tank_contact_stable = ctx.role == .tank and tankMeleeContactStable(ctx.bot.state, target.scan);
        // rear_arc_ok is excluded: once in swing range the bot can attack. In open world
        // mobs face their attacker so rear arc is unreachable; requiring it would block
        // start_attack indefinitely. Arc positioning remains advisory via the moving_to guidance.
        const melee_dps_contact_stable = ctx.role == .melee_dps and
            targetInMeleeSwingRange(ctx.bot.state, target.scan);

        if (!tank_contact_stable and !melee_dps_contact_stable and shouldMoveForPlacement(ctx.role, placement, result, range != null)) {
            const ai = ActiveIntent{
                .intent = .{ .moving_to = .{
                    .pos = result.desired_pos,
                    .arrival_yards = arrivalYardsForPlacement(placement),
                    .reason = .role_stack,
                    .non_blocking = movementIsNonBlocking(ctx.role, placement, result),
                } },
                .priority = .role,
                .created_at_ms = ctx.game_time_ms,
                .source = .role_stack,
            };
            trace.intent = std.meta.activeTag(ai.intent);
            trace.blocks_spec = blocksSpec(ai);
            trace.reason = if (result.in_position) .not_at_desired_pos else .out_of_position;
            return .{ .ai = ai, .trace = trace };
        }

        if (!tank_contact_stable and !melee_dps_contact_stable and !result.facing_ok) {
            const ai = ActiveIntent{
                .intent = .{ .facing = .{ .radians = result.desired_facing } },
                .priority = .role,
                .created_at_ms = ctx.game_time_ms,
                .source = .role_facing,
            };
            trace.intent = std.meta.activeTag(ai.intent);
            trace.blocks_spec = blocksSpec(ai);
            trace.reason = .bad_facing;
            return .{ .ai = ai, .trace = trace };
        }
    }

    if (!trace.uses_autoattack) {
        trace.reason = .no_autoattack_profile;
        return .{ .ai = null, .trace = trace };
    }
    if (ctx.bot.state.is_casting != 0) {
        trace.reason = .already_casting;
        return .{ .ai = null, .trace = trace };
    }
    if (ctx.bot.state.is_channeling != 0) {
        trace.reason = .already_channeling;
        return .{ .ai = null, .trace = trace };
    }
    if (anchor_authoritative and !targetInMeleeSwingRange(ctx.bot.state, target.scan)) {
        // Anchored but target is out of melee swing range. Emitting start_attack
        // would call StartAttack() lua, which sets the WoW auto-attack flag and
        // makes the client engine drive a CTM=attack_pos chase toward the target
        // — dragging the bot off the anchor. Threat from earlier attacks (or
        // spec ranged casts) will pull the twin into melee on its own; we just
        // face it and wait. The brain layer dispatches a one-shot stop_attack
        // alongside the facing action whenever ctm_action is attack_pos, which
        // breaks any chase already in flight.
        const desired_facing = geo.angleTo2d(
            .{ .x = ctx.bot.state.x, .y = ctx.bot.state.y, .z = ctx.bot.state.z },
            .{ .x = target.scan.x, .y = target.scan.y, .z = target.scan.z },
        );
        const ai = ActiveIntent{
            .intent = .{ .facing = .{ .radians = desired_facing } },
            .priority = .role,
            .created_at_ms = ctx.game_time_ms,
            .source = .role_facing,
        };
        trace.intent = std.meta.activeTag(ai.intent);
        trace.blocks_spec = blocksSpec(ai);
        trace.reason = .at_anchor_facing;
        return .{ .ai = ai, .trace = trace };
    }

    {
        const ai = startAttackIntent(ctx);
        trace.intent = std.meta.activeTag(ai.intent);
        trace.blocks_spec = blocksSpec(ai);
        trace.reason = if (anchor_authoritative) .at_anchor else .start_attack_heartbeat;
        return .{ .ai = ai, .trace = trace };
    }
}

fn targetInMeleeSwingRange(state: proto.State, scan: proto.ScanEntry) bool {
    const dx = scan.x - state.x;
    const dy = scan.y - state.y;
    const dist_sq = dx * dx + dy * dy;
    const swing = state.combat_reach + scan.combat_reach + positioning.base_meleerange_offset;
    return dist_sq <= swing * swing;
}

fn positionOverrideIntent(ctx: *const CombatContext, pos: role_mod.PositionOverride) ?ActiveIntent {
    const dx = pos.x - ctx.bot.state.x;
    const dy = pos.y - ctx.bot.state.y;
    if (dx * dx + dy * dy <= pos.arrival_yards * pos.arrival_yards) return null;

    return ActiveIntent{
        .intent = .{ .moving_to = .{
            .pos = .{ .x = pos.x, .y = pos.y, .z = pos.z },
            .arrival_yards = pos.arrival_yards,
            .reason = .role_stack,
            .non_blocking = true,
        } },
        .priority = .role,
        .created_at_ms = ctx.game_time_ms,
        .source = .role_stack,
    };
}

fn clampDesiredToAnchor(anchor: role_mod.PositionOverride, result: *positioning.PositioningResult, state: proto.State) void {
    const dx = result.desired_pos.x - anchor.x;
    const dy = result.desired_pos.y - anchor.y;
    const d_sq = dx * dx + dy * dy;
    const max_sq = anchor.arrival_yards * anchor.arrival_yards;
    if (d_sq <= max_sq) return;

    const scale = anchor.arrival_yards / @sqrt(d_sq);
    result.desired_pos.x = anchor.x + dx * scale;
    result.desired_pos.y = anchor.y + dy * scale;

    const bdx = state.x - result.desired_pos.x;
    const bdy = state.y - result.desired_pos.y;
    result.dist_to_desired = @sqrt(bdx * bdx + bdy * bdy);
}

fn startAttackIntent(ctx: *const CombatContext) ActiveIntent {
    return .{
        .intent = .start_attack,
        .priority = .role,
        .created_at_ms = ctx.game_time_ms,
        .source = .role_start_attack,
    };
}

pub fn blocksSpec(ai: ActiveIntent) bool {
    return switch (ai.intent) {
        .moving_to => |mv| !mv.non_blocking,
        .facing => true,
        else => false,
    };
}

fn unitFromState(state: proto.State) positioning.Unit {
    return .{
        .pos = .{ .x = state.x, .y = state.y, .z = state.z },
        .orientation = state.orientation,
        .combat_reach = state.combat_reach,
    };
}

fn unitFromScan(scan: proto.ScanEntry) positioning.Unit {
    return .{
        .pos = .{ .x = scan.x, .y = scan.y, .z = scan.z },
        .orientation = scan.orientation,
        .combat_reach = scan.combat_reach,
    };
}

fn tankMeleeContactStable(state: proto.State, scan: proto.ScanEntry) bool {
    return positioning.meleeContactStable(unitFromState(state), unitFromScan(scan));
}

fn targetVelocity(target: WorldSnapshot) geo.Vec3 {
    return .{
        .x = target.velocity_x_yards_per_second,
        .y = target.velocity_y_yards_per_second,
        .z = target.velocity_z_yards_per_second,
    };
}

fn placementForRole(role: role_mod.CombatRole, dynamic_range_yards: ?f32) positioning.Placement {
    return switch (role) {
        .tank => .{ .relative_angle = 0, .facing_tolerance = positioning.melee_facing_tolerance_rad, .arc_policy = .none, .range = .melee },
        .melee_dps => .{
            .relative_angle = std.math.pi,
            .angle_tolerance = positioning.melee_rear_arc_tolerance_rad,
            .facing_tolerance = positioning.melee_facing_tolerance_rad,
            .range = .melee,
        },
        .ranged_dps, .healer => .{ .relative_angle = 0, .range = .{ .yards = dynamic_range_yards orelse 0.0 } },
    };
}

fn shouldMoveForPlacement(role: role_mod.CombatRole, placement: positioning.Placement, result: positioning.PositioningResult, has_dynamic_range: bool) bool {
    return switch (placement.range) {
        .melee => switch (role) {
            .tank => result.bot_dist > result.range_upper + tank_reposition_slack_yards and
                result.dist_to_desired > arrivalYardsForPlacement(placement),
            .melee_dps => result.bot_dist > result.range_upper or
                (!result.in_position and result.dist_to_desired > arrivalYardsForPlacement(placement)),
            else => !result.in_position and result.bot_dist > result.range_upper and
                result.dist_to_desired > arrivalYardsForPlacement(placement),
        },
        .yards => has_dynamic_range and result.bot_dist > result.range_upper,
    };
}

fn arrivalYardsForPlacement(placement: positioning.Placement) f32 {
    return switch (placement.range) {
        .melee => melee_arrival_yards,
        .yards => ranged_arrival_yards,
    };
}

fn movementIsNonBlocking(role: role_mod.CombatRole, placement: positioning.Placement, result: positioning.PositioningResult) bool {
    return switch (placement.range) {
        .melee => role != .melee_dps or result.bot_dist <= result.range_upper,
        .yards => false,
    };
}

fn usesAutoAttack(ctx: *const CombatContext) bool {
    return switch (ctx.role) {
        .tank, .melee_dps => true,
        .ranged_dps => spec_registry.meta(ctx.spec).profile == .ranged,
        .healer => false,
    };
}

fn dynamicPlacementRange(ctx: *const CombatContext) ?f32 {
    return switch (ctx.role) {
        .tank, .melee_dps => null,
        .ranged_dps => blk: {
            const action = spec_routine.planSpecRoutine(ctx.bot, ctx.world, ctx.spec);
            const spell_id = spellIdForPrimaryTarget(action, ctx.primary_target orelse ctx.bot.state.target_guid) orelse break :blk null;
            break :blk clientSpellRange(ctx.bot.state, spell_id);
        },
        .healer => blk: {
            const meta = spec_registry.meta(ctx.spec);
            const spell = meta.heal_spell orelse break :blk null;
            break :blk clientSpellRange(ctx.bot.state, spell.spell_id);
        },
    };
}

fn spellIdForPrimaryTarget(action: Action, primary_target: u64) ?u32 {
    if (primary_target == 0) return null;
    return switch (action) {
        .cast_target => |ct| if (ct.target_guid == primary_target) ct.spell_id else null,
        .cast_target_instant => |ct| if (ct.target_guid == primary_target) ct.spell_id else null,
        else => null,
    };
}

fn clientSpellRange(state: proto.State, spell_id: u32) ?f32 {
    const n = @min(state.spell_range_count, state.spell_ranges.len);
    for (state.spell_ranges[0..n]) |entry| {
        if (entry.spell_id != spell_id) continue;
        if (entry.max_range_yards <= 0) return null;
        return entry.max_range_yards;
    }
    return null;
}

fn makeBot(comptime id: u8, spec: class_spec.Spec, x: f32, y: f32, orientation: f32) BotSnapshot {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id[0] = id;
    bot.state.guid = 0x100 + @as(u64, id);
    bot.state.class = classForSpec(spec);
    bot.state.talent_points = talentsForSpec(spec);
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.x = x;
    bot.state.y = y;
    bot.state.z = 0;
    bot.state.orientation = orientation;
    bot.state.game_time_ms = 1000;
    bot.state.combat_reach = 1.0;
    return bot;
}

fn addSpellRange(bot: *BotSnapshot, spell_id: u32, max_range_yards: f32) void {
    const n: usize = @intCast(bot.state.spell_range_count);
    bot.state.spell_ranges[n] = .{ .spell_id = spell_id, .max_range_yards = max_range_yards };
    bot.state.spell_range_count += 1;
}

fn classForSpec(spec: class_spec.Spec) u32 {
    return @intFromEnum(switch (spec) {
        .protection_paladin, .holy_paladin, .retribution => class_spec.Class.paladin,
        .survival, .marksmanship, .beast_mastery => class_spec.Class.hunter,
        .shadow, .holy_priest, .discipline => class_spec.Class.priest,
        .arcane, .fire, .frost_mage => class_spec.Class.mage,
        else => class_spec.Class.rogue,
    });
}

fn talentsForSpec(spec: class_spec.Spec) proto.TalentPoints {
    return switch (spec) {
        .protection_paladin => .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 },
        .holy_priest => .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 },
        .shadow => .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 },
        .survival => .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 },
        .arcane => .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 },
        else => .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 },
    };
}

fn makeWorld(target_x: f32, target_y: f32, orientation: f32) [1]WorldSnapshot {
    var scan: proto.ScanEntry = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    scan.x = target_x;
    scan.y = target_y;
    scan.z = 0;
    scan.orientation = orientation;
    scan.combat_reach = 1.0;
    return .{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};
}

fn buildCtx(bot: BotSnapshot, world: []const WorldSnapshot) CombatContext {
    return CombatContext.build(bot, &.{bot}, world, &.{}, true);
}

test "proposeIntent: tank moves into contact" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(1, .protection_paladin, 20, 0, std.math.pi);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .moving_to);
    try std.testing.expect(ai.intent.moving_to.non_blocking);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), ai.intent.moving_to.pos.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ai.intent.moving_to.pos.y, 0.01);
}

test "proposeIntent: tank in melee range ignores target front arc" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(34, .protection_paladin, 0, 4, -std.math.pi / 2.0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .start_attack);
    try std.testing.expectEqual(intent.Reason.role_start_attack, ai.source);
}

test "proposeIntent: tank inside combat reach sum does not back away" {
    var world = makeWorld(0, 0, 0);
    world[0].scan.combat_reach = 3.0;
    var bot = makeBot(35, .protection_paladin, 3.6, 0, std.math.pi);
    bot.state.combat_reach = 1.5;
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .start_attack);
    try std.testing.expectEqual(intent.Reason.role_start_attack, ai.source);
}

test "proposeIntent: tank in contact does not spin for unstable facing" {
    var world = makeWorld(0.0, 0.5, 0);
    world[0].scan.combat_reach = 0.0;
    var bot = makeBot(36, .protection_paladin, 0, 0, 0);
    bot.state.combat_reach = 1.5;
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .start_attack);
    try std.testing.expectEqual(intent.Reason.role_start_attack, ai.source);
}

test "proposeIntent: tank does not orbit near melee edge" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(37, .protection_paladin, 7.2, 0, std.math.pi);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .start_attack);
    try std.testing.expectEqual(intent.Reason.role_start_attack, ai.source);
}

test "proposeIntent: melee dps moves when outside melee range" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(54, .assassination, 7.2, 0, 0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .moving_to);
    try std.testing.expect(!ai.intent.moving_to.non_blocking);
}

test "proposeIntent: melee dps keeps closing when just outside swing range" {
    var world = makeWorld(0, 0, 0);
    world[0].scan.combat_reach = 0.0;
    var bot = makeBot(58, .assassination, -5.4, 0, 0);
    bot.state.combat_reach = 0.0;
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .moving_to);
    try std.testing.expect(!ai.intent.moving_to.non_blocking);
    try std.testing.expectApproxEqAbs(@as(f32, -4.0), ai.intent.moving_to.pos.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ai.intent.moving_to.pos.y, 0.01);
}

test "proposeIntent: melee dps attacks when in rear arc and melee range" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(55, .assassination, -4.0, 0, 0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .start_attack);
    try std.testing.expectEqual(intent.Reason.role_start_attack, ai.source);
}

test "proposeIntent: melee dps keeps moving until rear arc is valid" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(56, .assassination, 4.0, 0.0, 0.0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .moving_to);
    try std.testing.expect(ai.intent.moving_to.non_blocking);
}

test "proposeIntent: melee dps chases moving target instead of orbiting to rear apex" {
    // Target moves along +X while facing +X; bot starts in front at (10, 0).
    // The old rear-apex placement would send the bot to roughly (-4, 0), forcing
    // it to traverse around or through the target while the target keeps
    // rotating — the visible "orbit" symptom. The chase placement aims along
    // the bot→target line so the bot closes distance directly on its side.
    var world = makeWorld(0, 0, 0);
    world[0].velocity_x_yards_per_second = 5.0;
    const bot = makeBot(57, .assassination, 10.0, 0.0, std.math.pi);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .moving_to);
    // Desired x must stay on the bot's side of the target (positive X), not get
    // teleported behind it to negative X.
    try std.testing.expect(ai.intent.moving_to.pos.x > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ai.intent.moving_to.pos.y, 0.01);
}

test "proposeIntent: position override anchors tank instead of chasing target" {
    const world = makeWorld(30, 0, 0);
    const bot = makeBot(38, .protection_paladin, 0, 0, 0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    follow.setPosition(bot.bot_id, .{
        .x = 0,
        .y = 0,
        .z = 0,
        .arrival_yards = 5.0,
    });
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .moving_to);
    try std.testing.expect(ai.intent.moving_to.non_blocking);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), ai.intent.moving_to.pos.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ai.intent.moving_to.pos.y, 0.01);
}

test "proposeIntent: position override returns tank to anchor" {
    const world = makeWorld(30, 0, 0);
    const bot = makeBot(39, .protection_paladin, 12, 0, 0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    follow.setPosition(bot.bot_id, .{
        .x = 0,
        .y = 0,
        .z = 0,
        .arrival_yards = 5.0,
    });
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .moving_to);
    try std.testing.expect(ai.intent.moving_to.non_blocking);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ai.intent.moving_to.pos.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ai.intent.moving_to.pos.y, 0.01);
}

test "proposeIntent: authoritative override skips back-arc inside arrival" {
    // Bot sits on the anchor in melee with a live target. Without authoritative,
    // the role proposer would emit a back-arc moving_to (and keep oscillating
    // around the anchor edge as the target rotates). With authoritative, it
    // must skip placement entirely and emit start_attack so the tank stays
    // planted on the platform.
    var world = makeWorld(2, 0, std.math.pi);
    world[0].scan.combat_reach = 1.0;
    var bot = makeBot(50, .protection_paladin, 0, 0, 0);
    bot.state.combat_reach = 1.0;
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    follow.setPosition(bot.bot_id, .{
        .x = 0,
        .y = 0,
        .z = 0,
        .arrival_yards = 3.5,
        .authoritative = true,
    });
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .start_attack);
    try std.testing.expectEqual(intent.Reason.role_start_attack, ai.source);

    const trace = explainDecision(&ctx, &follow);
    try std.testing.expectEqual(DecisionReason.at_anchor, trace.reason);
}

test "proposeIntent: authoritative override faces target instead of chasing when out of melee" {
    // At anchor but target is well out of melee swing range. Emitting
    // start_attack would trigger the WoW client to start a CTM=attack_pos
    // chase. Instead the role proposer must emit a facing intent so the bot
    // stays planted and just turns to look at the twin while threat draws it in.
    var world = makeWorld(10, 0, std.math.pi);
    world[0].scan.combat_reach = 1.0;
    var bot = makeBot(53, .protection_paladin, 0, 0, 0);
    bot.state.combat_reach = 1.0;
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    follow.setPosition(bot.bot_id, .{
        .x = 0,
        .y = 0,
        .z = 0,
        .arrival_yards = 3.5,
        .authoritative = true,
    });
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .facing);
    try std.testing.expectEqual(intent.Reason.role_facing, ai.source);
    // Target is at (+x, 0) so the bot should face toward +x.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ai.intent.facing.radians, 0.01);

    const trace = explainDecision(&ctx, &follow);
    try std.testing.expectEqual(DecisionReason.at_anchor_facing, trace.reason);
}

test "proposeIntent: authoritative override never pulls back when outside arrival" {
    // Authoritative anchor: the twin walked to the bot and pushed it 8y away.
    // We must NOT emit moving_to back to anchor — the bot faces the target and
    // waits. Only non-authoritative anchors trigger a pull-back CTM.
    const world = makeWorld(30, 0, std.math.pi);
    const bot = makeBot(51, .protection_paladin, 8, 0, 0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    follow.setPosition(bot.bot_id, .{
        .x = 0,
        .y = 0,
        .z = 0,
        .arrival_yards = 3.5,
        .authoritative = true,
    });
    const ai = proposeIntent(&ctx, &follow).?;

    // Target is at (30, 0) and bot is at (8, 0), distance = 22y — out of melee.
    // Expect facing toward the target, not moving_to anchor.
    try std.testing.expect(ai.intent == .facing);
    try std.testing.expectEqual(intent.Reason.role_facing, ai.source);
}

test "proposeIntent: authoritative override returns null without target" {
    var bot = makeBot(52, .protection_paladin, 0, 0, 0);
    bot.state.target_guid = 0;
    const ctx = buildCtx(bot, &.{});
    var follow: FollowStore = .{};
    follow.setPosition(bot.bot_id, .{
        .x = 0,
        .y = 0,
        .z = 0,
        .arrival_yards = 3.5,
        .authoritative = true,
    });

    try std.testing.expect(proposeIntent(&ctx, &follow) == null);
}

test "proposeIntent: position override does not start attack without target" {
    var bot = makeBot(40, .protection_paladin, 0, 0, 0);
    bot.state.target_guid = 0;
    const ctx = buildCtx(bot, &.{});
    var follow: FollowStore = .{};
    follow.setPosition(bot.bot_id, .{
        .x = 0,
        .y = 0,
        .z = 0,
        .arrival_yards = 5.0,
    });

    try std.testing.expect(proposeIntent(&ctx, &follow) == null);
}

test "proposeIntent: melee moves behind" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(2, .assassination, -20, 0, 0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .moving_to);
    try std.testing.expectApproxEqAbs(@as(f32, -4.0), ai.intent.moving_to.pos.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ai.intent.moving_to.pos.y, 0.01);
}

test "proposeIntent: ranged in band faces before attacking" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(3, .survival, -18.5, 0, std.math.pi / 2.0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .facing);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ai.intent.facing.radians, 0.01);
}

test "proposeIntent: ranged too close does not move away" {
    const world = makeWorld(0, 0, 0);
    var bot = makeBot(30, .survival, -16, 0, 0);
    addSpellRange(&bot, 60052, 30.0);
    addSpellRange(&bot, 49052, 30.0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .start_attack);
}

test "proposeIntent: ranged too far moves toward desired point and blocks spec" {
    const world = makeWorld(0, 0, 0);
    var bot = makeBot(31, .survival, -30, 0, 0);
    addSpellRange(&bot, 60052, 30.0);
    addSpellRange(&bot, 49052, 30.0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .moving_to);
    try std.testing.expect(!ai.intent.moving_to.non_blocking);
    try std.testing.expectApproxEqAbs(@as(f32, -27.5), ai.intent.moving_to.pos.x, 0.01);
}

test "proposeIntent: ranged without client spell range does not move" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(32, .survival, -60, 0, 0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .start_attack);
}

test "proposeIntent: start_attack when placed and facing" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(4, .assassination, -4, 0, 0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .start_attack);
    try std.testing.expectEqual(intent.Reason.role_start_attack, ai.source);
}

test "proposeIntent: melee faces instead of micro-moving inside arrival radius" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(33, .assassination, -4.8, 0, std.math.pi / 2.0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .facing);
    try std.testing.expectEqual(intent.Reason.role_facing, ai.source);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ai.intent.facing.radians, 0.01);
}

test "proposeIntent: no autoattack while casting or channeling" {
    const world = makeWorld(0, 0, 0);
    var bot = makeBot(5, .assassination, -4, 0, 0);
    var follow: FollowStore = .{};

    bot.state.is_casting = 1;
    var ctx = buildCtx(bot, &world);
    try std.testing.expect(proposeIntent(&ctx, &follow) == null);

    bot.state.is_casting = 0;
    bot.state.is_channeling = 1;
    ctx = buildCtx(bot, &world);
    try std.testing.expect(proposeIntent(&ctx, &follow) == null);
}

test "proposeIntent: healer and caster do not autoattack" {
    const world = makeWorld(0, 0, 0);
    var follow: FollowStore = .{};

    const healer = makeBot(6, .holy_priest, -22, 0, 0);
    const healer_ctx = buildCtx(healer, &world);
    try std.testing.expect(proposeIntent(&healer_ctx, &follow) == null);

    const caster = makeBot(7, .shadow, -20, 0, 0);
    const caster_ctx = buildCtx(caster, &world);
    try std.testing.expect(proposeIntent(&caster_ctx, &follow) == null);
}

test "proposeIntent: hunter ranged dps uses autoattack" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(8, .survival, -20, 0, 0);
    const ctx = buildCtx(bot, &world);
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .start_attack);
}

test "proposeIntent: threat state does not suppress hunter autoattack heartbeat" {
    const world = makeWorld(0, 0, 0);
    const bot = makeBot(36, .survival, -20, 0, 0);
    var ctx = buildCtx(bot, &world);
    ctx.threat_high = true;
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &follow).?;

    try std.testing.expect(ai.intent == .start_attack);
    try std.testing.expectEqual(DecisionReason.start_attack_heartbeat, explainDecision(&ctx, &follow).reason);
}

test "proposeIntent: target must be scanned and attackable" {
    const bot = makeBot(9, .assassination, 4, 0, std.math.pi);
    var follow: FollowStore = .{};

    var ctx = buildCtx(bot, &.{});
    try std.testing.expect(proposeIntent(&ctx, &follow) == null);

    var world = makeWorld(0, 0, 0);
    world[0].scan.hp = 0;
    ctx = buildCtx(bot, &world);
    try std.testing.expect(proposeIntent(&ctx, &follow) == null);

    world[0].scan.unit_flags = @intFromEnum(proto.UnitFlag.non_attackable);
    world[0].scan.hp = 100;
    ctx = buildCtx(bot, &world);
    try std.testing.expect(proposeIntent(&ctx, &follow) == null);
}

test "blocksSpec: movement and facing gate spec rotation" {
    const now_ms: u32 = 1000;

    const moving: ActiveIntent = .{
        .intent = .{ .moving_to = .{
            .pos = .{ .x = 1, .y = 2, .z = 3 },
            .reason = .role_stack,
        } },
        .priority = .role,
        .created_at_ms = now_ms,
        .source = .role_stack,
    };
    const facing: ActiveIntent = .{
        .intent = .{ .facing = .{ .radians = 1.0 } },
        .priority = .role,
        .created_at_ms = now_ms,
        .source = .role_facing,
    };
    const start_attack: ActiveIntent = .{
        .intent = .start_attack,
        .priority = .role,
        .created_at_ms = now_ms,
        .source = .role_start_attack,
    };

    try std.testing.expect(blocksSpec(moving));
    try std.testing.expect(blocksSpec(facing));
    try std.testing.expect(!blocksSpec(start_attack));
}
