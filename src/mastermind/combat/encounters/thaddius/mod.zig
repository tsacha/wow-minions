// Thaddius encounter driver (Naxxramas, map 533).
// proposeIntent() is called once per bot per brain tick.
// Per-bot and fight-global mutable state lives in state.zig.

const std = @import("std");
const proto = @import("protocol");
const registry_mod = @import("registry");
const world_memory_mod = @import("../../../world/memory.zig");
const context = @import("../../context.zig");
const geo = @import("../../geo.zig");
const intent = @import("../../intent/mod.zig");
const positioning = @import("../../positioning.zig");
const role_mod = @import("../../role.zig");
const spec_registry = @import("../../specs/spec_registry.zig");
const world_query = @import("../../world_query.zig");
const state = @import("state.zig");
const roster = @import("roster.zig");
const trig = @import("triggers.zig");
const pred = @import("predicates.zig");
const arena = @import("arena.zig");
const TargetStore = @import("../../target_store.zig");

const BotSnapshot = registry_mod.BotSnapshot;
const Registry = registry_mod.Registry;
const CombatContext = context.CombatContext;
const ActiveIntent = intent.ActiveIntent;
const IntentStore = intent.IntentStore;
const DispatchStore = intent.DispatchStore;
const FollowStore = role_mod.FollowStore;
const BotId = state.BotId;
const Side = state.Side;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const map_id: u32 = 533;
pub const twin_tank_anchor_arrival_yards: f32 = 5.0;
const twin_route_done_arrival_yards: f32 = 5.0;
const twin_pull_cooldown_fresh_ms: u32 = proto.brain_tick_ms * 5;
const twin_pull_facing_tolerance_rad: f32 = positioning.melee_facing_tolerance_rad;
const polarity_proximity_warn_yards: f32 = 14.0;
const polarity_proximity_warn_interval_ms: u32 = 5000;
var last_logged_phase: ?Phase = null;

// ─── Polarity charge-pulse diagnostics (MASTERMIND_LOG_POLARITY_CHARGES) ─────
// Each charged player periodically pulses its charge (`go` event). Same-charge
// players within range gain the +damage buff; opposite-charge players within
// range take the polarity damage (4500 on 25-man / 3500 on 10-man). We only log
// pulses that actually hit ≥1 opposite-charge victim — i.e. who is taking charge
// damage right now — so the channel stays silent once the raid is sorted.
const spell_positive_charge_pulse: u32 = 28062;
const spell_negative_charge_pulse: u32 = 28085;
// Charge interaction range (same/opposite-charge "nearby" radius), from in-game
// measurement — matches `polarity_proximity_warn_yards` above. The proximity warner
// flags opposite charges that close to this distance; this attributes a real pulse
// to the opposite-charge bots actually inside it.
const charge_pulse_radius_yards: f32 = polarity_proximity_warn_yards;
var charge_pulse_log_enabled: bool = false;

pub fn setChargePulseLogEnabled(enabled: bool) void {
    charge_pulse_log_enabled = enabled;
}

// ─── Aggro hooks ─────────────────────────────────────────────────────────────

pub fn tankOwnerForHostile(bots: []const BotSnapshot, world: []const WorldSnapshot, hostile_guid: u64) ?BotSnapshot {
    const stalagg = world_query.scanByNameOnMap(world, "Stalagg", map_id);
    if (stalagg != null and stalagg.?.guid == hostile_guid) return tankForSide(bots, .left);
    const feugen = world_query.scanByNameOnMap(world, "Feugen", map_id);
    if (feugen != null and feugen.?.guid == hostile_guid) return tankForSide(bots, .right);
    return null;
}

fn tankForSide(bots: []const BotSnapshot, side: state.Side) ?BotSnapshot {
    for (bots) |bot| {
        if (bot.state.map_id != map_id) continue;
        if (role_mod.roleForBot(bot) != .tank) continue;
        const tank_side = state.tankSide(bot.bot_id) orelse continue;
        if (tank_side == side) return bot;
    }
    return null;
}

// ─── Phase detection ──────────────────────────────────────────────────────────

const Phase = enum { idle, twins, transition, thaddius };

fn detectPhase(ctx: *const CombatContext) Phase {
    if (pred.thaddiusAttackable(ctx)) return .thaddius;
    if (state.bothTwinsDefeated()) return .transition;
    if (pred.twinStalaggAlive(ctx) or pred.twinFeugenAlive(ctx)) return .twins;
    return .idle;
}

fn detectPhaseForWorld(world: []const WorldSnapshot) Phase {
    if (thaddiusAttackableInWorld(world)) return .thaddius;
    if (state.bothTwinsDefeated()) return .transition;
    if (twinsAlive(world)) return .twins;
    return .idle;
}

pub fn beginTick(bots: []const BotSnapshot, world: []const WorldSnapshot, events: []const proto.SpellEvent, operator_fight_started: bool, intent_store: *const IntentStore) void {
    // Diagnostic only: deliberately ungated by fight/phase so charge auras can be
    // reproduced out of combat on a private server. No-op in production (flag off).
    if (charge_pulse_log_enabled) logChargePulses(bots, events);

    if (!operator_fight_started) return;

    var game_time_ms: u32 = 0;
    state.beginTankRefresh();
    for (bots) |bot| {
        if (bot.state.map_id != map_id) continue;
        if (game_time_ms == 0) game_time_ms = bot.state.game_time_ms;
        const bot_role = role_mod.roleForBot(bot);
        const name = std.mem.sliceTo(&bot.state.player_name, 0);
        const initial_side = roster.sideFromName(name);
        if (bot_role == .healer) {
            if (state.findOrInsert(bot.bot_id, initial_side)) |bs| {
                bs.side = bs.initial_side;
            }
        }
        if (bot_role != .tank) continue;

        state.refreshTank(bot.bot_id, bot.state.guid, name, initial_side);
        if (tankAtInitialRally(bot, initial_side)) state.setTankReady(bot.bot_id, initial_side);
    }
    state.refreshAssignedTanks();

    updateTwinDefeatState(world);
    const phase = detectPhaseForWorld(world);
    if (phase == .thaddius and game_time_ms != 0) {
        state.noteThaddiusAttackable(game_time_ms);
    }
    logPhaseChange(phase, world);

    const fight = state.fightState();
    if (!twinsAlive(world)) return;
    if (pred.magneticPullGoEventAfter(events, fight.last_magnetic_pull_game_time_ms)) |event| {
        _ = state.applySwap(event.spell_id, event.caster_guid, event.observer_guid, event.game_time_ms);
    }

    if (phase == .thaddius and game_time_ms != 0) {
        logPolarityProximityViolations(bots, intent_store, game_time_ms);
    }
}

fn polaritySign(is_positive: bool) u8 {
    return if (is_positive) '+' else '-';
}

fn polarityLastTag(p: state.Polarity) []const u8 {
    return switch (p) {
        .positive => "+",
        .negative => "-",
        .none => "?",
    };
}

fn polarityRouteTag(r: state.PolarityRoute) []const u8 {
    return switch (r) {
        .none => "none",
        .positive_to_negative => "p>n",
        .negative_to_positive => "n>p",
    };
}

fn polarityStepTag(step: u8) []const u8 {
    return switch (step) {
        0 => "wp0",
        1 => "wp1",
        2 => "wp2",
        3 => "done",
        else => "wp+",
    };
}

fn priorityTag(p: intent.Priority) []const u8 {
    return switch (p) {
        .idle => "idle",
        .role => "role",
        .spec => "spec",
        .encounter => "enc",
        .operator => "op",
    };
}

/// Charge polarity a bot currently carries, from its own marker aura (the same
/// source the planner routes on), or null if uncharged.
fn chargePolarity(bot: BotSnapshot) ?state.Polarity {
    if (world_query.hasAura(&bot.state.player_auras, bot.state.player_aura_count, pred.spell_polarity_positive)) return .positive;
    if (world_query.hasAura(&bot.state.player_auras, bot.state.player_aura_count, pred.spell_polarity_negative)) return .negative;
    return null;
}

fn pulseSignTag(p: state.Polarity) []const u8 {
    return switch (p) {
        .positive => "+",
        .negative => "-",
        .none => "?",
    };
}

/// True when `victim` is a different, alive, on-map bot whose charge is opposite
/// to `pulse_sign` and which sits inside the charge radius of `caster` — i.e. it
/// is taking polarity damage from this pulse.
fn isChargeVictim(caster: BotSnapshot, victim: BotSnapshot, pulse_sign: state.Polarity) bool {
    if (victim.state.guid == caster.state.guid) return false;
    if (victim.state.map_id != map_id) return false;
    if (victim.state.hp == 0) return false;
    const victim_pol = chargePolarity(victim) orelse return false;
    if (victim_pol == pulse_sign) return false; // same charge → buffed, not hurt

    const dx = caster.state.x - victim.state.x;
    const dy = caster.state.y - victim.state.y;
    return dx * dx + dy * dy <= charge_pulse_radius_yards * charge_pulse_radius_yards;
}

// Self-contained per-GUID cache for the charge diagnostic so it works without the
// encounter's per-bot state machine being initialized (e.g. reproducing the charge
// auras out of combat on a private server). `last_pulse_ms` dedups a pulse lingering
// in the 5 s SpellEventStore window; `hp_at_last_log` feeds the ΔHP column.
const ChargeLogEntry = struct {
    guid: u64 = 0,
    last_pulse_ms: u32 = 0,
    hp_at_last_log: u64 = 0,
};
var charge_log_cache: [state.max_bots]ChargeLogEntry = .{ChargeLogEntry{}} ** state.max_bots;

fn chargeLogEntry(guid: u64) *ChargeLogEntry {
    for (&charge_log_cache) |*e| {
        if (e.guid == guid) return e;
    }
    for (&charge_log_cache) |*e| {
        if (e.guid == 0) {
            e.guid = guid;
            return e;
        }
    }
    return &charge_log_cache[0]; // unreachable with ≤ max_bots distinct GUIDs
}

/// For each charge pulse (`go` of 28062/28085) emitted by a known bot this tick,
/// log every opposite-charge bot inside the charge radius — i.e. who is actually
/// taking polarity damage — with distance, HP and ΔHP since that victim was last
/// hit. One line per caster→victim pair. Silent when the raid is correctly sorted.
fn logChargePulses(bots: []const BotSnapshot, events: []const proto.SpellEvent) void {
    for (events) |ev| {
        if (ev.kind != @intFromEnum(proto.SpellEventKind.go)) continue;
        const pulse_sign: state.Polarity = switch (ev.spell_id) {
            spell_positive_charge_pulse => .positive,
            spell_negative_charge_pulse => .negative,
            else => continue,
        };

        const caster = registry_mod.botForGuid(bots, ev.caster_guid) orelse continue;
        if (caster.state.map_id != map_id) continue;
        const cs = chargeLogEntry(caster.state.guid);
        if (ev.game_time_ms <= cs.last_pulse_ms) continue;
        cs.last_pulse_ms = @max(cs.last_pulse_ms, ev.game_time_ms);

        for (bots) |victim| {
            if (!isChargeVictim(caster, victim, pulse_sign)) continue;
            const victim_pol = chargePolarity(victim).?;

            const dx = caster.state.x - victim.state.x;
            const dy = caster.state.y - victim.state.y;
            const dist_sq = dx * dx + dy * dy;

            const vs = chargeLogEntry(victim.state.guid);
            const hp_pct: u64 = if (victim.state.hp_max > 0)
                @as(u64, victim.state.hp) * 100 / victim.state.hp_max
            else
                0;
            const dhp = vs.hp_at_last_log -| victim.state.hp; // >0 = HP lost since last hit
            vs.hp_at_last_log = victim.state.hp;

            std.log.info(
                "thaddius: [charge] pulse={s} caster={s} caster_pol={s} caster_pos=({d},{d}) victim={s} victim_pol={s} dist={d:.1}yd hp={d}%({d}/{d}) dHP={d} game_time_ms={d}",
                .{
                    pulseSignTag(pulse_sign),
                    std.mem.sliceTo(&caster.state.player_name, 0),
                    pulseSignTag(pulse_sign),
                    @as(i32, @intFromFloat(caster.state.x)),
                    @as(i32, @intFromFloat(caster.state.y)),
                    std.mem.sliceTo(&victim.state.player_name, 0),
                    polarityLastTag(victim_pol),
                    @sqrt(dist_sq),
                    hp_pct,
                    victim.state.hp,
                    victim.state.hp_max,
                    dhp,
                    ev.game_time_ms,
                },
            );
        }
    }
}

