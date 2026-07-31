//! Marteaulourd (G4). Roster : assets/setup.md

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const spells_db = @import("../spells.zig");
const cooldown = @import("../cooldown.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const data = struct {
    pub const spells = struct {
        pub const seal_of_vengeance = spells_db.get(31801);
        pub const retribution_aura = spells_db.get(54043);
        pub const greater_blessing_of_might = spells_db.get(48934);
        pub const crusader_strike = spells_db.get(35395);
        pub const judgement_of_wisdom = spells_db.get(53408);
        pub const divine_storm = spells_db.get(53385);
        pub const consecration = spells_db.get(48819);
        pub const exorcism = spells_db.get(48801);
        pub const holy_wrath = spells_db.get(48817);
    };
    pub const resources = struct {};
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.seal_of_vengeance.spell_id };
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (!selfHasAura(bot.state, data.spells.seal_of_vengeance.spell_id)) {
        return .{ .cast_instant = data.spells.seal_of_vengeance.spell_id };
    }

    if (!selfHasAura(bot.state, data.spells.retribution_aura.spell_id)) {
        return .{ .cast_instant = data.spells.retribution_aura.spell_id };
    }

    const g = world_query.primaryHostileAttackGuid(bot.state, world) orelse return .none;

    if (cooldown.spellReady(bot.state, data.spells.crusader_strike.spell_id)) {
        return .{ .cast_target = .{ .spell_id = data.spells.crusader_strike.spell_id, .target_guid = g } };
    }

    if (cooldown.spellReady(bot.state, data.spells.judgement_of_wisdom.spell_id)) {
        return .{ .cast_target = .{ .spell_id = data.spells.judgement_of_wisdom.spell_id, .target_guid = g } };
    }

    if (cooldown.spellReady(bot.state, data.spells.divine_storm.spell_id)) {
        return .{ .cast_instant = data.spells.divine_storm.spell_id };
    }

    if (cooldown.spellReady(bot.state, data.spells.consecration.spell_id)) {
        return .{ .cast_instant = data.spells.consecration.spell_id };
    }

    if (cooldown.spellReady(bot.state, data.spells.exorcism.spell_id)) {
        return .{ .cast_target = .{ .spell_id = data.spells.exorcism.spell_id, .target_guid = g } };
    }

    if (cooldown.spellReady(bot.state, data.spells.holy_wrath.spell_id)) {
        return .{ .cast_instant = data.spells.holy_wrath.spell_id };
    }

    return .none;
}

fn makeHostileWorld(guid: u64, map_id: u32) [1]WorldSnapshot {
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = guid;
    scan.hp = 100;
    return .{.{
        .scan = scan,
        .map_id = map_id,
        .last_seen_ts_ns = 0,
    }};
}

fn makeBot(guid: u64, target_guid: u64, map_id: u32) BotSnapshot {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = guid;
    bot.state.map_id = map_id;
    bot.state.target_guid = target_guid;
    bot.state.target_unit_reaction = 2;
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.seal_of_vengeance.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.retribution_aura.spell_id, .remaining_ms = 0 };
    return bot;
}

test "plan: Seal of Vengeance missing casts it" {
    const bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    const a = plan(bot, &.{});
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.seal_of_vengeance.spell_id, a.cast_instant);
}

test "plan: Retribution Aura missing casts it" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.seal_of_vengeance.spell_id, .remaining_ms = 0 };
    const a = plan(bot, &.{});
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.retribution_aura.spell_id, a.cast_instant);
}

test "plan: no target returns none" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.player_aura_count = 2;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.seal_of_vengeance.spell_id, .remaining_ms = 0 };
    bot.state.player_auras[1] = .{ .caster_guid = 0, .spell_id = data.spells.retribution_aura.spell_id, .remaining_ms = 0 };
    const world: []const WorldSnapshot = &.{};
    try std.testing.expect(plan(bot, world) == .none);
}

test "plan: Crusader Strike first when all cooldowns ready" {
    const g: u64 = 0xaaa;
    const bot = makeBot(0x100, g, 533);
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.crusader_strike.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(g, a.cast_target.target_guid);
}

