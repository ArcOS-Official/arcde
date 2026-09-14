const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
const builtin = @import("builtin");
const wayland = @import("wayland").client;
const WaylandContext = @import("waylandContext.zig");

pub const InitOptions = SDLBackend.InitOptions;
pub const WindowGeometry = SDLBackend.WindowGeometry;
const c = SDLBackend.c;
const log = std.log.scoped(.SDLCustomBackend);

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const SDL_ERROR = bool;
const SDL_SUCCESS: SDL_ERROR = true;
const sdl3 = true;

pub const LayerShellOpts = struct {
    /// Which edges to anchor to. Empty (all null) = centered on both axes.
    /// Example: .{ .top, .left, null, null } anchors to top-left corner.
    /// Per the protocol, omitting an axis centers on it: anchor `.top`
    /// only → horizontally centered bar; anchor `.left` only → vertically
    /// centered panel. `center` below forces this explicitly.
    anchors: [4]?Anchor = .{null}**4,
    /// Explicit centering. Overrides `anchors` on that axis by clearing
    /// it: `.horizontal`/`.both` clears left/right, `.vertical`/`.both`
    /// clears top/bottom. Combine with `anchors` for e.g. top-anchored +
    /// horizontally centered: `.anchors = .{ .top, null, null, null },
    /// .center = .horizontal`.
    center: Center = .none,
    /// Margins for anchored edges: [top, right, bottom, left]. Only affects
    /// edges you are anchored to. Doubles as position offset for `moveTo`.
    padding: [4]i32 = .{0}**4,
    layer: Layer = .top,
    exclusive_zone: i32 = 0,
    namespace: [:0]const u8 = "dvui-layer",
    keyboard_interactivity: wayland.zwlr.LayerSurfaceV1.KeyboardInteractivity = .on_demand,

    pub const Anchor = enum {
        top,
        left,
        right,
        bottom,
    };

    pub const Center = enum {
        /// Use `anchors` as-is.
        none,
        /// Center horizontally (clear left/right anchors).
        horizontal,
        /// Center vertically (clear top/bottom anchors).
        vertical,
        /// Center on both axes (clear all anchors → floating overlay).
        both,
    };

    /// Centered floating overlay (no anchors, client-sized).
    pub fn centered() @This() {
        return .{ .center = .both };
    }

    /// Top edge, horizontally centered (fixed-size centered bar).
    pub fn topCentered() @This() {
        return .{ .anchors = .{ .top, null, null, null }, .center = .horizontal };
    }

    /// Left edge, vertically centered (fixed-size centered side panel).
    pub fn leftCentered() @This() {
        return .{ .anchors = .{ null, .left, null, null }, .center = .vertical };
    }

    pub fn isCenteredHorizontally(self: @This()) bool {
        if (self.center == .horizontal or self.center == .both) return true;
        return self.anchorMaskNoCenter().left == false and self.anchorMaskNoCenter().right == false;
    }

    pub fn isCenteredVertically(self: @This()) bool {
        if (self.center == .vertical or self.center == .both) return true;
        return self.anchorMaskNoCenter().top == false and self.anchorMaskNoCenter().bottom == false;
    }

    pub const Layer = enum {
        background,
        bottom,
        top,
        overlay,
    };

    pub fn anchorMask(self: @This()) wayland.zwlr.LayerSurfaceV1.Anchor {
        var a = self.anchorMaskNoCenter();
        switch (self.center) {
            .none => {},
            .horizontal => {
                a.left = false;
                a.right = false;
            },
            .vertical => {
                a.top = false;
                a.bottom = false;
            },
            .both => a = .{},
        }
        return a;
    }

    fn anchorMaskNoCenter(self: @This()) wayland.zwlr.LayerSurfaceV1.Anchor {
        var a: wayland.zwlr.LayerSurfaceV1.Anchor = .{};
        for (self.anchors) |maybe| {
            if (maybe) |ank| switch (ank) {
                .top => a.top = true,
                .bottom => a.bottom = true,
                .left => a.left = true,
                .right => a.right = true,
            };
        }
        return a;
    }

    pub fn waylandLayer(self: @This()) wayland.zwlr.LayerShellV1.Layer {
        return switch (self.layer) {
            .background => .background,
            .bottom => .bottom,
            .top => .top,
            .overlay => .overlay,
        };
    }

    pub fn waylandConfig(self: @This(), size: dvui.Size) WaylandContext.Config {
        // dvui.Size w/h are f32; clamp to u32, 0 = let compositor decide (anchored axis)
        const w: u32 = if (size.w > 0) @intFromFloat(@round(size.w)) else 0;
        const h: u32 = if (size.h > 0) @intFromFloat(@round(size.h)) else 0;
        return .{
            .width = w,
            .height = h,
            .layer = self.waylandLayer(),
            .anchor = self.anchorMask(),
            .margins = self.padding,
            .exclusive_zone = self.exclusive_zone,
            .namespace = self.namespace,
            .keyboard_interactivity = self.keyboard_interactivity,
        };
    }
};

