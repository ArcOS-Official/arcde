const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Compositor protocol – fully fledged for all kinds of compositor events
/// and client queries, with pluggable wire encoding (raw packed vs
/// deflate-compressed on the fly). The outer transport is the `root.zig`
/// `Message { kind: u8, data: []const u8 }` framed by `Header`. The `data`
/// payload is a `wire.Frame`: `[1 byte Encoding][payload or deflate(payload)]`.
/// Callers choose per-message whether to zip (images, snapshots) or just pack.
pub const compositor = struct {
    // -----------------------------------------------------------------------
    // Shared primitive types
    // -----------------------------------------------------------------------

    pub const Encoding = enum(u8) {
        raw = 0,
        deflate = 1,

        pub fn toByte(self: Encoding) u8 {
            return @intFromEnum(self);
        }
        pub fn fromByte(b: u8) !Encoding {
            return switch (b) {
                0 => .raw,
                1 => .deflate,
                else => error.UnsupportedEncoding,
            };
        }
    };

    pub const PixelFormat = enum(u8) {
        rgba8 = 0,
        bgra8 = 1,
        rgbx8 = 2,
        bgrx8 = 3,
        r8 = 4,
        rgb8 = 5,
    };

    pub const Rect = struct {
        x: i32 = 0,
        y: i32 = 0,
        width: u32 = 0,
        height: u32 = 0,

        pub fn encodeAlloc(self: Rect, alloc: Allocator, list: *std.ArrayList(u8)) !void {
            try wire.writeI32BE(list, alloc, self.x);
            try wire.writeI32BE(list, alloc, self.y);
            try wire.writeU32BE(list, alloc, self.width);
            try wire.writeU32BE(list, alloc, self.height);
        }
        pub fn decodeAlloc(reader: *wire.Reader) !Rect {
            return .{
                .x = try reader.readI32BE(),
                .y = try reader.readI32BE(),
                .width = try reader.readU32BE(),
                .height = try reader.readU32BE(),
            };
        }
    };

    pub const Mode = struct {
        width: u32 = 0,
        height: u32 = 0,
        refresh: u32 = 0, // mHz

        pub fn encodeAlloc(self: Mode, alloc: Allocator, list: *std.ArrayList(u8)) !void {
            try wire.writeU32BE(list, alloc, self.width);
            try wire.writeU32BE(list, alloc, self.height);
            try wire.writeU32BE(list, alloc, self.refresh);
        }
        pub fn decodeAlloc(reader: *wire.Reader) !Mode {
            return .{
                .width = try reader.readU32BE(),
                .height = try reader.readU32BE(),
                .refresh = try reader.readU32BE(),
            };
        }
    };

    /// Window – expanded with defaults so legacy `{ .title, .id }` literals
    /// continue to compile.
    pub const Window = struct {
        id: u64,
        title: []const u8 = "",
        app_id: []const u8 = "",
        workspace: u64 = 0,
        output: u64 = 0,
        pid: u32 = 0,
        rect: Rect = .{},
        floating: bool = false,
        fullscreen: bool = false,
        focused: bool = false,
        urgent: bool = false,

        pub fn deinit(self: Window, alloc: Allocator) void {
            if (self.title.len > 0) alloc.free(self.title);
            if (self.app_id.len > 0) alloc.free(self.app_id);
        }

        pub fn encodeAlloc(self: Window, alloc: Allocator, list: *std.ArrayList(u8)) !void {
            try wire.writeU64BE(list, alloc, self.id);
            try wire.writeString(list, alloc, self.title);
            try wire.writeString(list, alloc, self.app_id);
            try wire.writeU64BE(list, alloc, self.workspace);
            try wire.writeU64BE(list, alloc, self.output);
            try wire.writeU32BE(list, alloc, self.pid);
            try self.rect.encodeAlloc(alloc, list);
            try wire.writeBool(list, alloc, self.floating);
            try wire.writeBool(list, alloc, self.fullscreen);
            try wire.writeBool(list, alloc, self.focused);
            try wire.writeBool(list, alloc, self.urgent);
        }

        pub fn decodeAlloc(reader: *wire.Reader, alloc: Allocator) !Window {
            const id = try reader.readU64BE();
            const title = try reader.readString(alloc);
            errdefer if (title.len > 0) alloc.free(title);
            const app_id = try reader.readString(alloc);
            errdefer if (app_id.len > 0) alloc.free(app_id);
            const workspace = try reader.readU64BE();
            const output = try reader.readU64BE();
            const pid = try reader.readU32BE();
            const rect = try Rect.decodeAlloc(reader);
            const floating = try reader.readBool();
            const fullscreen = try reader.readBool();
            const focused = try reader.readBool();
            const urgent = try reader.readBool();
            return .{
                .id = id,
                .title = title,
                .app_id = app_id,
                .workspace = workspace,
                .output = output,
                .pid = pid,
                .rect = rect,
                .floating = floating,
                .fullscreen = fullscreen,
                .focused = focused,
                .urgent = urgent,
            };
        }

        pub fn eql(a: Window, b: Window) bool {
            return a.id == b.id and std.mem.eql(u8, a.title, b.title) and std.mem.eql(u8, a.app_id, b.app_id) and a.workspace == b.workspace and a.output == b.output and a.pid == b.pid and a.rect.x == b.rect.x and a.rect.y == b.rect.y and a.rect.width == b.rect.width and a.rect.height == b.rect.height and a.floating == b.floating and a.fullscreen == b.fullscreen and a.focused == b.focused and a.urgent == b.urgent;
        }
    };

    pub const WorkspaceMode = enum(u8) {
        tiling = 0,
        floating = 1,
    };

    pub const Workspace = struct {
        id: u64 = 0,
        number: u8 = 0,
        name: []const u8 = "",
        active: bool = false,
        // legacy field `current` maps to `active` for compat; keep both.
        current: bool = false,
        urgent: bool = false,
        output: u64 = 0,
        mode: WorkspaceMode = .tiling,

        pub fn deinit(self: Workspace, alloc: Allocator) void {
            if (self.name.len > 0) alloc.free(self.name);
        }

        pub fn encodeAlloc(self: Workspace, alloc: Allocator, list: *std.ArrayList(u8)) !void {
            try wire.writeU64BE(list, alloc, self.id);
            try wire.writeU8(list, alloc, self.number);
            try wire.writeString(list, alloc, self.name);
            try wire.writeBool(list, alloc, self.active);
            try wire.writeBool(list, alloc, self.current);
            try wire.writeBool(list, alloc, self.urgent);
            try wire.writeU64BE(list, alloc, self.output);
            try wire.writeU8(list, alloc, @intFromEnum(self.mode));
        }

        pub fn decodeAlloc(reader: *wire.Reader, alloc: Allocator) !Workspace {
            const id = try reader.readU64BE();
            const number = try reader.readU8();
            const name = try reader.readString(alloc);
            errdefer if (name.len > 0) alloc.free(name);
            const active = try reader.readBool();
            const current = try reader.readBool();
            const urgent = try reader.readBool();
            const output = try reader.readU64BE();
            // New field `mode` may be missing from old peers — default to tiling
            const mode: WorkspaceMode = if (reader.eof()) .tiling else blk: {
                const b = reader.readU8() catch break :blk WorkspaceMode.tiling;
                break :blk std.enums.fromInt(WorkspaceMode, b) orelse .tiling;
            };
            return .{ .id = id, .number = number, .name = name, .active = active, .current = current, .urgent = urgent, .output = output, .mode = mode };
        }
    };

    pub const Output = struct {
        id: u64,
        name: []const u8 = "",
        make: []const u8 = "",
        model: []const u8 = "",
        x: i32 = 0,
        y: i32 = 0,
        mode: Mode = .{},
        scale: u32 = 1000, // 1000 = 1.0
        enabled: bool = true,

        pub fn deinit(self: Output, alloc: Allocator) void {
            if (self.name.len > 0) alloc.free(self.name);
            if (self.make.len > 0) alloc.free(self.make);
            if (self.model.len > 0) alloc.free(self.model);
        }

        pub fn encodeAlloc(self: Output, alloc: Allocator, list: *std.ArrayList(u8)) !void {
            try wire.writeU64BE(list, alloc, self.id);
            try wire.writeString(list, alloc, self.name);
            try wire.writeString(list, alloc, self.make);
            try wire.writeString(list, alloc, self.model);
            try wire.writeI32BE(list, alloc, self.x);
            try wire.writeI32BE(list, alloc, self.y);
            try self.mode.encodeAlloc(alloc, list);
            try wire.writeU32BE(list, alloc, self.scale);
            try wire.writeBool(list, alloc, self.enabled);
        }

        pub fn decodeAlloc(reader: *wire.Reader, alloc: Allocator) !Output {
            const id = try reader.readU64BE();
            const name = try reader.readString(alloc);
            errdefer if (name.len > 0) alloc.free(name);
            const make = try reader.readString(alloc);
            errdefer if (make.len > 0) alloc.free(make);
            const model = try reader.readString(alloc);
            errdefer if (model.len > 0) alloc.free(model);
            const x = try reader.readI32BE();
            const y = try reader.readI32BE();
            const mode = try Mode.decodeAlloc(reader);
            const scale = try reader.readU32BE();
            const enabled = try reader.readBool();
            return .{ .id = id, .name = name, .make = make, .model = model, .x = x, .y = y, .mode = mode, .scale = scale, .enabled = enabled };
        }
    };

    pub const Image = struct {
        width: u32 = 0,
        height: u32 = 0,
        stride: u32 = 0,
        format: PixelFormat = .rgba8,
        data: []const u8 = "",

        pub fn deinit(self: Image, alloc: Allocator) void {
            if (self.data.len > 0) alloc.free(self.data);
        }

        pub fn encodeAlloc(self: Image, alloc: Allocator, list: *std.ArrayList(u8)) !void {
            try wire.writeU32BE(list, alloc, self.width);
            try wire.writeU32BE(list, alloc, self.height);
            try wire.writeU32BE(list, alloc, self.stride);
            try wire.writeU8(list, alloc, @intFromEnum(self.format));
            try wire.writeBytes(list, alloc, self.data);
        }

        pub fn decodeAlloc(reader: *wire.Reader, alloc: Allocator) !Image {
            const width = try reader.readU32BE();
            const height = try reader.readU32BE();
            const stride = try reader.readU32BE();
            const fmt_byte = try reader.readU8();
            const format = std.enums.fromInt(PixelFormat, fmt_byte) orelse return error.InvalidData;
            const data = try reader.readBytes(alloc);
            errdefer if (data.len > 0) alloc.free(data);
            return .{ .width = width, .height = height, .stride = stride, .format = format, .data = data };
        }
    };

    // -----------------------------------------------------------------------
    // Wire – packing helpers + framing (raw vs deflate)
    // -----------------------------------------------------------------------
    pub const wire = struct {
        const flate = std.compress.flate;

        pub const DecodedFrame = struct {
            encoding: Encoding,
            data: []u8, // owned; caller must free

            pub fn deinit(self: DecodedFrame, alloc: Allocator) void {
                if (self.data.len > 0) alloc.free(self.data);
            }
        };

        // ---- primitive packing ------------------------------------------------

        pub fn writeU8(list: *std.ArrayList(u8), alloc: Allocator, v: u8) !void {
            try list.append(alloc, v);
        }
        pub fn writeBool(list: *std.ArrayList(u8), alloc: Allocator, v: bool) !void {
            try list.append(alloc, @intFromBool(v));
        }
        pub fn writeU16BE(list: *std.ArrayList(u8), alloc: Allocator, v: u16) !void {
            var buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &buf, v, .big);
            try list.appendSlice(alloc, &buf);
        }
        pub fn writeU32BE(list: *std.ArrayList(u8), alloc: Allocator, v: u32) !void {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, v, .big);
            try list.appendSlice(alloc, &buf);
        }
        pub fn writeU64BE(list: *std.ArrayList(u8), alloc: Allocator, v: u64) !void {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, v, .big);
            try list.appendSlice(alloc, &buf);
        }
        pub fn writeI32BE(list: *std.ArrayList(u8), alloc: Allocator, v: i32) !void {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(i32, &buf, v, .big);
            try list.appendSlice(alloc, &buf);
        }

        /// length-prefixed string: u32 BE len + bytes (no sentinel)
        pub fn writeString(list: *std.ArrayList(u8), alloc: Allocator, s: []const u8) !void {
            try writeU32BE(list, alloc, @intCast(s.len));
            if (s.len > 0) try list.appendSlice(alloc, s);
        }
        /// length-prefixed bytes: u32 BE len + bytes
        pub fn writeBytes(list: *std.ArrayList(u8), alloc: Allocator, b: []const u8) !void {
            try writeU32BE(list, alloc, @intCast(b.len));
            if (b.len > 0) try list.appendSlice(alloc, b);
        }
        /// slice with u32 count prefix (for arrays)
        pub fn writeSliceHeader(list: *std.ArrayList(u8), alloc: Allocator, count: u32) !void {
            try writeU32BE(list, alloc, count);
        }

        pub const Reader = struct {
            data: []const u8,
            pos: usize = 0,

            pub fn init(d: []const u8) Reader {
                return .{ .data = d, .pos = 0 };
            }
            pub fn eof(self: Reader) bool {
                return self.pos >= self.data.len;
            }
            pub fn remaining(self: Reader) usize {
                return self.data.len - self.pos;
            }
            fn ensure(self: Reader, n: usize) !void {
                if (self.pos + n > self.data.len) return error.InvalidData;
            }
            pub fn readU8(self: *Reader) !u8 {
                try self.ensure(1);
                const v = self.data[self.pos];
                self.pos += 1;
                return v;
            }
            pub fn readBool(self: *Reader) !bool {
                const b = try self.readU8();
                return switch (b) {
                    0 => false,
                    1 => true,
                    else => error.InvalidData,
                };
            }
            pub fn readU16BE(self: *Reader) !u16 {
                try self.ensure(2);
                const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
                self.pos += 2;
                return v;
            }
            pub fn readU32BE(self: *Reader) !u32 {
                try self.ensure(4);
                const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
                self.pos += 4;
                return v;
            }
            pub fn readU64BE(self: *Reader) !u64 {
                try self.ensure(8);
                const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .big);
                self.pos += 8;
                return v;
            }
            pub fn readI32BE(self: *Reader) !i32 {
                try self.ensure(4);
                const v = std.mem.readInt(i32, self.data[self.pos..][0..4], .big);
                self.pos += 4;
                return v;
            }
            pub fn readString(self: *Reader, alloc: Allocator) ![]u8 {
                const len = try self.readU32BE();
                if (len == 0) {
                    // Return a non-owned empty slice; deinit guards free only if len>0.
                    // Allocate an empty slice via dupe to keep semantics, but we can return "".
                    // To keep deinit safe, return alloc.dupe for len==0 is not needed.
                    // Return a slice that won't be freed (empty). Caller checks len>0 before free.
                    return @constCast(@as([]const u8, ""));
                }
                try self.ensure(len);
                const slice = self.data[self.pos .. self.pos + len];
                self.pos += len;
                const out = try alloc.dupe(u8, slice);
                return out;
            }
            pub fn readBytes(self: *Reader, alloc: Allocator) ![]u8 {
                const len = try self.readU32BE();
                if (len == 0) return @constCast(@as([]const u8, ""));
                try self.ensure(len);
                const slice = self.data[self.pos .. self.pos + len];
                self.pos += len;
                return try alloc.dupe(u8, slice);
            }
            pub fn readSliceHeader(self: *Reader) !u32 {
                return try self.readU32BE();
            }
        };

        // ---- compression helpers ----------------------------------------------

        pub fn compressAlloc(alloc: Allocator, data: []const u8) ![]u8 {
            // Use flate.Compress raw deflate. Allocating writer grows as needed.
            var out: Io.Writer.Allocating = try .initCapacity(alloc, @max(@as(usize, 128), data.len / 4 + 64));
            errdefer out.deinit();
            var deflate_buf: [flate.max_window_len]u8 = undefined;
            var c = try flate.Compress.init(&out.writer, &deflate_buf, .raw, .default);
            try c.writer.writeAll(data);
            try c.finish();
            return out.toOwnedSlice();
        }

        pub fn decompressAlloc(alloc: Allocator, compressed: []const u8) ![]u8 {
            var in_reader: Io.Reader = .fixed(compressed);
            var buf: [flate.max_window_len]u8 = undefined;
            var d: flate.Decompress = .init(&in_reader, .raw, &buf);
            var out: Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            while (true) {
                const chunk = d.reader.peekGreedy(1) catch |e| switch (e) {
                    error.ReadFailed => {
                        if (d.err) |err| return err;
                        return error.ReadFailed;
                    },
                    error.EndOfStream => break,
                };
                if (chunk.len == 0) break;
                try out.writer.writeAll(chunk);
                d.reader.toss(chunk.len);
            }
            return out.toOwnedSlice();
        }

        /// Frame: [1 byte Encoding][payload]. If encoding==deflate, payload is
        /// raw-deflate compressed pack. If raw, payload is copied verbatim.
        /// This is the low-level framing used when callers want per-message
        /// zip choice independent of `kind`. Typed `Request`/`Event` below
        /// prefer kind-driven encoding (no prefix) and use `compressAlloc`
        /// directly; this helper remains for generic use.
        pub fn encodeFrame(alloc: Allocator, payload: []const u8, enc: Encoding) ![]u8 {
            switch (enc) {
                .raw => {
                    var out = try alloc.alloc(u8, 1 + payload.len);
                    out[0] = enc.toByte();
                    if (payload.len > 0) @memcpy(out[1..], payload);
                    return out;
                },
                .deflate => {
                    const comp = try compressAlloc(alloc, payload);
                    defer if (comp.len > 0) alloc.free(comp);
                    var out = try alloc.alloc(u8, 1 + comp.len);
                    out[0] = enc.toByte();
                    if (comp.len > 0) @memcpy(out[1..], comp);
                    return out;
                },
            }
        }

        pub fn decodeFrame(alloc: Allocator, frame: []const u8) !DecodedFrame {
            if (frame.len == 0) return error.InvalidData;
            const enc = try Encoding.fromByte(frame[0]);
            const inner = frame[1..];
            switch (enc) {
                .raw => {
                    const data = try alloc.dupe(u8, inner);
                    return .{ .encoding = .raw, .data = data };
                },
                .deflate => {
                    const data = try decompressAlloc(alloc, inner);
                    return .{ .encoding = .deflate, .data = data };
                },
            }
        }

        // ---- convenience helpers for lists ------------------------------------

        pub fn encodeWindowList(alloc: Allocator, windows: []const Window, list: *std.ArrayList(u8)) !void {
            try writeSliceHeader(list, alloc, @intCast(windows.len));
            for (windows) |w| try w.encodeAlloc(alloc, list);
        }
        pub fn decodeWindowList(reader: *Reader, alloc: Allocator) ![]Window {
            const count = try reader.readSliceHeader();
            var arr = try alloc.alloc(Window, count);
            errdefer alloc.free(arr);
            for (0..count) |i| {
                arr[i] = try Window.decodeAlloc(reader, alloc);
            }
            return arr;
        }
        pub fn encodeWorkspaceList(alloc: Allocator, ws: []const Workspace, list: *std.ArrayList(u8)) !void {
            try writeSliceHeader(list, alloc, @intCast(ws.len));
            for (ws) |w| try w.encodeAlloc(alloc, list);
        }
        pub fn decodeWorkspaceList(reader: *Reader, alloc: Allocator) ![]Workspace {
            const count = try reader.readSliceHeader();
            var arr = try alloc.alloc(Workspace, count);
            errdefer alloc.free(arr);
            for (0..count) |i| arr[i] = try Workspace.decodeAlloc(reader, alloc);
            return arr;
        }
        pub fn encodeOutputList(alloc: Allocator, outs: []const Output, list: *std.ArrayList(u8)) !void {
            try writeSliceHeader(list, alloc, @intCast(outs.len));
            for (outs) |o| try o.encodeAlloc(alloc, list);
        }
        pub fn decodeOutputList(reader: *Reader, alloc: Allocator) ![]Output {
            const count = try reader.readSliceHeader();
            var arr = try alloc.alloc(Output, count);
            errdefer alloc.free(arr);
            for (0..count) |i| arr[i] = try Output.decodeAlloc(reader, alloc);
            return arr;
        }
    };

    /// Per-kind encoding defaults – `kind` is the source of truth for data shape.
    /// Heavy payloads (snapshots, images) default to deflate, small control
    /// messages to raw. This avoids the HTTP-200/JSON-404 mismatch where
    /// `Message.kind` says success but `data` hides an error.
    pub fn encodingForRequest(tag: RequestTag) Encoding {
        _ = tag;
        return .raw;
    }
    pub fn encodingForEvent(tag: EventTag) Encoding {
        return switch (tag) {
            .windows, .windows_snapshot, .outputs, .outputs_snapshot, .workspaces, .workspaces_snapshot, .full_image, .window_image, .output_image => .deflate,
            else => .raw,
        };
    }

    /// Options for `Request.send` / `Event.send` – second struct after `self` pointer.
    pub const SendOpts = struct {
        encoding: Encoding = .raw,
        // Reserved for future: timeout, priority, etc.
        // If encoding is .raw but per-kind default is .deflate, caller's choice wins.
    };

    // -----------------------------------------------------------------------
    // Legacy type aliases kept for compatibility with original file
    // -----------------------------------------------------------------------
    // Old Event.NewWindow maps to WindowOpened payload.
    // Old Workspaces [9] alias kept.
    pub const Legacy = struct {
        pub const NewWindow = struct {
            title: []const u8,
            id: u64,
        };
        pub const Workspaces = [9]Workspace;
    };

    // -----------------------------------------------------------------------
    // Request – client → compositor queries / commands
    // Overlaps numerically with Event on purpose (direction distinguishes).
    // -----------------------------------------------------------------------
    pub const RequestTag = enum(u8) {
        /// legacy: full_image (no payload)
        full_image = 0x1,
        /// legacy: window_image (no payload in original, now with optional id)
        window_image = 0x2,
        // extended
        ping = 0x3,
        pong = 0x4,
        list_windows = 0x10,
        list_workspaces = 0x11,
        list_outputs = 0x12,
        get_window = 0x13,
        get_output = 0x14,
        get_workspace = 0x15,
        subscribe = 0x1E,
        unsubscribe = 0x1F,
        capture_full = 0x20,
        capture_output = 0x21,
        capture_window = 0x22,
        focus_window = 0x40,
        close_window = 0x41,
        move_window = 0x42,
        resize_window = 0x43,
        switch_workspace = 0x44,
        set_workspace_name = 0x45,
        shell_register = 0x46,
        set_window_floating = 0x47,
        set_workspace_mode = 0x48,
        set_focus_config = 0x49,
        request_keyboard_focus = 0x4A,
        release_keyboard_focus = 0x4B,
        set_window_fullscreen = 0x4C,
    };

    pub const Request = union(RequestTag) {
        full_image: void,
        window_image: WindowImageReq,
        ping: void,
        pong: void,
        list_windows: void,
        list_workspaces: void,
        list_outputs: void,
        get_window: GetWindow,
        get_output: GetOutput,
        get_workspace: GetWorkspace,
        subscribe: Subscribe,
        unsubscribe: Subscribe,
        capture_full: CaptureFull,
        capture_output: CaptureOutput,
        capture_window: CaptureWindow,
        focus_window: FocusWindow,
        close_window: CloseWindow,
        move_window: MoveWindow,
        resize_window: ResizeWindow,
        switch_workspace: SwitchWorkspace,
        set_workspace_name: SetWorkspaceName,
        shell_register: ShellRegister,
        set_window_floating: SetWindowFloating,
        set_workspace_mode: SetWorkspaceMode,
        set_focus_config: SetFocusConfig,
        request_keyboard_focus: RequestKeyboardFocus,
        release_keyboard_focus: void,
        set_window_fullscreen: SetWindowFullscreen,

        // payload structs
        pub const WindowImageReq = struct {
            window_id: u64 = 0, // 0 = legacy no-id
        };
        pub const GetWindow = struct { id: u64 };
        pub const GetOutput = struct { id: u64 };
        pub const GetWorkspace = struct { id: u64 };
        pub const Subscribe = struct { mask: u64 = 0 }; // 0 = all events; otherwise bitmask
        pub const CaptureFull = struct {
            output_id: u64 = 0, // 0 = all outputs / primary
            scale: u32 = 1000, // 1000 = 1.0 native
        };
        pub const CaptureOutput = struct {
            output_id: u64,
            scale: u32 = 1000,
        };
        pub const CaptureWindow = struct {
            window_id: u64,
            scale: u32 = 1000,
        };
        pub const FocusWindow = struct { id: u64 };
        pub const CloseWindow = struct { id: u64 };
        pub const MoveWindow = struct { id: u64, x: i32, y: i32 };
        pub const ResizeWindow = struct { id: u64, width: u32, height: u32 };
        pub const SwitchWorkspace = struct { id: u64 };
        pub const SetWorkspaceName = struct { id: u64, name: []const u8 };
        pub const ShellRegister = struct { namespace: []const u8 };
        pub const SetWindowFloating = struct { id: u64, floating: bool };
        pub const SetWorkspaceMode = struct { id: u64, mode: WorkspaceMode };
        pub const SetFocusConfig = struct { switch_workspace_on_focus: bool };
        pub const RequestKeyboardFocus = struct { namespace: []const u8 };
        pub const SetWindowFullscreen = struct { id: u64, fullscreen: bool };

        pub fn deinit(self: Request, alloc: Allocator) void {
            switch (self) {
                .set_workspace_name => |v| if (v.name.len > 0) alloc.free(v.name),
                .shell_register => |v| if (v.namespace.len > 0) alloc.free(v.namespace),
                .request_keyboard_focus => |v| if (v.namespace.len > 0) alloc.free(v.namespace),
                else => {},
            }
        }

        fn encodeBodyAlloc(self: Request, alloc: Allocator) ![]u8 {
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(alloc);
            switch (self) {
                .full_image, .ping, .pong, .list_windows, .list_workspaces, .list_outputs => {},
                .window_image => |v| try wire.writeU64BE(&list, alloc, v.window_id),
                .get_window => |v| try wire.writeU64BE(&list, alloc, v.id),
                .get_output => |v| try wire.writeU64BE(&list, alloc, v.id),
                .get_workspace => |v| try wire.writeU64BE(&list, alloc, v.id),
                .subscribe => |v| try wire.writeU64BE(&list, alloc, v.mask),
                .unsubscribe => |v| try wire.writeU64BE(&list, alloc, v.mask),
                .capture_full => |v| {
                    try wire.writeU64BE(&list, alloc, v.output_id);
                    try wire.writeU32BE(&list, alloc, v.scale);
                },
                .capture_output => |v| {
                    try wire.writeU64BE(&list, alloc, v.output_id);
                    try wire.writeU32BE(&list, alloc, v.scale);
                },
                .capture_window => |v| {
                    try wire.writeU64BE(&list, alloc, v.window_id);
                    try wire.writeU32BE(&list, alloc, v.scale);
                },
                .focus_window => |v| try wire.writeU64BE(&list, alloc, v.id),
                .close_window => |v| try wire.writeU64BE(&list, alloc, v.id),
                .move_window => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeI32BE(&list, alloc, v.x);
                    try wire.writeI32BE(&list, alloc, v.y);
                },
                .resize_window => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeU32BE(&list, alloc, v.width);
                    try wire.writeU32BE(&list, alloc, v.height);
                },
                .switch_workspace => |v| try wire.writeU64BE(&list, alloc, v.id),
                .set_workspace_name => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeString(&list, alloc, v.name);
                },
                .shell_register => |v| {
                    try wire.writeString(&list, alloc, v.namespace);
                },
                .set_window_floating => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeBool(&list, alloc, v.floating);
                },
                .set_workspace_mode => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeU8(&list, alloc, @intFromEnum(v.mode));
                },
                .set_focus_config => |v| {
                    try wire.writeBool(&list, alloc, v.switch_workspace_on_focus);
                },
                .request_keyboard_focus => |v| {
                    try wire.writeString(&list, alloc, v.namespace);
                },
                .release_keyboard_focus => {},
                .set_window_fullscreen => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeBool(&list, alloc, v.fullscreen);
                },
            }
            return list.toOwnedSlice(alloc);
        }

        fn decodeBodyAlloc(tag: RequestTag, data: []const u8, alloc: Allocator) !Request {
            var r = wire.Reader.init(data);
            switch (tag) {
                .full_image => {
                    if (!r.eof()) return error.InvalidData;
                    return .{ .full_image = {} };
                },
                .window_image => {
                    if (r.eof()) return .{ .window_image = .{ .window_id = 0 } };
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .window_image = .{ .window_id = id } };
                },
                .ping => {
                    if (!r.eof()) return error.InvalidData;
                    return .{ .ping = {} };
                },
                .pong => {
                    if (!r.eof()) return error.InvalidData;
                    return .{ .pong = {} };
                },
                .list_windows => {
                    if (!r.eof()) return error.InvalidData;
                    return .{ .list_windows = {} };
                },
                .list_workspaces => {
                    if (!r.eof()) return error.InvalidData;
                    return .{ .list_workspaces = {} };
                },
                .list_outputs => {
                    if (!r.eof()) return error.InvalidData;
                    return .{ .list_outputs = {} };
                },
                .get_window => {
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .get_window = .{ .id = id } };
                },
                .get_output => {
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .get_output = .{ .id = id } };
                },
                .get_workspace => {
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .get_workspace = .{ .id = id } };
                },
                .subscribe => {
                    const mask = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .subscribe = .{ .mask = mask } };
                },
                .unsubscribe => {
                    const mask = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .unsubscribe = .{ .mask = mask } };
                },
                .capture_full => {
                    const output_id = if (r.eof()) 0 else try r.readU64BE();
                    const scale = if (r.eof()) 1000 else try r.readU32BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .capture_full = .{ .output_id = output_id, .scale = scale } };
                },
                .capture_output => {
                    const output_id = try r.readU64BE();
                    const scale = if (r.eof()) 1000 else try r.readU32BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .capture_output = .{ .output_id = output_id, .scale = scale } };
                },
                .capture_window => {
                    const window_id = try r.readU64BE();
                    const scale = if (r.eof()) 1000 else try r.readU32BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .capture_window = .{ .window_id = window_id, .scale = scale } };
                },
                .focus_window => {
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .focus_window = .{ .id = id } };
                },
                .close_window => {
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .close_window = .{ .id = id } };
                },
                .move_window => {
                    const id = try r.readU64BE();
                    const x = try r.readI32BE();
                    const y = try r.readI32BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .move_window = .{ .id = id, .x = x, .y = y } };
                },
                .resize_window => {
                    const id = try r.readU64BE();
                    const width = try r.readU32BE();
                    const height = try r.readU32BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .resize_window = .{ .id = id, .width = width, .height = height } };
                },
                .switch_workspace => {
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .switch_workspace = .{ .id = id } };
                },
                .set_workspace_name => {
                    const id = try r.readU64BE();
                    const name = try r.readString(alloc);
                    errdefer if (name.len > 0) alloc.free(name);
                    if (!r.eof()) {
                        if (name.len > 0) alloc.free(name);
                        return error.InvalidData;
                    }
                    return .{ .set_workspace_name = .{ .id = id, .name = name } };
                },
                .shell_register => {
                    const namespace = try r.readString(alloc);
                    errdefer if (namespace.len > 0) alloc.free(namespace);
                    if (!r.eof()) {
                        if (namespace.len > 0) alloc.free(namespace);
                        return error.InvalidData;
                    }
                    return .{ .shell_register = .{ .namespace = namespace } };
                },
                .set_window_floating => {
                    const id = try r.readU64BE();
                    const floating = try r.readBool();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .set_window_floating = .{ .id = id, .floating = floating } };
                },
                .set_workspace_mode => {
                    const id = try r.readU64BE();
                    const mode_byte = try r.readU8();
                    const mode = std.enums.fromInt(WorkspaceMode, mode_byte) orelse return error.InvalidData;
                    if (!r.eof()) return error.InvalidData;
                    return .{ .set_workspace_mode = .{ .id = id, .mode = mode } };
                },
                .set_focus_config => {
                    const sw = try r.readBool();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .set_focus_config = .{ .switch_workspace_on_focus = sw } };
                },
                .request_keyboard_focus => {
                    const namespace = try r.readString(alloc);
                    errdefer if (namespace.len > 0) alloc.free(namespace);
                    if (!r.eof()) {
                        if (namespace.len > 0) alloc.free(namespace);
                        return error.InvalidData;
                    }
                    return .{ .request_keyboard_focus = .{ .namespace = namespace } };
                },
                .release_keyboard_focus => {
                    if (!r.eof()) return error.InvalidData;
                    return .{ .release_keyboard_focus = {} };
                },
                .set_window_fullscreen => {
                    const id = try r.readU64BE();
                    const fullscreen = try r.readBool();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .set_window_fullscreen = .{ .id = id, .fullscreen = fullscreen } };
                },
            }
        }

        /// Encode union into bytes ready for `Message.data`.
        /// Encoding is driven by `kind` (per-kind default) unless `enc` is
        /// explicitly passed. No prefix byte is stored – `kind` is the single
        /// source of truth for how to interpret `data`, avoiding the
        /// “HTTP 200 / JSON 404” mismatch.
        pub fn encodeAlloc(self: Request, alloc: Allocator, enc: Encoding) ![]u8 {
            const body = try self.encodeBodyAlloc(alloc);
            defer alloc.free(body);
            return switch (enc) {
                .raw => try alloc.dupe(u8, body),
                .deflate => try wire.compressAlloc(alloc, body),
            };
        }
        /// Kind-driven default (no caller-chosen enc).
        pub fn encodeAllocDefault(self: Request, alloc: Allocator) ![]u8 {
            return self.encodeAlloc(alloc, encodingForRequest(@as(RequestTag, self)));
        }

        /// Decode from `Message.data`. `kind` determines whether `data` is
        /// deflate-compressed. Caller must have already selected the correct
        /// `kind` – no hidden status inside `data`.
        pub fn decodeAlloc(alloc: Allocator, kind_byte: u8, data: []const u8) !Request {
            // intToEnum (not @enumFromInt): unknown tags from newer peers
            // must be a catchable error, never UB/panic — mixed-version
            // setups share one socket.
            const tag = std.enums.fromInt(RequestTag, kind_byte) orelse return error.InvalidData;
            // If caller used explicit enc that differs from per-kind default,
            // they must use `decodeAllocWith` below. This path uses the
            // per-kind default.
            return decodeAllocWith(alloc, kind_byte, data, encodingForRequest(tag));
        }
        pub fn decodeAllocWith(alloc: Allocator, kind_byte: u8, data: []const u8, enc: Encoding) !Request {
            const tag = std.enums.fromInt(RequestTag, kind_byte) orelse return error.InvalidData;
            const body = switch (enc) {
                .raw => try alloc.dupe(u8, data),
                .deflate => try wire.decompressAlloc(alloc, data),
            };
            defer alloc.free(body);
            return decodeBodyAlloc(tag, body, alloc);
        }

        /// Helper for root.zig: map request to kind byte.
        pub fn kind(self: Request) u8 {
            return @intFromEnum(@as(RequestTag, self));
        }

        /// Send `self` over a `root.Connection` (or any `anytype` with `.alloc` and `.request`).
        /// First param is pointer to `self`, second is `SendOpts` (encoding + future opts).
        /// `Message.kind` is set from `self` and determines `data` shape – no hidden status.
        pub fn send(self: *const Request, conn: anytype, opts: SendOpts) !Event {
            const alloc = conn.alloc;
            const enc = opts.encoding;
            const data = try self.encodeAlloc(alloc, enc);
            defer if (data.len > 0) alloc.free(data);
            const msg = .{ .kind = self.kind(), .encoding = enc, .data = data };
            const resp = try conn.request(msg);
            defer if (resp.data.len > 0) alloc.free(resp.data);
            // resp.encoding tells how to decompress; kind tells which variant
            return try Event.decodeAllocWith(alloc, resp.kind, resp.data, resp.encoding);
        }

        /// Convenience: use per-kind default encoding (`encodingForRequest`).
        pub fn sendDefault(self: *const Request, conn: anytype) !Event {
            return self.send(conn, .{ .encoding = encodingForRequest(@as(RequestTag, self.*)) });
        }

        /// One-way send that discards response (for fire-and-forget). Returns raw `Message` handling.
        pub fn sendOneWay(self: *const Request, conn: anytype, opts: SendOpts) !void {
            const alloc = conn.alloc;
            const enc = opts.encoding;
            const data = try self.encodeAlloc(alloc, enc);
            defer if (data.len > 0) alloc.free(data);
            const msg = .{ .kind = self.kind(), .encoding = enc, .data = data };
            const resp = try conn.request(msg);
            if (resp.data.len > 0) alloc.free(resp.data);
        }
    };

    // -----------------------------------------------------------------------
    // Event – compositor → client notifications / responses
    // -----------------------------------------------------------------------
    pub const EventTag = enum(u8) {
        new_window = 0x1,
        new_output = 0x2,
        windows = 0x3,
        outputs = 0x4,
        switch_workspace = 0x5,
        workspaces = 0x6,
        full_image = 0x7,
        window_image = 0x8,
        // extended
        window_closed = 0x9,
        window_focused = 0xA,
        window_moved = 0xB,
        window_resized = 0xC,
        window_title_changed = 0xD,
        window_app_id_changed = 0xE,
        window_state_changed = 0xF,
        window_workspace_changed = 0x10,
        output_added = 0x11,
        output_removed = 0x12,
        output_changed = 0x13,
        workspace_created = 0x14,
        workspace_removed = 0x15,
        workspace_activated = 0x16,
        workspace_deactivated = 0x17,
        error_msg = 0x18,
        pong = 0x19,
        output_image = 0x1A,
        windows_snapshot = 0x1B, // alias to windows but explicit
        outputs_snapshot = 0x1C,
        workspaces_snapshot = 0x1D,
        launcher_opened = 0x1E,
        launcher_closed = 0x1F,
        switcher_opened = 0x20,
        switcher_closed = 0x21,
        workspace_mode_changed = 0x22,
        window_floating_changed = 0x23,
        shell_focus_changed = 0x24,
    };

    pub const Event = union(EventTag) {
        new_window: NewWindow,
        new_output: Output,
        windows: WindowList,
        outputs: OutputList,
        switch_workspace: SwitchWorkspace,
        workspaces: WorkspaceList,
        full_image: Image,
        window_image: WindowImage,
        window_closed: WindowClosed,
        window_focused: WindowFocused,
        window_moved: WindowMoved,
        window_resized: WindowMoved,
        window_title_changed: WindowTitleChanged,
        window_app_id_changed: WindowAppIdChanged,
        window_state_changed: WindowStateChanged,
        window_workspace_changed: WindowWorkspaceChanged,
        output_added: Output,
        output_removed: OutputRemoved,
        output_changed: Output,
        workspace_created: Workspace,
        workspace_removed: WorkspaceRemoved,
        workspace_activated: WorkspaceActivated,
        workspace_deactivated: WorkspaceDeactivated,
        error_msg: ErrorMsg,
        pong: Pong,
        output_image: OutputImage,
        windows_snapshot: WindowList,
        outputs_snapshot: OutputList,
        workspaces_snapshot: WorkspaceList,
        launcher_opened: void,
        launcher_closed: void,
        switcher_opened: void,
        switcher_closed: void,
        workspace_mode_changed: WorkspaceModeChanged,
        window_floating_changed: WindowFloatingChanged,
        shell_focus_changed: ShellFocusChanged,

        // payload aliases for compat
        pub const NewWindow = struct {
            title: []const u8,
            id: u64,
            pub fn deinit(self: NewWindow, alloc: Allocator) void {
                if (self.title.len > 0) alloc.free(self.title);
            }
        };
        pub const Workspaces = [9]Workspace; // legacy fixed alias
        pub const WindowList = struct { items: []Window };
        pub const OutputList = struct { items: []Output };
        pub const WorkspaceList = struct { items: []Workspace };
        pub const SwitchWorkspace = struct { index: u8 };
        pub const WindowClosed = struct { id: u64 };
        pub const WindowFocused = struct { id: u64, old_id: u64 }; // 0 = none
        pub const WindowMoved = struct { id: u64, rect: Rect };
        pub const WindowTitleChanged = struct { id: u64, title: []const u8 };
        pub const WindowAppIdChanged = struct { id: u64, app_id: []const u8 };
        pub const WindowStateChanged = struct {
            id: u64,
            floating: bool,
            fullscreen: bool,
            urgent: bool,
            focused: bool,
        };
        pub const WindowWorkspaceChanged = struct { id: u64, old_workspace: u64, new_workspace: u64 };
        pub const OutputRemoved = struct { id: u64 };
        pub const WorkspaceRemoved = struct { id: u64 };
        pub const WorkspaceActivated = struct { id: u64 };
        pub const WorkspaceDeactivated = struct { id: u64 };
        pub const WindowImage = struct { window_id: u64, image: Image };
        pub const OutputImage = struct { output_id: u64, image: Image };
        pub const ErrorMsg = struct { code: u32, message: []const u8 };
        pub const Pong = struct { nonce: u64 = 0 };
        pub const WorkspaceModeChanged = struct { id: u64, mode: WorkspaceMode };
        pub const WindowFloatingChanged = struct { id: u64, floating: bool };
        pub const ShellFocusChanged = struct { focused: bool };

        pub fn deinit(self: Event, alloc: Allocator) void {
            switch (self) {
                .new_window => |v| if (v.title.len > 0) alloc.free(v.title),
                .new_output => |v| v.deinit(alloc),
                .windows => |v| {
                    for (v.items) |w| w.deinit(alloc);
                    if (v.items.len > 0) alloc.free(v.items);
                },
                .outputs => |v| {
                    for (v.items) |o| o.deinit(alloc);
                    if (v.items.len > 0) alloc.free(v.items);
                },
                .workspaces => |v| {
                    for (v.items) |w| w.deinit(alloc);
                    if (v.items.len > 0) alloc.free(v.items);
                },
                .windows_snapshot => |v| {
                    for (v.items) |w| w.deinit(alloc);
                    if (v.items.len > 0) alloc.free(v.items);
                },
                .outputs_snapshot => |v| {
                    for (v.items) |o| o.deinit(alloc);
                    if (v.items.len > 0) alloc.free(v.items);
                },
                .workspaces_snapshot => |v| {
                    for (v.items) |w| w.deinit(alloc);
                    if (v.items.len > 0) alloc.free(v.items);
                },
                .full_image => |v| v.deinit(alloc),
                .window_image => |v| v.image.deinit(alloc),
                .output_image => |v| v.image.deinit(alloc),
                .window_title_changed => |v| if (v.title.len > 0) alloc.free(v.title),
                .window_app_id_changed => |v| if (v.app_id.len > 0) alloc.free(v.app_id),
                .error_msg => |v| if (v.message.len > 0) alloc.free(v.message),
                .output_added => |v| v.deinit(alloc),
                .output_changed => |v| v.deinit(alloc),
                .workspace_created => |v| v.deinit(alloc),
                else => {},
            }
        }

        fn encodeBodyAlloc(self: Event, alloc: Allocator) ![]u8 {
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(alloc);
            switch (self) {
                .new_window => |v| {
                    try wire.writeString(&list, alloc, v.title);
                    try wire.writeU64BE(&list, alloc, v.id);
                },
                .new_output => |v| try v.encodeAlloc(alloc, &list),
                .output_added => |v| try v.encodeAlloc(alloc, &list),
                .output_changed => |v| try v.encodeAlloc(alloc, &list),
                .windows => |v| try wire.encodeWindowList(alloc, v.items, &list),
                .windows_snapshot => |v| try wire.encodeWindowList(alloc, v.items, &list),
                .outputs => |v| try wire.encodeOutputList(alloc, v.items, &list),
                .outputs_snapshot => |v| try wire.encodeOutputList(alloc, v.items, &list),
                .switch_workspace => |v| try wire.writeU8(&list, alloc, v.index),
                .workspaces => |v| try wire.encodeWorkspaceList(alloc, v.items, &list),
                .workspaces_snapshot => |v| try wire.encodeWorkspaceList(alloc, v.items, &list),
                .full_image => |v| try v.encodeAlloc(alloc, &list),
                .window_image => |v| {
                    try wire.writeU64BE(&list, alloc, v.window_id);
                    try v.image.encodeAlloc(alloc, &list);
                },
                .output_image => |v| {
                    try wire.writeU64BE(&list, alloc, v.output_id);
                    try v.image.encodeAlloc(alloc, &list);
                },
                .window_closed => |v| try wire.writeU64BE(&list, alloc, v.id),
                .window_focused => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeU64BE(&list, alloc, v.old_id);
                },
                .window_moved => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try v.rect.encodeAlloc(alloc, &list);
                },
                .window_resized => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try v.rect.encodeAlloc(alloc, &list);
                },
                .window_title_changed => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeString(&list, alloc, v.title);
                },
                .window_app_id_changed => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeString(&list, alloc, v.app_id);
                },
                .window_state_changed => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeBool(&list, alloc, v.floating);
                    try wire.writeBool(&list, alloc, v.fullscreen);
                    try wire.writeBool(&list, alloc, v.urgent);
                    try wire.writeBool(&list, alloc, v.focused);
                },
                .window_workspace_changed => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeU64BE(&list, alloc, v.old_workspace);
                    try wire.writeU64BE(&list, alloc, v.new_workspace);
                },
                .output_removed => |v| try wire.writeU64BE(&list, alloc, v.id),
                .workspace_created => |v| try v.encodeAlloc(alloc, &list),
                .workspace_removed => |v| try wire.writeU64BE(&list, alloc, v.id),
                .workspace_activated => |v| try wire.writeU64BE(&list, alloc, v.id),
                .workspace_deactivated => |v| try wire.writeU64BE(&list, alloc, v.id),
                .error_msg => |v| {
                    try wire.writeU32BE(&list, alloc, v.code);
                    try wire.writeString(&list, alloc, v.message);
                },
                .pong => |v| try wire.writeU64BE(&list, alloc, v.nonce),
                .launcher_opened, .launcher_closed => {},
                .switcher_opened, .switcher_closed => {},
                .workspace_mode_changed => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeU8(&list, alloc, @intFromEnum(v.mode));
                },
                .window_floating_changed => |v| {
                    try wire.writeU64BE(&list, alloc, v.id);
                    try wire.writeBool(&list, alloc, v.floating);
                },
                .shell_focus_changed => |v| {
                    try wire.writeBool(&list, alloc, v.focused);
                },
            }
            return list.toOwnedSlice(alloc);
        }

        fn decodeBodyAlloc(tag: EventTag, data: []const u8, alloc: Allocator) !Event {
            var r = wire.Reader.init(data);
            switch (tag) {
                .new_window => {
                    const title = try r.readString(alloc);
                    errdefer if (title.len > 0) alloc.free(title);
                    const id = try r.readU64BE();
                    if (!r.eof()) {
                        if (title.len > 0) alloc.free(title);
                        return error.InvalidData;
                    }
                    return .{ .new_window = .{ .title = title, .id = id } };
                },
                .new_output, .output_added, .output_changed => {
                    const out = try Output.decodeAlloc(&r, alloc);
                    errdefer out.deinit(alloc);
                    if (!r.eof()) {
                        out.deinit(alloc);
                        return error.InvalidData;
                    }
                    return switch (tag) {
                        .new_output => .{ .new_output = out },
                        .output_added => .{ .output_added = out },
                        .output_changed => .{ .output_changed = out },
                        else => unreachable,
                    };
                },
                .windows, .windows_snapshot => {
                    const items = try wire.decodeWindowList(&r, alloc);
                    errdefer {
                        for (items) |w| w.deinit(alloc);
                        if (items.len > 0) alloc.free(items);
                    }
                    if (!r.eof()) {
                        for (items) |w| w.deinit(alloc);
                        if (items.len > 0) alloc.free(items);
                        return error.InvalidData;
                    }
                    return switch (tag) {
                        .windows => .{ .windows = .{ .items = items } },
                        .windows_snapshot => .{ .windows_snapshot = .{ .items = items } },
                        else => unreachable,
                    };
                },
                .outputs, .outputs_snapshot => {
                    const items = try wire.decodeOutputList(&r, alloc);
                    errdefer {
                        for (items) |o| o.deinit(alloc);
                        if (items.len > 0) alloc.free(items);
                    }
                    if (!r.eof()) {
                        for (items) |o| o.deinit(alloc);
                        if (items.len > 0) alloc.free(items);
                        return error.InvalidData;
                    }
                    return switch (tag) {
                        .outputs => .{ .outputs = .{ .items = items } },
                        .outputs_snapshot => .{ .outputs_snapshot = .{ .items = items } },
                        else => unreachable,
                    };
                },
                .switch_workspace => {
                    const idx = try r.readU8();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .switch_workspace = .{ .index = idx } };
                },
                .workspaces, .workspaces_snapshot => {
                    const items = try wire.decodeWorkspaceList(&r, alloc);
                    errdefer {
                        for (items) |w| w.deinit(alloc);
                        if (items.len > 0) alloc.free(items);
                    }
                    if (!r.eof()) {
                        for (items) |w| w.deinit(alloc);
                        if (items.len > 0) alloc.free(items);
                        return error.InvalidData;
                    }
                    return switch (tag) {
                        .workspaces => .{ .workspaces = .{ .items = items } },
                        .workspaces_snapshot => .{ .workspaces_snapshot = .{ .items = items } },
                        else => unreachable,
                    };
                },
                .full_image => {
                    const img = try Image.decodeAlloc(&r, alloc);
                    errdefer img.deinit(alloc);
                    if (!r.eof()) {
                        img.deinit(alloc);
                        return error.InvalidData;
                    }
                    return .{ .full_image = img };
                },
                .window_image => {
                    const window_id = try r.readU64BE();
                    const img = try Image.decodeAlloc(&r, alloc);
                    errdefer img.deinit(alloc);
                    if (!r.eof()) {
                        img.deinit(alloc);
                        return error.InvalidData;
                    }
                    return .{ .window_image = .{ .window_id = window_id, .image = img } };
                },
                .output_image => {
                    const output_id = try r.readU64BE();
                    const img = try Image.decodeAlloc(&r, alloc);
                    errdefer img.deinit(alloc);
                    if (!r.eof()) {
                        img.deinit(alloc);
                        return error.InvalidData;
                    }
                    return .{ .output_image = .{ .output_id = output_id, .image = img } };
                },
                .window_closed => {
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .window_closed = .{ .id = id } };
                },
                .window_focused => {
                    const id = try r.readU64BE();
                    const old_id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .window_focused = .{ .id = id, .old_id = old_id } };
                },
                .window_moved => {
                    const id = try r.readU64BE();
                    const rect = try Rect.decodeAlloc(&r);
                    if (!r.eof()) return error.InvalidData;
                    return .{ .window_moved = .{ .id = id, .rect = rect } };
                },
                .window_resized => {
                    const id = try r.readU64BE();
                    const rect = try Rect.decodeAlloc(&r);
                    if (!r.eof()) return error.InvalidData;
                    return .{ .window_resized = .{ .id = id, .rect = rect } };
                },
                .window_title_changed => {
                    const id = try r.readU64BE();
                    const title = try r.readString(alloc);
                    errdefer if (title.len > 0) alloc.free(title);
                    if (!r.eof()) {
                        if (title.len > 0) alloc.free(title);
                        return error.InvalidData;
                    }
                    return .{ .window_title_changed = .{ .id = id, .title = title } };
                },
                .window_app_id_changed => {
                    const id = try r.readU64BE();
                    const app_id = try r.readString(alloc);
                    errdefer if (app_id.len > 0) alloc.free(app_id);
                    if (!r.eof()) {
                        if (app_id.len > 0) alloc.free(app_id);
                        return error.InvalidData;
                    }
                    return .{ .window_app_id_changed = .{ .id = id, .app_id = app_id } };
                },
                .window_state_changed => {
                    const id = try r.readU64BE();
                    const floating = try r.readBool();
                    const fullscreen = try r.readBool();
                    const urgent = try r.readBool();
                    const focused = try r.readBool();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .window_state_changed = .{ .id = id, .floating = floating, .fullscreen = fullscreen, .urgent = urgent, .focused = focused } };
                },
                .window_workspace_changed => {
                    const id = try r.readU64BE();
                    const old_ws = try r.readU64BE();
                    const new_ws = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .window_workspace_changed = .{ .id = id, .old_workspace = old_ws, .new_workspace = new_ws } };
                },
                .output_removed => {
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .output_removed = .{ .id = id } };
                },
                .workspace_created => {
                    const ws = try Workspace.decodeAlloc(&r, alloc);
                    errdefer ws.deinit(alloc);
                    if (!r.eof()) {
                        ws.deinit(alloc);
                        return error.InvalidData;
                    }
                    return .{ .workspace_created = ws };
                },
                .workspace_removed => {
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .workspace_removed = .{ .id = id } };
                },
                .workspace_activated => {
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .workspace_activated = .{ .id = id } };
                },
                .workspace_deactivated => {
                    const id = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .workspace_deactivated = .{ .id = id } };
                },
                .error_msg => {
                    const code = try r.readU32BE();
                    const msg = try r.readString(alloc);
                    errdefer if (msg.len > 0) alloc.free(msg);
                    if (!r.eof()) {
                        if (msg.len > 0) alloc.free(msg);
                        return error.InvalidData;
                    }
                    return .{ .error_msg = .{ .code = code, .message = msg } };
                },
                .pong => {
                    const nonce = try r.readU64BE();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .pong = .{ .nonce = nonce } };
                },
                .launcher_opened => {
                    if (!r.eof()) return error.InvalidData;
                    return .{ .launcher_opened = {} };
                },
                .launcher_closed => {
                    if (!r.eof()) return error.InvalidData;
                    return .{ .launcher_closed = {} };
                },
                .switcher_opened => {
                    if (!r.eof()) return error.InvalidData;
                    return .{ .switcher_opened = {} };
                },
                .switcher_closed => {
                    if (!r.eof()) return error.InvalidData;
                    return .{ .switcher_closed = {} };
                },
                .workspace_mode_changed => {
                    const id = try r.readU64BE();
                    const mode_byte = try r.readU8();
                    const mode = std.enums.fromInt(WorkspaceMode, mode_byte) orelse return error.InvalidData;
                    if (!r.eof()) return error.InvalidData;
                    return .{ .workspace_mode_changed = .{ .id = id, .mode = mode } };
                },
                .window_floating_changed => {
                    const id = try r.readU64BE();
                    const floating = try r.readBool();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .window_floating_changed = .{ .id = id, .floating = floating } };
                },
                .shell_focus_changed => {
                    const focused = try r.readBool();
                    if (!r.eof()) return error.InvalidData;
                    return .{ .shell_focus_changed = .{ .focused = focused } };
                },
            }
        }

        pub fn encodeAlloc(self: Event, alloc: Allocator, enc: Encoding) ![]u8 {
            const body = try self.encodeBodyAlloc(alloc);
            defer alloc.free(body);
            return switch (enc) {
                .raw => try alloc.dupe(u8, body),
                .deflate => try wire.compressAlloc(alloc, body),
            };
        }
        pub fn encodeAllocDefault(self: Event, alloc: Allocator) ![]u8 {
            return self.encodeAlloc(alloc, encodingForEvent(@as(EventTag, self)));
        }

        pub fn decodeAlloc(alloc: Allocator, kind_byte: u8, data: []const u8) !Event {
            // intToEnum (not @enumFromInt): unknown tags from newer peers
            // must be a catchable error, never UB/panic.
            const tag = std.enums.fromInt(EventTag, kind_byte) orelse return error.InvalidData;
            return decodeAllocWith(alloc, kind_byte, data, encodingForEvent(tag));
        }
        pub fn decodeAllocWith(alloc: Allocator, kind_byte: u8, data: []const u8, enc: Encoding) !Event {
            const tag = std.enums.fromInt(EventTag, kind_byte) orelse return error.InvalidData;
            const body = switch (enc) {
                .raw => try alloc.dupe(u8, data),
                .deflate => try wire.decompressAlloc(alloc, data),
            };
            defer alloc.free(body);
            return decodeBodyAlloc(tag, body, alloc);
        }

        pub fn kind(self: Event) u8 {
            return @intFromEnum(@as(EventTag, self));
        }

        /// Send `self` over a `root.Connection` (or any `anytype` with `.alloc` and `.request`).
        /// First param is pointer to `self`, second is `SendOpts` (encoding + future opts).
        /// `Message.kind` carries the `EventTag`, `Message.data` shape follows it.
        pub fn send(self: *const Event, conn: anytype, opts: SendOpts) !void {
            const alloc = conn.alloc;
            const enc = opts.encoding;
            const data = try self.encodeAlloc(alloc, enc);
            defer if (data.len > 0) alloc.free(data);
            const msg = .{ .kind = self.kind(), .encoding = enc, .data = data };
            const resp = try conn.request(msg);
            if (resp.data.len > 0) alloc.free(resp.data);
        }

        pub fn sendDefault(self: *const Event, conn: anytype) !void {
            return self.send(conn, .{ .encoding = encodingForEvent(@as(EventTag, self.*)) });
        }

        /// Server-side broadcast – encode `self` and push it to every
        /// connected client without waiting for a request. Takes `*Server`
        /// (anytype with `.alloc` and `.broadcast`).
        pub fn sendViaServer(self: *const Event, server: anytype, opts: SendOpts) !void {
            const alloc = server.alloc;
            const enc = opts.encoding;
            const data = try self.encodeAlloc(alloc, enc);
            defer if (data.len > 0) alloc.free(data);
            // kind carries the EventTag; id 0 marks it unsolicited so
            // client readers route it to the event listener.
            try server.broadcast(.{ .kind = self.kind(), .encoding = enc, .data = data });
        }
    };

    /// Backwards-compat alias: original `compositor.Event` was an enum;
    /// keep the tag enum available under the old name for code that did
    /// `protocols.compositor.Event.new_window`.
    pub const EventEnum = EventTag;
    pub const RequestEnum = RequestTag;
};

