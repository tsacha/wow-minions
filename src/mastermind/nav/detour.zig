const std = @import("std");
const shared = @import("nav_shared");
const proto = @import("protocol");
const types = @import("types");
const registry_mod = @import("registry");

const BotId = types.BotId;
const Registry = registry_mod.Registry;
const BotSnapshot = registry_mod.BotSnapshot;

pub const pathfinding_enabled = shared.pathfinding_enabled;
pub const NavigateCommand = shared.NavigateCommand;
pub const route_max_points = shared.route_max_points;
pub const RoutePoint = shared.RoutePoint;
pub const RouteSnapshot = shared.RouteSnapshot;

const c = @cImport({
    @cInclude("detour_bridge.h");
});

const mmaps_dir = "mmaps";

const mmap_magic: u32 = 0x4D4D4150;
const mmap_version: u32 = 8;

const max_mmap_file_bytes: usize = 1 * 1024 * 1024;
const max_mmtile_file_bytes: usize = 64 * 1024 * 1024;

const max_route_points: usize = shared.route_max_points;
const route_completion_epsilon_m: f32 = 0.001;
const max_tile_layer_index: u8 = 99;
const min_tile_filename_len: usize = 14;
const tile_map_id_prefix_len: usize = 3;
const waypoint_arrival_xy_radius_m: f32 = 2.0;
const waypoint_reached_dist_sq: f32 = waypoint_arrival_xy_radius_m * waypoint_arrival_xy_radius_m;
const waypoint_advance_lead_xy_radius_m: f32 = 3.0;
const waypoint_advance_lead_dist_sq: f32 = waypoint_advance_lead_xy_radius_m * waypoint_advance_lead_xy_radius_m;
const append_tail_advance_min_sq: f32 = 0.04;
const append_goal_progress_min_world_units: f32 = 5.0;
const append_pending_goal_dedupe_eps_sq: f32 = 0.25;
const no_progress_dist_sq: f32 = 0.25;
const stuck_repath_ticks: u16 = 25;
const world_tile_size: f32 = 533.333_3;
const world_tile_origin: f32 = 32.0;
const direct_route_max_world_units: f32 = world_tile_size;
const direct_route_max_dist_sq: f32 = direct_route_max_world_units * direct_route_max_world_units;
const ctm_target_match_dist_sq: f32 = 4.0;
const issue_retry_ms: u32 = 500;
const issue_refresh_ms: u32 = 2000;
const manual_cancel_grace_ms: u32 = 300;

const initial_tile_radius: i32 = 1;
const max_tile_radius: i32 = 6;
const extended_tile_radius_max: i32 = 12;
const overlay_tile_radius: i32 = 1;
const chunk_step_world_units: f32 = 160.0;
const chunk_min_step_world_units: f32 = 40.0;
const chunk_max_steps: usize = 24;
const chunk_steps_per_call: usize = 1;
const chunk_tile_radius_max: i32 = 2;
const chunk_step_scales = [_]f32{ 1.0, 0.66, 0.4, 0.25 };
const pending_commands_per_tick: usize = 1;
const overlay_retained_tile_budget: usize = 220;
const overlay_route_lookahead_points: usize = 64;
const overlay_route_stride: usize = 2;
const overlay_route_tile_radius: i32 = 1;

const TileHeader = extern struct {
    mmap_magic: u32,
    dt_version: u32,
    mmap_version: u32,
    size: u32,
    uses_liquids: u32,
};

const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

const Route = struct {
    bot_id: BotId,
    map_id: u32,
    goal: Vec3,
    waypoints: [max_route_points]RoutePoint,
    waypoint_count: u16,
    next_waypoint: u16,
    last_dist_sq: f32,
    no_progress_ticks: u16,
    last_issue_time_ms: u32,
    last_dispatched_waypoint: u16,
    saw_non_idle_for_waypoint: bool,
};

const RouteSlot = struct {
    active: bool = false,
    route: Route = undefined,
};

const MapNav = struct {
    ctx: *c.mb_detour_ctx,
    loaded_tiles: std.AutoHashMap(u64, void),
    attempted_tiles: std.AutoHashMap(u64, void),
    nav_segments: std.ArrayListUnmanaged(NavSegment),
    nav_segments_dirty: bool,
};

pub const navmesh_snapshot_max_segments: usize = 180_000;

pub const NavSegmentSnapshot = struct {
    map_id: u32,
    ax: f32,
    ay: f32,
    az: f32,
    bx: f32,
    by: f32,
    bz: f32,
};

const NavSegment = struct {
    ax: f32,
    ay: f32,
    az: f32,
    bx: f32,
    by: f32,
    bz: f32,
};

