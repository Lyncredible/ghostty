//! UI Automation for the tab bar, which we draw ourselves, so that screen
//! readers can find and switch tabs: a Tab control whose children are
//! TabItems named by the tabs' titles, which can be selected, and then
//! the bar's buttons, which can be invoked.
//!
//! The tab bar returns the root from WM_GETOBJECT. We ask UI Automation to
//! call us on the tab bar's thread (UseComThreading), so the tab bar and
//! its window are only touched there. The tab bar is cleared (and the
//! provider disconnected) when the tab bar goes away, after which every
//! element is unavailable.
const Root = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("util.zig");
const c = util.c;
const Tab = @import("Tab.zig");
const TabBar = @import("TabBar.zig");

simple: Interface = .{ .vtbl = &root_simple_vtbl },
fragment: Interface = .{ .vtbl = &root_fragment_vtbl },
fragment_root: Interface = .{ .vtbl = &root_fragment_root_vtbl },
selection: Interface = .{ .vtbl = &root_selection_vtbl },

refs: std.atomic.Value(u32) = .init(1),
bar: ?*TabBar,
alloc: Allocator,

pub fn create(alloc: Allocator, bar: *TabBar) !*Root {
    const self = try alloc.create(Root);
    self.* = .{ .alloc = alloc, .bar = bar };
    return self;
}

/// Forget the tab bar and release our reference.
pub fn detach(self: *Root) void {
    self.bar = null;
    _ = UiaDisconnectProvider(&self.simple);
    _ = self.release();
}

/// Answer WM_GETOBJECT for UI Automation.
pub fn getObject(self: *Root, hwnd: c.HWND, wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
    const UiaRootObjectId: c.LPARAM = -25;
    if (lparam != UiaRootObjectId) return null;
    return UiaReturnRawElementProvider(hwnd, wparam, lparam, &self.simple);
}

/// Tell screen readers that a tab was selected.
pub fn tabSelected(self: *Root, tab: *Tab) void {
    if (UiaClientsAreListening() == 0) return;
    const item = Item.create(self, .{ .tab = tab }) catch return;
    defer _ = item.release();
    _ = UiaRaiseAutomationEvent(&item.simple, UIA_SelectionItem_ElementSelectedEventId);
}

fn addRef(self: *Root) u32 {
    return self.refs.fetchAdd(1, .acq_rel) + 1;
}

fn release(self: *Root) u32 {
    const refs = self.refs.fetchSub(1, .acq_rel) - 1;
    if (refs == 0) self.alloc.destroy(self);
    return refs;
}

fn queryInterface(self: *Root, iid: *const GUID, out: *?*anyopaque) HRESULT {
    out.* = if (eqlGuid(iid, &IID_IUnknown) or eqlGuid(iid, &IID_IRawElementProviderSimple))
        &self.simple
    else if (eqlGuid(iid, &IID_IRawElementProviderFragment))
        &self.fragment
    else if (eqlGuid(iid, &IID_IRawElementProviderFragmentRoot))
        &self.fragment_root
    else if (eqlGuid(iid, &IID_ISelectionProvider))
        &self.selection
    else
        return E_NOINTERFACE;
    _ = self.addRef();
    return S_OK;
}

/// The child element at a position, with a reference for the caller: the
/// tabs, then the buttons.
fn childAt(self: *Root, pos: usize) ?*Item {
    const bar = self.bar orelse return null;
    const tabs = bar.window.tabs.items;
    const kind: Item.Kind = if (pos < tabs.len)
        .{ .tab = tabs[pos] }
    else if (pos - tabs.len < buttons.len)
        .{ .button = buttons[pos - tabs.len] }
    else
        return null;
    return Item.create(self, kind) catch null;
}

fn childCount(self: *const Root) usize {
    const bar = self.bar orelse return 0;
    return bar.window.tabs.items.len + buttons.len;
}

const buttons = std.enums.values(TabBar.Button);

fn fromIface(comptime field: []const u8, iface: *Interface) *Root {
    return @alignCast(@fieldParentPtr(field, iface));
}

