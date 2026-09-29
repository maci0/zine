//! DirectInput implementation for keyboard and mouse.
const std = @import("std");
const env = @import("../loader/env.zig");
const runtime = @import("../runtime.zig");
const trace = @import("../trace.zig");
const w32cc = @import("calling_convention.zig");

// --- DirectInput GUID constants (Data1 field) ---
const GUID_SysMouse: u32 = 0x6F1D2B60;
const GUID_SysKeyboard: u32 = 0x6F1D2B61;

// --- COM VTables ---

/// IDirectInput interface.
pub const IDirectInput = extern struct {
    lpVtbl: *const IDirectInputVtbl,
};

/// IDirectInput vtable.
pub const IDirectInputVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32,
    AddRef: *const fn (*IDirectInput) callconv(w32cc.WINAPI) u32,
    Release: *const fn (*IDirectInput) callconv(w32cc.WINAPI) u32,
    CreateDevice: *const fn (*IDirectInput, usize, *?*IDirectInputDevice, usize) callconv(w32cc.WINAPI) i32,
    EnumDevices: *const fn (*IDirectInput, u32, usize, usize, u32) callconv(w32cc.WINAPI) i32,
    GetDeviceStatus: *const fn (*IDirectInput, usize) callconv(w32cc.WINAPI) i32,
    RunControlPanel: *const fn (*IDirectInput, usize, u32) callconv(w32cc.WINAPI) i32,
    Initialize: *const fn (*IDirectInput, usize, u32) callconv(w32cc.WINAPI) i32,
};

/// IDirectInputDevice interface.
pub const IDirectInputDevice = extern struct {
    lpVtbl: *const IDirectInputDeviceVtbl,
};

/// IDirectInputDevice vtable — matches real DirectX SDK layout exactly.
pub const IDirectInputDeviceVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32,
    AddRef: *const fn (*IDirectInputDevice) callconv(w32cc.WINAPI) u32,
    Release: *const fn (*IDirectInputDevice) callconv(w32cc.WINAPI) u32,
    // IDirectInputDevice
    GetCapabilities: *const fn (*IDirectInputDevice, usize) callconv(w32cc.WINAPI) i32,
    EnumObjects: *const fn (*IDirectInputDevice, usize, usize, u32) callconv(w32cc.WINAPI) i32,
    GetProperty: *const fn (*IDirectInputDevice, usize, usize) callconv(w32cc.WINAPI) i32,
    SetProperty: *const fn (*IDirectInputDevice, usize, usize) callconv(w32cc.WINAPI) i32,
    Acquire: *const fn (*IDirectInputDevice) callconv(w32cc.WINAPI) i32,
    Unacquire: *const fn (*IDirectInputDevice) callconv(w32cc.WINAPI) i32,
    GetDeviceState: *const fn (*IDirectInputDevice, u32, usize) callconv(w32cc.WINAPI) i32,
    GetDeviceData: *const fn (*IDirectInputDevice, u32, usize, *u32, u32) callconv(w32cc.WINAPI) i32,
    SetDataFormat: *const fn (*IDirectInputDevice, usize) callconv(w32cc.WINAPI) i32,
    SetEventNotification: *const fn (*IDirectInputDevice, usize) callconv(w32cc.WINAPI) i32,
    SetCooperativeLevel: *const fn (*IDirectInputDevice, usize, u32) callconv(w32cc.WINAPI) i32,
    GetObjectInfo: *const fn (*IDirectInputDevice, usize, u32, u32) callconv(w32cc.WINAPI) i32,
    GetDeviceInfo: *const fn (*IDirectInputDevice, usize) callconv(w32cc.WINAPI) i32,
    RunControlPanel: *const fn (*IDirectInputDevice, usize, u32) callconv(w32cc.WINAPI) i32,
    Initialize: *const fn (*IDirectInputDevice, usize, u32, usize) callconv(w32cc.WINAPI) i32,
    // IDirectInputDevice2
    CreateEffect: *const fn (*IDirectInputDevice, usize, usize, *?*anyopaque, usize) callconv(w32cc.WINAPI) i32,
    EnumEffects: *const fn (*IDirectInputDevice, usize, usize, u32) callconv(w32cc.WINAPI) i32,
    GetEffectInfo: *const fn (*IDirectInputDevice, usize, usize) callconv(w32cc.WINAPI) i32,
    GetForceFeedbackState: *const fn (*IDirectInputDevice, *u32) callconv(w32cc.WINAPI) i32,
    SendForceFeedbackCommand: *const fn (*IDirectInputDevice, u32) callconv(w32cc.WINAPI) i32,
    EnumCreatedEffectObjects: *const fn (*IDirectInputDevice, usize, usize, u32) callconv(w32cc.WINAPI) i32,
    Escape: *const fn (*IDirectInputDevice, usize) callconv(w32cc.WINAPI) i32,
    Poll: *const fn (*IDirectInputDevice) callconv(w32cc.WINAPI) i32,
    SendDeviceData: *const fn (*IDirectInputDevice, u32, usize, *u32, u32) callconv(w32cc.WINAPI) i32,
    // IDirectInputDevice7
    EnumEffectsInFile: *const fn (*IDirectInputDevice, usize, usize, usize, u32) callconv(w32cc.WINAPI) i32,
    WriteEffectToFile: *const fn (*IDirectInputDevice, usize, u32, usize, u32) callconv(w32cc.WINAPI) i32,
    // IDirectInputDevice8
    BuildActionMap: *const fn (*IDirectInputDevice, usize, usize, u32) callconv(w32cc.WINAPI) i32,
    SetActionMap: *const fn (*IDirectInputDevice, usize, usize, u32) callconv(w32cc.WINAPI) i32,
    GetImageInfo: *const fn (*IDirectInputDevice, usize) callconv(w32cc.WINAPI) i32,
};