pub fn initWindow(init_options: InitOptions, opts: LayerShellOpts, alloc: std.mem.Allocator) !struct {
    const Self = @This();
    backend: SDLBackend,
    waylandCtx: *WaylandContext,
} {
    try initSDL();
    const new = try createWindowRenderer(init_options, opts, alloc);

    var back = SDLBackend.init(init_options.io, new.win, new.renderer);
    back.init_opts_save = init_options;
    back.window_geometry = new.saved_geometry orelse .{};

    try configureBackend(&back, init_options, opts);

    return .{
        .backend = back,
        .waylandCtx = new.waylandCtx,
    };
}

/// SDL initialization for the all SDL app, i.e. common for all OS Windows
/// This is expected to be called only once. This build **panics** if Wayland cannot be used.
pub fn initSDL() !void {
    // -- Force Wayland -------------------------------------------------------
    // This system is Wayland-only. We set both spellings of the env var and
    // the SDL hint (when available) before SDL_Init so SDL cannot fall back
    // to X11/XWayland. After init we verify the selected driver and panic
    // if it is not "wayland".
    _ = setenv("SDL_VIDEODRIVER", "wayland", 1);
    _ = setenv("SDL_VIDEO_DRIVER", "wayland", 1);
    // SDL3 exposes SDL_HINT_VIDEO_DRIVER in some builds; try both names defensively
    if (@hasDecl(c, "SDL_HINT_VIDEO_DRIVER")) {
        _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "wayland");
    }
    if (@hasDecl(c, "SDL_HINT_VIDEODRIVER")) {
        _ = c.SDL_SetHint(c.SDL_HINT_VIDEODRIVER, "wayland");
    }
    // Also hint via string literal in case translate-c name differs
    _ = c.SDL_SetHint("SDL_HINT_VIDEO_DRIVER", "wayland");
    _ = c.SDL_SetHint("SDL_VIDEO_DRIVER", "wayland");

    // use the string version instead of the #define so we compile with SDL < 2.24
    _ = c.SDL_SetHint("SDL_HINT_WINDOWS_DPI_SCALING", "1");

    // makes mac scrolling better
    _ = c.SDL_SetHint(c.SDL_HINT_MAC_SCROLL_MOMENTUM, "1");

    // prevents some bad performance in certain wayland compositors (sway) under some conditions
    if (c.SDL_SetHint(c.SDL_HINT_VIDEO_WAYLAND_PREFER_LIBDECOR, "1") != SDL_SUCCESS) {
        log.err("failed to set libdecor hint", .{});
    }

    // SDL_Init is Wayland-only: do not go through toErr/logErr (which would
    // duplicate the error log before the panic). Check directly and panic with
    // a single, user-facing message that includes SDL_GetError() and
    // WAYLAND_DISPLAY for debuggability.
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS) != SDL_SUCCESS) {
        const sdl_err = std.mem.span(c.SDL_GetError());
        const wd_ptr = std.c.getenv("WAYLAND_DISPLAY");
        const wd = if (wd_ptr) |p| std.mem.span(p) else "(unset)";
        // Also respect the test override WAYLAND_DISPLAY=1 that was used in CI
        std.debug.panic("Wayland required but SDL_Init failed: {s} (SDL_VIDEODRIVER=wayland forced, WAYLAND_DISPLAY={s}) - is a Wayland compositor running?", .{ sdl_err, wd });
    }

    // Verify SDL actually picked Wayland; panic otherwise
    const driver = c.SDL_GetCurrentVideoDriver();
    if (driver == null) {
        const wd_ptr = std.c.getenv("WAYLAND_DISPLAY");
        const wd = if (wd_ptr) |p| std.mem.span(p) else "(unset)";
        std.debug.panic("SDL_GetCurrentVideoDriver returned null - Wayland required but no video driver active (WAYLAND_DISPLAY={s})", .{wd});
    }
    const driver_name = std.mem.span(driver.?);
    if (std.mem.order(u8, driver_name, "wayland") != .eq) {
        std.debug.panic("SDL selected video driver '{s}' but this build requires 'wayland' (SDL_VIDEODRIVER=wayland forced)", .{driver_name});
    }
    log.info("SDL video driver forced to wayland", .{});

    // FIXME : as per SDL docs :
    // Consider reporting some basic metadata about your application before calling SDL_Init, using either SDL_SetAppMetadata() or SDL_SetAppMetadataProperty().
    // This would be nice here probably ...
}