pub const Navigator = struct {
    allocator: std.mem.Allocator,
    maps: std.AutoHashMap(u32, MapNav),
    missing_maps: std.AutoHashMap(u32, void),
    routes: [types.max_bots]RouteSlot,
    pending_cmds: [types.max_bots]NavigateCommand,
    pending_count: usize,

    const AppendResult = enum {
        not_applicable,
        appended,
        failed,
    };

    pub fn init(allocator: std.mem.Allocator) Navigator {
        return .{
            .allocator = allocator,
            .maps = std.AutoHashMap(u32, MapNav).init(allocator),
            .missing_maps = std.AutoHashMap(u32, void).init(allocator),
            .routes = [_]RouteSlot{.{}} ** types.max_bots,
            .pending_cmds = undefined,
            .pending_count = 0,
        };
    }

    pub fn deinit(self: *Navigator) void {
        var it = self.maps.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.loaded_tiles.deinit();
            entry.value_ptr.attempted_tiles.deinit();
            entry.value_ptr.nav_segments.deinit(self.allocator);
            c.mb_detour_ctx_destroy(entry.value_ptr.ctx);
        }
        self.maps.deinit();
        self.missing_maps.deinit();
    }

    /// Drops queued `navigate_to` commands that include any of these bots and clears their active routes.
    pub fn cancelRoutesForBots(self: *Navigator, bot_ids: []const BotId) void {
        prunePendingNavigateTouchingBots(self, bot_ids);
        for (bot_ids) |id| {
            if (types.isZeroBotId(&id)) continue;
            clearRoute(self, &id);
        }
    }

    pub fn setDestinations(self: *Navigator, io: std.Io, registry: *Registry, bots: []const BotSnapshot, cmd: NavigateCommand) void {
        _ = bots;

        const incoming_targets = @min(@as(usize, @intCast(cmd.bot_count)), cmd.bot_ids.len);
        prunePendingNavigateTouchingBots(self, cmd.bot_ids[0..incoming_targets]);

        if (!cmd.append) {
            for (cmd.bot_ids[0..incoming_targets]) |bot_id| {
                if (types.isZeroBotId(&bot_id)) continue;
                clearRoute(self, &bot_id);
                _ = registry.dispatch(io, .ctm_stop, &[_]BotId{bot_id});
            }
        }

        for (cmd.bot_ids[0..incoming_targets]) |bot_id| {
            if (types.isZeroBotId(&bot_id)) continue;

            if (self.pending_count >= self.pending_cmds.len) {
                std.log.warn("nav: pending queue full, navigate_to dropped map={}", .{cmd.map_id});
                return;
            }

            var bot_cmd = cmd;
            bot_cmd.bot_ids = std.mem.zeroes(@TypeOf(bot_cmd.bot_ids));
            bot_cmd.bot_ids[0] = bot_id;
            bot_cmd.bot_count = 1;
            self.pending_cmds[self.pending_count] = bot_cmd;
            self.pending_count += 1;
        }
        std.log.info("nav: queued navigate_to map={} bots={} append={} dst=({d:.1},{d:.1},{d:.1})", .{ cmd.map_id, cmd.bot_count, cmd.append, cmd.x, cmd.y, cmd.z });
    }

    fn processOnePendingCmd(self: *Navigator, io: std.Io, registry: *Registry, bots: []const BotSnapshot) void {
        if (self.pending_count == 0) return;

        const cmd = self.pending_cmds[0];
        var i: usize = 0;
        while (i + 1 < self.pending_count) : (i += 1) {
            self.pending_cmds[i] = self.pending_cmds[i + 1];
        }
        self.pending_count -= 1;

        const target_count = @min(@as(usize, @intCast(cmd.bot_count)), cmd.bot_ids.len);
        if (target_count == 0) return;

        const goal: Vec3 = .{ .x = cmd.x, .y = cmd.y, .z = cmd.z };
        std.log.info("nav: processing navigate_to map={} bots={} append={} dst=({d:.1},{d:.1},{d:.1})", .{ cmd.map_id, target_count, cmd.append, goal.x, goal.y, goal.z });

        for (cmd.bot_ids[0..target_count]) |bot_id| {
            if (types.isZeroBotId(&bot_id)) continue;
            const bot = registry_mod.findBotSnapshot(bots, &bot_id) orelse {
                std.log.warn("nav: bot snapshot not found (not world_ready or disconnected)", .{});
                continue;
            };
            if (bot.state.map_id != cmd.map_id) {
                std.log.warn("nav: bot map mismatch bot_map={} cmd_map={}", .{ bot.state.map_id, cmd.map_id });
                continue;
            }

            const map = self.getOrLoadMap(io, cmd.map_id) catch |err| {
                std.log.err("nav: load map {} failed: {}", .{ cmd.map_id, err });
                clearRoute(self, &bot_id);
                continue;
            };

            if (cmd.append) {
                switch (self.tryAppendDestination(io, &bot_id, bot.state, cmd.map_id, map, goal)) {
                    .appended => {
                        self.maybeQueueContinuation(&bot_id, cmd.map_id, goal);
                        continue;
                    },
                    .failed => continue,
                    .not_applicable => {},
                }
            }

            clearRoute(self, &bot_id);
            const stop_targets = [_]BotId{bot_id};
            _ = registry.dispatch(io, .ctm_stop, &stop_targets);

            var route = self.computeRouteWithTileLoads(io, cmd.map_id, map, bot.state, goal) orelse {
                std.log.warn("nav: no route found start=({d:.1},{d:.1},{d:.1}) dst=({d:.1},{d:.1},{d:.1}) map={}", .{ bot.state.x, bot.state.y, bot.state.z, goal.x, goal.y, goal.z, cmd.map_id });
                clearRoute(self, &bot_id);
                continue;
            };
            route.bot_id = bot_id;
            route.map_id = cmd.map_id;

            const is_partial = route.waypoint_count > 0 and
                distanceSq(route.waypoints[route.waypoint_count - 1].x, route.waypoints[route.waypoint_count - 1].y, goal.x, goal.y) > waypoint_reached_dist_sq;

            if (upsertRoute(self, route)) {
                const wp = route.waypoints[route.next_waypoint];
                std.log.info("nav: route ready points={} partial={} first_wp=({d:.1},{d:.1},{d:.1})", .{ route.waypoint_count, is_partial, wp.x, wp.y, wp.z });
                if (is_partial) {
                    self.queueAppend(&bot_id, cmd.map_id, goal);
                }
            } else {
                std.log.warn("nav: route dropped (no free route slot)", .{});
            }
        }
    }

    fn queueAppend(self: *Navigator, bot_id: *const BotId, map_id: u32, goal: Vec3) void {
        if (self.pending_count >= self.pending_cmds.len) return;

        if (self.pending_count > 0) {
            const last = self.pending_cmds[self.pending_count - 1];
            if (last.append and
                @as(usize, @intCast(last.bot_count)) >= 1 and
                std.mem.eql(u8, &last.bot_ids[0], bot_id) and
                last.map_id == map_id and
                goalsNearlyEqual(last.x, last.y, last.z, goal.x, goal.y, goal.z))
            {
                return;
            }
        }

        var cmd: NavigateCommand = undefined;
        cmd.bot_ids = std.mem.zeroes(@TypeOf(cmd.bot_ids));
        cmd.bot_ids[0] = bot_id.*;
        cmd.bot_count = 1;
        cmd.append = true;
        cmd.map_id = map_id;
        cmd.x = goal.x;
        cmd.y = goal.y;
        cmd.z = goal.z;
        self.pending_cmds[self.pending_count] = cmd;
        self.pending_count += 1;
    }

    fn queueRepath(self: *Navigator, bot_id: *const BotId, map_id: u32, goal: Vec3) void {
        if (self.pending_count >= self.pending_cmds.len) return;
        var cmd: NavigateCommand = undefined;
        cmd.bot_ids = std.mem.zeroes(@TypeOf(cmd.bot_ids));
        cmd.bot_ids[0] = bot_id.*;
        cmd.bot_count = 1;
        cmd.append = false;
        cmd.map_id = map_id;
        cmd.x = goal.x;
        cmd.y = goal.y;
        cmd.z = goal.z;
        self.pending_cmds[self.pending_count] = cmd;
        self.pending_count += 1;
    }

    fn maybeQueueContinuation(self: *Navigator, bot_id: *const BotId, map_id: u32, goal: Vec3) void {
        const slot = findRouteSlot(self, bot_id) orelse return;
        if (slot.route.waypoint_count == 0) return;
        const tail = slot.route.waypoints[slot.route.waypoint_count - 1];
        if (distanceSq(tail.x, tail.y, goal.x, goal.y) > waypoint_reached_dist_sq) {
            self.queueAppend(bot_id, map_id, goal);
        }
    }

    fn tryAppendDestination(self: *Navigator, io: std.Io, bot_id: *const BotId, state: proto.State, map_id: u32, map: *MapNav, goal: Vec3) AppendResult {
        const slot = findRouteSlot(self, bot_id) orelse return .not_applicable;
        if (slot.route.map_id != map_id) return .not_applicable;

        const tail = if (slot.route.waypoint_count > 0)
            slot.route.waypoints[slot.route.waypoint_count - 1]
        else
            RoutePoint{ .x = state.x, .y = state.y, .z = state.z };

        var start_state = state;
        start_state.x = tail.x;
        start_state.y = tail.y;
        start_state.z = tail.z;

        const extension = self.computeRouteWithTileLoads(io, map_id, map, start_state, goal) orelse {
            std.log.warn("nav: append failed no route tail=({d:.1},{d:.1},{d:.1}) dst=({d:.1},{d:.1},{d:.1})", .{ tail.x, tail.y, tail.z, goal.x, goal.y, goal.z });
            return .failed;
        };

        const ext_n: usize = extension.waypoint_count;
        const cand_tail = extension.waypoints[ext_n - 1];
        const goal_close = distanceSq3(cand_tail.x, cand_tail.y, cand_tail.z, goal.x, goal.y, goal.z) <= waypoint_reached_dist_sq;
        const moved_along = extensionAddsProgressVsTail(tail, &slot.route, extension);
        if (!goal_close and !moved_along) {
            std.log.warn("nav: append rejected no tail advance tail=({d:.1},{d:.1},{d:.1}) cand=({d:.1},{d:.1},{d:.1})", .{ tail.x, tail.y, tail.z, cand_tail.x, cand_tail.y, cand_tail.z });
            return .failed;
        }
        if (!goal_close and !extensionReducesGoalDistance(tail, cand_tail, goal)) {
            std.log.warn("nav: append rejected no goal progress tail=({d:.1},{d:.1},{d:.1}) cand=({d:.1},{d:.1},{d:.1}) dst=({d:.1},{d:.1},{d:.1})", .{ tail.x, tail.y, tail.z, cand_tail.x, cand_tail.y, cand_tail.z, goal.x, goal.y, goal.z });
            return .failed;
        }

        if (!appendRoutePoints(&slot.route, extension)) {
            std.log.warn("nav: append dropped route full", .{});
            return .failed;
        }

        if (slot.route.next_waypoint < slot.route.waypoint_count) {
            const wp = slot.route.waypoints[slot.route.next_waypoint];
            std.log.info("nav: route extended points={} next_wp=({d:.1},{d:.1},{d:.1})", .{ slot.route.waypoint_count, wp.x, wp.y, wp.z });
        }

        return .appended;
    }

    pub fn tick(self: *Navigator, io: std.Io, registry: *Registry, bots: []const BotSnapshot) void {
        var processed: usize = 0;
        while (self.pending_count > 0 and processed < pending_commands_per_tick) : (processed += 1) {
            self.processOnePendingCmd(io, registry, bots);
        }

        for (&self.routes) |*slot| {
            if (!slot.active) continue;

            const bot = registry_mod.findBotSnapshot(bots, &slot.route.bot_id) orelse {
                slot.active = false;
                continue;
            };

            if (bot.state.map_id != slot.route.map_id) {
                slot.active = false;
                continue;
            }

            if (slot.route.next_waypoint >= slot.route.waypoint_count) {
                const remaining_goal_dist_sq = distanceSq(bot.state.x, bot.state.y, slot.route.goal.x, slot.route.goal.y);
                if (remaining_goal_dist_sq > waypoint_reached_dist_sq) {
                    self.queueRepath(&slot.route.bot_id, slot.route.map_id, slot.route.goal);
                }
                slot.active = false;
                continue;
            }

            if (slot.route.last_dispatched_waypoint == slot.route.next_waypoint and
                bot.state.ctm_action != @intFromEnum(proto.CtmAction.idle))
            {
                slot.route.saw_non_idle_for_waypoint = true;
            }

            var waypoint_advanced = false;
            while (slot.route.next_waypoint < slot.route.waypoint_count) {
                const wp = slot.route.waypoints[slot.route.next_waypoint];
                const dsq = distanceSq(bot.state.x, bot.state.y, wp.x, wp.y);
                if (dsq > waypoint_advance_lead_dist_sq) break;

                slot.route.next_waypoint += 1;
                waypoint_advanced = true;
            }

            if (slot.route.next_waypoint >= slot.route.waypoint_count) {
                const remaining_goal_dist_sq = distanceSq(bot.state.x, bot.state.y, slot.route.goal.x, slot.route.goal.y);
                if (remaining_goal_dist_sq > waypoint_reached_dist_sq) {
                    self.queueRepath(&slot.route.bot_id, slot.route.map_id, slot.route.goal);
                }
                slot.active = false;
                continue;
            }

            const current_target = slot.route.waypoints[slot.route.next_waypoint];
            const dist_sq = distanceSq(bot.state.x, bot.state.y, current_target.x, current_target.y);

            if (slot.route.last_dist_sq - dist_sq > no_progress_dist_sq) {
                slot.route.no_progress_ticks = 0;
            } else {
                slot.route.no_progress_ticks +%= 1;
            }
            slot.route.last_dist_sq = dist_sq;

            if (slot.route.no_progress_ticks >= stuck_repath_ticks) {
                std.log.info("nav: bot stuck, stop + repath dst=({d:.1},{d:.1},{d:.1})", .{ slot.route.goal.x, slot.route.goal.y, slot.route.goal.z });
                const stuck_targets = [_]BotId{slot.route.bot_id};
                _ = registry.dispatch(io, .ctm_stop, &stuck_targets);
                self.queueRepath(&slot.route.bot_id, slot.route.map_id, slot.route.goal);
                slot.active = false;
                continue;
            }

            const elapsed_ms = bot.state.game_time_ms -% slot.route.last_issue_time_ms;
            if (slot.route.last_dispatched_waypoint == slot.route.next_waypoint and
                slot.route.saw_non_idle_for_waypoint and
                bot.state.ctm_action == @intFromEnum(proto.CtmAction.idle) and
                dist_sq > waypoint_reached_dist_sq and
                elapsed_ms >= manual_cancel_grace_ms)
            {
                std.log.info("nav: route canceled (movement stopped) bot dist={d:.1}", .{@sqrt(dist_sq)});
                slot.active = false;
                continue;
            }

            const ctm_target_dist_sq = distanceSq(bot.state.ctm_x, bot.state.ctm_y, current_target.x, current_target.y);
            const ctm_target_matches = ctm_target_dist_sq <= ctm_target_match_dist_sq;

            var should_issue = waypoint_advanced or slot.route.last_dispatched_waypoint != slot.route.next_waypoint;
            if (!should_issue and slot.route.last_dispatched_waypoint == slot.route.next_waypoint) {
                if (bot.state.ctm_action == @intFromEnum(proto.CtmAction.idle) and
                    !slot.route.saw_non_idle_for_waypoint and
                    elapsed_ms >= issue_retry_ms)
                {
                    should_issue = true;
                } else if (elapsed_ms >= issue_refresh_ms and
                    !(bot.state.ctm_action == @intFromEnum(proto.CtmAction.idle) and slot.route.saw_non_idle_for_waypoint))
                {
                    should_issue = true;
                } else if (!ctm_target_matches and bot.state.ctm_action != @intFromEnum(proto.CtmAction.idle)) {
                    should_issue = true;
                }
            }

            if (should_issue) {
                _ = self.issueCurrentWaypoint(io, registry, bot.state.game_time_ms, &slot.route.bot_id);
            }
        }
    }

    pub fn ensureOverlayForBots(self: *Navigator, io: std.Io, bots: []const BotSnapshot) void {
        var seen_maps: [types.max_bots]u32 = undefined;
        var seen_count: usize = 0;

        for (bots) |bot| {
            const map_id = bot.state.map_id;
            if (containsMapId(seen_maps[0..seen_count], map_id)) continue;

            if (seen_count < seen_maps.len) {
                seen_maps[seen_count] = map_id;
                seen_count += 1;
            }

            const map = self.getOrLoadMap(io, map_id) catch |err| {
                if (err == error.MapUnavailable or err == error.FileNotFound) continue;
                std.log.warn("nav: overlay map load failed map={} err={}", .{ map_id, err });
                continue;
            };

            const bot_pos: Vec3 = .{ .x = bot.state.x, .y = bot.state.y, .z = bot.state.z };
            const tile = tileCoordForPos(bot_pos);
            self.ensureTilesAround(io, map_id, map, tile.tx, tile.ty, overlay_tile_radius) catch |err| {
                std.log.warn("nav: overlay tile preload failed map={} tx={} ty={} err={}", .{ map_id, tile.tx, tile.ty, err });
                continue;
            };

            self.trimMapToOverlayWindow(io, map_id, map, bots) catch |err| {
                std.log.warn("nav: overlay trim failed map={} err={}", .{ map_id, err });
            };
        }
    }

    pub fn snapshotRoutes(self: *const Navigator, out: *[types.max_bots]RouteSnapshot) usize {
        var count: usize = 0;

        for (self.routes) |slot| {
            if (!slot.active) continue;
            if (count >= out.len) break;

            out[count] = .{
                .bot_id = slot.route.bot_id,
                .map_id = slot.route.map_id,
                .waypoint_count = slot.route.waypoint_count,
                .next_waypoint = slot.route.next_waypoint,
                .waypoints = slot.route.waypoints,
            };
            count += 1;
        }

        return count;
    }

    pub fn snapshotNavSegmentsForBots(self: *Navigator, bots: []const BotSnapshot, out: *[navmesh_snapshot_max_segments]NavSegmentSnapshot) usize {
        var map_ids: [types.max_bots]u32 = undefined;
        var map_count: usize = 0;

        for (bots) |bot| {
            const map_id = bot.state.map_id;
            if (containsMapId(map_ids[0..map_count], map_id)) continue;

            if (map_count < map_ids.len) {
                map_ids[map_count] = map_id;
                map_count += 1;
            }
        }

        var count: usize = 0;

        for (map_ids[0..map_count]) |map_id| {
            const map = self.maps.getPtr(map_id) orelse continue;
            if (map.nav_segments_dirty) {
                self.rebuildMapNavSegments(map) catch |err| {
                    std.log.warn("nav: rebuild mesh overlay failed map={} err={}", .{ map_id, err });
                    map.nav_segments.clearRetainingCapacity();
                };
                map.nav_segments_dirty = false;
            }

            for (map.nav_segments.items) |seg| {
                if (count >= out.len) return count;
                out[count] = .{
                    .map_id = map_id,
                    .ax = seg.ax,
                    .ay = seg.ay,
                    .az = seg.az,
                    .bx = seg.bx,
                    .by = seg.by,
                    .bz = seg.bz,
                };
                count += 1;
            }
        }

        return count;
    }

    fn rebuildMapNavSegments(self: *Navigator, map: *MapNav) !void {
        const raw = try self.allocator.alloc(c.mb_detour_segment, navmesh_snapshot_max_segments);
        defer self.allocator.free(raw);

        var raw_count: c_int = 0;
        if (c.mb_detour_ctx_collect_segments(map.ctx, raw.ptr, navmesh_snapshot_max_segments, &raw_count) == 0) {
            return error.NavMeshCollectFailed;
        }

        const count: usize = @intCast(@max(raw_count, 0));
        map.nav_segments.clearRetainingCapacity();
        try map.nav_segments.ensureTotalCapacity(self.allocator, count);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const s = raw[i];
            map.nav_segments.appendAssumeCapacity(.{
                .ax = s.ax,
                .ay = s.ay,
                .az = s.az,
                .bx = s.bx,
                .by = s.by,
                .bz = s.bz,
            });
        }
    }

    fn issueCurrentWaypoint(self: *Navigator, io: std.Io, registry: *Registry, game_time_ms: u32, bot_id: *const BotId) bool {
        for (&self.routes) |*slot| {
            if (!slot.active) continue;
            if (!std.mem.eql(u8, &slot.route.bot_id, bot_id)) continue;
            if (slot.route.next_waypoint >= slot.route.waypoint_count) return false;

            const wp = slot.route.waypoints[slot.route.next_waypoint];
            const target_slice = [_]BotId{slot.route.bot_id};
            const sent = registry.dispatch(io, .{ .ctm_move = .{ .x = wp.x, .y = wp.y, .z = wp.z } }, &target_slice);
            if (sent == 0) {
                std.log.warn("nav: failed to dispatch ctm_move (queue closed?)", .{});
                return false;
            }

            slot.route.last_dispatched_waypoint = slot.route.next_waypoint;
            slot.route.last_issue_time_ms = game_time_ms;
            slot.route.saw_non_idle_for_waypoint = false;
            return true;
        }

        return false;
    }

    fn computeRouteWithTileLoads(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, state: proto.State, goal: Vec3) ?Route {
        const start = Vec3{ .x = state.x, .y = state.y, .z = state.z };
        const route_dist_sq = distanceSq3(start.x, start.y, start.z, goal.x, goal.y, goal.z);
        if (route_dist_sq > direct_route_max_dist_sq) {
            if (self.computeRouteChunked(io, map_id, map, state, goal)) |route| {
                return route;
            }

            std.log.warn("nav: no long route prefix found map={} start=({d:.1},{d:.1},{d:.1}) dst=({d:.1},{d:.1},{d:.1})", .{ map_id, state.x, state.y, state.z, goal.x, goal.y, goal.z });
            return null;
        }

        if (self.computeRouteRadiusSweepInRange(io, map_id, map, state, goal, initial_tile_radius, max_tile_radius)) |route| {
            return route;
        }

        std.log.warn("nav: path not found after radius sweep map={} start=({d:.1},{d:.1},{d:.1}) dst=({d:.1},{d:.1},{d:.1})", .{ map_id, state.x, state.y, state.z, goal.x, goal.y, goal.z });

        if (self.computeRouteChunked(io, map_id, map, state, goal)) |route| {
            return route;
        }

        if (max_tile_radius < extended_tile_radius_max) {
            if (self.computeRouteRadiusSweepInRange(io, map_id, map, state, goal, max_tile_radius + 1, extended_tile_radius_max)) |route| {
                std.log.info("nav: route found after extended tile radius points={}", .{route.waypoint_count});
                return route;
            }
        }

        std.log.warn("nav: no route found (chunked fallback failed) map={} start=({d:.1},{d:.1},{d:.1}) dst=({d:.1},{d:.1},{d:.1})", .{ map_id, state.x, state.y, state.z, goal.x, goal.y, goal.z });

        return null;
    }

    fn computeRouteRadiusSweep(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, state: proto.State, goal: Vec3) ?Route {
        return self.computeRouteRadiusSweepInRange(io, map_id, map, state, goal, initial_tile_radius, max_tile_radius);
    }

    fn computeRouteRadiusSweepInRange(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, state: proto.State, goal: Vec3, radius_min: i32, radius_max: i32) ?Route {
        var radius: i32 = radius_min;
        while (radius <= radius_max) : (radius += 1) {
            self.ensureTilesForPath(io, map_id, map, .{ .x = state.x, .y = state.y, .z = state.z }, goal, radius) catch |err| {
                std.log.err("nav: ensureTilesForPath failed radius={} map={} err={}", .{ radius, map_id, err });
                return null;
            };

            if (computeRoute(map.ctx, state, goal)) |route| {
                return route;
            }
        }

        return null;
    }

    fn computeRouteChunked(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, state: proto.State, goal: Vec3) ?Route {
        return self.computeRouteChunkedN(io, map_id, map, state, goal, chunk_steps_per_call);
    }

    fn computeRouteChunkedN(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, state: proto.State, goal: Vec3, max_steps: usize) ?Route {
        var cursor_state = state;
        var cursor = Vec3{ .x = state.x, .y = state.y, .z = state.z };
        var route_acc: ?Route = null;
        var step_index: usize = 0;

        while (step_index < max_steps) : (step_index += 1) {
            const dx = goal.x - cursor.x;
            const dy = goal.y - cursor.y;
            const dz = goal.z - cursor.z;
            const remaining_dist = @sqrt(dx * dx + dy * dy + dz * dz);
            if (remaining_dist <= route_completion_epsilon_m) break;

            const base_step = @min(chunk_step_world_units, remaining_dist);
            var segment_opt: ?Route = null;

            for (chunk_step_scales) |scale| {
                var step_world = base_step * scale;
                if (remaining_dist > chunk_min_step_world_units and step_world < chunk_min_step_world_units) {
                    step_world = chunk_min_step_world_units;
                }
                step_world = @min(step_world, remaining_dist);
                if (step_world <= 0.0) continue;

                const ratio = step_world / remaining_dist;
                const segment_goal: Vec3 = .{
                    .x = cursor.x + dx * ratio,
                    .y = cursor.y + dy * ratio,
                    .z = cursor.z + dz * ratio,
                };
                if (distanceSq(cursor.x, cursor.y, segment_goal.x, segment_goal.y) <= no_progress_dist_sq) continue;

                cursor_state.x = cursor.x;
                cursor_state.y = cursor.y;
                cursor_state.z = cursor.z;

                const segment = self.computeRouteRadiusSweepInRange(io, map_id, map, cursor_state, segment_goal, initial_tile_radius, chunk_tile_radius_max) orelse continue;
                if (segment.waypoint_count == 0) continue;

                const segment_tail = segment.waypoints[segment.waypoint_count - 1];
                if (distanceSq(cursor.x, cursor.y, segment_tail.x, segment_tail.y) <= no_progress_dist_sq) continue;

                segment_opt = segment;
                break;
            }

            const segment = segment_opt orelse break;
            if (segment.waypoint_count == 0) break;

            const segment_tail = segment.waypoints[segment.waypoint_count - 1];
            if (distanceSq(cursor.x, cursor.y, segment_tail.x, segment_tail.y) <= no_progress_dist_sq) break;

            if (route_acc) |*acc| {
                if (!appendRoutePoints(acc, segment)) break;
            } else {
                route_acc = segment;
            }

            cursor = .{ .x = segment_tail.x, .y = segment_tail.y, .z = segment_tail.z };

            if (distanceSq(cursor.x, cursor.y, goal.x, goal.y) <= waypoint_reached_dist_sq) {
                var result = route_acc orelse return null;
                result.goal = goal;
                std.log.info("nav: chunked route ready points={} steps={}", .{ result.waypoint_count, step_index + 1 });
                return result;
            }
        }

        if (route_acc) |route| {
            var result = route;
            result.goal = goal;

            if (route.next_waypoint < route.waypoint_count) {
                const tail = route.waypoints[route.waypoint_count - 1];
                std.log.warn("nav: chunked route partial points={} tail=({d:.1},{d:.1},{d:.1}) dst=({d:.1},{d:.1},{d:.1})", .{ route.waypoint_count, tail.x, tail.y, tail.z, goal.x, goal.y, goal.z });
                return result;
            }
        }

        return null;
    }

    fn ensureTilesForPath(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, start: Vec3, goal: Vec3, radius: i32) !void {
        const start_tile = tileCoordForPos(start);
        const goal_tile = tileCoordForPos(goal);
        const corridor_radius = radius;

        std.log.info("nav: tile centers start=({},{}) goal=({},{}) radius={}", .{ start_tile.tx, start_tile.ty, goal_tile.tx, goal_tile.ty, radius });

        try self.ensureTilesAlongSegment(io, map_id, map, start_tile, goal_tile, corridor_radius);
        try self.ensureTilesAround(io, map_id, map, start_tile.tx, start_tile.ty, radius);
        try self.ensureTilesAround(io, map_id, map, goal_tile.tx, goal_tile.ty, radius);
    }

    fn ensureTilesAlongSegment(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, start_tile: TileCoord, goal_tile: TileCoord, radius: i32) !void {
        const dx = goal_tile.tx - start_tile.tx;
        const dy = goal_tile.ty - start_tile.ty;
        const step_count = @max(@as(usize, @intCast(@abs(dx))), @as(usize, @intCast(@abs(dy))));

        if (step_count == 0) {
            try self.ensureTilesAround(io, map_id, map, start_tile.tx, start_tile.ty, radius);
            return;
        }

        var prev_tx: i32 = std.math.minInt(i32);
        var prev_ty: i32 = std.math.minInt(i32);

        var step: usize = 0;
        while (step <= step_count) : (step += 1) {
            const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(step_count));
            const txf = @as(f32, @floatFromInt(start_tile.tx)) + @as(f32, @floatFromInt(dx)) * t;
            const tyf = @as(f32, @floatFromInt(start_tile.ty)) + @as(f32, @floatFromInt(dy)) * t;
            const tx: i32 = @intFromFloat(@round(txf));
            const ty: i32 = @intFromFloat(@round(tyf));

            if (tx == prev_tx and ty == prev_ty) continue;

            try self.ensureTilesAround(io, map_id, map, tx, ty, radius);
            prev_tx = tx;
            prev_ty = ty;
        }
    }

    fn ensureTilesAround(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, tile_x: i32, tile_y: i32, radius: i32) !void {
        var dy: i32 = -radius;
        while (dy <= radius) : (dy += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                try self.ensureTileLoaded(io, map_id, map, tile_x + dx, tile_y + dy);
            }
        }
    }

    fn ensureTileLoaded(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, tile_x: i32, tile_y: i32) !void {
        const key = tileKey(tile_x, tile_y);
        if (map.attempted_tiles.contains(key)) return;

        const loaded_any = try self.loadTilesAtCoords(io, map_id, map, tile_x, tile_y);

        if (loaded_any) {
            try map.loaded_tiles.put(key, {});
        }
        try map.attempted_tiles.put(key, {});
    }

    fn loadTilesAtCoords(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, tile_x: i32, tile_y: i32) !bool {
        const tx_u8: u8 = std.math.cast(u8, tile_x) orelse {
            std.log.warn("nav: tile_x out of range map={} x={}", .{ map_id, tile_x });
            return false;
        };
        const ty_u8: u8 = std.math.cast(u8, tile_y) orelse {
            std.log.warn("nav: tile_y out of range map={} y={}", .{ map_id, tile_y });
            return false;
        };

        var map_prefix_buf: [4]u8 = undefined;
        const map_prefix = try std.fmt.bufPrint(&map_prefix_buf, "{d:0>3}", .{map_id});

        var dir = try std.Io.Dir.cwd().openDir(io, mmaps_dir, .{ .iterate = true });
        defer dir.close(io);

        var loaded_any = false;
        var loaded_count: usize = 0;
        var name_buf: [24]u8 = undefined;
        const base_name = try std.fmt.bufPrint(&name_buf, "{s}{d:0>2}{d:0>2}.mmtile", .{ map_prefix, tx_u8, ty_u8 });
        if (try self.tryLoadTile(io, dir, map, base_name)) {
            loaded_any = true;
            loaded_count += 1;
        }

        var layer: u8 = 0;
        while (layer <= max_tile_layer_index) : (layer += 1) {
            const layer_name = try std.fmt.bufPrint(&name_buf, "{s}{d:0>2}{d:0>2}_{d:0>2}.mmtile", .{ map_prefix, tx_u8, ty_u8, layer });
            if (try self.tryLoadTile(io, dir, map, layer_name)) {
                loaded_any = true;
                loaded_count += 1;
            }
        }

        if (loaded_count > 0) {
            std.log.info("nav: loaded {} tile file(s) map={} tx={} ty={}", .{ loaded_count, map_id, tile_x, tile_y });
        }

        return loaded_any;
    }

    fn tryLoadTile(self: *Navigator, io: std.Io, dir: std.Io.Dir, map: *MapNav, name: []const u8) !bool {
        loadTile(io, self.allocator, dir, name, map.ctx) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };

        map.nav_segments_dirty = true;

        return true;
    }

    fn trimMapToOverlayWindow(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, bots: []const BotSnapshot) !void {
        if (map.loaded_tiles.count() <= overlay_retained_tile_budget) return;

        var desired_tiles = std.AutoHashMap(u64, void).init(self.allocator);
        defer desired_tiles.deinit();

        for (bots) |bot| {
            if (bot.state.map_id != map_id) continue;

            const tile = tileCoordForPos(.{ .x = bot.state.x, .y = bot.state.y, .z = bot.state.z });
            try addTileWindow(&desired_tiles, tile, overlay_tile_radius);
        }

        for (self.routes) |slot| {
            if (!slot.active) continue;
            if (slot.route.map_id != map_id) continue;
            if (slot.route.next_waypoint >= slot.route.waypoint_count) continue;

            const start_idx: usize = slot.route.next_waypoint;
            const end_idx: usize = @min(@as(usize, slot.route.waypoint_count), start_idx + overlay_route_lookahead_points);
            var idx = start_idx;
            while (idx < end_idx) : (idx += overlay_route_stride) {
                const wp = slot.route.waypoints[idx];
                const tile = tileCoordForPos(.{ .x = wp.x, .y = wp.y, .z = wp.z });
                try addTileWindow(&desired_tiles, tile, overlay_route_tile_radius);
            }
        }

        if (desired_tiles.count() == 0) return;
        if (loadedTilesSubsetOfDesired(map, &desired_tiles)) return;

        try self.rebuildMapWithDesiredTiles(io, map_id, map, &desired_tiles);
    }

    fn rebuildMapWithDesiredTiles(self: *Navigator, io: std.Io, map_id: u32, map: *MapNav, desired_tiles: *const std.AutoHashMap(u64, void)) !void {
        const new_ctx = try self.createContextForMap(io, map_id);
        errdefer c.mb_detour_ctx_destroy(new_ctx);

        var staged: MapNav = .{
            .ctx = new_ctx,
            .loaded_tiles = std.AutoHashMap(u64, void).init(self.allocator),
            .attempted_tiles = std.AutoHashMap(u64, void).init(self.allocator),
            .nav_segments = .empty,
            .nav_segments_dirty = true,
        };
        errdefer staged.loaded_tiles.deinit();
        errdefer staged.attempted_tiles.deinit();
        errdefer staged.nav_segments.deinit(self.allocator);

        var it = desired_tiles.iterator();
        while (it.next()) |entry| {
            const tile = tileCoordFromKey(entry.key_ptr.*);
            const loaded_any = try self.loadTilesAtCoords(io, map_id, &staged, tile.tx, tile.ty);
            if (loaded_any) {
                try staged.loaded_tiles.put(entry.key_ptr.*, {});
            }
            try staged.attempted_tiles.put(entry.key_ptr.*, {});
        }

        const staged_count = staged.loaded_tiles.count();
        if (staged_count == 0) {
            staged.loaded_tiles.deinit();
            staged.attempted_tiles.deinit();
            staged.nav_segments.deinit(self.allocator);
            c.mb_detour_ctx_destroy(staged.ctx);
            return;
        }

        const old_count = map.loaded_tiles.count();
        const old_ctx = map.ctx;
        var old_loaded_tiles = map.loaded_tiles;
        var old_attempted_tiles = map.attempted_tiles;
        var old_segments = map.nav_segments;

        map.* = staged;

        old_loaded_tiles.deinit();
        old_attempted_tiles.deinit();
        old_segments.deinit(self.allocator);
        c.mb_detour_ctx_destroy(old_ctx);

        std.log.info("nav: overlay tile window map={} kept={} was={}", .{ map_id, staged_count, old_count });
    }

    fn createContextForMap(self: *Navigator, io: std.Io, map_id: u32) !*c.mb_detour_ctx {
        const ctx = c.mb_detour_ctx_create() orelse return error.NavAllocFailed;
        errdefer c.mb_detour_ctx_destroy(ctx);

        var dir = try std.Io.Dir.cwd().openDir(io, mmaps_dir, .{ .iterate = true });
        defer dir.close(io);

        var mmap_name_buf: [16]u8 = undefined;
        const mmap_name = try std.fmt.bufPrint(&mmap_name_buf, "{d:0>3}.mmap", .{map_id});
        const mmap_params = dir.readFileAlloc(io, mmap_name, self.allocator, .limited(max_mmap_file_bytes)) catch |err| {
            if (err == error.FileNotFound) {
                self.missing_maps.put(map_id, {}) catch {};
            }
            return err;
        };
        defer self.allocator.free(mmap_params);

        const params_size = c.mb_detour_navmesh_params_size();
        if (params_size == 0 or mmap_params.len < params_size) return error.BadMmapParams;
        if (c.mb_detour_ctx_init_from_params(ctx, mmap_params.ptr, params_size) == 0) return error.DetourInitFailed;

        return ctx;
    }

    fn getOrLoadMap(self: *Navigator, io: std.Io, map_id: u32) !*MapNav {
        if (self.maps.getPtr(map_id)) |map| return map;
        if (self.missing_maps.contains(map_id)) return error.MapUnavailable;

        const ctx = try self.createContextForMap(io, map_id);
        std.log.info("nav: mmap loaded map={}", .{map_id});

        try self.maps.put(map_id, .{
            .ctx = ctx,
            .loaded_tiles = std.AutoHashMap(u64, void).init(self.allocator),
            .attempted_tiles = std.AutoHashMap(u64, void).init(self.allocator),
            .nav_segments = .empty,
            .nav_segments_dirty = true,
        });
        return self.maps.getPtr(map_id).?;
    }
};