// ---------------------------------------------------------------------------
// Self-tests for compositor wire roundtrips
// ---------------------------------------------------------------------------
test "compositor wire: primitive roundtrip" {
    const t = std.testing;
    const alloc = t.allocator;

    // Rect
    {
        const rect: compositor.Rect = .{ .x = -10, .y = 20, .width = 800, .height = 600 };
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        try rect.encodeAlloc(alloc, &list);
        var r = compositor.wire.Reader.init(list.items);
        const dec = try compositor.Rect.decodeAlloc(&r);
        try t.expectEqual(rect.x, dec.x);
        try t.expectEqual(rect.y, dec.y);
        try t.expectEqual(rect.width, dec.width);
        try t.expectEqual(rect.height, dec.height);
        try t.expect(r.eof());
    }

    // Window raw
    {
        const w: compositor.Window = .{ .id = 42, .title = "hello", .app_id = "app", .workspace = 1, .output = 2, .pid = 1234, .rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .floating = true, .focused = true };
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        try w.encodeAlloc(alloc, &list);
        var r = compositor.wire.Reader.init(list.items);
        const dec = try compositor.Window.decodeAlloc(&r, alloc);
        defer dec.deinit(alloc);
        try t.expect(w.eql(dec));
    }

    // Workspace
    {
        const ws: compositor.Workspace = .{ .id = 7, .number = 3, .name = "code", .active = true, .current = true, .urgent = false, .output = 1 };
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        try ws.encodeAlloc(alloc, &list);
        var r = compositor.wire.Reader.init(list.items);
        const dec = try compositor.Workspace.decodeAlloc(&r, alloc);
        defer dec.deinit(alloc);
        try t.expectEqual(ws.id, dec.id);
        try t.expectEqualStrings(ws.name, dec.name);
    }

    // Output
    {
        const out: compositor.Output = .{ .id = 9, .name = "HDMI-1", .make = "Dell", .model = "U2719D", .x = 0, .y = 0, .mode = .{ .width = 2560, .height = 1440, .refresh = 60000 }, .scale = 1000, .enabled = true };
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        try out.encodeAlloc(alloc, &list);
        var r = compositor.wire.Reader.init(list.items);
        const dec = try compositor.Output.decodeAlloc(&r, alloc);
        defer dec.deinit(alloc);
        try t.expectEqual(out.id, dec.id);
        try t.expectEqualStrings(out.name, dec.name);
        try t.expectEqual(out.mode.width, dec.mode.width);
    }

    // Image roundtrip via raw frame
    {
        const img: compositor.Image = .{ .width = 2, .height = 2, .stride = 8, .format = .rgba8, .data = &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } };
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        try img.encodeAlloc(alloc, &list);
        var r = compositor.wire.Reader.init(list.items);
        const dec = try compositor.Image.decodeAlloc(&r, alloc);
        defer dec.deinit(alloc);
        try t.expectEqual(img.width, dec.width);
        try t.expectEqualStrings(img.data, dec.data);
    }
}