fn createWindowRenderer(options: InitOptions, layer_opts: LayerShellOpts, alloc: std.mem.Allocator) !struct {
    win: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    saved_geometry: ?WindowGeometry,
    waylandCtx: *WaylandContext,
} {
    var hidden = options.hidden;
    var show_window_in_begin = false;
    if (dvui.accesskit_enabled and !hidden) {
        // hide the window until we can initialize accesskit in Window.begin
        hidden = true;
        show_window_in_begin = true;
    }

    const saved_geometry: ?WindowGeometry = if (sdl3) WindowGeometry.load(options) else null;

    const hidden_flag = if (hidden) c.SDL_WINDOW_HIDDEN else 0;
    const fullscreen_flag = if (options.fullscreen) c.SDL_WINDOW_FULLSCREEN else 0;
    const transparent = options.transparent and sdl3;
    const transparent_flag = if (transparent) c.SDL_WINDOW_TRANSPARENT else 0;
    const window: *c.SDL_Window = if (sdl3) blk: {
        // Window properties let us apply restored geometry at creation time,
        // so the window appears directly at its previous position/size.
        const props = c.SDL_CreateProperties();
        defer c.SDL_DestroyProperties(props);

        const flags: c.SDL_WindowFlags = @intCast(c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_RESIZABLE | transparent_flag | hidden_flag | fullscreen_flag);
        var w: c_int = @as(c_int, @trunc(options.size.w));
        var h: c_int = @as(c_int, @trunc(options.size.h));

        if (saved_geometry) |g| {
            // Don't restore geometry for transparent layer-shell panels; compositor controls placement
            if (!options.transparent) {
                w = g.w;
                h = g.h;
                if (posOnADisplay(g)) {
                    try toErr(c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_X_NUMBER, g.x), "SDL_SetNumberProperty in initWindow");
                    try toErr(c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_Y_NUMBER, g.y), "SDL_SetNumberProperty in initWindow");
                }
            }
        }

        try toErr(c.SDL_SetStringProperty(props, c.SDL_PROP_WINDOW_CREATE_TITLE_STRING, options.title), "SDL_SetStringProperty in initWindow");
        try toErr(c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, w), "SDL_SetNumberProperty in initWindow");
        try toErr(c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, h), "SDL_SetNumberProperty in initWindow");
        try toErr(c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER, @intCast(flags)), "SDL_SetNumberProperty in initWindow");

        try toErr(c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_WAYLAND_SURFACE_ROLE_CUSTOM_BOOLEAN, true), "SDL_SetBooleanProperty in initWindow");
        try toErr(c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_OPENGL_BOOLEAN, true), "SDL_SetBooleanProperty in initWindow");
        try toErr(c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_HIDDEN_BOOLEAN, true), "SDL_SetBooleanProperty in initWindow");

        break :blk c.SDL_CreateWindowWithProperties(props) orelse return logErr("SDL_CreateWindowWithProperties in initWindow");
    } else c.SDL_CreateWindow(
        options.title,
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        @as(c_int, @trunc(options.size.w)),
        @as(c_int, @trunc(options.size.h)),
        @intCast(c.SDL_WINDOW_ALLOW_HIGHDPI | c.SDL_WINDOW_RESIZABLE | hidden_flag),
    ) orelse return logErr("SDL_CreateWindow in initWindow");

    errdefer c.SDL_DestroyWindow(window);

    // Double-check Wayland window properties before entering Wayland code - panic if not Wayland
    {
        const props = c.SDL_GetWindowProperties(window);
        if (c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null) == null) {
            const drv_ptr = c.SDL_GetCurrentVideoDriver();
            const drv_name = if (drv_ptr) |p| std.mem.span(p) else "null";
            std.debug.panic("Wayland required but SDL window has no wl_display - SDL fell back to X11/XWayland (driver={s})", .{drv_name});
        }
        if (c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null) == null) {
            std.debug.panic("Wayland required but SDL window has no wl_surface", .{});
        }
        // Extra: ensure video driver still wayland after window creation
        const drv = c.SDL_GetCurrentVideoDriver();
        if (drv == null or std.mem.orderZ(u8, std.mem.span(drv.?), "wayland") != .eq) {
            std.debug.panic("Wayland required but driver after window creation is '{s}'", .{if (drv) |d| std.mem.span(d) else "null"});
        }
    }

    const waylandCfg = layer_opts.waylandConfig(options.size);
    const waylandCtx = try WaylandContext.init(window, waylandCfg, alloc);
    errdefer waylandCtx.deinit(alloc);

    // get initial content scale
    var scale: f32 = 1.0;
    if (sdl3) {
        scale = c.SDL_GetDisplayContentScale(c.SDL_GetDisplayForWindow(window));
        if (scale == 0) {
            log.err("SDL_GetDisplayContentScale returned 0", .{});
            scale = 1.0;
        }
        log.info("SDL3 backend scale {d}", .{scale});
    } else {
        // scale = SDL2GuessScale(options.environ_map, options.io, window);
        // sdl2_scale = scale;
    }

    // adjust window size for content scale
    if (scale != 1.0 and saved_geometry == null) {
        if (builtin.abi.isAndroid()) {
            // log.error fails on Android but SDL_Log will show up in LogCat
            c.SDL_Log("[ERROR] Android doesn't support SDL_SetWindowSize");
        } else {
            _ = c.SDL_SetWindowSize(
                window,
                @as(c_int, @trunc(scale * options.size.w)),
                @as(c_int, @trunc(scale * options.size.h)),
            );
        }
    }

    if (options.min_size) |size| {
        if (builtin.abi.isAndroid()) {
            // log.error fails on Android but SDL_Log will show up in LogCat
            c.SDL_Log("[ERROR] Android doesn't support SDL_SetWindowMinimumSize");
        } else {
            const ret = c.SDL_SetWindowMinimumSize(
                window,
                @as(c_int, @trunc(scale * size.w)),
                @as(c_int, @trunc(scale * size.h)),
            );
            if (sdl3) try toErr(ret, "SDL_SetWindowMinimumSize in initWindow");
        }
    }

    if (options.max_size) |size| {
        if (builtin.abi.isAndroid()) {
            // log.error fails on Android but SDL_Log will show up in LogCat
            c.SDL_Log("[ERROR] Android doesn't support SDL_SetWindowMaximumSize");
        } else {
            const ret = c.SDL_SetWindowMaximumSize(
                window,
                @as(c_int, @trunc(scale * size.w)),
                @as(c_int, @trunc(scale * size.h)),
            );
            if (sdl3) try toErr(ret, "SDL_SetWindowMaximumSize in initWindow");
        }
    }

    const renderer: *c.SDL_Renderer = if (!sdl3)
        c.SDL_CreateRenderer(window, -1, @intCast(
            c.SDL_RENDERER_TARGETTEXTURE | (if (options.vsync) c.SDL_RENDERER_PRESENTVSYNC else 0),
        )) orelse return logErr("SDL_CreateRenderer in initWindow")
    else blk: {
        const props = c.SDL_CreateProperties();
        defer c.SDL_DestroyProperties(props);

        try toErr(
            c.SDL_SetPointerProperty(props, c.SDL_PROP_RENDERER_CREATE_WINDOW_POINTER, window),
            "SDL_SetPointerProperty in initWindow",
        );

        if (options.vsync) {
            try toErr(
                c.SDL_SetNumberProperty(props, c.SDL_PROP_RENDERER_CREATE_PRESENT_VSYNC_NUMBER, 1),
                "SDL_SetNumberProperty in initWindow",
            );
        }

        break :blk c.SDL_CreateRendererWithProperties(props) orelse return logErr("SDL_CreateRendererWithProperties in initWindow");
    };
    errdefer c.SDL_DestroyRenderer(renderer);

    // do premultiplied alpha blending:
    // * rendering to a texture and then rendering the texture works the same
    // * any filtering happening across pixels won't bleed in transparent rgb values
    const pma_blend = c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD);
    try toErr(c.SDL_SetRenderDrawBlendMode(renderer, pma_blend), "SDL_SetRenderDrawBlendMode in initWindow");

    // do fullscreen/maximize after window creation so the original geometry is saved:
    // position window -> fullscreen -> quit -> restart -> unfullscreen should restore original position
    if (!options.hidden) {
        if (saved_geometry) |g| {
            switch (g.state) {
                .normal => {},
                .maximized => {
                    _ = c.SDL_MaximizeWindow(window);
                },
                .fullscreen => {
                    if (sdl3) _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY, "1");
                    _ = c.SDL_SetWindowFullscreen(window, true);
                },
            }
        }
    }

    return .{
        .win = window,
        .renderer = renderer,
        .saved_geometry = saved_geometry,
        .waylandCtx = waylandCtx,
    };
}

