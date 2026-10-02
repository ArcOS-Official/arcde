//! Frame compositor for the active screen share.
//!
//! ## Why this exists
//!
//! The compositor has no public API that hands it output pixels — that is
//! what wlr-screencopy is for, and it is client-driven. So instead of asking
//! for a copy, this module *builds the picture itself*: it assembles a
//! private `wlr.Scene` that mirrors the real one, and that private scene is
//! what the share's capture source renders (see Share.zig / Server.zig).
//!
//! Two consequences, both intended:
//!
//!  * The user's own screen is never touched. It keeps using
//!    `server.scene` via `wlr_scene_output`. Redaction happens in *this*
//!    tree, so a window hidden from the recipient stays fully visible,
//!    clickable and typable for the person sitting at the machine.
//!  * `Window.share_hidden` is honoured by substituting an opaque black
//!    `wlr.SceneRect` covering the window's box, exactly as the feature
//!    asks ("a black box instead of its actual texture"). The wallpaper and
//!    anything behind the window are covered too, which is the point — a
//!    translucent placeholder would leak the window's shape.
//!
//! ## Layering
//!
//! The z-order below deliberately mirrors `Scene.zig`'s tree creation order
//! (creation order *is* stacking order in wlr_scene), and the window pass
//! mirrors `WindowManager.renderFinish` — bottom-to-top over
//! `rendering_requested.list`, with fullscreen windows split into their own
//! higher layer. If you change one, change the other; a drift here shows up
//! as a share whose popups draw under windows.
//!
//! ## Cadence
//!
//! `tick` rebuilds at most every `frame_interval_ms` (30fps) and only when
//! something actually changed, so an idle share costs nothing and a busy one
//! never rebuilds more than 30 times a second regardless of display refresh.

const std = @import("std");
const wlr = @import("wlroots");
const build_options = @import("build_options");
const log = std.log;

const server = &@import("main.zig").server;
const Window = @import("Window.zig");
const Output = @import("Output.zig");
const Share = @import("Share.zig");
const geom = @import("share_geom.zig");

/// Regeneration cap. 30fps is plenty for a screen share and is what the
/// portal producer was already paced at.
pub const frame_interval_ms: u64 = 33;

/// Opaque black. Alpha 1 matters: the rect must fully occlude whatever is
/// behind it.
const redact_color = [4]f32{ 0, 0, 0, 1 };

var scene: ?*wlr.Scene = null;
/// Child of `scene.tree` holding everything we emit. A dedicated subtree so
/// a rebuild can clear it wholesale without touching the scene root.
var root: ?*wlr.SceneTree = null;

/// Layout origin subtracted from every mirrored buffer, so the composed
/// image is exactly the shared view and nothing else.
var origin_x: i32 = 0;
var origin_y: i32 = 0;
var view_w: c_int = 0;
var view_h: c_int = 0;

var dirty: bool = true;
var last_build_ms: u64 = 0;

pub fn init() !void {
    if (scene != null) return;
    const s = try wlr.Scene.create();
    errdefer s.tree.node.destroy();
    const r = try s.tree.createSceneTree();
    scene = s;
    root = r;
    dirty = true;
}

pub fn deinit() void {
    if (scene) |s| {
        s.tree.node.destroy();
        scene = null;
    }
    root = null;
    dirty = true;
}

/// The composed scene's root node, for the renderer that rasterises it into
/// the PipeWire buffer.
///
/// Deliberately NOT wrapped in an `ext_image_capture_source_v1`: the
/// compositor owns the stream end to end, so nothing outside this process
/// ever needs a capture source, and publishing one would be a way for any
/// client to pull the (redacted) screen without going through the share
/// session at all.
pub fn rootNode() ?*wlr.SceneNode {
    if (root) |r| return &r.node;
    return null;
}

/// The composed tree, for the rasteriser. Its direct children are exactly
/// the things we emitted, in stacking order.
pub fn treeRoot() ?*wlr.SceneTree {
    return root;
}

/// Point the composer at a different view. Call when a share starts, stops
/// or is reconfigured for another output/window.
pub fn setView(ox: i32, oy: i32, w: c_int, h: c_int) void {
    if (ox == origin_x and oy == origin_y and w == view_w and h == view_h) return;
    origin_x = ox;
    origin_y = oy;
    view_w = w;
    view_h = h;
    dirty = true;
}

