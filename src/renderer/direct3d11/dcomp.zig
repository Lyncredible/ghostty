//! Minimal DirectComposition bindings. dcomp.h only declares C++ interfaces,
//! so we declare the vtables ourselves, up to the methods we use. The slot
//! order follows dcomp.h; overloaded methods take two slots each.
const std = @import("std");
const com = @import("com.zig");
const c = com.c;

pub const IID_IDCompositionDevice: c.GUID = .{
    .Data1 = 0xc37ea93a,
    .Data2 = 0xe7aa,
    .Data3 = 0x450d,
    .Data4 = .{ 0xb1, 0x6f, 0x97, 0x46, 0xcb, 0x04, 0x07, 0xf3 },
};

pub extern "dcomp" fn DCompositionCreateDevice(
    dxgi_device: ?*c.IDXGIDevice,
    iid: *const c.GUID,
    device: *?*anyopaque,
) callconv(.winapi) c.HRESULT;

const Unknown = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(.winapi) c.ULONG,
};

pub const Device = extern struct {
    lpVtbl: *const Vtbl,

    const Vtbl = extern struct {
        unknown: Unknown,
        Commit: *const fn (*Device) callconv(.winapi) c.HRESULT,
        WaitForCommitCompletion: *const anyopaque,
        GetFrameStatistics: *const anyopaque,
        CreateTargetForHwnd: *const fn (*Device, c.HWND, c.BOOL, *?*Target) callconv(.winapi) c.HRESULT,
        CreateVisual: *const fn (*Device, *?*Visual) callconv(.winapi) c.HRESULT,
    };

    pub fn commit(self: *Device) c.HRESULT {
        return self.lpVtbl.Commit(self);
    }

    pub fn createTargetForHwnd(self: *Device, hwnd: c.HWND, topmost: bool, out: *?*Target) c.HRESULT {
        return self.lpVtbl.CreateTargetForHwnd(self, hwnd, if (topmost) c.TRUE else c.FALSE, out);
    }

    pub fn createVisual(self: *Device, out: *?*Visual) c.HRESULT {
        return self.lpVtbl.CreateVisual(self, out);
    }

    pub fn release(self: *Device) void {
        _ = self.lpVtbl.unknown.Release(self);
    }
};

pub const Target = extern struct {
    lpVtbl: *const Vtbl,

    const Vtbl = extern struct {
        unknown: Unknown,
        SetRoot: *const fn (*Target, ?*Visual) callconv(.winapi) c.HRESULT,
    };

    pub fn setRoot(self: *Target, visual: ?*Visual) c.HRESULT {
        return self.lpVtbl.SetRoot(self, visual);
    }

    pub fn release(self: *Target) void {
        _ = self.lpVtbl.unknown.Release(self);
    }
};

pub const Visual = extern struct {
    lpVtbl: *const Vtbl,

    const Vtbl = extern struct {
        unknown: Unknown,
        SetOffsetX: [2]*const anyopaque,
        SetOffsetY: [2]*const anyopaque,
        SetTransform: [2]*const anyopaque,
        SetTransformParent: *const anyopaque,
        SetEffect: *const anyopaque,
        SetBitmapInterpolationMode: *const anyopaque,
        SetBorderMode: *const anyopaque,
        SetClip: [2]*const anyopaque,
        SetContent: *const fn (*Visual, ?*c.IUnknown) callconv(.winapi) c.HRESULT,
    };

    pub fn setContent(self: *Visual, content: ?*c.IUnknown) c.HRESULT {
        return self.lpVtbl.SetContent(self, content);
    }

    pub fn release(self: *Visual) void {
        _ = self.lpVtbl.unknown.Release(self);
    }
};

comptime {
    // SetContent is the 16th slot of IDCompositionVisual, and CreateVisual
    // the 8th slot of IDCompositionDevice.
    std.debug.assert(@offsetOf(Visual.Vtbl, "SetContent") == 15 * @sizeOf(usize));
    std.debug.assert(@offsetOf(Device.Vtbl, "CreateVisual") == 7 * @sizeOf(usize));
    std.debug.assert(@offsetOf(Target.Vtbl, "SetRoot") == 3 * @sizeOf(usize));
}
