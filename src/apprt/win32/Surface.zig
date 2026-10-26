//! A terminal surface. Each surface is a child window that the renderer
//! presents into, and which receives keyboard and mouse input.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");

const util = @import("util.zig");
const c = util.c;
const key = @import("key.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const DimOverlay = @import("DimOverlay.zig");
const BellBorder = @import("BellBorder.zig");
const TitleDialog = @import("TitleDialog.zig");
const LinkPreview = @import("LinkPreview.zig");
const Scrollbar = @import("Scrollbar.zig");
const Badge = @import("Badge.zig");
const SearchBar = @import("SearchBar.zig");
const Overrides = @import("Overrides.zig");
const Menu = @import("Menu.zig");
const CommandPalette = @import("CommandPalette.zig");
const InspectorWindow = @import("InspectorWindow.zig");
const drop = @import("drop.zig");
const SplitDrag = @import("SplitDrag.zig");
const Accessibility = @import("Accessibility.zig");
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.win32);

app: *App,

/// The window that hosts this surface.
window: *Window,

/// The child window we render to and receive input on.
hwnd: c.HWND,

/// The core surface. This is only valid while `core_initialized` is true.
core_surface: CoreSurface,
core_initialized: bool = false,

/// Current size of the surface in pixels.
size: apprt.SurfaceSize,

/// Current content scale (DPI / 96).
content_scale: apprt.ContentScale,

/// The last known cursor position, in pixels.
cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },

/// Whether we're tracking the mouse to get WM_MOUSELEAVE.
tracking_mouse: bool = false,

/// Whether the core left the last right button press to us, so we show
/// the context menu when it's released.
context_menu_pending: bool = false,

/// The cursor to show when the mouse is over us, and whether it's hidden.
cursor: c.HCURSOR,
cursor_hidden: bool = false,

/// The current title, if one was set.
title: ?[:0]const u8 = null,

/// A title set by the user, which takes precedence over `title`.
title_override: ?[:0]const u8 = null,

/// Bell behavior from this surface's config, including conditional config.
bell_features: configpkg.Config.BellFeatures = .{},

/// True from a bell until this surface is focused or receives key input.
/// This drives the `title` and `border` bell features.
bell_pending: bool = false,

/// The background and foreground colors set by the terminal (OSC 10 and
/// 11), which the tab bar follows. Null for the configured colors.
background_color: ?terminal.color.RGB = null,
foreground_color: ?terminal.color.RGB = null,
notify_on_command_finish: configpkg.Config.NotifyOnCommandFinish = .never,
notify_on_command_finish_action: configpkg.Config.NotifyOnCommandFinishAction = .{},
notify_on_command_finish_after: configpkg.Config.Duration = .{ .duration = 5 * std.time.ns_per_s },

/// The most recent terminal progress report, expiring after 15 seconds.
progress_style: bool = true,
progress_report: ?terminal.osc.Command.ProgressReport = null,
progress_value: ?u8 = null,
progress_expires_at: u64 = 0,

dim_overlay: DimOverlay = .{},
bell_border: BellBorder = .{},
link_preview: LinkPreview = .{},
scrollbar: Scrollbar = .{},

/// Indicators for read-only mode, active key tables and sequences, and
/// renderer failures.
readonly_badge: Badge = .{},
key_badge: Badge = .{},
health_badge: Badge = .{},

/// A short message that hides itself, like GTK's toasts.
toast_badge: Badge = .{},

/// Our UI Automation provider, for screen readers.
accessibility: ?*Accessibility = null,

/// When we last got key input, in GetTickCount64 milliseconds.
last_key_ms: u64 = 0,

/// The vertical position of an ongoing touch pan, in screen pixels.
pan_y: ?c_int = null,

/// The handle to drag this split elsewhere, and the highlight where a
/// dragged split would drop on us.
drag_handle: SplitDrag.Handle = .{},
drop_zone: SplitDrag.DropZone = .{},

/// The terminal size shown while resizing, per resize-overlay.
resize_badge: Badge = .{},
resize_overlay: configpkg.Config.ResizeOverlay = .@"after-first",
resize_overlay_ms: u32 = 750,

/// The grid size from the last resize, null before the first.
last_grid: ?struct { columns: u32, rows: u32 } = null,

/// The size of a cell in pixels, from the core, for window-step-resize.
cell_size: ?apprt.action.CellSize = null,
search_bar: SearchBar = .{},
command_palette: CommandPalette = .{},

/// The terminal inspector's window, while it's open.
inspector: ?*InspectorWindow = null,

/// The search state from the core, shown in the search bar.
search_total: ?usize = null,
search_selected: ?usize = null,

/// Active key tables (innermost last) and the pending key sequence, as
/// display labels.
key_tables: std.ArrayList([:0]const u8) = .empty,
key_sequence: std.ArrayList([:0]const u8) = .empty,

/// An explicitly selected command, owned by this surface and inherited by splits.
shell: ?configpkg.Command = null,

/// Whether our command runs WSL, so that dropped files are pasted as
/// Linux paths.
runs_wsl: bool = false,

/// A pending high surrogate from a standalone WM_CHAR.
high_surrogate: ?u16 = null,

/// The number of split trees referencing this surface. The surface is
/// destroyed when the last reference is released. See `ref`.
ref_count: usize = 0,

pub const Options = struct {
    /// The surface to inherit properties from, if any.
    parent: ?*CoreSurface = null,

    /// The context the surface is being created in.
    context: apprt.surface.NewSurfaceContext = .window,

    shell: ?configpkg.Command = null,

    /// Overrides from +new-window or +new-tab. These only apply to this
    /// surface, not to splits from it.
    overrides: Overrides = .none,
};

/// Allocate and initialize a new surface in the given window. The
/// surface starts with no references; it's destroyed when the last
/// split tree holding it releases it, or with `destroy`.
pub fn create(window: *Window, opts: Options) !*Surface {
    const alloc = window.app.core_app.alloc;
    const self = try alloc.create(Surface);
    errdefer alloc.destroy(self);
    try self.init(window.app, window, opts);
    return self;
}

/// Deinitialize and free the surface, and destroy its window.
pub fn destroy(self: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const hwnd = self.hwnd;
    self.deinit();
    _ = c.DestroyWindow(hwnd);
    alloc.destroy(self);
}

// The functions below implement the view interface for SplitTree.

pub fn ref(self: *Surface) *Surface {
    self.ref_count += 1;
    return self;
}

pub fn unref(self: *Surface) void {
    std.debug.assert(self.ref_count > 0);
    self.ref_count -= 1;
    if (self.ref_count == 0) self.destroy();
}

pub fn eql(self: *const Surface, other: *const Surface) bool {
    return self == other;
}

