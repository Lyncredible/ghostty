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
