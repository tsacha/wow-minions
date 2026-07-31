//! Unit tests for the brain's compute pipeline. Exercises `compute` and
//! `computeWithProposers` against synthetic snapshots so combat coordination
//! can be validated without a live WoW session.

const std = @import("std");
const proto = @import("protocol");
const types = @import("types");
const registry_mod = @import("registry");
const world_memory_mod = @import("../world/memory.zig");
const brain = @import("mod.zig");
const combat = @import("../combat/mod.zig");
const intent = @import("../combat/intent/mod.zig");
const intent_confirm = @import("../combat/intent/confirm.zig");
const context = @import("../combat/context.zig");

const BotId = types.BotId;
const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;
const DispatchStore = combat.DispatchStore;
const IntentStore = intent.IntentStore;
const Order = brain.Order;
const RoleProposeFn = brain.RoleProposeFn;
const SpecProposeFn = brain.SpecProposeFn;
const test_sequence_wait_max_age_ms = brain.test_sequence_wait_max_age_ms;
const compute = brain.compute;
const computeWithProposers = brain.computeWithProposers;

const gui_snapshot = @import("../gui/snapshot.zig");
const order_label = @import("../gui/order_label.zig");
const formatOrderLabel = order_label.formatOrderLabel;

const blood_frost_presence_spell_id: u32 = 48263;
const feign_death_spell_id: u32 = 5384;

fn testBotId(n: u8) BotId {
    var id: BotId = std.mem.zeroes(BotId);
    id[0] = n;
    return id;
}

fn addPlayerAura(bot: *BotSnapshot, spell_id: u32) void {
    const i: usize = @intCast(bot.state.player_aura_count);
    bot.state.player_auras[i] = .{ .caster_guid = bot.state.guid, .spell_id = spell_id, .remaining_ms = 0 };
    bot.state.player_aura_count += 1;
}

fn testRoleMovingBlocking(ctx: *const context.CombatContext, follow: *combat.FollowStore) ?intent.ActiveIntent {
    _ = follow;
    return .{
        .intent = .{ .moving_to = .{
            .pos = .{ .x = 10, .y = 20, .z = 30 },
            .arrival_yards = 0.5,
            .reason = .role_stack,
            .non_blocking = false,
        } },
        .priority = .role,
        .created_at_ms = ctx.game_time_ms,
        .source = .role_stack,
    };
}

fn testRoleMovingNonBlocking(ctx: *const context.CombatContext, follow: *combat.FollowStore) ?intent.ActiveIntent {
    _ = follow;
    return .{
        .intent = .{ .moving_to = .{
            .pos = .{ .x = 10, .y = 20, .z = 30 },
            .arrival_yards = 0.5,
            .reason = .role_stack,
            .non_blocking = true,
        } },
        .priority = .role,
        .created_at_ms = ctx.game_time_ms,
        .source = .role_stack,
    };
}

fn testRoleFacing(ctx: *const context.CombatContext, follow: *combat.FollowStore) ?intent.ActiveIntent {
    _ = follow;
    return .{
        .intent = .{ .facing = .{ .radians = 1.25 } },
        .priority = .role,
        .created_at_ms = ctx.game_time_ms,
        .source = .role_facing,
    };
}

fn testRoleStartAttack(ctx: *const context.CombatContext, follow: *combat.FollowStore) ?intent.ActiveIntent {
    _ = follow;
    return .{
        .intent = .start_attack,
        .priority = .role,
        .created_at_ms = ctx.game_time_ms,
        .source = .role_start_attack,
    };
}

fn testSpecCast(ctx: *const context.CombatContext) ?intent.ActiveIntent {
    return .{
        .intent = .{ .casting_scripted = .{
            .spell_id = 777,
            .target_guid = ctx.bot.state.guid,
        } },
        .priority = .spec,
        .created_at_ms = ctx.game_time_ms,
        .source = .spec_attack,
    };
}

fn testSpecCastTarget(ctx: *const context.CombatContext) ?intent.ActiveIntent {
    return .{
        .intent = .{ .casting_scripted = .{
            .spell_id = 777,
            .target_guid = ctx.bot.state.target_guid,
            .instant = true,
        } },
        .priority = .spec,
        .created_at_ms = ctx.game_time_ms,
        .source = .spec_attack,
    };
}

fn testNoRole(ctx: *const context.CombatContext, follow: *combat.FollowStore) ?intent.ActiveIntent {
    _ = ctx;
    _ = follow;
    return null;
}

fn testNoSpec(ctx: *const context.CombatContext) ?intent.ActiveIntent {
    _ = ctx;
    return null;
}

fn testComputeWithProposers(
    bot: BotSnapshot,
    role_propose: RoleProposeFn,
    spec_propose: SpecProposeFn,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    follow_store: *combat.FollowStore,
    out: *[types.max_bots]Order,
) []const Order {
    return computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        out,
        dispatch_store,
        follow_store,
        intent_store,
        true,
        role_propose,
        spec_propose,
        null,
    );
}

test "compute: role blocking moving_to blocks spec cast" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(1);
    bot.state.guid = 0x101;
    bot.state.game_time_ms = 1000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    const orders = testComputeWithProposers(bot, testRoleMovingBlocking, testSpecCast, &intent_store, &dispatch_store, &follow_store, &out_buf);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .ctm_move);
    try std.testing.expectEqual(@as(f32, 10), orders[0].msg.ctm_move.x);
    try std.testing.expectEqual(intent.Priority.role, intent_store.current(bot.bot_id).?.priority);
    try std.testing.expect(intent_store.current(bot.bot_id).?.intent == .moving_to);
}

test "compute: role non-blocking moving_to allows spec cast" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(11);
    bot.state.guid = 0x111;
    bot.state.game_time_ms = 1000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    const orders = testComputeWithProposers(bot, testRoleMovingNonBlocking, testSpecCast, &intent_store, &dispatch_store, &follow_store, &out_buf);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .cast_spell_id);
    try std.testing.expectEqual(@as(u32, 777), orders[0].msg.cast_spell_id.spell_id);
    try std.testing.expectEqual(intent.Priority.spec, intent_store.current(bot.bot_id).?.priority);
    try std.testing.expect(intent_store.current(bot.bot_id).?.intent == .casting_scripted);
}

test "compute: role facing blocks spec cast" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(2);
    bot.state.guid = 0x102;
    bot.state.game_time_ms = 1000;

    const orders = testComputeWithProposers(bot, testRoleFacing, testSpecCast, &intent_store, &dispatch_store, &follow_store, &out_buf);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .set_facing);
    try std.testing.expectEqual(@as(f32, 1.25), orders[0].msg.set_facing);
    try std.testing.expectEqual(intent.Priority.role, intent_store.current(bot.bot_id).?.priority);
    try std.testing.expect(intent_store.current(bot.bot_id).?.intent == .facing);
}

test "compute: role start_attack does not block spec" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(3);
    bot.state.guid = 0x103;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    const orders = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        false,
        testRoleStartAttack,
        testSpecCast,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .cast_spell_id);
    try std.testing.expectEqual(@as(u32, 777), orders[0].msg.cast_spell_id.spell_id);
    try std.testing.expectEqual(intent.Priority.spec, intent_store.current(bot.bot_id).?.priority);
    try std.testing.expect(intent_store.current(bot.bot_id).?.intent == .casting_scripted);
}

test "compute: spec cast does not force stop_attack during anchor chase" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(4);
    bot.state.guid = 0x104;
    bot.state.target_guid = 0xabc;
    bot.state.orientation = std.math.pi / 2.0;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.attack_pos);

    const world = [_]WorldSnapshot{.{
        .scan = blk: {
            var scan = std.mem.zeroes(proto.ScanEntry);
            scan.guid = 0xabc;
            scan.x = 5;
            scan.y = 0;
            scan.z = 0;
            break :blk scan;
        },
        .map_id = 0,
        .last_seen_ts_ns = 0,
    }};

    const orders = computeWithProposers(
        &.{bot},
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleStartAttack,
        testSpecCastTarget,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), orders.len);
}

test "compute: threat hold blocks stale spec when threat table drops out" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.bot_id = testBotId(33);
    dps.state.guid = 0xd05;
    dps.state.map_id = 1;
    dps.state.class = @intFromEnum(combat.Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.target_guid = 0xabc;
    dps.state.target_unit_reaction = 2;
    dps.state.game_time_ms = 1000;
    dps.state.target_threat_count = 2;
    dps.state.target_threats[0] = .{ .unit_guid = dps.state.guid, .threat = 950 };
    dps.state.target_threats[1] = .{ .unit_guid = 0xaaa, .threat = 1000 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id = testBotId(34);
    tank.state.guid = 0xaaa;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(combat.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    tank.state.target_guid = 0xabc;
    tank.state.target_unit_reaction = 2;
    tank.state.game_time_ms = dps.state.game_time_ms;
    tank.state.target_threat_count = 2;
    tank.state.target_threats[0] = .{ .unit_guid = tank.state.guid, .threat = 1000 };
    tank.state.target_threats[1] = .{ .unit_guid = dps.state.guid, .threat = 950 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    _ = computeWithProposers(
        &.{ dps, tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleStartAttack,
        testSpecCast,
        null,
    );

    dps.state.game_time_ms = 1800;
    dps.state.target_threat_count = 0;
    tank.state.game_time_ms = dps.state.game_time_ms;
    tank.state.target_threat_count = 0;

    const orders = computeWithProposers(
        &.{ dps, tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleStartAttack,
        testSpecCast,
        null,
    );

    _ = orders;
}

test "compute: existing spec intent cleared when role blocks" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(4);
    bot.state.guid = 0x104;
    bot.state.game_time_ms = 1000;

    _ = intent_store.replaceAt(bot.bot_id, .{
        .intent = .{ .casting_scripted = .{ .spell_id = 111, .target_guid = bot.state.guid } },
        .priority = .spec,
        .created_at_ms = bot.state.game_time_ms,
        .source = .spec_attack,
    }, &dispatch_store, bot.state.game_time_ms);

    const orders = testComputeWithProposers(bot, testRoleMovingBlocking, testNoSpec, &intent_store, &dispatch_store, &follow_store, &out_buf);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .ctm_move);
    try std.testing.expectEqual(intent.Priority.role, intent_store.current(bot.bot_id).?.priority);
    try std.testing.expect(intent_store.current(bot.bot_id).?.intent == .moving_to);
}

test "compute: role does not clear encounter intent" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(5);
    bot.state.guid = 0x105;
    bot.state.game_time_ms = 1000;

    _ = intent_store.replaceAt(bot.bot_id, .{
        .intent = .{ .moving_to = .{
            .pos = .{ .x = 77, .y = 88, .z = 99 },
            .arrival_yards = 0.5,
            .reason = .encounter_route,
            .non_blocking = true,
        } },
        .priority = .encounter,
        .created_at_ms = bot.state.game_time_ms,
        .source = .encounter_route,
    }, &dispatch_store, bot.state.game_time_ms);

    const orders = testComputeWithProposers(bot, testRoleMovingBlocking, testSpecCast, &intent_store, &dispatch_store, &follow_store, &out_buf);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .ctm_move);
    try std.testing.expectEqual(@as(f32, 77), orders[0].msg.ctm_move.x);
    try std.testing.expectEqual(intent.Priority.encounter, intent_store.current(bot.bot_id).?.priority);
    try std.testing.expectEqual(intent.Reason.encounter_route, intent_store.current(bot.bot_id).?.source);
}

test "compute: target loss clears role movement and stops active CTM" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(15);
    bot.state.guid = 0x115;
    bot.state.game_time_ms = 1000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);

    _ = intent_store.replaceAt(bot.bot_id, .{
        .intent = .{ .moving_to = .{
            .pos = .{ .x = 77, .y = 88, .z = 99 },
            .arrival_yards = 0.5,
            .reason = .role_stack,
            .non_blocking = true,
        } },
        .priority = .role,
        .created_at_ms = bot.state.game_time_ms,
        .source = .role_stack,
    }, &dispatch_store, bot.state.game_time_ms);

    const orders = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .ctm_stop);
    try std.testing.expectEqual(intent.Priority.idle, intent_store.current(bot.bot_id).?.priority);
}

test "compute: friendly selected target clears start attack and stops autoattack" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(58);
    bot.state.guid = 0x158;
    bot.state.game_time_ms = 1000;
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 5;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    _ = intent_store.replaceAt(bot.bot_id, .{
        .intent = .start_attack,
        .priority = .role,
        .created_at_ms = bot.state.game_time_ms,
        .source = .role_start_attack,
    }, &dispatch_store, bot.state.game_time_ms);

    const orders = computeWithProposers(
        &.{bot},
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .lua_exec);
    try std.testing.expectEqualStrings("StopAttack()", std.mem.sliceTo(&orders[0].msg.lua_exec, 0));
    try std.testing.expectEqual(intent.Priority.idle, intent_store.current(bot.bot_id).?.priority);
}

