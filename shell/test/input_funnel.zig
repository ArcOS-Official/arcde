const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const event_pump = @import("../src/event_pump.zig");
const HubUi = @import("../src/HubUi.zig");
const State = @import("../src/State.zig");

const C = SDLBackend.c;
const testing = std.testing;

// Input-funnel checks for the shell focus domain (bar + hub overlay).
//
// NOTE: kept in the tree on request until the author says to commit, at
// which point this file (and its build step) should be REMOVED, not
// committed. It is intentionally thorough rather than minimal.
//
// What it pins, end to end with fake inputs:
//  1. The shared SDL pump delivers hub-targeted OS events to the hub
//     dvui.Window (and bar-targeted ones to the bar) — i.e. the window
//     even gets these inputs.
//  2. Typed text arriving at the hub lands in the launcher search and
//     wifi search entries — i.e. it is NOT a textEntry widget bug.
//  3. The dvui keysym layer reports real letter codes (fork regression:
//     A-Z used to collapse to .zero, which also broke the p shortcut).
//  4. Shell focus requests are domain-scoped (hub or bar).
//
// Hermetic: forces the SDL dummy video/audio drivers via hints, hidden
// windows, no compositor, no D-Bus.

const FakeHubCtx = struct {
    pub const KeyboardInteractivity = enum { none, exclusive, on_demand };

    pub fn setSize(_: @This(), _: u32, _: u32) void {}
    pub fn setKeyboardInteractivity(_: @This(), _: KeyboardInteractivity) void {}
};

fn useDummyDrivers() void {
    _ = C.SDL_SetHint(C.SDL_HINT_VIDEO_DRIVER, "dummy");
    _ = C.SDL_SetHint(C.SDL_HINT_AUDIO_DRIVER, "dummy");
}

const Harness = struct {
    be_bar: SDLBackend,
    be_hub: SDLBackend,
    win_bar: dvui.Window,
    win_hub: dvui.Window,

    fn init(alloc: std.mem.Allocator) !Harness {
        useDummyDrivers();
        var be_bar = try SDLBackend.initWindow(.{
            .io = testing.io,
            .size = .{ .w = 640, .h = 50 },
            .vsync = false,
            .title = "funnel-bar",
            .hidden = true,
        });
        errdefer be_bar.deinit();
        var be_hub = try SDLBackend.initWindow(.{
            .io = testing.io,
            .size = .{ .w = 640, .h = 600 },
            .vsync = false,
            .title = "funnel-hub",
            .hidden = true,
        });
        // Only the bar backend quits SDL; mirrors main.zig.
        be_hub.sdl_quit = false;
        errdefer be_hub.deinit();
        var win_bar = try dvui.Window.init(@src(), alloc, be_bar.backend(), .{});
        errdefer win_bar.deinit();
        const win_hub = try dvui.Window.init(@src(), alloc, be_hub.backend(), .{});
        return .{
            .be_bar = be_bar,
            .be_hub = be_hub,
            .win_bar = win_bar,
            .win_hub = win_hub,
        };
    }

    fn deinit(self: *Harness) void {
        self.win_hub.deinit();
        self.win_bar.deinit();
        self.be_hub.deinit();
        self.be_bar.deinit();
    }
};

fn pushKeyDown(window_id: u32, key: c_uint) !void {
    var ev: C.SDL_Event = std.mem.zeroes(C.SDL_Event);
    ev.type = @as(u32, @intCast(C.SDL_EVENT_KEY_DOWN));
    ev.key.windowID = window_id;
    ev.key.key = @as(@TypeOf(ev.key.key), @intCast(key));
    ev.key.down = true;
    ev.key.repeat = false;
    try testing.expect(C.SDL_PushEvent(&ev));
}

fn pushText(window_id: u32, text: []const u8, buf: []u8) !void {
    try testing.expect(text.len + 1 <= buf.len);
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    var ev: C.SDL_Event = std.mem.zeroes(C.SDL_Event);
    ev.type = @as(u32, @intCast(C.SDL_EVENT_TEXT_INPUT));
    ev.text.windowID = window_id;
    ev.text.text = @ptrCast(buf.ptr);
    try testing.expect(C.SDL_PushEvent(&ev));
}

const SeenInput = struct {
    key_p: bool = false,
    key_a: bool = false,
    text_p: bool = false,
};

fn scanInputs() SeenInput {
    var seen: SeenInput = .{};
    for (dvui.events()) |*ev| {
        switch (ev.evt) {
            .key => |k| {
                if (k.action == .down) {
                    if (k.code == .p) seen.key_p = true;
                    if (k.code == .a) seen.key_a = true;
                }
            },
            .text => |te| switch (te.action) {
                .value => |set| {
                    const s = std.mem.sliceTo(set.txt, 0);
                    if (std.mem.eql(u8, s, "p")) seen.text_p = true;
                },
                else => {},
            },
            else => {},
        }
    }
    return seen;
}