fn configureBackend(back: *SDLBackend, options: InitOptions, opts: LayerShellOpts) !void {
    _ = opts;
    var hidden = options.hidden;
    var show_window_in_begin = false;
    if (dvui.accesskit_enabled and !hidden) {
        // hide the window until we can initialize accesskit in Window.begin
        hidden = true;
        show_window_in_begin = true;
    }
    back.ak_should_initialized = show_window_in_begin;
    back.we_own_window = true;
    // Always clear; clearWindow() clears to 0,0,0,0 (transparent) which is correct for
    // transparent == true and harmless for opaque (content will overdraw).
    // When transparent == true, the window's default dvui background must remain
    // transparent - see main.zig theme handling.
    back.clear_window_on_begin = true;

    // If transparency is requested, log that the window will be composited with per-pixel alpha;
    // blend mode already set in createWindowRenderer.
    if (options.transparent) {
        log.info("layer-shell transparency enabled: window will be composited with per-pixel alpha", .{});
    }

    if (options.icon) |bytes| {
        if (builtin.abi.isAndroid()) {
            // log.error fails on Android but SDL_Log will show up in LogCat
            c.SDL_Log("[ERROR] Android doesn't support setting a custom icon at runtime");
        } else {
            try back.setIconFromFileContent(bytes);
        }
    }
}

