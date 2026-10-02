//! `nile-share-verify` — end-to-end check of the screen-share pipeline that
//! needs nothing but the compositor.
//!
//! Speaks the bank protocol directly to `/tmp/arcos/compositor.sock`, so it
//! does not depend on PipeWire, on a desktop portal, or on a session bus.
//! That makes it usable inside another desktop's session, where the real
//! ScreenCast path is unavailable.
//!
//! What it proves, in order:
//!
//!  1. The compositor is reachable and lists outputs and windows.
//!  2. `share_select` is answered with `configure_share`, and the hideable
//!     items are the windows actually on that output.
//!  3. `share_configured` starts a share.
//!  4. `share_snapshot` returns a real frame of the right size — proof that
//!     ShareScene composed something and ShareRender rasterised it.
//!  5. Hiding a window makes its rectangle go black in the frame, and
//!     unhiding brings it back. This is the actual feature.
//!  6. `share_stop` is answered with `share_stopped`.
//!
//! Frames are written as binary PPM so they can be opened and eyeballed.
//!
//! Exit status is 0 only if every check passed.

const std = @import("std");
const nilebank = @import("bank");
const protocols_root = @import("bank");
const protocols = @import("bank").protocols.compositor;

const alloc = std.heap.page_allocator;

var passed: usize = 0;
var failed: usize = 0;

fn ok(comptime fmt: []const u8, args: anytype) void {
    passed += 1;
    std.debug.print("  PASS  " ++ fmt ++ "\n", args);
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    failed += 1;
    std.debug.print("  FAIL  " ++ fmt ++ "\n", args);
}

/// Both format strings must consume `args` identically: Zig type-checks both
/// branches, so a placeholder in one and not the other is a compile error.
/// That is a feature here -- it stops a FAIL message silently losing the
/// value it was explaining.
fn check(cond: bool, comptime pass_fmt: []const u8, comptime fail_fmt: []const u8, args: anytype) void {
    if (cond) ok(pass_fmt, args) else fail(fail_fmt, args);
}

/// Collector for compositor pushes, filled by the connection's reader.
const Inbox = struct {
    /// The bank connection's reader thread is the only writer; main reads.
    mu: std.Io.Mutex = .init,
    outputs: std.ArrayList(protocols.Output) = .empty,
    windows: std.ArrayList(protocols.Window) = .empty,
    configure: ?protocols.Event.ConfigureShare = null,
    started: ?protocols.Event.ShareStarted = null,
    stopped_seen: bool = false,
    frame: ?protocols.Image = null,
    frame_serial: u64 = 0,
    last_error: ?protocols.Event.ErrorMsg = null,

    fn deinit(self: *Inbox) void {
        for (self.outputs.items) |*o| o.deinit(alloc);
        self.outputs.deinit(alloc);
        for (self.windows.items) |*w| w.deinit(alloc);
        self.windows.deinit(alloc);
        if (self.configure) |c| for (c.items) |it| it.deinit(alloc);
        if (self.frame) |f| f.deinit(alloc);
    }
};

/// Event listener. Runs on the bank connection's reader thread, so every
/// write takes the mutex. `msg.data` is borrowed, hence the decode.
fn onEvent(ctx: ?*anyopaque, msg: nilebank.Message) void {
    const inbox: *Inbox = @ptrCast(@alignCast(ctx orelse return));
    inbox.mu.lockUncancelable(io);
    defer inbox.mu.unlock(io);

    const ev = protocols_root.decodeCompositorEvent(alloc, msg) catch return;
    switch (ev) {
        .outputs => |v| replaceOutputs(inbox, v.items),
        .outputs_snapshot => |v| replaceOutputs(inbox, v.items),
        .windows => |v| replaceWindows(inbox, v.items),
        .windows_snapshot => |v| replaceWindows(inbox, v.items),
        .configure_share => |*v| {
            if (inbox.configure) |c| freeShareItems(c.items);
            var copy: []protocols.ShareItem = &.{};
            if (v.items.len > 0) {
                copy = alloc.alloc(protocols.ShareItem, v.items.len) catch &.{};
                var n: usize = 0;
                for (v.items) |src| {
                    copy[n] = .{ .id = src.id, .title = alloc.dupe(u8, src.title) catch "" };
                    n += 1;
                }
            }
            inbox.configure = .{ .kind = v.kind, .id = v.id, .items = copy };
        },
        .share_started => |v| inbox.started = v,
        .share_stopped => inbox.stopped_seen = true,
        .share_frame => |*v| {
            if (inbox.frame) |f| f.deinit(alloc);
            var copy: protocols.Image = .{};
            if (v.image.data.len > 0) {
                copy = protocols.Image{
                    .width = v.image.width,
                    .height = v.image.height,
                    .stride = v.image.stride,
                    .format = v.image.format,
                    .data = alloc.dupe(u8, v.image.data) catch &.{},
                };
            }
            inbox.frame = copy;
            inbox.frame_serial = v.serial;
        },
        .error_msg => |v| inbox.last_error = v,
        else => {},
    }
    ev.deinit(alloc);
}

