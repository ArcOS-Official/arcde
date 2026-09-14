const Self = @This();

const std = @import("std");

const wayland = @import("wayland").client;
const c = @import("backend").c;

layer_shell: ?*wayland.zwlr.LayerShellV1 = null,
layer_surface: ?*wayland.zwlr.LayerSurfaceV1 = null,
compositor: ?*wayland.wl.Compositor = null,
window: *c.SDL_Window = undefined,
// Handles needed for runtime reconfiguration (move/resize).
display: *wayland.wl.Display = undefined,
surface: *wayland.wl.Surface = undefined,
queue: *wayland.wl.EventQueue = undefined,
/// Last requested state (mirrors what was sent via set_* + commit).
config: Config = .{},
/// Last size suggested by the compositor (0 = client decides).
configured_width: u32 = 0,
configured_height: u32 = 0,
layer_shell_configured: bool = false,
should_close: bool = false,

pub const Config = struct {
    width: u32 = 0,
    height: u32 = 0,
    layer: wayland.zwlr.LayerShellV1.Layer = .top,
    anchor: wayland.zwlr.LayerSurfaceV1.Anchor = .{},
    margins: [4]i32 = .{ 0, 0, 0, 0 }, // top, right, bottom, left
    exclusive_zone: i32 = 0,
    keyboard_interactivity: wayland.zwlr.LayerSurfaceV1.KeyboardInteractivity = .on_demand,
    namespace: [:0]const u8 = "dvui-layer",
};

pub fn init(sdl_window: *c.SDL_Window, config: Config, alloc: std.mem.Allocator) !*Self {
    const self = try alloc.create(Self);
    self.* = .{ .window = sdl_window, .config = config };

    const props = c.SDL_GetWindowProperties(self.window);
    const wl_display_ptr: ?*anyopaque = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null);
    if (wl_display_ptr == null) {
        std.debug.panic("Wayland required but SDL window has no wl_display (SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER is null) - SDL is not running on Wayland", .{});
    }
    const wl_display: *wayland.wl.Display = @ptrCast(wl_display_ptr.?);
    const wl_surface_nullable: ?*wayland.wl.Surface = @ptrCast(c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null));

    if (wl_surface_nullable == null) {
        std.debug.panic("Wayland required but SDL window has no wl_surface (SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER is null)", .{});
    }
    const wl_surface = wl_surface_nullable.?;

    self.display = wl_display;
    self.surface = wl_surface;

    const wl_queue = wayland.wl.Display.createQueue(wl_display) catch |e| {
        std.debug.panic("Wayland required but failed to create wl queue: {any}", .{e});
    };
    self.queue = wl_queue;
    const wl_registry = wayland.wl.Display.getRegistry(wl_display) catch |e| {
        std.debug.panic("Wayland required but failed to get wl_registry: {any}", .{e});
    };
    wayland.wl.Proxy.setQueue(@ptrCast(wl_registry), wl_queue);

    wl_registry.setListener(*Self, registryListener, self);

    if (wl_display.roundtripQueue(wl_queue) != .SUCCESS) {
        std.debug.panic("Wayland required but wl_display.roundtrip failed - compositor did not respond", .{});
    }

    if (self.layer_shell == null) {
        std.debug.panic("Wayland required but compositor does not support zwlr_layer_shell_v1 (wlr-layer-shell) - are you running a Wayland compositor with layer-shell?", .{});
    }

    self.layer_surface = self.layer_shell.?.getLayerSurface(wl_surface, null, config.layer, config.namespace) catch |e| {
        std.debug.panic("Wayland required but getLayerSurface failed: {any}", .{e});
    };

    if (self.layer_surface) |ls| {
        ls.setSize(config.width, config.height);
        // packed struct Anchor is truthy if any field set; setAnchor with empty struct is anchor = none (centered)
        ls.setAnchor(config.anchor);
        ls.setMargin(config.margins[0], config.margins[1], config.margins[2], config.margins[3]);
        if (config.exclusive_zone != 0) ls.setExclusiveZone(config.exclusive_zone);
        ls.setKeyboardInteractivity(config.keyboard_interactivity);
        ls.setListener(*Self, layerSurfaceListener, self);
    } else {
        std.debug.panic("Wayland required but zwlr_layer_shell_v1 not advertised by compositor", .{});
    }

    std.log.info("committing...", .{});

    wl_surface.commit();

    while (!self.layer_shell_configured) {
        if (wl_display.dispatchQueue(wl_queue) != .SUCCESS) {
            std.debug.panic("Wayland required but wl_display.dispatchQueue failed while waiting for layer_surface configure", .{});
        }
    }

    return self;
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    if (self.layer_surface) |ls| ls.destroy();
    if (self.layer_shell) |ls| ls.destroy();
    self.queue.destroy();
    alloc.destroy(self);
}