const TileCoord = struct { tx: i32, ty: i32 };

fn tileCoordForPos(pos: Vec3) TileCoord {
    const tx: i32 = @intFromFloat(@floor(world_tile_origin - (pos.x / world_tile_size)));
    const ty: i32 = @intFromFloat(@floor(world_tile_origin - (pos.y / world_tile_size)));
    return .{ .tx = tx, .ty = ty };
}

fn tileKey(tile_x: i32, tile_y: i32) u64 {
    const x: u32 = @bitCast(tile_x);
    const y: u32 = @bitCast(tile_y);
    return (@as(u64, x) << 32) | @as(u64, y);
}

fn tileCoordFromKey(key: u64) TileCoord {
    const x_u32: u32 = @intCast(key >> 32);
    const y_u32: u32 = @intCast(key & 0xFFFF_FFFF);

    return .{
        .tx = @bitCast(x_u32),
        .ty = @bitCast(y_u32),
    };
}

fn addTileWindow(desired_tiles: *std.AutoHashMap(u64, void), center: TileCoord, radius: i32) !void {
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += 1) {
            try desired_tiles.put(tileKey(center.tx + dx, center.ty + dy), {});
        }
    }
}

fn loadedTilesSubsetOfDesired(map: *const MapNav, desired_tiles: *const std.AutoHashMap(u64, void)) bool {
    if (map.loaded_tiles.count() <= overlay_retained_tile_budget) return true;

    var it = map.loaded_tiles.iterator();
    while (it.next()) |entry| {
        if (!desired_tiles.contains(entry.key_ptr.*)) return false;
    }
    return true;
}