/// DirectInput device object data.
pub const DIDEVICEOBJECTDATA = extern struct {
    /// Scancode offset or axis offset.
    dwOfs: u32,
    /// Key state (0x80=down, 0x00=up) or axis delta.
    dwData: u32,
    /// Timestamp in ms.
    dwTimeStamp: u32,
    /// Global sequence number.
    dwSequence: u32,
};

const EVENT_BUFFER_SIZE = 128;

/// Ring buffer for input events.
pub const EventRingBuffer = struct {
    events: [EVENT_BUFFER_SIZE]DIDEVICEOBJECTDATA = undefined,
    head: u32 = 0,
    tail: u32 = 0, // head == tail means empty
    /// Producers run on FLTK/web backend threads; the guest consumes via
    /// GetDeviceData. Producers even advance `tail` when dropping on full, so
    /// every operation must hold this lock.
    lock: runtime.Mutex = .{},

    /// Push an event onto the buffer.
    /// Implementation status: Partially implemented
    pub fn push(self: *EventRingBuffer, evt: DIDEVICEOBJECTDATA) void {
        self.lock.lock();
        defer self.lock.unlock();
        const next_head = (self.head + 1) % EVENT_BUFFER_SIZE;
        if (next_head == self.tail) {
            // Buffer full — drop oldest event
            self.tail = (self.tail + 1) % EVENT_BUFFER_SIZE;
        }
        self.events[self.head] = evt;
        self.head = next_head;
    }

    /// Return the number of events in the buffer.
    /// Implementation status: Partially implemented
    pub fn count(self: *EventRingBuffer) u32 {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.head >= self.tail) {
            return self.head - self.tail;
        } else {
            return EVENT_BUFFER_SIZE - self.tail + self.head;
        }
    }

    /// Drain events from the buffer.
    /// Implementation status: Partially implemented
    pub fn drain(self: *EventRingBuffer, out: [*]DIDEVICEOBJECTDATA, max_items: u32, peek: bool) u32 {
        self.lock.lock();
        defer self.lock.unlock();
        var n: u32 = 0;
        var pos = self.tail;
        while (pos != self.head and n < max_items) {
            out[n] = self.events[pos];
            pos = (pos + 1) % EVENT_BUFFER_SIZE;
            n += 1;
        }
        if (!peek) {
            self.tail = pos;
        }
        return n;
    }

    /// Flush the buffer.
    /// Implementation status: Partially implemented
    pub fn flush(self: *EventRingBuffer) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.tail = self.head;
    }
};

