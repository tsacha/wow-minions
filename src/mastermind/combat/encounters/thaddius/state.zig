// Per-bot and global mutable state for the Thaddius encounter.

const std = @import("std");
const types = @import("types");
const assignments = @import("../../assignments.zig");

pub const BotId = types.BotId;
pub const max_bots = types.max_bots;
pub const twin_defeated_hp_threshold: u32 = 1;

pub const Side = enum { left, right };

pub const Polarity = enum { none, positive, negative };
pub const PolarityRoute = enum { none, positive_to_negative, negative_to_positive };

pub fn opposite(side: Side) Side {
    return switch (side) {
        .left => .right,
        .right => .left,
    };
}

pub const BotState = struct {
    bot_id: BotId,
    initial_side: Side,
    side: Side,
    twin_route_seeded: bool = false,
    twin_route_done: bool = false,
    twin_opening_hold_done: bool = false,
    swap_in_progress: bool = false,
    last_swap_generation_queued: u32 = 0,
    post_twin_queued: bool = false,
    post_twin_arrived: bool = false,
    thaddius_opening_hold_done: bool = false,
    thaddius_tank_engage_sent: bool = false,
    thaddius_tank_engage_done: bool = false,
    twin_pull_platform_queued: bool = false,
    twin_pull_platform_done: bool = false,
    twin_pull_facing_done: bool = false,
    last_polarity: Polarity = .none,
    polarity_waypoint_step: u8 = 0,
    last_polarity_warn_ms: u32 = 0,
};

pub const TankState = struct {
    active: bool = false,
    bot_id: BotId = std.mem.zeroes(BotId),
    guid: u64 = 0,
    name: [32]u8 = std.mem.zeroes([32]u8),
    initial_side: Side = .left,
    side: Side = .left,
    ready: bool = false,
};

pub const FightState = struct {
    tanks: [2]TankState = .{ .{}, .{} },
    tank_count: u8 = 0,
    extra_tank_count: u8 = 0,
    swap_generation: u32 = 0,
    last_magnetic_pull_game_time_ms: u32 = 0,
    thaddius_attackable_game_time_ms: u32 = 0,
    stalagg_seen_alive: bool = false,
    feugen_seen_alive: bool = false,
    stalagg_seen_dead: bool = false,
    feugen_seen_dead: bool = false,
};

var entries: [max_bots]?BotState = .{null} ** max_bots;
var fight: FightState = .{};

pub fn fightState() *FightState {
    return &fight;
}

pub fn noteTwinSeen(side: Side, hp: u32) void {
    switch (side) {
        .left => {
            if (!twinDefeatedHp(hp)) {
                if (!fight.stalagg_seen_alive) std.log.info("thaddius: Stalagg seen alive hp={}", .{hp});
                fight.stalagg_seen_alive = true;
            } else {
                if (!fight.stalagg_seen_dead) std.log.info("thaddius: Stalagg seen dead", .{});
                fight.stalagg_seen_dead = true;
            }
        },
        .right => {
            if (!twinDefeatedHp(hp)) {
                if (!fight.feugen_seen_alive) std.log.info("thaddius: Feugen seen alive hp={}", .{hp});
                fight.feugen_seen_alive = true;
            } else {
                if (!fight.feugen_seen_dead) std.log.info("thaddius: Feugen seen dead", .{});
                fight.feugen_seen_dead = true;
            }
        },
    }
}

pub fn twinDefeatedHp(hp: u32) bool {
    return hp <= twin_defeated_hp_threshold;
}

pub fn bothTwinsDefeated() bool {
    return fight.stalagg_seen_alive and fight.feugen_seen_alive and
        fight.stalagg_seen_dead and fight.feugen_seen_dead;
}

pub fn bothTanksReady() bool {
    if (fight.tank_count != 2) return false;
    return fight.tanks[0].ready and fight.tanks[1].ready;
}

pub fn tanksPullSequenceDone() bool {
    if (fight.tank_count != 2) return false;
    for (fight.tanks[0..fight.tank_count]) |tank| {
        if (!tank.active) return false;
        const bs = find(tank.bot_id) orelse return false;
        if (!bs.twin_pull_facing_done) return false;
    }
    return true;
}

pub fn setTankReady(bot_id: BotId, side: Side) void {
    const was_ready = bothTanksReady();
    for (&fight.tanks) |*tank| {
        if (tank.active and std.mem.eql(u8, &tank.bot_id, &bot_id)) {
            tank.ready = true;
            tank.side = side;
            if (!was_ready and bothTanksReady()) {
                std.log.info("thaddius: both tanks ready - attack phase starting", .{});
            }
            return;
        }
    }
}

pub fn tankSide(bot_id: BotId) ?Side {
    for (&fight.tanks) |*tank| {
        if (tank.active and std.mem.eql(u8, &tank.bot_id, &bot_id)) return tank.side;
    }
    return null;
}

