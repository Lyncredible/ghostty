//! Glyph rasterization with DirectWrite, for text that looks like the rest
//! of Windows. FreeType still loads the face, measures it and shapes with
//! HarfBuzz; this only draws the coverage mask of an outline glyph from
//! the same font data, with the same placement that FreeType would get.
//!
//! The font data comes from FreeType (the whole font file, which works for
//! faces loaded from memory too, such as the embedded fonts) and is loaded
//! into DirectWrite with its in-memory font file loader. Variable fonts get
//! FreeType's current design coordinates.
const std = @import("std");
const Allocator = std.mem.Allocator;
const freetype = @import("freetype");

const c = @import("dwrite_c");

const log = std.log.scoped(.font_face);

pub const Error = error{DirectWriteFailed} || Allocator.Error;

/// A transform from a glyph's outline, in pixels with the origin on the
/// baseline and y going up (as FreeType has it), to where it's drawn:
/// `x' = xx * x + xy * y + dx` and `y' = yy * y + dy`, also y going up.
pub const Transform = struct {
    xx: f64 = 1,
    xy: f64 = 0,
    yy: f64 = 1,
    dx: f64 = 0,
    dy: f64 = 0,
};

/// An 8-bit coverage mask, with the position of its top left pixel
/// relative to the origin: `left` to the right and `top` up, like
/// FreeType's `bitmap_left` and `bitmap_top`. Owned by the caller.
pub const Bitmap = struct {
    data: []u8,
    width: u32,
    height: u32,
    left: i32,
    top: i32,

    pub fn deinit(self: *Bitmap, alloc: Allocator) void {
        alloc.free(self.data);
        self.* = undefined;
    }
};

