//! dvui-layer-shell — layer-shell + Wayland-only wrapper for dvui (SDL3)
//!
//! ## Usage — drop-in `main`
//! ```zig
//! const dvui = @import("dvui");
//! const layer_shell = @import("dvui-layer-shell");
//!
//! pub const dvui_app: dvui.App = .{
//!     .config = .{ .options = .{
//!         .title = "My bar",
//!         .size = .{ .w = 800, .h = 600 },
//!         .transparent = true, // <- dvui's own flag, no duplicate
//!     } },
//!     .frameFn = frame,
//! };
//! pub const layer_shell_opts: layer_shell.LayerShellOpts = .{
//!     .anchors = .{ .top, .left, .right, null },
//!     .layer = .top,
//!     .exclusive_zone = 600,
//! };
//! pub const main = layer_shell.main;
//! pub const panic = dvui.App.panic;
//! pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };
//! ```
//!
//! ## Usage — function call from your own `main`
//! ```zig
//! pub fn main(init: std.process.Init) !void {
//!     const app: dvui.App = .{ .config = .{ .options = .{ .size = .{ .w = 800, .h = 600 }, ...} }, .frameFn = frame };
//!     const opts: layer_shell.LayerShellOpts = .{ .layer = .top };
//!     _ = try layer_shell.run(init, app, opts);
//! }
//! // or low-level manual loop:
//! pub fn main(init: std.process.Init) !void {
//!     const ctx = try layer_shell.initWindow(.{ .io = init.io, .title = "...", .size = .{ .w = 800, .h = 600 }, .transparent = true }, .{ .anchors = .{...} }, init.gpa);
//!     defer ctx.backend.deinit();
//!     defer ctx.waylandCtx.deinit(init.gpa);
//!     // ... your Window loop (see README)
//! }
//! ```

const std = @import("std");
const dvui = @import("dvui");
const builtin = @import("builtin");
const SDLBackend = @import("backend");
const sdlInit = @import("sdlCustomInit.zig");
const WaylandContext = @import("waylandContext.zig");

pub const LayerShellOpts = sdlInit.LayerShellOpts;
pub const WaylandContextType = WaylandContext;
pub const initWindow = sdlInit.initWindow;
pub const Config = WaylandContext.Config;

// Re-export for convenience
pub const Anchor = LayerShellOpts.Anchor;
pub const Layer = LayerShellOpts.Layer;
pub const Center = LayerShellOpts.Center;

/// Resolve layer-shell opts from root if user used drop-in `main`.
///
/// Looks for (in order): `layer_shell_opts`, `dvui_layer_opts`, `layer_opts`.
/// Falls back to `. {}` if none found.
fn rootLayerOpts() LayerShellOpts {
    const root = @import("root");
    if (@hasDecl(root, "layer_shell_opts")) return root.layer_shell_opts;
    if (@hasDecl(root, "dvui_layer_opts")) return root.dvui_layer_opts;
    if (@hasDecl(root, "layer_opts")) return root.layer_opts;
    return .{};
}

/// Active layer-surface for the running App loop (set by `run`, cleared on
/// exit). Lets `frameFn` move/resize after launch without threading a
/// handle through dvui:
///
/// ```zig
/// fn frame() !dvui.App.Result {
///     if (dvui.button(@src(), "Wider", .{}, .{})) {
///         if (layer_shell.wayland()) |wl| wl.setSize(1000, 600);
///     }
///     return .ok;
/// }
/// ```
/// Null outside `run` (or on the manual path — use your own `ctx.waylandCtx`).
var current_wayland_ctx: ?*WaylandContext = null;

/// Access the live layer-surface from inside `frameFn`. See `current_wayland_ctx`.
pub fn wayland() ?*WaylandContext {
    return current_wayland_ctx;
}