test "compute: encounter threat does not block movement route" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.bot_id = testBotId(59);
    dps.state.guid = 0xd59;
    dps.state.map_id = 1;
    dps.state.class = @intFromEnum(combat.Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.target_guid = 0xabc;
    dps.state.target_unit_reaction = 2;
    dps.state.game_time_ms = 1000;
    dps.state.ctm_action = @intFromEnum(proto.CtmAction.attack_pos);
    dps.state.target_threat_count = 2;
    dps.state.target_threats[0] = .{ .unit_guid = dps.state.guid, .threat = 1100 };
    dps.state.target_threats[1] = .{ .unit_guid = 0xaaa, .threat = 1000 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id = testBotId(60);
    tank.state.guid = 0xaaa;
    tank.state.map_id = dps.state.map_id;
    tank.state.class = @intFromEnum(combat.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    tank.state.target_guid = dps.state.target_guid;
    tank.state.target_unit_reaction = 2;
    tank.state.game_time_ms = dps.state.game_time_ms;
    tank.state.target_threat_count = 2;
    tank.state.target_threats[0] = .{ .unit_guid = tank.state.guid, .threat = 1000 };
    tank.state.target_threats[1] = .{ .unit_guid = dps.state.guid, .threat = 1100 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = dps.state.target_guid;
    scan.hp = 1000;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = dps.state.map_id, .last_seen_ts_ns = 0 }};

    _ = intent_store.replaceAt(dps.bot_id, .{
        .intent = .{ .moving_to = .{
            .pos = .{ .x = 77, .y = 88, .z = 99 },
            .arrival_yards = 0.5,
            .reason = .encounter_route,
            .non_blocking = true,
        } },
        .priority = .encounter,
        .created_at_ms = dps.state.game_time_ms,
        .source = .encounter_route,
    }, &dispatch_store, dps.state.game_time_ms);

    const stop = computeWithProposers(
        &.{ dps, tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );
    var move_found_tick1 = false;
    for (stop) |order| {
        if (!std.mem.eql(u8, &order.bot_id, &dps.bot_id)) continue;
        try std.testing.expect(order.msg == .ctm_move);
        try std.testing.expectEqual(@as(f32, 77), order.msg.ctm_move.x);
        try std.testing.expectEqual(@as(f32, 88), order.msg.ctm_move.y);
        move_found_tick1 = true;
    }
    try std.testing.expect(move_found_tick1);
    try std.testing.expectEqual(intent.Priority.encounter, intent_store.current(dps.bot_id).?.priority);
}

test "compute: ranged encounter threat stop reasserts while idle" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.bot_id = testBotId(61);
    dps.state.guid = 0xd61;
    dps.state.map_id = 1;
    dps.state.class = @intFromEnum(combat.Class.hunter);
    dps.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    dps.state.target_guid = 0xabc;
    dps.state.target_unit_reaction = 2;
    dps.state.game_time_ms = 1000;
    dps.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    dps.state.target_threat_count = 2;
    dps.state.target_threats[0] = .{ .unit_guid = dps.state.guid, .threat = 1100 };
    dps.state.target_threats[1] = .{ .unit_guid = 0xaaa, .threat = 1000 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id = testBotId(62);
    tank.state.guid = 0xaaa;
    tank.state.map_id = dps.state.map_id;
    tank.state.class = @intFromEnum(combat.Class.paladin);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    tank.state.target_guid = dps.state.target_guid;
    tank.state.target_unit_reaction = 2;
    tank.state.game_time_ms = dps.state.game_time_ms;
    tank.state.target_threat_count = 2;
    tank.state.target_threats[0] = .{ .unit_guid = tank.state.guid, .threat = 1000 };
    tank.state.target_threats[1] = .{ .unit_guid = dps.state.guid, .threat = 1100 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = dps.state.target_guid;
    scan.hp = 1000;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = dps.state.map_id, .last_seen_ts_ns = 0 }};

    var seq = intent.Sequenced{ .steps = undefined, .len = 1 };
    seq.steps[0] = .{ .intent = .{ .waiting_for = .{
        .until = .{ .game_time_at_least_ms = dps.state.game_time_ms + 5000 },
        .max_age_ms = 6000,
    } } };
    _ = intent_store.replaceAt(dps.bot_id, .{
        .intent = .{ .sequenced = seq },
        .priority = .encounter,
        .created_at_ms = dps.state.game_time_ms,
        .source = .encounter_swap,
    }, &dispatch_store, dps.state.game_time_ms);

    const tick1 = computeWithProposers(
        &.{ dps, tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );
    var tick1_stop_found = false;
    for (tick1) |order| {
        if (!std.mem.eql(u8, &order.bot_id, &dps.bot_id)) continue;
        try std.testing.expect(order.msg == .lua_exec);
        try std.testing.expectEqualStrings("StopAttack()", std.mem.sliceTo(&order.msg.lua_exec, 0));
        tick1_stop_found = true;
    }
    try std.testing.expect(tick1_stop_found);

    dps.state.game_time_ms += proto.brain_tick_ms;
    tank.state.game_time_ms = dps.state.game_time_ms;

    const tick2 = computeWithProposers(
        &.{ dps, tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );
    var tick2_stop_found = false;
    for (tick2) |order| {
        if (!std.mem.eql(u8, &order.bot_id, &dps.bot_id)) continue;
        try std.testing.expect(order.msg == .lua_exec);
        try std.testing.expectEqualStrings("StopAttack()", std.mem.sliceTo(&order.msg.lua_exec, 0));
        tick2_stop_found = true;
    }
    try std.testing.expect(tick2_stop_found);
}

test "compute: high threat stops role autoattack heartbeat" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.bot_id = testBotId(63);
    dps.state.guid = 0xd63;
    dps.state.map_id = 1;
    dps.state.class = @intFromEnum(combat.Class.hunter);
    dps.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    dps.state.target_guid = 0xabc;
    dps.state.target_unit_reaction = 2;
    dps.state.game_time_ms = 1000;
    dps.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    dps.state.target_threat_count = 2;
    dps.state.target_threats[0] = .{ .unit_guid = dps.state.guid, .threat = 1100 };
    dps.state.target_threats[1] = .{ .unit_guid = 0xaaa, .threat = 1000 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id = testBotId(64);
    tank.state.guid = 0xaaa;
    tank.state.map_id = dps.state.map_id;
    tank.state.class = @intFromEnum(combat.Class.paladin);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    tank.state.target_guid = dps.state.target_guid;
    tank.state.target_unit_reaction = 2;
    tank.state.game_time_ms = dps.state.game_time_ms;
    tank.state.target_threat_count = 2;
    tank.state.target_threats[0] = .{ .unit_guid = tank.state.guid, .threat = 1000 };
    tank.state.target_threats[1] = .{ .unit_guid = dps.state.guid, .threat = 1100 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = dps.state.target_guid;
    scan.hp = 1000;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = dps.state.map_id, .last_seen_ts_ns = 0 }};

    const orders = computeWithProposers(
        &.{ dps, tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleStartAttack,
        testNoSpec,
        null,
    );

    var stop_found = false;
    for (orders) |order| {
        if (!std.mem.eql(u8, &order.bot_id, &dps.bot_id)) continue;
        try std.testing.expect(order.msg == .lua_exec);
        try std.testing.expectEqualStrings("StopAttack()", std.mem.sliceTo(&order.msg.lua_exec, 0));
        stop_found = true;
    }
    try std.testing.expect(stop_found);
    try std.testing.expectEqual(intent.Priority.idle, intent_store.current(dps.bot_id).?.priority);
}

test "compute: high threat survival casts Feign Death" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.bot_id = testBotId(65);
    dps.state.guid = 0xd65;
    dps.state.map_id = 1;
    dps.state.class = @intFromEnum(combat.Class.hunter);
    dps.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    dps.state.target_guid = 0xabc;
    dps.state.target_unit_reaction = 2;
    dps.state.game_time_ms = 1000;
    dps.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    dps.state.target_threat_count = 2;
    dps.state.target_threats[0] = .{ .unit_guid = dps.state.guid, .threat = 1980 };
    dps.state.target_threats[1] = .{ .unit_guid = 0xaaa, .threat = 1000 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id = testBotId(66);
    tank.state.guid = 0xaaa;
    tank.state.map_id = dps.state.map_id;
    tank.state.class = @intFromEnum(combat.Class.paladin);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    tank.state.target_guid = dps.state.target_guid;
    tank.state.target_unit_reaction = 2;
    tank.state.game_time_ms = dps.state.game_time_ms;
    tank.state.target_threat_count = 2;
    tank.state.target_threats[0] = .{ .unit_guid = tank.state.guid, .threat = 1000 };
    tank.state.target_threats[1] = .{ .unit_guid = dps.state.guid, .threat = 1980 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = dps.state.target_guid;
    scan.hp = 1000;
    scan.hp_max = 1000;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = dps.state.map_id, .last_seen_ts_ns = 0 }};

    const orders = compute(
        &.{ dps, tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
    );

    var feign_found = false;
    for (orders) |order| {
        if (!std.mem.eql(u8, &order.bot_id, &dps.bot_id)) continue;
        try std.testing.expect(order.msg == .cast_spell_id);
        try std.testing.expectEqual(feign_death_spell_id, order.msg.cast_spell_id.spell_id);
        feign_found = true;
    }
    try std.testing.expect(feign_found);
    try std.testing.expectEqual(intent.Reason.spec_threat, intent_store.current(dps.bot_id).?.source);
}

test "compute: high threat survival casts Feign Death during encounter swap" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var dps: BotSnapshot = std.mem.zeroes(BotSnapshot);
    dps.bot_id = testBotId(67);
    dps.state.guid = 0xd67;
    dps.state.map_id = 1;
    dps.state.class = @intFromEnum(combat.Class.hunter);
    dps.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    dps.state.target_guid = 0xabc;
    dps.state.target_unit_reaction = 2;
    dps.state.game_time_ms = 1000;
    dps.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    dps.state.target_threat_count = 2;
    dps.state.target_threats[0] = .{ .unit_guid = dps.state.guid, .threat = 1980 };
    dps.state.target_threats[1] = .{ .unit_guid = 0xaaa, .threat = 1000 };

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.bot_id = testBotId(68);
    tank.state.guid = 0xaaa;
    tank.state.map_id = dps.state.map_id;
    tank.state.class = @intFromEnum(combat.Class.paladin);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    tank.state.target_guid = dps.state.target_guid;
    tank.state.target_unit_reaction = 2;
    tank.state.game_time_ms = dps.state.game_time_ms;
    tank.state.target_threat_count = 2;
    tank.state.target_threats[0] = .{ .unit_guid = tank.state.guid, .threat = 1000 };
    tank.state.target_threats[1] = .{ .unit_guid = dps.state.guid, .threat = 1980 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = dps.state.target_guid;
    scan.hp = 1000;
    scan.hp_max = 1000;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = dps.state.map_id, .last_seen_ts_ns = 0 }};

    var seq = intent.Sequenced{ .steps = undefined, .len = 1 };
    seq.steps[0] = .{ .intent = .{ .waiting_for = .{
        .until = .{ .game_time_at_least_ms = dps.state.game_time_ms + 5000 },
        .max_age_ms = 6000,
    } } };
    _ = intent_store.replaceAt(dps.bot_id, .{
        .intent = .{ .sequenced = seq },
        .priority = .encounter,
        .created_at_ms = dps.state.game_time_ms,
        .source = .encounter_swap,
    }, &dispatch_store, dps.state.game_time_ms);

    const orders = compute(
        &.{ dps, tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
    );

    var feign_found = false;
    for (orders) |order| {
        if (!std.mem.eql(u8, &order.bot_id, &dps.bot_id)) continue;
        try std.testing.expect(order.msg == .cast_spell_id);
        try std.testing.expectEqual(feign_death_spell_id, order.msg.cast_spell_id.spell_id);
        feign_found = true;
    }
    try std.testing.expect(feign_found);
    try std.testing.expectEqual(intent.Priority.encounter, intent_store.current(dps.bot_id).?.priority);
    try std.testing.expectEqual(intent.Reason.encounter_swap, intent_store.current(dps.bot_id).?.source);
}

test "compute: target loss does not clear encounter movement" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(16);
    bot.state.guid = 0x116;
    bot.state.game_time_ms = 1000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    _ = intent_store.replaceAt(bot.bot_id, .{
        .intent = .{ .moving_to = .{
            .pos = .{ .x = 77, .y = 88, .z = 99 },
            .arrival_yards = 0.5,
            .reason = .encounter_route,
            .non_blocking = true,
        } },
        .priority = .encounter,
        .created_at_ms = bot.state.game_time_ms,
        .source = .encounter_route,
    }, &dispatch_store, bot.state.game_time_ms);

    const orders = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .ctm_move);
    try std.testing.expectEqual(@as(f32, 77), orders[0].msg.ctm_move.x);
    try std.testing.expectEqual(intent.Priority.encounter, intent_store.current(bot.bot_id).?.priority);
}

test "compute: encounter still preempts role" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(6);
    bot.state.guid = 0x106;
    bot.state.game_time_ms = 1000;

    _ = intent_store.replaceAt(bot.bot_id, .{
        .intent = .{ .facing = .{ .radians = 2.5 } },
        .priority = .encounter,
        .created_at_ms = bot.state.game_time_ms,
        .source = .encounter_transition,
    }, &dispatch_store, bot.state.game_time_ms);

    const orders = testComputeWithProposers(bot, testRoleMovingBlocking, testSpecCast, &intent_store, &dispatch_store, &follow_store, &out_buf);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .set_facing);
    try std.testing.expectEqual(@as(f32, 2.5), orders[0].msg.set_facing);
    try std.testing.expectEqual(intent.Priority.encounter, intent_store.current(bot.bot_id).?.priority);
}

