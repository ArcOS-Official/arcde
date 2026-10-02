const std = @import("std");
const builtin = @import("builtin");
const Dbus = @import("Dbus.zig");
const State = @import("State.zig");
const c = @import("sd_bus");

// xdg-desktop-portal backend for screen casting: serves
// org.freedesktop.impl.portal.ScreenCast on the session bus so
// xdg-desktop-portal can route app ScreenCast requests to us (see
// scripts/arc.portal). Implements the version-6 impl interface:
//
//   CreateSession  -> remembers the session object the frontend hands us
//   SelectSources  -> remembers types / multiple / cursor_mode
//   Start          -> opens the hub's share picker (HubUi .sharescreen),
//                     waits for the user to confirm in the config menu, then
//                     asks the compositor to start and returns its PipeWire
//                     node id
//   Session.Close  -> tears the stream down
//
// Start answers synchronously (the impl interface returns response + results
// in the reply), so the picker wait blocks this thread — it never touches the
// bus while waiting, and other calls simply queue behind it on the socket.
// That is why this runs on its own thread instead of State.worker: the
// notification service there must keep answering while the picker is open.
//
// Everything below runs single-threaded on the portal thread. The session bus
// is the only thing polled: the compositor owns the stream, the image and
// the PipeWire node (compositor/src/ShareStream.zig), so once configured
// this thread does nothing but wait on the bus.

const Portal = @This();

// The PipeWire producer, the frame compositor and the capture session all
// live in the compositor process (compositor/src/ShareStream.zig and
// friends): the compositor owns the stream end to end, so this file is
// only the D-Bus frontend's side of the handshake.


pub const bus_name = "org.freedesktop.impl.portal.desktop.arc";
const object_path = "/org/freedesktop/impl/portal/ScreenCast";
const iface_screen = "org.freedesktop.impl.portal.ScreenCast";
const iface_session = "org.freedesktop.impl.portal.Session";
const iface_props = "org.freedesktop.DBus.Properties";

// Source types (AvailableSourceTypes bitmask): monitors only for now.
pub const source_monitor: u32 = 1;
// Cursor modes: Hidden (stream has no cursor) and Embedded (the compositor
// paints cursors into the frames we capture).
pub const cursor_hidden: u32 = 1;
pub const cursor_embedded: u32 = 2;
pub const cursor_modes: u32 = cursor_hidden | cursor_embedded;

/// Interface version we implement (see the XML in
/// /usr/share/dbus-1/interfaces).
pub const interface_version: u32 = 6;

// Portal response codes (org.freedesktop.portal.Request semantics).
const resp_success: u32 = 0;
const resp_cancelled: u32 = 1;
const resp_failed: u32 = 2;

/// How long Start waits for the picker before giving up (cancelled). The
/// frontend's own dialog timeout is 25s; stay just under it.
const picker_timeout_ms: i64 = 25_000;
const picker_poll_ms: i64 = 40;
/// How long Start waits for the compositor to publish a PipeWire node.
const start_wait_ms: i64 = 15_000;
/// Backoff when the bus name is taken or there is no session bus.
const bus_retry_ms: i64 = 30_000;

const Session = struct {
    /// Object path the frontend wants the Session object exported at.
    session_path: []const u8,
    /// Request object path from CreateSession (unused: replies are direct).
    handle_path: []const u8,
    app_id: []const u8,
    session_id: []const u8,
    types: u32 = source_monitor,
    multiple: bool = false,
    cursor_mode: u32 = cursor_hidden,
    started: bool = false,

    fn deinit(self: *Session, alloc: std.mem.Allocator) void {
        if (self.session_path.len > 0) alloc.free(self.session_path);
        if (self.handle_path.len > 0) alloc.free(self.handle_path);
        if (self.app_id.len > 0) alloc.free(self.app_id);
        if (self.session_id.len > 0) alloc.free(self.session_id);
    }
};

alloc: std.mem.Allocator = undefined,
io: std.Io = undefined,
state: *State = undefined,
bus: ?*Dbus.Bus = null,
retry_at_ms: i64 = 0,
sessions: std.StringHashMapUnmanaged(Session) = .empty,
next_session: u64 = 1,
next_stream: u64 = 1,

