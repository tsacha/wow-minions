const registry_mod = @import("registry");
const world_memory_mod = @import("../../world/memory.zig");
const class_spec = @import("../class_spec.zig");
const role_mod = @import("../role.zig");
const spells_db = @import("../spells.zig");
const spell_range = @import("../spell_range.zig");
const dispatch = @import("../dispatch.zig");
const Action = @import("../action.zig").Action;
const context = @import("../context.zig");

const paladin_blessings = @import("paladin_blessings.zig");

const affliction = @import("affliction.zig");
const arcane = @import("arcane.zig");
const arms = @import("arms.zig");
const assassination = @import("assassination.zig");
const balance = @import("balance.zig");
const blood = @import("blood.zig");
const demonology = @import("demonology.zig");
const discipline = @import("discipline.zig");
const elemental = @import("elemental.zig");
const enhancement = @import("enhancement.zig");
const feral = @import("feral.zig");
const frost_dk = @import("frost_dk.zig");
const holy_paladin = @import("holy_paladin.zig");
const holy_priest = @import("holy_priest.zig");
const protection_paladin = @import("protection_paladin.zig");
const retribution = @import("retribution.zig");
const restoration_druid = @import("restoration_druid.zig");
const restoration_shaman = @import("restoration_shaman.zig");
const shadow = @import("shadow.zig");
const survival = @import("survival.zig");
const unholy = @import("unholy.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

const emergency_raid_hp_ratio: f32 = 0.50;
const emergency_raid_injured_count: u32 = 4;
const emergency_tank_hp_ratio: f32 = 0.25;

const arcane_raid_buff_actions = [_]Action{.{ .cast_instant = arcane.data.spells.arcane_brilliance.spell_id }};
const restoration_druid_raid_buff_actions = [_]Action{.{ .cast_instant = restoration_druid.data.spells.gift_of_the_wild.spell_id }};
const unholy_raid_buff_actions = [_]Action{.{ .cast_instant = unholy.data.spells.horn_of_winter.spell_id }};

pub const PlanFn = *const fn (BotSnapshot, []const WorldSnapshot) Action;
pub const PlanWithContextFn = *const fn (*const context.CombatContext) Action;
pub const HealMaintenanceFn = *const fn (*const context.CombatContext) Action;
pub const RangeFn = *const fn (u32) ?f32;
pub const SpellNameFn = *const fn (u32) ?[]const u8;
pub const OutOfCombatCheckFn = *const fn (u32) bool;

pub const HealKit = struct {
    cheap: spells_db.Spell,
    expensive: ?spells_db.Spell = null,
    hot: ?spells_db.Spell = null,
    group: ?spells_db.Spell = null,
    expensive_hp_ratio: f32 = 0.45,
    cheap_below_mana_pct: ?u32 = null,
};

pub const HealPolicy = enum {
    tank_primary,
    tank_support,
    raid_primary,
};

pub const HealEmergencyCooldown = struct {
    spell: spells_db.Spell,
    injured_hp_ratio: f32,
    injured_count: u32,
};

pub const TankEmergencyCooldown = struct {
    spell: spells_db.Spell,
    hp_ratio: f32,
};

pub const RaidBuffPlan = struct {
    actions: []const Action,
    inter_step_delay_ms: u32 = 0,
};

pub const max_blessing_actions = paladin_blessings.max_actions;
pub const blessing_step_delay_ms: u32 = 2000;

pub const SpecInfo = struct {
    spec: class_spec.Spec,
    role: role_mod.CombatRole,
    profile: role_mod.RangeProfile,
    plan: ?PlanFn = null,
    plan_with_context: ?PlanWithContextFn = null,
    threat_plan: ?PlanWithContextFn = null,
    max_range: ?RangeFn = null,
    spell_name: ?SpellNameFn = null,
    out_of_combat_check: ?OutOfCombatCheckFn = null,
    heal_spell: ?spells_db.Spell = null,
    heal_kit: ?HealKit = null,
    heal_policy: HealPolicy = .raid_primary,
    heal_emergency_cooldown: ?HealEmergencyCooldown = null,
    tank_emergency_cooldown: ?TankEmergencyCooldown = null,
    heal_maintenance: ?HealMaintenanceFn = null,
    heal_fallback: ?HealMaintenanceFn = null,
    pull_spell: ?spells_db.Spell = null,
    taunt_spell: ?spells_db.Spell = null,
};

pub const SpecMeta = struct {
    role: role_mod.CombatRole = .ranged_dps,
    profile: role_mod.RangeProfile = .caster,
    plan: ?PlanFn = null,
    plan_with_context: ?PlanWithContextFn = null,
    threat_plan: ?PlanWithContextFn = null,
    max_range: ?RangeFn = null,
    spell_name: ?SpellNameFn = null,
    out_of_combat_check: ?OutOfCombatCheckFn = null,
    heal_spell: ?spells_db.Spell = null,
    heal_kit: ?HealKit = null,
    heal_policy: HealPolicy = .raid_primary,
    heal_emergency_cooldown: ?HealEmergencyCooldown = null,
    tank_emergency_cooldown: ?TankEmergencyCooldown = null,
    heal_maintenance: ?HealMaintenanceFn = null,
    heal_fallback: ?HealMaintenanceFn = null,
    pull_spell: ?spells_db.Spell = null,
    taunt_spell: ?spells_db.Spell = null,
};

fn outOfCombatCheckFn(comptime Spells: type) OutOfCombatCheckFn {
    return struct {
        fn run(spell_id: u32) bool {
            return spell_range.hasOutOfCombatTag(Spells, spell_id);
        }
    }.run;
}

fn maxRangeFn(comptime Spells: type) RangeFn {
    return struct {
        fn run(spell_id: u32) ?f32 {
            return spell_range.maxRange(Spells, spell_id);
        }
    }.run;
}

fn spellNameFn(comptime Spells: type) SpellNameFn {
    return struct {
        fn run(spell_id: u32) ?[]const u8 {
            return spell_range.name(Spells, spell_id);
        }
    }.run;
}

fn plannedSpec(
    comptime spec: class_spec.Spec,
    comptime role: role_mod.CombatRole,
    comptime profile: role_mod.RangeProfile,
    comptime Mod: type,
    comptime threat_plan: ?PlanWithContextFn,
) SpecInfo {
    return .{
        .spec = spec,
        .role = role,
        .profile = profile,
        .plan = Mod.plan,
        .threat_plan = threat_plan,
        .max_range = maxRangeFn(Mod.data.spells),
        .spell_name = spellNameFn(Mod.data.spells),
        .out_of_combat_check = outOfCombatCheckFn(Mod.data.spells),
    };
}

fn placeholderSpec(
    comptime spec: class_spec.Spec,
    comptime role: role_mod.CombatRole,
    comptime profile: role_mod.RangeProfile,
) SpecInfo {
    return .{ .spec = spec, .role = role, .profile = profile };
}

pub const entries = [_]SpecInfo{
    .{ .spec = .affliction, .role = .ranged_dps, .profile = .caster, .plan_with_context = affliction.planWithContext, .threat_plan = affliction.threatPlan, .max_range = maxRangeFn(affliction.data.spells), .spell_name = spellNameFn(affliction.data.spells), .out_of_combat_check = outOfCombatCheckFn(affliction.data.spells) },
    .{ .spec = .arcane, .role = .ranged_dps, .profile = .caster, .plan = arcane.plan, .threat_plan = arcane.threatPlan, .max_range = maxRangeFn(arcane.data.spells), .spell_name = spellNameFn(arcane.data.spells), .out_of_combat_check = outOfCombatCheckFn(arcane.data.spells) },
    plannedSpec(.arms, .melee_dps, .melee, arms, null),
    .{ .spec = .assassination, .role = .melee_dps, .profile = .melee, .plan = assassination.plan, .plan_with_context = assassination.planWithContext, .max_range = maxRangeFn(assassination.data.spells), .spell_name = spellNameFn(assassination.data.spells), .out_of_combat_check = outOfCombatCheckFn(assassination.data.spells) },
    plannedSpec(.balance, .ranged_dps, .caster, balance, null),
    .{ .spec = .blood, .role = .tank, .profile = .melee, .plan = blood.plan, .max_range = maxRangeFn(blood.data.spells), .spell_name = spellNameFn(blood.data.spells), .out_of_combat_check = outOfCombatCheckFn(blood.data.spells), .pull_spell = blood.data.spells.icy_touch, .taunt_spell = blood.data.spells.dark_command },
    plannedSpec(.demonology, .ranged_dps, .caster, demonology, demonology.threatPlan),
    .{ .spec = .discipline, .role = .healer, .profile = .caster, .plan = discipline.plan, .max_range = maxRangeFn(discipline.data.spells), .spell_name = spellNameFn(discipline.data.spells), .out_of_combat_check = outOfCombatCheckFn(discipline.data.spells), .heal_spell = discipline.data.spells.flash_heal, .heal_kit = .{ .cheap = discipline.data.spells.flash_heal, .expensive = discipline.data.spells.greater_heal }, .heal_policy = .tank_support, .heal_emergency_cooldown = .{ .spell = discipline.data.spells.divine_hymn, .injured_hp_ratio = emergency_raid_hp_ratio, .injured_count = emergency_raid_injured_count }, .tank_emergency_cooldown = .{ .spell = discipline.data.spells.pain_suppression, .hp_ratio = emergency_tank_hp_ratio }, .heal_maintenance = discipline.maintenance, .heal_fallback = discipline.fallback },
    plannedSpec(.elemental, .ranged_dps, .caster, elemental, null),
    plannedSpec(.enhancement, .melee_dps, .melee, enhancement, null),
    plannedSpec(.feral, .melee_dps, .melee, feral, feral.threatPlan),
    plannedSpec(.frost_dk, .melee_dps, .melee, frost_dk, null),
    .{ .spec = .holy_paladin, .role = .healer, .profile = .caster, .max_range = maxRangeFn(holy_paladin.data.spells), .spell_name = spellNameFn(holy_paladin.data.spells), .out_of_combat_check = outOfCombatCheckFn(holy_paladin.data.spells), .heal_spell = holy_paladin.data.spells.flash_of_light, .heal_kit = .{ .cheap = holy_paladin.data.spells.flash_of_light, .expensive = holy_paladin.data.spells.holy_light, .expensive_hp_ratio = 0.85, .cheap_below_mana_pct = 20 }, .heal_policy = .tank_primary, .heal_maintenance = holy_paladin.maintenance },
    .{ .spec = .holy_priest, .role = .healer, .profile = .caster, .max_range = maxRangeFn(holy_priest.data.spells), .spell_name = spellNameFn(holy_priest.data.spells), .out_of_combat_check = outOfCombatCheckFn(holy_priest.data.spells), .heal_spell = holy_priest.data.spells.flash_heal, .heal_kit = .{ .cheap = holy_priest.data.spells.flash_heal, .expensive = holy_priest.data.spells.greater_heal }, .heal_emergency_cooldown = .{ .spell = holy_priest.data.spells.divine_hymn, .injured_hp_ratio = emergency_raid_hp_ratio, .injured_count = emergency_raid_injured_count } },
    .{ .spec = .protection_paladin, .role = .tank, .profile = .melee, .plan = protection_paladin.plan, .max_range = maxRangeFn(protection_paladin.data.spells), .spell_name = spellNameFn(protection_paladin.data.spells), .out_of_combat_check = outOfCombatCheckFn(protection_paladin.data.spells), .pull_spell = protection_paladin.data.spells.avengers_shield, .taunt_spell = protection_paladin.data.spells.hand_of_reckoning },
    plannedSpec(.retribution, .melee_dps, .melee, retribution, null),
    .{ .spec = .restoration_druid, .role = .healer, .profile = .caster, .plan = restoration_druid.plan, .max_range = maxRangeFn(restoration_druid.data.spells), .spell_name = spellNameFn(restoration_druid.data.spells), .out_of_combat_check = outOfCombatCheckFn(restoration_druid.data.spells), .heal_spell = restoration_druid.data.spells.rejuvenation, .heal_kit = .{ .cheap = restoration_druid.data.spells.rejuvenation, .expensive = restoration_druid.data.spells.healing_touch, .hot = restoration_druid.data.spells.rejuvenation }, .heal_emergency_cooldown = .{ .spell = restoration_druid.data.spells.tranquility, .injured_hp_ratio = emergency_raid_hp_ratio, .injured_count = emergency_raid_injured_count }, .heal_maintenance = restoration_druid.maintenance },
    .{ .spec = .restoration_shaman, .role = .healer, .profile = .caster, .plan = restoration_shaman.plan, .max_range = maxRangeFn(restoration_shaman.data.spells), .spell_name = spellNameFn(restoration_shaman.data.spells), .out_of_combat_check = outOfCombatCheckFn(restoration_shaman.data.spells), .heal_spell = restoration_shaman.data.spells.healing_wave, .heal_kit = .{ .cheap = restoration_shaman.data.spells.lesser_healing_wave, .expensive = restoration_shaman.data.spells.healing_wave, .group = restoration_shaman.data.spells.chain_heal }, .heal_policy = .tank_primary, .heal_maintenance = restoration_shaman.maintenance },
    plannedSpec(.shadow, .ranged_dps, .caster, shadow, shadow.threatPlan),
    .{ .spec = .survival, .role = .ranged_dps, .profile = .ranged, .plan = survival.plan, .plan_with_context = survival.planWithContext, .threat_plan = survival.threatPlan, .max_range = maxRangeFn(survival.data.spells), .spell_name = spellNameFn(survival.data.spells), .out_of_combat_check = outOfCombatCheckFn(survival.data.spells) },
    plannedSpec(.unholy, .melee_dps, .melee, unholy, null),
    placeholderSpec(.fury, .melee_dps, .melee),
    placeholderSpec(.protection_warrior, .tank, .melee),
    placeholderSpec(.beast_mastery, .ranged_dps, .ranged),
    placeholderSpec(.marksmanship, .ranged_dps, .ranged),
    placeholderSpec(.combat, .melee_dps, .melee),
    placeholderSpec(.subtlety, .melee_dps, .melee),
    placeholderSpec(.fire, .ranged_dps, .caster),
    placeholderSpec(.frost_mage, .ranged_dps, .caster),
    .{ .spec = .destruction, .role = .ranged_dps, .profile = .caster, .threat_plan = affliction.threatPlan },
    placeholderSpec(.unknown, .ranged_dps, .caster),
};

pub fn lookup(spec: class_spec.Spec) ?SpecInfo {
    inline for (entries) |entry| {
        if (entry.spec == spec) return entry;
    }
    return null;
}

pub fn meta(spec: class_spec.Spec) SpecMeta {
    const entry = lookup(spec) orelse return .{};
    return .{
        .role = entry.role,
        .profile = entry.profile,
        .plan = entry.plan,
        .plan_with_context = entry.plan_with_context,
        .threat_plan = entry.threat_plan,
        .max_range = entry.max_range,
        .spell_name = entry.spell_name,
        .out_of_combat_check = entry.out_of_combat_check,
        .heal_spell = entry.heal_spell,
        .heal_kit = entry.heal_kit,
        .heal_policy = entry.heal_policy,
        .heal_emergency_cooldown = entry.heal_emergency_cooldown,
        .tank_emergency_cooldown = entry.tank_emergency_cooldown,
        .heal_maintenance = entry.heal_maintenance,
        .heal_fallback = entry.heal_fallback,
        .pull_spell = entry.pull_spell,
        .taunt_spell = entry.taunt_spell,
    };
}

pub fn raidBuffAction(spec: class_spec.Spec) ?Action {
    return switch (spec) {
        .arcane => arcane.raidBuffAction(),
        .discipline => discipline.raidBuffActions()[0],
        .restoration_druid => restoration_druid.raidBuffAction(),
        .unholy => unholy.raidBuffAction(),
        else => null,
    };
}

pub fn raidBuffActions(spec: class_spec.Spec) ?[]const Action {
    return switch (spec) {
        .discipline => discipline.raidBuffActions(),
        .arcane => arcane_raid_buff_actions[0..],
        .restoration_druid => restoration_druid_raid_buff_actions[0..],
        .unholy => unholy_raid_buff_actions[0..],
        else => null,
    };
}

pub fn raidBuffPlan(spec: class_spec.Spec) ?RaidBuffPlan {
    return switch (spec) {
        .discipline => .{
            .actions = discipline.raidBuffActions(),
            .inter_step_delay_ms = dispatch.instant_cast_debounce_ms,
        },
        .arcane => .{ .actions = arcane_raid_buff_actions[0..] },
        .restoration_druid => .{ .actions = restoration_druid_raid_buff_actions[0..] },
        .unholy => .{ .actions = unholy_raid_buff_actions[0..] },
        else => null,
    };
}

pub fn burstAction(spec: class_spec.Spec, step: usize) ?Action {
    return switch (spec) {
        .arcane => arcane.burstAction(step),
        .demonology => demonology.burstAction(step),
        .elemental => elemental.burstAction(step),
        .enhancement => enhancement.burstAction(step),
        .arms => arms.burstAction(step),
        .unholy => unholy.burstAction(step),
        else => null,
    };
}

/// Returns a dynamic raid buff plan for paladin specs that casts one Greater Blessing
/// per class present on the caster's map. `buf` must remain valid until the plan is consumed.
pub fn raidBuffPlanDynamic(
    spec: class_spec.Spec,
    caster: BotSnapshot,
    bots: []const BotSnapshot,
    buf: *[max_blessing_actions]Action,
) ?RaidBuffPlan {
    switch (spec) {
        .holy_paladin, .protection_paladin, .retribution => {},
        else => return null,
    }
    const actions = paladin_blessings.buildActions(caster, spec, bots, buf);
    if (actions.len == 0) return null;
    return .{ .actions = actions, .inter_step_delay_ms = blessing_step_delay_ms };
}
