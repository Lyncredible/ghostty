//! Small integrations with the Windows shell: the touch keyboard and file
//! dialogs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../../global.zig");

const util = @import("util.zig");
const c = util.c;

const log = std.log.scoped(.win32);

/// Show or hide the touch keyboard, for the show_on_screen_keyboard action.
///
/// This uses the shell's ITipInvocation interface, which isn't documented
/// but is how programs have opened the touch keyboard since Windows 8. It
/// only toggles, so the action hides the keyboard if it's already shown.
pub fn toggleTouchKeyboard(hwnd: c.HWND) bool {
    const tip = tipInvocation() orelse tip: {
        // The keyboard's host process isn't running. Start it and try
        // once more.
        var buf: [std.Io.Dir.max_path_bytes]u16 = undefined;
        const n = c.ExpandEnvironmentStringsW(
            std.unicode.utf8ToUtf16LeStringLiteral("%CommonProgramFiles%\\microsoft shared\\ink\\TabTip.exe"),
            &buf,
            buf.len,
        );
        if (n == 0 or n > buf.len) return false;
        if (@intFromPtr(c.ShellExecuteW(null, null, &buf, null, null, c.SW_SHOWNORMAL)) <= 32) {
            log.warn("unable to start the touch keyboard", .{});
            return false;
        }
        break :tip tipInvocation() orelse return false;
    };
    defer _ = tip.vtbl.Release(tip);
    return tip.vtbl.Toggle(tip, hwnd) >= 0;
}

const ITipInvocation = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ITipInvocation) callconv(.winapi) c.ULONG,
        Toggle: *const fn (*ITipInvocation, c.HWND) callconv(.winapi) c.HRESULT,
    },
};

fn tipInvocation() ?*ITipInvocation {
    const CLSID_UIHostNoLaunch: c.GUID = .{
        .Data1 = 0x4ce576fa,
        .Data2 = 0x83dc,
        .Data3 = 0x4f88,
        .Data4 = .{ 0x95, 0x1c, 0x9d, 0x07, 0x82, 0xb4, 0xe3, 0x76 },
    };
    const IID_ITipInvocation: c.GUID = .{
        .Data1 = 0x37c994e7,
        .Data2 = 0x432b,
        .Data3 = 0x4834,
        .Data4 = .{ 0xa2, 0xf7, 0xdc, 0xe1, 0xf1, 0x3b, 0x83, 0x4b },
    };
    var tip: ?*ITipInvocation = null;
    if (c.CoCreateInstance(
        &CLSID_UIHostNoLaunch,
        null,
        c.CLSCTX_INPROC_SERVER | c.CLSCTX_LOCAL_SERVER,
        &IID_ITipInvocation,
        @ptrCast(&tip),
    ) < 0) return null;
    return tip;
}

/// Open a file in the app associated with its type, or in Notepad if
/// there's none. Our config file's `.ghostty` type usually has no app, and
/// Windows would only ask which app to use.
pub fn openFile(alloc: Allocator, path: []const u8) void {
    const path16 = util.utf16Alloc(alloc, path) catch return;
    defer alloc.free(path16);
    const open = std.unicode.utf8ToUtf16LeStringLiteral("open");

    if (hasAssociation(path)) {
        const result = c.ShellExecuteW(null, open, path16, null, null, c.SW_SHOWNORMAL);
        if (@intFromPtr(result) > 32) return;
        log.warn("failed to open file path={s} result={}", .{ path, @intFromPtr(result) });
    }

    // Notepad takes the path as a single (quoted) argument.
    const params = std.fmt.allocPrint(alloc, "\"{s}\"", .{path}) catch return;
    defer alloc.free(params);
    const params16 = util.utf16Alloc(alloc, params) catch return;
    defer alloc.free(params16);
    var notepad_buf: [c.MAX_PATH + 16]u16 = undefined;
    const notepad = systemProgram(
        &notepad_buf,
        std.unicode.utf8ToUtf16LeStringLiteral("notepad.exe"),
    );
    const result = c.ShellExecuteW(null, open, notepad, params16, null, c.SW_SHOWNORMAL);
    if (@intFromPtr(result) <= 32) {
        log.warn("failed to open file in notepad path={s} result={}", .{ path, @intFromPtr(result) });
    }
}

