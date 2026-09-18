const std = @import("std");
const dvui = @import("dvui");
const ls = @import("layershell");
const State = @import("State.zig");
const HubUi = @import("HubUi.zig");
const Icons = @import("Icons.zig");
const Wallpaper = @import("Wallpaper.zig");
const event_pump = @import("event_pump.zig");

pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

var state: State = undefined;
var hub_ui: HubUi = undefined;

// Worker -> GUI wakeup: runs on the worker thread every time a snapshot is
// pushed into the inbox. Forwards to dvui.refresh(window), which pushes an
// SDL user event that interrupts the backend's waitEventTimeout so the next
// frame (which drains the inbox in frame()) happens immediately instead of
// waiting for the next input event. Waking either window is enough: one loop
// iteration redraws both.
fn requestDvuiRefresh(ctx: ?*anyopaque) void {
    if (ctx) |c| {
        const win: *dvui.Window = @ptrCast(@alignCast(c));
        dvui.refresh(win, @src(), null);
    }
}

// Single shared pump for the shell's layer-shell windows; see event_pump.zig.
// Two-window path (bar + hub) when no wallpaper exists; three-window path
// once the background surface is mapped.
fn pumpEvents(backend_bar: anytype, win_bar: anytype, backend_hub: anytype, win_hub: anytype) !void {
    return event_pump.pumpEvents(backend_bar, win_bar, backend_hub, win_hub);
}

fn pumpEvents3(
    backend_bar: anytype,
    win_bar: anytype,
    backend_hub: anytype,
    win_hub: anytype,
    backend_bg: anytype,
    win_bg: anytype,
) !void {
    return event_pump.pumpEvents3(backend_bar, win_bar, backend_hub, win_hub, backend_bg, win_bg);
}

// Background wallpaper frame: fullscreen image covering the output.
// Bytes borrow the loaded wallpaper buffer (stable for the process
// lifetime); dvui caches the texture by pointer.
fn wallpaperFrame(wallpaper_bytes: []const u8) !dvui.App.Result {
    var outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = false,
    });
    defer outer.deinit();
    _ = dvui.image(@src(), .{
        .source = .{ .imageFile = .{ .bytes = wallpaper_bytes, .name = "wallpaper" } },
    }, .{
        .expand = .both,
    });
    return .ok;
}

// Authoritative hub keyboard (input) focus now comes from the compositor:
// nile broadcasts `shell_focus_changed` on every focus edge (plus once
// after each `shell_register` so reconnects converge), and State's worker
// thread stores it straight into HubUi.hub_keyboard_focused via the
// bindHubFocus pointer below. No SDL polling here: dvui's SDL backend
// consumes FOCUS_GAINED/LOST for accesskit and never surfaces them as
// dvui events, and the window flag can race the compositor (focus granted
// after a panel-open request arrives a frame later, reading as a loss).

const LayerShellWindow = @typeInfo(@TypeOf(ls.initWindow)).@"fn".return_type.?;