pub fn init(self: *Surface, app: *App, window: *Window, opts: Options) !void {
    const alloc = app.core_app.alloc;

    self.* = .{
        .app = app,
        .window = window,
        .hwnd = undefined,
        .core_surface = undefined,
        .size = .{ .width = 0, .height = 0 },
        .content_scale = .{ .x = 1, .y = 1 },
        .cursor = util.loadSystemCursor(util.IDC_IBEAM),
    };

    var parent_rect: c.RECT = undefined;
    _ = c.GetClientRect(window.hwnd, &parent_rect);

    const hwnd = c.CreateWindowExW(
        0,
        App.surface_class,
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS,
        0,
        0,
        parent_rect.right - parent_rect.left,
        parent_rect.bottom - parent_rect.top,
        window.hwnd,
        null,
        app.hinstance,
        null,
    ) orelse {
        log.err("failed to create surface window err={}", .{c.GetLastError()});
        return error.CreateWindowFailed;
    };
    errdefer _ = c.DestroyWindow(hwnd);
    self.hwnd = hwnd;
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    self.content_scale = self.queryContentScale();
    self.size = self.querySize();

    // Add ourselves to the list of surfaces on the app.
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    // Get our new surface config
    var config = try apprt.surface.newConfig(app.core_app, &app.config, opts.context);
    defer config.deinit();
    self.shell = if (opts.shell) |shell| try shell.clone(alloc) else null;
    errdefer if (self.shell) |shell| shell.deinit(alloc);
    if (self.shell) |shell| {
        config.command = shell;
        config.@"initial-command" = null;
    }
    opts.overrides.apply(&config);
    self.runs_wsl = if (config.command) |command| commandRunsWsl(command) else false;
    self.bell_features = config.@"bell-features";
    self.notify_on_command_finish = config.@"notify-on-command-finish";
    self.notify_on_command_finish_action = config.@"notify-on-command-finish-action";
    self.notify_on_command_finish_after = config.@"notify-on-command-finish-after";
    self.progress_style = config.@"progress-style";
    try self.dim_overlay.init(hwnd, app.hinstance, &config);
    errdefer self.dim_overlay.deinit();
    self.dim_overlay.resize(@intCast(self.size.width), @intCast(self.size.height));
    try self.bell_border.init(hwnd, app.hinstance);
    errdefer self.bell_border.deinit();
    self.bell_border.resize(@intCast(self.size.width), @intCast(self.size.height));
    try self.link_preview.init(hwnd, app.hinstance, &config);
    errdefer self.link_preview.deinit(alloc);
    try self.scrollbar.init(hwnd, app.hinstance, &config, self, scrollToRow);
    errdefer self.scrollbar.deinit();
    try self.readonly_badge.init(hwnd, app.hinstance, &config, .top_right);
    errdefer self.readonly_badge.deinit(alloc);
    try self.key_badge.init(hwnd, app.hinstance, &config, .bottom_center);
    errdefer self.key_badge.deinit(alloc);
    try self.health_badge.init(hwnd, app.hinstance, &config, .center);
    errdefer self.health_badge.deinit(alloc);
    try self.toast_badge.init(hwnd, app.hinstance, &config, .bottom_center);
    errdefer self.toast_badge.deinit(alloc);
    try self.resize_badge.init(hwnd, app.hinstance, &config, .center);
    errdefer self.resize_badge.deinit(alloc);
    try self.drop_zone.init(hwnd, app.hinstance, &config);
    errdefer self.drop_zone.deinit();
    try self.drag_handle.init(self, app.hinstance, &config);
    errdefer self.drag_handle.deinit();
    self.accessibility = Accessibility.create(alloc, self) catch null;
    errdefer if (self.accessibility) |a| a.detach();
    self.updateResizeOverlay(&config);
    c.DragAcceptFiles(hwnd, c.TRUE);

    // A vertical one finger pan on a touch screen scrolls, with inertia,
    // rather than selecting text with emulated mouse input.
    var gesture: c.GESTURECONFIG = .{
        .dwID = c.GID_PAN,
        .dwWant = c.GC_PAN_WITH_SINGLE_FINGER_VERTICALLY | c.GC_PAN_WITH_INERTIA,
        .dwBlock = c.GC_PAN_WITH_SINGLE_FINGER_HORIZONTALLY | c.GC_PAN_WITH_GUTTER,
    };
    _ = c.SetGestureConfig(hwnd, 0, 1, &gesture, @sizeOf(c.GESTURECONFIG));
    try self.search_bar.init(hwnd, app.hinstance, &config, self, searchEvent);
    errdefer self.search_bar.deinit();
    try self.command_palette.init(hwnd, app.hinstance, &config, self, commandPaletteChoice);
    errdefer self.command_palette.deinit();

    // Initialize our surface now that we have the stable pointer.
    try self.core_surface.init(
        alloc,
        &config,
        app.core_app,
        app,
        self,
    );
    self.core_initialized = true;
    errdefer {
        self.core_initialized = false;
        self.core_surface.deinit();
    }
    self.showResizeOverlay();

    // Inherit the font size of our parent if configured.
    if (opts.parent) |parent| {
        if (app.config.@"window-inherit-font-size") {
            try self.core_surface.setFontSize(parent.font_size);
        }
    }
}

pub fn deinit(self: *Surface) void {
    const alloc = self.app.core_app.alloc;

    // Detach from our window first so that no more messages reach us.
    _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
    self.dim_overlay.deinit();
    self.bell_border.deinit();
    self.link_preview.deinit(alloc);
    self.scrollbar.deinit();
    self.readonly_badge.deinit(alloc);
    self.key_badge.deinit(alloc);
    self.health_badge.deinit(alloc);
    _ = c.KillTimer(self.hwnd, toast_timer_id);
    self.toast_badge.deinit(alloc);
    _ = c.KillTimer(self.hwnd, resize_timer_id);
    _ = c.KillTimer(self.hwnd, accessibility_timer_id);
    self.resize_badge.deinit(alloc);
    self.drag_handle.deinit();
    self.drop_zone.deinit();
    if (self.accessibility) |a| a.detach();
    self.accessibility = null;
    self.closeInspector();
    self.search_bar.deinit();
    self.command_palette.deinit();
    clearLabels(alloc, &self.key_tables);
    self.key_tables.deinit(alloc);
    clearLabels(alloc, &self.key_sequence);
    self.key_sequence.deinit(alloc);

    if (self.title) |v| alloc.free(v);
    if (self.title_override) |v| alloc.free(v);

    // Remove ourselves from the list of known surfaces in the app.
    self.app.core_app.deleteSurface(self);
    self.app.notifier.surfaceDestroyed(&self.core_surface);

    // Clean up our core surface so that all the rendering and IO stop.
    if (self.core_initialized) {
        self.core_initialized = false;
        self.core_surface.deinit();
    }
    if (self.shell) |shell| shell.deinit(alloc);
}

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *const Surface) *App {
    return self.app;
}

/// Close this surface. If `process_active` is true then the user is
/// asked for confirmation first.
pub fn close(self: *Surface, process_active: bool) void {
    const hwnd = self.hwnd;
    const identity = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (process_active and !Window.confirm(
        self.window,
        "Close terminal?",
        "A process is still running in this terminal. Closing it will kill the process.",
    )) return;

    if (c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA) != identity) return;

    self.window.closeSurface(self);
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    const alloc = self.app.core_app.alloc;
    if (self.title) |v| alloc.free(v);
    self.title = alloc.dupeSentinel(u8, title, 0) catch null;
    self.window.surfaceTitleChanged(self);
}

/// The title to show: the user's override if set, else the terminal's.
pub fn effectiveTitle(self: *const Surface) ?[:0]const u8 {
    return self.title_override orelse self.title;
}

/// Set or clear (with null or an empty title) the user's title override.
pub fn setTitleOverride(self: *Surface, title: ?[]const u8) void {
    const alloc = self.app.core_app.alloc;
    if (self.title_override) |v| alloc.free(v);
    self.title_override = null;
    if (title) |v| if (v.len > 0) {
        self.title_override = alloc.dupeSentinel(u8, v, 0) catch null;
    };
    self.window.surfaceTitleChanged(self);
}

/// Prompt for a new surface, tab or window title override.
pub fn promptTitle(self: *Surface, kind: apprt.action.PromptTitle) !void {
    const alloc = self.app.core_app.alloc;
    const window = self.window;
    const initial: []const u8 = switch (kind) {
        .surface => self.effectiveTitle() orelse "",
        .tab => (window.tabOf(self) orelse return).title(),
        .window => window.title_override orelse window.activeTab().title(),
    };

    const hwnd = self.hwnd;
    const identity = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    const title = try TitleDialog.prompt(alloc, window.hwnd, kind, initial) orelse return;
    defer alloc.free(title);

    // We may have been closed while the dialog was open.
    if (c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA) != identity) return;
    switch (kind) {
        .surface => self.setTitleOverride(title),
        .tab => if (self.window.tabOf(self)) |tab| tab.setTitleOverride(title),
        .window => self.window.setTitleOverride(title),
    }
}

pub fn setReadonly(self: *Surface, value: apprt.action.Readonly) void {
    self.readonly_badge.set(self.app.core_app.alloc, switch (value) {
        .on => "\u{1F512} Read-only",
        .off => null,
    });
}

pub fn setRendererHealth(self: *Surface, health: renderer.Health) void {
    self.health_badge.set(self.app.core_app.alloc, switch (health) {
        .healthy => null,
        .unhealthy => "Unable to render this terminal. The graphics device may have been reset.",
    });
}

pub fn keySequence(self: *Surface, value: apprt.action.KeySequence) !void {
    const alloc = self.app.core_app.alloc;
    switch (value) {
        .trigger => |trigger| {
            const label = try std.fmt.allocPrintSentinel(alloc, "{f}", .{trigger}, 0);
            errdefer alloc.free(label);
            try self.key_sequence.append(alloc, label);
        },
        .end => clearLabels(alloc, &self.key_sequence),
    }
    self.updateKeyBadge();
}

