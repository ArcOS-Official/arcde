//! Tests for the screen-share model and its bank requests.
//!
//! These cover the parts that can run headless: what the shell *asks* the
//! compositor for, how the derived picker model looks, and the portal
//! handshake. Compositor-side behaviour (scene composition, PipeWire) has no
//! headless harness in this repo and is only compile-verified.

const std = @import("std");
const State = @import("State.zig");
const proto = @import("bank").protocols.compositor;
const Activity = @import("Activity.zig");
const testing = std.testing;

fn newState(alloc: std.mem.Allocator, io: std.Io) !State {
    var s = State{};
    s.socket_path_override = "/tmp/nshell-share-test-unused.sock";
    try s.init(alloc, io);
    return s;
}

/// Drain the UI -> worker outbox so a test can assert on what was queued.
fn drain(alloc: std.mem.Allocator, io: std.Io, s: *State) ![]State.Action {
    var list: std.ArrayList(State.Action) = .empty;
    s.req_q.popAll(io, &list);
    return list.toOwnedSlice(alloc);
}

fn freeActions(alloc: std.mem.Allocator, items: []State.Action) void {
    // `Action.deinit` owns the payload cleanup, which is exactly what the
    // real send path relies on.
    for (items) |*it| it.deinit(alloc);
    if (items.len > 0) alloc.free(items);
}

/// A share selection whose confirmed hidden set is exactly `want`.
fn expectHiddenSet(alloc: std.mem.Allocator, io: std.Io, s: *State, want: []const u64) !void {
    const acts = try drain(alloc, io, s);
    defer freeActions(alloc, acts);

    var found = false;
    for (acts) |*it| {
        if (it.* != .share_configured) continue;
        found = true;
        try testing.expectEqual(@as(usize, want.len), it.share_configured.hidden.len);
        // Order is a hash map walk, so compare as sets.
        for (want) |w| {
            var hit = false;
            for (it.share_configured.hidden) |g| {
                if (g == w) hit = true;
            }
            try testing.expect(hit);
        }
    }
    try testing.expect(found);
}

test "share: selectShareView asks the compositor, dropping any prior ticks" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    // A stale tick from a previous picker must not leak into the next share.
    s.share_hidden_ids.put(alloc, 99, {}) catch unreachable;

    s.selectShareView(.screen, 7);

    try testing.expectEqual(s.sharePickerState(), .idle);
    const acts = try drain(alloc, io, &s);
    defer freeActions(alloc, acts);
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expect(acts[0] == .share_select);
    try testing.expectEqual(proto.ShareKind.screen, acts[0].share_select.kind);
    try testing.expectEqual(@as(u64, 7), acts[0].share_select.id);
    try testing.expectEqual(@as(usize, 0), s.share_hidden_ids.count());
}

test "share: setShareHidden ticks a window and set_share_hidden is sent each time" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    s.setShareHidden(11, true);
    try testing.expect(s.isShareHidden(11));

    const acts = try drain(alloc, io, &s);
    defer freeActions(alloc, acts);
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expect(acts[0] == .set_share_hidden);
    try testing.expectEqual(@as(u64, 11), acts[0].set_share_hidden.id);
    try testing.expectEqual(true, acts[0].set_share_hidden.hidden);

    // Unticking removes it from the confirmed set.
    s.setShareHidden(11, false);
    try testing.expect(!s.isShareHidden(11));
    const acts2 = try drain(alloc, io, &s);
    defer freeActions(alloc, acts2);
    try testing.expectEqual(@as(usize, 1), acts2.len);
    try testing.expectEqual(false, acts2[0].set_share_hidden.hidden);
}

test "share: confirmShare sends exactly the ticked windows, then clears them" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    s.setShareHidden(3, true);
    s.setShareHidden(9, true);
    s.setShareHidden(4, true);
    // Discard the set_share_hidden requests themselves, but free the list.
    const ticks = try drain(alloc, io, &s);
    freeActions(alloc, ticks);

    s.confirmShare(.screen, 42);
    try expectHiddenSet(alloc, io, &s, &.{ 3, 9, 4 });

    // A re-confirm must not carry the previous set forward: it would keep
    // hiding a window the user has since unticked.
    try testing.expectEqual(@as(usize, 0), s.share_hidden_ids.count());
    s.confirmShare(.screen, 42);
    try expectHiddenSet(alloc, io, &s, &.{});
}

test "share: stopShare asks the compositor to stop" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    s.stopShare();
    const acts = try drain(alloc, io, &s);
    defer freeActions(alloc, acts);
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expect(acts[0] == .share_stop);
}