// Global sequence counter for event ordering
/// Monotonic event sequence shared by all producers (UI threads), so it must
/// be atomic.
var global_sequence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Global keyboard event buffer.
pub var keyboard_events: EventRingBuffer = .{};
/// Global mouse event buffer.
pub var mouse_events: EventRingBuffer = .{};

/// Push a keyboard event into the DirectInput buffer.
/// scancode: DirectInput scancode (DIK_xxx), e.g. DIK_ESCAPE=0x01
/// pressed: true for key down, false for key up
/// Implementation status: Partially implemented
pub fn pushKeyEvent(scancode: u8, pressed: bool) void {
    const seq = global_sequence.fetchAdd(1, .monotonic) + 1;
    keyboard_events.push(.{
        .dwOfs = scancode,
        .dwData = if (pressed) 0x80 else 0x00,
        .dwTimeStamp = getTickCount(),
        .dwSequence = seq,
    });
    if (trace.enable_tracing) trace.print("DINPUT: pushKeyEvent(scancode=0x{x}, pressed={})  buf_count={d}\n", .{ scancode, pressed, keyboard_events.count() });
}

/// Push a mouse event into the DirectInput buffer.
/// dwOfs: DIMOFS_X(0), DIMOFS_Y(4), DIMOFS_Z(8), DIMOFS_BUTTON0(12), etc.
/// dwData: axis delta or button state (0x80=down, 0x00=up)
/// Implementation status: Partially implemented
pub fn pushMouseEvent(dwOfs: u32, dwData: u32) void {
    const seq = global_sequence.fetchAdd(1, .monotonic) + 1;
    mouse_events.push(.{
        .dwOfs = dwOfs,
        .dwData = dwData,
        .dwTimeStamp = getTickCount(),
        .dwSequence = seq,
    });
}

fn getTickCount() u32 {
    // DirectInput timestamps use milliseconds (like GetTickCount): monotonic,
    // since consumers diff consecutive dwTimeStamp values.
    return @truncate(@as(u64, @bitCast(runtime.monoMilliTimestamp())));
}

/// Global IDirectInput instance.
pub var global_dinput: IDirectInput = undefined;

/// Global keyboard IDirectInputDevice instance.
pub var keyboard_device: IDirectInputDevice = undefined;
/// Global mouse IDirectInputDevice instance.
pub var mouse_device: IDirectInputDevice = undefined;

/// DirectInput device types.
pub const DeviceType = enum { unknown, keyboard, mouse };
/// Current keyboard device type.
pub var keyboard_device_type: DeviceType = .unknown;
/// Current mouse device type.
pub var mouse_device_type: DeviceType = .unknown;

fn getDeviceType(this: *IDirectInputDevice) DeviceType {
    if (this == &keyboard_device) return keyboard_device_type;
    if (this == &mouse_device) return mouse_device_type;
    return .unknown;
}

// ============================================================================
// IDirectInput Implementation
// ============================================================================

fn dinput_QueryInterface(this: *anyopaque, riid: usize, ppvObj: *?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = riid;
    if (trace.enable_tracing) trace.print("DINPUT: QueryInterface\n", .{});
    ppvObj.* = this;
    return 0; // S_OK
}

fn dinput_AddRef(_: *IDirectInput) callconv(w32cc.WINAPI) u32 {
    return 1;
}

fn dinput_Release(_: *IDirectInput) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInput::Release\n", .{});
    return 0;
}

