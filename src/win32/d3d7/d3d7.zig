// Direct3D stubs — IDirect3D7, IDirect3D3, IDirect3DDevice3, IDirect3DViewport3
//
// Europa 1400 uses IDirect3D3 (obtained via IDirectDraw::QueryInterface).
// It then calls IDirect3D3::CreateDevice to get IDirect3DDevice3.
// These have DIFFERENT vtable layouts from IDirect3D7/IDirect3DDevice7.
// See docs/DX_VTABLES.md for the authoritative reference.

const std = @import("std");
const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const kernel32 = @import("../kernel32.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const display_surface = @import("../display_surface.zig");
const rasterizer = @import("rasterizer.zig");
const state = @import("state.zig");

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
// 42 methods — see docs/DX_VTABLES.md for the reference

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
// 21 methods — see docs/DX_VTABLES.md

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

// ===== IDirect3DTexture2 =====

pub const IDirect3DTexture2 = extern struct {
    lpVtbl: *const IDirect3DTexture2Vtbl,
};

const IDirect3DTexture2Vtbl = extern struct {
    // IUnknown (0-2)
    QueryInterface: usize, // 0
    AddRef: usize, // 1
    Release: usize, // 2
    // IDirect3DTexture2 (3-5)
    GetHandle: *const fn (*IDirect3DTexture2, usize, *u32) callconv(w32cc.WINAPI) i32, // 3
    PaletteChanged: usize, // 4
    Load: usize, // 5
};

const MAX_TEXTURES = 64;
var texture_pool: [MAX_TEXTURES]IDirect3DTexture2 = undefined;
var texture_pool_count: u32 = 0;
var texture2_vtbl: IDirect3DTexture2Vtbl = undefined;

// ===== Instances =====

pub var global_d3d7: IDirect3D7 = undefined;
pub var global_d3d3: IDirect3D7 = undefined; // IDirect3D3-compatible vtable, same struct type
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

/// Allocate a texture object from the pool for QueryInterface.
pub fn allocTexture() *IDirect3DTexture2 {
    if (texture_pool_count < MAX_TEXTURES) {
        const idx = texture_pool_count;
        texture_pool[idx].lpVtbl = &texture2_vtbl;
        texture_pool_count += 1;
        return &texture_pool[idx];
    }
    // Out of pool — recycle last one
    return &texture_pool[MAX_TEXTURES - 1];
}

// Storage for viewport data — D3DVIEWPORT2 is 44 bytes
var viewport2_data: [44]u8 = @as([44]u8, @splat(0));
var viewport2_valid: bool = false;
// D3DVIEWPORT (legacy) is 44 bytes too
var viewport_data: [44]u8 = @as([44]u8, @splat(0));
var viewport_valid: bool = false;

// ===== Pipeline State Storage =====

/// Texture stage state: 8 stages × 32 state types.
const MAX_TEXTURE_STAGES = 8;
const MAX_TSS_STATES = 32;
var texture_stage_states: [MAX_TEXTURE_STAGES][MAX_TSS_STATES]u32 = @as([MAX_TEXTURE_STAGES][MAX_TSS_STATES]u32, @splat(@as([MAX_TSS_STATES]u32, @splat(0))));

/// Active texture handles per stage.
var texture_handles: [MAX_TEXTURE_STAGES]usize = @as([MAX_TEXTURE_STAGES]usize, @splat(0));

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
            @as(*u32, @ptrFromInt(lpData + 12)).* = display_surface.width; // dwWidth
            @as(*u32, @ptrFromInt(lpData + 16)).* = display_surface.height; // dwHeight
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
            @as(*u32, @ptrFromInt(lpData + 12)).* = display_surface.width; // dwWidth
            @as(*u32, @ptrFromInt(lpData + 16)).* = display_surface.height; // dwHeight
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
        var desc7: [544]u8 = @as([544]u8, @splat(0));
        @as(*align(1) u32, @ptrFromInt(@intFromPtr(&desc7))).* = 0x00017FF1; // dwDevCaps
        // ... fill dpcLineCaps, dpcTriCaps, etc.

        const device_desc_str = "Zine HAL Device\x00";
        const device_name_str = "HAL\x00";
        const result = cb(@intFromPtr(device_desc_str.ptr), @intFromPtr(device_name_str.ptr), @intFromPtr(&desc7), lpUserArg);
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
        // Layout verified from Wine d3dcaps.h — see docs/DX_VTABLES.md
        var hw_desc: [252]u8 = @as([252]u8, @splat(0));
        var hel_desc: [252]u8 = @as([252]u8, @splat(0));

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
        const result = cb(@intFromPtr(&hal_guid), @intFromPtr(device_desc_str.ptr), @intFromPtr(device_name_str.ptr), @intFromPtr(&hw_desc), @intFromPtr(&hel_desc), lpUserArg);
        if (trace.enable_tracing) trace.print("D3D7: EnumDevices callback returned {d}\n", .{result});
    }
    return w32.D3D_OK;
}

