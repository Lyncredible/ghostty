//! Saving and restoring windows, tabs, and splits for `window-save-state`:
//! their placement, tab titles set by the user, split layouts, and each
//! terminal's working directory.
//!
//! The state is saved as JSON in %LOCALAPPDATA%\ghostty when the app quits
//! or the user closes its last window, and restored when it starts. When
//! the last window closes because its shell exited, the state is cleared,
//! since that isn't a session to come back to.
const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../../global.zig");

const util = @import("util.zig");
const c = util.c;
const App = @import("App.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

pub const State = struct {
    version: u32 = 1,
    windows: []const WindowState,
};

pub const WindowState = struct {
    /// The window's restored (not maximized) rectangle, in screen pixels.
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    maximized: bool = false,
    active_tab: usize = 0,
    tabs: []const TabState,
};

pub const TabState = struct {
    title: ?[]const u8 = null,

    /// The index of the focused terminal among the tab's terminals, in
    /// tree order.
    focused: usize = 0,

    /// The split tree's nodes, as in SplitTree: node 0 is the root and
    /// splits refer to their children by index.
    nodes: []const NodeState,
};

pub const NodeState = struct {
    /// For a terminal, its working directory, if known.
    pwd: ?[]const u8 = null,

    /// For a split, its layout, ratio, and children. A node without a
    /// layout is a terminal.
    layout: ?Tab.Tree.Split.Layout = null,
    ratio: f32 = 0.5,
    left: u16 = 0,
    right: u16 = 0,
};

/// Whether the config asks us to save and restore state on every launch.
/// `default` only does so when Windows restarts us, see registerRestart.
pub fn enabled(app: *const App) bool {
    return app.config.@"window-save-state" == .always;
}

/// Save the state of the app's windows, except the quick terminal.
pub fn save(app: *App) void {
    if (!enabled(app)) return;
    write(app);
}

/// Save the state when Windows ends the session (shutting down, restarting,
/// or signing out, as for an update), since the process won't quit on its
/// own. With `default`, Windows restarts us to restore it, see
/// registerRestart; with `never`, we don't save.
pub fn saveForEndSession(app: *App) void {
    if (app.config.@"window-save-state" == .never) return;
    write(app);
}

/// With `window-save-state = default`, follow the system setting to restart
/// apps after signing in ("Automatically save my restartable apps"): Windows
/// restarts us after a reboot or an update, with an argument that restores
/// the windows saved when the session ended. Not after crashes or hangs.
pub fn registerRestart(app: *const App) void {
    if (app.config.@"window-save-state" != .default) return;
    const RESTART_NO_CRASH = 1;
    const RESTART_NO_HANG = 2;
    const hr = RegisterApplicationRestart(
        std.unicode.utf8ToUtf16LeStringLiteral("--window-save-state=always"),
        RESTART_NO_CRASH | RESTART_NO_HANG,
    );
    if (hr < 0) log.warn("failed to register for restart hr={x}", .{hr});
}

extern "kernel32" fn RegisterApplicationRestart(command_line: ?[*:0]const u16, flags: u32) callconv(.winapi) c.HRESULT;

fn write(app: *App) void {
    var arena: std.heap.ArenaAllocator = .init(app.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const state = capture(alloc, app) catch |err| {
        log.warn("error capturing window state err={}", .{err});
        return;
    };
    const json = std.json.Stringify.valueAlloc(alloc, state, .{ .whitespace = .indent_2 }) catch return;
    const file = path(alloc) orelse return;
    if (std.fs.path.dirname(file)) |dir| std.Io.Dir.cwd().createDirPath(global.io(), dir) catch {};
    std.Io.Dir.cwd().writeFile(global.io(), .{ .sub_path = file, .data = json }) catch |err| {
        log.warn("error saving window state path={s} err={}", .{ file, err });
        return;
    };
    log.info("saved window state path={s}", .{file});
}

/// Forget the saved state.
pub fn clear(app: *App) void {
    if (!enabled(app)) return;
    var arena: std.heap.ArenaAllocator = .init(app.core_app.alloc);
    defer arena.deinit();
    const file = path(arena.allocator()) orelse return;
    std.Io.Dir.cwd().deleteFile(global.io(), file) catch {};
}

/// Load the saved state, if there is any. It's allocated in the arena.
pub fn load(arena: Allocator, app: *const App) ?State {
    if (!enabled(app)) return null;
    const file = path(arena) orelse return null;
    const json = std.Io.Dir.cwd().readFileAlloc(global.io(), file, arena, .limited(16 << 20)) catch return null;
    const state = std.json.parseFromSliceLeaky(State, arena, json, .{ .ignore_unknown_fields = true }) catch |err| {
        log.warn("ignoring invalid window state path={s} err={}", .{ file, err });
        return null;
    };
    if (state.version != 1 or state.windows.len == 0) return null;
    return state;
}

fn path(alloc: Allocator) ?[]const u8 {
    const local = global.environ().getAlloc(alloc, "LOCALAPPDATA") catch return null;
    return std.fs.path.join(alloc, &.{ local, "ghostty", "window-state.json" }) catch null;
}

fn capture(alloc: Allocator, app: *App) !State {
    var windows: std.ArrayList(WindowState) = .empty;
    for (app.windows.items) |window| {
        if (window.quick or window.tabs.items.len == 0) continue;

        var placement: c.WINDOWPLACEMENT = undefined;
        placement.length = @sizeOf(c.WINDOWPLACEMENT);
        if (c.GetWindowPlacement(window.hwnd, &placement) == 0) continue;

        var tabs: std.ArrayList(TabState) = .empty;
        for (window.tabs.items) |tab| try tabs.append(alloc, try captureTab(alloc, tab));
        const rect = placement.rcNormalPosition;
        try windows.append(alloc, .{
            .left = rect.left,
            .top = rect.top,
            .right = rect.right,
            .bottom = rect.bottom,
            .maximized = placement.showCmd == c.SW_SHOWMAXIMIZED,
            .active_tab = window.active,
            .tabs = tabs.items,
        });
    }
    return .{ .windows = windows.items };
}

fn captureTab(alloc: Allocator, tab: *const Tab) !TabState {
    const nodes = try alloc.alloc(NodeState, tab.tree.nodes.len);
    for (tab.tree.nodes, nodes) |node, *state| switch (node) {
        .leaf => |surface| {
            state.* = .{
                .pwd = if (surface.core_initialized) surface.core_surface.pwd(alloc) catch null else null,
            };
        },
        .split => |s| state.* = .{
            .layout = s.layout,
            .ratio = @floatCast(s.ratio),
            .left = @intCast(s.left.idx()),
            .right = @intCast(s.right.idx()),
        },
    };
    return .{
        .title = tab.title_override,
        .focused = leafIndex(&tab.tree, tab.focused) orelse 0,
        .nodes = nodes,
    };
}

/// The index of a terminal among a tree's terminals, from left to right
/// (depth first). Unlike the order of the nodes, this survives restoring.
pub fn leafIndex(tree: *const Tab.Tree, surface: *const anyopaque) ?usize {
    var index: usize = 0;
    return leafIndexFrom(tree, .root, surface, &index);
}

fn leafIndexFrom(tree: *const Tab.Tree, handle: Tab.Tree.Node.Handle, surface: *const anyopaque, index: *usize) ?usize {
    if (handle.idx() >= tree.nodes.len) return null;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            if (@as(*const anyopaque, view) == surface) return index.*;
            index.* += 1;
            return null;
        },
        .split => |s| return leafIndexFrom(tree, s.left, surface, index) orelse
            leafIndexFrom(tree, s.right, surface, index),
    }
}