fn dinput_CreateDevice(_: *IDirectInput, rguid: usize, lplpDirectInputDevice: *?*IDirectInputDevice, _: usize) callconv(w32cc.WINAPI) i32 {
    // Identify device by GUID.Data1
    var dev_type: DeviceType = .unknown;
    if (rguid != 0) {
        const guid_data1 = @as(*const u32, @ptrFromInt(rguid)).*;
        if (guid_data1 == GUID_SysMouse) {
            dev_type = .mouse;
        } else if (guid_data1 == GUID_SysKeyboard) {
            dev_type = .keyboard;
        }
    }

    switch (dev_type) {
        .mouse => {
            if (trace.enable_tracing) trace.print("DINPUT: IDirectInput::CreateDevice -> mouse (GUID_SysMouse)\n", .{});
            mouse_device_type = .mouse;
            lplpDirectInputDevice.* = &mouse_device;
        },
        .keyboard => {
            if (trace.enable_tracing) trace.print("DINPUT: IDirectInput::CreateDevice -> keyboard (GUID_SysKeyboard)\n", .{});
            keyboard_device_type = .keyboard;
            lplpDirectInputDevice.* = &keyboard_device;
        },
        .unknown => {
            // Unknown GUID — default to keyboard
            if (trace.enable_tracing) trace.print("DINPUT: IDirectInput::CreateDevice -> unknown GUID, defaulting keyboard\n", .{});
            lplpDirectInputDevice.* = &keyboard_device;
        },
    }
    return 0; // DI_OK
}

fn dinput_EnumDevices(_: *IDirectInput, _: u32, lpCallback: usize, pvRef: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInput::EnumDevices\n", .{});
    if (lpCallback != 0) {
        var inst: [300]u8 = undefined;
        @memset(&inst, 0);
        // Only the header fields exist, so dwSize is the modeled struct size, not sizeof(DIDEVICEINSTANCEA).
        @as(*u32, @ptrCast(@alignCast(&inst[0]))).* = 260;
        const cb = @as(*const fn (usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(lpCallback));
        _ = cb(@intFromPtr(&inst), pvRef);
    }
    return 0; // DI_OK
}

fn dinput_GetDeviceStatus(_: *IDirectInput, _: usize) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn dinput_RunControlPanel(_: *IDirectInput, _: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn dinput_Initialize(_: *IDirectInput, _: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

// ============================================================================
// IDirectInputDevice Implementation
// ============================================================================

fn device_QueryInterface(this: *anyopaque, _: usize, ppvObj: *?*anyopaque) callconv(w32cc.WINAPI) i32 {
    ppvObj.* = this;
    return 0; // S_OK
}

fn device_AddRef(_: *IDirectInputDevice) callconv(w32cc.WINAPI) u32 {
    return 1;
}

fn device_Release(_: *IDirectInputDevice) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::Release\n", .{});
    return 0;
}

fn device_GetCapabilities(this: *IDirectInputDevice, lpDIDevCaps: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpDIDevCaps;
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::GetCapabilities ({s})\n", .{@tagName(getDeviceType(this))});
    // Game should handle zero-filled caps gracefully
    return 0; // DI_OK
}

fn device_EnumObjects(_: *IDirectInputDevice, _: usize, _: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::EnumObjects\n", .{});
    return 0; // DI_OK
}

fn device_GetProperty(_: *IDirectInputDevice, _: usize, _: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::GetProperty\n", .{});
    return 0; // DI_OK
}

fn device_SetProperty(_: *IDirectInputDevice, _: usize, _: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::SetProperty\n", .{});
    return 0; // DI_OK
}

fn device_Acquire(this: *IDirectInputDevice) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::Acquire ({s})\n", .{@tagName(getDeviceType(this))});
    return 0; // DI_OK
}

fn device_Unacquire(this: *IDirectInputDevice) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::Unacquire ({s})\n", .{@tagName(getDeviceType(this))});
    return 0; // DI_OK
}

/// DIMOUSESTATE layout (16 bytes):
/// i32 lX, lY, lZ;
/// u8  rgbButtons[4];
const DIMOUSESTATE = extern struct {
    lX: i32,
    lY: i32,
    lZ: i32,
    rgbButtons: [4]u8,
};