test "compositor wire: frame raw vs deflate" {
    const t = std.testing;
    const alloc = t.allocator;
    const payload = "hello world hello world hello world hello world hello world hello world hello world";
    const raw_frame = try compositor.wire.encodeFrame(alloc, payload, .raw);
    defer alloc.free(raw_frame);
    try t.expectEqual(@as(u8, 0), raw_frame[0]);
    {
        const dec = try compositor.wire.decodeFrame(alloc, raw_frame);
        defer dec.deinit(alloc);
        try t.expectEqual(compositor.Encoding.raw, dec.encoding);
        try t.expectEqualStrings(payload, dec.data);
    }
    const def_frame = try compositor.wire.encodeFrame(alloc, payload, .deflate);
    defer alloc.free(def_frame);
    try t.expectEqual(@as(u8, 1), def_frame[0]);
    try t.expect(def_frame.len < raw_frame.len); // should compress repetitive data
    {
        const dec = try compositor.wire.decodeFrame(alloc, def_frame);
        defer dec.deinit(alloc);
        try t.expectEqual(compositor.Encoding.deflate, dec.encoding);
        try t.expectEqualStrings(payload, dec.data);
    }
    // binary data (image-like)
    const bin = try alloc.alloc(u8, 4096);
    defer alloc.free(bin);
    for (bin, 0..) |*b, i| b.* = @intCast(i % 256);
    const bin_raw = try compositor.wire.encodeFrame(alloc, bin, .raw);
    defer alloc.free(bin_raw);
    const bin_def = try compositor.wire.encodeFrame(alloc, bin, .deflate);
    defer alloc.free(bin_def);
    {
        const dec = try compositor.wire.decodeFrame(alloc, bin_def);
        defer dec.deinit(alloc);
        try t.expectEqualStrings(bin, dec.data);
    }
}