pub const Rasterizer = struct {
    factory: *c.IDWriteFactory6,
    loader: *c.IDWriteInMemoryFontFileLoader,
    resource: *c.IDWriteFontResource,
    face: *c.IDWriteFontFace5,

    /// The design coordinates the face was made with, to notice when
    /// FreeType's change.
    coords: [max_axes]freetype.c.FT_Fixed = undefined,
    coords_len: usize = 0,

    const max_axes = 32;

    /// Load the font data of a FreeType face into DirectWrite.
    pub fn init(alloc: Allocator, ft: freetype.Face) Error!Rasterizer {
        // Tag 0 is the whole font file (all of a collection).
        var len: c_ulong = 0;
        if (freetype.c.FT_Load_Sfnt_Table(ft.handle, 0, 0, null, &len) != 0 or len == 0)
            return error.DirectWriteFailed;
        const data = try alloc.alloc(u8, len);
        defer alloc.free(data);
        if (freetype.c.FT_Load_Sfnt_Table(ft.handle, 0, 0, data.ptr, &len) != 0)
            return error.DirectWriteFailed;

        var factory: ?*c.IDWriteFactory6 = null;
        try check(c.DWriteCreateFactory(
            c.DWRITE_FACTORY_TYPE_SHARED,
            &IID_IDWriteFactory6,
            @ptrCast(&factory),
        ));
        errdefer release(factory.?);

        var loader: ?*c.IDWriteInMemoryFontFileLoader = null;
        try check(call(factory.?, "CreateInMemoryFontFileLoader", .{&loader}));
        errdefer release(loader.?);
        try check(call(factory.?, "RegisterFontFileLoader", .{@as(*c.IDWriteFontFileLoader, @ptrCast(loader.?))}));
        errdefer _ = call(factory.?, "UnregisterFontFileLoader", .{@as(*c.IDWriteFontFileLoader, @ptrCast(loader.?))});

        // With no owner, the loader keeps a copy of the data.
        var file: ?*c.IDWriteFontFile = null;
        try check(call(loader.?, "CreateInMemoryFontFileReference", .{
            @as(*c.IDWriteFactory, @ptrCast(factory.?)),
            @as(*const anyopaque, data.ptr),
            @as(c.UINT32, @intCast(len)),
            @as(?*c.IUnknown, null),
            &file,
        }));
        defer release(file.?);

        // The low 16 bits are the face's index in a collection; the rest
        // pick a named instance, which FreeType's coordinates cover.
        const index: c.UINT32 = @intCast(ft.handle.*.face_index & 0xFFFF);
        var resource: ?*c.IDWriteFontResource = null;
        try check(call(factory.?, "CreateFontResource", .{ file.?, index, &resource }));
        errdefer release(resource.?);

        var result: Rasterizer = .{
            .factory = factory.?,
            .loader = loader.?,
            .resource = resource.?,
            .face = undefined,
        };
        result.face = try result.createFace(ft);
        return result;
    }

    pub fn deinit(self: *Rasterizer) void {
        release(self.face);
        release(self.resource);
        _ = call(self.factory, "UnregisterFontFileLoader", .{@as(*c.IDWriteFontFileLoader, @ptrCast(self.loader))});
        release(self.loader);
        release(self.factory);
        self.* = undefined;
    }

    /// Make the face again if FreeType's design coordinates changed.
    pub fn syncVariations(self: *Rasterizer, ft: freetype.Face) Error!void {
        var coords: [max_axes]freetype.c.FT_Fixed = undefined;
        const n = designCoordinates(ft, &coords);
        if (n == self.coords_len and
            std.mem.eql(freetype.c.FT_Fixed, coords[0..n], self.coords[0..n])) return;
        const face = try self.createFace(ft);
        release(self.face);
        self.face = face;
    }

    fn createFace(self: *Rasterizer, ft: freetype.Face) Error!*c.IDWriteFontFace5 {
        self.coords_len = designCoordinates(ft, &self.coords);

        var values: [max_axes]c.DWRITE_FONT_AXIS_VALUE = undefined;
        var n: usize = 0;
        if (self.coords_len > 0) {
            const mm = ft.getMMVar() catch return error.DirectWriteFailed;
            defer _ = freetype.c.FT_Done_MM_Var(ft.handle.*.glyph.*.library, mm);
            for (0..self.coords_len) |i| {
                // FreeType's tags are big endian; DirectWrite's are the
                // characters in order in memory.
                const tag: u32 = @intCast(mm.axis[i].tag);
                values[n] = .{
                    .axisTag = @byteSwap(tag),
                    .value = @floatCast(@as(f64, @floatFromInt(self.coords[i])) / 65536.0),
                };
                n += 1;
            }
        }

        var face: ?*c.IDWriteFontFace5 = null;
        try check(call(self.resource, "CreateFontFace", .{
            @as(c.DWRITE_FONT_SIMULATIONS, c.DWRITE_FONT_SIMULATIONS_NONE),
            @as([*c]const c.DWRITE_FONT_AXIS_VALUE, if (n > 0) &values[0] else null),
            @as(c.UINT32, @intCast(n)),
            &face,
        }));
        return face.?;
    }

    /// Draw a glyph at `em_size` pixels with the transform. Null if it
    /// covers no pixels (a space, say).
    pub fn render(
        self: *const Rasterizer,
        alloc: Allocator,
        glyph: u32,
        em_size: f64,
        t: Transform,
    ) Error!?Bitmap {
        const index: c.UINT16 = std.math.cast(c.UINT16, glyph) orelse return error.DirectWriteFailed;
        const advance: c.FLOAT = 0;
        const run: c.DWRITE_GLYPH_RUN = .{
            .fontFace = @ptrCast(self.face),
            .fontEmSize = @floatCast(em_size),
            .glyphCount = 1,
            .glyphIndices = &index,
            .glyphAdvances = &advance,
            .glyphOffsets = null,
            .isSideways = c.FALSE,
            .bidiLevel = 0,
        };

        // DirectWrite's y goes down. For a point (x, -y) of the outline,
        // the result must be (x', -y').
        const matrix: c.DWRITE_MATRIX = .{
            .m11 = @floatCast(t.xx),
            .m12 = 0,
            .m21 = @floatCast(-t.xy),
            .m22 = @floatCast(t.yy),
            .dx = @floatCast(t.dx),
            .dy = @floatCast(-t.dy),
        };

        // Symmetric (vertical and horizontal) antialiasing with DirectWrite's
        // own grid fitting, as text is drawn elsewhere in Windows with
        // grayscale antialiasing.
        var analysis: ?*c.IDWriteGlyphRunAnalysis = null;
        try check(call(self.factory, "IDWriteFactory3_CreateGlyphRunAnalysis", .{
            &run,
            &matrix,
            @as(c.DWRITE_RENDERING_MODE1, c.DWRITE_RENDERING_MODE1_NATURAL_SYMMETRIC),
            @as(c.DWRITE_MEASURING_MODE, c.DWRITE_MEASURING_MODE_NATURAL),
            @as(c.DWRITE_GRID_FIT_MODE, c.DWRITE_GRID_FIT_MODE_DEFAULT),
            @as(c.DWRITE_TEXT_ANTIALIAS_MODE, c.DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE),
            @as(c.FLOAT, 0),
            @as(c.FLOAT, 0),
            &analysis,
        }));
        defer release(analysis.?);

        // With grayscale antialiasing, the "aliased" texture has a byte of
        // coverage per pixel.
        var bounds: c.RECT = undefined;
        try check(call(analysis.?, "GetAlphaTextureBounds", .{
            @as(c.DWRITE_TEXTURE_TYPE, c.DWRITE_TEXTURE_ALIASED_1x1),
            &bounds,
        }));
        if (bounds.right <= bounds.left or bounds.bottom <= bounds.top) return null;

        const width: u32 = @intCast(bounds.right - bounds.left);
        const height: u32 = @intCast(bounds.bottom - bounds.top);
        const data = try alloc.alloc(u8, width * height);
        errdefer alloc.free(data);
        try check(call(analysis.?, "CreateAlphaTexture", .{
            @as(c.DWRITE_TEXTURE_TYPE, c.DWRITE_TEXTURE_ALIASED_1x1),
            &bounds,
            data.ptr,
            @as(c.UINT32, @intCast(data.len)),
        }));

        return .{
            .data = data,
            .width = width,
            .height = height,
            .left = bounds.left,
            .top = -bounds.top,
        };
    }
};