/// Drop-in replacement for `pub const main = dvui.App.main` when using layer-shell.
///
/// Reads `dvui_app: dvui.App` and `layer_shell_opts: LayerShellOpts` from your
/// root file (or defaults). Panics if no Wayland compositor / layer-shell is
/// available — this backend is Wayland-only by design (SDL_VIDEODRIVER forced
/// to `wayland`).
pub fn main(init: std.process.Init) !u8 {
    dvui.App.main_init = init;
    const app = dvui.App.get() orelse return error.DvuiAppNotDefined;
    const opts = rootLayerOpts();
    return try run(init, app, opts);
}

/// Run a `dvui.App` on a layer-shell surface (Wayland-only).
///
/// This is the App-friendly equivalent of `initWindow` + the standard
/// `dvui.App` event loop. It forces `SDL_VIDEODRIVER=wayland`, creates the
/// window via `sdlCustomInit.initWindow`, and otherwise mirrors
/// `dvui/backend/sdl.zig:main` (non-callback path). For the callback path
/// (macOS/Windows with SDL3 callbacks), it still works via the same
/// non-callback loop — layer-shell is Linux-only, so the callback path is not
/// needed for the Wayland case. If you need callbacks on macOS/Windows,
/// use plain `dvui.App.main` without layer-shell.
pub fn run(init: std.process.Init, app: dvui.App, layer_opts: LayerShellOpts) !u8 {
    dvui.App.main_init = init;

    if (builtin.os.tag == .windows) {
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }
    SDLBackend.enableSDLLogging();
    std.log.info("SDL version: {f}", .{SDLBackend.getSDLVersion()});

    const init_opts = app.config.get();

    // We always use the non-callback path for layer-shell (Wayland).
    // Mirror sdl.zig:2104 main but with our initWindow.
    const gpa = init_opts.gpa orelse init.gpa;
    const io = init_opts.io orelse init.io;
    var ctx = try sdlInit.initWindow(.{
        .io = io,
        .environ_map = init.environ_map,
        .size = init_opts.size,
        .min_size = init_opts.min_size,
        .max_size = init_opts.max_size,
        .vsync = init_opts.vsync,
        .title = init_opts.title,
        .org = init_opts.org,
        .icon = init_opts.icon,
        .hidden = init_opts.hidden,
        .transparent = init_opts.transparent,
        .persist_window_geometry = init_opts.persist_window_geometry,
        .pref_path = init_opts.pref_path,
    }, layer_opts, gpa);
    var backend = ctx.backend;
    defer backend.deinit();
    defer ctx.waylandCtx.deinit(gpa);
    current_wayland_ctx = ctx.waylandCtx;
    defer current_wayland_ctx = null;

    _ = SDLBackend.c.SDL_EnableScreenSaver();

    // Theme: if transparent, ensure window fill is transparent so the
    // per-pixel alpha isn't overdrawn by the default theme. Mirrors the
    // manual fix that used to live in main.zig.
    var window_init_opts = init_opts.window_init_options;
    if (init_opts.transparent) {
        var theme = window_init_opts.theme orelse switch (backend.preferredColorScheme() orelse .light) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        };
        theme.window.fill = .transparent;
        window_init_opts.theme = theme;
    }

    var win = try dvui.Window.init(@src(), gpa, backend.backend(), window_init_opts);
    defer win.deinit();

    if (init_opts.window_init_options.open_flag != null)
        dvui.log.warn("`open_flag` option has no effect in dvui App. It is managed internally.", .{});
    var window_open = true;
    win.open_flag = &window_open;

    if (app.initFn) |initFn| {
        try win.begin(win.frame_time_ns);
        try initFn(&win);
        _ = try win.end(.{});
    }
    defer if (app.deinitFn) |deinitFn| deinitFn();

    var interrupted = false;
    main_loop: while (window_open) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        try backend.addAllEvents(&win);
        if (ctx.waylandCtx.should_close) break :main_loop;
        const res = try app.frameFn();
        const end_micros = try win.end(.{});
        if (res != .ok) break :main_loop;
        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
    return 0;
}

// Provide panic/logFn passthroughs so users can do `pub const panic = layer_shell.panic`
pub const panic = dvui.App.panic;
pub const logFn = dvui.App.logFn;