test "compositor Request encode/decode raw" {
    const t = std.testing;
    const alloc = t.allocator;
    const cases = [_]compositor.Request{
        .{ .ping = {} },
        .{ .list_windows = {} },
        .{ .get_window = .{ .id = 123 } },
        .{ .subscribe = .{ .mask = 0xFF } },
        .{ .capture_window = .{ .window_id = 42, .scale = 2000 } },
        .{ .move_window = .{ .id = 1, .x = -10, .y = 20 } },
        .{ .set_workspace_name = .{ .id = 7, .name = "code" } },
        .{ .shell_register = .{ .namespace = "nshell-hub" } },
        .{ .set_window_fullscreen = .{ .id = 99, .fullscreen = true } },
        .{ .set_window_fullscreen = .{ .id = 99, .fullscreen = false } },
    };
    for (cases) |req| {
        const k = req.kind();
        const data = try req.encodeAlloc(alloc, .raw);
        defer alloc.free(data);
        const dec = try compositor.Request.decodeAllocWith(alloc, k, data, .raw);
        defer dec.deinit(alloc);
        try t.expectEqual(k, dec.kind());
        switch (dec) {
            .get_window => |v| try t.expectEqual(@as(u64, 123), v.id),
            .move_window => |v| {
                if (k == @intFromEnum(compositor.RequestTag.move_window)) {
                    try t.expectEqual(@as(i32, -10), v.x);
                }
            },
            .shell_register => |v| try t.expectEqualStrings("nshell-hub", v.namespace),
            .set_window_fullscreen => |v| {
                try t.expectEqual(@as(u64, 99), v.id);
                if (k == @intFromEnum(compositor.RequestTag.set_window_fullscreen)) {
                    try t.expectEqual(req.set_window_fullscreen.fullscreen, v.fullscreen);
                }
            },
            else => {},
        }
    }
}

