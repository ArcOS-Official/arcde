//! The PipeWire side of a screen share: one `pw_stream` publishing the
//! composed image from `ShareScene`.
//!
//! ## Shape
//!
//! The compositor owns the stream outright (see the decision that the
//! shell does nothing once a share is configured). So this module, not the
//! shell, creates the node, and `share_started` reports the node id the
//! recipient's app connects to.
//!
//! ## Where frames are made
//!
//! PipeWire allocates the buffers and hands one to us per frame. The render
//! callback wraps that pointer in a `wlr.Buffer` and calls `ShareRender`,
//! which rasterises the composed scene straight into it. There is no
//! intermediate frame copy anywhere on this path.
//!
//! ## Threading
//!
//! Main thread only, like the rest of the compositor: the wlroots renderer
//! and the scene graph are not thread-safe, and the render callback runs
//! inside `pshare_dispatch`, which we drive from a timer on the Wayland
//! event loop. `pshare_dispatch` is non-blocking (`pw_loop_iterate(..., 0)`),
//! so a 33ms timer bounds the frame rate without adding latency.

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const log = std.log;

const server = &@import("main.zig").server;
const Share = @import("Share.zig");
const ShareScene = @import("ShareScene.zig");
const ShareRender = @import("ShareRender.zig");
/// The struct itself, not the file namespace: `wrap` lives on the type.
const share_buffer = @import("ShareBuffer.zig").ShareBuffer;
const drm_format_xrgb8888 = @import("ShareBuffer.zig").drm_format_xrgb8888;
const Bank = @import("Bank.zig");

/// Frame pacing for the PipeWire graph. Matches ShareScene's own cap so the
/// scene is never rebuilt more often than it is rasterised.
const dispatch_interval_ms: u32 = 33;

/// Hard ceiling on the published frame size. A 5K or rotated output would
/// otherwise ask PipeWire for a ~50MB buffer per frame; sharing the screen
/// does not need full sensor resolution to be legible.
const max_stream_w: u32 = 1920;
const max_stream_h: u32 = 1080;

const Pshare = opaque {};

const RenderFn = *const fn (
    user: ?*anyopaque,
    dst: ?*anyopaque,
    stride: u32,
    width: u32,
    height: u32,
    drm_format: u32,
) callconv(.c) c_int;

extern fn pshare_create(
    name: [*:0]const u8,
    width: c_int,
    height: c_int,
    stride: u32,
    drm_format: u32,
    render: RenderFn,
    user: ?*anyopaque,
) ?*Pshare;
extern fn pshare_destroy(p: *Pshare) void;
extern fn pshare_dispatch(p: *Pshare) void;
extern fn pshare_node_id(p: *Pshare) u32;
extern fn pshare_connected(p: *Pshare) c_int;
extern fn pshare_render_failed(p: *Pshare) c_int;

/// Timer callback context. The event loop takes an opaque data pointer, so
/// the module owns a single instance rather than allocating one per stream.
const Ctx = struct {};

var ctx: Ctx = .{};
var stream: ?*Pshare = null;
var timer: ?*wl.EventSource = null;
var node_id: u32 = 0;
/// Set once `share_started` has been pushed for this stream, so the
/// consumer-connect edge is published exactly once.
var announced: bool = false;

/// Published frame ceiling, so a snapshot matches the live stream exactly.
pub fn maxStreamW() u32 {
    return max_stream_w;
}
pub fn maxStreamH() u32 {
    return max_stream_h;
}

pub fn isLive() bool {
    return stream != null;
}

pub fn nodeId() u32 {
    return node_id;
}

/// Called from Share when a share is confirmed. Idempotent: a second
/// confirmation while streaming just re-points the scene.
pub fn start() void {
    if (stream != null) {
        ShareScene.syncToSession(Share.nowMsPublic());
        return;
    }
    const size = ShareScene.viewSize();
    if (size.w == 0 or size.h == 0) {
        log.warn("share: nothing composed yet, cannot start stream", .{});
        return;
    }

    const w: u32 = @min(size.w, max_stream_w);
    const h: u32 = @min(size.h, max_stream_h);
    const stride: u32 = @intCast(std.mem.alignForward(usize, @as(usize, w) * 4, 16));

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "arc-screen-{d}", .{@as(u32, @intCast(node_id))}) catch "arc-screen";

    const p = pshare_create(
        name.ptr,
        @intCast(w),
        @intCast(h),
        stride,
        drm_format_xrgb8888,
        renderFrame,
        null,
    ) orelse {
        log.err("share: could not create the PipeWire stream", .{});
        return;
    };

    stream = p;
    node_id = pshare_node_id(p);
    announced = false;

    // addTimer takes no interval: the first expiry is scheduled separately.
    timer = server.wl_server.getEventLoop().addTimer(*Ctx, handleTick, &ctx) catch |err| blk: {
        log.err("share: no frame timer ({s}); the stream will only advance on other compositor activity", .{@errorName(err)});
        break :blk @as(?*wl.EventSource, null);
    };
    if (timer) |t| t.timerUpdate(dispatch_interval_ms) catch {};

    log.info("share: streaming {d}x{d} as PipeWire node {d}", .{ w, h, node_id });
}

/// Called from Share when the share ends.
pub fn stop() void {
    if (timer) |t| {
        t.remove();
        timer = null;
    }
    if (stream) |p| {
        pshare_destroy(p);
        stream = null;
    }
    // No announcement here: Share owns the share_stopped push, so it fires
    // even when no consumer ever attached.
    node_id = 0;
    announced = false;
}

fn handleTick(_: *Ctx) c_int {
    const p = stream orelse return 0;
    pshare_dispatch(p);

    // The graph only reaches PAUSED once a consumer links, so this is the
    // moment the recipient can actually attach. Publishing earlier would
    // show a live indicator for a stream nobody can watch.
    if (!announced and pshare_connected(p) != 0) {
        announced = true;
        if (Share.active()) |s| {
            Bank.broadcast(.{
                .share_started = .{
                    .node_id = pshare_node_id(p),
                    .kind = s.kind,
                    .id = s.id,
                },
            });
            log.info("share: consumer attached to node {d}", .{pshare_node_id(p)});
        }
    }
    return 0;
}

/// Rasterise the composed scene into one PipeWire buffer.
fn renderFrame(
    _: ?*anyopaque,
    dst: ?*anyopaque,
    stride: u32,
    width: u32,
    height: u32,
    drm_format: u32,
) callconv(.c) c_int {
    const raw = dst orelse return 0;
    const len = @as(usize, stride) * @as(usize, height);
    const sb = share_buffer.wrap(
        @ptrCast(raw),
        len,
        @intCast(width),
        @intCast(height),
        @intCast(stride),
        drm_format,
    ) catch return 0;
    defer sb.destroy();

    return if (ShareRender.render(&sb.buffer)) 1 else 0;
}