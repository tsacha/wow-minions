//! Malecrou, Toxiboulon, Gribouille (G4). Roster : assets/setup.md

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const context = @import("../context.zig");
const cooldown = @import("../cooldown.zig");
const spells_db = @import("../spells.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;
const CombatContext = context.CombatContext;

const pending_spell_window_ticks: u32 = 3;
const pending_spell_window_ms: u32 = proto.brain_tick_ms * pending_spell_window_ticks;

pub const data = struct {
    pub const spells = struct {
        pub const fel_armor = spells_db.get(47893);
        pub const summon_imp = spells_db.get(688);
        pub const life_tap_rank1 = spells_db.get(1454);
        pub const life_tap = spells_db.get(57946);
        pub const shadow_bolt = spells_db.get(47809);
        pub const corruption = spells_db.get(47813);
        pub const unstable_affliction = spells_db.get(47841);
        pub const haunt = spells_db.get(59164);
        pub const curse_of_agony = spells_db.get(47864);
        pub const soulshatter = spells_db.get(29858);
    };
    pub const resources = struct {
        pub const life_tap_glyph_aura: u32 = 63321;
        pub const shadow_embrace_aura: u32 = 17800;
        // Use rank1 (minimal HP cost) when mana is above this threshold; rank8 only when below.
        pub const life_tap_rank1_above_mana_pct: u32 = 30;
        pub const life_tap_max_at_or_below_mana_pct: u32 = 20;
    };
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.fel_armor.spell_id };
}

pub fn threatPlan(ctx: *const CombatContext) Action {
    if (!ctx.threat_high) return .none;
    if (ctx.bot.state.is_casting != 0 or ctx.bot.state.is_channeling != 0) return .none;
    if (!cooldown.spellReady(ctx.bot.state, data.spells.soulshatter.spell_id)) return .none;
    return .{ .cast_instant = data.spells.soulshatter.spell_id };
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

fn targetHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.target_auras, state.target_aura_count, spell_id);
}

fn manaPercent(state: proto.State) u32 {
    if (state.active_power_max == 0) return 100;
    return (state.active_power * 100) / state.active_power_max;
}

fn lifeTapSpellId(state: proto.State) u32 {
    if (manaPercent(state) > data.resources.life_tap_rank1_above_mana_pct) {
        return data.spells.life_tap_rank1.spell_id;
    }

    return data.spells.life_tap.spell_id;
}

fn shouldLifeTapForMana(state: proto.State) bool {
    return manaPercent(state) <= data.resources.life_tap_max_at_or_below_mana_pct;
}

fn targetedCastInFlight(state: proto.State, target_guid: u64) bool {
    if (state.is_casting == 0) return false;
    if (target_guid == 0 or state.target_guid != target_guid) return false;

    return switch (state.casting_spell_id) {
        data.spells.shadow_bolt.spell_id,
        data.spells.unstable_affliction.spell_id,
        data.spells.haunt.spell_id,
        => true,
        else => false,
    };
}

fn recentSpellLaunchSeen(ctx: *const CombatContext, spell_id: u32, target_guid: u64) bool {
    // Spell events carry no target GUID; we guard on the bot's current target matching
    // so a cast on a different unit never satisfies the check for this target.
    if (target_guid == 0 or ctx.bot.state.target_guid != target_guid) return false;

    if ((ctx.bot.state.is_casting != 0 and ctx.bot.state.casting_spell_id == spell_id) or
        (ctx.bot.state.is_channeling != 0 and ctx.bot.state.channel_spell_id == spell_id))
    {
        return true;
    }

    for (ctx.spell_events) |event| {
        if (event.caster_guid != ctx.bot.state.guid) continue;
        if (event.spell_id != spell_id) continue;
        if (ctx.game_time_ms < event.game_time_ms) continue;

        const kind = std.enums.fromInt(proto.SpellEventKind, event.kind) orelse continue;
        switch (kind) {
            .start, .go => {},
            .failed, .interrupted, .channel_update, .channel_end => continue,
        }

        if (ctx.game_time_ms - event.game_time_ms <= pending_spell_window_ms) return true;
    }

    return false;
}

fn targetHasAuraOrPending(ctx: *const CombatContext, spell_id: u32, target_guid: u64) bool {
    return targetHasAura(ctx.bot.state, spell_id) or recentSpellLaunchSeen(ctx, spell_id, target_guid);
}

