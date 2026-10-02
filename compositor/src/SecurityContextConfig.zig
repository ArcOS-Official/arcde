// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

//! User-configurable allow/block lists for the security-context global
//! filter (`Server.globalFilter`).
//!
//! Clients created with `wp_security_context_v1` only see globals the
//! compositor considers safe. The built-in lists in `Server.zig` cover the
//! known protocols; this config adjusts them per interface name:
//!
//! ```json
//! {
//!   "allow": ["zwlr_screencopy_manager_v1"],
//!   "block": ["zwp_virtual_keyboard_manager_v1"]
//! }
//! ```
//!
//! Loaded once at startup from `$XDG_CONFIG_HOME/nile/security-context.json`
//! or `~/.config/nile/security-context.json`. A missing file keeps the
//! built-in lists; unknown fields are ignored.

const SecurityContextConfig = @This();

const std = @import("std");
const mem = std.mem;
const log = std.log;
const util = @import("util.zig");
const Io = std.Io;

/// Interface names exposed to security-context clients in addition to the
/// built-in allowlist. An entry here also overrides a built-in block entry.
allow: []const []const u8 = &.{},

/// Interface names withheld from security-context clients. Wins over both
/// `allow` and the built-in allowlist.
block: []const []const u8 = &.{},

/// Arena backing `allow`/`block` when loaded from JSON.
arena: ?*std.heap.ArenaAllocator = null,

const File = struct {
    allow: ?[]const []const u8 = null,
    block: ?[]const []const u8 = null,
};

pub fn allowed(config: *const SecurityContextConfig, name: []const u8) bool {
    for (config.allow) |entry| {
        if (mem.eql(u8, name, entry)) return true;
    }
    return false;
}

pub fn blocked(config: *const SecurityContextConfig, name: []const u8) bool {
    for (config.block) |entry| {
        if (mem.eql(u8, name, entry)) return true;
    }
    return false;
}

/// Parse `contents` as the config file format, replacing any previous
/// configuration. On parse failure the previous configuration is kept.
pub fn loadFromSlice(config: *SecurityContextConfig, gpa: mem.Allocator, contents: []const u8) !void {
    const parsed = try std.json.parseFromSlice(File, gpa, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    config.deinit(gpa);
    // The parsed strings live in the arena: take ownership instead of
    // parsed.deinit(), which would free them.
    config.arena = parsed.arena;
    config.allow = parsed.value.allow orelse &.{};
    config.block = parsed.value.block orelse &.{};
    for (config.allow) |allow_entry| {
        for (config.block) |block_entry| {
            if (mem.eql(u8, allow_entry, block_entry)) {
                log.warn("security-context config: {s} listed in both allow and block; block wins", .{allow_entry});
            }
        }
    }
}

/// Load from file path. Returns an error if the file cannot be read.
pub fn loadFromFile(config: *SecurityContextConfig, gpa: mem.Allocator, path: []const u8) !void {
    const io = Io.Threaded.global_single_threaded.io();
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const contents = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(contents);
    try config.loadFromSlice(gpa, contents);
    log.info("security-context config from {s}: {d} allow, {d} block", .{ path, config.allow.len, config.block.len });
}

/// Load from `$XDG_CONFIG_HOME/nile/security-context.json`, falling back to
/// `~/.config/nile/security-context.json`. A missing file keeps defaults.
pub fn loadFromXdg(config: *SecurityContextConfig, gpa: mem.Allocator) void {
    const xdg_opt = std.c.getenv("XDG_CONFIG_HOME");
    const home_opt = std.c.getenv("HOME");
    const path: []const u8 = if (xdg_opt) |xdg| blk: {
        break :blk std.fs.path.join(gpa, &.{ mem.sliceTo(xdg, 0), "nile/security-context.json" }) catch return;
    } else if (home_opt) |home| blk: {
        break :blk std.fs.path.join(gpa, &.{ mem.sliceTo(home, 0), ".config/nile/security-context.json" }) catch return;
    } else return;
    defer gpa.free(path);
    config.loadFromFile(gpa, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("security-context config {s}: {}", .{ path, err }),
    };
}

pub fn deinit(config: *SecurityContextConfig, gpa: mem.Allocator) void {
    if (config.arena) |arena| {
        arena.deinit();
        gpa.destroy(arena);
    }
    config.* = .{};
}

test "allow and block lists with block precedence" {
    const gpa = std.testing.allocator;
    var config: SecurityContextConfig = .{};
    defer config.deinit(gpa);
    try config.loadFromSlice(gpa,
        \\{"allow": ["wl_compositor", "zwlr_screencopy_manager_v1"], "block": ["wl_compositor"]}
    );
    try std.testing.expect(config.blocked("wl_compositor"));
    try std.testing.expect(config.allowed("zwlr_screencopy_manager_v1"));
    try std.testing.expect(!config.allowed("wl_seat"));
    try std.testing.expect(!config.blocked("wl_seat"));
}

test "empty config and unknown fields" {
    const gpa = std.testing.allocator;
    var config: SecurityContextConfig = .{};
    defer config.deinit(gpa);
    try config.loadFromSlice(gpa, "{}");
    try std.testing.expect(!config.allowed("wl_seat"));
    try config.loadFromSlice(gpa, "{\"future_field\": 1, \"block\": [\"wp_drm_lease_v1\"]}");
    try std.testing.expect(config.blocked("wp_drm_lease_v1"));
    try std.testing.expect(!config.blocked("wl_seat"));
    try std.testing.expect(!config.allowed("wp_drm_lease_v1"));
}

test "invalid json keeps previous config" {
    const gpa = std.testing.allocator;
    var config: SecurityContextConfig = .{};
    defer config.deinit(gpa);
    try config.loadFromSlice(gpa, "{\"block\": [\"wl_seat\"]}");
    if (config.loadFromSlice(gpa, "{")) |_| {
        return error.ExpectedParseFailure;
    } else |_| {}
    try std.testing.expect(config.blocked("wl_seat"));
}
