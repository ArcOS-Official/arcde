//! Geometry for the screen-share frame compositor, kept in its own
//! dependency-free file so it can be unit tested without standing up a
//! wlroots scene, a renderer or a server (`ShareScene.zig` needs all three,
//! which is why this is not simply a section of that file).
//!
//! Everything here is pure integer arithmetic on layout coordinates.

const std = @import("std");

/// An axis-aligned box. `w`/`h` are 0 when there is no area, matching how
/// wlroots reports a never-mapped window.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Intersect a window box (layout coordinates) with the shared view, and
/// return the result in view-local coordinates (origin at 0,0).
///
/// Returns null when they do not overlap, which is the "skip this window"
/// case. Deliberately strict about empty input: a zero-area rect renders as
/// nothing, so allowing one through would silently leak the very window the
/// black box was meant to hide.
pub fn clipToView(win: Rect, view: Rect) ?Rect {
    if (win.w <= 0 or win.h <= 0 or view.w <= 0 or view.h <= 0) return null;

    // Shift into view-local space. lx/ly may be negative for a window that
    // straddles the left/top edge.
    const lx = win.x - view.x;
    const ly = win.y - view.y;

    const x0 = @max(0, lx);
    const y0 = @max(0, ly);
    const x1 = @min(view.w, lx + win.w);
    const y1 = @min(view.h, ly + win.h);
    if (x1 <= x0 or y1 <= y0) return null;

    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// True when two boxes share any area. Decides which windows are hideable on
/// a shared screen: a window that is not on that screen is already absent
/// from the image, so offering to hide it would be a lie.
pub fn overlaps(a: Rect, b: Rect) bool {
    if (a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0) return false;
    return a.x < b.x + b.w and b.x < a.x + a.w and
        a.y < b.y + b.h and b.y < a.y + a.h;
}

test "clipToView: fully inside the view" {
    const got = clipToView(
        .{ .x = 100, .y = 50, .w = 200, .h = 100 },
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
    ).?;
    try std.testing.expectEqual(@as(i32, 100), got.x);
    try std.testing.expectEqual(@as(i32, 50), got.y);
    try std.testing.expectEqual(@as(i32, 200), got.w);
    try std.testing.expectEqual(@as(i32, 100), got.h);
}

test "clipToView: an offset view origin shifts the result" {
    // Second monitor at x=1920: a window at x=1950 must land at 30 locally.
    // Left as 1950 it would fall outside the 1920-wide frame entirely.
    const got = clipToView(
        .{ .x = 1950, .y = 10, .w = 100, .h = 50 },
        .{ .x = 1920, .y = 0, .w = 1920, .h = 1080 },
    ).?;
    try std.testing.expectEqual(@as(i32, 30), got.x);
    try std.testing.expectEqual(@as(i32, 10), got.y);
    try std.testing.expectEqual(@as(i32, 100), got.w);
}

test "clipToView: right edge truncates without going negative" {
    const got = clipToView(
        .{ .x = 1800, .y = 0, .w = 400, .h = 100 },
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
    ).?;
    try std.testing.expectEqual(@as(i32, 1800), got.x);
    try std.testing.expectEqual(@as(i32, 120), got.w);
}

test "clipToView: left edge truncates on both sides" {
    const got = clipToView(
        .{ .x = -50, .y = 0, .w = 200, .h = 100 },
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
    ).?;
    try std.testing.expectEqual(@as(i32, 0), got.x);
    try std.testing.expectEqual(@as(i32, 150), got.w);
}

test "clipToView: bottom-right corner truncates both axes" {
    const got = clipToView(
        .{ .x = 1800, .y = 1000, .w = 400, .h = 400 },
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
    ).?;
    try std.testing.expectEqual(@as(i32, 120), got.w);
    try std.testing.expectEqual(@as(i32, 80), got.h);
}

test "clipToView: disjoint returns null" {
    try std.testing.expect(clipToView(
        .{ .x = 5000, .y = 0, .w = 100, .h = 100 },
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
    ) == null);
}

test "clipToView: empty rects never yield a zero-area black box" {
    // The leak this guards: a zero-area rect draws nothing, so the window it
    // was meant to hide stays visible in the share.
    try std.testing.expect(clipToView(
        .{ .x = 10, .y = 10, .w = 0, .h = 50 },
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
    ) == null);
    try std.testing.expect(clipToView(
        .{ .x = 10, .y = 10, .w = 50, .h = 0 },
        .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
    ) == null);
    try std.testing.expect(clipToView(
        .{ .x = 10, .y = 10, .w = 50, .h = 50 },
        .{ .x = 0, .y = 0, .w = 0, .h = 1080 },
    ) == null);
}

test "overlaps: partial and full containment, but not flush edges" {
    const view = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expect(overlaps(.{ .x = 50, .y = 50, .w = 50, .h = 50 }, view));
    try std.testing.expect(overlaps(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, view));
    try std.testing.expect(overlaps(.{ .x = 90, .y = 90, .w = 20, .h = 20 }, view));
    // Exactly flush on the right edge: zero shared area.
    try std.testing.expect(!overlaps(.{ .x = 100, .y = 0, .w = 50, .h = 50 }, view));
    // Diagonally touching only at a corner.
    try std.testing.expect(!overlaps(.{ .x = 100, .y = 100, .w = 10, .h = 10 }, view));
}

test "overlaps: zero-area rects never count" {
    const view = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expect(!overlaps(.{ .x = 10, .y = 10, .w = 0, .h = 50 }, view));
}