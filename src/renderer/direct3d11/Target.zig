//! Represents a render target.
//!
//! In this case, a render target is an offscreen texture which the
//! renderer draws into. Presenting a target copies it into the swap
//! chain's back buffer.
const Self = @This();

const std = @import("std");

const com = @import("com.zig");
const c = com.c;

const log = std.log.scoped(.direct3d11);

/// Options for initializing a Target
pub const Options = struct {
    device: *c.ID3D11Device,

    width: usize,
    height: usize,

    format: c.DXGI_FORMAT,
};

/// The texture we render into.
texture: *c.ID3D11Texture2D,

/// The view used to render to the texture.
rtv: *c.ID3D11RenderTargetView,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    const desc: c.D3D11_TEXTURE2D_DESC = .{
        .Width = @intCast(opts.width),
        .Height = @intCast(opts.height),
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = opts.format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = c.D3D11_USAGE_DEFAULT,
        .BindFlags = c.D3D11_BIND_RENDER_TARGET,
        .CPUAccessFlags = 0,
        .MiscFlags = 0,
    };

    var texture: ?*c.ID3D11Texture2D = null;
    try com.check(
        com.call(opts.device, "CreateTexture2D", .{ &desc, null, &texture }),
        "ID3D11Device::CreateTexture2D",
    );
    errdefer com.releaseOpt(texture);

    var rtv: ?*c.ID3D11RenderTargetView = null;
    try com.check(com.call(opts.device, "CreateRenderTargetView", .{
        @as(*c.ID3D11Resource, @ptrCast(texture.?)),
        null,
        &rtv,
    }), "ID3D11Device::CreateRenderTargetView");

    return .{
        .texture = texture.?,
        .rtv = rtv.?,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    com.release(self.rtv);
    com.release(self.texture);
}
