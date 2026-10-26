//! Compile the built-in HLSL shaders of the Direct3D 11 renderer to
//! bytecode at build time, so that the renderer doesn't spend time
//! compiling them when it starts. This uses D3DCompile from
//! d3dcompiler_47.dll, so it only runs on Windows build hosts; elsewhere
//! the renderer compiles the shaders at runtime.
//!
//! Usage: hlsl_compile <source.hlsl> <out-dir> <debug: 0|1> <entry>...
//!
//! Each entry is compiled with the vs_5_0 profile if its name ends with
//! "_vertex" and ps_5_0 otherwise, to <out-dir>/<entry>.dxbc. The flags
//! must match `compile` in src/renderer/direct3d11/shaders.zig.
const std = @import("std");

const ID3DBlob = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3DBlob) callconv(.winapi) u32,
        GetBufferPointer: *const fn (*ID3DBlob) callconv(.winapi) [*]const u8,
        GetBufferSize: *const fn (*ID3DBlob) callconv(.winapi) usize,
    },

    fn bytes(self: *ID3DBlob) []const u8 {
        return self.vtbl.GetBufferPointer(self)[0..self.vtbl.GetBufferSize(self)];
    }
};

extern "d3dcompiler_47" fn D3DCompile(
    src: [*]const u8,
    src_len: usize,
    name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*anyopaque,
    entry: [*:0]const u8,
    target: [*:0]const u8,
    flags1: u32,
    flags2: u32,
    code: *?*ID3DBlob,
    errors: *?*ID3DBlob,
) callconv(.winapi) i32;

const D3DCOMPILE_DEBUG: u32 = 1 << 0;
const D3DCOMPILE_SKIP_OPTIMIZATION: u32 = 1 << 2;
const D3DCOMPILE_ENABLE_STRICTNESS: u32 = 1 << 11;
const D3DCOMPILE_OPTIMIZATION_LEVEL3: u32 = 1 << 15;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 4) return error.InvalidArguments;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, args[1], alloc, .limited(1 << 20));
    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(io, args[2], .{});
    defer out_dir.close(io);
    const debug = std.mem.eql(u8, args[3], "1");
    const flags: u32 = D3DCOMPILE_ENABLE_STRICTNESS | if (debug)
        D3DCOMPILE_DEBUG | D3DCOMPILE_SKIP_OPTIMIZATION
    else
        D3DCOMPILE_OPTIMIZATION_LEVEL3;

    for (args[4..]) |entry| {
        const entry_z = try alloc.dupeSentinel(u8, entry, 0);
        const profile: [:0]const u8 = if (std.mem.endsWith(u8, entry, "_vertex")) "vs_5_0" else "ps_5_0";
        var code: ?*ID3DBlob = null;
        var errors: ?*ID3DBlob = null;
        const hr = D3DCompile(source.ptr, source.len, "shaders.hlsl", null, null, entry_z, profile, flags, 0, &code, &errors);
        if (errors) |e| {
            std.debug.print("{s}: {s}\n", .{ entry, e.bytes() });
            _ = e.vtbl.Release(e);
        }
        if (hr < 0) {
            std.debug.print("D3DCompile failed for {s}: 0x{x:0>8}\n", .{ entry, @as(u32, @bitCast(hr)) });
            return error.CompileFailed;
        }

        const blob = code.?;
        defer _ = blob.vtbl.Release(blob);
        const name = try std.fmt.allocPrint(alloc, "{s}.dxbc", .{entry});
        try out_dir.writeFile(io, .{ .sub_path = name, .data = blob.bytes() });
    }
}
