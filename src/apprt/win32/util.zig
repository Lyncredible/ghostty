//! Small helpers shared across the Win32 apprt.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const c = @import("win32_c");

// Values defined by macros that translate-c can't convert usefully.
pub const CW_USEDEFAULT: c_int = @bitCast(@as(c_uint, 0x80000000));
pub const GWLP_USERDATA: c_int = -21;
pub const USER_DEFAULT_SCREEN_DPI = 96;

/// A size at 96 DPI scaled to a DPI.
pub fn scale(v: c_int, dpi: c_int) c_int {
    return @divTrunc(v * dpi, USER_DEFAULT_SCREEN_DPI);
}

/// A color as GDI wants it (RGB()).
pub fn rgb(r: u8, g: u8, b: u8) c.COLORREF {
    return @as(c.COLORREF, r) | (@as(c.COLORREF, g) << 8) | (@as(c.COLORREF, b) << 16);
}

/// A number from outside, such as a point another process asks about, as
/// an integer: cut to the type's range, with NaN as 0, where
/// `@intFromFloat` would panic.
pub fn saturate(comptime T: type, v: f64) T {
    comptime std.debug.assert(@bitSizeOf(T) <= 32);
    if (std.math.isNan(v)) return 0;
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    return @intFromFloat(std.math.clamp(v, lo, hi));
}

test saturate {
    const testing = std.testing;
    try testing.expectEqual(@as(c_int, 12), saturate(c_int, 12.7));
    try testing.expectEqual(@as(c_int, -12), saturate(c_int, -12.7));
    try testing.expectEqual(@as(c_int, std.math.maxInt(c_int)), saturate(c_int, 1e20));
    try testing.expectEqual(@as(c_int, std.math.minInt(c_int)), saturate(c_int, -std.math.inf(f64)));
    try testing.expectEqual(@as(c_int, 0), saturate(c_int, std.math.nan(f64)));
    try testing.expectEqual(@as(u32, 0), saturate(u32, -5));
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), saturate(u32, std.math.inf(f64)));
}

