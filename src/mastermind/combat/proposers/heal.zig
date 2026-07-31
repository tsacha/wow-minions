const proto = @import("protocol");
const action_mod = @import("../action.zig");
const class_spec = @import("../class_spec.zig");
const context = @import("../context.zig");
const encounter = @import("../encounters/mod.zig");
const intent = @import("../intent/mod.zig");
const registry_mod = @import("registry");
const assignments = @import("../assignments.zig");
const spec_registry = @import("../specs/spec_registry.zig");

const Action = action_mod.Action;
const ActiveIntent = intent.ActiveIntent;
const CombatContext = context.CombatContext;
const Spell = @import("../spells.zig").Spell;
const world_query = @import("../world_query.zig");

const heal_intent_ttl_ms: u32 = proto.brain_tick_ms * 5;
const resto_shaman_tidal_waves_aura_id: u32 = 53390;
const resto_shaman_tidal_waves_big_heal_hp_ratio: f32 = 0.70;
const emergency_cooldown_ttl_ms: u32 = proto.brain_tick_ms * 2;
const tranquility_spell_id: u32 = 48447;
const divine_hymn_spell_id: u32 = 64843;

pub fn proposeIntent(ctx: *const CombatContext) ?ActiveIntent {
    if (ctx.role != .healer) return null;
    if (ctx.bot.state.is_casting != 0 or ctx.bot.state.is_channeling != 0) return null;

    if (!ctx.operator_fight_started and encounter.mapUsesOperatorPrepGate(ctx.bot.state.map_id)) {
        return null;
    }

    const meta = spec_registry.meta(ctx.spec);

    if (meta.tank_emergency_cooldown) |cooldown| {
        if (emergencyTankTarget(ctx, cooldown)) |target_guid| {
            return .{
                .intent = .{ .casting_scripted = .{
                    .spell_id = cooldown.spell.spell_id,
                    .target_guid = target_guid,
                    .instant = true,
                } },
                .priority = .role,
                .created_at_ms = ctx.game_time_ms,
                .max_age_ms = heal_intent_ttl_ms,
                .source = .role_heal_move,
            };
        }
    }

    if (meta.heal_emergency_cooldown) |cooldown| {
        if (shouldUseEmergencyCooldown(ctx, cooldown)) {
            return .{
                .intent = .{ .casting_scripted = .{
                    .spell_id = cooldown.spell.spell_id,
                    .target_guid = ctx.bot.state.guid,
                    .instant = false,
                } },
                .priority = .role,
                .created_at_ms = ctx.game_time_ms,
                .max_age_ms = emergency_cooldown_ttl_ms,
                .source = .role_heal_move,
            };
        }
    }

    if (meta.heal_maintenance) |maintenance| {
        const action = maintenance(ctx);
        if (intentFromAction(ctx, action)) |ai| return ai;
    }

    const kit = meta.heal_kit orelse return null;
    const target = ctx.heal_priority orelse return null;
    const spell = chooseSpell(ctx, kit, target.guid, target.hp_ratio) orelse {
        if (meta.heal_fallback) |fallback| {
            if (intentFromAction(ctx, fallback(ctx))) |ai| return ai;
        }
        return null;
    };

    return .{
        .intent = .{ .casting_scripted = .{
            .spell_id = spell.spell_id,
            .target_guid = target.guid,
            .instant = spell.is_channel or spell.spell_id == hotSpellId(kit),
        } },
        .priority = .role,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = heal_intent_ttl_ms,
        .source = .role_heal_move,
    };
}

