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
const TextRange = @import("TextRange.zig");

const log = std.log.scoped(.win32);

/// The two COM interfaces we implement. Each is a vtable pointer at the
/// start of a field, so a pointer to the field is the interface pointer.
simple: Interface = .{ .vtbl = &simple_vtbl },
value: Interface = .{ .vtbl = &value_vtbl },
text: Interface = .{ .vtbl = &text_vtbl },

refs: std.atomic.Value(u32) = .init(1),

/// The visible text when we last announced output, to find what's new.
/// Only used on the surface's thread.
last_text: ?[:0]const u8 = null,
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
    if (self.last_text) |t| self.alloc.free(t);
    self.last_text = null;
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

/// Announce new output to screen readers, like Windows Terminal, with a
/// UI Automation notification. Called periodically while the surface has
/// focus. `typing` is whether the user typed recently, in which case
/// changes to the last line are their own echo, which screen readers
/// already speak.
pub fn announceOutput(self: *Accessibility, typing: bool) void {
    if (UiaClientsAreListening() == 0) return;
    const surface = self.surface.load(.acquire) orelse return;
    if (!surface.core_initialized) return;

    const text = viewportText(self.alloc, surface) catch return;
    const old = self.last_text;
    self.last_text = text;
    const previous = old orelse return;
    defer self.alloc.free(previous);

    const change = newOutput(previous, text);
    if (change.text.len == 0) return;
    if (typing and change.only_last_line) return;

    const text16 = util.utf16Alloc(self.alloc, change.text) catch return;
    defer self.alloc.free(text16);
    const display = SysAllocStringLen(text16.ptr, @intCast(text16.len)) orelse return;
    defer SysFreeString(display);
    const activity_id = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyOutput");
    const activity = SysAllocStringLen(activity_id, activity_id.len) orelse return;
    defer SysFreeString(activity);
    _ = UiaRaiseNotificationEvent(&self.simple, NotificationKind_Other, NotificationProcessing_All, display, activity);
}

/// What's new in `new` compared to `old`, two snapshots of the visible
/// lines. If the screen scrolled, the old lines are found at the top of
/// the new ones and everything after them is new; the last old line may
/// have grown, such as a prompt that the output follows on. Otherwise the
/// new text starts at the first line that changed.
pub const Change = struct {
    text: []const u8,
    /// Whether only the last non-empty line changed, such as while typing.
    only_last_line: bool,
};

pub fn newOutput(old: []const u8, new: []const u8) Change {
    const old_trimmed = std.mem.trimEnd(u8, old, " \n");
    const new_trimmed = std.mem.trimEnd(u8, new, " \n");
    if (std.mem.eql(u8, old_trimmed, new_trimmed)) return .{ .text = "", .only_last_line = false };

    // Scrolled (or not) by some number of lines: drop old lines from the
    // top until what's left is where the new text starts.
    var shift: usize = 0;
    var rest = old_trimmed;
    while (true) {
        if (std.mem.startsWith(u8, new_trimmed, rest)) {
            const added = std.mem.trimStart(u8, new_trimmed[rest.len..], " \n");
            const last_line_start = if (std.mem.lastIndexOfScalar(u8, rest, '\n')) |i| i + 1 else 0;
            const only_last = shift == 0 and std.mem.indexOfScalar(u8, new_trimmed[last_line_start..], '\n') == null;
            return .{ .text = added, .only_last_line = only_last };
        }
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
        rest = rest[nl + 1 ..];
        shift += 1;
    }

    // Something changed in place: from the first line that differs.
    var start: usize = 0;
    var i: usize = 0;
    while (i < old_trimmed.len and i < new_trimmed.len and old_trimmed[i] == new_trimmed[i]) : (i += 1) {
        if (new_trimmed[i] == '\n') start = i + 1;
    }
    const tail = new_trimmed[start..];
    return .{ .text = tail, .only_last_line = std.mem.indexOfScalar(u8, tail, '\n') == null };
}