/// Something changed that the composed image depends on.
pub fn markDirty() void {
    dirty = true;
}

/// Called once per compositor frame tick. Rebuilds if dirty and the rate cap
/// has elapsed.
pub fn tick(now_ms: u64) void {
    if (!dirty) return;
    if (now_ms -% last_build_ms < frame_interval_ms) return;
    rebuild(now_ms);
}

/// Force a rebuild now, ignoring the cap. Used on start/stop, where the
/// first frame must not wait.
pub fn rebuildNow(now_ms: u64) void {
    rebuild(now_ms);
}

fn rebuild(now_ms: u64) void {
    const r = root orelse return;
    if (view_w <= 0 or view_h <= 0) {
        // Nothing to compose yet; an empty tree would capture as garbage.
        clear(r);
        dirty = false;
        last_build_ms = now_ms;
        return;
    }

    clear(r);

    // Base coat. Without it, any pixel not covered by a layer would come
    // from whatever the buffer happened to contain.
    if (r.createSceneRect(@intCast(view_w), @intCast(view_h), &redact_color)) |_| {} else |_| {}

    // Scene.zig creates the layer trees in stacking order; mirror exactly
    // that. Anything with no share-relevant content is cloned whole via
    // forEachBuffer, which needs no knowledge of what is inside.
    mirror(r, &server.scene.layers.background.node);
    mirror(r, &server.scene.layers.bottom.node);
    windows(r, .normal);
    mirror(r, &server.scene.layers.top.node);
    windows(r, .fullscreen);
    // The fullscreen layer also holds river shell surfaces that belong
    // above fullscreen windows; the windows in it were just emitted by
    // windows(.fullscreen) and must not be cloned twice.
    mirrorLayerSkippingOwned(r, server.scene.layers.fullscreen, .already_emitted);
    mirror(r, &server.scene.layers.overlay.node);
    // Popups live in their own top-most layer regardless of which window
    // owns them, so a share-hidden window's menus have to be dropped here
    // or they would float above its black box and give it away.
    mirrorLayerSkippingOwned(r, server.scene.layers.popups, .share_hidden);
    if (build_options.xwayland) mirror(r, &server.scene.layers.override_redirect.node);
    // Sibling of interactive_tree under the scene root, created after it, so
    // it sits above everything above.
    mirror(r, &server.scene.drag_icons.node);

    dirty = false;
    last_build_ms = now_ms;
}

/// Why a node that belongs to a window would be dropped when mirroring a
/// layer.
const Skip = enum {
    /// Already emitted by the window pass (fullscreen trees).
    already_emitted,
    /// Stand-in black rect was emitted instead; its popups must go too.
    share_hidden,
};

/// Which window, if any, owns this layer child. A layer's children are
/// exactly the window trees/subsurface trees parented into it, so identity
/// comparison is enough — and it avoids the fixed-capacity skip-set that a
/// pointer array would need (a busy session can have more windows than any
/// static array should assume).
fn owningWindow(node: *wlr.SceneNode) ?*Window {
    var it = server.wm.rendering_requested.list.iterator(.forward);
    while (it.next()) |n| {
        const win = switch (n.get()) {
            .window => |w| w,
            .shell_surface => continue,
        };
        if (&win.tree.node == node or &win.popup_tree.node == node) return win;
    }
    return null;
}

fn mirrorLayerSkippingOwned(r: *wlr.SceneTree, layer: *wlr.SceneTree, skip: Skip) void {
    var it = layer.children.iterator(.forward);
    while (it.next()) |child| {
        const win = owningWindow(child) orelse {
            mirror(r, child);
            continue;
        };
        switch (skip) {
            .already_emitted => if (!(win.wm_requested.fullscreen != null and !win.rendering_requested.hidden)) {
                mirror(r, child);
            },
            .share_hidden => if (!win.share_hidden) {
                mirror(r, child);
            },
        }
    }
}

const WindowPass = enum { normal, fullscreen };

/// Emit the window layer for one pass. Windows come bottom-to-top from
/// `rendering_requested.list`; that order is maintained by
/// `WindowManager.renderFinish`, which is the same list it stacks from.
fn windows(r: *wlr.SceneTree, pass: WindowPass) void {
    var it = server.wm.rendering_requested.list.iterator(.forward);
    while (it.next()) |node| {
        switch (node.get()) {
            .window => |win| emitWindow(r, win, pass),
            .shell_surface => {},
        }
    }
}

