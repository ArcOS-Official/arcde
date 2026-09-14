const std = @import("std");
pub const protocols = @import("protocols.zig");

const log = std.log.scoped(.protocol);

pub const Encoding = protocols.compositor.Encoding;

pub const Header = struct {
    kind: u8,
    encoding: Encoding,
    length: u16,
    /// Request id. `0` is reserved for unsolicited pushes (server → client
    /// events with no matching request). Requests use `id >= 1` (assigned by
    /// `Connection.request` / `Connection.notify`); replies echo the
    /// request's id so the client reader can match them to the waiter.
    /// Anything arriving with an unknown/non-waited id is delivered to the
    /// connection's event listener.
    id: u32,

    pub const size = 8;

    /// Reserved id for unsolicited server pushes (events without a request).
    pub const push_id: u32 = 0;

    pub fn toBytes(self: *const Header) [size]u8 {
        var buf: [size]u8 = undefined;
        buf[0] = self.kind;
        buf[1] = @intFromEnum(self.encoding);
        std.mem.writeInt(u16, buf[2..4], self.length, .big);
        std.mem.writeInt(u32, buf[4..8], self.id, .big);
        return buf;
    }

    pub fn fromBytes(self: *Header, buf: [size]u8) void {
        self.* = fromStatic(buf);
    }

    pub fn fromStatic(buf: [size]u8) Header {
        return .{
            .kind = buf[0],
            .encoding = @enumFromInt(buf[1]),
            .length = std.mem.readInt(u16, buf[2..4], .big),
            .id = std.mem.readInt(u32, buf[4..8], .big),
        };
    }

    /// Checked parse for the wire read loops: a corrupt/unknown encoding
    /// byte drops the connection instead of panicking the fiber (mixed or
    /// hostile peers must never kill either side).
    pub fn parse(buf: [size]u8) !Header {
        return .{
            .kind = buf[0],
            .encoding = try Encoding.fromByte(buf[1]),
            .length = std.mem.readInt(u16, buf[2..4], .big),
            .id = std.mem.readInt(u32, buf[4..8], .big),
        };
    }
};

/// `Message.kind` is the enum discriminant – it *is* the `RequestTag`/
/// `EventTag` and fully determines how `data` must be interpreted. No
/// secondary status is hidden inside `data` (avoids HTTP-200/JSON-404).
pub const Message = struct {
    kind: u8,
    /// How `data` is stored on the wire. Transport compresses/decompresses
    /// transparently; logical `data` exposed to callbacks is always uncompressed.
    /// For compositor messages the default is `encodingFor*` per kind.
    encoding: Encoding = .raw,
    data: []const u8,
};

// ---------------------------------------------------------------------------
// Compositor wire integration – bridges typed Request/Event to Message.data
// ---------------------------------------------------------------------------

/// Re-export for convenience.
pub const compositorWire = protocols.compositor.wire;
pub const CompositorEncoding = protocols.compositor.Encoding;

/// Encode a compositor Request into a generic `Message` ready for `Connection.request`.
/// `Message.kind` is set to the `RequestTag` discriminant and *solely*
/// determines the shape of `data`. `enc` selects per-message zipping
/// (`.deflate` for bulk – snapshots/images – `.raw` for tiny control).
/// No secondary status is hidden inside `data`.
pub fn encodeCompositorRequest(
    alloc: std.mem.Allocator,
    req: protocols.compositor.Request,
    enc: CompositorEncoding,
) !Message {
    const body = try req.encodeAlloc(alloc, enc);
    return .{ .kind = req.kind(), .encoding = enc, .data = body };
}

/// Kind-driven overload – uses per-kind default (`encodingForRequest`).
pub fn encodeCompositorRequestDefault(
    alloc: std.mem.Allocator,
    req: protocols.compositor.Request,
) !Message {
    const enc = protocols.compositor.encodingForRequest(@as(protocols.compositor.RequestTag, req));
    return encodeCompositorRequest(alloc, req, enc);
}

/// Decode a `Message` that is known to carry a compositor `Request`.
/// `Message.kind` must match the payload variant; decoding follows `kind`
/// and `Message.encoding` – no hidden error code inside `data`.
pub fn decodeCompositorRequest(
    alloc: std.mem.Allocator,
    msg: Message,
) !protocols.compositor.Request {
    return try protocols.compositor.Request.decodeAllocWith(alloc, msg.kind, msg.data, msg.encoding);
}

/// Encode a compositor Event into a generic `Message` (as returned by the server callback).
/// `kind` is the `EventTag`; `data` shape follows `kind`.
pub fn encodeCompositorEvent(
    alloc: std.mem.Allocator,
    ev: protocols.compositor.Event,
    enc: CompositorEncoding,
) !Message {
    const body = try ev.encodeAlloc(alloc, enc);
    return .{ .kind = ev.kind(), .encoding = enc, .data = body };
}

pub fn encodeCompositorEventDefault(
    alloc: std.mem.Allocator,
    ev: protocols.compositor.Event,
) !Message {
    const enc = protocols.compositor.encodingForEvent(@as(protocols.compositor.EventTag, ev));
    return encodeCompositorEvent(alloc, ev, enc);
}

/// Decode a `Message` that is known to carry a compositor `Event`.
pub fn decodeCompositorEvent(
    alloc: std.mem.Allocator,
    msg: Message,
) !protocols.compositor.Event {
    return try protocols.compositor.Event.decodeAllocWith(alloc, msg.kind, msg.data, msg.encoding);
}

/// Raw frame helpers – low-level `[Encoding byte][payload]` framing for
/// generic callers that don't use typed Request/Event unions.
pub fn encodeFrame(
    alloc: std.mem.Allocator,
    payload: []const u8,
    enc: CompositorEncoding,
) ![]u8 {
    return compositorWire.encodeFrame(alloc, payload, enc);
}

