//! A pointer-backed `wlr.Buffer` used as the render target for screen sharing.
//!
//! ## Why a hand-rolled impl
//!
//! `ShareRender` rasterises the composed scene with
//! `wlr_renderer_begin_buffer_pass`, which needs a `wlr_buffer` to target.
//! PipeWire hands us raw memory, not a wlroots buffer, so something has to
//! wrap it. wlroots' own shm implementation is not exposed to embedders —
//! `wlr_buffer_init` plus a custom `wlr.Buffer.Impl` is the supported route,
//! and `Impl` is a plain struct of six function pointers.
//!
//! ## Ownership
//!
//! Memory belongs to PipeWire. This wrapper never frees, unmaps or closes
//! anything: it only describes a region someone else allocated, so
//! `destroy` frees the wrapper and nothing else.
//!
//! `Impl` carries no user data, so the `wlr.Buffer` and its `Impl` are
//! embedded in this struct and the callbacks recover `self` with
//! `@fieldParentPtr`.

const std = @import("std");
const wlr = @import("wlroots");
const log = std.log;

/// DRM_FORMAT_XRGB8888. Alpha is unused, so the compositor's premultiplied
/// blend mode produces the same bytes a consumer expects from BGRx.
pub const drm_format_xrgb8888: u32 = 0x3432_5258;

pub const Error = error{OutOfMemory};

pub const ShareBuffer = struct {
    buffer: wlr.Buffer,
    impl: wlr.Buffer.Impl,

    ptr: [*]u8,
    len: usize,
    width: c_int,
    height: c_int,
    stride: c_int,
    format: u32,

    /// Guards against a data_ptr_access pair being left open, which would
    /// make wlroots treat the buffer as permanently busy.
    accessing: bool = false,

    /// Describe `ptr` (owned by the caller) as a wlroots buffer.
    pub fn wrap(
        ptr: [*]u8,
        len: usize,
        width: c_int,
        height: c_int,
        stride: c_int,
        format: u32,
    ) Error!*ShareBuffer {
        const self = try std.heap.c_allocator.create(ShareBuffer);
        self.* = .{
            .buffer = undefined,
            .impl = undefined,
            .ptr = ptr,
            .len = len,
            .width = width,
            .height = height,
            .stride = stride,
            .format = format,
            .accessing = false,
        };
        self.impl = .{
            .destroy = destroyCb,
            .get_dmabuf = null,
            // Reported as shm because wlroots' render pass path checks it to
            // decide whether the target is CPU-mappable. There is no fd: the
            // memory came from PipeWire, and nothing here is exported.
            .get_shm = getShm,
            .begin_data_ptr_access = beginDataPtrAccess,
            .end_data_ptr_access = endDataPtrAccess,
        };
        wlr.Buffer.init(&self.buffer, &self.impl, width, height);
        return self;
    }

    pub fn destroy(self: *ShareBuffer) void {
        const alloc = std.heap.c_allocator;
        alloc.destroy(self);
    }

    pub fn sizeBytes(self: *const ShareBuffer) usize {
        return self.len;
    }

    // --- wlr.Buffer.Impl callbacks -----------------------------------------

    fn from(buffer: *wlr.Buffer) *ShareBuffer {
        return @fieldParentPtr("buffer", buffer);
    }

    fn destroyCb(buffer: *wlr.Buffer) callconv(.c) void {
        from(buffer).destroy();
    }

    fn getShm(buffer: *wlr.Buffer, attribs: *wlr.ShmAttributes) callconv(.c) bool {
        const self = from(buffer);
        // fd -1 marks "shm-backed but not exportable", which is exactly our
        // situation and is what wlroots expects for a non-exportable buffer.
        attribs.fd = -1;
        attribs.format = self.format;
        attribs.width = self.width;
        attribs.height = self.height;
        attribs.stride = self.stride;
        attribs.offset = 0;
        return true;
    }

    fn beginDataPtrAccess(
        buffer: *wlr.Buffer,
        flags: u32,
        data: **anyopaque,
        format: *u32,
        stride: *usize,
    ) callconv(.c) bool {
        const self = from(buffer);
        if (self.accessing) {
            log.err("share: overlapping data_ptr_access on the share buffer", .{});
            return false;
        }
        self.accessing = true;
        data.* = @ptrCast(self.ptr);
        format.* = self.format;
        stride.* = @intCast(self.stride);
        _ = flags;
        return true;
    }

    fn endDataPtrAccess(buffer: *wlr.Buffer) callconv(.c) void {
        from(buffer).accessing = false;
    }
};