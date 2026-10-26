//! The tab bar of a window. This is a custom drawn child window so that
//! it can match the colors of the terminal, which the native tab control
//! can't.
const TabBar = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../../global.zig");
const configpkg = @import("../../config.zig");
const path = @import("../../os/path.zig");

const util = @import("util.zig");
const c = util.c;
const App = @import("App.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const Menu = @import("Menu.zig");

const log = std.log.scoped(.win32);

window: *Window,

/// The tab bar's window handle.
hwnd: c.HWND,

/// The font used for tab titles, scaled for our DPI.
font: ?c.HFONT = null,

/// The element under the mouse, if any.
hover: ?Hit = null,

/// Whether we're tracking the mouse to get WM_MOUSELEAVE.
tracking_mouse: bool = false,

/// The tab under an in-progress left-button drag, if still present.
drag_tab: ?*Tab = null,
drag_start_x: c_int = 0,
drag_start_y: c_int = 0,
dragging: bool = false,

/// The parts of the tab bar the mouse can be over.
const Hit = union(enum) {
    tab: usize,
    close: usize,
    new_tab,
    shell_menu,
    main_menu,

    fn eql(a: ?Hit, b: ?Hit) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return std.meta.eql(x, y);
    }
};

pub fn init(self: *TabBar, window: *Window) !void {
    const hwnd = c.CreateWindowExW(
        0,
        App.tab_bar_class,
        null,
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        window.hwnd,
        null,
        window.app.hinstance,
        null,
    ) orelse {
        log.err("failed to create tab bar err={}", .{c.GetLastError()});
        return error.CreateWindowFailed;
    };

    self.* = .{ .window = window, .hwnd = hwnd };
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.updateFont();
}

pub fn deinit(self: *TabBar) void {
    _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);
    if (self.font) |f| _ = c.DeleteObject(f);
}