pub fn decodeFrame(
    alloc: std.mem.Allocator,
    frame: []const u8,
) !compositorWire.DecodedFrame {
    return compositorWire.decodeFrame(alloc, frame);
}

/// Decide encoding automatically: use `.deflate` for payloads larger than 1 KiB
/// (typical for images / snapshots), `.raw` otherwise.
pub fn autoEncodingFor(payload_len: usize) CompositorEncoding {
    return if (payload_len > 1024) .deflate else .raw;
}

/// Request handler: answers one client request. `ctx` is the userdata
/// passed to `serve`/`servePath`. The returned `Message.data` must be heap
/// allocated (server frees it after sending). Return `error.NoReply` to
/// deliberately send nothing (for fire-and-forget `notify` requests).
pub const RequestHandler = *const fn (ctx: ?*anyopaque, msg: Message) anyerror!Message;

/// Event listener: receives server pushes and any reply that matches no
/// outstanding request (`Header.push_id` or unknown id). `msg.data` is
/// borrowed – valid only for the duration of the call; dupe it to retain.
pub const EventListener = *const fn (ctx: ?*anyopaque, msg: Message) void;

/// Backwards-compat alias for the request handler type.
pub const Callback = RequestHandler;

/// Per-connection server state, shared between the `handleClient` fiber
/// (reads + replies) and `Server.broadcast` (unsolicited pushes).
/// Writes are serialized through `write_mutex`.
const ServerClient = struct {
    stream: std.Io.net.Stream,
    write_mutex: std.Io.Mutex = .init,
    alive: std.atomic.Value(bool) = .init(true),
};

fn writeMessage(
    io: std.Io,
    stream: std.Io.net.Stream,
    alloc: std.mem.Allocator,
    kind: u8,
    encoding: Encoding,
    id: u32,
    payload: []const u8,
) !void {
    var bufw = std.ArrayList(u8).empty;
    defer bufw.deinit(alloc);
    const h = Header{
        .kind = kind,
        .encoding = encoding,
        .length = @as(u16, @intCast(payload.len)),
        .id = id,
    };
    try bufw.appendSlice(alloc, &h.toBytes());
    try bufw.appendSlice(alloc, payload);
    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(bufw.items);
    try writer.interface.flush();
}

fn registerClient(server: *Server, client: *ServerClient) !void {
    try server.clients_mutex.lock(server.io);
    defer server.clients_mutex.unlock(server.io);
    try server.clients.append(server.alloc, client);
}

fn unregisterClient(server: *Server, client: *ServerClient) void {
    server.clients_mutex.lock(server.io) catch return;
    defer server.clients_mutex.unlock(server.io);
    for (server.clients.items, 0..) |c, i| {
        if (c == client) {
            _ = server.clients.swapRemove(i);
            break;
        }
    }
}

fn handleClient(
    alloc: std.mem.Allocator,
    io: std.Io,
    server: *Server,
    connection: std.Io.net.Stream,
) void {
    const client = alloc.create(ServerClient) catch {
        connection.close(io);
        return;
    };
    client.* = .{ .stream = connection };
    registerClient(server, client) catch {
        alloc.destroy(client);
        connection.close(io);
        return;
    };
    defer {
        client.alive.store(false, .release);
        unregisterClient(server, client);
        connection.close(io);
        alloc.destroy(client);
    }

    var bufw = std.ArrayList(u8).empty;
    defer bufw.deinit(alloc);

    // Re-use reader with stack buffer for this connection.
    var read_buf: [4096]u8 = undefined;
    var reader = connection.reader(io, &read_buf);

    const handler = server.handler;
    const handler_ctx = server.handler_ctx;

    while (true) {
        io.checkCancel() catch return;
        bufw.clearRetainingCapacity();

        var hdr_buf: [Header.size]u8 = undefined;
        reader.interface.readSliceAll(&hdr_buf) catch |err| {
            log.debug("handleClient: header read failed: {}", .{err});
            return;
        };

        const reqh = Header.parse(hdr_buf) catch |err| {
            log.debug("handleClient: bad header: {}", .{err});
            return;
        };

        if (reqh.kind == 0x0) {
            return;
        }

        const wire_payload = alloc.alloc(u8, reqh.length) catch return;
        defer alloc.free(wire_payload);

        if (reqh.length > 0) {
            reader.interface.readSliceAll(wire_payload) catch |err| {
                log.debug("handleClient: payload read failed: {}", .{err});
                return;
            };
        }

        // Transport is agnostic – `Message.data` is the wire payload
        // (maybe deflate-compressed). `kind` is the sole discriminant for
        // payload shape; `encoding` tells how `data` is stored. No hidden
        // status inside `data`.
        const payload = alloc.dupe(u8, wire_payload) catch return;
        defer alloc.free(payload);

        const ev = handler(handler_ctx, .{
            .kind = reqh.kind,
            .encoding = reqh.encoding,
            .data = payload,
        }) catch |err| {
            // Fire-and-forget: handler asked for no reply.
            if (err == error.NoReply) continue;
            log.debug("handleClient: callback failed: {}", .{err});
            client.write_mutex.lock(io) catch return;
            defer client.write_mutex.unlock(io);
            const h = Header{ .kind = 0x0, .encoding = .raw, .length = 0, .id = reqh.id };
            var write_buf: [4096]u8 = undefined;
            var writer = connection.writer(io, &write_buf);
            writer.interface.writeAll(&h.toBytes()) catch {};
            writer.interface.flush() catch {};
            return;
        };

        std.debug.assert(ev.kind != 0x0);

        // Replies echo the request id so the client can match them even
        // when unsolicited pushes interleave on the same connection.
        client.write_mutex.lock(io) catch {
            if (ev.data.len > 0) alloc.free(@constCast(ev.data));
            return;
        };
        defer client.write_mutex.unlock(io);
        if (!client.alive.load(.acquire)) {
            if (ev.data.len > 0) alloc.free(@constCast(ev.data));
            return;
        }
        const resp_h = Header{
            .kind = ev.kind,
            .encoding = ev.encoding,
            .length = @as(u16, @intCast(ev.data.len)),
            .id = reqh.id,
        };
        bufw.appendSlice(alloc, &resp_h.toBytes()) catch {
            if (ev.data.len > 0) alloc.free(@constCast(ev.data));
            return;
        };
        bufw.appendSlice(alloc, ev.data) catch {
            if (ev.data.len > 0) alloc.free(@constCast(ev.data));
            return;
        };
        var write_buf: [4096]u8 = undefined;
        var writer = connection.writer(io, &write_buf);
        writer.interface.writeAll(bufw.items) catch {
            if (ev.data.len > 0) alloc.free(@constCast(ev.data));
            return;
        };
        writer.interface.flush() catch {
            if (ev.data.len > 0) alloc.free(@constCast(ev.data));
            return;
        };

        // Callback returned heap-allocated wire data; server owns it.
        if (ev.data.len > 0) alloc.free(@constCast(ev.data));
    }
}