fn chooseSpell(ctx: *const CombatContext, kit: spec_registry.HealKit, target_guid: u64, hp_ratio: f32) ?Spell {
    if (ctx.spec == .restoration_shaman) {
        return chooseRestorationShamanSpell(ctx, kit, hp_ratio);
    }

    if (kit.hot) |spell| {
        if (targetHasAuraFromSelf(ctx, target_guid, spell.spell_id)) {
            if (kit.expensive) |expensive| {
                if (hp_ratio <= kit.expensive_hp_ratio and ctx.spellReady(expensive.spell_id)) return expensive;
            }
            return null;
        }
    }

    const use_cheap_for_mana = if (kit.cheap_below_mana_pct) |mana_pct|
        if (ctx.manaPct()) |current| current <= mana_pct else false
    else
        false;
    if (!use_cheap_for_mana and hp_ratio <= kit.expensive_hp_ratio) {
        if (kit.expensive) |spell| {
            if (ctx.spellReady(spell.spell_id)) return spell;
        }
    }
    if (ctx.spellReady(kit.cheap.spell_id)) return kit.cheap;
    return null;
}

fn chooseRestorationShamanSpell(ctx: *const CombatContext, kit: spec_registry.HealKit, hp_ratio: f32) ?Spell {
    const tidal_waves_up = ctx.auraOnSelf(resto_shaman_tidal_waves_aura_id) != null;

    if (tidal_waves_up and hp_ratio <= resto_shaman_tidal_waves_big_heal_hp_ratio) {
        if (kit.expensive) |spell| {
            if (ctx.spellReady(spell.spell_id)) return spell;
        }
    }

    if (ctx.spellReady(kit.cheap.spell_id)) return kit.cheap;

    if (kit.expensive) |spell| {
        if (ctx.spellReady(spell.spell_id)) return spell;
    }

    return null;
}

fn emergencyTankTarget(ctx: *const CombatContext, cooldown: spec_registry.TankEmergencyCooldown) ?u64 {
    if (ctx.assigned_tank_guid == 0) return null;
    if (!ctx.spellReady(cooldown.spell.spell_id)) return null;

    const scan = world_query.scanForGuidOnMap(ctx.world, ctx.assigned_tank_guid, ctx.bot.state.map_id) orelse return null;
    if (scan.hp == 0) return null;
    if (hpRatio(scan.hp, scan.hp_max) >= cooldown.hp_ratio) return null;

    const dx = scan.x - ctx.bot.state.x;
    const dy = scan.y - ctx.bot.state.y;
    const dz = scan.z - ctx.bot.state.z;
    const range_sq = cooldown.spell.range_yards * cooldown.spell.range_yards;
    if (dx * dx + dy * dy + dz * dz > range_sq) return null;

    return ctx.assigned_tank_guid;
}

fn shouldUseEmergencyCooldown(ctx: *const CombatContext, cooldown: spec_registry.HealEmergencyCooldown) bool {
    if (!ctx.spellReady(cooldown.spell.spell_id)) return false;
    if (otherHealerChannelingEmergencyCooldown(ctx)) return false;
    return countInjuredLocalMembers(ctx, cooldown.spell.range_yards, cooldown.injured_hp_ratio) >= cooldown.injured_count;
}

fn otherHealerChannelingEmergencyCooldown(ctx: *const CombatContext) bool {
    for (ctx.bots) |ally| {
        if (ally.state.guid == ctx.bot.state.guid) continue;
        if (ally.state.map_id != ctx.bot.state.map_id) continue;
        if (ally.state.is_channeling == 0) continue;
        if (ally.state.channel_spell_id == tranquility_spell_id or
            ally.state.channel_spell_id == divine_hymn_spell_id)
            return true;
    }
    return false;
}

fn countInjuredLocalMembers(ctx: *const CombatContext, range_yards: f32, hp_ratio_threshold: f32) u32 {
    var count: u32 = 0;
    const max_range_sq = range_yards * range_yards;

    for (ctx.bots) |ally| {
        if (ally.state.map_id != ctx.bot.state.map_id) continue;
        if (ally.state.guid == 0) continue;

        if (ally.state.guid == ctx.bot.state.guid) {
            if (hpRatio(ally.state.hp, ally.state.hp_max) < hp_ratio_threshold) count += 1;
            continue;
        }

        const scan = world_query.scanForGuidOnMap(ctx.world, ally.state.guid, ctx.bot.state.map_id) orelse continue;
        if (scan.hp == 0) continue;

        const dx = scan.x - ctx.bot.state.x;
        const dy = scan.y - ctx.bot.state.y;
        const dz = scan.z - ctx.bot.state.z;
        if (dx * dx + dy * dy + dz * dz > max_range_sq) continue;
        if (hpRatio(scan.hp, scan.hp_max) < hp_ratio_threshold) count += 1;
    }

    return count;
}