fn logPolarityProximityViolations(bots: []const BotSnapshot, intent_store: *const IntentStore, game_time_ms: u32) void {
    for (bots, 0..) |a, i| {
        if (a.state.map_id != map_id) continue;
        if (a.state.hp == 0) continue;
        const a_pos = world_query.hasAura(&a.state.player_auras, a.state.player_aura_count, pred.spell_polarity_positive);
        const a_neg = world_query.hasAura(&a.state.player_auras, a.state.player_aura_count, pred.spell_polarity_negative);
        if (!a_pos and !a_neg) continue;

        for (bots[i + 1 ..]) |b| {
            if (b.state.map_id != map_id) continue;
            if (b.state.hp == 0) continue;
            const b_pos = world_query.hasAura(&b.state.player_auras, b.state.player_aura_count, pred.spell_polarity_positive);
            const b_neg = world_query.hasAura(&b.state.player_auras, b.state.player_aura_count, pred.spell_polarity_negative);
            if (!b_pos and !b_neg) continue;

            const opposite = (a_pos and b_neg) or (a_neg and b_pos);
            if (!opposite) continue;

            const dx = a.state.x - b.state.x;
            const dy = a.state.y - b.state.y;
            const dist_sq = dx * dx + dy * dy;
            const warn_sq = polarity_proximity_warn_yards * polarity_proximity_warn_yards;
            if (dist_sq > warn_sq) continue;

            const bs_a = state.find(a.bot_id) orelse continue;
            const bs_b = state.find(b.bot_id) orelse continue;
            if (game_time_ms -| bs_a.last_polarity_warn_ms < polarity_proximity_warn_interval_ms) continue;
            if (game_time_ms -| bs_b.last_polarity_warn_ms < polarity_proximity_warn_interval_ms) continue;

            bs_a.last_polarity_warn_ms = game_time_ms;
            bs_b.last_polarity_warn_ms = game_time_ms;

            const pol_a: state.Polarity = if (a_pos) .positive else .negative;
            const pol_b: state.Polarity = if (b_pos) .positive else .negative;
            const route_a = trig.routeForPolarity(pol_a, a.state.x, a.state.y);
            const route_b = trig.routeForPolarity(pol_b, b.state.x, b.state.y);

            const ai_a = intent_store.current(a.bot_id);
            const ai_b = intent_store.current(b.bot_id);

            std.log.info(
                "thaddius: [proximity] {s}({c},last={s},{s},route={s},intent={s}/{s}) ↔ {s}({c},last={s},{s},route={s},intent={s}/{s}) dist={d:.1}yd pos=({d},{d})/({d},{d})",
                .{
                    std.mem.sliceTo(&a.state.player_name, 0),            polaritySign(a_pos),
                    polarityLastTag(bs_a.last_polarity),                 polarityStepTag(bs_a.polarity_waypoint_step),
                    polarityRouteTag(route_a),                           if (ai_a) |ai| priorityTag(ai.priority) else "none",
                    if (ai_a) |ai| @tagName(ai.source) else "-",         std.mem.sliceTo(&b.state.player_name, 0),
                    polaritySign(b_pos),                                 polarityLastTag(bs_b.last_polarity),
                    polarityStepTag(bs_b.polarity_waypoint_step),        polarityRouteTag(route_b),
                    if (ai_b) |ai| priorityTag(ai.priority) else "none", if (ai_b) |ai| @tagName(ai.source) else "-",
                    @sqrt(dist_sq),                                      @as(i32, @intFromFloat(a.state.x)),
                    @as(i32, @intFromFloat(a.state.y)),                  @as(i32, @intFromFloat(b.state.x)),
                    @as(i32, @intFromFloat(b.state.y)),
                },
            );
        }
    }
}

fn updateTwinDefeatState(world: []const WorldSnapshot) void {
    if (world_query.scanByNameOnMap(world, "Stalagg", map_id)) |stalagg| {
        state.noteTwinSeen(.left, stalagg.hp);
    }
    if (world_query.scanByNameOnMap(world, "Feugen", map_id)) |feugen| {
        state.noteTwinSeen(.right, feugen.hp);
    }
}

fn tankAtInitialRally(bot: BotSnapshot, side: Side) bool {
    const rally = if (side == .left) arena.stalagg_initial else arena.feugen_initial;
    const dx = rally.x - bot.state.x;
    const dy = rally.y - bot.state.y;
    return dx * dx + dy * dy <= twin_route_done_arrival_yards * twin_route_done_arrival_yards;
}

fn twinsAlive(world: []const WorldSnapshot) bool {
    const stalagg = world_query.scanByNameOnMap(world, "Stalagg", map_id);
    const feugen = world_query.scanByNameOnMap(world, "Feugen", map_id);
    return (stalagg != null and !state.twinDefeatedHp(stalagg.?.hp)) or
        (feugen != null and !state.twinDefeatedHp(feugen.?.hp));
}

fn thaddiusAttackableInWorld(world: []const WorldSnapshot) bool {
    const thaddius = world_query.scanByNameOnMap(world, "Thaddius", map_id) orelse return false;
    if (proto.hasUnitFlag(thaddius.unit_flags, .uninteractible)) return false;
    if (proto.hasUnitFlag(thaddius.unit_flags, .immune_to_pc)) return false;
    return true;
}

fn logPhaseChange(phase: Phase, world: []const WorldSnapshot) void {
    if (last_logged_phase != null and last_logged_phase.? == phase) return;
    last_logged_phase = phase;

    const fight = state.fightState();
    const stalagg = world_query.scanByNameOnMap(world, "Stalagg", map_id);
    const feugen = world_query.scanByNameOnMap(world, "Feugen", map_id);
    const thaddius = world_query.scanByNameOnMap(world, "Thaddius", map_id);
    std.log.info("thaddius: phase={s} stalagg_hp={?} feugen_hp={?} thaddius_hp={?} thaddius_flags=0x{x} seen_alive={}/{} seen_dead={}/{}", .{
        @tagName(phase),
        if (stalagg) |s| s.hp else null,
        if (feugen) |f| f.hp else null,
        if (thaddius) |t| t.hp else null,
        if (thaddius) |t| t.unit_flags else 0,
        fight.stalagg_seen_alive,
        fight.feugen_seen_alive,
        fight.stalagg_seen_dead,
        fight.feugen_seen_dead,
    });
}

// ─── proposeIntent ────────────────────────────────────────────────────────────

pub fn proposeIntent(ctx: *const CombatContext, targets: *TargetStore, follow: *FollowStore) ?ActiveIntent {
    if (ctx.bot.state.map_id != map_id) return null;
    if (!ctx.operator_fight_started) return null;

    const char_name = std.mem.sliceTo(&ctx.bot.state.player_name, 0);
    const default_side = roster.sideFromName(char_name);
    const bs = state.findOrInsert(ctx.bot.bot_id, default_side) orelse return null;
    if (ctx.role == .tank) {
        bs.side = state.tankSide(ctx.bot.bot_id) orelse bs.side;
    } else {
        bs.side = bs.initial_side;
    }
    state.refreshAssignedTanks();

    const phase = detectPhase(ctx);

    if (bs.post_twin_queued and phase != .thaddius) return proposeTransitionIntent(ctx, bs, follow);

    switch (phase) {
        .idle => return proposeTwinsIntent(ctx, bs, targets, follow),
        .twins => return proposeTwinsIntent(ctx, bs, targets, follow),
        .transition => return proposeTransitionIntent(ctx, bs, follow),
        .thaddius => return proposeThaddiusIntent(ctx, bs, targets, follow),
    }
}

fn proposeTwinsIntent(ctx: *const CombatContext, bs: *state.BotState, targets: *TargetStore, follow: *FollowStore) ?ActiveIntent {
    if (!bs.twin_route_seeded) {
        bs.twin_route_seeded = true;
        var ai = trig.twinApproachIntent(bs.side);
        ai.created_at_ms = ctx.game_time_ms;
        return ai;
    }

    if (!bs.twin_route_done) {
        const rally = if (bs.side == .left) arena.stalagg_initial else arena.feugen_initial;
        const dx = rally.x - ctx.bot.state.x;
        const dy = rally.y - ctx.bot.state.y;
        if (dx * dx + dy * dy <= twin_route_done_arrival_yards * twin_route_done_arrival_yards) {
            bs.twin_route_done = true;
            std.log.info("thaddius: [{s}] route done (side={s})", .{
                std.mem.sliceTo(&ctx.bot.state.player_name, 0), @tagName(bs.side),
            });
            if (ctx.role == .tank) state.setTankReady(ctx.bot.bot_id, bs.side);
        } else {
            return null;
        }
    }

    if (ctx.role == .tank) {
        const fight = state.fightState();
        if (fight.swap_generation > bs.last_swap_generation_queued) {
            bs.side = state.tankSide(ctx.bot.bot_id) orelse bs.side;
            setTwinTankAnchor(ctx, follow, bs.side);
            bs.swap_in_progress = false;
            bs.last_swap_generation_queued = fight.swap_generation;
            const name = std.mem.sliceTo(&ctx.bot.state.player_name, 0);
            std.log.info("thaddius: [{s}] queue tank swap generation={} side={s}", .{ name, fight.swap_generation, @tagName(bs.side) });
            return trig.tankSwapIntent(ctx, bs.side);
        }
    } else {
        const fight = state.fightState();
        if (fight.swap_generation > bs.last_swap_generation_queued) {
            const release_ms = fight.last_magnetic_pull_game_time_ms +| trig.dps_swap_hold_ms;
            if (ctx.game_time_ms < release_ms) return trig.dpsSwapHoldIntent(ctx, release_ms);
            bs.last_swap_generation_queued = fight.swap_generation;
        }
    }

    if (ctx.role != .tank and ctx.role != .healer) {
        if (dpsSyncHoldIntent(ctx, bs.side)) |ai| return ai;
    }

    if (!state.bothTanksReady()) {
        if (ctx.role != .tank and ctx.role != .healer) return trig.dpsTankReadyHoldIntent(ctx);
        return null;
    }

    if (ctx.role == .tank) {
        if (trig.twinGuid(ctx, bs.side)) |guid| {
            if (bs.twin_pull_facing_done) {
                targets.set(ctx.bot.bot_id, guid);
            } else {
                targets.setSelectOnly(ctx.bot.bot_id, guid);
            }
        }
        setTwinTankAnchor(ctx, follow, bs.side);
        if (tankInitialPullIntent(ctx, bs)) |ai| return ai;
    } else if (!state.tanksPullSequenceDone()) {
        return trig.dpsTankPullSequenceHoldIntent(ctx);
    } else if (ctx.role != .healer and !bs.twin_opening_hold_done) {
        bs.twin_opening_hold_done = true;
        return trig.dpsOpeningHoldIntent(ctx, ctx.game_time_ms + trig.dps_opening_hold_ms);
    } else if (trig.twinGuid(ctx, bs.side)) |guid| {
        switch (ctx.role) {
            .melee_dps => targets.set(ctx.bot.bot_id, guid),
            // Ranged and casters select the twin so the spec rotation can target
            // it, but must not chase — the role proposer handles positioning.
            .ranged_dps => targets.setSelectOnly(ctx.bot.bot_id, guid),
            // Healers don't attack the twins; leave their target unset so the
            // role proposer doesn't position them relative to the boss.
            .healer, .tank => {},
        }
    }

    return null;
}

fn tankInitialPullIntent(ctx: *const CombatContext, bs: *state.BotState) ?ActiveIntent {
    if (!bs.twin_pull_platform_queued and !tankPullSpellCooldownFresh(ctx)) return null;
    bs.twin_pull_platform_queued = true;

    if (!bs.twin_pull_platform_done) {
        if (!arrivedAtTwinPlatform(ctx, bs.side)) return trig.tankPullPlatformIntent(ctx, bs.side);
        bs.twin_pull_platform_done = true;
    }

    if (!bs.twin_pull_facing_done) {
        const twin = twinForSide(ctx, bs.side) orelse return null;
        const desired_facing = geo.angleTo2d(
            .{ .x = ctx.bot.state.x, .y = ctx.bot.state.y, .z = ctx.bot.state.z },
            .{ .x = twin.x, .y = twin.y, .z = twin.z },
        );
        if (geo.absAngleDeltaRad(ctx.bot.state.orientation, desired_facing) > twin_pull_facing_tolerance_rad) {
            return trig.tankPullFacingIntent(ctx, desired_facing);
        }
        bs.twin_pull_facing_done = true;
    }

    return null;
}

fn tankPullSpellCooldownFresh(ctx: *const CombatContext) bool {
    const spell = spec_registry.meta(ctx.spec).pull_spell orelse return false;
    const n = @min(ctx.bot.state.cooldown_count, ctx.bot.state.cooldowns.len);
    for (ctx.bot.state.cooldowns[0..n]) |cooldown| {
        if (cooldown.spell_id != spell.spell_id) continue;
        if (cooldown.duration_ms == 0) return false;
        return cooldown.remaining_ms >= cooldown.duration_ms -| twin_pull_cooldown_fresh_ms;
    }
    return false;
}

fn arrivedAtTwinPlatform(ctx: *const CombatContext, side: Side) bool {
    if (ctx.bot.state.ctm_action != @intFromEnum(proto.CtmAction.idle)) return false;

    const platform = if (side == .left) arena.left_platform else arena.right_platform;
    const dx = platform.x - ctx.bot.state.x;
    const dy = platform.y - ctx.bot.state.y;
    const dz = platform.z - ctx.bot.state.z;
    const arrival_sq = twin_tank_anchor_arrival_yards * twin_tank_anchor_arrival_yards;
    return dx * dx + dy * dy + dz * dz <= arrival_sq;
}

fn twinForSide(ctx: *const CombatContext, side: Side) ?proto.ScanEntry {
    const twin_name: []const u8 = if (side == .left) "Stalagg" else "Feugen";
    return world_query.scanByNameOnMap(ctx.world, twin_name, map_id);
}

fn dpsSyncHoldIntent(ctx: *const CombatContext, side: Side) ?ActiveIntent {
    const my_hp_pct = trig.twinHpPct(ctx, side) orelse {
        std.log.warn("thaddius: dps sync blocked — no scan for {s} twin", .{@tagName(side)});
        return null;
    };
    const other_hp_pct = trig.twinHpPct(ctx, state.opposite(side)) orelse {
        std.log.warn("thaddius: dps sync blocked — no scan for {s} twin", .{@tagName(state.opposite(side))});
        return null;
    };

    if (my_hp_pct < trig.dps_sync_release_5_pct and other_hp_pct < trig.dps_sync_release_5_pct) return null;

    const hold_thresholds = [_]u32{
        trig.dps_sync_hold_50_pct,
        trig.dps_sync_hold_30_pct,
        trig.dps_sync_hold_15_pct,
    };

    inline for (hold_thresholds) |threshold_pct| {
        if (my_hp_pct <= threshold_pct and other_hp_pct > threshold_pct) {
            var ai = trig.dpsOpeningHoldIntent(ctx, ctx.game_time_ms + trig.dps_sync_hold_ms);
            ai.source = .encounter_pull;
            std.log.info("thaddius: dps sync hold [{s}] my_hp={}% other_hp={}% threshold={}%", .{
                std.mem.sliceTo(&ctx.bot.state.player_name, 0),
                my_hp_pct,
                other_hp_pct,
                threshold_pct,
            });
            return ai;
        }
    }

    return null;
}

