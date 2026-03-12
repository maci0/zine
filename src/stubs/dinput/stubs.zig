const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../../calling_convention.zig");

// --- COM VTables ---

pub const IDirectInput = extern struct {
    lpVtbl: *const IDirectInputVtbl,
};

pub const IDirectInputVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32,
    AddRef: usize,
    Release: *const fn (*IDirectInput) callconv(w32cc.WINAPI) u32,
    CreateDevice: *const fn (*IDirectInput, usize, *?*IDirectInputDevice, usize) callconv(w32cc.WINAPI) i32,
    EnumDevices: *const fn (*IDirectInput, u32, usize, usize, u32) callconv(w32cc.WINAPI) i32,
    GetDeviceStatus: usize,
    RunControlPanel: usize,
    Initialize: usize,
};

pub const IDirectInputDevice = extern struct {
    lpVtbl: *const IDirectInputDeviceVtbl,
};

// IDirectInputDevice8 vtable — extended from IDirectInputDevice with extra methods
pub const IDirectInputDeviceVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32,
    AddRef: usize,
    Release: *const fn (*IDirectInputDevice) callconv(w32cc.WINAPI) u32,
    GetCapabilities: usize,
    EnumObjects: usize,
    GetProperty: usize,
    SetProperty: *const fn (*IDirectInputDevice, usize, usize) callconv(w32cc.WINAPI) i32,
    Acquire: *const fn (*IDirectInputDevice) callconv(w32cc.WINAPI) i32,
    Unacquire: usize,
    GetDeviceState: *const fn (*IDirectInputDevice, u32, usize) callconv(w32cc.WINAPI) i32,
    GetDeviceData: usize,
    SetDataFormat: *const fn (*IDirectInputDevice, usize) callconv(w32cc.WINAPI) i32,
    SetEventNotification: usize,
    SetCooperativeLevel: *const fn (*IDirectInputDevice, usize, u32) callconv(w32cc.WINAPI) i32,
    GetObjectInfo: usize,
    GetDeviceInfo: usize,
    RunControlPanel: usize,
    Initialize: usize,
    // IDirectInputDevice2 extensions
    CreateEffect: usize,
    EnumEffects: usize,
    GetEffectInfo: usize,
    GetForceFeedbackState: usize,
    SendForceFeedbackCommand: usize,
    EnumCreatedEffectObjects: usize,
    Escape: usize,
    Poll: usize,
    SendDeviceData: usize,
    // IDirectInputDevice7 extensions
    EnumEffectsInFile: usize,
    WriteEffectToFile: usize,
    // IDirectInputDevice8 extensions
    BuildActionMap: usize,
    SetActionMap: usize,
    GetImageInfo: usize,
};

pub var global_dinput: IDirectInput = undefined;
pub var global_dinput_device: IDirectInputDevice = undefined;

// --- IDirectInputDevice Implementation ---

pub fn dinput_QueryInterface(this: *anyopaque, riid: usize, ppvObj: *?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = riid;
    if (trace.enable_tracing) trace.print("DINPUT: QueryInterface\n", .{});
    ppvObj.* = this;
    return 0; // S_OK
}

pub fn device_Release(this: *IDirectInputDevice) callconv(w32cc.WINAPI) u32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::Release\n", .{});
    return 0;
}

pub fn device_Acquire(this: *IDirectInputDevice) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::Acquire\n", .{});
    return 0; // DI_OK
}

pub fn device_SetDataFormat(this: *IDirectInputDevice, lpFormat: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = lpFormat;
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::SetDataFormat\n", .{});
    return 0; // DI_OK
}

pub fn device_SetCooperativeLevel(this: *IDirectInputDevice, hwnd: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = hwnd; _ = dwFlags;
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::SetCooperativeLevel\n", .{});
    return 0; // DI_OK
}

pub fn device_SetProperty(this: *IDirectInputDevice, rguidProp: usize, pdiph: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = rguidProp; _ = pdiph;
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::SetProperty\n", .{});
    return 0; // DI_OK
}

pub fn device_GetDeviceState(this: *IDirectInputDevice, cbData: u32, lpvData: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::GetDeviceState({d})\n", .{cbData});
    
    if (cbData > 0 and lpvData != 0) {
        const buf = @as([*]u8, @ptrFromInt(lpvData));
        const renderer = @import("../../gui/renderer.zig");
        const copy_len = @min(cbData, @as(u32, 256));
        @memcpy(buf[0..copy_len], renderer.keyboard_state[0..copy_len]);
        if (copy_len < cbData) {
            @memset(buf[copy_len..cbData], 0);
        }
    }
    return 0; // DI_OK
}