const State = enum { normal, maximized, fullscreen };

const Saved = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    state: State = .normal,
};

const zon_file_name = "window_geometry.zon";

fn filePath(buf: []u8, options: InitOptions) ?[:0]const u8 {
    if (options.pref_path) |dir| {
        if (std.mem.endsWith(u8, dir, std.fs.path.sep_str)) {
            return std.fmt.bufPrintZ(buf, "{s}{s}", .{ dir, zon_file_name }) catch null;
        }
        return std.fmt.bufPrintZ(buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, zon_file_name }) catch null;
    }
    const pref = c.SDL_GetPrefPath(options.org.ptr, options.title.ptr) orelse {
        logErr("SDL_GetPrefPath in WindowGeometry") catch {};
        return null;
    };
    defer c.SDL_free(pref);
    return std.fmt.bufPrintZ(buf, "{s}" ++ zon_file_name, .{std.mem.span(@as([*:0]const u8, @ptrCast(pref)))}) catch null;
}

fn fromSaved(saved: Saved) ?WindowGeometry {
    if (saved.w < 1 or saved.h < 1) return null;
    return .{
        .x = std.math.cast(c_int, saved.x) orelse return null,
        .y = std.math.cast(c_int, saved.y) orelse return null,
        .w = std.math.cast(c_int, saved.w) orelse return null,
        .h = std.math.cast(c_int, saved.h) orelse return null,
        .state = saved.state,
    };
}