fn d3d7_CreateDevice(this: *IDirect3D7, rclsid: usize, lpDDS: usize, lplpD3DDevice: *?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = rclsid;
    _ = lpDDS;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D7::CreateDevice\n", .{});
    renderer.setResolution(display_surface.width, display_surface.height);
    lplpD3DDevice.* = @ptrCast(&global_d3d7_device);
    return w32.D3D_OK;
}

/// IDirect3D3::CreateDevice(this, rclsid, pDDS, ppDevice, pUnkOuter)
fn d3d3_CreateDevice(this: *IDirect3D7, rclsid: usize, lpDDS: usize, lplpD3DDevice: *?*anyopaque, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = rclsid;
    _ = lpDDS;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D3::CreateDevice\n", .{});
    renderer.setResolution(display_surface.width, display_surface.height);
    lplpD3DDevice.* = @ptrCast(&global_d3d3_device);
    // Signal that a paint is needed — so the next PeekMessageA returns WM_PAINT,
    // allowing the game's WndProc to initialize rendering now that the D3D device exists.
    const user32 = @import("../user32.zig");
    user32.needs_paint = true;
    return w32.D3D_OK;
}

fn d3d7_CreateVertexBuffer(this: *IDirect3D7, lpVBDesc: usize, lplpD3DVertexBuffer: *?*anyopaque, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = lpVBDesc;
    _ = dwFlags;
    if (trace.enable_tracing) trace.print("D3D7: CreateVertexBuffer\n", .{});
    lplpD3DVertexBuffer.* = @ptrFromInt(0xBEEF7000);
    return w32.D3D_OK;
}

fn d3d7_EnumZBufferFormats(this: *IDirect3D7, riidDevice: usize, lpEnumCallback: usize, lpContext: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = riidDevice;
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
    _ = this;
    _ = pUnk;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D3::CreateLight\n", .{});
    ppLight.* = @ptrCast(&global_light);
    return w32.D3D_OK;
}

fn d3d3_CreateMaterial(this: *IDirect3D7, ppMaterial: *?*anyopaque, pUnk: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = pUnk;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D3::CreateMaterial\n", .{});
    ppMaterial.* = @ptrCast(&global_material3);
    return w32.D3D_OK;
}

fn d3d3_CreateViewport(this: *IDirect3D7, ppViewport: *?*anyopaque, pUnk: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = pUnk;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D3::CreateViewport\n", .{});
    ppViewport.* = @ptrCast(&global_viewport3);
    return w32.D3D_OK;
}

fn d3d3_FindDevice(this: *IDirect3D7, pSearch: usize, pResult: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3D3::FindDevice(search=0x{x}, result=0x{x})\n", .{ pSearch, pResult });
    if (pResult != 0) {
        const hal_guid = [16]u8{ 0xE0, 0x3D, 0xE6, 0x84, 0xAA, 0x46, 0xCF, 0x11, 0x81, 0x6F, 0x00, 0x00, 0xC0, 0x20, 0x15, 0x6E };
        const dest = @as([*]u8, @ptrFromInt(pResult + 4));
        @memcpy(dest[0..16], &hal_guid);
    }
    return w32.D3D_OK;
}

// ===== IDirect3DTexture2 Implementation =====