/// Redraw the tab bar, e.g. after tabs or titles changed.
pub fn invalidate(self: *TabBar) void {
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// The height of the tab bar for our current font and DPI.
pub fn height(self: *const TabBar) c_int {
    return self.scale(32);
}

/// Scale a size in DPI-independent pixels to physical pixels.
fn scale(self: *const TabBar, v: c_int) c_int {
    const dpi: c_int = @intCast(c.GetDpiForWindow(self.window.hwnd));
    return @divTrunc(v * dpi, util.USER_DEFAULT_SCREEN_DPI);
}

/// Set our font to the system UI font for our DPI.
pub fn updateFont(self: *TabBar) void {
    const dpi = c.GetDpiForWindow(self.window.hwnd);
    var metrics: c.NONCLIENTMETRICSW = undefined;
    metrics.cbSize = @sizeOf(c.NONCLIENTMETRICSW);
    if (c.SystemParametersInfoForDpi(
        c.SPI_GETNONCLIENTMETRICS,
        metrics.cbSize,
        &metrics,
        0,
        dpi,
    ) == 0) return;

    const font = c.CreateFontIndirectW(&metrics.lfMessageFont) orelse return;
    if (self.font) |old| _ = c.DeleteObject(old);
    self.font = font;
    self.invalidate();
}

//----------------------------------------------------------------------------
// Layout

const Layout = struct {
    /// The width of each tab.
    tab_width: c_int,

    /// The rectangle of the new tab button.
    new_tab: c.RECT,
    shell_menu: c.RECT,

    /// The main menu button, at the right end of the bar.
    main_menu: c.RECT,

    fn tabRect(self: Layout, idx: usize, h: c_int) c.RECT {
        const left = @as(c_int, @intCast(idx)) * self.tab_width;
        return .{ .left = left, .top = 0, .right = left + self.tab_width, .bottom = h };
    }
};

fn layout(self: *const TabBar) Layout {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    const h = client.bottom;
    const n: c_int = @intCast(@max(1, self.window.tabs.items.len));

    // Tabs share the width (less the buttons) up to a maximum.
    const button = h;
    const available = @max(0, client.right - button * 3);
    const tab_width = @min(self.scale(240), @divTrunc(available, n));

    const new_left = tab_width * n;
    return .{
        .tab_width = tab_width,
        .new_tab = .{ .left = new_left, .top = 0, .right = new_left + button, .bottom = h },
        .shell_menu = .{ .left = new_left + button, .top = 0, .right = new_left + button * 2, .bottom = h },
        .main_menu = .{ .left = client.right - button, .top = 0, .right = client.right, .bottom = h },
    };
}

/// The rectangle of the close button of a tab.
fn closeRect(self: *const TabBar, tab: c.RECT) c.RECT {
    const size = self.scale(16);
    const margin = self.scale(8);
    const top = tab.top + @divTrunc(tab.bottom - tab.top - size, 2);
    return .{
        .left = tab.right - margin - size,
        .top = top,
        .right = tab.right - margin,
        .bottom = top + size,
    };
}

fn hitTest(self: *const TabBar, x: c_int, y: c_int) ?Hit {
    const l = self.layout();
    var client: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    const pt: c.POINT = .{ .x = x, .y = y };

    if (c.PtInRect(&l.new_tab, pt) != 0) return .new_tab;
    if (c.PtInRect(&l.shell_menu, pt) != 0) return .shell_menu;
    if (c.PtInRect(&l.main_menu, pt) != 0) return .main_menu;
    for (0..self.window.tabs.items.len) |i| {
        const rect = l.tabRect(i, client.bottom);
        if (c.PtInRect(&rect, pt) == 0) continue;
        const close = self.closeRect(rect);
        if (c.PtInRect(&close, pt) != 0) return .{ .close = i };
        return .{ .tab = i };
    }
    return null;
}

//----------------------------------------------------------------------------
// Painting

const Rgb = struct { r: u8, g: u8, b: u8 };

const Colors = struct {
    bar: Rgb,
    active: Rgb,
    hover: Rgb,
    text: Rgb,
    text_inactive: Rgb,
    separator: Rgb,
};

fn colors(self: *const TabBar) Colors {
    // The active terminal's colors, which programs may have changed.
    const config = &self.window.app.config;
    const surface = if (self.window.tabs.items.len > 0) self.window.activeSurface() else null;
    const bg_color = if (surface) |s| s.background_color orelse config.background.toTerminalRGB() else config.background.toTerminalRGB();
    const fg_color = if (surface) |s| s.foreground_color orelse config.foreground.toTerminalRGB() else config.foreground.toTerminalRGB();
    const bg: Rgb = .{ .r = bg_color.r, .g = bg_color.g, .b = bg_color.b };
    const fg: Rgb = .{ .r = fg_color.r, .g = fg_color.g, .b = fg_color.b };
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const bar = blend(bg, black, 0.25);
    return .{
        .bar = bar,
        .active = bg,
        .hover = blend(bar, fg, 0.08),
        .text = fg,
        .text_inactive = blend(fg, bg, 0.4),
        .separator = blend(bg, fg, 0.15),
    };
}

/// Blend color `a` toward `b` by `t` (0 to 1).
fn blend(a: Rgb, b: Rgb, t: f32) Rgb {
    return .{
        .r = mix(a.r, b.r, t),
        .g = mix(a.g, b.g, t),
        .b = mix(a.b, b.b, t),
    };
}

fn mix(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

fn colorref(v: Rgb) c.COLORREF {
    return @as(c.COLORREF, v.r) | (@as(c.COLORREF, v.g) << 8) | (@as(c.COLORREF, v.b) << 16);
}

fn fill(hdc: c.HDC, rect: *const c.RECT, color: Rgb) void {
    const brush = c.CreateSolidBrush(colorref(color));
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, rect, brush);
}

fn paint(self: *TabBar, hdc: c.HDC, client: c.RECT) void {
    const col = self.colors();
    const l = self.layout();
    const window = self.window;

    fill(hdc, &client, col.bar);

    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    const old_font = if (self.font) |f| c.SelectObject(hdc, f) else null;
    defer if (old_font) |f| {
        _ = c.SelectObject(hdc, f);
    };

    const alloc = window.app.core_app.alloc;
    for (window.tabs.items, 0..) |tab, i| {
        const rect = l.tabRect(i, client.bottom);
        const active = i == window.active;
        const hovered = Hit.eql(self.hover, .{ .tab = i }) or Hit.eql(self.hover, .{ .close = i });

        if (active) {
            fill(hdc, &rect, col.active);
        } else if (hovered) {
            fill(hdc, &rect, col.hover);
        }

        // Separators between inactive tabs.
        if (!active and i + 1 != window.active and i + 1 < window.tabs.items.len) {
            const sep: c.RECT = .{
                .left = rect.right - 1,
                .top = rect.top + self.scale(8),
                .right = rect.right,
                .bottom = rect.bottom - self.scale(8),
            };
            fill(hdc, &sep, col.separator);
        }

        // Title
        const close = self.closeRect(rect);
        var text_rect: c.RECT = .{
            .left = rect.left + self.scale(12),
            .top = rect.top,
            .right = close.left - self.scale(4),
            .bottom = rect.bottom,
        };
        const title = tab.title();
        const title8 = if (tab.hasBell())
            std.fmt.allocPrint(alloc, "🔔 {s}", .{title}) catch continue
        else
            alloc.dupe(u8, title) catch continue;
        defer alloc.free(title8);
        const title16 = util.utf16Alloc(alloc, title8) catch continue;
        defer alloc.free(title16);
        _ = c.SetTextColor(hdc, colorref(if (active) col.text else col.text_inactive));
        _ = c.DrawTextW(
            hdc,
            title16.ptr,
            @intCast(title16.len),
            &text_rect,
            c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
        );

        // Close button, shown on the active and hovered tabs.
        if (active or hovered) {
            if (Hit.eql(self.hover, .{ .close = i })) {
                fill(hdc, &close, blend(if (active) col.active else col.hover, col.text, 0.15));
            }
            self.drawCross(hdc, close, if (active) col.text else col.text_inactive);
        }
    }

    // New tab button
    if (Hit.eql(self.hover, .new_tab)) fill(hdc, &l.new_tab, col.hover);
    self.drawPlus(hdc, l.new_tab, col.text_inactive);
    if (Hit.eql(self.hover, .shell_menu)) fill(hdc, &l.shell_menu, col.hover);
    self.drawChevron(hdc, l.shell_menu, col.text_inactive);
    if (Hit.eql(self.hover, .main_menu)) fill(hdc, &l.main_menu, col.hover);
    self.drawHamburger(hdc, l.main_menu, col.text_inactive);
}

fn drawHamburger(self: *const TabBar, hdc: c.HDC, rect: c.RECT, color: Rgb) void {
    const half_width = self.scale(6);
    const gap = self.scale(4);
    const cx = @divTrunc(rect.left + rect.right, 2);
    const cy = @divTrunc(rect.top + rect.bottom, 2);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, self.scale(1)), colorref(color));
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old);
    for ([_]c_int{ -gap, 0, gap }) |dy| {
        _ = c.MoveToEx(hdc, cx - half_width, cy + dy, null);
        _ = c.LineTo(hdc, cx + half_width + 1, cy + dy);
    }
}

