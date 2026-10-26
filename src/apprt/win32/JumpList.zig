//! The taskbar jump list: tasks shown when right-clicking the taskbar
//! button or the Start menu entry.
//!
//! "New Window" starts ghostty.exe again, which opens a window in the
//! running instance (see Ipc.claim) or starts one.
const std = @import("std");
const c = @import("util.zig").c;
const util = @import("util.zig");

const log = std.log.scoped(.win32);

/// Replace the jump list's tasks. COM must be initialized.
pub fn update() void {
    updateInner() catch |err| log.warn("error updating the jump list err={}", .{err});
}

fn updateInner() !void {
    var exe_buf: [32768]u16 = undefined;
    const exe_len = c.GetModuleFileNameW(null, &exe_buf, exe_buf.len);
    if (exe_len == 0 or exe_len >= exe_buf.len) return error.NoExecutable;
    exe_buf[exe_len] = 0;
    const exe: [*:0]const u16 = exe_buf[0..exe_len :0];

    var list: ?*c.ICustomDestinationList = null;
    try check(c.CoCreateInstance(&c.CLSID_DestinationList, null, c.CLSCTX_INPROC_SERVER, &c.IID_ICustomDestinationList, @ptrCast(&list)));
    defer _ = list.?.lpVtbl.*.Release.?(list);

    var min_slots: c.UINT = 0;
    var removed: ?*c.IObjectArray = null;
    try check(list.?.lpVtbl.*.BeginList.?(list, &min_slots, &c.IID_IObjectArray, @ptrCast(&removed)));
    defer if (removed) |r| {
        _ = r.lpVtbl.*.Release.?(r);
    };

    var tasks: ?*c.IObjectCollection = null;
    try check(c.CoCreateInstance(&c.CLSID_EnumerableObjectCollection, null, c.CLSCTX_INPROC_SERVER, &c.IID_IObjectCollection, @ptrCast(&tasks)));
    defer _ = tasks.?.lpVtbl.*.Release.?(tasks);

    const link = try shellLink(exe, std.unicode.utf8ToUtf16LeStringLiteral(""), std.unicode.utf8ToUtf16LeStringLiteral("New Window"));
    defer _ = link.lpVtbl.*.Release.?(link);
    try check(tasks.?.lpVtbl.*.AddObject.?(tasks, @ptrCast(link)));

    var array: ?*c.IObjectArray = null;
    try check(tasks.?.lpVtbl.*.QueryInterface.?(tasks, &c.IID_IObjectArray, @ptrCast(&array)));
    defer _ = array.?.lpVtbl.*.Release.?(array);
    try check(list.?.lpVtbl.*.AddUserTasks.?(list, array));
    try check(list.?.lpVtbl.*.CommitList.?(list));
}

/// A shell link that runs `exe` with `args`, titled `title`.
fn shellLink(exe: [*:0]const u16, args: [*:0]const u16, title: [*:0]const u16) !*c.IShellLinkW {
    var link: ?*c.IShellLinkW = null;
    try check(c.CoCreateInstance(&c.CLSID_ShellLink, null, c.CLSCTX_INPROC_SERVER, &c.IID_IShellLinkW, @ptrCast(&link)));
    errdefer _ = link.?.lpVtbl.*.Release.?(link);
    try check(link.?.lpVtbl.*.SetPath.?(link, exe));
    try check(link.?.lpVtbl.*.SetArguments.?(link, args));
    try check(link.?.lpVtbl.*.SetIconLocation.?(link, exe, 0));

    // Tasks show their title property.
    var store: ?*c.IPropertyStore = null;
    try check(link.?.lpVtbl.*.QueryInterface.?(link, &c.IID_IPropertyStore, @ptrCast(&store)));
    defer _ = store.?.lpVtbl.*.Release.?(store);
    var value = std.mem.zeroes(c.PROPVARIANT);
    value.unnamed_0.unnamed_0.vt = c.VT_LPWSTR;
    value.unnamed_0.unnamed_0.unnamed_0.pwszVal = @constCast(title);
    try check(store.?.lpVtbl.*.SetValue.?(store, &PKEY_Title, &value));
    try check(store.?.lpVtbl.*.Commit.?(store));
    return link.?;
}

/// PKEY_Title, from propkey.h.
const PKEY_Title: c.PROPERTYKEY = .{
    .fmtid = .{
        .Data1 = 0xf29f85e0,
        .Data2 = 0x4ff9,
        .Data3 = 0x1068,
        .Data4 = .{ 0xab, 0x91, 0x08, 0x00, 0x2b, 0x27, 0xb3, 0xd9 },
    },
    .pid = 2,
};

fn check(hr: c.HRESULT) !void {
    if (hr < 0) return error.ComFailed;
}