pub fn tankGuidForSide(side: Side) ?u64 {
    for (&fight.tanks) |*tank| {
        if (tank.active and tank.side == side) return tank.guid;
    }
    return null;
}

pub fn refreshAssignedTanks() void {
    for (&entries) |*slot| {
        if (slot.*) |*entry| {
            assignments.setAssignedTank(entry.bot_id, tankGuidForSide(entry.side) orelse 0);
        }
    }
}

pub fn noteThaddiusAttackable(game_time_ms: u32) void {
    if (fight.thaddius_attackable_game_time_ms == 0) {
        fight.thaddius_attackable_game_time_ms = game_time_ms;
        std.log.info("thaddius: boss became attackable game_time_ms={}", .{game_time_ms});
    }
}

pub fn isTankSwapping(bot_id: BotId) bool {
    return (find(bot_id) orelse return false).swap_in_progress;
}

pub fn beginTankRefresh() void {
    for (&fight.tanks) |*tank| {
        tank.active = false;
    }
    fight.tank_count = 0;
    fight.extra_tank_count = 0;
}

pub fn refreshTank(bot_id: BotId, guid: u64, name: []const u8, initial_side: Side) void {
    for (&fight.tanks) |*tank| {
        if (std.mem.eql(u8, &tank.bot_id, &bot_id)) {
            tank.active = true;
            tank.guid = guid;
            copyName(&tank.name, name);
            tank.initial_side = initial_side;
            fight.tank_count += 1;
            return;
        }
    }

    for (&fight.tanks) |*tank| {
        if (types.isZeroBotId(&tank.bot_id)) {
            tank.* = .{
                .active = true,
                .bot_id = bot_id,
                .guid = guid,
                .name = std.mem.zeroes([32]u8),
                .initial_side = initial_side,
                .side = initial_side,
                .ready = false,
            };
            copyName(&tank.name, name);
            fight.tank_count += 1;
            return;
        }
    }

    fight.extra_tank_count += 1;
}

pub fn applySwap(spell_id: u32, caster_guid: u64, observer_guid: u64, game_time_ms: u32) bool {
    if (game_time_ms <= fight.last_magnetic_pull_game_time_ms) return false;
    if (fight.tank_count != 2 or fight.extra_tank_count != 0) {
        std.log.warn("thaddius: magnetic pull ignored spell={} caster=0x{x} observer=0x{x} game_time_ms={} tanks={} extra_tanks={}", .{
            spell_id,
            caster_guid,
            observer_guid,
            game_time_ms,
            fight.tank_count,
            fight.extra_tank_count,
        });
        fight.last_magnetic_pull_game_time_ms = game_time_ms;
        return false;
    }

    const old_a = fight.tanks[0].side;
    const old_b = fight.tanks[1].side;
    fight.tanks[0].side = opposite(fight.tanks[0].side);
    fight.tanks[1].side = opposite(fight.tanks[1].side);
    fight.swap_generation +|= 1;
    fight.last_magnetic_pull_game_time_ms = game_time_ms;
    refreshAssignedTanks();

    std.log.info("thaddius: magnetic pull swap_generation={} spell={} caster=0x{x} observer=0x{x} game_time_ms={} tankA={s}/0x{x}:{s}->{s} tankB={s}/0x{x}:{s}->{s}", .{
        fight.swap_generation,
        spell_id,
        caster_guid,
        observer_guid,
        game_time_ms,
        std.mem.sliceTo(&fight.tanks[0].name, 0),
        fight.tanks[0].guid,
        @tagName(old_a),
        @tagName(fight.tanks[0].side),
        std.mem.sliceTo(&fight.tanks[1].name, 0),
        fight.tanks[1].guid,
        @tagName(old_b),
        @tagName(fight.tanks[1].side),
    });
    return true;
}

pub fn find(bot_id: BotId) ?*BotState {
    for (&entries) |*slot| {
        if (slot.*) |*e| {
            if (std.mem.eql(u8, &e.bot_id, &bot_id)) return e;
        }
    }
    return null;
}

pub fn findOrInsert(bot_id: BotId, default_side: Side) ?*BotState {
    if (find(bot_id)) |e| return e;
    for (&entries) |*slot| {
        if (slot.* == null) {
            slot.* = BotState{ .bot_id = bot_id, .initial_side = default_side, .side = default_side };
            return &slot.*.?;
        }
    }
    return null;
}

pub fn reset() void {
    entries = .{null} ** max_bots;
    fight = .{};
    assignments.reset();
}

fn copyName(dst: *[32]u8, name: []const u8) void {
    @memset(dst[0..], 0);
    const n = @min(name.len, dst.len - 1);
    @memcpy(dst[0..n], name[0..n]);
}
