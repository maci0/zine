// Direct3D stubs — IDirect3D7, IDirect3D3, IDirect3DDevice3, IDirect3DViewport3
//
// Europa 1400 uses IDirect3D3 (obtained via IDirectDraw::QueryInterface).
// It then calls IDirect3D3::CreateDevice to get IDirect3DDevice3.
// These have DIFFERENT vtable layouts from IDirect3D7/IDirect3DDevice7.
// See dx_headers/VTABLES.md for the authoritative reference.

const std = @import("std");
const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const kernel32 = @import("../kernel32.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");
const ddraw_stubs = @import("../ddraw/ddraw.zig");

// ===== IDirect3D7 =====

pub const IDirect3D7 = extern struct {
    lpVtbl: *const IDirect3D7Vtbl,
};

// IDirect3D7 vtable: 8 methods
const IDirect3D7Vtbl = extern struct {
    QueryInterface: *const fn (*IDirect3D7, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32, // 0
    AddRef: *const fn (*IDirect3D7) callconv(w32cc.WINAPI) u32, // 1
    Release: *const fn (*IDirect3D7) callconv(w32cc.WINAPI) u32, // 2
    EnumDevices: *const fn (*IDirect3D7, usize, usize) callconv(w32cc.WINAPI) i32, // 3
    CreateDevice: *const fn (*IDirect3D7, usize, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32, // 4
    CreateVertexBuffer: *const fn (*IDirect3D7, usize, *?*anyopaque, u32) callconv(w32cc.WINAPI) i32, // 5
    EnumZBufferFormats: *const fn (*IDirect3D7, usize, usize, usize) callconv(w32cc.WINAPI) i32, // 6
    EvictManagedTextures: *const fn (*IDirect3D7) callconv(w32cc.WINAPI) i32, // 7
};

// IDirect3D3 vtable: 12 methods (from Wine d3d.h)
// 0: QueryInterface
// 1: AddRef
// 2: Release
// 3: EnumDevices
// 4: CreateLight
// 5: CreateMaterial
// 6: CreateViewport
// 7: FindDevice
// 8: CreateDevice
// 9: CreateVertexBuffer
// 10: EnumZBufferFormats
// 11: EvictManagedTextures
const IDirect3D3Vtbl = extern struct {
    QueryInterface: *const fn (*IDirect3D7, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32, // 0
    AddRef: *const fn (*IDirect3D7) callconv(w32cc.WINAPI) u32, // 1
    Release: *const fn (*IDirect3D7) callconv(w32cc.WINAPI) u32, // 2
    EnumDevices: *const fn (*IDirect3D7, usize, usize) callconv(w32cc.WINAPI) i32, // 3
    CreateLight: *const fn (*IDirect3D7, *?*anyopaque, usize) callconv(w32cc.WINAPI) i32, // 4
    CreateMaterial: *const fn (*IDirect3D7, *?*anyopaque, usize) callconv(w32cc.WINAPI) i32, // 5
    CreateViewport: *const fn (*IDirect3D7, *?*anyopaque, usize) callconv(w32cc.WINAPI) i32, // 6
    FindDevice: *const fn (*IDirect3D7, usize, usize) callconv(w32cc.WINAPI) i32, // 7
    CreateDevice: *const fn (*IDirect3D7, usize, usize, *?*anyopaque, usize) callconv(w32cc.WINAPI) i32, // 8
    CreateVertexBuffer: *const fn (*IDirect3D7, usize, *?*anyopaque, u32) callconv(w32cc.WINAPI) i32, // 9
    EnumZBufferFormats: *const fn (*IDirect3D7, usize, usize, usize) callconv(w32cc.WINAPI) i32, // 10
    EvictManagedTextures: *const fn (*IDirect3D7) callconv(w32cc.WINAPI) i32, // 11
};

// ===== IDirect3DDevice3 =====
// 42 methods — see dx_headers/VTABLES.md for the reference

pub const IDirect3DDevice3 = extern struct {
    lpVtbl: *const IDirect3DDevice3Vtbl,
};

const IDirect3DDevice3Vtbl = extern struct {
    // IUnknown (0-2)
    QueryInterface: usize, // 0: 0x00
    AddRef: usize, // 1: 0x04
    Release: usize, // 2: 0x08
    // IDirect3DDevice3 (3-41)
    GetCaps: usize, // 3: 0x0C  GetCaps(D3DDEVICEDESC*, D3DDEVICEDESC*)
    GetStats: usize, // 4: 0x10
    AddViewport: usize, // 5: 0x14  AddViewport(IDirect3DViewport3*)
    DeleteViewport: usize, // 6: 0x18
    NextViewport: usize, // 7: 0x1C
    EnumTextureFormats: usize, // 8: 0x20  EnumTextureFormats(callback, ctx)
    BeginScene: *const fn (usize) callconv(w32cc.WINAPI) i32, // 9: 0x24
    EndScene: *const fn (usize) callconv(w32cc.WINAPI) i32, // 10: 0x28
    GetDirect3D: usize, // 11: 0x2C
    SetCurrentViewport: usize, // 12: 0x30
    GetCurrentViewport: usize, // 13: 0x34
    SetRenderTarget: usize, // 14: 0x38
    GetRenderTarget: usize, // 15: 0x3C
    Begin: usize, // 16: 0x40
    BeginIndexed: usize, // 17: 0x44
    Vertex: usize, // 18: 0x48
    Index: usize, // 19: 0x4C
    End: usize, // 20: 0x50
    GetRenderState: usize, // 21: 0x54
    SetRenderState: usize, // 22: 0x58
    GetLightState: usize, // 23: 0x5C
    SetLightState: usize, // 24: 0x60
    SetTransform: usize, // 25: 0x64
    GetTransform: usize, // 26: 0x68
    MultiplyTransform: usize, // 27: 0x6C
    DrawPrimitive: usize, // 28: 0x70
    DrawIndexedPrimitive: usize, // 29: 0x74
    SetClipStatus: usize, // 30: 0x78
    GetClipStatus: usize, // 31: 0x7C
    DrawPrimitiveStrided: usize, // 32: 0x80
    DrawIndexedPrimitiveStrided: usize, // 33: 0x84
    DrawPrimitiveVB: usize, // 34: 0x88
    DrawIndexedPrimitiveVB: usize, // 35: 0x8C
    ComputeSphereVisibility: usize, // 36: 0x90
    GetTexture: usize, // 37: 0x94
    SetTexture: usize, // 38: 0x98
    GetTextureStageState: usize, // 39: 0x9C
    SetTextureStageState: usize, // 40: 0xA0
    ValidateDevice: usize, // 41: 0xA4
};

// ===== IDirect3DViewport3 =====
// 21 methods — see dx_headers/VTABLES.md

pub const IDirect3DViewport3 = extern struct {
    lpVtbl: *const IDirect3DViewport3Vtbl,
};

const IDirect3DViewport3Vtbl = extern struct {
    QueryInterface: usize, // 0: 0x00
    AddRef: usize, // 1: 0x04
    Release: usize, // 2: 0x08
    Initialize: usize, // 3: 0x0C
    GetViewport: usize, // 4: 0x10
    SetViewport: usize, // 5: 0x14
    TransformVertices: usize, // 6: 0x18
    LightElements: usize, // 7: 0x1C
    SetBackground: usize, // 8: 0x20
    GetBackground: usize, // 9: 0x24
    SetBackgroundDepth: usize, // 10: 0x28
    GetBackgroundDepth: usize, // 11: 0x2C
    Clear: usize, // 12: 0x30
    AddLight: usize, // 13: 0x34
    DeleteLight: usize, // 14: 0x38
    NextLight: usize, // 15: 0x3C
    GetViewport2: usize, // 16: 0x40
    SetViewport2: usize, // 17: 0x44
    SetBackgroundDepth2: usize, // 18: 0x48
    GetBackgroundDepth2: usize, // 19: 0x4C
    Clear2: usize, // 20: 0x50
};

// ===== IDirect3DDevice7 (still needed for IDirect3D7 path) =====

pub const IDirect3DDevice7 = extern struct {
    lpVtbl: *const IDirect3DDevice7Vtbl,
};

// IDirect3DDevice7 vtable: 48 methods
const IDirect3DDevice7Vtbl = extern struct {
    QueryInterface: usize, // 0: 0x00
    AddRef: usize, // 1: 0x04
    Release: usize, // 2: 0x08
    GetCaps: *const fn (*IDirect3DDevice7, usize) callconv(w32cc.WINAPI) i32, // 3: 0x0C
    EnumTextureFormats: *const fn (*IDirect3DDevice7, usize, usize) callconv(w32cc.WINAPI) i32, // 4: 0x10
    BeginScene: *const fn (*IDirect3DDevice7) callconv(w32cc.WINAPI) i32, // 5: 0x14
    EndScene: *const fn (*IDirect3DDevice7) callconv(w32cc.WINAPI) i32, // 6: 0x18
    GetDirect3D: usize, // 7
    SetRenderTarget: usize, // 8
    GetRenderTarget: usize, // 9
    Clear: *const fn (*IDirect3DDevice7, u32, usize, u32, u32, f32, u32) callconv(w32cc.WINAPI) i32, // 10
    SetTransform: usize, // 11
    GetTransform: usize, // 12
    SetViewport: usize, // 13
    MultiplyTransform: usize, // 14
    GetViewport: usize, // 15
    SetMaterial: usize, // 16
    GetMaterial: usize, // 17
    SetLight: usize, // 18
    GetLight: usize, // 19
    SetRenderState: usize, // 20
    GetRenderState: usize, // 21
    BeginStateBlock: usize, // 22
    EndStateBlock: usize, // 23
    PreLoad: usize, // 24
    DrawPrimitive: usize, // 25
    DrawIndexedPrimitive: usize, // 26
    SetClipStatus: usize, // 27
    GetClipStatus: usize, // 28
    DrawPrimitiveStrided: usize, // 29
    DrawIndexedPrimitiveStrided: usize, // 30
    DrawPrimitiveVB: usize, // 31
    DrawIndexedPrimitiveVB: usize, // 32
    ComputeSphereVisibility: usize, // 33
    GetTexture: usize, // 34
    SetTexture: usize, // 35
    GetTextureStageState: usize, // 36
    SetTextureStageState: usize, // 37
    ValidateDevice: usize, // 38
    ApplyStateBlock: usize, // 39
    CaptureStateBlock: usize, // 40
    DeleteStateBlock: usize, // 41
    CreateStateBlock: usize, // 42
    Load: usize, // 43
    LightEnable: usize, // 44
    GetLightEnable: usize, // 45
    SetClipPlane: usize, // 46
    GetClipPlane: usize, // 47
};

// ===== IDirect3DMaterial3 =====

pub const IDirect3DMaterial3 = extern struct {
    lpVtbl: *const IDirect3DMaterial3Vtbl,
};

const IDirect3DMaterial3Vtbl = extern struct {
    // IUnknown
    QueryInterface: usize, // 0
    AddRef: usize, // 1
    Release: usize, // 2
    // IDirect3DMaterial3
    SetMaterial: usize, // 3
    GetMaterial: usize, // 4
    GetHandle: usize, // 5
};

// ===== IDirect3DLight =====

pub const IDirect3DLight = extern struct {
    lpVtbl: *const IDirect3DLightVtbl,
};

const IDirect3DLightVtbl = extern struct {
    // IUnknown
    QueryInterface: usize, // 0
    AddRef: usize, // 1
    Release: usize, // 2
    // IDirect3DLight
    Initialize: usize, // 3
    SetLight: usize, // 4
    GetLight: usize, // 5
};

// ===== Instances =====

pub var global_d3d7: IDirect3D7 = undefined;
pub var global_d3d3: IDirect3D7 = undefined;  // IDirect3D3-compatible vtable, same struct type
var global_d3d7_device: IDirect3DDevice7 = undefined;
var global_d3d3_device: IDirect3DDevice3 = undefined;
var global_viewport3: IDirect3DViewport3 = undefined;
var global_material3: IDirect3DMaterial3 = undefined;
var global_light: IDirect3DLight = undefined;

var d3d7_vtbl: IDirect3D7Vtbl = undefined;
var d3d3_vtbl: IDirect3D3Vtbl = undefined;
var device7_vtbl: IDirect3DDevice7Vtbl = undefined;
var device3_vtbl: IDirect3DDevice3Vtbl = undefined;
var viewport3_vtbl: IDirect3DViewport3Vtbl = undefined;
var material3_vtbl: IDirect3DMaterial3Vtbl = undefined;
var light_vtbl: IDirect3DLightVtbl = undefined;

// Storage for viewport data — D3DVIEWPORT2 is 44 bytes
var viewport2_data: [44]u8 = [_]u8{0} ** 44;
var viewport2_valid: bool = false;
// D3DVIEWPORT (legacy) is 44 bytes too
var viewport_data: [44]u8 = [_]u8{0} ** 44;
var viewport_valid: bool = false;

// ===== Viewport Implementations =====

/// IDirect3DViewport3::SetViewport2(this, lpViewport2)
fn vp_SetViewport2(this: usize, lpData: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (lpData != 0) {
        const src = @as(*const [44]u8, @ptrFromInt(lpData));
        // Read dwSize (first DWORD) to determine copy length
        const size = @as(*const u32, @ptrFromInt(lpData)).*;
        const copy_len = @min(size, 44);
        @memcpy(viewport2_data[0..copy_len], src[0..copy_len]);
        viewport2_valid = true;
        if (trace.enable_tracing) {
            // D3DVIEWPORT2 layout: dwSize(0), dwX(4), dwY(8), dwWidth(12), dwHeight(16)
            const w = @as(*const u32, @ptrFromInt(lpData + 12)).*;
            const h = @as(*const u32, @ptrFromInt(lpData + 16)).*;
            trace.print("D3D7: SetViewport2(width={d}, height={d})\n", .{ w, h });
        }
    }
    return w32.D3D_OK;
}

/// IDirect3DViewport3::GetViewport2(this, lpViewport2)
fn vp_GetViewport2(this: usize, lpData: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (lpData != 0) {
        if (viewport2_valid) {
            const dst = @as(*[44]u8, @ptrFromInt(lpData));
            @memcpy(dst, &viewport2_data);
        } else {
            // Not set yet — fill with display mode defaults
            const dst = @as(*[44]u8, @ptrFromInt(lpData));
            @memset(dst, 0);
            @as(*u32, @ptrFromInt(lpData + 0)).* = 44; // dwSize
            @as(*u32, @ptrFromInt(lpData + 12)).* = ddraw_stubs.display_mode_w; // dwWidth
            @as(*u32, @ptrFromInt(lpData + 16)).* = ddraw_stubs.display_mode_h; // dwHeight
        }
        if (trace.enable_tracing) {
            const w = @as(*const u32, @ptrFromInt(lpData + 12)).*;
            const h = @as(*const u32, @ptrFromInt(lpData + 16)).*;
            trace.print("D3D7: GetViewport2 -> width={d}, height={d}\n", .{ w, h });
        }
    }
    return w32.D3D_OK;
}

/// IDirect3DViewport3::SetViewport(this, lpViewport) — legacy D3DVIEWPORT
fn vp_SetViewport(this: usize, lpData: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (lpData != 0) {
        const src = @as(*const [44]u8, @ptrFromInt(lpData));
        const size = @as(*const u32, @ptrFromInt(lpData)).*;
        const copy_len = @min(size, 44);
        @memcpy(viewport_data[0..copy_len], src[0..copy_len]);
        viewport_valid = true;
        if (trace.enable_tracing) trace.print("D3D7: SetViewport\n", .{});
    }
    return w32.D3D_OK;
}

/// IDirect3DViewport3::GetViewport(this, lpViewport) — legacy D3DVIEWPORT
fn vp_GetViewport(this: usize, lpData: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (lpData != 0) {
        if (viewport_valid) {
            const dst = @as(*[44]u8, @ptrFromInt(lpData));
            @memcpy(dst, &viewport_data);
        } else {
            // Not set yet — fill with display mode defaults
            const dst = @as(*[44]u8, @ptrFromInt(lpData));
            @memset(dst, 0);
            @as(*u32, @ptrFromInt(lpData + 0)).* = 44; // dwSize
            @as(*u32, @ptrFromInt(lpData + 12)).* = ddraw_stubs.display_mode_w; // dwWidth
            @as(*u32, @ptrFromInt(lpData + 16)).* = ddraw_stubs.display_mode_h; // dwHeight
        }
        if (trace.enable_tracing) trace.print("D3D7: GetViewport\n", .{});
    }
    return w32.D3D_OK;
}

// ===== IDirect3D7/D3D3 Implementations =====

fn d3d7_QueryInterface(this: *IDirect3D7, riid: usize, ppvObj: *?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = riid;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D7::QueryInterface\n", .{});
    ppvObj.* = @ptrCast(this);
    return w32.S_OK;
}

fn d3d7_AddRef(this: *IDirect3D7) callconv(w32cc.WINAPI) u32 {
    _ = this;
    return 1;
}

fn d3d7_Release(this: *IDirect3D7) callconv(w32cc.WINAPI) u32 {
    _ = this;
    return 1;
}

fn d3d7_EnumDevices(this: *IDirect3D7, lpEnumDevicesCallback: usize, lpUserArg: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D7::EnumDevices\n", .{});

    if (lpEnumDevicesCallback != 0) {
        // D3D7 EnumDevices callback: HRESULT CALLBACK(LPSTR lpDeviceDescription, LPSTR lpDeviceName, LPD3DDEVICEDESC7 lpD3DDeviceDesc, LPVOID lpContext)
        const cb = @as(*const fn (usize, usize, usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(lpEnumDevicesCallback));

        // Create D3DDEVICEDESC7 (smaller than D3DDEVICEDESC — different struct)
        var desc7: [544]u8 = [_]u8{0} ** 544;
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&desc7))).* = 0x00017FF1; // dwDevCaps
        // ... fill dpcLineCaps, dpcTriCaps, etc.

        const device_desc_str = "Zine HAL Device\x00";
        const device_name_str = "HAL\x00";
        const result = cb(@intFromPtr(device_desc_str.ptr), @intFromPtr(device_name_str.ptr),
            @intFromPtr(&desc7), lpUserArg);
        _ = result;
    }
    return w32.D3D_OK;
}

/// IDirect3D3 EnumDevices — callback takes 6 args:
/// HRESULT CALLBACK(GUID* lpGuid, LPSTR lpDesc, LPSTR lpName, LPD3DDEVICEDESC lpHWDesc, LPD3DDEVICEDESC lpHELDesc, LPVOID lpCtx)
fn d3d3_EnumDevices(this: *IDirect3D7, lpEnumDevicesCallback: usize, lpUserArg: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D3::EnumDevices\n", .{});

    if (lpEnumDevicesCallback != 0) {
        const cb = @as(*const fn (usize, usize, usize, usize, usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(lpEnumDevicesCallback));

        // IID_IDirect3DHALDevice = {84E63dE0-46AA-11CF-816F-0000C020156E}
        const hal_guid = [16]u8{ 0xE0, 0x3D, 0xE6, 0x84, 0xAA, 0x46, 0xCF, 0x11, 0x81, 0x6F, 0x00, 0x00, 0xC0, 0x20, 0x15, 0x6E };

        // D3DDEVICEDESC (old-style) = 252 bytes (0xFC)
        // IMPORTANT: D3DPRIMCAPS is 56 bytes (14 DWORDs), NOT 48!
        // Layout verified from Wine d3dcaps.h — see dx_headers/VTABLES.md
        var hw_desc: [252]u8 = [_]u8{0} ** 252;
        var hel_desc: [252]u8 = [_]u8{0} ** 252;

        // ---------- hw_desc ----------
        // 0x00: dwSize = 252
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x00)).* = 252;
        // 0x04: dwFlags = all capability groups present (0x7FF)
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x04)).* = 0x7FF;
        // 0x08: dcmColorModel = D3DCOLOR_RGB = 2 (NOT 1 which is MONO!)
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x08)).* = 2;
        // 0x0C: dwDevCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x0C)).* = 0x00017FF1;
        // 0x10: dtcTransformCaps.dwSize = 8
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x10)).* = 8;
        // 0x14: dtcTransformCaps.dwCaps = D3DTRANSFORMCAPS_CLIP
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x14)).* = 1;
        // 0x18: bClipping = TRUE
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x18)).* = 1;
        // 0x1C-0x2B: dlcLightingCaps (16 bytes)
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x1C)).* = 16; // dwSize
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x20)).* = 0x1E; // dwCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x24)).* = 0; // dwLightingModel
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x28)).* = 8; // dwNumLights

        // 0x2C-0x63: dpcLineCaps (D3DPRIMCAPS = 56 bytes)
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x2C)).* = 56; // dwSize
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x30)).* = 0x3FF; // dwMiscCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x34)).* = 0x1F01; // dwRasterCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x38)).* = 0xFF; // dwZCmpCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x3C)).* = 0x1FF; // dwSrcBlendCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x40)).* = 0x1FF; // dwDestBlendCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x44)).* = 0xFF; // dwAlphaCmpCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x48)).* = 0x1F; // dwShadeCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x4C)).* = 0x1FF; // dwTextureCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x50)).* = 0x7; // dwTextureFilterCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x54)).* = 0x7; // dwTextureBlendCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x58)).* = 0x7; // dwTextureAddressCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x5C)).* = 32; // dwStippleWidth
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x60)).* = 32; // dwStippleHeight

        // 0x64-0x9B: dpcTriCaps (D3DPRIMCAPS = 56 bytes)
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x64)).* = 56; // dwSize
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x68)).* = 0x3FF; // dwMiscCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x6C)).* = 0x1F01; // dwRasterCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x70)).* = 0xFF; // dwZCmpCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x74)).* = 0x1FF; // dwSrcBlendCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x78)).* = 0x1FF; // dwDestBlendCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x7C)).* = 0xFF; // dwAlphaCmpCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x80)).* = 0x1F; // dwShadeCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x84)).* = 0x1FF; // dwTextureCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x88)).* = 0x7; // dwTextureFilterCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x8C)).* = 0x7; // dwTextureBlendCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x90)).* = 0x7; // dwTextureAddressCaps
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x94)).* = 32; // dwStippleWidth
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x98)).* = 32; // dwStippleHeight

        // 0x9C: dwDeviceRenderBitDepth = DDBD_8|DDBD_16|DDBD_24|DDBD_32 = 0x0F00
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0x9C)).* = 0x0F00;
        // 0xA0: dwDeviceZBufferBitDepth = DDBD_16|DDBD_24|DDBD_32 = 0x0E00
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0xA0)).* = 0x0E00;
        // 0xA4: dwMaxBufferSize = 0
        // 0xA8: dwMaxVertexCount = 65536
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0xA8)).* = 65536;
        // 0xAC: dwMinTextureWidth = 1
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0xAC)).* = 1;
        // 0xB0: dwMinTextureHeight = 1
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0xB0)).* = 1;
        // 0xB4: dwMaxTextureWidth = 2048
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0xB4)).* = 2048;
        // 0xB8: dwMaxTextureHeight = 2048
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hw_desc) + 0xB8)).* = 2048;

        // ---------- hel_desc ----------
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&hel_desc) + 0x00)).* = 252; // dwSize

        const device_desc_str = "Zine HAL Device\x00";
        const device_name_str = "HAL\x00";
        if (trace.enable_tracing) trace.print("D3D7: EnumDevices callback=0x{x} calling with HAL guid\n", .{lpEnumDevicesCallback});
        const result = cb(@intFromPtr(&hal_guid), @intFromPtr(device_desc_str.ptr), @intFromPtr(device_name_str.ptr),
            @intFromPtr(&hw_desc), @intFromPtr(&hel_desc), lpUserArg);
        if (trace.enable_tracing) trace.print("D3D7: EnumDevices callback returned {d}\n", .{result});
    }
    return w32.D3D_OK;
}

