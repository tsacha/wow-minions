const build_options = @import("build_options");
const types = @import("types");
const gui_command = @import("gui_command");

pub const pathfinding_enabled: bool = build_options.pathfinding;
pub const NavigateCommand = @FieldType(gui_command.GuiCommand, "navigate_to");
pub const route_max_points: usize = 256;
pub const RoutePoint = struct {
    x: f32,
    y: f32,
    z: f32,
};
pub const RouteSnapshot = struct {
    bot_id: types.BotId,
    map_id: u32,
    waypoint_count: u16,
    next_waypoint: u16,
    waypoints: [route_max_points]RoutePoint,
};
