//! Wrapper for handling samplers.
const Self = @This();

const std = @import("std");

const com = @import("com.zig");
const c = com.c;

const log = std.log.scoped(.direct3d11);

/// Options for initializing a sampler.
pub const Options = struct {
    device: *c.ID3D11Device,
    filter: c.D3D11_FILTER,
    address_u: c.D3D11_TEXTURE_ADDRESS_MODE,
    address_v: c.D3D11_TEXTURE_ADDRESS_MODE,
};

/// The underlying sampler state.
sampler: *c.ID3D11SamplerState,

pub const Error = error{
    /// A Direct3D API call failed.
    Direct3DFailed,
};

/// Initialize a sampler
pub fn init(
    opts: Options,
) Error!Self {
    const desc: c.D3D11_SAMPLER_DESC = .{
        .Filter = opts.filter,
        .AddressU = opts.address_u,
        .AddressV = opts.address_v,
        .AddressW = c.D3D11_TEXTURE_ADDRESS_CLAMP,
        .MipLODBias = 0,
        .MaxAnisotropy = 1,
        .ComparisonFunc = c.D3D11_COMPARISON_NEVER,
        .BorderColor = .{ 0, 0, 0, 0 },
        .MinLOD = 0,
        .MaxLOD = c.D3D11_FLOAT32_MAX,
    };

    var sampler: ?*c.ID3D11SamplerState = null;
    try com.check(
        com.call(opts.device, "CreateSamplerState", .{ &desc, &sampler }),
        "ID3D11Device::CreateSamplerState",
    );

    return .{ .sampler = sampler.? };
}

pub fn deinit(self: Self) void {
    com.release(self.sampler);
}