test "compositor Request encode/decode deflate explicit" {
    const t = std.testing;
    const alloc = t.allocator;
    const req: compositor.Request = .{ .capture_full = .{ .output_id = 1, .scale = 1000 } };
    const k = req.kind();
    const data = try req.encodeAlloc(alloc, .deflate);
    defer alloc.free(data);
    // data is now deflate-compressed pack, not prefixed; ensure it decompresses
    const dec = try compositor.Request.decodeAllocWith(alloc, k, data, .deflate);
    defer dec.deinit(alloc);
    try t.expectEqual(k, dec.kind());
}

test "compositor Event encode/decode raw and deflate" {
    const t = std.testing;
    const alloc = t.allocator;

    const ev1: compositor.Event = .{ .new_window = .{ .title = "term", .id = 99 } };
    {
        const k = ev1.kind();
        const data = try ev1.encodeAlloc(alloc, .raw);
        defer alloc.free(data);
        var dec = try compositor.Event.decodeAllocWith(alloc, k, data, .raw);
        defer dec.deinit(alloc);
        try t.expectEqual(k, dec.kind());
        switch (dec) {
            .new_window => |v| {
                try t.expectEqualStrings("term", v.title);
                try t.expectEqual(@as(u64, 99), v.id);
            },
            else => return error.WrongTag,
        }
    }

    const win: compositor.Window = .{ .id = 1, .title = "a", .app_id = "b" };
    const ev2: compositor.Event = .{ .window_workspace_changed = .{ .id = 1, .old_workspace = 2, .new_workspace = 3 } };
    {
        const k = ev2.kind();
        const data = try ev2.encodeAlloc(alloc, .deflate);
        defer alloc.free(data);
        var dec = try compositor.Event.decodeAllocWith(alloc, k, data, .deflate);
        defer dec.deinit(alloc);
        try t.expectEqual(k, dec.kind());
    }
    _ = win;

    // windows snapshot with deflate (typical zip-on-the-fly case)
    // kind-driven default for windows is deflate – use encodeAllocDefault
    {
        var wins = try alloc.alloc(compositor.Window, 2);
        defer alloc.free(wins);
        wins[0] = .{ .id = 1, .title = try alloc.dupe(u8, "one"), .app_id = try alloc.dupe(u8, "app1") };
        wins[1] = .{ .id = 2, .title = try alloc.dupe(u8, "two"), .app_id = try alloc.dupe(u8, "app2") };
        defer for (wins) |w| w.deinit(alloc);
        const ev: compositor.Event = .{ .windows = .{ .items = wins } };
        const k = ev.kind();
        const raw = try ev.encodeAlloc(alloc, .raw);
        defer alloc.free(raw);
        const def = try ev.encodeAlloc(alloc, .deflate);
        defer alloc.free(def);
        // default for this kind is deflate
        const def2 = try ev.encodeAllocDefault(alloc);
        defer alloc.free(def2);
        var dec = try compositor.Event.decodeAllocWith(alloc, k, def, .deflate);
        defer dec.deinit(alloc);
        try t.expectEqual(@as(usize, 2), dec.windows.items.len);
        var dec2 = try compositor.Event.decodeAlloc(alloc, k, def2);
        defer dec2.deinit(alloc);
        try t.expectEqual(@as(usize, 2), dec2.windows.items.len);
    }

    // launcher/switcher open/close are empty control events (default raw encoding)
    for ([_]compositor.Event{
        .{ .launcher_opened = {} },
        .{ .launcher_closed = {} },
        .{ .switcher_opened = {} },
        .{ .switcher_closed = {} },
    }) |ev| {
        const k = ev.kind();
        const data = try ev.encodeAllocDefault(alloc);
        defer alloc.free(data);
        try t.expectEqual(compositor.Encoding.raw, compositor.encodingForEvent(@as(compositor.EventTag, @enumFromInt(k))));
        var dec = try compositor.Event.decodeAlloc(alloc, k, data);
        defer dec.deinit(alloc);
        try t.expectEqual(k, dec.kind());
    }

    // shell_focus_changed carries one bool (default raw encoding)
    for ([_]bool{ true, false }) |focused| {
        const ev: compositor.Event = .{ .shell_focus_changed = .{ .focused = focused } };
        const k = ev.kind();
        const data = try ev.encodeAllocDefault(alloc);
        defer alloc.free(data);
        try t.expectEqual(compositor.Encoding.raw, compositor.encodingForEvent(@as(compositor.EventTag, @enumFromInt(k))));
        var dec = try compositor.Event.decodeAlloc(alloc, k, data);
        defer dec.deinit(alloc);
        try t.expectEqual(k, dec.kind());
        try t.expectEqual(focused, dec.shell_focus_changed.focused);
    }

    // full_image with deflate (large binary) – per-kind default is deflate
    {
        const data = try alloc.alloc(u8, 1024);
        defer alloc.free(data);
        for (data, 0..) |*b, i| b.* = @intCast(i % 251);
        const img: compositor.Image = .{ .width = 32, .height = 32, .stride = 32 * 4, .format = .rgba8, .data = data };
        const ev: compositor.Event = .{ .full_image = img };
        const k = ev.kind();
        const def = try ev.encodeAllocDefault(alloc);
        defer alloc.free(def);
        var dec = try compositor.Event.decodeAlloc(alloc, k, def);
        defer dec.deinit(alloc);
        try t.expectEqual(img.width, dec.full_image.width);
        try t.expectEqualStrings(data, dec.full_image.data);
    }
}