/// Show the main menu below its button.
fn showMainMenu(self: *TabBar) void {
    const rect = self.layout().main_menu;
    var pt: c.POINT = .{ .x = rect.right, .y = rect.bottom };
    _ = c.ClientToScreen(self.hwnd, &pt);
    self.setHover(null);
    Menu.track(&Menu.main, self.window.activeSurface(), self.window.hwnd, pt, c.TPM_RIGHTALIGN);
}

fn drawChevron(self: *const TabBar, hdc: c.HDC, rect: c.RECT, color: Rgb) void {
    const size = self.scale(4);
    const cx = @divTrunc(rect.left + rect.right, 2);
    const cy = @divTrunc(rect.top + rect.bottom, 2);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, self.scale(1)), colorref(color));
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old);
    _ = c.MoveToEx(hdc, cx - size, cy - @divTrunc(size, 2), null);
    _ = c.LineTo(hdc, cx, cy + @divTrunc(size, 2));
    _ = c.LineTo(hdc, cx + size, cy - @divTrunc(size, 2));
}

fn openWslRegistry() ?c.HKEY {
    var current_user: c.HKEY = null;
    if (c.RegOpenCurrentUser(c.KEY_READ, &current_user) != c.ERROR_SUCCESS) return null;
    defer _ = c.RegCloseKey(current_user);

    var key: c.HKEY = null;
    if (c.RegOpenKeyExW(
        current_user,
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss"),
        0,
        c.KEY_READ,
        &key,
    ) != c.ERROR_SUCCESS) return null;
    return key;
}