test newOutput {
    const testing = std.testing;

    // A command's output after the prompt, without scrolling.
    var change = newOutput("C:\\> dir\n\n", "C:\\> dir\nfile.txt\nC:\\>\n");
    try testing.expectEqualStrings("file.txt\nC:\\>", change.text);
    try testing.expect(!change.only_last_line);

    // Typing on the prompt line.
    change = newOutput("a\nC:\\> di", "a\nC:\\> dir");
    try testing.expectEqualStrings("r", change.text);
    try testing.expect(change.only_last_line);

    // Scrolled by two lines.
    change = newOutput("1\n2\n3\n4", "3\n4\n5\n6");
    try testing.expectEqualStrings("5\n6", change.text);
    try testing.expect(!change.only_last_line);

    // Nothing new.
    try testing.expectEqualStrings("", newOutput("a\nb  \n", "a\nb\n\n").text);

    // Cleared and redrawn.
    change = newOutput("old\nscreen", "new\nscreen");
    try testing.expectEqualStrings("new\nscreen", change.text);
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
const IID_ITextProvider: GUID = .{ .a = 0x3589c92c, .b = 0x63f3, .c = 0x4367, .d = .{ 0x99, 0xbb, 0xad, 0xa6, 0x53, 0xb7, 0x7c, 0xf2 } };
const IID_ITextRangeProvider: GUID = .{ .a = 0x5347ad7b, .b = 0xc355, .c = 0x46f8, .d = .{ 0xaf, 0xf5, 0x90, 0x90, 0x33, 0x58, 0x2f, 0x63 } };
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
const UIA_TextPatternId = 10014;
const SupportedTextSelection_Single = 1;
const VT_R8 = 5;
const VT_UNKNOWN = 13;
const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000e));
const UIA_ControlTypePropertyId = 30003;
const UIA_NamePropertyId = 30005;
const UIA_HasKeyboardFocusPropertyId = 30008;
const UIA_IsKeyboardFocusablePropertyId = 30009;
const UIA_DocumentControlTypeId = 50030;

