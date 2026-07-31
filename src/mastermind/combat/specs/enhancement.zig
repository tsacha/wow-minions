//! Chocazur (G1). Roster : assets/setup.md

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const spells_db = @import("../spells.zig");
const cooldown = @import("../cooldown.zig");
const aura = @import("../aura.zig");
const Action = @import("../action.zig").Action;
const world_query = @import("../world_query.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const data = struct {
    pub const spells = struct {
        pub const bloodlust = spells_db.get(2825);
        pub const fire_elemental_totem = spells_db.get(2894);
        pub const feral_spirit = spells_db.get(51533);
        pub const lightning_bolt = spells_db.get(49238);
        pub const stormstrike = spells_db.get(17364);
        pub const shamanistic_rage = spells_db.get(30823);
        pub const flame_shock = spells_db.get(49233);
        pub const magma_totem = spells_db.get(58734);
        pub const lightning_shield = spells_db.get(49281);
        pub const earth_shock = spells_db.get(49231);
        pub const fire_nova = spells_db.get(61657);
        pub const lava_lash = spells_db.get(60103);
        pub const maelstrom_weapon = spells_db.get(53817);
    };
    pub const resources = struct {};
};

pub fn raidBuffAction() ?Action {
    return .{ .cast_instant = data.spells.lightning_shield.spell_id };
}

const maelstrom_weapon_max_stacks: u32 = 5;

fn selfAuraStacks(state: proto.State, spell_id: u32) u32 {
    const n = @min(state.player_aura_count, state.player_auras.len);
    for (state.player_auras[0..n]) |a| {
        if (a.spell_id == spell_id) return @max(a.stacks, 1);
    }
    return 0;
}

fn targetHasAura(state: proto.State, spell_id: u32) bool {
    return aura.remainingMsOnTarget(state, spell_id) != null;
}

fn selfHasAura(state: proto.State, spell_id: u32) bool {
    return world_query.hasAura(&state.player_auras, state.player_aura_count, spell_id);
}

fn inCombat(state: proto.State) bool {
    return proto.hasUnitFlag(state.unit_flags, .in_combat);
}

fn fireTotemRemainingMs(state: proto.State) u32 {
    return proto.totemSlot(&state.totems, .fire).remaining_ms;
}

pub fn plan(bot: BotSnapshot, world: []const WorldSnapshot) Action {
    // 1. Maelstrom Weapon at 5 stacks → Lightning Bolt on target
    if (selfAuraStacks(bot.state, data.spells.maelstrom_weapon.spell_id) >= maelstrom_weapon_max_stacks) {
        if (world_query.primaryHostileAttackGuid(bot.state, world)) |g| {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.lightning_bolt.spell_id, .target_guid = g } };
        }
    }

    // 2. Stormstrike on cooldown
    if (cooldown.spellReady(bot.state, data.spells.stormstrike.spell_id)) {
        if (world_query.primaryHostileAttackGuid(bot.state, world)) |g| {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.stormstrike.spell_id, .target_guid = g } };
        }
    }

    // 3. Shamanistic Rage on cooldown, combat only
    if (inCombat(bot.state) and cooldown.spellReady(bot.state, data.spells.shamanistic_rage.spell_id)) {
        return .{ .cast_instant = data.spells.shamanistic_rage.spell_id };
    }

    // 4. Flame Shock debuff to maintain on target
    if (world_query.primaryHostileAttackGuid(bot.state, world)) |g| {
        if (!targetHasAura(bot.state, data.spells.flame_shock.spell_id)) {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.flame_shock.spell_id, .target_guid = g } };
        }
    }

    // 5. Magma Totem when the fire slot is empty
    if (inCombat(bot.state) and fireTotemRemainingMs(bot.state) == 0) {
        return .{ .cast_instant = data.spells.magma_totem.spell_id };
    }

    // 6. Lightning Shield to maintain on self
    if (!selfHasAura(bot.state, data.spells.lightning_shield.spell_id)) {
        return .{ .cast_instant = data.spells.lightning_shield.spell_id };
    }

    // 7. Earth Shock on cooldown if Flame Shock active on target
    if (cooldown.spellReady(bot.state, data.spells.earth_shock.spell_id)) {
        if (targetHasAura(bot.state, data.spells.flame_shock.spell_id)) {
            if (world_query.primaryHostileAttackGuid(bot.state, world)) |g| {
                return .{ .cast_target_instant = .{ .spell_id = data.spells.earth_shock.spell_id, .target_guid = g } };
            }
        }
    }

    // 8. Fire Nova only in combat
    if (inCombat(bot.state) and cooldown.spellReady(bot.state, data.spells.fire_nova.spell_id)) {
        return .{ .cast_instant = data.spells.fire_nova.spell_id };
    }

    // 9. Lava Lash (non-priority)
    if (cooldown.spellReady(bot.state, data.spells.lava_lash.spell_id)) {
        if (world_query.primaryHostileAttackGuid(bot.state, world)) |g| {
            return .{ .cast_target_instant = .{ .spell_id = data.spells.lava_lash.spell_id, .target_guid = g } };
        }
    }

    return .none;
}