pub fn device_noop1(a: usize) callconv(w32cc.WINAPI) usize { _ = a; return 0; }
pub fn device_noop2(a: usize, b: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; return 0; }
pub fn device_noop3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; return 0; }
pub fn device_noop4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; _ = d; return 0; }
pub fn device_noop5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; _ = d; _ = e; return 0; }
pub fn device_noop6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; _ = d; _ = e; _ = f; return 0; }

pub var device_vtbl: IDirectInputDeviceVtbl = undefined;
pub var dinput_vtbl: IDirectInputVtbl = undefined;

pub fn initVtables() void {
    const n1 = @intFromPtr(&device_noop1);
    const n2 = @intFromPtr(&device_noop2);
    const n3 = @intFromPtr(&device_noop3);
    const n4 = @intFromPtr(&device_noop4);
    const n5 = @intFromPtr(&device_noop5);
    const n6 = @intFromPtr(&device_noop6);

    device_vtbl = .{
        .QueryInterface = @ptrCast(&dinput_QueryInterface),
        .AddRef = n1,
        .Release = device_Release,
        .GetCapabilities = n2,
        .EnumObjects = n5,
        .GetProperty = n3,
        .SetProperty = @ptrCast(&device_SetProperty),
        .Acquire = device_Acquire,
        .Unacquire = n1,
        .GetDeviceState = device_GetDeviceState,
        .GetDeviceData = n5,
        .SetDataFormat = device_SetDataFormat,
        .SetEventNotification = n2,
        .SetCooperativeLevel = device_SetCooperativeLevel,
        .GetObjectInfo = n4,
        .GetDeviceInfo = n2,
        .RunControlPanel = n3,
        .Initialize = n4,
        .CreateEffect = n6,
        .EnumEffects = n4,
        .GetEffectInfo = n3,
        .GetForceFeedbackState = n2,
        .SendForceFeedbackCommand = n2,
        .EnumCreatedEffectObjects = n4,
        .Escape = n2,
        .Poll = n1,
        .SendDeviceData = n5,
        .EnumEffectsInFile = n5,
        .WriteEffectToFile = n5,
        .BuildActionMap = n4,
        .SetActionMap = n4,
        .GetImageInfo = n2,
    };

    dinput_vtbl = .{
        .QueryInterface = @ptrCast(&dinput_QueryInterface),
        .AddRef = n1,
        .Release = dinput_Release,
        .CreateDevice = dinput_CreateDevice,
        .EnumDevices = dinput_EnumDevices,
        .GetDeviceStatus = n2,
        .RunControlPanel = n3,
        .Initialize = n4,
    };

    global_dinput.lpVtbl = &dinput_vtbl;
    global_dinput_device.lpVtbl = &device_vtbl;
}

pub fn dinput_EnumDevices(this: *IDirectInput, dwDevType: u32, lpCallback: usize, pvRef: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = dwDevType; _ = dwFlags;
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInput::EnumDevices\n", .{});
    if (lpCallback != 0) {
        var inst: [300]u8 = undefined;
        @memset(&inst, 0);
        @as(*u32, @ptrCast(@alignCast(&inst[0]))).* = 260; // dwSize = sizeof(DIDEVICEINSTANCEA)
        const cb = @as(*const fn (usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(lpCallback));
        _ = cb(@intFromPtr(&inst), pvRef);
    }
    return 0; // DI_OK
}

pub fn dinput_CreateDevice(this: *IDirectInput, rguid: usize, lplpDirectInputDevice: *?*IDirectInputDevice, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = rguid; _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInput::CreateDevice\n", .{});
    lplpDirectInputDevice.* = &global_dinput_device;
    return 0; // DI_OK
}

pub fn dinput_Release(this: *IDirectInput) callconv(w32cc.WINAPI) u32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInput::Release\n", .{});
    return 0; // Reference count
}


pub fn stub_DirectInputCreateA(hinst: usize, dwVersion: u32, ppDI: *?*IDirectInput, punkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = hinst; _ = dwVersion; _ = punkOuter;
    if (trace.enable_tracing) trace.print("DINPUT: DirectInputCreateA\n", .{});
    ppDI.* = &global_dinput;
    return 0; // DI_OK
}

pub fn stub_DirectInput8Create(hinst: usize, dwVersion: u32, riidltf: usize, ppvOut: *?*IDirectInput, punkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = hinst; _ = dwVersion; _ = riidltf; _ = punkOuter;
    if (trace.enable_tracing) trace.print("DINPUT8: DirectInput8Create\n", .{});
    ppvOut.* = &global_dinput;
    return 0; // DI_OK
}