pub const Server = struct {
    listener: std.Io.net.Server,
    group: std.Io.Group,
    io: std.Io,
    alloc: std.mem.Allocator,
    handler: RequestHandler,
    handler_ctx: ?*anyopaque,
    clients_mutex: std.Io.Mutex = .init,
    clients: std.ArrayList(*ServerClient),

    pub fn deinit(self: *Server) void {
        self.group.cancel(self.io);
        self.listener.deinit(self.io);
        self.clients.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn handleServing(
        self: *Server,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) void {
        while (true) {
            io.checkCancel() catch return;
            const connection = self.listener.accept(io) catch |err| {
                if (err == error.Canceled) return;
                log.debug("handleServing: accept failed: {}", .{err});
                continue;
            };
            self.group.async(io, handleClient, .{ alloc, io, self, connection });
        }
    }

    /// Send an unsolicited event to every connected client (no request
    /// needed). Uses `Header.push_id` so client readers route it to the
    /// event listener instead of an outstanding `request`.
    /// `msg.data` is borrowed; no ownership transfer.
    pub fn broadcast(self: *Server, msg: Message) !void {
        self.clients_mutex.lock(self.io) catch return error.Canceled;
        defer self.clients_mutex.unlock(self.io);
        for (self.clients.items) |client| {
            if (!client.alive.load(.acquire)) continue;
            client.write_mutex.lock(self.io) catch continue;
            defer client.write_mutex.unlock(self.io);
            if (!client.alive.load(.acquire)) continue;
            writeMessage(self.io, client.stream, self.alloc, msg.kind, msg.encoding, Header.push_id, msg.data) catch |err| {
                log.debug("broadcast: write failed: {}", .{err});
            };
        }
    }

    /// Typed helper: encode a compositor `Event` and broadcast it.
    pub fn broadcastCompositorEvent(
        self: *Server,
        ev: protocols.compositor.Event,
        enc: CompositorEncoding,
    ) !void {
        const msg = try encodeCompositorEvent(self.alloc, ev, enc);
        defer if (msg.data.len > 0) self.alloc.free(@constCast(msg.data));
        return self.broadcast(msg);
    }

    /// Like `broadcastCompositorEvent` with per-kind default encoding.
    pub fn broadcastCompositorEventDefault(
        self: *Server,
        ev: protocols.compositor.Event,
    ) !void {
        const enc = protocols.compositor.encodingForEvent(@as(protocols.compositor.EventTag, ev));
        return self.broadcastCompositorEvent(ev, enc);
    }

    pub fn clientCount(self: *Server) usize {
        self.clients_mutex.lock(self.io) catch return 0;
        defer self.clients_mutex.unlock(self.io);
        return self.clients.items.len;
    }
};

/// The use of 0x0 as the event kind is forbidden as it's used for the decode error message.
pub fn serve(
    alloc: std.mem.Allocator,
    io: std.Io,
    comptime id: []const u8,
    handler: RequestHandler,
    handler_ctx: ?*anyopaque,
) !*Server {
    const path = "/tmp/arcos/" ++ id ++ ".sock";
    std.Io.Dir.createDirAbsolute(io, "/tmp/arcos", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return servePath(alloc, io, path, handler, handler_ctx);
}

/// Typed compositor handler. Decodes `Message` into `Request`, invokes
/// `handler`, encodes the returned `Event` as `Message`.
/// Choose whether responses should be zipped per-event (e.g. deflate for images).
pub fn compositorCallback(
    alloc: std.mem.Allocator,
    msg: Message,
    handler: *const fn (std.mem.Allocator, protocols.compositor.Request) anyerror!protocols.compositor.Event,
    response_enc: CompositorEncoding,
) !Message {
    const req = try decodeCompositorRequest(alloc, msg);
    defer req.deinit(alloc);
    // msg.data is borrowed (freed by handleClient); don't free it here.
    var ev = try handler(alloc, req);
    defer ev.deinit(alloc);
    // handler-owned Event's heap is duplicated into frame; then ev freed above.
    const resp_msg = try encodeCompositorEvent(alloc, ev, response_enc);
    return resp_msg;
}

/// Like `serve` but with an explicit filesystem path. Useful for tests
/// which want to use a temporary directory (e.g. /tmp).
pub fn servePath(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    handler: RequestHandler,
    handler_ctx: ?*anyopaque,
) !*Server {
    const addr = try std.Io.net.UnixAddress.init(path);
    const listener = try addr.listen(io, .{});

    const server = try alloc.create(Server);
    server.* = .{
        .listener = listener,
        .alloc = alloc,
        .io = io,
        .group = .init,
        .handler = handler,
        .handler_ctx = handler_ctx,
        .clients = .empty,
    };

    server.group.async(io, Server.handleServing, .{ server, alloc, io });

    return server;
}

pub const Connection = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    conn: std.Io.net.Stream,
    /// Serializes all writes (requests, notifies, close frame).
    write_mutex: std.Io.Mutex = .init,
    /// Guards the pending-request slot below.
    state_mutex: std.Io.Mutex = .init,
    state_cond: std.Io.Condition = .init,
    waiting: bool = false,
    pending_id: u32 = 0,
    pending_msg: ?Message = null,
    pending_err: bool = false,
    next_id: u32 = 1,
    event_cb: ?EventListener = null,
    event_ctx: ?*anyopaque = null,
    read_group: std.Io.Group = .init,
    closed: std.atomic.Value(bool) = .init(false),

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        comptime id: []const u8,
        event_cb: ?EventListener,
        event_ctx: ?*anyopaque,
    ) !*Connection {
        return initPath(alloc, io, "/tmp/arcos/" ++ id ++ ".sock", event_cb, event_ctx);
    }

    pub fn initPath(
        alloc: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        event_cb: ?EventListener,
        event_ctx: ?*anyopaque,
    ) !*Connection {
        const addr = try std.Io.net.UnixAddress.init(path);
        const connection = try addr.connect(io);
        const self = try alloc.create(Connection);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .conn = connection,
            .event_cb = event_cb,
            .event_ctx = event_ctx,
        };
        self.read_group.async(io, readLoop, .{self});
        return self;
    }

    /// Background reader: the *only* reader on this connection. Replies
    /// matching the outstanding `request` id wake the waiter; everything
    /// else (pushes with `Header.push_id`, stale ids) goes to the event
    /// listener. Listener `msg.data` is borrowed for the call duration.
    fn readLoop(self: *Connection) void {
        var read_buf: [4096]u8 = undefined;
        var reader = self.conn.reader(self.io, &read_buf);
        while (!self.closed.load(.acquire)) {
            self.io.checkCancel() catch return;
            var hdr_buf: [Header.size]u8 = undefined;
            reader.interface.readSliceAll(&hdr_buf) catch {
                self.failPending();
                return;
            };
            const resh = Header.parse(hdr_buf) catch {
                self.failPending();
                return;
            };
            if (resh.kind == 0x0) {
                self.failPending();
                return;
            }
            const payload = self.alloc.alloc(u8, resh.length) catch {
                self.failPending();
                return;
            };
            if (resh.length > 0) {
                reader.interface.readSliceAll(payload) catch {
                    self.alloc.free(payload);
                    self.failPending();
                    return;
                };
            }

            const msg: Message = .{
                .kind = resh.kind,
                .encoding = resh.encoding,
                .data = payload,
            };

            // Try to match an outstanding request.
            self.state_mutex.lock(self.io) catch {
                self.alloc.free(payload);
                return;
            };
            const is_reply = self.waiting and resh.id != Header.push_id and resh.id == self.pending_id;
            if (is_reply) {
                self.pending_msg = msg; // transfer ownership to waiter
                self.waiting = false;
                self.state_mutex.unlock(self.io);
                self.state_cond.signal(self.io);
                continue;
            }
            const listener = self.event_cb;
            const listener_ctx = self.event_ctx;
            self.state_mutex.unlock(self.io);

            // Unsolicited push or reply to no specific request.
            if (listener) |cb| cb(listener_ctx, msg);
            self.alloc.free(payload);
        }
    }

    fn failPending(self: *Connection) void {
        self.state_mutex.lock(self.io) catch return;
        defer self.state_mutex.unlock(self.io);
        self.pending_err = true;
        self.waiting = false;
        self.state_cond.broadcast(self.io);
    }

    fn nextId(self: *Connection) u32 {
        // Skip the reserved push id (0).
        while (true) {
            const id = self.next_id;
            self.next_id +%= 1;
            if (self.next_id == Header.push_id) self.next_id +%= 1;
            if (id != Header.push_id) return id;
        }
    }

    fn writeRaw(self: *Connection, kind: u8, encoding: Encoding, id: u32, data: []const u8) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed.load(.acquire)) return error.Disconnected;
        var bufw = std.ArrayList(u8).empty;
        defer bufw.deinit(self.alloc);
        const h = Header{
            .kind = kind,
            .encoding = encoding,
            .length = @as(u16, @intCast(data.len)),
            .id = id,
        };
        try bufw.appendSlice(self.alloc, &h.toBytes());
        try bufw.appendSlice(self.alloc, data);
        var write_buf: [4096]u8 = undefined;
        var w = self.conn.writer(self.io, &write_buf);
        try w.interface.writeAll(bufw.items);
        try w.interface.flush();
    }

    /// The use of 0x0 message request kind is forbidden due to it's use in the
    /// close request.
    /// **SAFETY**: the returned Message.data is heap allocated and it's freeing
    /// is a responsibility of the owner.
    /// Accepts `Message` or any struct with `.kind: u8`, `.encoding: Encoding`, `.data: []const u8`
    /// to allow `compositor.Request.send` / `Event.send` duck-typing without cycle.
    /// Only one outstanding `request` at a time; concurrent callers get `error.Busy`.
    pub fn request(self: *Connection, msg: anytype) !Message {
        std.debug.assert(msg.kind != 0x0);
        const enc: Encoding = if (@hasField(@TypeOf(msg), "encoding")) msg.encoding else .raw;

        // Reserve the reply slot *before* writing so the reader can match it.
        // Ids (not arrival order) pair replies, so pushes racing a request
        // are still routed to the event listener.
        try self.state_mutex.lock(self.io);
        if (self.waiting) {
            self.state_mutex.unlock(self.io);
            return error.Busy;
        }
        if (self.closed.load(.acquire) or self.pending_err) {
            self.state_mutex.unlock(self.io);
            return error.Disconnected;
        }
        const id = self.nextId();
        self.waiting = true;
        self.pending_id = id;
        self.pending_msg = null;
        self.state_mutex.unlock(self.io);

        self.writeRaw(msg.kind, enc, id, msg.data) catch |err| {
            try self.state_mutex.lock(self.io);
            self.waiting = false;
            self.state_mutex.unlock(self.io);
            return err;
        };

        try self.state_mutex.lock(self.io);
        defer self.state_mutex.unlock(self.io);
        while (self.waiting and !self.pending_err) {
            try self.state_cond.wait(self.io, &self.state_mutex);
        }
        if (self.pending_err) return error.Disconnected;
        return self.pending_msg orelse error.Disconnected;
    }

    /// Fire-and-forget write: sends with a fresh id but doesn't wait for the
    /// reply. If the server replies anyway, the reply matches no waiter and
    /// lands in the event listener.
    pub fn notify(self: *Connection, msg: anytype) !void {
        std.debug.assert(msg.kind != 0x0);
        const enc: Encoding = if (@hasField(@TypeOf(msg), "encoding")) msg.encoding else .raw;
        const id = blk: {
            try self.state_mutex.lock(self.io);
            defer self.state_mutex.unlock(self.io);
            break :blk self.nextId();
        };
        try self.writeRaw(msg.kind, enc, id, msg.data);
    }

    /// Close the connection, stop the reader fiber and free `self`.
    /// Must not be called from within the event listener (reader fiber).
    pub fn close(self: *Connection) void {
        if (self.closed.swap(true, .acq_rel)) return;
        // Best-effort close frame so the server's handleClient exits.
        self.writeRaw(0x0, .raw, Header.push_id, &.{}) catch {};
        // Wake any waiter so `request` returns instead of hanging.
        self.failPending();
        self.conn.close(self.io);
        self.read_group.cancel(self.io);
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    /// Typed helper: send a compositor `Request` and decode the `Event` reply.
    /// `enc` controls whether the request body is zipped (use `.deflate` for
    /// bulk data like captures, `.raw` for small control messages).
    /// The returned `Event` owns heap memory – call `ev.deinit(alloc)` when done;
    /// the framing payload is freed internally.
    pub fn requestCompositor(
        self: *Connection,
        req: protocols.compositor.Request,
        enc: CompositorEncoding,
    ) !protocols.compositor.Event {
        const msg = try encodeCompositorRequest(self.alloc, req, enc);
        defer if (msg.data.len > 0) self.alloc.free(@constCast(msg.data));
        const resp = try self.request(msg);
        defer if (resp.data.len > 0) self.alloc.free(resp.data);
        return try decodeCompositorEvent(self.alloc, resp);
    }

    /// Like `requestCompositor` but allows caller to choose expected response
    /// decoding (when server may reply with different kinds). Returns raw `Message`.
    pub fn requestCompositorRaw(
        self: *Connection,
        req: protocols.compositor.Request,
        enc: CompositorEncoding,
    ) !Message {
        const msg = try encodeCompositorRequest(self.alloc, req, enc);
        defer if (msg.data.len > 0) self.alloc.free(@constCast(msg.data));
        return try self.request(msg);
    }
};