test "funnel: pump delivers hub-targeted input to the hub window" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const hub_id = C.SDL_GetWindowID(h.be_hub.window);
    const bar_id = C.SDL_GetWindowID(h.be_bar.window);
    try testing.expect(hub_id != 0);
    try testing.expect(bar_id != 0);
    try testing.expect(hub_id != bar_id);

    // Fake OS-level input aimed at the hub surface.
    try pushKeyDown(hub_id, C.SDLK_P);
    try pushKeyDown(hub_id, C.SDLK_A);
    var tbuf: [8]u8 = undefined;
    try pushText(hub_id, "p", &tbuf);

    // Through the exact dispatch the live shell uses.
    try event_pump.pumpEvents(&h.be_bar, &h.win_bar, &h.be_hub, &h.win_hub);

    // The hub window must have all of it, with real letter codes.
    const t: i128 = 16 * std.time.ns_per_ms;
    try h.win_hub.begin(t);
    const hub_seen = scanInputs();
    _ = try h.win_hub.end(.{});
    try testing.expect(hub_seen.key_p);
    try testing.expect(hub_seen.key_a);
    try testing.expect(hub_seen.text_p);

    // The bar window must have none of it.
    try h.win_bar.begin(t);
    const bar_seen = scanInputs();
    _ = try h.win_bar.end(.{});
    try testing.expect(!bar_seen.key_p);
    try testing.expect(!bar_seen.key_a);
    try testing.expect(!bar_seen.text_p);
}

test "funnel: bar-targeted input stays on the bar" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const bar_id = C.SDL_GetWindowID(h.be_bar.window);
    try testing.expect(bar_id != 0);

    var tbuf: [8]u8 = undefined;
    try pushText(bar_id, "p", &tbuf);
    try event_pump.pumpEvents(&h.be_bar, &h.win_bar, &h.be_hub, &h.win_hub);

    const t: i128 = 16 * std.time.ns_per_ms;
    try h.win_bar.begin(t);
    const bar_seen = scanInputs();
    _ = try h.win_bar.end(.{});
    try testing.expect(bar_seen.text_p);

    try h.win_hub.begin(t);
    const hub_seen = scanInputs();
    _ = try h.win_hub.end(.{});
    try testing.expect(!hub_seen.text_p);
}

fn driveHubFrames(win: *dvui.Window, hub: *HubUi, state: *State, t: *i128, n: usize) !void {
    const tick: i128 = 16 * std.time.ns_per_ms;
    var f: usize = 0;
    while (f < n) : (f += 1) {
        t.* += tick;
        try win.begin(t.*);
        _ = try hub.hubFrame(state, state.io, FakeHubCtx{}, undefined);
        _ = try win.end(.{});
    }
}

test "funnel: typed text lands in the launcher search entry" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var state: State = .{};
    state.socket_path_override = "/tmp/nshell-funnel-unused.sock";
    try state.init(alloc, testing.io);
    defer state.deinit();
    var hub = HubUi.init();

    var t: i128 = 0;
    try h.win_hub.begin(1);
    hub.switchMode(.launcher, &state);
    _ = try hub.hubFrame(&state, state.io, FakeHubCtx{}, undefined);
    _ = try h.win_hub.end(.{});
    try driveHubFrames(&h.win_hub, &hub, &state, &t, 5);
    try testing.expect(hub.launcher_query.len == 0);

    // Fake typing, the way the pump would deliver it.
    t += 16 * std.time.ns_per_ms;
    try h.win_hub.begin(t);
    _ = try h.win_hub.addEventText(.{ .text = "hello" });
    _ = try hub.hubFrame(&state, state.io, FakeHubCtx{}, undefined);
    _ = try h.win_hub.end(.{});
    try driveHubFrames(&h.win_hub, &hub, &state, &t, 2);

    // Delivery works, so any live failure is upstream of the entry —
    // not a textEntry widget bug.
    try testing.expectEqualStrings("hello", hub.launcher_query);
}

test "funnel: p typed in wifi search stays in network and lands" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var state: State = .{};
    state.socket_path_override = "/tmp/nshell-funnel-unused.sock";
    try state.init(alloc, testing.io);
    defer state.deinit();
    var hub = HubUi.init();

    var t: i128 = 0;
    try h.win_hub.begin(1);
    hub.switchMode(.network, &state);
    _ = try hub.hubFrame(&state, state.io, FakeHubCtx{}, undefined);
    _ = try h.win_hub.end(.{});
    try driveHubFrames(&h.win_hub, &hub, &state, &t, 5);
    try testing.expect(hub.hubmode == .network);

    // Fake key + text for "p", as SDL would deliver them.
    t += 16 * std.time.ns_per_ms;
    try h.win_hub.begin(t);
    _ = try h.win_hub.addEventKey(.{ .code = .p, .action = .down, .mod = .none });
    _ = try h.win_hub.addEventText(.{ .text = "p" });
    _ = try hub.hubFrame(&state, state.io, FakeHubCtx{}, undefined);
    _ = try h.win_hub.end(.{});
    try driveHubFrames(&h.win_hub, &hub, &state, &t, 2);

    // No hijack to launcher, and the entry kept the character.
    try testing.expect(hub.hubmode == .network);
    try testing.expectEqualStrings("p", state.net.search);
}

test "funnel: shell focus requests are domain-scoped" {
    const alloc = testing.allocator;
    var state: State = .{};
    state.socket_path_override = "/tmp/nshell-funnel-unused.sock";
    try state.init(alloc, testing.io);
    defer state.deinit();

    // Either shell surface may request; both name the shared domain.
    state.requestShellFocus(.hub);
    state.requestShellFocus(.bar);

    var batch: std.ArrayList(State.Action) = .empty;
    defer batch.deinit(alloc);
    state.req_q.popAll(testing.io, &batch);
    try testing.expectEqual(@as(usize, 2), batch.items.len);
    try testing.expect(batch.items[0] == .request_keyboard_focus);
    try testing.expect(batch.items[0].request_keyboard_focus == .hub);
    try testing.expect(batch.items[1] == .request_keyboard_focus);
    try testing.expect(batch.items[1].request_keyboard_focus == .bar);
}
