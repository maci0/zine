const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const renderer = @import("../gui/renderer.zig");
const kernel32 = @import("kernel32.zig");
const w32 = @import("constants.zig");
const w32cc = @import("calling_convention.zig");

// --- IDirect3D8 COM Interface ---

const IDirect3D8 = extern struct {
    lpVtbl: *const IDirect3D8Vtbl,
};

const IDirect3D8Vtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*IDirect3D8, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32, // 0
    AddRef: *const fn (*IDirect3D8) callconv(w32cc.WINAPI) u32, // 1
    Release: *const fn (*IDirect3D8) callconv(w32cc.WINAPI) u32, // 2
    // IDirect3D8
    RegisterSoftwareDevice: usize, // 3
    GetAdapterCount: *const fn (*IDirect3D8) callconv(w32cc.WINAPI) u32, // 4
    GetAdapterIdentifier: *const fn (*IDirect3D8, u32, u32, usize) callconv(w32cc.WINAPI) i32, // 5
    GetAdapterModeCount: *const fn (*IDirect3D8, u32) callconv(w32cc.WINAPI) u32, // 6
    EnumAdapterModes: *const fn (*IDirect3D8, u32, u32, usize) callconv(w32cc.WINAPI) i32, // 7
    GetAdapterDisplayMode: *const fn (*IDirect3D8, u32, usize) callconv(w32cc.WINAPI) i32, // 8
    CheckDeviceType: *const fn (*IDirect3D8, u32, u32, u32, u32, i32) callconv(w32cc.WINAPI) i32, // 9
    CheckDeviceFormat: *const fn (*IDirect3D8, u32, u32, u32, u32, u32, u32) callconv(w32cc.WINAPI) i32, // 10
    CheckDeviceMultiSampleType: *const fn (*IDirect3D8, u32, u32, u32, i32, usize) callconv(w32cc.WINAPI) i32, // 11
    CheckDepthStencilMatch: *const fn (*IDirect3D8, u32, u32, u32, u32, u32) callconv(w32cc.WINAPI) i32, // 12
    GetDeviceCaps: *const fn (*IDirect3D8, u32, u32, usize) callconv(w32cc.WINAPI) i32, // 13
    GetAdapterMonitor: *const fn (*IDirect3D8, u32) callconv(w32cc.WINAPI) usize, // 14
    CreateDevice: *const fn (*IDirect3D8, u32, u32, usize, u32, usize, *?*IDirect3DDevice8) callconv(w32cc.WINAPI) i32, // 15
};

// --- IDirect3DDevice8 COM Interface ---

const IDirect3DDevice8 = extern struct {
    lpVtbl: *const IDirect3DDevice8Vtbl,
};

// IDirect3DDevice8 has 97 methods (0-96)
// We only implement the ones needed
const IDirect3DDevice8Vtbl = extern struct {
    // IUnknown
    QueryInterface: usize, // 0
    AddRef: usize, // 1
    Release: *const fn (*IDirect3DDevice8) callconv(w32cc.WINAPI) u32, // 2
    // IDirect3DDevice8
    TestCooperativeLevel: *const fn (*IDirect3DDevice8) callconv(w32cc.WINAPI) i32, // 3
    GetAvailableTextureMem: *const fn (*IDirect3DDevice8) callconv(w32cc.WINAPI) u32, // 4
    ResourceManagerDiscardBytes: usize, // 5
    GetDirect3D: usize, // 6
    GetDeviceCaps: *const fn (*IDirect3DDevice8, usize) callconv(w32cc.WINAPI) i32, // 7
    GetDisplayMode: *const fn (*IDirect3DDevice8, usize) callconv(w32cc.WINAPI) i32, // 8
    GetCreationParameters: usize, // 9
    SetCursorProperties: usize, // 10
    SetCursorPosition: usize, // 11
    ShowCursor: usize, // 12
    CreateAdditionalSwapChain: usize, // 13
    Reset: *const fn (*IDirect3DDevice8, usize) callconv(w32cc.WINAPI) i32, // 14
    Present: *const fn (*IDirect3DDevice8, usize, usize, usize, usize) callconv(w32cc.WINAPI) i32, // 15
    GetBackBuffer: usize, // 16
    GetRasterStatus: usize, // 17
    SetGammaRamp: usize, // 18
    GetGammaRamp: usize, // 19
    CreateTexture: usize, // 20
    CreateVolumeTexture: usize, // 21
    CreateCubeTexture: usize, // 22
    CreateVertexBuffer: usize, // 23
    CreateIndexBuffer: usize, // 24
    CreateRenderTarget: usize, // 25
    CreateDepthStencilSurface: usize, // 26
    CreateImageSurface: usize, // 27
    CopyRects: usize, // 28
    UpdateTexture: usize, // 29
    GetFrontBuffer: usize, // 30
    SetRenderTarget: usize, // 31
    GetRenderTarget: usize, // 32
    GetDepthStencilSurface: usize, // 33
    BeginScene: *const fn (*IDirect3DDevice8) callconv(w32cc.WINAPI) i32, // 34
    EndScene: *const fn (*IDirect3DDevice8) callconv(w32cc.WINAPI) i32, // 35
    Clear: *const fn (*IDirect3DDevice8, u32, usize, u32, u32, f32, u32) callconv(w32cc.WINAPI) i32, // 36
    SetTransform: usize, // 37
    GetTransform: usize, // 38
    MultiplyTransform: usize, // 39
    SetViewport: *const fn (*IDirect3DDevice8, usize) callconv(w32cc.WINAPI) i32, // 40
    GetViewport: *const fn (*IDirect3DDevice8, usize) callconv(w32cc.WINAPI) i32, // 41
    SetMaterial: usize, // 42
    GetMaterial: usize, // 43
    SetLight: usize, // 44
    GetLight: usize, // 45
    LightEnable: usize, // 46
    GetLightEnable: usize, // 47
    SetClipPlane: usize, // 48
    GetClipPlane: usize, // 49
    SetRenderState: *const fn (*IDirect3DDevice8, u32, u32) callconv(w32cc.WINAPI) i32, // 50
    GetRenderState: usize, // 51
    BeginStateBlock: usize, // 52
    EndStateBlock: usize, // 53
    ApplyStateBlock: usize, // 54
    CaptureStateBlock: usize, // 55
    DeleteStateBlock: usize, // 56
    CreateStateBlock: usize, // 57
    SetClipStatus: usize, // 58
    GetClipStatus: usize, // 59
    GetTexture: usize, // 60
    SetTexture: usize, // 61
    GetTextureStageState: usize, // 62
    SetTextureStageState: usize, // 63
    ValidateDevice: usize, // 64
    GetInfo: usize, // 65
    SetPaletteEntries: usize, // 66
    GetPaletteEntries: usize, // 67
    SetCurrentTexturePalette: usize, // 68
    GetCurrentTexturePalette: usize, // 69
    DrawPrimitive: usize, // 70
    DrawIndexedPrimitive: usize, // 71
    DrawPrimitiveUP: usize, // 72
    DrawIndexedPrimitiveUP: usize, // 73
    ProcessVertices: usize, // 74
    CreateVertexShader: usize, // 75
    SetVertexShader: usize, // 76
    GetVertexShader: usize, // 77
    DeleteVertexShader: usize, // 78
    SetVertexShaderConstant: usize, // 79
    GetVertexShaderConstant: usize, // 80
    GetVertexShaderDeclaration: usize, // 81
    GetVertexShaderFunction: usize, // 82
    SetStreamSource: usize, // 83
    GetStreamSource: usize, // 84
    SetIndices: usize, // 85
    GetIndices: usize, // 86
    CreatePixelShader: usize, // 87
    SetPixelShader: usize, // 88
    GetPixelShader: usize, // 89
    DeletePixelShader: usize, // 90
    SetPixelShaderConstant: usize, // 91
    GetPixelShaderConstant: usize, // 92
    DrawRectPatch: usize, // 93
    DrawTriPatch: usize, // 94
    DeletePatch: usize, // 95
    CreateQuery: usize, // 96 -- D3D9 only, padded to keep the slot
};