fn texture2_GetHandle(this: *IDirect3DTexture2, hDevice: usize, lpHandle: *u32) callconv(w32cc.WINAPI) i32 {
    _ = hDevice;
    // Return a unique handle based on pool index (1-based, 0 = no texture)
    const base = @intFromPtr(&texture_pool[0]);
    const addr = @intFromPtr(this);
    const idx: u32 = if (addr >= base) @intCast((addr - base) / @sizeOf(IDirect3DTexture2)) else 0;
    lpHandle.* = idx + 1;
    if (trace.enable_tracing) trace.print("D3D7: IDirect3DTexture2::GetHandle -> {d}\n", .{idx + 1});
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
    display_surface.pushFrame();
    return w32.D3D_OK;
}

/// A DDPIXELFORMAT the enum callbacks see, in the masks the app expects.
const PixelFormat = struct { bpp: u32, r: u32, g: u32, b: u32, a: u32, flags: u32 };

fn enumTextureFormats(formats: []const PixelFormat, lpd3dEnumPixelProc: usize, lpArg: usize) void {
    if (lpd3dEnumPixelProc == 0) return;
    const cb = @as(*const fn (usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(lpd3dEnumPixelProc));
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

fn device3_EnumTextureFormats(this: usize, lpd3dEnumPixelProc: usize, lpArg: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D3Dev: EnumTextureFormats\n", .{});
    enumTextureFormats(&.{
        .{ .bpp = 16, .r = 0xF800, .g = 0x07E0, .b = 0x001F, .a = 0, .flags = 0x40 }, // RGB565
        .{ .bpp = 16, .r = 0x7C00, .g = 0x03E0, .b = 0x001F, .a = 0x8000, .flags = 0x41 }, // ARGB1555
        .{ .bpp = 32, .r = 0x00FF0000, .g = 0x0000FF00, .b = 0x000000FF, .a = 0xFF000000, .flags = 0x41 }, // ARGB8888
        .{ .bpp = 32, .r = 0x00FF0000, .g = 0x0000FF00, .b = 0x000000FF, .a = 0, .flags = 0x40 }, // XRGB8888
    }, lpd3dEnumPixelProc, lpArg);
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
    enumTextureFormats(&.{
        .{ .bpp = 16, .r = 0xF800, .g = 0x07E0, .b = 0x001F, .a = 0, .flags = 0x40 },
        .{ .bpp = 32, .r = 0x00FF0000, .g = 0x0000FF00, .b = 0x000000FF, .a = 0xFF000000, .flags = 0x41 },
        .{ .bpp = 32, .r = 0x00FF0000, .g = 0x0000FF00, .b = 0x000000FF, .a = 0, .flags = 0x40 },
    }, lpd3dEnumPixelProc, lpArg);
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
    display_surface.pushFrame();
    return w32.D3D_OK;
}

fn device7_Clear(this: *IDirect3DDevice7, dwCount: u32, lpRects: usize, dwFlags: u32, dwColor: u32, dvZ: f32, dwStencil: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = dwCount;
    _ = lpRects;
    _ = dwStencil;
    if (trace.enable_tracing) trace.print("D3D7: Clear(flags=0x{x}, color=0x{x:0>8}, z={d})\n", .{ dwFlags, dwColor, @as(u32, @bitCast(dvZ)) });

    const D3DCLEAR_TARGET: u32 = 0x1;
    const D3DCLEAR_ZBUFFER: u32 = 0x2;

    // Clear color buffer
    if (dwFlags & D3DCLEAR_TARGET != 0) {
        const vw = renderer.global_width;
        const vh = renderer.global_height;
        const pixels = vw * vh;

        if (display_surface.buffer.len >= pixels * 4) {
            const b: u8 = @intCast(dwColor & 0xFF);
            const g: u8 = @intCast((dwColor >> 8) & 0xFF);
            const r: u8 = @intCast((dwColor >> 16) & 0xFF);
            for (0..pixels) |i| {
                display_surface.buffer[i * 4 + 0] = b;
                display_surface.buffer[i * 4 + 1] = g;
                display_surface.buffer[i * 4 + 2] = r;
                display_surface.buffer[i * 4 + 3] = 255;
            }
        }
    }

    // Clear z-buffer
    if (dwFlags & D3DCLEAR_ZBUFFER != 0) {
        rasterizer.clearZBuffer(dvZ);
    }

    return w32.D3D_OK;
}

// Traced N-ary no-ops for D3D Device3 method tracing
fn tn1(comptime name: []const u8) *const fn (usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize) callconv(w32cc.WINAPI) usize {
            _ = a;
            if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{});
            return 0;
        }
    }.func;
}
fn tn2(comptime name: []const u8) *const fn (usize, usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
            _ = a;
            _ = b;
            if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{});
            return 0;
        }
    }.func;
}
fn tn3(comptime name: []const u8) *const fn (usize, usize, usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
            _ = a;
            _ = b;
            _ = c;
            if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{});
            return 0;
        }
    }.func;
}
fn tn4(comptime name: []const u8) *const fn (usize, usize, usize, usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
            _ = a;
            _ = b;
            _ = c;
            _ = d;
            if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{});
            return 0;
        }
    }.func;
}
fn tn6(comptime name: []const u8) *const fn (usize, usize, usize, usize, usize, usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize {
            _ = a;
            _ = b;
            _ = c;
            _ = d;
            _ = e;
            _ = f;
            if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{});
            return 0;
        }
    }.func;
}
fn tn8(comptime name: []const u8) *const fn (usize, usize, usize, usize, usize, usize, usize, usize) callconv(w32cc.WINAPI) usize {
    return &struct {
        fn func(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(w32cc.WINAPI) usize {
            _ = a;
            _ = b;
            _ = c;
            _ = d;
            _ = e;
            _ = f;
            _ = g;
            _ = h;
            if (trace.enable_tracing) trace.print("D3D3Dev: " ++ name ++ "\n", .{});
            return 0;
        }
    }.func;
}

// Typed no-ops (stdcall)
fn n1(a: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    return 0;
}
fn n2(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    return 0;
}
fn n3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    return 0;
}
fn n4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    return 0;
}
fn n5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    return 0;
}
fn n6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    return 0;
}
fn n7(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    return 0;
}
fn n8(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    _ = h;
    return 0;
}