fn device_GetDeviceState(this: *IDirectInputDevice, cbData: u32, lpvData: usize) callconv(w32cc.WINAPI) i32 {
    if (cbData == 0 or lpvData == 0) return 0;

    const dev_type = getDeviceType(this);
    if (dev_type == .unknown) {
        // Fallback: guess from cbData
        if (cbData >= 256) return device_GetDeviceState_keyboard(cbData, lpvData);
        return device_GetDeviceState_mouse(cbData, lpvData);
    }

    if (dev_type == .mouse) return device_GetDeviceState_mouse(cbData, lpvData);
    return device_GetDeviceState_keyboard(cbData, lpvData);
}

fn device_GetDeviceState_mouse(cbData: u32, lpvData: usize) i32 {
    const renderer = @import("../gui/renderer.zig");
    if (cbData >= @sizeOf(DIMOUSESTATE)) {
        const mouse = @as(*DIMOUSESTATE, @ptrFromInt(lpvData));
        // Read and clear as one step: a GUI thread accumulating a delta
        // between the two would have it overwritten by the reset below.
        renderer.input_mutex.lock();
        mouse.lX = renderer.mouse_dx;
        mouse.lY = renderer.mouse_dy;
        mouse.lZ = renderer.mouse_dz;
        mouse.rgbButtons = renderer.mouse_buttons;
        // Consume deltas
        renderer.mouse_dx = 0;
        renderer.mouse_dy = 0;
        renderer.mouse_dz = 0;
        renderer.input_mutex.unlock();
    } else {
        @memset(@as([*]u8, @ptrFromInt(lpvData))[0..cbData], 0);
    }
    return 0;
}

fn device_GetDeviceState_keyboard(cbData: u32, lpvData: usize) i32 {
    const renderer = @import("../gui/renderer.zig");
    const buf = @as([*]u8, @ptrFromInt(lpvData));
    const copy_len = @min(cbData, @as(u32, 256));
    @memcpy(buf[0..copy_len], renderer.keyboard_state[0..copy_len]);
    if (copy_len < cbData) {
        @memset(buf[copy_len..cbData], 0);
    }
    return 0;
}

/// IDirectInputDevice::GetDeviceData — returns buffered input events.
/// cbObjectData: size of each DIDEVICEOBJECTDATA struct (16 or 20 bytes)
/// rgdod: output buffer for events (may be null to just query count)
/// pdwInOut: IN = max items to read, OUT = items actually read
/// dwFlags: 0 = consume events, 1 = DIGDD_PEEK (don't consume)
fn device_GetDeviceData(this: *IDirectInputDevice, cbObjectData: u32, rgdod: usize, pdwInOut: *u32, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    const dev_type = getDeviceType(this);
    const buffer = if (dev_type == .mouse) &mouse_events else &keyboard_events;
    const peek = (dwFlags & 1) != 0; // DIGDD_PEEK = 1

    if (rgdod == 0) {
        // Null buffer — just return count of available events
        const avail = buffer.count();
        pdwInOut.* = avail;
        if (!peek) buffer.flush();
        return 0; // DI_OK
    }

    const max_items = pdwInOut.*;
    _ = cbObjectData; // We always use sizeof(DIDEVICEOBJECTDATA) = 16

    const out_ptr = @as([*]DIDEVICEOBJECTDATA, @ptrFromInt(rgdod));
    const items_read = buffer.drain(out_ptr, max_items, peek);
    pdwInOut.* = items_read;

    if (trace.enable_tracing and items_read > 0) {
        trace.print("DINPUT: GetDeviceData({s}) -> {d} events\n", .{ @tagName(dev_type), items_read });
    }

    return 0; // DI_OK
}

