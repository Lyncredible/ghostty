//! A window for a surface's terminal inspector, like GTK's inspector
//! window. The inspector is drawn with Dear ImGui through its Win32 and
//! Direct3D 11 backends, on a device and swap chain of its own.
const InspectorWindow = @This();

const std = @import("std");
const cimgui = @import("dcimgui");
const global = @import("../../global.zig");
const Inspector = @import("../../inspector/Inspector.zig");
const com = @import("../../renderer/direct3d11/com.zig");
const d3d = com.c;
const D3DDevice = @import("../../renderer/direct3d11/Device.zig");

const util = @import("util.zig");
const c = util.c;
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32);

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyInspector");

/// Redraw this often while open, for the live terminal state, like GTK's
/// tick callback.
const redraw_timer_id = 1;
const redraw_ms = 50;

surface: *Surface,
hwnd: c.HWND,
ig_context: *cimgui.c.ImGuiContext,
device: *d3d.ID3D11Device,
context: *d3d.ID3D11DeviceContext,
swap_chain: *d3d.IDXGISwapChain1,
target: ?*d3d.ID3D11RenderTargetView = null,
last_frame: ?std.Io.Timestamp = null,

/// Open an inspector window for the surface, activating its inspector.
pub fn create(surface: *Surface) !*InspectorWindow {
    const alloc = surface.app.core_app.alloc;
    try surface.core_surface.activateInspector();
    errdefer surface.core_surface.deactivateInspector();

    var title_buf: [512]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Inspector: {s}", .{
        surface.effectiveTitle() orelse "Ghostty",
    }) catch "Inspector";
    const title16 = try util.utf16Alloc(alloc, title);
    defer alloc.free(title16);

    const hwnd = c.CreateWindowExW(
        0,
        class_name,
        title16.ptr,
        c.WS_OVERLAPPEDWINDOW,
        util.CW_USEDEFAULT,
        util.CW_USEDEFAULT,
        0,
        0,
        null,
        null,
        surface.app.hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = c.DestroyWindow(hwnd);

    // The inspector is always dark.
    const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    const dark: c.BOOL = c.TRUE;
    _ = c.DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(c.BOOL));

    // 1000x800 points, like the GTK inspector window.
    const dpi: c_int = @intCast(c.GetDpiForWindow(hwnd));
    _ = util.SetWindowPos(hwnd, 0, 0, 0, @divTrunc(1000 * dpi, 96), @divTrunc(800 * dpi, 96), c.SWP_NOMOVE | c.SWP_NOZORDER);

    var device: D3DDevice = .{ .adapter = null };
    const created = try device.createDevice();
    errdefer {
        com.release(created.context);
        com.release(created.device);
    }
    const swap_chain = try createSwapChain(created.device, hwnd);
    errdefer com.release(swap_chain);

    const ig_context = cimgui.c.ImGui_CreateContext(null) orelse return error.ImGuiFailed;
    errdefer cimgui.c.ImGui_DestroyContext(ig_context);
    cimgui.c.ImGui_SetCurrentContext(ig_context);
    if (!cimgui.ImGui_ImplWin32_Init(hwnd)) return error.ImGuiFailed;
    errdefer cimgui.ImGui_ImplWin32_Shutdown();
    if (!cimgui.ImGui_ImplDX11_Init(created.device, created.context)) return error.ImGuiFailed;
    errdefer cimgui.ImGui_ImplDX11_Shutdown();
    Inspector.setup();

    const self = try alloc.create(InspectorWindow);
    self.* = .{
        .surface = surface,
        .hwnd = hwnd,
        .ig_context = ig_context,
        .device = created.device,
        .context = created.context,
        .swap_chain = swap_chain,
    };
    self.updateScale();
    _ = c.SetWindowLongPtrW(hwnd, util.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    _ = c.SetTimer(hwnd, redraw_timer_id, redraw_ms, null);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    return self;
}

