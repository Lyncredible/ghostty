//! The Direct3D 11 device context.
//!
//! This is shared by all surface renderers. It only holds the DXGI
//! adapter we render with; each surface renderer creates its own
//! ID3D11Device and immediate context from it. Separate devices keep
//! surfaces from serializing on a shared immediate context (including
//! while one of them waits for vsync in Present).
const Device = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const com = @import("com.zig");
const c = com.c;

const log = std.log.scoped(.direct3d11);

/// Options used when creating the Direct3D 11 device.
/// There are currently no options.
pub const Options = struct {};

/// The adapter to create devices on. If null, Direct3D picks the
/// default adapter when creating each device.
adapter: ?*c.IDXGIAdapter1,

/// The maximum 2D texture width and height supported by the device.
max_texture_size: u32 = c.D3D11_REQ_TEXTURE2D_U_OR_V_DIMENSION,

pub fn init(alloc: Allocator, options: Options) !*Device {
    _ = options;
    const self = try alloc.create(Device);
    errdefer alloc.destroy(self);
    self.* = .{ .adapter = chooseAdapter() };
    return self;
}

pub fn deinit(self: *Device, alloc: Allocator) void {
    com.releaseOpt(self.adapter);
    alloc.destroy(self);
}

/// Choose the adapter to render with. This is currently always the
/// first (default) adapter, which is the one Windows considers primary.
fn chooseAdapter() ?*c.IDXGIAdapter1 {
    var factory: ?*c.IDXGIFactory2 = null;
    com.check(c.CreateDXGIFactory1(
        &com.IID_IDXGIFactory2,
        @ptrCast(&factory),
    ), "CreateDXGIFactory1") catch return null;
    defer com.releaseOpt(factory);

    var adapter: ?*c.IDXGIAdapter1 = null;
    com.check(
        com.call(factory.?, "EnumAdapters1", .{ 0, &adapter }),
        "EnumAdapters1",
    ) catch return null;

    var desc: c.DXGI_ADAPTER_DESC1 = undefined;
    if (com.call(adapter.?, "GetDesc1", .{&desc}) >= 0) {
        var buf: [256]u8 = undefined;
        const len = std.unicode.utf16LeToUtf8(
            &buf,
            std.mem.sliceTo(&desc.Description, 0),
        ) catch 0;
        log.info("using adapter name={s}", .{buf[0..len]});
    }

    return adapter;
}

/// Create a new ID3D11Device and its immediate context.
pub fn createDevice(self: *const Device) !struct {
    device: *c.ID3D11Device,
    context: *c.ID3D11DeviceContext,
} {
    const feature_levels = [_]c.D3D_FEATURE_LEVEL{
        c.D3D_FEATURE_LEVEL_11_1,
        c.D3D_FEATURE_LEVEL_11_0,
    };

    const base_flags: c.UINT = c.D3D11_CREATE_DEVICE_BGRA_SUPPORT;

    // The debug layer is only available when the Graphics Tools optional
    // feature is installed, so if creating a debug device fails we just
    // try again without it. It's slow, so we only use it in debug builds
    // (not ReleaseSafe, which is a release configuration).
    const attempts: []const struct { driver: c.D3D_DRIVER_TYPE, flags: c.UINT } =
        if (builtin.mode == .debug) &.{
            .{ .driver = c.D3D_DRIVER_TYPE_HARDWARE, .flags = base_flags | c.D3D11_CREATE_DEVICE_DEBUG },
            .{ .driver = c.D3D_DRIVER_TYPE_HARDWARE, .flags = base_flags },
            .{ .driver = c.D3D_DRIVER_TYPE_WARP, .flags = base_flags },
        } else &.{
            .{ .driver = c.D3D_DRIVER_TYPE_HARDWARE, .flags = base_flags },
            .{ .driver = c.D3D_DRIVER_TYPE_WARP, .flags = base_flags },
        };

    for (attempts) |attempt| {
        // If we were given an adapter, D3D requires the driver type to be
        // unknown. WARP is a software driver with its own adapter.
        const adapter: ?*c.IDXGIAdapter = if (attempt.driver == c.D3D_DRIVER_TYPE_HARDWARE)
            @ptrCast(self.adapter)
        else
            null;
        const driver: c.D3D_DRIVER_TYPE = if (adapter != null) c.D3D_DRIVER_TYPE_UNKNOWN else attempt.driver;

        var device: ?*c.ID3D11Device = null;
        var context: ?*c.ID3D11DeviceContext = null;
        var level: c.D3D_FEATURE_LEVEL = undefined;
        const hr = c.D3D11CreateDevice(
            adapter,
            driver,
            null,
            attempt.flags,
            &feature_levels,
            feature_levels.len,
            c.D3D11_SDK_VERSION,
            &device,
            &level,
            &context,
        );
        if (hr < 0) {
            log.debug(
                "D3D11CreateDevice failed driver={} flags=0x{x} hr=0x{x:0>8}",
                .{ attempt.driver, attempt.flags, @as(u32, @bitCast(hr)) },
            );
            continue;
        }

        log.info("created device driver={} feature_level=0x{x} debug={}", .{
            attempt.driver,
            level,
            attempt.flags & c.D3D11_CREATE_DEVICE_DEBUG != 0,
        });

        return .{ .device = device.?, .context = context.? };
    }

    log.err("unable to create a Direct3D 11 device", .{});
    return error.Direct3DFailed;
}