test "compositor unknown kind bytes are errors, not panics" {
    // Mixed-version peers share one socket: a tag this build doesn't know
    // must decode to an error (caller replies/drops cleanly), never UB.
    const t = std.testing;
    const alloc = t.allocator;
    try t.expectError(error.InvalidData, compositor.Request.decodeAllocWith(alloc, 0xFF, "", .raw));
    try t.expectError(error.InvalidData, compositor.Event.decodeAllocWith(alloc, 0xFF, "", .raw));
    // 0x46/0x1E are known to THIS build (shell_register/launcher_opened);
    // empty bodies must still validate structurally.
    try t.expectError(error.InvalidData, compositor.Request.decodeAllocWith(alloc, 0x46, "", .raw));
    const ev = try compositor.Event.decodeAllocWith(alloc, 0x1E, "", .raw);
    defer ev.deinit(alloc);
    try t.expect(ev == .launcher_opened);
}

test "compositor legacy Window literal compat" {
    const t = std.testing;
    // Old code: Window{ .title = "hi", .id = 1 } must still compile
    const w: compositor.Window = .{ .title = "hi", .id = 1 };
    try t.expectEqualStrings("hi", w.title);
    try t.expectEqual(@as(u64, 1), w.id);
    // Workspace legacy
    const ws: compositor.Workspace = .{ .active = true, .current = false, .number = 2 };
    try t.expectEqual(true, ws.active);
}