/// FreeType's design coordinates for a variable font, or none.
fn designCoordinates(ft: freetype.Face, buf: *[Rasterizer.max_axes]freetype.c.FT_Fixed) usize {
    if (!ft.hasMultipleMasters()) return 0;
    const mm = ft.getMMVar() catch return 0;
    defer _ = freetype.c.FT_Done_MM_Var(ft.handle.*.glyph.*.library, mm);
    const n = @min(buf.len, mm.num_axis);
    ft.getVarDesignCoordinates(buf[0..n]) catch return 0;
    return n;
}

const IID_IDWriteFactory6 = guid(0xf3744d80, 0x21f7, 0x42eb, .{ 0xb3, 0x5d, 0x99, 0x5b, 0xc7, 0x2f, 0xc2, 0x23 });

fn guid(a: u32, b: u16, d: u16, e: [8]u8) c.IID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = d, .Data4 = e };
}

fn check(hr: c.HRESULT) error{DirectWriteFailed}!void {
    if (hr < 0) {
        log.debug("DirectWrite failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.DirectWriteFailed;
    }
}

inline fn call(obj: anytype, comptime method: []const u8, args: anytype) MethodReturn(@TypeOf(obj), method) {
    return @call(.auto, @field(obj.lpVtbl.*, method).?, .{obj} ++ args);
}

fn MethodReturn(comptime Ptr: type, comptime method: []const u8) type {
    const T = @typeInfo(Ptr).pointer.child;
    const Vtbl = @typeInfo(@FieldType(T, "lpVtbl")).pointer.child;
    const FnPtr = @typeInfo(@FieldType(Vtbl, method)).optional.child;
    return @typeInfo(@typeInfo(FnPtr).pointer.child).@"fn".return_type.?;
}

inline fn release(obj: anytype) void {
    _ = call(obj, "Release", .{});
}

const testing = std.testing;
const embedded = @import("../embedded.zig");

fn testFace(lib: freetype.Library) !freetype.Face {
    const face = try lib.initMemoryFace(embedded.regular, 0);
    errdefer face.deinit();
    try face.setCharSize(0, 12 * 64, 96, 96);
    return face;
}

test "render a glyph like FreeType places it" {
    const alloc = testing.allocator;
    const lib = try freetype.Library.init();
    defer lib.deinit();
    const ft = try testFace(lib);
    defer ft.deinit();

    var r = try Rasterizer.init(alloc, ft);
    defer r.deinit();

    const glyph = freetype.c.FT_Get_Char_Index(ft.handle, 'H');
    try testing.expect(glyph != 0);
    var bitmap = (try r.render(alloc, glyph, 16, .{})).?;
    defer bitmap.deinit(alloc);

    // FreeType's unhinted outline of the same glyph.
    try ft.loadGlyph(glyph, .{ .no_hinting = true });
    const m = ft.handle.*.glyph.*.metrics;
    const ft_left: f64 = @as(f64, @floatFromInt(m.horiBearingX)) / 64;
    const ft_top: f64 = @as(f64, @floatFromInt(m.horiBearingY)) / 64;
    const ft_width: f64 = @as(f64, @floatFromInt(m.width)) / 64;
    const ft_height: f64 = @as(f64, @floatFromInt(m.height)) / 64;

    // The mask covers the outline, give or take a pixel of antialiasing.
    try testing.expectApproxEqAbs(ft_left, @as(f64, @floatFromInt(bitmap.left)), 1.5);
    try testing.expectApproxEqAbs(ft_top, @as(f64, @floatFromInt(bitmap.top)), 1.5);
    try testing.expectApproxEqAbs(ft_width, @as(f64, @floatFromInt(bitmap.width)), 2.5);
    try testing.expectApproxEqAbs(ft_height, @as(f64, @floatFromInt(bitmap.height)), 2.5);

    // An H's stems are fully covered somewhere in its middle row.
    const row = bitmap.data[(bitmap.height / 2) * bitmap.width ..][0..bitmap.width];
    try testing.expect(std.mem.max(u8, row) == 255);
}

test "transform scales and moves the glyph" {
    const alloc = testing.allocator;
    const lib = try freetype.Library.init();
    defer lib.deinit();
    const ft = try testFace(lib);
    defer ft.deinit();

    var r = try Rasterizer.init(alloc, ft);
    defer r.deinit();

    const glyph = freetype.c.FT_Get_Char_Index(ft.handle, 'H');
    var plain = (try r.render(alloc, glyph, 16, .{})).?;
    defer plain.deinit(alloc);
    var moved = (try r.render(alloc, glyph, 16, .{ .yy = 2, .dx = 5, .dy = -3 })).?;
    defer moved.deinit(alloc);

    try testing.expectApproxEqAbs(@as(f64, @floatFromInt(plain.left + 5)), @as(f64, @floatFromInt(moved.left)), 1);
    try testing.expectApproxEqAbs(@as(f64, @floatFromInt(plain.height * 2)), @as(f64, @floatFromInt(moved.height)), 2);
    try testing.expectApproxEqAbs(@as(f64, @floatFromInt(plain.top * 2 - 3)), @as(f64, @floatFromInt(moved.top)), 2);
}

test "a space covers nothing" {
    const alloc = testing.allocator;
    const lib = try freetype.Library.init();
    defer lib.deinit();
    const ft = try testFace(lib);
    defer ft.deinit();

    var r = try Rasterizer.init(alloc, ft);
    defer r.deinit();
    const glyph = freetype.c.FT_Get_Char_Index(ft.handle, ' ');
    try testing.expect(try r.render(alloc, glyph, 16, .{}) == null);
}

test "skew leans the glyph to the right" {
    const alloc = testing.allocator;
    const lib = try freetype.Library.init();
    defer lib.deinit();
    const ft = try testFace(lib);
    defer ft.deinit();

    var r = try Rasterizer.init(alloc, ft);
    defer r.deinit();

    // tan(12 degrees), as synthetic italic has it.
    const glyph = freetype.c.FT_Get_Char_Index(ft.handle, 'H');
    var plain = (try r.render(alloc, glyph, 16, .{})).?;
    defer plain.deinit(alloc);
    var skewed = (try r.render(alloc, glyph, 16, .{ .xy = 0.2126 })).?;
    defer skewed.deinit(alloc);

    // H has vertical sides, so leaning makes it wider by about its height
    // times the skew, and its top starts further right than its bottom.
    try testing.expect(skewed.width >= plain.width + 2);
    const first = struct {
        fn covered(b: Bitmap, row: u32) usize {
            const line = b.data[row * b.width ..][0..b.width];
            for (line, 0..) |v, i| if (v > 128) return i;
            return line.len;
        }
    }.covered;
    try testing.expect(first(skewed, 1) > first(skewed, skewed.height - 2));
}
