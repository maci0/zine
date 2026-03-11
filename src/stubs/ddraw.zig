
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const renderer = @import("../gui/renderer.zig");
const w32 = @import("win32_constants.zig");

// --- COM VTables ---

const IDirectDraw = extern struct {
    lpVtbl: *const IDirectDrawVtbl,
};

const IDirectDrawSurface = extern struct {
    lpVtbl: *const IDirectDrawSurfaceVtbl,
};

const IDirectDrawVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, usize, *?*anyopaque) callconv(.winapi) i32,
    AddRef: usize,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    Compact: usize,
    CreateClipper: *const fn (*IDirectDraw, u32, *?*IDirectDrawClipper, usize) callconv(.winapi) i32,
    CreatePalette: usize,
    CreateSurface: *const fn (*IDirectDraw, usize, *?*IDirectDrawSurface, usize) callconv(.winapi) i32,
    DuplicateSurface: usize,
    EnumDisplayModes: *const fn (*IDirectDraw, u32, usize, usize, usize) callconv(.winapi) i32,
    EnumSurfaces: usize,
    FlipToGDISurface: usize,
    GetCaps: usize,
    GetDisplayMode: *const fn (*IDirectDraw, usize) callconv(.winapi) i32,
    GetFourCCCodes: usize,
    GetGDISurface: usize,
    GetMonitorFrequency: usize,
    GetScanLine: usize,
    GetVerticalBlankStatus: usize,
    Initialize: usize,
    RestoreDisplayMode: usize,
    SetCooperativeLevel: *const fn (*IDirectDraw, usize, u32) callconv(.winapi) i32,
    SetDisplayMode: *const fn (*IDirectDraw, u32, u32, u32) callconv(.winapi) i32,
    WaitForVerticalBlank: usize,
};

const IDirectDrawClipper = extern struct {
    lpVtbl: *const IDirectDrawClipperVtbl,
};

const IDirectDrawClipperVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, usize, *?*anyopaque) callconv(.winapi) i32,
    AddRef: usize,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetClipList: usize,
    GetHWnd: usize,
    Initialize: usize,
    IsClipListChanged: usize,
    SetClipList: usize,
    SetHWnd: *const fn (*IDirectDrawClipper, u32, usize) callconv(.winapi) i32,
};

const IDirectDrawSurfaceVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, usize, *?*anyopaque) callconv(.winapi) i32,
    AddRef: usize,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    AddAttachedSurface: usize,
    AddOverlay: usize,
    Blt: *const fn (*IDirectDrawSurface, usize, *IDirectDrawSurface, usize, u32, usize) callconv(.winapi) i32,
    BltBatch: usize,
    BltFast: usize,
    DeleteAttachedSurface: usize,
    EnumAttachedSurfaces: usize,
    EnumOverlayZOrders: usize,
    Flip: usize,
    GetAttachedSurface: usize,
    GetBltStatus: usize,
    GetCaps: usize,
    GetClipper: usize,
    GetColorKey: usize,
    GetDC: usize,
    GetFlipStatus: usize,
    GetOverlayPosition: usize,
    GetPalette: usize,
    GetPixelFormat: usize,
    GetSurfaceDesc: usize,
    Initialize: usize,
    IsLost: usize,
    Lock: *const fn (*IDirectDrawSurface, usize, usize, u32, usize) callconv(.winapi) i32,
    ReleaseDC: usize,
    Restore: *const fn (*IDirectDrawSurface) callconv(.winapi) i32,
    SetClipper: *const fn (*IDirectDrawSurface, usize) callconv(.winapi) i32,
    SetColorKey: usize,
    SetOverlayPosition: usize,
    SetPalette: usize,
    Unlock: *const fn (*IDirectDrawSurface, usize) callconv(.winapi) i32,
    UpdateOverlay: usize,
    UpdateOverlayDisplay: usize,
    UpdateOverlayZOrder: usize,
};

// --- Instances ---

var global_ddraw: IDirectDraw = undefined;
var global_primary_surface: IDirectDrawSurface = undefined;
var global_clipper: IDirectDrawClipper = undefined;

var surface_buffer: []u8 = &[_]u8{};

