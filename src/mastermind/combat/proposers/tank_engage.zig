const proto = @import("protocol");
const context = @import("../context.zig");
const intent = @import("../intent/mod.zig");
const positioning = @import("../positioning.zig");
const spec_registry = @import("../specs/spec_registry.zig");
const spells_db = @import("../spells.zig");
const world_query = @import("../world_query.zig");

const ActiveIntent = intent.ActiveIntent;
const CombatContext = context.CombatContext;

// Window during which we treat the pull spell cooldown as "just placed" and hold
// position while both tanks' pulls synchronize. Must be >= one scan cycle.
const pull_transit_window_ms: u32 = proto.brain_tick_ms * 5;

pub fn proposeIntent(ctx: *const CombatContext) ?ActiveIntent {
    return proposeIntentForTarget(ctx, null);
}

pub fn proposeIntentForTarget(ctx: *const CombatContext, forced_target: ?u64) ?ActiveIntent {
    if (ctx.role != .tank) return null;

    const spell = spec_registry.meta(ctx.spec).pull_spell orelse return null;

    const target_guid = forced_target orelse ctx.primary_target orelse return null;
    const target = world_query.entryForGuidOnMap(ctx.world, target_guid, ctx.bot.state.map_id) orelse return null;
    if (target.scan.hp == 0) return null;

    if (!targetOutsideMelee(ctx, target.scan)) return null;

    if (hasCooldown(ctx.bot.state, spell.spell_id)) {
        if (!hasFreshCooldown(ctx.bot.state, spell.spell_id)) return null;
        return .{
            .intent = .idle,
            .priority = .spec,
            .created_at_ms = ctx.game_time_ms,
            .max_age_ms = pull_transit_window_ms,
            .source = .tank_engage,
        };
    }

    const client_range = clientSpellRange(ctx.bot.state, spell.spell_id) orelse return null;
    if (!targetInPullRange(ctx, target.scan, client_range)) return null;

    return .{
        .intent = .{ .casting_scripted = .{
            .spell_id = spell.spell_id,
            .target_guid = target_guid,
            .instant = true,
            .one_shot = true,
        } },
        .priority = .spec,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = proto.brain_tick_ms * 5,
        .source = .tank_engage,
    };
}

fn targetOutsideMelee(ctx: *const CombatContext, target: proto.ScanEntry) bool {
    const result = positioning.computeDesiredPos(.{
        .bot = .{
            .pos = .{ .x = ctx.bot.state.x, .y = ctx.bot.state.y, .z = ctx.bot.state.z },
            .orientation = ctx.bot.state.orientation,
            .combat_reach = ctx.bot.state.combat_reach,
        },
        .target = .{
            .pos = .{ .x = target.x, .y = target.y, .z = target.z },
            .orientation = target.orientation,
            .combat_reach = target.combat_reach,
        },
        .placement = .{
            .relative_angle = 0,
            .facing_tolerance = positioning.melee_facing_tolerance_rad,
            .arc_policy = .none,
            .range = .melee,
        },
    });
    return result.bot_dist > result.range_upper;
}

fn targetInPullRange(ctx: *const CombatContext, target: proto.ScanEntry, client_range: f32) bool {
    const dist_sq = distanceSq(ctx.bot.state, target);
    const effective_range = client_range + target.combat_reach;
    return dist_sq <= effective_range * effective_range;
}

fn distanceSq(state: proto.State, target: proto.ScanEntry) f32 {
    const dx = target.x - state.x;
    const dy = target.y - state.y;
    const dz = target.z - state.z;
    return dx * dx + dy * dy + dz * dz;
}

fn hasCooldown(state: proto.State, spell_id: u32) bool {
    const n = @min(state.cooldown_count, state.cooldowns.len);
    return world_query.hasCooldown(state.cooldowns[0..], n, spell_id);
}

fn hasFreshCooldown(state: proto.State, spell_id: u32) bool {
    const n = @min(state.cooldown_count, state.cooldowns.len);
    for (state.cooldowns[0..n]) |cd| {
        if (cd.spell_id != spell_id) continue;
        if (cd.duration_ms == 0) return false;
        return cd.remaining_ms >= cd.duration_ms -| pull_transit_window_ms;
    }
    return false;
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

test "proposeIntent: blood tank engages with icy touch before melee placement" {
    const std = @import("std");
    const registry_mod = @import("registry");
    const world_memory_mod = @import("../../world/memory.zig");
    const class_spec = @import("../class_spec.zig");

    var bot: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.class = @intFromEnum(class_spec.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.spell_range_count = 1;
    bot.state.spell_ranges[0] = .{ .spell_id = spells_db.get(49909).spell_id, .max_range_yards = 20.0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.hp_max = 1000;
    scan.x = 15;
    scan.combat_reach = 1.0;

    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;

    try std.testing.expect(ai.intent == .casting_scripted);
    try std.testing.expectEqual(spells_db.get(49909).spell_id, ai.intent.casting_scripted.spell_id);
    try std.testing.expect(ai.intent.casting_scripted.one_shot);
    try std.testing.expectEqual(intent.Reason.tank_engage, ai.source);
}

test "proposeIntent: tank engage requires client range" {
    const std = @import("std");
    const registry_mod = @import("registry");
    const world_memory_mod = @import("../../world/memory.zig");
    const class_spec = @import("../class_spec.zig");

    var bot: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.class = @intFromEnum(class_spec.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.hp_max = 1000;
    scan.x = 20;
    scan.combat_reach = 1.0;

    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);

    try std.testing.expect(proposeIntent(&ctx) == null);
}

test "proposeIntent: holds position after pull while cooldown is fresh" {
    const std = @import("std");
    const registry_mod = @import("registry");
    const world_memory_mod = @import("../../world/memory.zig");
    const class_spec = @import("../class_spec.zig");

    const icy_touch_id = spells_db.get(49909).spell_id;
    const cd_duration_ms: u32 = 6_000;

    var bot: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.class = @intFromEnum(class_spec.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{
        .spell_id = icy_touch_id,
        .category = 0,
        .duration_ms = cd_duration_ms,
        .remaining_ms = cd_duration_ms - 1,
    };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.hp_max = 1000;
    scan.x = 20;
    scan.combat_reach = 1.0;

    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;

    try std.testing.expect(ai.intent == .idle);
    try std.testing.expectEqual(intent.Priority.spec, ai.priority);
    try std.testing.expectEqual(intent.Reason.tank_engage, ai.source);
    try std.testing.expect(ai.max_age_ms > 0);
}

test "proposeIntent: does not hold when cooldown is old" {
    const std = @import("std");
    const registry_mod = @import("registry");
    const world_memory_mod = @import("../../world/memory.zig");
    const class_spec = @import("../class_spec.zig");

    const icy_touch_id = spells_db.get(49909).spell_id;
    const cd_duration_ms: u32 = 6_000;

    var bot: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.state.class = @intFromEnum(class_spec.Class.death_knight);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.map_id = 1;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{
        .spell_id = icy_touch_id,
        .category = 0,
        .duration_ms = cd_duration_ms,
        .remaining_ms = cd_duration_ms / 2,
    };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 1000;
    scan.hp_max = 1000;
    scan.x = 20;
    scan.combat_reach = 1.0;

    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);

    try std.testing.expect(proposeIntent(&ctx) == null);
}