fn hpRatio(hp: u32, hp_max: u32) f32 {
    if (hp_max == 0) return 1.0;
    return @as(f32, @floatFromInt(hp)) / @as(f32, @floatFromInt(hp_max));
}

fn intentFromAction(ctx: *const CombatContext, action: Action) ?ActiveIntent {
    const result: intent.Intent = switch (action) {
        .none => return null,
        .cast_instant => |spell_id| .{ .casting_scripted = .{
            .spell_id = spell_id,
            .target_guid = ctx.bot.state.guid,
            .instant = true,
        } },
        .cast_target_instant => |ct| .{ .casting_scripted = .{
            .spell_id = ct.spell_id,
            .target_guid = ct.target_guid,
            .instant = true,
        } },
        else => return null,
    };
    return .{
        .intent = result,
        .priority = .role,
        .created_at_ms = ctx.game_time_ms,
        .max_age_ms = heal_intent_ttl_ms,
        .source = .role_heal_move,
    };
}

fn hotSpellId(kit: spec_registry.HealKit) u32 {
    return if (kit.hot) |spell| spell.spell_id else 0;
}

fn targetHasAuraFromSelf(ctx: *const CombatContext, target_guid: u64, spell_id: u32) bool {
    const scan = world_query.scanForGuidOnMap(ctx.world, target_guid, ctx.bot.state.map_id) orelse return false;
    const n = @min(scan.aura_count, scan.auras.len);
    for (scan.auras[0..n]) |entry| {
        if (entry.spell_id == spell_id and entry.caster_guid == ctx.bot.state.guid) return true;
    }
    return false;
}

test "proposeIntent: resto druid uses tranquility for local raid emergency" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    const healer = makeEmergencyBot(1, 0x100, class_spec.Class.druid, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 0, 0, 0, 1000, 1000);
    const ally1 = makeEmergencyBot(2, 0x200, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 5, 0, 0, 400, 1000);
    const ally2 = makeEmergencyBot(3, 0x300, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 6, 0, 0, 400, 1000);
    const ally3 = makeEmergencyBot(4, 0x400, class_spec.Class.mage, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 7, 0, 0, 400, 1000);
    const ally4 = makeEmergencyBot(5, 0x500, class_spec.Class.warlock, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 8, 0, 0, 400, 1000);
    const bots = [_]registry_mod.BotSnapshot{ healer, ally1, ally2, ally3, ally4 };
    const world = [_]world_memory_mod.WorldSnapshot{
        emergencyWorldEntry(ally1),
        emergencyWorldEntry(ally2),
        emergencyWorldEntry(ally3),
        emergencyWorldEntry(ally4),
    };

    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;
    try std.testing.expectEqual(@as(u32, 48447), ai.intent.casting_scripted.spell_id);
    try std.testing.expectEqual(healer.state.guid, ai.intent.casting_scripted.target_guid);
    try std.testing.expect(!ai.intent.casting_scripted.instant);
}

test "proposeIntent: emergency cooldown waits when another healer is already channeling one" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    const healer = makeEmergencyBot(1, 0x100, class_spec.Class.priest, .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 }, 0, 0, 0, 1000, 1000);
    const ally1 = makeEmergencyBot(2, 0x200, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 5, 0, 0, 400, 1000);
    const ally2 = makeEmergencyBot(3, 0x300, class_spec.Class.rogue, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 6, 0, 0, 400, 1000);
    const ally3 = makeEmergencyBot(4, 0x400, class_spec.Class.mage, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 7, 0, 0, 400, 1000);
    const ally4 = makeEmergencyBot(5, 0x500, class_spec.Class.warlock, .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 }, 8, 0, 0, 400, 1000);
    var other_healer = makeEmergencyBot(6, 0x600, class_spec.Class.druid, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 3, 0, 0, 1000, 1000);
    other_healer.state.is_channeling = 1;
    other_healer.state.channel_spell_id = 48447;

    const bots = [_]registry_mod.BotSnapshot{ healer, ally1, ally2, ally3, ally4, other_healer };
    const world = [_]world_memory_mod.WorldSnapshot{
        emergencyWorldEntry(ally1),
        emergencyWorldEntry(ally2),
        emergencyWorldEntry(ally3),
        emergencyWorldEntry(ally4),
        emergencyWorldEntry(other_healer),
    };

    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;
    try std.testing.expect(ai.intent == .casting_scripted);
    try std.testing.expect(ai.intent.casting_scripted.spell_id != 64843);
}