extern "uiautomationcore" fn UiaReturnRawElementProvider(hwnd: c.HWND, wparam: c.WPARAM, lparam: c.LPARAM, provider: *Interface) callconv(.winapi) c.LRESULT;
extern "uiautomationcore" fn UiaHostProviderFromHwnd(hwnd: c.HWND, provider: *?*anyopaque) callconv(.winapi) HRESULT;
extern "uiautomationcore" fn UiaDisconnectProvider(provider: *Interface) callconv(.winapi) HRESULT;
extern "oleaut32" fn SysAllocStringLen(s: ?[*]const u16, len: u32) callconv(.winapi) ?[*:0]u16;
extern "oleaut32" fn SysFreeString(s: ?[*:0]u16) callconv(.winapi) void;
extern "oleaut32" fn SafeArrayCreateVector(vt: u16, lower: i32, count: u32) callconv(.winapi) ?*anyopaque;
extern "oleaut32" fn SafeArrayPutElement(array: *anyopaque, index: *const i32, value: *const anyopaque) callconv(.winapi) HRESULT;
extern "uiautomationcore" fn UiaGetReservedNotSupportedValue(out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "uiautomationcore" fn UiaClientsAreListening() callconv(.winapi) c.BOOL;
extern "uiautomationcore" fn UiaRaiseAutomationEvent(provider: *Interface, id: i32) callconv(.winapi) HRESULT;
const UIA_Text_TextSelectionChangedEventId = 20014;
extern "uiautomationcore" fn UiaRaiseNotificationEvent(
    provider: *Interface,
    kind: i32,
    processing: i32,
    display: ?[*:0]u16,
    activity: ?[*:0]u16,
) callconv(.winapi) HRESULT;
const NotificationKind_Other = 4;
const NotificationProcessing_All = 2;

fn fromSimple(iface: *Interface) *Accessibility {
    return @fieldParentPtr("simple", iface);
}

fn fromValue(iface: *Interface) *Accessibility {
    return @fieldParentPtr("value", iface);
}

fn fromText(iface: *Interface) *Accessibility {
    return @fieldParentPtr("text", iface);
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
    } else if (std.meta.eql(iid.*, IID_ITextProvider)) {
        out.* = &self.text;
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
    } else if (pattern == UIA_TextPatternId) {
        out.* = &self.text;
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

//---------------------------------------------------------------------------
// Text pattern

const UiaPoint = extern struct { x: f64, y: f64 };

const text_vtbl = extern struct {
    QueryInterface: *const fn (*Interface, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT = &textQueryInterface,
    AddRef: *const fn (*Interface) callconv(.winapi) u32 = &textAddRef,
    Release: *const fn (*Interface) callconv(.winapi) u32 = &textRelease,
    GetSelection: *const fn (*Interface, *?*anyopaque) callconv(.winapi) HRESULT = &textSelection,
    GetVisibleRanges: *const fn (*Interface, *?*anyopaque) callconv(.winapi) HRESULT = &textVisibleRanges,
    RangeFromChild: *const fn (*Interface, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT = &textRangeFromChild,
    RangeFromPoint: *const fn (*Interface, UiaPoint, *?*anyopaque) callconv(.winapi) HRESULT = &textRangeFromPoint,
    get_DocumentRange: *const fn (*Interface, *?*anyopaque) callconv(.winapi) HRESULT = &textDocumentRange,
    get_SupportedTextSelection: *const fn (*Interface, *i32) callconv(.winapi) HRESULT = &textSupportedSelection,
}{};

fn textQueryInterface(iface: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    return queryInterface(fromText(iface), iid, out);
}
fn textAddRef(iface: *Interface) callconv(.winapi) u32 {
    return addRef(fromText(iface));
}
fn textRelease(iface: *Interface) callconv(.winapi) u32 {
    return release(fromText(iface));
}

/// A snapshot of the visible text, the cursor, and where the text is on
/// the screen.
fn takeSnapshot(self: *Accessibility) !*TextRange.Snapshot {
    const surface = self.surface.load(.acquire) orelse return error.NoSurface;
    if (!surface.core_initialized) return error.NoSurface;
    const alloc = self.alloc;

    const text, const cursor_line: u32, const cursor_column: u32, const selection = text: {
        const core = &surface.core_surface;
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        const screen = core.io.terminal.screens.active;
        const top_left = screen.pages.getTopLeft(.viewport);
        const bottom_right = screen.pages.getBottomRight(.viewport) orelse return error.NoViewport;
        const utf8 = try screen.selectionString(alloc, .{
            .sel = terminal.Selection.init(top_left, bottom_right, false),
            .trim = true,
        });
        break :text .{ utf8, screen.cursor.y, screen.cursor.x, viewportSelection(screen) };
    };
    defer alloc.free(text);
    const text16 = try util.utf16Alloc(alloc, text);
    errdefer alloc.free(text16);

    const snapshot = try alloc.create(TextRange.Snapshot);
    snapshot.* = .{ .alloc = alloc, .text = text16, .cursor = 0 };
    snapshot.cursor = snapshot.offsetOf(cursor_line, cursor_column);
    if (selection) |sel| snapshot.selection = .{
        snapshot.offsetOf(sel.start_line, sel.start_column),
        snapshot.offsetOf(sel.end_line, sel.end_column),
    };

    var rect: c.RECT = undefined;
    if (c.GetWindowRect(surface.hwnd, &rect) != 0) {
        const size = surface.core_surface.size;
        snapshot.origin_x = @floatFromInt(rect.left + @as(c_int, @intCast(size.padding.left)));
        snapshot.origin_y = @floatFromInt(rect.top + @as(c_int, @intCast(size.padding.top)));
        snapshot.cell_width = @floatFromInt(size.cell.width);
        snapshot.cell_height = @floatFromInt(size.cell.height);
    }
    return snapshot;
}

/// The part of the screen's selection in the viewport, as lines and
/// columns of the viewport with an exclusive end, or null if none of it
/// is visible. A rectangle selection is treated as running from its top
/// left to its bottom right.
fn viewportSelection(screen: *terminal.Screen) ?struct {
    start_line: u32,
    start_column: u32,
    end_line: u32,
    end_column: u32,
} {
    const sel = screen.selection orelse return null;
    const pages = &screen.pages;
    const start = (pages.pointFromPin(.screen, sel.topLeft(screen)) orelse return null).coord();
    const end = (pages.pointFromPin(.screen, sel.bottomRight(screen)) orelse return null).coord();
    const top = (pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse return null).coord().y;
    const bottom_pin = pages.getBottomRight(.viewport) orelse return null;
    const bottom = (pages.pointFromPin(.screen, bottom_pin) orelse return null).coord().y;
    if (end.y < top or start.y > bottom) return null;

    return .{
        .start_line = if (start.y < top) 0 else start.y - top,
        .start_column = if (start.y < top) 0 else start.x,
        .end_line = @min(end.y, bottom) - top,
        .end_column = if (end.y > bottom) std.math.maxInt(u32) else @as(u32, end.x) + 1,
    };
}

test viewportSelection {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s: terminal.Screen = try .init(testing.io, alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 10_000 });
    defer s.deinit();
    try s.testWriteString("1\n2\n3\nabcd\nefgh");
    try testing.expect(viewportSelection(&s) == null);

    // Within the viewport, which shows "3", "abcd", and "efgh".
    try s.select(terminal.Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 2, .y = 4 } }).?,
        false,
    ));
    const inside = viewportSelection(&s).?;
    try testing.expectEqual(@as(u32, 1), inside.start_line);
    try testing.expectEqual(@as(u32, 1), inside.start_column);
    try testing.expectEqual(@as(u32, 2), inside.end_line);
    try testing.expectEqual(@as(u32, 3), inside.end_column);

    // Starting in the scrollback: the visible part starts at the top.
    try s.select(terminal.Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
        false,
    ));
    const above = viewportSelection(&s).?;
    try testing.expectEqual(@as(u32, 0), above.start_line);
    try testing.expectEqual(@as(u32, 0), above.start_column);
    try testing.expectEqual(@as(u32, 1), above.end_line);
    try testing.expectEqual(@as(u32, 2), above.end_column);

    // Only in the scrollback.
    try s.select(terminal.Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
        false,
    ));
    try testing.expect(viewportSelection(&s) == null);
}