fn parseTwoDigits(a: u8, b: u8) ?u8 {
    if (a < '0' or a > '9') return null;
    if (b < '0' or b > '9') return null;
    return (a - '0') * 10 + (b - '0');
}

fn isTileNameFor(map_prefix: []const u8, tx: u8, ty: u8, name: []const u8) bool {
    if (name.len < min_tile_filename_len) return false;
    if (!std.mem.endsWith(u8, name, ".mmtile")) return false;
    if (!std.mem.eql(u8, name[0..tile_map_id_prefix_len], map_prefix)) return false;

    const file_tx = parseTwoDigits(name[3], name[4]) orelse return false;
    const file_ty = parseTwoDigits(name[5], name[6]) orelse return false;
    if (file_tx != tx or file_ty != ty) return false;

    const marker = name[7];
    if (marker != '.' and marker != '_') return false;

    return true;
}

fn loadTile(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, ctx: *c.mb_detour_ctx) !void {
    const tile_buf = try dir.readFileAlloc(io, name, allocator, .limited(max_mmtile_file_bytes));
    defer allocator.free(tile_buf);

    if (tile_buf.len < @sizeOf(TileHeader)) return error.BadMmapTileHeader;

    const header = std.mem.bytesToValue(TileHeader, tile_buf[0..@sizeOf(TileHeader)]);
    if (header.mmap_magic != mmap_magic) return error.BadMmapTileMagic;
    if (header.mmap_version != mmap_version) return error.BadMmapVersion;
    if (header.dt_version != c.mb_detour_navmesh_version()) return error.BadDetourVersion;

    const payload_len: usize = @intCast(header.size);
    const payload_start = @sizeOf(TileHeader);
    if (payload_len == 0) return error.EmptyMmapTile;
    if (payload_start + payload_len > tile_buf.len) return error.TruncatedMmapTile;

    const payload = tile_buf[payload_start .. payload_start + payload_len];
    if (c.mb_detour_ctx_add_tile_copy(ctx, payload.ptr, payload.len) == 0) {
        return error.DetourAddTileFailed;
    }
}

