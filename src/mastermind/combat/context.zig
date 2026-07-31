// CombatContext — built once per bot per brain tick.
// Specs and encounters receive `*const CombatContext` instead of raw (bot, world).
// Expensive queries (heal target ranking, threat check) run at build time and are cached.

const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../world/memory.zig");
const class_spec = @import("class_spec.zig");
const spec_registry = @import("specs/spec_registry.zig");
const role_mod = @import("role.zig");
const world_query = @import("world_query.zig");
const aura = @import("aura.zig");
const cooldown = @import("cooldown.zig");
const aggro = @import("aggro.zig");
const heal_select = @import("heal_select.zig");
const assignments = @import("assignments.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const HealTarget = heal_select.HealTarget;

pub const CombatContext = struct {
    bot: BotSnapshot,
    bots: []const BotSnapshot,
    world: []const WorldSnapshot,
    spell_events: []const proto.SpellEvent,
    spec: class_spec.Spec,
    role: role_mod.CombatRole,
    /// Cached hostile target guid from `primaryHostileAttackGuid`, or null.
    primary_target: ?u64,
    /// Cached heal target (computed once for healers; null for non-healers).
    heal_priority: ?HealTarget,
    /// Encounter-assigned tank for healer maintenance; 0 when no encounter assignment exists.
    assigned_tank_guid: u64,
    /// True when the bot's threat percentage exceeds the safety threshold.
    threat_high: bool,
    game_time_ms: u32,
    operator_fight_started: bool,

    pub fn build(
        bot: BotSnapshot,
        bots: []const BotSnapshot,
        world: []const WorldSnapshot,
        spell_events: []const proto.SpellEvent,
        operator_fight_started: bool,
    ) CombatContext {
        const spec = class_spec.primarySpecFromState(bot.state);
        const meta = spec_registry.meta(spec);
        const role = role_mod.roleForSpec(spec);

        const primary_target = world_query.primaryHostileAttackGuid(bot.state, world);

        const heal_priority: ?HealTarget = if (role == .healer) blk: {
            const max_range = if (meta.heal_kit) |k|
                (if (k.expensive) |s| s.range_yards else k.cheap.range_yards)
            else
                40.0;
            break :blk heal_select.rank(bot, bots, world, max_range, meta.heal_policy);
        } else null;

        const threat_high = aggro.highThreat(bot, bots, world, spec);
        const assigned_tank_guid = assignments.assignedTankGuid(bot.bot_id) orelse 0;

        return .{
            .bot = bot,
            .bots = bots,
            .world = world,
            .spell_events = spell_events,
            .spec = spec,
            .role = role,
            .primary_target = primary_target,
            .heal_priority = heal_priority,
            .assigned_tank_guid = assigned_tank_guid,
            .threat_high = threat_high,
            .game_time_ms = bot.state.game_time_ms,
            .operator_fight_started = operator_fight_started,
        };
    }

    // ─── Convenience helpers ──────────────────────────────────────────────────

    pub fn spellReady(self: *const CombatContext, spell_id: u32) bool {
        return cooldown.spellReady(self.bot.state, spell_id);
    }

    pub fn runeReady(self: *const CombatContext, rune_type: u32) bool {
        return cooldown.runeReady(self.bot.state, rune_type);
    }

    pub fn auraOnSelf(self: *const CombatContext, spell_id: u32) ?u32 {
        return aura.remainingMsOnSelf(self.bot.state, spell_id);
    }

    pub fn auraOnTarget(self: *const CombatContext, spell_id: u32) ?u32 {
        return aura.remainingMsOnTarget(self.bot.state, spell_id);
    }

    pub fn hpPct(self: *const CombatContext) u32 {
        if (self.bot.state.hp_max == 0) return 100;
        return @intCast((self.bot.state.hp * 100) / self.bot.state.hp_max);
    }

    pub fn manaPct(self: *const CombatContext) ?u32 {
        return cooldown.manaPct(self.bot.state);
    }

    pub fn runicPower(self: *const CombatContext) u32 {
        return self.bot.state.active_power;
    }

    pub fn targetHpPct(self: *const CombatContext) ?u32 {
        const guid = self.primary_target orelse return null;
        const scan = world_query.scanForGuidOnMap(self.world, guid, self.bot.state.map_id) orelse return null;
        if (scan.hp_max == 0) return null;
        return @intCast((scan.hp * 100) / scan.hp_max);
    }
};
