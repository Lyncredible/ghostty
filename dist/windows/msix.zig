//! Create or check an MSIX package with the packaging API built into
//! Windows (AppxPackaging), so that no Windows SDK tools are needed.
//!
//! Usage:
//!
//!     zig run dist/windows/msix.zig -lc -lole32 -lshlwapi -lurlmon -- pack <layout-dir> <out.msix>
//!     zig run dist/windows/msix.zig -lc -lole32 -lshlwapi -lurlmon -- check <file.msix>
//!
//! `pack` adds every file in the layout directory, with AppxManifest.xml as
//! the manifest. `check` opens a package with the package reader, which
//! validates its block map and manifest, and prints the package identity.
const std = @import("std");
const windows = std.os.windows;

const HRESULT = i32;
const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

const CLSID_AppxFactory: GUID = .{ .a = 0x5842a140, .b = 0xff9f, .c = 0x4166, .d = .{ 0x8f, 0x5c, 0x62, 0xf5, 0xb7, 0xb0, 0xc7, 0x81 } };
const IID_IAppxFactory: GUID = .{ .a = 0xbeb94909, .b = 0xe451, .c = 0x438b, .d = .{ 0xb5, 0xa7, 0xd7, 0x9e, 0x76, 0x7b, 0x75, 0xd8 } };

/// A COM object: a pointer to a table of function pointers, called with
/// the object first. We only declare the methods we use, by index.
const Object = extern struct {
    vtbl: [*]const *const anyopaque,

    fn method(self: *Object, comptime T: type, index: usize) T {
        return @ptrCast(self.vtbl[index]);
    }

    fn release(self: *Object) void {
        _ = self.method(*const fn (*Object) callconv(.winapi) u32, 2)(self);
    }
};

const APPX_PACKAGE_SETTINGS = extern struct {
    force_zip32: i32,
    hash_method: *Object,
};

const APPX_COMPRESSION_OPTION_NORMAL = 1;
const STGM_READ = 0;
const STGM_CREATE = 0x1000;
const STGM_WRITE = 1;

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, context: u32, iid: *const GUID, out: *?*Object) callconv(.winapi) HRESULT;
extern "shlwapi" fn SHCreateStreamOnFileEx(file: [*:0]const u16, mode: u32, attributes: u32, create: i32, template: ?*Object, out: *?*Object) callconv(.winapi) HRESULT;
extern "urlmon" fn CreateUri(uri: [*:0]const u16, flags: u32, reserved: usize, out: *?*Object) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(ptr: ?*anyopaque) callconv(.winapi) void;

fn check(hr: HRESULT, what: []const u8) !void {
    if (hr >= 0) return;
    std.debug.print("{s} failed: 0x{x:0>8}\n", .{ what, @as(u32, @bitCast(hr)) });
    return error.ComFailed;
}

fn wide(alloc: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(alloc, s);
}

fn openStream(alloc: std.mem.Allocator, path: []const u8, mode: u32, create: bool) !*Object {
    var stream: ?*Object = null;
    try check(SHCreateStreamOnFileEx(try wide(alloc, path), mode, 0x80, @intFromBool(create), null, &stream), "SHCreateStreamOnFileEx");
    return stream.?;
}