/// WSL may be installed without a registered distribution. In that case
/// launching bare wsl.exe only displays an error instead of a shell.
fn hasWslDistribution() bool {
    const key = openWslRegistry() orelse return false;
    defer _ = c.RegCloseKey(key);

    var name: [256]u16 = undefined;
    var name_len: c.DWORD = name.len;
    return c.RegEnumKeyExW(key, 0, &name, &name_len, null, null, null, null) == c.ERROR_SUCCESS;
}

/// Add each registered WSL distribution as its own shell choice.
fn appendWslDistributions(
    menu: c.HMENU,
    alloc: Allocator,
    wsl_exe: [:0]const u8,
    commands: *std.ArrayList(configpkg.Command),
) void {
    const root = openWslRegistry() orelse return;
    defer _ = c.RegCloseKey(root);

    var index: c.DWORD = 0;
    while (true) : (index += 1) {
        var key_name: [256]u16 = undefined;
        var key_len: c.DWORD = key_name.len;
        const result = c.RegEnumKeyExW(root, index, &key_name, &key_len, null, null, null, null);
        if (result == c.ERROR_NO_MORE_ITEMS) break;
        if (result != c.ERROR_SUCCESS) continue;
        key_name[key_len] = 0;

        var distro_key: c.HKEY = null;
        if (c.RegOpenKeyExW(root, &key_name, 0, c.KEY_READ, &distro_key) != c.ERROR_SUCCESS) continue;
        defer _ = c.RegCloseKey(distro_key);

        var value_type: c.DWORD = 0;
        var value: [2048]u16 = undefined;
        var value_len: c.DWORD = @sizeOf(@TypeOf(value));
        if (c.RegQueryValueExW(
            distro_key,
            std.unicode.utf8ToUtf16LeStringLiteral("DistributionName"),
            null,
            &value_type,
            @ptrCast(&value),
            &value_len,
        ) != c.ERROR_SUCCESS or value_type != c.REG_SZ) continue;
        const units = @min(@as(usize, @intCast(value_len / 2)), value.len - 1);
        value[units] = 0;
        const name = util.utf8Alloc(alloc, std.mem.sliceTo(value[0 .. units + 1], 0)) catch return;
        if (name.len == 0) continue;

        const label = std.fmt.allocPrint(alloc, "WSL: {s}", .{name}) catch return;
        const label16 = util.utf16Alloc(alloc, label) catch return;
        const argv = alloc.alloc([:0]const u8, 3) catch return;
        argv[0] = wsl_exe;
        argv[1] = "-d";
        argv[2] = name;
        commands.append(alloc, .{ .direct = argv }) catch return;
        _ = c.AppendMenuW(menu, c.MF_STRING, commands.items.len + 1, label16.ptr);
    }
}

/// This native menu pumps messages: the window may close while it is open.
fn showShellMenu(self: *TabBar) void {
    const hwnd = self.hwnd;
    const owner = self.window.hwnd;
    const identity = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    var arena: std.heap.ArenaAllocator = .init(self.window.app.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);

    const candidates = .{
        .{ "Command Prompt", "cmd.exe" },
        .{ "Windows PowerShell", "powershell.exe" },
        .{ "PowerShell", "pwsh.exe" },
        .{ "WSL (default distribution)", "wsl.exe" },
    };
    var commands: std.ArrayList(configpkg.Command) = .empty;
    var wsl_exe: ?[:0]const u8 = null;
    _ = c.AppendMenuW(menu, c.MF_STRING, 1, std.unicode.utf8ToUtf16LeStringLiteral("Configured default"));
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    var env = global.environMap() catch return;
    defer env.deinit();
    inline for (candidates) |candidate| {
        const available = if (comptime std.mem.eql(u8, candidate[1], "wsl.exe"))
            hasWslDistribution()
        else
            true;
        if (available) {
            if (path.expand(global.io(), alloc, &env, candidate[1]) catch null) |exe| {
                const argv = alloc.alloc([:0]const u8, 1) catch return;
                argv[0] = alloc.dupeSentinel(u8, exe, 0) catch return;
                commands.append(alloc, .{ .direct = argv }) catch return;
                _ = c.AppendMenuW(menu, c.MF_STRING, commands.items.len + 1, std.unicode.utf8ToUtf16LeStringLiteral(candidate[0]));
                if (comptime std.mem.eql(u8, candidate[1], "wsl.exe")) wsl_exe = argv[0];
            }
        }
    }
    if (wsl_exe) |exe| appendWslDistributions(menu, alloc, exe, &commands);

    const rect = self.layout().shell_menu;
    var pt: c.POINT = .{ .x = rect.left, .y = rect.bottom };
    _ = c.ClientToScreen(hwnd, &pt);
    self.setHover(null);
    const selected = c.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_NONOTIFY, pt.x, pt.y, 0, owner, null);
    // Never dereference self after the nested loop unless it still owns HWND.
    if (selected == 0 or c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA) != identity) return;
    const shell = if (selected == 1) null else commands.items[@intCast(selected - 2)];
    _ = self.window.addTabWithShell(&self.window.activeSurface().core_surface, shell) catch |err| {
        log.err("error creating shell tab err={}", .{err});
    };
}

