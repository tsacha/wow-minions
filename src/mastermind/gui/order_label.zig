//! Human-readable labels for combat `Order`s — fed into the GUI status panel
//! and the dispatch debug log. Pure formatting; no I/O.

const std = @import("std");
const proto = @import("protocol");
const types = @import("types");
const registry_mod = @import("registry");
const world_memory_mod = @import("../world/memory.zig");
const gui_snapshot = @import("snapshot.zig");
const combat = @import("../combat/mod.zig");
const world_query = @import("../combat/world_query.zig");
const geo = @import("../combat/geo.zig");

const BotId = types.BotId;
const BotSnapshot = registry_mod.BotSnapshot;
const WorldSnapshot = world_memory_mod.WorldSnapshot;

pub const Order = struct {
    bot_id: BotId,
    msg: proto.MastermindMsg,
};

pub fn copyLabel(dst: *[gui_snapshot.combat_order_label_len]u8, text: []const u8) void {
    @memset(dst.*[0..], 0);
    const n = @min(text.len, dst.len - 1);
    @memcpy(dst.*[0..n], text[0..n]);
}

pub fn zeroTerminatedLen(buf: []const u8) usize {
    for (buf, 0..) |b, i| {
        if (b == 0) return i;
    }
    return buf.len;
}

pub fn botLabel(bot: BotSnapshot) []const u8 {
    const name_len = zeroTerminatedLen(bot.state.player_name[0..]);
    const name = bot.state.player_name[0..name_len];
    if (name.len > 0) return name;
    const id_len = zeroTerminatedLen(bot.bot_id[0..]);
    return bot.bot_id[0..id_len];
}

pub fn spellLabelForBot(bot_opt: ?BotSnapshot, spell_id: u32) []const u8 {
    const bot = bot_opt orelse return "unknown";
    const spec = combat.primarySpecFromState(bot.state);
    return combat.spellName(spec, spell_id) orelse "unknown";
}

fn petOwnerLabel(bots: []const BotSnapshot, pet_guid: u64) ?[]const u8 {
    if (pet_guid == 0) return null;
    for (bots) |*bot| {
        if (bot.state.pet_guid != pet_guid) continue;
        const name_len = zeroTerminatedLen(bot.state.player_name[0..]);
        const name = bot.state.player_name[0..name_len];
        if (name.len > 0) return name;
        const id_len = zeroTerminatedLen(bot.bot_id[0..]);
        return bot.bot_id[0..id_len];
    }
    return null;
}

pub const OrderTargetDebug = struct {
    target: proto.ScanEntry,
    dist: f32,
    target_to_player: f32,
    target_player_delta: f32,
};

pub fn orderTargetDebug(bot: BotSnapshot, world: []const WorldSnapshot, target_guid: u64) ?OrderTargetDebug {
    if (target_guid == 0) return null;
    const target = world_query.scanForGuidOnMap(world, target_guid, bot.state.map_id) orelse return null;
    const bot_pos = geo.Vec3{ .x = bot.state.x, .y = bot.state.y, .z = bot.state.z };
    const target_pos = geo.Vec3{ .x = target.x, .y = target.y, .z = target.z };
    const dx = target.x - bot.state.x;
    const dy = target.y - bot.state.y;
    const dz = target.z - bot.state.z;
    const target_to_player = geo.angleTo2d(target_pos, bot_pos);

    return .{
        .target = target,
        .dist = @sqrt(dx * dx + dy * dy + dz * dz),
        .target_to_player = target_to_player,
        .target_player_delta = geo.absAngleDeltaRad(target.orientation, target_to_player),
    };
}