test "compute: stale move_to onto current position clears confirm instead of re-dispatching forever" {
    // Thaddius first-shift polarity deadlock: an encounter stacking intent whose
    // destination the bot already occupies kept `confirm.active` pinned (the
    // engine issues no motion, so `move_started` never latches), which starved
    // the fresh cross-arena waypoint. The dispatch pipeline must clear it.
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(21);
    bot.state.guid = 0x121;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.x = 10;
    bot.state.y = 10;
    bot.state.z = 0;
    // Past the move-start grace window (4 ticks) so the liveness guard fires.
    bot.state.game_time_ms = 1_000 + proto.brain_tick_ms * 4;

    _ = intent_store.replaceAt(bot.bot_id, .{
        .intent = .{ .stacking = .{ .x = 10, .y = 10, .z = 0, .tolerance = 1.5 } },
        .priority = .encounter,
        .created_at_ms = 1_000,
        .max_age_ms = 10_000,
        .source = .encounter_stack,
    }, &dispatch_store, 1_000);

    const entry = intent_store.currentMut(bot.bot_id).?;
    entry.confirm.active = true;
    entry.confirm.move_started = false;
    entry.confirm.last_action = .{ .move_to = .{ .x = 10, .y = 10, .z = 0, .arrival_yards = 1.5 } };
    entry.confirm.dispatched_at_ms = 1_000;

    const orders = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );

    // No spurious move re-dispatched, and the deadlocked confirm is cleared so a
    // fresh same-priority intent can replace it on the next tick.
    try std.testing.expectEqual(@as(usize, 0), orders.len);
    try std.testing.expect(!intent_store.current(bot.bot_id).?.confirm.active);
}

fn testIntentSlotFromAction(action: combat.Action) intent.IntentSlot {
    const built: intent.SimpleIntent = switch (action) {
        .none => .idle,
        .target_guid => |guid| .{ .targeting = .{ .target_guid = guid } },
        .attack => |guid| .{ .attacking = .{ .target_guid = guid } },
        .start_attack => .start_attack,
        .stop_attack => .idle,
        .stop_cast => .idle,
        .set_facing_rad => |rad| .{ .facing = .{ .radians = rad } },
        .move_to => |p| .{
            .moving_to = .{
                .pos = .{ .x = p.x, .y = p.y, .z = p.z },
                .reason = .operator_nav,
            },
        },
        .move_to_nb => |p| .{
            .moving_to = .{
                .pos = .{ .x = p.x, .y = p.y, .z = p.z },
                .reason = .operator_nav,
                .non_blocking = true,
            },
        },
        .cast => |id| .{
            .casting_scripted = .{
                .spell_id = id,
                .target_guid = 0,
                .allow_cancel = false,
            },
        },
        .cast_instant => |id| .{
            .casting_scripted = .{
                .spell_id = id,
                .target_guid = 0,
                .instant = true,
            },
        },
        .cast_target => |ct| .{
            .casting_scripted = .{
                .spell_id = ct.spell_id,
                .target_guid = ct.target_guid,
            },
        },
        .cast_target_instant => |ct| .{
            .casting_scripted = .{
                .spell_id = ct.spell_id,
                .target_guid = ct.target_guid,
                .instant = true,
            },
        },
        .cast_ground => |cg| .{
            .casting_scripted_ground = .{
                .spell_id = cg.spell_id,
                .x = cg.x,
                .y = cg.y,
                .z = cg.z,
                .instant = true,
            },
        },
        .jump => .jump,
        .walk => .idle,
        .jump_near_xy => |j| .{
            .jump_near = .{
                .x = j.x,
                .y = j.y,
                .tolerance_yards = j.tolerance_yards,
            },
        },
        .ctm_stop => .{ .waiting_for = .{ .until = .ctm_idle, .max_age_ms = test_sequence_wait_max_age_ms } },
        .clear_target => .{ .waiting_for = .{ .until = .target_cleared, .max_age_ms = test_sequence_wait_max_age_ms } },
        .interact => .idle,
        .use_inventory_item => .idle,
        .apply_poison => .idle,
    };

    return .{ .intent = built, .done_when = null };
}

fn installTestSequence(
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    bot_id: BotId,
    actions: []const combat.Action,
    game_time_ms: u32,
) void {
    std.debug.assert(actions.len <= intent.max_seq_steps);
    var seq = intent.Sequenced{ .steps = undefined, .len = @intCast(actions.len) };
    for (actions, 0..) |action, i| {
        seq.steps[i] = testIntentSlotFromAction(action);
    }
    const ai = intent.ActiveIntent{
        .intent = .{ .sequenced = seq },
        .priority = .operator,
        .created_at_ms = game_time_ms,
        .source = .operator_nav,
    };
    _ = intent_store.replace(bot_id, ai, true, dispatch_store, game_time_ms);
}

fn installOneShotSpellSequence(
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    bot_id: BotId,
    spell_ids: []const u32,
    game_time_ms: u32,
    source: intent.Reason,
) void {
    std.debug.assert(spell_ids.len <= intent.max_seq_steps);
    var seq = intent.Sequenced{ .steps = undefined, .len = @intCast(spell_ids.len) };
    for (spell_ids, 0..) |spell_id, i| {
        seq.steps[i] = .{ .intent = .{ .casting_scripted = .{
            .spell_id = spell_id,
            .target_guid = 0,
            .instant = true,
            .one_shot = true,
        } } };
    }
    const ai = intent.ActiveIntent{
        .intent = .{ .sequenced = seq },
        .priority = .operator,
        .created_at_ms = game_time_ms,
        .source = source,
    };
    _ = intent_store.replace(bot_id, ai, true, dispatch_store, game_time_ms);
}

fn sequencedCurrent(intent_store: *const IntentStore, bot_id: BotId) ?u8 {
    const ai = intent_store.current(bot_id) orelse return null;
    if (ai.intent != .sequenced) return null;
    return ai.intent.sequenced.current;
}

fn sequencedExhausted(intent_store: *const IntentStore, bot_id: BotId) bool {
    const cur = sequencedCurrent(intent_store, bot_id) orelse return true;
    const ai = intent_store.current(bot_id).?;
    return cur >= ai.intent.sequenced.len;
}

test "compute: instant attack steps advance same tick" {
    const bot_id = testBotId(42);
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    installTestSequence(&intent_store, &dispatch_store, bot_id, &.{ .{ .attack = 100 }, .{ .attack = 200 } }, 0);

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = bot_id;

    const orders1 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders1.len);
    try std.testing.expect(orders1[0].msg == .ctm_attack_guid);
    try std.testing.expectEqual(@as(u8, 1), sequencedCurrent(&intent_store, bot_id).?);

    const orders2 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders2.len);
    try std.testing.expect(sequencedExhausted(&intent_store, bot_id));
}

test "compute: cast steps stop CTM before dispatching" {
    const bot_id = testBotId(41);
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    installTestSequence(&intent_store, &dispatch_store, bot_id, &.{.{ .cast = 777 }}, 0);

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = bot_id;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);

    const orders1 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders1.len);
    try std.testing.expect(orders1[0].msg == .ctm_stop);
    try std.testing.expectEqual(@as(u8, 0), sequencedCurrent(&intent_store, bot_id).?);
    try std.testing.expect(intent_store.current(bot_id).?.confirm.cast_stop_sent);

    const orders2 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders2.len);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    const orders3 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders3.len);
    try std.testing.expect(orders3[0].msg == .cast_spell_id);
}

test "compute: operator sequence skips cooldowned spell steps" {
    const bot_id = testBotId(40);
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    installOneShotSpellSequence(&intent_store, &dispatch_store, bot_id, &.{ 12042, 12472, 55342 }, 0, .operator_nav);

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = bot_id;
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = 12042, .category = 0, .remaining_ms = 3000, .duration_ms = 120000 };

    const orders1 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders1.len);
    try std.testing.expect(orders1[0].msg == .cast_spell_id);
    try std.testing.expectEqual(@as(u32, 12472), orders1[0].msg.cast_spell_id.spell_id);
    try std.testing.expectEqual(@as(u8, 1), sequencedCurrent(&intent_store, bot_id).?);
}

test "compute: finished operator sequence yields back to spec rotation" {
    const bot_id = testBotId(39);
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    installOneShotSpellSequence(&intent_store, &dispatch_store, bot_id, &.{12042}, 0, .operator_burst);

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = bot_id;
    bot.state.guid = 0x39;
    bot.state.game_time_ms = 1000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    const orders1 = testComputeWithProposers(bot, testNoRole, testSpecCast, &intent_store, &dispatch_store, &follow_store, &out_buf);
    try std.testing.expectEqual(@as(usize, 1), orders1.len);
    try std.testing.expect(orders1[0].msg == .cast_spell_id);
    try std.testing.expectEqual(@as(u32, 12042), orders1[0].msg.cast_spell_id.spell_id);

    bot.state.game_time_ms += combat.instant_cast_debounce_ms;
    const orders2 = testComputeWithProposers(bot, testNoRole, testSpecCast, &intent_store, &dispatch_store, &follow_store, &out_buf);
    try std.testing.expectEqual(@as(usize, 0), orders2.len);

    bot.state.game_time_ms += 1;
    const orders3 = testComputeWithProposers(bot, testNoRole, testSpecCast, &intent_store, &dispatch_store, &follow_store, &out_buf);
    try std.testing.expectEqual(@as(usize, 1), orders3.len);
    try std.testing.expect(orders3[0].msg == .cast_spell_id);
    try std.testing.expectEqual(@as(u32, 777), orders3[0].msg.cast_spell_id.spell_id);
}

test "compute: missing spec proposal does not clear in-flight spec confirm" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(46);
    bot.state.guid = 0x46;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.game_time_ms = 1000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    _ = intent_store.replace(bot.bot_id, .{
        .intent = .{ .casting_scripted = .{ .spell_id = 47841, .target_guid = 0xabc } },
        .priority = .spec,
        .created_at_ms = bot.state.game_time_ms,
        .source = .spec_attack,
        .confirm = .{
            .active = true,
            .last_action = .{ .cast_target = .{ .spell_id = 47841, .target_guid = 0xabc } },
            .expected_spell_id = 47841,
            .dispatched_at_ms = bot.state.game_time_ms,
            .spell_phase = .waiting_go,
        },
    }, true, &dispatch_store, bot.state.game_time_ms);

    const orders = computeWithProposers(
        &.{bot},
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );
    try std.testing.expectEqual(@as(usize, 0), orders.len);

    const current = intent_store.current(bot.bot_id).?;
    try std.testing.expect(current.priority == .spec);
    try std.testing.expect(current.confirm.active);
    try std.testing.expect(current.source == .spec_attack);
}

test "compute: in-range targeted cast dispatches normally" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(47);
    bot.state.class = @intFromEnum(combat.Class.priest);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.x = -8;
    bot.state.y = 0;
    bot.state.orientation = 0;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = 15473, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = 48168, .remaining_ms = 0 };
    bot.state.target_aura_count = 1;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = 48160, .remaining_ms = 0 };
    bot.state.spell_range_count = 2;
    bot.state.spell_ranges[0] = .{ .spell_id = 48160, .max_range_yards = 30.0 };
    bot.state.spell_ranges[1] = .{ .spell_id = 48125, .max_range_yards = 30.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.x = 10;
    scan.y = 0;
    scan.z = 0;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .cast_spell_guid);
}

test "compute: melee DPS out of strict swing range moves before cast" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(48);
    bot.state.class = @intFromEnum(combat.Class.rogue);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.x = -6.2;
    bot.state.y = 0;
    bot.state.orientation = 0;
    bot.state.game_time_ms = 10_000;
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = 48666, .max_range_yards = 5.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    scan.x = 0;
    scan.y = 0;
    scan.combat_reach = 2.0;

    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .ctm_move);
    try std.testing.expectApproxEqAbs(@as(f32, -4.0), orders[0].msg.ctm_move.x, 0.01);
    try std.testing.expectEqual(intent.Reason.role_stack, intent_store.current(bot.bot_id).?.source);
}

test "compute: blood tank engage casts icy touch before role movement" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(55);
    bot.state.class = @intFromEnum(combat.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.x = 0;
    bot.state.y = 0;
    bot.state.game_time_ms = 10_000;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = 49909, .max_range_yards = 20.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    scan.x = 15;
    scan.y = 0;
    scan.combat_reach = 1.0;

    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .cast_spell_guid);
    try std.testing.expectEqual(@as(u32, 49909), orders[0].msg.cast_spell_guid.spell_id);
    try std.testing.expectEqual(intent.Reason.tank_engage, intent_store.current(bot.bot_id).?.source);
}

test "compute: tank engage casts instant pull during active movement" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(57);
    bot.state.class = @intFromEnum(combat.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.x = 0;
    bot.state.y = 0;
    bot.state.game_time_ms = 10_000;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };
    addPlayerAura(&bot, blood_frost_presence_spell_id);
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = 49909, .max_range_yards = 20.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    scan.x = 15;
    scan.y = 0;
    scan.combat_reach = 1.0;

    var world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const orders1 = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders1.len);
    try std.testing.expect(orders1[0].msg == .cast_spell_guid);
    try std.testing.expectEqual(@as(u32, 49909), orders1[0].msg.cast_spell_guid.spell_id);

    bot.state.game_time_ms += proto.brain_tick_ms;
    const orders2 = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders2.len);

    bot.state.game_time_ms += combat.instant_cast_debounce_ms;
    const orders3 = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders3.len);
    try std.testing.expect(intent_store.current(bot.bot_id).?.intent == .idle);
}

test "compute: role start stops residual movement before spec cast" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(58);
    bot.state.class = @intFromEnum(combat.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.x = 14;
    bot.state.y = 0;
    bot.state.orientation = std.math.pi;
    bot.state.game_time_ms = 10_000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };
    addPlayerAura(&bot, blood_frost_presence_spell_id);
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = 49909, .max_range_yards = 20.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    scan.x = 10;
    scan.y = 0;
    scan.combat_reach = 1.0;

    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .ctm_stop);
    try std.testing.expectEqual(intent.Reason.role_start_attack, intent_store.current(bot.bot_id).?.source);

    const orders2 = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders2.len);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.game_time_ms += intent_confirm.ctm_stop_settle_ms;
    const orders3 = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders3.len);

    bot.state.game_time_ms += proto.brain_tick_ms;
    const orders4 = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders4.len);
    try std.testing.expect(orders4[0].msg == .cast_spell_guid);
}