var win_hub_g: *dvui.Window = undefined;
var win_bar_g: *dvui.Window = undefined;
// Set when the wallpaper surface exists; the fallback refresher wakes it
// alongside bar/hub so the background converges without input events.
var win_bg_g: ?*dvui.Window = null;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    // HubUi owns all hub state now (see HubUi.zig); main keeps only the
    // windows, backends, and shared pump.

    // Bar surface. Values carried over from the old dvui_app/layer_shell_opts.
    var ctx_bar = try ls.initWindow(.{
        .io = io,
        .environ_map = init.environ_map,
        .size = .{ .w = 0, .h = 50.0 },
        .title = "nshell - Nile bar",
        .transparent = true,
        .vsync = true,
    }, .{
        .anchors = .{ .top, .left, .right, null },
        .padding = .{ 4, 6, 6, 8 },
        .layer = .top,
        .exclusive_zone = 50,
        .namespace = State.bar_namespace,
    }, gpa);
    var backend_bar = ctx_bar.backend;
    defer backend_bar.deinit();
    defer ctx_bar.waylandCtx.deinit(gpa);

    // Hub surface: centered overlay with its own namespace. Always open.
    var ctx_hub = try ls.initWindow(.{
        .io = io,
        .environ_map = init.environ_map,
        .size = .{ .w = 150, .h = 50.0 },
        .title = "hub",
        .transparent = true,
        .persist_window_geometry = false,
        .vsync = true,
    }, .{
        .layer = .overlay,
        .namespace = State.shell_namespace,
        .center = .horizontal,
        .anchors = .{ .top, null, null, null },
        .padding = .{ 4, 0, 0, 0 },
    }, gpa);
    var backend_hub = ctx_hub.backend;
    // Only the bar backend quits SDL; the hub only destroys its own
    // window/renderer (same convention as secondary os windows).
    backend_hub.sdl_quit = false;
    defer backend_hub.deinit();
    defer ctx_hub.waylandCtx.deinit(gpa);

    // Background wallpaper surface: fullscreen background layer showing
    // ~/Pictures/wallpaper.png when it exists. Opaque, no keyboard focus,
    // exclusive_zone=-1 so it stretches under panels. Missing/unreadable
    // file (or a failed surface): no background window, shell runs on.
    const wallpaper_bytes: ?[]u8 = blk: {
        const home = init.environ_map.get("HOME");
        const path = Wallpaper.wallpaperPath(gpa, home) catch null;
        if (path) |p| {
            defer gpa.free(p);
            break :blk Wallpaper.loadWallpaperBytes(gpa, io, p);
        }
        break :blk null;
    };
    defer if (wallpaper_bytes) |b| gpa.free(b);
    if (wallpaper_bytes) |b| {
        std.log.info("wallpaper: loaded {d} bytes", .{b.len});
    } else {
        std.log.info("wallpaper: ~/Pictures/wallpaper.png not found, no background window", .{});
    }

    const BackendT = @TypeOf(backend_bar);
    var backend_bg: ?BackendT = null;
    defer if (backend_bg) |*b| b.deinit();
    const WaylandCtxT = @TypeOf(ctx_bar.waylandCtx.*);
    var wayland_bg: ?*WaylandCtxT = null;
    defer if (wayland_bg) |wc| wc.deinit(gpa);
    var have_bg = false;
    if (wallpaper_bytes != null) {
        const ctx_bg = ls.initWindow(.{
            .io = io,
            .environ_map = init.environ_map,
            .size = .{ .w = 1280, .h = 720 },
            .title = "nshell-wallpaper",
            .transparent = false,
            .persist_window_geometry = false,
            .vsync = true,
        }, .{
            .anchors = .{ .top, .left, .right, .bottom },
            .layer = .background,
            .exclusive_zone = -1,
            .namespace = State.wallpaper_namespace,
            .keyboard_interactivity = .none,
        }, gpa) catch |e| blk: {
            std.log.warn("wallpaper: background surface failed: {s}, continuing without it", .{@errorName(e)});
            break :blk null;
        };
        if (ctx_bg) |*c| {
            // initWindow returns a value; copy its fields out (same shape
            // as ctx_bar/ctx_hub) so optionals own them.
            backend_bg = c.backend;
            backend_bg.?.sdl_quit = false;
            wayland_bg = c.waylandCtx;
            have_bg = true;
        }
    }

    const C = @TypeOf(backend_bar).c;
    _ = C.SDL_EnableScreenSaver();

    // Transparent panels: keep the window fill transparent so per-pixel alpha
    // isn't overdrawn (same handling as the library's App path).
    var theme = dvui.Theme.builtin.adwaita_dark;
    theme.window.fill = .transparent;

    var bar_open = true;
    var win_bar = try dvui.Window.init(@src(), gpa, backend_bar.backend(), .{
        .theme = theme,
    });
    win_bar.open_flag = &bar_open;
    defer win_bar.deinit();
    // Fallback wakeup below refreshes both windows so live bar values
    // (speed, battery, bell count) converge without input events.
    win_bar_g = &win_bar;

    var hub_open = true;
    var win_hub = try dvui.Window.init(@src(), gpa, backend_hub.backend(), .{
        .theme = theme,
    });
    win_hub_g = &win_hub;
    win_hub.open_flag = &hub_open;
    defer win_hub.deinit();
    hub_ui = HubUi.init();

    // Background dvui window shares the panel theme; the wallpaper image
    // covers it fully so the fill never shows.
    var bg_open = true;
    var win_bg: ?dvui.Window = null;
    defer if (win_bg) |*w| w.deinit();
    if (have_bg) {
        win_bg = try dvui.Window.init(@src(), gpa, backend_bg.?.backend(), .{
            .theme = theme,
        });
        win_bg.?.open_flag = &bg_open;
        win_bg_g = &win_bg.?;
    }

    try state.initWithWakeup(gpa, io, &win_bar, &requestDvuiRefresh);
    defer state.deinit();
    // Worker-driven focus: compositor pushes store straight into the hub
    // flag (see State.bindHubFocus). Must precede the worker spawn below.
    state.bindHubFocus(&hub_ui.hub_keyboard_focused);
    // Populate launcher list (uses arena alloc, non-fatal if dirs missing).
    state.launcher.loadList(init) catch |e| std.log.warn("launcher load: {s}", .{@errorName(e)});

    // Worker after init (it spins until `inited`), cancelled before deinit
    // frees the model: LIFO defers run cancel first.
    var a = io.async(State.worker, .{ &state, io });
    defer a.cancel(io);

    var ref = io.async(struct {
        pub fn refresh(io_: std.Io) void {
            while (true) {
                // Fallback wakeup on the shared Net cadence: worker pushes
                // already wake the loop on change, but snapshots also need
                // to flow (and spinners/animations need frames) when
                // nothing pushes. Matches HubUi's steady panel timer. All
                // windows refresh: the bar carries live speed/battery/bell
                // values that would otherwise stale between input events.
                io_.sleep(.fromMilliseconds(@intCast(State.Net.refresh_ms)), .awake) catch {
                    return;
                };
                dvui.refresh(win_hub_g, @src(), null);
                dvui.refresh(win_bar_g, @src(), null);
                if (win_bg_g) |w| dvui.refresh(w, @src(), null);
            }
        }
    }.refresh, .{io});
    defer ref.cancel(io);

    var interrupted = false;
    // Single app lifetime: closing any window tears down all surfaces.
    // (Per-window lifetimes would leave the other layer surfaces mapped
    // with a frozen last frame after this function returns one window's
    // defers.)
    while (bar_open and hub_open and (!have_bg or bg_open)) {
        if (ctx_bar.waylandCtx.should_close or ctx_hub.waylandCtx.should_close) break;
        if (have_bg and wayland_bg.?.should_close) break;

        const t_bar = if (bar_open) win_bar.beginWait(interrupted) else 0;
        const t_hub = if (hub_open) win_hub.beginWait(interrupted) else 0;
        const t_bg: i128 = if (have_bg and bg_open) win_bg.?.beginWait(interrupted) else 0;

        if (have_bg) {
            try pumpEvents3(&backend_bar, &win_bar, &backend_hub, &win_hub, &backend_bg.?, &win_bg.?);
        } else {
            try pumpEvents(&backend_bar, &win_bar, &backend_hub, &win_hub);
        }

        var end_bar: ?u32 = null;
        if (bar_open) {
            try win_bar.begin(t_bar);
            _ = try frame();
            end_bar = try win_bar.end(.{});
        }

        var end_hub: ?u32 = null;
        if (hub_open) {
            try win_hub.begin(t_hub);
            _ = try hub_ui.hubFrame(&state, io, ctx_hub.waylandCtx, &win_hub);
            end_hub = try win_hub.end(.{});
        }

        var end_bg: ?u32 = null;
        if (have_bg and bg_open) {
            try win_bg.?.begin(t_bg);
            _ = try wallpaperFrame(wallpaper_bytes.?);
            end_bg = try win_bg.?.end(.{});
        }

        if (!bar_open or !hub_open) break;
        if (have_bg and !bg_open) break;

        const wait_bar = if (bar_open) win_bar.waitTime(end_bar) else std.math.maxInt(u32);
        const wait_hub = if (hub_open) win_hub.waitTime(end_hub) else std.math.maxInt(u32);
        const wait_bg = if (have_bg and bg_open) win_bg.?.waitTime(end_bg) else std.math.maxInt(u32);
        interrupted = try backend_bar.waitEventTimeout(@min(wait_bar, @min(wait_hub, wait_bg)));
    }
    return 0;
}

