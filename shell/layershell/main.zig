const std = @import("std");
const dvui = @import("dvui");
const layer_shell = @import("dvui-layer-shell");

// ---------------------------------------------------------------------------
// Example: App on a layer-shell surface.
//
// This file demonstrates BOTH integration styles the library supports:
//
// 1) Drop-in replacement (used here) — replace your `main` with the
//    library's `main` and just declare `dvui_app` + `layer_shell_opts`:
//
//      pub const dvui_app: dvui.App = .{ ... };
//      pub const layer_shell_opts: layer_shell.LayerShellOpts = .{ ... };
//      pub const main = layer_shell.main;
//      pub const panic = dvui.App.panic;
//
// 2) Function call — keep your own `main` and call `layer_shell.run`:
//
//      pub fn main(init: std.process.Init) !u8 {
//          const app: dvui.App = .{ .config = .{ .options = .{...} }, .frameFn = frame };
//          const opts: layer_shell.LayerShellOpts = .{ .anchors = .{...}, .layer = .top };
//          return try layer_shell.run(init, app, opts);
//      }
//
// 3) Low-level manual loop (still available):
//
//      const ctx = try layer_shell.initWindow(.{ .io = init.io, ... }, layer_opts, gpa);
//      defer ctx.backend.deinit();
//      defer ctx.waylandCtx.deinit(gpa);
//      var win = try dvui.Window.init(... ctx.backend.backend() ...);
//      while (...) { try win.begin(...); try ctx.backend.addAllEvents(&win); try frame(); ... }
//
// The library is Wayland-only: it forces SDL_VIDEODRIVER=wayland and panics
// with a diagnostic if no Wayland compositor / zwlr_layer_shell_v1 is available.
// Transparency uses dvui's own `StartOptions.transparent` (no duplicate field).
// ---------------------------------------------------------------------------

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .title = "[bpavuk/mustfloat] SDL layer-shell (App)",
            .size = .{ .w = 800, .h = 600 },
            .min_size = .{ .w = 200, .h = 100 },
            .vsync = true,
            .transparent = true, // per-pixel alpha; library auto-patches theme to .transparent
        },
    },
    .frameFn = frame,
};

pub const layer_shell_opts: layer_shell.LayerShellOpts = .{
    // Floating centered overlay — resizable/movable at runtime via
    // `layer_shell.wayland()` (see frame() below).
    // Other ideas:
    //   top bar:          .{ .anchors = .{ .top, .left, .right, null } }
    //   top + h-centered: .{ .anchors = .{ .top, null, null, null }, .center = .horizontal }
    //   left + v-centered:.{ .anchors = .{ null, .left, null, null }, .center = .vertical }
    .center = .both,
    .padding = .{ 0, 0, 0, 0 },
    .layer = .overlay,
    .exclusive_zone = 0,
    .namespace = "dvui-layer-example",
};

// Drop-in: dvuis App main is replaced by the layer-shell wrapper.
// It reads `dvui_app` + `layer_shell_opts` from this file automatically.
pub const main = layer_shell.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

fn frame() !dvui.App.Result {
    // Mirrors the previous `content()` from the manual example. When
    // `dvui_app.config.options.transparent` is true the backend is cleared to
    // 0,0,0,0 and the theme's window fill is patched to .transparent, so any
    // uncovered pixel stays transparent. Only draw backgrounds where you want opacity.
    const transparent = dvui_app.config.get().transparent;

    if (transparent) {
        var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .gravity_y = 0.5,
            .gravity_x = 0.5,
            .padding = .all(12),
            .background = false, // keep window transparent around card
        });
        defer outer.deinit();

        var card = dvui.box(@src(), .{}, .{
            .gravity_y = 0.5,
            .gravity_x = 0.5,
            .background = true,
            .style = .content,
            .corners = .all(12),
            .padding = .all(16),
            .border = dvui.Rect.all(1),
            .min_size_content = .{ .w = 300, .h = 100 },
        });
        defer card.deinit();

        dvui.label(@src(), "Hello World (transparent, App)", .{}, .{ .font = .theme(.title), .gravity_x = 0.5 });
        if (dvui.button(@src(), "Click me!", .{ .touch_drag = true }, .{ .gravity_x = 0.5 })) {
            std.debug.print("Pressed\n", .{});
        }

        // --- Centering / move / resize demo (runtime layer-surface control)
        if (layer_shell.wayland()) |wl| {
            dvui.label(@src(), "Center", .{}, .{ .gravity_x = 0.5 });
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
                defer row.deinit();
                if (dvui.button(@src(), "X", .{}, .{})) wl.setCenter(.horizontal);
                if (dvui.button(@src(), "Y", .{}, .{})) wl.setCenter(.vertical);
                if (dvui.button(@src(), "Both", .{}, .{})) wl.setCenter(.both);
            }
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
                defer row.deinit();
                if (dvui.button(@src(), "◀", .{}, .{})) wl.moveBy(-20, 0);
                if (dvui.button(@src(), "▶", .{}, .{})) wl.moveBy(20, 0);
                if (dvui.button(@src(), "▲", .{}, .{})) wl.moveBy(0, -20);
                if (dvui.button(@src(), "▼", .{}, .{})) wl.moveBy(0, 20);
                if (dvui.button(@src(), "TL", .{}, .{})) wl.moveTo(32, 32);
            }
            {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
                defer row.deinit();
                if (dvui.button(@src(), "800x600", .{}, .{})) wl.setSize(800, 600);
                if (dvui.button(@src(), "400x300", .{}, .{})) wl.setSize(400, 300);
                if (dvui.button(@src(), "+w", .{}, .{})) {
                    const cfg = wl.getConfig();
                    wl.setSize(cfg.width + 40, cfg.height);
                }
                if (dvui.button(@src(), "+h", .{}, .{})) {
                    const cfg = wl.getConfig();
                    wl.setSize(cfg.width, cfg.height + 40);
                }
            }
        }
    } else {
        var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
            .style = .window,
            .gravity_y = 0.5,
            .gravity_x = 0.5,
        });
        defer outer.deinit();

        dvui.label(@src(), "Hello World", .{}, .{ .font = .theme(.title), .gravity_x = 0.5 });
        if (dvui.button(@src(), "Click me!", .{ .touch_drag = true }, .{ .gravity_x = 0.5 })) {
            std.debug.print("Pressed\n", .{});
        }
    }

    return .ok;
}

// ---------------------------------------------------------------------------
// Alternative function-call form (commented, for reference):
//
// pub fn main(init: std.process.Init) !u8 {
//     const app: dvui.App = .{
//         .config = .{ .options = .{
//             .title = "My bar",
//             .size = .{ .w = 800, .h = 600 },
//             .transparent = true,
//         } },
//         .frameFn = frame,
//     };
//     const opts: layer_shell.LayerShellOpts = .{
//         .anchors = .{ .top, .left, .right, null },
//         .layer = .top,
//     };
//     return try layer_shell.run(init, app, opts);
// }
// ---------------------------------------------------------------------------