test "proposeIntent: discipline uses pain suppression on assigned tank below emergency threshold" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    assignments.reset();
    defer assignments.reset();

    var healer = makeEmergencyBot(1, 0x100, class_spec.Class.priest, .{ .tab1 = 30, .tab2 = 30, .tab3 = 0 }, 0, 0, 0, 1000, 1000);
    healer.state.spell_range_count = 1;
    healer.state.spell_ranges[0] = .{ .spell_id = 33206, .max_range_yards = 40.0 };
    const tank = makeEmergencyBot(2, 0x200, class_spec.Class.warrior, .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }, 5, 0, 0, 240, 1000);
    assignments.setAssignedTank(healer.bot_id, tank.state.guid);

    const bots = [_]registry_mod.BotSnapshot{ healer, tank };
    const world = [_]world_memory_mod.WorldSnapshot{emergencyWorldEntry(tank)};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;

    try std.testing.expectEqual(@as(u32, 33206), ai.intent.casting_scripted.spell_id);
    try std.testing.expectEqual(tank.state.guid, ai.intent.casting_scripted.target_guid);
    try std.testing.expect(ai.intent.casting_scripted.instant);
}

test "proposeIntent casts cheap heal on cached target" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    var healer: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.priest);
    healer.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    healer.state.cooldown_count = 1;
    healer.state.cooldowns[0] = .{ .spell_id = 53007, .category = 0, .remaining_ms = 5000, .duration_ms = 10000 };
    healer.state.spell_range_count = 1;
    healer.state.spell_ranges[0] = .{ .spell_id = 48071, .max_range_yards = 40.0 };

    var ally: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    ally.state.guid = 0x200;
    ally.state.map_id = 1;
    ally.state.class = @intFromEnum(class_spec.Class.rogue);
    ally.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = ally.state.guid;
    scan.hp = 700;
    scan.hp_max = 1000;
    scan.aura_count = 1;
    scan.auras[0] = .{ .spell_id = 53563, .caster_guid = healer.state.guid, .remaining_ms = 30_000 };

    const bots = [_]registry_mod.BotSnapshot{ healer, ally };
    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;
    try std.testing.expectEqual(intent.Reason.role_heal_move, ai.source);
    try std.testing.expectEqual(@as(u32, 48066), ai.intent.casting_scripted.spell_id);
    try std.testing.expectEqual(ally.state.guid, ai.intent.casting_scripted.target_guid);
}

test "proposeIntent: resto druid does not recast rejuvenation on an already hotted target" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    var healer: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.druid);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    healer.state.spell_range_count = 2;
    healer.state.spell_ranges[0] = .{ .spell_id = 48441, .max_range_yards = 40.0 };
    healer.state.spell_ranges[1] = .{ .spell_id = 48443, .max_range_yards = 40.0 };

    var ally: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    ally.state.guid = 0x200;
    ally.state.map_id = 1;
    ally.state.class = @intFromEnum(class_spec.Class.warrior);
    ally.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = ally.state.guid;
    scan.hp = 550;
    scan.hp_max = 1000;
    scan.aura_count = 1;
    scan.auras[0] = .{ .spell_id = 48441, .caster_guid = healer.state.guid, .remaining_ms = 12_000 };

    const bots = [_]registry_mod.BotSnapshot{ healer, ally };
    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx);
    try std.testing.expect(ai != null);
    try std.testing.expectEqual(@as(u32, 48438), ai.?.intent.casting_scripted.spell_id);
    try std.testing.expectEqual(ally.state.guid, ai.?.intent.casting_scripted.target_guid);
}