// ---------------------------------------------------------------------------
// Tests — run with `zig build test`
// ---------------------------------------------------------------------------

test "Header roundtrip" {
    const t = std.testing;
    var h = Header{ .kind = 0x42, .encoding = .deflate, .length = 0x1234, .id = 0xAABBCCDD };
    const bytes = h.toBytes();
    // kind, encoding, length high, low, id BE
    try t.expectEqual(@as(u8, 0x42), bytes[0]);
    try t.expectEqual(@as(u8, 1), bytes[1]);
    try t.expectEqual(@as(u8, 0x12), bytes[2]);
    try t.expectEqual(@as(u8, 0x34), bytes[3]);
    try t.expectEqual(@as(u8, 0xAA), bytes[4]);
    try t.expectEqual(@as(u8, 0xBB), bytes[5]);
    try t.expectEqual(@as(u8, 0xCC), bytes[6]);
    try t.expectEqual(@as(u8, 0xDD), bytes[7]);

    var decoded: Header = undefined;
    decoded.fromBytes(bytes);
    try t.expectEqual(h.kind, decoded.kind);
    try t.expectEqual(h.encoding, decoded.encoding);
    try t.expectEqual(h.length, decoded.length);
    try t.expectEqual(h.id, decoded.id);

    const decoded2 = Header.fromStatic(bytes);
    try t.expectEqual(h.kind, decoded2.kind);
    try t.expectEqual(h.encoding, decoded2.encoding);
    try t.expectEqual(h.length, decoded2.length);
    try t.expectEqual(h.id, decoded2.id);

    // raw encoding
    var h2 = Header{ .kind = 1, .encoding = .raw, .length = 10, .id = 7 };
    var dec2: Header = undefined;
    dec2.fromBytes(h2.toBytes());
    try t.expectEqual(Header{ .kind = 1, .encoding = .raw, .length = 10, .id = 7 }, dec2);
}