// Current display mode (updated by SetDisplayMode)
var display_mode_w: u32 = 640;
var display_mode_h: u32 = 480;
var display_mode_bpp: u32 = 32;

// Surface pool for offscreen surfaces (max 4)
const MAX_SURFACES = 4;
var surface_pool: [MAX_SURFACES]IDirectDrawSurface = undefined;
var surface_widths: [MAX_SURFACES]u32 = .{ 0, 0, 0, 0 };
var surface_heights: [MAX_SURFACES]u32 = .{ 0, 0, 0, 0 };
var surface_count: u32 = 0;

// The backbuffer surface (largest offscreen) — set during CreateSurface
var backbuffer_surface: ?*IDirectDrawSurface = null;
var backbuffer_w: u32 = 0;
var backbuffer_h: u32 = 0;

/// Look up the dimensions for a given surface pointer
fn getSurfaceDims(surf: *IDirectDrawSurface) struct { w: u32, h: u32 } {
    for (0..surface_count) |i| {
        if (&surface_pool[i] == surf) {
            return .{ .w = surface_widths[i], .h = surface_heights[i] };
        }
    }
    return .{ .w = renderer.global_width, .h = renderer.global_height };
}

// --- Implementations ---

fn ddraw_QueryInterface(this: *anyopaque, riid: usize, ppvObj: *?*anyopaque) callconv(.winapi) i32 {
    _ = riid;
    if (trace.enable_tracing) trace.print("DDRAW: QueryInterface\n", .{});
    ppvObj.* = this;
    return w32.S_OK;
}

fn ddraw_Release(this: *anyopaque) callconv(.winapi) u32 {
    _ = this;
    return 0;
}

fn ddraw_Dummy(this: *anyopaque) callconv(.winapi) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DDRAW: Dummy\n", .{});
    return w32.DD_OK;
}

fn clipper_SetHWnd(this: *IDirectDrawClipper, dwFlags: u32, hWnd: usize) callconv(.winapi) i32 {
    _ = this; _ = dwFlags; _ = hWnd;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawClipper::SetHWnd\n", .{});
    return w32.DD_OK;
}

fn ddraw_CreateClipper(this: *IDirectDraw, dwFlags: u32, lplpDDClipper: *?*IDirectDrawClipper, pUnkOuter: usize) callconv(.winapi) i32 {
    _ = this; _ = dwFlags; _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::CreateClipper\n", .{});
    lplpDDClipper.* = &global_clipper;
    return w32.DD_OK;
}

fn ddraw_CreateSurface(this: *IDirectDraw, lpDDSurfaceDesc: usize, lplpDDSurface: *?*IDirectDrawSurface, pUnkOuter: usize) callconv(.winapi) i32 {
    _ = this; _ = pUnkOuter;
    
    if (surface_buffer.len == 0) {
        if (@import("kernel32.zig").global_env) |genv| {
            surface_buffer = genv.allocator.alloc(u8, 1024 * 1024 * 4) catch unreachable;
        }
    }
    
    var w: u32 = 0;
    var h: u32 = 0;
    var flags: u32 = 0;
    var caps: u32 = 0;
    var back_buffer_count: u32 = 0;
    if (lpDDSurfaceDesc != 0) {
        const desc = @as(*w32.DDSURFACEDESC, @ptrFromInt(lpDDSurfaceDesc));
        flags = desc.dwFlags;
        if ((flags & w32.DDSD_WIDTH) != 0) w = desc.dwWidth;
        if ((flags & w32.DDSD_HEIGHT) != 0) h = desc.dwHeight;
        if ((flags & w32.DDSD_BACKBUFFERCOUNT) != 0) back_buffer_count = desc.dwBackBufferCount;
        if ((flags & w32.DDSD_CAPS) != 0) caps = desc.ddsCaps.dwCaps;
    }
    
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::CreateSurface({d}x{d} flags=0x{x} caps=0x{x} bbcount={d})\n", .{w, h, flags, caps, back_buffer_count});

    if (w > 0 and h > 0) {
        // Offscreen surface with explicit dimensions
        if (surface_count < MAX_SURFACES) {
            const idx = surface_count;
            surface_pool[idx].lpVtbl = &surface_vtbl;
            surface_widths[idx] = w;
            surface_heights[idx] = h;
            surface_count += 1;
            lplpDDSurface.* = &surface_pool[idx];

            // Track the largest as the backbuffer
            if (w * h > backbuffer_w * backbuffer_h) {
                backbuffer_surface = &surface_pool[idx];
                backbuffer_w = w;
                backbuffer_h = h;
            }
            // Always update renderer resolution
            renderer.setResolution(w, h);
        } else {
            lplpDDSurface.* = &global_primary_surface;
        }
    } else {
        // Primary surface (no explicit dimensions)
        lplpDDSurface.* = &global_primary_surface;
        
        // In fullscreen mode (display mode changed from default), create a backbuffer
        // at the display mode dimensions so GetAttachedSurface works
        const is_fullscreen = display_mode_bpp != 32 or display_mode_w != 640 or display_mode_h != 480;
        if (is_fullscreen or back_buffer_count > 0) {
            // Set resolution to display mode dimensions
            renderer.setResolution(display_mode_w, display_mode_h);
            
            // Create an implicit backbuffer in the pool
            if (surface_count < MAX_SURFACES) {
                const idx = surface_count;
                surface_pool[idx].lpVtbl = &surface_vtbl;
                surface_widths[idx] = display_mode_w;
                surface_heights[idx] = display_mode_h;
                surface_count += 1;
                backbuffer_surface = &surface_pool[idx];
                backbuffer_w = display_mode_w;
                backbuffer_h = display_mode_h;
            }
        }
    }
    return w32.DD_OK;
}