// Live stream (one at a time: the picker delivers a single monitor).
/// session_path of the session owning the live stream (borrowed key).
active_session: ?[]const u8 = null,
// Buffer geometry the capture negotiated (what the stream really is, not
// necessarily the output mode): reported back to the frontend.
stream_w: u32 = 0,
stream_h: u32 = 0,

pub fn init(self: *Portal, alloc: std.mem.Allocator, io: std.Io, state: *State) void {
    self.* = .{ .alloc = alloc, .io = io, .state = state };
}

/// Thread entry (see main.zig: init must run before spawning this). Runs
/// until the state stop flag; everything it owns is released before
/// returning, and the portal_done flag tells State.deinit it is safe to
/// free the model underneath us.
pub fn threadMain(self: *Portal, state: *State) void {
    while (!state.stop.load(.seq_cst)) self.tick();
    self.shutdown();
    state.portal_done.store(true, .seq_cst);
}

fn shutdown(self: *Portal) void {
    if (self.bus) |b| Dbus.closeBus(b);
    self.bus = null;
    self.forgetAllSessions();
}

// -- main loop --------------------------------------------------------------

fn nowMs(self: *Portal) i64 {
    return std.Io.Clock.boot.now(self.io).toMilliseconds();
}

fn tick(self: *Portal) void {
    // Like Dbus.zig: dead under tests, which also keeps sd_bus, wayland and
    // pipewire symbols out of the link-light test binaries.
    if (builtin.is_test) return;

    if (self.bus == null and self.nowMs() >= self.retry_at_ms) {
        self.retry_at_ms = self.nowMs() + bus_retry_ms;
        if (self.connect()) std.log.info("portal: serving {s}", .{bus_name});
    }
    if (self.bus) |bus| self.processBus(bus);

    self.waitForEvents();
}

/// Sleep until one of our fds has work, or until the next frame is due.
fn waitForEvents(self: *Portal) void {
    var fds: [3]std.posix.pollfd = undefined;
    var n: usize = 0;
    if (self.bus) |bus| {
        fds[n] = .{
            .fd = c.sd_bus_get_fd(bus),
            // sd-bus reports its readiness as poll bits, so they map 1:1.
            .events = @intCast(c.sd_bus_get_events(bus)),
            .revents = 0,
        };
        n += 1;
    }
    // Nothing else to poll: the compositor owns the PipeWire loop, so this
    // thread only ever waits on the session bus.
    _ = std.posix.poll(fds[0..n], 200) catch {};
}

fn connect(self: *Portal) bool {
    const bus = Dbus.openSession() orelse return false;
    if (c.sd_bus_add_object(bus, null, object_path, objectHandler, @ptrCast(self)) < 0) {
        Dbus.closeBus(bus);
        return false;
    }
    const rc = c.sd_bus_request_name(bus, bus_name, 0);
    if (rc < 0) {
        // xdg-desktop-portal routes to whichever backend owns the name; a
        // second desktop session (or wlr's own backend) may already hold it.
        std.log.debug("portal: cannot own {s} ({d})", .{ bus_name, rc });
        Dbus.closeBus(bus);
        return false;
    }
    self.bus = bus;
    return true;
}

fn processBus(self: *Portal, bus: *Dbus.Bus) void {
    while (true) {
        var msg: ?*c.sd_bus_message = null;
        const r = c.sd_bus_process(bus, &msg);
        if (msg) |m| _ = c.sd_bus_message_unref(m);
        if (r < 0) {
            std.log.warn("portal: bus error ({d}), reconnecting", .{r});
            Dbus.closeBus(bus);
            self.bus = null;
            self.retry_at_ms = self.nowMs() + bus_retry_ms;
            // Sessions died with the bus; nothing can reach them anymore.
            self.forgetAllSessions();
            return;
        }
        if (r == 0) break;
    }
    _ = c.sd_bus_flush(bus);
}

fn forgetAllSessions(self: *Portal) void {
    self.teardownStream();
    var it = self.sessions.iterator();
    while (it.next()) |entry| {
        var sess = entry.value_ptr.*;
        sess.deinit(self.alloc);
    }
    self.sessions.deinit(self.alloc);
    self.sessions = .empty;
}

