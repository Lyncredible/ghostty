//! Windows taskbar progress for top-level windows.
const Taskbar = @This();

const std = @import("std");
const c = @import("util.zig").c;
const log = std.log.scoped(.win32);

list: ?*c.ITaskbarList3 = null,
com_initialized: bool = false,

pub fn init() Taskbar {
    var self: Taskbar = .{};
    const hr = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    self.com_initialized = hr >= 0;
    if (hr < 0 and hr != c.RPC_E_CHANGED_MODE) {
        log.warn("taskbar COM initialization failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return self;
    }

    var list: ?*c.ITaskbarList3 = null;
    const create_hr = c.CoCreateInstance(
        &c.CLSID_TaskbarList,
        null,
        c.CLSCTX_INPROC_SERVER,
        &c.IID_ITaskbarList3,
        @ptrCast(&list),
    );
    if (create_hr >= 0 and list != null) {
        if (list.?.lpVtbl.*.HrInit.?(list) >= 0) {
            self.list = list;
        } else {
            log.warn("taskbar HrInit failed", .{});
            _ = list.?.lpVtbl.*.Release.?(list);
        }
    } else {
        log.warn("taskbar CoCreateInstance failed hr=0x{x}", .{@as(u32, @bitCast(create_hr))});
    }
    return self;
}

pub fn deinit(self: *Taskbar) void {
    if (self.list) |list| _ = list.lpVtbl.*.Release.?(list);
    if (self.com_initialized) c.CoUninitialize();
}

pub fn clear(self: *Taskbar, hwnd: c.HWND) void {
    self.setState(hwnd, c.TBPF_NOPROGRESS);
}

pub fn setState(self: *Taskbar, hwnd: c.HWND, state: c.TBPFLAG) void {
    if (self.list) |list| {
        const hr = list.lpVtbl.*.SetProgressState.?(list, hwnd, state);
        if (hr < 0) log.warn("taskbar SetProgressState failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
    }
}

pub fn setValue(self: *Taskbar, hwnd: c.HWND, value: u8) void {
    if (self.list) |list| {
        const hr = list.lpVtbl.*.SetProgressValue.?(list, hwnd, value, 100);
        if (hr < 0) log.warn("taskbar SetProgressValue failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
    }
}
