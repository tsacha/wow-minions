const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const context = @import("../context.zig");
const spells_db = @import("../spells.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;
const CombatContext = context.CombatContext;

pub const data = struct {
    pub const spells = struct {
        pub const arcane_brilliance = spells_db.get(43002);
        pub const arcane_blast = spells_db.get(42897);
        pub const arcane_missiles = spells_db.get(42846);
        pub const arcane_power = spells_db.get(12042);
        pub const evocation = spells_db.get(12051);
        pub const icy_veins = spells_db.get(12472);
        pub const mage_armor = spells_db.get(43024);
        pub const mirror_image = spells_db.get(55342);
    };
    pub const resources = struct {};
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.arcane_brilliance.spell_id };
}

pub fn burstAction(step: usize) ?Action {
    return switch (step) {
        0 => .{ .cast_instant = data.spells.arcane_power.spell_id },
        1 => .{ .cast_instant = data.spells.icy_veins.spell_id },
        2 => .{ .cast_instant = data.spells.mirror_image.spell_id },
        else => null,
    };
}

pub fn threatPlan(ctx: *const CombatContext) Action {
    if (!ctx.threat_high) return .none;
    if (ctx.bot.state.is_casting != 0 or ctx.bot.state.is_channeling != 0) return .none;
    if (!spellReady(ctx.bot.state, data.spells.mirror_image.spell_id)) return .none;
    return .{ .cast_instant = data.spells.mirror_image.spell_id };
}

const mana_power_type: u32 = 0;
const evocation_mana_threshold_pct: u32 = 0;
const arcane_blast_max_stacks: u32 = 4;
const arcane_blast_missiles_window_ms: u32 = 2500;
const arcane_blast_aura_id: u32 = 36032;

fn spellReady(state: proto.State, spell_id: u32) bool {
    return !world_query.hasCooldown(&state.cooldowns, state.cooldown_count, spell_id);
}

fn manaPct(state: proto.State) ?u32 {
    if (state.active_power_type != mana_power_type) return null;
    if (state.active_power_max == 0) return null;
    return @intCast((state.active_power * 100) / state.active_power_max);
}

fn outOfMana(state: proto.State) bool {
    if (state.active_power_type != mana_power_type) return false;
    return state.active_power == 0 or manaPct(state) == evocation_mana_threshold_pct;
}

fn hasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(state.player_auras[0..], state.player_aura_count, spell_id);
}

fn auraRemainingMs(state: proto.State, spell_id: u32) ?u32 {
    const count = @min(state.player_aura_count, state.player_auras.len);
    for (state.player_auras[0..count]) |aura| {
        if (aura.spell_id == spell_id) return aura.remaining_ms;
    }
    return null;
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    if (bot.state.is_channeling != 0) return .none;

    if (!proto.hasUnitFlag(bot.state.unit_flags, .in_combat) and
        !hasAura(bot.state, data.spells.mage_armor.spell_id))
    {
        return .{ .cast_instant = data.spells.mage_armor.spell_id };
    }

    if (proto.hasUnitFlag(bot.state.unit_flags, .in_combat) and
        outOfMana(bot.state) and
        spellReady(bot.state, data.spells.evocation.spell_id))
    {
        return .{ .cast = data.spells.evocation.spell_id };
    }

    const g = world_query.primaryHostileAttackGuid(bot.state, world) orelse return .none;

    var ab_stacks: u32 = 0;
    const aura_count = @min(bot.state.player_aura_count, bot.state.player_auras.len);
    for (bot.state.player_auras[0..aura_count]) |aura| {
        if (aura.spell_id != arcane_blast_aura_id) continue;
        ab_stacks = aura.stacks;
        break;
    }

    const ab_remaining_ms = auraRemainingMs(bot.state, arcane_blast_aura_id) orelse 0;
    if (ab_stacks >= arcane_blast_max_stacks and
        ab_remaining_ms > arcane_blast_missiles_window_ms and
        spellReady(bot.state, data.spells.arcane_missiles.spell_id))
    {
        return .{ .cast_target = .{ .spell_id = data.spells.arcane_missiles.spell_id, .target_guid = g } };
    }

    return .{ .cast_target = .{ .spell_id = data.spells.arcane_blast.spell_id, .target_guid = g } };
}

