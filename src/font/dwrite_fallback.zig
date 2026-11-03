//! The font Windows itself would use for a codepoint, from DirectWrite's
//! system font fallback. It takes the user's locale and the system's
//! preferences into account, for example Yu Gothic or Meiryo for Japanese
//! text on a Japanese system and Segoe UI Emoji for emoji, where scanning
//! the font folders finds whichever font file happens to come first.
//! Also the face of a font family for a style, from DirectWrite's index
//! of installed fonts.
const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("dwrite_c");

const log = std.log.scoped(.discovery);

/// A font file and the index of the face within it.
pub const Font = struct {
    /// UTF-8, owned by the caller.
    path: [:0]u8,
    index: u32,

    /// The weight DirectWrite matched, from 1 to 999, which picks the
    /// named instance of a variable font. Zero from `find`.
    weight: u32 = 0,
};

/// The font DirectWrite falls back to for a codepoint, or null if there's
/// none or DirectWrite fails.
pub fn find(alloc: Allocator, codepoint: u21, bold: bool, italic: bool) ?Font {
    return findInner(alloc, codepoint, bold, italic) catch |err| {
        log.debug("DirectWrite fallback failed err={}", .{err});
        return null;
    };
}

fn findInner(alloc: Allocator, codepoint: u21, bold: bool, italic: bool) !?Font {
    var factory: ?*c.IDWriteFactory2 = null;
    try check(c.DWriteCreateFactory(
        c.DWRITE_FACTORY_TYPE_SHARED,
        &IID_IDWriteFactory2,
        @ptrCast(&factory),
    ));
    defer release(factory.?);

    var fallback: ?*c.IDWriteFontFallback = null;
    try check(call(factory.?, "GetSystemFontFallback", .{&fallback}));
    defer release(fallback.?);

    var source: TextSource = .{};
    source.text_len = @intCast(std.unicode.utf8Encode(codepoint, &source.utf8) catch return null);
    source.text_len = @intCast(std.unicode.wtf8ToWtf16Le(
        &source.text,
        source.utf8[0..source.text_len],
    ) catch return null);
    if (c.GetUserDefaultLocaleName(&source.locale, source.locale.len) == 0) {
        source.locale[0] = 0;
    }

    var mapped_len: c.UINT32 = 0;
    var font: ?*c.IDWriteFont = null;
    var scale: f32 = 1;
    try check(call(fallback.?, "MapCharacters", .{
        @as(*c.IDWriteTextAnalysisSource, @ptrCast(&source)),
        0,
        source.text_len,
        null,
        null,
        @as(c.DWRITE_FONT_WEIGHT, if (bold) c.DWRITE_FONT_WEIGHT_BOLD else c.DWRITE_FONT_WEIGHT_NORMAL),
        @as(c.DWRITE_FONT_STYLE, if (italic) c.DWRITE_FONT_STYLE_ITALIC else c.DWRITE_FONT_STYLE_NORMAL),
        @as(c.DWRITE_FONT_STRETCH, c.DWRITE_FONT_STRETCH_NORMAL),
        &mapped_len,
        &font,
        &scale,
    }));
    const mapped = font orelse return null;
    defer release(mapped);
    return try fontFile(alloc, mapped);
}

/// The face of a family that DirectWrite matches to a style, or null if
/// the family isn't installed or doesn't have that style (DirectWrite
/// would simulate it). DirectWrite keeps an index of the installed fonts,
/// per-user ones too, so this is much faster than opening font files.
pub fn findFamily(alloc: Allocator, family: []const u8, bold: bool, italic: bool) ?Font {
    return findFamilyInner(alloc, family, bold, italic) catch |err| {
        log.debug("DirectWrite family lookup failed err={}", .{err});
        return null;
    };
}

