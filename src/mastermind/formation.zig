// Raid invite / ConvertToRaid state machine. Started by the operator (GUI
// "Start formation" or repl `reform`); independent of combat — the brain
// continues its compute loop while this ticks until `done`.
const std = @import("std");
const proto = @import("protocol");
const types = @import("types");
const registry_mod = @import("registry");

const Registry = registry_mod.Registry;
const BotSnapshot = registry_mod.BotSnapshot;
const BotId = types.BotId;

const accept_interval: u32 = 10;
const convert_retry_interval: u32 = 10;
// Safety fallback (~5 min)
const timeout_ticks: u32 = 1500;

const Phase = enum {
    disbanding, // send DisbandGroup / LeaveParty
    wait_disband, // wait until all bots have is_in_raid == 0 and group_size == 0
    invite_second, // send InviteUnit(bot2)
    converting, // send ConvertToRaid until bot2.is_in_raid == 1
    invite_n, // send InviteUnit(next_invite_num)
    wait_n, // wait for botN.is_in_raid == 1
};

pub const FormationStore = struct {
    tick: u32 = 0,
    done: bool = false,
    phase: Phase = .disbanding,
    last_connected_count: usize = 0,
    next_invite_num: u32 = 3,
};

pub fn reset(store: *FormationStore) void {
    store.* = .{};
}

pub fn isDone(store: *const FormationStore) bool {
    return store.done;
}

pub fn tick(store: *FormationStore, io: std.Io, registry: *Registry, bots: []const BotSnapshot) void {
    if (store.done) return;

    if (bots.len != store.last_connected_count) {
        std.log.info("formation: {} bot(s) connected", .{bots.len});
        store.last_connected_count = bots.len;
    }

    if (raidIsAlreadyFormed(bots, types.max_bots)) {
        std.log.info("formation: raid already formed at {} members, skipping re-form", .{types.max_bots});
        store.done = true;
        return;
    }

    if (bots.len <= 1) {
        store.done = true;
        return;
    }

    store.tick += 1;

    var bot1: ?BotSnapshot = null;
    for (bots) |bot| {
        if (isBot1(&bot.bot_id)) bot1 = bot;
    }

    if (bot1 == null) {
        std.log.warn("formation: tick={} no bot1 found among {} bots", .{ store.tick, bots.len });
        return;
    }
    const b1 = bot1.?;

    // Dismiss invite/ConvertToRaid popups on all bots every accept_interval ticks.
    if (store.tick % accept_interval == 0) {
        for (bots) |bot| {
            sendLua(io, registry, bot.bot_id, "if StaticPopup1 and StaticPopup1:IsShown() then StaticPopup1Button1:Click() end");
        }
    }

    switch (store.phase) {
        .disbanding => {
            std.log.info("formation: disbanding all groups", .{});
            sendLua(io, registry, b1.bot_id, "DisbandGroup()");
            for (bots) |bot| {
                if (!isBot1(&bot.bot_id)) sendLua(io, registry, bot.bot_id, "LeaveParty()");
            }
            store.phase = .wait_disband;
        },

        .wait_disband => {
            std.log.debug("formation: waiting for all bots to leave group", .{});
            if (allBotsUngrouped(bots)) {
                std.log.info("formation: all bots ungrouped, ready to form raid", .{});
                store.phase = .invite_second;
            }
        },

        .invite_second => {
            const name = findBotName(bots, 2) orelse {
                std.log.warn("formation: bot2 not connected, waiting", .{});
                return;
            };
            inviteByName(io, registry, b1.bot_id, name);
            std.log.info("formation: invited bot2 ({s})", .{name});
            store.phase = .converting;
        },

        // ConvertToRaid() fails silently until bot2 accepts the invite.
        // Retry every convert_retry_interval ticks; exit when bot2.is_in_raid == 1.
        .converting => {
            if (botIsInRaid(bots, 2)) {
                std.log.info("formation: bot2 in raid, starting invites from bot3", .{});
                store.phase = .invite_n;
                return;
            }
            if (store.tick % convert_retry_interval == 0) {
                std.log.info("formation: sending ConvertToRaid", .{});
                sendLua(io, registry, b1.bot_id, "ConvertToRaid()");
            }
        },

        .invite_n => {
            const n = store.next_invite_num;
            const name = findBotName(bots, n) orelse {
                if (allConnectedBotsInRaid(bots)) {
                    std.log.info("formation: all connected bots in raid, done", .{});
                    store.done = true;
                }
                return;
            };
            inviteByName(io, registry, b1.bot_id, name);
            std.log.info("formation: invited bot{} ({s})", .{ n, name });
            store.phase = .wait_n;
        },

        .wait_n => {
            const n = store.next_invite_num;
            std.log.debug("formation: waiting for bot{} is_in_raid", .{n});
            if (botIsInRaid(bots, n)) {
                store.next_invite_num += 1;
                if (store.next_invite_num > types.max_bots) {
                    std.log.info("formation: all {} bots in raid, done", .{types.max_bots});
                    store.done = true;
                    return;
                }
                store.phase = .invite_n;
            }
        },
    }

    if (store.tick >= timeout_ticks) {
        std.log.warn("formation: timeout (phase={s}, next=bot{})", .{
            @tagName(store.phase), store.next_invite_num,
        });
        store.done = true;
    }
}

