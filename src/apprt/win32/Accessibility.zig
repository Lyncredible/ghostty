//! UI Automation for a surface, so that screen readers such as Narrator
//! can read the terminal. Like the macOS app's accessibility element, the
//! surface is a document whose value is the text on the screen.
//!
//! The surface returns this provider from WM_GETOBJECT. UI Automation may
//! call it from other threads, so the surface pointer is atomic and is
//! cleared (and the provider disconnected) when the surface goes away.
const Accessibility = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../../global.zig");
const terminal = @import("../../terminal/main.zig");

const util = @import("util.zig");
const c = util.c;
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32);

/// The two COM interfaces we implement. Each is a vtable pointer at the
/// start of a field, so a pointer to the field is the interface pointer.
simple: Interface = .{ .vtbl = &simple_vtbl },
value: Interface = .{ .vtbl = &value_vtbl },

refs: std.atomic.Value(u32) = .init(1),
surface: std.atomic.Value(?*Surface) = .init(null),
alloc: Allocator,

const Interface = extern struct { vtbl: *const anyopaque };

pub fn create(alloc: Allocator, surface: *Surface) !*Accessibility {
    const self = try alloc.create(Accessibility);
    self.* = .{ .alloc = alloc };
    self.surface.store(surface, .release);
    return self;
}

/// Forget the surface and release our reference. Clients may still hold
/// references, which then get nothing.
pub fn detach(self: *Accessibility) void {
    self.surface.store(null, .release);
    _ = UiaDisconnectProvider(&self.simple);
    _ = release(self);
}

/// Answer WM_GETOBJECT for UI Automation.
pub fn getObject(self: *Accessibility, hwnd: c.HWND, wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
    const UiaRootObjectId: c.LPARAM = -25;
    if (lparam != UiaRootObjectId) return null;
    return UiaReturnRawElementProvider(hwnd, wparam, lparam, &self.simple);
}

//---------------------------------------------------------------------------
// COM

const HRESULT = c.HRESULT;
const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_ACCESSDENIED: HRESULT = @bitCast(@as(u32, 0x80070005));
const UIA_E_ELEMENTNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x80040201));

const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const IID_IUnknown: GUID = .{ .a = 0, .b = 0, .c = 0, .d = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IRawElementProviderSimple: GUID = .{ .a = 0xd6dd68d1, .b = 0x86fd, .c = 0x4332, .d = .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c } };
const IID_IValueProvider: GUID = .{ .a = 0xc7935180, .b = 0x6fb3, .c = 0x4201, .d = .{ 0xb1, 0x74, 0x7d, 0xf7, 0x3a, 0xdb, 0xf6, 0x4a } };

const VARIANT = extern struct {
    vt: u16 = 0,
    reserved: [3]u16 = .{ 0, 0, 0 },
    value: extern union {
        int: i32,
        boolean: i16,
        bstr: ?[*:0]u16,
        padding: [2]u64,
    } = .{ .padding = .{ 0, 0 } },
};
const VT_I4 = 3;
const VT_BSTR = 8;
const VT_BOOL = 11;

const ProviderOptions_ServerSideProvider = 0x1;
const ProviderOptions_UseComThreading = 0x20;
const UIA_ValuePatternId = 10002;
const UIA_ControlTypePropertyId = 30003;
const UIA_NamePropertyId = 30005;
const UIA_HasKeyboardFocusPropertyId = 30008;
const UIA_IsKeyboardFocusablePropertyId = 30009;
const UIA_DocumentControlTypeId = 50030;

extern "uiautomationcore" fn UiaReturnRawElementProvider(hwnd: c.HWND, wparam: c.WPARAM, lparam: c.LPARAM, provider: *Interface) callconv(.winapi) c.LRESULT;
extern "uiautomationcore" fn UiaHostProviderFromHwnd(hwnd: c.HWND, provider: *?*anyopaque) callconv(.winapi) HRESULT;
extern "uiautomationcore" fn UiaDisconnectProvider(provider: *Interface) callconv(.winapi) HRESULT;
extern "oleaut32" fn SysAllocStringLen(s: ?[*]const u16, len: u32) callconv(.winapi) ?[*:0]u16;

fn fromSimple(iface: *Interface) *Accessibility {
    return @fieldParentPtr("simple", iface);
}

fn fromValue(iface: *Interface) *Accessibility {
    return @fieldParentPtr("value", iface);
}

fn addRef(self: *Accessibility) u32 {
    return self.refs.fetchAdd(1, .acq_rel) + 1;
}

fn release(self: *Accessibility) u32 {
    const refs = self.refs.fetchSub(1, .acq_rel) - 1;
    if (refs == 0) self.alloc.destroy(self);
    return refs;
}

fn queryInterface(self: *Accessibility, iid: *const GUID, out: *?*anyopaque) HRESULT {
    if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_IRawElementProviderSimple)) {
        out.* = &self.simple;
    } else if (std.meta.eql(iid.*, IID_IValueProvider)) {
        out.* = &self.value;
    } else {
        out.* = null;
        return E_NOINTERFACE;
    }
    _ = addRef(self);
    return S_OK;
}

