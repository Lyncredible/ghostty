//! Build-time tool: compiles the translations in `po/` into the catalog
//! that the Windows app embeds, since Windows has no `msgfmt` to make
//! gettext's `.mo` files with and no libintl to read them. The format is
//! in src/os/i18n_catalog.zig, which also reads it at runtime.
//!
//! Usage: po_compile <out-file> (<locale> <file.po>)...
const std = @import("std");
const catalog = @import("i18n_catalog");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 2 or args.len % 2 != 0) return error.InvalidArguments;

    var sources: std.ArrayList(catalog.Source) = .empty;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        const po = try std.Io.Dir.cwd().readFileAlloc(io, args[i + 1], alloc, .limited(16 << 20));
        // Check each file by itself, to name the one that's wrong.
        if (catalog.parse(alloc, po)) |_| {} else |err| {
            std.debug.print("{s}: {}\n", .{ args[i + 1], err });
            return err;
        }
        try sources.append(alloc, .{ .locale = args[i], .po = po });
    }

    const blob = try catalog.compile(alloc, sources.items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = blob });
}