pub fn keyTable(self: *Surface, value: apprt.action.KeyTable) !void {
    const alloc = self.app.core_app.alloc;
    switch (value) {
        .activate => |name| {
            const label = try alloc.dupeSentinel(u8, name, 0);
            errdefer alloc.free(label);
            try self.key_tables.append(alloc, label);
        },
        .deactivate => if (self.key_tables.pop()) |label| alloc.free(label),
        .deactivate_all => clearLabels(alloc, &self.key_tables),
    }
    self.updateKeyBadge();
}

fn clearLabels(alloc: Allocator, labels: *std.ArrayList([:0]const u8)) void {
    for (labels.items) |label| alloc.free(label);
    labels.clearRetainingCapacity();
}

/// Show the active key tables and pending sequence, like GTK:
/// "table > inner › ctrl+a b".
fn updateKeyBadge(self: *Surface) void {
    const alloc = self.app.core_app.alloc;
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    const w = &text.writer;
    for (self.key_tables.items, 0..) |label, i| {
        if (i > 0) w.writeAll(" > ") catch return;
        w.writeAll(label) catch return;
    }
    if (self.key_tables.items.len > 0 and self.key_sequence.items.len > 0) {
        w.writeAll(" \u{203A} ") catch return;
    }
    for (self.key_sequence.items, 0..) |label, i| {
        if (i > 0) w.writeByte(' ') catch return;
        w.writeAll(label) catch return;
    }
    self.key_badge.set(alloc, text.written());
}

/// Show the search bar, for the start_search action.
pub fn startSearch(self: *Surface, needle: []const u8) void {
    self.search_bar.show(self.app.core_app.alloc, needle);
}

/// Hide the search bar, for the end_search action.
pub fn endSearch(self: *Surface) void {
    const had_focus = c.GetFocus() == self.search_bar.edit;
    self.search_bar.hide();
    self.search_total = null;
    self.search_selected = null;
    if (had_focus) _ = c.SetFocus(self.hwnd);
}

pub fn setSearchTotal(self: *Surface, total: ?usize) void {
    self.search_total = total;
    self.search_bar.setCount(self.search_selected, total);
}

pub fn setSearchSelected(self: *Surface, selected: ?usize) void {
    self.search_selected = selected;
    self.search_bar.setCount(selected, self.search_total);
}

/// The color to paint beneath the renderer's translucent background so
/// that together they look like the opaque background color, for
/// toggle_background_opacity.
///
/// The compositor blends premultiplied, gamma encoded colors. With linear
/// alpha blending the renderer premultiplies in linear space and gamma
/// encodes the result, so its background comes out as encode(a * lin(bg))
/// rather than a * bg, and we compensate for that.
fn opaqueUnderlay(self: *const Surface) c.COLORREF {
    const config = &self.app.config;
    const bg = config.background;
    const alpha: f32 = @floatCast(@max(0, @min(1, config.@"background-opacity")));
    if (alpha >= 1) return rgbRef(bg.r, bg.g, bg.b);
    const linear = config.@"alpha-blending".isLinear();
    return rgbRef(
        underlay(bg.r, alpha, linear),
        underlay(bg.g, alpha, linear),
        underlay(bg.b, alpha, linear),
    );
}

/// The channel value beneath `alpha` of `value` that composites to `value`.
fn underlay(value: u8, alpha: f32, linear: bool) u8 {
    const v = @as(f32, @floatFromInt(value)) / 255;
    const top = if (linear) srgbEncode(alpha * srgbDecode(v)) else alpha * v;
    const under = std.math.clamp((v - top) / (1 - alpha), 0, 1);
    return @intFromFloat(@round(under * 255));
}

fn srgbDecode(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn srgbEncode(v: f32) f32 {
    return if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

fn rgbRef(r: u8, g: u8, b: u8) c.COLORREF {
    return @as(c.COLORREF, r) | (@as(c.COLORREF, g) << 8) | (@as(c.COLORREF, b) << 16);
}

test underlay {
    const testing = std.testing;

    // Gamma space blending: the renderer's half is half the color.
    try testing.expectEqual(@as(u8, 192), underlay(192, 0.5, false));

    // Linear blending: the renderer's half is encode(0.5 * lin(192)), about
    // 141, so beneath it we need about 2 * (192 - 141).
    try testing.expectEqual(@as(u8, 103), underlay(192, 0.5, true));
    try testing.expectEqual(@as(u8, 0), underlay(0, 0.5, true));
}

/// Whether a command starts WSL. For a shell command line, this looks at
/// the program, the first word, which may be quoted.
fn commandRunsWsl(command: configpkg.Command) bool {
    const program = switch (command) {
        .direct => |args| if (args.len > 0) args[0] else return false,
        .shell => |line| program: {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "\"")) {
                const end = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse trimmed.len;
                break :program trimmed[1..end];
            }
            const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
            break :program trimmed[0..end];
        },
    };
    return internal_os.wsl.isWsl(program);
}

test commandRunsWsl {
    const testing = std.testing;
    try testing.expect(commandRunsWsl(.{ .shell = "wsl.exe -d Ubuntu" }));
    try testing.expect(commandRunsWsl(.{ .shell = "\"C:\\Windows\\System32\\wsl.exe\" ~" }));
    try testing.expect(!commandRunsWsl(.{ .shell = "cmd.exe" }));
}

/// Scroll for a touch pan gesture. Returns false for other gestures,
/// which go to DefWindowProc.
fn panGesture(self: *Surface, lparam: c.LPARAM) bool {
    var info: c.GESTUREINFO = undefined;
    info.cbSize = @sizeOf(c.GESTUREINFO);
    const handle = util.handle(c.HGESTUREINFO, lparam);
    if (c.GetGestureInfo(handle, &info) == 0) return false;
    if (info.dwID != c.GID_PAN) return false;
    defer _ = c.CloseGestureInfoHandle(handle);

    const y: c_int = info.ptsLocation.y;
    if (info.dwFlags & c.GF_BEGIN != 0) {
        self.pan_y = y;
        return true;
    }
    const last = self.pan_y orelse y;
    self.pan_y = if (info.dwFlags & c.GF_END != 0) null else y;

    // Content follows the finger: moving down shows earlier lines, which
    // is a positive (upward) scroll for the core.
    const dy = y - last;
    if (dy != 0 and self.core_initialized) {
        self.core_surface.scrollCallback(0, @floatFromInt(dy), .{ .precision = true }) catch |err| {
            log.err("error in scroll callback err={}", .{err});
        };
    }
    return true;
}

/// Paste the paths of files dropped on us, quoted for our shell.
fn dropFiles(self: *Surface, hdrop: c.HDROP) void {
    defer c.DragFinish(hdrop);
    if (!self.core_initialized) return;

    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const count = c.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    var paths: std.ArrayList([]const u8) = .empty;
    for (0..count) |i| {
        const len = c.DragQueryFileW(hdrop, @intCast(i), null, 0);
        const buf = alloc.alloc(u16, len + 1) catch return;
        _ = c.DragQueryFileW(hdrop, @intCast(i), buf.ptr, len + 1);
        const path = util.utf8Alloc(alloc, buf[0..len]) catch return;
        paths.append(alloc, path) catch return;
    }
    if (paths.items.len == 0) return;

    const text = drop.text(alloc, paths.items, if (self.runs_wsl) .wsl else .windows) catch return;
    self.completeClipboardText(.{ .paste = .standard }, text, false);
}

/// With focus-follows-mouse, take focus from another terminal in our
/// window when the mouse moves over us. We check that the cursor really
/// moved, since resizing a split under a still cursor also sends
/// WM_MOUSEMOVE, and we never take focus from anything but a terminal,
/// such as a search field or the command palette.
fn focusFollowsMouse(self: *Surface, wparam: c.WPARAM) void {
    if (!self.app.config.@"focus-follows-mouse") return;
    const buttons = c.MK_LBUTTON | c.MK_RBUTTON | c.MK_MBUTTON;
    if (wparam & buttons != 0) return;
    if (c.GetForegroundWindow() != self.window.hwnd) return;
    const focus = c.GetFocus() orelse return;
    if (focus == self.hwnd) return;

    var class: [64]u16 = undefined;
    const len: usize = @intCast(@max(0, c.GetClassNameW(focus, &class, class.len)));
    if (!std.mem.eql(u16, class[0..len], App.surface_class)) return;
    _ = c.SetFocus(self.hwnd);
}