/// Tell screen readers that the terminal's selection changed. This must
/// not be called with the renderer mutex held, since screen readers may
/// ask for the selection right away.
pub fn selectionChanged(self: *Accessibility) void {
    if (UiaClientsAreListening() == 0) return;
    _ = UiaRaiseAutomationEvent(&self.simple, UIA_Text_TextSelectionChangedEventId);
}

/// A new text range object, taking a reference to the snapshot.
fn newRange(self: *Accessibility, snapshot: *TextRange.Snapshot, start: u32, end: u32) !*RangeObject {
    const range = try self.alloc.create(RangeObject);
    snapshot.ref();
    _ = addRef(self);
    range.* = .{
        .owner = self,
        .range = .{ .snapshot = snapshot, .start = start, .end = end },
    };
    return range;
}

/// A SAFEARRAY with one text range.
fn rangeArray(range: *RangeObject) ?*anyopaque {
    const array = SafeArrayCreateVector(VT_UNKNOWN, 0, 1) orelse return null;
    const index: i32 = 0;
    _ = SafeArrayPutElement(array, &index, &range.iface);
    return array;
}

fn textSelection(iface: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = fromText(iface);
    out.* = null;
    const snapshot = self.takeSnapshot() catch return UIA_E_ELEMENTNOTAVAILABLE;
    defer snapshot.unref();
    // We report the terminal's selection, or else the cursor as an empty
    // selection, like a caret.
    const start, const end = snapshot.selection orelse .{ snapshot.cursor, snapshot.cursor };
    const range = self.newRange(snapshot, start, end) catch return E_OUTOFMEMORY;
    defer _ = range.release();
    out.* = rangeArray(range) orelse return E_OUTOFMEMORY;
    return S_OK;
}

fn textVisibleRanges(iface: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = fromText(iface);
    out.* = null;
    const snapshot = self.takeSnapshot() catch return UIA_E_ELEMENTNOTAVAILABLE;
    defer snapshot.unref();
    const range = self.newRange(snapshot, 0, @intCast(snapshot.text.len)) catch return E_OUTOFMEMORY;
    defer _ = range.release();
    out.* = rangeArray(range) orelse return E_OUTOFMEMORY;
    return S_OK;
}

fn textRangeFromChild(_: *Interface, _: ?*anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    return E_INVALIDARG;
}