// --- Runtime reconfiguration -------------------------------------------
// All setters are double-buffered: they take effect on `commit()` (called
// internally). Safe to call any time after `init` from the main thread.
// `layer`/`namespace` are fixed at creation and cannot be changed here.

/// Push pending double-buffered state to the compositor.
pub fn commit(self: *Self) void {
    self.surface.commit();
    _ = self.display.flush();
}

/// Resize the surface after launch. Pass 0 on an axis to let the
/// compositor pick (requires opposite anchors on that axis). The
/// compositor answers with a `configure` event which updates the SDL
/// window; we also optimistically resize SDL so content scales
/// immediately when both dimensions are non-zero.
pub fn setSize(self: *Self, width: u32, height: u32) void {
    self.config.width = width;
    self.config.height = height;
    if (self.layer_surface) |ls| ls.setSize(width, height);
    if (width > 0 and height > 0) {
        _ = c.SDL_SetWindowSize(self.window, @intCast(width), @intCast(height));
    }
    self.commit();
}

pub const resize = setSize;

/// Change anchors after launch (e.g. unanchor to center, or anchor to an
/// edge/corner to dock). See `setCenter`/`moveTo` for higher-level helpers.
pub fn setAnchor(self: *Self, anchor: wayland.zwlr.LayerSurfaceV1.Anchor) void {
    self.config.anchor = anchor;
    if (self.layer_surface) |ls| ls.setAnchor(anchor);
    self.commit();
}

pub const CenterMode = enum {
    none,
    horizontal,
    vertical,
    both,
};