// Polarity is the top priority once Thaddius is engaged: while the bot carries
// a polarity charge it must stay at the matching stack point. Without an
// anchor, the role proposer fights `polarityStackIntent` — once the encounter
// intent expires (3 ticks after arrival) the role layer recomputes back-arc /
// range-band placement against the boss, the bot drifts off, and the polarity
// stack intent re-fires to drag it back: erratic oscillation.
//
// During polarity, the encounter route is authoritative for every role. Role
// placement must not pull a bot off its sign group, including melee dps trying
// to micro-adjust into swing range.
fn updatePolarityAnchor(ctx: *const CombatContext, bs: *state.BotState, follow: *FollowStore) void {
    const stack = trig.polarityAnchorPosition(ctx, bs);
    if (stack == null) {
        follow.clearPosition(ctx.bot.bot_id);
        return;
    }

    follow.setPosition(ctx.bot.bot_id, .{
        .x = stack.?.x,
        .y = stack.?.y,
        .z = stack.?.z,
        .arrival_yards = stack.?.arrival_yards,
        .authoritative = true,
    });
}

fn setTwinTankAnchor(ctx: *const CombatContext, follow: *FollowStore, side: Side) void {
    const anchor = if (side == .left) arena.left_platform else arena.right_platform;
    follow.setPosition(ctx.bot.bot_id, .{
        .x = anchor.x,
        .y = anchor.y,
        .z = anchor.z,
        .arrival_yards = twin_tank_anchor_arrival_yards,
        // The platform position is the final word for the tank. Once inside
        // arrival_yards, the role proposer must NOT recompute back-arc behind
        // the twin (the engine handles facing via auto-attack). Without this,
        // the tank oscillates around the anchor edge as the twin shifts.
        .authoritative = true,
    });
}

fn proposeTransitionIntent(ctx: *const CombatContext, bs: *state.BotState, follow: *FollowStore) ?ActiveIntent {
    follow.clearPosition(ctx.bot.bot_id);

    if (!bs.post_twin_queued) {
        bs.post_twin_queued = true;
        bs.post_twin_arrived = false;
        bs.swap_in_progress = false;
        bs.last_swap_generation_queued = state.fightState().swap_generation;
        bs.thaddius_tank_engage_done = false;
        bs.thaddius_tank_engage_sent = false;
        bs.twin_pull_platform_queued = true;
        bs.twin_pull_platform_done = true;
        bs.twin_pull_facing_done = true;
        std.log.info("thaddius: [{s}] entering post-twin transition (side={s})", .{
            std.mem.sliceTo(&ctx.bot.state.player_name, 0), @tagName(bs.side),
        });
        return trig.postTwinTransitionIntent(ctx, bs.side);
    }

    if (!bs.post_twin_arrived) {
        if (!arrivedAtPostTwinStack(ctx, bs.side)) return null;
        bs.post_twin_arrived = true;
        std.log.info("thaddius: [{s}] post-twin transition arrived (side={s})", .{
            std.mem.sliceTo(&ctx.bot.state.player_name, 0), @tagName(bs.side),
        });
    }

    return trig.transitionHoldIntent(ctx);
}

fn arrivedAtPostTwinStack(ctx: *const CombatContext, side: Side) bool {
    if (ctx.bot.state.ctm_action != @intFromEnum(proto.CtmAction.idle)) return false;

    const stack = if (side == .left) arena.stack_melee_positive else arena.stack_melee_negative;
    const dx = stack.x - ctx.bot.state.x;
    const dy = stack.y - ctx.bot.state.y;
    const dz = stack.z - ctx.bot.state.z;
    return dx * dx + dy * dy + dz * dz <= stack.arrival_yards * stack.arrival_yards;
}

fn proposeThaddiusIntent(ctx: *const CombatContext, bs: *state.BotState, targets: *TargetStore, follow: *FollowStore) ?ActiveIntent {
    updatePolarityAnchor(ctx, bs, follow);

    if (!bs.post_twin_queued) {
        bs.post_twin_queued = true;
        bs.post_twin_arrived = false;
        bs.thaddius_opening_hold_done = false;
        bs.thaddius_tank_engage_done = false;
        bs.thaddius_tank_engage_sent = false;
        std.log.info("thaddius: [{s}] entering thaddius phase (side={s})", .{
            std.mem.sliceTo(&ctx.bot.state.player_name, 0), @tagName(bs.side),
        });
        return trig.postTwinIntent(ctx, bs.side);
    }

    if (ctx.role == .tank) {
        if (thaddiusTankEngageIntent(ctx, bs, targets)) |ai| return ai;
    }

    if (trig.polarityStackIntent(ctx, bs)) |stack| {
        return stack;
    }

    if (ctx.role != .tank and ctx.role != .healer and !bs.thaddius_opening_hold_done) {
        bs.thaddius_opening_hold_done = true;
        const fight = state.fightState();
        const release_ms = fight.thaddius_attackable_game_time_ms +| trig.thaddius_dps_opening_hold_ms;
        return trig.thaddiusDpsOpeningHoldIntent(ctx, release_ms);
    }

    if (trig.thaddiusGuid(ctx)) |guid| setThaddiusTarget(ctx, targets, guid);
    return null;
}

fn thaddiusTankEngageIntent(ctx: *const CombatContext, bs: *state.BotState, targets: *TargetStore) ?ActiveIntent {
    if (bs.thaddius_tank_engage_done) return null;

    const guid = trig.thaddiusGuid(ctx) orelse return null;
    setThaddiusTarget(ctx, targets, guid);
    if (bs.thaddius_tank_engage_sent and ctx.bot.state.target_guid == guid) {
        bs.thaddius_tank_engage_done = true;
        return null;
    }

    bs.thaddius_tank_engage_sent = true;
    return trig.thaddiusTankEngageIntent(ctx, guid);
}

fn setThaddiusTarget(ctx: *const CombatContext, targets: *TargetStore, guid: u64) void {
    const name = std.mem.sliceTo(&ctx.bot.state.player_name, 0);
    if (pred.hasPolarityPositive(ctx) or pred.hasPolarityNegative(ctx)) {
        targets.setSelectOnly(ctx.bot.bot_id, guid);
        const pol = if (pred.hasPolarityPositive(ctx)) "positive" else if (pred.hasPolarityNegative(ctx)) "negative" else "none";
        std.log.info("thaddius: [target_mode] bot={s} mode=select_only polarity={s}", .{ name, pol });
        return;
    }

    targets.set(ctx.bot.bot_id, guid);
    std.log.info("thaddius: [target_mode] bot={s} mode=attack polarity=none", .{name});
}

// ─── Lifecycle (GUI) ──────────────────────────────────────────────────────────

pub fn onStartFight(
    io: std.Io,
    registry: *registry_mod.Registry,
    bots: []const BotSnapshot,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    follow_store: *FollowStore,
) void {
    state.reset();
    last_logged_phase = null;

    for (bots) |bot| {
        if (bot.state.map_id != map_id) continue;

        const bot_id = bot.bot_id;
        const char_name = std.mem.sliceTo(&bot.state.player_name, 0);
        const side = roster.sideFromName(char_name);
        const game_time_ms = bot.state.game_time_ms;

        const one = [_]BotId{bot_id};
        _ = registry.dispatch(io, .ctm_stop, &one);
        follow_store.clearPosition(bot_id);

        const bs = state.findOrInsert(bot_id, side) orelse {
            std.log.warn("thaddius: onStartFight state full for {s}", .{char_name});
            continue;
        };
        bs.side = side;
        bs.initial_side = side;
        bs.twin_route_seeded = true;
        bs.twin_route_done = false;
        bs.swap_in_progress = false;
        bs.last_swap_generation_queued = 0;
        bs.post_twin_queued = false;
        bs.post_twin_arrived = false;
        bs.thaddius_tank_engage_sent = false;
        bs.thaddius_tank_engage_done = false;
        bs.twin_pull_platform_queued = false;
        bs.twin_pull_platform_done = false;
        bs.twin_pull_facing_done = false;

        var ai = trig.twinApproachIntent(side);
        ai.created_at_ms = game_time_ms;
        const r = intent_store.replace(bot_id, ai, true, dispatch_store, game_time_ms);
        if (r == .rejected_priority) {
            std.log.warn("thaddius: onStartFight intent rejected for {s}", .{char_name});
        }
    }
}

pub fn onCleanOrders(
    io: std.Io,
    registry: *registry_mod.Registry,
    bots: []const BotSnapshot,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    follow_store: *FollowStore,
) void {
    state.reset();
    last_logged_phase = null;

    for (bots) |bot| {
        if (bot.state.map_id != map_id) continue;

        const bot_id = bot.bot_id;
        const game_time_ms = bot.state.game_time_ms;
        const one = [_]BotId{bot_id};
        _ = registry.dispatch(io, .ctm_stop, &one);
        intent_store.clear(bot_id, dispatch_store, game_time_ms);
        follow_store.clearPosition(bot_id);
    }
}

pub fn onTestJump(
    io: std.Io,
    registry: *registry_mod.Registry,
    bots: []const BotSnapshot,
    intent_store: *IntentStore,
    dispatch_store: *DispatchStore,
    follow_store: *FollowStore,
) void {
    for (bots) |bot| {
        if (bot.state.map_id != map_id) continue;

        const bot_id = bot.bot_id;
        const char_name = std.mem.sliceTo(&bot.state.player_name, 0);
        const side = roster.sideFromName(char_name);
        const game_time_ms = bot.state.game_time_ms;

        const one = [_]BotId{bot_id};
        _ = registry.dispatch(io, .ctm_stop, &one);
        follow_store.clearPosition(bot_id);

        const bs = state.findOrInsert(bot_id, side) orelse {
            std.log.warn("thaddius: onTestJump state full for {s}", .{char_name});
            continue;
        };
        bs.side = side;
        bs.initial_side = side;
        bs.twin_route_seeded = true;
        bs.twin_route_done = true;
        bs.post_twin_queued = true;
        bs.post_twin_arrived = false;
        bs.thaddius_tank_engage_sent = false;
        bs.thaddius_tank_engage_done = false;
        bs.swap_in_progress = false;
        bs.last_swap_generation_queued = state.fightState().swap_generation;
        bs.twin_pull_platform_queued = true;
        bs.twin_pull_platform_done = true;
        bs.twin_pull_facing_done = true;

        const ctx = CombatContext.build(bot, bots, &.{}, &.{}, false);
        var ai = trig.postTwinIntent(&ctx, side);
        ai.created_at_ms = game_time_ms;
        _ = intent_store.replace(bot_id, ai, true, dispatch_store, game_time_ms);
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

fn makePaladinBot(id: u8, x: f32, y: f32, z: f32) BotSnapshot {
    var bot = std.mem.zeroes(BotSnapshot);
    bot.bot_id[0] = id;
    bot.state.class = @intFromEnum(@import("../../class_spec.zig").Class.paladin);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 51, .tab3 = 0 };
    bot.state.map_id = map_id;
    bot.state.x = x;
    bot.state.y = y;
    bot.state.z = z;
    bot.state.hp = 1000;
    bot.state.hp_max = 1000;
    return bot;
}

fn setName(bot: *BotSnapshot, name: []const u8) void {
    @memset(bot.state.player_name[0..], 0);
    @memcpy(bot.state.player_name[0..name.len], name);
}

fn magneticPullEvent(kind: proto.SpellEventKind, spell_id: u32, game_time_ms: u32) proto.SpellEvent {
    return .{
        .kind = @intFromEnum(kind),
        ._pad = .{ 0, 0, 0 },
        .observer_guid = 0x9999,
        .caster_guid = 0xDEAD,
        .spell_id = spell_id,
        .flags = 0,
        .value_ms = 0,
        .game_time_ms = game_time_ms,
    };
}

fn makeWorldWithTwins() [2]WorldSnapshot {
    return makeWorldWithTwinsAtHp(1000, 1000);
}

fn makeWorldWithTwinsAtHp(stalagg_hp: u32, feugen_hp: u32) [2]WorldSnapshot {
    const hp_max: u32 = 1000;

    var stalagg = std.mem.zeroes(proto.ScanEntry);
    stalagg.guid = 0x1111;
    stalagg.hp = stalagg_hp;
    stalagg.hp_max = hp_max;
    std.mem.copyForwards(u8, stalagg.name[0.."Stalagg".len], "Stalagg");
    stalagg.x = 3431.0;
    stalagg.y = -2951.0;
    stalagg.z = 311.6;

    var feugen = std.mem.zeroes(proto.ScanEntry);
    feugen.guid = 0x2222;
    feugen.hp = feugen_hp;
    feugen.hp_max = hp_max;
    std.mem.copyForwards(u8, feugen.name[0.."Feugen".len], "Feugen");
    feugen.x = 3488.0;
    feugen.y = -3009.0;
    feugen.z = 311.6;

    return .{
        .{ .scan = stalagg, .map_id = map_id, .last_seen_ts_ns = 0 },
        .{ .scan = feugen, .map_id = map_id, .last_seen_ts_ns = 0 },
    };
}

fn makeWorldWithThaddius() [1]WorldSnapshot {
    var thaddius = std.mem.zeroes(proto.ScanEntry);
    thaddius.guid = 0x3333;
    thaddius.hp = 1000;
    std.mem.copyForwards(u8, thaddius.name[0.."Thaddius".len], "Thaddius");
    thaddius.x = 3515.0;
    thaddius.y = -2924.0;
    thaddius.z = 303.0;

    return .{.{ .scan = thaddius, .map_id = map_id, .last_seen_ts_ns = 0 }};
}

fn makeWorldWithBlockedThaddius() [1]WorldSnapshot {
    var world = makeWorldWithThaddius();
    world[0].scan.unit_flags = @intFromEnum(proto.UnitFlag.uninteractible) |
        @intFromEnum(proto.UnitFlag.immune_to_pc);
    return world;
}

fn makeWorldWithAttackableZeroHpThaddius() [1]WorldSnapshot {
    var world = makeWorldWithThaddius();
    world[0].scan.hp = 0;
    world[0].scan.unit_flags = 0;
    return world;
}

test "proposeIntent: seeds twin approach sequenced intent on first call" {
    state.reset();
    const bot = makePaladinBot(1, 3426.0, -3003.0, 295.6);
    const world = makeWorldWithTwins();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow);
    try std.testing.expect(ai != null);
    try std.testing.expect(ai.?.intent == .sequenced);
    try std.testing.expectEqual(intent.Priority.encounter, ai.?.priority);
    try std.testing.expect(ai.?.intent.sequenced.steps[2].intent == .moving_to);
    try std.testing.expectEqual(arena.stalagg_initial.x, ai.?.intent.sequenced.steps[2].intent.moving_to.pos.x);
    try std.testing.expectEqual(arena.stalagg_initial.y, ai.?.intent.sequenced.steps[2].intent.moving_to.pos.y);
}