// --- Generic D3D8 Resource (fake texture/surface/VB/IB) ---
// A minimal COM object with a large vtable full of typed noops.
// Used for CreateTexture, CreateVertexBuffer, etc. — app just needs a non-NULL handle.

const D3D8Resource = extern struct {
    lpVtbl: *const [64]usize, // large enough for any D3D8 sub-object vtable
};

var resource_vtbl: [64]usize = undefined;
var global_resources: [32]D3D8Resource = undefined;
var next_resource: usize = 0;

fn allocResource() *D3D8Resource {
    const idx = next_resource % global_resources.len;
    next_resource += 1;
    global_resources[idx].lpVtbl = &resource_vtbl;
    return &global_resources[idx];
}

// --- Instances ---

var global_d3d8: IDirect3D8 = undefined;
var global_d3d8_device: IDirect3DDevice8 = undefined;

var d3d8_vtbl: IDirect3D8Vtbl = undefined;
var device_vtbl: IDirect3DDevice8Vtbl = undefined;

// --- IDirect3D8 Implementations ---

fn d3d8_QueryInterface(this: *IDirect3D8, riid: usize, ppvObj: *?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = riid;
    ppvObj.* = @ptrCast(this);
    return w32.S_OK;
}

fn d3d8_AddRef(this: *IDirect3D8) callconv(w32cc.WINAPI) u32 {
    _ = this;
    return 1;
}

fn d3d8_Release(this: *IDirect3D8) callconv(w32cc.WINAPI) u32 {
    _ = this;
    return 0;
}

fn d3d8_GetAdapterCount(this: *IDirect3D8) callconv(w32cc.WINAPI) u32 {
    _ = this;
    if (trace.enable_tracing) trace.print("D3D8: IDirect3D8::GetAdapterCount -> 1\n", .{});
    return 1;
}

fn d3d8_GetAdapterIdentifier(this: *IDirect3D8, Adapter: u32, Flags: u32, pIdentifier: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Adapter;
    _ = Flags;
    if (trace.enable_tracing) trace.print("D3D8: IDirect3D8::GetAdapterIdentifier\n", .{});
    if (pIdentifier != 0) {
        // D3DADAPTER_IDENTIFIER8: Driver[512], Description[512], ...
        const buf = @as([*]u8, @ptrFromInt(pIdentifier));
        @memset(buf[0 .. 1024 + 48], 0);
        const driver = "Zine Virtual GPU";
        @memcpy(buf[0..driver.len], driver);
        const desc = "Zine D3D8 Emulation";
        @memcpy(buf[512 .. 512 + desc.len], desc);
    }
    return w32.D3D_OK;
}

fn d3d8_GetAdapterModeCount(this: *IDirect3D8, Adapter: u32) callconv(w32cc.WINAPI) u32 {
    _ = this;
    _ = Adapter;
    if (trace.enable_tracing) trace.print("D3D8: IDirect3D8::GetAdapterModeCount -> 3\n", .{});
    return 3; // 640x480, 800x600, 1024x768
}

fn d3d8_EnumAdapterModes(this: *IDirect3D8, Adapter: u32, Mode: u32, pMode: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Adapter;
    if (trace.enable_tracing) trace.print("D3D8: IDirect3D8::EnumAdapterModes(mode={d})\n", .{Mode});
    if (pMode == 0) return @as(i32, @bitCast(w32.D3DERR_INVALIDCALL));
    const mode = @as(*w32.D3DDISPLAYMODE, @ptrFromInt(pMode));
    switch (Mode) {
        0 => {
            mode.Width = 640;
            mode.Height = 480;
            mode.RefreshRate = 60;
            mode.Format = w32.D3DFMT_X8R8G8B8;
        },
        1 => {
            mode.Width = 800;
            mode.Height = 600;
            mode.RefreshRate = 60;
            mode.Format = w32.D3DFMT_X8R8G8B8;
        },
        2 => {
            mode.Width = 1024;
            mode.Height = 768;
            mode.RefreshRate = 60;
            mode.Format = w32.D3DFMT_X8R8G8B8;
        },
        else => return @as(i32, @bitCast(w32.D3DERR_INVALIDCALL)),
    }
    return w32.D3D_OK;
}

