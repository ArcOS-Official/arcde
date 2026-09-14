const std = @import("std");
const nilebank = @import("bank");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/tmp/nilebank-example.sock";

    // Retry connect – server may still be starting.
    var conn: *nilebank.Connection = undefined;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        if (nilebank.Connection.initPath(alloc, io, path, null, null)) |c| {
            conn = c;
            break;
        } else |_| {
            try io.sleep(.fromMilliseconds(100), .awake);
            if (i == 29) {
                std.log.err("could not connect to {s}", .{path});
                return error.ServerNotReady;
            }
        }
    }
    defer conn.close();

    // --- raw Message API ---
    {
        const resp = try conn.request(.{ .kind = 1, .data = "hello" });
        defer alloc.free(resp.data);
        std.log.info("raw: kind=0x{x} payload=\"{s}\"", .{ resp.kind, resp.data });
    }
    {
        const resp = try conn.request(.{ .kind = 2, .data = "world" });
        defer alloc.free(resp.data);
        std.log.info("raw: kind=0x{x} payload=\"{s}\"", .{ resp.kind, resp.data });
    }

    // --- typed compositor API (ping/pong) ---
    {
        const req: nilebank.protocols.compositor.Request = .{ .ping = {} };
        const ev = try conn.requestCompositor(req, .raw);
        defer ev.deinit(alloc);
        switch (ev) {
            .pong => |p| std.log.info("typed: pong nonce=0x{x}", .{p.nonce}),
            else => std.log.info("typed: unexpected {s}", .{@tagName(ev)}),
        }
    }
}