test "proposeIntent: resto shaman uses healing wave with tidal waves on injured target" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    var healer: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.shaman);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    healer.state.spell_range_count = 2;
    healer.state.spell_ranges[0] = .{ .spell_id = 49276, .max_range_yards = 40.0 };
    healer.state.spell_ranges[1] = .{ .spell_id = 49273, .max_range_yards = 40.0 };
    healer.state.totems[@intFromEnum(proto.TotemElement.air)].remaining_ms = 30_000;
    healer.state.totems[@intFromEnum(proto.TotemElement.earth)].remaining_ms = 30_000;
    healer.state.totems[@intFromEnum(proto.TotemElement.fire)].remaining_ms = 30_000;
    healer.state.totems[@intFromEnum(proto.TotemElement.water)].remaining_ms = 30_000;
    healer.state.player_aura_count = 5;
    healer.state.player_auras[0] = .{ .caster_guid = healer.state.guid, .spell_id = resto_shaman_tidal_waves_aura_id, .remaining_ms = 10_000 };
    healer.state.player_auras[1] = .{ .caster_guid = healer.state.guid, .spell_id = 2895, .remaining_ms = 30_000 };
    healer.state.player_auras[2] = .{ .caster_guid = healer.state.guid, .spell_id = 58646, .remaining_ms = 30_000 };
    healer.state.player_auras[3] = .{ .caster_guid = healer.state.guid, .spell_id = 58645, .remaining_ms = 30_000 };
    healer.state.player_auras[4] = .{ .caster_guid = healer.state.guid, .spell_id = 58777, .remaining_ms = 30_000 };

    var tank: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    tank.state.guid = 0x200;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = tank.state.guid;
    scan.hp = 600;
    scan.hp_max = 1000;
    scan.aura_count = 2;
    scan.auras[0] = .{ .spell_id = 32594, .caster_guid = healer.state.guid, .remaining_ms = 600_000 };
    scan.auras[1] = .{ .spell_id = 61299, .caster_guid = healer.state.guid, .remaining_ms = 12_000 };

    const bots = [_]registry_mod.BotSnapshot{ healer, tank };
    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;
    try std.testing.expectEqual(@as(u32, 49273), ai.intent.casting_scripted.spell_id);
    try std.testing.expectEqual(tank.state.guid, ai.intent.casting_scripted.target_guid);
}

test "proposeIntent: resto shaman casts missing totem maintenance" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    var healer: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.shaman);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    healer.state.unit_flags = @intFromEnum(proto.UnitFlag.in_combat);
    healer.state.spell_range_count = 1;
    healer.state.spell_ranges[0] = .{ .spell_id = 66842, .max_range_yards = 0.0 };
    healer.state.totems[@intFromEnum(proto.TotemElement.earth)].remaining_ms = 30_000;
    healer.state.totems[@intFromEnum(proto.TotemElement.fire)].remaining_ms = 30_000;
    healer.state.totems[@intFromEnum(proto.TotemElement.water)].remaining_ms = 30_000;
    healer.state.player_aura_count = 3;
    healer.state.player_auras[0] = .{ .caster_guid = healer.state.guid, .spell_id = 58646, .remaining_ms = 30_000 };
    healer.state.player_auras[1] = .{ .caster_guid = healer.state.guid, .spell_id = 58645, .remaining_ms = 30_000 };
    healer.state.player_auras[2] = .{ .caster_guid = healer.state.guid, .spell_id = 58777, .remaining_ms = 30_000 };

    const world = [_]world_memory_mod.WorldSnapshot{};
    const ctx = CombatContext.build(healer, &.{healer}, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;
    try std.testing.expectEqual(@as(u32, 66842), ai.intent.casting_scripted.spell_id);
    try std.testing.expectEqual(healer.state.guid, ai.intent.casting_scripted.target_guid);
    try std.testing.expect(ai.intent.casting_scripted.instant);
}