fn device_SetDataFormat(this: *IDirectInputDevice, lpFormat: usize) callconv(w32cc.WINAPI) i32 {
    var data_size: u32 = 0;
    if (lpFormat != 0) {
        data_size = @as(*const u32, @ptrFromInt(lpFormat + 12)).*;
    }
    const dev_type: DeviceType = if (data_size == 256) .keyboard else if (data_size <= 20) .mouse else .unknown;
    if (this == &keyboard_device) {
        keyboard_device_type = dev_type;
    } else if (this == &mouse_device) {
        mouse_device_type = dev_type;
    }
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::SetDataFormat (dataSize={d} -> {s})\n", .{ data_size, @tagName(dev_type) });
    return 0; // DI_OK
}

fn device_SetEventNotification(_: *IDirectInputDevice, hEvent: usize) callconv(w32cc.WINAPI) i32 {
    _ = hEvent;
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::SetEventNotification\n", .{});
    return 0; // DI_OK
}

fn device_SetCooperativeLevel(_: *IDirectInputDevice, _: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::SetCooperativeLevel\n", .{});
    return 0; // DI_OK
}

fn device_GetObjectInfo(_: *IDirectInputDevice, _: usize, _: u32, _: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::GetObjectInfo\n", .{});
    return 0; // DI_OK
}

fn device_GetDeviceInfo(_: *IDirectInputDevice, _: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DINPUT: IDirectInputDevice::GetDeviceInfo\n", .{});
    return 0; // DI_OK
}