fn d3d7_CreateDevice(this: *IDirect3D7, rclsid: usize, lpDDS: usize, lplpD3DDevice: *?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = rclsid; _ = lpDDS;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D7::CreateDevice\n", .{});
    renderer.setResolution(ddraw_stubs.display_mode_w, ddraw_stubs.display_mode_h);
    lplpD3DDevice.* = @ptrCast(&global_d3d7_device);
    return w32.D3D_OK;
}

/// IDirect3D3::CreateDevice(this, rclsid, pDDS, ppDevice, pUnkOuter)
fn d3d3_CreateDevice(this: *IDirect3D7, rclsid: usize, lpDDS: usize, lplpD3DDevice: *?*anyopaque, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = rclsid; _ = lpDDS; _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D3::CreateDevice\n", .{});
    renderer.setResolution(ddraw_stubs.display_mode_w, ddraw_stubs.display_mode_h);
    lplpD3DDevice.* = @ptrCast(&global_d3d3_device);
    // Signal that a paint is needed — so the next PeekMessageA returns WM_PAINT,
    // allowing the game's WndProc to initialize rendering now that the D3D device exists.
    const user32 = @import("../user32.zig");
    user32.needs_paint = true;
    return w32.D3D_OK;
}

fn d3d7_CreateVertexBuffer(this: *IDirect3D7, lpVBDesc: usize, lplpD3DVertexBuffer: *?*anyopaque, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = lpVBDesc; _ = dwFlags;
    if (trace.enable_tracing) trace.print("D3D7: CreateVertexBuffer\n", .{});
    lplpD3DVertexBuffer.* = @ptrFromInt(0xBEEF7000);
    return w32.D3D_OK;
}