/// ===== Pipeline State Implementations =====
/// SetTransform — shared implementation for Device3 (this, type, matrix) and Device7.
/// D3D3 Device3 slot 25: SetTransform(this, d3dts, lpD3DMatrix)
fn impl_SetTransform(this: usize, d3dts: usize, lpMatrix: usize) callconv(w32cc.WINAPI) usize {
    _ = this;
    if (d3dts < state.max_transforms and lpMatrix != 0) {
        const src = @as(*const [16]f32, @ptrFromInt(lpMatrix));
        state.transform_matrices[d3dts] = src.*;
        if (trace.enable_tracing) trace.print("D3D7: SetTransform(type={d})\\n", .{d3dts});
    }
    return 0; // D3D_OK
}

/// GetTransform — retrieves a stored transform matrix.
fn impl_GetTransform(this: usize, d3dts: usize, lpMatrix: usize) callconv(w32cc.WINAPI) usize {
    _ = this;
    if (d3dts < state.max_transforms and lpMatrix != 0) {
        const dst = @as(*[16]f32, @ptrFromInt(lpMatrix));
        dst.* = state.transform_matrices[d3dts];
        if (trace.enable_tracing) trace.print("D3D7: GetTransform(type={d})\\n", .{d3dts});
    }
    return 0;
}

/// MultiplyTransform — multiplies current matrix by new matrix: M[type] = M[type] × lpMatrix.
fn impl_MultiplyTransform(this: usize, d3dts: usize, lpMatrix: usize) callconv(w32cc.WINAPI) usize {
    _ = this;
    if (d3dts < state.max_transforms and lpMatrix != 0) {
        const m = @as(*const [16]f32, @ptrFromInt(lpMatrix));
        state.transform_matrices[d3dts] = state.mat4x4Multiply(state.transform_matrices[d3dts], m.*);
        if (trace.enable_tracing) trace.print("D3D7: MultiplyTransform(type={d})\\n", .{d3dts});
    }
    return 0;
}

/// SetRenderState — stores a render state value.
fn impl_SetRenderState(this: usize, dwState: usize, dwValue: usize) callconv(w32cc.WINAPI) usize {
    _ = this;

    if (dwState < state.max_render_states) {
        state.render_states[dwState] = @truncate(dwValue);
        if (trace.enable_tracing) trace.print("D3D7: SetRenderState({d} = 0x{x})\\n", .{ dwState, dwValue });
    }
    return 0;
}