fn device_RunControlPanel(_: *IDirectInputDevice, _: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn device_Initialize(_: *IDirectInputDevice, _: usize, _: u32, _: usize) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn device_CreateEffect(_: *IDirectInputDevice, _: usize, _: usize, ppEffect: *?*anyopaque, _: usize) callconv(w32cc.WINAPI) i32 {
    ppEffect.* = null;
    return @bitCast(@as(u32, 0x80004001)); // E_NOTIMPL
}

fn device_EnumEffects(_: *IDirectInputDevice, _: usize, _: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn device_GetEffectInfo(_: *IDirectInputDevice, _: usize, _: usize) callconv(w32cc.WINAPI) i32 {
    return @bitCast(@as(u32, 0x80004001)); // E_NOTIMPL
}

fn device_GetForceFeedbackState(_: *IDirectInputDevice, pdwOut: *u32) callconv(w32cc.WINAPI) i32 {
    pdwOut.* = 0;
    return 0; // DI_OK
}

fn device_SendForceFeedbackCommand(_: *IDirectInputDevice, _: u32) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn device_EnumCreatedEffectObjects(_: *IDirectInputDevice, _: usize, _: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn device_Escape(_: *IDirectInputDevice, _: usize) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn device_Poll(_: *IDirectInputDevice) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn device_SendDeviceData(_: *IDirectInputDevice, _: u32, _: usize, pdwInOut: *u32, _: u32) callconv(w32cc.WINAPI) i32 {
    pdwInOut.* = 0;
    return 0; // DI_OK
}

fn device_EnumEffectsInFile(_: *IDirectInputDevice, _: usize, _: usize, _: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn device_WriteEffectToFile(_: *IDirectInputDevice, _: usize, _: u32, _: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn device_BuildActionMap(_: *IDirectInputDevice, _: usize, _: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn device_SetActionMap(_: *IDirectInputDevice, _: usize, _: usize, _: u32) callconv(w32cc.WINAPI) i32 {
    return 0; // DI_OK
}

fn device_GetImageInfo(_: *IDirectInputDevice, _: usize) callconv(w32cc.WINAPI) i32 {
    return @bitCast(@as(u32, 0x80004001)); // E_NOTIMPL
}

// ============================================================================
// VTable Initialization
// ============================================================================

/// IDirectInputDevice vtable instance.
pub var device_vtbl: IDirectInputDeviceVtbl = undefined;
/// IDirectInput vtable instance.
pub var dinput_vtbl: IDirectInputVtbl = undefined;

/// Initialize DirectInput vtables.
/// Implementation status: Partially implemented
pub fn initVtables() void {
    device_vtbl = .{
        .QueryInterface = @ptrCast(&device_QueryInterface),
        .AddRef = device_AddRef,
        .Release = device_Release,
        .GetCapabilities = device_GetCapabilities,
        .EnumObjects = device_EnumObjects,
        .GetProperty = device_GetProperty,
        .SetProperty = device_SetProperty,
        .Acquire = device_Acquire,
        .Unacquire = device_Unacquire,
        .GetDeviceState = device_GetDeviceState,
        .GetDeviceData = device_GetDeviceData,
        .SetDataFormat = device_SetDataFormat,
        .SetEventNotification = device_SetEventNotification,
        .SetCooperativeLevel = device_SetCooperativeLevel,
        .GetObjectInfo = device_GetObjectInfo,
        .GetDeviceInfo = device_GetDeviceInfo,
        .RunControlPanel = device_RunControlPanel,
        .Initialize = device_Initialize,
        .CreateEffect = device_CreateEffect,
        .EnumEffects = device_EnumEffects,
        .GetEffectInfo = device_GetEffectInfo,
        .GetForceFeedbackState = device_GetForceFeedbackState,
        .SendForceFeedbackCommand = device_SendForceFeedbackCommand,
        .EnumCreatedEffectObjects = device_EnumCreatedEffectObjects,
        .Escape = device_Escape,
        .Poll = device_Poll,
        .SendDeviceData = device_SendDeviceData,
        .EnumEffectsInFile = device_EnumEffectsInFile,
        .WriteEffectToFile = device_WriteEffectToFile,
        .BuildActionMap = device_BuildActionMap,
        .SetActionMap = device_SetActionMap,
        .GetImageInfo = device_GetImageInfo,
    };

    dinput_vtbl = .{
        .QueryInterface = @ptrCast(&dinput_QueryInterface),
        .AddRef = dinput_AddRef,
        .Release = dinput_Release,
        .CreateDevice = dinput_CreateDevice,
        .EnumDevices = dinput_EnumDevices,
        .GetDeviceStatus = dinput_GetDeviceStatus,
        .RunControlPanel = dinput_RunControlPanel,
        .Initialize = dinput_Initialize,
    };

    global_dinput.lpVtbl = &dinput_vtbl;
    keyboard_device.lpVtbl = &device_vtbl;
    mouse_device.lpVtbl = &device_vtbl;
}

/// DirectInputCreateA exported entry point.
/// Implementation status: Stub
pub fn stub_DirectInputCreateA(_: usize, _: u32, ppDI: *?*IDirectInput, _: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DINPUT: DirectInputCreateA\n", .{});
    ppDI.* = &global_dinput;
    return 0; // DI_OK
}

/// DirectInput8Create exported entry point.
/// Implementation status: Stub
pub fn stub_DirectInput8Create(_: usize, _: u32, _: usize, ppvOut: *?*IDirectInput, _: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DINPUT8: DirectInput8Create\n", .{});
    ppvOut.* = &global_dinput;
    return 0; // DI_OK
}

/// Map a Windows Virtual Key code to a DirectInput keyboard scancode (DIK_xxx).
/// Returns 0 if no mapping exists.
/// Implementation status: Partially implemented
pub fn vkToDIK(vk: usize) u8 {
    return switch (vk) {
        0x1B => 0x01, // VK_ESCAPE -> DIK_ESCAPE
        0x31 => 0x02, // VK_1 -> DIK_1
        0x32 => 0x03, // VK_2 -> DIK_2
        0x33 => 0x04, // VK_3 -> DIK_3
        0x34 => 0x05, // VK_4 -> DIK_4
        0x35 => 0x06, // VK_5 -> DIK_5
        0x36 => 0x07, // VK_6 -> DIK_6
        0x37 => 0x08, // VK_7 -> DIK_7
        0x38 => 0x09, // VK_8 -> DIK_8
        0x39 => 0x0A, // VK_9 -> DIK_9
        0x30 => 0x0B, // VK_0 -> DIK_0
        0x08 => 0x0E, // VK_BACK -> DIK_BACK
        0x09 => 0x0F, // VK_TAB -> DIK_TAB
        0x51 => 0x10, // Q -> DIK_Q
        0x57 => 0x11, // W -> DIK_W
        0x45 => 0x12, // E -> DIK_E
        0x52 => 0x13, // R -> DIK_R
        0x54 => 0x14, // T -> DIK_T
        0x59 => 0x15, // Y -> DIK_Y
        0x55 => 0x16, // U -> DIK_U
        0x49 => 0x17, // I -> DIK_I
        0x4F => 0x18, // O -> DIK_O
        0x50 => 0x19, // P -> DIK_P
        0x0D => 0x1C, // VK_RETURN -> DIK_RETURN
        0x11 => 0x1D, // VK_CONTROL -> DIK_LCONTROL
        0x41 => 0x1E, // A -> DIK_A
        0x53 => 0x1F, // S -> DIK_S
        0x44 => 0x20, // D -> DIK_D
        0x46 => 0x21, // F -> DIK_F
        0x47 => 0x22, // G -> DIK_G
        0x48 => 0x23, // H -> DIK_H
        0x4A => 0x24, // J -> DIK_J
        0x4B => 0x25, // K -> DIK_K
        0x4C => 0x26, // L -> DIK_L
        0x10 => 0x2A, // VK_SHIFT -> DIK_LSHIFT
        0x5A => 0x2C, // Z -> DIK_Z
        0x58 => 0x2D, // X -> DIK_X
        0x43 => 0x2E, // C -> DIK_C
        0x56 => 0x2F, // V -> DIK_V
        0x42 => 0x30, // B -> DIK_B
        0x4E => 0x31, // N -> DIK_N
        0x4D => 0x32, // M -> DIK_M
        0x12 => 0x38, // VK_MENU -> DIK_LALT
        0x20 => 0x39, // VK_SPACE -> DIK_SPACE
        0x70 => 0x3B, // VK_F1 -> DIK_F1
        0x71 => 0x3C, // VK_F2 -> DIK_F2
        0x72 => 0x3D, // VK_F3 -> DIK_F3
        0x73 => 0x3E, // VK_F4 -> DIK_F4
        0x74 => 0x3F, // VK_F5 -> DIK_F5
        0x75 => 0x40, // VK_F6 -> DIK_F6
        0x76 => 0x41, // VK_F7 -> DIK_F7
        0x77 => 0x42, // VK_F8 -> DIK_F8
        0x78 => 0x43, // VK_F9 -> DIK_F9
        0x79 => 0x44, // VK_F10 -> DIK_F10
        0x7A => 0x57, // VK_F11 -> DIK_F11
        0x7B => 0x58, // VK_F12 -> DIK_F12
        0x26 => 0xC8, // VK_UP -> DIK_UP
        0x28 => 0xD0, // VK_DOWN -> DIK_DOWN
        0x25 => 0xCB, // VK_LEFT -> DIK_LEFT
        0x27 => 0xCD, // VK_RIGHT -> DIK_RIGHT
        0x2E => 0xD3, // VK_DELETE -> DIK_DELETE
        0x24 => 0xC7, // VK_HOME -> DIK_HOME
        0x23 => 0xCF, // VK_END -> DIK_END
        0x21 => 0xC9, // VK_PRIOR (PageUp) -> DIK_PGUP
        0x22 => 0xD1, // VK_NEXT (PageDown) -> DIK_PGDN
        0x2D => 0xD2, // VK_INSERT -> DIK_INSERT
        else => 0,
    };
}

/// Registers DINPUT.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    initVtables();

    const builtin_module = "DINPUT.dll";
    try environment.addBuiltinExportComptime(builtin_module, "DirectInputCreateA", stub_DirectInputCreateA);

    environment.addBuiltinVtableComptime(IDirectInputVtbl, &dinput_vtbl);
    environment.addBuiltinVtableComptime(IDirectInputDeviceVtbl, &device_vtbl);
}