test "Header edge cases" {
    const t = std.testing;
    var h0 = Header{ .kind = 1, .encoding = .raw, .length = 0, .id = Header.push_id };
    var dec0: Header = undefined;
    dec0.fromBytes(h0.toBytes());
    try t.expectEqual(h0.kind, dec0.kind);
    try t.expectEqual(h0.encoding, dec0.encoding);
    try t.expectEqual(h0.length, dec0.length);
    try t.expectEqual(h0.id, dec0.id);

    var hmax = Header{ .kind = 255, .encoding = .deflate, .length = 0xFFFF, .id = 0xFFFFFFFF };
    var decmax: Header = undefined;
    decmax.fromBytes(hmax.toBytes());
    try t.expectEqual(hmax.kind, decmax.kind);
    try t.expectEqual(hmax.encoding, decmax.encoding);
    try t.expectEqual(hmax.length, decmax.length);
    try t.expectEqual(hmax.id, decmax.id);
}

// Simple echo/transform callback used by the integration test.
// We keep allocator in a global so the `fn(Message) Message` can allocate.
var test_alloc: std.mem.Allocator = undefined;

fn echoCallback(ctx: ?*anyopaque, msg: Message) anyerror!Message {
    _ = ctx;
    // Echo preserves encoding; kind determines data shape.
    switch (msg.kind) {
        1 => {
            const out = try test_alloc.dupe(u8, msg.data);
            return .{ .kind = 0x11, .encoding = msg.encoding, .data = out };
        },
        2 => {
            const out = try test_alloc.dupe(u8, msg.data);
            for (out) |*c| c.* = std.ascii.toUpper(c.*);
            return .{ .kind = 0x22, .encoding = msg.encoding, .data = out };
        },
        else => {
            const out = try test_alloc.dupe(u8, msg.data);
            const k: u8 = if (msg.kind + 100 == 0) 100 else msg.kind + 100;
            return .{ .kind = k, .encoding = msg.encoding, .data = out };
        },
    }
}