fn d3d8_GetAdapterDisplayMode(this: *IDirect3D8, Adapter: u32, pMode: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Adapter;
    if (trace.enable_tracing) trace.print("D3D8: IDirect3D8::GetAdapterDisplayMode\n", .{});
    if (pMode != 0) {
        const mode = @as(*w32.D3DDISPLAYMODE, @ptrFromInt(pMode));
        mode.Width = 800;
        mode.Height = 600;
        mode.RefreshRate = 60;
        mode.Format = w32.D3DFMT_X8R8G8B8;
    }
    return w32.D3D_OK;
}

fn d3d8_CheckDeviceType(this: *IDirect3D8, Adapter: u32, CheckType: u32, DisplayFormat: u32, BackBufferFormat: u32, Windowed: i32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Adapter;
    _ = CheckType;
    _ = DisplayFormat;
    _ = BackBufferFormat;
    _ = Windowed;
    return w32.D3D_OK;
}

fn d3d8_CheckDeviceFormat(this: *IDirect3D8, Adapter: u32, DeviceType: u32, AdapterFormat: u32, Usage: u32, RType: u32, CheckFormat: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Adapter;
    _ = DeviceType;
    _ = AdapterFormat;
    _ = Usage;
    _ = RType;
    _ = CheckFormat;
    return w32.D3D_OK;
}

fn d3d8_CheckDeviceMultiSampleType(this: *IDirect3D8, Adapter: u32, DeviceType: u32, SurfaceFormat: u32, Windowed: i32, MultiSampleType: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Adapter;
    _ = DeviceType;
    _ = SurfaceFormat;
    _ = Windowed;
    _ = MultiSampleType;
    return w32.D3D_OK;
}

fn d3d8_CheckDepthStencilMatch(this: *IDirect3D8, Adapter: u32, DeviceType: u32, AdapterFormat: u32, RenderTargetFormat: u32, DepthStencilFormat: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Adapter;
    _ = DeviceType;
    _ = AdapterFormat;
    _ = RenderTargetFormat;
    _ = DepthStencilFormat;
    return w32.D3D_OK;
}

fn d3d8_GetDeviceCaps(this: *IDirect3D8, Adapter: u32, DeviceType: u32, pCaps: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Adapter;
    _ = DeviceType;
    if (trace.enable_tracing) trace.print("D3D8: IDirect3D8::GetDeviceCaps\n", .{});
    if (pCaps != 0) {
        fillD3D8Caps(pCaps);
    }
    return w32.D3D_OK;
}