// IRawElementProviderSimple

const root_simple_vtbl = SimpleVtbl{
    .QueryInterface = struct {
        fn f(i: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return fromIface("simple", i).queryInterface(iid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return fromIface("simple", i).addRef();
        }
    }.f,
    .Release = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return fromIface("simple", i).release();
        }
    }.f,
    .get_ProviderOptions = providerOptions,
    .GetPatternProvider = struct {
        fn f(i: *Interface, pattern: i32, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const self = fromIface("simple", i);
            out.* = null;
            if (pattern == UIA_SelectionPatternId) {
                out.* = &self.selection;
                _ = self.addRef();
            }
            return S_OK;
        }
    }.f,
    .GetPropertyValue = struct {
        fn f(i: *Interface, property: i32, out: *VARIANT) callconv(.winapi) HRESULT {
            const self = fromIface("simple", i);
            out.* = .{};
            if (self.bar == null) return UIA_E_ELEMENTNOTAVAILABLE;
            switch (property) {
                UIA_ControlTypePropertyId => setInt(out, UIA_TabControlTypeId),
                UIA_NamePropertyId => setString(out, "Tabs"),
                else => {},
            }
            return S_OK;
        }
    }.f,
    .get_HostRawElementProvider = struct {
        fn f(i: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const self = fromIface("simple", i);
            out.* = null;
            const bar = self.bar orelse return UIA_E_ELEMENTNOTAVAILABLE;
            return UiaHostProviderFromHwnd(bar.hwnd, out);
        }
    }.f,
};

// IRawElementProviderFragment

const root_fragment_vtbl = FragmentVtbl{
    .QueryInterface = struct {
        fn f(i: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return fromIface("fragment", i).queryInterface(iid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return fromIface("fragment", i).addRef();
        }
    }.f,
    .Release = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return fromIface("fragment", i).release();
        }
    }.f,
    .Navigate = struct {
        fn f(i: *Interface, direction: i32, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const self = fromIface("fragment", i);
            out.* = null;
            const bar = self.bar orelse return UIA_E_ELEMENTNOTAVAILABLE;
            _ = bar;
            const n = self.childCount();
            const item = switch (direction) {
                NavigateDirection_FirstChild => self.childAt(0),
                NavigateDirection_LastChild => if (n > 0) self.childAt(n - 1) else null,
                // The host window provides our parent and siblings.
                else => null,
            };
            if (item) |v| out.* = &v.fragment;
            return S_OK;
        }
    }.f,
    .GetRuntimeId = struct {
        fn f(_: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
            // The host window provides a root's runtime ID.
            out.* = null;
            return S_OK;
        }
    }.f,
    .get_BoundingRectangle = struct {
        fn f(i: *Interface, out: *UiaRect) callconv(.winapi) HRESULT {
            const self = fromIface("fragment", i);
            out.* = .{};
            const bar = self.bar orelse return UIA_E_ELEMENTNOTAVAILABLE;
            var rect: c.RECT = undefined;
            if (c.GetWindowRect(bar.hwnd, &rect) != 0) out.* = .fromRect(rect);
            return S_OK;
        }
    }.f,
    .GetEmbeddedFragmentRoots = noEmbeddedRoots,
    .SetFocus = noFocus,
    .get_FragmentRoot = struct {
        fn f(i: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const self = fromIface("fragment", i);
            out.* = &self.fragment_root;
            _ = self.addRef();
            return S_OK;
        }
    }.f,
};

// IRawElementProviderFragmentRoot

