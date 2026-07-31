//! Map combat `Action` values to wire `MastermindMsg` values.
//!
//! Pure helpers: no I/O, no logs. Pulled out of brain.zig so the action →
//! wire-message translation can be exercised without dragging in the full
//! brain dependency graph.

const std = @import("std");
const proto = @import("protocol");
const combat = @import("../combat/mod.zig");

pub fn withinJumpNearXY(state: proto.State, target_x: f32, target_y: f32, tolerance_yards: f32) bool {
    const tol = @max(tolerance_yards, 0.0);
    const dx = state.x - target_x;
    const dy = state.y - target_y;
    return dx * dx + dy * dy <= tol * tol;
}

pub fn ctmActionNeedsStop(raw: u32) bool {
    const action = std.enums.fromInt(proto.CtmAction, raw) orelse return false;
    return switch (action) {
        .idle => false,
        .move, .interact_npc, .loot, .interact_obj, .skin, .attack_pos, .attack => true,
    };
}

pub fn actionToMsg(action: combat.Action, state: proto.State) ?proto.MastermindMsg {
    return switch (action) {
        .none => null,
        .cast => |id| .{ .cast_spell_id = .{ .spell_id = id } },
        .cast_instant => |id| .{ .cast_spell_id = .{ .spell_id = id } },
        .cast_target => |ct| .{ .cast_spell_guid = .{ .spell_id = ct.spell_id, .target_guid = ct.target_guid } },
        .cast_target_instant => |ct| .{ .cast_spell_guid = .{ .spell_id = ct.spell_id, .target_guid = ct.target_guid } },
        .cast_ground => |cg| .{ .cast_spell_ground = .{ .spell_id = cg.spell_id, .x = cg.x, .y = cg.y, .z = cg.z } },
        .attack => |guid| .{ .ctm_attack_guid = .{ .guid = guid } },
        .target_guid => |guid| .{ .set_target_guid = .{ .guid = guid } },
        .ctm_stop => .ctm_stop,
        .clear_target => blk: {
            var buf = std.mem.zeroes([proto.lua_str_max]u8);
            @memcpy(buf[0.."StopAttack()ClearTarget()".len], "StopAttack()ClearTarget()");
            break :blk .{ .lua_exec = buf };
        },
        .start_attack => blk: {
            var buf = std.mem.zeroes([proto.lua_str_max]u8);
            @memcpy(buf[0.."StartAttack()".len], "StartAttack()");
            break :blk .{ .lua_exec = buf };
        },
        .stop_attack => blk: {
            var buf = std.mem.zeroes([proto.lua_str_max]u8);
            @memcpy(buf[0.."StopAttack()".len], "StopAttack()");
            break :blk .{ .lua_exec = buf };
        },
        .stop_cast => blk: {
            var buf = std.mem.zeroes([proto.lua_str_max]u8);
            @memcpy(buf[0.."SpellStopCasting()".len], "SpellStopCasting()");
            break :blk .{ .lua_exec = buf };
        },
        .set_facing_rad => |rad| .{ .set_facing = rad },
        .interact => |guid| .{ .ctm_interact_guid = .{ .guid = guid } },
        .move_to => |coords| .{ .ctm_move = .{ .x = coords.x, .y = coords.y, .z = coords.z } },
        .move_to_nb => |coords| .{ .ctm_move = .{ .x = coords.x, .y = coords.y, .z = coords.z } },
        .jump => .{ .jump = 0 },
        .walk => |w| .{ .walk = .{ .direction = w.direction, .duration_ms = w.duration_ms } },
        .jump_near_xy => |j| if (withinJumpNearXY(state, j.x, j.y, j.tolerance_yards))
            .{ .jump = 0 }
        else
            null,
        .use_inventory_item => |slot| blk: {
            var buf = std.mem.zeroes([proto.lua_str_max]u8);
            _ = std.fmt.bufPrint(&buf, "UseInventoryItem({d})", .{slot}) catch break :blk null;
            break :blk .{ .lua_exec = buf };
        },
        .apply_poison => |item_id| blk: {
            var buf = std.mem.zeroes([proto.lua_str_max]u8);
            _ = std.fmt.bufPrint(&buf,
                \\m,_,_,h=GetWeaponEnchantInfo()if not m or not h then for b=0,4 do for s=1,GetContainerNumSlots(b)do i=GetContainerItemID(b,s)if i=={d} then UseContainerItem(b,s)PickupInventoryItem(m and 17 or 16)return end end end end
            , .{item_id}) catch break :blk null;
            break :blk .{ .lua_exec = buf };
        },
    };
}

test "actionToMsg: jump_near_xy only when in range" {
    var state = std.mem.zeroes(proto.State);
    const j: combat.Action = .{ .jump_near_xy = .{ .x = 100, .y = 200, .tolerance_yards = 2.0 } };
    state.x = 0;
    state.y = 0;
    try std.testing.expect(actionToMsg(j, state) == null);
    state.x = 100;
    state.y = 200.5;
    const msg = actionToMsg(j, state).?;
    try std.testing.expect(msg == .jump);
}

test "actionToMsg: target_guid maps to non-ctm target selection" {
    const msg = actionToMsg(.{ .target_guid = 0xabc }, std.mem.zeroes(proto.State)).?;
    try std.testing.expect(msg == .set_target_guid);
    try std.testing.expectEqual(@as(u64, 0xabc), msg.set_target_guid.guid);
}

test "actionToMsg: walk maps to wire walk command" {
    const action: combat.Action = .{ .walk = .{ .direction = .backward, .duration_ms = proto.brain_tick_ms } };
    const msg = actionToMsg(action, std.mem.zeroes(proto.State)).?;
    try std.testing.expect(msg == .walk);
    try std.testing.expectEqual(proto.WalkDir.backward, msg.walk.direction);
    try std.testing.expectEqual(proto.brain_tick_ms, msg.walk.duration_ms);
}

test "actionToMsg: cast_ground maps to wire ground cast command" {
    const action: combat.Action = .{ .cast_ground = .{ .spell_id = 1234, .x = 10.0, .y = 20.0, .z = 30.0 } };
    const msg = actionToMsg(action, std.mem.zeroes(proto.State)).?;
    try std.testing.expect(msg == .cast_spell_ground);
    try std.testing.expectEqual(@as(u32, 1234), msg.cast_spell_ground.spell_id);
    try std.testing.expectEqual(@as(f32, 10.0), msg.cast_spell_ground.x);
    try std.testing.expectEqual(@as(f32, 20.0), msg.cast_spell_ground.y);
    try std.testing.expectEqual(@as(f32, 30.0), msg.cast_spell_ground.z);
}

test "ctmActionNeedsStop treats idle and unknown as stopped" {
    try std.testing.expect(!ctmActionNeedsStop(@intFromEnum(proto.CtmAction.idle)));
    try std.testing.expect(!ctmActionNeedsStop(0));
    try std.testing.expect(ctmActionNeedsStop(@intFromEnum(proto.CtmAction.move)));
}