fn ddraw_SetCooperativeLevel(this: *IDirectDraw, hWnd: usize, dwFlags: u32) callconv(.winapi) i32 {
    _ = this; _ = hWnd; _ = dwFlags;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::SetCooperativeLevel\n", .{});
    return w32.DD_OK;
}

fn ddraw_SetDisplayMode(this: *IDirectDraw, dwWidth: u32, dwHeight: u32, dwBPP: u32) callconv(.winapi) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::SetDisplayMode({d}x{d} @ {d}bpp)\n", .{dwWidth, dwHeight, dwBPP});
    display_mode_w = dwWidth;
    display_mode_h = dwHeight;
    display_mode_bpp = dwBPP;
    // Reset surface pool — app will create new surfaces
    surface_count = 0;
    backbuffer_surface = null;
    backbuffer_w = 0;
    backbuffer_h = 0;
    return w32.DD_OK;
}

fn ddraw_RestoreDisplayMode(this: *IDirectDraw) callconv(.winapi) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::RestoreDisplayMode\n", .{});
    display_mode_w = 640;
    display_mode_h = 480;
    display_mode_bpp = 32;
    return w32.DD_OK;
}

fn ddraw_WaitForVerticalBlank(this: *IDirectDraw, dwFlags: u32, hEvent: usize) callconv(.winapi) i32 {
    _ = this;
    _ = dwFlags;
    _ = hEvent;
    return w32.DD_OK;
}

fn ddraw_GetDisplayMode(this: *IDirectDraw, lpDDSurfaceDesc: usize) callconv(.winapi) i32 {
    _ = this;
    const ret_addr = @returnAddress();
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::GetDisplayMode (ret: 0x{x})\n", .{ret_addr});

    if (lpDDSurfaceDesc != 0) {
        const desc = @as(*w32.DDSURFACEDESC, @ptrFromInt(lpDDSurfaceDesc));
        desc.dwSize = 108;
        desc.dwFlags = w32.DDSD_WIDTH | w32.DDSD_HEIGHT | w32.DDSD_PIXELFORMAT;
        desc.dwHeight = display_mode_h;
        desc.dwWidth = display_mode_w;

        desc.ddpfPixelFormat.dwSize = 32;
        desc.ddpfPixelFormat.dwFlags = w32.DDPF_RGB;
        desc.ddpfPixelFormat.dwFourCC = 0;
        desc.ddpfPixelFormat.dwRGBBitCount = display_mode_bpp;
        if (display_mode_bpp == 16) {
            desc.ddpfPixelFormat.dwRBitMask = 0xF800;      // RGB565
            desc.ddpfPixelFormat.dwGBitMask = 0x07E0;
            desc.ddpfPixelFormat.dwBBitMask = 0x001F;
            desc.ddpfPixelFormat.dwRGBAlphaBitMask = 0;
        } else {
            desc.ddpfPixelFormat.dwRBitMask = 0x00FF0000;  // BGRA8888
            desc.ddpfPixelFormat.dwGBitMask = 0x0000FF00;
            desc.ddpfPixelFormat.dwBBitMask = 0x000000FF;
            desc.ddpfPixelFormat.dwRGBAlphaBitMask = 0xFF000000;
        }
    }
    return w32.DD_OK;
}