fn findFamilyInner(alloc: Allocator, family: []const u8, bold: bool, italic: bool) !?Font {
    var factory: ?*c.IDWriteFactory2 = null;
    try check(c.DWriteCreateFactory(
        c.DWRITE_FACTORY_TYPE_SHARED,
        &IID_IDWriteFactory2,
        @ptrCast(&factory),
    ));
    defer release(factory.?);

    var collection: ?*c.IDWriteFontCollection = null;
    try check(call(factory.?, "GetSystemFontCollection", .{ &collection, c.FALSE }));
    defer release(collection.?);

    const family16 = std.unicode.wtf8ToWtf16LeAllocZ(alloc, family) catch return null;
    defer alloc.free(family16);
    var index: c.UINT32 = 0;
    var exists: c.BOOL = c.FALSE;
    try check(call(collection.?, "FindFamilyName", .{ family16.ptr, &index, &exists }));
    if (exists == c.FALSE) return null;

    var font_family: ?*c.IDWriteFontFamily = null;
    try check(call(collection.?, "GetFontFamily", .{ index, &font_family }));
    defer release(font_family.?);

    var font: ?*c.IDWriteFont = null;
    try check(call(font_family.?, "GetFirstMatchingFont", .{
        @as(c.DWRITE_FONT_WEIGHT, if (bold) c.DWRITE_FONT_WEIGHT_BOLD else c.DWRITE_FONT_WEIGHT_NORMAL),
        @as(c.DWRITE_FONT_STRETCH, c.DWRITE_FONT_STRETCH_NORMAL),
        @as(c.DWRITE_FONT_STYLE, if (italic) c.DWRITE_FONT_STYLE_ITALIC else c.DWRITE_FONT_STYLE_NORMAL),
        &font,
    }));
    const matched = font orelse return null;
    defer release(matched);
    if (call(matched, "GetSimulations", .{}) != c.DWRITE_FONT_SIMULATIONS_NONE) return null;
    var result = try fontFile(alloc, matched) orelse return null;
    result.weight = @intCast(call(matched, "GetWeight", .{}));
    return result;
}

/// The fonts DirectWrite knows that aren't in the given directories, such
/// as the ones packaged apps register (Windows Terminal's Cascadia Mono).
/// Each face is listed once per weight, so a variable font's named
/// instances are listed separately. Empty if DirectWrite fails. Free with
/// `freeFonts`.
pub fn otherFonts(alloc: Allocator, skip_dirs: []const []const u8) []Font {
    return otherFontsInner(alloc, skip_dirs) catch |err| {
        log.debug("DirectWrite font listing failed err={}", .{err});
        return &.{};
    };
}

pub fn freeFonts(alloc: Allocator, fonts: []Font) void {
    for (fonts) |font| alloc.free(font.path);
    alloc.free(fonts);
}

fn otherFontsInner(alloc: Allocator, skip_dirs: []const []const u8) ![]Font {
    var factory: ?*c.IDWriteFactory3 = null;
    try check(c.DWriteCreateFactory(
        c.DWRITE_FACTORY_TYPE_SHARED,
        &IID_IDWriteFactory3,
        @ptrCast(&factory),
    ));
    defer release(factory.?);

    // The font set lists each face and named instance with its file, so
    // nothing has to be parsed: creating a font face for each of the
    // system collection's fonts took about 780 ms for 750 fonts.
    var set: ?*c.IDWriteFontSet = null;
    try check(call(factory.?, "GetSystemFontSet", .{&set}));
    defer release(set.?);

    var list: std.ArrayList(Font) = .empty;
    errdefer {
        for (list.items) |font| alloc.free(font.path);
        list.deinit(alloc);
    }

    const count = call(set.?, "GetFontCount", .{});
    for (0..count) |i| {
        var ref: ?*c.IDWriteFontFaceReference = null;
        try check(call(set.?, "GetFontFaceReference", .{ @as(c.UINT32, @intCast(i)), &ref }));
        defer release(ref.?);
        if (call(ref.?, "GetSimulations", .{}) != c.DWRITE_FONT_SIMULATIONS_NONE) continue;

        var file: ?*c.IDWriteFontFile = null;
        try check(call(ref.?, "GetFontFile", .{&file}));
        defer release(file.?);

        // Fonts that aren't in a local file can't be opened by path.
        const path = (filePath(alloc, file.?) catch continue) orelse continue;
        const font: Font = .{
            .path = path,
            .index = call(ref.?, "GetFontFaceIndex", .{}),
            .weight = axisWeight(ref.?),
        };
        if (inDirs(font.path, skip_dirs) or contains(list.items, font)) {
            alloc.free(font.path);
            continue;
        }
        try list.append(alloc, font);
    }
    return try list.toOwnedSlice(alloc);
}

/// The weight axis value of a variable font's named instance, or zero.
fn axisWeight(ref: *c.IDWriteFontFaceReference) u32 {
    var ref1: ?*c.IDWriteFontFaceReference1 = null;
    check(call(ref, "QueryInterface", .{ &IID_IDWriteFontFaceReference1, @as(?*?*anyopaque, @ptrCast(&ref1)) })) catch
        return 0;
    defer release(ref1.?);

    var values: [16]c.DWRITE_FONT_AXIS_VALUE = undefined;
    const n = @min(values.len, call(ref1.?, "GetFontAxisValueCount", .{}));
    check(call(ref1.?, "GetFontAxisValues", .{ &values, @as(c.UINT32, @intCast(n)) })) catch return 0;
    for (values[0..n]) |value| {
        if (value.axisTag == c.DWRITE_FONT_AXIS_TAG_WEIGHT) return @intFromFloat(value.value);
    }
    return 0;
}

