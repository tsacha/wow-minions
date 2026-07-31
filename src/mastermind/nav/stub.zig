const std = @import("std");
const shared = @import("nav_shared");
const types = @import("types");

pub const pathfinding_enabled = shared.pathfinding_enabled;
pub const NavigateCommand = shared.NavigateCommand;
pub const route_max_points = shared.route_max_points;
pub const RoutePoint = shared.RoutePoint;
pub const RouteSnapshot = shared.RouteSnapshot;

const registry_mod = @import("registry");
const Registry = registry_mod.Registry;
const BotSnapshot = registry_mod.BotSnapshot;
const BotId = types.BotId;

pub const Navigator = struct {
    pub fn init(allocator: std.mem.Allocator) Navigator {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *Navigator) void {
        _ = self;
    }

    pub fn cancelRoutesForBots(self: *Navigator, bot_ids: []const BotId) void {
        _ = .{ self, bot_ids };
    }

    pub fn setDestinations(self: *Navigator, io: std.Io, registry: *Registry, bots: []const BotSnapshot, cmd: NavigateCommand) void {
        _ = .{ self, io, registry, bots, cmd };
    }

    pub fn tick(self: *Navigator, io: std.Io, registry: *Registry, bots: []const BotSnapshot) void {
        _ = .{ self, io, registry, bots };
    }

    pub fn ensureOverlayForBots(self: *Navigator, io: std.Io, bots: []const BotSnapshot) void {
        _ = .{ self, io, bots };
    }

    pub fn snapshotRoutes(self: *const Navigator, out: *[types.max_bots]RouteSnapshot) usize {
        _ = .{ self, out };
        return 0;
    }
};
