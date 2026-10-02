//! Screen-share session state for the bank protocol.
//!
//! Owns the authoritative answer to "is something being shared right now,
//! and what is it", and the `configure_share` / `share_started` /
//! `share_stopped` pushes that drive the shell's picker, config menu and
//! activity indicator.
//!
//! ## What this file does NOT do
//!
//! It does not move a single pixel. Frame production lives in the share
//! compositor (see `composeFrame` below and the PipeWire producer), and the
//! bank socket deliberately carries no frames — only share *state* and
//! on-demand thumbnails for the picker.
//!
//! ## Threading
//!
//! Main thread only, like everything else that walks `server.wm.windows`.
//! The bank socket thread marshals requests onto the main loop through
//! `queueAsync` before any of these entry points is called, so window ids
//! here are always safe to resolve.
//!
//! ## Hiding windows
//!
//! `Window.share_hidden` (see Window.zig) is set here and read only by the
//! frame compositor. It never disables `window.tree`, so a window hidden
//! from the recipient stays fully visible and interactive for the user —
//! the whole point of the feature.

const std = @import("std");
const wlr = @import("wlroots");
const log = @import("std").log;

const server = &@import("main.zig").server;
const Window = @import("Window.zig");
const Output = @import("Output.zig");
const Bank = @import("Bank.zig");
const ShareScene = @import("ShareScene.zig");
const ShareRender = @import("ShareRender.zig");
const ShareStream = @import("ShareStream.zig");
const share_buffer = @import("ShareBuffer.zig").ShareBuffer;
const drm_format_xrgb8888 = @import("ShareBuffer.zig").drm_format_xrgb8888;
const util = @import("util.zig");
const protocols = @import("bank").protocols.compositor;

/// Same clock as the internal helper; ShareStream needs it to re-point the
/// scene when a share is re-confirmed.
pub fn nowMsPublic() u64 {
    return nowMs();
}

fn nowMs() u64 {
    const ts = util.timestamp();
    return @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms));
}

pub const Kind = protocols.ShareKind;

