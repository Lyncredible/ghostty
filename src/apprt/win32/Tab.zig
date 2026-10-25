//! A tab in a window. A tab is a tree of surfaces (splits).
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

const util = @import("util.zig");
const c = util.c;
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

pub const Tree = SplitTree(Surface);

window: *Window,

/// The tree of surfaces in this tab.
tree: Tree,

/// The surface in this tab that has (or last had) focus.
focused: *Surface,

/// The dividers between splits from the last layout, used to resize
/// splits with the mouse.
dividers: std.ArrayList(Divider) = .empty,

/// A divider between the two sides of a split.
pub const Divider = struct {
    /// The split node this divides.
    handle: Tree.Node.Handle,

    /// The layout of the split.
    layout: Tree.Split.Layout,

    /// The divider's rectangle, in window client coordinates.
    rect: c.RECT,

    /// The rectangle of the whole split, used to compute ratios.
    split_rect: c.RECT,
};

pub fn create(window: *Window, parent: ?*CoreSurface, first: bool) !*Tab {
    const alloc = window.app.core_app.alloc;

    const surface = try Surface.create(window, .{
        .parent = parent,
        .context = if (first) .window else .tab,
    });
    errdefer surface.destroy();

    var tree: Tree = try .init(alloc, surface);
    errdefer tree.deinit();

    const self = try alloc.create(Tab);
    self.* = .{
        .window = window,
        .tree = tree,
        .focused = surface,
    };
    return self;
}

/// Destroy the tab, which closes all of its surfaces.
pub fn destroy(self: *Tab) void {
    const alloc = self.window.app.core_app.alloc;
    self.dividers.deinit(alloc);
    self.tree.deinit();
    alloc.destroy(self);
}

/// Returns whether this tab contains the given surface.
pub fn contains(self: *const Tab, surface: *const Surface) bool {
    return self.tree.locate(surface) != null;
}

/// Returns true if this tab only has a single surface.
pub fn isSingle(self: *const Tab) bool {
    return !self.tree.isSplit();
}

/// Returns true if closing this tab requires confirmation.
pub fn needsConfirmQuit(self: *const Tab) bool {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.core_surface.needsConfirmQuit()) return true;
    }
    return false;
}

/// Show or hide all of the surfaces in this tab.
pub fn setVisible(self: *Tab, visible: bool) void {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        const shown = visible and self.isShown(entry.handle);
        if ((c.IsWindowVisible(entry.view.hwnd) != 0) == shown) continue;
        _ = c.ShowWindow(entry.view.hwnd, if (shown) c.SW_SHOWNA else c.SW_HIDE);
        entry.view.setVisible(shown);
    }
}

/// Whether the given leaf is shown, which is all of them unless a
/// split is zoomed.
fn isShown(self: *const Tab, handle: Tree.Node.Handle) bool {
    const zoomed = self.tree.zoomed orelse return true;
    return zoomed == handle;
}

/// Focus the given surface in this tab.
pub fn focus(self: *Tab, surface: *Surface) void {
    self.focused = surface;
    _ = c.SetFocus(surface.hwnd);
}

/// Replace our tree with a new tree, freeing the old one. Any surfaces
/// that aren't in the new tree are destroyed.
fn replaceTree(self: *Tab, tree: Tree) void {
    var old = self.tree;
    self.tree = tree;
    old.deinit();
}

/// Split the given surface in the given direction, creating and
/// focusing a new surface.
pub fn split(
    self: *Tab,
    from: *Surface,
    direction: apprt.action.SplitDirection,
) !void {
    const alloc = self.window.app.core_app.alloc;
    const at = self.tree.locate(from) orelse return;

    const surface = try Surface.create(self.window, .{
        .parent = &from.core_surface,
        .context = .split,
    });
    var insert: Tree = Tree.init(alloc, surface) catch |err| {
        surface.destroy();
        return err;
    };
    defer insert.deinit();

    const new_tree = try self.tree.split(
        alloc,
        at,
        switch (direction) {
            .right => .right,
            .left => .left,
            .down => .down,
            .up => .up,
        },
        0.5,
        &insert,
    );
    self.replaceTree(new_tree);

    self.window.layout();
    self.focus(surface);
}