fn toSaved(self: WindowGeometry) Saved {
    return .{
        .x = @intCast(self.x),
        .y = @intCast(self.y),
        .w = @intCast(self.w),
        .h = @intCast(self.h),
        .state = self.state,
    };
}

pub fn load(options: InitOptions) ?WindowGeometry {
    if (!options.persist_window_geometry) return null;
    var path_buf: [1024]u8 = undefined;
    const path = filePath(&path_buf, options) orelse return null;
    return loadZon(options.io, path);
}

fn loadZon(io: std.Io, path: [:0]const u8) ?WindowGeometry {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(4096)) catch return null;
    defer std.heap.page_allocator.free(data);
    var nul_buf: [4097]u8 = undefined;
    if (data.len >= nul_buf.len) return null;
    @memcpy(nul_buf[0..data.len], data);
    nul_buf[data.len] = 0;
    const saved = std.zon.parse.fromSlice(
        Saved,
        std.heap.page_allocator,
        nul_buf[0..data.len :0],
        null,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    return fromSaved(saved);
}

fn writeFile(io: std.Io, path: [:0]const u8, g: WindowGeometry) void {
    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer aw.deinit();
    std.zon.stringify.serialize(g.toSaved(), .{}, &aw.writer) catch return;
    const parent = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.createDirAbsolute(io, parent, .default_dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() }) catch {
        log.err("failed to write window_geometry.zon", .{});
    };
}

fn save(back: *SDLBackend) void {
    const opts = back.init_opts_save orelse return;
    var path_buf: [1024]u8 = undefined;
    const path = filePath(&path_buf, opts) orelse return;

    //std.debug.print("saving window geometry: {any}\n", .{back.window_geometry});
    WindowGeometry.writeFile(opts.io, path, back.window_geometry);
}

/// True if the window's title bar area would land on a connected display.
/// Guards against restoring onto a monitor that is no longer attached.
fn posOnADisplay(self: WindowGeometry) bool {
    var count: c_int = 0;
    const displays = c.SDL_GetDisplays(&count) orelse return false;
    defer c.SDL_free(displays);
    const cx = self.x + @divTrunc(self.w, 2);
    const cy = self.y + 10;
    for (displays[0..@intCast(count)]) |id| {
        var bounds: c.SDL_Rect = undefined;
        if (!c.SDL_GetDisplayUsableBounds(id, &bounds)) continue;
        if (cx >= bounds.x and cx < bounds.x + bounds.w and cy >= bounds.y and cy < bounds.y + bounds.h) return true;
    }
    return false;
}

inline fn toErr(res: SDL_ERROR, what: []const u8) !void {
    if (res == SDL_SUCCESS) return;
    return logErr(what);
}

inline fn logErr(what: []const u8) dvui.Backend.GenericError {
    log.err("{s} failed, error={s}", .{ what, c.SDL_GetError() });
    return dvui.Backend.GenericError.BackendError;
}