pub fn actionLabel(buf: *[gui_snapshot.combat_order_label_len]u8, action: combat.Action, bot_opt: ?BotSnapshot) []const u8 {
    @memset(buf.*[0..], 0);
    return switch (action) {
        .cast, .cast_instant => |id| std.fmt.bufPrintZ(buf.*[0..], "{s} ({})", .{ spellLabelForBot(bot_opt, id), id }) catch @tagName(action),
        .cast_target => |ct| std.fmt.bufPrintZ(buf.*[0..], "{s} ({})", .{ spellLabelForBot(bot_opt, ct.spell_id), ct.spell_id }) catch @tagName(action),
        .cast_target_instant => |ct| std.fmt.bufPrintZ(buf.*[0..], "{s} ({})", .{ spellLabelForBot(bot_opt, ct.spell_id), ct.spell_id }) catch @tagName(action),
        .cast_ground => |cg| std.fmt.bufPrintZ(buf.*[0..], "{s} ({}) @ ({d:.1},{d:.1},{d:.1})", .{ spellLabelForBot(bot_opt, cg.spell_id), cg.spell_id, cg.x, cg.y, cg.z }) catch @tagName(action),
        .target_guid => |guid| std.fmt.bufPrintZ(buf.*[0..], "target 0x{x}", .{guid}) catch @tagName(action),
        else => @tagName(action),
    };
}

fn formatCastOrderLabel(
    buf: *[gui_snapshot.combat_order_label_len]u8,
    bot_name: []const u8,
    bot_opt: ?BotSnapshot,
    world: []const WorldSnapshot,
    spell_id: u32,
    cast_target_guid: u64,
) []const u8 {
    const name = spellLabelForBot(bot_opt, spell_id);
    const bot = bot_opt orelse return std.fmt.bufPrintZ(buf.*[0..], "{s}: {s} ({d})", .{ bot_name, name, spell_id }) catch blk: {
        copyLabel(buf, "order label overflow");
        break :blk buf.*[0..0 :0];
    };

    if (orderTargetDebug(bot, world, cast_target_guid)) |target_debug| {
        const target = target_debug.target;
        return std.fmt.bufPrintZ(
            buf.*[0..],
            "{s}: {s} ({d}) cast_tgt=0x{x} dist={d:.1} from=({d:.1},{d:.1},{d:.1}) o={d:.3} tgt=0x{x} target=({d:.1},{d:.1},{d:.1}) target_o={d:.3} target_to_player={d:.3} target_player_delta={d:.3} reach=({d:.1},{d:.1}) br=({d:.1},{d:.1}) ctm={} ctm_dst=({d:.1},{d:.1},{d:.1})",
            .{
                bot_name,
                name,
                spell_id,
                cast_target_guid,
                target_debug.dist,
                bot.state.x,
                bot.state.y,
                bot.state.z,
                bot.state.orientation,
                bot.state.target_guid,
                target.x,
                target.y,
                target.z,
                target.orientation,
                target_debug.target_to_player,
                target_debug.target_player_delta,
                bot.state.combat_reach,
                target.combat_reach,
                bot.state.bounding_radius,
                target.bounding_radius,
                bot.state.ctm_action,
                bot.state.ctm_x,
                bot.state.ctm_y,
                bot.state.ctm_z,
            },
        ) catch blk: {
            copyLabel(buf, "order label overflow");
            break :blk buf.*[0..0 :0];
        };
    }

    return std.fmt.bufPrintZ(
        buf.*[0..],
        "{s}: {s} ({d}) cast_tgt=0x{x} from=({d:.1},{d:.1},{d:.1}) o={d:.3} tgt=0x{x} ctm={} ctm_dst=({d:.1},{d:.1},{d:.1})",
        .{
            bot_name,
            name,
            spell_id,
            cast_target_guid,
            bot.state.x,
            bot.state.y,
            bot.state.z,
            bot.state.orientation,
            bot.state.target_guid,
            bot.state.ctm_action,
            bot.state.ctm_x,
            bot.state.ctm_y,
            bot.state.ctm_z,
        },
    ) catch blk: {
        copyLabel(buf, "order label overflow");
        break :blk buf.*[0..0 :0];
    };
}