/// Remove the given surface from the tab, destroying it. The tab must
/// have more than one surface.
pub fn remove(self: *Tab, surface: *Surface) !void {
    const alloc = self.window.app.core_app.alloc;
    const at = self.tree.locate(surface) orelse return;
    std.debug.assert(!self.isSingle());

    // Find the surface to focus next if we're removing the focused one.
    const next: ?*Surface = if (surface == self.focused) next: {
        const handle = (self.tree.goto(alloc, at, .previous) catch null) orelse
            (self.tree.goto(alloc, at, .next) catch null) orelse
            break :next null;
        break :next self.tree.nodes[handle.idx()].leaf;
    } else null;

    const new_tree = try self.tree.remove(alloc, at);
    self.replaceTree(new_tree);

    if (next) |n| self.focused = n;
    self.window.layout();
    if (next) |n| self.focus(n);
}

/// Move focus to another split, returning true if focus moved.
pub fn gotoSplit(self: *Tab, from: *Surface, to: apprt.action.GotoSplit) bool {
    const alloc = self.window.app.core_app.alloc;
    const at = self.tree.locate(from) orelse return false;
    const handle = (self.tree.goto(alloc, at, switch (to) {
        .previous => .previous_wrapped,
        .next => .next_wrapped,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    }) catch return false) orelse return false;

    const target = self.tree.nodes[handle.idx()].leaf;
    if (target == from) return false;

    // Moving focus out of a zoomed split unzooms it, otherwise we'd
    // focus a hidden surface.
    if (self.tree.zoomed != null) {
        self.tree.zoom(null);
        self.window.layout();
    }

    self.focus(target);
    return true;
}