fn inDirs(path: []const u8, dirs: []const []const u8) bool {
    for (dirs) |dir| {
        if (path.len > dir.len and
            std.ascii.startsWithIgnoreCase(path, dir) and
            (path[dir.len] == '\\' or path[dir.len] == '/')) return true;
    }
    return false;
}

fn contains(fonts: []const Font, font: Font) bool {
    for (fonts) |other| {
        if (other.index == font.index and
            other.weight == font.weight and
            std.ascii.eqlIgnoreCase(other.path, font.path)) return true;
    }
    return false;
}

/// The file and face index of a DirectWrite font, or null if it isn't in
/// a local file.
fn fontFile(alloc: Allocator, font: *c.IDWriteFont) !?Font {
    var face: ?*c.IDWriteFontFace = null;
    try check(call(font, "CreateFontFace", .{&face}));
    defer release(face.?);

    var file_count: c.UINT32 = 1;
    var file: ?*c.IDWriteFontFile = null;
    try check(call(face.?, "GetFiles", .{ &file_count, &file }));
    const font_file = file orelse return null;
    defer release(font_file);

    const path = try filePath(alloc, font_file) orelse return null;
    return .{ .path = path, .index = call(face.?, "GetIndex", .{}) };
}

/// The path of a font file, or null if it isn't a local file.
fn filePath(alloc: Allocator, font_file: *c.IDWriteFontFile) !?[:0]u8 {
    var key: ?*const anyopaque = null;
    var key_size: c.UINT32 = 0;
    try check(call(font_file, "GetReferenceKey", .{ &key, &key_size }));
    var loader: ?*c.IDWriteFontFileLoader = null;
    try check(call(font_file, "GetLoader", .{&loader}));
    defer release(loader.?);

    // Only fonts in files have a path.
    var local: ?*c.IDWriteLocalFontFileLoader = null;
    try check(call(loader.?, "QueryInterface", .{ &IID_IDWriteLocalFontFileLoader, @as(?*?*anyopaque, @ptrCast(&local)) }));
    defer release(local.?);

    var path_len: c.UINT32 = 0;
    try check(call(local.?, "GetFilePathLengthFromKey", .{ key, key_size, &path_len }));
    const path16 = try alloc.alloc(u16, path_len + 1);
    defer alloc.free(path16);
    try check(call(local.?, "GetFilePathFromKey", .{ key, key_size, path16.ptr, path_len + 1 }));

    return try std.unicode.wtf16LeToWtf8AllocZ(alloc, path16[0..path_len]);
}