fn truncateTitle(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    // truncate at max, add ellipsis
    if (max < 3) return s[0..max];
    return s[0 .. max - 1];
}

// The bar button only arms the toggle; HubUi.toggleNetworkMenu runs at
// the top of the next hubFrame (hub window context) so the resize
// animation registers on the right window. See HubUi.net_toggle_pending.
fn toggleNetworkMenu() void {
    hub_ui.net_toggle_pending = true;
}

fn frame() !dvui.App.Result {
    state.update();

    var t = &dvui.currentWindow().theme;

    // Scale knob for the bar: workspace numbers set the type size, and icon
    // glyphs render at the same size (see icon_px below).
    const num_font = t.font_mono.withWeight(.bold).withSize(11.0);
    const icon_px: f32 = num_font.size * 2;

    var outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
        .background = false,
    });
    defer outer.deinit();

    {
        var left = dvui.box(
            @src(),
            .{ .dir = .horizontal, .equal_space = true },
            .{
                .background = true,
                .color_fill = t.color(.content, .fill),
                .color_border = t.color(.content, .text).opacity(0.15),
                .border = .all(1),
                .corners = .all(10),
                .min_size_content = .{ .h = 48.0, .w = (32 * 9) + (6 * 7) },
                .padding = .fromSize(.{ .w = 4 }),
                .gravity_y = 0.5,
            },
        );
        defer left.deinit();

        for (state.workspaces, 0..) |w, i| {
            var btn: dvui.ButtonWidget = undefined;
            btn.init(@src(), .{}, .{
                .background = true,
                .color_fill = if (w.current)
                    t.color(.highlight, .fill)
                else
                    t.color(.content, .fill).lighten(10),
                .color_fill_hover = if (w.current)
                    t.color(.highlight, .fill).lighten(-5)
                else
                    t.color(.content, .fill).lighten(5),
                .gravity_y = 0.5,
                .corners = .all(10),
                .padding = .all(0),
                .id_extra = i,
                .min_size_content = .{ .w = 32, .h = 32 },
                .max_size_content = .{ .w = 32, .h = 32 },
            });
            defer btn.deinit();
            btn.drawBackground();
            btn.processEvents();
            if (btn.clicked()) {
                state.switchWorkspace(w.id);
            }
            dvui.labelNoFmt(@src(), &.{'0' + w.number}, .{
                .align_x = 0.5,
                .align_y = 0.55,
            }, .{
                .font = num_font,
                .gravity_y = 0.5,
                .gravity_x = 0.5,
                .expand = .both,
                .padding = .all(0),
            });
        }
    }

    _ = dvui.spacer(@src(), .{
        .expand = .horizontal,
    });

    {
        var right = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{
                .background = true,
                .color_fill = t.color(.content, .fill),
                .color_border = t.color(.content, .text).opacity(0.15),
                .border = .all(1),
                .corners = .all(10),
                .min_size_content = .{ .h = 48.0 },
                .padding = .fromSize(.{ .w = 8 }),
                .gravity_y = 0.5,
            },
        );
        defer right.deinit();

        const nst = state.net.status();
        const pst = state.power.status();
        const small = t.font_body.withSize(10.0);
        // One comptime call per icon (not a runtime-selected enum): tabler
        // embeds only referenced icons, so the selection stays explicit.
        // Smoothed SSAA raster (see Icons): rasterize at the display size,
        // show with linear sampling.

        // Bluetooth: hidden without an adapter, dimmed when off.
        if (nst.bt_present) {
            const bt_tint: dvui.Color = if (nst.bt_powered) .white else t.color(.content, .text).opacity(0.35);
            if (Icons.iconPx(.bluetooth, icon_px, bt_tint) catch null) |c| {
                _ = dvui.image(@src(), Icons.pixelImage(c), .{
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = 32, .h = 32 },
                    .expand = .none,
                });
            }
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });
        }

        // Link state: globe on ethernet, globe_off with no router, wifi
        // bars otherwise — yellowed when linked but offline (same state
        // as the control-center alert). The button opens the network menu.
        const online = State.Net.online(nst.connectivity);
        const net_crisp: ?Icons.Icon = if (nst.eth_up)
            Icons.iconPx(.globe, icon_px, .white) catch null
        else if (nst.connected)
            switch (State.Net.barsForStrength(nst.strength)) {
                0 => Icons.iconPx(.wifi_off, icon_px, .white) catch null,
                1 => Icons.iconPx(.wifi_0, icon_px, if (online) .white else .yellow) catch null,
                2 => Icons.iconPx(.wifi_1, icon_px, if (online) .white else .yellow) catch null,
                3 => Icons.iconPx(.wifi_2, icon_px, if (online) .white else .yellow) catch null,
                else => Icons.iconPx(.wifi, icon_px, if (online) .white else .yellow) catch null,
            }
        else
            Icons.iconPx(.globe_off, icon_px, t.color(.content, .text).opacity(0.5)) catch null;

        // Manual button composition (mirrors dvui.buttonIcon): the 32px box
        // keeps the hit area, but the glyph renders at icon_px so it tracks
        // the workspace number size instead of filling the button.
        {
            var nbtn: dvui.ButtonWidget = undefined;
            nbtn.init(@src(), .{
                .draw_focus = false,
            }, .{
                .color_fill = t.color(.content, .fill),
                .corners = .all(10),
                .padding = .all(0),
                .min_size_content = .{ .w = 32, .h = 32 },
                .max_size_content = .{ .w = 32, .h = 32 },
                .gravity_y = 0.5,
            });
            defer nbtn.deinit();
            nbtn.processEvents();
            nbtn.drawBackground();
            if (net_crisp) |c| {
                _ = dvui.image(@src(), Icons.pixelImage(c), .{
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = icon_px, .h = icon_px },
                    .expand = .none,
                });
            }
            if (nbtn.clicked()) toggleNetworkMenu();
        }

        // Link use: down/up rates while a route exists. Hidden offline so
        // the globe_off state stays uncluttered.
        if (nst.eth_up or nst.connected) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });
            var dbuf: [32]u8 = undefined;
            var ubuf: [32]u8 = undefined;
            const dtxt = State.Net.formatSpeed(&dbuf, nst.down_bps);
            const utxt = State.Net.formatSpeed(&ubuf, nst.up_bps);
            if (Icons.iconPx(.arrow_down, 14, t.color(.content, .text).opacity(0.7)) catch null) |c| {
                _ = dvui.image(@src(), Icons.pixelImage(c), .{
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .expand = .none,
                });
            }
            dvui.labelNoFmt(@src(), dtxt, .{}, .{ .font = small, .gravity_y = 0.5 });
            if (Icons.iconPx(.arrow_up, 14, t.color(.content, .text).opacity(0.7)) catch null) |c| {
                _ = dvui.image(@src(), Icons.pixelImage(c), .{
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = 14, .h = 14 },
                    .expand = .none,
                });
            }
            dvui.labelNoFmt(@src(), utxt, .{}, .{ .font = small, .gravity_y = 0.5 });
        }

        // Notifications: bell plus unread count; clicking clears (stub
        // behavior until a daemon feed lands — see Notif.zig).
        {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });
            var bbtn: dvui.ButtonWidget = undefined;
            bbtn.init(@src(), .{ .draw_focus = false }, .{
                .color_fill = t.color(.content, .fill),
                .corners = .all(10),
                .padding = .all(0),
                .min_size_content = .{ .w = 32, .h = 32 },
                .max_size_content = .{ .w = 32, .h = 32 },
                .gravity_y = 0.5,
            });
            defer bbtn.deinit();
            bbtn.processEvents();
            bbtn.drawBackground();
            if (Icons.iconPx(.bell, icon_px, .white) catch null) |c| {
                _ = dvui.image(@src(), Icons.pixelImage(c), .{
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = icon_px, .h = icon_px },
                    .expand = .none,
                });
            }
            if (bbtn.clicked()) state.notif.clear();
            const n_unread = state.notif.count();
            if (n_unread > 0) {
                var nbuf: [16]u8 = undefined;
                const ntxt = std.fmt.bufPrint(&nbuf, "{d}", .{n_unread}) catch "?";
                dvui.labelNoFmt(@src(), ntxt, .{}, .{ .font = small, .gravity_y = 0.5 });
            }
        }

        // Battery: hidden without one (desktop). Idle shows the level
        // icon in text color; charging greens with the charging icon;
        // under 5% reds with the need-charge icon.
        if (pst.present) {
            _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 } });
            const batt: ?Icons.Icon = if (pst.charging)
                Icons.iconPx(.battery_charging, icon_px, dvui.Color.green) catch null
            else if (pst.percent < 5)
                Icons.iconPx(.battery_charging_2, icon_px, dvui.Color.red) catch null
            else if (pst.percent < 25)
                Icons.iconPx(.battery_1, icon_px, .white) catch null
            else if (pst.percent < 50)
                Icons.iconPx(.battery_2, icon_px, .white) catch null
            else if (pst.percent < 75)
                Icons.iconPx(.battery_3, icon_px, .white) catch null
            else
                Icons.iconPx(.battery_4, icon_px, .white) catch null;
            if (batt) |c| {
                _ = dvui.image(@src(), Icons.pixelImage(c), .{
                    .gravity_y = 0.5,
                    .min_size_content = .{ .w = icon_px, .h = icon_px },
                    .expand = .none,
                });
            }
            var pbuf: [8]u8 = undefined;
            const ptxt = std.fmt.bufPrint(&pbuf, "{d}%", .{pst.percent}) catch "?";
            dvui.labelNoFmt(@src(), ptxt, .{}, .{ .font = small, .gravity_y = 0.5 });
        }
    }

    return .ok;
}