/// Resize the nearest split of the given surface in the given direction.
pub fn resizeSplit(
    self: *Tab,
    from: *Surface,
    resize: apprt.action.ResizeSplit,
    area: c.RECT,
) !bool {
    if (resize.amount == 0) return false;
    const alloc = self.window.app.core_app.alloc;
    const at = self.tree.locate(from) orelse return false;

    const width: f64 = @floatFromInt(area.right - area.left);
    const height: f64 = @floatFromInt(area.bottom - area.top);
    if (width <= 0 or height <= 0) return false;
    const amount: f64 = @floatFromInt(resize.amount);

    // Convert our pixel amount into a ratio of the whole tree, with the
    // sign giving the direction.
    const ratio: f64 = switch (resize.direction) {
        .right => amount / width,
        .left => -(amount / width),
        .down => amount / height,
        .up => -(amount / height),
    };
    const split_layout: Tree.Split.Layout = switch (resize.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    const new_tree = try self.tree.resize(
        alloc,
        at,
        split_layout,
        @floatCast(std.math.clamp(ratio, -1, 1)),
    );
    self.replaceTree(new_tree);
    self.window.layout();
    return true;
}

/// Make all splits the same size.
pub fn equalize(self: *Tab) !void {
    const alloc = self.window.app.core_app.alloc;
    const new_tree = try self.tree.equalize(alloc);
    self.replaceTree(new_tree);
    self.window.layout();
}

/// Toggle zooming the given surface to fill the whole tab.
pub fn toggleZoom(self: *Tab, surface: *Surface) bool {
    if (self.isSingle()) return false;
    const at = self.tree.locate(surface) orelse return false;
    self.tree.zoom(if (self.tree.zoomed == null) at else null);
    self.window.layout();
    self.focus(surface);
    return true;
}

/// Lay out the surfaces of this tab within the given area of the window.
pub fn layout(self: *Tab, area: c.RECT) void {
    const alloc = self.window.app.core_app.alloc;
    self.dividers.clearRetainingCapacity();

    if (self.tree.zoomed) |zoomed| {
        self.layoutLeaf(zoomed, area);
    } else if (!self.tree.isEmpty()) {
        self.layoutNode(alloc, .root, area);
    }

    // Visibility depends on the zoom state.
    self.setVisible(true);
}

fn layoutLeaf(self: *Tab, handle: Tree.Node.Handle, rect: c.RECT) void {
    const surface = self.tree.nodes[handle.idx()].leaf;
    _ = c.MoveWindow(
        surface.hwnd,
        rect.left,
        rect.top,
        @max(0, rect.right - rect.left),
        @max(0, rect.bottom - rect.top),
        c.TRUE,
    );
}

fn layoutNode(
    self: *Tab,
    alloc: Allocator,
    handle: Tree.Node.Handle,
    rect: c.RECT,
) void {
    switch (self.tree.nodes[handle.idx()]) {
        .leaf => self.layoutLeaf(handle, rect),
        .split => |s| {
            const divider = self.dividerSize();
            var left = rect;
            var right = rect;
            var div = rect;
            switch (s.layout) {
                .horizontal => {
                    const total = rect.right - rect.left - divider;
                    const pos = rect.left + splitPos(total, s.ratio);
                    left.right = pos;
                    div.left = pos;
                    div.right = pos + divider;
                    right.left = pos + divider;
                },
                .vertical => {
                    const total = rect.bottom - rect.top - divider;
                    const pos = rect.top + splitPos(total, s.ratio);
                    left.bottom = pos;
                    div.top = pos;
                    div.bottom = pos + divider;
                    right.top = pos + divider;
                },
            }

            self.dividers.append(alloc, .{
                .handle = handle,
                .layout = s.layout,
                .rect = div,
                .split_rect = rect,
            }) catch {};

            self.layoutNode(alloc, s.left, left);
            self.layoutNode(alloc, s.right, right);
        },
    }
}

fn splitPos(total: c_int, ratio: f16) c_int {
    const pos: f32 = @as(f32, @floatFromInt(@max(0, total))) * @as(f32, ratio);
    return @intFromFloat(@round(pos));
}

/// The thickness of the dividers between splits, in pixels.
pub fn dividerSize(self: *const Tab) c_int {
    const dpi = c.GetDpiForWindow(self.window.hwnd);
    return @intCast(@max(1, @divFloor(dpi, util.USER_DEFAULT_SCREEN_DPI)));
}

/// Returns the divider at the given point (in window client coordinates),
/// if any. The hit area is a little larger than the divider itself to
/// make it easier to grab.
pub fn dividerAt(self: *const Tab, x: c_int, y: c_int) ?Divider {
    const slop: c_int = 3 * self.dividerSize();
    for (self.dividers.items) |d| {
        if (x >= d.rect.left - slop and x < d.rect.right + slop and
            y >= d.rect.top - slop and y < d.rect.bottom + slop)
        {
            return d;
        }
    }
    return null;
}

/// Move a divider so that it's at the given point.
pub fn dragDivider(self: *Tab, d: Divider, x: c_int, y: c_int) void {
    const divider = self.dividerSize();
    const start: c_int, const total: c_int, const pos: c_int = switch (d.layout) {
        .horizontal => .{ d.split_rect.left, d.split_rect.right - d.split_rect.left - divider, x },
        .vertical => .{ d.split_rect.top, d.split_rect.bottom - d.split_rect.top - divider, y },
    };
    if (total <= 0) return;

    const ratio = std.math.clamp(
        @as(f32, @floatFromInt(pos - start)) / @as(f32, @floatFromInt(total)),
        0.05,
        0.95,
    );
    self.tree.resizeInPlace(d.handle, @floatCast(ratio));
    self.window.layout();
}
