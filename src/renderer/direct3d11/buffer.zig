const std = @import("std");
const Allocator = std.mem.Allocator;

const com = @import("com.zig");
const c = com.c;

const log = std.log.scoped(.direct3d11);

/// Options for initializing a buffer.
pub const Options = struct {
    device: *c.ID3D11Device,
    context: *c.ID3D11DeviceContext,
    kind: Kind,

    pub const Kind = enum {
        /// Bound as the vertex buffer for per-vertex/per-instance data.
        vertex,

        /// Bound as a constant buffer (cbuffer) for uniforms.
        constant,

        /// Bound as a shader resource (StructuredBuffer) for arbitrary
        /// read-only data indexed by the shader.
        structured,
    };
};

/// The raw buffer resources, which is what is passed to render steps.
pub const Raw = struct {
    buffer: *c.ID3D11Buffer,

    /// Shader resource view, only set for structured buffers.
    srv: ?*c.ID3D11ShaderResourceView,

    /// Size in bytes of a single element.
    stride: u32,
};

/// Direct3D 11 GPU data storage for a certain set of equal types. This is
/// usually used for vertex buffers, etc. This helpful wrapper makes it easy
/// to prealloc, shrink, grow, sync, buffers with Direct3D.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The options this buffer was initialized with.
        opts: Options,

        /// The underlying buffer resources.
        buffer: Raw,

        /// The allocated length of the buffer, in elements of T.
        len: usize,

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) !Self {
            return .{
                .opts = opts,
                .buffer = try create(opts, len),
                .len = len,
            };
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            var self = try init(opts, data.len);
            errdefer self.deinit();
            try self.sync(data);
            return self;
        }

        pub fn deinit(self: *const Self) void {
            destroy(self.buffer);
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        ///
        /// If the amount of data is smaller than the buffer length, the
        /// remaining data in the buffer is left untouched.
        pub fn sync(self: *Self, data: []const T) !void {
            try self.ensureCapacity(data.len);
            const dst = try self.map();
            defer self.unmap();
            @memcpy(dst[0 .. data.len * @sizeOf(T)], std.mem.sliceAsBytes(data));
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| total_len += list.items.len;

            try self.ensureCapacity(total_len);
            const dst = try self.map();
            defer self.unmap();

            var i: usize = 0;
            for (lists) |list| {
                const bytes = std.mem.sliceAsBytes(list.items);
                @memcpy(dst[i..][0..bytes.len], bytes);
                i += bytes.len;
            }

            return total_len;
        }

        /// Grow the buffer if it can't hold `len` elements. Growing
        /// doubles the requested size to reduce future reallocations.
        fn ensureCapacity(self: *Self, len: usize) !void {
            if (len <= self.len) return;
            const new_len = len * 2;
            const new = try create(self.opts, new_len);
            destroy(self.buffer);
            self.buffer = new;
            self.len = new_len;
        }

        fn map(self: *Self) ![*]u8 {
            var mapped: c.D3D11_MAPPED_SUBRESOURCE = undefined;
            try com.check(com.call(self.opts.context, "Map", .{
                @as(*c.ID3D11Resource, @ptrCast(self.buffer.buffer)),
                0,
                c.D3D11_MAP_WRITE_DISCARD,
                0,
                &mapped,
            }), "ID3D11DeviceContext::Map");
            return @ptrCast(mapped.pData.?);
        }

        fn unmap(self: *Self) void {
            com.call(self.opts.context, "Unmap", .{
                @as(*c.ID3D11Resource, @ptrCast(self.buffer.buffer)),
                0,
            });
        }

        fn create(opts: Options, len: usize) !Raw {
            // Direct3D doesn't allow zero-sized buffers.
            var byte_width: c.UINT = @intCast(@max(len, 1) * @sizeOf(T));

            // Constant buffers must be a multiple of 16 bytes.
            if (opts.kind == .constant) {
                byte_width = std.mem.alignForward(c.UINT, byte_width, 16);
            }

            const desc: c.D3D11_BUFFER_DESC = .{
                .ByteWidth = byte_width,
                .Usage = c.D3D11_USAGE_DYNAMIC,
                .BindFlags = @intCast(switch (opts.kind) {
                    .vertex => c.D3D11_BIND_VERTEX_BUFFER,
                    .constant => c.D3D11_BIND_CONSTANT_BUFFER,
                    .structured => c.D3D11_BIND_SHADER_RESOURCE,
                }),
                .CPUAccessFlags = c.D3D11_CPU_ACCESS_WRITE,
                .MiscFlags = @intCast(switch (opts.kind) {
                    .vertex, .constant => 0,
                    .structured => c.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
                }),
                .StructureByteStride = switch (opts.kind) {
                    .vertex, .constant => 0,
                    .structured => @sizeOf(T),
                },
            };

            var buffer: ?*c.ID3D11Buffer = null;
            try com.check(
                com.call(opts.device, "CreateBuffer", .{ &desc, null, &buffer }),
                "ID3D11Device::CreateBuffer",
            );
            errdefer com.releaseOpt(buffer);

            const srv: ?*c.ID3D11ShaderResourceView = switch (opts.kind) {
                .vertex, .constant => null,
                .structured => srv: {
                    var srv_desc: c.D3D11_SHADER_RESOURCE_VIEW_DESC = std.mem.zeroes(
                        c.D3D11_SHADER_RESOURCE_VIEW_DESC,
                    );
                    srv_desc.Format = c.DXGI_FORMAT_UNKNOWN;
                    srv_desc.ViewDimension = c.D3D11_SRV_DIMENSION_BUFFER;
                    srv_desc.unnamed_0.Buffer.unnamed_0.FirstElement = 0;
                    srv_desc.unnamed_0.Buffer.unnamed_1.NumElements =
                        @intCast(byte_width / @sizeOf(T));

                    var srv: ?*c.ID3D11ShaderResourceView = null;
                    try com.check(com.call(opts.device, "CreateShaderResourceView", .{
                        @as(*c.ID3D11Resource, @ptrCast(buffer.?)),
                        &srv_desc,
                        &srv,
                    }), "ID3D11Device::CreateShaderResourceView");
                    break :srv srv.?;
                },
            };

            return .{
                .buffer = buffer.?,
                .srv = srv,
                .stride = @sizeOf(T),
            };
        }

        fn destroy(raw: Raw) void {
            com.releaseOpt(raw.srv);
            com.release(raw.buffer);
        }
    };
}