fn ddraw_EnumDisplayModes(this: *IDirectDraw, dwFlags: u32, lpDDSurfaceDesc: usize, lpContext: usize, lpEnumCallback: usize) callconv(.winapi) i32 {
    _ = this; _ = dwFlags; _ = lpDDSurfaceDesc;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::EnumDisplayModes\n", .{});
    if (lpEnumCallback != 0) {
        var desc = w32.DDSURFACEDESC{};
        desc.dwFlags = w32.DDSD_WIDTH | w32.DDSD_HEIGHT | w32.DDSD_PIXELFORMAT;
        desc.dwHeight = 480;
        desc.dwWidth = 640;

        desc.ddpfPixelFormat.dwFlags = w32.DDPF_RGB;
        desc.ddpfPixelFormat.dwRGBBitCount = 32;
        desc.ddpfPixelFormat.dwRBitMask = 0x00FF0000;
        desc.ddpfPixelFormat.dwGBitMask = 0x0000FF00;
        desc.ddpfPixelFormat.dwBBitMask = 0x000000FF;
        desc.ddpfPixelFormat.dwRGBAlphaBitMask = 0x00000000;

        const cb = @as(*const fn (usize, usize) callconv(.winapi) i32, @ptrFromInt(lpEnumCallback));
        _ = cb(@intFromPtr(&desc), lpContext);
    }
    return w32.DD_OK;
}

fn surface_Blt(this: *IDirectDrawSurface, lpDestRect: usize, lpDDSrcSurface: *IDirectDrawSurface, lpSrcRect: usize, dwFlags: u32, lpDDBltFx: usize) callconv(.winapi) i32 {
    _ = this; _ = lpDestRect; _ = lpDDSrcSurface; _ = lpSrcRect; _ = dwFlags; _ = lpDDBltFx;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawSurface::Blt\n", .{});
    
    pushSurfaceFrame();
    return w32.DD_OK;
}

/// Convert surface_buffer to RGBA in global_framebuf and push frame.
/// Handles both 16bpp RGB565 and 32bpp BGRA based on current display mode.
fn pushSurfaceFrame() void {
    const vw = renderer.global_width;
    const vh = renderer.global_height;
    const pixels = vw * vh;
    const bpp: u32 = if (display_mode_bpp == 16) 2 else 4;

    if (surface_buffer.len < pixels * bpp) return;

    if (display_mode_bpp == 16) {
        for (0..pixels) |i| {
            const lo: u16 = surface_buffer[i * 2];
            const hi: u16 = surface_buffer[i * 2 + 1];
            const rgb565 = lo | (hi << 8);
            const r: u8 = @truncate((rgb565 >> 11) << 3);
            const g: u8 = @truncate(((rgb565 >> 5) & 0x3F) << 2);
            const b: u8 = @truncate((rgb565 & 0x1F) << 3);
            renderer.global_framebuf[i * 4 + 0] = r;
            renderer.global_framebuf[i * 4 + 1] = g;
            renderer.global_framebuf[i * 4 + 2] = b;
            renderer.global_framebuf[i * 4 + 3] = 255;
        }
    } else {
        for (0..pixels) |i| {
            renderer.global_framebuf[i * 4 + 0] = surface_buffer[i * 4 + 2]; // R <- B
            renderer.global_framebuf[i * 4 + 1] = surface_buffer[i * 4 + 1]; // G
            renderer.global_framebuf[i * 4 + 2] = surface_buffer[i * 4 + 0]; // B <- R
            renderer.global_framebuf[i * 4 + 3] = 255;                       // A
        }
    }
    renderer.pushFrame();
}