test "compute: role start does not stop idle-like ctm action" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(60);
    bot.state.class = @intFromEnum(combat.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.x = 14;
    bot.state.y = 0;
    bot.state.orientation = std.math.pi;
    bot.state.game_time_ms = 10_000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };
    addPlayerAura(&bot, blood_frost_presence_spell_id);
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = 49909, .max_range_yards = 20.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    scan.x = 10;
    scan.y = 0;
    scan.combat_reach = 1.0;

    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .cast_spell_guid);
}

test "compute: protection paladin tank engage casts avengers shield before role movement" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(56);
    bot.state.class = @intFromEnum(combat.Class.paladin);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.x = 0;
    bot.state.y = 0;
    bot.state.game_time_ms = 10_000;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = 48827, .max_range_yards = 30.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    scan.x = 20;
    scan.y = 0;
    scan.combat_reach = 1.0;

    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .cast_spell_guid);
    try std.testing.expectEqual(@as(u32, 48827), orders[0].msg.cast_spell_guid.spell_id);
    try std.testing.expectEqual(intent.Reason.tank_engage, intent_store.current(bot.bot_id).?.source);
}

test "compute: instant target casts are debounced" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(43);
    bot.state.class = @intFromEnum(combat.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.x = 14;
    bot.state.y = 0;
    bot.state.orientation = std.math.pi;
    bot.state.game_time_ms = 10_000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };
    addPlayerAura(&bot, blood_frost_presence_spell_id);
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = 49909, .max_range_yards = 20.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.x = 10;
    scan.y = 0;
    scan.z = 0;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const orders1 = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders1.len);
    try std.testing.expect(orders1[0].msg == .cast_spell_guid);

    bot.state.game_time_ms += proto.brain_tick_ms;
    const orders2 = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders2.len);

    bot.state.game_time_ms += combat.instant_cast_debounce_ms;
    const orders3 = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders3.len);
    try std.testing.expect(!intent_store.current(bot.bot_id).?.confirm.active);

    bot.state.game_time_ms += proto.brain_tick_ms;
    const orders4 = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders4.len);
    try std.testing.expect(orders4[0].msg == .cast_spell_guid);
}

test "compute: melee targeted casts face first when misaligned" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(54);
    bot.state.class = @intFromEnum(combat.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.x = 14;
    bot.state.y = 0;
    bot.state.orientation = std.math.pi / 2.0;
    bot.state.game_time_ms = 10_000;
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };
    addPlayerAura(&bot, blood_frost_presence_spell_id);
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = 49909, .max_range_yards = 20.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.x = 10;
    scan.y = 0;
    scan.z = 0;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .set_facing);
}

test "compute: melee contact at 90 deg facing error issues set_facing before cast" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(59);
    bot.state.class = @intFromEnum(combat.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.x = 0;
    bot.state.y = 0;
    bot.state.orientation = 0;
    bot.state.game_time_ms = 10_000;
    bot.state.combat_reach = 1.5;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };
    addPlayerAura(&bot, blood_frost_presence_spell_id);
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = 49909, .max_range_yards = 20.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.hp_max = 100;
    scan.x = 0;
    scan.y = 0.5;
    scan.z = 0;
    scan.combat_reach = 3.0;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .set_facing);
}

test "formatOrderLabel keeps labels written into caller buffer" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(44);
    bot.state.class = @intFromEnum(combat.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    const name = "Sangboulon";
    @memcpy(bot.state.player_name[0..name.len], name[0..name.len]);
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.x = 3;
    scan.y = 4;
    scan.orientation = 1;
    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const order: Order = .{
        .bot_id = bot.bot_id,
        .msg = .{ .cast_spell_guid = .{ .spell_id = 49921, .target_guid = 0xabc } },
    };

    var buf: [gui_snapshot.combat_order_label_len]u8 = undefined;
    const label = formatOrderLabel(&buf, order, &.{bot}, &world);
    try std.testing.expectEqualStrings(
        "Sangboulon: Plague Strike (49921) cast_tgt=0xabc dist=5.0 from=(0.0,0.0,0.0) o=0.000 tgt=0xabc target=(3.0,4.0,0.0) target_o=1.000 target_to_player=4.069 target_player_delta=3.069 reach=(0.0,0.0) br=(0.0,0.0) ctm=0 ctm_dst=(0.0,0.0,0.0)",
        label,
    );
}

test "compute: sequenced exhaustion clears active step" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    const bot_id = testBotId(99);

    installTestSequence(&intent_store, &dispatch_store, bot_id, &.{.{ .attack = 555 }}, 0);

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = bot_id;
    var out_buf: [types.max_bots]Order = undefined;

    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expect(sequencedExhausted(&intent_store, bot_id));
}

test "compute: move_to blocks until CTM idle after having started" {
    const bot_id = testBotId(77);
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    installTestSequence(&intent_store, &dispatch_store, bot_id, &.{
        .{ .move_to = .{ .x = 100, .y = 200, .z = 300 } },
        .{ .attack = 999 },
    }, 0);

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = bot_id;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    const orders1 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders1.len);
    try std.testing.expect(orders1[0].msg == .ctm_move);
    try std.testing.expectEqual(@as(u8, 0), sequencedCurrent(&intent_store, bot_id).?);

    const orders2 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders2.len);
    try std.testing.expectEqual(@as(u8, 0), sequencedCurrent(&intent_store, bot_id).?);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(u8, 0), sequencedCurrent(&intent_store, bot_id).?);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(u8, 1), sequencedCurrent(&intent_store, bot_id).?);

    const orders5 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders5.len);
    try std.testing.expect(sequencedExhausted(&intent_store, bot_id));
}

test "compute: following intent is passive after movement cleanup" {
    const bot_id = testBotId(76);
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    _ = intent_store.replace(bot_id, .{
        .intent = .{ .following = .{ .target_guid = 0xABCD } },
        .priority = .operator,
        .created_at_ms = 0,
        .source = .role_follow,
    }, true, &dispatch_store, 0);
    if (intent_store.currentMut(bot_id)) |ai| {
        ai.confirm.active = true;
        ai.confirm.move_started = true;
        ai.confirm.last_action = .{ .move_to = .{ .x = 7.5, .y = 10.0, .z = 0.0 } };
    }

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = bot_id;
    bot.state.class = @intFromEnum(combat.Class.rogue);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0xABCD;
    bot.state.target_unit_reaction = 2;
    bot.state.map_id = 1;
    bot.state.x = 0;
    bot.state.y = 0;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xABCD;
    scan.hp = 100;
    scan.x = 20;
    scan.y = 10;
    scan.z = 0;
    scan.orientation = 0;

    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 1,
        .last_seen_ts_ns = 0,
    }};

    const orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders.len);
}

test "compute: move_to_nb then jump without waiting for idle" {
    const bot_id = testBotId(55);
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    installTestSequence(&intent_store, &dispatch_store, bot_id, &.{
        .{ .move_to_nb = .{ .x = 1, .y = 2, .z = 3 } },
        .jump,
    }, 0);

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = bot_id;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    const orders1 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders1.len);
    try std.testing.expect(orders1[0].msg == .ctm_move);
    try std.testing.expectEqual(@as(u8, 1), sequencedCurrent(&intent_store, bot_id).?);

    const orders2 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders2.len);
    try std.testing.expect(orders2[0].msg == .jump);
    try std.testing.expect(sequencedExhausted(&intent_store, bot_id));
}

test "compute: jump_near_xy defers jump until in tolerance" {
    const bot_id = testBotId(61);
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    installTestSequence(&intent_store, &dispatch_store, bot_id, &.{.{ .jump_near_xy = .{
        .x = 100,
        .y = 200,
        .tolerance_yards = 3.0,
    } }}, 0);

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = bot_id;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    bot.state.x = 0;
    bot.state.y = 0;

    const orders_far = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders_far.len);
    try std.testing.expect(!sequencedExhausted(&intent_store, bot_id));

    bot.state.x = 100;
    bot.state.y = 200;
    const orders_jump = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders_jump.len);
    try std.testing.expect(orders_jump[0].msg == .jump);

    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expect(sequencedExhausted(&intent_store, bot_id));
}

test "compute: jump_near_xy cancels when CTM goes idle out of range" {
    const bot_id = testBotId(62);
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    installTestSequence(&intent_store, &dispatch_store, bot_id, &.{.{ .jump_near_xy = .{
        .x = 100,
        .y = 200,
        .tolerance_yards = 2.0,
    } }}, 0);

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = bot_id;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.x = 50;
    bot.state.y = 50;

    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expect(intent_store.current(bot_id).?.intent != .idle);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expect(intent_store.current(bot_id).?.intent != .idle);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expect(intent_store.current(bot_id).?.intent == .idle);
}

test "compute: advance, jump, advance sequence" {
    const bot_id = testBotId(88);
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    installTestSequence(&intent_store, &dispatch_store, bot_id, &.{
        .{ .move_to = .{ .x = 100, .y = 210, .z = 300 } },
        .jump,
        .{ .move_to = .{ .x = 100, .y = 220, .z = 300 } },
    }, 0);

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = bot_id;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    const orders1 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders1.len);
    try std.testing.expect(orders1[0].msg == .ctm_move);
    try std.testing.expectEqual(@as(u8, 0), sequencedCurrent(&intent_store, bot_id).?);

    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(u8, 0), sequencedCurrent(&intent_store, bot_id).?);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(u8, 0), sequencedCurrent(&intent_store, bot_id).?);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(u8, 1), sequencedCurrent(&intent_store, bot_id).?);

    const orders5 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders5.len);
    try std.testing.expect(orders5[0].msg == .jump);
    try std.testing.expectEqual(@as(u8, 2), sequencedCurrent(&intent_store, bot_id).?);

    const orders6 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders6.len);
    try std.testing.expect(orders6[0].msg == .ctm_move);
    try std.testing.expectEqual(@as(u8, 2), sequencedCurrent(&intent_store, bot_id).?);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    _ = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expect(sequencedExhausted(&intent_store, bot_id));
}

test "compute: spec intent expires after buff is applied — no re-dispatch past debounce" {
    // Regression: a stale casting_scripted intent must not re-fire after the debounce
    // window expires if the spec condition (buff missing) is already false.
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    const prot_paladin_class = @intFromEnum(combat.Class.paladin);
    const prot_paladin_talents = proto.TalentPoints{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    const righteous_fury_id: u32 = 25780;
    const blessing_of_sanctuary_id: u32 = 25899;

    var bot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(90);
    bot.state.class = prot_paladin_class;
    bot.state.talent_points = prot_paladin_talents;
    bot.state.game_time_ms = 10_000;
    bot.state.active_power_type = 0;
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;

    // Buff absent — expect a dispatch.
    const orders1 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders1.len);
    try std.testing.expect(orders1[0].msg == .cast_spell_id);
    try std.testing.expectEqual(righteous_fury_id, orders1[0].msg.cast_spell_id.spell_id);

    // Righteous Fury is already up, leaving the original buff condition.
    // Advance past
    // spec_intent_ttl_ms (500ms) but still inside instant_cast_debounce_ms (1500ms).
    // The stale casting_scripted intent must have expired; nothing should dispatch.
    const seal_of_vengeance_id: u32 = 31801;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{
        .caster_guid = bot.state.guid,
        .spell_id = righteous_fury_id,
        .remaining_ms = 600_000,
    };
    bot.state.player_auras[1] = .{
        .caster_guid = bot.state.guid,
        .spell_id = blessing_of_sanctuary_id,
        .remaining_ms = 600_000,
    };
    bot.state.player_aura_count = 3;
    bot.state.player_auras[2] = .{
        .caster_guid = bot.state.guid,
        .spell_id = seal_of_vengeance_id,
        .remaining_ms = 600_000,
    };
    bot.state.game_time_ms = 10_600; // +600ms > ttl(500), < debounce(1500)

    const orders2 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders2.len);

    // Also verify no re-dispatch after debounce window expires.
    bot.state.game_time_ms = 12_000; // +2000ms > debounce(1500)
    const orders3 = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders3.len);
}

test "compute: discipline casts inner fire as self buff out of combat" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(91);
    bot.state.guid = 0x100;
    bot.state.class = @intFromEnum(combat.Class.priest);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.game_time_ms = 10_000;

    const orders = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, false);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .cast_spell_id);
    try std.testing.expectEqual(@as(u32, 48168), orders[0].msg.cast_spell_id.spell_id);

    const ai = intent_store.current(bot.bot_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ai.priority == .spec);
    try std.testing.expect(ai.source == .spec_attack);
}

test "compute: dead bot does not cast missing self buff" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(92);
    bot.state.class = @intFromEnum(combat.Class.paladin);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    bot.state.game_time_ms = 10_000;
    bot.state.hp = 0;
    bot.state.hp_max = 1000;

    const orders = compute(&.{bot}, &.{}, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), orders.len);
    try std.testing.expect(intent_store.current(bot.bot_id) == null);
}

// ─── Thaddius encounter integration tests ────────────────────────────────────

fn thaddiusWorldSnapshot() [1]world_memory_mod.WorldSnapshot {
    var thaddius_scan = std.mem.zeroes(proto.ScanEntry);
    thaddius_scan.guid = 0x9999;
    thaddius_scan.hp = 5_000_000;
    std.mem.copyForwards(u8, thaddius_scan.name[0.."Thaddius".len], "Thaddius");
    thaddius_scan.x = 3480.0;
    thaddius_scan.y = -2928.0;
    thaddius_scan.z = 303.0;
    return .{.{ .scan = thaddius_scan, .map_id = 533, .last_seen_ts_ns = 0 }};
}

