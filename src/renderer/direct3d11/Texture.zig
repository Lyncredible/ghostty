//! Wrapper for handling textures.
const Self = @This();

const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;

const com = @import("com.zig");
const c = com.c;

const log = std.log.scoped(.direct3d11);

/// Options for initializing a texture.
pub const Options = struct {
    device: *c.ID3D11Device,
    context: *c.ID3D11DeviceContext,
    format: c.DXGI_FORMAT,

    /// Whether this texture can be rendered to.
    render_target: bool = false,
};

/// The underlying texture.
texture: *c.ID3D11Texture2D,

/// The view used to read this texture from shaders.
srv: *c.ID3D11ShaderResourceView,

/// The view used to render to this texture, if it's a render target.
rtv: ?*c.ID3D11RenderTargetView,

/// The immediate context used to upload data to this texture.
context: *c.ID3D11DeviceContext,

/// The width of this texture.
width: usize,
/// The height of this texture.
height: usize,

/// Bytes per pixel for this texture.
bpp: usize,

pub const Error = error{
    /// A Direct3D API call failed.
    Direct3DFailed,
};

/// Initialize a texture
pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const bpp = bppOf(opts.format);

    const desc: c.D3D11_TEXTURE2D_DESC = .{
        .Width = @intCast(width),
        .Height = @intCast(height),
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = opts.format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = c.D3D11_USAGE_DEFAULT,
        .BindFlags = @intCast(c.D3D11_BIND_SHADER_RESOURCE |
            if (opts.render_target) c.D3D11_BIND_RENDER_TARGET else 0),
        .CPUAccessFlags = 0,
        .MiscFlags = 0,
    };

    if (data) |d| assert(d.len == width * height * bpp);
    const initial: ?c.D3D11_SUBRESOURCE_DATA = if (data) |d| .{
        .pSysMem = d.ptr,
        .SysMemPitch = @intCast(width * bpp),
        .SysMemSlicePitch = 0,
    } else null;

    var texture: ?*c.ID3D11Texture2D = null;
    try com.check(com.call(opts.device, "CreateTexture2D", .{
        &desc,
        if (initial) |*i| i else null,
        &texture,
    }), "ID3D11Device::CreateTexture2D");
    errdefer com.releaseOpt(texture);

    var srv: ?*c.ID3D11ShaderResourceView = null;
    try com.check(com.call(opts.device, "CreateShaderResourceView", .{
        @as(*c.ID3D11Resource, @ptrCast(texture.?)),
        null,
        &srv,
    }), "ID3D11Device::CreateShaderResourceView");
    errdefer com.releaseOpt(srv);

    var rtv: ?*c.ID3D11RenderTargetView = null;
    if (opts.render_target) try com.check(com.call(opts.device, "CreateRenderTargetView", .{
        @as(*c.ID3D11Resource, @ptrCast(texture.?)),
        null,
        &rtv,
    }), "ID3D11Device::CreateRenderTargetView");

    return .{
        .texture = texture.?,
        .srv = srv.?,
        .rtv = rtv,
        .context = opts.context,
        .width = width,
        .height = height,
        .bpp = bpp,
    };
}

pub fn deinit(self: Self) void {
    com.releaseOpt(self.rtv);
    com.release(self.srv);
    com.release(self.texture);
}

/// Replace a region of the texture with the provided data.
///
/// Does NOT check the dimensions of the data to ensure correctness.
pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) error{}!void {
    const box: c.D3D11_BOX = .{
        .left = @intCast(x),
        .top = @intCast(y),
        .front = 0,
        .right = @intCast(x + width),
        .bottom = @intCast(y + height),
        .back = 1,
    };
    com.call(self.context, "UpdateSubresource", .{
        @as(*c.ID3D11Resource, @ptrCast(self.texture)),
        0,
        &box,
        data.ptr,
        @as(c.UINT, @intCast(self.bpp * width)),
        0,
    });
}

/// Returns the bytes per pixel for the formats we use.
pub fn bppOf(format: c.DXGI_FORMAT) usize {
    return switch (format) {
        c.DXGI_FORMAT_R8_UNORM => 1,

        c.DXGI_FORMAT_R8G8B8A8_UNORM,
        c.DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
        c.DXGI_FORMAT_B8G8R8A8_UNORM,
        c.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        => 4,

        else => @panic("unsupported DXGI format"),
    };
}

test bppOf {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 1), bppOf(c.DXGI_FORMAT_R8_UNORM));
    try testing.expectEqual(@as(usize, 4), bppOf(c.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB));
}

test "init and replaceRegion upload pixels" {
    const testing = std.testing;
    const Device = @import("Device.zig");
    // A hardware device, or WARP, which Windows always has.
    const created = Device.createDefault() catch return error.SkipZigTest;
    defer {
        com.release(created.context);
        com.release(created.device);
    }
    const opts: Options = .{
        .device = created.device,
        .context = created.context,
        .format = c.DXGI_FORMAT_R8_UNORM,
    };

    var initial: [4 * 3]u8 = undefined;
    for (&initial, 0..) |*p, i| p.* = @intCast(i);
    const texture = try init(opts, 4, 3, &initial);
    defer texture.deinit();
    try testing.expectEqual(@as(?*c.ID3D11RenderTargetView, null), texture.rtv);

    // Two pixels in the middle row, from the second column.
    try texture.replaceRegion(1, 1, 2, 1, &.{ 200, 201 });

    var pixels: [4 * 3]u8 = undefined;
    try readBack(texture, &pixels);
    try testing.expectEqualSlices(u8, &.{
        0, 1,   2,   3,
        4, 200, 201, 7,
        8, 9,   10,  11,
    }, &pixels);

    // A render target has a view to render to.
    const target = try init(.{
        .device = created.device,
        .context = created.context,
        .format = c.DXGI_FORMAT_B8G8R8A8_UNORM,
        .render_target = true,
    }, 2, 2, null);
    defer target.deinit();
    try testing.expect(target.rtv != null);
}

/// Copy a texture's pixels back from the GPU, row by row, for tests.
fn readBack(self: Self, out: []u8) !void {
    var desc: c.D3D11_TEXTURE2D_DESC = undefined;
    com.call(self.texture, "GetDesc", .{&desc});
    desc.Usage = c.D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = c.D3D11_CPU_ACCESS_READ;
    var device: ?*c.ID3D11Device = null;
    com.call(self.texture, "GetDevice", .{&device});
    defer com.releaseOpt(device);
    var staging: ?*c.ID3D11Texture2D = null;
    try com.check(com.call(device.?, "CreateTexture2D", .{ &desc, null, &staging }), "CreateTexture2D");
    defer com.releaseOpt(staging);
    const resource: *c.ID3D11Resource = @ptrCast(staging.?);
    com.call(self.context, "CopyResource", .{ resource, @as(*c.ID3D11Resource, @ptrCast(self.texture)) });

    var mapped: c.D3D11_MAPPED_SUBRESOURCE = undefined;
    try com.check(com.call(self.context, "Map", .{ resource, 0, c.D3D11_MAP_READ, 0, &mapped }), "Map");
    defer com.call(self.context, "Unmap", .{ resource, 0 });
    const row = self.width * self.bpp;
    const data: [*]const u8 = @ptrCast(mapped.pData.?);
    for (0..self.height) |y| @memcpy(out[y * row ..][0..row], data[y * mapped.RowPitch ..][0..row]);
}