pub fn burstAction(step: usize) ?Action {
    return switch (step) {
        0 => .{ .cast_instant = data.spells.bloodlust.spell_id },
        1 => .{ .cast_instant = data.spells.fire_elemental_totem.spell_id },
        2 => .{ .cast_instant = data.spells.feral_spirit.spell_id },
        else => null,
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

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
    return bot;
}

fn setPlayerAura(bot: *BotSnapshot, spell_id: u32, stacks: u32) void {
    const i = bot.state.player_aura_count;
    bot.state.player_auras[i] = .{ .caster_guid = 0, .spell_id = spell_id, .remaining_ms = 0, .stacks = stacks };
    bot.state.player_aura_count = i + 1;
}

fn setTargetAura(bot: *BotSnapshot, spell_id: u32) void {
    const i = bot.state.target_aura_count;
    bot.state.target_auras[i] = .{ .caster_guid = bot.state.guid, .spell_id = spell_id, .remaining_ms = 0 };
    bot.state.target_aura_count = i + 1;
}

fn setCooldown(bot: *BotSnapshot, spell_id: u32, remaining_ms: u32) void {
    const i = bot.state.cooldown_count;
    bot.state.cooldowns[i] = .{ .spell_id = spell_id, .category = 0, .remaining_ms = remaining_ms, .duration_ms = remaining_ms * 2 };
    bot.state.cooldown_count = i + 1;
}

fn setFireTotem(bot: *BotSnapshot, remaining_ms: u32) void {
    bot.state.totems[@intFromEnum(proto.TotemElement.fire)].remaining_ms = remaining_ms;
}

test "plan: no target returns none" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    setPlayerAura(&bot, data.spells.lightning_shield.spell_id, 1);
    setCooldown(&bot, data.spells.shamanistic_rage.spell_id, 60000);
    setCooldown(&bot, data.spells.fire_nova.spell_id, 5000);
    const world: []const WorldSnapshot = &.{};
    try std.testing.expect(plan(bot, world) == .none);
}

test "plan: Lightning Shield missing casts it" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    setCooldown(&bot, data.spells.shamanistic_rage.spell_id, 60000);
    const world: []const WorldSnapshot = &.{};
    const a = plan(bot, world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.lightning_shield.spell_id, a.cast_instant);
}

test "plan: MW5 on self casts Lightning Bolt on target" {
    const g: u64 = 0xbbb;
    var bot = makeBot(0x100, g, 533);
    setPlayerAura(&bot, data.spells.maelstrom_weapon.spell_id, 5);
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.lightning_bolt.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: MW4 does not cast Lightning Bolt" {
    const g: u64 = 0xbbb;
    var bot = makeBot(0x100, g, 533);
    setPlayerAura(&bot, data.spells.maelstrom_weapon.spell_id, 4);
    setPlayerAura(&bot, data.spells.lightning_shield.spell_id, 1);
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    // Should skip MW4 and proceed down the priority list
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.stormstrike.spell_id, a.cast_target_instant.spell_id);
}

test "plan: Stormstrike ready on cooldown" {
    const g: u64 = 0xbbb;
    var bot = makeBot(0x100, g, 533);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    setFireTotem(&bot, 12000);
    setPlayerAura(&bot, data.spells.lightning_shield.spell_id, 1);
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.stormstrike.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: Shamanistic Rage on cooldown" {
    const g: u64 = 0xbbb;
    var bot = makeBot(0x100, g, 533);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    setFireTotem(&bot, 12000);
    setPlayerAura(&bot, data.spells.lightning_shield.spell_id, 1);
    setTargetAura(&bot, data.spells.flame_shock.spell_id);
    setCooldown(&bot, data.spells.stormstrike.spell_id, 2000);
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.shamanistic_rage.spell_id, a.cast_instant);
}