pub fn formatOrderLabel(buf: *[gui_snapshot.combat_order_label_len]u8, order: Order, bots: []const BotSnapshot, world: []const WorldSnapshot) []const u8 {
    const bot_opt = registry_mod.findBotSnapshot(bots, &order.bot_id);
    const bot_name_src = if (bot_opt) |bot| botLabel(bot) else order.bot_id[0..zeroTerminatedLen(order.bot_id[0..])];
    var bot_name_buf: [32]u8 = std.mem.zeroes([32]u8);
    const bot_name_len = @min(bot_name_src.len, bot_name_buf.len - 1);
    @memcpy(bot_name_buf[0..bot_name_len], bot_name_src[0..bot_name_len]);
    const bot_name = bot_name_buf[0..bot_name_len];
    @memset(buf.*[0..], 0);
    const text = switch (order.msg) {
        .cast_spell_id => |c| blk: {
            const target_guid = if (bot_opt) |bot| bot.state.target_guid else 0;
            if (petOwnerLabel(bots, target_guid)) |owner| {
                break :blk std.fmt.bufPrintZ(
                    buf.*[0..],
                    "{s}: {s} ({d}) cast_tgt=0x{x} pet_owner=0x{x} Owned by {s}",
                    .{ bot_name, spellLabelForBot(bot_opt, c.spell_id), c.spell_id, target_guid, if (bot_opt) |bot| bot.state.pet_guid else 0, owner },
                ) catch {
                    copyLabel(buf, "order label overflow");
                    break :blk buf.*[0..0 :0];
                };
            }
            break :blk formatCastOrderLabel(buf, bot_name, bot_opt, world, c.spell_id, target_guid);
        },
        .cast_spell_guid => |c| blk: {
            if (petOwnerLabel(bots, c.target_guid)) |owner| {
                break :blk std.fmt.bufPrintZ(
                    buf.*[0..],
                    "{s}: {s} ({d}) cast_tgt=0x{x} pet_owner=0x{x} Owned by {s}",
                    .{ bot_name, spellLabelForBot(bot_opt, c.spell_id), c.spell_id, c.target_guid, if (bot_opt) |bot| bot.state.pet_guid else 0, owner },
                ) catch {
                    copyLabel(buf, "order label overflow");
                    break :blk buf.*[0..0 :0];
                };
            }
            break :blk formatCastOrderLabel(buf, bot_name, bot_opt, world, c.spell_id, c.target_guid);
        },
        .cast_spell_ground => |c| blk: {
            break :blk std.fmt.bufPrintZ(
                buf.*[0..],
                "{s}: {s} ({d}) @ ({d:.1},{d:.1},{d:.1})",
                .{ bot_name, spellLabelForBot(bot_opt, c.spell_id), c.spell_id, c.x, c.y, c.z },
            ) catch {
                copyLabel(buf, "order label overflow");
                break :blk buf.*[0..0 :0];
            };
        },
        .ctm_move => |c| blk: {
            if (bot_opt) |bot| {
                const dx = c.x - bot.state.x;
                const dy = c.y - bot.state.y;
                const dz = c.z - bot.state.z;
                const dist = @sqrt(dx * dx + dy * dy + dz * dz);
                break :blk std.fmt.bufPrintZ(
                    buf.*[0..],
                    "{s}: move dst=({d:.1},{d:.1},{d:.1}) from=({d:.1},{d:.1},{d:.1}) d={d:.1} o={d:.3} tgt=0x{x} ctm={} ctm_dst=({d:.1},{d:.1},{d:.1})",
                    .{
                        bot_name,
                        c.x,
                        c.y,
                        c.z,
                        bot.state.x,
                        bot.state.y,
                        bot.state.z,
                        dist,
                        bot.state.orientation,
                        bot.state.target_guid,
                        bot.state.ctm_action,
                        bot.state.ctm_x,
                        bot.state.ctm_y,
                        bot.state.ctm_z,
                    },
                ) catch {
                    copyLabel(buf, "order label overflow");
                    break :blk buf.*[0..0 :0];
                };
            }
            break :blk std.fmt.bufPrintZ(buf.*[0..], "{s}: move {d:.1},{d:.1}", .{ bot_name, c.x, c.y }) catch {
                copyLabel(buf, "order label overflow");
                break :blk buf.*[0..0 :0];
            };
        },
        .ctm_stop => std.fmt.bufPrintZ(buf.*[0..], "{s}: stop", .{bot_name}) catch blk: {
            copyLabel(buf, "order label overflow");
            break :blk buf.*[0..0 :0];
        },
        .lua_exec => |code| blk: {
            const text_code = std.mem.sliceTo(&code, 0);
            break :blk std.fmt.bufPrintZ(buf.*[0..], "{s}: lua {s}", .{ bot_name, text_code[0..@min(text_code.len, 28)] }) catch {
                copyLabel(buf, "order label overflow");
                break :blk buf.*[0..0 :0];
            };
        },
        .ctm_attack_guid => std.fmt.bufPrintZ(buf.*[0..], "{s}: attack", .{bot_name}) catch blk: {
            copyLabel(buf, "order label overflow");
            break :blk buf.*[0..0 :0];
        },
        .set_target_guid => |c| std.fmt.bufPrintZ(buf.*[0..], "{s}: target 0x{x}", .{ bot_name, c.guid }) catch blk: {
            copyLabel(buf, "order label overflow");
            break :blk buf.*[0..0 :0];
        },
        .ctm_interact_guid => std.fmt.bufPrintZ(buf.*[0..], "{s}: interact", .{bot_name}) catch blk: {
            copyLabel(buf, "order label overflow");
            break :blk buf.*[0..0 :0];
        },
        .set_facing => std.fmt.bufPrintZ(buf.*[0..], "{s}: face", .{bot_name}) catch blk: {
            copyLabel(buf, "order label overflow");
            break :blk buf.*[0..0 :0];
        },
        .jump => std.fmt.bufPrintZ(buf.*[0..], "{s}: jump", .{bot_name}) catch blk: {
            copyLabel(buf, "order label overflow");
            break :blk buf.*[0..0 :0];
        },
        .walk => |c| std.fmt.bufPrintZ(buf.*[0..], "{s}: walk {s} {d}ms", .{ bot_name, @tagName(c.direction), c.duration_ms }) catch blk: {
            copyLabel(buf, "order label overflow");
            break :blk buf.*[0..0 :0];
        },
        .lua_get => |code| blk: {
            const text_code = std.mem.sliceTo(&code, 0);
            break :blk std.fmt.bufPrintZ(buf.*[0..], "{s}: get {s}", .{ bot_name, text_code[0..@min(text_code.len, 28)] }) catch {
                copyLabel(buf, "order label overflow");
                break :blk buf.*[0..0 :0];
            };
        },
    };
    if (text.len > 0) return text;
    return std.mem.sliceTo(buf.*[0..], 0);
}

test "formatOrderLabel: pet target shows owner" {
    var bot: BotSnapshot = std.mem.zeroes(BotSnapshot);
    bot.bot_id[0] = 'w';
    bot.bot_id[1] = 'l';
    bot.bot_id[2] = 'k';
    bot.state.pet_guid = 0xfeed;
    bot.state.player_name[0] = 'D';
    bot.state.player_name[1] = 'e';
    bot.state.player_name[2] = 'm';
    bot.state.player_name[3] = 'o';

    const order: Order = .{
        .bot_id = bot.bot_id,
        .msg = .{ .cast_spell_guid = .{ .spell_id = 30146, .target_guid = 0xfeed } },
    };

    var buf: [gui_snapshot.combat_order_label_len]u8 = undefined;
    const text = formatOrderLabel(&buf, order, &.{bot}, &.{});
    try std.testing.expect(std.mem.indexOf(u8, text, "Owned by Demo") != null);
}