fn shadowEmbraceSatisfied(ctx: *const CombatContext, target_guid: u64) bool {
    return targetHasAura(ctx.bot.state, data.resources.shadow_embrace_aura) or
        recentSpellLaunchSeen(ctx, data.spells.shadow_bolt.spell_id, target_guid);
}

fn hasPet(state: proto.State) bool {
    return state.pet_guid != 0;
}

pub fn planWithContext(ctx: *const CombatContext) Action {
    if (!selfHasAura(ctx.bot.state, data.spells.fel_armor.spell_id)) {
        return .{ .cast_instant = data.spells.fel_armor.spell_id };
    }

    if (!hasPet(ctx.bot.state)) {
        return .{ .cast_instant = data.spells.summon_imp.spell_id };
    }

    const g = ctx.primary_target orelse return .none;

    if (targetedCastInFlight(ctx.bot.state, g)) {
        return .none;
    }

    if (!selfHasAura(ctx.bot.state, data.resources.life_tap_glyph_aura)) {
        return .{ .cast_instant = lifeTapSpellId(ctx.bot.state) };
    }

    if (shouldLifeTapForMana(ctx.bot.state)) {
        return .{ .cast_instant = data.spells.life_tap.spell_id };
    }

    if (!shadowEmbraceSatisfied(ctx, g)) {
        return .{ .cast_target = .{ .spell_id = data.spells.shadow_bolt.spell_id, .target_guid = g } };
    }

    if (!targetHasAuraOrPending(ctx, data.spells.corruption.spell_id, g)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.corruption.spell_id, .target_guid = g } };
    }

    if (!targetHasAuraOrPending(ctx, data.spells.unstable_affliction.spell_id, g)) {
        return .{ .cast_target = .{ .spell_id = data.spells.unstable_affliction.spell_id, .target_guid = g } };
    }

    if (!targetHasAuraOrPending(ctx, data.spells.haunt.spell_id, g)) {
        return .{ .cast_target = .{ .spell_id = data.spells.haunt.spell_id, .target_guid = g } };
    }

    if (!targetHasAura(ctx.bot.state, data.spells.curse_of_agony.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.curse_of_agony.spell_id, .target_guid = g } };
    }

    return .{ .cast_target = .{ .spell_id = data.spells.shadow_bolt.spell_id, .target_guid = g } };
}

fn ctxNoEvents(bot: BotSnapshot, world: []const WorldSnapshot) CombatContext {
    return CombatContext.build(bot, &.{bot}, world, &.{}, false);
}

test "planWithContext: casts Fel Armor when missing" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    const ctx = ctxNoEvents(bot, &.{});
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.fel_armor.spell_id, a.cast_instant);
}

test "planWithContext: summons Imp when pet absent" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    const ctx = ctxNoEvents(bot, &.{});
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.summon_imp.spell_id, a.cast_instant);
}

test "planWithContext: no target returns none" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    const ctx = ctxNoEvents(bot, &.{});
    try std.testing.expectEqual(Action.none, planWithContext(&ctx));
}

test "planWithContext: Life Tap glyph aura missing, mana > 30% uses rank 1" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 8000;
    bot.state.active_power_max = 10000;
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.life_tap_rank1.spell_id, a.cast_instant);
}

test "planWithContext: Life Tap glyph aura missing, mana <= 30% uses rank 8" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 3000;
    bot.state.active_power_max = 10000;
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.life_tap.spell_id, a.cast_instant);
}

test "planWithContext: Shadow Embrace missing casts Shadow Bolt" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.shadow_bolt.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target.target_guid);
}

test "planWithContext: Shadow Bolt cast in flight returns none" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.is_casting = 1;
    bot.state.casting_spell_id = data.spells.shadow_bolt.spell_id;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    try std.testing.expectEqual(Action.none, planWithContext(&ctx));
}

test "planWithContext: Life Tap glyph aura present, low mana uses rank 8" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 2000;
    bot.state.active_power_max = 10000;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.life_tap.spell_id, a.cast_instant);
}

test "planWithContext: Life Tap glyph aura present, mana above 20% keeps rotation" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 2100;
    bot.state.active_power_max = 10000;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.shadow_bolt.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target.target_guid);
}

test "planWithContext: Corruption missing casts Corruption" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };
    bot.state.target_aura_count = 1;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.resources.shadow_embrace_aura, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.corruption.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}