const root_fragment_root_vtbl = FragmentRootVtbl{
    .QueryInterface = struct {
        fn f(i: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return fromIface("fragment_root", i).queryInterface(iid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return fromIface("fragment_root", i).addRef();
        }
    }.f,
    .Release = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return fromIface("fragment_root", i).release();
        }
    }.f,
    .ElementProviderFromPoint = struct {
        fn f(i: *Interface, x: f64, y: f64, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const self = fromIface("fragment_root", i);
            out.* = null;
            const bar = self.bar orelse return UIA_E_ELEMENTNOTAVAILABLE;
            const pt: c.POINT = .{ .x = @intFromFloat(x), .y = @intFromFloat(y) };
            const kind: ?Item.Kind = if (bar.hitAtScreen(pt)) |hit| switch (hit) {
                .tab, .close => |idx| .{ .tab = bar.window.tabs.items[idx] },
                .new_tab => .{ .button = .new_tab },
                .shell_menu => .{ .button = .shell_menu },
                .main_menu => .{ .button = .main_menu },
            } else null;
            if (kind) |k| if (Item.create(self, k)) |item| {
                out.* = &item.fragment;
                return S_OK;
            } else |_| {};
            out.* = &self.fragment;
            _ = self.addRef();
            return S_OK;
        }
    }.f,
    .GetFocus = struct {
        fn f(_: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
            // Focus is in the terminal, not the tabs.
            out.* = null;
            return S_OK;
        }
    }.f,
};

// ISelectionProvider

const root_selection_vtbl = SelectionVtbl{
    .QueryInterface = struct {
        fn f(i: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return fromIface("selection", i).queryInterface(iid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return fromIface("selection", i).addRef();
        }
    }.f,
    .Release = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return fromIface("selection", i).release();
        }
    }.f,
    .GetSelection = struct {
        fn f(i: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const self = fromIface("selection", i);
            out.* = null;
            const bar = self.bar orelse return UIA_E_ELEMENTNOTAVAILABLE;
            // The tabs come first, so a tab's position is its index.
            const item = self.childAt(bar.window.active) orelse return S_OK;
            defer _ = item.release();
            const array = SafeArrayCreateVector(VT_UNKNOWN, 0, 1) orelse return E_OUTOFMEMORY;
            const index: i32 = 0;
            // The array takes its own reference.
            _ = SafeArrayPutElement(array, &index, &item.simple);
            out.* = array;
            return S_OK;
        }
    }.f,
    .get_CanSelectMultiple = falseProperty,
    .get_IsSelectionRequired = struct {
        fn f(_: *Interface, out: *c.BOOL) callconv(.winapi) HRESULT {
            out.* = c.TRUE;
            return S_OK;
        }
    }.f,
};

/// A tab, as a TabItem element, or a button. A tab may have closed since,
/// so it's looked up in the window each time.
const Item = struct {
    simple: Interface = .{ .vtbl = &item_simple_vtbl },
    fragment: Interface = .{ .vtbl = &item_fragment_vtbl },
    selection_item: Interface = .{ .vtbl = &item_selection_vtbl },
    invoke: Interface = .{ .vtbl = &item_invoke_vtbl },
    refs: std.atomic.Value(u32) = .init(1),
    root: *Root,
    kind: Kind,

    const Kind = union(enum) {
        tab: *Tab,
        button: TabBar.Button,
    };

    fn create(root: *Root, kind: Kind) !*Item {
        const self = try root.alloc.create(Item);
        _ = root.addRef();
        self.* = .{ .root = root, .kind = kind };
        return self;
    }

    fn addRef(self: *Item) u32 {
        return self.refs.fetchAdd(1, .acq_rel) + 1;
    }

    fn release(self: *Item) u32 {
        const refs = self.refs.fetchSub(1, .acq_rel) - 1;
        if (refs == 0) {
            const root = self.root;
            root.alloc.destroy(self);
            _ = root.release();
        }
        return refs;
    }

    fn queryInterface(self: *Item, iid: *const GUID, out: *?*anyopaque) HRESULT {
        out.* = if (eqlGuid(iid, &IID_IUnknown) or eqlGuid(iid, &IID_IRawElementProviderSimple))
            &self.simple
        else if (eqlGuid(iid, &IID_IRawElementProviderFragment))
            &self.fragment
        else if (self.kind == .tab and eqlGuid(iid, &IID_ISelectionItemProvider))
            &self.selection_item
        else if (self.kind == .button and eqlGuid(iid, &IID_IInvokeProvider))
            &self.invoke
        else
            return E_NOINTERFACE;
        _ = self.addRef();
        return S_OK;
    }

    /// The position among the tab bar's children, if the element and the
    /// tab bar still exist.
    fn position(self: *const Item) ?usize {
        const bar = self.root.bar orelse return null;
        return switch (self.kind) {
            .tab => |tab| bar.window.tabIndex(tab),
            .button => |button| bar.window.tabs.items.len + @backingInt(button),
        };
    }

    /// The tab's index, for a tab that still exists.
    fn tabIndex(self: *const Item) ?usize {
        return switch (self.kind) {
            .tab => self.position(),
            .button => null,
        };
    }

    fn fromIface(comptime field: []const u8, iface: *Interface) *Item {
        return @alignCast(@fieldParentPtr(field, iface));
    }
};