test "onTestJump: post-twin sequence uses engineering boots" {
    state.reset();
    var bot = makePaladinBot(1, 3489.0, -3002.0, 312.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Sangboulon");
    bot.state.game_time_ms = 1234;

    const world = makeWorldWithTwins();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, false);
    const ai = trig.postTwinIntent(&ctx, .right);

    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expectEqual(@as(u8, 5), ai.intent.sequenced.len);
    try std.testing.expect(ai.intent.sequenced.steps[1].intent == .waiting_for);
    try std.testing.expect(ai.intent.sequenced.steps[1].intent.waiting_for.until == .sequenced_step_elapsed_ms);
    try std.testing.expectEqual(trig.post_twin_platform_settle_ms, ai.intent.sequenced.steps[1].intent.waiting_for.until.sequenced_step_elapsed_ms);
    try std.testing.expect(ai.intent.sequenced.steps[2].intent == .use_inventory_item);
    try std.testing.expectEqual(arena.boots_inventory_slot, ai.intent.sequenced.steps[2].intent.use_inventory_item);
    try std.testing.expect(ai.intent.sequenced.steps[3].intent == .moving_to);
    try std.testing.expect(ai.intent.sequenced.steps[3].intent.moving_to.non_blocking);
    try std.testing.expectEqual(arena.right_waypoint.x, ai.intent.sequenced.steps[3].intent.moving_to.pos.x);
    try std.testing.expectEqual(arena.right_waypoint.y, ai.intent.sequenced.steps[3].intent.moving_to.pos.y);
    try std.testing.expect(ai.intent.sequenced.steps[3].done_when.? == .arrived_at);
    try std.testing.expectEqual(arena.right_waypoint.x, ai.intent.sequenced.steps[3].done_when.?.arrived_at.x);
    try std.testing.expectEqual(arena.right_waypoint.y, ai.intent.sequenced.steps[3].done_when.?.arrived_at.y);
    try std.testing.expect(ai.intent.sequenced.steps[3].trigger_once.?.action == .jump);
    try std.testing.expect(ai.intent.sequenced.steps[3].trigger_once.?.when == .z_above);
    try std.testing.expectEqual(arena.post_twin_jump_z_threshold, ai.intent.sequenced.steps[3].trigger_once.?.when.z_above);
    try std.testing.expect(ai.intent.sequenced.steps[4].intent == .moving_to);
    try std.testing.expect(ai.intent.sequenced.steps[4].intent.moving_to.non_blocking);
    try std.testing.expectEqual(arena.stack_melee_negative.x, ai.intent.sequenced.steps[4].intent.moving_to.pos.x);
    try std.testing.expectEqual(arena.stack_melee_negative.y, ai.intent.sequenced.steps[4].intent.moving_to.pos.y);
    try std.testing.expect(ai.intent.sequenced.steps[4].done_when.? == .arrived_at);
    try std.testing.expectEqual(arena.stack_melee_negative.x, ai.intent.sequenced.steps[4].done_when.?.arrived_at.x);
    try std.testing.expectEqual(arena.stack_melee_negative.y, ai.intent.sequenced.steps[4].done_when.?.arrived_at.y);
}