test "planWithContext: recent Corruption launch prevents immediate duplicate cast" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.game_time_ms = 10_000;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };
    bot.state.target_aura_count = 1;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.resources.shadow_embrace_aura, .remaining_ms = 0 };

    const event = proto.SpellEvent{
        .kind = @intFromEnum(proto.SpellEventKind.go),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x100,
        .caster_guid = 0x100,
        .spell_id = data.spells.corruption.spell_id,
        .flags = 0,
        .value_ms = 0,
        .game_time_ms = 10_000,
    };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{event}, false);

    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.unstable_affliction.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target.target_guid);
}

test "planWithContext: all up casts Shadow Bolt filler" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };
    bot.state.target_aura_count = 5;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.resources.shadow_embrace_aura, .remaining_ms = 0 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.corruption.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[2] = .{ .caster_guid = 0, .spell_id = data.spells.unstable_affliction.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[3] = .{ .caster_guid = 0, .spell_id = data.spells.haunt.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[4] = .{ .caster_guid = 0, .spell_id = data.spells.curse_of_agony.spell_id, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.shadow_bolt.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target.target_guid);
}

test "planWithContext: Unstable Affliction missing casts Unstable Affliction after Corruption" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };
    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.resources.shadow_embrace_aura, .remaining_ms = 0 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.corruption.spell_id, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.unstable_affliction.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target.target_guid);
}

test "planWithContext: Haunt missing casts Haunt after Unstable Affliction" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 8000;
    bot.state.active_power_max = 10000;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };
    bot.state.target_aura_count = 3;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.resources.shadow_embrace_aura, .remaining_ms = 0 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.corruption.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[2] = .{ .caster_guid = 0, .spell_id = data.spells.unstable_affliction.spell_id, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.haunt.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target.target_guid);
}

test "planWithContext: Haunt cast in flight returns none" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.is_casting = 1;
    bot.state.casting_spell_id = data.spells.haunt.spell_id;
    bot.state.active_power = 8000;
    bot.state.active_power_max = 10000;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };
    bot.state.target_aura_count = 3;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.resources.shadow_embrace_aura, .remaining_ms = 0 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.corruption.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[2] = .{ .caster_guid = 0, .spell_id = data.spells.unstable_affliction.spell_id, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    try std.testing.expectEqual(Action.none, planWithContext(&ctx));
}

test "planWithContext: Curse of Agony missing casts Curse of Agony after Haunt" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = 8000;
    bot.state.active_power_max = 10000;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };
    bot.state.target_aura_count = 4;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.resources.shadow_embrace_aura, .remaining_ms = 0 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.corruption.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[2] = .{ .caster_guid = 0, .spell_id = data.spells.unstable_affliction.spell_id, .remaining_ms = 0 };
    bot.state.target_auras[3] = .{ .caster_guid = 0, .spell_id = data.spells.haunt.spell_id, .remaining_ms = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};

    const ctx = ctxNoEvents(bot, &world);
    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.curse_of_agony.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}

test "planWithContext: recent Shadow Bolt launch satisfies opener without visible Shadow Embrace aura" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.game_time_ms = 10_000;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };

    const event = proto.SpellEvent{
        .kind = @intFromEnum(proto.SpellEventKind.go),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x100,
        .caster_guid = 0x100,
        .spell_id = data.spells.shadow_bolt.spell_id,
        .flags = 0,
        .value_ms = 0,
        .game_time_ms = 10_000,
    };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{event}, false);

    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.corruption.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target_instant.target_guid);
}

test "planWithContext: recent Unstable Affliction launch prevents immediate duplicate cast" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = 0x100;
    bot.state.map_id = 1;
    bot.state.pet_guid = 0xbeef;
    bot.state.target_guid = 0xabc;
    bot.state.target_unit_reaction = 2;
    bot.state.game_time_ms = 10_000;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.fel_armor.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.resources.life_tap_glyph_aura, .remaining_ms = 0 };
    bot.state.target_aura_count = 2;
    bot.state.target_auras[0] = .{ .caster_guid = 0, .spell_id = data.resources.shadow_embrace_aura, .remaining_ms = 0 };
    bot.state.target_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.corruption.spell_id, .remaining_ms = 0 };

    const event = proto.SpellEvent{
        .kind = @intFromEnum(proto.SpellEventKind.go),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x100,
        .caster_guid = 0x100,
        .spell_id = data.spells.unstable_affliction.spell_id,
        .flags = 0,
        .value_ms = 0,
        .game_time_ms = 10_000,
    };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xabc;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{event}, false);

    const a = planWithContext(&ctx);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.haunt.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xabc), a.cast_target.target_guid);
}