const simple_vtbl = extern struct {
    QueryInterface: *const fn (*Interface, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT = &simpleQueryInterface,
    AddRef: *const fn (*Interface) callconv(.winapi) u32 = &simpleAddRef,
    Release: *const fn (*Interface) callconv(.winapi) u32 = &simpleRelease,
    get_ProviderOptions: *const fn (*Interface, *i32) callconv(.winapi) HRESULT = &providerOptions,
    GetPatternProvider: *const fn (*Interface, i32, *?*anyopaque) callconv(.winapi) HRESULT = &patternProvider,
    GetPropertyValue: *const fn (*Interface, i32, *VARIANT) callconv(.winapi) HRESULT = &propertyValue,
    get_HostRawElementProvider: *const fn (*Interface, *?*anyopaque) callconv(.winapi) HRESULT = &hostProvider,
}{};

const value_vtbl = extern struct {
    QueryInterface: *const fn (*Interface, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT = &valueQueryInterface,
    AddRef: *const fn (*Interface) callconv(.winapi) u32 = &valueAddRef,
    Release: *const fn (*Interface) callconv(.winapi) u32 = &valueRelease,
    SetValue: *const fn (*Interface, ?[*:0]const u16) callconv(.winapi) HRESULT = &setValue,
    get_Value: *const fn (*Interface, *?[*:0]u16) callconv(.winapi) HRESULT = &getValue,
    get_IsReadOnly: *const fn (*Interface, *c.BOOL) callconv(.winapi) HRESULT = &isReadOnly,
}{};

fn simpleQueryInterface(iface: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    return queryInterface(fromSimple(iface), iid, out);
}
fn simpleAddRef(iface: *Interface) callconv(.winapi) u32 {
    return addRef(fromSimple(iface));
}
fn simpleRelease(iface: *Interface) callconv(.winapi) u32 {
    return release(fromSimple(iface));
}
fn valueQueryInterface(iface: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    return queryInterface(fromValue(iface), iid, out);
}
fn valueAddRef(iface: *Interface) callconv(.winapi) u32 {
    return addRef(fromValue(iface));
}
fn valueRelease(iface: *Interface) callconv(.winapi) u32 {
    return release(fromValue(iface));
}

fn providerOptions(_: *Interface, out: *i32) callconv(.winapi) HRESULT {
    out.* = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading;
    return S_OK;
}

fn patternProvider(iface: *Interface, pattern: i32, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = fromSimple(iface);
    out.* = null;
    if (pattern == UIA_ValuePatternId) {
        out.* = &self.value;
        _ = addRef(self);
    }
    return S_OK;
}

fn propertyValue(iface: *Interface, property: i32, out: *VARIANT) callconv(.winapi) HRESULT {
    const self = fromSimple(iface);
    out.* = .{};
    const surface = self.surface.load(.acquire) orelse return UIA_E_ELEMENTNOTAVAILABLE;
    switch (property) {
        UIA_ControlTypePropertyId => {
            out.vt = VT_I4;
            out.value = .{ .int = UIA_DocumentControlTypeId };
        },
        UIA_NamePropertyId => {
            const name = std.unicode.utf8ToUtf16LeStringLiteral("Terminal");
            out.vt = VT_BSTR;
            out.value = .{ .bstr = SysAllocStringLen(name, name.len) };
        },
        UIA_IsKeyboardFocusablePropertyId => {
            out.vt = VT_BOOL;
            out.value = .{ .boolean = -1 };
        },
        UIA_HasKeyboardFocusPropertyId => {
            out.vt = VT_BOOL;
            out.value = .{ .boolean = if (c.GetFocus() == surface.hwnd) -1 else 0 };
        },
        else => {},
    }
    return S_OK;
}

fn hostProvider(iface: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = fromSimple(iface);
    out.* = null;
    const surface = self.surface.load(.acquire) orelse return UIA_E_ELEMENTNOTAVAILABLE;
    return UiaHostProviderFromHwnd(surface.hwnd, out);
}

fn setValue(_: *Interface, _: ?[*:0]const u16) callconv(.winapi) HRESULT {
    return E_ACCESSDENIED;
}

fn isReadOnly(_: *Interface, out: *c.BOOL) callconv(.winapi) HRESULT {
    out.* = c.TRUE;
    return S_OK;
}

/// The text on the screen (the viewport), like the macOS app's value.
fn getValue(iface: *Interface, out: *?[*:0]u16) callconv(.winapi) HRESULT {
    const self = fromValue(iface);
    out.* = null;
    const surface = self.surface.load(.acquire) orelse return UIA_E_ELEMENTNOTAVAILABLE;
    if (!surface.core_initialized) return UIA_E_ELEMENTNOTAVAILABLE;

    const alloc = self.alloc;
    const text = viewportText(alloc, surface) catch |err| {
        log.warn("error reading text for UI Automation err={}", .{err});
        return UIA_E_ELEMENTNOTAVAILABLE;
    };
    defer alloc.free(text);
    const text16 = util.utf16Alloc(alloc, text) catch return UIA_E_ELEMENTNOTAVAILABLE;
    defer alloc.free(text16);
    out.* = SysAllocStringLen(text16.ptr, @intCast(text16.len));
    return S_OK;
}

fn viewportText(alloc: Allocator, surface: *Surface) ![:0]const u8 {
    const core = &surface.core_surface;
    core.renderer_state.mutex.lockUncancelable(global.io());
    defer core.renderer_state.mutex.unlock(global.io());
    const screen = core.io.terminal.screens.active;
    const top_left = screen.pages.getTopLeft(.viewport);
    const bottom_right = screen.pages.getBottomRight(.viewport) orelse return error.NoViewport;
    return try screen.selectionString(alloc, .{
        .sel = terminal.Selection.init(top_left, bottom_right, false),
        .trim = true,
    });
}