/// A color channel from `a` toward `b` by `t` (0 to 1).
pub fn mix(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

/// The color `a` toward `b` by `t` (0 to 1), of any two colors with `r`,
/// `g` and `b` fields, as GDI wants it.
pub fn blend(a: anytype, b: @TypeOf(a), t: f32) c.COLORREF {
    return rgb(mix(a.r, b.r, t), mix(a.g, b.g, t), mix(a.b, b.b, t));
}

/// The first of the system's icon fonts that's installed, Segoe Fluent
/// Icons (Windows 11) or Segoe MDL2 Assets (Windows 10), at a size in
/// points (at 96 DPI) for a DPI. The caller deletes it.
pub fn iconFont(points: c_int, dpi: c_int) ?c.HFONT {
    const faces = [_][:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe Fluent Icons"),
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe MDL2 Assets"),
    };
    const dc = c.GetDC(null) orelse return null;
    defer _ = c.ReleaseDC(null, dc);
    for (faces) |face| {
        var lf = std.mem.zeroes(c.LOGFONTW);
        lf.lfHeight = -scale(points, dpi);
        lf.lfCharSet = c.DEFAULT_CHARSET;
        @memcpy(lf.lfFaceName[0..face.len], face);
        const font = c.CreateFontIndirectW(&lf) orelse continue;
        // Windows substitutes another font for one that isn't installed.
        const old = c.SelectObject(dc, font);
        var got: [c.LF_FACESIZE]u16 = undefined;
        const n = c.GetTextFaceW(dc, got.len, &got);
        _ = c.SelectObject(dc, old);
        if (n > 0 and std.mem.eql(u16, got[0..@intCast(n - 1)], face)) return font;
        _ = c.DeleteObject(font);
    }
    return null;
}

test "scale and rgb" {
    try std.testing.expectEqual(@as(c_int, 48), scale(48, 96));
    try std.testing.expectEqual(@as(c_int, 72), scale(48, 144));
    try std.testing.expectEqual(@as(c_int, 7), scale(5, 144));
    try std.testing.expectEqual(@as(c.COLORREF, 0x00563412), rgb(0x12, 0x34, 0x56));
}

test "mix and blend" {
    try std.testing.expectEqual(@as(u8, 0), mix(0, 255, 0));
    try std.testing.expectEqual(@as(u8, 255), mix(0, 255, 1));
    try std.testing.expectEqual(@as(u8, 20), mix(0, 255, 0.08));
    try std.testing.expectEqual(@as(u8, 235), mix(255, 0, 0.08));
    const Rgb = struct { r: u8, g: u8, b: u8 };
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expectEqual(rgb(128, 128, 128), blend(black, white, 0.5));
    try std.testing.expectEqual(rgb(255, 255, 255), blend(black, white, 1));
}

test iconFont {
    // Windows 10 and 11 both have one of them.
    const font = iconFont(10, 144) orelse return error.TestNoIconFont;
    defer _ = c.DeleteObject(font);
    var lf: c.LOGFONTW = undefined;
    try std.testing.expect(c.GetObjectW(font, @sizeOf(c.LOGFONTW), &lf) != 0);
    try std.testing.expectEqual(@as(c.LONG, -15), lf.lfHeight);
}

/// Load one of the predefined system cursors (IDC_*).
pub fn loadSystemCursor(id: u16) c.HCURSOR {
    return LoadCursorW(null, id);
}

/// Load an icon resource by its integer ID.
pub fn loadIcon(hinstance: c.HINSTANCE, id: u16) c.HICON {
    return LoadIconW(hinstance, id);
}

// These take MAKEINTRESOURCE values, which are small integers smuggled in
// a string pointer. Those aren't valid (aligned) pointers in Zig, so we
// declare these with the integer type instead.
extern "user32" fn LoadCursorW(hinstance: c.HINSTANCE, id: usize) callconv(.winapi) c.HCURSOR;
extern "user32" fn LoadIconW(hinstance: c.HINSTANCE, id: usize) callconv(.winapi) c.HICON;

/// SetWindowPos with an integer insert-after handle, so we can pass the
/// special values HWND_TOPMOST (-1) and HWND_NOTOPMOST (-2), which aren't
/// valid pointers in Zig.
pub extern "user32" fn SetWindowPos(
    hwnd: c.HWND,
    insert_after: isize,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    flags: c.UINT,
) callconv(.winapi) c.BOOL;
pub const HWND_TOPMOST: isize = -1;
pub const HWND_NOTOPMOST: isize = -2;

/// RegGetValueW with an integer key, so we can pass the predefined keys
/// such as HKEY_CURRENT_USER, which aren't valid pointers in Zig.
pub extern "advapi32" fn RegGetValueW(
    key: usize,
    sub_key: ?[*:0]const u16,
    value: ?[*:0]const u16,
    flags: c.DWORD,
    type: ?*c.DWORD,
    data: ?*anyopaque,
    size: ?*c.DWORD,
) callconv(.winapi) c.LONG;
pub const HKEY_CURRENT_USER: usize = @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000001)))));

// Predefined cursor IDs (MAKEINTRESOURCE values).
pub const IDC_ARROW = 32512;
pub const IDC_IBEAM = 32513;
pub const IDC_WAIT = 32514;
pub const IDC_CROSS = 32515;
pub const IDC_SIZENWSE = 32642;
pub const IDC_SIZENESW = 32643;
pub const IDC_SIZEWE = 32644;
pub const IDC_SIZENS = 32645;
pub const IDC_SIZEALL = 32646;
pub const IDC_NO = 32648;
pub const IDC_HAND = 32649;
pub const IDC_APPSTARTING = 32650;
pub const IDC_HELP = 32651;