fn surface_Lock(this: *IDirectDrawSurface, lpDestRect: usize, lpDDSurfaceDesc: usize, dwFlags: u32, hEvent: usize) callconv(.winapi) i32 {
    _ = lpDestRect; _ = dwFlags; _ = hEvent;
    const bytes_per_pixel: u32 = if (display_mode_bpp == 16) 2 else 4;
    const dims = getSurfaceDims(this);
    if (trace.enable_tracing) {
        trace.print("DDRAW: IDirectDrawSurface::Lock (this=0x{x} dims={d}x{d} pitch={d} bpp={d})\n", .{ @intFromPtr(this), dims.w, dims.h, dims.w * bytes_per_pixel, display_mode_bpp });
    }
    if (lpDDSurfaceDesc != 0) {
        const desc = @as(*w32.DDSURFACEDESC, @ptrFromInt(lpDDSurfaceDesc));
        desc.lpSurface = @truncate(@intFromPtr(surface_buffer.ptr));
        desc.lPitch = dims.w * bytes_per_pixel;
    }
    return w32.DD_OK;
}

fn surface_Unlock(this: *IDirectDrawSurface, lpRect: usize) callconv(.winapi) i32 {
    _ = this; _ = lpRect;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawSurface::Unlock\n", .{});
    return w32.DD_OK;
}

fn surface_Flip(this: *IDirectDrawSurface, lpDDSurfaceTargetOverride: usize, dwFlags: u32) callconv(.winapi) i32 {
    _ = this;
    _ = lpDDSurfaceTargetOverride;
    _ = dwFlags;

    pushSurfaceFrame();
    return w32.DD_OK;
}

fn surface_GetAttachedSurface(this: *IDirectDrawSurface, lpDDSCaps: usize, lplpDDAttachedSurface: *?*IDirectDrawSurface) callconv(.winapi) i32 {
    _ = this;
    _ = lpDDSCaps;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawSurface::GetAttachedSurface\n", .{});
    // Return the back buffer
    if (backbuffer_surface) |bb| {
        lplpDDAttachedSurface.* = bb;
    } else {
        lplpDDAttachedSurface.* = &global_primary_surface;
    }
    return w32.DD_OK;
}

fn surface_GetCaps(this: *IDirectDrawSurface, lpDDSCaps: usize) callconv(.winapi) i32 {
    _ = this;
    if (lpDDSCaps != 0) {
        @as(*align(1) u32, @ptrFromInt(lpDDSCaps)).* = w32.DDSCAPS_OFFSCREENPLAIN;
    }
    return w32.DD_OK;
}

fn surface_GetSurfaceDesc(this: *IDirectDrawSurface, lpDDSurfaceDesc: usize) callconv(.winapi) i32 {
    _ = this;
    if (lpDDSurfaceDesc != 0) {
        const desc = @as(*w32.DDSURFACEDESC, @ptrFromInt(lpDDSurfaceDesc));
        desc.dwSize = 108;
        desc.dwFlags = w32.DDSD_WIDTH | w32.DDSD_HEIGHT | w32.DDSD_PITCH;
        desc.dwHeight = renderer.global_height;
        desc.dwWidth = renderer.global_width;
        desc.lPitch = renderer.global_width * 4;
    }
    return w32.DD_OK;
}

fn surface_IsLost(this: *IDirectDrawSurface) callconv(.winapi) i32 {
    _ = this;
    return w32.DD_OK; // not lost
}

fn surface_Restore(this: *IDirectDrawSurface) callconv(.winapi) i32 {
    _ = this;
    return w32.DD_OK;
}

fn surface_SetClipper(this: *IDirectDrawSurface, lpDDClipper: usize) callconv(.winapi) i32 {
    _ = this; _ = lpDDClipper;
    return w32.DD_OK;
}

var clipper_vtbl: IDirectDrawClipperVtbl = undefined;
var ddraw_vtbl: IDirectDrawVtbl = undefined;
var surface_vtbl: IDirectDrawSurfaceVtbl = undefined;

// --- Exports ---