const item_simple_vtbl = SimpleVtbl{
    .QueryInterface = struct {
        fn f(i: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return Item.fromIface("simple", i).queryInterface(iid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return Item.fromIface("simple", i).addRef();
        }
    }.f,
    .Release = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return Item.fromIface("simple", i).release();
        }
    }.f,
    .get_ProviderOptions = providerOptions,
    .GetPatternProvider = struct {
        fn f(i: *Interface, pattern: i32, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const self = Item.fromIface("simple", i);
            out.* = null;
            if (self.kind == .tab and pattern == UIA_SelectionItemPatternId) {
                out.* = &self.selection_item;
                _ = self.addRef();
            } else if (self.kind == .button and pattern == UIA_InvokePatternId) {
                out.* = &self.invoke;
                _ = self.addRef();
            }
            return S_OK;
        }
    }.f,
    .GetPropertyValue = struct {
        fn f(i: *Interface, property: i32, out: *VARIANT) callconv(.winapi) HRESULT {
            const self = Item.fromIface("simple", i);
            out.* = .{};
            _ = self.position() orelse return UIA_E_ELEMENTNOTAVAILABLE;
            const bar = self.root.bar orelse return UIA_E_ELEMENTNOTAVAILABLE;
            switch (property) {
                UIA_ControlTypePropertyId => setInt(out, switch (self.kind) {
                    .tab => UIA_TabItemControlTypeId,
                    .button => UIA_ButtonControlTypeId,
                }),
                UIA_NamePropertyId => setString(out, switch (self.kind) {
                    .tab => |tab| tab.title(),
                    .button => |button| bar.buttonName(button),
                }),
                else => {},
            }
            return S_OK;
        }
    }.f,
    .get_HostRawElementProvider = struct {
        fn f(_: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
            out.* = null;
            return S_OK;
        }
    }.f,
};

const item_fragment_vtbl = FragmentVtbl{
    .QueryInterface = struct {
        fn f(i: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return Item.fromIface("fragment", i).queryInterface(iid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return Item.fromIface("fragment", i).addRef();
        }
    }.f,
    .Release = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return Item.fromIface("fragment", i).release();
        }
    }.f,
    .Navigate = struct {
        fn f(i: *Interface, direction: i32, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const self = Item.fromIface("fragment", i);
            out.* = null;
            const pos = self.position() orelse return UIA_E_ELEMENTNOTAVAILABLE;
            switch (direction) {
                NavigateDirection_Parent => {
                    out.* = &self.root.fragment;
                    _ = self.root.addRef();
                },
                NavigateDirection_NextSibling => if (self.root.childAt(pos + 1)) |v| {
                    out.* = &v.fragment;
                },
                NavigateDirection_PreviousSibling => if (pos > 0) {
                    if (self.root.childAt(pos - 1)) |v| out.* = &v.fragment;
                },
                else => {},
            }
            return S_OK;
        }
    }.f,
    .GetRuntimeId = struct {
        fn f(i: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const self = Item.fromIface("fragment", i);
            out.* = null;
            // UiaAppendRuntimeId, then an ID that's unique among the
            // children: a tab's address, or a small number for a button.
            const id: i32 = switch (self.kind) {
                .tab => |tab| @truncate(@as(isize, @bitCast(@intFromPtr(tab)))),
                .button => |button| 1 + @as(i32, @backingInt(button)),
            };
            const ids = [_]i32{ UiaAppendRuntimeId, id };
            const array = SafeArrayCreateVector(VT_I4, 0, ids.len) orelse return E_OUTOFMEMORY;
            for (ids, 0..) |value, n| {
                const at: i32 = @intCast(n);
                _ = SafeArrayPutElement(array, &at, &value);
            }
            out.* = array;
            return S_OK;
        }
    }.f,
    .get_BoundingRectangle = struct {
        fn f(i: *Interface, out: *UiaRect) callconv(.winapi) HRESULT {
            const self = Item.fromIface("fragment", i);
            out.* = .{};
            const pos = self.position() orelse return UIA_E_ELEMENTNOTAVAILABLE;
            const bar = self.root.bar orelse return UIA_E_ELEMENTNOTAVAILABLE;
            out.* = .fromRect(switch (self.kind) {
                .tab => bar.tabScreenRect(pos),
                .button => |button| bar.buttonScreenRect(button),
            });
            return S_OK;
        }
    }.f,
    .GetEmbeddedFragmentRoots = noEmbeddedRoots,
    .SetFocus = noFocus,
    .get_FragmentRoot = struct {
        fn f(i: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const self = Item.fromIface("fragment", i);
            out.* = &self.root.fragment_root;
            _ = self.root.addRef();
            return S_OK;
        }
    }.f,
};