/// The text to map, as an IDWriteTextAnalysisSource. It only lives on the
/// stack during MapCharacters, so reference counting does nothing.
const TextSource = extern struct {
    vtbl: *const c.IDWriteTextAnalysisSourceVtbl = &vtable,
    text: [2]u16 = undefined,
    text_len: c.UINT32 = 0,
    utf8: [4]u8 = undefined,
    locale: [c.LOCALE_NAME_MAX_LENGTH]u16 = undefined,

    const vtable: c.IDWriteTextAnalysisSourceVtbl = .{
        .QueryInterface = &queryInterface,
        .AddRef = &addRef,
        .Release = &addRef,
        .GetTextAtPosition = &getTextAtPosition,
        .GetTextBeforePosition = &getTextBeforePosition,
        .GetParagraphReadingDirection = &getParagraphReadingDirection,
        .GetLocaleName = &getLocaleName,
        .GetNumberSubstitution = &getNumberSubstitution,
    };

    fn from(this: [*c]c.IDWriteTextAnalysisSource) *TextSource {
        return @ptrCast(@alignCast(this));
    }

    fn queryInterface(
        this: [*c]c.IDWriteTextAnalysisSource,
        riid: [*c]const c.IID,
        out: [*c]?*anyopaque,
    ) callconv(.winapi) c.HRESULT {
        if (std.meta.eql(riid.*, IID_IUnknown) or
            std.meta.eql(riid.*, IID_IDWriteTextAnalysisSource))
        {
            out.* = this;
            return c.S_OK;
        }
        out.* = null;
        return c.E_NOINTERFACE;
    }

    fn addRef(_: [*c]c.IDWriteTextAnalysisSource) callconv(.winapi) c.ULONG {
        return 1;
    }

    fn getTextAtPosition(
        this: [*c]c.IDWriteTextAnalysisSource,
        position: c.UINT32,
        text: [*c][*c]const c.WCHAR,
        len: [*c]c.UINT32,
    ) callconv(.winapi) c.HRESULT {
        const self = from(this);
        if (position >= self.text_len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = @ptrCast(&self.text[position]);
            len.* = self.text_len - position;
        }
        return c.S_OK;
    }

    fn getTextBeforePosition(
        this: [*c]c.IDWriteTextAnalysisSource,
        position: c.UINT32,
        text: [*c][*c]const c.WCHAR,
        len: [*c]c.UINT32,
    ) callconv(.winapi) c.HRESULT {
        const self = from(this);
        if (position == 0 or position > self.text_len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = @ptrCast(&self.text[0]);
            len.* = position;
        }
        return c.S_OK;
    }

    fn getParagraphReadingDirection(
        _: [*c]c.IDWriteTextAnalysisSource,
    ) callconv(.winapi) c.DWRITE_READING_DIRECTION {
        return c.DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
    }

    fn getLocaleName(
        this: [*c]c.IDWriteTextAnalysisSource,
        position: c.UINT32,
        len: [*c]c.UINT32,
        locale: [*c][*c]const c.WCHAR,
    ) callconv(.winapi) c.HRESULT {
        const self = from(this);
        locale.* = @ptrCast(&self.locale);
        len.* = self.text_len -| position;
        return c.S_OK;
    }

    fn getNumberSubstitution(
        this: [*c]c.IDWriteTextAnalysisSource,
        position: c.UINT32,
        len: [*c]c.UINT32,
        substitution: [*c][*c]c.IDWriteNumberSubstitution,
    ) callconv(.winapi) c.HRESULT {
        const self = from(this);
        substitution.* = null;
        len.* = self.text_len -| position;
        return c.S_OK;
    }
};

const IID_IUnknown = guid(0x00000000, 0x0000, 0x0000, .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 });
const IID_IDWriteFactory2 = guid(0x0439fc60, 0xca44, 0x4994, .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec });
const IID_IDWriteFactory3 = guid(0x9a1b41c3, 0xd3bb, 0x466a, .{ 0x87, 0xfc, 0xfe, 0x67, 0x55, 0x6a, 0x3b, 0x65 });
const IID_IDWriteFontFaceReference1 = guid(0xc081fe77, 0x2fd1, 0x41ac, .{ 0xa5, 0xa3, 0x34, 0x98, 0x3c, 0x4b, 0xa6, 0x1a });
const IID_IDWriteTextAnalysisSource = guid(0x688e1a58, 0x5094, 0x47c8, .{ 0xad, 0xc8, 0xfb, 0xce, 0xa6, 0x0a, 0xe9, 0x2b });
const IID_IDWriteLocalFontFileLoader = guid(0xb2d9f3ec, 0xc9fe, 0x4a11, .{ 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 });

fn guid(a: u32, b: u16, d: u16, e: [8]u8) c.IID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = d, .Data4 = e };
}

fn check(hr: c.HRESULT) error{DirectWriteFailed}!void {
    if (hr < 0) return error.DirectWriteFailed;
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

test findFamily {
    const testing = std.testing;
    const font = findFamily(testing.allocator, "Consolas", true, false) orelse return error.SkipZigTest;
    defer testing.allocator.free(font.path);
    try testing.expect(std.ascii.endsWithIgnoreCase(font.path, "consolab.ttf"));
    try testing.expectEqual(@as(u32, c.DWRITE_FONT_WEIGHT_BOLD), font.weight);
    try testing.expect(findFamily(testing.allocator, "No Such Font Family", false, false) == null);
}

test otherFonts {
    const testing = std.testing;
    const alloc = testing.allocator;
    const fonts = otherFonts(alloc, &.{});
    defer freeFonts(alloc, fonts);

    // With no directories skipped, Consolas Bold is among them, once.
    var found: usize = 0;
    for (fonts) |font| {
        if (std.ascii.endsWithIgnoreCase(font.path, "consolab.ttf")) found += 1;
    }
    try testing.expectEqual(@as(usize, 1), found);
}

test find {
    const testing = std.testing;
    const font = find(testing.allocator, 'A', false, false) orelse return error.SkipZigTest;
    defer testing.allocator.free(font.path);
    try testing.expect(std.ascii.endsWithIgnoreCase(font.path, ".ttf") or
        std.ascii.endsWithIgnoreCase(font.path, ".ttc") or
        std.ascii.endsWithIgnoreCase(font.path, ".otf"));
}
