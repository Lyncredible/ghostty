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
    if (!SaveState.validTree(state.nodes)) return error.InvalidState;

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
            // The shell chosen for it, or the configured command.
            .shell = if (node.command) |command| try command.command(arena) else null,
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
        // The window's own WS_VISIBLE, not IsWindowVisible: that's false
        // for every child while the window is hidden (as when restoring a
        // session), which skipped hiding the other tabs, and they all
        // showed up with the window.
        const has_visible = c.GetWindowLongPtrW(entry.view.hwnd, c.GWL_STYLE) & c.WS_VISIBLE != 0;
        if (has_visible == shown) continue;
        _ = c.ShowWindow(entry.view.hwnd, if (shown) c.SW_SHOWNA else c.SW_HIDE);
        entry.view.setVisible(shown);
    }
}

/// Tell the shown surfaces whether anyone can see them, when the window
/// is minimized or restored. Their windows stay shown, so the taskbar's
/// preview keeps the last frame.
pub fn setMinimized(self: *Tab, minimized: bool) void {
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        if (self.isShown(entry.handle)) entry.view.setVisible(!minimized);
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

/// Where a surface was in the split tree, so that it can be put back
/// after it's removed: next to the terminals it was split from, on the
/// same side and with the same size.
pub const Placement = struct {
    /// The terminals of the subtree on the other side of the split.
    /// They aren't referenced; we only compare them.
    siblings: []*Surface,
    direction: Tree.Split.Direction,
    ratio: f16,

    pub fn deinit(self: *Placement, alloc: Allocator) void {
        alloc.free(self.siblings);
    }
};

/// Where the given surface is. The tab must have more than one surface.
pub fn placement(self: *const Tab, alloc: Allocator, surface: *const Surface) !Placement {
    const at = self.tree.locate(surface) orelse return error.NotFound;
    for (self.tree.nodes) |node| switch (node) {
        .leaf => {},
        .split => |s| {
            if (s.left != at and s.right != at) continue;
            const sibling = if (s.left == at) s.right else s.left;
            var siblings: std.ArrayList(*Surface) = .empty;
            errdefer siblings.deinit(alloc);
            try self.collectLeaves(alloc, sibling, &siblings);
            return .{
                .siblings = try siblings.toOwnedSlice(alloc),
                .direction = switch (s.layout) {
                    .horizontal => if (s.left == at) .left else .right,
                    .vertical => if (s.left == at) .up else .down,
                },
                .ratio = s.ratio,
            };
        },
    };
    return error.NotFound;
}

fn collectLeaves(
    self: *const Tab,
    alloc: Allocator,
    handle: Tree.Node.Handle,
    list: *std.ArrayList(*Surface),
) !void {
    switch (self.tree.nodes[handle.idx()]) {
        .leaf => |view| try list.append(alloc, view),
        .split => |s| {
            try self.collectLeaves(alloc, s.left, list);
            try self.collectLeaves(alloc, s.right, list);
        },
    }
}

/// Put a removed surface back where it was, and focus it. If the
/// terminals it was split from have changed, it goes next to the one
/// that's left, or splits the whole tab.
pub fn restore(self: *Tab, surface: *Surface, where: Placement) !void {
    const alloc = self.window.app.core_app.alloc;
    const at = try self.siblingNode(alloc, where.siblings);

    var insert: Tree = try .init(alloc, surface);
    defer insert.deinit();
    const new_tree = try self.tree.split(alloc, at, where.direction, where.ratio, &insert);
    self.replaceTree(new_tree);

    self.window.layout();
    self.setVisible(true);
    self.focus(surface);
}

/// The node whose terminals are exactly the given ones, or else a node
/// with one of them, or else the root.
fn siblingNode(self: *const Tab, alloc: Allocator, siblings: []const *Surface) !Tree.Node.Handle {
    var leaves: std.ArrayList(*Surface) = .empty;
    defer leaves.deinit(alloc);
    for (0..self.tree.nodes.len) |i| {
        const handle: Tree.Node.Handle = @fromBackingInt(@intCast(i));
        leaves.clearRetainingCapacity();
        try self.collectLeaves(alloc, handle, &leaves);
        if (leaves.items.len != siblings.len) continue;
        const same = for (siblings) |sibling| {
            if (std.mem.indexOfScalar(*Surface, leaves.items, sibling) == null) break false;
        } else true;
        if (same) return handle;
    }

    for (siblings) |sibling| {
        if (self.tree.locate(sibling)) |handle| return handle;
    }
    return .root;
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
    // focus a hidden surface. With `split-preserve-zoom = navigation`,
    // like GTK, the target is zoomed instead.
    if (self.tree.zoomed != null) {
        const preserve = self.window.app.config.@"split-preserve-zoom".navigation;
        self.tree.zoom(if (preserve) handle else null);
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
            const parts: SplitRects = .init(rect, s.layout, s.ratio, self.dividerSize());
            self.dividers.append(alloc, .{
                .handle = handle,
                .layout = s.layout,
                .rect = parts.divider,
                .split_rect = rect,
            }) catch {};

            self.layoutNode(alloc, s.left, parts.left);
            self.layoutNode(alloc, s.right, parts.right);
        },
    }
}