/// The active share, or null when nothing is being shared. Main thread only.
pub const Session = struct {
    kind: Kind,
    /// Output id when `kind == .screen`, window id when `kind == .window`.
    id: u64,
    /// PipeWire node the recipient's app connects to. 0 until the producer
    /// is up (see Stage 4); the shell treats 0 as "not streamable yet".
    node_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

var session: ?Session = null;

pub fn active() ?Session {
    return session;
}

/// Resolve the compositor object a view id names, or null if it is gone
/// (output unplugged, window closed). The id namespace depends on `kind`,
/// so this must never be called without one.
fn resolve(kind: Kind, id: u64) ?union(enum) { output: *Output, window: *Window } {
    return switch (kind) {
        .screen => blk: {
            var it = server.om.outputs.iterator(.forward);
            while (it.next()) |out| {
                // Same derivation Bank.makeCompositorWindow uses: output ids
                // are the Output pointer value.
                if (@intFromPtr(out) == id) break :blk .{ .output = out };
            }
            break :blk null;
        },
        .window => blk: {
            const gen: u32 = @intCast(id >> 32);
            const idx: u32 = @intCast(id & 0xFFFFFFFF);
            const ref: Window.Ref = .{ .key = .{ .generation = gen, .index = idx } };
            const win = ref.get() orelse break :blk null;
            if (win.impl == .destroying) break :blk null;
            break :blk .{ .window = win };
        },
    };
}

/// Windows the user may choose to hide for `kind`/`id`: the ones actually
/// on that screen right now. A shared window has nothing to hide inside it,
/// so it contributes no items — matching the TODO ("only appear when the
/// view is a screen").
///
/// A window already on another workspace is not listed: it is not in the
/// shared image to begin with, so offering to hide it would be a lie.
fn collectHideable(kind: Kind, id: u64, alloc: std.mem.Allocator) ![]protocols.ShareItem {
    var items: std.ArrayList(protocols.ShareItem) = .empty;
    errdefer {
        for (items.items) |it| it.deinit(alloc);
        items.deinit(alloc);
    }

    if (kind == .window) return items.toOwnedSlice(alloc);

    const target = resolve(kind, id) orelse return items.toOwnedSlice(alloc);
    const out = switch (target) {
        .output => |o| o,
        .window => return items.toOwnedSlice(alloc),
    };
    const obox = out.current.box();
    if (obox.width == 0 or obox.height == 0) return items.toOwnedSlice(alloc);

    var it = server.wm.windows.iterator();
    while (it.next()) |win| {
        if (win.impl == .destroying or win.state == .init) continue;
        // Only what the recipient would actually see.
        if (win.rendering_requested.hidden) continue;
        if (win.wm_requested.workspace != server.workspace.currentWorkspace()) continue;
        const b = win.box;
        if (b.width == 0 or b.height == 0) continue;
        const overlaps = b.x < obox.x + obox.width and
            obox.x < b.x + b.width and
            b.y < obox.y + obox.height and
            obox.y < b.y + b.height;
        if (!overlaps) continue;

        const title = alloc.dupe(u8, if (win.getTitle()) |c| std.mem.sliceTo(c, 0) else "") catch continue;
        items.append(alloc, .{ .id = bankIdOf(win), .title = title }) catch {
            alloc.free(title);
            continue;
        };
    }
    return items.toOwnedSlice(alloc);
}

fn bankIdOf(win: *Window) u64 {
    return (@as(u64, win.ref.key.generation) << 32) | @as(u64, win.ref.key.index);
}

/// The shell picked a view: answer with `configure_share` carrying the
/// sub-views it may offer to hide. If the view has since disappeared
/// (output unplugged between picking and confirming) this silently does
/// nothing and the shell's picker times out.
pub fn beginConfigure(kind: Kind, id: u64, alloc: std.mem.Allocator) void {
    const items = collectHideable(kind, id, alloc) catch |err| {
        log.warn("bank: configure_share: collecting hideable windows failed: {}", .{err});
        return;
    };
    Bank.broadcast(.{ .configure_share = .{ .kind = kind, .id = id, .items = items } });
}

/// The user confirmed. Clear every previous window's flag first, then apply
/// the new set: the confirmed list is authoritative, so a re-confirm can
/// never leave a stale window hidden from a share the user has since
/// changed their mind about.
pub fn applyConfigured(kind: Kind, id: u64, hidden: []const u64) void {
    if (resolve(kind, id) == null) {
        log.warn("bank: share_configured: view {d} no longer exists", .{id});
        return;
    }

    clearAllFlags();

    for (hidden) |wid| {
        const gen: u32 = @intCast(wid >> 32);
        const idx: u32 = @intCast(wid & 0xFFFFFFFF);
        const ref: Window.Ref = .{ .key = .{ .generation = gen, .index = idx } };
        const win = ref.get() orelse continue;
        if (win.impl == .destroying) continue;
        win.share_hidden = true;
    }

    session = .{ .kind = kind, .id = id };
    log.info("bank: share started: {s} {d}, {d} window(s) hidden", .{
        @tagName(kind), id, hidden.len,
    });

    // Point the frame compositor at the new view and build its first image
    // immediately, so the recipient gets a real frame rather than a black
    // one while the 30fps cap catches up.
    ShareScene.init() catch |err| {
        log.err("bank: share: cannot create share scene: {}", .{err});
        session = null;
        clearAllFlags();
        return;
    };
    ShareScene.syncToSession(nowMs());
    ShareScene.markDirty();

    // Publish the image. ShareStream creates the PipeWire node and drives
    // ShareRender into it; share_started is pushed once a consumer links.
    ShareStream.start();

    // No share_started push yet: there is no PipeWire node to hand the
    // recipient until Stage 4 wires the producer. Announcing a share that
    // cannot be connected to would show the user a live indicator for a
    // stream nobody can watch.
}

/// Toggle one window's flag. Valid mid-share — this is what the activity
/// menu's per-window privacy toggle uses.
pub fn setWindowHidden(id: u64, hidden: bool) void {
    const gen: u32 = @intCast(id >> 32);
    const idx: u32 = @intCast(id & 0xFFFFFFFF);
    const ref: Window.Ref = .{ .key = .{ .generation = gen, .index = idx } };
    const win = ref.get() orelse {
        log.warn("bank: set_share_hidden: unknown window {d}", .{id});
        return;
    };
    win.share_hidden = hidden;
    // Rebuild *now*, not just mark dirty. A privacy change must not wait on
    // the next damage event: on an idle compositor there may not be one, and
    // the outgoing image would keep showing content the user just asked to
    // hide.
    ShareScene.rebuildNow(nowMs());
    log.info("bank: set_share_hidden {d} = {}", .{ id, hidden });
}

/// End the share and drop every window's flag. Idempotent: stopping when
/// nothing is shared is a no-op, so a double Stop (button + client
/// disconnect) is harmless.
pub fn stop() void {
    if (session == null) return;
    clearAllFlags();
    session = null;
    // Tear the composed view down so a stopped share cannot keep
    // rendering the last image of the desktop.
    ShareStream.stop();
    ShareScene.deinit();
    // Announced here, not in ShareStream: the share is over as far as the
    // shell is concerned the moment the user stops it. Tying this to a
    // PipeWire consumer having attached would leave the activity indicator
    // lit forever whenever nothing was consuming the node.
    Bank.broadcast(.{ .share_stopped = {} });
    log.info("bank: share stopped", .{});
}

/// Called when the share goes away for a reason other than the user asking
/// (shared window closed, shared output unplugged) so the shell's indicator
/// cannot get stuck.
pub fn onSourceLost(kind: Kind, id: u64) void {
    const s = session orelse return;
    if (s.kind != kind or s.id != id) return;
    log.warn("share: source {s} {d} disappeared, stopping", .{ @tagName(kind), id });
    stop();
}

fn clearAllFlags() void {
    var it = server.wm.windows.iterator();
    while (it.next()) |win| win.share_hidden = false;
}

// ---------------------------------------------------------------------------
// Snapshot: the composed image, for verification and diagnostics.
// ---------------------------------------------------------------------------

/// Render the current share image into an owned RGBA8 buffer and broadcast it
/// as `share_frame`.
///
/// This exists so the composed image can be *checked* without a PipeWire
/// consumer: `ShareScene`, `ShareRender` and the redaction all run exactly as
/// they do for a live stream, because it is the same render path writing into
/// a different buffer. Anything that would break a real share -- a window's
/// buffer failing to import, the black box not being drawn, the scene being
/// empty -- shows up here as obviously wrong pixels.
///
/// `serial` is echoed back so a client can match request to reply. Runs on the
/// main thread (it touches the renderer and the scene graph).
pub fn snapshot(serial: u64, alloc: std.mem.Allocator) void {
    // No composed view (no share running) -> report an empty frame rather
    // than a stale one.
    if (ShareScene.treeRoot() == null) {
        Bank.broadcast(.{ .share_frame = .{ .serial = serial, .image = .{} } });
        return;
    }
    const size = ShareScene.viewSize();
    if (size.w == 0 or size.h == 0) {
        Bank.broadcast(.{ .share_frame = .{ .serial = serial, .image = .{} } });
        return;
    }

    const w: u32 = size.w;
    const h: u32 = size.h;
    const stride: usize = w * 4;
    const len = stride * h;

    const pixels = alloc.alloc(u8, len) catch {
        Bank.broadcast(.{ .share_frame = .{ .serial = serial, .image = .{} } });
        return;
    };
    // Black rather than uninitialised: a failed snapshot must not look like
    // random noise to whatever is inspecting it.
    @memset(pixels, 0);

    // ShareStream caps the stream at 1080p; match it so a snapshot and the
    // live image are comparable pixel for pixel.
    const capped_w: u32 = @min(w, ShareStream.maxStreamW());
    const capped_h: u32 = @min(h, ShareStream.maxStreamH());

    const sb = share_buffer.wrap(
        pixels.ptr,
        len,
        @intCast(capped_w),
        @intCast(capped_h),
        @intCast(stride),
        drm_format_xrgb8888,
    ) catch {
        alloc.free(pixels);
        Bank.broadcast(.{ .share_frame = .{ .serial = serial, .image = .{} } });
        return;
    };
    defer sb.destroy();

    const ok = ShareRender.render(&sb.buffer);
    if (!ok) {
        alloc.free(pixels);
        Bank.broadcast(.{ .share_frame = .{ .serial = serial, .image = .{} } });
        return;
    }

    // XRGB8888 -> RGBA8: the alpha byte is undefined, so set it opaque
    // rather than shipping whatever was in the buffer.
    var i: usize = 3;
    while (i < len) : (i += 4) pixels[i] = 0xFF;

    Bank.broadcast(.{
        .share_frame = .{
            .serial = serial,
            .image = .{
                .width = capped_w,
                .height = capped_h,
                .stride = @intCast(stride),
                .format = .rgba8,
                .data = pixels,
            },
        },
    });
}
