// Pure world-state predicates for the Thaddius encounter.

const proto = @import("protocol");
const context = @import("../../context.zig");
const world_query = @import("../../world_query.zig");
const arena = @import("arena.zig");
const state = @import("state.zig");

const CombatContext = context.CombatContext;
const map_id = @import("mod.zig").map_id;

pub const spell_polarity_positive: u32 = 28059;
pub const spell_polarity_negative: u32 = 28084;
pub const spell_magnetic_pull_trigger: u32 = 54517;

pub fn twinStalaggAlive(ctx: *const CombatContext) bool {
    const s = world_query.scanByNameOnMap(ctx.world, "Stalagg", map_id) orelse return false;
    return !state.twinDefeatedHp(s.hp);
}

pub fn twinFeugenAlive(ctx: *const CombatContext) bool {
    const s = world_query.scanByNameOnMap(ctx.world, "Feugen", map_id) orelse return false;
    return !state.twinDefeatedHp(s.hp);
}

pub fn thaddiusAlive(ctx: *const CombatContext) bool {
    const s = world_query.scanByNameOnMap(ctx.world, "Thaddius", map_id) orelse return false;
    return s.hp > 0;
}

pub fn thaddiusAttackable(ctx: *const CombatContext) bool {
    const s = world_query.scanByNameOnMap(ctx.world, "Thaddius", map_id) orelse return false;
    if (proto.hasUnitFlag(s.unit_flags, .uninteractible)) return false;
    if (proto.hasUnitFlag(s.unit_flags, .immune_to_pc)) return false;
    return true;
}

pub fn hasPolarityPositive(ctx: *const CombatContext) bool {
    return world_query.hasAura(
        &ctx.bot.state.player_auras,
        ctx.bot.state.player_aura_count,
        spell_polarity_positive,
    );
}

pub fn hasPolarityNegative(ctx: *const CombatContext) bool {
    return world_query.hasAura(
        &ctx.bot.state.player_auras,
        ctx.bot.state.player_aura_count,
        spell_polarity_negative,
    );
}

fn isMagneticPullSpell(spell_id: u32) bool {
    return spell_id == spell_magnetic_pull_trigger;
}

/// Returns the first Magnetic Pull launch event after `after_game_time_ms`.
pub fn magneticPullGoEventAfter(events: []const proto.SpellEvent, after_game_time_ms: u32) ?proto.SpellEvent {
    for (events) |event| {
        if (event.kind != @intFromEnum(proto.SpellEventKind.go)) continue;
        if (!isMagneticPullSpell(event.spell_id)) continue;
        if (event.game_time_ms <= after_game_time_ms) continue;
        return event;
    }

    return null;
}