/// A split's two sides and the divider between them.
const SplitRects = struct {
    left: c.RECT,
    divider: c.RECT,
    right: c.RECT,

    /// Split `rect` at `ratio` of the room left after the divider. The
    /// left (or top) side gets the ratio, the right (or bottom) the rest.
    fn init(rect: c.RECT, layout_: Tree.Split.Layout, ratio: f16, divider: c_int) SplitRects {
        var parts: SplitRects = .{ .left = rect, .divider = rect, .right = rect };
        switch (layout_) {
            .horizontal => {
                const pos = rect.left + splitPos(rect.right - rect.left - divider, ratio);
                parts.left.right = pos;
                parts.divider.left = pos;
                parts.divider.right = pos + divider;
                parts.right.left = pos + divider;
            },
            .vertical => {
                const pos = rect.top + splitPos(rect.bottom - rect.top - divider, ratio);
                parts.left.bottom = pos;
                parts.divider.top = pos;
                parts.divider.bottom = pos + divider;
                parts.right.top = pos + divider;
            },
        }
        return parts;
    }
};

fn splitPos(total: c_int, ratio: f16) c_int {
    const pos: f32 = @as(f32, @floatFromInt(@max(0, total))) * @as(f32, ratio);
    return @intFromFloat(@round(pos));
}

test SplitRects {
    const testing = std.testing;
    const rect: c.RECT = .{ .left = 10, .top = 20, .right = 1011, .bottom = 621 };

    // Side by side: the 1000 pixels left after the divider are shared.
    const h: SplitRects = .init(rect, .horizontal, 0.5, 1);
    try testing.expectEqual(c.RECT{ .left = 10, .top = 20, .right = 510, .bottom = 621 }, h.left);
    try testing.expectEqual(c.RECT{ .left = 510, .top = 20, .right = 511, .bottom = 621 }, h.divider);
    try testing.expectEqual(c.RECT{ .left = 511, .top = 20, .right = 1011, .bottom = 621 }, h.right);

    // Stacked, a quarter on top, with a 2 pixel divider (192 DPI).
    const v: SplitRects = .init(rect, .vertical, 0.25, 2);
    try testing.expectEqual(@as(c_int, 20 + 150), v.left.bottom);
    try testing.expectEqual(c.RECT{ .left = 10, .top = 170, .right = 1011, .bottom = 172 }, v.divider);
    try testing.expectEqual(@as(c_int, 172), v.right.top);
    try testing.expectEqual(rect.bottom, v.right.bottom);

    // Too small for the divider: the left side is empty (the right is
    // inverted, which layoutLeaf sizes as empty too).
    const tiny: SplitRects = .init(.{ .left = 0, .top = 0, .right = 0, .bottom = 5 }, .horizontal, 0.5, 1);
    try testing.expectEqual(@as(c_int, 0), tiny.left.right - tiny.left.left);
    try testing.expectEqual(@as(c_int, 1), tiny.divider.right);
}

/// The ratio that puts a split's divider at a point, kept between 5% and
/// 95% so neither side disappears; null if the split has no room.
fn dragRatio(split_rect: c.RECT, layout_: Tree.Split.Layout, divider: c_int, x: c_int, y: c_int) ?f32 {
    const start: c_int, const total: c_int, const pos: c_int = switch (layout_) {
        .horizontal => .{ split_rect.left, split_rect.right - split_rect.left - divider, x },
        .vertical => .{ split_rect.top, split_rect.bottom - split_rect.top - divider, y },
    };
    if (total <= 0) return null;
    return std.math.clamp(
        @as(f32, @floatFromInt(pos - start)) / @as(f32, @floatFromInt(total)),
        0.05,
        0.95,
    );
}

test dragRatio {
    const testing = std.testing;
    const rect: c.RECT = .{ .left = 100, .top = 0, .right = 1101, .bottom = 501 };
    try testing.expectApproxEqAbs(@as(f32, 0.3), dragRatio(rect, .horizontal, 1, 400, 0).?, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dragRatio(rect, .vertical, 1, 0, 250).?, 0.001);
    // Dragged past either end, a side keeps 5%.
    try testing.expectEqual(@as(f32, 0.05), dragRatio(rect, .horizontal, 1, -500, 0).?);
    try testing.expectEqual(@as(f32, 0.95), dragRatio(rect, .horizontal, 1, 5000, 0).?);
    // No room to drag in.
    try testing.expect(dragRatio(.{ .left = 0, .top = 0, .right = 1, .bottom = 1 }, .horizontal, 1, 0, 0) == null);
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
    const ratio = dragRatio(d.split_rect, d.layout, self.dividerSize(), x, y) orelse return;
    self.tree.resizeInPlace(d.handle, @floatCast(ratio));
    self.window.layout();
}