/// Paint with a buffered paint DC whose alpha channel is made opaque
/// afterwards. GDI leaves alpha at zero, which shows through as glass
/// where the window's frame extends into its client area (for
/// `background-opacity`). This also double buffers the painting.
pub fn paintOpaque(
    hdc: c.HDC,
    rect: c.RECT,
    ctx: anytype,
    comptime paint: fn (@TypeOf(ctx), c.HDC) void,
) void {
    var params: c.BP_PAINTPARAMS = .{
        .cbSize = @sizeOf(c.BP_PAINTPARAMS),
        .dwFlags = 0,
        .prcExclude = null,
        .pBlendFunction = null,
    };
    var mem: c.HDC = null;
    const buffer = c.BeginBufferedPaint(hdc, &rect, c.BPBF_TOPDOWNDIB, &params, &mem);
    if (buffer == 0 or mem == null) {
        // Paint directly if buffering isn't available.
        paint(ctx, hdc);
        return;
    }
    paint(ctx, mem);
    _ = c.BufferedPaintSetAlpha(buffer, null, 255);
    _ = c.EndBufferedPaint(buffer, c.TRUE);
}

/// Move a child window to just above the first of the given siblings
/// that has a window, for an overlay made when it first shows: new child
/// windows go below their older siblings, so this puts it back where it
/// would be had it been made with the others.
pub fn placeAbove(hwnd: c.HWND, siblings: []const *const c.HWND) void {
    for (siblings) |sibling| {
        if (sibling.* == null) continue;
        // With no window above the sibling this is HWND_TOP.
        _ = c.SetWindowPos(
            hwnd,
            c.GetWindow(sibling.*, c.GW_HWNDPREV),
            0,
            0,
            0,
            0,
            c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE,
        );
        return;
    }
}

/// The low and high words of an LPARAM/WPARAM as signed values. These are
/// equivalent to GET_X_LPARAM and GET_Y_LPARAM.
pub fn loword(v: anytype) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(v)))));
}

pub fn hiword(v: anytype) i16 {
    return @bitCast(@as(u16, @truncate(@as(usize, @bitCast(v)) >> 16)));
}

/// Convert a UTF-8 string to a NUL-terminated UTF-16 string. Invalid
/// UTF-8 is replaced with the replacement character.
pub fn utf16Alloc(alloc: Allocator, utf8: []const u8) Allocator.Error![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(alloc, utf8) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => {
            // Fall back to a lossy conversion.
            var list: std.ArrayList(u16) = .empty;
            errdefer list.deinit(alloc);
            var i: usize = 0;
            while (i < utf8.len) {
                const cp, const len = decodeLossy(utf8[i..]);
                i += len;

                if (cp < 0x10000) {
                    try list.append(alloc, @intCast(cp));
                } else {
                    const v = cp - 0x10000;
                    try list.append(alloc, @intCast(0xD800 + (v >> 10)));
                    try list.append(alloc, @intCast(0xDC00 + (v & 0x3FF)));
                }
            }
            return try list.toOwnedSliceSentinel(alloc, 0);
        },
    };
}

/// The first code point of non-empty UTF-8 and its length in bytes, or
/// the replacement character for one byte if it's invalid.
fn decodeLossy(utf8: []const u8) struct { u21, usize } {
    const len = std.unicode.utf8ByteSequenceLength(utf8[0]) catch return .{ 0xFFFD, 1 };
    if (len > utf8.len) return .{ 0xFFFD, 1 };
    const cp = std.unicode.utf8Decode(utf8[0..len]) catch return .{ 0xFFFD, 1 };
    return .{ cp, len };
}

/// Convert UTF-8 into a fixed buffer as UTF-16, as much as fits, for text
/// that can be any length (titles, names). Returns the units written. It
/// stops before a character that doesn't fit, so a surrogate pair is never
/// split, and invalid UTF-8 becomes the replacement character.
///
/// `std.unicode.utf8ToUtf16Le` doesn't truncate: it writes past the end of
/// a buffer that's too small (a panic in safe builds).
pub fn utf16Truncate(buf: []u16, utf8: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < utf8.len) {
        const cp, const len = decodeLossy(utf8[i..]);
        if (cp < 0x10000) {
            if (n + 1 > buf.len) break;
            buf[n] = @intCast(cp);
            n += 1;
        } else {
            if (n + 2 > buf.len) break;
            const v = cp - 0x10000;
            buf[n] = @intCast(0xD800 + (v >> 10));
            buf[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        }
        i += len;
    }
    return n;
}