/// The terminal's background or foreground color changed.
pub fn colorChanged(self: *Surface, change: apprt.action.ColorChange) void {
    const color: terminal.color.RGB = .{ .r = change.r, .g = change.g, .b = change.b };
    switch (change.kind) {
        .background => self.background_color = color,
        .foreground => self.foreground_color = color,
        else => return,
    }
    self.window.tab_bar.invalidate();
}

/// Show, hide, or toggle the terminal inspector's window.
pub fn controlInspector(self: *Surface, mode: apprt.action.Inspector) void {
    const show = switch (mode) {
        .toggle => self.inspector == null,
        .show => true,
        .hide => false,
    };
    if (!show) return self.closeInspector();
    if (self.inspector) |window| return window.present();
    self.inspector = InspectorWindow.create(self) catch |err| {
        log.err("error opening the inspector err={}", .{err});
        return;
    };
}

/// Close the terminal inspector's window, if it's open.
pub fn closeInspector(self: *Surface) void {
    const window = self.inspector orelse return;
    self.inspector = null;
    window.destroy();
}

/// Redraw the terminal inspector, if it's open.
pub fn queueInspectorRender(self: *Surface) void {
    if (self.inspector) |window| window.queueRender();
}

/// Show the command palette, or hide it if it's open.
pub fn toggleCommandPalette(self: *Surface) void {
    // From the tab overview, we switch to the commands.
    if (self.command_palette.visible()) {
        const overview = self.command_palette.contents == .terminals;
        self.command_palette.hide();
        if (!overview) return;
    }

    // Every terminal can be focused from the palette.
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    var targets: std.ArrayList(CommandPalette.Target) = .empty;
    for (self.app.core_app.surfaces.items) |surface| {
        if (!surface.core_initialized) continue;
        // Closed tabs kept for undo can't be focused.
        if (surface.window.tabOf(surface) == null) continue;
        targets.append(alloc, .{
            .surface = &surface.core_surface,
            .title = surface.effectiveTitle() orelse "Untitled",
            .pwd = surface.core_surface.pwd(alloc) catch null,
        }) catch break;
    }
    self.command_palette.show(self.app.core_app.alloc, &self.app.config, .commands, targets.items);
}

/// Show the tabs of our window to switch between, like the GTK tab
/// overview, or hide them if they're shown. It's the command palette
/// listing only the focused terminal of each tab.
pub fn toggleTabOverview(self: *Surface) void {
    if (self.command_palette.visible()) {
        const overview = self.command_palette.contents == .terminals;
        self.command_palette.hide();
        if (overview) return;
    }

    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    var targets: std.ArrayList(CommandPalette.Target) = .empty;
    for (self.window.tabs.items, 1..) |tab, i| {
        const surface = tab.focused;
        if (!surface.core_initialized) continue;
        targets.append(alloc, .{
            .surface = &surface.core_surface,
            .title = std.fmt.allocPrint(alloc, "Tab {d}: {s}", .{ i, tab.title() }) catch break,
            .pwd = surface.core_surface.pwd(alloc) catch null,
        }) catch break;
    }
    self.command_palette.show(self.app.core_app.alloc, &self.app.config, .terminals, targets.items);
}

/// Called by the command palette when the user chooses an entry.
fn commandPaletteChoice(ctx: *anyopaque, choice: CommandPalette.Choice) void {
    const self: *Surface = @ptrCast(@alignCast(ctx));
    switch (choice) {
        .action => |action| self.performMenuAction(action),
        // presentSurface ignores a terminal that has closed since.
        .surface => |surface| self.app.presentSurface(surface),
    }
}

/// Called by the search bar for user input.
fn searchEvent(ctx: *anyopaque, event: SearchBar.Event) void {
    const self: *Surface = @ptrCast(@alignCast(ctx));
    if (!self.core_initialized) return;
    const action: input.Binding.Action = switch (event) {
        .changed => |needle| .{ .search = needle },
        .next => .{ .navigate_search = .next },
        .previous => .{ .navigate_search = .previous },
        .close => .end_search,
    };
    _ = self.core_surface.performBindingAction(action) catch |err| {
        log.warn("error performing search action err={}", .{err});
    };
}

/// Called by the scrollbar while dragging its thumb.
fn scrollToRow(ctx: *anyopaque, row: usize) void {
    const self: *Surface = @ptrCast(@alignCast(ctx));
    if (!self.core_initialized) return;
    _ = self.core_surface.performBindingAction(.{ .scroll_to_row = row }) catch |err| {
        log.warn("error scrolling err={}", .{err});
    };
}

/// Show the URL under the mouse, or hide it if empty.
pub fn setMouseOverLink(self: *Surface, url: []const u8) void {
    self.link_preview.setUrl(self.app.core_app.alloc, url, .{
        .x = @intFromFloat(self.cursor_pos.x),
        .y = @intFromFloat(self.cursor_pos.y),
    });
}

/// Copy the effective title to the clipboard.
pub fn copyTitleToClipboard(self: *Surface) !bool {
    const title = self.effectiveTitle() orelse return false;
    if (title.len == 0) return false;
    try writeClipboardText(self.app.core_app.alloc, self.hwnd, title, null);
    return true;
}

/// Apply runtime settings that aren't handled by the core surface.
pub fn configChanged(self: *Surface, config: *const configpkg.Config) void {
    self.bell_features = config.@"bell-features";
    if (!self.bell_features.title and !self.bell_features.border and self.bell_pending) {
        self.setBellPending(false);
    } else {
        self.updateBellBorder();
    }
    self.notify_on_command_finish = config.@"notify-on-command-finish";
    self.notify_on_command_finish_action = config.@"notify-on-command-finish-action";
    self.notify_on_command_finish_after = config.@"notify-on-command-finish-after";
    self.progress_style = config.@"progress-style";
    self.window.updateTaskbarProgress();
    self.link_preview.updateConfig(config);
    self.scrollbar.updateConfig(config);
    self.readonly_badge.updateConfig(config);
    self.key_badge.updateConfig(config);
    self.health_badge.updateConfig(config);
    self.toast_badge.updateConfig(config);
    self.resize_badge.updateConfig(config);
    self.drag_handle.updateConfig(config);
    self.drop_zone.updateConfig(config);
    self.updateResizeOverlay(config);
    self.search_bar.updateConfig(config);
    self.command_palette.updateConfig(config);
    self.dim_overlay.updateConfig(config) catch |err| {
        log.err("error updating split dimming err={}", .{err});
    };
}

pub fn ringBell(self: *Surface) void {
    if (self.bell_features.system) _ = c.MessageBeep(c.MB_OK);
    if (self.bell_features.audio) self.app.playBellAudio();
    if (self.bell_features.attention) self.window.requestAttention();
    if (self.bell_features.title or self.bell_features.border) {
        self.window.surfaceBell(self);
    }
}

/// Set or clear the pending bell and update its indicators.
pub fn setBellPending(self: *Surface, pending: bool) void {
    if (self.bell_pending == pending) return;
    self.bell_pending = pending;
    self.updateBellBorder();
    self.window.updateBellIndicators();
}

/// Show the bell border while a bell is pending, if enabled.
pub fn updateBellBorder(self: *Surface) void {
    self.bell_border.setVisible(self.bell_pending and self.bell_features.border);
}

pub fn commandFinished(self: *Surface, value: apprt.Action.Value(.command_finished)) void {
    const notify = switch (self.notify_on_command_finish) {
        .never => false,
        .unfocused => c.GetFocus() != self.hwnd,
        .always => true,
    };
    if (!notify or value.duration.lte(self.notify_on_command_finish_after)) return;
    if (self.notify_on_command_finish_action.bell) {
        log.debug("command finished bell duration={f}", .{value.duration});
        self.ringBell();
    }
    if (self.notify_on_command_finish_action.notify) {
        self.notifyCommandFinished(value);
    }
}