test "client-server: multiple commands are processed and echoed" {
    const t = std.testing;
    const io = t.io;
    const alloc = t.allocator;
    test_alloc = alloc;

    // Use a unique socket path in /tmp so test doesn't need /run/arcos.
    const path = "/tmp/nilebank-unit-test.sock";
    // Ensure stale file is removed.
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    // Start server.
    const server = try servePath(alloc, io, path, echoCallback, null);
    defer {
        server.deinit();
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    // Give the listener a moment to be ready (async spawn is immediate, but
    // ensure the accept fiber is scheduled).
    // In Threaded Io, async is truly concurrent, so a tiny yield helps.
    // We just try to connect with retry.
    var conn: *Connection = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (Connection.initPath(alloc, io, path, null, null)) |c| {
            conn = c;
            break;
        } else |_| {
            // Yield briefly; Threaded Io will schedule the server fiber.
            std.Thread.yield() catch {};
            if (i == 19) return error.ServerNotReady;
        }
    }
    defer conn.close();

    // Define a batch of requests.
    const Case = struct { kind: u8, payload: []const u8, expect_kind: u8, expect_payload: []const u8 };
    const cases = [_]Case{
        .{ .kind = 1, .payload = "hello", .expect_kind = 0x11, .expect_payload = "hello" },
        .{ .kind = 2, .payload = "world", .expect_kind = 0x22, .expect_payload = "WORLD" },
        .{ .kind = 1, .payload = "", .expect_kind = 0x11, .expect_payload = "" },
        .{ .kind = 3, .payload = "zig", .expect_kind = 103, .expect_payload = "zig" },
        .{ .kind = 2, .payload = "TeSt123", .expect_kind = 0x22, .expect_payload = "TEST123" },
    };

    for (cases) |c| {
        const resp = try conn.request(.{ .kind = c.kind, .data = c.payload });
        defer alloc.free(resp.data);
        try t.expectEqual(c.expect_kind, resp.kind);
        try t.expectEqualStrings(c.expect_payload, resp.data);
    }

    // Verify that a second client can also connect and get correct service.
    {
        var conn2 = try Connection.initPath(alloc, io, path, null, null);
        defer conn2.close();
        const resp = try conn2.request(.{ .kind = 1, .data = "second-client" });
        defer alloc.free(resp.data);
        try t.expectEqual(@as(u8, 0x11), resp.kind);
        try t.expectEqualStrings("second-client", resp.data);
    }
}

var compositor_test_alloc: std.mem.Allocator = undefined;

fn compositorTypedCallback(ctx: ?*anyopaque, msg: Message) anyerror!Message {
    _ = ctx;
    // Decode as Request, respond with Event. Choose encoding per response:
    // use deflate for any image/snapshot, raw otherwise.
    const req = try decodeCompositorRequest(compositor_test_alloc, msg);
    defer req.deinit(compositor_test_alloc);

    const resp_ev: protocols.compositor.Event = switch (req) {
        .ping => .{ .pong = .{ .nonce = 0xDEADBEEF } },
        .list_windows => blk: {
            const wins = try compositor_test_alloc.alloc(protocols.compositor.Window, 2);
            wins[0] = .{ .id = 1, .title = try compositor_test_alloc.dupe(u8, "alpha"), .app_id = try compositor_test_alloc.dupe(u8, "term") };
            wins[1] = .{ .id = 2, .title = try compositor_test_alloc.dupe(u8, "beta"), .app_id = try compositor_test_alloc.dupe(u8, "browser") };
            // Transfer ownership to Event; don't free wins here – Event.deinit will.
            break :blk .{ .windows = .{ .items = wins } };
        },
        .list_workspaces => blk: {
            const ws = try compositor_test_alloc.alloc(protocols.compositor.Workspace, 1);
            ws[0] = .{ .id = 10, .number = 1, .name = try compositor_test_alloc.dupe(u8, "main"), .active = true, .current = true, .output = 1 };
            break :blk .{ .workspaces = .{ .items = ws } };
        },
        .capture_window => |cap| blk: {
            const data = try compositor_test_alloc.alloc(u8, 256);
            for (data, 0..) |*b, i| b.* = @intCast((i * 7) % 256);
            const img: protocols.compositor.Image = .{ .width = 16, .height = 16, .stride = 64, .format = .rgba8, .data = data };
            break :blk .{ .window_image = .{ .window_id = cap.window_id, .image = img } };
        },
        else => .{ .error_msg = .{ .code = 1, .message = try compositor_test_alloc.dupe(u8, "unsupported") } },
    };

    // Heuristic: deflate for snapshots/images, raw for tiny pings.
    const enc: CompositorEncoding = switch (resp_ev) {
        .windows, .workspaces, .window_image, .full_image, .output_image, .windows_snapshot, .outputs_snapshot, .workspaces_snapshot => .deflate,
        else => .raw,
    };
    // Encode Event; its heap strings are copied into the frame, then we deinit resp_ev.
    var ev_copy = resp_ev;
    defer ev_copy.deinit(compositor_test_alloc);
    const out = try encodeCompositorEvent(compositor_test_alloc, ev_copy, enc);
    return out;
}