/// Like `utf16Truncate`, into a buffer with room for a NUL after the text.
pub fn utf16TruncateZ(buf: []u16, utf8: []const u8) [:0]u16 {
    const n = utf16Truncate(buf[0 .. buf.len - 1], utf8);
    buf[n] = 0;
    return buf[0..n :0];
}

/// Convert UTF-8 into a fixed buffer as UTF-16, NUL terminated, for text
/// that must be whole (names of things). Fails if it doesn't fit or isn't
/// valid UTF-8, where `std.unicode.utf8ToUtf16Le` would write past the end.
pub fn utf16Exact(buf: []u16, utf8: []const u8) error{ InvalidUtf8, NoSpaceLeft }![:0]u16 {
    const len = std.unicode.calcUtf16LeLen(utf8) catch return error.InvalidUtf8;
    if (len >= buf.len) return error.NoSpaceLeft;
    const n = std.unicode.utf8ToUtf16Le(buf[0..len], utf8) catch return error.InvalidUtf8;
    buf[n] = 0;
    return buf[0..n :0];
}

test utf16Truncate {
    const testing = std.testing;
    var buf: [4]u16 = undefined;

    try testing.expectEqualSlices(u16, &.{ 'a', 'b' }, buf[0..utf16Truncate(&buf, "ab")]);
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c', 'd' }, buf[0..utf16Truncate(&buf, "abcdefgh")]);
    // A surrogate pair that doesn't fit is left out whole.
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, buf[0..utf16Truncate(&buf, "abc😀")]);
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 0xD83D, 0xDE00 }, buf[0..utf16Truncate(&buf, "ab😀")]);
    // Invalid or cut off UTF-8 becomes the replacement character.
    try testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b' }, buf[0..utf16Truncate(&buf, "a\xffb")]);
    try testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 0xFFFD }, buf[0..utf16Truncate(&buf, "a\xe3\x81")]);
    try testing.expectEqual(@as(usize, 0), utf16Truncate(buf[0..0], "a"));

    var zbuf: [3]u16 = undefined;
    try testing.expectEqualSlices(u16, &.{ 'a', 'b' }, utf16TruncateZ(&zbuf, "abc"));
    try testing.expectEqual(@as(u16, 0), zbuf[2]);
}

test utf16Exact {
    const testing = std.testing;
    var buf: [4]u16 = undefined;
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, try utf16Exact(&buf, "abc"));
    try testing.expectEqual(@as(u16, 0), buf[3]);
    try testing.expectError(error.NoSpaceLeft, utf16Exact(&buf, "abcd"));
    try testing.expectError(error.NoSpaceLeft, utf16Exact(&buf, "ab😀"));
    try testing.expectError(error.InvalidUtf8, utf16Exact(&buf, "a\xff"));
}

/// Convert a UTF-16 string to UTF-8. Unpaired surrogates are encoded
/// as WTF-8 so this never fails except for allocation.
pub fn utf8Alloc(alloc: Allocator, utf16: []const u16) Allocator.Error![:0]u8 {
    return std.unicode.wtf16LeToWtf8AllocZ(alloc, utf16);
}

/// The Windows build number, for example 22631, or 0 if unknown.
pub fn windowsBuild() u32 {
    const windows = std.os.windows;
    var info: windows.RTL_OSVERSIONINFOW = undefined;
    info.dwOSVersionInfoSize = @sizeOf(windows.RTL_OSVERSIONINFOW);
    if (windows.ntdll.RtlGetVersion(&info) != .SUCCESS) return 0;
    return info.dwBuildNumber;
}

/// Whether a high contrast theme is on (Settings > Accessibility >
/// Contrast themes). Our own drawn UI then uses the theme's system colors
/// (`GetSysColor`), as Windows asks of apps, instead of the terminal's.
pub fn highContrast() bool {
    var hc: c.HIGHCONTRASTW = .{ .cbSize = @sizeOf(c.HIGHCONTRASTW), .dwFlags = 0, .lpszDefaultScheme = null };
    if (c.SystemParametersInfoW(c.SPI_GETHIGHCONTRAST, hc.cbSize, &hc, 0) == 0) return false;
    return hc.dwFlags & c.HCF_HIGHCONTRASTON != 0;
}