fn notifyCommandFinished(self: *Surface, value: apprt.Action.Value(.command_finished)) void {
    const title = if (value.exit_code) |code|
        if (code == 0) "Command Succeeded" else "Command Failed"
    else
        "Command Finished";

    var buf: [128]u8 = undefined;
    const duration = value.duration.round(std.time.ns_per_ms);
    const body = if (value.exit_code) |code|
        std.fmt.bufPrint(&buf, "Command took {f} and exited with code {d}.", .{ duration, code })
    else
        std.fmt.bufPrint(&buf, "Command took {f}.", .{duration});
    self.app.notifier.send(
        &self.core_surface,
        title,
        body catch "Command finished.",
    );
}

pub fn setProgressReport(self: *Surface, report: terminal.osc.Command.ProgressReport) void {
    log.debug("progress report state={} value={?}", .{ report.state, report.progress });
    if (report.state == .remove) {
        self.progress_report = null;
        self.progress_value = null;
    } else {
        self.progress_report = report;
        if (report.progress) |value| self.progress_value = value;
        self.progress_expires_at = c.GetTickCount64() + 15_000;
    }
    if (self.window.tabs.items.len > 0 and self.window.activeSurface() == self) {
        self.window.updateTaskbarProgress();
    }
}

/// Called by the window when this surface is shown or hidden, such as
/// when switching tabs.
pub fn setVisible(self: *Surface, visible: bool) void {
    if (!self.core_initialized) return;
    self.core_surface.occlusionCallback(visible) catch |err| {
        log.err("error in occlusion callback err={}", .{err});
    };
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return self.content_scale;
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return self.size;
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    return self.cursor_pos;
}

fn queryContentScale(self: *const Surface) apprt.ContentScale {
    const dpi: f32 = @floatFromInt(c.GetDpiForWindow(self.hwnd));
    const scale = @max(1, dpi / util.USER_DEFAULT_SCREEN_DPI);
    return .{ .x = scale, .y = scale };
}

fn querySize(self: *const Surface) apprt.SurfaceSize {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(self.hwnd, &rect) == 0) return .{ .width = 0, .height = 0 };
    return .{
        .width = @intCast(@max(0, rect.right - rect.left)),
        .height = @intCast(@max(0, rect.bottom - rect.top)),
    };
}

pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    const id: u16 = switch (shape) {
        .default, .context_menu, .alias, .copy, .cell => util.IDC_ARROW,
        .help => util.IDC_HELP,
        .pointer, .grab, .grabbing => util.IDC_HAND,
        .progress => util.IDC_APPSTARTING,
        .wait => util.IDC_WAIT,
        .crosshair => util.IDC_CROSS,
        .text, .vertical_text => util.IDC_IBEAM,
        .move, .all_scroll => util.IDC_SIZEALL,
        .no_drop, .not_allowed => util.IDC_NO,
        .col_resize, .e_resize, .w_resize, .ew_resize => util.IDC_SIZEWE,
        .row_resize, .n_resize, .s_resize, .ns_resize => util.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => util.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => util.IDC_SIZENWSE,
        .zoom_in, .zoom_out => util.IDC_ARROW,
    };
    self.cursor = util.loadSystemCursor(id);
    self.applyCursor();
}

pub fn setMouseVisibility(self: *Surface, visible: bool) void {
    self.cursor_hidden = !visible;
    self.applyCursor();
}

/// Apply our cursor if the mouse is currently over us.
fn applyCursor(self: *const Surface) void {
    var pt: c.POINT = undefined;
    if (c.GetCursorPos(&pt) == 0) return;
    if (c.WindowFromPoint(pt) != self.hwnd) return;
    _ = c.SetCursor(if (self.cursor_hidden) null else self.cursor);
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    if (clipboard_type != .standard) return .unsupported;

    switch (state) {
        .paste, .osc_52_read => {},

        // We only support plain text for now, which isn't enough to
        // serve the Kitty clipboard protocol or paste events.
        .kitty_read, .kitty_write, .list => return .unsupported,

        // No clipboard write code paths travel through this function
        .osc_52_write => unreachable,
    }

    const alloc = self.app.core_app.alloc;
    const text = readClipboardText(alloc, self.hwnd) catch |err| {
        log.warn("failed to read clipboard err={}", .{err});
        return .unavailable;
    } orelse return .unavailable;
    defer alloc.free(text);

    self.completeClipboardText(state, text, false);
    return .started;
}

/// Complete a clipboard request with the given text, asking the user
/// for confirmation if the core considers the paste unsafe.
fn completeClipboardText(
    self: *Surface,
    state: apprt.ClipboardRequest,
    text: [:0]const u8,
    confirmed: bool,
) void {
    const contents = [_]terminal.clipboard.Content{.{
        .mime = "text/plain",
        .data = text,
    }};
    const available = [_][]const u8{"text/plain"};

    self.core_surface.completeClipboardRequest(state, .{
        .contents = &contents,
        .available = &available,
        .confirmed = confirmed,
    }) catch |err| switch (err) {
        error.UnsafePaste,
        error.UnauthorizedPaste,
        => {
            const hwnd = self.hwnd;
            const identity = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
            // Like GTK, we say what's happening and show the text.
            const title: []const u8, const message: []const u8 = if (err == error.UnsafePaste) .{
                "Warning: Potentially Unsafe Paste",
                "Pasting this text into the terminal may be dangerous as it looks like some commands may be executed. Paste anyway?",
            } else .{
                "Authorize Clipboard Access",
                "An application is attempting to read from the clipboard. The current clipboard contents are shown below. Allow it?",
            };
            const allowed = !confirmed and Window.confirmText(
                self.window,
                self.app.core_app.alloc,
                title,
                message,
                text,
            );
            // The process can exit and destroy this surface while the
            // confirmation dialog pumps messages.
            if (c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA) != identity) return;
            if (allowed) {
                self.completeClipboardText(state, text, true);
            } else {
                self.core_surface.denyClipboardRequest(state);
            }
        },

        else => log.err("error completing clipboard request err={}", .{err}),
    };
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    if (clipboard_type != .standard) return;

    // We write plain text, and HTML (with colors and styles) when we have
    // it, which rich text editors paste.
    const text: [:0]const u8 = for (contents) |content| {
        if (std.mem.eql(u8, content.mime, "text/plain")) break content.data;
    } else return;
    const html: ?[]const u8 = for (contents) |content| {
        if (std.mem.eql(u8, content.mime, "text/html")) break content.data;
    } else null;

    const alloc = self.app.core_app.alloc;
    const owned_text = if (confirm) try alloc.dupeSentinel(u8, text, 0) else null;
    defer if (owned_text) |copy| alloc.free(copy);
    const hwnd = self.hwnd;
    const identity = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);

    if (confirm and !Window.confirmText(
        self.window,
        alloc,
        "Authorize Clipboard Access",
        "An application is attempting to write to the clipboard. The text it would copy is shown below. Allow it?",
        text,
    )) return;

    if (c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA) != identity) return;

    try writeClipboardText(alloc, hwnd, owned_text orelse text, html);
    if (self.app.config.@"app-notifications".@"clipboard-copy") {
        self.showToast(if ((owned_text orelse text).len > 0) "Copied to clipboard" else "Cleared clipboard");
    }
}

const toast_timer_id = 1;
const resize_timer_id = 2;
const accessibility_timer_id = 3;

/// Posted to the surface when its selection changes.
pub const WM_GHOSTTY_SELECTION_CHANGED = c.WM_APP + 10;
const accessibility_ms = 500;

fn updateResizeOverlay(self: *Surface, config: *const configpkg.Config) void {
    self.resize_overlay = config.@"resize-overlay";
    self.resize_overlay_ms = @intCast(@min(config.@"resize-overlay-duration".asMilliseconds(), std.math.maxInt(u32)));
    self.resize_badge.anchor = switch (config.@"resize-overlay-position") {
        .center => .center,
        .@"top-left" => .top_left,
        .@"top-center" => .top_center,
        .@"top-right" => .top_right,
        .@"bottom-left" => .bottom_left,
        .@"bottom-center" => .bottom_center,
        .@"bottom-right" => .bottom_right,
    };
}