fn textRangeFromPoint(iface: *Interface, point: UiaPoint, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = fromText(iface);
    out.* = null;
    const snapshot = self.takeSnapshot() catch return UIA_E_ELEMENTNOTAVAILABLE;
    defer snapshot.unref();
    const line: u32 = if (snapshot.cell_height > 0) @intFromFloat(@max(0, (point.y - snapshot.origin_y) / snapshot.cell_height)) else 0;
    const column: u32 = if (snapshot.cell_width > 0) @intFromFloat(@max(0, (point.x - snapshot.origin_x) / snapshot.cell_width)) else 0;
    const pos = snapshot.offsetOf(line, column);
    const range = self.newRange(snapshot, pos, pos) catch return E_OUTOFMEMORY;
    out.* = &range.iface;
    return S_OK;
}

fn textDocumentRange(iface: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = fromText(iface);
    out.* = null;
    const snapshot = self.takeSnapshot() catch return UIA_E_ELEMENTNOTAVAILABLE;
    defer snapshot.unref();
    const range = self.newRange(snapshot, 0, @intCast(snapshot.text.len)) catch return E_OUTOFMEMORY;
    out.* = &range.iface;
    return S_OK;
}

fn textSupportedSelection(_: *Interface, out: *i32) callconv(.winapi) HRESULT {
    out.* = SupportedTextSelection_Single;
    return S_OK;
}

/// An ITextRangeProvider.
const RangeObject = struct {
    iface: Interface = .{ .vtbl = &range_vtbl },
    refs: std.atomic.Value(u32) = .init(1),
    owner: *Accessibility,
    range: TextRange.Range,

    fn from(iface: *Interface) *RangeObject {
        return @fieldParentPtr("iface", iface);
    }

    fn release(self: *RangeObject) u32 {
        const refs = self.refs.fetchSub(1, .acq_rel) - 1;
        if (refs == 0) {
            const owner = self.owner;
            self.range.snapshot.unref();
            owner.alloc.destroy(self);
            _ = Accessibility.release(owner);
        }
        return refs;
    }

    /// Another range of ours, given as an ITextRangeProvider. Ranges from
    /// other providers aren't ours, and would be a different object type.
    fn other(self: *RangeObject, iface: ?*Interface) ?*RangeObject {
        const i = iface orelse return null;
        if (i.vtbl != @as(*const anyopaque, &range_vtbl)) return null;
        const range = from(i);
        if (range.owner != self.owner) return null;
        return range;
    }
};

const range_vtbl = extern struct {
    QueryInterface: *const fn (*Interface, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT = &rangeQueryInterface,
    AddRef: *const fn (*Interface) callconv(.winapi) u32 = &rangeAddRef,
    Release: *const fn (*Interface) callconv(.winapi) u32 = &rangeRelease,
    Clone: *const fn (*Interface, *?*anyopaque) callconv(.winapi) HRESULT = &rangeClone,
    Compare: *const fn (*Interface, ?*Interface, *c.BOOL) callconv(.winapi) HRESULT = &rangeCompare,
    CompareEndpoints: *const fn (*Interface, i32, ?*Interface, i32, *i32) callconv(.winapi) HRESULT = &rangeCompareEndpoints,
    ExpandToEnclosingUnit: *const fn (*Interface, i32) callconv(.winapi) HRESULT = &rangeExpand,
    FindAttribute: *const fn (*Interface, i32, VARIANT, c.BOOL, *?*anyopaque) callconv(.winapi) HRESULT = &rangeFindAttribute,
    FindText: *const fn (*Interface, ?[*:0]const u16, c.BOOL, c.BOOL, *?*anyopaque) callconv(.winapi) HRESULT = &rangeFindText,
    GetAttributeValue: *const fn (*Interface, i32, *VARIANT) callconv(.winapi) HRESULT = &rangeAttributeValue,
    GetBoundingRectangles: *const fn (*Interface, *?*anyopaque) callconv(.winapi) HRESULT = &rangeBoundingRectangles,
    GetEnclosingElement: *const fn (*Interface, *?*anyopaque) callconv(.winapi) HRESULT = &rangeEnclosingElement,
    GetText: *const fn (*Interface, i32, *?[*:0]u16) callconv(.winapi) HRESULT = &rangeText,
    Move: *const fn (*Interface, i32, i32, *i32) callconv(.winapi) HRESULT = &rangeMove,
    MoveEndpointByUnit: *const fn (*Interface, i32, i32, i32, *i32) callconv(.winapi) HRESULT = &rangeMoveEndpointByUnit,
    MoveEndpointByRange: *const fn (*Interface, i32, ?*Interface, i32) callconv(.winapi) HRESULT = &rangeMoveEndpointByRange,
    Select: *const fn (*Interface) callconv(.winapi) HRESULT = &rangeNoop,
    AddToSelection: *const fn (*Interface) callconv(.winapi) HRESULT = &rangeNoop,
    RemoveFromSelection: *const fn (*Interface) callconv(.winapi) HRESULT = &rangeNoop,
    ScrollIntoView: *const fn (*Interface, c.BOOL) callconv(.winapi) HRESULT = &rangeScrollIntoView,
    GetChildren: *const fn (*Interface, *?*anyopaque) callconv(.winapi) HRESULT = &rangeChildren,
}{};

fn rangeQueryInterface(iface: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_ITextRangeProvider)) {
        out.* = iface;
        _ = rangeAddRef(iface);
        return S_OK;
    }
    out.* = null;
    return E_NOINTERFACE;
}
fn rangeAddRef(iface: *Interface) callconv(.winapi) u32 {
    return RangeObject.from(iface).refs.fetchAdd(1, .acq_rel) + 1;
}
fn rangeRelease(iface: *Interface) callconv(.winapi) u32 {
    return RangeObject.from(iface).release();
}