fn isBot1(bot_id: *const BotId) bool {
    return std.mem.eql(u8, std.mem.sliceTo(bot_id, 0), "bot1");
}

fn botNumber(bot_id: *const BotId) u32 {
    const s = std.mem.sliceTo(bot_id, 0);
    if (s.len <= "bot".len) return std.math.maxInt(u32);
    return std.fmt.parseInt(u32, s["bot".len..], 10) catch std.math.maxInt(u32);
}

fn findBotName(bots: []const BotSnapshot, num: u32) ?[]const u8 {
    for (bots) |*bot| {
        if (botNumber(&bot.bot_id) == num) return std.mem.sliceTo(&bot.state.player_name, 0);
    }
    return null;
}

fn botIsInRaid(bots: []const BotSnapshot, num: u32) bool {
    for (bots) |bot| {
        if (botNumber(&bot.bot_id) == num) return bot.state.is_in_raid == 1;
    }
    return false;
}

fn allBotsUngrouped(bots: []const BotSnapshot) bool {
    for (bots) |bot| {
        if (bot.state.is_in_raid == 1 or bot.state.group_size > 0) return false;
    }
    return true;
}

fn allConnectedBotsInRaid(bots: []const BotSnapshot) bool {
    for (bots) |bot| {
        if (bot.state.is_in_raid == 0) return false;
    }
    return true;
}

fn raidIsAlreadyFormed(bots: []const BotSnapshot, expected_size: usize) bool {
    if (bots.len == 0 or expected_size == 0) return false;

    for (bots) |bot| {
        if (bot.state.is_in_raid == 0) return false;
        if (bot.state.group_size + 1 != expected_size) return false;
    }

    return true;
}

fn inviteByName(io: std.Io, registry: *Registry, bot1_id: BotId, name: []const u8) void {
    var script: [proto.lua_str_max]u8 = undefined;
    const written = std.fmt.bufPrint(&script, "InviteUnit(\"{s}\");", .{name}) catch return;
    sendLua(io, registry, bot1_id, written);
}

fn sendLua(io: std.Io, registry: *Registry, bot_id: BotId, script: []const u8) void {
    var buf = std.mem.zeroes([proto.lua_str_max]u8);
    const len = @min(script.len, proto.lua_str_max - 1);
    @memcpy(buf[0..len], script[0..len]);
    const sent = registry.dispatch(io, .{ .lua_exec = buf }, &.{bot_id});
    std.log.debug("formation: lua_exec to {s} ({} sent): {s}", .{ std.mem.sliceTo(&bot_id, 0), sent, script });
}

test "tick: already formed raid at full size is left alone" {
    var store: FormationStore = .{};
    var registry: Registry = .{};
    var bot1 = std.mem.zeroes(BotSnapshot);
    var bot2 = std.mem.zeroes(BotSnapshot);

    bot1.state.is_in_raid = 1;
    bot1.state.group_size = 24;
    bot2.state.is_in_raid = 1;
    bot2.state.group_size = 24;

    const bots = [_]BotSnapshot{ bot1, bot2 };

    tick(&store, std.testing.allocator, &registry, bots[0..]);
    try std.testing.expect(store.done);
}