/// Center on one/both axes by clearing anchors for that axis, or restore
/// edge-anchoring with `.none` (keeps current anchors — pair with
/// `setAnchor` to re-dock).
pub fn setCenter(self: *Self, mode: CenterMode) void {
    var a = self.config.anchor;
    switch (mode) {
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
    self.setAnchor(a);
}

pub fn isCenteredHorizontally(self: *const Self) bool {
    return !self.config.anchor.left and !self.config.anchor.right;
}

pub fn isCenteredVertically(self: *const Self) bool {
    return !self.config.anchor.top and !self.config.anchor.bottom;
}

/// Change margins (offsets from the anchored edges) after launch.
/// Margins only affect edges you are anchored to. Commits immediately.
pub fn setMargins(self: *Self, margins: [4]i32) void {
    self.config.margins = margins;
    if (self.layer_surface) |ls| ls.setMargin(margins[0], margins[1], margins[2], margins[3]);
    self.commit();
}

/// Move a docked/anchored surface by setting its margins. For a
/// free-floating centered overlay, this anchors it to the top-left first
/// so `x`/`y` act as absolute offsets, then sets margins.
pub fn moveTo(self: *Self, x: i32, y: i32) void {
    const a: wayland.zwlr.LayerSurfaceV1.Anchor = .{ .top = true, .left = true };
    self.config.anchor = a;
    var m = self.config.margins;
    m[0] = y; // top
    m[3] = x; // left
    self.config.margins = m;
    if (self.layer_surface) |ls| {
        ls.setAnchor(a);
        ls.setMargin(m[0], m[1], m[2], m[3]);
    }
    self.commit();
}

/// Nudge the current position by `dx`/`dy` (adjusts top/left margins).
/// If the surface is centered (no anchors), anchors to top-left first
/// like `moveTo`.
pub fn moveBy(self: *Self, dx: i32, dy: i32) void {
    if (self.isCenteredHorizontally() or self.isCenteredVertically()) {
        // Anchor so margins take effect; keep the other axis as-is.
        var a = self.config.anchor;
        a.top = true;
        a.left = true;
        self.config.anchor = a;
        if (self.layer_surface) |ls| ls.setAnchor(a);
    }
    var m = self.config.margins;
    m[0] += dy;
    m[3] += dx;
    self.config.margins = m;
    if (self.layer_surface) |ls| ls.setMargin(m[0], m[1], m[2], m[3]);
    self.commit();
}

/// Atomic move + resize in a single commit (avoids flicker vs calling
/// `moveTo` + `setSize` separately). Any `null` field keeps its value.
pub fn reposition(self: *Self, opts: struct {
    anchor: ?wayland.zwlr.LayerSurfaceV1.Anchor = null,
    margins: ?[4]i32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
}) void {
    if (opts.anchor) |a| {
        self.config.anchor = a;
        if (self.layer_surface) |ls| ls.setAnchor(a);
    }
    if (opts.margins) |m| {
        self.config.margins = m;
        if (self.layer_surface) |ls| ls.setMargin(m[0], m[1], m[2], m[3]);
    }
    const w = opts.width orelse self.config.width;
    const h = opts.height orelse self.config.height;
    self.config.width = w;
    self.config.height = h;
    if (self.layer_surface) |ls| ls.setSize(w, h);
    if (w > 0 and h > 0) _ = c.SDL_SetWindowSize(self.window, @intCast(w), @intCast(h));
    self.commit();
}

/// Change exclusive zone after launch (0 = move aside for other
/// exclusive surfaces, -1 = stretch under panels, >0 = reserve space).
pub fn setExclusiveZone(self: *Self, zone: i32) void {
    self.config.exclusive_zone = zone;
    if (self.layer_surface) |ls| ls.setExclusiveZone(zone);
    self.commit();
}

pub fn setKeyboardInteractivity(self: *Self, mode: wayland.zwlr.LayerSurfaceV1.KeyboardInteractivity) void {
    self.config.keyboard_interactivity = mode;
    if (self.layer_surface) |ls| ls.setKeyboardInteractivity(mode);
    self.commit();
}

pub fn getConfig(self: *const Self) Config {
    return self.config;
}

pub fn getConfiguredSize(self: *const Self) struct { w: u32, h: u32 } {
    return .{ .w = self.configured_width, .h = self.configured_height };
}

fn registryListener(registry: *wayland.wl.Registry, event: wayland.wl.Registry.Event, context: *Self) void {
    const log = std.log.scoped(.wlRegistryListener);

    switch (event) {
        .global => |global| {
            log.info("received interface {s} v{d}", .{ global.interface, global.version });
            if (std.mem.orderZ(u8, global.interface, wayland.wl.Compositor.interface.name) == .eq) {
                const version = @min(global.version, 6);
                context.compositor = registry.bind(global.name, wayland.wl.Compositor, version) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wayland.zwlr.LayerShellV1.interface.name) == .eq) {
                const version = @min(global.version, 5);
                context.layer_shell = registry.bind(global.name, wayland.zwlr.LayerShellV1, version) catch return;
            }
        },
        .global_remove => {},
    }
}

fn layerSurfaceListener(layer_surface: *wayland.zwlr.LayerSurfaceV1, event: wayland.zwlr.LayerSurfaceV1.Event, context: *Self) void {
    const log = std.log.scoped(.wlLayerSurfaceListener);
    log.info("received layer shell event", .{});

    switch (event) {
        .closed => {
            context.should_close = true;
        },
        .configure => |configure| {
            log.info("received layer shell configure event", .{});
            layer_surface.ackConfigure(configure.serial);
            context.layer_shell_configured = true;
            // 0 means "client decides" — keep current SDL size on that axis.
            context.configured_width = configure.width;
            context.configured_height = configure.height;
            if (configure.width > 0 and configure.height > 0) {
                _ = c.SDL_SetWindowSize(context.window, @intCast(configure.width), @intCast(configure.height));
            } else if (configure.width > 0) {
                var w: c_int = 0;
                var h: c_int = 0;
                _ = c.SDL_GetWindowSize(context.window, &w, &h);
                _ = c.SDL_SetWindowSize(context.window, @intCast(configure.width), h);
            } else if (configure.height > 0) {
                var w: c_int = 0;
                var h: c_int = 0;
                _ = c.SDL_GetWindowSize(context.window, &w, &h);
                _ = c.SDL_SetWindowSize(context.window, w, @intCast(configure.height));
            }
        },
    }
}