const item_selection_vtbl = SelectionItemVtbl{
    .QueryInterface = struct {
        fn f(i: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return Item.fromIface("selection_item", i).queryInterface(iid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return Item.fromIface("selection_item", i).addRef();
        }
    }.f,
    .Release = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return Item.fromIface("selection_item", i).release();
        }
    }.f,
    .Select = selectItem,
    .AddToSelection = selectItem,
    .RemoveFromSelection = struct {
        fn f(_: *Interface) callconv(.winapi) HRESULT {
            // One tab is always selected.
            return UIA_E_INVALIDOPERATION;
        }
    }.f,
    .get_IsSelected = struct {
        fn f(i: *Interface, out: *c.BOOL) callconv(.winapi) HRESULT {
            const self = Item.fromIface("selection_item", i);
            out.* = c.FALSE;
            const idx = self.tabIndex() orelse return UIA_E_ELEMENTNOTAVAILABLE;
            const bar = self.root.bar orelse return UIA_E_ELEMENTNOTAVAILABLE;
            out.* = @intFromBool(idx == bar.window.active);
            return S_OK;
        }
    }.f,
    .get_SelectionContainer = struct {
        fn f(i: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
            const self = Item.fromIface("selection_item", i);
            out.* = &self.root.simple;
            _ = self.root.addRef();
            return S_OK;
        }
    }.f,
};

const item_invoke_vtbl = InvokeVtbl{
    .QueryInterface = struct {
        fn f(i: *Interface, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return Item.fromIface("invoke", i).queryInterface(iid, out);
        }
    }.f,
    .AddRef = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return Item.fromIface("invoke", i).addRef();
        }
    }.f,
    .Release = struct {
        fn f(i: *Interface) callconv(.winapi) u32 {
            return Item.fromIface("invoke", i).release();
        }
    }.f,
    .Invoke = struct {
        fn f(i: *Interface) callconv(.winapi) HRESULT {
            const self = Item.fromIface("invoke", i);
            const bar = self.root.bar orelse return UIA_E_ELEMENTNOTAVAILABLE;
            switch (self.kind) {
                .button => |button| bar.pressButton(button),
                .tab => return UIA_E_INVALIDOPERATION,
            }
            return S_OK;
        }
    }.f,
};

fn selectItem(i: *Interface) callconv(.winapi) HRESULT {
    const self = Item.fromIface("selection_item", i);
    const idx = self.tabIndex() orelse return UIA_E_ELEMENTNOTAVAILABLE;
    const bar = self.root.bar orelse return UIA_E_ELEMENTNOTAVAILABLE;
    bar.window.selectTab(idx);
    return S_OK;
}