fn navigateCmdTouchesAnyBot(cmd: *const NavigateCommand, bot_ids: []const BotId) bool {
    const n = @min(@as(usize, @intCast(cmd.bot_count)), cmd.bot_ids.len);
    for (cmd.bot_ids[0..n]) |pb| {
        if (types.isZeroBotId(&pb)) continue;
        for (bot_ids) |tb| {
            if (types.isZeroBotId(&tb)) continue;
            if (std.mem.eql(u8, &pb, &tb)) return true;
        }
    }
    return false;
}

fn prunePendingNavigateTouchingBots(nav: *Navigator, bot_ids: []const BotId) void {
    var w: usize = 0;
    var r: usize = 0;
    while (r < nav.pending_count) : (r += 1) {
        const p = nav.pending_cmds[r];
        if (navigateCmdTouchesAnyBot(&p, bot_ids)) continue;
        if (w != r) nav.pending_cmds[w] = p;
        w += 1;
    }
    nav.pending_count = w;
}

fn findRouteSlot(nav: *Navigator, bot_id: *const BotId) ?*RouteSlot {
    for (&nav.routes) |*slot| {
        if (!slot.active) continue;
        if (std.mem.eql(u8, &slot.route.bot_id, bot_id)) return slot;
    }
    return null;
}

