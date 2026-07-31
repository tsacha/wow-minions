const std = @import("std");
const win32 = @import("win32");
const types = @import("types.zig");
const offsets = @import("offsets.zig");
const world = @import("world.zig");
const Offsets = offsets.Offsets;

const click_to_move: types.ClickToMoveFn = @ptrFromInt(Offsets.CTM_FUN_PTR);
const ctm_face: types.CtmFaceFn = @ptrFromInt(Offsets.CTM_FACE);
const jump_or_ascend_start: types.JumpOrAscendStartFn = @ptrFromInt(Offsets.LUA_JUMP_OR_ASCEND_START);
const move_forward_start: types.WalkFn = @ptrFromInt(Offsets.MOVE_FORWARD_START);
const move_forward_stop: types.WalkFn = @ptrFromInt(Offsets.MOVE_FORWARD_STOP);
const move_backward_start: types.WalkFn = @ptrFromInt(Offsets.MOVE_BACKWARD_START);
const move_backward_stop: types.WalkFn = @ptrFromInt(Offsets.MOVE_BACKWARD_STOP);
const strafe_left_start: types.WalkFn = @ptrFromInt(Offsets.STRAFE_LEFT_START);
const strafe_left_stop: types.WalkFn = @ptrFromInt(Offsets.STRAFE_LEFT_STOP);
const strafe_right_start: types.WalkFn = @ptrFromInt(Offsets.STRAFE_RIGHT_START);
const strafe_right_stop: types.WalkFn = @ptrFromInt(Offsets.STRAFE_RIGHT_STOP);

const ctm_move_stop_distance: f32 = 0.5;
const ctm_interact_stop_distance: f32 = 3.0;

pub fn ctmMoveTo(pos: types.Vec3) void {
    if (!world.isWorldReady()) return;
    if (!world.vec3LooksValid(pos)) return;
    const world_obj = world.world_player_obj.load(.acquire);
    var guid: u64 = 0;
    var p = [3]f32{ pos.x, pos.y, pos.z };
    click_to_move(world_obj, @intFromEnum(types.CtmAction.move), &guid, &p, ctm_move_stop_distance);
}

pub fn ctmFace(radians: f32) void {
    if (!world.isWorldReady()) return;
    if (!std.math.isFinite(radians)) return;
    const world_obj = world.world_player_obj.load(.acquire);
    ctm_face(world_obj, radians);
}

pub fn ctmStop() void {
    if (!world.isWorldReady()) return;
    const world_obj = world.world_player_obj.load(.acquire);
    const pos = world.readPlayerPosition(world_obj) orelse return;
    if (!world.vec3LooksValid(pos)) return;
    var guid: u64 = 0;
    var p = [3]f32{ pos.x, pos.y, pos.z };
    click_to_move(world_obj, @intFromEnum(types.CtmAction.move), &guid, &p, ctm_move_stop_distance);
}

pub fn ctmGuidAction(action: types.CtmAction, guid: u64) void {
    if (!world.isWorldReady()) return;
    const obj_mgr = world.world_object_manager.load(.acquire);
    if (obj_mgr == 0) return;

    const target_obj = world.findObjectByGuid(obj_mgr, guid) orelse return;
    const vec = world.readPlayerPosition(target_obj) orelse return;
    if (!world.vec3LooksValid(vec)) return;
    const world_obj = world.world_player_obj.load(.acquire);
    var target_guid = guid;
    var pos = [3]f32{ vec.x, vec.y, vec.z };
    click_to_move(world_obj, @intFromEnum(action), &target_guid, &pos, ctm_interact_stop_distance);
}

pub fn readCtmState() types.CtmState {
    return world.readCtmState();
}

pub fn jump() void {
    jump_or_ascend_start();
}

pub fn walkStart(dir: types.WalkDir) void {
    switch (dir) {
        .forward => move_forward_start(),
        .backward => move_backward_start(),
        .strafe_left => strafe_left_start(),
        .strafe_right => strafe_right_start(),
    }
}

pub fn walkStop(dir: types.WalkDir) void {
    switch (dir) {
        .forward => move_forward_stop(),
        .backward => move_backward_stop(),
        .strafe_left => strafe_left_stop(),
        .strafe_right => strafe_right_stop(),
    }
}