test "plan: Judgement when Crusader Strike on cooldown" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 533);
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.crusader_strike.spell_id, .category = 0, .remaining_ms = 2000, .duration_ms = 4000 };
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.judgement_of_wisdom.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(g, a.cast_target.target_guid);
}

test "plan: Divine Storm when CS and Judgement on cooldown" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 533);
    bot.state.cooldown_count = 2;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.crusader_strike.spell_id, .category = 0, .remaining_ms = 2000, .duration_ms = 4000 };
    bot.state.cooldowns[1] = .{ .spell_id = data.spells.judgement_of_wisdom.spell_id, .category = 0, .remaining_ms = 4000, .duration_ms = 10000 };
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.divine_storm.spell_id, a.cast_instant);
}

test "plan: Consecration when top 3 on cooldown" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 533);
    bot.state.cooldown_count = 3;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.crusader_strike.spell_id, .category = 0, .remaining_ms = 2000, .duration_ms = 4000 };
    bot.state.cooldowns[1] = .{ .spell_id = data.spells.judgement_of_wisdom.spell_id, .category = 0, .remaining_ms = 4000, .duration_ms = 10000 };
    bot.state.cooldowns[2] = .{ .spell_id = data.spells.divine_storm.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 10000 };
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.consecration.spell_id, a.cast_instant);
}

test "plan: Exorcism when top 4 on cooldown" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 533);
    bot.state.cooldown_count = 4;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.crusader_strike.spell_id, .category = 0, .remaining_ms = 2000, .duration_ms = 4000 };
    bot.state.cooldowns[1] = .{ .spell_id = data.spells.judgement_of_wisdom.spell_id, .category = 0, .remaining_ms = 4000, .duration_ms = 10000 };
    bot.state.cooldowns[2] = .{ .spell_id = data.spells.divine_storm.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 10000 };
    bot.state.cooldowns[3] = .{ .spell_id = data.spells.consecration.spell_id, .category = 0, .remaining_ms = 3000, .duration_ms = 8000 };
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.exorcism.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(g, a.cast_target.target_guid);
}

test "plan: Holy Wrath when top 5 on cooldown" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 533);
    bot.state.cooldown_count = 5;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.crusader_strike.spell_id, .category = 0, .remaining_ms = 2000, .duration_ms = 4000 };
    bot.state.cooldowns[1] = .{ .spell_id = data.spells.judgement_of_wisdom.spell_id, .category = 0, .remaining_ms = 4000, .duration_ms = 10000 };
    bot.state.cooldowns[2] = .{ .spell_id = data.spells.divine_storm.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 10000 };
    bot.state.cooldowns[3] = .{ .spell_id = data.spells.consecration.spell_id, .category = 0, .remaining_ms = 3000, .duration_ms = 8000 };
    bot.state.cooldowns[4] = .{ .spell_id = data.spells.exorcism.spell_id, .category = 0, .remaining_ms = 6000, .duration_ms = 15000 };
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.holy_wrath.spell_id, a.cast_instant);
}

test "plan: all on cooldown returns none" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 533);
    bot.state.cooldown_count = 6;
    bot.state.cooldowns[0] = .{ .spell_id = data.spells.crusader_strike.spell_id, .category = 0, .remaining_ms = 2000, .duration_ms = 4000 };
    bot.state.cooldowns[1] = .{ .spell_id = data.spells.judgement_of_wisdom.spell_id, .category = 0, .remaining_ms = 4000, .duration_ms = 10000 };
    bot.state.cooldowns[2] = .{ .spell_id = data.spells.divine_storm.spell_id, .category = 0, .remaining_ms = 5000, .duration_ms = 10000 };
    bot.state.cooldowns[3] = .{ .spell_id = data.spells.consecration.spell_id, .category = 0, .remaining_ms = 3000, .duration_ms = 8000 };
    bot.state.cooldowns[4] = .{ .spell_id = data.spells.exorcism.spell_id, .category = 0, .remaining_ms = 6000, .duration_ms = 15000 };
    bot.state.cooldowns[5] = .{ .spell_id = data.spells.holy_wrath.spell_id, .category = 0, .remaining_ms = 8000, .duration_ms = 30000 };
    const world = makeHostileWorld(g, 533);
    try std.testing.expect(plan(bot, &world) == .none);
}