fn d3d7_EnumZBufferFormats(this: *IDirect3D7, riidDevice: usize, lpEnumCallback: usize, lpContext: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = riidDevice;
    if (trace.enable_tracing) trace.print("D3D7: EnumZBufferFormats\n", .{});
    if (lpEnumCallback != 0) {
        const cb = @as(*const fn (usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(lpEnumCallback));
        var pf: w32.DDPIXELFORMAT = std.mem.zeroes(w32.DDPIXELFORMAT);
        pf.dwSize = 32;
        pf.dwFlags = 0x00000400; // DDPF_ZBUFFER
        pf.dwRGBBitCount = 16; // dwZBufferBitDepth
        pf.dwRBitMask = 0xFFFF; // dwZBitMask
        _ = cb(@intFromPtr(&pf), lpContext);
    }
    return w32.D3D_OK;
}

fn d3d7_EvictManagedTextures(this: *IDirect3D7) callconv(w32cc.WINAPI) i32 {
    _ = this;
    return w32.D3D_OK;
}

// ===== IDirect3D3 Specific Stubs =====

fn d3d3_CreateLight(this: *IDirect3D7, ppLight: *?*anyopaque, pUnk: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = pUnk;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D3::CreateLight\n", .{});
    ppLight.* = @ptrCast(&global_light);
    return w32.D3D_OK;
}

fn d3d3_CreateMaterial(this: *IDirect3D7, ppMaterial: *?*anyopaque, pUnk: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = pUnk;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D3::CreateMaterial\n", .{});
    ppMaterial.* = @ptrCast(&global_material3);
    return w32.D3D_OK;
}

fn d3d3_CreateViewport(this: *IDirect3D7, ppViewport: *?*anyopaque, pUnk: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = pUnk;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D3::CreateViewport\n", .{});
    ppViewport.* = @ptrCast(&global_viewport3);
    return w32.D3D_OK;
}

fn d3d3_FindDevice(this: *IDirect3D7, pSearch: usize, pResult: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D3::FindDevice(search=0x{x}, result=0x{x})\n", .{pSearch, pResult});
    if (pResult != 0) {
        const hal_guid = [16]u8{ 0xE0, 0x3D, 0xE6, 0x84, 0xAA, 0x46, 0xCF, 0x11, 0x81, 0x6F, 0x00, 0x00, 0xC0, 0x20, 0x15, 0x6E };
        const dest = @as([*]u8, @ptrFromInt(pResult + 4));
        @memcpy(dest[0..16], &hal_guid);
    }
    return w32.D3D_OK;
}

// ===== IDirect3DDevice3 Implementations =====

fn device3_BeginScene(this: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D7: BeginScene\n", .{});
    return w32.D3D_OK;
}

fn device3_EndScene(this: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D7: EndScene\n", .{});
    ddraw_stubs.pushSurfaceFrame();
    return w32.D3D_OK;
}

fn device3_EnumTextureFormats(this: usize, lpd3dEnumPixelProc: usize, lpArg: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D3Dev: EnumTextureFormats\n", .{});
    if (lpd3dEnumPixelProc != 0) {
        const cb = @as(*const fn (usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(lpd3dEnumPixelProc));
        const formats = [_]struct { bpp: u32, r: u32, g: u32, b: u32, a: u32, flags: u32 }{
            .{ .bpp = 16, .r = 0xF800, .g = 0x07E0, .b = 0x001F, .a = 0, .flags = 0x40 }, // RGB565
            .{ .bpp = 16, .r = 0x7C00, .g = 0x03E0, .b = 0x001F, .a = 0x8000, .flags = 0x41 }, // ARGB1555
            .{ .bpp = 32, .r = 0x00FF0000, .g = 0x0000FF00, .b = 0x000000FF, .a = 0xFF000000, .flags = 0x41 }, // ARGB8888
            .{ .bpp = 32, .r = 0x00FF0000, .g = 0x0000FF00, .b = 0x000000FF, .a = 0, .flags = 0x40 }, // XRGB8888
        };
        for (formats) |fmt| {
            var pf: w32.DDPIXELFORMAT = std.mem.zeroes(w32.DDPIXELFORMAT);
            pf.dwSize = 32;
            pf.dwFlags = fmt.flags;
            pf.dwRGBBitCount = fmt.bpp;
            pf.dwRBitMask = fmt.r;
            pf.dwGBitMask = fmt.g;
            pf.dwBBitMask = fmt.b;
            pf.dwRGBAlphaBitMask = fmt.a;
            const cont = cb(@intFromPtr(&pf), lpArg);
            if (cont == 0) break;
        }
    }
    return w32.D3D_OK;
}

// ===== IDirect3DDevice7 Implementations =====

fn device7_GetCaps(this: *IDirect3DDevice7, pCaps: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3DDevice7::GetCaps\n", .{});
    if (pCaps != 0) {
        const caps = @as([*]u8, @ptrFromInt(pCaps));
        @memset(caps[0..544], 0);
        @as(*align(1) u32, @ptrFromInt(pCaps)).* = 0x00017FF1;
        @as(*align(1) u32, @ptrFromInt(pCaps + 196)).* = 2048;
        @as(*align(1) u32, @ptrFromInt(pCaps + 200)).* = 2048;
    }
    return w32.D3D_OK;
}

fn device7_EnumTextureFormats(this: *IDirect3DDevice7, lpd3dEnumPixelProc: usize, lpArg: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D7: EnumTextureFormats\n", .{});
    if (lpd3dEnumPixelProc != 0) {
        const cb = @as(*const fn (usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(lpd3dEnumPixelProc));
        const formats = [_]struct { bpp: u32, r: u32, g: u32, b: u32, a: u32, flags: u32 }{
            .{ .bpp = 16, .r = 0xF800, .g = 0x07E0, .b = 0x001F, .a = 0, .flags = 0x40 },
            .{ .bpp = 32, .r = 0x00FF0000, .g = 0x0000FF00, .b = 0x000000FF, .a = 0xFF000000, .flags = 0x41 },
            .{ .bpp = 32, .r = 0x00FF0000, .g = 0x0000FF00, .b = 0x000000FF, .a = 0, .flags = 0x40 },
        };
        for (formats) |fmt| {
            var pf: w32.DDPIXELFORMAT = std.mem.zeroes(w32.DDPIXELFORMAT);
            pf.dwSize = 32;
            pf.dwFlags = fmt.flags;
            pf.dwRGBBitCount = fmt.bpp;
            pf.dwRBitMask = fmt.r;
            pf.dwGBitMask = fmt.g;
            pf.dwBBitMask = fmt.b;
            pf.dwRGBAlphaBitMask = fmt.a;
            const cont = cb(@intFromPtr(&pf), lpArg);
            if (cont == 0) break;
        }
    }
    return w32.D3D_OK;
}

fn device7_BeginScene(this: *IDirect3DDevice7) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D7: BeginScene\n", .{});
    return w32.D3D_OK;
}

fn device7_EndScene(this: *IDirect3DDevice7) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D7: EndScene\n", .{});
    ddraw_stubs.pushSurfaceFrame();
    return w32.D3D_OK;
}

fn device7_Clear(this: *IDirect3DDevice7, dwCount: u32, lpRects: usize, dwFlags: u32, dwColor: u32, dvZ: f32, dwStencil: u32) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = dwCount; _ = lpRects; _ = dwFlags; _ = dvZ; _ = dwStencil;
    if (trace.enable_tracing) trace.print("D3D7: Clear(color=0x{x:0>8})\n", .{dwColor});

    const vw = renderer.global_width;
    const vh = renderer.global_height;
    const pixels = vw * vh;

    if (ddraw_stubs.surface_buffer.len >= pixels * 4) {
        const b: u8 = @intCast(dwColor & 0xFF);
        const g: u8 = @intCast((dwColor >> 8) & 0xFF);
        const r: u8 = @intCast((dwColor >> 16) & 0xFF);
        for (0..pixels) |i| {
            ddraw_stubs.surface_buffer[i * 4 + 0] = b;
            ddraw_stubs.surface_buffer[i * 4 + 1] = g;
            ddraw_stubs.surface_buffer[i * 4 + 2] = r;
            ddraw_stubs.surface_buffer[i * 4 + 3] = 255;
        }
    }
    return w32.D3D_OK;
}