fn drawCross(self: *const TabBar, hdc: c.HDC, rect: c.RECT, color: Rgb) void {
    const inset = self.scale(4);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, self.scale(1)), colorref(color));
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old);
    _ = c.MoveToEx(hdc, rect.left + inset, rect.top + inset, null);
    _ = c.LineTo(hdc, rect.right - inset, rect.bottom - inset);
    _ = c.MoveToEx(hdc, rect.right - inset - 1, rect.top + inset, null);
    _ = c.LineTo(hdc, rect.left + inset - 1, rect.bottom - inset);
}

fn drawPlus(self: *const TabBar, hdc: c.HDC, rect: c.RECT, color: Rgb) void {
    const size = self.scale(6);
    const cx = @divTrunc(rect.left + rect.right, 2);
    const cy = @divTrunc(rect.top + rect.bottom, 2);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, self.scale(1)), colorref(color));
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old);
    _ = c.MoveToEx(hdc, cx - size, cy, null);
    _ = c.LineTo(hdc, cx + size + 1, cy);
    _ = c.MoveToEx(hdc, cx, cy - size, null);
    _ = c.LineTo(hdc, cx, cy + size + 1);
}

//----------------------------------------------------------------------------
// Window procedure

fn setHover(self: *TabBar, hit: ?Hit) void {
    if (Hit.eql(self.hover, hit)) return;
    self.hover = hit;
    self.invalidate();
}

fn dragMove(self: *TabBar, x: c_int, y: c_int) void {
    const tab = self.drag_tab orelse return;
    if (self.window.tabs.items[self.window.active] != tab) {
        self.drag_tab = null;
        return;
    }
    if (!self.dragging) {
        // Dragging down starts a drag too, to move the tab to a window.
        const threshold_x = @max(1, c.GetSystemMetrics(c.SM_CXDRAG));
        const threshold_y = @max(1, c.GetSystemMetrics(c.SM_CYDRAG));
        if (@abs(x - self.drag_start_x) < threshold_x and
            @abs(y - self.drag_start_y) < threshold_y) return;
        self.dragging = true;
    }
    const width = self.layout().tab_width;
    if (width <= 0) return;
    const to: usize = @min(
        @as(usize, @intCast(@divTrunc(@max(0, x), width))),
        self.window.tabs.items.len - 1,
    );
    const from = self.window.active;
    if (to != from) _ = self.window.moveTab(@as(isize, @intCast(to)) - @as(isize, @intCast(from)));
}

