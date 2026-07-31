const std = @import("std");
const ray = @import("ray");
const scene = @import("scene.zig");
const gui_snapshot = @import("snapshot.zig");
const gui_command = @import("gui_command");
const proto = @import("protocol");
const combat = @import("../combat/mod.zig");
const combat_rage = @import("../combat/rage.zig");
const lua_output_mod = @import("../lua_output.zig");
const repl = @import("../repl.zig");
const map_helpers = @import("map_helpers.zig");
const gui_log = @import("log.zig");

const containsU32 = map_helpers.containsU32;
const insertionSortU32 = map_helpers.insertionSortU32;
const findBotByBotId = map_helpers.findBotByBotId;
const entityGuid = map_helpers.entityGuid;
const isEntityBot = map_helpers.isEntityBot;
const findEntity = map_helpers.findEntity;
const maxThreatOnTarget = map_helpers.maxThreatOnTarget;
const threatForGuidOnTarget = map_helpers.threatForGuidOnTarget;
const collectAggroTable = map_helpers.collectAggroTable;
const findTargetName = map_helpers.findTargetName;
const findPetOwnerName = map_helpers.findPetOwnerName;
const findBotPetName = map_helpers.findBotPetName;
const findTargetUnitFlags = map_helpers.findTargetUnitFlags;
const appendUnitFlagNames = map_helpers.appendUnitFlagNames;
const findGameTime = map_helpers.findGameTime;
const className = map_helpers.className;
const unitReactionStandingName = map_helpers.unitReactionStandingName;
const reactionColor = map_helpers.reactionColor;
const groupKindName = map_helpers.groupKindName;
const shapeshiftFormName = map_helpers.shapeshiftFormName;
const objTypeName = map_helpers.objTypeName;
const ctmActionName = map_helpers.ctmActionName;
const powerTypeName = map_helpers.powerTypeName;
const pointInRectInt = map_helpers.pointInRectInt;
const drawBar = map_helpers.drawBar;
const appendFlag = map_helpers.appendFlag;
const entityColor = map_helpers.entityColor;
const classColor = map_helpers.classColor;
const objectTypeColor = map_helpers.objectTypeColor;

// ─── Palette ─────────────────────────────────────────────────────────────────

const bg_color = ray.Color{ .r = 15, .g = 15, .b = 20, .a = 255 };
const text_color = ray.Color{ .r = 245, .g = 245, .b = 245, .a = 255 };
const center_cross_color = ray.Color{ .r = 60, .g = 120, .b = 255, .a = 255 };
const sel_ring_color = ray.Color{ .r = 0, .g = 200, .b = 0, .a = 255 };
const sel_rect_fill_color = ray.Color{ .r = 0, .g = 200, .b = 0, .a = 40 };
const sel_rect_border_color = ray.Color{ .r = 0, .g = 200, .b = 0, .a = 255 };
const map_label_color = ray.Color{ .r = 255, .g = 200, .b = 80, .a = 255 };
const dead_color = ray.Color{ .r = 80, .g = 60, .b = 60, .a = 255 };

const ctm_line_color = ray.Color{ .r = 0, .g = 200, .b = 0, .a = 160 };
const ctm_dot_gap: f32 = 10.0;
const ctm_dot_radius: f32 = 1.5;
const route_line_color = ray.Color{ .r = 255, .g = 200, .b = 60, .a = 120 };
const route_active_color = ray.Color{ .r = 255, .g = 140, .b = 40, .a = 200 };
const route_line_width: f32 = 2.0;

// ─── Display constants ───────────────────────────────────────────────────────

const bot_radius: f32 = 7.0;
const object_radius: f32 = 4.0;
const bot_selection_ring_offset: f32 = 6.0;
const object_selection_ring_offset: f32 = 4.0;
const facing_line_len: f32 = 24.0;
const facing_line_alpha: u8 = 140;
const facing_line_width: f32 = 2.0;

const sel_drag_threshold: f32 = 4.0;

const hud_selected_y_start: c_int = 28;
const hud_line_spacing: c_int = 10;

const start_fight_btn_w: c_int = 112;
const start_fight_btn_h: c_int = 26;
const start_fight_btn_margin_r: c_int = 8;
const fight_btn_v_gap: c_int = 6;
const formation_btn_y: c_int = 36;
const start_fight_btn_y: c_int = formation_btn_y + start_fight_btn_h + fight_btn_v_gap;
const stop_fight_btn_y: c_int = start_fight_btn_y + start_fight_btn_h + fight_btn_v_gap;
const reset_fight_btn_y: c_int = stop_fight_btn_y + start_fight_btn_h + fight_btn_v_gap;
const raid_buff_btn_y: c_int = reset_fight_btn_y + start_fight_btn_h + fight_btn_v_gap;
const burst_btn_y: c_int = raid_buff_btn_y + start_fight_btn_h + fight_btn_v_gap;

const label_offset_x: c_int = 10;
const bot_selection_label_offset_x: c_int = label_offset_x + bot_selection_ring_offset * 2;
const font_size: c_int = 18;
const center_cross_half_size: c_int = 8;

const grid_step_world_units: i32 = 50;

const zoom_factor: f32 = 1.15;
const initial_range_world_units: f32 = 80.0;
const min_scale: f32 = 0.05;
const max_scale: f32 = 100.0;

const max_label_len = 12;
const max_map_ids = 64;
const max_selection: usize = 256;

// 1 is the WoW shapeshift-form id for the druid cat (feral) form.
const druid_cat_form_id: u32 = 1;
const max_combo_points: u32 = 5;
const totem_slot_count: usize = @typeInfo(proto.TotemElement).@"enum".fields.len;
const max_aura_display_ui: usize = 20;

const hud_buffer_len = 160;
const label_buffer_len = 96;

// ─── Detail panel constants ─────────────────────────────────────────────────

const panel_width_expanded: c_int = 360;
const panel_padding: c_int = 12;
const panel_line_h: c_int = 20;
const panel_section_gap: c_int = 10;
const panel_font_size: c_int = 15;
const panel_heading_font_size: c_int = 20;
const panel_buf_len: usize = 192;
const bar_h: c_int = 10;

const panel_bg = ray.Color{ .r = 25, .g = 25, .b = 35, .a = 230 };
const panel_heading_color = ray.Color{ .r = 255, .g = 220, .b = 100, .a = 255 };
const panel_text_color = ray.Color{ .r = 220, .g = 220, .b = 230, .a = 255 };
const panel_dim_color = ray.Color{ .r = 140, .g = 140, .b = 160, .a = 255 };
const panel_hp_bg = ray.Color{ .r = 80, .g = 20, .b = 20, .a = 255 };
const panel_hp_fg = ray.Color{ .r = 50, .g = 205, .b = 50, .a = 255 };
const panel_power_bg = ray.Color{ .r = 20, .g = 20, .b = 80, .a = 255 };
const panel_power_fg = ray.Color{ .r = 60, .g = 120, .b = 230, .a = 255 };
const panel_bar_border = ray.Color{ .r = 80, .g = 80, .b = 100, .a = 255 };
const rune_blood_color = ray.Color{ .r = 170, .g = 30, .b = 30, .a = 255 };
const rune_unholy_color = ray.Color{ .r = 35, .g = 150, .b = 70, .a = 255 };
const rune_frost_color = ray.Color{ .r = 70, .g = 120, .b = 255, .a = 255 };
const rune_death_color = ray.Color{ .r = 220, .g = 80, .b = 220, .a = 255 };
const rune_unknown_color = panel_dim_color;
const combo_point_filled_color = ray.Color{ .r = 255, .g = 200, .b = 40, .a = 255 };
const combo_point_empty_color = panel_dim_color;
const formation_btn_bg = ray.Color{ .r = 35, .g = 65, .b = 45, .a = 255 };
const formation_btn_hot = ray.Color{ .r = 50, .g = 100, .b = 65, .a = 255 };
const start_fight_btn_bg = ray.Color{ .r = 45, .g = 55, .b = 85, .a = 255 };
const start_fight_btn_hot = ray.Color{ .r = 65, .g = 85, .b = 130, .a = 255 };
const stop_fight_btn_bg = ray.Color{ .r = 75, .g = 35, .b = 40, .a = 255 };
const stop_fight_btn_hot = ray.Color{ .r = 110, .g = 50, .b = 55, .a = 255 };
const reset_fight_btn_bg = ray.Color{ .r = 60, .g = 40, .b = 10, .a = 255 };
const reset_fight_btn_hot = ray.Color{ .r = 100, .g = 70, .b = 20, .a = 255 };
const raid_buff_btn_bg = ray.Color{ .r = 55, .g = 70, .b = 35, .a = 255 };
const raid_buff_btn_hot = ray.Color{ .r = 90, .g = 115, .b = 55, .a = 255 };
const burst_btn_bg = ray.Color{ .r = 90, .g = 40, .b = 85, .a = 255 };
const burst_btn_hot = ray.Color{ .r = 135, .g = 65, .b = 130, .a = 255 };

const cast_bar_bg = ray.Color{ .r = 30, .g = 30, .b = 30, .a = 230 };
const cast_bar_fg = ray.Color{ .r = 30, .g = 200, .b = 30, .a = 255 };
const channel_bar_fg = ray.Color{ .r = 60, .g = 120, .b = 230, .a = 255 };

const map_cast_bar_w: f32 = 42.0;
const map_cast_bar_h: f32 = 6.0;
const map_cast_bar_y_offset: f32 = 20.0;

const map_hp_bar_w_bot: f32 = 32.0;
const map_hp_bar_w_obj: f32 = 18.0;
const map_hp_bar_h: c_int = 3;
const map_pwr_bar_h: c_int = 2;
const map_hp_bar_y_offset_px: f32 = 2.0;
const map_hp_pwr_bar_gap_px: c_int = 1;
const map_hp_bar_bg = ray.Color{ .r = 80, .g = 20, .b = 20, .a = 200 };
const map_hp_bar_fg = ray.Color{ .r = 50, .g = 205, .b = 50, .a = 230 };
const map_pwr_bar_bg = ray.Color{ .r = 20, .g = 20, .b = 60, .a = 200 };
const map_pwr_bar_fg = ray.Color{ .r = 60, .g = 120, .b = 230, .a = 230 };
const combat_ring_color = ray.Color{ .r = 255, .g = 50, .b = 50, .a = 200 };
const combat_ring_radius_offset_px: f32 = 4.0;

const label_bot_y_offset_px: c_int = -2;
const label_bot_size_offset_px: c_int = 4;

// ─── Thaddius polarity ───────────────────────────────────────────────────────

const thaddius_polarity_positive_spell: u32 = 28059;
const thaddius_polarity_negative_spell: u32 = 28084;
const thaddius_polarity_aura_yards: f32 = 14.2;
const polarity_positive_color = ray.Color{ .r = 80, .g = 140, .b = 255, .a = 255 };
const polarity_negative_color = ray.Color{ .r = 255, .g = 70, .b = 70, .a = 255 };
const polarity_positive_ring_color = ray.Color{ .r = 80, .g = 140, .b = 255, .a = 55 };
const polarity_negative_ring_color = ray.Color{ .r = 255, .g = 70, .b = 70, .a = 55 };

const overview_panel_w: c_int = 230;
const overview_row_h: c_int = 24;
const overview_padding: c_int = 6;
const overview_name_w: c_int = 90;
const overview_dot_r: f32 = 3.5;
const overview_name_text_offset_x_px: c_int = 10;
const overview_font_size_reduction_px: c_int = 3;
const overview_bar_y_offset_px: c_int = 2;
const overview_pwr_bar_h_reduction_px: c_int = 2;