fn freeShareItems(items: []protocols.ShareItem) void {
    for (items) |it| {
        if (it.title.len > 0) alloc.free(it.title);
    }
    if (items.len > 0) alloc.free(items);
}

fn replaceOutputs(inbox: *Inbox, items: []protocols.Output) void {
    for (inbox.outputs.items) |*o| o.deinit(alloc);
    inbox.outputs.deinit(alloc);
    inbox.outputs = .empty;
    for (items) |o| inbox.outputs.append(alloc, o) catch {};
}

fn replaceWindows(inbox: *Inbox, items: []protocols.Window) void {
    for (inbox.windows.items) |*w| w.deinit(alloc);
    inbox.windows.deinit(alloc);
    inbox.windows = .empty;
    for (items) |w| inbox.windows.append(alloc, w) catch {};
}

/// Wait until `pred` holds or the deadline passes. Returns true on success.
fn waitFor(pred: anytype, arg: anytype, timeout_ms: u64, inbox: *Inbox) bool {
    // Poll rather than wall-clock: a monotonic deadline would need a clock
    // source this binary does not otherwise need.
    var waited_ms: u64 = 0;
    const step_ms: u64 = 20;
    while (true) {
        inbox.mu.lockUncancelable(io);
        const hit = pred(inbox, arg);
        inbox.mu.unlock(io);
        if (hit) return true;
        if (waited_ms >= timeout_ms) return false;
        io.sleep(.fromMilliseconds(step_ms), .awake) catch return false;
        waited_ms += step_ms;
    }
}

var io: std.Io = undefined;
var inbox_conn: *nilebank.Connection = undefined;

/// Ask for one frame and wait for the matching `share_frame`.
fn requestFrame(inbox: *Inbox, serial: u64) bool {
    if (inbox.frame) |f| f.deinit(alloc);
    inbox.frame = null;
    inbox.frame_serial = 0;

    const ev = inbox_conn.requestCompositor(.{ .share_snapshot = .{ .serial = serial } }, .raw) catch {
        std.log.err("share_snapshot request failed", .{});
        return false;
    };
    ev.deinit(alloc);
    return waitFor(struct {
        fn p(ib: *Inbox, s: u64) bool {
            return ib.frame != null and ib.frame_serial == s;
        }
    }.p, serial, 5000, inbox);
}

/// Mean luminance of a rectangle, 0..255. Used to tell "black box drawn"
/// from "nothing there", without depending on exact colours.
fn regionLuma(img: protocols.Image, x0: u32, y0: u32, x1: u32, y1: u32) f64 {
    if (x1 <= x0 or y1 <= y0) return -1;
    var sum: u64 = 0;
    var n: u64 = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const i = (y * img.stride + x * 4) % img.data.len;
            if (i + 2 >= img.data.len) break;
            sum += (@as(u64, img.data[i]) + img.data[i + 1] + img.data[i + 2]) / 3;
            n += 1;
        }
    }
    if (n == 0) return -1;
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));
}

fn wholeLuma(img: protocols.Image) f64 {
    if (img.data.len == 0) return -1;
    return regionLuma(img, 0, 0, img.width, img.height);
}