/// Close the window and deactivate the surface's inspector.
pub fn destroy(self: *InspectorWindow) void {
    _ = c.KillTimer(self.hwnd, redraw_timer_id);
    _ = c.SetWindowLongPtrW(self.hwnd, util.GWLP_USERDATA, 0);

    cimgui.c.ImGui_SetCurrentContext(self.ig_context);
    cimgui.ImGui_ImplDX11_Shutdown();
    cimgui.ImGui_ImplWin32_Shutdown();
    cimgui.c.ImGui_DestroyContext(self.ig_context);

    com.releaseOpt(self.target);
    com.release(self.swap_chain);
    com.release(self.context);
    com.release(self.device);
    _ = c.DestroyWindow(self.hwnd);

    self.surface.core_surface.deactivateInspector();
    self.surface.app.core_app.alloc.destroy(self);
}

/// Bring the window to the front.
pub fn present(self: *InspectorWindow) void {
    if (c.IsIconic(self.hwnd) != 0) _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(self.hwnd);
}

/// Redraw soon, for example because the inspector has changes.
pub fn queueRender(self: *InspectorWindow) void {
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

fn createSwapChain(device: *d3d.ID3D11Device, hwnd: c.HWND) !*d3d.IDXGISwapChain1 {
    const dxgi_device = try com.queryInterface(d3d.IDXGIDevice, device, &com.IID_IDXGIDevice);
    defer com.release(dxgi_device);
    var adapter: ?*d3d.IDXGIAdapter = null;
    try com.check(com.call(dxgi_device, "GetAdapter", .{&adapter}), "IDXGIDevice::GetAdapter");
    defer com.releaseOpt(adapter);
    var factory: ?*d3d.IDXGIFactory2 = null;
    try com.check(
        com.call(adapter.?, "GetParent", .{ &com.IID_IDXGIFactory2, @as(?*?*anyopaque, @ptrCast(&factory)) }),
        "IDXGIAdapter::GetParent",
    );
    defer com.releaseOpt(factory);

    const desc: d3d.DXGI_SWAP_CHAIN_DESC1 = .{
        .Width = 0,
        .Height = 0,
        .Format = d3d.DXGI_FORMAT_B8G8R8A8_UNORM,
        .Stereo = d3d.FALSE,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = d3d.DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .Scaling = d3d.DXGI_SCALING_NONE,
        .SwapEffect = d3d.DXGI_SWAP_EFFECT_FLIP_DISCARD,
        .AlphaMode = d3d.DXGI_ALPHA_MODE_IGNORE,
        .Flags = 0,
    };
    var swap_chain: ?*d3d.IDXGISwapChain1 = null;
    try com.check(com.call(factory.?, "CreateSwapChainForHwnd", .{
        @as(*d3d.IUnknown, @ptrCast(device)),
        @as(d3d.HWND, @ptrCast(hwnd)),
        &desc,
        null,
        null,
        &swap_chain,
    }), "IDXGIFactory2::CreateSwapChainForHwnd");
    return swap_chain.?;
}

/// Scale the style and font for the window's DPI. The inspector's font
/// is sized for a 2x scale.
fn updateScale(self: *InspectorWindow) void {
    cimgui.c.ImGui_SetCurrentContext(self.ig_context);
    const scale: f32 = @as(f32, @floatFromInt(c.GetDpiForWindow(self.hwnd))) /
        @as(f32, @floatFromInt(util.USER_DEFAULT_SCREEN_DPI));
    var style: cimgui.c.ImGuiStyle = undefined;
    cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
    cimgui.c.ImGuiStyle_ScaleAllSizes(&style, scale);
    style.FontScaleMain = scale / 2;
    cimgui.c.ImGui_GetStyle().* = style;
}

/// Drop the render target view, for example before resizing the buffers.
fn releaseTarget(self: *InspectorWindow) void {
    if (self.target) |target| {
        com.call(self.context, "OMSetRenderTargets", .{ 0, null, null });
        com.release(target);
        self.target = null;
    }
}

fn ensureTarget(self: *InspectorWindow) !*d3d.ID3D11RenderTargetView {
    if (self.target) |target| return target;
    var buffer: ?*d3d.ID3D11Texture2D = null;
    try com.check(com.call(self.swap_chain, "GetBuffer", .{
        0,
        &com.IID_ID3D11Texture2D,
        @as(?*?*anyopaque, @ptrCast(&buffer)),
    }), "IDXGISwapChain::GetBuffer");
    defer com.releaseOpt(buffer);
    var target: ?*d3d.ID3D11RenderTargetView = null;
    try com.check(com.call(self.device, "CreateRenderTargetView", .{
        @as(*d3d.ID3D11Resource, @ptrCast(buffer.?)),
        null,
        &target,
    }), "ID3D11Device::CreateRenderTargetView");
    self.target = target;
    return target.?;
}

fn render(self: *InspectorWindow) void {
    const target = self.ensureTarget() catch return;
    cimgui.c.ImGui_SetCurrentContext(self.ig_context);

    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    const now: std.Io.Timestamp = .now(global.io(), .awake);
    io.DeltaTime = if (self.last_frame) |prev| delta: {
        const ns: f64 = @floatFromInt(prev.durationTo(now).nanoseconds);
        break :delta @max(0.00001, @as(f32, @floatCast(ns / std.time.ns_per_s)));
    } else 1.0 / 60.0;
    self.last_frame = now;

    // Like GTK, we draw twice, since some ImGui behaviors take two frames.
    for (0..2) |_| {
        cimgui.ImGui_ImplDX11_NewFrame();
        cimgui.ImGui_ImplWin32_NewFrame();
        cimgui.c.ImGui_NewFrame();
        if (self.surface.core_surface.inspector) |inspector| {
            inspector.render(&self.surface.core_surface);
        }
        cimgui.c.ImGui_Render();
    }

    const clear = [4]f32{ 0, 0, 0, 1 };
    com.call(self.context, "OMSetRenderTargets", .{ 1, @as([*c]const ?*d3d.ID3D11RenderTargetView, @ptrCast(&target)), null });
    com.call(self.context, "ClearRenderTargetView", .{ target, &clear });
    cimgui.ImGui_ImplDX11_RenderDrawData(cimgui.c.ImGui_GetDrawData());
    _ = com.call(self.swap_chain, "Present", .{ 1, 0 });
}

pub fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, util.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *InspectorWindow = @ptrFromInt(@as(usize, @bitCast(ptr)));

    // Input for Dear ImGui. It handles input messages but always lets us
    // see them too.
    cimgui.c.ImGui_SetCurrentContext(self.ig_context);
    if (cimgui.ImGui_ImplWin32_WndProcHandler(hwnd.?, msg, wparam, lparam) != 0) return 1;
    switch (msg) {
        c.WM_KEYDOWN,
        c.WM_KEYUP,
        c.WM_SYSKEYDOWN,
        c.WM_SYSKEYUP,
        c.WM_CHAR,
        c.WM_MOUSEMOVE,
        c.WM_MOUSEWHEEL,
        c.WM_MOUSEHWHEEL,
        c.WM_LBUTTONDOWN,
        c.WM_LBUTTONUP,
        c.WM_RBUTTONDOWN,
        c.WM_RBUTTONUP,
        c.WM_MBUTTONDOWN,
        c.WM_MBUTTONUP,
        => self.queueRender(),
        else => {},
    }

    switch (msg) {
        c.WM_ERASEBKGND => return 1,

        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            _ = c.BeginPaint(hwnd, &ps);
            _ = c.EndPaint(hwnd, &ps);
            self.render();
            return 0;
        },

        c.WM_TIMER => if (wparam == redraw_timer_id) {
            if (c.IsIconic(hwnd) == 0) self.render();
            return 0;
        },

        c.WM_SIZE => {
            if (wparam != c.SIZE_MINIMIZED) {
                self.releaseTarget();
                _ = com.call(self.swap_chain, "ResizeBuffers", .{ 0, 0, 0, d3d.DXGI_FORMAT_UNKNOWN, 0 });
                self.queueRender();
            }
            return 0;
        },

        c.WM_DPICHANGED => {
            const rect: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = util.SetWindowPos(hwnd, 0, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            self.updateScale();
            return 0;
        },

        c.WM_CLOSE => {
            self.surface.closeInspector();
            return 0;
        },

        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