fn extensionMergeSkipCount(route: *const Route, extension: Route) usize {
    const ext_count: usize = extension.waypoint_count;
    if (ext_count > 1) return 1;
    if (route.waypoint_count == 0) return 0;
    const p = extension.waypoints[0];
    const rt = route.waypoints[route.waypoint_count - 1];
    const dup_tail_xy = distanceSq(p.x, p.y, rt.x, rt.y) <= append_tail_advance_min_sq;
    return if (dup_tail_xy) 1 else 0;
}

fn extensionAddsProgressVsTail(tail: RoutePoint, route: *const Route, extension: Route) bool {
    const ext_count: usize = extension.waypoint_count;
    if (ext_count == 0) return false;

    const skip = extensionMergeSkipCount(route, extension);
    var i: usize = skip;
    while (i < ext_count) : (i += 1) {
        const p = extension.waypoints[i];
        if (distanceSq3(tail.x, tail.y, tail.z, p.x, p.y, p.z) > append_tail_advance_min_sq) return true;
    }

    return false;
}

fn extensionReducesGoalDistance(tail: RoutePoint, cand_tail: RoutePoint, goal: Vec3) bool {
    const old_dist = @sqrt(distanceSq3(tail.x, tail.y, tail.z, goal.x, goal.y, goal.z));
    const new_dist = @sqrt(distanceSq3(cand_tail.x, cand_tail.y, cand_tail.z, goal.x, goal.y, goal.z));
    return old_dist - new_dist >= append_goal_progress_min_world_units;
}