// -- main object handler ----------------------------------------------------

fn objectHandler(
    m_raw: ?*c.sd_bus_message,
    userdata: ?*anyopaque,
    ret_error: [*c]c.sd_bus_error,
) callconv(.c) c_int {
    _ = ret_error;
    const m = m_raw orelse return 0;
    const self: *Portal = @ptrCast(@alignCast(userdata orelse return 0));
    var msg_type: u8 = 0;
    if (c.sd_bus_message_get_type(m, &msg_type) < 0) return 0;
    if (msg_type != @as(u8, c.SD_BUS_MESSAGE_METHOD_CALL)) return 0;
    const member_ptr = c.sd_bus_message_get_member(m);
    if (member_ptr == null) return 0;
    const member = std.mem.span(member_ptr);

    if (std.mem.eql(u8, member, "CreateSession")) return self.handleCreateSession(m);
    if (std.mem.eql(u8, member, "SelectSources")) return self.handleSelectSources(m);
    if (std.mem.eql(u8, member, "Start")) return self.handleStart(m);
    if (std.mem.eql(u8, member, "Get") or std.mem.eql(u8, member, "GetAll"))
        return self.handleProperties(m, member);
    if (std.mem.eql(u8, member, "Introspect")) {
        const xml: [*:0]const u8 = introspect_xml;
        _ = c.sd_bus_reply_method_return(m, "s", xml);
        return 1;
    }
    _ = c.sd_bus_reply_method_errorf(m, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
    return 1;
}

/// org.freedesktop.DBus.Properties: the frontend reads these at startup to
/// decide what we can do.
fn handleProperties(self: *Portal, m: *c.sd_bus_message, member: []const u8) c_int {
    _ = self;
    const is_all = std.mem.eql(u8, member, "GetAll");
    var iface: ?[*:0]const u8 = null;
    var prop: ?[*:0]const u8 = null;
    if (is_all) {
        if (c.sd_bus_message_read(m, "s", &iface) < 0) return 1;
    } else {
        if (c.sd_bus_message_read(m, "ss", &iface, &prop) < 0) return 1;
    }
    if (!is_forInterface(str(iface))) {
        _ = c.sd_bus_reply_method_errorf(m, "org.freedesktop.DBus.Error.UnknownInterface", "Unknown interface");
        return 1;
    }
    if (is_all) return replyAllProps(m);
    const name = str(prop);
    const value: ?u32 = if (std.mem.eql(u8, name, "AvailableSourceTypes"))
        source_monitor
    else if (std.mem.eql(u8, name, "AvailableCursorModes"))
        cursor_modes
    else if (std.mem.eql(u8, name, "version"))
        interface_version
    else
        null;
    if (value) |v| {
        _ = c.sd_bus_reply_method_return(m, "v", "u", v);
        return 1;
    }
    _ = c.sd_bus_reply_method_errorf(m, "org.freedesktop.DBus.Error.UnknownProperty", "Unknown property");
    return 1;
}

fn is_forInterface(name: []const u8) bool {
    return std.mem.eql(u8, name, iface_screen) or std.mem.eql(u8, name, iface_props);
}

fn replyAllProps(m: *c.sd_bus_message) c_int {
    var reply_slot: ?*c.sd_bus_message = null;
    if (c.sd_bus_message_new_method_return(m, &reply_slot) < 0) return 1;
    const reply = reply_slot orelse return 1;
    defer _ = c.sd_bus_message_unref(reply);
    if (c.sd_bus_message_open_container(reply, 'a', "{sv}") < 0) return 1;
    appendPropU32(reply, "AvailableSourceTypes", source_monitor);
    appendPropU32(reply, "AvailableCursorModes", cursor_modes);
    appendPropU32(reply, "version", interface_version);
    if (c.sd_bus_message_close_container(reply) < 0) return 1;
    _ = c.sd_bus_message_send(reply);
    return 1;
}

fn appendPropU32(msg: *c.sd_bus_message, key: [*:0]const u8, value: u32) void {
    if (c.sd_bus_message_open_container(msg, 'e', "{sv}") < 0) return;
    if (c.sd_bus_message_append(msg, "s", key) < 0) return;
    if (c.sd_bus_message_open_container(msg, 'v', "u") < 0) return;
    _ = c.sd_bus_message_append(msg, "u", value);
    _ = c.sd_bus_message_close_container(msg);
    _ = c.sd_bus_message_close_container(msg);
}

// -- ScreenCast methods -----------------------------------------------------

fn handleCreateSession(self: *Portal, m: *c.sd_bus_message) c_int {
    var handle: ?[*:0]const u8 = null;
    var session_path: ?[*:0]const u8 = null;
    var app_id: ?[*:0]const u8 = null;
    if (c.sd_bus_message_read(m, "ooss", &handle, &session_path, &app_id) < 0)
        return replyFailed(m, "malformed CreateSession");
    if (c.sd_bus_message_skip(m, "a{sv}") < 0)
        return replyFailed(m, "malformed CreateSession options");

    const bus = self.bus orelse return replyFailed(m, "no bus");
    const key = str(session_path);
    const alloc = self.alloc;
    const path_copy = alloc.dupe(u8, key) catch return replyFailed(m, "out of memory");
    errdefer alloc.free(path_copy);
    const handle_copy = alloc.dupe(u8, str(handle)) catch return replyFailed(m, "out of memory");
    errdefer alloc.free(handle_copy);
    const app_copy = alloc.dupe(u8, str(app_id)) catch return replyFailed(m, "out of memory");
    errdefer alloc.free(app_copy);
    var id_stack: [24]u8 = undefined;
    const id_text = std.fmt.bufPrint(&id_stack, "{d}", .{self.next_session}) catch return replyFailed(m, "out of memory");
    const id_buf = alloc.dupe(u8, id_text) catch return replyFailed(m, "out of memory");
    self.next_session += 1;

    // Export the Session object at the path the frontend picked, so its
    // Close (and our Closed signal) land there.
    if (c.sd_bus_add_object(bus, null, session_path, sessionHandler, @ptrCast(self)) < 0) {
        alloc.free(id_buf);
        alloc.free(app_copy);
        alloc.free(handle_copy);
        alloc.free(path_copy);
        return replyFailed(m, "cannot export session object");
    }
    const gop = self.sessions.getOrPut(alloc, key) catch {
        alloc.free(id_buf);
        alloc.free(app_copy);
        alloc.free(handle_copy);
        alloc.free(path_copy);
        return replyFailed(m, "out of memory");
    };
    if (gop.found_existing) {
        var old = gop.value_ptr;
        old.deinit(alloc);
    }
    gop.key_ptr.* = path_copy;
    gop.value_ptr.* = .{
        .session_path = path_copy,
        .handle_path = handle_copy,
        .app_id = app_copy,
        .session_id = id_buf,
    };
    std.log.info("portal: session {s} for {s}", .{ key, app_copy });

    return replySessionId(m, resp_success, id_buf);
}

fn handleSelectSources(self: *Portal, m: *c.sd_bus_message) c_int {
    var handle: ?[*:0]const u8 = null;
    var session_path: ?[*:0]const u8 = null;
    var app_id: ?[*:0]const u8 = null;
    if (c.sd_bus_message_read(m, "ooss", &handle, &session_path, &app_id) < 0)
        return replyFailed(m, "malformed SelectSources");
    const session = self.sessions.getPtr(str(session_path)) orelse
        return replyFailed(m, "unknown session");

    self.readOptions(m, session);
    if ((session.types & source_monitor) == 0) {
        // Only monitors: a window/virtual-only request cannot be served.
        std.log.warn("portal: SelectSources asked for types {d}, we only do monitors", .{session.types});
        return replyResults(m, resp_failed, 0, 0, 0);
    }
    if (session.cursor_mode != cursor_hidden and session.cursor_mode != cursor_embedded) {
        std.log.warn("portal: unsupported cursor_mode {d}, using hidden", .{session.cursor_mode});
        session.cursor_mode = cursor_hidden;
    }
    return replyResults(m, resp_success, 0, 0, 0);
}

fn handleStart(self: *Portal, m: *c.sd_bus_message) c_int {
    var handle: ?[*:0]const u8 = null;
    var session_path: ?[*:0]const u8 = null;
    var app_id: ?[*:0]const u8 = null;
    var parent: ?[*:0]const u8 = null;
    if (c.sd_bus_message_read(m, "oosss", &handle, &session_path, &app_id, &parent) < 0)
        return replyFailed(m, "malformed Start");
    const session = self.sessions.getPtr(str(session_path)) orelse
        return replyFailed(m, "unknown session");

    // The picker IS the dialog for SelectSources' configuration: open the
    // hub share menu and block here until the user chooses or walks away.
    const sel = self.waitForPicker() orelse {
        std.log.info("portal: Start cancelled for {s}", .{session.app_id});
        return replyResults(m, resp_cancelled, 0, 0, 0);
    };
    const node_id = self.startStream(sel) orelse {
        return replyResults(m, resp_failed, 0, 0, 0);
    };
    session.started = true;
    self.active_session = session.session_path;
    // Size is the compositor's buffer geometry, not the output mode: the
    // stream is whatever the capture session negotiated.
    return replyResults(m, resp_success, node_id, self.stream_w, self.stream_h);
}

/// Open the picker (HubUi .share) and wait for the user's choice. Returns
/// null when the user cancelled, timed out, or the shell is shutting down.
fn waitForPicker(self: *Portal) ?State.ShareSelection {
    self.state.beginShareRequest();
    const deadline = self.nowMs() + picker_timeout_ms;
    while (self.state.sharePickerState() == .waiting) {
        if (self.state.stop.load(.seq_cst)) return null;
        if (self.nowMs() > deadline) {
            std.log.warn("portal: no pick within {d}ms, cancelling", .{picker_timeout_ms});
            return null;
        }
        // No bus pumping here: sd_bus_process is not reentrant, and the
        // reply we owe the frontend blocks anyway until we answer.
        self.io.sleep(.fromMilliseconds(@intCast(picker_poll_ms)), .awake) catch return null;
    }
    if (self.state.sharePickerState() != .picked) return null;
    const sel = self.state.shareSelection();
    if (sel.id == 0 or sel.name.len == 0) return null;
    return sel;
}

// -- stream lifecycle -------------------------------------------------------

/// Capture the picked monitor and publish it as a PipeWire node. Returns
/// the node id the frontend hands to the app.
/// Ask the compositor to start streaming the selected view, then wait for
/// it to publish a node.
///
/// The compositor owns the stream end to end (it builds the image and runs
/// the PipeWire producer), so there is nothing to create here: this asks for
/// a share and waits for `share_started`. By the time we get here the user
/// has already been through the picker and the config menu, so the hidden
/// window set is whatever they confirmed.
fn startStream(self: *Portal, sel: State.ShareSelection) ?u32 {
    // One stream at a time: a new share replaces the old one (its session is
    // told with Closed).
    if (self.active_session) |old| self.closeSession(old, true);

    self.state.confirmShare(sel.kind, sel.id);

    // Bounded: the compositor publishes only once a PipeWire consumer links,
    // which for a brand-new node takes as long as the recipient needs to
    // connect. Wait, but not forever.
    const deadline = self.nowMs() + start_wait_ms;
    while (self.nowMs() < deadline) {
        if (self.state.stop.load(.seq_cst)) return null;
        const node = self.state.shareNodeId();
        if (node != 0) {
            std.log.info("portal: compositor streaming {s} {d} as node {d}", .{
                @tagName(sel.kind), sel.id, node,
            });
            return node;
        }
        self.io.sleep(.fromMilliseconds(picker_poll_ms), .awake) catch return null;
    }
    std.log.warn("portal: compositor never published a node for {d}", .{sel.id});
    return null;
}

fn teardownStream(self: *Portal) void {
    // The compositor owns the stream; ask it to stop rather than tearing
    // anything down here.
    if (self.active_session != null) self.state.stopShare();
    self.active_session = null;
}

/// Close a session (frontend Close, or our own teardown after the capture
/// died). When `emit_closed`, the portal is the one ending it, so the
/// Session.Closed signal is required.
fn closeSession(self: *Portal, session_path: ?[]const u8, emit_closed: bool) void {
    const path = session_path orelse return;
    if (self.active_session) |active| {
        if (std.mem.eql(u8, active, path)) self.teardownStream();
    }
    if (emit_closed) {
        if (self.bus) |bus| {
            _ = c.sd_bus_emit_signal(bus, path.ptr, iface_session, "Closed", "");
        }
    }
    if (self.sessions.fetchRemove(path)) |kv| {
        var sess = kv.value;
        sess.deinit(self.alloc);
    }
}

// -- Session objects --------------------------------------------------------

fn sessionHandler(
    m_raw: ?*c.sd_bus_message,
    userdata: ?*anyopaque,
    ret_error: [*c]c.sd_bus_error,
) callconv(.c) c_int {
    _ = ret_error;
    const m = m_raw orelse return 0;
    const self: *Portal = @ptrCast(@alignCast(userdata orelse return 0));
    var msg_type: u8 = 0;
    if (c.sd_bus_message_get_type(m, &msg_type) < 0) return 0;
    if (msg_type != @as(u8, c.SD_BUS_MESSAGE_METHOD_CALL)) return 0;
    const member_ptr = c.sd_bus_message_get_member(m);
    if (member_ptr == null) return 0;
    const member = std.mem.span(member_ptr);

    const path = c.sd_bus_message_get_path(m);
    const session_path = if (path != null) str(path) else "";

    if (std.mem.eql(u8, member, "Close")) {
        self.closeSession(session_path, false);
        _ = c.sd_bus_reply_method_return(m, "");
        return 1;
    }
    if (std.mem.eql(u8, member, "Get")) {
        var iface: ?[*:0]const u8 = null;
        var prop: ?[*:0]const u8 = null;
        if (c.sd_bus_message_read(m, "ss", &iface, &prop) < 0) return 1;
        if (std.mem.eql(u8, str(iface), iface_session) and std.mem.eql(u8, str(prop), "version")) {
            _ = c.sd_bus_reply_method_return(m, "v", "u", @as(u32, 1));
            return 1;
        }
        _ = c.sd_bus_reply_method_errorf(m, "org.freedesktop.DBus.Error.UnknownProperty", "Unknown property");
        return 1;
    }
    _ = c.sd_bus_reply_method_errorf(m, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
    return 1;
}

// -- replies ----------------------------------------------------------------

fn replyFailed(m: *c.sd_bus_message, comptime why: [*:0]const u8) c_int {
    _ = c.sd_bus_reply_method_errorf(m, "org.freedesktop.DBus.Error.InvalidArgs", why);
    return 1;
}

/// CreateSession reply: response + {"session_id": s}.
fn replySessionId(m: *c.sd_bus_message, response: u32, session_id: []const u8) c_int {
    var reply_slot: ?*c.sd_bus_message = null;
    if (c.sd_bus_message_new_method_return(m, &reply_slot) < 0) return 1;
    const reply = reply_slot orelse return 1;
    defer _ = c.sd_bus_message_unref(reply);
    if (c.sd_bus_message_append(reply, "u", response) < 0) return 1;
    if (c.sd_bus_message_open_container(reply, 'a', "{sv}") < 0) return 1;
    if (response == resp_success) {
        var zbuf: [64]u8 = undefined;
        const z: [*:0]const u8 = std.fmt.bufPrintZ(&zbuf, "{s}", .{session_id}) catch return 1;
        if (c.sd_bus_message_open_container(reply, 'e', "{sv}") < 0) return 1;
        if (c.sd_bus_message_append(reply, "s", "session_id") < 0) return 1;
        if (c.sd_bus_message_open_container(reply, 'v', "s") < 0) return 1;
        if (c.sd_bus_message_append(reply, "s", z) < 0) return 1;
        _ = c.sd_bus_message_close_container(reply);
        _ = c.sd_bus_message_close_container(reply);
    }
    if (c.sd_bus_message_close_container(reply) < 0) return 1;
    _ = c.sd_bus_message_send(reply);
    return 1;
}

/// The shared ScreenCast reply: (response, results). On success results
/// carries `streams` = one a(ua{sv}) entry: node id plus position, size and
/// source_type (position is optional in the spec, size is not).
fn replyResults(
    m: *c.sd_bus_message,
    response: u32,
    node_id: u32,
    width: u32,
    height: u32,
) c_int {
    var reply_slot: ?*c.sd_bus_message = null;
    if (c.sd_bus_message_new_method_return(m, &reply_slot) < 0) return 1;
    const reply = reply_slot orelse return 1;
    defer _ = c.sd_bus_message_unref(reply);
    if (c.sd_bus_message_append(reply, "u", response) < 0) return 1;
    if (c.sd_bus_message_open_container(reply, 'a', "{sv}") < 0) return 1;
    if (response == resp_success) {
        // streams: a(ua{sv}) -> one entry (node_id, {..})
        if (c.sd_bus_message_open_container(reply, 'a', "(ua{sv})") < 0) return 1;
        if (c.sd_bus_message_open_container(reply, 'r', "ua{sv}") < 0) return 1;
        if (c.sd_bus_message_append(reply, "u", node_id) < 0) return 1;
        if (c.sd_bus_message_open_container(reply, 'a', "{sv}") < 0) return 1;
        // size: (ii)
        if (c.sd_bus_message_open_container(reply, 'e', "{sv}") < 0) return 1;
        if (c.sd_bus_message_append(reply, "s", "size") < 0) return 1;
        if (c.sd_bus_message_open_container(reply, 'v', "(ii)") < 0) return 1;
        if (c.sd_bus_message_append(reply, "(ii)", @as(i32, @intCast(width)), @as(i32, @intCast(height))) < 0) return 1;
        _ = c.sd_bus_message_close_container(reply);
        _ = c.sd_bus_message_close_container(reply);
        // source_type: u (1 = monitor)
        if (c.sd_bus_message_open_container(reply, 'e', "{sv}") < 0) return 1;
        if (c.sd_bus_message_append(reply, "s", "source_type") < 0) return 1;
        if (c.sd_bus_message_open_container(reply, 'v', "u") < 0) return 1;
        if (c.sd_bus_message_append(reply, "u", source_monitor) < 0) return 1;
        _ = c.sd_bus_message_close_container(reply);
        _ = c.sd_bus_message_close_container(reply);
        _ = c.sd_bus_message_close_container(reply); // dict a{sv} of the entry
        _ = c.sd_bus_message_close_container(reply); // struct (ua{sv})
        _ = c.sd_bus_message_close_container(reply); // array a(ua{sv})
    }
    if (c.sd_bus_message_close_container(reply) < 0) return 1;
    _ = c.sd_bus_message_send(reply);
    return 1;
}

// -- options parsing --------------------------------------------------------

/// Read the a{sv} options of SelectSources/Start into the session. Consumes
/// the container (so callers must not skip it afterwards).
fn readOptions(self: *Portal, m: *c.sd_bus_message, session: *Session) void {
    _ = self;
    if (c.sd_bus_message_enter_container(m, 'a', "{sv}") < 0) return;
    while (c.sd_bus_message_enter_container(m, 'e', "{sv}") > 0) {
        var key: ?[*:0]const u8 = null;
        if (c.sd_bus_message_read_basic(m, 's', @ptrCast(&key)) > 0) {
            const k = str(key);
            if (std.mem.eql(u8, k, "types")) {
                session.types = readVariantU32(m) orelse session.types;
            } else if (std.mem.eql(u8, k, "multiple")) {
                session.multiple = readVariantBool(m) orelse session.multiple;
            } else if (std.mem.eql(u8, k, "cursor_mode")) {
                session.cursor_mode = readVariantU32(m) orelse session.cursor_mode;
            } else {
                _ = c.sd_bus_message_skip(m, "v");
            }
        }
        _ = c.sd_bus_message_exit_container(m);
    }
    _ = c.sd_bus_message_exit_container(m);
}

/// Read a "v" positioned at `m` when it wraps a u32.
fn readVariantU32(m: *c.sd_bus_message) ?u32 {
    var t: u8 = 0;
    var contents: ?[*:0]const u8 = null;
    if (c.sd_bus_message_peek_type(m, &t, @ptrCast(&contents)) < 0) return null;
    if (t != 'v' or contents == null) return null;
    if (!std.mem.eql(u8, std.mem.span(contents.?), "u")) {
        _ = c.sd_bus_message_skip(m, "v");
        return null;
    }
    if (c.sd_bus_message_enter_container(m, 'v', contents.?) < 0) return null;
    var v: u32 = 0;
    const ok = c.sd_bus_message_read_basic(m, 'u', &v) > 0;
    _ = c.sd_bus_message_exit_container(m);
    return if (ok) v else null;
}

fn readVariantBool(m: *c.sd_bus_message) ?bool {
    var t: u8 = 0;
    var contents: ?[*:0]const u8 = null;
    if (c.sd_bus_message_peek_type(m, &t, @ptrCast(&contents)) < 0) return null;
    if (t != 'v' or contents == null) return null;
    if (!std.mem.eql(u8, std.mem.span(contents.?), "b")) {
        _ = c.sd_bus_message_skip(m, "v");
        return null;
    }
    if (c.sd_bus_message_enter_container(m, 'v', contents.?) < 0) return null;
    var v: u32 = 0;
    const ok = c.sd_bus_message_read_basic(m, 'b', &v) > 0;
    _ = c.sd_bus_message_exit_container(m);
    return if (ok) v != 0 else null;
}

fn str(p: ?[*:0]const u8) []const u8 {
    const s = p orelse return "";
    return std.mem.span(s);
}

const introspect_xml =
    \\<node>
    \\  <interface name="org.freedesktop.impl.portal.ScreenCast">
    \\    <method name="CreateSession">
    \\      <arg type="o" name="handle" direction="in"/>
    \\      <arg type="o" name="session_handle" direction="in"/>
    \\      <arg type="s" name="app_id" direction="in"/>
    \\      <arg type="a{sv}" name="options" direction="in"/>
    \\      <arg type="u" name="response" direction="out"/>
    \\      <arg type="a{sv}" name="results" direction="out"/>
    \\    </method>
    \\    <method name="SelectSources">
    \\      <arg type="o" name="handle" direction="in"/>
    \\      <arg type="o" name="session_handle" direction="in"/>
    \\      <arg type="s" name="app_id" direction="in"/>
    \\      <arg type="a{sv}" name="options" direction="in"/>
    \\      <arg type="u" name="response" direction="out"/>
    \\      <arg type="a{sv}" name="results" direction="out"/>
    \\    </method>
    \\    <method name="Start">
    \\      <arg type="o" name="handle" direction="in"/>
    \\      <arg type="o" name="session_handle" direction="in"/>
    \\      <arg type="s" name="app_id" direction="in"/>
    \\      <arg type="s" name="parent_window" direction="in"/>
    \\      <arg type="a{sv}" name="options" direction="in"/>
    \\      <arg type="u" name="response" direction="out"/>
    \\      <arg type="a{sv}" name="results" direction="out"/>
    \\    </method>
    \\    <property name="AvailableSourceTypes" type="u" access="read"/>
    \\    <property name="AvailableCursorModes" type="u" access="read"/>
    \\    <property name="version" type="u" access="read"/>
    \\  </interface>
    \\  <interface name="org.freedesktop.impl.portal.Session">
    \\    <method name="Close"/>
    \\    <signal name="Closed"/>
    \\    <property name="version" type="u" access="read"/>
    \\  </interface>
    \\  <interface name="org.freedesktop.DBus.Introspectable">
    \\    <method name="Introspect">
    \\      <arg type="s" name="xml_data" direction="out"/>
    \\    </method>
    \\  </interface>
    \\</node>
;
// ---------------------------------------------------------------------------
// Tests (the service itself needs a live session bus; under test the tick
// loop is dead, so only the advertised contract is checked)
// ---------------------------------------------------------------------------

test "portal: advertises monitors only, both cursor modes, interface v6" {
    const t = std.testing;
    // No window sharing or virtual monitors: apps must pick a monitor.
    try t.expectEqual(@as(u32, 1), source_monitor);
    // Hidden + Embedded (paint_cursors); no Metadata cursor channel.
    try t.expectEqual(@as(u32, 3), cursor_modes);
    // The frontend checks this against the interface XML it knows.
    try t.expectEqual(@as(u32, 6), interface_version);
    // The bus name must match scripts/arc.portal's DBusName.
    try t.expectEqualStrings("org.freedesktop.impl.portal.desktop.arc", bus_name);
}