/// Whether Windows animates its controls and windows (Settings >
/// Accessibility > Visual effects > Animation effects). Our own
/// animations are skipped when it's off.
pub fn animations() bool {
    var on: c.BOOL = c.TRUE;
    if (c.SystemParametersInfoW(c.SPI_GETCLIENTAREAANIMATION, 0, &on, 0) == 0) return true;
    return on != c.FALSE;
}

/// The colors of a tooltip-like box (border, background, text): the given
/// ones, or with a high contrast theme on, the theme's tooltip colors.
pub const TipColors = struct {
    border: c.COLORREF,
    background: c.COLORREF,
    foreground: c.COLORREF,

    pub fn effective(self: TipColors) TipColors {
        if (!highContrast()) return self;
        return .{
            .border = c.GetSysColor(c.COLOR_INFOTEXT),
            .background = c.GetSysColor(c.COLOR_INFOBK),
            .foreground = c.GetSysColor(c.COLOR_INFOTEXT),
        };
    }
};

/// The system's message font (Settings > Accessibility > Text size) at a
/// DPI, or null if the system won't say.
pub fn messageLogFont(dpi: c.UINT) ?c.LOGFONTW {
    // Zeroed, so the face name's unused tail compares equal each time.
    var metrics = std.mem.zeroes(c.NONCLIENTMETRICSW);
    metrics.cbSize = @sizeOf(c.NONCLIENTMETRICSW);
    if (c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, metrics.cbSize, &metrics, 0, dpi) == 0) return null;
    return metrics.lfMessageFont;
}

/// The message font, scaled by `percent`, as a GDI font kept until the DPI
/// or the system font changes. Our overlays lay out on every resize step,
/// and the link preview on every mouse move over a link, which made and
/// deleted a font each time.
pub const MessageFont = struct {
    font: c.HFONT = null,
    logfont: c.LOGFONTW = std.mem.zeroes(c.LOGFONTW),

    /// A new font was made. `old` is the one it replaced (null the first
    /// time), for the caller to delete once nothing uses it: an Edit
    /// control given it with WM_SETFONT, say.
    pub const Change = struct { old: c.HFONT };

    /// Make the font for `dpi` if it's different; null if nothing changed.
    pub fn update(self: *MessageFont, dpi: c.UINT, percent: c.LONG) ?Change {
        var lf = messageLogFont(dpi) orelse return null;
        lf.lfHeight = @divTrunc(lf.lfHeight * percent, 100);
        if (self.font != null and std.mem.eql(u8, std.mem.asBytes(&lf), std.mem.asBytes(&self.logfont))) return null;
        const font = c.CreateFontIndirectW(&lf) orelse return null;
        const old = self.font;
        self.font = font;
        self.logfont = lf;
        return .{ .old = old };
    }

    /// `update`, deleting the old font right away: for a font only
    /// selected into a DC while painting.
    pub fn refresh(self: *MessageFont, dpi: c.UINT, percent: c.LONG) void {
        const change = self.update(dpi, percent) orelse return;
        if (change.old != null) _ = c.DeleteObject(change.old);
    }

    pub fn deinit(self: *MessageFont) void {
        if (self.font != null) _ = c.DeleteObject(self.font);
        self.* = .{};
    }
};

test MessageFont {
    var font: MessageFont = .{};
    defer font.deinit();
    // The first update makes a font, with nothing to delete.
    const first_change = font.update(96, 100) orelse return error.NoFont;
    try std.testing.expect(first_change.old == null);
    const first = font.font orelse return error.NoFont;
    // The same DPI again changes nothing.
    try std.testing.expect(font.update(96, 100) == null);
    // Another DPI makes a new font, and hands back the old one.
    const change = font.update(192, 100) orelse return error.NoNewFont;
    try std.testing.expectEqual(@as(c.HFONT, first), change.old);
    try std.testing.expect(font.font != change.old);
    _ = c.DeleteObject(change.old);
    try std.testing.expect(font.logfont.lfHeight != 0);
    // A smaller size does too.
    const height = font.logfont.lfHeight;
    font.refresh(192, 90);
    try std.testing.expect(@abs(font.logfont.lfHeight) < @abs(height));
}