// Traced N-ary no-ops for D3D Device3 method tracing
fn tn1(comptime name: []const u8) *const fn (usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize) callconv(w32cc.WINAPI) usize { _ = a; if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{}); return 0; }
    }.func;
}
fn tn2(comptime name: []const u8) *const fn (usize, usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize, b: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{}); return 0; }
    }.func;
}
fn tn3(comptime name: []const u8) *const fn (usize, usize, usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{}); return 0; }
    }.func;
}
fn tn4(comptime name: []const u8) *const fn (usize, usize, usize, usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; _ = d; if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{}); return 0; }
    }.func;
}
fn tn6(comptime name: []const u8) *const fn (usize, usize, usize, usize, usize, usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; _ = d; _ = e; _ = f; if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{}); return 0; }
    }.func;
}
fn tn8(comptime name: []const u8) *const fn (usize, usize, usize, usize, usize, usize, usize, usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; _ = d; _ = e; _ = f; _ = g; _ = h; if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{}); return 0; }
    }.func;
}

// Typed no-ops (stdcall)
fn n1(a: usize) callconv(w32cc.WINAPI) usize { _ = a; return 0; }
fn n2(a: usize, b: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; return 0; }
fn n3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; return 0; }
fn n4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; _ = d; return 0; }
fn n5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; _ = d; _ = e; return 0; }
fn n6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; _ = d; _ = e; _ = f; return 0; }
fn n7(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; _ = d; _ = e; _ = f; _ = g; return 0; }
fn n8(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(w32cc.WINAPI) usize { _ = a; _ = b; _ = c; _ = d; _ = e; _ = f; _ = g; _ = h; return 0; }

// ===== Registration =====

pub fn init() void {
    const N1 = @intFromPtr(&n1);
    const N2 = @intFromPtr(&n2);
    const N3 = @intFromPtr(&n3);
    const N4 = @intFromPtr(&n4);
    const N6 = @intFromPtr(&n6);
    const N7 = @intFromPtr(&n7);
    const N8 = @intFromPtr(&n8);


    d3d7_vtbl = .{
        .QueryInterface = d3d7_QueryInterface,
        .AddRef = d3d7_AddRef,
        .Release = d3d7_Release,
        .EnumDevices = d3d7_EnumDevices,
        .CreateDevice = d3d7_CreateDevice,
        .CreateVertexBuffer = d3d7_CreateVertexBuffer,
        .EnumZBufferFormats = d3d7_EnumZBufferFormats,
        .EvictManagedTextures = d3d7_EvictManagedTextures,
    };

    d3d3_vtbl = .{
        .QueryInterface = d3d7_QueryInterface,
        .AddRef = d3d7_AddRef,
        .Release = d3d7_Release,
        .EnumDevices = d3d3_EnumDevices,
        .CreateLight = d3d3_CreateLight,
        .CreateMaterial = d3d3_CreateMaterial,
        .CreateViewport = d3d3_CreateViewport,
        .FindDevice = d3d3_FindDevice,
        .CreateDevice = d3d3_CreateDevice,
        .CreateVertexBuffer = d3d7_CreateVertexBuffer,
        .EnumZBufferFormats = d3d7_EnumZBufferFormats,
        .EvictManagedTextures = d3d7_EvictManagedTextures,
    };

    // IDirect3DDevice3 vtable — 42 methods (traced stubs)
    device3_vtbl = .{
        .QueryInterface = @intFromPtr(tn3("QueryInterface")),     // 0
        .AddRef = @intFromPtr(tn1("AddRef")),             // 1
        .Release = @intFromPtr(tn1("Release")),            // 2
        .GetCaps = @intFromPtr(tn3("GetCaps")),            // 3
        .GetStats = @intFromPtr(tn2("GetStats")),           // 4
        .AddViewport = @intFromPtr(tn2("AddViewport")),        // 5
        .DeleteViewport = @intFromPtr(tn2("DeleteViewport")),     // 6
        .NextViewport = @intFromPtr(tn4("NextViewport")),       // 7
        .EnumTextureFormats = @intFromPtr(&device3_EnumTextureFormats), // 8
        .BeginScene = device3_BeginScene, // 9
        .EndScene = device3_EndScene,     // 10
        .GetDirect3D = @intFromPtr(tn2("GetDirect3D")),  // 11
        .SetCurrentViewport = @intFromPtr(tn2("SetCurrentViewport")), // 12
        .GetCurrentViewport = @intFromPtr(tn2("GetCurrentViewport")), // 13
        .SetRenderTarget = @intFromPtr(tn3("SetRenderTarget")),    // 14
        .GetRenderTarget = @intFromPtr(tn2("GetRenderTarget")),    // 15
        .Begin = @intFromPtr(tn4("Begin")),              // 16
        .BeginIndexed = @intFromPtr(tn6("BeginIndexed")),       // 17
        .Vertex = @intFromPtr(tn2("Vertex")),             // 18
        .Index = @intFromPtr(tn2("Index")),              // 19
        .End = @intFromPtr(tn2("End")),                // 20
        .GetRenderState = @intFromPtr(tn3("GetRenderState")),     // 21
        .SetRenderState = @intFromPtr(tn3("SetRenderState")),     // 22
        .GetLightState = @intFromPtr(tn3("GetLightState")),      // 23
        .SetLightState = @intFromPtr(tn3("SetLightState")),      // 24
        .SetTransform = @intFromPtr(tn3("SetTransform")),       // 25
        .GetTransform = @intFromPtr(tn3("GetTransform")),       // 26
        .MultiplyTransform = @intFromPtr(tn3("MultiplyTransform")),  // 27
        .DrawPrimitive = @intFromPtr(tn6("DrawPrimitive")),      // 28
        .DrawIndexedPrimitive = @intFromPtr(tn8("DrawIndexedPrimitive")), // 29
        .SetClipStatus = @intFromPtr(tn2("SetClipStatus")),      // 30
        .GetClipStatus = @intFromPtr(tn2("GetClipStatus")),      // 31
        .DrawPrimitiveStrided = @intFromPtr(tn6("DrawPrimitiveStrided")), // 32
        .DrawIndexedPrimitiveStrided = @intFromPtr(tn8("DrawIndexedPrimitiveStrided")), // 33
        .DrawPrimitiveVB = @intFromPtr(tn6("DrawPrimitiveVB")),    // 34
        .DrawIndexedPrimitiveVB = @intFromPtr(tn6("DrawIndexedPrimitiveVB")), // 35
        .ComputeSphereVisibility = @intFromPtr(tn6("ComputeSphereVisibility")), // 36
        .GetTexture = @intFromPtr(tn3("GetTexture")),         // 37
        .SetTexture = @intFromPtr(tn3("SetTexture")),         // 38
        .GetTextureStageState = @intFromPtr(tn4("GetTextureStageState")), // 39
        .SetTextureStageState = @intFromPtr(tn4("SetTextureStageState")), // 40
        .ValidateDevice = @intFromPtr(tn2("ValidateDevice")),     // 41
    };

    // IDirect3DDevice7 vtable — 48 methods
    device7_vtbl = .{
        .QueryInterface = N3,
        .AddRef = N1,
        .Release = N1,
        .GetCaps = device7_GetCaps,
        .EnumTextureFormats = device7_EnumTextureFormats,
        .BeginScene = device7_BeginScene,
        .EndScene = device7_EndScene,
        .GetDirect3D = N2,
        .SetRenderTarget = N3,
        .GetRenderTarget = N2,
        .Clear = device7_Clear,
        .SetTransform = N3,
        .GetTransform = N3,
        .SetViewport = N2,
        .MultiplyTransform = N3,
        .GetViewport = N2,
        .SetMaterial = N2,
        .GetMaterial = N2,
        .SetLight = N3,
        .GetLight = N3,
        .SetRenderState = N3,
        .GetRenderState = N3,
        .BeginStateBlock = N1,
        .EndStateBlock = N2,
        .PreLoad = N2,
        .DrawPrimitive = N6,
        .DrawIndexedPrimitive = N8,
        .SetClipStatus = N2,
        .GetClipStatus = N2,
        .DrawPrimitiveStrided = N6,
        .DrawIndexedPrimitiveStrided = N8,
        .DrawPrimitiveVB = N6,
        .DrawIndexedPrimitiveVB = N8,
        .ComputeSphereVisibility = N6,
        .GetTexture = N3,
        .SetTexture = N3,
        .GetTextureStageState = N4,
        .SetTextureStageState = N4,
        .ValidateDevice = N2,
        .ApplyStateBlock = N2,
        .CaptureStateBlock = N2,
        .DeleteStateBlock = N2,
        .CreateStateBlock = N3,
        .Load = N6,
        .LightEnable = N3,
        .GetLightEnable = N3,
        .SetClipPlane = N3,
        .GetClipPlane = N3,
    };

    // IDirect3DViewport3 vtable — 21 methods
    viewport3_vtbl = .{
        .QueryInterface = N3, // 0
        .AddRef = N1,         // 1
        .Release = N1,        // 2
        .Initialize = N2,     // 3
        .GetViewport = @intFromPtr(&vp_GetViewport), // 4
        .SetViewport = @intFromPtr(&vp_SetViewport), // 5
        .TransformVertices = N4, // 6
        .LightElements = N3,  // 7
        .SetBackground = N2,  // 8
        .GetBackground = N3,  // 9
        .SetBackgroundDepth = N2, // 10
        .GetBackgroundDepth = N3, // 11
        .Clear = N4,          // 12: this, count, rects, flags
        .AddLight = N2,       // 13
        .DeleteLight = N2,    // 14
        .NextLight = N4,      // 15
        .GetViewport2 = @intFromPtr(&vp_GetViewport2), // 16
        .SetViewport2 = @intFromPtr(&vp_SetViewport2), // 17
        .SetBackgroundDepth2 = N2, // 18
        .GetBackgroundDepth2 = N3, // 19
        .Clear2 = N7,         // 20: this, count, rects, flags, color, z, stencil
    };

    // IDirect3DMaterial3 vtable — 6 methods
    material3_vtbl = .{
        .QueryInterface = N3,
        .AddRef = N1,
        .Release = N1,
        .SetMaterial = N2,
        .GetMaterial = N2,
        .GetHandle = N3,
    };

    // IDirect3DLight vtable — 6 methods
    light_vtbl = .{
        .QueryInterface = N3,
        .AddRef = N1,
        .Release = N1,
        .Initialize = N2,
        .SetLight = N2,
        .GetLight = N2,
    };

    global_d3d7.lpVtbl = &d3d7_vtbl;
    global_d3d3.lpVtbl = @ptrCast(&d3d3_vtbl);
    global_d3d7_device.lpVtbl = &device7_vtbl;
    global_d3d3_device.lpVtbl = &device3_vtbl;
    global_viewport3.lpVtbl = &viewport3_vtbl;
    global_material3.lpVtbl = &material3_vtbl;
    global_light.lpVtbl = &light_vtbl;
}

pub fn registerVtables(environment: anytype) void {
    environment.addBuiltinVtableComptime(IDirect3D7Vtbl, &d3d7_vtbl);
    environment.addBuiltinVtableComptime(IDirect3D3Vtbl, &d3d3_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DDevice7Vtbl, &device7_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DDevice3Vtbl, &device3_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DViewport3Vtbl, &viewport3_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DMaterial3Vtbl, &material3_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DLightVtbl, &light_vtbl);
}