fn providerOptions(_: *Interface, out: *i32) callconv(.winapi) HRESULT {
    out.* = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading;
    return S_OK;
}

fn noEmbeddedRoots(_: *Interface, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    return S_OK;
}

fn noFocus(_: *Interface) callconv(.winapi) HRESULT {
    return S_OK;
}

fn falseProperty(_: *Interface, out: *c.BOOL) callconv(.winapi) HRESULT {
    out.* = c.FALSE;
    return S_OK;
}

fn setInt(out: *VARIANT, value: i32) void {
    out.vt = VT_I4;
    out.value = .{ .int = value };
}

fn setString(out: *VARIANT, utf8: []const u8) void {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, utf8[0..@min(utf8.len, buf.len)]) catch return;
    out.vt = VT_BSTR;
    out.value = .{ .bstr = SysAllocStringLen(&buf, @intCast(n)) };
}

fn eqlGuid(a: *const GUID, b: *const GUID) bool {
    return std.meta.eql(a.*, b.*);
}

//---------------------------------------------------------------------------
// COM and UI Automation declarations

const Interface = extern struct { vtbl: *const anyopaque };

const HRESULT = c.HRESULT;
const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000e));
const UIA_E_ELEMENTNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x80040201));
const UIA_E_INVALIDOPERATION: HRESULT = @bitCast(@as(u32, 0x80131509));

const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const IID_IUnknown: GUID = .{ .a = 0, .b = 0, .c = 0, .d = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IRawElementProviderSimple: GUID = .{ .a = 0xd6dd68d1, .b = 0x86fd, .c = 0x4332, .d = .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c } };
const IID_IRawElementProviderFragment: GUID = .{ .a = 0xf7063da8, .b = 0x8359, .c = 0x439c, .d = .{ 0x92, 0x97, 0xbb, 0xc5, 0x29, 0x9a, 0x7d, 0x87 } };
const IID_IRawElementProviderFragmentRoot: GUID = .{ .a = 0x620ce2a5, .b = 0xab8f, .c = 0x40a9, .d = .{ 0x86, 0xcb, 0xde, 0x3c, 0x75, 0x59, 0x9b, 0x58 } };
const IID_ISelectionProvider: GUID = .{ .a = 0xfb8b03af, .b = 0x3bdf, .c = 0x48d4, .d = .{ 0xbd, 0x36, 0x1a, 0x65, 0x79, 0x3b, 0xe1, 0x68 } };
const IID_IInvokeProvider: GUID = .{ .a = 0x54fcb24b, .b = 0xe18e, .c = 0x47a2, .d = .{ 0xb4, 0xd3, 0xec, 0xcb, 0xe7, 0x75, 0x99, 0xa2 } };
const IID_ISelectionItemProvider: GUID = .{ .a = 0x2acad808, .b = 0xb2d4, .c = 0x452d, .d = .{ 0xa4, 0x07, 0x91, 0xff, 0x1a, 0xd1, 0x67, 0xb2 } };

const VARIANT = extern struct {
    vt: u16 = 0,
    reserved: [3]u16 = .{ 0, 0, 0 },
    value: extern union {
        int: i32,
        bstr: ?[*:0]u16,
        padding: [2]u64,
    } = .{ .padding = .{ 0, 0 } },
};
const VT_I4 = 3;
const VT_BSTR = 8;
const VT_UNKNOWN = 13;

const UiaRect = extern struct {
    left: f64 = 0,
    top: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,

    fn fromRect(r: c.RECT) UiaRect {
        return .{
            .left = @floatFromInt(r.left),
            .top = @floatFromInt(r.top),
            .width = @floatFromInt(r.right - r.left),
            .height = @floatFromInt(r.bottom - r.top),
        };
    }
};