const overview_dot_in_combat_color = ray.Color{ .r = 255, .g = 60, .b = 60, .a = 255 };
const overview_dot_out_of_combat_color = ray.Color{ .r = 60, .g = 200, .b = 60, .a = 255 };

// ─── Console constants ───────────────────────────────────────────────────────

const console_font_size: c_int = 15;
const console_line_h: c_int = 20;
const console_history_lines: usize = 8;
const console_height: c_int = console_line_h * (console_history_lines + 1) + 16;
const console_padding: c_int = 8;
const console_bg = ray.Color{ .r = 10, .g = 10, .b = 20, .a = 220 };
const console_border_color = ray.Color{ .r = 80, .g = 80, .b = 120, .a = 255 };
const console_input_color = ray.Color{ .r = 240, .g = 240, .b = 100, .a = 255 };
const console_history_color = ray.Color{ .r = 180, .g = 200, .b = 255, .a = 255 };
const console_result_color = ray.Color{ .r = 120, .g = 230, .b = 120, .a = 255 };
const console_cursor_color = ray.Color{ .r = 240, .g = 240, .b = 100, .a = 200 };
const console_cursor_blink_rate: f32 = 0.5;
const console_backspace_initial_delay: f32 = 0.4;
const console_backspace_repeat_interval: f32 = 0.05;

const ConsoleLine = struct {
    buf: [proto.lua_str_max + 48]u8,
    len: usize,
    is_result: bool,
};

const console_max_history = 64;

// ─── View ─────────────────────────────────────────────────────────────────────