/// Show the terminal's size after a resize, like GTK, if its grid changed.
fn showResizeOverlay(self: *Surface) void {
    if (!self.core_initialized) return;
    const grid = self.core_surface.size.grid();
    const first = self.last_grid == null;
    if (self.last_grid) |last| {
        if (last.columns == grid.columns and last.rows == grid.rows) return;
    }
    self.last_grid = .{ .columns = grid.columns, .rows = grid.rows };

    // Sizing a new window before it's shown counts as being created.
    const creating = first or c.IsWindowVisible(self.window.hwnd) == 0;
    switch (self.resize_overlay) {
        .never => return,
        .@"after-first" => if (creating) return,
        .always => {},
    }
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d} x {d}", .{ grid.columns, grid.rows }) catch return;
    self.resize_badge.set(self.app.core_app.alloc, text);
    _ = c.SetTimer(self.hwnd, resize_timer_id, @max(1, self.resize_overlay_ms), null);
}
const toast_ms = 2000;

/// Show a short message for a couple of seconds.
pub fn showToast(self: *Surface, text: []const u8) void {
    self.toast_badge.set(self.app.core_app.alloc, text);
    _ = c.SetTimer(self.hwnd, toast_timer_id, toast_ms, null);
}

/// Open the clipboard, retrying a few times since another application
/// may briefly have it open.
fn openClipboard(hwnd: c.HWND) !void {
    for (0..10) |_| {
        if (c.OpenClipboard(hwnd) != 0) return;
        c.Sleep(5);
    }
    return error.OpenClipboardFailed;
}

/// Read text from the clipboard. Returns null if the clipboard has no
/// text. Line endings are normalized from CRLF to LF.
fn readClipboardText(alloc: Allocator, hwnd: c.HWND) !?[:0]u8 {
    if (c.IsClipboardFormatAvailable(c.CF_UNICODETEXT) == 0) return null;

    try openClipboard(hwnd);
    defer _ = c.CloseClipboard();

    const handle = c.GetClipboardData(c.CF_UNICODETEXT) orelse return null;
    const ptr: [*:0]const u16 = @ptrCast(@alignCast(c.GlobalLock(handle) orelse return null));
    defer _ = c.GlobalUnlock(handle);

    const text = try util.utf8Alloc(alloc, std.mem.span(ptr));
    errdefer alloc.free(text);

    // Normalize CRLF to LF. The core turns LF into CR for the terminal
    // (as is standard), so CRLF would otherwise become two newlines.
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        text[len] = text[i];
        len += 1;
    }
    text[len] = 0;
    if (len == text.len) return text;
    const shrunk = try alloc.realloc(text[0 .. text.len + 1], len + 1);
    return shrunk[0..len :0];
}

/// Write text to the clipboard. Line endings are converted from LF to
/// CRLF, as is standard for text on Windows.
fn writeClipboardText(alloc: Allocator, hwnd: c.HWND, text: []const u8, html: ?[]const u8) !void {
    // Convert LF to CRLF.
    var crlf: std.ArrayList(u8) = .empty;
    defer crlf.deinit(alloc);
    for (text, 0..) |ch, i| {
        if (ch == '\n' and (i == 0 or text[i - 1] != '\r')) try crlf.append(alloc, '\r');
        try crlf.append(alloc, ch);
    }

    const text16 = try util.utf16Alloc(alloc, crlf.items);
    defer alloc.free(text16);

    const bytes = (text16.len + 1) * @sizeOf(u16);
    const mem = c.GlobalAlloc(c.GMEM_MOVEABLE, bytes) orelse return error.OutOfMemory;
    {
        const dst: [*]u16 = @ptrCast(@alignCast(c.GlobalLock(mem) orelse {
            _ = c.GlobalFree(mem);
            return error.OutOfMemory;
        }));
        @memcpy(dst[0 .. text16.len + 1], text16[0 .. text16.len + 1]);
        _ = c.GlobalUnlock(mem);
    }

    openClipboard(hwnd) catch |err| {
        _ = c.GlobalFree(mem);
        return err;
    };
    defer _ = c.CloseClipboard();

    _ = c.EmptyClipboard();
    if (c.SetClipboardData(c.CF_UNICODETEXT, mem) == null) {
        // On success the system owns the memory, otherwise we do.
        _ = c.GlobalFree(mem);
        return error.SetClipboardFailed;
    }

    // HTML is a bonus, so failing to add it isn't an error.
    if (html) |fragment| html: {
        const format = c.RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("HTML Format"));
        if (format == 0) break :html;
        const data = cfHtml(alloc, fragment) catch break :html;
        defer alloc.free(data);
        const html_mem = c.GlobalAlloc(c.GMEM_MOVEABLE, data.len + 1) orelse break :html;
        const dst: [*]u8 = @ptrCast(c.GlobalLock(html_mem) orelse {
            _ = c.GlobalFree(html_mem);
            break :html;
        });
        @memcpy(dst[0..data.len], data);
        dst[data.len] = 0;
        _ = c.GlobalUnlock(html_mem);
        if (c.SetClipboardData(format, html_mem) == null) _ = c.GlobalFree(html_mem);
    }
}

/// An HTML fragment in the clipboard's "HTML Format" (CF_HTML): a header
/// with the byte offsets of the document and of the fragment within it.
fn cfHtml(alloc: Allocator, fragment: []const u8) ![]u8 {
    // The offsets are fixed width so the header's length doesn't depend
    // on them.
    const header_len = "Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\n".len;
    const prefix = "<html><body>\r\n<!--StartFragment-->";
    const suffix = "<!--EndFragment-->\r\n</body></html>";
    const start_html = header_len;
    const start_fragment = start_html + prefix.len;
    const end_fragment = start_fragment + fragment.len;
    const end_html = end_fragment + suffix.len;
    return std.fmt.allocPrint(
        alloc,
        "Version:0.9\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\nStartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\n" ++
            prefix ++ "{s}" ++ suffix,
        .{ start_html, end_html, start_fragment, end_fragment, fragment },
    );
}

test cfHtml {
    const testing = std.testing;
    const data = try cfHtml(testing.allocator, "<b>hi</b>");
    defer testing.allocator.free(data);

    const offset = struct {
        fn f(d: []const u8, name: []const u8) usize {
            const i = std.mem.indexOf(u8, d, name).? + name.len;
            return std.fmt.parseInt(usize, d[i .. i + 10], 10) catch unreachable;
        }
    }.f;
    try testing.expectEqualStrings("<b>hi</b>", data[offset(data, "StartFragment:")..offset(data, "EndFragment:")]);
    try testing.expectEqualStrings("<html>", data[offset(data, "StartHTML:")..][0..6]);
    try testing.expectEqual(data.len, offset(data, "EndHTML:"));
}

pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map {
    _ = self;
    return try global.environMap();
}

pub fn renderDeviceOptions(self: *Surface) !renderer.Device.Options {
    _ = self;
    return .{};
}

/// Redraw the inspector for our surface. The inspector isn't
/// supported on Windows yet.
pub fn redrawInspector(self: *Surface) void {
    _ = self;
}