test "plan: Arcane Blast when full mana and no debuff" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 533;
    bot.state.target_guid = 0xaaa;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power_type = mana_power_type;
    bot.state.active_power = 15000;
    bot.state.active_power_max = 15000;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xaaa;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 533,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.arcane_blast.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xaaa), a.cast_target.target_guid);
}

test "plan: Mage Armor out of combat when missing" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 533;
    bot.state.active_power_type = mana_power_type;
    bot.state.active_power = 15000;
    bot.state.active_power_max = 15000;

    const world: []const WorldSnapshot = &.{};

    const a = plan(bot, world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.mage_armor.spell_id, a.cast_instant);
}

test "plan: no Mage Armor refresh in combat" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 533;
    bot.state.active_power_type = mana_power_type;
    bot.state.active_power = 15000;
    bot.state.active_power_max = 15000;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);

    const world: []const WorldSnapshot = &.{};

    try std.testing.expect(plan(bot, world) == .none);
}

test "plan: Arcane Missiles when Arcane Blast stacks reach four and debuff is fresh" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 533;
    bot.state.target_guid = 0xaaa;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power_type = mana_power_type;
    bot.state.active_power = 9000;
    bot.state.active_power_max = 15000;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.player_auras[0] = .{
        .spell_id = arcane_blast_aura_id,
        .remaining_ms = 5000,
        .caster_guid = bot.state.guid,
        .stacks = 4,
    };
    bot.state.player_aura_count = 1;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xaaa;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 533,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.arcane_missiles.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xaaa), a.cast_target.target_guid);
}

test "plan: Arcane Blast when Arcane Blast debuff is nearly expired" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 533;
    bot.state.target_guid = 0xaaa;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power_type = mana_power_type;
    bot.state.active_power = 12000;
    bot.state.active_power_max = 15000;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    bot.state.player_auras[0] = .{
        .spell_id = arcane_blast_aura_id,
        .remaining_ms = 1500,
        .caster_guid = bot.state.guid,
        .stacks = 4,
    };
    bot.state.player_aura_count = 1;

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xaaa;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 533,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target);
    try std.testing.expectEqual(data.spells.arcane_blast.spell_id, a.cast_target.spell_id);
    try std.testing.expectEqual(@as(u64, 0xaaa), a.cast_target.target_guid);
}

test "plan: Evocation when out of mana" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.map_id = 533;
    bot.state.target_guid = 0xaaa;
    bot.state.target_unit_reaction = 2;
    bot.state.active_power_type = mana_power_type;
    bot.state.active_power = 0;
    bot.state.active_power_max = 15000;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = 0xaaa;
    scan.hp = 100;
    const world = [_]WorldSnapshot{.{
        .scan = scan,
        .map_id = 533,
        .last_seen_ts_ns = 0,
    }};

    const a = plan(bot, &world);
    try std.testing.expect(a == .cast);
    try std.testing.expectEqual(data.spells.evocation.spell_id, a.cast);
}

test "plan: none when channeling" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.is_channeling = 1;
    bot.state.active_power_type = mana_power_type;
    bot.state.active_power = 15000;
    bot.state.active_power_max = 15000;

    const world: []const WorldSnapshot = &.{};

    try std.testing.expect(plan(bot, world) == .none);
}

test "plan: Evocation even without hostile target when in combat" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.active_power_type = mana_power_type;
    bot.state.active_power = 0;
    bot.state.active_power_max = 15000;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);

    const world: []const WorldSnapshot = &.{};

    const a = plan(bot, world);
    try std.testing.expect(a == .cast);
    try std.testing.expectEqual(data.spells.evocation.spell_id, a.cast);
}

test "plan: no Evocation out of combat" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.active_power_type = mana_power_type;
    bot.state.active_power = 0;
    bot.state.active_power_max = 15000;
    bot.state.player_auras[0] = .{
        .spell_id = data.spells.mage_armor.spell_id,
        .remaining_ms = 30_000,
        .caster_guid = bot.state.guid,
    };
    bot.state.player_aura_count = 1;

    const world: []const WorldSnapshot = &.{};

    try std.testing.expect(plan(bot, world) == .none);
}

test "plan: no cast without hostile target and mana ok" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.state.active_power_type = mana_power_type;
    bot.state.active_power = 500;
    bot.state.active_power_max = 15000;
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    const world: []const WorldSnapshot = &.{};
    try std.testing.expect(plan(bot, world) == .none);
}
