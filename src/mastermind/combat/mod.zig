//! Mastermind entry for the `combat/` package: `@import("combat/mod.zig")`.
//! A separate Zig `combat` build module would duplicate `world_memory.zig` across module graphs.

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../world/memory.zig");

const action_mod = @import("action.zig");
const class_spec = @import("class_spec.zig");
const context = @import("context.zig");
const dispatch = @import("dispatch.zig");
const dispatch_store_mod = @import("dispatch_store.zig");
const encounter = @import("encounters/mod.zig");
const intent_dispatch = @import("intent/dispatch.zig");
const intent = @import("intent/mod.zig");
const intent_role = @import("proposers/role.zig");
const intent_spec = @import("proposers/spec.zig");
const prep_gate = @import("prep_gate.zig");
const thaddius_enc = @import("encounters/thaddius/mod.zig");
const role_mod = @import("role.zig");
const cast_range = @import("cast_range.zig");
const spec_registry = @import("specs/spec_registry.zig");
const spells = @import("spells.zig");

pub const BotSnapshot = registry_mod.BotSnapshot;

pub const Action = action_mod.Action;
pub const DispatchStore = dispatch_store_mod.DispatchStore;
pub const dispatchThrottleKey = dispatch.dispatchThrottleKey;
pub const instant_cast_debounce_ms = dispatch.instant_cast_debounce_ms;

pub const Class = class_spec.Class;
pub const classFromState = class_spec.classFromState;
pub const primarySpec = class_spec.primarySpec;
pub const primarySpecFromState = class_spec.primarySpecFromState;
pub const specName = class_spec.specName;

pub const CastRangeCheck = cast_range.CastRangeCheck;
pub const dispatchRangeResult = cast_range.dispatchRangeResult;
pub const FollowStore = role_mod.FollowStore;

pub const IntentStore = intent.IntentStore;

/// MASTERMIND_LOG_POLARITY_CHARGES: log who takes Thaddius charge damage (per pulse).
pub const setPolarityChargeLogEnabled = thaddius_enc.setChargePulseLogEnabled;

/// On prep-gated encounter maps before the operator clicks **Start fight**, idle players
/// may only emit OOC buffs. Once the client reports combat, combat-only spells may pass.
pub fn actionAllowedEncounterPrep(operator_fight_started: bool, state: proto.State, action: Action, spec: class_spec.Spec) bool {
    return prep_gate.actionAllowed(operator_fight_started, state, action, spec);
}

pub fn spellName(spec: class_spec.Spec, spell_id: u32) ?[]const u8 {
    const lookup = spec_registry.meta(spec).spell_name orelse return null;
    const name = lookup(spell_id) orelse return null;
    if (std.mem.eql(u8, name, "unknown")) return null;
    return name;
}

test {
    _ = @import("assignments.zig");
    _ = @import("cast_range.zig");
    _ = @import("class_spec.zig");
    _ = @import("dispatch.zig");
    _ = @import("dispatch_store.zig");
    _ = @import("encounters/thaddius/mod.zig");
    _ = @import("heal_select.zig");
    _ = @import("intent/mod.zig");
    _ = @import("intent/confirm.zig");
    _ = @import("intent/dispatch.zig");
    _ = @import("positioning.zig");
    _ = @import("prep_gate.zig");
    _ = @import("proposers/heal.zig");
    _ = @import("proposers/role.zig");
    _ = @import("proposers/spec.zig");
    _ = @import("proposers/tank_rescue.zig");
    _ = @import("proposers/tank_engage.zig");
    _ = @import("rage.zig");
    _ = @import("role.zig");
    _ = @import("specs/arcane.zig");
    _ = @import("specs/arms.zig");
    _ = @import("specs/assassination.zig");
    _ = @import("specs/blood.zig");
    _ = @import("specs/discipline.zig");
    _ = @import("specs/feral.zig");
    _ = @import("specs/paladin_blessings.zig");
    _ = @import("specs/protection_paladin.zig");
    _ = @import("specs/shadow.zig");
    _ = @import("specs/survival.zig");
    _ = @import("spells.zig");
    _ = @import("target_spell.zig");
    _ = @import("aggro.zig");
    _ = @import("world_query.zig");
}