/// A dragged tab was dropped at a point in our client area. Dropped well
/// above or below the tab bar, like in browsers, it moves to the window
/// under the pointer, or to a new window there. Moving our window's last
/// tab to another window closes ours, and us with it.
fn dropTab(self: *TabBar, tab: *Tab, x: c_int, y: c_int) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    const margin = client.bottom - client.top;
    if (y >= client.top - margin and y < client.bottom + margin) return;

    var pt: c.POINT = .{ .x = x, .y = y };
    _ = c.ClientToScreen(self.hwnd, &pt);
    const window = self.window;
    if (window.app.windowAt(pt)) |target| {
        if (target != window) {
            _ = window.moveTabToWindow(tab, target) catch |err| {
                log.warn("error moving tab to window err={}", .{err});
            };
            return;
        }
    }

    const new_window = (window.tearOffTab(tab) catch |err| {
        log.warn("error moving tab to a new window err={}", .{err});
        return;
    }) orelse return;

    // Put the new window's tab bar under the pointer.
    if (c.IsZoomed(new_window.hwnd) != 0) return;
    const dpi: c_int = @intCast(c.GetDpiForWindow(new_window.hwnd));
    const offset_x = @divTrunc(80 * dpi, 96);
    const offset_y = c.GetSystemMetricsForDpi(c.SM_CYCAPTION, @intCast(dpi)) +
        @divTrunc(margin, 2);
    _ = c.SetWindowPos(
        new_window.hwnd,
        null,
        pt.x - offset_x,
        pt.y - offset_y,
        0,
        0,
        c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

fn paintClient(self: *TabBar, hdc: c.HDC) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    self.paint(hdc, client);
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *TabBar = @ptrFromInt(@as(usize, @bitCast(ptr)));

    switch (msg) {
        c.WM_ERASEBKGND => return 1,

        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);

            var client: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client);
            util.paintOpaque(hdc, client, self, paintClient);
            return 0;
        },

        c.WM_MOUSEMOVE => {
            if (self.drag_tab != null and (wparam & c.MK_LBUTTON) != 0) {
                self.dragMove(util.loword(lparam), util.hiword(lparam));
            }
            if (!self.tracking_mouse) {
                var tme: c.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
                    .dwFlags = c.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                if (c.TrackMouseEvent(&tme) != 0) self.tracking_mouse = true;
            }
            self.setHover(self.hitTest(util.loword(lparam), util.hiword(lparam)));
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.tracking_mouse = false;
            self.setHover(null);
            return 0;
        },

        // We set CS_DBLCLKS for double clicks on empty space. A quick
        // second click on anything else is just another click.
        c.WM_LBUTTONDOWN, c.WM_LBUTTONDBLCLK => {
            const hit = self.hitTest(util.loword(lparam), util.hiword(lparam)) orelse {
                if (msg == c.WM_LBUTTONDBLCLK) _ = self.window.newTab();
                return 0;
            };
            switch (hit) {
                .tab => |i| {
                    self.window.selectTab(i);
                    self.drag_tab = self.window.tabs.items[i];
                    self.drag_start_x = util.loword(lparam);
                    self.drag_start_y = util.hiword(lparam);
                    self.dragging = false;
                    _ = c.SetCapture(hwnd);
                },
                .close => |i| self.window.closeTabAt(i),
                .new_tab => _ = self.window.newTab(),
                .shell_menu => self.showShellMenu(),
                .main_menu => self.showMainMenu(),
            }
            return 0;
        },

        c.WM_LBUTTONUP => {
            if (self.drag_tab) |tab| {
                const dragged = self.dragging;
                self.drag_tab = null;
                self.dragging = false;
                if (c.GetCapture() == hwnd) _ = c.ReleaseCapture();
                if (dragged) self.dropTab(tab, util.loword(lparam), util.hiword(lparam));
            }
            return 0;
        },

        c.WM_CAPTURECHANGED => {
            self.drag_tab = null;
            self.dragging = false;
            return 0;
        },

        c.WM_RBUTTONUP => {
            var pt: c.POINT = .{ .x = util.loword(lparam), .y = util.hiword(lparam) };
            const hit = self.hitTest(pt.x, pt.y);
            _ = c.ClientToScreen(hwnd, &pt);
            self.setHover(null);
            if (hit) |h| switch (h) {
                .tab, .close => |i| {
                    const tab = self.window.tabs.items[i];
                    Menu.track(&Menu.tab, tab.focused, self.window.hwnd, pt, 0);
                    return 0;
                },
                else => {},
            };
            Menu.track(&Menu.main, self.window.activeSurface(), self.window.hwnd, pt, 0);
            return 0;
        },

        c.WM_MBUTTONUP => {
            const hit = self.hitTest(util.loword(lparam), util.hiword(lparam)) orelse return 0;
            switch (hit) {
                .tab, .close => |i| self.window.closeTabAt(i),
                .new_tab, .shell_menu, .main_menu => {},
            }
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