test "proposeIntent: one dead twin does not trigger post-twin transition" {
    state.reset();
    var bot = makePaladinBot(1, arena.stalagg_initial.x, arena.stalagg_initial.y, arena.stalagg_initial.z);
    setName(&bot, "Lefttank");

    var world = makeWorldWithTwins();
    beginTick(&.{bot}, &world, &.{}, true, &(.{}));
    world[0].scan.hp = 0;
    beginTick(&.{bot}, world[0..1], &.{}, true, &(.{}));

    const ctx = CombatContext.build(bot, &.{bot}, world[0..1], &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expectEqual(intent.Reason.encounter_route, ai.source);
}

test "proposeIntent: both twins seen dead triggers post-twin transition" {
    state.reset();
    var bot = makePaladinBot(1, arena.stalagg_initial.x, arena.stalagg_initial.y, arena.stalagg_initial.z);
    setName(&bot, "Lefttank");

    var world = makeWorldWithTwins();
    beginTick(&.{bot}, &world, &.{}, true, &(.{}));
    world[0].scan.hp = 0;
    world[1].scan.hp = 0;
    beginTick(&.{bot}, &world, &.{}, true, &(.{}));

    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expectEqual(intent.Reason.encounter_transition, ai.source);
    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expect(ai.intent.sequenced.steps[0].intent == .stop_attack);
    try std.testing.expect(ai.intent.sequenced.steps[1].intent == .waiting_for);
    try std.testing.expect(ai.intent.sequenced.steps[1].intent.waiting_for.until == .ctm_idle);
}

test "proposeIntent: both twins at one hp triggers post-twin transition" {
    state.reset();
    var bot = makePaladinBot(1, arena.stalagg_initial.x, arena.stalagg_initial.y, arena.stalagg_initial.z);
    setName(&bot, "Lefttank");

    var world = makeWorldWithTwins();
    beginTick(&.{bot}, &world, &.{}, true, &(.{}));
    world[0].scan.hp = state.twin_defeated_hp_threshold;
    world[1].scan.hp = state.twin_defeated_hp_threshold;
    beginTick(&.{bot}, &world, &.{}, true, &(.{}));

    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expectEqual(intent.Reason.encounter_transition, ai.source);
    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expect(ai.intent.sequenced.steps[0].intent == .stop_attack);
}

test "proposeIntent: defeated twins state beats stale live twin scan" {
    state.reset();
    var bot = makePaladinBot(1, arena.stalagg_initial.x, arena.stalagg_initial.y, arena.stalagg_initial.z);
    setName(&bot, "Lefttank");

    var world = makeWorldWithTwins();
    state.noteTwinSeen(.left, 1000);
    state.noteTwinSeen(.right, 1000);
    state.noteTwinSeen(.left, 0);
    state.noteTwinSeen(.right, 0);

    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expectEqual(intent.Reason.encounter_transition, ai.source);
    try std.testing.expect(ai.intent == .sequenced);
}

test "proposeIntent: forced post-twin keeps control while twins are still scanned" {
    state.reset();
    var bot = makePaladinBot(1, arena.stack_melee_positive.x, arena.stack_melee_positive.y, arena.stack_melee_positive.z);
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    bot.state.game_time_ms = 1000;
    setName(&bot, "Lefttank");

    const world = makeWorldWithTwins();
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;

    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expectEqual(intent.Reason.encounter_transition, ai.source);
    try std.testing.expect(ai.intent == .waiting_for);
    try std.testing.expectEqual(@as(?u64, null), targets.get(bot.bot_id));
    try std.testing.expect(follow.get(bot.bot_id) == null or follow.get(bot.bot_id).?.position_override == null);
}

test "proposeIntent: blocked thaddius flags keep transition hold" {
    state.reset();
    var bot = makePaladinBot(1, arena.stack_melee_positive.x, arena.stack_melee_positive.y, arena.stack_melee_positive.z);
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    setName(&bot, "Lefttank");

    var twins = makeWorldWithTwins();
    beginTick(&.{bot}, &twins, &.{}, true, &(.{}));
    twins[0].scan.hp = 0;
    twins[1].scan.hp = 0;
    beginTick(&.{bot}, &twins, &.{}, true, &(.{}));

    var blocked = makeWorldWithBlockedThaddius();
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = false;

    const ctx = CombatContext.build(bot, &.{bot}, &blocked, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expectEqual(intent.Reason.encounter_transition, ai.source);
    try std.testing.expect(ai.intent == .waiting_for);
    try std.testing.expectEqual(@as(?u64, null), targets.get(bot.bot_id));
}

test "proposeIntent: thaddius attackable flags resume normal targeting" {
    state.reset();
    var bot = makePaladinBot(1, arena.stack_melee_positive.x, arena.stack_melee_positive.y, arena.stack_melee_positive.z);
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    setName(&bot, "Lefttank");

    var twins = makeWorldWithTwins();
    beginTick(&.{bot}, &twins, &.{}, true, &(.{}));
    twins[0].scan.hp = 0;
    twins[1].scan.hp = 0;
    beginTick(&.{bot}, &twins, &.{}, true, &(.{}));

    const world = makeWorldWithThaddius();
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;

    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expectEqual(intent.Reason.encounter_pull, ai.source);
    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expectEqual(@as(u8, 1), ai.intent.sequenced.len);
    try std.testing.expect(ai.intent.sequenced.steps[0].intent == .targeting);
    try std.testing.expectEqual(@as(u64, 0x3333), ai.intent.sequenced.steps[0].intent.targeting.target_guid);
    try std.testing.expectEqual(@as(?u64, 0x3333), targets.get(bot.bot_id));

    var targeted_bot = bot;
    targeted_bot.state.target_guid = 0x3333;
    const targeted_ctx = CombatContext.build(targeted_bot, &.{targeted_bot}, &world, &.{}, true);

    targets.reset();
    const again = proposeIntent(&targeted_ctx, &targets, &follow);
    try std.testing.expect(again == null);
    try std.testing.expectEqual(@as(?u64, 0x3333), targets.get(bot.bot_id));
}

test "proposeIntent: thaddius tank engage repeats until target selection is observed" {
    state.reset();
    var bot = makePaladinBot(1, arena.stack_melee_positive.x, arena.stack_melee_positive.y, arena.stack_melee_positive.z);
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    setName(&bot, "Lefttank");

    const world = makeWorldWithThaddius();
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const first = proposeIntent(&ctx, &targets, &follow).?;
    const second = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expect(first.intent == .sequenced);
    try std.testing.expect(second.intent == .sequenced);
    try std.testing.expect(!bs.thaddius_tank_engage_done);

    bot.state.target_guid = 0x3333;
    const targeted_ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    targets.reset();
    const done = proposeIntent(&targeted_ctx, &targets, &follow);

    try std.testing.expect(done == null);
    try std.testing.expect(bs.thaddius_tank_engage_done);
    try std.testing.expectEqual(@as(?u64, 0x3333), targets.get(bot.bot_id));
}

test "proposeIntent: thaddius zero hp with attackable flags starts phase" {
    state.reset();
    var bot = makePaladinBot(1, arena.stack_melee_positive.x, arena.stack_melee_positive.y, arena.stack_melee_positive.z);
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    setName(&bot, "Lefttank");

    var twins = makeWorldWithTwins();
    beginTick(&.{bot}, &twins, &.{}, true, &(.{}));
    twins[0].scan.hp = 0;
    twins[1].scan.hp = 0;
    beginTick(&.{bot}, &twins, &.{}, true, &(.{}));

    const world = makeWorldWithAttackableZeroHpThaddius();
    beginTick(&.{bot}, &world, &.{}, true, &(.{}));

    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;

    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expectEqual(@as(u32, bot.state.game_time_ms), state.fightState().thaddius_attackable_game_time_ms);
    try std.testing.expectEqual(intent.Reason.encounter_pull, ai.source);
    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expect(ai.intent.sequenced.steps[0].intent == .targeting);
    try std.testing.expectEqual(@as(u64, 0x3333), ai.intent.sequenced.steps[0].intent.targeting.target_guid);
    try std.testing.expectEqual(@as(?u64, 0x3333), targets.get(bot.bot_id));
}

test "beginTick: magnetic pull go swaps both tanks globally" {
    state.reset();
    var bot = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Lefttank");

    var other_tank = makePaladinBot(2, 3508.0, -2988.0, 312.0);
    other_tank.state.guid = 0xBBBB;
    setName(&other_tank, "Sangboulon");

    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    const other_bs = state.findOrInsert(other_tank.bot_id, .right).?;
    other_bs.twin_route_seeded = true;
    other_bs.twin_route_done = true;

    const world = makeWorldWithTwins();
    const events = [_]proto.SpellEvent{magneticPullEvent(.go, pred.spell_magnetic_pull_trigger, 1000)};
    beginTick(&.{ bot, other_tank }, &world, &events, true, &(.{}));

    try std.testing.expectEqual(@as(u32, 1), state.fightState().swap_generation);
    try std.testing.expectEqual(Side.right, state.tankSide(bot.bot_id).?);
    try std.testing.expectEqual(Side.left, state.tankSide(other_tank.bot_id).?);

    const ctx = CombatContext.build(bot, &.{ bot, other_tank }, &world, &events, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow);
    try std.testing.expect(ai != null);
    try std.testing.expect(ai.?.intent == .sequenced);
    try std.testing.expectEqual(@as(u8, 3), ai.?.intent.sequenced.len);
    try std.testing.expect(ai.?.intent.sequenced.steps[0].intent == .targeting);
    try std.testing.expect(ai.?.intent.sequenced.steps[1].intent == .moving_to);
    try std.testing.expect(ai.?.intent.sequenced.steps[2].intent == .targeting);
    try std.testing.expectEqual(@as(f32, @import("arena.zig").right_platform.x), ai.?.intent.sequenced.steps[1].intent.moving_to.pos.x);
    try std.testing.expectEqual(@as(f32, @import("arena.zig").right_platform.y), ai.?.intent.sequenced.steps[1].intent.moving_to.pos.y);
    try std.testing.expectEqual(twin_tank_anchor_arrival_yards, ai.?.intent.sequenced.steps[1].intent.moving_to.arrival_yards);
    try std.testing.expectEqual(intent.Reason.encounter_swap, ai.?.source);
}

test "beginTick: magnetic pull refreshes healer assigned tank before context build" {
    state.reset();

    var healer = makePaladinBot(3, 3433.0, -2948.0, 312.0);
    healer.state.guid = 0xCCCC;
    healer.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    setName(&healer, "Lumibarbe");

    var left_tank = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    left_tank.state.guid = 0xAAAA;
    setName(&left_tank, "Lefttank");

    var right_tank = makePaladinBot(2, 3508.0, -2988.0, 312.0);
    right_tank.state.guid = 0xBBBB;
    setName(&right_tank, "Sangboulon");

    const world = makeWorldWithTwins();
    const events = [_]proto.SpellEvent{magneticPullEvent(.go, pred.spell_magnetic_pull_trigger, 1000)};
    beginTick(&.{ healer, left_tank, right_tank }, &world, &events, true, &(.{}));

    const ctx = CombatContext.build(healer, &.{ healer, left_tank, right_tank }, &world, &events, true);
    try std.testing.expectEqual(left_tank.state.guid, ctx.assigned_tank_guid);
}

test "beginTick: magnetic pull duplicate is consumed once" {
    state.reset();
    var bot = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Lefttank");

    var other_tank = makePaladinBot(2, 3508.0, -2988.0, 312.0);
    other_tank.state.guid = 0xBBBB;
    setName(&other_tank, "Sangboulon");

    var world = makeWorldWithTwins();
    _ = &world;
    const events = [_]proto.SpellEvent{
        magneticPullEvent(.go, pred.spell_magnetic_pull_trigger, 1000),
        magneticPullEvent(.go, pred.spell_magnetic_pull_trigger, 1000),
    };

    beginTick(&.{ bot, other_tank }, &world, &events, true, &(.{}));
    beginTick(&.{ bot, other_tank }, &world, &events, true, &(.{}));

    try std.testing.expectEqual(@as(u32, 1), state.fightState().swap_generation);
}

test "beginTick: magnetic pull effect events are ignored" {
    state.reset();
    var bot = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Lefttank");

    var other_tank = makePaladinBot(2, 3508.0, -2988.0, 312.0);
    other_tank.state.guid = 0xBBBB;
    setName(&other_tank, "Sangboulon");

    var world = makeWorldWithTwins();
    _ = &world;
    const events = [_]proto.SpellEvent{
        magneticPullEvent(.start, pred.spell_magnetic_pull_trigger, 1000),
        magneticPullEvent(.go, pred.spell_magnetic_pull_trigger, 1000),
        magneticPullEvent(.go, 30010, 1052),
        magneticPullEvent(.go, 30010, 1052),
    };

    beginTick(&.{ bot, other_tank }, &world, &events, true, &(.{}));
    beginTick(&.{ bot, other_tank }, &world, &events, true, &(.{}));

    try std.testing.expectEqual(@as(u32, 1), state.fightState().swap_generation);
}

test "beginTick: legacy magnetic pull ids are ignored" {
    state.reset();
    var bot = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Lefttank");

    var other_tank = makePaladinBot(2, 3508.0, -2988.0, 312.0);
    other_tank.state.guid = 0xBBBB;
    setName(&other_tank, "Sangboulon");

    var world = makeWorldWithTwins();
    _ = &world;
    const events = [_]proto.SpellEvent{
        magneticPullEvent(.go, 28338, 1000),
        magneticPullEvent(.go, 28339, 1000),
        magneticPullEvent(.go, 30010, 1000),
    };

    beginTick(&.{ bot, other_tank }, &world, &events, true, &(.{}));

    try std.testing.expectEqual(@as(u32, 0), state.fightState().swap_generation);
}

test "beginTick: magnetic pull start does not swap" {
    state.reset();
    var bot = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Lefttank");

    var other_tank = makePaladinBot(2, 3508.0, -2988.0, 312.0);
    other_tank.state.guid = 0xBBBB;
    setName(&other_tank, "Sangboulon");

    const world = makeWorldWithTwins();
    const events = [_]proto.SpellEvent{magneticPullEvent(.start, pred.spell_magnetic_pull_trigger, 1000)};

    beginTick(&.{ bot, other_tank }, &world, &events, true, &(.{}));

    try std.testing.expectEqual(@as(u32, 0), state.fightState().swap_generation);
}

test "beginTick: magnetic pull fails closed without exactly two tanks" {
    state.reset();
    var tank_a = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    tank_a.state.guid = 0xAAAA;
    setName(&tank_a, "Lefttank");

    var tank_b = makePaladinBot(2, 3508.0, -2988.0, 312.0);
    tank_b.state.guid = 0xBBBB;
    setName(&tank_b, "Sangboulon");

    var tank_c = makePaladinBot(3, 3508.0, -2988.0, 312.0);
    tank_c.state.guid = 0xCCCC;
    setName(&tank_c, "Thirdtank");

    const world = makeWorldWithTwins();
    const events = [_]proto.SpellEvent{magneticPullEvent(.go, pred.spell_magnetic_pull_trigger, 1000)};

    beginTick(&.{ tank_a, tank_b, tank_c }, &world, &events, true, &(.{}));

    try std.testing.expectEqual(@as(u32, 0), state.fightState().swap_generation);
}

test "beginTick: target guid changes never trigger tank swap" {
    state.reset();
    var bot = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Lefttank");

    var other_tank = makePaladinBot(2, 3508.0, -2988.0, 312.0);
    other_tank.state.guid = 0xBBBB;
    setName(&other_tank, "Sangboulon");

    var world = makeWorldWithTwins();
    world[0].scan.target_guid = 0xBBBB;
    world[1].scan.target_guid = 0xAAAA;

    beginTick(&.{ bot, other_tank }, &world, &.{}, true, &(.{}));

    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;

    const ctx = CombatContext.build(bot, &.{ bot, other_tank }, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow);
    try std.testing.expect(ai == null or ai.?.source != .encounter_swap);
}

test "proposeIntent: polarity stack returns stacking intent" {
    state.reset();
    var bot = makePaladinBot(1, 3499.0, -2988.0, 312.0);
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_positive,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    const world = makeWorldWithTwins();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, false);
    const bs = state.findOrInsert(bot.bot_id, .left).?;

    const ai = trig.polarityStackIntent(&ctx, bs);
    try std.testing.expect(ai != null);
    try std.testing.expect(ai.?.intent == .stacking);
    try std.testing.expectEqual(intent.Priority.encounter, ai.?.priority);
}

fn setPolarityAura(bot: *BotSnapshot, spell_id: u32) void {
    bot.state.player_auras[0] = .{ .spell_id = spell_id, .remaining_ms = 8000, .caster_guid = 0 };
    bot.state.player_aura_count = 1;
}

// cmangos allocates aura slots first-free over the full `MAX_AURAS` (64) range, so a
// heavily-buffed bot carries the polarity charge marker past the old 40-slot wire cap.
// `player_auras` must hold the whole range or the charge reads as `none` until buffs expire.
test "chargePolarity: marker past the legacy 40-slot cap is still detected" {
    try std.testing.expect(proto.max_auras >= 64);

    var bot = makePaladinBot(1, 3499.0, -2988.0, 312.0);
    var i: u32 = 0;
    while (i < proto.max_auras) : (i += 1) {
        bot.state.player_auras[i] = .{ .spell_id = 1126 + i, .remaining_ms = 8000, .caster_guid = 0 };
    }
    const charge_slot = 50; // > legacy cap of 40, < max_auras
    bot.state.player_auras[charge_slot] = .{
        .spell_id = pred.spell_polarity_negative,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = proto.max_auras;

    try std.testing.expectEqual(state.Polarity.negative, chargePolarity(bot).?);
}

test "isChargeVictim: opposite charge inside radius takes damage" {
    var caster = makePaladinBot(1, 3510.0, -2930.0, 303.0);
    caster.state.guid = 0x100;
    setPolarityAura(&caster, pred.spell_polarity_positive);

    // Negative charge 6 yd away → victim of the positive pulse.
    var near_opp = makePaladinBot(2, 3514.0, -2934.0, 303.0);
    near_opp.state.guid = 0x200;
    setPolarityAura(&near_opp, pred.spell_polarity_negative);

    // Negative charge ~20 yd away → out of range.
    var far_opp = makePaladinBot(3, 3525.0, -2944.0, 303.0);
    far_opp.state.guid = 0x300;
    setPolarityAura(&far_opp, pred.spell_polarity_negative);

    // Same (positive) charge nearby → buffed, not hurt.
    var near_same = makePaladinBot(4, 3512.0, -2932.0, 303.0);
    near_same.state.guid = 0x400;
    setPolarityAura(&near_same, pred.spell_polarity_positive);

    // Opposite charge nearby but dead → no damage.
    var dead_opp = makePaladinBot(5, 3511.0, -2931.0, 303.0);
    dead_opp.state.guid = 0x500;
    dead_opp.state.hp = 0;
    setPolarityAura(&dead_opp, pred.spell_polarity_negative);

    try std.testing.expect(isChargeVictim(caster, near_opp, .positive));
    try std.testing.expect(!isChargeVictim(caster, far_opp, .positive));
    try std.testing.expect(!isChargeVictim(caster, near_same, .positive));
    try std.testing.expect(!isChargeVictim(caster, dead_opp, .positive));
    try std.testing.expect(!isChargeVictim(caster, caster, .positive));
}

test "proposeIntent: polarity stack returns null when already idle in position" {
    state.reset();
    const sp = @import("arena.zig").stack_melee_positive;
    var bot = makePaladinBot(1, sp.x, sp.y, sp.z);
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_positive,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    bot.state.ctm_action = @intFromEnum(proto.CtmAction.idle);
    const world = makeWorldWithTwins();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, false);
    const bs = state.findOrInsert(bot.bot_id, .left).?;

    const ai = trig.polarityStackIntent(&ctx, bs);
    try std.testing.expect(ai == null);
}

test "proposeIntent: polarity sets authoritative anchor at stack point" {
    state.reset();
    const sp = @import("arena.zig").stack_melee_positive;
    var bot = makePaladinBot(1, sp.x, sp.y, sp.z);
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_positive,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_opening_hold_done = true;

    const world = makeWorldWithThaddius();

    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    _ = proposeIntent(&ctx, &targets, &follow);

    const entry = follow.get(bot.bot_id).?;
    const pos = entry.position_override.?;
    try std.testing.expect(pos.authoritative);
    try std.testing.expectEqual(sp.x, pos.x);
    try std.testing.expectEqual(sp.y, pos.y);
}

test "proposeIntent: polarity anchor follows route waypoint before final stack" {
    state.reset();
    const from = arena.stack_melee_positive;
    var bot = makePaladinBot(1, from.x, from.y, from.z);
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_negative,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_opening_hold_done = true;
    bs.thaddius_tank_engage_done = true;
    bs.last_polarity = .positive;

    const world = makeWorldWithThaddius();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    const entry = follow.get(bot.bot_id).?;
    const pos = entry.position_override.?;
    try std.testing.expect(ai.intent == .stacking);
    try std.testing.expectEqual(arena.stack_melee_waypoints_positive_to_negative[0].x, ai.intent.stacking.x);
    try std.testing.expectEqual(arena.stack_melee_waypoints_positive_to_negative[0].y, ai.intent.stacking.y);
    try std.testing.expect(pos.authoritative);
    try std.testing.expectEqual(arena.stack_melee_waypoints_positive_to_negative[0].x, pos.x);
    try std.testing.expectEqual(arena.stack_melee_waypoints_positive_to_negative[0].y, pos.y);
}

test "proposeIntent: polarity anchor for melee_dps is authoritative" {
    state.reset();
    const sp = @import("arena.zig").stack_melee_positive;
    var bot = makePaladinBot(1, sp.x, sp.y, sp.z);
    bot.state.talent_points = .{ .tab1 = 0, .tab2 = 0, .tab3 = 51 }; // retribution → melee_dps
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_positive,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_opening_hold_done = true;

    const world = makeWorldWithThaddius();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    _ = proposeIntent(&ctx, &targets, &follow);

    const entry = follow.get(bot.bot_id).?;
    const pos = entry.position_override.?;
    try std.testing.expect(pos.authoritative);
    try std.testing.expectEqual(sp.x, pos.x);
    try std.testing.expectEqual(sp.y, pos.y);
}

test "proposeIntent: no polarity pins anchor at stack_melee_positive (initial hold)" {
    state.reset();
    const sp = @import("arena.zig").stack_melee_positive;
    var bot = makePaladinBot(1, sp.x, sp.y, sp.z);
    bot.state.player_aura_count = 0;
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_opening_hold_done = true;

    const world = makeWorldWithThaddius();

    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    _ = proposeIntent(&ctx, &targets, &follow);

    const entry = follow.get(bot.bot_id).?;
    const pos = entry.position_override.?;
    try std.testing.expect(pos.authoritative);
    try std.testing.expectEqual(sp.x, pos.x);
    try std.testing.expectEqual(sp.y, pos.y);
}

test "proposeIntent: no polarity after positive charge pins anchor at positive stack" {
    state.reset();
    const sp = arena.stack_melee_positive;
    var bot = makePaladinBot(1, sp.x, sp.y, sp.z);
    bot.state.player_aura_count = 0;
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_opening_hold_done = true;
    bs.last_polarity = .positive;

    const world = makeWorldWithThaddius();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    _ = proposeIntent(&ctx, &targets, &follow);

    const entry = follow.get(bot.bot_id).?;
    const pos = entry.position_override.?;
    try std.testing.expectEqual(sp.x, pos.x);
    try std.testing.expectEqual(sp.y, pos.y);
}

test "proposeIntent: no polarity after negative charge pins anchor at negative stack" {
    state.reset();
    const sn = arena.stack_melee_negative;
    var bot = makePaladinBot(1, sn.x, sn.y, sn.z);
    bot.state.player_aura_count = 0;
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_opening_hold_done = true;
    bs.last_polarity = .negative;

    const world = makeWorldWithThaddius();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    _ = proposeIntent(&ctx, &targets, &follow);

    const entry = follow.get(bot.bot_id).?;
    const pos = entry.position_override.?;
    try std.testing.expectEqual(sn.x, pos.x);
    try std.testing.expectEqual(sn.y, pos.y);
}

test "proposeIntent: ranged polarity uses melee stack point" {
    state.reset();
    var bot = makePaladinBot(1, 3490.0, -2920.0, 303.0);
    bot.state.class = @intFromEnum(@import("../../class_spec.zig").Class.mage);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_negative,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    const world = makeWorldWithThaddius();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const bs = state.findOrInsert(bot.bot_id, .left).?;

    const ai = trig.polarityStackIntent(&ctx, bs).?;
    const sp = @import("arena.zig").stack_melee_negative;
    try std.testing.expect(ai.intent == .stacking);
    try std.testing.expectEqual(sp.x, ai.intent.stacking.x);
    try std.testing.expectEqual(sp.y, ai.intent.stacking.y);
    try std.testing.expectEqual(sp.arrival_yards, ai.intent.stacking.tolerance);
}

test "proposeIntent: polarity route positive to negative uses first waypoint" {
    state.reset();
    const from = arena.stack_melee_positive;
    var bot = makePaladinBot(1, from.x, from.y, from.z);
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_negative,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    const world = makeWorldWithTwins();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, false);
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.last_polarity = .positive;

    const ai = trig.polarityStackIntent(&ctx, bs).?;
    try std.testing.expect(ai.intent == .stacking);
    try std.testing.expectEqual(arena.stack_melee_waypoints_positive_to_negative[0].x, ai.intent.stacking.x);
    try std.testing.expectEqual(arena.stack_melee_waypoints_positive_to_negative[0].y, ai.intent.stacking.y);
}