/// Called when the operator clicks **Start fight** in the GUI (once per click).
pub fn onStartFight(
    io: std.Io,
    registry: *registry_mod.Registry,
    bots: []const BotSnapshot,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    follow_store: *FollowStore,
) void {
    thaddius_enc.onStartFight(io, registry, bots, intent_store, dispatch_store, follow_store);
}

/// Called when the operator clicks **Test jump** in the GUI (once per click).
/// Seeds the post-twin transition intent (platform move + boots) for every bot on map 533.
pub fn onTestJump(
    io: std.Io,
    registry: *registry_mod.Registry,
    bots: []const BotSnapshot,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    follow_store: *FollowStore,
) void {
    thaddius_enc.onTestJump(io, registry, bots, intent_store, dispatch_store, follow_store);
}

/// Called when the operator clicks **Clean orders** in the GUI (once per click).
/// Sends CTM stop to every bot and clears all plans, follow positions, and encounter state.
pub fn onCleanOrders(
    io: std.Io,
    registry: *registry_mod.Registry,
    bots: []const BotSnapshot,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    follow_store: *FollowStore,
) void {
    thaddius_enc.onCleanOrders(io, registry, bots, intent_store, dispatch_store, follow_store);
}

fn roleAction(
    bot: BotSnapshot,
    bots: []const BotSnapshot,
    world: []const world_memory_mod.WorldSnapshot,
    follow_store: *FollowStore,
    operator_fight_started: bool,
) Action {
    const ctx = context.CombatContext.build(bot, bots, world, &.{}, operator_fight_started);
    return intent_role.dispatchAction(&ctx, follow_store);
}

fn specAction(
    bot: BotSnapshot,
    bots: []const BotSnapshot,
    world: []const world_memory_mod.WorldSnapshot,
    follow: *FollowStore,
    operator_fight_started: bool,
) Action {
    const ctx = context.CombatContext.build(bot, bots, world, &.{}, operator_fight_started);
    const ai = intent_spec.proposeIntent(&ctx) orelse return .none;
    return intent_dispatch.actionForIntent(ai, &ctx, follow);
}

test "plan: role layer moves toward hostile target_guid" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.class = @intFromEnum(Class.warrior);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    bot.state.map_id = encounter.thaddius_map_id;
    bot.state.x = 0;
    bot.state.y = 0;
    bot.state.z = 0;
    bot.state.target_guid = 0xdeadbeef;
    bot.state.target_unit_reaction = 2; // Hostile

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xdeadbeef;
    scan.hp = 100;
    scan.x = 40;
    scan.y = 0;
    scan.z = 1;
    const world = [_]world_memory_mod.WorldSnapshot{.{
        .scan = scan,
        .map_id = encounter.thaddius_map_id,
        .last_seen_ts_ns = 0,
    }};

    var follow_store: FollowStore = .{};
    const a = roleAction(bot, &.{bot}, &world, &follow_store, true);
    try std.testing.expect(a == .move_to_nb);
}

test "plan: blood dk spec rotation does not cast tank engage spell" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.class = @intFromEnum(Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.map_id = encounter.thaddius_map_id;
    bot.state.x = 0;
    bot.state.y = 0;
    bot.state.z = 0;
    bot.state.target_guid = 0xdeadbeef;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.game_time_ms = 1000;
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .spell_id = 48263, .caster_guid = 1, .remaining_ms = 1000 };
    bot.state.rune_types = .{ 2, 3, 1, 4, 1, 2 };
    bot.state.rune_regen_ms = .{ 0, 0, 5000, 5000, 5000, 5000 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xdeadbeef;
    scan.hp = 100;
    scan.x = 15;
    scan.y = 0;
    scan.z = 0;
    const world = [_]world_memory_mod.WorldSnapshot{.{
        .scan = scan,
        .map_id = encounter.thaddius_map_id,
        .last_seen_ts_ns = 0,
    }};

    var follow_store: FollowStore = .{};
    const a = specAction(bot, &.{bot}, &world, &follow_store, true);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(@as(u32, 49909), a.cast_target_instant.spell_id); // icy_touch
}