/// Fill D3DCAPS8 (304 bytes) with plausible hardware-accelerated device caps
fn fillD3D8Caps(pCaps: usize) void {
    const caps = @as([*]u8, @ptrFromInt(pCaps));
    @memset(caps[0..304], 0);

    // D3DCAPS8 layout (offsets in bytes):
    //   0: DeviceType (4)
    //   4: AdapterOrdinal (4)
    //   8: Caps (4)
    //  12: Caps2 (4)
    //  16: Caps3 (4)
    //  20: PresentationIntervals (4)
    //  24: CursorCaps (4)
    //  28: DevCaps (4)
    //  32: PrimitiveMiscCaps (4)
    //  36: RasterCaps (4)
    //  40: ZCmpCaps (4)
    //  44: SrcBlendCaps (4)
    //  48: DestBlendCaps (4)
    //  52: AlphaCmpCaps (4)
    //  56: ShadeCaps (4)
    //  60: TextureCaps (4)
    //  64: TextureFilterCaps (4)
    //  68: CubeTextureFilterCaps (4)
    //  72: VolumeTextureFilterCaps (4)
    //  76: TextureAddressCaps (4)
    //  80: VolumeTextureAddressCaps (4)
    //  84: LineCaps (4)
    //  88: MaxTextureWidth (4)
    //  92: MaxTextureHeight (4)
    //  96: MaxVolumeExtent (4)
    // 100: MaxTextureRepeat (4)
    // 104: MaxTextureAspectRatio (4)
    // 108: MaxAnisotropy (4)
    // 112: MaxVertexW (4, float)
    // 116: GuardBandLeft (4, float)
    // 120: GuardBandTop (4, float)
    // 124: GuardBandRight (4, float)
    // 128: GuardBandBottom (4, float)
    // 132: ExtentsAdjust (4, float)
    // 136: StencilCaps (4)
    // 140: FVFCaps (4)
    // 144: TextureOpCaps (4)
    // 148: MaxTextureBlendStages (4)
    // 152: MaxSimultaneousTextures (4)
    // 156: VertexProcessingCaps (4)
    // 160: MaxActiveLights (4)
    // 164: MaxUserClipPlanes (4)
    // 168: MaxVertexBlendMatrices (4)
    // 172: MaxVertexBlendMatrixIndex (4)
    // 176: MaxPointSize (4, float)
    // 180: MaxPrimitiveCount (4)
    // 184: MaxVertexIndex (4)
    // 188: MaxStreams (4)
    // 192: MaxStreamStride (4)
    // 196: VertexShaderVersion (4)
    // 200: MaxVertexShaderConst (4)
    // 204: PixelShaderVersion (4)
    // 208: MaxPixelShaderValue (4, float)

    @as(*align(1) u32, @ptrFromInt(pCaps + 0)).* = w32.D3DDEVTYPE_HAL; // DeviceType
    @as(*align(1) u32, @ptrFromInt(pCaps + 4)).* = 0; // AdapterOrdinal
    @as(*align(1) u32, @ptrFromInt(pCaps + 8)).* = 0x00020000; // Caps: D3DCAPS_READ_SCANLINE
    @as(*align(1) u32, @ptrFromInt(pCaps + 12)).* = 0x00080000; // Caps2: D3DCAPS2_CANRENDERWINDOWED
    @as(*align(1) u32, @ptrFromInt(pCaps + 20)).* = 0x00000001; // PresentationIntervals: D3DPRESENT_INTERVAL_ONE
    @as(*align(1) u32, @ptrFromInt(pCaps + 28)).* = 0x001BBEF0; // DevCaps: HAL capabilities
    @as(*align(1) u32, @ptrFromInt(pCaps + 32)).* = 0x000000B2; // PrimitiveMiscCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 36)).* = 0x07672191; // RasterCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 40)).* = 0xFF; // ZCmpCaps: all compare funcs
    @as(*align(1) u32, @ptrFromInt(pCaps + 44)).* = 0x1FFF; // SrcBlendCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 48)).* = 0x1FFF; // DestBlendCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 52)).* = 0xFF; // AlphaCmpCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 56)).* = 0x0207000E; // ShadeCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 60)).* = 0x0001FC01; // TextureCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 64)).* = 0x07030700; // TextureFilterCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 76)).* = 0x3F; // TextureAddressCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 84)).* = 0x1F; // LineCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 88)).* = 2048; // MaxTextureWidth
    @as(*align(1) u32, @ptrFromInt(pCaps + 92)).* = 2048; // MaxTextureHeight
    @as(*align(1) u32, @ptrFromInt(pCaps + 96)).* = 256; // MaxVolumeExtent
    @as(*align(1) u32, @ptrFromInt(pCaps + 100)).* = 8192; // MaxTextureRepeat
    @as(*align(1) u32, @ptrFromInt(pCaps + 104)).* = 2048; // MaxTextureAspectRatio
    @as(*align(1) u32, @ptrFromInt(pCaps + 108)).* = 16; // MaxAnisotropy
    @as(*align(1) f32, @ptrFromInt(pCaps + 112)).* = 1.0e10; // MaxVertexW
    @as(*align(1) u32, @ptrFromInt(pCaps + 136)).* = 0xFF; // StencilCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 140)).* = 0x000F0008; // FVFCaps: 8 texcoords
    @as(*align(1) u32, @ptrFromInt(pCaps + 144)).* = 0x03FFFFFF; // TextureOpCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 148)).* = 8; // MaxTextureBlendStages
    @as(*align(1) u32, @ptrFromInt(pCaps + 152)).* = 8; // MaxSimultaneousTextures
    @as(*align(1) u32, @ptrFromInt(pCaps + 156)).* = 0x0000013F; // VertexProcessingCaps
    @as(*align(1) u32, @ptrFromInt(pCaps + 160)).* = 8; // MaxActiveLights
    @as(*align(1) u32, @ptrFromInt(pCaps + 164)).* = 6; // MaxUserClipPlanes
    @as(*align(1) u32, @ptrFromInt(pCaps + 168)).* = 4; // MaxVertexBlendMatrices
    @as(*align(1) u32, @ptrFromInt(pCaps + 172)).* = 0; // MaxVertexBlendMatrixIndex
    @as(*align(1) f32, @ptrFromInt(pCaps + 176)).* = 256.0; // MaxPointSize
    @as(*align(1) u32, @ptrFromInt(pCaps + 180)).* = 0x000FFFFF; // MaxPrimitiveCount
    @as(*align(1) u32, @ptrFromInt(pCaps + 184)).* = 0x000FFFFF; // MaxVertexIndex
    @as(*align(1) u32, @ptrFromInt(pCaps + 188)).* = 16; // MaxStreams
    @as(*align(1) u32, @ptrFromInt(pCaps + 192)).* = 256; // MaxStreamStride
    @as(*align(1) u32, @ptrFromInt(pCaps + 196)).* = 0; // VertexShaderVersion (0=fixed function)
    @as(*align(1) u32, @ptrFromInt(pCaps + 200)).* = 96; // MaxVertexShaderConst
    @as(*align(1) u32, @ptrFromInt(pCaps + 204)).* = 0; // PixelShaderVersion (0=fixed function)
    @as(*align(1) f32, @ptrFromInt(pCaps + 208)).* = 1.0; // MaxPixelShaderValue
}

fn d3d8_GetAdapterMonitor(this: *IDirect3D8, Adapter: u32) callconv(w32cc.WINAPI) usize {
    _ = this;
    _ = Adapter;
    return 0xBEEF0020; // Fake HMONITOR
}

var surface_buffer: []u8 = &[_]u8{};

fn d3d8_CreateDevice(this: *IDirect3D8, Adapter: u32, DeviceType: u32, hFocusWindow: usize, BehaviorFlags: u32, pPresentationParameters: usize, ppReturnedDeviceInterface: *?*IDirect3DDevice8) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Adapter;
    _ = DeviceType;
    _ = hFocusWindow;
    _ = BehaviorFlags;
    if (trace.enable_tracing) trace.print("D3D8: IDirect3D8::CreateDevice\n", .{});

    // Read presentation parameters for resolution
    if (pPresentationParameters != 0) {
        const pp = @as(*const w32.D3DPRESENT_PARAMETERS, @ptrFromInt(pPresentationParameters));
        if (pp.BackBufferWidth > 0 and pp.BackBufferHeight > 0) {
            renderer.setResolution(pp.BackBufferWidth, pp.BackBufferHeight);
            if (trace.enable_tracing) trace.print("D3D8: CreateDevice resolution: {d}x{d}\n", .{ pp.BackBufferWidth, pp.BackBufferHeight });
        }
    }

    // Allocate surface buffer
    if (surface_buffer.len == 0) {
        if (kernel32.global_env) |genv| {
            surface_buffer = genv.allocator.alloc(u8, 2048 * 2048 * 4) catch return @as(i32, @bitCast(w32.D3DERR_OUTOFVIDEOMEMORY));
        }
    }

    ppReturnedDeviceInterface.* = &global_d3d8_device;
    return w32.D3D_OK;
}

// --- IDirect3DDevice8 Implementations ---

fn device_Release(this: *IDirect3DDevice8) callconv(w32cc.WINAPI) u32 {
    _ = this;
    return 0;
}

fn device_TestCooperativeLevel(this: *IDirect3DDevice8) callconv(w32cc.WINAPI) i32 {
    _ = this;
    return w32.D3D_OK;
}

