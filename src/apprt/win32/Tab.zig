//! A tab in a window. A tab is a tree of surfaces (splits).
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const SaveState = @import("SaveState.zig");

const util = @import("util.zig");
const c = util.c;
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const Overrides = @import("Overrides.zig");

const log = std.log.scoped(.win32);

pub const Tree = SplitTree(Surface);

window: *Window,

/// The tree of surfaces in this tab.
tree: Tree,

/// The surface in this tab that has (or last had) focus.
focused: *Surface,

/// A title set by the user, which takes precedence over the focused
/// surface's title.
title_override: ?[:0]const u8 = null,

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

pub fn create(
    window: *Window,
    parent: ?*CoreSurface,
    first: bool,
    shell: ?configpkg.Command,
    overrides: Overrides,
) !*Tab {
    const alloc = window.app.core_app.alloc;

    const surface = try Surface.create(window, .{
        .parent = parent,
        .context = if (first) .window else .tab,
        .shell = shell,
        .overrides = overrides,
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

/// Create a tab from saved state, with a terminal in each saved working
/// directory and the saved splits. `first` is whether this is the first
/// tab of a new window.
pub fn createRestored(window: *Window, state: SaveState.TabState, first: bool) !*Tab {
    const alloc = window.app.core_app.alloc;
    if (state.nodes.len == 0) return error.InvalidState;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var context: apprt.surface.NewSurfaceContext = if (first) .window else .tab;
    var tree = try restoreNode(window, arena.allocator(), state.nodes, 0, &context, 0);
    errdefer tree.deinit();

    // The focused terminal, counting terminals from left to right.
    const focused = SaveState.leafAt(&tree, state.focused) orelse
        SaveState.leafAt(&tree, 0);

    const self = try alloc.create(Tab);
    self.* = .{
        .window = window,
        .tree = tree,
        .focused = focused.?,
    };
    if (state.title) |saved| self.title_override = alloc.dupeSentinel(u8, saved, 0) catch null;
    return self;
}

fn restoreNode(
    window: *Window,
    arena: std.mem.Allocator,
    nodes: []const SaveState.NodeState,
    index: usize,
    context: *apprt.surface.NewSurfaceContext,
    depth: usize,
) !Tree {
    const alloc = window.app.core_app.alloc;
    if (index >= nodes.len or depth > nodes.len) return error.InvalidState;
    const node = nodes[index];

    const split_layout = node.layout orelse {
        const surface = try Surface.create(window, .{
            .context = context.*,
            .overrides = .{
                .working_directory = if (node.pwd) |pwd| try arena.dupeSentinel(u8, pwd, 0) else null,
            },
        });
        context.* = .split;
        return Tree.init(alloc, surface) catch |err| {
            surface.destroy();
            return err;
        };
    };

    var left = try restoreNode(window, arena, nodes, node.left, context, depth + 1);
    defer left.deinit();
    var right = try restoreNode(window, arena, nodes, node.right, context, depth + 1);
    defer right.deinit();
    return try left.split(
        alloc,
        .root,
        switch (split_layout) {
            .horizontal => .right,
            .vertical => .down,
        },
        @floatCast(std.math.clamp(node.ratio, 0.05, 0.95)),
        &right,
    );
}

/// Destroy the tab, which closes all of its surfaces.
pub fn destroy(self: *Tab) void {
    const alloc = self.window.app.core_app.alloc;
    if (self.title_override) |v| alloc.free(v);
    self.dividers.deinit(alloc);
    self.tree.deinit();
    alloc.destroy(self);
}

/// Whether a process is still running in any of the tab's terminals.
pub fn hasRunningProcess(self: *const Tab) bool {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        if (!entry.view.core_surface.child_exited) return true;
    }
    return false;
}

/// The title to show for this tab.
pub fn title(self: *const Tab) [:0]const u8 {
    return self.title_override orelse self.focused.effectiveTitle() orelse "Ghostty";
}

/// Set or clear (with null or an empty title) the user's title override.
pub fn setTitleOverride(self: *Tab, value: ?[]const u8) void {
    const alloc = self.window.app.core_app.alloc;
    if (self.title_override) |v| alloc.free(v);
    self.title_override = null;
    if (value) |v| if (v.len > 0) {
        self.title_override = alloc.dupeSentinel(u8, v, 0) catch null;
    };
    self.window.surfaceTitleChanged(self.focused);
}

/// Returns whether this tab contains the given surface.
pub fn contains(self: *const Tab, surface: *const Surface) bool {
    return self.tree.locate(surface) != null;
}

/// Returns true if this tab only has a single surface.
pub fn isSingle(self: *const Tab) bool {
    return !self.tree.isSplit();
}

/// Whether any split in this tab shows a pending bell in its title.
pub fn hasBell(self: *const Tab) bool {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        const view = entry.view;
        if (view.bell_pending and view.bell_features.title) return true;
    }
    return false;
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
    self.updateDimming();
    _ = c.SetFocus(surface.hwnd);
    self.window.surfaceFocused(surface);
}

/// Dim all other splits even when the top-level window loses focus.
pub fn updateDimming(self: *Tab) void {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        entry.view.dim_overlay.setDimmed(entry.view != self.focused);
    }
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
        .shell = from.shell,
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
    // Destroying the removed surface can synchronously send focus
    // messages to the parent window. Publish its replacement before
    // releasing the old tree so activeSurface() never returns it.
    if (next) |n| self.focused = n;
    self.replaceTree(new_tree);

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
    self.updateDimming();
    self.updateDragHandles();
}

/// Show the drag handles per the drag-handle config: with `auto`, only
/// when there's more than one split to rearrange.
pub fn updateDragHandles(self: *Tab) void {
    const show = switch (self.window.app.config.@"drag-handle") {
        .always => true,
        .auto => !self.isSingle() and self.tree.zoomed == null,
        .never => false,
    };
    var it = self.tree.iterator();
    while (it.next()) |entry| entry.view.drag_handle.setShown(show);
}

/// The terminal at a point on the screen, if any.
pub fn surfaceAt(self: *const Tab, pt: c.POINT) ?*Surface {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        var rect: c.RECT = undefined;
        if (c.GetWindowRect(entry.view.hwnd, &rect) == 0) continue;
        if (c.PtInRect(&rect, pt) != 0) return entry.view;
    }
    return null;
}

/// Move a terminal next to another in this tab, like GTK's moveSplit.
pub fn moveSplit(self: *Tab, source: *Surface, target: *Surface, direction: Tree.Split.Direction) !void {
    if (source == target) return;
    const alloc = self.window.app.core_app.alloc;
    const target_handle = self.tree.locate(target) orelse return;
    const source_handle = self.tree.locate(source) orelse return;

    var branch: Tree = try .init(alloc, source);
    defer branch.deinit();
    var after_split = try self.tree.split(alloc, target_handle, direction, 0.5, &branch);
    defer after_split.deinit();
    const after_remove = try after_split.remove(alloc, source_handle);
    self.replaceTree(after_remove);

    self.window.layout();
    self.focus(source);
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