test "plan: highThreat blocks DPS actions" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0xd05;
    bot.state.class = @intFromEnum(Class.rogue);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.threat_on_target = 1100;

    var tank: BotSnapshot = std.mem.zeroes(BotSnapshot);
    tank.state.guid = 0xaaa;
    tank.state.class = @intFromEnum(Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    tank.state.target_guid = 0xabc;
    tank.state.target_unit_reaction = 2;
    tank.state.threat_on_target = 1000;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    scan.x = 10;
    scan.y = 0;
    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    var follow_store: FollowStore = .{};
    const action = roleAction(bot, &.{ bot, tank }, &world, &follow_store, true);
    try std.testing.expect(action == .none);
}

test "plan: encounter map prep — seal when blessing up" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.class = @intFromEnum(Class.paladin);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    bot.state.map_id = encounter.thaddius_map_id;
    bot.state.unit_flags = 0;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{
        .caster_guid = 1,
        .spell_id = spells.get(25780).spell_id,
        .remaining_ms = 9999999,
    };
    bot.state.player_auras[1] = .{
        .caster_guid = 1,
        .spell_id = spells.get(25899).spell_id,
        .remaining_ms = 9999999,
    };

    var follow_store: FollowStore = .{};
    const a = specAction(bot, &.{bot}, &.{}, &follow_store, false);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(spells.get(31801).spell_id, a.cast_instant);
}

test "plan: encounter map prep — blessing when OOC and operator idle" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.class = @intFromEnum(Class.paladin);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    bot.state.map_id = encounter.thaddius_map_id;
    bot.state.unit_flags = 0;

    var follow_store: FollowStore = .{};
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{
        .caster_guid = 1,
        .spell_id = spells.get(25780).spell_id,
        .remaining_ms = 9999999,
    };

    const a = specAction(bot, &.{bot}, &.{}, &follow_store, false);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(spells.get(25899).spell_id, a.cast_instant);
}

test "plan: encounter map prep — no blessing while WoW in combat" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.class = @intFromEnum(Class.paladin);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    bot.state.map_id = encounter.thaddius_map_id;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);

    var follow_store: FollowStore = .{};
    const a = specAction(bot, &.{bot}, &.{}, &follow_store, false);
    try std.testing.expect(a == .none);
}

test "plan: encounter map prep — no role move toward hostile tab" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.class = @intFromEnum(Class.warrior);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    bot.state.map_id = encounter.thaddius_map_id;
    bot.state.x = 0;
    bot.state.y = 0;
    bot.state.z = 0;
    bot.state.target_guid = 0xdeadbeef;
    bot.state.target_unit_reaction = 2;
    bot.state.unit_flags = 0;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xdeadbeef;
    scan.hp = 100;
    scan.x = 40;
    scan.y = 0;
    scan.z = 1;
    const world = [_]world_memory_mod.WorldSnapshot{.{
        .scan = scan,
        .map_id = encounter.thaddius_map_id,
        .last_seen_ts_ns = 0,
    }};

    var follow_store: FollowStore = .{};
    const a = roleAction(bot, &.{bot}, &world, &follow_store, false);
    try std.testing.expect(a == .none);
}

test {
    _ = @import("cast_range.zig");
    _ = @import("class_spec.zig");
    _ = @import("dispatch.zig");
    _ = @import("dispatch_store.zig");
    _ = @import("encounters/thaddius/mod.zig");
    _ = @import("positioning.zig");
    _ = @import("prep_gate.zig");
    _ = @import("proposers/heal.zig");
    _ = @import("role.zig");
    _ = @import("specs/arcane.zig");
    _ = @import("specs/arms.zig");
    _ = @import("specs/assassination.zig");
    _ = @import("specs/blood.zig");
    _ = @import("specs/feral.zig");
    _ = @import("specs/paladin_blessings.zig");
    _ = @import("specs/protection_paladin.zig");
    _ = @import("specs/shadow.zig");
    _ = @import("specs/survival.zig");
    _ = @import("spells.zig");
    _ = @import("target_spell.zig");
    _ = @import("aggro.zig");
    _ = @import("world_query.zig");
}