const ProviderOptions_ServerSideProvider = 0x1;
const ProviderOptions_UseComThreading = 0x20;
const UiaAppendRuntimeId = 3;
const UIA_InvokePatternId = 10000;
const UIA_SelectionPatternId = 10001;
const UIA_SelectionItemPatternId = 10010;
const UIA_ControlTypePropertyId = 30003;
const UIA_NamePropertyId = 30005;
const UIA_TabControlTypeId = 50018;
const UIA_TabItemControlTypeId = 50019;
const UIA_ButtonControlTypeId = 50000;
const UIA_SelectionItem_ElementSelectedEventId = 20012;
const NavigateDirection_Parent = 0;
const NavigateDirection_NextSibling = 1;
const NavigateDirection_PreviousSibling = 2;
const NavigateDirection_FirstChild = 3;
const NavigateDirection_LastChild = 4;

const QueryInterfaceFn = *const fn (*Interface, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
const RefFn = *const fn (*Interface) callconv(.winapi) u32;
const OutFn = *const fn (*Interface, *?*anyopaque) callconv(.winapi) HRESULT;
const BoolFn = *const fn (*Interface, *c.BOOL) callconv(.winapi) HRESULT;
const VoidFn = *const fn (*Interface) callconv(.winapi) HRESULT;

const SimpleVtbl = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: RefFn,
    Release: RefFn,
    get_ProviderOptions: *const fn (*Interface, *i32) callconv(.winapi) HRESULT,
    GetPatternProvider: *const fn (*Interface, i32, *?*anyopaque) callconv(.winapi) HRESULT,
    GetPropertyValue: *const fn (*Interface, i32, *VARIANT) callconv(.winapi) HRESULT,
    get_HostRawElementProvider: OutFn,
};

const FragmentVtbl = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: RefFn,
    Release: RefFn,
    Navigate: *const fn (*Interface, i32, *?*anyopaque) callconv(.winapi) HRESULT,
    GetRuntimeId: OutFn,
    get_BoundingRectangle: *const fn (*Interface, *UiaRect) callconv(.winapi) HRESULT,
    GetEmbeddedFragmentRoots: OutFn,
    SetFocus: VoidFn,
    get_FragmentRoot: OutFn,
};

const FragmentRootVtbl = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: RefFn,
    Release: RefFn,
    ElementProviderFromPoint: *const fn (*Interface, f64, f64, *?*anyopaque) callconv(.winapi) HRESULT,
    GetFocus: OutFn,
};

const SelectionVtbl = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: RefFn,
    Release: RefFn,
    GetSelection: OutFn,
    get_CanSelectMultiple: BoolFn,
    get_IsSelectionRequired: BoolFn,
};

const InvokeVtbl = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: RefFn,
    Release: RefFn,
    Invoke: VoidFn,
};

const SelectionItemVtbl = extern struct {
    QueryInterface: QueryInterfaceFn,
    AddRef: RefFn,
    Release: RefFn,
    Select: VoidFn,
    AddToSelection: VoidFn,
    RemoveFromSelection: VoidFn,
    get_IsSelected: BoolFn,
    get_SelectionContainer: OutFn,
};

extern "uiautomationcore" fn UiaReturnRawElementProvider(hwnd: c.HWND, wparam: c.WPARAM, lparam: c.LPARAM, provider: *Interface) callconv(.winapi) c.LRESULT;
extern "uiautomationcore" fn UiaHostProviderFromHwnd(hwnd: c.HWND, provider: *?*anyopaque) callconv(.winapi) HRESULT;
extern "uiautomationcore" fn UiaDisconnectProvider(provider: *Interface) callconv(.winapi) HRESULT;
extern "uiautomationcore" fn UiaClientsAreListening() callconv(.winapi) c.BOOL;
extern "uiautomationcore" fn UiaRaiseAutomationEvent(provider: *Interface, id: i32) callconv(.winapi) HRESULT;
extern "oleaut32" fn SysAllocStringLen(s: ?[*]const u16, len: u32) callconv(.winapi) ?[*:0]u16;
extern "oleaut32" fn SafeArrayCreateVector(vt: u16, lower: i32, count: u32) callconv(.winapi) ?*anyopaque;
extern "oleaut32" fn SafeArrayPutElement(array: *anyopaque, index: *const i32, value: *const anyopaque) callconv(.winapi) HRESULT;
