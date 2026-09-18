const std = @import("std");

// Wallpaper helpers (pure filesystem, no dvui): resolve
// ~/Pictures/wallpaper.png and load its bytes. Only stb-compatible
// raster reaches dvui.imageFile, same contract as launcher icons.
//
// Mirrors State.wallpaper_namespace ("nshell-wallpaper") and
// compositor/common/shell_domain.zig: wallpaper_namespace.

/// Max wallpaper file size (32 MiB): larger files are ignored so a
/// stray dump in ~/Pictures can't OOM the shell at startup.
pub const max_wallpaper_bytes: usize = 32 * 1024 * 1024;

/// Join `$HOME/Pictures/wallpaper.png`. Returns null when home is null
/// or empty. Caller owns the result.
pub fn wallpaperPath(alloc: std.mem.Allocator, home: ?[]const u8) !?[]u8 {
    const h = home orelse return null;
    if (h.len == 0) return null;
    return try std.fmt.allocPrint(alloc, "{s}/Pictures/wallpaper.png", .{h});
}

/// Load the wallpaper bytes at `path`. Returns null when the file is
/// missing, empty, too large, or unreadable. Caller owns the result.
pub fn loadWallpaperBytes(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > max_wallpaper_bytes) return null;
    const size: usize = @intCast(stat.size);
    var rd = file.reader(io, &.{});
    return rd.interface.readAlloc(alloc, size) catch null;
}

test "wallpaper path joins home" {
    const alloc = std.testing.allocator;
    const p = try wallpaperPath(alloc, "/home/u");
    defer if (p) |v| alloc.free(v);
    try std.testing.expect(p != null);
    try std.testing.expectEqualStrings("/home/u/Pictures/wallpaper.png", p.?);
}

test "wallpaper path null without home" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try wallpaperPath(alloc, null) == null);
    try std.testing.expect(try wallpaperPath(alloc, "") == null);
}

test "load missing wallpaper returns null" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expect(loadWallpaperBytes(alloc, io, "/tmp/nshell-no-such-wallpaper-xyz.png") == null);
}