test "plan: Flame Shock missing on target casts it" {
    const g: u64 = 0xbbb;
    var bot = makeBot(0x100, g, 533);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    setFireTotem(&bot, 12000);
    setPlayerAura(&bot, data.spells.lightning_shield.spell_id, 1);
    setCooldown(&bot, data.spells.stormstrike.spell_id, 2000);
    setCooldown(&bot, data.spells.shamanistic_rage.spell_id, 60000);
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.flame_shock.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: Earth Shock on CD when Flame Shock active" {
    const g: u64 = 0xbbb;
    var bot = makeBot(0x100, g, 533);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    setFireTotem(&bot, 12000);
    setPlayerAura(&bot, data.spells.lightning_shield.spell_id, 1);
    setTargetAura(&bot, data.spells.flame_shock.spell_id);
    setCooldown(&bot, data.spells.stormstrike.spell_id, 2000);
    setCooldown(&bot, data.spells.shamanistic_rage.spell_id, 60000);
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.earth_shock.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: Earth Shock skipped when Flame Shock not on target" {
    const g: u64 = 0xbbb;
    var bot = makeBot(0x100, g, 533);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    setFireTotem(&bot, 12000);
    setPlayerAura(&bot, data.spells.lightning_shield.spell_id, 1);
    setCooldown(&bot, data.spells.stormstrike.spell_id, 2000);
    setCooldown(&bot, data.spells.shamanistic_rage.spell_id, 60000);
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    // Should cast Flame Shock first, not Earth Shock
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.flame_shock.spell_id, a.cast_target_instant.spell_id);
}

test "plan: Fire Nova only in combat" {
    const g: u64 = 0xbbb;
    var bot = makeBot(0x100, g, 533);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    setFireTotem(&bot, 12000);
    setPlayerAura(&bot, data.spells.lightning_shield.spell_id, 1);
    setTargetAura(&bot, data.spells.flame_shock.spell_id);
    setCooldown(&bot, data.spells.stormstrike.spell_id, 2000);
    setCooldown(&bot, data.spells.shamanistic_rage.spell_id, 60000);
    setCooldown(&bot, data.spells.earth_shock.spell_id, 2000);
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.fire_nova.spell_id, a.cast_instant);
}

test "plan: Magma Totem before Lightning Shield when fire slot empty" {
    const g: u64 = 0xbbb;
    var bot = makeBot(0x100, g, 533);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    setPlayerAura(&bot, data.spells.lightning_shield.spell_id, 1);
    setTargetAura(&bot, data.spells.flame_shock.spell_id);
    setCooldown(&bot, data.spells.stormstrike.spell_id, 2000);
    setCooldown(&bot, data.spells.shamanistic_rage.spell_id, 60000);
    setCooldown(&bot, data.spells.earth_shock.spell_id, 2000);
    setCooldown(&bot, data.spells.fire_nova.spell_id, 5000);
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_instant);
    try std.testing.expectEqual(data.spells.magma_totem.spell_id, a.cast_instant);
}

test "plan: Lava Lash non-priority" {
    const g: u64 = 0xbbb;
    var bot = makeBot(0x100, g, 533);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    setFireTotem(&bot, 12000);
    setPlayerAura(&bot, data.spells.lightning_shield.spell_id, 1);
    setTargetAura(&bot, data.spells.flame_shock.spell_id);
    setCooldown(&bot, data.spells.stormstrike.spell_id, 2000);
    setCooldown(&bot, data.spells.shamanistic_rage.spell_id, 60000);
    setCooldown(&bot, data.spells.earth_shock.spell_id, 2000);
    setCooldown(&bot, data.spells.fire_nova.spell_id, 5000);
    const world = makeHostileWorld(g, 533);
    const a = plan(bot, &world);
    try std.testing.expect(a == .cast_target_instant);
    try std.testing.expectEqual(data.spells.lava_lash.spell_id, a.cast_target_instant.spell_id);
    try std.testing.expectEqual(g, a.cast_target_instant.target_guid);
}

test "plan: all on cooldown returns none" {
    const g: u64 = 0xbbb;
    var bot = makeBot(0x100, g, 533);
    bot.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    setFireTotem(&bot, 12000);
    setPlayerAura(&bot, data.spells.lightning_shield.spell_id, 1);
    setTargetAura(&bot, data.spells.flame_shock.spell_id);
    setCooldown(&bot, data.spells.stormstrike.spell_id, 2000);
    setCooldown(&bot, data.spells.shamanistic_rage.spell_id, 60000);
    setCooldown(&bot, data.spells.earth_shock.spell_id, 2000);
    setCooldown(&bot, data.spells.fire_nova.spell_id, 5000);
    setCooldown(&bot, data.spells.lava_lash.spell_id, 3000);
    const world = makeHostileWorld(g, 533);
    try std.testing.expect(plan(bot, &world) == .none);
}

test "burstAction: bloodlust then fire elemental then feral spirit" {
    const a0 = burstAction(0) orelse return error.TestUnexpectedResult;
    const a1 = burstAction(1) orelse return error.TestUnexpectedResult;
    const a2 = burstAction(2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(data.spells.bloodlust.spell_id, a0.cast_instant);
    try std.testing.expectEqual(data.spells.fire_elemental_totem.spell_id, a1.cast_instant);
    try std.testing.expectEqual(data.spells.feral_spirit.spell_id, a2.cast_instant);
    try std.testing.expect(burstAction(3) == null);
}
