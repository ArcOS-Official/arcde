//! Demo: runs a server and a client each in its own OS thread.
//! `zig build demo` then `./zig-out/bin/demo`.
//! Uses `std.Thread` for the two sides and `std.Io.Threaded` inside each.

const std = @import("std");
const nilebank = @import("nilebank");

const SOCK_PATH = "/tmp/nilebank-demo.sock";

var server_gpa_alloc: std.mem.Allocator = undefined;

fn serverCallback(ctx: ?*anyopaque, msg: nilebank.Message) anyerror!nilebank.Message {
    _ = ctx;
    const out = try server_gpa_alloc.dupe(u8, msg.data);
    switch (msg.kind) {
        1 => return .{ .kind = 0x11, .encoding = msg.encoding, .data = out },
        2 => {
            for (out) |*c| c.* = std.ascii.toUpper(c.*);
            return .{ .kind = 0x22, .encoding = msg.encoding, .data = out };
        },
        else => {
            const k: u8 = if (msg.kind + 100 == 0) 100 else msg.kind + 100;
            return .{ .kind = k, .encoding = msg.encoding, .data = out };
        },
    }
}

fn serverThreadFn() void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    server_gpa_alloc = alloc;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Clean stale socket.
    std.Io.Dir.deleteFileAbsolute(io, SOCK_PATH) catch {};

    const server = nilebank.servePath(alloc, io, SOCK_PATH, serverCallback, null) catch |err| {
        std.log.err("server failed to listen: {}", .{err});
        return;
    };
    defer {
        server.deinit();
        std.Io.Dir.deleteFileAbsolute(io, SOCK_PATH) catch {};
    }

    std.log.info("[server] listening on {s}", .{SOCK_PATH});
    // Run for a fixed window so the demo terminates on its own.
    // In a real program you would block indefinitely or wait on a signal.
    io.sleep(.fromSeconds(5), .awake) catch {};
    std.log.info("[server] shutting down", .{});
}

fn clientThreadFn() void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Give server a head-start.
    io.sleep(.fromMilliseconds(300), .awake) catch {};

    var conn: *nilebank.Connection = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        if (nilebank.Connection.initPath(alloc, io, SOCK_PATH, null, null)) |c| {
            conn = c;
            break;
        } else |_| {
            io.sleep(.fromMilliseconds(100), .awake) catch {};
            if (i == 19) {
                std.log.err("[client] could not connect", .{});
                return;
            }
        }
    }
    defer conn.close();
    std.log.info("[client] connected", .{});

    const cases = [_]struct { kind: u8, payload: []const u8 }{
        .{ .kind = 1, .payload = "hello" },
        .{ .kind = 2, .payload = "world" },
        .{ .kind = 1, .payload = "" },
        .{ .kind = 3, .payload = "zig" },
    };

    for (cases) |c| {
        const resp = conn.request(.{ .kind = c.kind, .data = c.payload }) catch |err| {
            std.log.err("[client] request failed: {}", .{err});
            return;
        };
        defer alloc.free(resp.data);
        std.log.info("[client] kind {d} -> 0x{x} \"{s}\"", .{ c.kind, resp.kind, resp.data });
        // small pause so logs interleave clearly
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    }

    // Typed API would use nilebank.protocols.compositor.Request/Event
    // against a typed server (see examples/server.zig with compositorCallback).
    // Raw echo server only speaks Message {kind, data}.

    std.log.info("[client] done", .{});
}

pub fn main() !void {
    // Launch server and client each on its own OS thread.
    const server_thread = try std.Thread.spawn(.{}, serverThreadFn, .{});
    const client_thread = try std.Thread.spawn(.{}, clientThreadFn, .{});

    client_thread.join();
    server_thread.join();
    std.log.info("demo finished", .{});
}