test "compositor typed: request/event via deflate and raw" {
    const t = std.testing;
    const io = t.io;
    const alloc = t.allocator;
    compositor_test_alloc = alloc;

    const path = "/tmp/nilebank-compositor-test.sock";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const server = try servePath(alloc, io, path, compositorTypedCallback, null);
    defer {
        server.deinit();
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    var conn: *Connection = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (Connection.initPath(alloc, io, path, null, null)) |c| {
            conn = c;
            break;
        } else |_| {
            std.Thread.yield() catch {};
            if (i == 19) return error.ServerNotReady;
        }
    }
    defer conn.close();

    // ping -> pong (raw)
    {
        const req: protocols.compositor.Request = .{ .ping = {} };
        const resp = try conn.requestCompositor(req, .raw);
        defer resp.deinit(alloc);
        switch (resp) {
            .pong => |v| try t.expectEqual(@as(u64, 0xDEADBEEF), v.nonce),
            else => return error.WrongResponse,
        }
    }

    // list_windows -> windows snapshot (deflate zipped on the fly)
    {
        const req: protocols.compositor.Request = .{ .list_windows = {} };
        const resp = try conn.requestCompositor(req, .raw);
        defer resp.deinit(alloc);
        switch (resp) {
            .windows => |v| {
                try t.expectEqual(@as(usize, 2), v.items.len);
                try t.expectEqualStrings("alpha", v.items[0].title);
                try t.expectEqualStrings("beta", v.items[1].title);
            },
            else => return error.WrongResponse,
        }
    }

    // capture_window -> window_image (deflate)
    {
        const req: protocols.compositor.Request = .{ .capture_window = .{ .window_id = 42, .scale = 1000 } };
        const resp = try conn.requestCompositor(req, .raw);
        defer resp.deinit(alloc);
        switch (resp) {
            .window_image => |v| {
                try t.expectEqual(@as(u64, 42), v.window_id);
                try t.expectEqual(@as(u32, 16), v.image.width);
                try t.expectEqual(@as(usize, 256), v.image.data.len);
            },
            else => return error.WrongResponse,
        }
    }

    // Verify raw Connection API still works for generic messages mixed with typed.
    {
        const raw_req = try encodeCompositorRequest(alloc, .{ .list_workspaces = {} }, .raw);
        defer alloc.free(raw_req.data);
        const raw_resp = try conn.request(raw_req);
        defer alloc.free(raw_resp.data);
        const ev = try decodeCompositorEvent(alloc, raw_resp);
        defer ev.deinit(alloc);
        try t.expect(ev == .workspaces or ev == .workspaces_snapshot or ev == .workspaces);
        switch (ev) {
            .workspaces => |v| try t.expectEqual(@as(usize, 1), v.items.len),
            else => return error.WrongResponse,
        }
    }
}

test "compositor Request/Event.send via Connection with SendOpts" {
    const t = std.testing;
    const io = t.io;
    const alloc = t.allocator;
    compositor_test_alloc = alloc;

    const path = "/tmp/nilebank-send-test.sock";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const server = try servePath(alloc, io, path, compositorTypedCallback, null);
    defer {
        server.deinit();
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    var conn: *Connection = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (Connection.initPath(alloc, io, path, null, null)) |c| {
            conn = c;
            break;
        } else |_| {
            std.Thread.yield() catch {};
            if (i == 19) return error.ServerNotReady;
        }
    }
    defer conn.close();

    // Request.send(self: *const Request, conn: *Connection, opts: SendOpts) -> Event
    {
        const req: protocols.compositor.Request = .{ .ping = {} };
        const resp = try req.send(conn, .{ .encoding = .raw });
        defer resp.deinit(alloc);
        try t.expect(resp == .pong);
        try t.expectEqual(@as(u64, 0xDEADBEEF), resp.pong.nonce);
    }

    // sendDefault uses per-kind default (raw for ping, deflate for snapshots)
    {
        const req: protocols.compositor.Request = .{ .list_windows = {} };
        const resp = try req.sendDefault(conn);
        defer resp.deinit(alloc);
        try t.expect(resp == .windows);
        try t.expectEqual(@as(usize, 2), resp.windows.items.len);
    }

    // Event encoding roundtrip via SendOpts (pong is server->client, test pack/unpack only)
    {
        const ev: protocols.compositor.Event = .{ .pong = .{ .nonce = 0x1234 } };
        const enc = try ev.encodeAlloc(alloc, .raw);
        defer alloc.free(enc);
        const decoded = try protocols.compositor.Event.decodeAllocWith(alloc, ev.kind(), enc, .raw);
        defer decoded.deinit(alloc);
        try t.expectEqual(@as(u64, 0x1234), decoded.pong.nonce);
    }

    // Direct SendOpts struct usage
    {
        const req: protocols.compositor.Request = .{ .get_window = .{ .id = 99 } };
        const opts: protocols.compositor.SendOpts = .{ .encoding = .raw };
        const resp = try req.send(conn, opts);
        defer resp.deinit(alloc);
        // get_window 99 is unsupported -> error_msg
        try t.expect(resp == .error_msg);
    }
}