fn appendRoutePoints(route: *Route, extension: Route) bool {
    const ext_count: usize = extension.waypoint_count;
    if (ext_count == 0) return false;

    const skip_count: usize = extensionMergeSkipCount(route, extension);

    route.goal = extension.goal;

    if (skip_count >= ext_count) {
        return true;
    }

    const add_count = ext_count - skip_count;
    const current_count: usize = route.waypoint_count;
    if (current_count + add_count > max_route_points) return false;

    var i: usize = 0;
    while (i < add_count) : (i += 1) {
        route.waypoints[current_count + i] = extension.waypoints[skip_count + i];
    }

    route.waypoint_count = @intCast(current_count + add_count);
    return true;
}

fn clearRoute(nav: *Navigator, bot_id: *const BotId) void {
    for (&nav.routes) |*slot| {
        if (!slot.active) continue;
        if (!std.mem.eql(u8, &slot.route.bot_id, bot_id)) continue;
        slot.active = false;
        return;
    }
}

fn upsertRoute(nav: *Navigator, route: Route) bool {
    var free_slot: ?*RouteSlot = null;

    for (&nav.routes) |*slot| {
        if (slot.active and std.mem.eql(u8, &slot.route.bot_id, &route.bot_id)) {
            slot.route = route;
            return true;
        }
        if (!slot.active and free_slot == null) free_slot = slot;
    }

    const slot = free_slot orelse return false;
    slot.active = true;
    slot.route = route;
    return true;
}

