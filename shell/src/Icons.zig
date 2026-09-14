const std = @import("std");
const dvui = @import("dvui");
const tabler = @import("tabler");

// Anti-aliased icons over tabler-zig's supersampled raster pipeline.
//
// Why this exists: dvui's TVG path (`dvui.icon`) hardcodes its edge
// feather (1px in `renderIcon`, `Path.strokeTriangles`, and the TVG
// round join/cap discs), so vector icons always render smoothed and
// there is no knob to turn that off — and no way to match the shell's
// tinting either. Instead we rasterize via `tabler.outlineRaster`
// (true 4x SSAA) and display with `dvui.image` under linear sampling,
// which keeps the smoothed edges on any fractional placement or scaling.
//
// `tint` is baked at raster time (and part of the cache key) because
// `dvui.image` has no tint stage — pass the text/fill color the icon
// sits on, as before with `dvui.icon`'s white defaults.
//
// Only valid between `Window.begin` and `Window.end`. Returned bytes
// live in dvui's per-window data store; do not free them.

pub const Icon = struct {
    rgba: []const u8,
    w: u32,
    h: u32,
};

// Rasterize `icon` at `raster_px`, cache per window under
// `nshell-icon-<tag>-WxH-<tint>` (same data-store pattern `tabler`
// itself uses: the store copies, so the tabler-owned raster slice is
// safe to hand over directly, no dupe needed).
//
// `raster_px` is the LOGICAL display size: the raster is generated at
// raster_px * windowNaturalScale() so one raster pixel maps to one
// physical pixel. Displayed with linear sampling, the SSAA-smoothed
// edges stay smooth on hidpi downscale and fractional placement.
pub fn iconPx(comptime icon: tabler.Outline, raster_px: f32, tint: dvui.Color) !Icon {
    const px = raster_px * dvui.windowNaturalScale();
    const r = try tabler.outlineRaster(icon, dvui.Size.all(px), tint);
    if (r.rgba.len == 0) return .{ .rgba = &.{}, .w = r.w, .h = r.h };

    const rgba = tint.toRGBA();
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "nshell-icon-{s}-{d}x{d}-{x}{x}{x}{x}", .{
        @tagName(icon), r.w, r.h, rgba[0], rgba[1], rgba[2], rgba[3],
    }) catch unreachable;
    const id = dvui.Id.zero.update("nshell-icon");
    if (dvui.dataGetSlice(null, id, key, []u8)) |stored| {
        return .{ .rgba = stored, .w = r.w, .h = r.h };
    }

    dvui.dataSetSlice(null, id, key, r.rgba);
    return .{ .rgba = dvui.dataGetSlice(null, id, key, []u8).?, .w = r.w, .h = r.h };
}

// Rasterize `icon` at `raster_px`, cache per window under
// `nshell-icon-<tag>-WxH-<tint>`. See iconPx for the logical-size /
// natural-scale contract.
pub fn iconPxFilled(comptime icon: tabler.Filled, raster_px: f32, tint: dvui.Color) !Icon {
    const px = raster_px * dvui.windowNaturalScale();
    const r = try tabler.filledRaster(icon, dvui.Size.all(px), tint);
    if (r.rgba.len == 0) return .{ .rgba = &.{}, .w = r.w, .h = r.h };

    const rgba = tint.toRGBA();
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "nshell-icon-{s}-{d}x{d}-{x}{x}{x}{x}", .{
        @tagName(icon), r.w, r.h, rgba[0], rgba[1], rgba[2], rgba[3],
    }) catch unreachable;
    const id = dvui.Id.zero.update("nshell-icon");
    if (dvui.dataGetSlice(null, id, key, []u8)) |stored| {
        return .{ .rgba = stored, .w = r.w, .h = r.h };
    }

    dvui.dataSetSlice(null, id, key, r.rgba);
    return .{ .rgba = dvui.dataGetSlice(null, id, key, []u8).?, .w = r.w, .h = r.h };
}

// `dvui.image` init opts for an Icon raster. Linear sampling keeps the
// SSAA-smoothed edges; nearest would stair-step them.
pub fn pixelImage(c: Icon) dvui.ImageInitOptions {
    return .{ .source = .{ .pixels = .{
        .rgba = c.rgba,
        .width = c.w,
        .height = c.h,
        .interpolation = .linear,
    } } };
}

// No refAllDecls block here on purpose: iconPx needs a window (mesh
// building + data store), which the link-light headless test builds
// don't have.