/// The MIME type for a file in the package.
fn contentType(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    const types = [_]struct { []const u8, []const u8 }{
        .{ ".exe", "application/x-msdownload" },
        .{ ".dll", "application/x-msdownload" },
        .{ ".png", "image/png" },
        .{ ".txt", "text/plain" },
        .{ ".ps1", "text/plain" },
        .{ ".xml", "application/xml" },
    };
    for (types) |t| if (std.ascii.eqlIgnoreCase(ext, t[0])) return t[1];
    return "application/octet-stream";
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 3) return error.InvalidArguments;

    try check(CoInitializeEx(null, 0x2), "CoInitializeEx");
    var factory: ?*Object = null;
    try check(CoCreateInstance(&CLSID_AppxFactory, null, 1, &IID_IAppxFactory, &factory), "CoCreateInstance(AppxFactory)");
    defer factory.?.release();

    if (std.mem.eql(u8, args[1], "check")) {
        const input = try openStream(alloc, args[2], STGM_READ, false);
        defer input.release();
        // IAppxFactory::CreatePackageReader (index 4), which validates the
        // package as it opens it.
        var reader: ?*Object = null;
        try check(factory.?.method(*const fn (*Object, *Object, *?*Object) callconv(.winapi) HRESULT, 4)(factory.?, input, &reader), "CreatePackageReader");
        defer reader.?.release();
        // IAppxPackageReader::GetManifest (index 7), then
        // IAppxManifestReader::GetPackageId (index 3) and
        // IAppxManifestPackageId::GetPackageFullName (index 9).
        var manifest: ?*Object = null;
        try check(reader.?.method(*const fn (*Object, *?*Object) callconv(.winapi) HRESULT, 7)(reader.?, &manifest), "GetManifest");
        defer manifest.?.release();
        var id: ?*Object = null;
        try check(manifest.?.method(*const fn (*Object, *?*Object) callconv(.winapi) HRESULT, 3)(manifest.?, &id), "GetPackageId");
        defer id.?.release();
        var full_name: ?[*:0]u16 = null;
        try check(id.?.method(*const fn (*Object, *?[*:0]u16) callconv(.winapi) HRESULT, 9)(id.?, &full_name), "GetPackageFullName");
        defer CoTaskMemFree(full_name);
        const name = try std.unicode.wtf16LeToWtf8Alloc(alloc, std.mem.sliceTo(full_name.?, 0));
        std.debug.print("valid package: {s}\n", .{name});
        return;
    }

    if (!std.mem.eql(u8, args[1], "pack") or args.len < 4) return error.InvalidArguments;
    const layout = args[2];

    const output = try openStream(alloc, args[3], STGM_CREATE | STGM_WRITE, true);
    defer output.release();

    var sha256: ?*Object = null;
    try check(CreateUri(try wide(alloc, "http://www.w3.org/2001/04/xmlenc#sha256"), 0, 0, &sha256), "CreateUri");
    defer sha256.?.release();
    var settings: APPX_PACKAGE_SETTINGS = .{ .force_zip32 = 1, .hash_method = sha256.? };

    // IAppxFactory::CreatePackageWriter (index 3).
    var writer: ?*Object = null;
    try check(factory.?.method(*const fn (*Object, *Object, *APPX_PACKAGE_SETTINGS, *?*Object) callconv(.winapi) HRESULT, 3)(factory.?, output, &settings, &writer), "CreatePackageWriter");
    defer writer.?.release();
    const addPayloadFile = writer.?.method(*const fn (*Object, [*:0]const u16, [*:0]const u16, u32, *Object) callconv(.winapi) HRESULT, 3);
    const close = writer.?.method(*const fn (*Object, *Object) callconv(.winapi) HRESULT, 4);

    var dir = try std.Io.Dir.cwd().openDir(io, layout, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.ascii.eqlIgnoreCase(entry.path, "AppxManifest.xml")) continue;
        const name = try alloc.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, name, '/', '\\');
        const file = try openStream(alloc, try std.fs.path.join(alloc, &.{ layout, name }), STGM_READ, false);
        defer file.release();
        try check(addPayloadFile(writer.?, try wide(alloc, name), try wide(alloc, contentType(name)), APPX_COMPRESSION_OPTION_NORMAL, file), "AddPayloadFile");
    }

    const manifest = try openStream(alloc, try std.fs.path.join(alloc, &.{ layout, "AppxManifest.xml" }), STGM_READ, false);
    defer manifest.release();
    try check(close(writer.?, manifest), "Close");
    std.debug.print("wrote {s}\n", .{args[3]});
}
