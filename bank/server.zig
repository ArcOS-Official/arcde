const std = @import("std");
const nilebank = @import("bank");

var gpa_alloc: std.mem.Allocator = undefined;

/// Minimal callback: echo with kind+100, upper-case kind==2 (same as test helper).
fn callback(ctx: ?*anyopaque, msg: nilebank.Message) anyerror!nilebank.Message {
    _ = ctx;
    const out = try gpa_alloc.dupe(u8, msg.data);
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

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    gpa_alloc = alloc;

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/tmp/nilebank-example.sock";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    const server = try nilebank.servePath(alloc, io, path, callback, null);
    defer {
        server.deinit();
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    }

    std.log.info("server listening on {s} (Ctrl+C to stop)", .{path});

    // Block forever; fibers handle clients.
    while (true) {
        try io.sleep(.fromSeconds(60), .awake);
    }
}
