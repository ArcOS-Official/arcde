const std = @import("std");

// The shell focus domain: every layer surface in these namespaces is shell
// UI (the bar + the hub overlay). The rules, enforced by the compositor:
//
// - Keyboard focus on ANY domain surface counts as shell focus (shared
//   domain: focusing one focuses the domain, so bar<->hub transitions
//   publish no shell_focus_changed edge).
// - Input pressed with the Win modifier (that matches no WM binding) is
//   detoured to the domain; foreign windows never observe Win-modified
//   input and cannot claim this privilege.
// - request_keyboard_focus may only target the domain (empty namespace =
//   topmost domain surface); anything else is rejected, never retargeted
//   at app windows or foreign overlays.
//
// Pure predicates so headless tests can pin the policy without wlroots.

/// Layer namespaces that belong to the shell. Mirrors the shell's own
/// constants (shell/src/State.zig: shell_namespace/bar_namespace).
pub const namespaces = [_][]const u8{ "nshell", "nshell-hub" };

/// Background wallpaper namespace. Mirrors the shell's own constant
/// (shell/src/State.zig: wallpaper_namespace). The wallpaper lives on
/// the background layer with keyboard_interactivity=none: it never
/// takes keyboard focus and never counts as shell focus. Tracked
/// separately from `namespaces` so shell-focus predicates stay false
/// for it while background-click handling can still recognize it.
pub const wallpaper_namespace: []const u8 = "nshell-wallpaper";

/// True when a layer namespace belongs to the shell domain.
pub fn isShellNamespace(ns: []const u8) bool {
    for (namespaces) |known| {
        if (std.mem.eql(u8, known, ns)) return true;
    }
    return false;
}

/// True when a layer namespace is the shell's background wallpaper.
pub fn isBackgroundNamespace(ns: []const u8) bool {
    return std.mem.eql(u8, ns, wallpaper_namespace);
}

/// True when a layer namespace is any shell-owned surface (interactive
/// domain or background wallpaper).
pub fn isShellOwnedNamespace(ns: []const u8) bool {
    return isShellNamespace(ns) or isBackgroundNamespace(ns);
}

/// Where a request_keyboard_focus call may land. Pure so both the
/// compositor handler and headless tests share one decision.
pub const RequestTarget = enum {
    /// Empty namespace: topmost mapped shell-domain surface.
    shell_topmost,
    /// Named shell-domain surface.
    shell_named,
};

/// Classify a focus-request namespace. Anything outside the domain is
/// rejected: requests can summon shell UI, never steal foreign focus.
pub fn resolveRequestTarget(namespace: []const u8) error{UnknownNamespace}!RequestTarget {
    if (namespace.len == 0) return .shell_topmost;
    if (isShellNamespace(namespace)) return .shell_named;
    return error.UnknownNamespace;
}

/// Shell overlay stays visible unless its output has a fullscreen window,
/// except exclusive-interactive panels which stay over fullscreen.
pub fn overlayVisible(fullscreen_on_output: bool, exclusive: bool) bool {
    return !fullscreen_on_output or exclusive;
}

test "shell domain namespaces" {
    try std.testing.expect(isShellNamespace("nshell"));
    try std.testing.expect(isShellNamespace("nshell-hub"));
    try std.testing.expect(!isShellNamespace(""));
    try std.testing.expect(!isShellNamespace("nshell-hub-evil"));
    try std.testing.expect(!isShellNamespace("firefox"));
}

test "request target resolution" {
    try std.testing.expectEqual(RequestTarget.shell_topmost, try resolveRequestTarget(""));
    try std.testing.expectEqual(RequestTarget.shell_named, try resolveRequestTarget("nshell"));
    try std.testing.expectEqual(RequestTarget.shell_named, try resolveRequestTarget("nshell-hub"));
    try std.testing.expectError(error.UnknownNamespace, resolveRequestTarget("nshell-hub-evil"));
    try std.testing.expectError(error.UnknownNamespace, resolveRequestTarget("wobble"));
}

test "overlay visibility over fullscreen" {
    try std.testing.expect(overlayVisible(false, false));
    try std.testing.expect(overlayVisible(false, true));
    try std.testing.expect(!overlayVisible(true, false));
    try std.testing.expect(overlayVisible(true, true));
}

test "background namespace is not shell focus" {
    try std.testing.expect(isBackgroundNamespace("nshell-wallpaper"));
    try std.testing.expect(!isBackgroundNamespace("nshell"));
    try std.testing.expect(!isBackgroundNamespace("nshell-hub"));
    try std.testing.expect(!isShellNamespace("nshell-wallpaper"));
    try std.testing.expect(isShellOwnedNamespace("nshell"));
    try std.testing.expect(isShellOwnedNamespace("nshell-hub"));
    try std.testing.expect(isShellOwnedNamespace("nshell-wallpaper"));
    try std.testing.expect(!isShellOwnedNamespace("firefox"));
}
