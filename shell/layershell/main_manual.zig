//! Low-level manual loop (without dvui.App) — kept for reference.
//! Uses `dvui-layer-shell`'s `initWindow` directly, then drives `dvui.Window` yourself.
//! Prefer the App form in `src/main.zig` for new code.

const std = @import("std");
const dvui = @import("dvui");
const layer_shell = @import("dvui-layer-shell");

var g_backend: ?@import("backend") = null;

pub fn main(init: std.process.Init) !void {
    const layerOpts = layer_shell.LayerShellOpts{
        .anchors = .{ .top, .left, .right, null },
        .padding = .{ 0, 0, 0, 0 },
        .layer = .top,
        .exclusive_zone = 0,
        .namespace = "dvui-layer-example",
    };

    const ctx = try layer_shell.initWindow(.{
        .io = init.io,
        .title = "[bpavuk/mustfloat] SDL layer-shell (manual)",
        .environ_map = init.environ_map,
        .vsync = true,
        .size = .{ .w = 800, .h = 400 },
        .min_size = .{ .h = 100, .w = 200 },
        .transparent = true,
    }, layerOpts, init.gpa);
    var backend = ctx.backend;
    g_backend = backend;
    defer backend.deinit();
    defer ctx.waylandCtx.deinit(init.gpa);

    _ = @import("backend").c.SDL_EnableScreenSaver();

    var window_open = true;
    var base_theme = switch (backend.preferredColorScheme() orelse .light) {
        .light => dvui.Theme.builtin.adwaita_light,
        .dark => dvui.Theme.builtin.adwaita_dark,
    };
    // Library's App path does this automatically; manual path must do it yourself.
    base_theme.window.fill = .transparent;

    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = base_theme,
        .open_flag = &window_open,
    });
    defer win.deinit();

    var interrupted = false;
    while (window_open) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        try backend.addAllEvents(&win);
        if (ctx.waylandCtx.should_close) break;
        _ = frame();
        const end_micros = try win.end(.{});
        interrupted = try backend.waitEventTimeout(win.waitTime(end_micros));
    }
}

fn frame() bool {
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .gravity_y = 0.5, .gravity_x = 0.5, .padding = .all(12), .background = false });
    defer outer.deinit();
    var card = dvui.box(@src(), .{}, .{ .gravity_y = 0.5, .gravity_x = 0.5, .background = true, .style = .content, .corners = .all(12), .padding = .all(16), .border = dvui.Rect.all(1), .min_size_content = .{ .w = 300, .h = 100 } });
    defer card.deinit();
    dvui.label(@src(), "Hello (manual)", .{}, .{ .font = .theme(.title), .gravity_x = 0.5 });
    if (dvui.button(@src(), "Click", .{}, .{ .gravity_x = 0.5 })) std.debug.print("Pressed\n", .{});
    return true;
}
