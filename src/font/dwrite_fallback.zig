//! The font Windows itself would use for a codepoint, from DirectWrite's
//! system font fallback. It takes the user's locale and the system's
//! preferences into account, for example Yu Gothic or Meiryo for Japanese
//! text on a Japanese system and Segoe UI Emoji for emoji, where scanning
//! the font folders finds whichever font file happens to come first.
const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("dwrite_c");

const log = std.log.scoped(.discovery);

/// A font file and the index of the face within it.
pub const Font = struct {
    /// UTF-8, owned by the caller.
    path: [:0]u8,
    index: u32,
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

    var face: ?*c.IDWriteFontFace = null;
    try check(call(mapped, "CreateFontFace", .{&face}));
    defer release(face.?);

    var file_count: c.UINT32 = 1;
    var file: ?*c.IDWriteFontFile = null;
    try check(call(face.?, "GetFiles", .{ &file_count, &file }));
    const font_file = file orelse return null;
    defer release(font_file);

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

    const path = try std.unicode.wtf16LeToWtf8AllocZ(alloc, path16[0..path_len]);
    return .{ .path = path, .index = call(face.?, "GetIndex", .{}) };
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

test find {
    const testing = std.testing;
    const font = find(testing.allocator, 'A', false, false) orelse return error.SkipZigTest;
    defer testing.allocator.free(font.path);
    try testing.expect(std.ascii.endsWithIgnoreCase(font.path, ".ttf") or
        std.ascii.endsWithIgnoreCase(font.path, ".ttc") or
        std.ascii.endsWithIgnoreCase(font.path, ".otf"));
}