fn device_GetAvailableTextureMem(this: *IDirect3DDevice8) callconv(w32cc.WINAPI) u32 {
    _ = this;
    return 128 * 1024 * 1024; // 128MB
}

fn device_GetDeviceCaps(this: *IDirect3DDevice8, pCaps: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (pCaps != 0) {
        fillD3D8Caps(pCaps);
    }
    return 0;
}

fn device_GetDisplayMode(this: *IDirect3DDevice8, pMode: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (pMode != 0) {
        const mode = @as(*w32.D3DDISPLAYMODE, @ptrFromInt(pMode));
        mode.Width = renderer.global_width;
        mode.Height = renderer.global_height;
        mode.RefreshRate = 60;
        mode.Format = w32.D3DFMT_X8R8G8B8;
    }
    return 0;
}

fn device_Reset(this: *IDirect3DDevice8, pPresentationParameters: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = pPresentationParameters;
    return 0;
}

fn device_Present(this: *IDirect3DDevice8, pSourceRect: usize, pDestRect: usize, hDestWindowOverride: usize, pDirtyRegion: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = pSourceRect;
    _ = pDestRect;
    _ = hDestWindowOverride;
    _ = pDirtyRegion;
    // Present the frame
    const pixels = renderer.global_width * renderer.global_height;
    if (surface_buffer.len >= pixels * 4) {
        for (0..pixels) |i| {
            renderer.global_framebuf[i * 4 + 0] = surface_buffer[i * 4 + 2]; // R
            renderer.global_framebuf[i * 4 + 1] = surface_buffer[i * 4 + 1]; // G
            renderer.global_framebuf[i * 4 + 2] = surface_buffer[i * 4 + 0]; // B
            renderer.global_framebuf[i * 4 + 3] = 255;
        }
        renderer.pushFrame();
    }
    return 0;
}

fn device_BeginScene(this: *IDirect3DDevice8) callconv(w32cc.WINAPI) i32 {
    _ = this;
    return 0;
}

fn device_EndScene(this: *IDirect3DDevice8) callconv(w32cc.WINAPI) i32 {
    _ = this;
    return 0;
}

fn device_Clear(this: *IDirect3DDevice8, Count: u32, pRects: usize, Flags: u32, Color: u32, Z: f32, Stencil: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Count;
    _ = pRects;
    _ = Flags;
    _ = Z;
    _ = Stencil;
    // Clear the surface buffer with the given color
    const pixels = renderer.global_width * renderer.global_height;
    if (surface_buffer.len >= pixels * 4) {
        const b: u8 = @intCast(Color & 0xFF);
        const g: u8 = @intCast((Color >> 8) & 0xFF);
        const r: u8 = @intCast((Color >> 16) & 0xFF);
        for (0..pixels) |i| {
            surface_buffer[i * 4 + 0] = b;
            surface_buffer[i * 4 + 1] = g;
            surface_buffer[i * 4 + 2] = r;
            surface_buffer[i * 4 + 3] = 255;
        }
    }
    return 0;
}

fn device_SetViewport(this: *IDirect3DDevice8, pViewport: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = pViewport;
    return 0;
}

fn device_GetViewport(this: *IDirect3DDevice8, pViewport: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (pViewport != 0) {
        const vp = @as(*w32.D3DVIEWPORT8, @ptrFromInt(pViewport));
        vp.X = 0;
        vp.Y = 0;
        vp.Width = renderer.global_width;
        vp.Height = renderer.global_height;
        vp.MinZ = 0.0;
        vp.MaxZ = 1.0;
    }
    return 0;
}

fn device_SetRenderState(this: *IDirect3DDevice8, State: u32, Value: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = State;
    _ = Value;
    return 0;
}

// --- Device methods that return resource objects ---

fn device_GetDirect3D(this: *IDirect3DDevice8, ppD3D8: *?*IDirect3D8) callconv(w32cc.WINAPI) i32 {
    _ = this;
    ppD3D8.* = &global_d3d8;
    return 0;
}

fn device_CreateTexture(this: *IDirect3DDevice8, Width: u32, Height: u32, Levels: u32, Usage: u32, Format: u32, Pool: u32, ppTexture: *?*D3D8Resource) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Levels;
    _ = Usage;
    _ = Format;
    _ = Pool;
    if (trace.enable_tracing) trace.print("D3D8: CreateTexture({d}x{d})\n", .{ Width, Height });
    ppTexture.* = allocResource();
    return 0;
}

fn device_CreateVertexBuffer(this: *IDirect3DDevice8, Length: u32, Usage: u32, FVF: u32, Pool: u32, ppVB: *?*D3D8Resource) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Usage;
    _ = FVF;
    _ = Pool;
    if (trace.enable_tracing) trace.print("D3D8: CreateVertexBuffer(len={d})\n", .{Length});
    ppVB.* = allocResource();
    return 0;
}

fn device_CreateIndexBuffer(this: *IDirect3DDevice8, Length: u32, Usage: u32, Format: u32, Pool: u32, ppIB: *?*D3D8Resource) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Usage;
    _ = Format;
    _ = Pool;
    if (trace.enable_tracing) trace.print("D3D8: CreateIndexBuffer(len={d})\n", .{Length});
    ppIB.* = allocResource();
    return 0;
}

fn device_CreateRenderTarget(this: *IDirect3DDevice8, Width: u32, Height: u32, Format: u32, MultiSample: u32, Lockable: u32, ppSurface: *?*D3D8Resource) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Format;
    _ = MultiSample;
    _ = Lockable;
    if (trace.enable_tracing) trace.print("D3D8: CreateRenderTarget({d}x{d})\n", .{ Width, Height });
    ppSurface.* = allocResource();
    return 0;
}

fn device_CreateDepthStencilSurface(this: *IDirect3DDevice8, Width: u32, Height: u32, Format: u32, MultiSample: u32, ppSurface: *?*D3D8Resource) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Format;
    _ = MultiSample;
    if (trace.enable_tracing) trace.print("D3D8: CreateDepthStencilSurface({d}x{d})\n", .{ Width, Height });
    ppSurface.* = allocResource();
    return 0;
}