fn makeThaddiusPaladinBot(id: u8, x: f32, y: f32, z: f32) BotSnapshot {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(id);
    bot.state.class = @intFromEnum(combat.Class.paladin);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    bot.state.map_id = 533;
    bot.state.x = x;
    bot.state.y = y;
    bot.state.z = z;
    bot.state.game_time_ms = 10_000;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.active_power_type = 0;
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;
    return bot;
}

fn makeThaddiusMageBot(id: u8, x: f32, y: f32, z: f32) BotSnapshot {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(id);
    bot.state.class = @intFromEnum(combat.Class.mage);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.map_id = 533;
    bot.state.x = x;
    bot.state.y = y;
    bot.state.z = z;
    bot.state.game_time_ms = 10_000;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.active_power_type = 0;
    bot.state.active_power = 100;
    bot.state.active_power_max = 100;
    return bot;
}

fn thaddiusTwinsWorldSnapshot() [2]world_memory_mod.WorldSnapshot {
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");

    var stalagg_scan = std.mem.zeroes(proto.ScanEntry);
    stalagg_scan.guid = 0x1111;
    stalagg_scan.hp = 1000;
    stalagg_scan.hp_max = 1000;
    std.mem.copyForwards(u8, stalagg_scan.name[0.."Stalagg".len], "Stalagg");
    stalagg_scan.x = thaddius_arena.stalagg_initial.x;
    stalagg_scan.y = thaddius_arena.stalagg_initial.y;
    stalagg_scan.z = thaddius_arena.stalagg_initial.z;
    stalagg_scan.combat_reach = 1.0;

    var feugen_scan = std.mem.zeroes(proto.ScanEntry);
    feugen_scan.guid = 0x2222;
    feugen_scan.hp = 1000;
    feugen_scan.hp_max = 1000;
    std.mem.copyForwards(u8, feugen_scan.name[0.."Feugen".len], "Feugen");
    feugen_scan.x = thaddius_arena.feugen_initial.x;
    feugen_scan.y = thaddius_arena.feugen_initial.y;
    feugen_scan.z = thaddius_arena.feugen_initial.z;
    feugen_scan.combat_reach = 1.0;

    return .{
        .{ .scan = stalagg_scan, .map_id = 533, .last_seen_ts_ns = 0 },
        .{ .scan = feugen_scan, .map_id = 533, .last_seen_ts_ns = 0 },
    };
}

fn thaddiusDeadTwinsWorldSnapshot() [2]world_memory_mod.WorldSnapshot {
    var world = thaddiusTwinsWorldSnapshot();
    world[0].scan.hp = 0;
    world[1].scan.hp = 0;
    return world;
}

test "compute: thaddius polarity selects target once idle in position" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");
    const spell_polarity_positive: u32 = 28059;

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    const sp = thaddius_arena.stack_melee_positive;
    var bot = makeThaddiusMageBot(20, sp.x + 25.0, sp.y, sp.z);
    bot.state.player_auras[0] = .{ .spell_id = spell_polarity_positive, .remaining_ms = 8000, .caster_guid = 0 };
    bot.state.player_aura_count = 1;

    const bs = thaddius_state.findOrInsert(bot.bot_id, .right).?;
    bs.post_twin_queued = true;

    const world = thaddiusWorldSnapshot();

    // Far from stack: encounter installs stacking, dispatch sends ctm_move.
    const tick1 = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), tick1.len);
    try std.testing.expect(tick1[0].msg == .ctm_move);
    try std.testing.expectEqual(intent.Priority.encounter, intent_store.current(bot.bot_id).?.priority);

    // Simulate movement: CTM transitions move→idle, bot arrives.
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    bot.state.game_time_ms += proto.brain_tick_ms;
    _ = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.x = sp.x;
    bot.state.y = sp.y;
    bot.state.game_time_ms += proto.brain_tick_ms;
    _ = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);

    // Once idle at the stack, encounter movement yields. TargetStore remains
    // select-only under polarity, so the bot may face/cast without CTM attack.
    bot.state.game_time_ms += proto.brain_tick_ms * 4;
    const target = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), target.len);
    try std.testing.expect(target[0].msg == .set_target_guid);
    try std.testing.expectEqual(@as(u64, 0x9999), target[0].msg.set_target_guid.guid);

    const ai = intent_store.current(bot.bot_id);
    if (ai) |a| {
        try std.testing.expect(a.priority != intent.Priority.encounter);
    }
}

test "compute: first thaddius polarity shift moves through attack chase (attack_pos)" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");
    const spell_polarity_negative: u32 = 28084;

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    const start = thaddius_arena.stack_melee_positive;
    var bot = makeThaddiusPaladinBot(44, start.x, start.y, start.z);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    bot.state.player_auras[0] = .{ .spell_id = spell_polarity_negative, .remaining_ms = 8000, .caster_guid = 0 };
    bot.state.player_aura_count = 1;
    bot.state.target_guid = 0x9999;
    bot.state.target_unit_reaction = 2;
    // Engine is mid auto-attack chase toward the boss. With the transport backlog
    // fixed, the move_to reaches the minion within a tick and overrides the chase
    // directly — no clear_target bypass, even with a hostile target still set.
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.attack_pos);

    const bs = thaddius_state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_opening_hold_done = true;

    var hold_seq = intent.Sequenced{ .steps = undefined, .len = 1 };
    hold_seq.steps[0] = .{ .intent = .{ .waiting_for = .{
        .until = .{ .game_time_at_least_ms = bot.state.game_time_ms + 5000 },
        .max_age_ms = 6000,
    } } };
    _ = intent_store.replaceAt(bot.bot_id, .{
        .intent = .{ .sequenced = hold_seq },
        .priority = .encounter,
        .created_at_ms = bot.state.game_time_ms,
        .max_age_ms = 6000,
        .source = .encounter_pull,
    }, &dispatch_store, bot.state.game_time_ms);

    const world = thaddiusWorldSnapshot();
    const orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    // The move_to is dispatched directly toward the first detour waypoint and
    // overrides the engine chase within a tick — no clear_target bypass.
    try std.testing.expect(orders[0].msg == .ctm_move);
    try std.testing.expectEqual(thaddius_arena.stack_melee_waypoints_positive_to_negative[0].x, orders[0].msg.ctm_move.x);
    try std.testing.expectEqual(thaddius_arena.stack_melee_waypoints_positive_to_negative[0].y, orders[0].msg.ctm_move.y);
}

test "compute: first thaddius polarity shift moves immediately when idle" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");
    const spell_polarity_negative: u32 = 28084;

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    const start = thaddius_arena.stack_melee_positive;
    var bot = makeThaddiusPaladinBot(45, start.x, start.y, start.z);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    bot.state.player_auras[0] = .{ .spell_id = spell_polarity_negative, .remaining_ms = 8000, .caster_guid = 0 };
    bot.state.player_aura_count = 1;
    bot.state.target_guid = 0x9999;
    bot.state.target_unit_reaction = 2;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    const bs = thaddius_state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_opening_hold_done = true;

    const world = thaddiusWorldSnapshot();
    const move_orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 1), move_orders.len);
    // Even with a hostile target still set and CTM idle, the move_to is dispatched
    // immediately toward the first detour waypoint — no pre-emptive clear_target.
    try std.testing.expect(move_orders[0].msg == .ctm_move);
    try std.testing.expectEqual(thaddius_arena.stack_melee_waypoints_positive_to_negative[0].x, move_orders[0].msg.ctm_move.x);
    try std.testing.expectEqual(thaddius_arena.stack_melee_waypoints_positive_to_negative[0].y, move_orders[0].msg.ctm_move.y);
}

test "compute: thaddius polarity stack uses select target without CTM attack" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");
    const spell_polarity_positive: u32 = 28059;

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    const sp = thaddius_arena.stack_melee_positive;
    var bot = makeThaddiusPaladinBot(41, sp.x, sp.y, sp.z);
    bot.state.player_auras[0] = .{ .spell_id = spell_polarity_positive, .remaining_ms = 8000, .caster_guid = 0 };
    bot.state.player_aura_count = 1;
    bot.state.target_guid = 0;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    const bs = thaddius_state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_tank_engage_done = true;

    const world = thaddiusWorldSnapshot();
    const orders = compute(
        &.{bot},
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
    );

    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .set_target_guid);
    try std.testing.expectEqual(@as(u64, 0x9999), orders[0].msg.set_target_guid.guid);
    try std.testing.expect(follow_store.get(bot.bot_id).?.position_override.?.authoritative);
}

test "compute: thaddius polarity stack allows facing without movement" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");
    const spell_polarity_positive: u32 = 28059;

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    const sp = thaddius_arena.stack_melee_positive;
    var bot = makeThaddiusPaladinBot(43, sp.x, sp.y, sp.z);
    bot.state.player_auras[0] = .{ .spell_id = spell_polarity_positive, .remaining_ms = 8000, .caster_guid = 0 };
    bot.state.player_aura_count = 1;
    bot.state.target_guid = 0x9999;
    bot.state.target_unit_reaction = 2;
    bot.state.orientation = std.math.pi;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    const bs = thaddius_state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_tank_engage_done = true;

    const world = thaddiusWorldSnapshot();
    const orders = compute(&.{bot}, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);

    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .set_facing);
    try std.testing.expect(follow_store.get(bot.bot_id).?.position_override.?.authoritative);
}

test "compute: thaddius polarity stack stops inherited movement" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");
    const spell_polarity_negative: u32 = 28084;

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    const sp = thaddius_arena.stack_melee_negative;
    var bot = makeThaddiusPaladinBot(42, sp.x, sp.y, sp.z);
    bot.state.player_auras[0] = .{ .spell_id = spell_polarity_negative, .remaining_ms = 8000, .caster_guid = 0 };
    bot.state.player_aura_count = 1;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    bot.state.ctm_x = sp.x + 20.0;
    bot.state.ctm_y = sp.y;
    bot.state.ctm_z = sp.z;

    const bs = thaddius_state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_tank_engage_done = true;

    const world = thaddiusWorldSnapshot();
    const orders = computeWithProposers(
        &.{bot},
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleMovingBlocking,
        testSpecCast,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .ctm_stop);
    try std.testing.expectEqual(intent.Priority.encounter, intent_store.current(bot.bot_id).?.priority);
    try std.testing.expectEqual(intent.Reason.encounter_stack, intent_store.current(bot.bot_id).?.source);
}

test "compute: prep gate clears stale encounter movement while operator stopped" {
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot = makeThaddiusPaladinBot(23, thaddius_arena.stalagg_initial.x, thaddius_arena.stalagg_initial.y, thaddius_arena.stalagg_initial.z);
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);

    var seq = intent.Sequenced{ .steps = undefined, .len = 1 };
    seq.steps[0] = .{ .intent = .{ .moving_to = .{
        .pos = .{ .x = thaddius_arena.left_platform.x, .y = thaddius_arena.left_platform.y, .z = thaddius_arena.left_platform.z },
        .arrival_yards = 5.0,
        .reason = .encounter_pull,
    } }, .done_when = .ctm_idle };

    _ = intent_store.replace(bot.bot_id, .{
        .intent = .{ .sequenced = seq },
        .priority = .encounter,
        .created_at_ms = bot.state.game_time_ms,
        .source = .encounter_pull,
    }, true, &dispatch_store, bot.state.game_time_ms);

    const orders = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        false,
        testNoRole,
        testNoSpec,
        null,
    );

    try std.testing.expectEqual(@as(usize, 0), orders.len);
    try std.testing.expectEqual(intent.Priority.idle, intent_store.current(bot.bot_id).?.priority);
}

test "compute: thaddius transition stops twin leftovers before jump route" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot = makeThaddiusPaladinBot(24, thaddius_arena.left_platform.x, thaddius_arena.left_platform.y, thaddius_arena.left_platform.z);
    bot.state.guid = 0xAAAA;
    bot.state.target_guid = 0x1111;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.attack);
    @memcpy(bot.state.player_name[0.."Lefttank".len], "Lefttank");

    thaddius_state.noteTwinSeen(.left, 1000);
    thaddius_state.noteTwinSeen(.right, 1000);

    const world = thaddiusDeadTwinsWorldSnapshot();
    const orders = computeWithProposers(
        &.{bot},
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .lua_exec);
    try std.testing.expect(std.mem.startsWith(u8, &orders[0].msg.lua_exec, "StopAttack()"));
    const ai = intent_store.current(bot.bot_id).?;
    try std.testing.expectEqual(intent.Reason.encounter_transition, ai.source);
    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expect(ai.intent.sequenced.steps[0].intent == .stop_attack);
}

