//! Helpers for calling the C COM interfaces of Direct3D 11 and DXGI.
//!
//! The translated headers expose each interface as a struct with an
//! `lpVtbl` pointer to a table of function pointers, where every
//! function takes the interface itself as its first argument. These
//! helpers make calling those less noisy.
const std = @import("std");

pub const c = @import("d3d11_c");

const log = std.log.scoped(.direct3d11);

pub const Error = error{Direct3DFailed};

/// The return type of `method` on the COM interface pointed to by `Ptr`.
fn MethodReturn(comptime Ptr: type, comptime method: []const u8) type {
    const T = @typeInfo(Ptr).pointer.child;
    const Vtbl = @typeInfo(@FieldType(T, "lpVtbl")).pointer.child;
    const FnPtr = @typeInfo(@FieldType(Vtbl, method)).optional.child;
    return @typeInfo(@typeInfo(FnPtr).pointer.child).@"fn".return_type.?;
}

/// Call `method` on the COM object `obj` with `args`.
pub inline fn call(
    obj: anytype,
    comptime method: []const u8,
    args: anytype,
) MethodReturn(@TypeOf(obj), method) {
    return @call(.auto, @field(obj.lpVtbl.*, method).?, .{obj} ++ args);
}

/// Release a reference to a COM object.
pub inline fn release(obj: anytype) void {
    _ = call(obj, "Release", .{});
}

/// Release a reference to an optional COM object if it is set.
pub inline fn releaseOpt(obj: anytype) void {
    if (obj) |o| release(o);
}

/// Returns an error if the HRESULT indicates a failure, logging the
/// HRESULT along with the given operation name.
pub fn check(hr: c.HRESULT, comptime op: []const u8) Error!void {
    if (hr >= 0) return;
    log.err("{s} failed hr=0x{x:0>8}", .{ op, @as(u32, @bitCast(hr)) });
    return error.Direct3DFailed;
}

/// Query `obj` for the interface `T`, identified by `iid`.
pub fn queryInterface(
    comptime T: type,
    obj: anytype,
    iid: *const c.IID,
) Error!*T {
    var out: ?*anyopaque = null;
    try check(call(obj, "QueryInterface", .{ iid, &out }), "QueryInterface");
    return @ptrCast(@alignCast(out.?));
}

/// Build a GUID from its textual components.
fn guid(
    d1: u32,
    d2: u16,
    d3: u16,
    d4: [8]u8,
) c.GUID {
    return .{ .Data1 = d1, .Data2 = d2, .Data3 = d3, .Data4 = d4 };
}

// The interface IDs we need. MinGW defines these in libdxguid, but we
// define them here so that we don't need to link it.
pub const IID_IDXGIDevice = guid(0x54ec77fa, 0x1377, 0x44e6, .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c });
pub const IID_IDXGIFactory2 = guid(0x50c83a1c, 0xe072, 0x4c48, .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 });
pub const IID_ID3D11Texture2D = guid(0x6f15aaf2, 0xd208, 0x4e89, .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c });
pub const IID_ID3D11Multithread = guid(0x9b7e4e00, 0x342c, 0x4106, .{ 0xa1, 0x9f, 0x4f, 0x27, 0x04, 0xf6, 0x89, 0xf0 });
pub const IID_ID3D11InfoQueue = guid(0x6543dbb6, 0x1b48, 0x42f5, .{ 0xab, 0x82, 0xe9, 0x7e, 0xc7, 0x43, 0x26, 0xf6 });