fn device_CreateImageSurface(this: *IDirect3DDevice8, Width: u32, Height: u32, Format: u32, ppSurface: *?*D3D8Resource) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Width;
    _ = Height;
    _ = Format;
    ppSurface.* = allocResource();
    return 0;
}

fn device_GetBackBuffer(this: *IDirect3DDevice8, BackBuffer: u32, Type: u32, ppBackBuffer: *?*D3D8Resource) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = BackBuffer;
    _ = Type;
    ppBackBuffer.* = allocResource();
    return 0;
}

fn device_SetRenderTarget(this: *IDirect3DDevice8, pRenderTarget: usize, pNewZStencil: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = pRenderTarget;
    _ = pNewZStencil;
    return 0;
}

fn device_GetRenderTarget(this: *IDirect3DDevice8, ppRenderTarget: *?*D3D8Resource) callconv(w32cc.WINAPI) i32 {
    _ = this;
    ppRenderTarget.* = allocResource();
    return 0;
}

fn device_GetDepthStencilSurface(this: *IDirect3DDevice8, ppZStencilSurface: *?*D3D8Resource) callconv(w32cc.WINAPI) i32 {
    _ = this;
    ppZStencilSurface.* = allocResource();
    return 0;
}

fn device_CreateVertexShader(this: *IDirect3DDevice8, pDeclaration: usize, pFunction: usize, pHandle: *u32, Usage: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = pDeclaration;
    _ = pFunction;
    _ = Usage;
    pHandle.* = 0xBEEF0100 +% @as(u32, @truncate(next_resource));
    return 0;
}

fn device_CreatePixelShader(this: *IDirect3DDevice8, pFunction: usize, pHandle: *u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = pFunction;
    pHandle.* = 0xBEEF0200 +% @as(u32, @truncate(next_resource));
    return 0;
}