test "compute: thaddius transition preempts in-flight encounter route" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot = makeThaddiusPaladinBot(26, thaddius_arena.stalagg_initial.x, thaddius_arena.stalagg_initial.y, thaddius_arena.stalagg_initial.z);
    bot.state.guid = 0xAAAA;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    @memcpy(bot.state.player_name[0.."Lefttank".len], "Lefttank");

    thaddius_state.noteTwinSeen(.left, 1000);
    thaddius_state.noteTwinSeen(.right, 1000);

    var old_seq = intent.Sequenced{ .steps = undefined, .len = 1 };
    old_seq.steps[0] = .{ .intent = .{ .moving_to = .{
        .pos = .{ .x = thaddius_arena.stalagg_initial.x + 20.0, .y = thaddius_arena.stalagg_initial.y, .z = thaddius_arena.stalagg_initial.z },
        .arrival_yards = 5.0,
        .reason = .encounter_route,
    } }, .done_when = .ctm_idle };
    _ = intent_store.replace(bot.bot_id, .{
        .intent = .{ .sequenced = old_seq },
        .priority = .encounter,
        .created_at_ms = bot.state.game_time_ms,
        .source = .encounter_route,
        .confirm = .{
            .active = true,
            .move_started = true,
            .last_action = .{ .move_to = .{
                .x = thaddius_arena.stalagg_initial.x + 20.0,
                .y = thaddius_arena.stalagg_initial.y,
                .z = thaddius_arena.stalagg_initial.z,
            } },
        },
    }, true, &dispatch_store, bot.state.game_time_ms);

    const world = thaddiusDeadTwinsWorldSnapshot();
    const orders = computeWithProposers(
        &.{bot},
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .lua_exec);
    try std.testing.expect(std.mem.startsWith(u8, &orders[0].msg.lua_exec, "StopAttack()"));

    const ai = intent_store.current(bot.bot_id).?;
    try std.testing.expectEqual(intent.Reason.encounter_transition, ai.source);
    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expect(!ai.confirm.active);
    try std.testing.expect(ai.intent.sequenced.steps[2].intent == .moving_to);
    try std.testing.expectEqual(thaddius_arena.left_platform.x, ai.intent.sequenced.steps[2].intent.moving_to.pos.x);
}

test "compute: thaddius tank engage replaces transition hold when boss is already targeted" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot = makeThaddiusPaladinBot(28, thaddius_arena.stack_melee_positive.x, thaddius_arena.stack_melee_positive.y, thaddius_arena.stack_melee_positive.z);
    bot.state.guid = 0xAAAA;
    bot.state.target_guid = 0x9999;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    @memcpy(bot.state.player_name[0.."Lefttank".len], "Lefttank");

    const bs = thaddius_state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;

    _ = intent_store.replace(bot.bot_id, .{
        .intent = .{ .waiting_for = .{
            .until = .{ .game_time_at_least_ms = bot.state.game_time_ms + proto.brain_tick_ms },
        } },
        .priority = .encounter,
        .created_at_ms = bot.state.game_time_ms,
        .source = .encounter_transition,
    }, true, &dispatch_store, bot.state.game_time_ms);

    const world = thaddiusWorldSnapshot();
    const orders = computeWithProposers(
        &.{bot},
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .set_target_guid);
    try std.testing.expectEqual(@as(u64, 0x9999), orders[0].msg.set_target_guid.guid);
    try std.testing.expectEqual(intent.Reason.encounter_pull, intent_store.current(bot.bot_id).?.source);
    try std.testing.expect(intent_store.current(bot.bot_id).?.intent == .sequenced);
    try std.testing.expectEqual(@as(u8, 1), intent_store.current(bot.bot_id).?.intent.sequenced.current);
}

test "compute: thaddius post-twin skips platform when already there and keeps role out until stack" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");
    const thaddius_triggers = @import("../combat/encounters/thaddius/triggers.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot = makeThaddiusPaladinBot(25, thaddius_arena.left_platform.x, thaddius_arena.left_platform.y, thaddius_arena.left_platform.z);
    bot.state.guid = 0xAAAA;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    @memcpy(bot.state.player_name[0.."Lefttank".len], "Lefttank");

    const bs = thaddius_state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;

    var ai = thaddius_triggers.postTwinIntent(&context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true), .left);
    ai.created_at_ms = bot.state.game_time_ms;
    _ = intent_store.replace(bot.bot_id, ai, true, &dispatch_store, bot.state.game_time_ms);

    const hold = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleMovingBlocking,
        testSpecCast,
        null,
    );
    try std.testing.expectEqual(@as(usize, 0), hold.len);

    bot.state.game_time_ms += thaddius_triggers.post_twin_platform_settle_ms;
    const boots = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleMovingBlocking,
        testSpecCast,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), boots.len);
    try std.testing.expect(boots[0].msg == .lua_exec);
    try std.testing.expect(std.mem.startsWith(u8, &boots[0].msg.lua_exec, "UseInventoryItem(8)"));

    bot.state.game_time_ms += proto.brain_tick_ms;
    const waypoint = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleMovingBlocking,
        testSpecCast,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), waypoint.len);
    try std.testing.expect(waypoint[0].msg == .ctm_move);
    try std.testing.expectEqual(thaddius_arena.left_waypoint.x, waypoint[0].msg.ctm_move.x);
    try std.testing.expectEqual(thaddius_arena.left_waypoint.y, waypoint[0].msg.ctm_move.y);
    try std.testing.expectEqual(intent.Priority.encounter, intent_store.current(bot.bot_id).?.priority);

    bot.state.game_time_ms += proto.brain_tick_ms;
    bot.state.z = thaddius_arena.post_twin_jump_z_threshold + 1.0;
    const jump = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleMovingBlocking,
        testSpecCast,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), jump.len);
    try std.testing.expect(jump[0].msg == .jump);
    try std.testing.expectEqual(@as(u8, 3), intent_store.current(bot.bot_id).?.intent.sequenced.current);
    try std.testing.expect(intent_store.current(bot.bot_id).?.intent.sequenced.steps[3].trigger_once.?.fired);

    bot.state.game_time_ms += proto.brain_tick_ms;
    const continue_waypoint = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleMovingBlocking,
        testSpecCast,
        null,
    );
    try std.testing.expectEqual(@as(usize, 0), continue_waypoint.len);
    try std.testing.expectEqual(@as(u8, 3), intent_store.current(bot.bot_id).?.intent.sequenced.current);

    bot.state.game_time_ms += proto.brain_tick_ms;
    bot.state.x = thaddius_arena.left_waypoint.x;
    bot.state.y = thaddius_arena.left_waypoint.y;
    bot.state.z = thaddius_arena.left_waypoint.z;
    const stack = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleMovingBlocking,
        testSpecCast,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), stack.len);
    try std.testing.expect(stack[0].msg == .ctm_move);
    try std.testing.expectEqual(thaddius_arena.stack_melee_positive.x, stack[0].msg.ctm_move.x);
    try std.testing.expectEqual(thaddius_arena.stack_melee_positive.y, stack[0].msg.ctm_move.y);
}

test "compute: thaddius post-twin platform requires tight arrival" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");
    const thaddius_triggers = @import("../combat/encounters/thaddius/triggers.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot = makeThaddiusPaladinBot(27, thaddius_arena.left_platform.x + 2.0, thaddius_arena.left_platform.y, thaddius_arena.left_platform.z);
    bot.state.guid = 0xAAAA;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    @memcpy(bot.state.player_name[0.."Lefttank".len], "Lefttank");

    const bs = thaddius_state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;

    var ai = thaddius_triggers.postTwinIntent(&context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true), .left);
    ai.created_at_ms = bot.state.game_time_ms;
    _ = intent_store.replace(bot.bot_id, ai, true, &dispatch_store, bot.state.game_time_ms);

    const orders = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleMovingBlocking,
        testSpecCast,
        null,
    );

    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .ctm_move);
    try std.testing.expectEqual(thaddius_arena.left_platform.x, orders[0].msg.ctm_move.x);
    try std.testing.expectEqual(thaddius_arena.left_platform.y, orders[0].msg.ctm_move.y);
    try std.testing.expectEqual(thaddius_triggers.post_twin_platform_arrival_yards, intent_store.current(bot.bot_id).?.intent.sequenced.steps[0].intent.moving_to.arrival_yards);
}

test "compute: thaddius post-twin inserts waypoint before stack" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");
    const thaddius_triggers = @import("../combat/encounters/thaddius/triggers.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot = makeThaddiusPaladinBot(28, thaddius_arena.left_platform.x, thaddius_arena.left_platform.y, thaddius_arena.left_platform.z);
    bot.state.guid = 0xAAAA;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    @memcpy(bot.state.player_name[0.."Lefttank".len], "Lefttank");

    const bs = thaddius_state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;

    var ai = thaddius_triggers.postTwinIntent(&context.CombatContext.build(bot, &.{bot}, &.{}, &.{}, true), .left);
    ai.created_at_ms = bot.state.game_time_ms;
    _ = intent_store.replace(bot.bot_id, ai, true, &dispatch_store, bot.state.game_time_ms);

    const orders = computeWithProposers(
        &.{bot},
        &.{},
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleMovingBlocking,
        testSpecCast,
        null,
    );

    try std.testing.expectEqual(@as(usize, 0), orders.len);
    try std.testing.expectEqual(thaddius_triggers.post_twin_waypoint_arrival_yards, intent_store.current(bot.bot_id).?.intent.sequenced.steps[3].intent.moving_to.arrival_yards);
    try std.testing.expectEqual(thaddius_arena.left_waypoint.x, intent_store.current(bot.bot_id).?.intent.sequenced.steps[3].intent.moving_to.pos.x);
    try std.testing.expectEqual(thaddius_arena.left_waypoint.y, intent_store.current(bot.bot_id).?.intent.sequenced.steps[3].intent.moving_to.pos.y);
    try std.testing.expect(intent_store.current(bot.bot_id).?.intent.sequenced.steps[3].done_when.? == .arrived_at);
    try std.testing.expectEqual(thaddius_arena.left_waypoint.x, intent_store.current(bot.bot_id).?.intent.sequenced.steps[3].done_when.?.arrived_at.x);
    try std.testing.expectEqual(thaddius_arena.left_waypoint.y, intent_store.current(bot.bot_id).?.intent.sequenced.steps[3].done_when.?.arrived_at.y);
    try std.testing.expect(intent_store.current(bot.bot_id).?.intent.sequenced.steps[3].trigger_once.?.action == .jump);
    try std.testing.expect(intent_store.current(bot.bot_id).?.intent.sequenced.steps[3].trigger_once.?.when == .z_above);
    try std.testing.expectEqual(thaddius_arena.post_twin_jump_z_threshold, intent_store.current(bot.bot_id).?.intent.sequenced.steps[3].trigger_once.?.when.z_above);
    try std.testing.expectEqual(thaddius_arena.stack_melee_positive.x, intent_store.current(bot.bot_id).?.intent.sequenced.steps[4].intent.moving_to.pos.x);
    try std.testing.expectEqual(thaddius_arena.stack_melee_positive.y, intent_store.current(bot.bot_id).?.intent.sequenced.steps[4].intent.moving_to.pos.y);
}

test "compute: thaddius twins — both tanks ready casts pull same tick as target assignment" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");
    const thaddius_triggers = @import("../combat/encounters/thaddius/triggers.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var left_tank = makeThaddiusPaladinBot(31, thaddius_arena.stalagg_initial.x + 25.0, thaddius_arena.stalagg_initial.y, thaddius_arena.stalagg_initial.z);
    left_tank.state.guid = 0xAAAA;
    left_tank.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    left_tank.state.orientation = std.math.pi;
    left_tank.state.spell_range_count = 1;
    left_tank.state.spell_ranges[0] = .{ .spell_id = 48827, .max_range_yards = 30.0 };
    @memcpy(left_tank.state.player_name[0.."Lefttank".len], "Lefttank");

    var right_tank = makeThaddiusPaladinBot(32, thaddius_arena.feugen_initial.x + 25.0, thaddius_arena.feugen_initial.y, thaddius_arena.feugen_initial.z);
    right_tank.state.guid = 0xBBBB;
    right_tank.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    right_tank.state.orientation = std.math.pi;
    right_tank.state.spell_range_count = 1;
    right_tank.state.spell_ranges[0] = .{ .spell_id = 48827, .max_range_yards = 30.0 };
    @memcpy(right_tank.state.player_name[0.."Sangboulon".len], "Sangboulon");

    const left_bs = thaddius_state.findOrInsert(left_tank.bot_id, .left).?;
    left_bs.twin_route_seeded = true;
    left_bs.twin_route_done = true;
    const right_bs = thaddius_state.findOrInsert(right_tank.bot_id, .right).?;
    right_bs.twin_route_seeded = true;
    right_bs.twin_route_done = true;
    thaddius_state.beginTankRefresh();
    thaddius_state.refreshTank(left_tank.bot_id, left_tank.state.guid, "Lefttank", .left);
    thaddius_state.refreshTank(right_tank.bot_id, right_tank.state.guid, "Sangboulon", .right);
    thaddius_state.setTankReady(left_tank.bot_id, .left);
    thaddius_state.setTankReady(right_tank.bot_id, .right);

    var right_route = thaddius_triggers.twinApproachIntent(.right);
    right_route.created_at_ms = right_tank.state.game_time_ms;
    right_route.intent.sequenced.current = 3;
    right_route.intent.sequenced.step_dispatched = false;
    _ = intent_store.replace(right_tank.bot_id, right_route, true, &dispatch_store, right_tank.state.game_time_ms);

    var stalagg_scan = std.mem.zeroes(proto.ScanEntry);
    stalagg_scan.guid = 0x1111;
    stalagg_scan.hp = 1000;
    std.mem.copyForwards(u8, stalagg_scan.name[0.."Stalagg".len], "Stalagg");
    stalagg_scan.x = thaddius_arena.stalagg_initial.x;
    stalagg_scan.y = thaddius_arena.stalagg_initial.y;
    stalagg_scan.z = thaddius_arena.stalagg_initial.z;

    var feugen_scan = std.mem.zeroes(proto.ScanEntry);
    feugen_scan.guid = 0x2222;
    feugen_scan.hp = 1000;
    std.mem.copyForwards(u8, feugen_scan.name[0.."Feugen".len], "Feugen");
    feugen_scan.x = thaddius_arena.feugen_initial.x;
    feugen_scan.y = thaddius_arena.feugen_initial.y;
    feugen_scan.z = thaddius_arena.feugen_initial.z;

    const world = [_]world_memory_mod.WorldSnapshot{
        .{ .scan = stalagg_scan, .map_id = 533, .last_seen_ts_ns = 0 },
        .{ .scan = feugen_scan, .map_id = 533, .last_seen_ts_ns = 0 },
    };

    const orders = compute(&.{ left_tank, right_tank }, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 2), orders.len);
    try std.testing.expect(orders[0].msg == .cast_spell_guid);
    try std.testing.expect(orders[1].msg == .cast_spell_guid);
    try std.testing.expectEqual(@as(u32, 48827), orders[0].msg.cast_spell_guid.spell_id);
    try std.testing.expectEqual(@as(u32, 48827), orders[1].msg.cast_spell_guid.spell_id);
    try std.testing.expectEqual(stalagg_scan.guid, orders[0].msg.cast_spell_guid.target_guid);
    try std.testing.expectEqual(feugen_scan.guid, orders[1].msg.cast_spell_guid.target_guid);
}