/// GetRenderState — retrieves a stored render state.
fn impl_GetRenderState(this: usize, dwState: usize, lpdwValue: usize) callconv(w32cc.WINAPI) usize {
    _ = this;

    if (dwState < state.max_render_states and lpdwValue != 0) {
        @as(*u32, @ptrFromInt(lpdwValue)).* = state.render_states[dwState];
    }
    return 0;
}

/// SetTexture — binds a texture handle to a stage.
fn impl_SetTexture(this: usize, dwStage: usize, lpTexture: usize) callconv(w32cc.WINAPI) usize {
    _ = this;
    if (dwStage < MAX_TEXTURE_STAGES) {
        texture_handles[dwStage] = lpTexture;
        if (trace.enable_tracing) trace.print("D3D7: SetTexture(stage={d}, tex=0x{x})\\n", .{ dwStage, lpTexture });
    }
    return 0;
}

/// SetTextureStageState — stores a texture stage state value.
fn impl_SetTextureStageState(this: usize, dwStage: usize, dwState: usize, dwValue: usize) callconv(w32cc.WINAPI) usize {
    _ = this;
    if (dwStage < MAX_TEXTURE_STAGES and dwState < MAX_TSS_STATES) {
        texture_stage_states[dwStage][dwState] = @truncate(dwValue);
        if (trace.enable_tracing) trace.print("D3D7: SetTextureStageState(stage={d}, state={d}, val=0x{x})\\n", .{ dwStage, dwState, dwValue });
    }
    return 0;
}

/// GetTextureStageState — retrieves a stored texture stage state.
fn impl_GetTextureStageState(this: usize, dwStage: usize, dwState: usize, lpdwValue: usize) callconv(w32cc.WINAPI) usize {
    _ = this;
    if (dwStage < MAX_TEXTURE_STAGES and dwState < MAX_TSS_STATES and lpdwValue != 0) {
        @as(*u32, @ptrFromInt(lpdwValue)).* = texture_stage_states[dwStage][dwState];
    }
    return 0;
}

