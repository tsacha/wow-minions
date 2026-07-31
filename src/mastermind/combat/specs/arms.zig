//! Microchoc (Groupe 1). Roster : assets/setup.md

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const spells_db = @import("../spells.zig");
const Action = @import("../action.zig").Action;
const rage_mod = @import("../rage.zig");
const world_query = @import("../world_query.zig");
const cooldown = @import("../cooldown.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const data = struct {
    pub const spells = struct {
        pub const battle_stance = spells_db.get(2457);
        pub const battle_shout = spells_db.get(47436);
        pub const commanding_shout = spells_db.get(47440);
        pub const recklessness = spells_db.get(1719);
        pub const rend = spells_db.get(47465);
        pub const sunder_armor = spells_db.get(7386);
        pub const execute = spells_db.get(47471);
        pub const overpower = spells_db.get(7384);
        pub const sudden_death = spells_db.get(52437);
        pub const mortal_strike = spells_db.get(47486);
        pub const heroic_strike = spells_db.get(47450);
        pub const taste_for_blood = spells_db.get(56638);
    };
    pub const resources = struct {};
};

const battle_stance_form: u32 = 17;
const execute_hp_pct: u32 = 20;
const battle_shout_min_rage_points: u32 = 10;
const commanding_shout_min_rage_points: u32 = 10;
const rage_cost_sunder_armor_points: u32 = 15;
const heroic_strike_min_rage_points: u32 = 60;
const sunder_armor_aura_spell_id: u32 = 58567;
const sunder_armor_max_stacks: u32 = 5;
const sunder_armor_refresh_ms: u32 = 1500;

fn spellReady(state: proto.State, spell_id: u32) bool {
    return cooldown.spellReady(state, spell_id);
}

fn targetAura(state: proto.State, spell_id: u32) ?proto.AuraEntry {
    const n = @min(state.target_aura_count, state.target_auras.len);
    for (state.target_auras[0..n]) |aura| {
        if (aura.spell_id == spell_id) return aura;
    }
    return null;
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

fn targetHealthPct(bot: BotSnapshot, world: []const WorldSnapshot, guid: u64) ?u32 {
    const scan = world_query.scanForGuidOnMap(world, guid, bot.state.map_id) orelse return null;
    if (scan.hp_max == 0) return null;
    return @as(u32, @intCast((scan.hp * 100) / scan.hp_max));
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (bot.state.shapeshift_form != battle_stance_form) {
        return .{ .cast_instant = data.spells.battle_stance.spell_id };
    }

    const in_combat = proto.hasUnitFlag(bot.state.unit_flags, .in_combat);

    if (in_combat and
        rage_mod.toPoints(bot.state.active_power) >= battle_shout_min_rage_points and
        !selfHasAura(bot.state, data.spells.battle_shout.spell_id))
    {
        return .{ .cast_instant = data.spells.battle_shout.spell_id };
    }

    if (in_combat and
        rage_mod.toPoints(bot.state.active_power) >= commanding_shout_min_rage_points and
        !selfHasAura(bot.state, data.spells.commanding_shout.spell_id))
    {
        return .{ .cast_instant = data.spells.commanding_shout.spell_id };
    }

    const g = world_query.primaryHostileAttackGuid(bot.state, world) orelse return .none;
    const hp_pct = targetHealthPct(bot, world, g) orelse 100;

    const rage_points = rage_mod.toPoints(bot.state.active_power);
    if (spellReady(bot.state, data.spells.rend.spell_id) and
        targetAura(bot.state, data.spells.rend.spell_id) == null)
    {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.rend.spell_id, .target_guid = g } };
    }

    const sunder_armor_aura = targetAura(bot.state, sunder_armor_aura_spell_id);
    if (rage_points >= rage_cost_sunder_armor_points and
        spellReady(bot.state, data.spells.sunder_armor.spell_id) and
        (sunder_armor_aura == null or
            sunder_armor_aura.?.stacks < sunder_armor_max_stacks or
            sunder_armor_aura.?.remaining_ms <= sunder_armor_refresh_ms))
    {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.sunder_armor.spell_id, .target_guid = g } };
    }

    if ((hp_pct < execute_hp_pct or selfHasAura(bot.state, data.spells.sudden_death.spell_id)) and
        spellReady(bot.state, data.spells.execute.spell_id))
    {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.execute.spell_id, .target_guid = g } };
    }

    if (selfHasAura(bot.state, data.spells.taste_for_blood.spell_id) and
        spellReady(bot.state, data.spells.overpower.spell_id))
    {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.overpower.spell_id, .target_guid = g } };
    }

    if (spellReady(bot.state, data.spells.mortal_strike.spell_id)) {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.mortal_strike.spell_id, .target_guid = g } };
    }

    if (rage_points >= heroic_strike_min_rage_points and
        spellReady(bot.state, data.spells.heroic_strike.spell_id))
    {
        return .{ .cast_target_instant = .{ .spell_id = data.spells.heroic_strike.spell_id, .target_guid = g } };
    }

    return .none;
}

pub fn burstAction(step: usize) ?Action {
    return switch (step) {
        0 => .{ .cast_instant = data.spells.recklessness.spell_id },
        else => null,
    };
}

fn makeScan(guid: u64, hp: u32, map_id: u32) WorldSnapshot {
    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = guid;
    scan.hp = hp;
    scan.hp_max = 100;
    return .{ .scan = scan, .map_id = map_id, .last_seen_ts_ns = 0 };
}