fn rangeClone(iface: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = RangeObject.from(iface);
    const clone = self.owner.newRange(self.range.snapshot, self.range.start, self.range.end) catch {
        out.* = null;
        return E_OUTOFMEMORY;
    };
    out.* = &clone.iface;
    return S_OK;
}

fn rangeCompare(iface: *Interface, target: ?*Interface, out: *c.BOOL) callconv(.winapi) HRESULT {
    const self = RangeObject.from(iface);
    const other = self.other(target) orelse return E_INVALIDARG;
    out.* = @intFromBool(other.range.start == self.range.start and other.range.end == self.range.end);
    return S_OK;
}

fn rangeCompareEndpoints(iface: *Interface, endpoint: i32, target: ?*Interface, target_endpoint: i32, out: *i32) callconv(.winapi) HRESULT {
    const self = RangeObject.from(iface);
    const other = self.other(target) orelse return E_INVALIDARG;
    const a: i64 = if (endpoint == 0) self.range.start else self.range.end;
    const b: i64 = if (target_endpoint == 0) other.range.start else other.range.end;
    out.* = @intCast(std.math.clamp(a - b, -1, 1));
    return S_OK;
}

fn rangeExpand(iface: *Interface, unit: i32) callconv(.winapi) HRESULT {
    RangeObject.from(iface).range.expand(@fromBackingInt(@intCast(unit)));
    return S_OK;
}

fn rangeFindAttribute(_: *Interface, _: i32, _: VARIANT, _: c.BOOL, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    return S_OK;
}

fn rangeFindText(iface: *Interface, needle: ?[*:0]const u16, backward: c.BOOL, ignore_case: c.BOOL, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = RangeObject.from(iface);
    out.* = null;
    const n = std.mem.sliceTo(needle orelse return E_INVALIDARG, 0);
    if (n.len == 0) return E_INVALIDARG;
    const hay = self.range.snapshot.text[self.range.start..self.range.end];
    if (n.len > hay.len) return S_OK;

    const lower = struct {
        fn f(ch: u16) u16 {
            return if (ch < 128) std.ascii.toLower(@intCast(ch)) else ch;
        }
    }.f;
    var i: usize = 0;
    var found: ?usize = null;
    while (i + n.len <= hay.len) : (i += 1) {
        const match = for (n, hay[i .. i + n.len]) |x, y| {
            if (if (ignore_case != 0) lower(x) != lower(y) else x != y) break false;
        } else true;
        if (match) {
            found = i;
            if (backward == 0) break;
        }
    }
    const at = found orelse return S_OK;
    const start: u32 = self.range.start + @as(u32, @intCast(at));
    const range = self.owner.newRange(self.range.snapshot, start, start + @as(u32, @intCast(n.len))) catch return E_OUTOFMEMORY;
    out.* = &range.iface;
    return S_OK;
}