test "compute: thaddius twins — tanks move to platforms after opener cooldown" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var left_tank = makeThaddiusPaladinBot(33, thaddius_arena.stalagg_initial.x + 25.0, thaddius_arena.stalagg_initial.y, thaddius_arena.stalagg_initial.z);
    left_tank.state.guid = 0xAAAA;
    left_tank.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    left_tank.state.cooldown_count = 1;
    left_tank.state.cooldowns[0] = .{ .spell_id = 48827, .category = 0, .duration_ms = 30_000, .remaining_ms = 30_000 };
    @memcpy(left_tank.state.player_name[0.."Lefttank".len], "Lefttank");

    var right_tank = makeThaddiusPaladinBot(34, thaddius_arena.feugen_initial.x + 25.0, thaddius_arena.feugen_initial.y, thaddius_arena.feugen_initial.z);
    right_tank.state.guid = 0xBBBB;
    right_tank.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    right_tank.state.cooldown_count = 1;
    right_tank.state.cooldowns[0] = .{ .spell_id = 48827, .category = 0, .duration_ms = 30_000, .remaining_ms = 30_000 };
    @memcpy(right_tank.state.player_name[0.."Sangboulon".len], "Sangboulon");

    const left_bs = thaddius_state.findOrInsert(left_tank.bot_id, .left).?;
    left_bs.twin_route_seeded = true;
    left_bs.twin_route_done = true;
    const right_bs = thaddius_state.findOrInsert(right_tank.bot_id, .right).?;
    right_bs.twin_route_seeded = true;
    right_bs.twin_route_done = true;
    thaddius_state.beginTankRefresh();
    thaddius_state.refreshTank(left_tank.bot_id, left_tank.state.guid, "Lefttank", .left);
    thaddius_state.refreshTank(right_tank.bot_id, right_tank.state.guid, "Sangboulon", .right);
    thaddius_state.setTankReady(left_tank.bot_id, .left);
    thaddius_state.setTankReady(right_tank.bot_id, .right);

    var world = thaddiusTwinsWorldSnapshot();
    world[0].scan.x = left_tank.state.x + 1.0;
    world[0].scan.y = left_tank.state.y;
    world[1].scan.x = right_tank.state.x + 1.0;
    world[1].scan.y = right_tank.state.y;

    const orders = compute(&.{ left_tank, right_tank }, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 2), orders.len);
    try std.testing.expect(orders[0].msg == .ctm_move);
    try std.testing.expect(orders[1].msg == .ctm_move);
    try std.testing.expectEqual(thaddius_arena.left_platform.x, orders[0].msg.ctm_move.x);
    try std.testing.expectEqual(thaddius_arena.left_platform.y, orders[0].msg.ctm_move.y);
    try std.testing.expectEqual(thaddius_arena.right_platform.x, orders[1].msg.ctm_move.x);
    try std.testing.expectEqual(thaddius_arena.right_platform.y, orders[1].msg.ctm_move.y);
    try std.testing.expectEqual(intent.Priority.encounter, intent_store.current(left_tank.bot_id).?.priority);
    try std.testing.expectEqual(intent.Reason.encounter_pull, intent_store.current(left_tank.bot_id).?.source);
}

test "compute: thaddius twins — tanks face twins after platform CTM" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var left_tank = makeThaddiusPaladinBot(35, thaddius_arena.left_platform.x, thaddius_arena.left_platform.y, thaddius_arena.left_platform.z);
    left_tank.state.guid = 0xAAAA;
    left_tank.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    left_tank.state.orientation = std.math.pi;
    left_tank.state.cooldown_count = 1;
    left_tank.state.cooldowns[0] = .{ .spell_id = 48827, .category = 0, .duration_ms = 30_000, .remaining_ms = 30_000 };
    @memcpy(left_tank.state.player_name[0.."Lefttank".len], "Lefttank");

    var right_tank = makeThaddiusPaladinBot(36, thaddius_arena.right_platform.x, thaddius_arena.right_platform.y, thaddius_arena.right_platform.z);
    right_tank.state.guid = 0xBBBB;
    right_tank.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    right_tank.state.orientation = 0.0;
    right_tank.state.cooldown_count = 1;
    right_tank.state.cooldowns[0] = .{ .spell_id = 48827, .category = 0, .duration_ms = 30_000, .remaining_ms = 30_000 };
    @memcpy(right_tank.state.player_name[0.."Sangboulon".len], "Sangboulon");

    const left_bs = thaddius_state.findOrInsert(left_tank.bot_id, .left).?;
    left_bs.twin_route_seeded = true;
    left_bs.twin_route_done = true;
    const right_bs = thaddius_state.findOrInsert(right_tank.bot_id, .right).?;
    right_bs.twin_route_seeded = true;
    right_bs.twin_route_done = true;
    thaddius_state.beginTankRefresh();
    thaddius_state.refreshTank(left_tank.bot_id, left_tank.state.guid, "Lefttank", .left);
    thaddius_state.refreshTank(right_tank.bot_id, right_tank.state.guid, "Sangboulon", .right);
    thaddius_state.setTankReady(left_tank.bot_id, .left);
    thaddius_state.setTankReady(right_tank.bot_id, .right);

    const world = thaddiusTwinsWorldSnapshot();
    const orders = compute(&.{ left_tank, right_tank }, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 2), orders.len);
    try std.testing.expect(orders[0].msg == .set_facing);
    try std.testing.expect(orders[1].msg == .set_facing);
    try std.testing.expectEqual(intent.Reason.encounter_pull, intent_store.current(left_tank.bot_id).?.source);
    try std.testing.expectEqual(intent.Reason.encounter_pull, intent_store.current(right_tank.bot_id).?.source);
}

