//! The taskbar jump list: tasks shown when right-clicking the taskbar
//! button or the Start menu entry.
//!
//! "New Window" starts ghostty.exe again (with our class, if it's custom),
//! which opens a window in the running instance (see Ipc.claim) or starts
//! one. After it, a task per shell (as in the new tab menu: Command Prompt,
//! PowerShell, each WSL distribution) opens a window with that shell, with
//! the shell's icon, like Windows Terminal's profiles.
const std = @import("std");
const c = @import("util.zig").c;
const util = @import("util.zig");
const shells = @import("shells.zig");
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.win32);

/// Replace the jump list's tasks on another thread. It takes the shell
/// tens of milliseconds, which delayed the first window. `class` is the
/// app's class, if it's custom.
pub fn updateInBackground(class: ?[]const u8) void {
    const Thread = struct {
        // Classes are AppUserModelIDs, at most 128 characters.
        var class_buf: [128]u8 = undefined;

        fn run(len: ?usize) void {
            const hr = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
            defer if (hr >= 0) c.CoUninitialize();
            update(if (len) |n| class_buf[0..n] else null);
        }
    };

    var len: ?usize = null;
    if (class) |v| {
        if (v.len > Thread.class_buf.len) return;
        @memcpy(Thread.class_buf[0..v.len], v);
        len = v.len;
    }
    const thread = std.Thread.spawn(.{}, Thread.run, .{len}) catch |err| {
        log.warn("error starting the jump list thread err={}", .{err});
        return;
    };
    thread.detach();
}

/// Replace the jump list's tasks. COM must be initialized. `class` is the
/// app's class, if it's custom.
pub fn update(class: ?[]const u8) void {
    updateInner(class) catch |err| log.warn("error updating the jump list err={}", .{err});
}

fn updateInner(class: ?[]const u8) !void {
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

    // A custom class has its own jump list (it's the AppUserModelID), and
    // its new windows belong to its instance.
    var args_buf: [300]u16 = undefined;
    const args: [*:0]const u16 = args: {
        const custom = class orelse break :args std.unicode.utf8ToUtf16LeStringLiteral("");
        var utf8_buf: [300]u8 = undefined;
        const utf8 = std.fmt.bufPrint(&utf8_buf, "\"--class={s}\"", .{custom}) catch return error.ClassTooLong;
        const n = std.unicode.utf8ToUtf16Le(args_buf[0 .. args_buf.len - 1], utf8) catch return error.ClassTooLong;
        args_buf[n] = 0;
        break :args args_buf[0..n :0];
    };
    const link = try shellLink(exe, args, std.unicode.utf8ToUtf16LeStringLiteral("New Window"), exe);
    defer _ = link.lpVtbl.*.Release.?(link);
    try check(tasks.?.lpVtbl.*.AddObject.?(tasks, @ptrCast(link)));

    // A window with each shell. Missing shells only cost their tasks.
    addShellTasks(exe, class, tasks.?) catch |err| log.warn("error adding the shells to the jump list err={}", .{err});

    var array: ?*c.IObjectArray = null;
    try check(tasks.?.lpVtbl.*.QueryInterface.?(tasks, &c.IID_IObjectArray, @ptrCast(&array)));
    defer _ = array.?.lpVtbl.*.Release.?(array);
    try check(list.?.lpVtbl.*.AddUserTasks.?(list, array));
    try check(list.?.lpVtbl.*.CommitList.?(list));
}

/// Add a task per shell (but the configured one, which is "New Window")
/// that opens a window running it: `ghostty.exe -e <shell>`, titled with
/// the shell's name and showing its program's icon.
fn addShellTasks(exe: [*:0]const u16, class: ?[]const u8, tasks: *c.IObjectCollection) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    for (try shells.list(alloc)) |shell| {
        const command = shell.command orelse continue;
        const argv = switch (command) {
            .direct => |v| v,
            .shell => continue,
        };
        if (argv.len == 0) continue;

        const args = try taskArguments(alloc, class, argv);
        const link = try shellLink(
            exe,
            try std.unicode.utf8ToUtf16LeAllocZ(alloc, args),
            try std.unicode.utf8ToUtf16LeAllocZ(alloc, shell.label),
            try std.unicode.utf8ToUtf16LeAllocZ(alloc, argv[0]),
        );
        defer _ = link.lpVtbl.*.Release.?(link);
        try check(tasks.lpVtbl.*.AddObject.?(tasks, @ptrCast(link)));
    }
}

/// The arguments of a shell's task: our class, if custom, and `-e` with
/// the shell's program and arguments, quoted for the command line.
fn taskArguments(alloc: std.mem.Allocator, class: ?[]const u8, argv: []const [:0]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    if (class) |v| try out.writer.print("\"--class={s}\" ", .{v});
    try out.writer.writeAll("-e");
    for (argv) |arg| {
        try out.writer.writeByte(' ');
        try internal_os.windows.writeCommandLineArg(&out.writer, arg);
    }
    return out.written();
}

test taskArguments {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings(
        "-e C:\\Windows\\system32\\cmd.exe",
        try taskArguments(alloc, null, &.{"C:\\Windows\\system32\\cmd.exe"}),
    );
    try testing.expectEqualStrings(
        "\"--class=com.example.work\" -e \"C:\\Program Files\\PowerShell\\7\\pwsh.exe\"",
        try taskArguments(alloc, "com.example.work", &.{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"}),
    );
    try testing.expectEqualStrings(
        "-e wsl.exe -d \"Ubuntu 24.04\" \"\" \"a\\\"b\" \"c d\\\\\"",
        try taskArguments(alloc, null, &.{ "wsl.exe", "-d", "Ubuntu 24.04", "", "a\"b", "c d\\" }),
    );
}

/// A shell link that runs `exe` with `args`, titled `title`, with the icon
/// of the program `icon`.
fn shellLink(exe: [*:0]const u16, args: [*:0]const u16, title: [*:0]const u16, icon: [*:0]const u16) !*c.IShellLinkW {
    var link: ?*c.IShellLinkW = null;
    try check(c.CoCreateInstance(&c.CLSID_ShellLink, null, c.CLSCTX_INPROC_SERVER, &c.IID_IShellLinkW, @ptrCast(&link)));
    errdefer _ = link.?.lpVtbl.*.Release.?(link);
    try check(link.?.lpVtbl.*.SetPath.?(link, exe));
    try check(link.?.lpVtbl.*.SetArguments.?(link, args));
    try check(link.?.lpVtbl.*.SetIconLocation.?(link, icon, 0));

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