fn rangeAttributeValue(_: *Interface, _: i32, out: *VARIANT) callconv(.winapi) HRESULT {
    // We don't report formatting.
    out.* = .{};
    var not_supported: ?*anyopaque = null;
    if (UiaGetReservedNotSupportedValue(&not_supported) >= 0) {
        out.vt = VT_UNKNOWN;
        out.value = .{ .padding = .{ @intFromPtr(not_supported), 0 } };
    }
    return S_OK;
}

/// A rectangle (left, top, width, height) for each line in the range.
fn rangeBoundingRectangles(iface: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const self = RangeObject.from(iface);
    const s = self.range.snapshot;
    var rects: std.ArrayList(f64) = .empty;
    defer rects.deinit(self.owner.alloc);
    if (s.cell_height > 0) {
        var pos = self.range.start;
        while (true) {
            const line_end = s.nextUnit(pos, .line);
            const end = @min(line_end, self.range.end);
            const lc = s.lineColumn(pos);
            var columns: u32 = end - pos;
            if (columns > 0 and s.text[end - 1] == '\n') columns -= 1;
            if (columns > 0) rects.appendSlice(self.owner.alloc, &.{
                s.origin_x + @as(f64, @floatFromInt(lc.column)) * s.cell_width,
                s.origin_y + @as(f64, @floatFromInt(lc.line)) * s.cell_height,
                @as(f64, @floatFromInt(columns)) * s.cell_width,
                s.cell_height,
            }) catch return E_OUTOFMEMORY;
            if (line_end >= self.range.end or line_end >= s.text.len) break;
            pos = line_end;
        }
    }
    const array = SafeArrayCreateVector(VT_R8, 0, @intCast(rects.items.len)) orelse return E_OUTOFMEMORY;
    for (rects.items, 0..) |value, i| {
        const index: i32 = @intCast(i);
        _ = SafeArrayPutElement(array, &index, &value);
    }
    out.* = array;
    return S_OK;
}

fn rangeEnclosingElement(iface: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
    const owner = RangeObject.from(iface).owner;
    out.* = &owner.simple;
    _ = addRef(owner);
    return S_OK;
}

fn rangeText(iface: *Interface, max_length: i32, out: *?[*:0]u16) callconv(.winapi) HRESULT {
    const self = RangeObject.from(iface);
    var text = self.range.snapshot.text[self.range.start..self.range.end];
    if (max_length >= 0 and text.len > max_length) text = text[0..@intCast(max_length)];
    out.* = SysAllocStringLen(text.ptr, @intCast(text.len));
    return S_OK;
}

fn rangeMove(iface: *Interface, unit: i32, count: i32, out: *i32) callconv(.winapi) HRESULT {
    out.* = RangeObject.from(iface).range.move(@fromBackingInt(@intCast(unit)), count);
    return S_OK;
}

fn rangeMoveEndpointByUnit(iface: *Interface, endpoint: i32, unit: i32, count: i32, out: *i32) callconv(.winapi) HRESULT {
    out.* = RangeObject.from(iface).range.moveEndpoint(endpoint == 0, @fromBackingInt(@intCast(unit)), count);
    return S_OK;
}

fn rangeMoveEndpointByRange(iface: *Interface, endpoint: i32, target: ?*Interface, target_endpoint: i32) callconv(.winapi) HRESULT {
    const self = RangeObject.from(iface);
    const other = self.other(target) orelse return E_INVALIDARG;
    const pos = if (target_endpoint == 0) other.range.start else other.range.end;
    if (endpoint == 0) {
        self.range.start = pos;
        if (self.range.end < pos) self.range.end = pos;
    } else {
        self.range.end = pos;
        if (self.range.start > pos) self.range.start = pos;
    }
    return S_OK;
}

fn rangeNoop(_: *Interface) callconv(.winapi) HRESULT {
    return S_OK;
}

fn rangeScrollIntoView(_: *Interface, _: c.BOOL) callconv(.winapi) HRESULT {
    return S_OK;
}

fn rangeChildren(_: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = SafeArrayCreateVector(VT_UNKNOWN, 0, 0) orelse return E_OUTOFMEMORY;
    return S_OK;
}