test "proposeIntent: resto shaman does not cast missing totem out of combat" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    var healer: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.shaman);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    healer.state.spell_range_count = 1;
    healer.state.spell_ranges[0] = .{ .spell_id = 3738, .max_range_yards = 0.0 };

    const world = [_]world_memory_mod.WorldSnapshot{};
    const ctx = CombatContext.build(healer, &.{healer}, &world, &.{}, true);
    try std.testing.expect(proposeIntent(&ctx) == null);
}

test "proposeIntent: healers stay idle on prep-gated maps before start fight" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");
    const encounter_mod = @import("../encounters/mod.zig");

    var healer: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = encounter_mod.thaddius_map_id;
    healer.state.class = @intFromEnum(class_spec.Class.shaman);
    healer.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };
    healer.state.spell_range_count = 2;
    healer.state.spell_ranges[0] = .{ .spell_id = 49276, .max_range_yards = 40.0 };
    healer.state.spell_ranges[1] = .{ .spell_id = 49273, .max_range_yards = 40.0 };

    var tank: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    tank.bot_id[0] = 2;
    tank.state.guid = 0x200;
    tank.state.map_id = encounter_mod.thaddius_map_id;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var tank_scan = std.mem.zeroes(proto.ScanEntry);
    tank_scan.guid = tank.state.guid;
    tank_scan.hp = 600;
    tank_scan.hp_max = 1000;

    const bots = [_]registry_mod.BotSnapshot{ healer, tank };
    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = tank_scan, .map_id = encounter_mod.thaddius_map_id, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, false);
    try std.testing.expect(proposeIntent(&ctx) == null);
}

test "proposeIntent: holy paladin uses holy light for serious damage" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    var healer: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.paladin);
    healer.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    healer.state.active_power_type = 0;
    healer.state.active_power = 8000;
    healer.state.active_power_max = 10_000;
    healer.state.spell_range_count = 2;
    healer.state.spell_ranges[0] = .{ .spell_id = 48785, .max_range_yards = 40.0 };
    healer.state.spell_ranges[1] = .{ .spell_id = 48782, .max_range_yards = 40.0 };

    var ally: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    ally.state.guid = 0x200;
    ally.state.map_id = 1;
    ally.state.class = @intFromEnum(class_spec.Class.warrior);
    ally.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = ally.state.guid;
    scan.hp = 700;
    scan.hp_max = 1000;
    scan.aura_count = 2;
    scan.auras[0] = .{ .spell_id = 53563, .caster_guid = healer.state.guid, .remaining_ms = 30_000 };
    scan.auras[1] = .{ .spell_id = 53601, .caster_guid = healer.state.guid, .remaining_ms = 60_000 };

    const bots = [_]registry_mod.BotSnapshot{ healer, ally };
    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;
    try std.testing.expectEqual(@as(u32, 48782), ai.intent.casting_scripted.spell_id);
}

test "proposeIntent: holy paladin uses flash of light for light damage" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    var healer: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.paladin);
    healer.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    healer.state.active_power_type = 0;
    healer.state.active_power = 8000;
    healer.state.active_power_max = 10_000;
    healer.state.spell_range_count = 2;
    healer.state.spell_ranges[0] = .{ .spell_id = 48785, .max_range_yards = 40.0 };
    healer.state.spell_ranges[1] = .{ .spell_id = 48782, .max_range_yards = 40.0 };

    var ally: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    ally.state.guid = 0x200;
    ally.state.map_id = 1;
    ally.state.class = @intFromEnum(class_spec.Class.rogue);
    ally.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = ally.state.guid;
    scan.hp = 900;
    scan.hp_max = 1000;

    const bots = [_]registry_mod.BotSnapshot{ healer, ally };
    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;
    try std.testing.expectEqual(@as(u32, 48785), ai.intent.casting_scripted.spell_id);
}