test "share: confirmShare releases the config menu" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    // Simulate the compositor's reply arriving.
    // The event owns both the items array and their titles (Event.deinit
    // frees them), so all of it must be heap memory: a stack array or a
    // string literal here would be freed on the deinit below.
    const items = try alloc.alloc(proto.ShareItem, 1);
    items[0] = .{ .id = 5, .title = try alloc.dupe(u8, "secret") };
    var ev: proto.Event = .{ .configure_share = .{
        .kind = .screen,
        .id = 3,
        .items = items,
    } };
    s.applyEvent(&ev);
    ev.deinit(alloc);

    try testing.expect(s.share_configure != null);
    try testing.expectEqual(@as(usize, 1), s.share_configure.?.items.len);
    // Deep copy: the title must survive the event being freed above.
    try testing.expectEqualStrings("secret", s.share_configure.?.items[0].title);
    try testing.expect(s.share_configure_pending);

    s.confirmShare(.screen, 3);
    try testing.expect(s.share_configure == null);
}

test "share: started/stopped drive the portal's pollable node id" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    try testing.expectEqual(@as(u32, 0), s.shareNodeId());

    var ev: proto.Event = .{ .share_started = .{ .node_id = 4242, .kind = .screen, .id = 1 } };
    s.applyEvent(&ev);
    ev.deinit(alloc);
    try testing.expectEqual(@as(u32, 4242), s.shareNodeId());

    ev = .{ .share_stopped = {} };
    s.applyEvent(&ev);
    ev.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), s.shareNodeId());
}

test "share: stopped clears the ticked windows so the indicator cannot go stale" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    s.setShareHidden(8, true);
    try testing.expect(s.isShareHidden(8));
    var ev: proto.Event = .{ .share_stopped = {} };
    s.applyEvent(&ev);
    ev.deinit(alloc);
    try testing.expect(!s.isShareHidden(8));
}

test "share: portal handshake reports waiting then picked" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    try testing.expectEqual(s.sharePickerState(), .idle);

    // This is what Portal.zig does when a client calls ScreenCast Start,
    // from its own thread.
    s.beginShareRequest();
    try testing.expectEqual(s.sharePickerState(), .waiting);
    try testing.expect(s.share_open_pending.load(.seq_cst));

    // The picker consumes the pending edge in hub context.
    try testing.expect(s.share_open_pending.swap(false, .seq_cst));

    s.selectShareOutput(.screen, 12, "DP-1");
    try testing.expectEqual(s.sharePickerState(), .picked);
    try testing.expectEqual(@as(u64, 12), s.shareSelection().id);
    try testing.expectEqualStrings("DP-1", s.shareSelection().name);
    try testing.expectEqual(proto.ShareKind.screen, s.shareSelection().kind);
}

test "share: cancelling the picker reports cancelled and clears the pending edge" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    s.beginShareRequest();
    s.cancelSharePicker();
    try testing.expectEqual(s.sharePickerState(), .cancelled);
    try testing.expect(!s.share_open_pending.load(.seq_cst));
    try testing.expectEqual(@as(u64, 0), s.shareSelection().id);
}

test "share: a fresh request forgets the previous selection" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    s.beginShareRequest();
    s.selectShareOutput(.window, 99, "editor");
    try testing.expectEqual(@as(u64, 99), s.shareSelection().id);

    // A second client asking to share must not see the first one's pick.
    s.beginShareRequest();
    try testing.expectEqual(@as(u64, 0), s.shareSelection().id);
}

// --- derived picker model ---------------------------------------------------

fn addOutput(s: *State, alloc: std.mem.Allocator, id: u64, name: []const u8, w: u32, enabled: bool) !void {
    for (s.outputs) |*o| o.deinit(alloc);
    if (s.outputs.len > 0) alloc.free(s.outputs);
    const items = try alloc.alloc(proto.Output, 1);
    items[0] = .{
        .id = id,
        .name = try alloc.dupe(u8, name),
        .x = 0,
        .y = 0,
        .mode = .{ .width = w, .height = 1080, .refresh = 60000 },
        .enabled = enabled,
    };
    s.outputs = items;
}

fn addWindow(s: *State, alloc: std.mem.Allocator, id: u64, title: []const u8) !void {
    const items = try alloc.alloc(proto.Window, 1);
    items[0] = .{ .id = id, .title = try alloc.dupe(u8, title) };
    s.windows = items;
}

test "share_views: lists screens before windows" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    try addWindow(&s, alloc, 500, "editor");
    try addOutput(&s, alloc, 100, "DP-1", 1920, true);
    s.update();

    try testing.expectEqual(@as(usize, 2), s.share_views.len);
    // A screen share is overwhelmingly the common case, so it leads.
    try testing.expectEqual(proto.ShareKind.screen, s.share_views[0].kind);
    try testing.expectEqual(@as(u64, 100), s.share_views[0].id);
    try testing.expectEqualStrings("DP-1", s.share_views[0].title);
    try testing.expectEqual(proto.ShareKind.window, s.share_views[1].kind);
    try testing.expectEqual(@as(u64, 500), s.share_views[1].id);
}

test "share_views: the first live display is the default, windows never are" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    try addOutput(&s, alloc, 100, "DP-1", 1920, true);
    try addWindow(&s, alloc, 500, "editor");
    s.update();

    try testing.expect(s.share_views[0].default);
    try testing.expect(!s.share_views[1].default);
}