test "proposeIntent: polarity route negative to positive uses first waypoint" {
    state.reset();
    const from = arena.stack_melee_negative;
    var bot = makePaladinBot(1, from.x, from.y, from.z);
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_positive,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    const world = makeWorldWithTwins();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, false);
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.last_polarity = .negative;

    const ai = trig.polarityStackIntent(&ctx, bs).?;
    try std.testing.expect(ai.intent == .stacking);
    try std.testing.expectEqual(arena.stack_melee_waypoints_negative_to_positive[0].x, ai.intent.stacking.x);
    try std.testing.expectEqual(arena.stack_melee_waypoints_negative_to_positive[0].y, ai.intent.stacking.y);
}

test "proposeIntent: polarity route advances from waypoint[0] to waypoint[1]" {
    state.reset();
    const wp0 = arena.stack_melee_waypoints_negative_to_positive[0];
    var bot = makePaladinBot(1, wp0.x, wp0.y, wp0.z);
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_positive,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    const world = makeWorldWithTwins();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, false);
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.last_polarity = .negative;

    const ai = trig.polarityStackIntent(&ctx, bs).?;
    try std.testing.expect(ai.intent == .stacking);
    try std.testing.expect(bs.polarity_waypoint_step > 0);
    try std.testing.expectEqual(arena.stack_melee_waypoints_negative_to_positive[1].x, ai.intent.stacking.x);
    try std.testing.expectEqual(arena.stack_melee_waypoints_negative_to_positive[1].y, ai.intent.stacking.y);
}

test "proposeIntent: polarity route advances from waypoint[1] to final stack" {
    state.reset();
    const wp1 = arena.stack_melee_waypoints_negative_to_positive[1];
    var bot = makePaladinBot(1, wp1.x, wp1.y, wp1.z);
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_positive,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    const world = makeWorldWithTwins();
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.last_polarity = .positive;
    bs.polarity_waypoint_step = 1;

    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, false);
    const ai = trig.polarityStackIntent(&ctx, bs).?;
    try std.testing.expect(ai.intent == .stacking);
    try std.testing.expect(bs.polarity_waypoint_step >= arena.polarity_waypoint_count);
    try std.testing.expectEqual(arena.stack_melee_positive.x, ai.intent.stacking.x);
    try std.testing.expectEqual(arena.stack_melee_positive.y, ai.intent.stacking.y);
}

test "proposeIntent: polarity route does not return to consumed waypoint" {
    state.reset();
    const wp0 = arena.stack_melee_waypoints_negative_to_positive[0];
    var bot = makePaladinBot(1, wp0.x, wp0.y, wp0.z);
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_positive,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    const world = makeWorldWithTwins();
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.last_polarity = .negative;

    var ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, false);
    _ = trig.polarityStackIntent(&ctx, bs).?;
    try std.testing.expect(bs.polarity_waypoint_step > 0);

    // Move the bot between wp0 and wp1 — it should keep heading to wp1, not return to wp0.
    bot.state.x = (arena.stack_melee_waypoints_negative_to_positive[0].x + arena.stack_melee_waypoints_negative_to_positive[1].x) / 2.0;
    bot.state.y = (arena.stack_melee_waypoints_negative_to_positive[0].y + arena.stack_melee_waypoints_negative_to_positive[1].y) / 2.0;
    ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, false);
    const ai = trig.polarityStackIntent(&ctx, bs).?;

    try std.testing.expect(ai.intent == .stacking);
    try std.testing.expectEqual(arena.stack_melee_waypoints_negative_to_positive[1].x, ai.intent.stacking.x);
    try std.testing.expectEqual(arena.stack_melee_waypoints_negative_to_positive[1].y, ai.intent.stacking.y);
}