// Typed no-ops for unimplemented device methods (stdcall must pop correct arg count)
fn noop1(a: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    return 0;
}
fn noop2(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    return 0;
}
fn noop3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    return 0;
}
fn noop4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    return 0;
}
fn noop5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    return 0;
}
fn noop6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    return 0;
}
fn noop7(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    return 0;
}
fn noop8(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(w32cc.WINAPI) usize {
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
fn noop9(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize, i: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    _ = h;
    _ = i;
    return 0;
}

// --- Resource method implementations ---

fn resource_GetSurfaceLevel(this: usize, Level: u32, ppSurfaceLevel: *?*D3D8Resource) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Level;
    ppSurfaceLevel.* = allocResource();
    return 0;
}

fn resource_LockRect(this: usize, Level: u32, pLockedRect: usize, pRect: usize, Flags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = Level;
    _ = pRect;
    _ = Flags;
    // D3DLOCKED_RECT: { INT Pitch; void* pBits; }
    if (pLockedRect != 0) {
        const lr = @as(*w32.D3DLOCKED_RECT, @ptrFromInt(pLockedRect));
        lr.Pitch = 2048 * 4; // generous pitch
        if (surface_buffer.len > 0) {
            lr.pBits = @truncate(@intFromPtr(surface_buffer.ptr));
        } else {
            lr.pBits = 0;
        }
    }
    return 0;
}

fn resource_VBLock(this: usize, OffsetToLock: u32, SizeToLock: u32, ppbData: *?*anyopaque, Flags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = OffsetToLock;
    _ = Flags;
    _ = SizeToLock;
    // Return our surface buffer as scratch space
    if (surface_buffer.len > 0) {
        ppbData.* = @ptrFromInt(@intFromPtr(surface_buffer.ptr));
    } else {
        ppbData.* = null;
    }
    return 0;
}

/// --- Registration ---
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const comPtr = @import("../x86/thunks.zig").comPtr;

    d3d8_vtbl = .{
        .QueryInterface = d3d8_QueryInterface,
        .AddRef = d3d8_AddRef,
        .Release = d3d8_Release,
        .RegisterSoftwareDevice = comPtr(noop2, "IDirect3D8::RegisterSoftwareDevice"), // this, pInitializeFunction
        .GetAdapterCount = d3d8_GetAdapterCount,
        .GetAdapterIdentifier = d3d8_GetAdapterIdentifier,
        .GetAdapterModeCount = d3d8_GetAdapterModeCount,
        .EnumAdapterModes = d3d8_EnumAdapterModes,
        .GetAdapterDisplayMode = d3d8_GetAdapterDisplayMode,
        .CheckDeviceType = d3d8_CheckDeviceType,
        .CheckDeviceFormat = d3d8_CheckDeviceFormat,
        .CheckDeviceMultiSampleType = d3d8_CheckDeviceMultiSampleType,
        .CheckDepthStencilMatch = d3d8_CheckDepthStencilMatch,
        .GetDeviceCaps = d3d8_GetDeviceCaps,
        .GetAdapterMonitor = d3d8_GetAdapterMonitor,
        .CreateDevice = d3d8_CreateDevice,
    };

    // Arg counts: this + params. E.g. QueryInterface(this, riid, ppv) = 3 args
    const n1 = comPtr(noop1, "IDirect3DDevice8::noop1");
    const n2 = comPtr(noop2, "IDirect3DDevice8::noop2");
    const n3 = comPtr(noop3, "IDirect3DDevice8::noop3");
    const n4 = comPtr(noop4, "IDirect3DDevice8::noop4");
    const n5 = comPtr(noop5, "IDirect3DDevice8::noop5");
    const n6 = comPtr(noop6, "IDirect3DDevice8::noop6");
    const n7 = comPtr(noop7, "IDirect3DDevice8::noop7");
    const n9 = comPtr(noop9, "IDirect3DDevice8::noop9");
    device_vtbl = .{
        .QueryInterface = n3, // 0: this, riid, ppv
        .AddRef = n1, // 1: this
        .Release = device_Release,
        .TestCooperativeLevel = device_TestCooperativeLevel,
        .GetAvailableTextureMem = device_GetAvailableTextureMem,
        .ResourceManagerDiscardBytes = n2, // 5: this, Bytes
        .GetDirect3D = comPtr(device_GetDirect3D, "IDirect3DDevice8::GetDirect3D"),
        .GetDeviceCaps = device_GetDeviceCaps,
        .GetDisplayMode = device_GetDisplayMode,
        .GetCreationParameters = n2, // 9: this, pParameters
        .SetCursorProperties = n4, // 10: this, XHotSpot, YHotSpot, pCursorBitmap
        .SetCursorPosition = n4, // 11: this, X, Y, Flags
        .ShowCursor = n2, // 12: this, bShow
        .CreateAdditionalSwapChain = n3, // 13: this, pPresentParams, ppSwapChain
        .Reset = device_Reset,
        .Present = device_Present,
        .GetBackBuffer = comPtr(device_GetBackBuffer, "IDirect3DDevice8::GetBackBuffer"),
        .GetRasterStatus = n2, // 17: this, pRasterStatus
        .SetGammaRamp = n3, // 18: this, Flags, pRamp
        .GetGammaRamp = n2, // 19: this, pRamp
        .CreateTexture = comPtr(device_CreateTexture, "IDirect3DDevice8::CreateTexture"),
        .CreateVolumeTexture = n9, // 21: this, W, H, D, Levels, Usage, Fmt, Pool, ppVolTex
        .CreateCubeTexture = n7, // 22: this, EdgeLen, Levels, Usage, Fmt, Pool, ppCubeTex
        .CreateVertexBuffer = comPtr(device_CreateVertexBuffer, "IDirect3DDevice8::CreateVertexBuffer"),
        .CreateIndexBuffer = comPtr(device_CreateIndexBuffer, "IDirect3DDevice8::CreateIndexBuffer"),
        .CreateRenderTarget = comPtr(device_CreateRenderTarget, "IDirect3DDevice8::CreateRenderTarget"),
        .CreateDepthStencilSurface = comPtr(device_CreateDepthStencilSurface, "IDirect3DDevice8::CreateDepthStencilSurface"),
        .CreateImageSurface = comPtr(device_CreateImageSurface, "IDirect3DDevice8::CreateImageSurface"),
        .CopyRects = n6, // 28: this, pSrcSurf, pSrcRects, cRects, pDstSurf, pDstPoints
        .UpdateTexture = n3, // 29: this, pSrcTex, pDstTex
        .GetFrontBuffer = n2, // 30: this, pDestSurface
        .SetRenderTarget = comPtr(device_SetRenderTarget, "IDirect3DDevice8::SetRenderTarget"),
        .GetRenderTarget = comPtr(device_GetRenderTarget, "IDirect3DDevice8::GetRenderTarget"),
        .GetDepthStencilSurface = comPtr(device_GetDepthStencilSurface, "IDirect3DDevice8::GetDepthStencilSurface"),
        .BeginScene = device_BeginScene,
        .EndScene = device_EndScene,
        .Clear = device_Clear,
        .SetTransform = n3, // 37: this, State, pMatrix
        .GetTransform = n3, // 38: this, State, pMatrix
        .MultiplyTransform = n3, // 39: this, State, pMatrix
        .SetViewport = device_SetViewport,
        .GetViewport = device_GetViewport,
        .SetMaterial = n2, // 42: this, pMaterial
        .GetMaterial = n2, // 43: this, pMaterial
        .SetLight = n3, // 44: this, Index, pLight
        .GetLight = n3, // 45: this, Index, pLight
        .LightEnable = n3, // 46: this, Index, Enable
        .GetLightEnable = n3, // 47: this, Index, pEnable
        .SetClipPlane = n3, // 48: this, Index, pPlane
        .GetClipPlane = n3, // 49: this, Index, pPlane
        .SetRenderState = device_SetRenderState,
        .GetRenderState = n3, // 51: this, State, pValue
        .BeginStateBlock = n1, // 52: this
        .EndStateBlock = n2, // 53: this, pToken
        .ApplyStateBlock = n2, // 54: this, Token
        .CaptureStateBlock = n2, // 55: this, Token
        .DeleteStateBlock = n2, // 56: this, Token
        .CreateStateBlock = n3, // 57: this, Type, pToken
        .SetClipStatus = n2, // 58: this, pClipStatus
        .GetClipStatus = n2, // 59: this, pClipStatus
        .GetTexture = n3, // 60: this, Stage, ppTexture
        .SetTexture = n3, // 61: this, Stage, pTexture
        .GetTextureStageState = n4, // 62: this, Stage, Type, pValue
        .SetTextureStageState = n4, // 63: this, Stage, Type, Value
        .ValidateDevice = n2, // 64: this, pNumPasses
        .GetInfo = n4, // 65: this, DevInfoID, pDevInfoStruct, Size
        .SetPaletteEntries = n3, // 66: this, PaletteNumber, pEntries
        .GetPaletteEntries = n3, // 67: this, PaletteNumber, pEntries
        .SetCurrentTexturePalette = n2, // 68: this, PaletteNumber
        .GetCurrentTexturePalette = n2, // 69: this, pPaletteNumber
        .DrawPrimitive = n4, // 70: this, PrimitiveType, StartVertex, PrimitiveCount
        .DrawIndexedPrimitive = n7, // 71: this, Type, MinIndex, NumVertices, StartIndex, PrimCount, unused
        .DrawPrimitiveUP = n5, // 72: this, PrimitiveType, PrimitiveCount, pVertexStreamZeroData, VertexStreamZeroStride
        .DrawIndexedPrimitiveUP = n9, // 73: this, PrimType, MinVertexIdx, NumVertexIdx, PrimCount, pIdxData, IdxDataFmt, pVertData, VertStride
        .ProcessVertices = n6, // 74: this, SrcStartIdx, DestIdx, VertexCount, pDestBuf, Flags
        .CreateVertexShader = comPtr(device_CreateVertexShader, "IDirect3DDevice8::CreateVertexShader"),
        .SetVertexShader = n2, // 76: this, Handle
        .GetVertexShader = n2, // 77: this, pHandle
        .DeleteVertexShader = n2, // 78: this, Handle
        .SetVertexShaderConstant = n4, // 79: this, Register, pConstantData, ConstantCount
        .GetVertexShaderConstant = n4, // 80: this, Register, pConstantData, ConstantCount
        .GetVertexShaderDeclaration = n4, // 81: this, Handle, pData, pSizeOfData
        .GetVertexShaderFunction = n4, // 82: this, Handle, pData, pSizeOfData
        .SetStreamSource = n4, // 83: this, StreamNumber, pStreamData, Stride
        .GetStreamSource = n4, // 84: this, StreamNumber, ppStreamData, pStride
        .SetIndices = n3, // 85: this, pIndexData, BaseVertexIndex
        .GetIndices = n3, // 86: this, ppIndexData, pBaseVertexIndex
        .CreatePixelShader = comPtr(device_CreatePixelShader, "IDirect3DDevice8::CreatePixelShader"),
        .SetPixelShader = n2, // 88: this, Handle
        .GetPixelShader = n2, // 89: this, pHandle
        .DeletePixelShader = n2, // 90: this, Handle
        .SetPixelShaderConstant = n4, // 91: this, Register, pConstantData, ConstantCount
        .GetPixelShaderConstant = n4, // 92: this, Register, pConstantData, ConstantCount
        .DrawRectPatch = n4, // 93: this, Handle, pNumSegs, pRectPatchInfo
        .DrawTriPatch = n4, // 94: this, Handle, pNumSegs, pTriPatchInfo
        .DeletePatch = n2, // 95: this, Handle
        .CreateQuery = n1, // 96: padding
    };

    // Initialize resource vtable — all entries use noop3 (handles up to this+2 args safely)
    // Specific overrides: [0]=QI(3), [1]=AddRef(1), [2]=Release(1)
    // Texture-specific: [17]=GetSurfaceLevel(this, Level, ppSurf)=3, [18]=LockRect(this,Level,pLocked,pRect,Flags)=5
    // VB-specific: [11]=Lock(this,Offset,Size,ppbData,Flags)=5, [12]=Unlock(this)=1
    for (&resource_vtbl) |*entry| {
        entry.* = comPtr(noop3, "D3D8Resource::noop3");
    }
    resource_vtbl[0] = n3; // QueryInterface
    resource_vtbl[1] = n1; // AddRef
    resource_vtbl[2] = n1; // Release
    // IDirect3DResource8 methods (3-10) — set correct arg-count noops
    resource_vtbl[3] = n2; // GetDevice(this, ppDevice)
    resource_vtbl[4] = n5; // SetPrivateData(this, refguid, pData, SizeOfData, Flags)
    resource_vtbl[5] = n4; // GetPrivateData(this, refguid, pData, pSizeOfData)
    resource_vtbl[6] = n2; // FreePrivateData(this, refguid)
    resource_vtbl[7] = n2; // SetPriority(this, PriorityNew)
    resource_vtbl[8] = n1; // GetPriority(this)
    resource_vtbl[9] = n1; // PreLoad(this) — also surface LockRect(4 args), conflict accepted
    resource_vtbl[10] = n1; // GetType(this)

    // IDirect3DVertexBuffer8: Lock at index 11, Unlock at 12, GetDesc at 13
    resource_vtbl[11] = comPtr(resource_VBLock, "D3D8Resource::Lock"); // Lock(this, Offset, Size, ppbData, Flags)
    resource_vtbl[12] = n1; // Unlock(this)
    resource_vtbl[13] = n2; // GetDesc(this, pDesc) / GetLevelCount(this) — 1-2 args, safe as noop2

    // IDirect3DTexture8 methods (14-18) — CORRECT indices per D3D8 SDK
    resource_vtbl[14] = n3; // GetLevelDesc(this, Level, pDesc)
    resource_vtbl[15] = comPtr(resource_GetSurfaceLevel, "D3D8Resource::GetSurfaceLevel"); // GetSurfaceLevel(this, Level, ppSurf)
    resource_vtbl[16] = comPtr(resource_LockRect, "D3D8Resource::LockRect"); // LockRect(this, Level, pLockedRect, pRect, Flags)
    resource_vtbl[17] = n2; // UnlockRect(this, Level)
    resource_vtbl[18] = n2; // AddDirtyRect(this, pDirtyRect)

    global_d3d8.lpVtbl = &d3d8_vtbl;
    global_d3d8_device.lpVtbl = &device_vtbl;

    const builtin_module = "d3d8.dll";
    try environment.addBuiltinExportComptime(builtin_module, "Direct3DCreate8", stub_Direct3DCreate8);

    environment.addBuiltinVtableComptime(IDirect3D8Vtbl, &d3d8_vtbl);
    environment.addBuiltinVtableComptime(IDirect3DDevice8Vtbl, &device_vtbl);

    // For resource_vtbl which is an array of usize pointers, we manually register them
    // assuming safe defaults. If the guest calls them natively, dispatchNativeCall
    // will jump to them. These are mostly noops.
    for (&resource_vtbl) |*func_ptr| {
        if (func_ptr.* != 0) {
            const thunks = @import("../x86/thunks.zig");
            // Since we don't know param_len exactly for the array at comptime, we default to 12 bytes
            // which handles noop3 safely.
            thunks.registerNativeImport(@intCast(func_ptr.*), "COM", "D3D8ResourceMethod", 12);
        }
    }

    // Finalize PE export directory so games that manually parse PE exports
    // (e.g. Europa 1400 TL) can find Direct3DCreate8 in the fake header.
    environment.finalizeExports("d3d8.dll");
}

fn stub_Direct3DCreate8(SDKVersion: u32) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) {
        trace.print("D3D8: Direct3DCreate8(version={d})\n", .{SDKVersion});
        trace.print("D3D8: global_d3d8 at {x}, vtbl at {x}\n", .{ @intFromPtr(&global_d3d8), @intFromPtr(global_d3d8.lpVtbl) });
        trace.print("D3D8: vtbl[10] CheckDeviceFormat at {x}\n", .{@intFromPtr(global_d3d8.lpVtbl.CheckDeviceFormat)});
    }
    return @intFromPtr(&global_d3d8);
}
