//! Sombreforge (G3). Roster : assets/setup.md

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const context = @import("../context.zig");
const spells_db = @import("../spells.zig");
const cooldown = @import("../cooldown.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;
const CombatContext = context.CombatContext;

pub const data = struct {
    pub const spells = struct {
        pub const shadowform = spells_db.get(15473);
        pub const fade = spells_db.get(586);
        pub const inner_fire = spells_db.get(48168);
        pub const vampiric_touch = spells_db.get(48160);
        pub const shadow_word_pain = spells_db.get(48125);
        pub const devouring_plague = spells_db.get(48300);
        pub const mind_blast = spells_db.get(48127);
        pub const mind_flay = spells_db.get(58381);
    };
    pub const resources = struct {};
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.shadowform.spell_id };
}

pub fn threatPlan(ctx: *const CombatContext) Action {
    if (!ctx.threat_high) return .none;
    if (ctx.bot.state.is_casting != 0 or ctx.bot.state.is_channeling != 0) return .none;
    if (!cooldown.spellReady(ctx.bot.state, data.spells.fade.spell_id)) return .none;
    return .{ .cast_instant = data.spells.fade.spell_id };
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return @import("../aura.zig").remainingMsOnSelf(state, spell_id) != null;
}

fn targetHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.target_auras, state.target_aura_count, spell_id);
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!selfHasAura(bot.state, data.spells.shadowform.spell_id)) {
        return .{ .cast_instant = data.spells.shadowform.spell_id };
    }

    if (!selfHasAura(bot.state, data.spells.inner_fire.spell_id)) {
        return .{ .cast_instant = data.spells.inner_fire.spell_id };
    }

    const g = world_query.primaryHostileAttackGuid(bot.state, world) orelse return .none;

    if (!targetHasAura(bot.state, data.spells.vampiric_touch.spell_id)) {
        return .{ .cast_target = .{ .spell_id = data.spells.vampiric_touch.spell_id, .target_guid = g } };
    }

    if (!targetHasAura(bot.state, data.spells.shadow_word_pain.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.shadow_word_pain.spell_id, .target_guid = g } };
    }

    if (!targetHasAura(bot.state, data.spells.devouring_plague.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.devouring_plague.spell_id, .target_guid = g } };
    }

    if (cooldown.spellReady(bot.state, data.spells.mind_blast.spell_id)) {
        return .{ .cast_target = .{ .spell_id = data.spells.mind_blast.spell_id, .target_guid = g } };
    }

    return .{ .cast_target = .{ .spell_id = data.spells.mind_flay.spell_id, .target_guid = g } };
}

test "plan: Shadowform missing casts it" {
    const bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    const world: []const WorldSnapshot = &.{};
    const a = plan(bot, world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.shadowform.spell_id, a.cast_instant);
}

test "plan: Inner Fire missing casts it" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.shadowform.spell_id, .remaining_ms = 0 };
    const world: []const WorldSnapshot = &.{};
    const a = plan(bot, world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.inner_fire.spell_id, a.cast_instant);
}

test "plan: Inner Fire stale aura is ignored" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.inner_fire.spell_id, .remaining_ms = 0 };
    const world: []const WorldSnapshot = &.{};
    const a = plan(bot, world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.shadowform.spell_id, a.cast_instant);
}

test "plan: no cast without hostile target" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.shadowform.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.inner_fire.spell_id, .remaining_ms = 0 };
    const world: []const WorldSnapshot = &.{};
    try std.testing.expect(plan(bot, world) == .none);
}

fn buildHostileWorld(guid: u64, map_id: u32) [1]WorldSnapshot {
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = guid;
    scan.hp = 100;
    return .{.{
        .scan = scan,
        .map_id = map_id,
        .last_seen_ts_ns = 0,
    }};
}

fn botWithShadowform(guid: u64, target_guid: u64, map_id: u32) BotSnapshot {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = guid;
    bot.state.map_id = map_id;
    bot.state.target_guid = target_guid;
    bot.state.target_unit_reaction = 2;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.shadowform.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.inner_fire.spell_id, .remaining_ms = 0 };
    return bot;
}

test "plan: Vampiric Touch missing casts it" {
    const g: u64 = 0xaaa;
    const bot = botWithShadowform(0x100, g, 533);
    const world = buildHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.vampiric_touch.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(g, a.cast_target.target_guid);
}

test "plan: Shadow Word: Pain missing casts it" {
    const g: u64 = 0xaaa;
    var bot = botWithShadowform(0x100, g, 533);
    bot.state.target_aura_count = 1;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.vampiric_touch.spell_id, .remaining_ms = 0 };
    const world = buildHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.shadow_word_pain.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: Devouring Plague missing casts it" {
    const g: u64 = 0xaaa;
    var bot = botWithShadowform(0x100, g, 533);
    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.vampiric_touch.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.shadow_word_pain.spell_id, .remaining_ms = 0 };
    const world = buildHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.devouring_plague.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: all DoTs up casts Mind Blast" {
    const g: u64 = 0xaaa;
    var bot = botWithShadowform(0x100, g, 533);
    bot.state.target_aura_count = 3;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.vampiric_touch.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.shadow_word_pain.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[2] = .{ .caster_guid = 0, .spell_id = data.spells.devouring_plague.spell_id, .remaining_ms = 0 };
    const world = buildHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.mind_blast.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(g, a.cast_target.target_guid);
}

test "plan: Mind Blast on cooldown filler Mind Flay" {
    const g: u64 = 0xaaa;
    var bot = botWithShadowform(0x100, g, 533);
    bot.state.target_aura_count = 3;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.vampiric_touch.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.shadow_word_pain.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[2] = .{ .caster_guid = 0, .spell_id = data.spells.devouring_plague.spell_id, .remaining_ms = 0 };
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.mind_blast.spell_id, .category = 0, .remaining_ms = 1500, .duration_ms = 8000 };
    const world = buildHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.mind_flay.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(g, a.cast_target.target_guid);
}
