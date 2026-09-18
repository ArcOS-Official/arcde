const std = @import("std");
const dvui = @import("dvui");
const nilebank = @import("bank");
const proto = nilebank.protocols.compositor;
const State = @import("State.zig");

// Headless tests for the 2-way bank API (see bank/, compositor/src/Bank.zig):
// one connection carries requests and server broadcasts; the reader fiber
// feeds the commit queue, update() applies, worker sends.

const Ctx = struct {
    alloc: std.mem.Allocator,
    switch_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    focus_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fullscreen_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    fullscreen_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    capture_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    output_capture_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    // Set when the worker declares the hub namespace after (re)connect.
    shell_registered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Fail the first capture for window 102, succeed after: proves a
    // transient error backs off and retries instead of disabling
    // thumbnails forever.
    cap102_calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

fn fakeHandler(ctx: ?*anyopaque, msg: nilebank.Message) anyerror!nilebank.Message {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    const alloc = c.alloc;
    const req = try nilebank.decodeCompositorRequest(alloc, msg);
    defer req.deinit(alloc);

    const resp: proto.Event = switch (req) {
        .list_workspaces => blk: {
            const ws = try alloc.alloc(proto.Workspace, 2);
            ws[0] = .{ .id = 10, .number = 1, .name = try alloc.dupe(u8, "main"), .active = true, .current = true, .output = 1 };
            ws[1] = .{ .id = 20, .number = 2, .name = try alloc.dupe(u8, "code"), .active = false, .current = false, .urgent = true, .output = 1 };
            break :blk .{ .workspaces = .{ .items = ws } };
        },
        .list_windows => blk: {
            const wins = try alloc.alloc(proto.Window, 1);
            wins[0] = .{
                .id = 100,
                .title = try alloc.dupe(u8, "main.zig - nvim"),
                .app_id = try alloc.dupe(u8, "nvim"),
                .workspace = 10,
                .output = 1,
                .focused = true,
            };
            break :blk .{ .windows = .{ .items = wins } };
        },
        .list_outputs => blk: {
            const outs = try alloc.alloc(proto.Output, 1);
            outs[0] = .{
                .id = 1,
                .name = try alloc.dupe(u8, "HDMI-1"),
                .make = try alloc.dupe(u8, ""),
                .model = try alloc.dupe(u8, "Test"),
                .mode = .{ .width = 1920, .height = 1080, .refresh = 60000 },
            };
            break :blk .{ .outputs = .{ .items = outs } };
        },
        .switch_workspace => |v| blk: {
            c.switch_id.store(v.id, .seq_cst);
            break :blk .{ .pong = .{ .nonce = v.id } };
        },
        .shell_register => |v| blk: {
            if (std.mem.eql(u8, v.namespace, State.shell_namespace))
                c.shell_registered.store(true, .seq_cst);
            break :blk .{ .pong = .{ .nonce = 0 } };
        },
        .focus_window => |v| blk: {
            c.focus_id.store(v.id, .seq_cst);
            break :blk .{ .pong = .{ .nonce = v.id } };
        },
        .set_window_fullscreen => |v| blk: {
            c.fullscreen_id.store(v.id, .seq_cst);
            c.fullscreen_flag.store(v.fullscreen, .seq_cst);
            break :blk .{ .pong = .{ .nonce = v.id } };
        },
        .get_window => |v| blk: {
            // Unknown id: window is gone; lets the client prune its stub.
            if (v.id == 999) {
                break :blk .{ .error_msg = .{ .code = 2, .message = try alloc.dupe(u8, "window not found") } };
            }
            const wins = try alloc.alloc(proto.Window, 1);
            wins[0] = .{
                .id = v.id,
                .title = try alloc.dupe(u8, "filled"),
                .app_id = try alloc.dupe(u8, "filled-app"),
                .workspace = 10,
                .output = 1,
            };
            break :blk .{ .windows = .{ .items = wins } };
        },
        .capture_window => |v| blk: {
            _ = c.capture_count.fetchAdd(1, .seq_cst);
            if (v.window_id == 102 and c.cap102_calls.fetchAdd(1, .seq_cst) == 0) {
                break :blk .{ .error_msg = .{ .code = 3, .message = try alloc.dupe(u8, "busy") } };
            }
            if (v.window_id == 101) {
                const data = try alloc.dupe(u8, &[_]u8{ 0, 0, 255, 255 });
                break :blk .{ .window_image = .{ .window_id = v.window_id, .image = .{
                    .width = 1,
                    .height = 1,
                    .stride = 4,
                    .format = .bgra8,
                    .data = data,
                } } };
            }
            const data = try alloc.alloc(u8, 12);
            @memcpy(data[0..8], &[_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 });
            @memset(data[8..], 0);
            break :blk .{ .window_image = .{ .window_id = v.window_id, .image = .{
                .width = 2,
                .height = 1,
                .stride = 12,
                .format = .rgba8,
                .data = data,
            } } };
        },
        .capture_output => |v| blk: {
            _ = c.output_capture_count.fetchAdd(1, .seq_cst);
            const data = try alloc.alloc(u8, 8);
            @memcpy(data, &[_]u8{ 0, 255, 0, 255, 0, 0, 255, 255 });
            break :blk .{ .output_image = .{ .output_id = v.output_id, .image = .{
                .width = 2,
                .height = 1,
                .stride = 8,
                .format = .rgba8,
                .data = data,
            } } };
        },
        else => .{ .error_msg = .{ .code = 1, .message = try alloc.dupe(u8, "unsupported") } },
    };
    var ev_copy = resp;
    defer ev_copy.deinit(alloc);
    return try nilebank.encodeCompositorEventDefault(alloc, ev_copy);
}

test "state: query, broadcast override, actions, images via 2-way connection" {
    const t = std.testing;
    const alloc = t.allocator;
    const io = t.io;

    const path = "/tmp/nshell-state2-test.sock";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    var ctx = Ctx{ .alloc = alloc };
    const server = try nilebank.servePath(alloc, io, path, fakeHandler, &ctx);
    defer server.deinit();

    var state = State{};
    state.socket_path_override = path;
    try state.init(alloc, io);
    const wt = try std.Thread.spawn(.{}, State.worker, .{ &state, io });
    // Teardown via defer (deinit first, then join) so a failing assertion
    // can't leak the worker into freed state and segfault the binary.
    defer wt.join();
    defer state.deinit();

    // Initial query populates the model.
    var tries: usize = 0;
    while (tries < 1000) : (tries += 1) {
        state.update();
        if (state.workspaces.len == 2 and state.windows.len == 1) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 2), state.workspaces.len);
    try t.expectEqual(@as(usize, 1), state.windows.len);
    try t.expectEqualStrings("main", state.workspaces[0].name);
    try t.expectEqualStrings("main.zig - nvim", state.windows[0].title);

    // Shell registration: the worker declares the hub namespace on
    // (re)connect so the compositor can focus it on MOD+/.
    tries = 0;
    while (!ctx.shell_registered.load(.seq_cst) and tries < 500) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(ctx.shell_registered.load(.seq_cst));

    // Launcher pushes (compositor MOD+/ binding) arm HubUi pending flags
    // for hubFrame to consume — they must not disturb switcher/model state.
    {
        var ev: proto.Event = .{ .launcher_opened = {} };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    {
        var ev: proto.Event = .{ .launcher_closed = {} };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    // Drain them; the model stays intact and both flags arm.
    tries = 0;
    while (tries < 20) : (tries += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 1), state.windows.len);
    try t.expect(state.launcher_open_pending);
    try t.expect(state.launcher_close_pending);
    state.launcher_open_pending = false;
    state.launcher_close_pending = false;

    // Compositor-driven hub focus: the worker stores `shell_focus_changed`
    // pushes straight into the bound HubUi flag (no commit-queue round
    // trip), so the UI thread observes the edge on its next frame.
    {
        var hub_focused = std.atomic.Value(bool).init(true);
        state.bindHubFocus(&hub_focused);
        {
            var ev: proto.Event = .{ .shell_focus_changed = .{ .focused = false } };
            defer ev.deinit(alloc);
            try server.broadcastCompositorEventDefault(ev);
        }
        tries = 0;
        while (hub_focused.load(.seq_cst) and tries < 500) : (tries += 1) {
            io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        try t.expect(!hub_focused.load(.seq_cst));
        {
            var ev: proto.Event = .{ .shell_focus_changed = .{ .focused = true } };
            defer ev.deinit(alloc);
            try server.broadcastCompositorEventDefault(ev);
        }
        tries = 0;
        while (!hub_focused.load(.seq_cst) and tries < 500) : (tries += 1) {
            io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        try t.expect(hub_focused.load(.seq_cst));
        // Focus pushes carry no model state: the windows list is untouched
        // and no commit was queued for update() to apply.
        state.update();
        try t.expectEqual(@as(usize, 1), state.windows.len);
    }

    // Broadcast overrides current state without any new request.
    {
        var ev: proto.Event = .{ .window_title_changed = .{ .id = 100, .title = try alloc.dupe(u8, "hello") } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    tries = 0;
    while (tries < 500) : (tries += 1) {
        state.update();
        if (state.windows.len == 1 and std.mem.eql(u8, state.windows[0].title, "hello")) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqualStrings("hello", state.windows[0].title);

    // Unknown window converges via get_window fill WITHOUT wiping the
    // existing list (regression: fills used to replace the whole model,
    // so the switcher showed only one window).
    {
        var ev: proto.Event = .{ .new_window = .{ .id = 101, .title = try alloc.dupe(u8, "fresh") } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    tries = 0;
    while (tries < 500) : (tries += 1) {
        state.update();
        var filled = false;
        for (state.windows) |*w| {
            if (w.id == 101 and std.mem.eql(u8, w.app_id, "filled-app")) filled = true;
        }
        if (filled) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    {
        var found = false;
        for (state.windows) |*w| {
            if (w.id != 101) continue;
            found = true;
            try t.expectEqualStrings("filled", w.title);
        }
        try t.expect(found);
        // The pre-existing window must survive the fill.
        try t.expectEqual(@as(usize, 2), state.windows.len);
        try t.expectEqualStrings("hello", state.windows[0].title);
    }

    // Focus order: a window_focused push moves the row to the front (MRU)
    // so the switcher lists index 0 = currently focused.
    {
        var ev: proto.Event = .{ .window_focused = .{ .id = 101, .old_id = 100 } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    tries = 0;
    while (tries < 500) : (tries += 1) {
        state.update();
        if (state.windows.len == 2 and state.windows[0].id == 101) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(u64, 101), state.windows[0].id);
    try t.expectEqual(@as(u64, 100), state.windows[1].id);
    try t.expect(state.windows[0].focused);
    try t.expect(!state.windows[1].focused);

    // Full-list pushes (e.g. the server's MRU re-push on focus change)
    // replace in the transmitted order.
    {
        const items = try alloc.alloc(proto.Window, 2);
        items[0] = .{ .id = 100, .title = try alloc.dupe(u8, "hello"), .focused = true };
        items[1] = .{ .id = 101, .title = try alloc.dupe(u8, "filled"), .focused = false };
        var ev: proto.Event = .{ .windows = .{ .items = items } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    tries = 0;
    while (tries < 500) : (tries += 1) {
        state.update();
        if (state.windows.len == 2 and state.windows[0].id == 100 and state.windows[0].focused) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(u64, 100), state.windows[0].id);
    try t.expectEqual(@as(u64, 101), state.windows[1].id);

    // Gone window: a get_window error prunes the stub instead of leaving a
    // blank switcher entry.
    {
        var ev: proto.Event = .{ .new_window = .{ .id = 999, .title = try alloc.dupe(u8, "ghost") } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    var saw_ghost = false;
    tries = 0;
    while (tries < 1000) : (tries += 1) {
        state.update();
        var ghost = false;
        for (state.windows) |*w| {
            if (w.id == 999) ghost = true;
        }
        if (ghost) saw_ghost = true;
        // Wait until the stub appears AND is then pruned by the error fill.
        if (saw_ghost and !ghost) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(saw_ghost);
    for (state.windows) |*w| try t.expect(w.id != 999);
    try t.expectEqual(@as(usize, 2), state.windows.len);

    // Actions reach the server.
    state.switchWorkspace(42);
    tries = 0;
    while (ctx.switch_id.load(.seq_cst) != 42 and tries < 500) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(u64, 42), ctx.switch_id.load(.seq_cst));

    state.focusWindow(99);
    tries = 0;
    while (ctx.focus_id.load(.seq_cst) != 99 and tries < 500) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(u64, 99), ctx.focus_id.load(.seq_cst));

    // Fullscreen action reaches the server; the state broadcast merges
    // the flag into the model; toggle flips it back.
    state.setWindowFullscreen(100, true);
    tries = 0;
    while ((ctx.fullscreen_id.load(.seq_cst) != 100 or !ctx.fullscreen_flag.load(.seq_cst)) and tries < 500) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(u64, 100), ctx.fullscreen_id.load(.seq_cst));
    try t.expect(ctx.fullscreen_flag.load(.seq_cst));
    {
        var ev: proto.Event = .{ .window_state_changed = .{ .id = 100, .floating = false, .fullscreen = true, .urgent = false, .focused = true } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    tries = 0;
    while (tries < 500) : (tries += 1) {
        state.update();
        if (state.windows.len > 0 and state.windows[0].id == 100 and state.windows[0].fullscreen) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(state.windows[0].fullscreen);
    state.toggleWindowFullscreen(100);
    tries = 0;
    while (ctx.fullscreen_flag.load(.seq_cst) and tries < 500) : (tries += 1) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(!ctx.fullscreen_flag.load(.seq_cst));

    // Images: miss enqueues one capture; pixels land in the map; repeats
    // are served from cache with no new traffic.
    try t.expect(state.windowImage(100) == null);
    var j: usize = 0;
    while (j < 10) : (j += 1) _ = state.windowImage(100);
    tries = 0;
    while (ctx.capture_count.load(.seq_cst) != 1 and tries < 1000) : (tries += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 1), ctx.capture_count.load(.seq_cst));
    var img: ?dvui.ImageSource = null;
    tries = 0;
    while (tries < 1000) : (tries += 1) {
        state.update();
        img = state.windowImage(100);
        if (img != null) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(img != null);
    try t.expectEqual(@as(u32, 2), img.?.pixels.width);
    try t.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 }, img.?.pixels.rgba);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const again = state.windowImage(100);
        try t.expect(again != null);
    }
    try t.expectEqual(@as(usize, 1), ctx.capture_count.load(.seq_cst));

    // bgra8 source is normalized to RGBA (blue -> red).
    _ = state.windowImage(101);
    var img101: ?dvui.ImageSource = null;
    tries = 0;
    while (tries < 1000) : (tries += 1) {
        state.update();
        img101 = state.windowImage(101);
        if (img101 != null) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(img101 != null);
    try t.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, img101.?.pixels.rgba);

    // Transient capture error backs off and retries: the first request for
    // 102 fails with code 3, but the thumbnail must still arrive instead of
    // being disabled forever.
    _ = state.windowImage(102);
    var img102: ?dvui.ImageSource = null;
    tries = 0;
    while (tries < 1500) : (tries += 1) {
        state.update();
        img102 = state.windowImage(102);
        if (img102 != null) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(img102 != null);
    try t.expectEqual(@as(u32, 2), img102.?.pixels.width);
    try t.expect(ctx.cap102_calls.load(.seq_cst) >= 2);

    // Prefetch coalescing: back-to-back prefetches issue no duplicate
    // traffic. Drain the first prefetch, snapshot, then prefetch again —
    // everything is freshly requested/fetched, so the second adds nothing.
    // (Sleeps stay well under the 2s image TTL so refetch can't kick in.)
    state.prefetchWindowImages();
    var drain: usize = 0;
    while (drain < 60) : (drain += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    const after_first_prefetch = ctx.capture_count.load(.seq_cst);
    state.prefetchWindowImages();
    var spins: usize = 0;
    while (spins < 60) : (spins += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(after_first_prefetch, ctx.capture_count.load(.seq_cst));

    // Outputs model converges from the initial list_outputs query.
    tries = 0;
    while (state.outputs.len != 1 and tries < 1000) : (tries += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 1), state.outputs.len);
    try t.expectEqualStrings("HDMI-1", state.outputs[0].name);
    try t.expectEqual(@as(u32, 1920), state.outputs[0].mode.width);

    // Output previews: miss enqueues one capture_output; pixels land in
    // the output map (green test pixels, 2x1 RGBA).
    try t.expect(state.outputImage(1) == null);
    tries = 0;
    while (ctx.output_capture_count.load(.seq_cst) != 1 and tries < 1000) : (tries += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 1), ctx.output_capture_count.load(.seq_cst));
    var oimg: ?dvui.ImageSource = null;
    tries = 0;
    while (tries < 1000) : (tries += 1) {
        state.update();
        oimg = state.outputImage(1);
        if (oimg != null) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expect(oimg != null);
    try t.expectEqual(@as(u32, 2), oimg.?.pixels.width);
    try t.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255, 0, 0, 255, 255 }, oimg.?.pixels.rgba);

    // Output broadcast merges: added/changed/removal converge the model.
    {
        var ev: proto.Event = .{ .output_added = .{
            .id = 2,
            .name = try alloc.dupe(u8, "DP-1"),
            .make = try alloc.dupe(u8, ""),
            .model = try alloc.dupe(u8, ""),
            .mode = .{ .width = 1280, .height = 720, .refresh = 60000 },
        } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    tries = 0;
    while (state.outputs.len != 2 and tries < 1000) : (tries += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 2), state.outputs.len);
    {
        var ev: proto.Event = .{ .output_removed = .{ .id = 2 } };
        defer ev.deinit(alloc);
        try server.broadcastCompositorEventDefault(ev);
    }
    tries = 0;
    while (state.outputs.len != 1 and tries < 1000) : (tries += 1) {
        state.update();
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 1), state.outputs.len);

    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}