fn computeRoute(ctx: *c.mb_detour_ctx, state: proto.State, goal: Vec3) ?Route {
    var points: [max_route_points * 3]f32 = undefined;
    var out_count: c_int = 0;

    const start = [3]f32{ state.x, state.y, state.z };
    const end = [3]f32{ goal.x, goal.y, goal.z };

    if (c.mb_detour_ctx_find_path(ctx, &start, &end, &points, max_route_points, &out_count) == 0) return null;
    if (out_count <= 0) return null;

    const count_u16: u16 = @intCast(@min(@as(usize, @intCast(out_count)), max_route_points));
    if (count_u16 == 0) return null;

    var route = Route{
        .bot_id = std.mem.zeroes(BotId),
        .map_id = state.map_id,
        .goal = goal,
        .waypoints = [_]RoutePoint{.{ .x = 0, .y = 0, .z = 0 }} ** max_route_points,
        .waypoint_count = count_u16,
        .next_waypoint = if (count_u16 > 1) 1 else 0,
        .last_dist_sq = std.math.floatMax(f32),
        .no_progress_ticks = 0,
        .last_issue_time_ms = 0,
        .last_dispatched_waypoint = std.math.maxInt(u16),
        .saw_non_idle_for_waypoint = false,
    };

    var i: usize = 0;
    while (i < count_u16) : (i += 1) {
        const base = i * 3;
        route.waypoints[i] = .{
            .x = points[base],
            .y = points[base + 1],
            .z = points[base + 2],
        };
    }

    if (route.next_waypoint < route.waypoint_count) {
        const wp = route.waypoints[route.next_waypoint];
        route.last_dist_sq = distanceSq(state.x, state.y, wp.x, wp.y);
    }

    return route;
}

fn goalsNearlyEqual(ax: f32, ay: f32, az: f32, bx: f32, by: f32, bz: f32) bool {
    const dx = ax - bx;
    const dy = ay - by;
    const dz = az - bz;
    return dx * dx + dy * dy + dz * dz <= append_pending_goal_dedupe_eps_sq;
}

fn distanceSq(ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = ax - bx;
    const dy = ay - by;
    return dx * dx + dy * dy;
}

fn distanceSq3(ax: f32, ay: f32, az: f32, bx: f32, by: f32, bz: f32) f32 {
    const dx = ax - bx;
    const dy = ay - by;
    const dz = az - bz;
    return dx * dx + dy * dy + dz * dz;
}

fn containsMapId(list: []const u32, map_id: u32) bool {
    for (list) |id| {
        if (id == map_id) return true;
    }
    return false;
}

test "extensionReducesGoalDistance rejects lateral oscillation" {
    const tail = RoutePoint{ .x = -9520.0, .y = -200.1, .z = 55.8 };
    const cand_tail = RoutePoint{ .x = -9520.0, .y = -200.8, .z = 55.8 };
    const goal = Vec3{ .x = -10749.2, .y = -241.2, .z = 52.9 };

    try std.testing.expect(!extensionReducesGoalDistance(tail, cand_tail, goal));
}

test "extensionReducesGoalDistance accepts meaningful goal progress" {
    const tail = RoutePoint{ .x = -9520.0, .y = -200.1, .z = 55.8 };
    const cand_tail = RoutePoint{ .x = -9530.0, .y = -200.4, .z = 55.8 };
    const goal = Vec3{ .x = -10749.2, .y = -241.2, .z = 52.9 };

    try std.testing.expect(extensionReducesGoalDistance(tail, cand_tail, goal));
}
