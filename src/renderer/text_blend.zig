//! DirectWrite's text blending parameters for `alpha-blending = directwrite`.
//!
//! Windows doesn't blend a grayscale glyph mask as plain coverage: it
//! boosts the contrast of the mask (less for light text) and corrects it
//! for the text color's intensity with the gamma chosen in the "Adjust
//! ClearType text" tool. The text shaders do the same with the values
//! here, following Windows Terminal's `dwrite_helpers` (MIT licensed).
const std = @import("std");
const builtin = @import("builtin");
const font = @import("../font/main.zig");

const log = std.log.scoped(.renderer);

/// Whether DirectWrite is linked in, to read the system's parameters.
const has_dwrite = builtin.os.tag == .windows and
    font.options.backend == .freetype_windows;

const c = if (has_dwrite) @import("dwrite_c") else struct {};

/// The values the shaders need.
pub const Params = struct {
    /// DirectWrite's grayscale enhanced contrast.
    contrast: f32,

    /// The four alpha correction constants for the gamma.
    gamma_ratios: [4]f32,

    /// Windows' defaults: gamma 1.8 and a grayscale contrast of 1.
    pub const default: Params = .{
        .contrast = 1.0,
        .gamma_ratios = gammaRatios(1.8),
    };

    /// The system's rendering parameters, or the defaults if they can't
    /// be read (or on other systems).
    pub fn system() Params {
        if (comptime !has_dwrite) return default;
        return querySystem() catch |err| {
            log.warn("couldn't read DirectWrite's rendering parameters err={}", .{err});
            return default;
        };
    }
};

/// The alpha correction constants for a gamma between 1.0 and 2.2, from
/// the table DirectWrite uses for gamma-incorrect (sRGB space) blending.
pub fn gammaRatios(gamma: f32) [4]f32 {
    const table = [13][4]f32{
        .{ 0.0000, 0.0000, 0.0000, 0.0000 }, // 1.0
        .{ 0.0166, -0.0807, 0.2227, -0.0751 }, // 1.1
        .{ 0.0350, -0.1760, 0.4325, -0.1370 }, // 1.2
        .{ 0.0543, -0.2821, 0.6302, -0.1876 }, // 1.3
        .{ 0.0739, -0.3963, 0.8167, -0.2287 }, // 1.4
        .{ 0.0933, -0.5161, 0.9926, -0.2616 }, // 1.5
        .{ 0.1121, -0.6395, 1.1588, -0.2877 }, // 1.6
        .{ 0.1300, -0.7649, 1.3159, -0.3080 }, // 1.7
        .{ 0.1469, -0.8911, 1.4644, -0.3234 }, // 1.8
        .{ 0.1627, -1.0170, 1.6051, -0.3347 }, // 1.9
        .{ 0.1773, -1.1420, 1.7385, -0.3426 }, // 2.0
        .{ 0.1908, -1.2652, 1.8650, -0.3476 }, // 2.1
        .{ 0.2031, -1.3864, 1.9851, -0.3501 }, // 2.2
    };
    // The table's values are /4 of the constants, scaled for 8-bit
    // values in the first and third, and for 16-bit in the second
    // and fourth, as DirectWrite uses them.
    const norm13: f32 = @floatCast(@as(f64, 0x10000) / (255 * 255));
    const norm24: f32 = @floatCast(@as(f64, 0x100) / 255);
    const scaled = if (std.math.isNan(gamma)) 18 else gamma * 10 + 0.5;
    const index: usize = @intFromFloat(std.math.clamp(@floor(scaled), 10, 22) - 10);
    const r = table[index];
    return .{ norm13 * r[0], norm24 * r[1], norm13 * r[2], norm24 * r[3] };
}

fn querySystem() error{DirectWriteFailed}!Params {
    var factory: ?*c.IDWriteFactory = null;
    try check(c.DWriteCreateFactory(
        c.DWRITE_FACTORY_TYPE_SHARED,
        &IID_IDWriteFactory,
        @ptrCast(&factory),
    ));
    defer _ = factory.?.lpVtbl.*.Release.?(factory.?);

    var params: ?*c.IDWriteRenderingParams = null;
    try check(factory.?.lpVtbl.*.CreateRenderingParams.?(factory.?, &params));
    defer _ = params.?.lpVtbl.*.Release.?(params.?);

    const gamma = params.?.lpVtbl.*.GetGamma.?(params.?);

    // The grayscale contrast is in IDWriteRenderingParams1 (Windows 8);
    // the plain enhanced contrast is ClearType's.
    var params1: ?*c.IDWriteRenderingParams1 = null;
    const contrast: f32 = if (params.?.lpVtbl.*.QueryInterface.?(
        params.?,
        &IID_IDWriteRenderingParams1,
        @ptrCast(&params1),
    ) >= 0) contrast: {
        defer _ = params1.?.lpVtbl.*.Release.?(params1.?);
        break :contrast params1.?.lpVtbl.*.GetGrayscaleEnhancedContrast.?(params1.?);
    } else params.?.lpVtbl.*.GetEnhancedContrast.?(params.?);

    log.debug("DirectWrite rendering parameters gamma={d} grayscale contrast={d}", .{ gamma, contrast });
    return .{
        .contrast = std.math.clamp(contrast, 0, 10),
        .gamma_ratios = gammaRatios(gamma),
    };
}

fn check(hr: anytype) error{DirectWriteFailed}!void {
    if (hr < 0) return error.DirectWriteFailed;
}

const IID_IDWriteFactory = if (has_dwrite) guid(0xb859ee5a, 0xd838, 0x4b5b, .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 }) else {};
const IID_IDWriteRenderingParams1 = if (has_dwrite) guid(0x94413cf4, 0xa6fc, 0x4248, .{ 0x8b, 0x50, 0x66, 0x74, 0x34, 0x8f, 0xca, 0xd3 }) else {};

fn guid(a: u32, b: u16, d: u16, e: [8]u8) c.IID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = d, .Data4 = e };
}

test "gamma ratios match DirectWrite's 1.8 defaults" {
    // The values Windows Terminal documents for the default gamma.
    const r = gammaRatios(1.8);
    const expected = [4]f32{ 0.148054421, -0.894594550, 1.47590804, -0.324668258 };
    for (r, expected) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-6);
}

test "gamma ratios clamp to the table" {
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, gammaRatios(0.5));
    try std.testing.expectEqual(gammaRatios(2.2), gammaRatios(3.0));
    try std.testing.expectEqual(gammaRatios(1.8), gammaRatios(std.math.nan(f32)));
}

test "system parameters are in range" {
    const p = Params.system();
    try std.testing.expect(p.contrast >= 0 and p.contrast <= 10);
}