/// ===== Registration =====
/// Implementation status: Partially implemented
pub fn init() void {
    const comPtr = @import("../../x86/thunks.zig").comPtr;

    const N1 = comPtr(n1, "IDirect3DDevice7::noop1");
    const N2 = comPtr(n2, "IDirect3DDevice7::noop2");
    const N3 = comPtr(n3, "IDirect3DDevice7::noop3");
    const N4 = comPtr(n4, "IDirect3DDevice7::noop4");
    const N6 = comPtr(n6, "IDirect3DDevice7::noop6");
    const N7 = comPtr(n7, "IDirect3DDevice7::noop7");
    const N8 = comPtr(n8, "IDirect3DDevice7::noop8");

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
        .QueryInterface = comPtr(tn3("QueryInterface").*, "IDirect3DDevice3::QueryInterface"), // 0
        .AddRef = comPtr(tn1("AddRef").*, "IDirect3DDevice3::AddRef"), // 1
        .Release = comPtr(tn1("Release").*, "IDirect3DDevice3::Release"), // 2
        .GetCaps = comPtr(tn3("GetCaps").*, "IDirect3DDevice3::GetCaps"), // 3
        .GetStats = comPtr(tn2("GetStats").*, "IDirect3DDevice3::GetStats"), // 4
        .AddViewport = comPtr(tn2("AddViewport").*, "IDirect3DDevice3::AddViewport"), // 5
        .DeleteViewport = comPtr(tn2("DeleteViewport").*, "IDirect3DDevice3::DeleteViewport"), // 6
        .NextViewport = comPtr(tn4("NextViewport").*, "IDirect3DDevice3::NextViewport"), // 7
        .EnumTextureFormats = comPtr(device3_EnumTextureFormats, "IDirect3DDevice3::EnumTextureFormats"), // 8
        .BeginScene = device3_BeginScene, // 9
        .EndScene = device3_EndScene, // 10
        .GetDirect3D = comPtr(tn2("GetDirect3D").*, "IDirect3DDevice3::GetDirect3D"), // 11
        .SetCurrentViewport = comPtr(tn2("SetCurrentViewport").*, "IDirect3DDevice3::SetCurrentViewport"), // 12
        .GetCurrentViewport = comPtr(tn2("GetCurrentViewport").*, "IDirect3DDevice3::GetCurrentViewport"), // 13
        .SetRenderTarget = comPtr(tn3("SetRenderTarget").*, "IDirect3DDevice3::SetRenderTarget"), // 14
        .GetRenderTarget = comPtr(tn2("GetRenderTarget").*, "IDirect3DDevice3::GetRenderTarget"), // 15
        .Begin = comPtr(tn4("Begin").*, "IDirect3DDevice3::Begin"), // 16
        .BeginIndexed = comPtr(tn6("BeginIndexed").*, "IDirect3DDevice3::BeginIndexed"), // 17
        .Vertex = comPtr(tn2("Vertex").*, "IDirect3DDevice3::Vertex"), // 18
        .Index = comPtr(tn2("Index").*, "IDirect3DDevice3::Index"), // 19
        .End = comPtr(tn2("End").*, "IDirect3DDevice3::End"), // 20
        .GetRenderState = comPtr(impl_GetRenderState, "IDirect3DDevice3::GetRenderState"), // 21
        .SetRenderState = comPtr(impl_SetRenderState, "IDirect3DDevice3::SetRenderState"), // 22
        .GetLightState = comPtr(tn3("GetLightState").*, "IDirect3DDevice3::GetLightState"), // 23
        .SetLightState = comPtr(tn3("SetLightState").*, "IDirect3DDevice3::SetLightState"), // 24
        .SetTransform = comPtr(impl_SetTransform, "IDirect3DDevice3::SetTransform"), // 25
        .GetTransform = comPtr(impl_GetTransform, "IDirect3DDevice3::GetTransform"), // 26
        .MultiplyTransform = comPtr(impl_MultiplyTransform, "IDirect3DDevice3::MultiplyTransform"), // 27
        .DrawPrimitive = comPtr(rasterizer.impl_DrawPrimitive, "IDirect3DDevice3::DrawPrimitive"), // 28
        .DrawIndexedPrimitive = comPtr(rasterizer.impl_DrawIndexedPrimitive, "IDirect3DDevice3::DrawIndexedPrimitive"), // 29
        .SetClipStatus = comPtr(tn2("SetClipStatus").*, "IDirect3DDevice3::SetClipStatus"), // 30
        .GetClipStatus = comPtr(tn2("GetClipStatus").*, "IDirect3DDevice3::GetClipStatus"), // 31
        .DrawPrimitiveStrided = comPtr(tn6("DrawPrimitiveStrided").*, "IDirect3DDevice3::DrawPrimitiveStrided"), // 32
        .DrawIndexedPrimitiveStrided = comPtr(tn8("DrawIndexedPrimitiveStrided").*, "IDirect3DDevice3::DrawIndexedPrimitiveStrided"), // 33
        .DrawPrimitiveVB = comPtr(tn6("DrawPrimitiveVB").*, "IDirect3DDevice3::DrawPrimitiveVB"), // 34
        .DrawIndexedPrimitiveVB = comPtr(tn6("DrawIndexedPrimitiveVB").*, "IDirect3DDevice3::DrawIndexedPrimitiveVB"), // 35
        .ComputeSphereVisibility = comPtr(tn6("ComputeSphereVisibility").*, "IDirect3DDevice3::ComputeSphereVisibility"), // 36
        .GetTexture = comPtr(tn3("GetTexture").*, "IDirect3DDevice3::GetTexture"), // 37
        .SetTexture = comPtr(impl_SetTexture, "IDirect3DDevice3::SetTexture"), // 38
        .GetTextureStageState = comPtr(impl_GetTextureStageState, "IDirect3DDevice3::GetTextureStageState"), // 39
        .SetTextureStageState = comPtr(impl_SetTextureStageState, "IDirect3DDevice3::SetTextureStageState"), // 40
        .ValidateDevice = comPtr(tn2("ValidateDevice").*, "IDirect3DDevice3::ValidateDevice"), // 41
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
        .SetTransform = comPtr(impl_SetTransform, "IDirect3DDevice7::SetTransform"),
        .GetTransform = comPtr(impl_GetTransform, "IDirect3DDevice7::GetTransform"),
        .SetViewport = N2,
        .MultiplyTransform = comPtr(impl_MultiplyTransform, "IDirect3DDevice7::MultiplyTransform"),
        .GetViewport = N2,
        .SetMaterial = N2,
        .GetMaterial = N2,
        .SetLight = N3,
        .GetLight = N3,
        .SetRenderState = comPtr(impl_SetRenderState, "IDirect3DDevice7::SetRenderState"),
        .GetRenderState = comPtr(impl_GetRenderState, "IDirect3DDevice7::GetRenderState"),
        .BeginStateBlock = N1,
        .EndStateBlock = N2,
        .PreLoad = N2,
        .DrawPrimitive = comPtr(rasterizer.impl_DrawPrimitive, "IDirect3DDevice7::DrawPrimitive"),
        .DrawIndexedPrimitive = comPtr(rasterizer.impl_DrawIndexedPrimitive, "IDirect3DDevice7::DrawIndexedPrimitive"),
        .SetClipStatus = N2,
        .GetClipStatus = N2,
        .DrawPrimitiveStrided = N6,
        .DrawIndexedPrimitiveStrided = N8,
        .DrawPrimitiveVB = N6,
        .DrawIndexedPrimitiveVB = N8,
        .ComputeSphereVisibility = N6,
        .GetTexture = N3,
        .SetTexture = comPtr(impl_SetTexture, "IDirect3DDevice7::SetTexture"),
        .GetTextureStageState = comPtr(impl_GetTextureStageState, "IDirect3DDevice7::GetTextureStageState"),
        .SetTextureStageState = comPtr(impl_SetTextureStageState, "IDirect3DDevice7::SetTextureStageState"),
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
        .AddRef = N1, // 1
        .Release = N1, // 2
        .Initialize = N2, // 3
        .GetViewport = comPtr(vp_GetViewport, "IDirect3DViewport3::GetViewport"), // 4
        .SetViewport = comPtr(vp_SetViewport, "IDirect3DViewport3::SetViewport"), // 5
        .TransformVertices = N4, // 6
        .LightElements = N3, // 7
        .SetBackground = N2, // 8
        .GetBackground = N3, // 9
        .SetBackgroundDepth = N2, // 10
        .GetBackgroundDepth = N3, // 11
        .Clear = N4, // 12: this, count, rects, flags
        .AddLight = N2, // 13
        .DeleteLight = N2, // 14
        .NextLight = N4, // 15
        .GetViewport2 = comPtr(vp_GetViewport2, "IDirect3DViewport3::GetViewport2"), // 16
        .SetViewport2 = comPtr(vp_SetViewport2, "IDirect3DViewport3::SetViewport2"), // 17
        .SetBackgroundDepth2 = N2, // 18
        .GetBackgroundDepth2 = N3, // 19
        .Clear2 = N7, // 20: this, count, rects, flags, color, z, stencil
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

    // IDirect3DTexture2 vtable — 6 methods
    texture2_vtbl = .{
        .QueryInterface = N3,
        .AddRef = N1,
        .Release = N1,
        .GetHandle = texture2_GetHandle,
        .PaletteChanged = N2,
        .Load = N3,
    };

    global_d3d7.lpVtbl = &d3d7_vtbl;
    global_d3d3.lpVtbl = @ptrCast(&d3d3_vtbl);
    global_d3d7_device.lpVtbl = &device7_vtbl;
    global_d3d3_device.lpVtbl = &device3_vtbl;
    global_viewport3.lpVtbl = &viewport3_vtbl;
    global_material3.lpVtbl = &material3_vtbl;
    global_light.lpVtbl = &light_vtbl;
}

/// Implementation status: Partially implemented
pub fn registerVtables(environment: anytype) void {
    environment.addBuiltinVtableComptime(IDirect3D7Vtbl, &d3d7_vtbl);
    environment.addBuiltinVtableComptime(IDirect3D3Vtbl, &d3d3_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DDevice7Vtbl, &device7_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DDevice3Vtbl, &device3_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DViewport3Vtbl, &viewport3_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DMaterial3Vtbl, &material3_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DLightVtbl, &light_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DTexture2Vtbl, &texture2_vtbl);
}