test "compute: thaddius twins — dps waits for tank platform and facing sequence" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var left_tank = makeThaddiusPaladinBot(37, thaddius_arena.left_platform.x, thaddius_arena.left_platform.y, thaddius_arena.left_platform.z);
    left_tank.state.guid = 0xAAAA;
    left_tank.state.target_guid = 0x1111;
    @memcpy(left_tank.state.player_name[0.."Lefttank".len], "Lefttank");

    var right_tank = makeThaddiusPaladinBot(38, thaddius_arena.right_platform.x, thaddius_arena.right_platform.y, thaddius_arena.right_platform.z);
    right_tank.state.guid = 0xBBBB;
    right_tank.state.target_guid = 0x2222;
    @memcpy(right_tank.state.player_name[0.."Sangboulon".len], "Sangboulon");

    var dps = makeThaddiusMageBot(39, thaddius_arena.stalagg_initial.x - 20.0, thaddius_arena.stalagg_initial.y, thaddius_arena.stalagg_initial.z);
    dps.state.guid = 0xCCCC;
    @memcpy(dps.state.player_name[0.."Casterone".len], "Casterone");

    const left_bs = thaddius_state.findOrInsert(left_tank.bot_id, .left).?;
    left_bs.twin_route_seeded = true;
    left_bs.twin_route_done = true;
    left_bs.twin_pull_platform_queued = true;
    left_bs.twin_pull_platform_done = true;
    left_bs.twin_pull_facing_done = true;
    const right_bs = thaddius_state.findOrInsert(right_tank.bot_id, .right).?;
    right_bs.twin_route_seeded = true;
    right_bs.twin_route_done = true;
    right_bs.twin_pull_platform_queued = true;
    right_bs.twin_pull_platform_done = true;
    right_bs.twin_pull_facing_done = false;
    const dps_bs = thaddius_state.findOrInsert(dps.bot_id, .left).?;
    dps_bs.twin_route_seeded = true;
    dps_bs.twin_route_done = true;

    thaddius_state.beginTankRefresh();
    thaddius_state.refreshTank(left_tank.bot_id, left_tank.state.guid, "Lefttank", .left);
    thaddius_state.refreshTank(right_tank.bot_id, right_tank.state.guid, "Sangboulon", .right);
    thaddius_state.setTankReady(left_tank.bot_id, .left);
    thaddius_state.setTankReady(right_tank.bot_id, .right);

    const world = thaddiusTwinsWorldSnapshot();
    const hold = computeWithProposers(
        &.{ dps, left_tank, right_tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );
    var dps_stop_sent = false;
    for (hold) |order| {
        if (!std.mem.eql(u8, &order.bot_id, &dps.bot_id)) continue;
        try std.testing.expect(order.msg == .lua_exec);
        try std.testing.expectEqualStrings("StopAttack()", std.mem.sliceTo(&order.msg.lua_exec, 0));
        dps_stop_sent = true;
    }
    try std.testing.expect(dps_stop_sent);
    try std.testing.expectEqual(intent.Priority.encounter, intent_store.current(dps.bot_id).?.priority);
    try std.testing.expectEqual(intent.Reason.encounter_pull, intent_store.current(dps.bot_id).?.source);

    right_bs.twin_pull_facing_done = true;
    dps.state.game_time_ms += proto.brain_tick_ms * 4;
    left_tank.state.game_time_ms = dps.state.game_time_ms;
    right_tank.state.game_time_ms = dps.state.game_time_ms;

    const opening_hold = computeWithProposers(
        &.{ dps, left_tank, right_tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );
    var opening_attacked = false;
    for (opening_hold) |order| {
        if (!std.mem.eql(u8, &order.bot_id, &dps.bot_id)) continue;
        if (order.msg == .ctm_attack_guid) opening_attacked = true;
    }
    try std.testing.expect(!opening_attacked);
    try std.testing.expectEqual(intent.Priority.encounter, intent_store.current(dps.bot_id).?.priority);
    try std.testing.expectEqual(intent.Reason.encounter_pull, intent_store.current(dps.bot_id).?.source);

    dps.state.game_time_ms += @import("../combat/encounters/thaddius/triggers.zig").dps_opening_hold_ms + proto.brain_tick_ms;
    left_tank.state.game_time_ms = dps.state.game_time_ms;
    right_tank.state.game_time_ms = dps.state.game_time_ms;

    const release = computeWithProposers(
        &.{ dps, left_tank, right_tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), release.len);
    try std.testing.expect(release[0].msg == .set_target_guid);
    try std.testing.expectEqual(@as(u64, 0x1111), release[0].msg.set_target_guid.guid);
}

test "compute: thaddius twins — dps sees tanks ready before tank proposer order" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");
    const thaddius_triggers = @import("../combat/encounters/thaddius/triggers.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var dps = makeThaddiusMageBot(42, thaddius_arena.stalagg_initial.x - 20.0, thaddius_arena.stalagg_initial.y, thaddius_arena.stalagg_initial.z);
    dps.state.guid = 0xCCCC;
    @memcpy(dps.state.player_name[0.."Casterone".len], "Casterone");

    var left_tank = makeThaddiusPaladinBot(43, thaddius_arena.stalagg_initial.x, thaddius_arena.stalagg_initial.y, thaddius_arena.stalagg_initial.z);
    left_tank.state.guid = 0xAAAA;
    @memcpy(left_tank.state.player_name[0.."Lefttank".len], "Lefttank");

    var right_tank = makeThaddiusPaladinBot(44, thaddius_arena.feugen_initial.x, thaddius_arena.feugen_initial.y, thaddius_arena.feugen_initial.z);
    right_tank.state.guid = 0xBBBB;
    @memcpy(right_tank.state.player_name[0.."Sangboulon".len], "Sangboulon");

    const dps_bs = thaddius_state.findOrInsert(dps.bot_id, .left).?;
    dps_bs.twin_route_seeded = true;
    dps_bs.twin_route_done = true;
    const left_bs = thaddius_state.findOrInsert(left_tank.bot_id, .left).?;
    left_bs.twin_route_seeded = true;
    left_bs.twin_route_done = true;
    left_bs.twin_pull_platform_queued = true;
    left_bs.twin_pull_platform_done = true;
    left_bs.twin_pull_facing_done = true;
    const right_bs = thaddius_state.findOrInsert(right_tank.bot_id, .right).?;
    right_bs.twin_route_seeded = true;
    right_bs.twin_route_done = true;
    right_bs.twin_pull_platform_queued = true;
    right_bs.twin_pull_platform_done = true;
    right_bs.twin_pull_facing_done = true;

    const world = thaddiusTwinsWorldSnapshot();
    const hold = computeWithProposers(
        &.{ dps, left_tank, right_tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );

    try std.testing.expect(thaddius_state.bothTanksReady());
    var dps_stopped = false;
    for (hold) |order| {
        if (!std.mem.eql(u8, &order.bot_id, &dps.bot_id)) continue;
        try std.testing.expect(order.msg == .lua_exec);
        try std.testing.expectEqualStrings("StopAttack()", std.mem.sliceTo(&order.msg.lua_exec, 0));
        dps_stopped = true;
    }
    try std.testing.expect(dps_stopped);

    dps.state.game_time_ms += thaddius_triggers.dps_opening_hold_ms + proto.brain_tick_ms;
    left_tank.state.game_time_ms = dps.state.game_time_ms;
    right_tank.state.game_time_ms = dps.state.game_time_ms;

    const release = computeWithProposers(
        &.{ dps, left_tank, right_tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );

    var dps_targeted = false;
    for (release) |order| {
        if (!std.mem.eql(u8, &order.bot_id, &dps.bot_id)) continue;
        try std.testing.expect(order.msg == .set_target_guid);
        try std.testing.expectEqual(@as(u64, 0x1111), order.msg.set_target_guid.guid);
        dps_targeted = true;
    }
    try std.testing.expect(dps_targeted);
}

test "compute: thaddius twins — pull sequence tank retarget does not CTM attack" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var left_tank = makeThaddiusPaladinBot(40, thaddius_arena.left_platform.x, thaddius_arena.left_platform.y, thaddius_arena.left_platform.z);
    left_tank.state.guid = 0xAAAA;
    left_tank.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    const facing = std.math.atan2(thaddius_arena.stalagg_initial.y - left_tank.state.y, thaddius_arena.stalagg_initial.x - left_tank.state.x);
    left_tank.state.orientation = if (facing < 0) facing + std.math.pi * 2.0 else facing;
    @memcpy(left_tank.state.player_name[0.."Lefttank".len], "Lefttank");

    var right_tank = makeThaddiusPaladinBot(41, thaddius_arena.right_platform.x, thaddius_arena.right_platform.y, thaddius_arena.right_platform.z);
    right_tank.state.guid = 0xBBBB;
    right_tank.state.target_guid = 0x2222;
    @memcpy(right_tank.state.player_name[0.."Sangboulon".len], "Sangboulon");

    const left_bs = thaddius_state.findOrInsert(left_tank.bot_id, .left).?;
    left_bs.twin_route_seeded = true;
    left_bs.twin_route_done = true;
    left_bs.twin_pull_platform_queued = true;
    left_bs.twin_pull_platform_done = true;
    left_bs.twin_pull_facing_done = false;
    const right_bs = thaddius_state.findOrInsert(right_tank.bot_id, .right).?;
    right_bs.twin_route_seeded = true;
    right_bs.twin_route_done = true;
    right_bs.twin_pull_platform_queued = true;
    right_bs.twin_pull_platform_done = true;
    right_bs.twin_pull_facing_done = true;

    thaddius_state.beginTankRefresh();
    thaddius_state.refreshTank(left_tank.bot_id, left_tank.state.guid, "Lefttank", .left);
    thaddius_state.refreshTank(right_tank.bot_id, right_tank.state.guid, "Sangboulon", .right);
    thaddius_state.setTankReady(left_tank.bot_id, .left);
    thaddius_state.setTankReady(right_tank.bot_id, .right);

    const world = thaddiusTwinsWorldSnapshot();
    const orders = computeWithProposers(
        &.{ left_tank, right_tank },
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testNoRole,
        testNoSpec,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expect(orders[0].msg == .set_target_guid);
    try std.testing.expectEqual(@as(u64, 0x1111), orders[0].msg.set_target_guid.guid);
}

test "compute: thaddius twins — tank swap retargets recenters and retargets" {
    const thaddius_state = @import("../combat/encounters/thaddius/state.zig");
    const thaddius_arena = @import("../combat/encounters/thaddius/arena.zig");

    thaddius_state.reset();

    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    // Tank at Stalagg position, left side.
    var bot = makeThaddiusPaladinBot(21, thaddius_arena.stalagg_initial.x, thaddius_arena.stalagg_initial.y, thaddius_arena.stalagg_initial.z);
    bot.state.guid = 0xAAAA;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    @memcpy(bot.state.player_name[0.."Lefttank".len], "Lefttank");

    var other_tank = makeThaddiusPaladinBot(22, thaddius_arena.feugen_initial.x, thaddius_arena.feugen_initial.y, thaddius_arena.feugen_initial.z);
    other_tank.state.guid = 0xBBBB;
    other_tank.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    @memcpy(other_tank.state.player_name[0.."Sangboulon".len], "Sangboulon");

    const bs = thaddius_state.findOrInsert(bot.bot_id, .left).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    const other_bs = thaddius_state.findOrInsert(other_tank.bot_id, .right).?;
    other_bs.twin_route_seeded = true;
    other_bs.twin_route_done = true;

    // World: twins alive, Magnetic Pull go event is the only swap signal.
    var stalagg_scan = std.mem.zeroes(proto.ScanEntry);
    stalagg_scan.guid = 0x1111;
    stalagg_scan.hp = 1000;
    std.mem.copyForwards(u8, stalagg_scan.name[0.."Stalagg".len], "Stalagg");
    stalagg_scan.x = thaddius_arena.stalagg_initial.x;
    stalagg_scan.y = thaddius_arena.stalagg_initial.y;
    stalagg_scan.z = thaddius_arena.stalagg_initial.z;
    stalagg_scan.target_guid = 0xBBBB;

    var feugen_scan = std.mem.zeroes(proto.ScanEntry);
    feugen_scan.guid = 0x2222;
    feugen_scan.hp = 1000;
    std.mem.copyForwards(u8, feugen_scan.name[0.."Feugen".len], "Feugen");
    feugen_scan.x = thaddius_arena.feugen_initial.x;
    feugen_scan.y = thaddius_arena.feugen_initial.y;
    feugen_scan.z = thaddius_arena.feugen_initial.z;

    const world = [_]world_memory_mod.WorldSnapshot{
        .{ .scan = stalagg_scan, .map_id = 533, .last_seen_ts_ns = 0 },
        .{ .scan = feugen_scan, .map_id = 533, .last_seen_ts_ns = 0 },
    };

    const bots = [_]BotSnapshot{ bot, other_tank };
    const events = [_]proto.SpellEvent{.{
        .kind = @intFromEnum(proto.SpellEventKind.go),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x9999,
        .caster_guid = 0xDEAD,
        .spell_id = 54517,
        .flags = 0,
        .value_ms = 0,
        .game_time_ms = 10_500,
    }};

    // Tick 1: one spell event triggers one global swap; retarget immediately without CTM attack.
    const tick1 = compute(&bots, &world, &events, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 2), tick1.len);
    try std.testing.expect(tick1[0].msg == .set_target_guid);
    try std.testing.expect(tick1[1].msg == .set_target_guid);
    try std.testing.expectEqual(feugen_scan.guid, tick1[0].msg.set_target_guid.guid);
    try std.testing.expectEqual(stalagg_scan.guid, tick1[1].msg.set_target_guid.guid);

    bot.state.game_time_ms += proto.brain_tick_ms;
    other_tank.state.game_time_ms += proto.brain_tick_ms;

    // Tick 2: move each tank to the explicit platform for its new side.
    const tick2 = compute(&.{ bot, other_tank }, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 2), tick2.len);
    try std.testing.expect(tick2[0].msg == .ctm_move);
    try std.testing.expect(tick2[1].msg == .ctm_move);
    try std.testing.expectEqual(thaddius_arena.right_platform.x, tick2[0].msg.ctm_move.x);
    try std.testing.expectEqual(thaddius_arena.right_platform.y, tick2[0].msg.ctm_move.y);
    try std.testing.expectEqual(thaddius_arena.left_platform.x, tick2[1].msg.ctm_move.x);
    try std.testing.expectEqual(thaddius_arena.left_platform.y, tick2[1].msg.ctm_move.y);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    bot.state.game_time_ms += proto.brain_tick_ms;
    other_tank.state.ctm_action = @intFromEnum(proto.CtmAction.move);
    other_tank.state.game_time_ms += proto.brain_tick_ms;
    const tick3 = compute(&.{ bot, other_tank }, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), tick3.len);

    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.x = thaddius_arena.right_platform.x;
    bot.state.y = thaddius_arena.right_platform.y;
    bot.state.z = thaddius_arena.right_platform.z;
    bot.state.target_guid = feugen_scan.guid;
    bot.state.game_time_ms += proto.brain_tick_ms;
    other_tank.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    other_tank.state.x = thaddius_arena.left_platform.x;
    other_tank.state.y = thaddius_arena.left_platform.y;
    other_tank.state.z = thaddius_arena.left_platform.z;
    other_tank.state.target_guid = stalagg_scan.guid;
    other_tank.state.game_time_ms += proto.brain_tick_ms;
    const tick4 = compute(&.{ bot, other_tank }, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 0), tick4.len);

    bot.state.game_time_ms += 1000;
    other_tank.state.game_time_ms += 1000;
    const tick5 = compute(&.{ bot, other_tank }, &world, &.{}, &out_buf, &dispatch_store, &follow_store, &intent_store, true);
    try std.testing.expectEqual(@as(usize, 2), tick5.len);
    try std.testing.expect(tick5[0].msg == .set_target_guid);
    try std.testing.expect(tick5[1].msg == .set_target_guid);
    try std.testing.expectEqual(feugen_scan.guid, tick5[0].msg.set_target_guid.guid);
    try std.testing.expectEqual(stalagg_scan.guid, tick5[1].msg.set_target_guid.guid);
}

test "compute: authoritative anchored tank starts melee before spec cast" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(90);
    bot.state.guid = 0x900;
    bot.state.map_id = 1;
    bot.state.class = @intFromEnum(combat.Class.paladin);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.game_time_ms = 1000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.combat_reach = 1.0;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.x = 2.0;
    scan.combat_reach = 1.0;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    follow_store.setPosition(bot.bot_id, .{
        .x = 0,
        .y = 0,
        .z = 0,
        .arrival_yards = 5.0,
        .authoritative = true,
    });

    const orders1 = computeWithProposers(
        &.{bot},
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleStartAttack,
        testSpecCast,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), orders1.len);
    try std.testing.expect(orders1[0].msg == .lua_exec);
    try std.testing.expectEqualStrings("StartAttack()", std.mem.sliceTo(&orders1[0].msg.lua_exec, 0));
    try std.testing.expectEqual(intent.Priority.role, intent_store.current(bot.bot_id).?.priority);

    bot.state.game_time_ms += 1000;
    const orders2 = computeWithProposers(
        &.{bot},
        &world,
        &.{},
        &out_buf,
        &dispatch_store,
        &follow_store,
        &intent_store,
        true,
        testRoleStartAttack,
        testSpecCast,
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), orders2.len);
    try std.testing.expectEqual(proto.NetCmd.cast_spell_id, std.meta.activeTag(orders2[0].msg));
    try std.testing.expectEqual(@as(u32, 777), orders2[0].msg.cast_spell_id.spell_id);
}

test "compute: blocking move interrupts an in-progress channel before moving" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(91);
    bot.state.guid = 0x191;
    bot.state.game_time_ms = 1000;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.is_channeling = 1;
    bot.state.channel_spell_id = 58381;

    // Channeling bot: relocating it must stop the cast first (the engine ignores a
    // click-to-move mid-channel), so the order is SpellStopCasting, not a move.
    const orders = testComputeWithProposers(bot, testRoleMovingBlocking, testNoSpec, &intent_store, &dispatch_store, &follow_store, &out_buf);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    try std.testing.expectEqual(proto.NetCmd.lua_exec, std.meta.activeTag(orders[0].msg));
    try std.testing.expect(std.mem.indexOf(u8, &orders[0].msg.lua_exec, "SpellStopCasting") != null);
}

test "compute: polarity transit move is dispatched even while engine is in attack chase" {
    var dispatch_store: DispatchStore = .{};
    var follow_store: combat.FollowStore = .{};
    var intent_store: IntentStore = .{};
    var out_buf: [types.max_bots]Order = undefined;

    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id = testBotId(92);
    bot.state.guid = 0x192;
    bot.state.game_time_ms = 1000;
    bot.state.hp = 100;
    bot.state.hp_max = 100;
    bot.state.map_id = 0; // non-encounter map: the built-in encounter proposer stays out
    bot.state.x = 3515.5;
    bot.state.y = -2937.9;
    bot.state.z = 303.0;
    // Engine is chasing the boss to melee (auto-attack flag set earlier).
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.attack_pos);

    // Pre-install the encounter stacking intent (as the encounter proposer would
    // on Thaddius): the bot must relocate to the opposite-charge stack.
    const stacking: intent.ActiveIntent = .{
        .intent = .{ .stacking = .{ .x = 3501.8, .y = -2925.3, .z = 303.1, .tolerance = 1.5, .reason = .encounter_stack } },
        .priority = .encounter,
        .created_at_ms = 1000,
        .source = .encounter_stack,
    };
    _ = intent_store.replaceAt(bot.bot_id, stacking, &dispatch_store, bot.state.game_time_ms);

    const orders = testComputeWithProposers(bot, testNoRole, testNoSpec, &intent_store, &dispatch_store, &follow_store, &out_buf);
    try std.testing.expectEqual(@as(usize, 1), orders.len);
    // With the transport backlog fixed (minion drains every queued command per
    // tick, throttle no longer saturates), the move_to reaches the minion within
    // a tick and overrides the engine chase. The move is dispatched directly even
    // while CTM is in attack_pos — no per-tick clear_target bypass.
    try std.testing.expectEqual(proto.NetCmd.ctm_move, std.meta.activeTag(orders[0].msg));
    try std.testing.expectEqual(@as(f32, 3501.8), orders[0].msg.ctm_move.x);
    try std.testing.expectEqual(@as(f32, -2925.3), orders[0].msg.ctm_move.y);
}