fn addTargetAura(state: *proto.State, spell_id: u32, remaining_ms: u32, stacks: u32) void {
    const i = state.target_aura_count;
    state.target_auras[i] = .{ .spell_id = spell_id, .caster_guid = 1, .remaining_ms = remaining_ms, .stacks = stacks };
    state.target_aura_count = i + 1;
}

fn makeBot(guid: u64, target_guid: u64, map_id: u32, rage: u32) BotSnapshot {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.guid = guid;
    bot.state.map_id = map_id;
    bot.state.target_guid = target_guid;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power = rage;
    bot.state.active_power_max = 100;
    bot.state.shapeshift_form = battle_stance_form;
    return bot;
}

fn addBothShouts(bot: *BotSnapshot) void {
    const i = bot.state.player_aura_count;
    bot.state.player_auras[i] = .{ .caster_guid = 0, .spell_id = data.spells.battle_shout.spell_id, .remaining_ms = 120000, .stacks = 0 };
    bot.state.player_auras[i + 1] = .{ .caster_guid = 0, .spell_id = data.spells.commanding_shout.spell_id, .remaining_ms = 120000, .stacks = 0 };
    bot.state.player_aura_count = i + 2;
}

test "plan: enters battle stance before combat actions" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    bot.state.shapeshift_form = 0;
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.battle_stance.spell_id, a.cast_instant);
}

test "plan: battle shout refreshes in combat before commanding shout" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.player_aura_count = 0;
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.battle_shout.spell_id, a.cast_instant);
}

test "plan: commanding shout refreshes in combat when battle shout is present" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.player_aura_count = 1;
    bot.state.player_auras[0] = .{ .caster_guid = 0, .spell_id = data.spells.battle_shout.spell_id, .remaining_ms = 120000 };
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.commanding_shout.spell_id, a.cast_instant);
}

test "plan: sunder armor when missing and enough rage" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 15000, 1);
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.sunder_armor.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: rend before sunder armor" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    addBothShouts(&bot);
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.rend.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: mortal strike when sunder armor already at five stacks" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 15000, 1);
    addTargetAura(&bot.state, sunder_armor_aura_spell_id, 2000, 5);
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.mortal_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: refreshes sunder armor below five stacks" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 15000, 1);
    addTargetAura(&bot.state, sunder_armor_aura_spell_id, 10000, 4);
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.sunder_armor.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: mortal strike before heroic strike with healthy rend" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 15000, 1);
    addTargetAura(&bot.state, sunder_armor_aura_spell_id, 2000, 5);
    addTargetAura(&bot.state, data.spells.mortal_strike.spell_id, 12000, 1);
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.mortal_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: mortal strike when no higher priority ability is ready" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 140);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 5000, 1);
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.mortal_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: execute at sub 20 percent" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 15000, 1);
    addTargetAura(&bot.state, sunder_armor_aura_spell_id, 2000, 5);
    const world = [_]WorldSnapshot{makeScan(g, 19, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.execute.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: execute with sudden death above 20 percent" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 5000, 1);
    addTargetAura(&bot.state, sunder_armor_aura_spell_id, 2000, 5);
    const sd_idx = bot.state.player_aura_count;
    bot.state.player_auras[sd_idx] = .{ .caster_guid = 0, .spell_id = data.spells.sudden_death.spell_id, .remaining_ms = 10000 };
    bot.state.player_aura_count = sd_idx + 1;
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.execute.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: overpower when taste for blood is present" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 15000, 1);
    addTargetAura(&bot.state, sunder_armor_aura_spell_id, 2000, 5);
    const tfb_idx = bot.state.player_aura_count;
    bot.state.player_auras[tfb_idx] = .{ .caster_guid = 0, .spell_id = data.spells.taste_for_blood.spell_id, .remaining_ms = 5000 };
    bot.state.player_aura_count = tfb_idx + 1;
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.overpower.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: mortal strike before heroic strike" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 5000, 1);
    addTargetAura(&bot.state, sunder_armor_aura_spell_id, 2000, 5);
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.mortal_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: mortal strike is used before heroic strike when rend is safe" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 150);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 12000, 1);
    addTargetAura(&bot.state, sunder_armor_aura_spell_id, 15000, 5);
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.mortal_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: heroic strike when mortal strike on cooldown" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 600);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 5000, 1);
    addTargetAura(&bot.state, sunder_armor_aura_spell_id, 15000, 5);
    bot.state.cooldown_count = 1;
    bot.state.cooldowns[0] = .{
        .spell_id = data.spells.mortal_strike.spell_id,
        .category = 0,
        .remaining_ms = 1000,
        .duration_ms = 6000,
    };
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.heroic_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: heroic strike while sunder armor is on cooldown" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 600);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 5000, 1);
    bot.state.cooldown_count = 2;
    bot.state.cooldowns[0] = .{
        .spell_id = data.spells.mortal_strike.spell_id,
        .category = 0,
        .remaining_ms = 1000,
        .duration_ms = 6000,
    };
    bot.state.cooldowns[1] = .{
        .spell_id = data.spells.sunder_armor.spell_id,
        .category = 0,
        .remaining_ms = 1000,
        .duration_ms = 1500,
    };
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.heroic_strike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: no heroic strike below rage threshold" {
    const g: u64 = 0xaaa;
    var bot = makeBot(0x100, g, 1, 500);
    addBothShouts(&bot);
    addTargetAura(&bot.state, data.spells.rend.spell_id, 5000, 1);
    addTargetAura(&bot.state, sunder_armor_aura_spell_id, 15000, 5);
    const world = [_]WorldSnapshot{makeScan(g, 100, 1)};
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.mortal_strike.spell_id, a.cast_target_instant.spell_id);
}
