//! Graphics API wrapper for Direct3D 11.
//!
//! Each surface renderer has its own ID3D11Device and immediate context,
//! and a DXGI flip model swap chain on the surface's HWND. Frames are
//! rendered into an offscreen target which is copied into the swap
//! chain's back buffer when presented.
pub const Direct3D11 = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(Direct3D11);
const shadertoy = @import("shadertoy.zig");

const com = @import("direct3d11/com.zig");
const c = com.c;
pub const Device = @import("direct3d11/Device.zig");

pub const GraphicsAPI = Direct3D11;
pub const Target = @import("direct3d11/Target.zig");
pub const Frame = @import("direct3d11/Frame.zig");
pub const RenderPass = @import("direct3d11/RenderPass.zig");
pub const Pipeline = @import("direct3d11/Pipeline.zig");
const bufferpkg = @import("direct3d11/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("direct3d11/Sampler.zig");
pub const Texture = @import("direct3d11/Texture.zig");
pub const shaders = @import("direct3d11/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .hlsl;
// The fragCoord for Direct3D shaders is +Y = down.
pub const custom_shader_y_is_down = true;

/// Triple buffering.
pub const swap_chain_count = 3;

/// The number of buffers in the DXGI swap chain. Flip model swap chains
/// require at least two.
const dxgi_buffer_count = 2;

/// The format of the DXGI swap chain buffers. Flip model swap chains
/// can't use sRGB formats, but our targets can be sRGB since copying
/// between formats in the same family copies the raw bytes.
const swap_chain_format = c.DXGI_FORMAT_B8G8R8A8_UNORM;

const log = std.log.scoped(.direct3d11);

/// The shared render device.
device: *const Device,

/// Our own Direct3D device and immediate context.
d3d: *c.ID3D11Device,
context: *c.ID3D11DeviceContext,

/// The window we present to, and its swap chain.
hwnd: c.HWND,
swap_chain: *c.IDXGISwapChain1,

/// The current size of the swap chain buffers.
swap_chain_width: u32,
swap_chain_height: u32,

/// Fixed function state shared by all render passes.
rasterizer: *c.ID3D11RasterizerState,
default_sampler: Sampler,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !Direct3D11 {
    _ = alloc;

    const hwnd: c.HWND = switch (apprt.runtime) {
        apprt.embedded => switch (opts.rt_surface.platform) {
            .windows => |v| @ptrCast(@alignCast(v.hwnd)),
            else => return error.UnsupportedPlatform,
        },

        apprt.win32 => @ptrCast(@alignCast(opts.rt_surface.hwnd)),

        else => return error.UnsupportedApprt,
    };

    const created = try device.createDevice();
    errdefer {
        com.release(created.context);
        com.release(created.device);
    }

    // The immediate context isn't thread-safe. Nearly all of our work
    // happens on the render thread, but some resources are initialized
    // elsewhere, so we have Direct3D protect the context for us. This is
    // uncontended so it costs very little.
    if (com.queryInterface(
        c.ID3D11Multithread,
        created.context,
        &com.IID_ID3D11Multithread,
    )) |mt| {
        defer com.release(mt);
        _ = com.call(mt, "SetMultithreadProtected", .{c.TRUE});
    } else |err| {
        log.warn("unable to enable multithread protection err={}", .{err});
    }

    const size = clientSize(hwnd);
    const swap_chain = try createSwapChain(created.device, hwnd, size.width, size.height);
    errdefer com.release(swap_chain);

    var rasterizer: ?*c.ID3D11RasterizerState = null;
    try com.check(com.call(created.device, "CreateRasterizerState", .{
        &c.D3D11_RASTERIZER_DESC{
            .FillMode = c.D3D11_FILL_SOLID,
            .CullMode = c.D3D11_CULL_NONE,
            .FrontCounterClockwise = c.FALSE,
            .DepthBias = 0,
            .DepthBiasClamp = 0,
            .SlopeScaledDepthBias = 0,
            // We don't use depth, and some of our vertices are
            // outside of the [0, 1] depth range.
            .DepthClipEnable = c.FALSE,
            .ScissorEnable = c.FALSE,
            .MultisampleEnable = c.FALSE,
            .AntialiasedLineEnable = c.FALSE,
        },
        &rasterizer,
    }), "ID3D11Device::CreateRasterizerState");
    errdefer com.releaseOpt(rasterizer);

    const default_sampler = try Sampler.init(.{
        .device = created.device,
        .filter = c.D3D11_FILTER_MIN_MAG_MIP_LINEAR,
        .address_u = c.D3D11_TEXTURE_ADDRESS_CLAMP,
        .address_v = c.D3D11_TEXTURE_ADDRESS_CLAMP,
    });
    errdefer default_sampler.deinit();

    return .{
        .device = device,
        .d3d = created.device,
        .context = created.context,
        .hwnd = hwnd,
        .swap_chain = swap_chain,
        .swap_chain_width = size.width,
        .swap_chain_height = size.height,
        .rasterizer = rasterizer.?,
        .default_sampler = default_sampler,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *Direct3D11) void {
    self.default_sampler.deinit();
    com.release(self.rasterizer);
    com.release(self.swap_chain);
    com.call(self.context, "ClearState", .{});
    com.release(self.context);
    com.release(self.d3d);
    self.* = undefined;
}

/// Create a flip model swap chain for the given window.
fn createSwapChain(
    device: *c.ID3D11Device,
    hwnd: c.HWND,
    width: u32,
    height: u32,
) !*c.IDXGISwapChain1 {
    // The swap chain must be created by the factory that created the
    // adapter of our device, so we walk up to it from the device.
    const dxgi_device = try com.queryInterface(c.IDXGIDevice, device, &com.IID_IDXGIDevice);
    defer com.release(dxgi_device);

    var adapter: ?*c.IDXGIAdapter = null;
    try com.check(
        com.call(dxgi_device, "GetAdapter", .{&adapter}),
        "IDXGIDevice::GetAdapter",
    );
    defer com.releaseOpt(adapter);

    var factory_ptr: ?*anyopaque = null;
    try com.check(
        com.call(adapter.?, "GetParent", .{ &com.IID_IDXGIFactory2, &factory_ptr }),
        "IDXGIAdapter::GetParent",
    );
    const factory: *c.IDXGIFactory2 = @ptrCast(@alignCast(factory_ptr.?));
    defer com.release(factory);

    const desc: c.DXGI_SWAP_CHAIN_DESC1 = .{
        .Width = width,
        .Height = height,
        .Format = swap_chain_format,
        .Stereo = c.FALSE,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = dxgi_buffer_count,
        .Scaling = c.DXGI_SCALING_NONE,
        .SwapEffect = c.DXGI_SWAP_EFFECT_FLIP_DISCARD,
        .AlphaMode = c.DXGI_ALPHA_MODE_IGNORE,
        .Flags = 0,
    };

    var swap_chain: ?*c.IDXGISwapChain1 = null;
    try com.check(com.call(factory, "CreateSwapChainForHwnd", .{
        @as(*c.IUnknown, @ptrCast(device)),
        hwnd,
        &desc,
        null,
        null,
        &swap_chain,
    }), "IDXGIFactory2::CreateSwapChainForHwnd");

    // We don't support DXGI's alt+enter fullscreen handling,
    // the apprt is responsible for fullscreen.
    _ = com.call(factory, "MakeWindowAssociation", .{
        hwnd,
        @as(c.UINT, c.DXGI_MWA_NO_ALT_ENTER),
    });

    return swap_chain.?;
}

/// Get the size of the client area of a window, at least 1x1.
fn clientSize(hwnd: c.HWND) struct { width: u32, height: u32 } {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(hwnd, &rect) == 0) return .{ .width = 1, .height = 1 };
    return .{
        .width = @intCast(@max(1, rect.right - rect.left)),
        .height = @intCast(@max(1, rect.bottom - rect.top)),
    };
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for Direct3D 11.
pub fn drawFrameStart(self: *Direct3D11) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
///
/// Right now there's nothing we need to do for Direct3D 11.
pub fn drawFrameEnd(self: *Direct3D11) void {
    _ = self;
}

pub fn initShaders(
    self: *const Direct3D11,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    return try shaders.Shaders.init(
        alloc,
        self.d3d,
        custom_shaders,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const Direct3D11) !struct { width: u32, height: u32 } {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &rect) == 0) return .{ .width = 0, .height = 0 };

    // We need to clamp our runtime surface size to the maximum
    // possible texture size since we can't create a screen buffer (texture)
    // larger than that.
    return .{
        .width = @min(
            @as(u32, @intCast(@max(0, rect.right - rect.left))),
            self.device.max_texture_size,
        ),
        .height = @min(
            @as(u32, @intCast(@max(0, rect.bottom - rect.top))),
            self.device.max_texture_size,
        ),
    };
}

/// The format of our render targets.
fn targetFormat(self: *const Direct3D11) c.DXGI_FORMAT {
    // Using an `*_SRGB` format makes Direct3D gamma encode the pixels
    // written to it *after* blending, which means we get linear alpha
    // blending rather than gamma-incorrect blending.
    return if (self.blending.isLinear())
        c.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB
    else
        c.DXGI_FORMAT_B8G8R8A8_UNORM;
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const Direct3D11, width: usize, height: usize) !Target {
    return Target.init(.{
        .device = self.d3d,
        .width = width,
        .height = height,
        .format = self.targetFormat(),
    });
}

/// Present the provided target.
pub fn present(self: *Direct3D11, target: Target) !void {
    const width: u32 = @intCast(target.width);
    const height: u32 = @intCast(target.height);

    // Resize the swap chain buffers to match our target if needed.
    if (width != self.swap_chain_width or height != self.swap_chain_height) {
        try com.check(com.call(self.swap_chain, "ResizeBuffers", .{
            0, // keep the buffer count
            width,
            height,
            c.DXGI_FORMAT_UNKNOWN, // keep the format
            0,
        }), "IDXGISwapChain::ResizeBuffers");
        self.swap_chain_width = width;
        self.swap_chain_height = height;
    }

    // Copy our target into the back buffer.
    {
        var back_buffer_ptr: ?*anyopaque = null;
        try com.check(com.call(self.swap_chain, "GetBuffer", .{
            0,
            &com.IID_ID3D11Texture2D,
            &back_buffer_ptr,
        }), "IDXGISwapChain::GetBuffer");
        const back_buffer: *c.ID3D11Texture2D = @ptrCast(@alignCast(back_buffer_ptr.?));
        defer com.release(back_buffer);

        com.call(self.context, "CopyResource", .{
            @as(*c.ID3D11Resource, @ptrCast(back_buffer)),
            @as(*c.ID3D11Resource, @ptrCast(target.texture)),
        });
    }

    // Present, waiting for vsync. This can return success codes such as
    // DXGI_STATUS_OCCLUDED which we're fine to ignore.
    try com.check(
        com.call(self.swap_chain, "Present", .{ 1, 0 }),
        "IDXGISwapChain::Present",
    );
}

/// Returns the options to use when constructing buffers.
inline fn bufferOptions(self: Direct3D11, kind: bufferpkg.Options.Kind) bufferpkg.Options {
    return .{
        .device = self.d3d,
        .context = self.context,
        .kind = kind,
    };
}

pub inline fn uniformBufferOptions(self: Direct3D11) bufferpkg.Options {
    return self.bufferOptions(.constant);
}

pub inline fn fgBufferOptions(self: Direct3D11) bufferpkg.Options {
    return self.bufferOptions(.vertex);
}

pub inline fn bgBufferOptions(self: Direct3D11) bufferpkg.Options {
    return self.bufferOptions(.structured);
}

pub inline fn imageBufferOptions(self: Direct3D11) bufferpkg.Options {
    return self.bufferOptions(.vertex);
}

pub inline fn bgImageBufferOptions(self: Direct3D11) bufferpkg.Options {
    return self.bufferOptions(.vertex);
}

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: Direct3D11) Texture.Options {
    return .{
        .device = self.d3d,
        .context = self.context,
        .format = self.targetFormat(),
        // textureOptions is currently only used for custom shaders,
        // which require both the shader read (for when multiple shaders
        // are chained) and render target (for the final output) usage.
        .render_target = true,
    };
}

pub inline fn samplerOptions(self: Direct3D11) Sampler.Options {
    return .{
        .device = self.d3d,

        // These parameters match Shadertoy behaviors.
        .filter = c.D3D11_FILTER_MIN_MAG_MIP_LINEAR,
        .address_u = c.D3D11_TEXTURE_ADDRESS_CLAMP,
        .address_v = c.D3D11_TEXTURE_ADDRESS_CLAMP,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toFormat(
        self: ImageTextureFormat,
        srgb: bool,
    ) c.DXGI_FORMAT {
        return switch (self) {
            // DXGI has no sRGB single channel format.
            .gray => c.DXGI_FORMAT_R8_UNORM,
            .rgba => if (srgb) c.DXGI_FORMAT_R8G8B8A8_UNORM_SRGB else c.DXGI_FORMAT_R8G8B8A8_UNORM,
            .bgra => if (srgb) c.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB else c.DXGI_FORMAT_B8G8R8A8_UNORM,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: Direct3D11,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .device = self.d3d,
        .context = self.context,
        .format = format.toFormat(srgb),
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const Direct3D11,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const format: c.DXGI_FORMAT = switch (atlas.format) {
        .grayscale => c.DXGI_FORMAT_R8_UNORM,
        .bgra => c.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        else => @panic("unsupported atlas format for Direct3D 11 texture"),
    };

    return try Texture.init(
        .{
            .device = self.d3d,
            .context = self.context,
            .format = format,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const Direct3D11,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    return try Frame.begin(.{
        .context = self.context,
        .rasterizer = self.rasterizer,
        .default_sampler = self.default_sampler.sampler,
    }, renderer, target);
}