pub fn register(environment: *env.Environment) !void {
    clipper_vtbl = .{
        .QueryInterface = @ptrCast(&ddraw_QueryInterface),
        .AddRef = 0,
        .Release = ddraw_Release,
        .GetClipList = 0,
        .GetHWnd = 0,
        .Initialize = 0,
        .IsClipListChanged = 0,
        .SetClipList = 0,
        .SetHWnd = clipper_SetHWnd,
    };

    ddraw_vtbl = .{
        .QueryInterface = @ptrCast(&ddraw_QueryInterface),
        .AddRef = 0,
        .Release = ddraw_Release,
        .Compact = 0,
        .CreateClipper = ddraw_CreateClipper,
        .CreatePalette = 0,
        .CreateSurface = ddraw_CreateSurface,
        .DuplicateSurface = 0,
        .EnumDisplayModes = ddraw_EnumDisplayModes,
        .EnumSurfaces = 0,
        .FlipToGDISurface = 0,
        .GetCaps = 0,
        .GetDisplayMode = ddraw_GetDisplayMode,
        .GetFourCCCodes = 0,
        .GetGDISurface = 0,
        .GetMonitorFrequency = 0,
        .GetScanLine = 0,
        .GetVerticalBlankStatus = 0,
        .Initialize = 0,
        .RestoreDisplayMode = @intFromPtr(&ddraw_RestoreDisplayMode),
        .SetCooperativeLevel = ddraw_SetCooperativeLevel,
        .SetDisplayMode = ddraw_SetDisplayMode,
        .WaitForVerticalBlank = @intFromPtr(&ddraw_WaitForVerticalBlank),
    };

    surface_vtbl = .{
        .QueryInterface = @ptrCast(&ddraw_QueryInterface),
        .AddRef = 0,
        .Release = ddraw_Release,
        .AddAttachedSurface = 0,
        .AddOverlay = 0,
        .Blt = surface_Blt,
        .BltBatch = 0,
        .BltFast = 0,
        .DeleteAttachedSurface = 0,
        .EnumAttachedSurfaces = 0,
        .EnumOverlayZOrders = 0,
        .Flip = @intFromPtr(&surface_Flip),
        .GetAttachedSurface = @intFromPtr(&surface_GetAttachedSurface),
        .GetBltStatus = 0,
        .GetCaps = @intFromPtr(&surface_GetCaps),
        .GetClipper = 0,
        .GetColorKey = 0,
        .GetDC = 0,
        .GetFlipStatus = 0,
        .GetOverlayPosition = 0,
        .GetPalette = 0,
        .GetPixelFormat = 0,
        .GetSurfaceDesc = @intFromPtr(&surface_GetSurfaceDesc),
        .Initialize = 0,
        .IsLost = @intFromPtr(&surface_IsLost),
        .Lock = surface_Lock,
        .ReleaseDC = 0,
        .Restore = surface_Restore,
        .SetClipper = surface_SetClipper,
        .SetColorKey = 0,
        .SetOverlayPosition = 0,
        .SetPalette = 0,
        .Unlock = surface_Unlock,
        .UpdateOverlay = 0,
        .UpdateOverlayDisplay = 0,
        .UpdateOverlayZOrder = 0,
    };

    global_ddraw.lpVtbl = &ddraw_vtbl;
    global_primary_surface.lpVtbl = &surface_vtbl;
    global_clipper.lpVtbl = &clipper_vtbl;

    const builtin_module = "DDRAW.dll";
    try environment.addBuiltinExport(builtin_module, "DirectDrawCreate", @intFromPtr(&stub_DirectDrawCreate));
    try environment.addBuiltinExport(builtin_module, "DirectDrawCreateEx", @intFromPtr(&stub_DirectDrawCreateEx));
}

fn stub_DirectDrawCreate(lpGUID: usize, lplpDD: *?*IDirectDraw, pUnkOuter: usize) callconv(.winapi) i32 {
    _ = lpGUID;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DDRAW: DirectDrawCreate()\n", .{});

    lplpDD.* = &global_ddraw;
    return w32.DD_OK;
}

fn stub_DirectDrawCreateEx(lpGUID: usize, lplpDD: *?*anyopaque, iid: usize, pUnkOuter: usize) callconv(.winapi) i32 {
    _ = lpGUID;
    _ = iid;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DDRAW: DirectDrawCreateEx()\n", .{});
    lplpDD.* = @ptrCast(&global_ddraw);
    return w32.DD_OK;
}