fn emitWindow(r: *wlr.SceneTree, win: *Window, pass: WindowPass) void {
    if (win.impl == .destroying) return;
    // The real tree is disabled for hidden and unmapped windows; mirror that
    // exactly so the share shows what the screen shows.
    if (win.rendering_requested.hidden) return;
    if (!(win.state == .mapped or win.state == .closing)) return;

    const is_fs = win.wm_requested.fullscreen != null and !win.rendering_requested.hidden;
    if ((pass == .fullscreen) != is_fs) return;

    const b = win.box;
    if (b.width <= 0 or b.height <= 0) return;

    if (win.share_hidden) {
        // Opaque black over the window's own box, clipped to the view so a
        // window straddling the output edge cannot spill outside the frame.
        // Popups belonging to a hidden window are dropped separately in
        // mirrorLayerSkippingOwned, or they would float above the black box.
        const area = geom.clipToView(
            .{ .x = b.x, .y = b.y, .w = b.width, .h = b.height },
            .{ .x = origin_x, .y = origin_y, .w = view_w, .h = view_h },
        ) orelse return;
        const rect = r.createSceneRect(area.w, area.h, &redact_color) catch return;
        rect.node.setPosition(area.x, area.y);
        return;
    }

    // "Everything, including decorations": the window tree already contains
    // its surface, subsurfaces, borders and decoration nodes, so mirroring
    // the whole node is both simplest and the most faithful.
    mirror(r, &win.tree.node);
    mirror(r, &win.popup_tree.node);
}

const MirrorCtx = struct {
    root: *wlr.SceneTree,
    ox: i32,
    oy: i32,
};

/// Clone every buffer under `node` into our tree, preserving each buffer's
/// source box, destination size, transform and opacity.
///
/// Opacity matters: `Window.applyAlpha` expresses window translucency
/// (animations, fading) purely as scene-buffer opacity, so dropping it would
/// make a fading window pop to full alpha in the share.
fn mirrorCb(buffer: *wlr.SceneBuffer, sx: c_int, sy: c_int, ctx: *MirrorCtx) void {
    const sb = ctx.root.createSceneBuffer(buffer.buffer) catch return;
    sb.setDestSize(buffer.dst_width, buffer.dst_height);
    sb.setSourceBox(&buffer.src_box);
    sb.setTransform(buffer.transform);
    if (buffer.opacity < 1.0) sb.setOpacity(buffer.opacity);
    sb.node.setPosition(sx - ctx.ox, sy - ctx.oy);
}

fn mirror(r: *wlr.SceneTree, node: *wlr.SceneNode) void {
    var ctx: MirrorCtx = .{ .root = r, .ox = origin_x, .oy = origin_y };
    node.forEachBuffer(*MirrorCtx, mirrorCb, &ctx);
}

fn clear(r: *wlr.SceneTree) void {
    var it = r.children.iterator(.forward);
    while (it.next()) |child| {
        child.destroy();
    }
}

/// Current view rectangle, for the PipeWire producer's buffer sizing.
pub fn viewSize() struct { w: u32, h: u32 } {
    return .{ .w = @intCast(@max(0, view_w)), .h = @intCast(@max(0, view_h)) };
}

/// Point the composer at whatever the active share session names. No-op
/// when nothing is shared.
pub fn syncToSession(now_ms: u64) void {
    const s = Share.active() orelse return;
    switch (s.kind) {
        .screen => {
            var it = server.om.outputs.iterator(.forward);
            while (it.next()) |out| {
                if (@intFromPtr(out) != s.id) continue;
                const b = out.current.box();
                setView(b.x, b.y, b.width, b.height);
                rebuildNow(now_ms);
                return;
            }
        },
        .window => {
            const gen: u32 = @intCast(s.id >> 32);
            const idx: u32 = @intCast(s.id & 0xFFFFFFFF);
            const ref: Window.Ref = .{ .key = .{ .generation = gen, .index = idx } };
            const win = ref.get() orelse return;
            setView(win.box.x, win.box.y, win.box.width, win.box.height);
            rebuildNow(now_ms);
            return;
        },
    }
}

/// Logged summary of the last rebuild; used by the bank debug path.
pub fn describe() void {
    log.info("share: composed {d}x{d} at {d},{d}", .{ view_w, view_h, origin_x, origin_y });
}