/// Make the menus of this process (popup menus and the system menu) dark
/// or light, to match our windows rather than the system's app theme.
///
/// This uses SetPreferredAppMode and FlushMenuThemes, which uxtheme only
/// exports by ordinal (135 and 136) from Windows 10 1903 (build 18362).
/// They're undocumented, but widely used for this. On older systems the
/// menus keep the system's theme.
pub fn setMenuTheme(dark: bool) void {
    if (windowsBuild() < 18362) return;
    const uxtheme = c.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("uxtheme.dll")) orelse return;
    const PreferredAppMode = enum(c_int) { force_dark = 2, force_light = 3 };
    const SetPreferredAppMode = *const fn (PreferredAppMode) callconv(.winapi) PreferredAppMode;
    const FlushMenuThemes = *const fn () callconv(.winapi) void;
    const set_mode: SetPreferredAppMode = @ptrCast(@alignCast(c.GetProcAddress(uxtheme, @ptrFromInt(135)) orelse return));
    const flush: FlushMenuThemes = @ptrCast(@alignCast(c.GetProcAddress(uxtheme, @ptrFromInt(136)) orelse return));
    _ = set_mode(if (dark) .force_dark else .force_light);
    flush();
}

/// Turn the blur behind accent on or off for a window. This blurs what's
/// behind the window's transparent parts on Windows 10 and early Windows
/// 11, which don't have system backdrops.
///
/// SetWindowCompositionAttribute is undocumented, but user32 has exported
/// it by name since Windows 7 and it's widely used for this. Returns
/// whether it succeeded.
pub fn setBlurBehindAccent(hwnd: c.HWND, enable: bool) bool {
    const AccentPolicy = extern struct {
        state: c_int,
        flags: c_int = 0,
        gradient_color: u32 = 0,
        animation_id: c_int = 0,
    };
    const CompositionData = extern struct {
        attribute: c_int,
        data: *anyopaque,
        size: usize,
    };
    const SetWindowCompositionAttribute = *const fn (c.HWND, *CompositionData) callconv(.winapi) c.BOOL;

    const user32 = c.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll")) orelse return false;
    const set: SetWindowCompositionAttribute = @ptrCast(@alignCast(c.GetProcAddress(user32, "SetWindowCompositionAttribute") orelse return false));

    const ACCENT_DISABLED = 0;
    const ACCENT_ENABLE_BLURBEHIND = 3;
    const WCA_ACCENT_POLICY = 19;
    var policy: AccentPolicy = .{ .state = if (enable) ACCENT_ENABLE_BLURBEHIND else ACCENT_DISABLED };
    var data: CompositionData = .{
        .attribute = WCA_ACCENT_POLICY,
        .data = &policy,
        .size = @sizeOf(AccentPolicy),
    };
    return set(hwnd, &data) != c.FALSE;
}

/// Undo subclassing a control with SetWindowLongPtrW(GWLP_WNDPROC) before
/// it's destroyed: its own window procedure goes back, and our user data
/// is cleared. Our subclass procedures fall back to DefWindowProcW once
/// the user data is gone, so without the original procedure back the
/// control (an Edit) never saw WM_DESTROY or WM_NCDESTROY and never freed
/// what it had made, a GDI object among it.
pub fn unsubclass(hwnd: c.HWND, original: c.WNDPROC) void {
    _ = c.SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
    if (original) |proc| _ = c.SetWindowLongPtrW(hwnd, c.GWLP_WNDPROC, @bitCast(@intFromPtr(proc)));
}

/// A handle (HWND, HDC, ...) passed in a message's WPARAM or LPARAM.
/// Handles aren't pointers to aligned memory, so `@ptrFromInt` would fail
/// its alignment check for many of them; we reinterpret the bits instead.
pub fn handle(comptime T: type, value: anytype) T {
    comptime std.debug.assert(@sizeOf(@TypeOf(value)) == @sizeOf(T));
    return @as(*const T, @ptrCast(&value)).*;
}