test "proposeIntent: writes twin guid to TargetStore when both tanks ready and route done" {
    state.reset();
    var bot = makePaladinBot(1, 3489.0, -3002.0, 312.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Sangboulon");

    var other_tank = makePaladinBot(2, 3433.0, -2948.0, 312.0);
    other_tank.state.guid = 0xBBBB;
    setName(&other_tank, "Lefttank");

    const world = makeWorldWithTwins();
    beginTick(&.{ bot, other_tank }, &world, &.{}, true, &(.{}));
    const ctx = CombatContext.build(bot, &.{ bot, other_tank }, &world, &.{}, true);

    const bs = state.findOrInsert(bot.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    state.setTankReady(bot.bot_id, .right);
    state.setTankReady(other_tank.bot_id, .left);

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow);
    try std.testing.expect(ai == null);
    try std.testing.expectEqual(@as(?u64, 0x2222), targets.get(bot.bot_id));
}

test "proposeIntent: twin tank waits at rally without platform anchor until both tanks ready" {
    state.reset();
    var bot = makePaladinBot(1, 3489.0, -3002.0, 312.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Sangboulon");

    var other_tank = makePaladinBot(2, 3433.0 + 25.0, -2948.0, 312.0);
    other_tank.state.guid = 0xBBBB;
    setName(&other_tank, "Lefttank");

    const world = makeWorldWithTwins();
    beginTick(&.{ bot, other_tank }, &world, &.{}, true, &(.{}));
    const ctx = CombatContext.build(bot, &.{ bot, other_tank }, &world, &.{}, true);

    const bs = state.findOrInsert(bot.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    state.setTankReady(bot.bot_id, .right);

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow);

    try std.testing.expect(ai == null);
    try std.testing.expectEqual(@as(?u64, null), targets.get(bot.bot_id));
    try std.testing.expect(follow.get(bot.bot_id) == null or follow.get(bot.bot_id).?.position_override == null);
}

test "proposeIntent: twin tank installs platform anchor while targeting twin" {
    state.reset();
    var bot = makePaladinBot(1, 3489.0, -3002.0, 312.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Sangboulon");

    var other_tank = makePaladinBot(2, 3433.0, -2948.0, 312.0);
    other_tank.state.guid = 0xBBBB;
    setName(&other_tank, "Lefttank");

    const world = makeWorldWithTwins();
    beginTick(&.{ bot, other_tank }, &world, &.{}, true, &(.{}));
    const ctx = CombatContext.build(bot, &.{ bot, other_tank }, &world, &.{}, true);

    const bs = state.findOrInsert(bot.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    state.setTankReady(bot.bot_id, .right);
    state.setTankReady(other_tank.bot_id, .left);

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow);
    const entry = follow.get(bot.bot_id).?;
    const pos = entry.position_override.?;
    const target = targets.getTarget(bot.bot_id).?;

    try std.testing.expect(ai == null);
    try std.testing.expectEqual(@as(?u64, 0x2222), targets.get(bot.bot_id));
    try std.testing.expectEqual(TargetStore.Mode.select_only, target.mode);
    try std.testing.expectApproxEqAbs(arena.right_platform.x, pos.x, 0.01);
    try std.testing.expectApproxEqAbs(arena.right_platform.y, pos.y, 0.01);
    try std.testing.expectApproxEqAbs(arena.right_platform.z, pos.z, 0.01);
    try std.testing.expectApproxEqAbs(twin_tank_anchor_arrival_yards, pos.arrival_yards, 0.01);
    try std.testing.expect(pos.authoritative);
}

test "proposeIntent: twin tank uses attack target mode after pull sequence" {
    state.reset();
    var bot = makePaladinBot(1, arena.right_platform.x, arena.right_platform.y, arena.right_platform.z);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Sangboulon");

    var other_tank = makePaladinBot(2, arena.left_platform.x, arena.left_platform.y, arena.left_platform.z);
    other_tank.state.guid = 0xBBBB;
    setName(&other_tank, "Lefttank");

    const world = makeWorldWithTwins();
    beginTick(&.{ bot, other_tank }, &world, &.{}, true, &(.{}));
    const ctx = CombatContext.build(bot, &.{ bot, other_tank }, &world, &.{}, true);

    const bs = state.findOrInsert(bot.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    bs.twin_pull_platform_queued = true;
    bs.twin_pull_platform_done = true;
    bs.twin_pull_facing_done = true;
    state.setTankReady(bot.bot_id, .right);
    state.setTankReady(other_tank.bot_id, .left);

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow);
    const target = targets.getTarget(bot.bot_id).?;

    try std.testing.expect(ai == null);
    try std.testing.expectEqual(@as(u64, 0x2222), target.guid);
    try std.testing.expectEqual(TargetStore.Mode.attack, target.mode);
}

test "proposeIntent: thaddius phase replaces twin tank anchor with polarity stack anchor" {
    state.reset();
    var bot = makePaladinBot(1, 3515.0, -2924.0, 303.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Sangboulon");

    const world = makeWorldWithThaddius();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const bs = state.findOrInsert(bot.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    follow.setPosition(bot.bot_id, .{
        .x = arena.right_platform.x,
        .y = arena.right_platform.y,
        .z = arena.right_platform.z,
        .arrival_yards = twin_tank_anchor_arrival_yards,
    });

    _ = proposeIntent(&ctx, &targets, &follow);
    const entry = follow.get(bot.bot_id).?;
    const pos = entry.position_override.?;
    // Anchor must have moved off the twin platform.
    try std.testing.expect(pos.x != arena.right_platform.x or pos.y != arena.right_platform.y);
    // Without an active polarity charge, the new anchor is the side-appropriate
    // polarity stack (Fix B: hold bots in formation before the first Shift).
    // This bot is .right → negative stack.
    try std.testing.expectEqual(arena.stack_melee_negative.x, pos.x);
    try std.testing.expectEqual(arena.stack_melee_negative.y, pos.y);
}

test "proposeIntent: thaddius pre-polarity target allows attack mode" {
    state.reset();
    var bot = makePaladinBot(3, arena.stack_melee_negative.x, arena.stack_melee_negative.y, arena.stack_melee_negative.z);
    bot.state.class = @intFromEnum(@import("../../class_spec.zig").Class.rogue);
    bot.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    bot.state.game_time_ms = 8000;
    setName(&bot, "Meleedps");

    const world = makeWorldWithThaddius();
    const bs = state.findOrInsert(bot.bot_id, .right).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;
    bs.thaddius_opening_hold_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const ai = proposeIntent(&ctx, &targets, &follow);
    const target = targets.getTarget(bot.bot_id).?;

    try std.testing.expect(ai == null);
    try std.testing.expectEqual(TargetStore.Mode.attack, target.mode);
}

test "proposeIntent: operator stopped does not target thaddius phase" {
    state.reset();
    var bot = makePaladinBot(1, 3515.0, -2924.0, 303.0);
    bot.state.guid = 0xAAAA;
    setName(&bot, "Sangboulon");

    const world = makeWorldWithThaddius();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, false);

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow);

    try std.testing.expect(ai == null);
    try std.testing.expectEqual(@as(?u64, null), targets.get(bot.bot_id));
    try std.testing.expect(follow.get(bot.bot_id) == null or follow.get(bot.bot_id).?.position_override == null);
}

test "proposeIntent: holds DPS after route until both tanks are ready" {
    state.reset();
    var dps = makePaladinBot(3, 3489.0, -3002.0, 312.0);
    dps.state.class = @intFromEnum(@import("../../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.game_time_ms = 1000;
    dps.state.target_guid = 0x2222;
    dps.state.target_unit_reaction = 2;
    setName(&dps, "Meleedps");

    var tank_a = makePaladinBot(1, 3489.0, -3002.0, 312.0);
    tank_a.state.guid = 0xAAAA;
    setName(&tank_a, "Sangboulon");
    var tank_b = makePaladinBot(2, 3433.0 + 25.0, -2948.0, 312.0);
    tank_b.state.guid = 0xBBBB;
    setName(&tank_b, "Lefttank");

    const world = makeWorldWithTwins();
    beginTick(&.{ dps, tank_a, tank_b }, &world, &.{}, true, &(.{}));
    state.setTankReady(tank_a.bot_id, .right);
    const bs = state.findOrInsert(dps.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ctx = CombatContext.build(dps, &.{ dps, tank_a, tank_b }, &world, &.{}, true);
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expectEqual(intent.Priority.encounter, ai.priority);
    try std.testing.expectEqual(intent.Reason.encounter_pull, ai.source);
    try std.testing.expectEqual(@as(u8, 2), ai.intent.sequenced.len);
    try std.testing.expect(ai.intent.sequenced.steps[0].intent == .stop_attack);
    try std.testing.expect(ai.intent.sequenced.steps[1].intent == .waiting_for);
    try std.testing.expectEqual(@as(u32, 1000 + proto.brain_tick_ms), ai.intent.sequenced.steps[1].intent.waiting_for.until.game_time_at_least_ms);
    try std.testing.expectEqual(@as(?u64, null), targets.get(dps.bot_id));
}

test "proposeIntent: twins hold DPS until tank pull sequence is done" {
    state.reset();
    var dps = makePaladinBot(3, 3489.0, -3002.0, 312.0);
    dps.state.class = @intFromEnum(@import("../../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.game_time_ms = 1000;
    setName(&dps, "Meleedps");

    var tank_a = makePaladinBot(1, 3489.0, -3002.0, 312.0);
    tank_a.state.guid = 0xAAAA;
    setName(&tank_a, "Sangboulon");
    var tank_b = makePaladinBot(2, 3433.0, -2948.0, 312.0);
    tank_b.state.guid = 0xBBBB;
    setName(&tank_b, "Lefttank");

    const world = makeWorldWithTwins();
    beginTick(&.{ dps, tank_a, tank_b }, &world, &.{}, true, &(.{}));
    state.setTankReady(tank_a.bot_id, .right);
    state.setTankReady(tank_b.bot_id, .left);
    const bs = state.findOrInsert(dps.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    var ctx = CombatContext.build(dps, &.{ dps, tank_a, tank_b }, &world, &.{}, true);
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expectEqual(intent.Reason.encounter_pull, ai.source);
    try std.testing.expectEqual(@as(u8, 2), ai.intent.sequenced.len);
    try std.testing.expect(ai.intent.sequenced.steps[0].intent == .stop_attack);
    try std.testing.expect(ai.intent.sequenced.steps[1].intent == .waiting_for);
    try std.testing.expectEqual(@as(?u64, null), targets.get(dps.bot_id));

    const tank_a_bs = state.findOrInsert(tank_a.bot_id, .right).?;
    tank_a_bs.twin_pull_platform_queued = true;
    tank_a_bs.twin_pull_platform_done = true;
    tank_a_bs.twin_pull_facing_done = true;
    const tank_b_bs = state.findOrInsert(tank_b.bot_id, .left).?;
    tank_b_bs.twin_pull_platform_queued = true;
    tank_b_bs.twin_pull_platform_done = true;
    tank_b_bs.twin_pull_facing_done = true;

    dps.state.game_time_ms = 6000;
    ctx = CombatContext.build(dps, &.{ dps, tank_a, tank_b }, &world, &.{}, true);
    const opening_hold = proposeIntent(&ctx, &targets, &follow).?;
    try std.testing.expect(opening_hold.intent == .sequenced);
    try std.testing.expectEqual(intent.Reason.encounter_pull, opening_hold.source);
    try std.testing.expectEqual(@as(?u64, null), targets.get(dps.bot_id));

    dps.state.game_time_ms = 6000 + trig.dps_opening_hold_ms + proto.brain_tick_ms;
    ctx = CombatContext.build(dps, &.{ dps, tank_a, tank_b }, &world, &.{}, true);
    try std.testing.expect(proposeIntent(&ctx, &targets, &follow) == null);
    try std.testing.expectEqual(@as(?u64, 0x2222), targets.get(dps.bot_id));
}

test "proposeIntent: holds DPS during tank swap generation" {
    state.reset();
    var dps = makePaladinBot(3, 3489.0, -3002.0, 312.0);
    dps.state.class = @intFromEnum(@import("../../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.game_time_ms = 2000;
    dps.state.target_guid = 0x2222;
    dps.state.target_unit_reaction = 2;
    setName(&dps, "Meleedps");

    var tank_a = makePaladinBot(1, 3489.0, -3002.0, 312.0);
    tank_a.state.guid = 0xAAAA;
    setName(&tank_a, "Sangboulon");
    var tank_b = makePaladinBot(2, 3433.0, -2948.0, 312.0);
    tank_b.state.guid = 0xBBBB;
    setName(&tank_b, "Lefttank");

    const world = makeWorldWithTwins();
    beginTick(&.{ dps, tank_a, tank_b }, &world, &.{}, true, &(.{}));
    state.setTankReady(tank_a.bot_id, .right);
    state.setTankReady(tank_b.bot_id, .left);
    _ = state.applySwap(pred.spell_magnetic_pull_trigger, 0x2222, tank_a.state.guid, 1500);

    const bs = state.findOrInsert(dps.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ctx = CombatContext.build(dps, &.{ dps, tank_a, tank_b }, &world, &.{}, true);
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expectEqual(@as(u8, 2), ai.intent.sequenced.len);
    try std.testing.expect(ai.intent.sequenced.steps[0].intent == .stop_attack);
    try std.testing.expect(ai.intent.sequenced.steps[1].intent == .waiting_for);
    try std.testing.expectEqual(@as(u32, 1500 + trig.dps_swap_hold_ms), ai.intent.sequenced.steps[1].intent.waiting_for.until.game_time_at_least_ms);
    try std.testing.expectEqual(@as(?u64, null), targets.get(dps.bot_id));
}

test "proposeIntent: thaddius transition includes DPS opening hold" {
    state.reset();
    var dps = makePaladinBot(3, 3515.0, -2924.0, 303.0);
    dps.state.class = @intFromEnum(@import("../../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.game_time_ms = 2000;

    const world = makeWorldWithThaddius();
    state.noteThaddiusAttackable(2000);
    const ctx = CombatContext.build(dps, &.{dps}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expectEqual(@as(u8, 6), ai.intent.sequenced.len);
    try std.testing.expect(ai.intent.sequenced.steps[3].intent == .moving_to);
    try std.testing.expect(ai.intent.sequenced.steps[3].intent.moving_to.non_blocking);
    try std.testing.expect(ai.intent.sequenced.steps[3].done_when.? == .arrived_at);
    try std.testing.expect(ai.intent.sequenced.steps[3].trigger_once.?.action == .jump);
    try std.testing.expect(ai.intent.sequenced.steps[3].trigger_once.?.when == .z_above);
    try std.testing.expect(ai.intent.sequenced.steps[4].intent == .moving_to);
    try std.testing.expect(ai.intent.sequenced.steps[4].done_when.? == .arrived_at);
    try std.testing.expect(ai.intent.sequenced.steps[5].intent == .waiting_for);
}

test "proposeIntent: thaddius opening hold is separate from swap hold" {
    state.reset();
    var dps = makePaladinBot(3, 3515.0, -2924.0, 303.0);
    dps.state.class = @intFromEnum(@import("../../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.game_time_ms = 2000;

    const world = makeWorldWithThaddius();
    state.noteThaddiusAttackable(2000);
    const bs = state.findOrInsert(dps.bot_id, .right).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;

    const ctx = CombatContext.build(dps, &.{dps}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expectEqual(@as(u8, 2), ai.intent.sequenced.len);
    try std.testing.expect(ai.intent.sequenced.steps[0].intent == .stop_attack);
    try std.testing.expect(ai.intent.sequenced.steps[1].intent == .waiting_for);
    try std.testing.expectEqual(@as(u32, 7000), ai.intent.sequenced.steps[1].intent.waiting_for.until.game_time_at_least_ms);
    try std.testing.expectEqual(intent.Reason.encounter_pull, ai.source);
}

test "proposeIntent: healer skips thaddius opening hold" {
    state.reset();
    var healer = makePaladinBot(3, 3515.0, -2924.0, 303.0);
    healer.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    healer.state.game_time_ms = 2000;

    const world = makeWorldWithThaddius();
    state.noteThaddiusAttackable(2000);
    const bs = state.findOrInsert(healer.bot_id, .right).?;
    bs.post_twin_queued = true;
    bs.post_twin_arrived = true;

    const ctx = CombatContext.build(healer, &.{healer}, &world, &.{}, true);
    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    try std.testing.expect(proposeIntent(&ctx, &targets, &follow) == null);
}

test "onStartFight: installs sequenced twin route intent" {
    state.reset();
    var dispatch_store: DispatchStore = .{};
    var intent_store: IntentStore = .{};
    var follow_store: FollowStore = .{};

    var bot = makePaladinBot(1, 3426.0, -3003.0, 295.6);
    @memcpy(bot.state.player_name[0.."TestBot".len], "TestBot");

    var registry: registry_mod.Registry = .{};

    onStartFight(std.testing.io, &registry, &.{bot}, &intent_store, &dispatch_store, &follow_store);

    const ai = intent_store.current(bot.bot_id) orelse return error.TestExpectedUnexpectedResult;
    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expectEqual(intent.Priority.encounter, ai.priority);
}

test "proposeIntent: caster ranged dps uses select-only target on twin (no CTM chase)" {
    state.reset();
    var dps = makePaladinBot(3, 3489.0, -3002.0, 312.0);
    dps.state.class = @intFromEnum(@import("../../class_spec.zig").Class.mage);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.game_time_ms = 6000 + trig.dps_opening_hold_ms + proto.brain_tick_ms;
    setName(&dps, "Meleedps");

    var tank_a = makePaladinBot(1, 3489.0, -3002.0, 312.0);
    tank_a.state.guid = 0xAAAA;
    setName(&tank_a, "Sangboulon");
    var tank_b = makePaladinBot(2, 3433.0, -2948.0, 312.0);
    tank_b.state.guid = 0xBBBB;
    setName(&tank_b, "Lefttank");

    const world = makeWorldWithTwins();
    beginTick(&.{ dps, tank_a, tank_b }, &world, &.{}, true, &(.{}));
    state.setTankReady(tank_a.bot_id, .right);
    state.setTankReady(tank_b.bot_id, .left);

    const bs = state.findOrInsert(dps.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    bs.twin_opening_hold_done = true;

    const tank_a_bs = state.findOrInsert(tank_a.bot_id, .right).?;
    tank_a_bs.twin_pull_platform_queued = true;
    tank_a_bs.twin_pull_platform_done = true;
    tank_a_bs.twin_pull_facing_done = true;
    const tank_b_bs = state.findOrInsert(tank_b.bot_id, .left).?;
    tank_b_bs.twin_pull_platform_queued = true;
    tank_b_bs.twin_pull_platform_done = true;
    tank_b_bs.twin_pull_facing_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ctx = CombatContext.build(dps, &.{ dps, tank_a, tank_b }, &world, &.{}, true);
    _ = proposeIntent(&ctx, &targets, &follow);

    const target = targets.getTarget(dps.bot_id).?;
    try std.testing.expectEqual(@as(u64, 0x2222), target.guid);
    try std.testing.expectEqual(TargetStore.Mode.select_only, target.mode);
}

test "proposeIntent: healer does not set target on twin (no CTM chase)" {
    state.reset();
    var healer = makePaladinBot(3, 3489.0, -3002.0, 312.0);
    healer.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    healer.state.game_time_ms = 6000 + trig.dps_opening_hold_ms + proto.brain_tick_ms;
    setName(&healer, "Meleedps");

    var tank_a = makePaladinBot(1, 3489.0, -3002.0, 312.0);
    tank_a.state.guid = 0xAAAA;
    setName(&tank_a, "Sangboulon");
    var tank_b = makePaladinBot(2, 3433.0, -2948.0, 312.0);
    tank_b.state.guid = 0xBBBB;
    setName(&tank_b, "Lefttank");

    const world = makeWorldWithTwins();
    beginTick(&.{ healer, tank_a, tank_b }, &world, &.{}, true, &(.{}));
    state.setTankReady(tank_a.bot_id, .right);
    state.setTankReady(tank_b.bot_id, .left);

    const bs = state.findOrInsert(healer.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    bs.twin_opening_hold_done = true;

    const tank_a_bs = state.findOrInsert(tank_a.bot_id, .right).?;
    tank_a_bs.twin_pull_platform_queued = true;
    tank_a_bs.twin_pull_platform_done = true;
    tank_a_bs.twin_pull_facing_done = true;
    const tank_b_bs = state.findOrInsert(tank_b.bot_id, .left).?;
    tank_b_bs.twin_pull_platform_queued = true;
    tank_b_bs.twin_pull_platform_done = true;
    tank_b_bs.twin_pull_facing_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ctx = CombatContext.build(healer, &.{ healer, tank_a, tank_b }, &world, &.{}, true);
    try std.testing.expect(proposeIntent(&ctx, &targets, &follow) == null);

    try std.testing.expectEqual(@as(?u64, null), targets.get(healer.bot_id));
}

test "proposeIntent: healer skips twin opening hold" {
    state.reset();
    var healer = makePaladinBot(3, 3489.0, -3002.0, 312.0);
    healer.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    healer.state.game_time_ms = 6000;
    setName(&healer, "Meleedps");

    var tank_a = makePaladinBot(1, 3489.0, -3002.0, 312.0);
    tank_a.state.guid = 0xAAAA;
    setName(&tank_a, "Sangboulon");
    var tank_b = makePaladinBot(2, 3433.0, -2948.0, 312.0);
    tank_b.state.guid = 0xBBBB;
    setName(&tank_b, "Lefttank");

    const world = makeWorldWithTwins();
    beginTick(&.{ healer, tank_a, tank_b }, &world, &.{}, true, &(.{}));
    state.setTankReady(tank_a.bot_id, .right);
    state.setTankReady(tank_b.bot_id, .left);

    const bs = state.findOrInsert(healer.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    bs.twin_opening_hold_done = true;

    const tank_a_bs = state.findOrInsert(tank_a.bot_id, .right).?;
    tank_a_bs.twin_pull_platform_queued = true;
    tank_a_bs.twin_pull_platform_done = true;
    tank_a_bs.twin_pull_facing_done = true;
    const tank_b_bs = state.findOrInsert(tank_b.bot_id, .left).?;
    tank_b_bs.twin_pull_platform_queued = true;
    tank_b_bs.twin_pull_platform_done = true;
    tank_b_bs.twin_pull_facing_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ctx = CombatContext.build(healer, &.{ healer, tank_a, tank_b }, &world, &.{}, true);
    try std.testing.expect(proposeIntent(&ctx, &targets, &follow) == null);
    try std.testing.expectEqual(@as(?u64, null), targets.get(healer.bot_id));
}

test "proposeIntent: holds left DPS when Stalagg below 30% and Feugen above 30%" {
    state.reset();
    var dps = makePaladinBot(3, 3433.0, -2948.0, 312.0);
    dps.state.class = @intFromEnum(@import("../../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.game_time_ms = 1000;
    setName(&dps, "Meleedps");

    var tank_a = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    tank_a.state.guid = 0xAAAA;
    setName(&tank_a, "Lefttank");
    var tank_b = makePaladinBot(2, 3489.0, -3002.0, 312.0);
    tank_b.state.guid = 0xBBBB;
    setName(&tank_b, "Sangboulon");

    // Stalagg at 29%, Feugen at 35% — left DPS must hold.
    const world = makeWorldWithTwinsAtHp(290, 350);
    beginTick(&.{ dps, tank_a, tank_b }, &world, &.{}, true, &(.{}));
    state.setTankReady(tank_a.bot_id, .left);
    state.setTankReady(tank_b.bot_id, .right);

    const bs = state.findOrInsert(dps.bot_id, .left).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    bs.twin_opening_hold_done = true;

    const tank_a_bs = state.findOrInsert(tank_a.bot_id, .left).?;
    tank_a_bs.twin_pull_platform_queued = true;
    tank_a_bs.twin_pull_platform_done = true;
    tank_a_bs.twin_pull_facing_done = true;
    const tank_b_bs = state.findOrInsert(tank_b.bot_id, .right).?;
    tank_b_bs.twin_pull_platform_queued = true;
    tank_b_bs.twin_pull_platform_done = true;
    tank_b_bs.twin_pull_facing_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ctx = CombatContext.build(dps, &.{ dps, tank_a, tank_b }, &world, &.{}, true);
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expectEqual(intent.Priority.encounter, ai.priority);
    try std.testing.expectEqual(intent.Reason.encounter_pull, ai.source);
    try std.testing.expect(ai.intent.sequenced.steps[0].intent == .stop_attack);
    try std.testing.expectEqual(@as(?u64, null), targets.get(dps.bot_id));
}

test "proposeIntent: does not hold left DPS when both twins at 29%" {
    state.reset();
    var dps = makePaladinBot(3, 3433.0, -2948.0, 312.0);
    dps.state.class = @intFromEnum(@import("../../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.game_time_ms = 1000;
    setName(&dps, "Meleedps");

    var tank_a = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    tank_a.state.guid = 0xAAAA;
    setName(&tank_a, "Lefttank");
    var tank_b = makePaladinBot(2, 3489.0, -3002.0, 312.0);
    tank_b.state.guid = 0xBBBB;
    setName(&tank_b, "Sangboulon");

    // Both at 29% — in sync, no hold.
    const world = makeWorldWithTwinsAtHp(290, 290);
    beginTick(&.{ dps, tank_a, tank_b }, &world, &.{}, true, &(.{}));
    state.setTankReady(tank_a.bot_id, .left);
    state.setTankReady(tank_b.bot_id, .right);

    const bs = state.findOrInsert(dps.bot_id, .left).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    bs.twin_opening_hold_done = true;

    const tank_a_bs = state.findOrInsert(tank_a.bot_id, .left).?;
    tank_a_bs.twin_pull_platform_queued = true;
    tank_a_bs.twin_pull_platform_done = true;
    tank_a_bs.twin_pull_facing_done = true;
    const tank_b_bs = state.findOrInsert(tank_b.bot_id, .right).?;
    tank_b_bs.twin_pull_platform_queued = true;
    tank_b_bs.twin_pull_platform_done = true;
    tank_b_bs.twin_pull_facing_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ctx = CombatContext.build(dps, &.{ dps, tank_a, tank_b }, &world, &.{}, true);
    const ai = proposeIntent(&ctx, &targets, &follow);

    try std.testing.expect(ai == null);
    try std.testing.expectEqual(@as(?u64, 0x1111), targets.get(dps.bot_id));
}

test "proposeIntent: holds right DPS when Feugen below 15% and Stalagg above 15%" {
    state.reset();
    var dps = makePaladinBot(3, 3489.0, -3002.0, 312.0);
    dps.state.class = @intFromEnum(@import("../../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.game_time_ms = 1000;
    setName(&dps, "Sangboulon");

    var tank_a = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    tank_a.state.guid = 0xAAAA;
    setName(&tank_a, "Lefttank");
    var tank_b = makePaladinBot(2, 3489.0, -3002.0, 312.0);
    tank_b.state.guid = 0xBBBB;
    setName(&tank_b, "Righttank");

    // Feugen at 10%, Stalagg at 20% — right DPS must hold at 15% threshold.
    const world = makeWorldWithTwinsAtHp(200, 100);
    beginTick(&.{ dps, tank_a, tank_b }, &world, &.{}, true, &(.{}));
    state.setTankReady(tank_a.bot_id, .left);
    state.setTankReady(tank_b.bot_id, .right);

    const bs = state.findOrInsert(dps.bot_id, .right).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    bs.twin_opening_hold_done = true;

    const tank_a_bs = state.findOrInsert(tank_a.bot_id, .left).?;
    tank_a_bs.twin_pull_platform_queued = true;
    tank_a_bs.twin_pull_platform_done = true;
    tank_a_bs.twin_pull_facing_done = true;
    const tank_b_bs = state.findOrInsert(tank_b.bot_id, .right).?;
    tank_b_bs.twin_pull_platform_queued = true;
    tank_b_bs.twin_pull_platform_done = true;
    tank_b_bs.twin_pull_facing_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ctx = CombatContext.build(dps, &.{ dps, tank_a, tank_b }, &world, &.{}, true);
    const ai = proposeIntent(&ctx, &targets, &follow).?;

    try std.testing.expect(ai.intent == .sequenced);
    try std.testing.expectEqual(intent.Priority.encounter, ai.priority);
    try std.testing.expectEqual(intent.Reason.encounter_pull, ai.source);
    try std.testing.expect(ai.intent.sequenced.steps[0].intent == .stop_attack);
    try std.testing.expectEqual(@as(?u64, null), targets.get(dps.bot_id));
}

test "proposeIntent: releases DPS sync when both twins below 5%" {
    state.reset();
    var dps = makePaladinBot(3, 3433.0, -2948.0, 312.0);
    dps.state.class = @intFromEnum(@import("../../class_spec.zig").Class.rogue);
    dps.state.talent_points = .{ .tab1 = 51, .tab2 = 0, .tab3 = 0 };
    dps.state.game_time_ms = 1000;
    setName(&dps, "Meleedps");

    var tank_a = makePaladinBot(1, 3433.0, -2948.0, 312.0);
    tank_a.state.guid = 0xAAAA;
    setName(&tank_a, "Lefttank");
    var tank_b = makePaladinBot(2, 3489.0, -3002.0, 312.0);
    tank_b.state.guid = 0xBBBB;
    setName(&tank_b, "Sangboulon");

    // Both at 3% — sync released, DPS attacks freely.
    const world = makeWorldWithTwinsAtHp(30, 30);
    beginTick(&.{ dps, tank_a, tank_b }, &world, &.{}, true, &(.{}));
    state.setTankReady(tank_a.bot_id, .left);
    state.setTankReady(tank_b.bot_id, .right);

    const bs = state.findOrInsert(dps.bot_id, .left).?;
    bs.twin_route_seeded = true;
    bs.twin_route_done = true;
    bs.twin_opening_hold_done = true;

    const tank_a_bs = state.findOrInsert(tank_a.bot_id, .left).?;
    tank_a_bs.twin_pull_platform_queued = true;
    tank_a_bs.twin_pull_platform_done = true;
    tank_a_bs.twin_pull_facing_done = true;
    const tank_b_bs = state.findOrInsert(tank_b.bot_id, .right).?;
    tank_b_bs.twin_pull_platform_queued = true;
    tank_b_bs.twin_pull_platform_done = true;
    tank_b_bs.twin_pull_facing_done = true;

    var targets: TargetStore = .{};
    var follow: FollowStore = .{};
    const ctx = CombatContext.build(dps, &.{ dps, tank_a, tank_b }, &world, &.{}, true);
    const ai = proposeIntent(&ctx, &targets, &follow);

    try std.testing.expect(ai == null);
    try std.testing.expectEqual(@as(?u64, 0x1111), targets.get(dps.bot_id));
}

// ─── Polarity route — positional model tests ─────────────────────────────────

test "routeForPolarity: positive polarity at positive stack → direct" {
    const sp = arena.stack_melee_positive;
    try std.testing.expectEqual(state.PolarityRoute.none, trig.routeForPolarity(.positive, sp.x, sp.y));
}

test "routeForPolarity: positive polarity at negative stack → via beta" {
    const sn = arena.stack_melee_negative;
    try std.testing.expectEqual(
        state.PolarityRoute.negative_to_positive,
        trig.routeForPolarity(.positive, sn.x, sn.y),
    );
}

test "routeForPolarity: negative polarity at positive stack → via alpha" {
    const sp = arena.stack_melee_positive;
    try std.testing.expectEqual(
        state.PolarityRoute.positive_to_negative,
        trig.routeForPolarity(.negative, sp.x, sp.y),
    );
}

test "routeForPolarity: negative polarity at negative stack → direct" {
    const sn = arena.stack_melee_negative;
    try std.testing.expectEqual(state.PolarityRoute.none, trig.routeForPolarity(.negative, sn.x, sn.y));
}

test "routeForPolarity: crossing-line waypoint p_to_n[0] is direct for either polarity" {
    const a = arena.stack_melee_waypoints_positive_to_negative[0];
    // Standing exactly on the diagonal — must not be rerouted across the centre.
    try std.testing.expectEqual(state.PolarityRoute.none, trig.routeForPolarity(.positive, a.x, a.y));
    try std.testing.expectEqual(state.PolarityRoute.none, trig.routeForPolarity(.negative, a.x, a.y));
}

test "routeForPolarity: crossing-line waypoint n_to_p[1] is direct for either polarity" {
    const b = arena.stack_melee_waypoints_negative_to_positive[1];
    try std.testing.expectEqual(state.PolarityRoute.none, trig.routeForPolarity(.positive, b.x, b.y));
    try std.testing.expectEqual(state.PolarityRoute.none, trig.routeForPolarity(.negative, b.x, b.y));
}

test "routeForPolarity: bot drifted in front of Thaddius (positive half) needs detour for negative" {
    // ~(3520, -2935) sits SE of centre, scalar > 0 → positive half.
    try std.testing.expectEqual(
        state.PolarityRoute.positive_to_negative,
        trig.routeForPolarity(.negative, 3520.0, -2935.0),
    );
    try std.testing.expectEqual(state.PolarityRoute.none, trig.routeForPolarity(.positive, 3520.0, -2935.0));
}

test "polarityStackIntent: bot drifted near boss with new negative polarity routes via first waypoint" {
    state.reset();
    // Bot in positive half (SE of centre), got the negative charge:
    // must NOT take the direct line across the centre.
    var bot = makePaladinBot(1, 3520.0, -2935.0, 303.06);
    bot.state.player_auras[0] = .{
        .spell_id = pred.spell_polarity_negative,
        .remaining_ms = 8000,
        .caster_guid = 0,
    };
    bot.state.player_aura_count = 1;
    const world = makeWorldWithThaddius();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.last_polarity = .positive;

    const ai = trig.polarityStackIntent(&ctx, bs).?;

    try std.testing.expect(ai.intent == .stacking);
    try std.testing.expectEqual(arena.stack_melee_waypoints_positive_to_negative[0].x, ai.intent.stacking.x);
    try std.testing.expectEqual(arena.stack_melee_waypoints_positive_to_negative[0].y, ai.intent.stacking.y);
}

test "polarityStackIntent: aura blink between Polarity Shifts does not corrupt the route" {
    state.reset();
    // Tick 1: bot at positive stack with positive polarity → no route needed.
    var bot = makePaladinBot(1, arena.stack_melee_positive.x, arena.stack_melee_positive.y, arena.stack_melee_positive.z);
    bot.state.player_auras[0] = .{ .spell_id = pred.spell_polarity_positive, .remaining_ms = 8000, .caster_guid = 0 };
    bot.state.player_aura_count = 1;
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    const world = makeWorldWithThaddius();
    var ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    _ = trig.polarityStackIntent(&ctx, bs);
    try std.testing.expectEqual(state.Polarity.positive, bs.last_polarity);

    // Tick 2: aura briefly drops during Polarity Shift recast.
    bot.state.player_aura_count = 0;
    ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const ai_blink = trig.polarityStackIntent(&ctx, bs);
    try std.testing.expect(ai_blink == null);
    // Sticky: previous polarity is remembered so the anchor doesn't drift.
    try std.testing.expectEqual(state.Polarity.positive, bs.last_polarity);

    // Tick 3: new (negative) polarity lands. Route is computed from the bot's
    // current position (still at positive stack) — must use the staged detour.
    bot.state.player_auras[0] = .{ .spell_id = pred.spell_polarity_negative, .remaining_ms = 8000, .caster_guid = 0 };
    bot.state.player_aura_count = 1;
    ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const ai = trig.polarityStackIntent(&ctx, bs).?;
    try std.testing.expect(ai.intent == .stacking);
    try std.testing.expectEqual(arena.stack_melee_waypoints_positive_to_negative[0].x, ai.intent.stacking.x);
    try std.testing.expectEqual(arena.stack_melee_waypoints_positive_to_negative[0].y, ai.intent.stacking.y);
}

test "polarityAnchorPosition: no polarity, no history, left side → anchored at positive stack (initial hold)" {
    state.reset();
    var bot = makePaladinBot(1, arena.stack_melee_positive.x, arena.stack_melee_positive.y, arena.stack_melee_positive.z);
    bot.state.player_aura_count = 0;
    const bs = state.findOrInsert(bot.bot_id, .left).?;

    const world = makeWorldWithThaddius();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const anchor = trig.polarityAnchorPosition(&ctx, bs).?;

    try std.testing.expectEqual(arena.stack_melee_positive.x, anchor.x);
    try std.testing.expectEqual(arena.stack_melee_positive.y, anchor.y);
}

test "polarityAnchorPosition: no polarity, no history, right side → anchored at negative stack (initial hold)" {
    state.reset();
    var bot = makePaladinBot(1, arena.stack_melee_negative.x, arena.stack_melee_negative.y, arena.stack_melee_negative.z);
    bot.state.player_aura_count = 0;
    const bs = state.findOrInsert(bot.bot_id, .right).?;

    const world = makeWorldWithThaddius();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const anchor = trig.polarityAnchorPosition(&ctx, bs).?;

    try std.testing.expectEqual(arena.stack_melee_negative.x, anchor.x);
    try std.testing.expectEqual(arena.stack_melee_negative.y, anchor.y);
}

test "polarityAnchorPosition: no polarity but bot last had negative → anchored at negative stack" {
    state.reset();
    var bot = makePaladinBot(1, arena.stack_melee_negative.x, arena.stack_melee_negative.y, arena.stack_melee_negative.z);
    bot.state.player_aura_count = 0;
    const bs = state.findOrInsert(bot.bot_id, .left).?;
    bs.last_polarity = .negative;

    const world = makeWorldWithThaddius();
    const ctx = CombatContext.build(bot, &.{bot}, &world, &.{}, true);
    const anchor = trig.polarityAnchorPosition(&ctx, bs).?;

    try std.testing.expectEqual(arena.stack_melee_negative.x, anchor.x);
    try std.testing.expectEqual(arena.stack_melee_negative.y, anchor.y);
}