pub const View = struct {
    font: ray.Font,
    dpi: f32,
    center_x: f32,
    center_y: f32,
    scale: f32,
    dragging: bool,
    drag_start_mouse: ray.Vector2,
    drag_start_center_x: f32,
    drag_start_center_y: f32,
    right_drag_active: bool,
    right_drag_start: ray.Vector2,
    follow_bot: bool,
    active_map_id: u32,
    selected_guids: [max_selection]u64,
    selected_count: usize,
    cmd_queue: *gui_command.Queue,
    last_combat_status: gui_snapshot.CombatStatus,
    sel_dragging: bool,
    sel_start: ray.Vector2,
    sel_end: ray.Vector2,
    sel_hit_entity: bool,
    console_open: bool,
    console_input: [gui_command.lua_code_max]u8,
    console_input_len: usize,
    console_history: [console_max_history]ConsoleLine,
    console_history_count: usize,
    console_history_head: usize,
    console_cursor_blink: f32,
    console_backspace_held: f32,
    pub fn init(cmd_queue: *gui_command.Queue, font: ray.Font, dpi: f32) View {
        return .{
            .font = font,
            .dpi = dpi,
            .center_x = 0.0,
            .center_y = 0.0,
            .scale = 0.0,
            .dragging = false,
            .drag_start_mouse = .{ .x = 0.0, .y = 0.0 },
            .drag_start_center_x = 0.0,
            .drag_start_center_y = 0.0,
            .follow_bot = true,
            .active_map_id = 0,
            .selected_guids = [_]u64{0} ** max_selection,
            .selected_count = 0,
            .cmd_queue = cmd_queue,
            .last_combat_status = .{},
            .sel_dragging = false,
            .sel_start = .{ .x = 0.0, .y = 0.0 },
            .sel_end = .{ .x = 0.0, .y = 0.0 },
            .sel_hit_entity = false,
            .right_drag_active = false,
            .right_drag_start = .{ .x = 0.0, .y = 0.0 },
            .console_open = false,
            .console_input = std.mem.zeroes([gui_command.lua_code_max]u8),
            .console_input_len = 0,
            .console_history = undefined,
            .console_history_count = 0,
            .console_history_head = 0,
            .console_cursor_blink = 0.0,
            .console_backspace_held = 0.0,
        };
    }

    fn s(self: *const View, v: c_int) c_int {
        return @intFromFloat(@as(f32, @floatFromInt(v)) * self.dpi);
    }

    fn drawText(self: *const View, text: [*:0]const u8, x: c_int, y: c_int, size: c_int, color: ray.Color) void {
        const spacing: f32 = 1.0;
        const scaled = @as(f32, @floatFromInt(size)) * self.dpi;
        ray.DrawTextEx(self.font, text, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, scaled, spacing, color);
    }

    fn measureText(self: *const View, text: [*:0]const u8, size: c_int) c_int {
        const spacing: f32 = 1.0;
        const scaled = @as(f32, @floatFromInt(size)) * self.dpi;
        const v = ray.MeasureTextEx(self.font, text, scaled, spacing);
        return @intFromFloat(v.x);
    }

    fn isSelected(self: *const View, guid: u64) bool {
        for (self.selected_guids[0..self.selected_count]) |g| {
            if (g == guid) return true;
        }
        return false;
    }

    fn addGuid(self: *View, guid: u64) void {
        if (guid == 0) return;
        if (self.isSelected(guid)) return;
        if (self.selected_count < self.selected_guids.len) {
            self.selected_guids[self.selected_count] = guid;
            self.selected_count += 1;
        }
    }

    fn clearSelection(self: *View) void {
        for (&self.selected_guids) |*g| g.* = 0;
        self.selected_count = 0;
    }

    fn mousePos(self: *const View) ray.Vector2 {
        const m = ray.GetMousePosition();
        return .{ .x = m.x * self.dpi, .y = m.y * self.dpi };
    }

    fn isInsideSelRect(self: View, px: f32, py: f32) bool {
        const x0 = @min(self.sel_start.x, self.sel_end.x);
        const x1 = @max(self.sel_start.x, self.sel_end.x);
        const y0 = @min(self.sel_start.y, self.sel_end.y);
        const y1 = @max(self.sel_start.y, self.sel_end.y);
        return px >= x0 and px <= x1 and py >= y0 and py <= y1;
    }

    // ─── Public API ──────────────────────────────────────────────────────────

    pub fn update(self: *View, snapshot: gui_snapshot.Snapshot, lua_lines: []const lua_output_mod.Line) void {
        self.initScaleIfNeeded();
        self.last_combat_status = snapshot.combat;
        self.ingestLuaLines(lua_lines);
        self.ensureActiveMapHasBot(snapshot.entities);
        if (self.console_open) {
            self.handleConsoleInput(snapshot.entities);
        } else {
            self.handleInput(snapshot.entities);
            self.updateFollow(snapshot.entities);
        }
        if (!self.console_open and (ray.IsKeyPressed(ray.KEY_ENTER) or ray.IsKeyPressed(ray.KEY_KP_ENTER))) self.console_open = true;
        self.console_cursor_blink += ray.GetFrameTime();
        if (self.console_cursor_blink > console_cursor_blink_rate * 2.0)
            self.console_cursor_blink -= console_cursor_blink_rate * 2.0;
    }

    pub fn draw(self: *View, entities: []const scene.Entity, routes: []const gui_snapshot.RouteSnapshot) void {
        ray.BeginDrawing();
        defer ray.EndDrawing();
        ray.ClearBackground(bg_color);

        self.drawCenterCross();
        self.drawRoutes(entities, routes);
        self.drawCtmLines(entities);
        self.drawEntitiesByKind(entities, .object);
        self.drawEntitiesByKind(entities, .bot);
        self.drawSelRect();
        self.drawHud(entities);
        if (self.selected_count != 1) self.drawOverviewPanel(entities);
        self.drawDetailPanel(entities);
        if (self.console_open) self.drawConsole();
    }

    // ─── Console ─────────────────────────────────────────────────────────────

    fn consoleAppend(self: *View, text: []const u8, is_result: bool) void {
        const idx = self.console_history_head % console_max_history;
        const n = @min(text.len, self.console_history[0].buf.len - 1);
        @memcpy(self.console_history[idx].buf[0..n], text[0..n]);
        self.console_history[idx].len = n;
        self.console_history[idx].is_result = is_result;
        self.console_history_head += 1;
        if (self.console_history_count < console_max_history)
            self.console_history_count += 1;
    }

    fn ingestLuaLines(self: *View, lines: []const lua_output_mod.Line) void {
        for (lines) |line| {
            const bot_name = std.mem.sliceTo(&line.bot_id, 0);
            var buf: [proto.lua_str_max + 48]u8 = undefined;
            const result_text = line.text[0..line.len];
            const formatted = std.fmt.bufPrint(&buf, "[{s}] {s}", .{ bot_name, result_text }) catch continue;
            self.consoleAppend(formatted, true);
        }
    }

    fn submitConsoleInput(self: *View, entities: []const scene.Entity) void {
        if (self.console_input_len == 0) return;
        const code_slice = self.console_input[0..self.console_input_len];

        var echo_buf: [proto.lua_str_max + 4]u8 = undefined;
        const echo = std.fmt.bufPrint(&echo_buf, "> {s}", .{code_slice}) catch return;
        self.consoleAppend(echo, false);

        const is_get = std.mem.startsWith(u8, code_slice, "return ");
        // Plain text (no Lua syntax) → wrap as chat via lineToLuaExecChat, like the CLI REPL.
        const looks_like_lua = is_get or std.mem.indexOfScalar(u8, code_slice, '(') != null;

        var cmd: gui_command.GuiCommand = .{ .lua_exec = .{
            .bot_ids = std.mem.zeroes([gui_command.max_ctm_targets]gui_command.BotId),
            .bot_count = 0,
            .code = std.mem.zeroes([gui_command.lua_code_max]u8),
            .is_get = is_get,
        } };

        if (!looks_like_lua) {
            if (!repl.lineToLuaExecChat(&cmd.lua_exec.code, code_slice)) {
                std.log.warn("gui: chat line too long for lua_exec", .{});
                return;
            }
        } else {
            // lua_get expects the expression without "return ".
            const wire_code: []const u8 = if (is_get) code_slice["return ".len..] else code_slice;
            const wire_len = @min(wire_code.len, gui_command.lua_code_max - 1);
            @memcpy(cmd.lua_exec.code[0..wire_len], wire_code[0..wire_len]);
        }

        var n: usize = 0;
        for (self.selected_guids[0..self.selected_count]) |guid| {
            if (n >= gui_command.max_ctm_targets) break;
            const ent = findEntity(entities, guid) orelse continue;
            if (ent.data != .bot) continue;
            cmd.lua_exec.bot_ids[n] = ent.data.bot.bot_id;
            n += 1;
        }
        cmd.lua_exec.bot_count = @intCast(n);

        if (!self.cmd_queue.push(cmd)) {
            std.log.warn("gui: lua_exec dropped (queue full)", .{});
        }
        self.console_input_len = 0;
        @memset(&self.console_input, 0);
    }

    fn consoleTryBackspace(self: *View) void {
        if (self.console_input_len > 0) {
            self.console_input_len -= 1;
            self.console_input[self.console_input_len] = 0;
        }
    }

    fn handleConsoleInput(self: *View, entities: []const scene.Entity) void {
        const dt = ray.GetFrameTime();

        if (ray.IsKeyPressed(ray.KEY_ESCAPE)) {
            self.console_open = false;
            self.console_backspace_held = 0.0;
            return;
        }
        if (ray.IsKeyPressed(ray.KEY_ENTER) or ray.IsKeyPressed(ray.KEY_KP_ENTER)) {
            self.submitConsoleInput(entities);
            self.console_open = false;
            self.console_backspace_held = 0.0;
            return;
        }

        // Backspace with OS-style key repeat (initial delay then interval).
        if (ray.IsKeyDown(ray.KEY_BACKSPACE)) {
            if (ray.IsKeyPressed(ray.KEY_BACKSPACE)) {
                self.consoleTryBackspace();
                self.console_backspace_held = 0.0;
            } else {
                self.console_backspace_held += dt;
                if (self.console_backspace_held > console_backspace_initial_delay) {
                    const repeats: usize = @intFromFloat((self.console_backspace_held - console_backspace_initial_delay) / console_backspace_repeat_interval);
                    const prev_repeats: usize = @intFromFloat((@max(0.0, self.console_backspace_held - dt) - console_backspace_initial_delay) / console_backspace_repeat_interval);
                    if (repeats > prev_repeats) self.consoleTryBackspace();
                }
            }
        } else {
            self.console_backspace_held = 0.0;
        }

        const super = ray.IsKeyDown(ray.KEY_LEFT_SUPER) or ray.IsKeyDown(ray.KEY_RIGHT_SUPER);
        const ctrl = ray.IsKeyDown(ray.KEY_LEFT_CONTROL) or ray.IsKeyDown(ray.KEY_RIGHT_CONTROL);

        // Cmd+C / Ctrl+C — copy current input to clipboard.
        if ((super or ctrl) and ray.IsKeyPressed(ray.KEY_C)) {
            var copy_buf: [gui_command.lua_code_max + 1]u8 = undefined;
            @memcpy(copy_buf[0..self.console_input_len], self.console_input[0..self.console_input_len]);
            copy_buf[self.console_input_len] = 0;
            ray.SetClipboardText(@ptrCast(&copy_buf));
        }

        // Cmd+V / Ctrl+V — paste from system clipboard.
        if ((super or ctrl) and ray.IsKeyPressed(ray.KEY_V)) {
            const clip = ray.GetClipboardText();
            if (clip != null) {
                const text = std.mem.span(clip);
                for (text) |c| {
                    if (c < 32 or c > 126) continue;
                    if (self.console_input_len >= gui_command.lua_code_max - 1) break;
                    self.console_input[self.console_input_len] = c;
                    self.console_input_len += 1;
                }
            }
        }

        var ch = ray.GetCharPressed();
        while (ch != 0) : (ch = ray.GetCharPressed()) {
            if (ch < 32 or ch > 126) continue;
            if (self.console_input_len >= gui_command.lua_code_max - 1) break;
            self.console_input[self.console_input_len] = @intCast(ch);
            self.console_input_len += 1;
        }
    }

    fn drawConsole(self: *View) void {
        const screen_w = ray.GetRenderWidth();
        const screen_h = ray.GetRenderHeight();
        const ch = self.s(console_height);
        const cy = screen_h - ch;
        const cp = self.s(console_padding);
        const lh = self.s(console_line_h);
        const fs = console_font_size;

        ray.DrawRectangle(0, cy, screen_w, ch, console_bg);
        ray.DrawLine(0, cy, screen_w, cy, console_border_color);

        // History lines (oldest first, bottom-up).
        const n_show = @min(self.console_history_count, console_history_lines);
        var i: usize = 0;
        while (i < n_show) : (i += 1) {
            const age = n_show - 1 - i;
            const raw_idx = (self.console_history_head + console_max_history - 1 - age) % console_max_history;
            const line = &self.console_history[raw_idx];
            const line_y = cy + cp + @as(c_int, @intCast(i)) * lh;
            const color = if (line.is_result) console_result_color else console_history_color;
            var buf: [proto.lua_str_max + 50]u8 = undefined;
            if (line.len < buf.len) {
                @memcpy(buf[0..line.len], line.buf[0..line.len]);
                buf[line.len] = 0;
                self.drawText(@ptrCast(&buf), cp, line_y, fs, color);
            }
        }

        // Input line.
        const input_y = cy + cp + @as(c_int, @intCast(n_show)) * lh;
        self.drawText("> ", cp, input_y, fs, console_input_color);
        const prompt_w = self.measureText("> ", fs);

        var input_display: [gui_command.lua_code_max + 1]u8 = undefined;
        @memcpy(input_display[0..self.console_input_len], self.console_input[0..self.console_input_len]);
        input_display[self.console_input_len] = 0;
        self.drawText(@ptrCast(&input_display), cp + prompt_w, input_y, fs, console_input_color);

        // Cursor blink.
        if (self.console_cursor_blink < console_cursor_blink_rate) {
            const input_text_w = self.measureText(@ptrCast(&input_display), fs);
            const cx = cp + prompt_w + input_text_w;
            ray.DrawRectangle(cx, input_y, self.s(2), lh, console_cursor_color);
        }
    }

    // ─── Coordinate transforms ───────────────────────────────────────────────

    fn worldToScreen(self: View, wx: f32, wy: f32) ray.Vector2 {
        const width: f32 = @floatFromInt(ray.GetRenderWidth());
        const height: f32 = @floatFromInt(ray.GetRenderHeight());

        return .{
            .x = width / 2.0 - (wy - self.center_y) * self.scale,
            .y = height / 2.0 - (wx - self.center_x) * self.scale,
        };
    }

    fn screenToWorldX(self: View, sy: f32) f32 {
        const height: f32 = @floatFromInt(ray.GetRenderHeight());
        return self.center_x - (sy - height / 2.0) / self.scale;
    }

    fn screenToWorldY(self: View, sx: f32) f32 {
        const width: f32 = @floatFromInt(ray.GetRenderWidth());
        return self.center_y - (sx - width / 2.0) / self.scale;
    }

    fn isOnScreen(pos: ray.Vector2) bool {
        const width: f32 = @floatFromInt(ray.GetRenderWidth());
        const height: f32 = @floatFromInt(ray.GetRenderHeight());

        return pos.x >= 0.0 and pos.x <= width and pos.y >= 0.0 and pos.y <= height;
    }

    // ─── Initialization ──────────────────────────────────────────────────────

    fn initScaleIfNeeded(self: *View) void {
        if (self.scale != 0.0) return;

        const width: f32 = @floatFromInt(ray.GetRenderWidth());
        self.scale = width / (2.0 * initial_range_world_units);
    }

    // ─── Input handling ───────────────────────────────────────────────────────

    fn handleInput(self: *View, entities: []const scene.Entity) void {
        self.handleZoom();
        self.handleDrag();
        self.handleEntityClick(entities);
        self.handleCtmClick(entities);
        self.handleFollowToggle();
        self.handleMapCycle(entities);
    }

    fn handleZoom(self: *View) void {
        const wheel = ray.GetMouseWheelMove();
        if (wheel > 0.0) {
            self.scale = @min(self.scale * zoom_factor, max_scale);
        } else if (wheel < 0.0) {
            self.scale = @max(self.scale / zoom_factor, min_scale);
        }
    }

    fn handleDrag(self: *View) void {
        if (ray.IsMouseButtonPressed(ray.MOUSE_BUTTON_MIDDLE) or ray.IsMouseButtonPressed(ray.MOUSE_BUTTON_RIGHT)) {
            self.dragging = false;
            self.right_drag_active = false;
            self.drag_start_mouse = self.mousePos();
            self.drag_start_center_x = self.center_x;
            self.drag_start_center_y = self.center_y;
            if (ray.IsMouseButtonPressed(ray.MOUSE_BUTTON_MIDDLE)) {
                self.dragging = true;
                self.follow_bot = false;
            } else {
                self.right_drag_active = true;
            }
        }
        if (ray.IsMouseButtonReleased(ray.MOUSE_BUTTON_MIDDLE)) {
            self.dragging = false;
        }
        if (ray.IsMouseButtonReleased(ray.MOUSE_BUTTON_RIGHT)) {
            self.right_drag_active = false;
        }
        const mouse = self.mousePos();
        if (self.dragging) {
            self.follow_bot = false;
            self.center_x = self.drag_start_center_x + (mouse.y - self.drag_start_mouse.y) / self.scale;
            self.center_y = self.drag_start_center_y + (mouse.x - self.drag_start_mouse.x) / self.scale;
        }
        if (self.right_drag_active) {
            const dx = @abs(mouse.x - self.drag_start_mouse.x);
            const dy = @abs(mouse.y - self.drag_start_mouse.y);
            if (dx > sel_drag_threshold or dy > sel_drag_threshold) {
                self.follow_bot = false;
                self.center_x = self.drag_start_center_x + (mouse.y - self.drag_start_mouse.y) / self.scale;
                self.center_y = self.drag_start_center_y + (mouse.x - self.drag_start_mouse.x) / self.scale;
            }
        }
    }

    fn hitTestEntity(self: *const View, entities: []const scene.Entity, mouse: ray.Vector2) u64 {
        for (entities) |entity| {
            if (entity.data != .bot or entity.map_id != self.active_map_id) continue;

            const screen = self.worldToScreen(entity.data.bot.x, entity.data.bot.y);
            if (!isOnScreen(screen)) continue;

            const dx = mouse.x - screen.x;
            const dy = mouse.y - screen.y;
            const hit_r = bot_radius + bot_selection_ring_offset;

            if (dx * dx + dy * dy <= hit_r * hit_r) {
                return entity.data.bot.guid;
            }
        }

        for (entities) |entity| {
            if (entity.data != .object or entity.map_id != self.active_map_id) continue;

            const screen = self.worldToScreen(entity.data.object.x, entity.data.object.y);
            if (!isOnScreen(screen)) continue;

            const dx = mouse.x - screen.x;
            const dy = mouse.y - screen.y;
            const hit_r = object_radius + object_selection_ring_offset;

            if (dx * dx + dy * dy <= hit_r * hit_r) {
                return entity.data.object.guid;
            }
        }

        return 0;
    }

    fn handleEntityClick(self: *View, entities: []const scene.Entity) void {
        if (ray.IsMouseButtonPressed(ray.MOUSE_BUTTON_LEFT)) {
            const mouse = self.mousePos();
            if (self.tryPushStartFormation(mouse)) return;
            if (self.tryPushStartFight(mouse)) return;
            if (self.tryPushCleanOrders(mouse)) return;
            if (self.tryPushResetFight(mouse)) return;
            if (self.tryPushRaidBuff(mouse, entities)) return;
            if (self.tryPushBurst(mouse, entities)) return;

            const hit_guid = self.hitTestEntity(entities, mouse);

            self.sel_dragging = true;
            self.sel_start = mouse;
            self.sel_end = mouse;
            self.sel_hit_entity = hit_guid != 0;
        }

        if (self.sel_dragging) {
            self.sel_end = self.mousePos();
        }

        if (!ray.IsMouseButtonReleased(ray.MOUSE_BUTTON_LEFT)) return;
        if (!self.sel_dragging) return;
        self.sel_dragging = false;

        const drag_dist_x = @abs(self.sel_end.x - self.sel_start.x);
        const drag_dist_y = @abs(self.sel_end.y - self.sel_start.y);

        const is_box = drag_dist_x > sel_drag_threshold or drag_dist_y > sel_drag_threshold;

        if (is_box) {
            if (!ray.IsKeyDown(ray.KEY_LEFT_CONTROL)) {
                self.clearSelection();
            }
            for (entities) |entity| {
                if (entity.data != .bot or entity.map_id != self.active_map_id) continue;
                const scr = self.worldToScreen(entity.data.bot.x, entity.data.bot.y);
                if (self.isInsideSelRect(scr.x, scr.y)) {
                    self.addGuid(entity.data.bot.guid);
                }
            }
        } else if (self.sel_hit_entity) {
            const hit_guid = self.hitTestEntity(entities, self.sel_start);
            if (hit_guid != 0) {
                if (ray.IsKeyDown(ray.KEY_LEFT_CONTROL)) {
                    if (isEntityBot(entities, hit_guid)) {
                        self.addGuid(hit_guid);
                    }
                } else {
                    self.clearSelection();
                    self.addGuid(hit_guid);
                }
            }
        } else {
            const release = self.sel_end;
            const sw = ray.GetRenderWidth();
            const panel_left = @as(f32, @floatFromInt(sw - self.s(panel_width_expanded)));
            if (release.x >= panel_left) {
                return;
            }
            if (!ray.IsKeyDown(ray.KEY_LEFT_CONTROL)) {
                self.clearSelection();
            }
        }
    }

    fn tryPushStartFormation(self: *View, mouse: ray.Vector2) bool {
        const screen_w = ray.GetRenderWidth();
        const btn_x = screen_w - self.s(start_fight_btn_w) - self.s(start_fight_btn_margin_r);
        if (!pointInRectInt(mouse, btn_x, self.s(formation_btn_y), self.s(start_fight_btn_w), self.s(start_fight_btn_h))) return false;

        self.cmd_queue.pushStartFormation();
        if (gui_log.commandLogEnabled()) std.log.info("gui: start_formation signalled", .{});
        return true;
    }

    fn tryPushStartFight(self: *View, mouse: ray.Vector2) bool {
        const screen_w = ray.GetRenderWidth();
        const btn_x = screen_w - self.s(start_fight_btn_w) - self.s(start_fight_btn_margin_r);
        if (!pointInRectInt(mouse, btn_x, self.s(start_fight_btn_y), self.s(start_fight_btn_w), self.s(start_fight_btn_h))) return false;

        self.cmd_queue.pushStartFight();
        if (gui_log.commandLogEnabled()) std.log.info("gui: start_fight signalled", .{});
        return true;
    }

    fn tryPushCleanOrders(self: *View, mouse: ray.Vector2) bool {
        const screen_w = ray.GetRenderWidth();
        const btn_x = screen_w - self.s(start_fight_btn_w) - self.s(start_fight_btn_margin_r);
        if (!pointInRectInt(mouse, btn_x, self.s(stop_fight_btn_y), self.s(start_fight_btn_w), self.s(start_fight_btn_h))) return false;

        self.cmd_queue.pushCleanOrders();
        if (gui_log.commandLogEnabled()) std.log.info("gui: clean_orders signalled", .{});
        return true;
    }

    fn tryPushResetFight(self: *View, mouse: ray.Vector2) bool {
        const screen_w = ray.GetRenderWidth();
        const btn_x = screen_w - self.s(start_fight_btn_w) - self.s(start_fight_btn_margin_r);
        if (!pointInRectInt(mouse, btn_x, self.s(reset_fight_btn_y), self.s(start_fight_btn_w), self.s(start_fight_btn_h))) return false;

        self.cmd_queue.pushResetFight();
        if (gui_log.commandLogEnabled()) std.log.info("gui: reset_fight signalled", .{});
        return true;
    }

    fn tryPushRaidBuff(self: *View, mouse: ray.Vector2, entities: []const scene.Entity) bool {
        const screen_w = ray.GetRenderWidth();
        const btn_x = screen_w - self.s(start_fight_btn_w) - self.s(start_fight_btn_margin_r);
        if (!pointInRectInt(mouse, btn_x, self.s(raid_buff_btn_y), self.s(start_fight_btn_w), self.s(start_fight_btn_h))) return false;

        self.pushRaidBuffCommand(entities);
        return true;
    }

    fn tryPushBurst(self: *View, mouse: ray.Vector2, entities: []const scene.Entity) bool {
        const screen_w = ray.GetRenderWidth();
        const btn_x = screen_w - self.s(start_fight_btn_w) - self.s(start_fight_btn_margin_r);
        if (!pointInRectInt(mouse, btn_x, self.s(burst_btn_y), self.s(start_fight_btn_w), self.s(start_fight_btn_h))) return false;

        self.pushBurstCommand(entities);
        return true;
    }

    fn pushRaidBuffCommand(self: *View, entities: []const scene.Entity) void {
        var cmd: gui_command.GuiCommand = .{ .operator_spec_action = .{
            .kind = .raid_buff,
            .map_id = self.active_map_id,
            .bot_ids = std.mem.zeroes([gui_command.max_ctm_targets]gui_command.BotId),
            .bot_count = 0,
        } };
        var bot_count: usize = 0;
        var bot_ids = &cmd.operator_spec_action.bot_ids;

        for (entities) |ent| {
            if (bot_count >= gui_command.max_ctm_targets) break;
            if (ent.map_id != self.active_map_id) continue;
            if (ent.data != .bot) continue;
            bot_ids[bot_count] = ent.data.bot.bot_id;
            bot_count += 1;
        }

        cmd.operator_spec_action.bot_count = @intCast(bot_count);
        if (bot_count == 0) return;

        if (!self.cmd_queue.push(cmd)) {
            std.log.warn("gui: operator spell command dropped (queue full)", .{});
            return;
        }
        if (gui_log.commandLogEnabled()) std.log.info("gui: operator spell command signalled", .{});
    }

    fn pushBurstCommand(self: *View, entities: []const scene.Entity) void {
        var cmd: gui_command.GuiCommand = .{ .operator_spec_action = .{
            .kind = .burst,
            .map_id = self.active_map_id,
            .bot_ids = std.mem.zeroes([gui_command.max_ctm_targets]gui_command.BotId),
            .bot_count = 0,
        } };
        var bot_count: usize = 0;
        var bot_ids = &cmd.operator_spec_action.bot_ids;

        for (entities) |ent| {
            if (bot_count >= gui_command.max_ctm_targets) break;
            if (ent.map_id != self.active_map_id) continue;
            if (ent.data != .bot) continue;
            bot_ids[bot_count] = ent.data.bot.bot_id;
            bot_count += 1;
        }

        cmd.operator_spec_action.bot_count = @intCast(bot_count);
        if (bot_count == 0) return;

        if (!self.cmd_queue.push(cmd)) {
            std.log.warn("gui: operator spell command dropped (queue full)", .{});
            return;
        }
        if (gui_log.commandLogEnabled()) std.log.info("gui: operator spell command signalled", .{});
    }

    fn handleCtmClick(self: *View, entities: []const scene.Entity) void {
        if (self.selected_count == 0) return;
        if (!ray.IsMouseButtonReleased(ray.MOUSE_BUTTON_RIGHT)) return;

        const mouse = self.mousePos();
        const drag_dist_x = @abs(mouse.x - self.drag_start_mouse.x);
        const drag_dist_y = @abs(mouse.y - self.drag_start_mouse.y);
        if (drag_dist_x > sel_drag_threshold or drag_dist_y > sel_drag_threshold) return;
        const wx = self.screenToWorldX(mouse.y);
        const wy = self.screenToWorldY(mouse.x);
        const append = ray.IsKeyDown(ray.KEY_LEFT_SHIFT) or ray.IsKeyDown(ray.KEY_RIGHT_SHIFT);

        var bot_ids = [_]gui_command.BotId{std.mem.zeroes(gui_command.BotId)} ** gui_command.max_ctm_targets;
        var bot_count: usize = 0;
        var move_z: f32 = 0.0;

        for (self.selected_guids[0..self.selected_count]) |guid| {
            if (bot_count >= gui_command.max_ctm_targets) break;
            const entity = findEntity(entities, guid) orelse continue;
            if (entity.data == .bot) {
                bot_ids[bot_count] = entity.data.bot.bot_id;
                if (bot_count == 0) move_z = entity.data.bot.z;
                bot_count += 1;
            }
        }

        if (bot_count == 0) return;

        const pushed = self.cmd_queue.push(.{
            .navigate_to = .{
                .bot_ids = bot_ids,
                .bot_count = @intCast(bot_count),
                .append = append,
                .map_id = self.active_map_id,
                .x = wx,
                .y = wy,
                .z = move_z,
            },
        });

        if (!pushed) {
            std.log.warn("gui: navigate_to dropped (queue full)", .{});
            return;
        }

        if (gui_log.commandLogEnabled()) {
            std.log.info("gui: navigate_to queued map={} bots={} append={} dst=({d:.1},{d:.1},{d:.1})", .{ self.active_map_id, bot_count, append, wx, wy, move_z });
        }
    }

    fn handleFollowToggle(self: *View) void {
        if (ray.IsKeyPressed(ray.KEY_SPACE)) {
            self.follow_bot = true;
        }
    }

    fn handleMapCycle(self: *View, entities: []const scene.Entity) void {
        if (ray.IsKeyPressed(ray.KEY_LEFT)) self.cycleMap(entities, -1);
        if (ray.IsKeyPressed(ray.KEY_RIGHT)) self.cycleMap(entities, 1);
    }

    fn cycleMap(self: *View, entities: []const scene.Entity, direction: i32) void {
        var ids: [max_map_ids]u32 = undefined;
        var count: usize = 0;

        // Collect distinct map_ids from bot entities.
        for (entities) |entity| {
            if (entity.data != .bot) continue;
            const mid = entity.map_id;
            if (containsU32(ids[0..count], mid)) continue;
            if (count < ids.len) {
                ids[count] = mid;
                count += 1;
            }
        }

        if (count <= 1) return;

        // Insertion-sort so cycling order is deterministic.
        insertionSortU32(ids[0..count]);

        // Find current index.
        var cur: usize = 0;
        for (ids[0..count], 0..) |id, idx| {
            if (id == self.active_map_id) {
                cur = idx;
                break;
            }
        }

        const next_idx: usize = @intCast(@mod(@as(i64, @intCast(cur)) + direction, @as(i64, @intCast(count))));
        self.active_map_id = ids[next_idx];
        self.follow_bot = true; // Re-center on a bot of the new map.
    }

    fn ensureActiveMapHasBot(self: *View, entities: []const scene.Entity) void {
        var fallback_bot: ?proto.State = null;

        for (entities) |entity| {
            if (entity.data != .bot) continue;
            if (fallback_bot == null) fallback_bot = entity.data.bot;
            if (entity.map_id == self.active_map_id) return;
        }

        const bot = fallback_bot orelse return;
        self.active_map_id = bot.map_id;
        self.center_x = bot.x;
        self.center_y = bot.y;
    }

    fn updateFollow(self: *View, entities: []const scene.Entity) void {
        if (!self.follow_bot) return;

        // Prefer a bot on the active map; fall back to any bot (sets active_map_id).
        for (entities) |entity| {
            if (entity.data != .bot) continue;
            if (entity.map_id != self.active_map_id) continue;
            self.center_x = entity.data.bot.x;
            self.center_y = entity.data.bot.y;
            return;
        }
        for (entities) |entity| {
            if (entity.data != .bot) continue;
            self.center_x = entity.data.bot.x;
            self.center_y = entity.data.bot.y;
            self.active_map_id = entity.map_id;
            return;
        }
    }

    // ─── Rendering ───────────────────────────────────────────────────────────

    fn drawCenterCross(self: View) void {
        const center = self.worldToScreen(self.center_x, self.center_y);
        const x: c_int = @intFromFloat(center.x);
        const y: c_int = @intFromFloat(center.y);

        ray.DrawLine(x - center_cross_half_size, y, x + center_cross_half_size, y, center_cross_color);
        ray.DrawLine(x, y - center_cross_half_size, x, y + center_cross_half_size, center_cross_color);
    }

    fn drawCtmLines(self: *const View, entities: []const scene.Entity) void {
        for (entities) |entity| {
            if (entity.data != .bot or entity.map_id != self.active_map_id) continue;
            const b = entity.data.bot;
            if (b.ctm_action == @intFromEnum(proto.CtmAction.idle)) continue;
            if (b.ctm_x == 0.0 and b.ctm_y == 0.0) continue;

            const from = self.worldToScreen(b.x, b.y);
            const to = self.worldToScreen(b.ctm_x, b.ctm_y);
            const dx = to.x - from.x;
            const dy = to.y - from.y;
            const dist = @sqrt(dx * dx + dy * dy);
            if (dist < 1.0) continue;

            const steps = dist / ctm_dot_gap;
            var i: f32 = 0.0;
            while (i <= steps) : (i += 1.0) {
                const t = if (i > steps) 1.0 else i / steps;
                const px: c_int = @intFromFloat(from.x + dx * t);
                const py: c_int = @intFromFloat(from.y + dy * t);
                ray.DrawCircle(px, py, ctm_dot_radius, ctm_line_color);
            }
        }
    }

    fn drawRoutes(self: *const View, entities: []const scene.Entity, routes: []const gui_snapshot.RouteSnapshot) void {
        for (routes) |route| {
            if (route.map_id != self.active_map_id) continue;
            if (route.waypoint_count < 2) continue;

            var i: usize = 1;
            while (i < route.waypoint_count) : (i += 1) {
                const from = route.waypoints[i - 1];
                const to = route.waypoints[i];
                const from_scr = self.worldToScreen(from.x, from.y);
                const to_scr = self.worldToScreen(to.x, to.y);
                ray.DrawLineEx(from_scr, to_scr, route_line_width, route_line_color);
            }

            if (route.next_waypoint < route.waypoint_count) {
                const next_wp = route.waypoints[route.next_waypoint];
                if (findBotByBotId(entities, route.bot_id)) |bot| {
                    const from_scr = self.worldToScreen(bot.x, bot.y);
                    const to_scr = self.worldToScreen(next_wp.x, next_wp.y);
                    ray.DrawLineEx(from_scr, to_scr, route_line_width + 1.0, route_active_color);
                }
            }
        }
    }

    fn drawSelRect(self: View) void {
        if (!self.sel_dragging) return;

        const x = @min(self.sel_start.x, self.sel_end.x);
        const y = @min(self.sel_start.y, self.sel_end.y);
        const w = @abs(self.sel_end.x - self.sel_start.x);
        const h = @abs(self.sel_end.y - self.sel_start.y);

        ray.DrawRectangle(@intFromFloat(x), @intFromFloat(y), @intFromFloat(w), @intFromFloat(h), sel_rect_fill_color);
        ray.DrawRectangleLines(@intFromFloat(x), @intFromFloat(y), @intFromFloat(w), @intFromFloat(h), sel_rect_border_color);
    }

    fn drawEntitiesByKind(self: View, entities: []const scene.Entity, kind: scene.EntityKind) void {
        for (entities) |entity| {
            if (entity.data != kind or entity.map_id != self.active_map_id) continue;

            const ex: f32 = switch (entity.data) {
                inline else => |d| d.x,
            };
            const ey: f32 = switch (entity.data) {
                inline else => |d| d.y,
            };
            const screen = self.worldToScreen(ex, ey);
            if (!isOnScreen(screen)) continue;

            const polarity = if (entity.data == .bot) botPolarity(entity.data.bot) else .none;
            const color = switch (polarity) {
                .positive => polarity_positive_color,
                .negative => polarity_negative_color,
                .none => entityColor(entities, entity),
            };
            const radius = if (kind == .bot) bot_radius else object_radius;
            const sx: c_int = @intFromFloat(screen.x);
            const sy: c_int = @intFromFloat(screen.y);

            if (polarity != .none) {
                const aura_r = thaddius_polarity_aura_yards * self.scale;
                const ring_color = if (polarity == .positive) polarity_positive_ring_color else polarity_negative_ring_color;
                ray.DrawCircle(sx, sy, aura_r, ring_color);
                ray.DrawCircleLines(sx, sy, aura_r, ring_color);
            }

            ray.DrawCircle(sx, sy, radius, color);

            if (entity.data == .bot and proto.hasUnitFlag(entity.data.bot.unit_flags, .in_combat)) {
                ray.DrawCircleLines(sx, sy, radius + combat_ring_radius_offset_px, combat_ring_color);
            }

            const facing_color = ray.Color{ .r = color.r, .g = color.g, .b = color.b, .a = facing_line_alpha };
            const orientation: f32 = switch (entity.data) {
                inline else => |d| d.orientation,
            };
            if (orientation != 0.0) {
                const end_x = screen.x - @sin(orientation) * facing_line_len;
                const end_y = screen.y - @cos(orientation) * facing_line_len;
                const start = ray.Vector2{ .x = screen.x, .y = screen.y };
                const end = ray.Vector2{ .x = end_x, .y = end_y };
                ray.DrawLineEx(start, end, facing_line_width, facing_color);
            }

            const guid = entityGuid(&entity);
            if (self.isSelected(guid)) {
                const ring_r = if (kind == .bot) bot_radius + bot_selection_ring_offset else object_radius + object_selection_ring_offset;
                ray.DrawCircleLines(sx, sy, ring_r, sel_ring_color);
            }

            const label_x = if (kind == .bot) sx + bot_selection_label_offset_x else sx + label_offset_x;
            self.drawEntityLabel(&entity, label_x, sy - font_size / 2, color);

            self.drawMapEntityBars(&entity, kind, sx, sy);
            self.drawMapCastBar(entities, &entity, kind, sx, sy);
        }
    }

    fn botPolarity(b: proto.State) enum { none, positive, negative } {
        const n = @min(b.player_aura_count, proto.max_auras);
        for (b.player_auras[0..n]) |aura| {
            if (aura.spell_id == thaddius_polarity_positive_spell) return .positive;
            if (aura.spell_id == thaddius_polarity_negative_spell) return .negative;
        }
        return .none;
    }

    fn drawEntityLabel(self: View, entity: *const scene.Entity, x: c_int, y: c_int, color: ray.Color) void {
        var label_buf: [label_buffer_len]u8 = undefined;
        const name = entity.nameSlice();
        const shown_name = name[0..@min(name.len, max_label_len)];
        const label = std.fmt.bufPrintSentinel(&label_buf, "{s}", .{shown_name}, 0) catch return;

        const is_bot = entity.data == .bot;
        const y_offset: c_int = if (is_bot) label_bot_y_offset_px else 0;
        const size_offset: c_int = if (is_bot) label_bot_size_offset_px else 0;

        self.drawText(label.ptr, x, y + y_offset, font_size + size_offset, color);
    }

    fn displayPower(class_id: u32, power: u32) u32 {
        const warrior_class = @intFromEnum(combat.Class.warrior);
        const death_knight_class = @intFromEnum(combat.Class.death_knight);
        return if (class_id == warrior_class or class_id == death_knight_class) combat_rage.toPoints(power) else power;
    }

    fn displayPowerMax(class_id: u32, power_max: u32) u32 {
        const warrior_class = @intFromEnum(combat.Class.warrior);
        const death_knight_class = @intFromEnum(combat.Class.death_knight);
        return if (class_id == warrior_class or class_id == death_knight_class) combat_rage.toPoints(power_max) else power_max;
    }

    fn drawMapEntityBars(self: View, entity: *const scene.Entity, kind: scene.EntityKind, sx: c_int, sy: c_int) void {
        _ = self;
        const hp, const hp_max, const pwr, const pwr_max: u32 = switch (entity.data) {
            .bot => |b| .{ b.hp, b.hp_max, displayPower(b.class, b.active_power), displayPowerMax(b.class, b.active_power_max) },
            .object => |o| blk: {
                if (o.obj_type != 3 and o.obj_type != 4) return;
                break :blk .{ o.hp, o.hp_max, 0, 0 };
            },
        };
        if (hp_max == 0) return;

        const bar_w = if (kind == .bot) map_hp_bar_w_bot else map_hp_bar_w_obj;
        const radius: f32 = if (kind == .bot) bot_radius else object_radius;
        const bar_x: c_int = @intFromFloat(@as(f32, @floatFromInt(sx)) - bar_w / 2.0);
        const bar_y: c_int = @intFromFloat(@as(f32, @floatFromInt(sy)) + radius + map_hp_bar_y_offset_px);
        const bar_wi: c_int = @intFromFloat(bar_w);

        ray.DrawRectangle(bar_x, bar_y, bar_wi, map_hp_bar_h, map_hp_bar_bg);
        if (hp_max > 0) {
            const fill: f32 = @as(f32, @floatFromInt(hp)) / @as(f32, @floatFromInt(hp_max));
            const fw: c_int = @intFromFloat(bar_w * @min(1.0, fill));
            if (fw > 0) ray.DrawRectangle(bar_x, bar_y, fw, map_hp_bar_h, map_hp_bar_fg);
        }

        if (kind == .bot and pwr_max > 0) {
            const pwr_y = bar_y + map_hp_bar_h + map_hp_pwr_bar_gap_px;
            ray.DrawRectangle(bar_x, pwr_y, bar_wi, map_pwr_bar_h, map_pwr_bar_bg);
            const fill: f32 = @as(f32, @floatFromInt(pwr)) / @as(f32, @floatFromInt(pwr_max));
            const fw: c_int = @intFromFloat(bar_w * @min(1.0, fill));
            if (fw > 0) ray.DrawRectangle(bar_x, pwr_y, fw, map_pwr_bar_h, map_pwr_bar_fg);
        }
    }

    fn drawMapCastBar(self: View, entities: []const scene.Entity, entity: *const scene.Entity, kind: scene.EntityKind, sx: c_int, sy: c_int) void {
        _ = self;
        _ = kind;

        const is_casting: bool, const is_channeling: bool, const elapsed_frac: f32 = switch (entity.data) {
            .bot => |b| blk: {
                if (b.is_casting != 0) {
                    const dur = @as(f32, @floatFromInt(b.cast_end_time_ms -| b.cast_start_time_ms));
                    const rem = @as(f32, @floatFromInt(b.cast_end_time_ms -| b.game_time_ms));
                    const frac = if (dur > 0) 1.0 - rem / dur else 0.0;
                    break :blk .{ true, false, frac };
                }
                if (b.is_channeling != 0) {
                    const dur = @as(f32, @floatFromInt(b.channel_end_time_ms -| b.channel_start_time_ms));
                    const rem = @as(f32, @floatFromInt(b.channel_end_time_ms -| b.game_time_ms));
                    const frac = if (dur > 0) rem / dur else 0.0;
                    break :blk .{ false, true, frac };
                }
                break :blk .{ false, false, 0.0 };
            },
            .object => |o| blk: {
                const now = findGameTime(entities);
                if (o.casting_spell_id != 0) {
                    const dur = @as(f32, @floatFromInt(o.cast_end_time_ms -| o.cast_start_time_ms));
                    const rem = @as(f32, @floatFromInt(o.cast_end_time_ms -| now));
                    const frac = if (dur > 0) @max(0.0, 1.0 - rem / dur) else 0.0;
                    break :blk .{ true, false, frac };
                }
                if (o.channel_spell_id != 0) {
                    const dur = @as(f32, @floatFromInt(o.channel_end_time_ms -| o.channel_start_time_ms));
                    const rem = @as(f32, @floatFromInt(o.channel_end_time_ms -| now));
                    const frac = if (dur > 0) @max(0.0, rem / dur) else 0.0;
                    break :blk .{ false, true, frac };
                }
                break :blk .{ false, false, 0.0 };
            },
        };

        if (!is_casting and !is_channeling) return;

        const bx: f32 = @as(f32, @floatFromInt(sx)) - map_cast_bar_w / 2.0;
        const by: f32 = @as(f32, @floatFromInt(sy)) + map_cast_bar_y_offset;
        const bw_i: c_int = @intFromFloat(map_cast_bar_w);
        const bh_i: c_int = @intFromFloat(map_cast_bar_h);

        ray.DrawRectangle(@intFromFloat(bx), @intFromFloat(by), bw_i, bh_i, cast_bar_bg);

        const clamped = @max(0.0, @min(1.0, elapsed_frac));
        const fg = if (is_casting) cast_bar_fg else channel_bar_fg;

        if (is_casting) {
            const fill_w: c_int = @intFromFloat(map_cast_bar_w * clamped);
            if (fill_w > 0) {
                ray.DrawRectangle(@intFromFloat(bx), @intFromFloat(by), fill_w, bh_i, fg);
            }
        } else {
            const fill_w: c_int = @intFromFloat(map_cast_bar_w * clamped);
            if (fill_w > 0) {
                ray.DrawRectangle(@intFromFloat(bx + map_cast_bar_w - @as(f32, @floatFromInt(fill_w))), @intFromFloat(by), fill_w, bh_i, fg);
            }
        }
    }

    fn drawHud(self: *View, entities: []const scene.Entity) void {
        var bot_count: usize = 0;
        var object_count: usize = 0;
        var selected_y: c_int = self.s(hud_selected_y_start);

        for (entities) |entity| {
            if (entity.map_id != self.active_map_id) continue;

            switch (entity.data) {
                .bot => bot_count += 1,
                .object => object_count += 1,
            }
        }

        var hud_buf: [hud_buffer_len]u8 = undefined;
        const width: f32 = @floatFromInt(ray.GetRenderWidth());
        const range = width / (2.0 * self.scale);
        const hud = std.fmt.bufPrintSentinel(
            &hud_buf,
            "bots:{} objs:{} sel:{} center:({d:.0},{d:.0}) range:+/-{d:.0}u scroll=zoom mid-drag=pan L=select R=move space=follow <>=map",
            .{ bot_count, object_count, self.selected_count, self.center_x, self.center_y, range },
            0,
        ) catch return;
        self.drawText(hud.ptr, 8, 8, font_size, text_color);

        for (entities) |entity| {
            if (!self.isSelected(entityGuid(&entity))) continue;

            const name = entity.nameSlice();

            var info_buf: [hud_buffer_len]u8 = undefined;
            const info = switch (entity.data) {
                .bot => |b| std.fmt.bufPrintSentinel(
                    &info_buf,
                    "[BOT] {s} Lvl{d} HP:{d}/{d} {s}:{d}",
                    .{ name, b.level, b.hp, b.hp_max, groupKindName(b.is_in_raid), b.group_size },
                    0,
                ) catch return,
                .object => |o| std.fmt.bufPrintSentinel(
                    &info_buf,
                    "[{s}] {s} Lvl{d} HP:{d}/{d}",
                    .{ objTypeName(o.obj_type), name, o.level, o.hp, o.hp_max },
                    0,
                ) catch return,
            };
            self.drawText(info.ptr, 8, selected_y, font_size, text_color);
            selected_y += self.s(font_size + hud_line_spacing);
        }

        var map_buf: [label_buffer_len]u8 = undefined;
        const map_label = std.fmt.bufPrintSentinel(&map_buf, "map {}", .{self.active_map_id}, 0) catch return;
        const map_width = self.measureText(map_label.ptr, font_size);
        const screen_w = ray.GetRenderWidth();
        self.drawText(map_label.ptr, screen_w - map_width - 8, 8, font_size, map_label_color);

        const btn_w = self.s(start_fight_btn_w);
        const btn_h = self.s(start_fight_btn_h);
        const btn_y_form = self.s(formation_btn_y);
        const btn_y0 = self.s(start_fight_btn_y);
        const btn_y1 = self.s(stop_fight_btn_y);
        const btn_y2 = self.s(reset_fight_btn_y);
        const btn_y3 = self.s(raid_buff_btn_y);
        const btn_y4 = self.s(burst_btn_y);
        const btn_x = screen_w - btn_w - self.s(start_fight_btn_margin_r);
        const mouse = self.mousePos();
        const hot_formation = pointInRectInt(mouse, btn_x, btn_y_form, btn_w, btn_h);
        ray.DrawRectangle(btn_x, btn_y_form, btn_w, btn_h, if (hot_formation) formation_btn_hot else formation_btn_bg);
        ray.DrawRectangleLines(btn_x, btn_y_form, btn_w, btn_h, panel_bar_border);
        self.drawText("Create group", btn_x + self.s(12), btn_y_form + self.s(4), panel_font_size, panel_text_color);

        const hot_start = pointInRectInt(mouse, btn_x, btn_y0, btn_w, btn_h);
        ray.DrawRectangle(btn_x, btn_y0, btn_w, btn_h, if (hot_start) start_fight_btn_hot else start_fight_btn_bg);
        ray.DrawRectangleLines(btn_x, btn_y0, btn_w, btn_h, panel_bar_border);
        self.drawText("Start fight", btn_x + self.s(10), btn_y0 + self.s(4), panel_font_size, panel_text_color);

        const hot_stop = pointInRectInt(mouse, btn_x, btn_y1, btn_w, btn_h);
        ray.DrawRectangle(btn_x, btn_y1, btn_w, btn_h, if (hot_stop) stop_fight_btn_hot else stop_fight_btn_bg);
        ray.DrawRectangleLines(btn_x, btn_y1, btn_w, btn_h, panel_bar_border);
        self.drawText("Clean orders", btn_x + self.s(14), btn_y1 + self.s(4), panel_font_size, panel_text_color);

        const hot_reset = pointInRectInt(mouse, btn_x, btn_y2, btn_w, btn_h);
        ray.DrawRectangle(btn_x, btn_y2, btn_w, btn_h, if (hot_reset) reset_fight_btn_hot else reset_fight_btn_bg);
        ray.DrawRectangleLines(btn_x, btn_y2, btn_w, btn_h, panel_bar_border);
        self.drawText("Reset fight", btn_x + self.s(12), btn_y2 + self.s(4), panel_font_size, panel_text_color);

        const hot_raid_buff = pointInRectInt(mouse, btn_x, btn_y3, btn_w, btn_h);
        ray.DrawRectangle(btn_x, btn_y3, btn_w, btn_h, if (hot_raid_buff) raid_buff_btn_hot else raid_buff_btn_bg);
        ray.DrawRectangleLines(btn_x, btn_y3, btn_w, btn_h, panel_bar_border);
        self.drawText("Raid buff", btn_x + self.s(16), btn_y3 + self.s(4), panel_font_size, panel_text_color);

        const hot_burst = pointInRectInt(mouse, btn_x, btn_y4, btn_w, btn_h);
        ray.DrawRectangle(btn_x, btn_y4, btn_w, btn_h, if (hot_burst) burst_btn_hot else burst_btn_bg);
        ray.DrawRectangleLines(btn_x, btn_y4, btn_w, btn_h, panel_bar_border);
        self.drawText("Burst", btn_x + self.s(30), btn_y4 + self.s(4), panel_font_size, panel_text_color);
    }

    fn findBotIntentLabel(self: *const View, bot_id: [32]u8) []const u8 {
        const count = self.last_combat_status.bot_intent_count;
        for (self.last_combat_status.bot_intents[0..count]) |entry| {
            if (std.mem.eql(u8, &entry.bot_id, &bot_id)) {
                return std.mem.sliceTo(&entry.label, 0);
            }
        }
        return "-";
    }

    fn drawOverviewPanel(self: *const View, entities: []const scene.Entity) void {
        var bot_count: usize = 0;
        for (entities) |e| {
            if (e.data == .bot and e.map_id == self.active_map_id) bot_count += 1;
        }
        if (bot_count == 0) return;

        const screen_h = ray.GetRenderHeight();
        const total_h = @as(c_int, @intCast(bot_count)) * self.s(overview_row_h) + 2 * self.s(overview_padding);
        const panel_w = self.s(overview_panel_w);
        const py = screen_h - total_h;

        ray.DrawRectangle(0, py, panel_w, total_h, panel_bg);
        ray.DrawLine(0, py, panel_w, py, panel_bar_border);
        ray.DrawLine(panel_w, py, panel_w, screen_h, panel_bar_border);

        var row: c_int = 0;
        for (entities) |e| {
            if (e.data != .bot or e.map_id != self.active_map_id) continue;
            const b = e.data.bot;
            const row_y = py + self.s(overview_padding) + row * self.s(overview_row_h);
            const mid_y = row_y + @divTrunc(self.s(overview_row_h), 2);

            const in_combat = proto.hasUnitFlag(b.unit_flags, .in_combat);
            const dot_color = if (b.hp == 0)
                dead_color
            else if (in_combat)
                overview_dot_in_combat_color
            else
                overview_dot_out_of_combat_color;
            ray.DrawCircle(self.s(overview_padding) + @as(c_int, @intFromFloat(overview_dot_r)), mid_y, overview_dot_r, dot_color);

            var name_buf: [14:0]u8 = std.mem.zeroes([14:0]u8);
            const name = e.nameSlice();
            const name_len = @min(name.len, name_buf.len - 1);
            @memcpy(name_buf[0..name_len], name[0..name_len]);
            self.drawText(&name_buf, self.s(overview_padding) + self.s(overview_name_text_offset_x_px), row_y + 2, panel_font_size - overview_font_size_reduction_px, classColor(b.class));

            const bar_x = self.s(overview_name_w);
            const bar_w = panel_w - bar_x - self.s(overview_padding);
            const hp_bar_y = row_y + self.s(overview_bar_y_offset_px);
            const pwr_bar_y = row_y + self.s(overview_bar_y_offset_px) + self.s(bar_h) + self.s(overview_bar_y_offset_px);

            if (bar_w > 0) {
                drawBar(bar_x, hp_bar_y, bar_w, self.s(bar_h), b.hp, b.hp_max, panel_hp_fg, panel_hp_bg);
                if (b.active_power_max > 0) {
                    drawBar(bar_x, pwr_bar_y, bar_w, self.s(bar_h) - overview_pwr_bar_h_reduction_px, b.active_power, b.active_power_max, panel_power_fg, panel_power_bg);
                }
            }

            row += 1;
        }
    }

    fn drawDetailPanel(self: *View, entities: []const scene.Entity) void {
        if (self.selected_count != 1) return;

        const guid = self.selected_guids[0];
        const entity = findEntity(entities, guid) orelse return;

        const screen_w = ray.GetRenderWidth();
        const screen_h = ray.GetRenderHeight();
        const pw = self.s(panel_width_expanded);
        const px = screen_w - pw;
        const inner_w = pw - 2 * self.s(panel_padding);

        ray.DrawRectangle(px, 0, pw, screen_h, panel_bg);
        ray.DrawLine(px, 0, px, screen_h, panel_bar_border);

        var y: c_int = panel_padding;
        var buf: [panel_buf_len]u8 = undefined;

        // Name heading
        const name = entity.nameSlice();
        const heading = std.fmt.bufPrintSentinel(&buf, "{s}", .{name[0..@min(name.len, 24)]}, 0) catch return;
        self.drawText(heading.ptr, px + panel_padding, y, panel_heading_font_size, panel_heading_color);
        y += panel_heading_font_size + panel_section_gap;

        // Type + Level
        const entity_guid = entityGuid(&entity);
        const owner_name = findPetOwnerName(entities, entity_guid);
        if (!std.mem.eql(u8, owner_name, "-") and !std.mem.eql(u8, owner_name, "?")) {
            const owner_line = std.fmt.bufPrintSentinel(&buf, "Owned by {s}", .{owner_name}, 0) catch return;
            self.drawText(owner_line.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
            y += self.s(panel_line_h);
        }

        const type_line = switch (entity.data) {
            .bot => |b| blk: {
                const class = combat.classFromState(b) orelse break :blk std.fmt.bufPrintSentinel(&buf, "{s}  Lvl {}", .{ className(b.class), b.level }, 0) catch return;
                const spec = combat.primarySpec(class, b.talent_points);
                break :blk std.fmt.bufPrintSentinel(&buf, "{s} {s}  Lvl {}", .{ combat.specName(spec), className(b.class), b.level }, 0) catch return;
            },
            .object => |o| std.fmt.bufPrintSentinel(&buf, "{s}  Lvl {}", .{ objTypeName(o.obj_type), o.level }, 0) catch return,
        };
        self.drawText(type_line.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
        y += self.s(panel_line_h);

        if (entity.data == .object and (entity.data.object.obj_type == 3 or entity.data.object.obj_type == 4)) {
            const scan = entity.data.object;
            const rname = unitReactionStandingName(scan.unit_reaction);
            const rline = std.fmt.bufPrintSentinel(&buf, "Reaction: {s} ({d})", .{ rname, scan.unit_reaction }, 0) catch return;
            self.drawText(rline.ptr, px + panel_padding, y, panel_font_size, reactionColor(scan.unit_reaction));
            y += self.s(panel_line_h);
        }

        const combat_line = if (self.last_combat_status.orders_planned == 0)
            std.fmt.bufPrintSentinel(&buf, "Combat: idle", .{}, 0) catch return
        else
            std.fmt.bufPrintSentinel(&buf, "Combat: {}/{} ok", .{ self.last_combat_status.orders_accepted, self.last_combat_status.orders_planned }, 0) catch return;
        const combat_color = if (self.last_combat_status.orders_dropped > 0) panel_hp_bg else panel_dim_color;
        self.drawText(combat_line.ptr, px + panel_padding, y, panel_font_size, combat_color);
        y += self.s(panel_line_h);

        if (entity.data == .bot) {
            const b = entity.data.bot;
            const pet_name = findBotPetName(entities, b.guid);
            if (!std.mem.eql(u8, pet_name, "-") and !std.mem.eql(u8, pet_name, "?")) {
                const pet_line = std.fmt.bufPrintSentinel(&buf, "Pet: {s}", .{pet_name}, 0) catch return;
                self.drawText(pet_line.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                y += self.s(panel_line_h);
            }
        }

        if (entity.data == .bot) {
            const b = entity.data.bot;
            const intent_label = self.findBotIntentLabel(b.bot_id);
            const intent_line = std.fmt.bufPrintSentinel(&buf, "Intent: {s}", .{intent_label}, 0) catch return;
            self.drawText(intent_line.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
            y += self.s(panel_line_h);
        }

        if (entity.data == .bot) {
            const b = entity.data.bot;
            const group_line = std.fmt.bufPrintSentinel(&buf, "Group: {s}  members excl. self: {}", .{ groupKindName(b.is_in_raid), b.group_size }, 0) catch return;
            self.drawText(group_line.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
            y += self.s(panel_line_h);

            const form_line = std.fmt.bufPrintSentinel(&buf, "Form: {s} ({})", .{ shapeshiftFormName(b.class, b.shapeshift_form), b.shapeshift_form }, 0) catch return;
            self.drawText(form_line.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
            y += self.s(panel_line_h);
        }
        y += panel_section_gap;

        // HP bar
        const hp, const hp_max = switch (entity.data) {
            .bot => |b| .{ b.hp, b.hp_max },
            .object => |o| .{ o.hp, o.hp_max },
        };
        const hp_label = std.fmt.bufPrintSentinel(&buf, "HP  {}/{}", .{ hp, hp_max }, 0) catch return;
        self.drawText(hp_label.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
        y += self.s(panel_line_h);
        drawBar(px + panel_padding, y, inner_w, bar_h, hp, hp_max, panel_hp_fg, panel_hp_bg);
        y += bar_h + panel_section_gap;

        // Power bar (bots only)
        if (entity.data == .bot) {
            const b = entity.data.bot;
            const pwr_label = std.fmt.bufPrintSentinel(&buf, "{s}  {}/{}", .{ powerTypeName(b.active_power_type), displayPower(b.class, b.active_power), displayPowerMax(b.class, b.active_power_max) }, 0) catch return;
            self.drawText(pwr_label.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
            y += self.s(panel_line_h);
            drawBar(px + panel_padding, y, inner_w, bar_h, displayPower(b.class, b.active_power), displayPowerMax(b.class, b.active_power_max), panel_power_fg, panel_power_bg);
            y += bar_h + panel_section_gap;

            const is_feral_cat = b.class == @intFromEnum(combat.Class.druid) and b.shapeshift_form == druid_cat_form_id;
            if (b.class == @intFromEnum(combat.Class.rogue) or is_feral_cat) {
                const cp_header = std.fmt.bufPrintSentinel(&buf, "CP: {d}/5", .{b.combo_points}, 0) catch return;
                self.drawText(cp_header.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                y += self.s(panel_line_h);

                const cp_x = px + panel_padding + self.measureText("  ", panel_font_size);
                const cp_step = self.measureText("* ", panel_font_size);
                var cp_i: u32 = 0;
                while (cp_i < max_combo_points) : (cp_i += 1) {
                    const glyph: [2:0]u8 = if (cp_i < b.combo_points) .{ '*', 0 } else .{ '.', 0 };
                    const color = if (cp_i < b.combo_points) combo_point_filled_color else combo_point_empty_color;
                    self.drawText(&glyph, cp_x + @as(c_int, @intCast(cp_i)) * cp_step, y, panel_font_size, color);
                }
                y += self.s(panel_line_h);
                y += panel_section_gap;
            }

            if (b.class == @intFromEnum(combat.Class.shaman)) {
                const display_order = [totem_slot_count]proto.TotemElement{ .earth, .fire, .water, .air };
                const display_chars = [totem_slot_count]u8{ 'E', 'F', 'W', 'A' };
                const totem_active_color = ray.Color{ .r = 100, .g = 200, .b = 255, .a = 255 };
                const totem_step = self.measureText("E ", panel_font_size);
                const totem_x = px + panel_padding + self.measureText("  ", panel_font_size);

                var active_count: u32 = 0;
                for (b.totems) |t| if (t.remaining_ms > 0) {
                    active_count += 1;
                };
                const totem_header = std.fmt.bufPrintSentinel(&buf, "Totems: {d}/4", .{active_count}, 0) catch return;
                self.drawText(totem_header.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                y += self.s(panel_line_h);

                for (display_order, 0..) |elem, i| {
                    const slot = proto.totemSlot(&b.totems, elem);
                    const glyph = [2:0]u8{ display_chars[i], 0 };
                    const color = if (slot.remaining_ms > 0) totem_active_color else panel_dim_color;
                    self.drawText(&glyph, totem_x + @as(c_int, @intCast(i)) * totem_step, y, panel_font_size, color);
                }
                y += self.s(panel_line_h);

                const totem_times = std.fmt.bufPrintSentinel(
                    &buf,
                    "  {d} {d} {d} {d}",
                    .{
                        proto.totemSlot(&b.totems, .earth).remaining_ms / std.time.ms_per_s,
                        proto.totemSlot(&b.totems, .fire).remaining_ms / std.time.ms_per_s,
                        proto.totemSlot(&b.totems, .water).remaining_ms / std.time.ms_per_s,
                        proto.totemSlot(&b.totems, .air).remaining_ms / std.time.ms_per_s,
                    },
                    0,
                ) catch return;
                self.drawText(totem_times.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                y += self.s(panel_line_h);
                y += panel_section_gap;
            }

            if (b.class == @intFromEnum(combat.Class.death_knight)) {
                var ready: u32 = 0;
                var rune_remaining_ms: [6]u32 = undefined;
                var rune_type_chars: [6]u8 = undefined;
                var rune_type_colors: [6]ray.Color = undefined;
                for (b.rune_regen_ms, 0..) |regen_ms, i| {
                    const remaining_ms: u32 = if (regen_ms == 0 or regen_ms <= b.game_time_ms)
                        0
                    else
                        regen_ms - b.game_time_ms;
                    rune_remaining_ms[i] = remaining_ms;
                    if (remaining_ms == 0) ready += 1;

                    const rune_type = b.rune_types[i];
                    rune_type_chars[i] = switch (rune_type) {
                        1 => 'B',
                        2 => 'F',
                        3 => 'U',
                        4 => 'D',
                        else => '?',
                    };
                    rune_type_colors[i] = switch (rune_type) {
                        1 => rune_blood_color,
                        2 => rune_frost_color,
                        3 => rune_unholy_color,
                        4 => rune_death_color,
                        else => rune_unknown_color,
                    };
                }

                const rune_header = std.fmt.bufPrintSentinel(&buf, "Runes: {d}/6 ready", .{ready}, 0) catch return;
                self.drawText(rune_header.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                y += self.s(panel_line_h);

                const rune_x = px + panel_padding + self.measureText("  ", panel_font_size);
                const rune_step = self.measureText("B ", panel_font_size);
                for (rune_type_chars, 0..) |ch, i| {
                    const glyph = [2:0]u8{ ch, 0 };
                    self.drawText(&glyph, rune_x + @as(c_int, @intCast(i)) * rune_step, y, panel_font_size, rune_type_colors[i]);
                }
                y += self.s(panel_line_h);

                const rune_time = std.fmt.bufPrintSentinel(
                    &buf,
                    "  {d} {d} {d} {d} {d} {d}",
                    .{
                        rune_remaining_ms[0],
                        rune_remaining_ms[1],
                        rune_remaining_ms[2],
                        rune_remaining_ms[3],
                        rune_remaining_ms[4],
                        rune_remaining_ms[5],
                    },
                    0,
                ) catch return;
                self.drawText(rune_time.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                y += self.s(panel_line_h);
                y += panel_section_gap;
            }
        }

        // Position
        const pos_x, const pos_y, const pos_z = switch (entity.data) {
            .bot => |b| .{ b.x, b.y, b.z },
            .object => |o| .{ o.x, o.y, o.z },
        };
        const pos_line = std.fmt.bufPrintSentinel(&buf, "X: {d:.1}  Y: {d:.1}  Z: {d:.1}", .{ pos_x, pos_y, pos_z }, 0) catch return;
        self.drawText(pos_line.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
        y += self.s(panel_line_h);

        const map_line = std.fmt.bufPrintSentinel(&buf, "Map: {}", .{entity.map_id}, 0) catch return;
        self.drawText(map_line.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
        y += panel_line_h + panel_section_gap;

        // Target
        const target_guid = switch (entity.data) {
            .bot => |b| b.target_guid,
            .object => |o| o.target_guid,
        };
        const target_name = findTargetName(entities, target_guid);
        const target_line = std.fmt.bufPrintSentinel(&buf, "Target: {s}", .{target_name}, 0) catch return;
        self.drawText(target_line.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
        y += self.s(panel_line_h);

        if (entity.data == .bot) {
            const bot = entity.data.bot;
            const rname = unitReactionStandingName(bot.target_unit_reaction);
            const rline = std.fmt.bufPrintSentinel(&buf, "Reaction: {s} ({d})", .{ rname, bot.target_unit_reaction }, 0) catch return;
            self.drawText(rline.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
            y += self.s(panel_line_h);

            const max_threat = maxThreatOnTarget(entities, bot.target_guid);
            const threat = threatForGuidOnTarget(entities, bot.target_guid, bot.guid);
            const threat_pct: u32 = if (max_threat > 0) threat * 100 / max_threat else 0;
            const threat_line = std.fmt.bufPrintSentinel(&buf, "Threat: {d}%", .{threat_pct}, 0) catch return;
            self.drawText(threat_line.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
            y += self.s(panel_line_h);
        }

        if (entity.data == .object and entity.data.object.obj_type == 3) {
            var aggro_buf: [proto.max_target_threats]map_helpers.AggroEntry = undefined;
            const aggro = collectAggroTable(entities, entity.data.object.guid, &aggro_buf);
            if (aggro.len > 0) {
                self.drawText("Aggro:", px + panel_padding, y, panel_font_size, panel_text_color);
                y += self.s(panel_line_h);

                const max_threat = aggro[0].threat;
                for (aggro[0..@min(aggro.len, 8)]) |entry| {
                    const pct: u32 = if (max_threat > 0) @intCast((@as(u64, entry.threat) * 100) / max_threat) else 0;
                    const unit_name = findTargetName(entities, entry.unit_guid);
                    const aggro_line = std.fmt.bufPrintSentinel(&buf, "  {s}: {d}%", .{ unit_name, pct }, 0) catch return;
                    self.drawText(aggro_line.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                    y += self.s(panel_line_h);
                    if (y > screen_h - panel_padding) break;
                }
            }
        }

        if (target_guid != 0) {
            if (findTargetUnitFlags(entities, target_guid)) |tf| {
                var fbuf: [256]u8 = undefined;
                var fl: usize = 0;
                appendUnitFlagNames(&fbuf, &fl, tf.f, tf.f2);
                if (fl > 0) {
                    fbuf[fl] = 0;
                    const flag_text: [:0]const u8 = fbuf[0..fl :0];
                    self.drawText(flag_text.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                    y += self.s(panel_line_h);
                }
                const tf_hex = std.fmt.bufPrintSentinel(&buf, "Target flags: 0x{X:0>8}", .{tf.f}, 0) catch return;
                self.drawText(tf_hex.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                y += self.s(panel_line_h);
                const tf_hex2 = std.fmt.bufPrintSentinel(&buf, "Target flags2: 0x{X:0>8}", .{tf.f2}, 0) catch return;
                self.drawText(tf_hex2.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                y += self.s(panel_line_h);
            } else {
                const na = std.fmt.bufPrintSentinel(&buf, "Target flags: n/a", .{}, 0) catch return;
                self.drawText(na.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                y += self.s(panel_line_h);
            }
        }

        y += panel_section_gap;

        // Casting
        switch (entity.data) {
            .bot => |b| {
                if (b.is_casting != 0) {
                    const dur_ms = b.cast_end_time_ms -| b.cast_start_time_ms;
                    const rem_ms = b.cast_end_time_ms -| b.game_time_ms;
                    if (dur_ms > 0) {
                        const t = std.fmt.bufPrintSentinel(&buf, "Casting: spell {} ({d}ms, {d}ms left)", .{ b.casting_spell_id, dur_ms, rem_ms }, 0) catch return;
                        self.drawText(t.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                    } else {
                        const t = std.fmt.bufPrintSentinel(&buf, "Casting: spell {}", .{b.casting_spell_id}, 0) catch return;
                        self.drawText(t.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                    }
                    y += self.s(panel_line_h);
                    const cast_target_name = findTargetName(entities, b.target_guid);
                    const ct = std.fmt.bufPrintSentinel(&buf, "  on {s}", .{cast_target_name}, 0) catch return;
                    self.drawText(ct.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                    y += self.s(panel_line_h);
                } else if (b.is_channeling != 0) {
                    const dur_ms = b.channel_end_time_ms -| b.channel_start_time_ms;
                    const rem_ms = b.channel_end_time_ms -| b.game_time_ms;
                    if (dur_ms > 0) {
                        const t = std.fmt.bufPrintSentinel(&buf, "Channeling: spell {} ({d}ms, {d}ms left)", .{ b.channel_spell_id, dur_ms, rem_ms }, 0) catch return;
                        self.drawText(t.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                    } else {
                        const t = std.fmt.bufPrintSentinel(&buf, "Channeling: spell {}", .{b.channel_spell_id}, 0) catch return;
                        self.drawText(t.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                    }
                    y += self.s(panel_line_h);
                    const ch_target_name = findTargetName(entities, b.channel_target_guid);
                    const ct = std.fmt.bufPrintSentinel(&buf, "  on {s}", .{ch_target_name}, 0) catch return;
                    self.drawText(ct.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                    y += self.s(panel_line_h);
                } else {
                    self.drawText("Casting: -", px + panel_padding, y, panel_font_size, panel_dim_color);
                    y += self.s(panel_line_h);
                }

                const ctm_name = ctmActionName(b.ctm_action);
                const ctm_line = std.fmt.bufPrintSentinel(&buf, "CTM: {s}", .{ctm_name}, 0) catch return;
                self.drawText(ctm_line.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                y += self.s(panel_line_h);
            },
            .object => |o| {
                if (o.casting_spell_id != 0) {
                    const dur_ms = o.cast_end_time_ms -| o.cast_start_time_ms;
                    const rem_ms = o.cast_end_time_ms -| findGameTime(entities);
                    if (dur_ms > 0) {
                        const t = std.fmt.bufPrintSentinel(&buf, "Casting: spell {} ({d}ms, {d}ms left)", .{ o.casting_spell_id, dur_ms, rem_ms }, 0) catch return;
                        self.drawText(t.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                    } else {
                        const t = std.fmt.bufPrintSentinel(&buf, "Casting: spell {}", .{o.casting_spell_id}, 0) catch return;
                        self.drawText(t.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                    }
                    y += self.s(panel_line_h);
                    const cast_target_name = findTargetName(entities, o.target_guid);
                    const ct = std.fmt.bufPrintSentinel(&buf, "  on {s}", .{cast_target_name}, 0) catch return;
                    self.drawText(ct.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                    y += self.s(panel_line_h);
                } else if (o.channel_spell_id != 0) {
                    const dur_ms = o.channel_end_time_ms -| o.channel_start_time_ms;
                    const rem_ms = o.channel_end_time_ms -| findGameTime(entities);
                    if (dur_ms > 0) {
                        const t = std.fmt.bufPrintSentinel(&buf, "Channeling: spell {} ({d}ms, {d}ms left)", .{ o.channel_spell_id, dur_ms, rem_ms }, 0) catch return;
                        self.drawText(t.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                    } else {
                        const t = std.fmt.bufPrintSentinel(&buf, "Channeling: spell {}", .{o.channel_spell_id}, 0) catch return;
                        self.drawText(t.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                    }
                    y += self.s(panel_line_h);
                    const ch_target_name = findTargetName(entities, o.target_guid);
                    const ct = std.fmt.bufPrintSentinel(&buf, "  on {s}", .{ch_target_name}, 0) catch return;
                    self.drawText(ct.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                    y += self.s(panel_line_h);
                } else {
                    self.drawText("Casting: -", px + panel_padding, y, panel_font_size, panel_dim_color);
                    y += self.s(panel_line_h);
                }
            },
        }
        y += panel_section_gap;

        // Unit flags
        const flags: u32 = switch (entity.data) {
            .bot => |b| b.unit_flags,
            .object => |o| o.unit_flags,
        };
        const flags2: u32 = switch (entity.data) {
            .bot => |b| b.unit_flags_2,
            .object => |o| o.unit_flags_2,
        };
        {
            var fbuf: [256]u8 = undefined;
            var fl: usize = 0;
            appendUnitFlagNames(&fbuf, &fl, flags, flags2);
            if (fl > 0) {
                fbuf[fl] = 0;
                const flag_text: [:0]const u8 = fbuf[0..fl :0];
                self.drawText(flag_text.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                y += self.s(panel_line_h);
            }
            const hex_line = std.fmt.bufPrintSentinel(&buf, "flags: 0x{X:0>8}", .{flags}, 0) catch return;
            self.drawText(hex_line.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
            y += self.s(panel_line_h);
            const hex2 = std.fmt.bufPrintSentinel(&buf, "flags2: 0x{X:0>8}", .{flags2}, 0) catch return;
            self.drawText(hex2.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
            y += self.s(panel_line_h);
        }
        y += panel_section_gap;

        const aura_line = std.fmt.bufPrintSentinel(&buf, "Auras:", .{}, 0) catch return;
        self.drawText(aura_line.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
        y += self.s(panel_line_h);

        var aura_list: [max_aura_display_ui]struct { spell_id: u32, remaining_ms: u32, stacks: u32 } = undefined;
        var n_aura: usize = 0;

        switch (entity.data) {
            .bot => |b| {
                const count = @min(b.player_aura_count, max_aura_display_ui);
                for (b.player_auras[0..count]) |a| {
                    if (n_aura >= max_aura_display_ui) break;
                    aura_list[n_aura] = .{ .spell_id = a.spell_id, .remaining_ms = a.remaining_ms, .stacks = a.stacks };
                    n_aura += 1;
                }
            },
            .object => |o| {
                const count = @min(o.aura_count, max_aura_display_ui);
                for (o.auras[0..count]) |a| {
                    if (n_aura >= max_aura_display_ui) break;
                    aura_list[n_aura] = .{ .spell_id = a.spell_id, .remaining_ms = a.remaining_ms, .stacks = a.stacks };
                    n_aura += 1;
                }
            },
        }

        if (n_aura == 0) {
            self.drawText("  none", px + panel_padding, y, panel_font_size, panel_dim_color);
        } else {
            for (aura_list[0..n_aura]) |a| {
                const remaining_s = a.remaining_ms / std.time.ms_per_s;
                const aura_txt = if (a.stacks > 1)
                    std.fmt.bufPrintSentinel(&buf, "  {d} x{d}  {d}s", .{ a.spell_id, a.stacks, remaining_s }, 0) catch break
                else
                    std.fmt.bufPrintSentinel(&buf, "  {d}  {d}s", .{ a.spell_id, remaining_s }, 0) catch break;
                self.drawText(aura_txt.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                y += self.s(panel_line_h);
                if (y > screen_h - panel_padding) break;
            }
        }
        y += panel_section_gap;

        if (entity.data == .bot) {
            const b = entity.data.bot;
            const cd_label = std.fmt.bufPrintSentinel(&buf, "Cooldowns ({d}):", .{b.cooldown_count}, 0) catch return;
            self.drawText(cd_label.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
            y += self.s(panel_line_h);

            const cd_count = @min(b.cooldown_count, proto.max_cooldowns);
            if (cd_count == 0) {
                self.drawText("  none", px + panel_padding, y, panel_font_size, panel_dim_color);
            } else {
                var cd_sorted: [proto.max_cooldowns]proto.CooldownEntry = undefined;
                @memcpy(cd_sorted[0..cd_count], b.cooldowns[0..cd_count]);
                std.mem.sort(proto.CooldownEntry, cd_sorted[0..cd_count], {}, struct {
                    fn lessThan(_: void, lhs: proto.CooldownEntry, rhs: proto.CooldownEntry) bool {
                        return lhs.remaining_ms > rhs.remaining_ms;
                    }
                }.lessThan);

                var group_remaining: u32 = std.math.maxInt(u32);
                for (cd_sorted[0..cd_count]) |cd| {
                    if (y > screen_h - panel_padding) break;
                    if (cd.remaining_ms != group_remaining) {
                        group_remaining = cd.remaining_ms;
                        const rem_s = cd.remaining_ms / std.time.ms_per_s;
                        const group_txt = std.fmt.bufPrintSentinel(&buf, "  -- {d}s --", .{rem_s}, 0) catch break;
                        self.drawText(group_txt.ptr, px + panel_padding, y, panel_font_size, panel_dim_color);
                        y += self.s(panel_line_h);
                        if (y > screen_h - panel_padding) break;
                    }
                    const pct: u32 = if (cd.duration_ms > 0)
                        (cd.remaining_ms * 100) / cd.duration_ms
                    else
                        0;
                    const cd_txt = std.fmt.bufPrintSentinel(&buf, "    spell {d}  cat {d}  {d}%", .{ cd.spell_id, cd.category, pct }, 0) catch break;
                    self.drawText(cd_txt.ptr, px + panel_padding, y, panel_font_size, panel_text_color);
                    y += self.s(panel_line_h);
                }
            }
        }
    }
};