test "share_views: a display with no active mode is not offered" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    // mode.width == 0 means "no mode committed"; such an output cannot be
    // captured, so offering it would produce a tile that never fills in.
    try addOutput(&s, alloc, 100, "DP-1", 0, true);
    s.update();
    try testing.expectEqual(@as(usize, 0), s.share_views.len);

    // Likewise a disabled output.
    try addOutput(&s, alloc, 101, "HDMI-1", 1920, false);
    s.update();
    try testing.expectEqual(@as(usize, 0), s.share_views.len);
}

test "share_views: titles are owned copies, not aliases of the model" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    try addOutput(&s, alloc, 100, "DP-1", 1920, true);
    s.update();

    // The view must own its own copy rather than aliasing the model's
    // string: the next broadcast frees the model's copy, and the picker
    // would be left holding freed memory.
    try testing.expectEqualStrings("DP-1", s.share_views[0].title);
    try testing.expect(s.share_views[0].title.ptr != s.outputs[0].name.ptr);

    // Same for windows.
    try addWindow(&s, alloc, 500, "editor");
    s.update();
    try testing.expectEqualStrings("editor", s.share_views[1].title);
    try testing.expect(s.share_views[1].title.ptr != s.windows[0].title.ptr);
}

test "share_views: a rebuild replaces the list rather than leaking it" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    try addOutput(&s, alloc, 100, "DP-1", 1920, true);
    s.update();
    try addWindow(&s, alloc, 500, "editor");
    // The window list changed, so the generation stamp must force a rebuild.
    s.update();

    try testing.expectEqual(@as(usize, 2), s.share_views.len);
    // Forcing extra rebuilds must stay leak-free (checked by the test
    // allocator at scope exit).
    s.rebuildShareViewsNow();
    s.rebuildShareViewsNow();
    try testing.expectEqual(@as(usize, 2), s.share_views.len);
    try testing.expectEqualStrings("editor", s.share_views[1].title);
}

test "viewImage dispatches on kind, not on the bare id" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    // Both caches are empty, so a cold lookup returns null -- but it must
    // have asked the compositor for the *matching* thing. Output and window
    // ids are different namespaces, so a screen must never enqueue
    // capture_window.
    try testing.expect(s.viewImage(.{ .kind = .screen, .id = 100 }) == null);
    const acts = try drain(alloc, io, &s);
    defer freeActions(alloc, acts);
    try testing.expectEqual(@as(usize, 1), acts.len);
    try testing.expect(acts[0] == .capture_output);

    try testing.expect(s.viewImage(.{ .kind = .window, .id = 100 }) == null);
    const acts2 = try drain(alloc, io, &s);
    defer freeActions(alloc, acts2);
    try testing.expectEqual(@as(usize, 1), acts2.len);
    try testing.expect(acts2[0] == .capture_window);
}
// --- activity indicator -----------------------------------------------------

test "share: the compositor's share shows one indicator and stops via bank" {
    const alloc = testing.allocator;
    const io = testing.io;
    var s = try newState(alloc, io);
    defer s.deinit();

    try testing.expectEqual(@as(usize, 0), s.activity.counts().share);

    var ev: proto.Event = .{ .share_started = .{ .node_id = 77, .kind = .screen, .id = 1 } };
    s.applyEvent(&ev);
    ev.deinit(alloc);

    // Exactly one share indicator, sourced from the compositor so the Stop
    // button goes through `share_stop` rather than `pw-cli destroy`.
    const counts = s.activity.counts();
    try testing.expectEqual(@as(usize, 1), counts.share);
    try testing.expectEqual(@as(usize, 1), counts.total());

    var snap = s.activity.snapshotCopy(alloc);
    defer snap.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), snap.items.len);
    try testing.expectEqual(Activity.Source.share_session, snap.items[0].source);
    try testing.expectEqual(Activity.Kind.share, snap.items[0].kind);
    try testing.expectEqual(@as(u64, 77), snap.items[0].id);

    ev = .{ .share_stopped = {} };
    s.applyEvent(&ev);
    ev.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), s.activity.counts().share);
}

test "share: our own PipeWire node is not also reported by the pw-dump sweep" {
    const alloc = testing.allocator;
    const io = testing.io;
    var activity: Activity = .{};
    activity.init(alloc, io);
    defer activity.deinit();

    // The compositor's producer is a plain Video/Source. Without telling
    // Activity which node is ours, adoptPwDump would classify it as a
    // generic `.share` and the strip would show two glyphs for one share.
    activity.setOwnShareNode(55);
    try testing.expectEqual(@as(usize, 1), activity.counts().share);

    var snap = activity.snapshotCopy(alloc);
    defer snap.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), snap.items.len);
    try testing.expectEqual(Activity.Source.share_session, snap.items[0].source);

    activity.setOwnShareNode(0);
    try testing.expectEqual(@as(usize, 0), activity.counts().share);
}