const PushCtx = struct {
    alloc: std.mem.Allocator,
    server_hits: std.atomic.Value(usize) = .init(0),
    events: std.atomic.Value(usize) = .init(0),
    last_kind: std.atomic.Value(u8) = .init(0),
    last_enc: std.atomic.Value(u8) = .init(0),
    last_buf: [256]u8 = [_]u8{0} ** 256,
    last_len: std.atomic.Value(usize) = .init(0),
};

fn pushHandler(ctx: ?*anyopaque, msg: Message) anyerror!Message {
    const c: *PushCtx = @ptrCast(@alignCast(ctx.?));
    _ = c.server_hits.fetchAdd(1, .release);
    // kind 9 is fire-and-forget: acknowledge by sending nothing.
    if (msg.kind == 9) return error.NoReply;
    const out = try c.alloc.dupe(u8, msg.data);
    const k: u8 = if (msg.kind + 100 == 0) 100 else msg.kind + 100;
    return .{ .kind = k, .encoding = msg.encoding, .data = out };
}

fn pushListener(ctx: ?*anyopaque, msg: Message) void {
    const c: *PushCtx = @ptrCast(@alignCast(ctx.?));
    // Copy-then-publish: bytes first, counter last (release), so a test
    // observing `events` (acquire) sees consistent kind/data.
    const n = @min(msg.data.len, c.last_buf.len);
    @memcpy(c.last_buf[0..n], msg.data[0..n]);
    c.last_len.store(n, .release);
    c.last_kind.store(msg.kind, .release);
    c.last_enc.store(@intFromEnum(msg.encoding), .release);
    _ = c.events.fetchAdd(1, .release);
}

test "unsolicited server push lands in listener, requests still match by id" {
    const t = std.testing;
    const io = t.io;
    const alloc = t.allocator;

    var ctx = PushCtx{ .alloc = alloc };
    const ctx_ptr: ?*anyopaque = @ptrCast(&ctx);

    const path = "/tmp/nilebank-push-test.sock";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const server = try servePath(alloc, io, path, pushHandler, ctx_ptr);
    defer {
        server.deinit();
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    var conn: *Connection = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (Connection.initPath(alloc, io, path, pushListener, ctx_ptr)) |c| {
            conn = c;
            break;
        } else |_| {
            std.Thread.yield() catch {};
            if (i == 19) return error.ServerNotReady;
        }
    }
    defer conn.close();

    // Wait until the server registered this client, else broadcast races accept.
    {
        var waits: usize = 0;
        while (server.clientCount() == 0) : (waits += 1) {
            if (waits > 500) return error.ServerNotReady;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
    }

    // 1. Normal request/reply still works (ctx reaches the handler).
    {
        const resp = try conn.request(.{ .kind = 1, .data = "hi" });
        defer alloc.free(resp.data);
        try t.expectEqual(@as(u8, 101), resp.kind);
        try t.expectEqualStrings("hi", resp.data);
        try t.expectEqual(@as(usize, 1), ctx.server_hits.load(.acquire));
        try t.expectEqual(@as(usize, 0), ctx.events.load(.acquire));
    }

    // 2. Unsolicited raw push arrives without any request.
    {
        const base = ctx.events.load(.acquire);
        try server.broadcast(.{ .kind = 0x77, .encoding = .raw, .data = "hello-push" });
        var waits: usize = 0;
        while (ctx.events.load(.acquire) != base + 1) : (waits += 1) {
            if (waits > 500) return error.PushNotReceived;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        try t.expectEqual(@as(u8, 0x77), ctx.last_kind.load(.acquire));
        const n = ctx.last_len.load(.acquire);
        try t.expectEqualStrings("hello-push", ctx.last_buf[0..n]);
    }

    // 3. Typed compositor event push decodes with the transmitted encoding.
    {
        const base = ctx.events.load(.acquire);
        const ev: protocols.compositor.Event = .{ .pong = .{ .nonce = 0xCAFE } };
        try server.broadcastCompositorEventDefault(ev);
        var waits: usize = 0;
        while (ctx.events.load(.acquire) != base + 1) : (waits += 1) {
            if (waits > 500) return error.PushNotReceived;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        const kind = ctx.last_kind.load(.acquire);
        try t.expectEqual(ev.kind(), kind);
        const n = ctx.last_len.load(.acquire);
        const enc: CompositorEncoding = @enumFromInt(ctx.last_enc.load(.acquire));
        const decoded = try protocols.compositor.Event.decodeAllocWith(alloc, kind, ctx.last_buf[0..n], enc);
        defer decoded.deinit(alloc);
        try t.expectEqual(@as(u64, 0xCAFE), decoded.pong.nonce);
    }

    // 4. Fire-and-forget notify: handler runs (NoReply), listener gets nothing.
    {
        const hits = ctx.server_hits.load(.acquire);
        const base = ctx.events.load(.acquire);
        try conn.notify(.{ .kind = 9, .data = "fire" });
        var waits: usize = 0;
        while (ctx.server_hits.load(.acquire) != hits + 1) : (waits += 1) {
            if (waits > 500) return error.NotifyNotHandled;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        // Give a stray reply a chance to (incorrectly) show up.
        try io.sleep(.fromMilliseconds(200), .awake);
        try t.expectEqual(base, ctx.events.load(.acquire));
    }

    // 5. Requests still match by id after interleaved pushes.
    {
        const resp = try conn.request(.{ .kind = 2, .data = "after-push" });
        defer alloc.free(resp.data);
        try t.expectEqual(@as(u8, 102), resp.kind);
        try t.expectEqualStrings("after-push", resp.data);
    }
}