//----------------------------------------------------------------------------
// Window procedure

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Surface = @ptrFromInt(@as(usize, @bitCast(ptr)));

    // Until the core surface is initialized we can't process any events.
    if (!self.core_initialized) return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        c.WM_ERASEBKGND => return 1,

        c.WM_PAINT => {
            // Our content is the renderer's composition visual, above
            // this. When the window is translucent, fill with black, which
            // GDI writes with zero alpha, so that only the terminal's own
            // alpha shows through. Otherwise fill with the background
            // color, so a translucent terminal made opaque with
            // toggle_background_opacity looks like an opaque one.
            var ps: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &ps);
            const color: c.COLORREF = if (self.app.translucent()) 0 else self.opaqueUnderlay();
            const brush = c.CreateSolidBrush(color);
            _ = c.FillRect(hdc, &ps.rcPaint, brush);
            _ = c.DeleteObject(brush);
            _ = c.EndPaint(hwnd, &ps);
            self.core_surface.refreshCallback() catch |err| {
                log.err("error in refresh callback err={}", .{err});
            };
            return 0;
        },

        c.WM_SIZE => {
            const size = self.querySize();
            if (size.width != self.size.width or size.height != self.size.height) {
                self.size = size;
                self.dim_overlay.resize(@intCast(size.width), @intCast(size.height));
                self.bell_border.resize(@intCast(size.width), @intCast(size.height));
                self.link_preview.parentResized();
                self.scrollbar.parentResized();
                self.readonly_badge.parentResized();
                self.key_badge.parentResized();
                self.health_badge.parentResized();
                self.toast_badge.parentResized();
                self.resize_badge.parentResized();
                self.drag_handle.parentResized();
                self.search_bar.parentResized();
                self.command_palette.parentResized();
                self.core_surface.sizeCallback(size) catch |err| {
                    log.err("error in size callback err={}", .{err});
                };
                self.showResizeOverlay();
            }
            return 0;
        },

        c.WM_DPICHANGED_AFTERPARENT => {
            self.content_scale = self.queryContentScale();
            self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
                log.err("error in content scale callback err={}", .{err});
            };
            return 0;
        },

        WM_GHOSTTY_SELECTION_CHANGED => {
            if (self.accessibility) |a| a.selectionChanged();
            return 0;
        },

        c.WM_SETFOCUS, c.WM_KILLFOCUS => {
            if (msg == c.WM_SETFOCUS) self.window.surfaceFocused(self);

            // Screen readers follow the output of the focused terminal.
            if (msg == c.WM_SETFOCUS)
                _ = c.SetTimer(hwnd, accessibility_timer_id, accessibility_ms, null)
            else
                _ = c.KillTimer(hwnd, accessibility_timer_id);
            self.core_surface.focusCallback(msg == c.WM_SETFOCUS) catch |err| {
                log.err("error in focus callback err={}", .{err});
            };
            return 0;
        },

        c.WM_KEYDOWN,
        c.WM_SYSKEYDOWN,
        c.WM_KEYUP,
        c.WM_SYSKEYUP,
        => if (self.keyEvent(msg, wparam, lparam)) return 0,

        c.WM_CHAR, c.WM_SYSCHAR => {
            // Characters that aren't attached to a key event we've
            // processed, such as text committed by an IME.
            self.charEvent(@truncate(wparam));
            return 0;
        },

        c.WM_IME_SETCONTEXT => {
            // We draw the composition (preedit) text ourselves, so hide
            // the IME's composition window. Its candidate window is kept.
            const l: usize = @bitCast(lparam);
            const without: usize = l & ~@as(usize, c.ISC_SHOWUICOMPOSITIONWINDOW);
            return c.DefWindowProcW(hwnd, msg, wparam, @bitCast(without));
        },

        c.WM_IME_STARTCOMPOSITION => {
            self.updateImePosition();
            return 0;
        },

        c.WM_IME_COMPOSITION => {
            self.imeComposition(lparam);
            self.updateImePosition();
            return 0;
        },

        c.WM_IME_ENDCOMPOSITION => {
            self.preedit(null);
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_MOUSEMOVE => {
            if (!self.tracking_mouse) {
                var tme: c.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
                    .dwFlags = c.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (c.TrackMouseEvent(&tme) != 0) self.tracking_mouse = true;
            }

            const pos: apprt.CursorPos = .{
                .x = @floatFromInt(util.loword(lparam)),
                .y = @floatFromInt(util.hiword(lparam)),
            };
            if (pos.x != self.cursor_pos.x or pos.y != self.cursor_pos.y) {
                self.focusFollowsMouse(wparam);
            }
            self.cursorPosEvent(pos);
            self.scrollbar.updateHover();
            return 0;
        },

        c.WM_TIMER => if (wparam == toast_timer_id) {
            _ = c.KillTimer(hwnd, toast_timer_id);
            self.toast_badge.set(self.app.core_app.alloc, null);
            return 0;
        } else if (wparam == accessibility_timer_id) {
            if (self.accessibility) |a| {
                const typing = c.GetTickCount64() -| self.last_key_ms < 2 * accessibility_ms;
                a.announceOutput(typing);
            }
            return 0;
        } else if (wparam == resize_timer_id) {
            _ = c.KillTimer(hwnd, resize_timer_id);
            self.resize_badge.set(self.app.core_app.alloc, null);
            return 0;
        },

        c.WM_GETOBJECT => if (self.accessibility) |a| {
            if (a.getObject(hwnd, wparam, lparam)) |result| return result;
        },

        c.WM_GESTURE => if (self.panGesture(lparam)) return 0,

        c.WM_DROPFILES => {
            self.dropFiles(util.handle(c.HDROP, wparam));
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.tracking_mouse = false;
            self.scrollbar.updateHover();

            // While we have the mouse captured (a button is held) we keep
            // getting mouse events, so the mouse hasn't really left us.
            if (c.GetCapture() != hwnd) self.cursorPosEvent(.{ .x = -1, .y = -1 });
            return 0;
        },

        c.WM_LBUTTONDOWN => return self.mouseButtonEvent(.press, .left, wparam, lparam),
        c.WM_LBUTTONUP => return self.mouseButtonEvent(.release, .left, wparam, lparam),
        c.WM_RBUTTONDOWN => return self.mouseButtonEvent(.press, .right, wparam, lparam),
        c.WM_RBUTTONUP => return self.mouseButtonEvent(.release, .right, wparam, lparam),
        c.WM_MBUTTONDOWN => return self.mouseButtonEvent(.press, .middle, wparam, lparam),
        c.WM_MBUTTONUP => return self.mouseButtonEvent(.release, .middle, wparam, lparam),
        c.WM_XBUTTONDOWN, c.WM_XBUTTONUP => {
            const button: input.MouseButton = switch (util.hiword(wparam)) {
                c.XBUTTON1 => .four,
                c.XBUTTON2 => .five,
                else => return 0,
            };
            _ = self.mouseButtonEvent(
                if (msg == c.WM_XBUTTONDOWN) .press else .release,
                button,
                wparam,
                lparam,
            );
            // XBUTTON messages must return TRUE.
            return 1;
        },

        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            const delta: f64 = @as(f64, @floatFromInt(util.hiword(wparam))) / c.WHEEL_DELTA;
            const xoff: f64, const yoff: f64 = if (msg == c.WM_MOUSEWHEEL)
                .{ 0, delta }
            else
                // Positive horizontal wheel deltas scroll right, which
                // is a negative x offset for the core.
                .{ -delta, 0 };
            self.core_surface.scrollCallback(xoff, yoff, .{}) catch |err| {
                log.err("error in scroll callback err={}", .{err});
            };
            return 0;
        },

        c.WM_SETCURSOR => {
            if (util.loword(lparam) == c.HTCLIENT) {
                _ = c.SetCursor(if (self.cursor_hidden) null else self.cursor);
                return 1;
            }
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn cursorPosEvent(self: *Surface, pos: apprt.CursorPos) void {
    // Windows may send phantom mouse move events without the cursor
    // actually moving, which we don't want to report.
    if (pos.x == self.cursor_pos.x and pos.y == self.cursor_pos.y) return;
    self.cursor_pos = pos;
    self.link_preview.cursorMoved(.{ .x = @intFromFloat(pos.x), .y = @intFromFloat(pos.y) });
    self.core_surface.cursorPosCallback(pos, key.currentMods()) catch |err| {
        log.err("error in cursor pos callback err={}", .{err});
    };
}

fn mouseButtonEvent(
    self: *Surface,
    action: input.MouseButtonState,
    button: input.MouseButton,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) c.LRESULT {
    // Capture the mouse while a button is held so that we keep getting
    // events (e.g. while selecting) if the cursor leaves the window.
    // Clicking a surface (e.g. another split) also focuses it.
    switch (action) {
        .press => {
            _ = c.SetCapture(self.hwnd);
            if (c.GetFocus() != self.hwnd) _ = c.SetFocus(self.hwnd);
        },
        .release => {
            // The message contains the buttons still down, including
            // both side buttons. Keep capture until the last is released.
            const buttons = c.MK_LBUTTON | c.MK_RBUTTON | c.MK_MBUTTON | c.MK_XBUTTON1 | c.MK_XBUTTON2;
            if (wparam & buttons == 0) _ = c.ReleaseCapture();
        },
    }

    const consumed = self.core_surface.mouseButtonCallback(action, button, key.currentMods()) catch |err| err: {
        log.err("error in mouse button callback err={}", .{err});
        break :err true;
    };

    // When `right-click-action` is `context-menu`, the core selects the
    // word under the cursor and doesn't consume the press. Like other
    // Windows apps, we show the menu when the button is released.
    if (button == .right) switch (action) {
        .press => self.context_menu_pending = !consumed,
        .release => if (self.context_menu_pending) {
            self.context_menu_pending = false;
            self.showContextMenu(.{ .x = util.loword(lparam), .y = util.hiword(lparam) });
        },
    };
    return 0;
}

/// Show the context menu at a point in our client area.
fn showContextMenu(self: *Surface, client_pt: c.POINT) void {
    var pt = client_pt;
    _ = c.ClientToScreen(self.hwnd, &pt);
    Menu.track(&Menu.context, self, self.window.hwnd, pt, 0);
}

/// Run an action chosen from a menu.
pub fn performMenuAction(self: *Surface, action: input.Binding.Action) void {
    if (!self.core_initialized) return;
    _ = self.core_surface.performBindingAction(action) catch |err| {
        log.warn("error performing menu action action={} err={}", .{ action, err });
    };
}

/// Handle a key message. Returns true if the message was handled and
/// shouldn't be passed on to DefWindowProc.
fn keyEvent(
    self: *Surface,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) bool {
    const vk: c.UINT = @intCast(wparam & 0xFFFF);
    self.last_key_ms = c.GetTickCount64();

    // Keys being processed by an IME are handled by the IME messages.
    if (vk == c.VK_PROCESSKEY) return false;

    const l: usize = @bitCast(lparam);
    const action: input.Action = switch (msg) {
        c.WM_KEYUP, c.WM_SYSKEYUP => .release,
        else => if ((l >> 30) & 1 != 0) .repeat else .press,
    };

    const native = key.nativeKeycode(wparam, lparam);
    const scancode: c.UINT = native & 0xFF;
    const mods = key.currentMods();

    // Collect the text for this key. TranslateMessage has already
    // queued the character messages for it, so we take them out of the
    // queue so they aren't processed again.
    var utf16_buf: [8]u16 = undefined;
    var utf16_len: usize = 0;
    var composing = false;
    if (action != .release) {
        var peeked: c.MSG = undefined;
        while (utf16_len < utf16_buf.len) {
            if (c.PeekMessageW(&peeked, self.hwnd, c.WM_CHAR, c.WM_DEADCHAR, c.PM_REMOVE) == 0 and
                c.PeekMessageW(&peeked, self.hwnd, c.WM_SYSCHAR, c.WM_SYSDEADCHAR, c.PM_REMOVE) == 0)
            {
                break;
            }

            switch (peeked.message) {
                c.WM_DEADCHAR, c.WM_SYSDEADCHAR => composing = true,
                else => {},
            }
            utf16_buf[utf16_len] = @truncate(peeked.wParam);
            utf16_len += 1;
        }
    }
    const utf16 = utf16_buf[0..utf16_len];

    var utf8_buf: [32]u8 = undefined;
    var consumed_mods: input.Mods = .{};
    const altgr = mods.ctrl and mods.alt and key.altGr();
    const utf8: []const u8 = utf8: {
        // With control (but not AltGr) Windows produces control characters,
        // or nothing at all. We want the text of the key itself.
        if (mods.ctrl and !altgr and action != .release and
            (utf16.len == 0 or key.isControl(utf16)))
        {
            break :utf8 key.textWithoutCtrl(vk, scancode, &utf8_buf);
        }

        break :utf8 key.utf16ToUtf8Buf(utf16, &utf8_buf);
    };

    // Determine the modifiers that were consumed to produce the text.
    if (utf8.len > 0 and !(utf8.len == 1 and std.ascii.isControl(utf8[0]))) {
        if (mods.shift) consumed_mods.shift = true;
        if (altgr) {
            consumed_mods.ctrl = true;
            consumed_mods.alt = true;
        }
    }

    const event: input.KeyEvent = .{
        .action = action,
        .key = key.physicalKey(native),
        .mods = mods,
        .consumed_mods = consumed_mods,
        .composing = composing,
        .utf8 = utf8,
        .unshifted_codepoint = key.unshiftedCodepoint(vk, scancode),
    };

    const effect = self.core_surface.keyCallback(event) catch |err| {
        log.err("error in key callback err={}", .{err});
        return true;
    };

    // Like GTK, the bell stops ringing on any key the core uses.
    if (effect == .consumed and action != .release) self.setBellPending(false);

    // Let Windows handle system keys we didn't use, such as alt+F4 to
    // close the window and alt+space for the system menu.
    if (effect == .ignored and (msg == c.WM_SYSKEYDOWN or msg == c.WM_SYSKEYUP)) {
        if (vk == c.VK_F4 or vk == c.VK_SPACE) return false;
    }

    return true;
}

/// Handle a character that wasn't part of a key event, such as text
/// committed by an IME.
fn charEvent(self: *Surface, unit: u16) void {
    var units: [2]u16 = undefined;
    const slice: []const u16 = if (std.unicode.utf16IsHighSurrogate(unit)) {
        self.high_surrogate = unit;
        return;
    } else if (std.unicode.utf16IsLowSurrogate(unit)) slice: {
        const high = self.high_surrogate orelse return;
        self.high_surrogate = null;
        units = .{ high, unit };
        break :slice &units;
    } else slice: {
        self.high_surrogate = null;
        units[0] = unit;
        break :slice units[0..1];
    };

    var buf: [8]u8 = undefined;
    const text = key.utf16ToUtf8Buf(slice, &buf);
    if (text.len == 0) return;
    _ = self.core_surface.textCallback(text) catch |err| {
        log.err("error in text callback err={}", .{err});
    };
}

/// Handle a change to the IME composition. The in-progress composition
/// is shown as preedit text, and the result is sent as text input.
fn imeComposition(self: *Surface, lparam: c.LPARAM) void {
    const himc = c.ImmGetContext(self.hwnd) orelse return;
    defer _ = c.ImmReleaseContext(self.hwnd, himc);

    const flags: c.DWORD = @truncate(@as(usize, @bitCast(lparam)));
    const alloc = self.app.core_app.alloc;

    if (flags & c.GCS_RESULTSTR != 0) {
        if (imeString(alloc, himc, c.GCS_RESULTSTR)) |result| {
            defer alloc.free(result);
            self.preedit(null);
            if (result.len > 0) {
                _ = self.core_surface.textCallback(result) catch |err| {
                    log.err("error in text callback err={}", .{err});
                };
            }
        }
    }

    if (flags & c.GCS_COMPSTR != 0) {
        if (imeString(alloc, himc, c.GCS_COMPSTR)) |comp| {
            defer alloc.free(comp);
            self.preedit(if (comp.len > 0) comp else null);
        }
    }
}

/// Get one of the IME composition strings as UTF-8.
fn imeString(alloc: Allocator, himc: c.HIMC, index: c.DWORD) ?[:0]u8 {
    // The length is in bytes.
    const len = c.ImmGetCompositionStringW(himc, index, null, 0);
    if (len < 0) return null;
    const buf = alloc.alloc(u16, @as(usize, @intCast(len)) / 2) catch return null;
    defer alloc.free(buf);
    if (buf.len > 0) _ = c.ImmGetCompositionStringW(himc, index, buf.ptr, @intCast(len));
    return util.utf8Alloc(alloc, buf) catch null;
}

fn preedit(self: *Surface, text: ?[]const u8) void {
    self.core_surface.preeditCallback(text) catch |err| {
        log.err("error in preedit callback err={}", .{err});
    };
}

/// Move the IME windows to our cursor.
fn updateImePosition(self: *Surface) void {
    const himc = c.ImmGetContext(self.hwnd) orelse return;
    defer _ = c.ImmReleaseContext(self.hwnd, himc);

    // Win32 wants physical pixels, not scaled points. The point is the
    // horizontal middle and bottom of the cursor cell.
    const pos = self.core_surface.imePointScaled(.{ .x = 1, .y = 1 });
    const x: c_int = @intFromFloat(pos.x);
    const y: c_int = @intFromFloat(pos.y);
    const height: c_int = @intFromFloat(pos.height);

    var form: c.COMPOSITIONFORM = .{
        .dwStyle = c.CFS_POINT,
        .ptCurrentPos = .{ .x = x, .y = y - height },
        .rcArea = std.mem.zeroes(c.RECT),
    };
    _ = c.ImmSetCompositionWindow(himc, &form);

    // Place the candidate window below the cursor, never covering it.
    var candidate: c.CANDIDATEFORM = .{
        .dwIndex = 0,
        .dwStyle = c.CFS_EXCLUDE,
        .ptCurrentPos = .{ .x = x, .y = y },
        .rcArea = .{ .left = x, .top = y - height, .right = x + 1, .bottom = y },
    };
    _ = c.ImmSetCandidateWindow(himc, &candidate);
}
