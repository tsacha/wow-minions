const ray = @import("ray");
const gui_snapshot = @import("snapshot.zig");
const map = @import("map.zig");
const gui_command = @import("gui_command");
const lua_output_mod = @import("../lua_output.zig");

const target_fps = 60;
const window_title = "WoW Mastermind";

const font_bytes = @embedFile("assets/JetBrainsMono-Regular.ttf");

// ASCII (32-126) + Latin-1 Supplement (160-255) + Latin Extended-A (256-383)
const font_codepoints = blk: {
    var cp: [341]c_int = undefined;
    var i = 0;
    var c: c_int = 32;
    while (c <= 126) : (c += 1) {
        cp[i] = c;
        i += 1;
    }
    c = 160;
    while (c <= 383) : (c += 1) {
        cp[i] = c;
        i += 1;
    }
    break :blk cp;
};

pub fn run(publisher: *gui_snapshot.Publisher, cmd_queue: *gui_command.Queue, lua_output: *lua_output_mod.Buffer) void {
    ray.SetTraceLogLevel(ray.LOG_NONE);
    ray.SetConfigFlags(ray.FLAG_WINDOW_RESIZABLE | ray.FLAG_WINDOW_HIGHDPI);
    ray.InitWindow(1280, 720, window_title);
    ray.SetWindowMinSize(1280, 720);
    ray.MaximizeWindow();
    ray.SetWindowFocused();
    ray.SetTargetFPS(target_fps);
    ray.SetExitKey(0);

    const dpi = ray.GetWindowScaleDPI();
    const font_size: c_int = @intFromFloat(32.0 * dpi.x);
    const font = ray.LoadFontFromMemory(".ttf", font_bytes, @intCast(font_bytes.len), font_size, &font_codepoints, font_codepoints.len);
    ray.SetTextureFilter(font.texture, ray.TEXTURE_FILTER_BILINEAR);
    defer ray.UnloadFont(font);

    var view = map.View.init(cmd_queue, font, dpi.x);

    while (!ray.WindowShouldClose()) {
        const snapshot = publisher.read();

        var lua_line_buf: [lua_output_mod.capacity]lua_output_mod.Line = undefined;
        const lua_lines = lua_output.drain(&lua_line_buf);

        view.update(snapshot, lua_lines);
        view.draw(snapshot.entities, snapshot.routes);
    }
}