/// The terminal at an index among a tree's terminals, from left to right.
pub fn leafAt(tree: *const Tab.Tree, index: usize) ?*Tab.Tree.View {
    var remaining = index;
    return leafAtFrom(tree, .root, &remaining);
}

fn leafAtFrom(tree: *const Tab.Tree, handle: Tab.Tree.Node.Handle, remaining: *usize) ?*Tab.Tree.View {
    if (handle.idx() >= tree.nodes.len) return null;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            if (remaining.* == 0) return view;
            remaining.* -= 1;
            return null;
        },
        .split => |s| return leafAtFrom(tree, s.left, remaining) orelse
            leafAtFrom(tree, s.right, remaining),
    }
}

test "state round trip" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const state: State = .{ .windows = &.{.{
        .left = 10,
        .top = 20,
        .right = 810,
        .bottom = 620,
        .maximized = true,
        .active_tab = 1,
        .tabs = &.{
            .{ .nodes = &.{.{ .pwd = "C:\\Users\\me" }} },
            .{ .title = "logs", .focused = 1, .nodes = &.{
                .{ .layout = .horizontal, .ratio = 0.25, .left = 1, .right = 2 },
                .{ .pwd = "C:\\src" },
                .{},
            } },
        },
    }} };
    const json = try std.json.Stringify.valueAlloc(alloc, state, .{});
    const parsed = try std.json.parseFromSliceLeaky(State, alloc, json, .{});
    try testing.expectEqual(@as(usize, 2), parsed.windows[0].tabs.len);
    try testing.expectEqualStrings("logs", parsed.windows[0].tabs[1].title.?);
    try testing.expectEqual(Tab.Tree.Split.Layout.horizontal, parsed.windows[0].tabs[1].nodes[0].layout.?);
    try testing.expectEqualStrings("C:\\src", parsed.windows[0].tabs[1].nodes[1].pwd.?);
    try testing.expect(parsed.windows[0].tabs[1].nodes[2].pwd == null);
}
