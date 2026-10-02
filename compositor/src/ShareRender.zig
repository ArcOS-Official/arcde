//! Rasteriser for the composed share scene.
//!
//! Walks the composed tree's own children — which are exactly the rects and
//! buffers `ShareScene` emitted, already in stacking order — and replays
//! them into a `wlr.RenderPass` targeting the destination buffer.
//!
//! ## Why this iterates children rather than `forEachBuffer`
//!
//! `wlr_scene_node_for_each_buffer` skips `SceneRect` nodes entirely. The
//! black boxes that redact hidden windows *are* rects, so a forEachBuffer
//! pass would silently drop the one thing this whole feature exists to do.
//! Walking the children keeps rects and buffers on one code path.
//!
//! ## Texture caching
//!
//! `wlr_scene_buffer` exposes no texture accessor in wlroots 0.20, so the
//! only way from a scene buffer to something `wlr_render_pass_add_texture`
//! accepts is `wlr_Texture_from_buffer`. Doing that per buffer per frame
//! would re-import every window 30 times a second. Instead each source
//! `wlr_buffer` pointer is imported once and the texture reused until that
//! buffer stops appearing, which is the same reuse wlroots does internally
//! for `wlr_scene_output`.
//!
//! Entries are evicted after `cache_entry_frames` frames of absence rather
//! than the instant they go missing: a window that stops producing damage
//! keeps the same committed buffer for a long time, and destroying its
//! texture the frame it goes quiet would throw away the work.

const std = @import("std");
const wlr = @import("wlroots");
const log = std.log;

const server = &@import("main.zig").server;
const ShareScene = @import("ShareScene.zig");

/// Direct-mapped cache. Sized above any plausible simultaneous window
/// count; overflow just degrades to re-importing, never to a wrong frame.
const cache_len = 64;
/// Frames an unreferenced entry survives before its texture is released.
const cache_entry_frames: u64 = 240;

const Slot = struct {
    src: ?*wlr.Buffer = null,
    tex: ?*wlr.Texture = null,
    /// Frame generation this slot was last needed.
    seen: u64 = 0,
};

var cache: [cache_len]Slot = [_]Slot{.{}} ** cache_len;
var frame_gen: u64 = 0;

/// sRGB primaries, used for the render pass's colour tagging. The share
/// target is an sRGB-ish RGB buffer; declaring anything else would make
/// wlroots convert on the way in.
const srgb_primaries: wlr.color.Primaries = .{
    .red = .{ .x = 0.640, .y = 0.330 },
    .green = .{ .x = 0.300, .y = 0.600 },
    .blue = .{ .x = 0.150, .y = 0.060 },
    .white = .{ .x = 0.3127, .y = 0.3290 },
};

fn hashBuffer(b: *wlr.Buffer) usize {
    const addr: usize = @intFromPtr(b);
    return @intCast((addr >> 4) & (cache_len - 1));
}

/// Texture for `src`, importing it only if we do not already hold one.
fn textureFor(src: *wlr.Buffer) ?*wlr.Texture {
    const idx = hashBuffer(src);
    const slot = &cache[idx];
    if (slot.src == src) {
        if (slot.tex) |t| {
            slot.seen = frame_gen;
            return t;
        }
    }
    // Slot occupied by a different buffer: release it now rather than
    // waiting for the eviction sweep.
    if (slot.tex) |t| t.destroy();
    slot.* = .{};

    const t = wlr.Texture.fromBuffer(server.renderer, src) orelse {
        log.warn("share: could not import buffer as texture", .{});
        return null;
    };
    slot.* = .{ .src = src, .tex = t, .seen = frame_gen };
    return t;
}

fn evictStale() void {
    for (&cache) |*slot| {
        const tex = slot.tex orelse continue;
        if (frame_gen -% slot.seen < cache_entry_frames) continue;
        tex.destroy();
        slot.* = .{};
    }
}

pub fn releaseAll() void {
    for (&cache) |*slot| {
        if (slot.tex) |t| t.destroy();
        slot.* = .{};
    }
}

/// Composite the share scene into `target`. Returns false when there is
/// nothing composed or the pass could not be submitted, in which case the
/// caller must not hand the buffer on as if it held a frame.
pub fn render(target: *wlr.Buffer) bool {
    const tree = ShareScene.treeRoot() orelse return false;
    frame_gen +%= 1;

    const pass = server.renderer.beginBufferPass(target, null) catch |err| {
        log.warn("share: beginBufferPass failed: {}", .{err});
        return false;
    };

    var drew: usize = 0;
    var it = tree.children.iterator(.forward);
    while (it.next()) |node| {
        switch (node.type) {
            .rect => drawRect(pass, node),
            .buffer => if (drawBuffer(pass, node)) {
                drew += 1;
            },
            // We never emit trees at the top level; a tree here would mean
            // ShareScene changed shape and this walk is out of date.
            .tree => {},
        }
    }

    const ok = pass.submit();
    evictStale();
    if (!ok) {
        log.warn("share: render pass submit failed", .{});
        return false;
    }
    if (drew == 0) {
        log.debug("share: composed an empty frame", .{});
    }
    return true;
}

fn drawRect(pass: *wlr.RenderPass, node: *wlr.SceneNode) void {
    const rect = wlr.SceneRect.fromNode(node);
    const opts: wlr.RenderPass.RectOptions = .{
        .box = .{
            .x = node.x,
            .y = node.y,
            .width = @intCast(rect.width),
            .height = @intCast(rect.height),
        },
        .color = .{
            .r = rect.color[0],
            .g = rect.color[1],
            .b = rect.color[2],
            .a = rect.color[3],
        },
        .clip = null,
        // Scene rect colours are straight (non-premultiplied) alpha.
        .blend_mode = .none,
    };
    pass.addRect(&opts);
}

/// TextureOptions.luminance_multiplier is a bare `*const f32` in wlroots
/// 0.20 (not optional), and it must stay alive through submit().
const unity: f32 = 1.0;

fn drawBuffer(pass: *wlr.RenderPass, node: *wlr.SceneNode) bool {
    const sb = wlr.SceneBuffer.fromNode(node);
    const src = sb.buffer orelse return false;
    const tex = textureFor(src) orelse return false;

    // Must outlive the submit() at the end of render(), so a local is right.
    const alpha: f32 = sb.opacity;
    const opts: wlr.RenderPass.TextureOptions = .{
        .texture = tex,
        .src_box = sb.src_box,
        .dst_box = .{
            .x = node.x,
            .y = node.y,
            .width = @intCast(sb.dst_width),
            .height = @intCast(sb.dst_height),
        },
        .alpha = if (alpha < 1.0) &alpha else null,
        .clip = null,
        .transform = sb.transform,
        .filter_mode = .bilinear,
        .blend_mode = .premultiplied,
        .transfer_function = .srgb,
        .primaries = &srgb_primaries,
        .color_encoding = .identity,
        .color_range = .full,
        .luminance_multiplier = &unity,
        .wait_timeline = null,
        .wait_point = 0,
    };
    pass.addTexture(&opts);
    return true;
}