test "proposeIntent: holy paladin casts beacon on first tank when missing" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    var healer: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.paladin);
    healer.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    healer.state.spell_range_count = 1;
    healer.state.spell_ranges[0] = .{ .spell_id = 53563, .max_range_yards = 60.0 };

    var tank: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    tank.state.guid = 0x200;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = tank.state.guid;
    scan.hp = 1000;
    scan.hp_max = 1000;

    const bots = [_]registry_mod.BotSnapshot{ healer, tank };
    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;
    try std.testing.expectEqual(@as(u32, 53563), ai.intent.casting_scripted.spell_id);
    try std.testing.expectEqual(tank.state.guid, ai.intent.casting_scripted.target_guid);
}

test "proposeIntent: discipline uses maintenance shield before heal kit" {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    var healer: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    healer.bot_id[0] = 1;
    healer.state.guid = 0x100;
    healer.state.map_id = 1;
    healer.state.class = @intFromEnum(class_spec.Class.priest);
    healer.state.talent_points = .{ .tab1 = 30, .tab2 = 30, .tab3 = 0 };
    healer.state.cooldown_count = 1;
    healer.state.cooldowns[0] = .{ .spell_id = 53007, .category = 0, .remaining_ms = 5000, .duration_ms = 10000 };
    healer.state.spell_range_count = 4;
    healer.state.spell_ranges[0] = .{ .spell_id = 48066, .max_range_yards = 40.0 };
    healer.state.spell_ranges[1] = .{ .spell_id = 33076, .max_range_yards = 40.0 };
    healer.state.spell_ranges[2] = .{ .spell_id = 48071, .max_range_yards = 40.0 };
    healer.state.spell_ranges[3] = .{ .spell_id = 48072, .max_range_yards = 40.0 };

    var tank: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    tank.state.guid = 0x200;
    tank.state.map_id = 1;
    tank.state.class = @intFromEnum(class_spec.Class.warrior);
    tank.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 };

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = tank.state.guid;
    scan.hp = 700;
    scan.hp_max = 1000;

    const bots = [_]registry_mod.BotSnapshot{ healer, tank };
    const world = [_]world_memory_mod.WorldSnapshot{.{ .scan = scan, .map_id = 1, .last_seen_ts_ns = 0 }};
    const ctx = CombatContext.build(healer, &bots, &world, &.{}, true);
    const ai = proposeIntent(&ctx).?;
    try std.testing.expectEqual(intent.Reason.role_heal_move, ai.source);
    try std.testing.expectEqual(@as(u32, 48066), ai.intent.casting_scripted.spell_id);
    try std.testing.expectEqual(tank.state.guid, ai.intent.casting_scripted.target_guid);
}

fn makeEmergencyBot(
    id: u8,
    guid: u64,
    class: class_spec.Class,
    talent_points: proto.TalentPoints,
    x: f32,
    y: f32,
    z: f32,
    hp: u32,
    hp_max: u32,
) registry_mod.BotSnapshot {
    const std = @import("std");

    var bot: registry_mod.BotSnapshot = std.mem.zeroes(registry_mod.BotSnapshot);
    bot.bot_id[0] = id;
    bot.state.bot_id[0] = id;
    bot.state.guid = guid;
    bot.state.map_id = 1;
    bot.state.class = @intFromEnum(class);
    bot.state.talent_points = talent_points;
    bot.state.x = x;
    bot.state.y = y;
    bot.state.z = z;
    bot.state.hp = hp;
    bot.state.hp_max = hp_max;
    return bot;
}

fn emergencyWorldEntry(bot: registry_mod.BotSnapshot) @import("../../world/memory.zig").WorldSnapshot {
    const std = @import("std");
    const world_memory_mod = @import("../../world/memory.zig");

    var scan = std.mem.zeroes(proto.ScanEntry);
    scan.guid = bot.state.guid;
    scan.x = bot.state.x;
    scan.y = bot.state.y;
    scan.z = bot.state.z;
    scan.hp = bot.state.hp;
    scan.hp_max = bot.state.hp_max;
    return world_memory_mod.WorldSnapshot{ .scan = scan, .map_id = bot.state.map_id, .last_seen_ts_ns = 0 };
}