/// Write a binary PPM so the frame can be opened and eyeballed. Built on
/// std.Io.File around a raw fd: this is a one-shot diagnostic dump and
/// should not depend on anything the rest of the tool does not already use.
fn writePpm(path: []const u8, img: protocols.Image) !void {
    if (img.data.len == 0 or img.width == 0 or img.height == 0) return error.EmptyFrame;

    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);

    var hdr: [64]u8 = undefined;
    const hs = try std.fmt.bufPrint(&hdr, "P6\n{d} {d}\n255\n", .{ img.width, img.height });
    try file.writeStreamingAll(io, hs);

    const row = try alloc.alloc(u8, img.width * 3);
    defer alloc.free(row);

    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            const si = y * img.stride + x * 4;
            const di = x * 3;
            if (si + 2 >= img.data.len) break;
            row[di + 0] = img.data[si + 0];
            row[di + 1] = img.data[si + 1];
            row[di + 2] = img.data[si + 2];
        }
        try file.writeStreamingAll(io, row);
    }
}

/// `--count-windows`: just report how many windows the compositor sees, then
/// exit. The harness polls this to know when its test window has mapped.
fn countWindowsOnly(conn: *nilebank.Connection) !void {
    var out: usize = 0;
    {
        const r = try conn.requestCompositor(.{ .list_windows = {} }, .raw);
        defer r.deinit(alloc);
        switch (r) {
            .windows => |v| out = v.items.len,
            .windows_snapshot => |v| out = v.items.len,
            else => {},
        }
    }
    std.debug.print("{d}\n", .{out});
}

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    io = threaded.io();

    const sock = "/tmp/arcos/compositor.sock";

    var inbox = Inbox{};
    defer inbox.deinit();

    const count_only = blk: {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
        defer it.deinit();
        while (it.next()) |a| {
            if (std.mem.eql(u8, a, "--count-windows")) break :blk true;
        }
        break :blk false;
    };

    if (!count_only) std.debug.print("nile-share-verify: connecting to {s}\n", .{sock});
    var conn: ?*nilebank.Connection = null;
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        if (nilebank.Connection.initPath(alloc, io, sock, onEvent, &inbox)) |c| {
            conn = c;
            break;
        } else |_| {
            io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
    }
    const c = conn orelse {
        std.log.err("could not reach the compositor at {s}. Is nile running?", .{sock});
        std.process.exit(2);
    };
    defer c.close();
    inbox_conn = c;

    if (count_only) {
        // Exit non-zero while there is still nothing to hide, so the
        // harness's wait loop terminates.
        try countWindowsOnly(c);
        var n: usize = 0;
        {
            const r = try c.requestCompositor(.{ .list_windows = {} }, .raw);
            defer r.deinit(alloc);
            switch (r) {
                .windows => |v| n = v.items.len,
                .windows_snapshot => |v| n = v.items.len,
                else => {},
            }
        }
        std.process.exit(if (n > 0) 0 else 1);
    }

    // ---- 1. the compositor is alive -------------------------------------
    // `list_outputs` is a request with a reply, so the answer comes back
    // from requestCompositor itself -- not through the push listener.
    const out_reply = try c.requestCompositor(.{ .list_outputs = {} }, .raw);
    defer out_reply.deinit(alloc);
    const win_reply = try c.requestCompositor(.{ .list_windows = {} }, .raw);
    defer win_reply.deinit(alloc);

    var outputs: []protocols.Output = &.{};
    switch (out_reply) {
        .outputs => |v| outputs = v.items,
        .outputs_snapshot => |v| outputs = v.items,
        else => {},
    }
    var windows: []protocols.Window = &.{};
    switch (win_reply) {
        .windows => |v| windows = v.items,
        .windows_snapshot => |v| windows = v.items,
        else => {},
    }

    if (outputs.len > 0) {
        ok("compositor answered list_outputs ({d} output(s), {d} window(s))", .{ outputs.len, windows.len });
    } else {
        fail("compositor reported no outputs: is a monitor attached?", .{});
        std.debug.print("\n{d} passed, {d} FAILED\n", .{ passed, failed });
        std.process.exit(1);
    }

    // `outputs`/`windows` alias the reply payloads, so the replies must stay
    // alive for as long as they are read -- hence the defers above, not a
    // deinit here.
    const out = outputs[0];
    std.debug.print("  output {s} ({d}x{d} @ {d},{d})\n", .{
        out.name, out.mode.width, out.mode.height, out.x, out.y,
    });
    std.debug.print("  {d} window(s) known\n", .{windows.len});

    // ---- 2. share_select -> configure_share -----------------------------
    {
        const ev = try c.requestCompositor(.{ .share_select = .{ .kind = .screen, .id = out.id } }, .raw);
        ev.deinit(alloc);
    }
    const got_cfg = waitFor(struct {
        fn p(ib: *Inbox, _: usize) bool {
            return ib.configure != null;
        }
    }.p, @as(usize, 0), 5000, &inbox);

    check(got_cfg, "share_select answered with configure_share", "configure_share never arrived", .{});
    if (!got_cfg) {
        std.debug.print("\n{d} passed, {d} FAILED\n", .{ passed, failed });
        std.process.exit(1);
    }
    const cfg = inbox.configure.?;
    std.debug.print("  hideable sub-views: {d}\n", .{cfg.items.len});
    for (cfg.items) |it| std.debug.print("    - {s} (id {d})\n", .{ it.title, it.id });

    // ---- 3. start a share -----------------------------------------------
    {
        const ev = try c.requestCompositor(.{ .share_configured = .{
            .kind = .screen,
            .id = out.id,
            .hidden = &.{},
        } }, .raw);
        ev.deinit(alloc);
    }
    io.sleep(.fromMilliseconds(200), .awake) catch {};
    // events arrive via the listener

    // ---- 4. a real frame comes back -------------------------------------
    const have_frame = requestFrame(&inbox, 1);
    check(have_frame, "share_snapshot returned a frame", "no share_frame came back", .{});
    if (!have_frame) {
        std.debug.print("\n{d} passed, {d} FAILED\n", .{ passed, failed });
        std.process.exit(1);
    }
    const img = inbox.frame.?;
    check(img.width > 0 and img.height > 0, "frame is {d}x{d}", "frame has zero size ({d}x{d})", .{img.width, img.height});
    check(
        img.data.len >= @as(usize, img.height) * img.stride,
        "frame carries {d} bytes (stride {d})",
        "frame truncated: {d} bytes at stride {d}",
        .{ img.data.len, img.stride },
    );
    const base_luma = wholeLuma(img);
    if (base_luma > 0.0) {
        ok("frame is not entirely black (mean luma {d:.1})", .{base_luma});
    } else {
        fail("frame is entirely black -- nothing was composed", .{});
    }
    writePpm("share-visible.ppm", img) catch |e| std.log.warn("could not write ppm: {s}", .{@errorName(e)});
    std.debug.print("  wrote share-visible.ppm\n", .{});

    // ---- 5. redaction actually redacts -----------------------------------
    // Compare *the hidden window's own rectangle*, not the whole frame. A
    // whole-frame average is useless here: the terminal is alive and
    // repainting between snapshots, so the rest of the screen moves on its
    // own. The window's rectangle is the only region whose change means
    // "redaction happened".
    //
    // Window rects are in layout coordinates; the frame is the output, which
    // may not start at 0,0.
    var target: ?protocols.Window = null;
    for (windows) |w| {
        if (w.rect.width == 0 or w.rect.height == 0) continue;
        if (target == null or w.id < target.?.id) target = w;
    }

    if (target) |t| {
        const fx: i32 = out.x;
        const fy: i32 = out.y;
// Window rects are in layout coordinates; the frame starts at the
        // output's origin, which is not necessarily 0,0.
        const lx: i32 = t.rect.x - fx;
        const ly: i32 = t.rect.y - fy;
        const lx1: i32 = lx + @as(i32, @intCast(t.rect.width));
        const ly1: i32 = ly + @as(i32, @intCast(t.rect.height));

        const rx0: u32 = @intCast(@max(0, lx));
        const ry0: u32 = @intCast(@max(0, ly));
        const rx1: u32 = @min(img.width, @as(u32, @intCast(@max(0, lx1))));
        const ry1: u32 = @min(img.height, @as(u32, @intCast(@max(0, ly1))));
        std.debug.print("  window {d} rect {d},{d} {d}x{d} -> frame region {d},{d} {d}x{d}\n", .{
            t.id, t.rect.x, t.rect.y, t.rect.width, t.rect.height, rx0, ry0, rx1 - rx0, ry1 - ry0,
        });

        if (rx1 <= rx0 or ry1 <= ry0) {
            fail("the test window is entirely off the shared output", .{});
        } else {
            // Sample the window's lower band, not its full rect and not its
            // centre. The shell's own surfaces are drawn *above* windows in
            // the composed scene and are correctly not hidden: the bar hugs
            // the top edge and the hub is a centred ~480x300 pill. Those sit
            // exactly where a naive sample would look, so measuring them
            // would report a false failure. The bottom of the window is
            // window content only.
            const cx0 = rx0;
            const cx1 = rx1;
            const cy0 = ry0 + (ry1 - ry0) * 3 / 5;
            const cy1 = ry1;

            const vis_luma = regionLuma(img, cx0, cy0, cx1, cy1);
            check(vis_luma > 1.0, "window region is visible before hiding (luma {d:.1})", "window region is already black before hiding (luma {d:.1})", .{vis_luma});

            // Hide it.
            var hide_list = [_]u64{t.id};
            {
                const ev = try c.requestCompositor(.{ .share_configured = .{
                    .kind = .screen, .id = out.id, .hidden = hide_list[0..],
                } }, .raw);
                ev.deinit(alloc);
            }
            io.sleep(.fromMilliseconds(150), .awake) catch {};

            if (requestFrame(&inbox, 2)) {
                const img2 = inbox.frame.?;
                writePpm("share-hidden.ppm", img2) catch {};
                const hid_luma = regionLuma(img2, cx0, cy0, cx1, cy1);
                check(
                    hid_luma <= 1.0,
                    "window region is BLACK while hidden (luma {d:.1})",
                    "window region is NOT black while hidden (luma {d:.1}) -- redaction did not happen",
                    .{hid_luma},
                );
                std.debug.print("  wrote share-hidden.ppm\n", .{});

                // Unhide: the flag must be a toggle, not a latch.
                {
                    const ev = try c.requestCompositor(.{ .set_share_hidden = .{ .id = t.id, .hidden = false } }, .raw);
                    ev.deinit(alloc);
                }
                io.sleep(.fromMilliseconds(150), .awake) catch {};
                if (requestFrame(&inbox, 3)) {
                    const back_luma = regionLuma(inbox.frame.?, cx0, cy0, cx1, cy1);
                    check(
                        back_luma > 1.0,
                        "window region came back when unhidden (luma {d:.1})",
                        "window region stayed black after unhiding (luma {d:.1}) -- the flag is a latch",
                        .{back_luma},
                    );
                } else {
                    fail("no frame after unhiding", .{});
                }
            } else {
                fail("no frame while a window was hidden", .{});
            }
        }
    } else {
        std.debug.print("  (no window on this output to hide; skipping the redaction check)\n", .{});
    }

    // ---- 6. stop ---------------------------------------------------------
    {
        const ev = try c.requestCompositor(.{ .share_stop = {} }, .raw);
        ev.deinit(alloc);
    }
    const stopped = waitFor(struct {
        fn p(ib: *Inbox, _: usize) bool {
            return ib.stopped_seen;
        }
    }.p, @as(usize, 0), 5000, &inbox);
    check(stopped, "share_stop answered with share_stopped", "share_stopped never arrived", .{});

    std.debug.print("\n{d} passed, {d} FAILED\n", .{ passed, failed });
    if (inbox.started) |s| {
        std.debug.print("note: a PipeWire consumer attached, node id {d}\n", .{s.node_id});
    } else {
        std.debug.print("note: no PipeWire consumer attached, so share_started never fired.\n", .{});
        std.debug.print("      That is expected with nothing consuming the node; run any app\n", .{});
        std.debug.print("      that shares, or `pw-cat --record` against the node, to see it.\n", .{});
    }
    std.process.exit(if (failed == 0) 0 else 1);
}