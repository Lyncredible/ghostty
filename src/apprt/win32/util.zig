//! Small helpers shared across the Win32 apprt.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const c = @import("win32_c");

// Values defined by macros that translate-c can't convert usefully.
pub const CW_USEDEFAULT: c_int = @bitCast(@as(c_uint, 0x80000000));
pub const GWLP_USERDATA: c_int = -21;
pub const USER_DEFAULT_SCREEN_DPI = 96;

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
                const cp: u21, const len: usize = decode: {
                    const len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch
                        break :decode .{ 0xFFFD, 1 };
                    if (i + len > utf8.len) break :decode .{ 0xFFFD, 1 };
                    const cp = std.unicode.utf8Decode(utf8[i..][0..len]) catch
                        break :decode .{ 0xFFFD, 1 };
                    break :decode .{ cp, len };
                };
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
    const set_mode: SetPreferredAppMode = @ptrCast(c.GetProcAddress(uxtheme, @ptrFromInt(135)) orelse return);
    const flush: FlushMenuThemes = @ptrCast(c.GetProcAddress(uxtheme, @ptrFromInt(136)) orelse return);
    _ = set_mode(if (dark) .force_dark else .force_light);
    flush();
}

/// Turn the blur behind accent on or off for a window. This blurs what's
/// behind the window's transparent parts on Windows 10 and early Windows
/// 11, which don't have system backdrops.
///
/// SetWindowCompositionAttribute is undocumented, but user32 has exported
/// it by name since Windows 7 and it's widely used for this.
pub fn setBlurBehindAccent(hwnd: c.HWND, enable: bool) void {
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

    const user32 = c.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll")) orelse return;
    const set: SetWindowCompositionAttribute = @ptrCast(c.GetProcAddress(user32, "SetWindowCompositionAttribute") orelse return);

    const ACCENT_DISABLED = 0;
    const ACCENT_ENABLE_BLURBEHIND = 3;
    const WCA_ACCENT_POLICY = 19;
    var policy: AccentPolicy = .{ .state = if (enable) ACCENT_ENABLE_BLURBEHIND else ACCENT_DISABLED };
    var data: CompositionData = .{
        .attribute = WCA_ACCENT_POLICY,
        .data = &policy,
        .size = @sizeOf(AccentPolicy),
    };
    _ = set(hwnd, &data);
}

/// A handle (HWND, HDC, ...) passed in a message's WPARAM or LPARAM.
/// Handles aren't pointers to aligned memory, so `@ptrFromInt` would fail
/// its alignment check for many of them; we reinterpret the bits instead.
pub fn handle(comptime T: type, value: anytype) T {
    comptime std.debug.assert(@sizeOf(@TypeOf(value)) == @sizeOf(T));
    return @as(*const T, @ptrCast(&value)).*;
}