/// A program that comes with Windows by its whole path, in the system
/// directory. Named alone it would be looked for in the current directory
/// first, and that can be anyone's (wherever we were started from). The
/// name alone if the directory can't be had.
fn systemProgram(buf: []u16, name: [:0]const u16) [*:0]const u16 {
    const n = c.GetSystemDirectoryW(buf.ptr, @intCast(buf.len));
    if (n == 0 or n + 1 + name.len + 1 > buf.len) return name.ptr;
    var len: usize = n;
    if (buf[len - 1] != '\\') {
        buf[len] = '\\';
        len += 1;
    }
    @memcpy(buf[len..][0..name.len], name);
    buf[len + name.len] = 0;
    return buf[0 .. len + name.len :0].ptr;
}

test systemProgram {
    const testing = std.testing;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [c.MAX_PATH + 16]u16 = undefined;
    const path = std.mem.span(systemProgram(&buf, L("notepad.exe")));
    try testing.expect(std.mem.endsWith(u16, path, L("\\notepad.exe")));
    try testing.expect(path.len > 14 and path[1] == ':');
    try testing.expect(c.GetFileAttributesW(path.ptr) != c.INVALID_FILE_ATTRIBUTES);

    // No room for the directory: the name as it was.
    var small: [8]u16 = undefined;
    try testing.expectEqualSlices(u16, L("notepad.exe"), std.mem.span(systemProgram(&small, L("notepad.exe"))));
}

/// Whether the file's type (its extension) has an app to open it with.
fn hasAssociation(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;
    var ext_buf: [64]u16 = undefined;
    if (ext.len >= ext_buf.len) return false;
    const n = std.unicode.utf8ToUtf16Le(&ext_buf, ext) catch return false;
    ext_buf[n] = 0;

    var len: u32 = 0;
    const ASSOCF_INIT_IGNOREUNKNOWN: u32 = 0x400;
    const ASSOCSTR_EXECUTABLE: i32 = 2;
    const S_FALSE = 1;
    const hr = AssocQueryStringW(
        ASSOCF_INIT_IGNOREUNKNOWN,
        ASSOCSTR_EXECUTABLE,
        ext_buf[0..n :0],
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        null,
        &len,
    );
    // With no output buffer, success is S_FALSE with the length.
    return hr == S_FALSE or hr == 0;
}

test hasAssociation {
    const testing = std.testing;
    // Windows comes with an app for text files.
    try testing.expect(hasAssociation("C:\\notes\\read me.txt"));
    // No extension, one nobody registers (as our config file's usually
    // is), and one too long to be one.
    try testing.expect(!hasAssociation("C:\\Users\\someone\\config"));
    try testing.expect(!hasAssociation("config.ghostty-test-no-such-type"));
    try testing.expect(!hasAssociation("config." ++ @as([80]u8, @splat('x'))));
    try testing.expect(!hasAssociation(""));
}

extern "shlwapi" fn AssocQueryStringW(
    flags: u32,
    str: i32,
    assoc: [*:0]const u16,
    extra: ?[*:0]const u16,
    out: ?[*]u16,
    out_len: *u32,
) callconv(.winapi) i32;

/// Ask where to save `contents` with the standard Save As dialog, and save
/// it there. The dialog is modal and pumps messages. Returns false if the
/// user canceled or saving failed.
pub fn saveAs(
    alloc: Allocator,
    owner: c.HWND,
    title: []const u8,
    default_name: []const u8,
    contents: []const u8,
) bool {
    var path: [c.MAX_PATH * 4]u16 = @splat(0);
    _ = util.utf16TruncateZ(&path, default_name);
    const title16 = util.utf16Alloc(alloc, title) catch return false;
    defer alloc.free(title16);

    var ofn = std.mem.zeroes(c.OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(c.OPENFILENAMEW);
    ofn.hwndOwner = owner;
    ofn.lpstrFilter = std.unicode.utf8ToUtf16LeStringLiteral("Text files (*.txt)\x00*.txt\x00All files (*.*)\x00*.*\x00");
    ofn.lpstrFile = &path;
    ofn.nMaxFile = path.len;
    ofn.lpstrTitle = title16.ptr;
    ofn.lpstrDefExt = std.unicode.utf8ToUtf16LeStringLiteral("txt");
    ofn.Flags = c.OFN_OVERWRITEPROMPT | c.OFN_PATHMUSTEXIST | c.OFN_NOCHANGEDIR;
    if (c.GetSaveFileNameW(&ofn) == 0) return false;

    const path8 = util.utf8Alloc(alloc, std.mem.sliceTo(&path, 0)) catch return false;
    defer alloc.free(path8);
    std.Io.Dir.cwd().writeFile(global.io(), .{ .sub_path = path8, .data = contents }) catch |err| {
        log.warn("error saving file path={s} err={}", .{ path8, err });
        return false;
    };
    return true;
}
