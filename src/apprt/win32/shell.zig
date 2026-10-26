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
    _ = std.unicode.utf8ToUtf16Le(path[0 .. path.len - 1], default_name) catch {};
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
