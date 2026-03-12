
const env = @import("../../loader/env.zig");
const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

// --- COM VTables ---

const IDirectDraw = extern struct {
    lpVtbl: *const IDirectDrawVtbl,
};

const IDirectDrawSurface = extern struct {
    lpVtbl: *const IDirectDrawSurfaceVtbl,
};

/// IDirectDraw7 vtable (superset of IDirectDraw — 30 entries)
/// All `usize` entries are filled with @intFromPtr(&ddraw_Dummy) at init
/// to prevent EIP=0 crashes when the game calls unimplemented methods.
const IDirectDrawVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32,
    AddRef: usize,
    Release: *const fn (*anyopaque) callconv(w32cc.WINAPI) u32,
    Compact: usize,
    CreateClipper: *const fn (*IDirectDraw, u32, *?*IDirectDrawClipper, usize) callconv(w32cc.WINAPI) i32,
    CreatePalette: usize,
    CreateSurface: *const fn (*IDirectDraw, usize, *?*IDirectDrawSurface, usize) callconv(w32cc.WINAPI) i32,
    DuplicateSurface: usize,
    EnumDisplayModes: *const fn (*IDirectDraw, u32, usize, usize, usize) callconv(w32cc.WINAPI) i32,
    EnumSurfaces: usize,
    FlipToGDISurface: usize,
    GetCaps: usize,
    GetDisplayMode: *const fn (*IDirectDraw, usize) callconv(w32cc.WINAPI) i32,
    GetFourCCCodes: usize,
    GetGDISurface: usize,
    GetMonitorFrequency: usize,
    GetScanLine: usize,
    GetVerticalBlankStatus: usize,
    Initialize: usize,
    RestoreDisplayMode: *const fn (*IDirectDraw) callconv(w32cc.WINAPI) i32,
    SetCooperativeLevel: *const fn (*IDirectDraw, usize, u32) callconv(w32cc.WINAPI) i32,
    SetDisplayMode: *const fn (*IDirectDraw, u32, u32, u32) callconv(w32cc.WINAPI) i32,
    WaitForVerticalBlank: *const fn (*IDirectDraw, u32, usize) callconv(w32cc.WINAPI) i32,
    // IDirectDraw7 additions (indices 23-29):
    GetAvailableVidMem: usize,
    GetSurfaceFromDC: usize,
    RestoreAllSurfaces: usize,
    TestCooperativeLevel: usize,
    GetDeviceIdentifier: usize,
    StartModeTest: usize,
    EvaluateMode: usize,
};

const IDirectDrawClipper = extern struct {
    lpVtbl: *const IDirectDrawClipperVtbl,
};

const IDirectDrawClipperVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32,
    AddRef: usize,
    Release: *const fn (*anyopaque) callconv(w32cc.WINAPI) u32,
    GetClipList: usize,
    GetHWnd: usize,
    Initialize: usize,
    IsClipListChanged: usize,
    SetClipList: usize,
    SetHWnd: *const fn (*IDirectDrawClipper, u32, usize) callconv(w32cc.WINAPI) i32,
};

/// IDirectDrawSurface7 vtable (superset of IDirectDrawSurface — 40+ entries)
const IDirectDrawSurfaceVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32,
    AddRef: usize,
    Release: *const fn (*anyopaque) callconv(w32cc.WINAPI) u32,
    AddAttachedSurface: usize,
    AddOverlay: usize,
    Blt: *const fn (*IDirectDrawSurface, usize, *IDirectDrawSurface, usize, u32, usize) callconv(w32cc.WINAPI) i32,
    BltBatch: usize,
    BltFast: usize,
    DeleteAttachedSurface: usize,
    EnumAttachedSurfaces: usize,
    EnumOverlayZOrders: usize,
    Flip: *const fn (*IDirectDrawSurface, usize, u32) callconv(w32cc.WINAPI) i32,
    GetAttachedSurface: *const fn (*IDirectDrawSurface, usize, *?*IDirectDrawSurface) callconv(w32cc.WINAPI) i32,
    GetBltStatus: usize,
    GetCaps: *const fn (*IDirectDrawSurface, usize) callconv(w32cc.WINAPI) i32,
    GetClipper: usize,
    GetColorKey: usize,
    GetDC: usize,
    GetFlipStatus: usize,
    GetOverlayPosition: usize,
    GetPalette: usize,
    GetPixelFormat: usize,
    GetSurfaceDesc: *const fn (*IDirectDrawSurface, usize) callconv(w32cc.WINAPI) i32,
    Initialize: usize,
    IsLost: *const fn (*IDirectDrawSurface) callconv(w32cc.WINAPI) i32,
    Lock: *const fn (*IDirectDrawSurface, usize, usize, u32, usize) callconv(w32cc.WINAPI) i32,
    ReleaseDC: usize,
    Restore: *const fn (*IDirectDrawSurface) callconv(w32cc.WINAPI) i32,
    SetClipper: *const fn (*IDirectDrawSurface, usize) callconv(w32cc.WINAPI) i32,
    SetColorKey: usize,
    SetOverlayPosition: usize,
    SetPalette: usize,
    Unlock: *const fn (*IDirectDrawSurface, usize) callconv(w32cc.WINAPI) i32,
    UpdateOverlay: usize,
    UpdateOverlayDisplay: usize,
    UpdateOverlayZOrder: usize,
    // IDirectDrawSurface7 additions:
    GetDDInterface: usize,
    PageLock: usize,
    PageUnlock: usize,
    SetSurfaceDesc: usize,
    SetPrivateData: usize,
    GetPrivateData: usize,
    FreePrivateData: usize,
    GetUniquenessValue: usize,
    ChangeUniquenessValue: usize,
    SetPriority: usize,
    GetPriority: usize,
    SetLOD: usize,
    GetLOD: usize,
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

fn ddraw_QueryInterface(this: *anyopaque, riid: usize, ppvObj: *?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = riid;
    if (trace.enable_tracing) trace.print("DDRAW: QueryInterface\n", .{});
    ppvObj.* = this;
    return w32.S_OK;
}

fn ddraw_Release(this: *anyopaque) callconv(w32cc.WINAPI) u32 {
    _ = this;
    return 0;
}

fn ddraw_Dummy(this: *anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DDRAW: Dummy\n", .{});
    return w32.DD_OK;
}

// Dummy stubs for different argument counts (stdcall requires callee cleanup)
fn ddraw_Dum2(a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = a; _ = b;
    if (trace.enable_tracing) trace.print("DDRAW: Dummy2\n", .{});
    return w32.DD_OK;
}

fn ddraw_Dum3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = a; _ = b; _ = c;
    if (trace.enable_tracing) trace.print("DDRAW: Dummy3\n", .{});
    return w32.DD_OK;
}

fn ddraw_Dum4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) i32 {
    _ = a; _ = b; _ = c; _ = d;
    if (trace.enable_tracing) trace.print("DDRAW: Dummy4\n", .{});
    return w32.DD_OK;
}

fn ddraw_Dum5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) i32 {
    _ = a; _ = b; _ = c; _ = d; _ = e;
    if (trace.enable_tracing) trace.print("DDRAW: Dummy5\n", .{});
    return w32.DD_OK;
}

fn ddraw_Dum6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) i32 {
    _ = a; _ = b; _ = c; _ = d; _ = e; _ = f;
    if (trace.enable_tracing) trace.print("DDRAW: Dummy6\n", .{});
    return w32.DD_OK;
}

fn clipper_SetHWnd(this: *IDirectDrawClipper, dwFlags: u32, hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = dwFlags; _ = hWnd;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawClipper::SetHWnd\n", .{});
    return w32.DD_OK;
}

fn ddraw_CreateClipper(this: *IDirectDraw, dwFlags: u32, lplpDDClipper: *?*IDirectDrawClipper, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = dwFlags; _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::CreateClipper\n", .{});
    lplpDDClipper.* = &global_clipper;
    return w32.DD_OK;
}

fn ddraw_CreateSurface(this: *IDirectDraw, lpDDSurfaceDesc: usize, lplpDDSurface: *?*IDirectDrawSurface, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = pUnkOuter;
    
    if (surface_buffer.len == 0) {
        if (@import("../kernel32.zig").global_env) |genv| {
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
    
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::CreateSurface({d}x{d} flags=0x{x} caps=0x{x} bbcount={d} size={d})\n", .{w, h, flags, caps, back_buffer_count, if (lpDDSurfaceDesc != 0) @as(*u32, @ptrFromInt(lpDDSurfaceDesc)).* else @as(u32, 0)});

    // Clamp to sane dimensions — guard against DDSURFACEDESC2 misparse
    if (w > 4096) w = 0;
    if (h > 4096) h = 0;

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
            const area = @as(u64, w) * @as(u64, h);
            const bb_area = @as(u64, backbuffer_w) * @as(u64, backbuffer_h);
            if (area > bb_area) {
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

fn ddraw_SetCooperativeLevel(this: *IDirectDraw, hWnd: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = hWnd; _ = dwFlags;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::SetCooperativeLevel\n", .{});
    return w32.DD_OK;
}

fn ddraw_SetDisplayMode(this: *IDirectDraw, dwWidth: u32, dwHeight: u32, dwBPP: u32) callconv(w32cc.WINAPI) i32 {
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

fn ddraw_RestoreDisplayMode(this: *IDirectDraw) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::RestoreDisplayMode\n", .{});
    display_mode_w = 640;
    display_mode_h = 480;
    display_mode_bpp = 32;
    return w32.DD_OK;
}

fn ddraw_WaitForVerticalBlank(this: *IDirectDraw, dwFlags: u32, hEvent: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = dwFlags;
    _ = hEvent;
    return w32.DD_OK;
}

fn ddraw_GetDisplayMode(this: *IDirectDraw, lpDDSurfaceDesc: usize) callconv(w32cc.WINAPI) i32 {
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

fn ddraw_EnumDisplayModes(this: *IDirectDraw, dwFlags: u32, lpDDSurfaceDesc: usize, lpContext: usize, lpEnumCallback: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = dwFlags; _ = lpDDSurfaceDesc;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::EnumDisplayModes\n", .{});
    if (lpEnumCallback != 0) {
        const cb = @as(*const fn (usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(lpEnumCallback));

        // Enumerate several common modes Europa 1400 may want
        const modes = [_]struct { w: u32, h: u32, bpp: u32 }{
            .{ .w = 640, .h = 480, .bpp = 16 },
            .{ .w = 640, .h = 480, .bpp = 32 },
            .{ .w = 800, .h = 600, .bpp = 16 },
            .{ .w = 800, .h = 600, .bpp = 32 },
            .{ .w = 1024, .h = 768, .bpp = 16 },
            .{ .w = 1024, .h = 768, .bpp = 32 },
        };

        for (modes) |mode| {
            var desc = w32.DDSURFACEDESC{};
            desc.dwSize = 108;
            desc.dwFlags = w32.DDSD_WIDTH | w32.DDSD_HEIGHT | w32.DDSD_PITCH | w32.DDSD_PIXELFORMAT;
            desc.dwHeight = mode.h;
            desc.dwWidth = mode.w;
            desc.lPitch = mode.w * (mode.bpp / 8);
            desc.dwRefreshRate = 60;

            desc.ddpfPixelFormat.dwSize = 32;
            desc.ddpfPixelFormat.dwFlags = w32.DDPF_RGB;
            desc.ddpfPixelFormat.dwRGBBitCount = mode.bpp;
            if (mode.bpp == 16) {
                desc.ddpfPixelFormat.dwRBitMask = 0xF800;
                desc.ddpfPixelFormat.dwGBitMask = 0x07E0;
                desc.ddpfPixelFormat.dwBBitMask = 0x001F;
                desc.ddpfPixelFormat.dwRGBAlphaBitMask = 0;
            } else {
                desc.ddpfPixelFormat.dwRBitMask = 0x00FF0000;
                desc.ddpfPixelFormat.dwGBitMask = 0x0000FF00;
                desc.ddpfPixelFormat.dwBBitMask = 0x000000FF;
                desc.ddpfPixelFormat.dwRGBAlphaBitMask = 0x00000000;
            }

            const cont = cb(@intFromPtr(&desc), lpContext);
            if (cont == 0) break; // DDENUMRET_CANCEL
        }
    }
    return w32.DD_OK;
}

fn surface_Blt(this: *IDirectDrawSurface, lpDestRect: usize, lpDDSrcSurface: *IDirectDrawSurface, lpSrcRect: usize, dwFlags: u32, lpDDBltFx: usize) callconv(w32cc.WINAPI) i32 {
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

fn surface_Lock(this: *IDirectDrawSurface, lpDestRect: usize, lpDDSurfaceDesc: usize, dwFlags: u32, hEvent: usize) callconv(w32cc.WINAPI) i32 {
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

fn surface_Unlock(this: *IDirectDrawSurface, lpRect: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = lpRect;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawSurface::Unlock\n", .{});
    return w32.DD_OK;
}

fn surface_Flip(this: *IDirectDrawSurface, lpDDSurfaceTargetOverride: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = lpDDSurfaceTargetOverride;
    _ = dwFlags;

    pushSurfaceFrame();
    return w32.DD_OK;
}

fn surface_GetAttachedSurface(this: *IDirectDrawSurface, lpDDSCaps: usize, lplpDDAttachedSurface: *?*IDirectDrawSurface) callconv(w32cc.WINAPI) i32 {
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

fn surface_GetCaps(this: *IDirectDrawSurface, lpDDSCaps: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (lpDDSCaps != 0) {
        @as(*align(1) u32, @ptrFromInt(lpDDSCaps)).* = w32.DDSCAPS_OFFSCREENPLAIN;
    }
    return w32.DD_OK;
}

fn surface_GetSurfaceDesc(this: *IDirectDrawSurface, lpDDSurfaceDesc: usize) callconv(w32cc.WINAPI) i32 {
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

fn surface_IsLost(this: *IDirectDrawSurface) callconv(w32cc.WINAPI) i32 {
    _ = this;
    return w32.DD_OK; // not lost
}

fn surface_Restore(this: *IDirectDrawSurface) callconv(w32cc.WINAPI) i32 {
    _ = this;
    return w32.DD_OK;
}

fn surface_SetClipper(this: *IDirectDrawSurface, lpDDClipper: usize) callconv(w32cc.WINAPI) i32 {
    _ = this; _ = lpDDClipper;
    return w32.DD_OK;
}

var clipper_vtbl: IDirectDrawClipperVtbl = undefined;
var ddraw_vtbl: IDirectDrawVtbl = undefined;
var surface_vtbl: IDirectDrawSurfaceVtbl = undefined;

// --- Exports ---

pub fn register(environment: *env.Environment) !void {
    const D1 = @intFromPtr(&ddraw_Dummy);
    const D2 = @intFromPtr(&ddraw_Dum2);
    const D3 = @intFromPtr(&ddraw_Dum3);
    const D4 = @intFromPtr(&ddraw_Dum4);
    const D5 = @intFromPtr(&ddraw_Dum5);
    const D6 = @intFromPtr(&ddraw_Dum6);

    clipper_vtbl = .{
        .QueryInterface = @ptrCast(&ddraw_QueryInterface),
        .AddRef = D1,
        .Release = ddraw_Release,
        .GetClipList = D4,      // this,rect,rgn,size
        .GetHWnd = D2,          // this,hwnd
        .Initialize = D2,       // this,dd
        .IsClipListChanged = D2, // this,changed
        .SetClipList = D3,      // this,rgn,flags
        .SetHWnd = clipper_SetHWnd,
    };

    ddraw_vtbl = .{
        .QueryInterface = @ptrCast(&ddraw_QueryInterface),
        .AddRef = D1,
        .Release = ddraw_Release,
        .Compact = D1,
        .CreateClipper = ddraw_CreateClipper,
        .CreatePalette = D5,    // this,flags,entries,pal,unk
        .CreateSurface = ddraw_CreateSurface,
        .DuplicateSurface = D3, // this,src,dst
        .EnumDisplayModes = ddraw_EnumDisplayModes,
        .EnumSurfaces = D5,     // this,flags,desc,ctx,cb
        .FlipToGDISurface = D1,
        .GetCaps = D3,          // this,drivercaps,helcaps
        .GetDisplayMode = ddraw_GetDisplayMode,
        .GetFourCCCodes = D3,   // this,numcodes,codes
        .GetGDISurface = D2,    // this,surf
        .GetMonitorFrequency = D2, // this,freq
        .GetScanLine = D2,      // this,scanline
        .GetVerticalBlankStatus = D2, // this,status
        .Initialize = D2,       // this,guid
        .RestoreDisplayMode = @ptrCast(&ddraw_RestoreDisplayMode),
        .SetCooperativeLevel = ddraw_SetCooperativeLevel,
        .SetDisplayMode = ddraw_SetDisplayMode,
        .WaitForVerticalBlank = @ptrCast(&ddraw_WaitForVerticalBlank),
        // IDirectDraw7 extras:
        .GetAvailableVidMem = D4,   // this,caps,total,free
        .GetSurfaceFromDC = D3,     // this,dc,surf
        .RestoreAllSurfaces = D1,
        .TestCooperativeLevel = D1,
        .GetDeviceIdentifier = D3,  // this,devid,flags
        .StartModeTest = D4,        // this,modes,count,flags
        .EvaluateMode = D3,         // this,flags,timeout
    };

    surface_vtbl = .{
        .QueryInterface = @ptrCast(&ddraw_QueryInterface),
        .AddRef = D1,
        .Release = ddraw_Release,
        .AddAttachedSurface = D2,     // this,surf
        .AddOverlay = D6,             // this,sr,ds,dr,f,ox
        .Blt = surface_Blt,
        .BltBatch = D4,               // this,batch,count,flags
        .BltFast = D6,                // this,x,y,surf,rect,flags
        .DeleteAttachedSurface = D3,  // this,flags,surf
        .EnumAttachedSurfaces = D3,   // this,ctx,cb
        .EnumOverlayZOrders = D4,     // this,flags,ctx,cb
        .Flip = surface_Flip,
        .GetAttachedSurface = surface_GetAttachedSurface,
        .GetBltStatus = D2,           // this,flags
        .GetCaps = @ptrCast(&surface_GetCaps),
        .GetClipper = D2,             // this,clipper
        .GetColorKey = D3,            // this,flags,ck
        .GetDC = D2,                  // this,dc
        .GetFlipStatus = D2,          // this,flags
        .GetOverlayPosition = D3,     // this,x,y
        .GetPalette = D2,             // this,pal
        .GetPixelFormat = D2,         // this,pf
        .GetSurfaceDesc = @ptrCast(&surface_GetSurfaceDesc),
        .Initialize = D3,             // this,dd,desc
        .IsLost = surface_IsLost,
        .Lock = surface_Lock,
        .ReleaseDC = D2,              // this,dc
        .Restore = surface_Restore,
        .SetClipper = surface_SetClipper,
        .SetColorKey = D3,            // this,flags,ck
        .SetOverlayPosition = D3,     // this,x,y
        .SetPalette = D2,             // this,pal
        .Unlock = surface_Unlock,
        .UpdateOverlay = D6,          // this,sr,ds,dr,f,ox
        .UpdateOverlayDisplay = D2,   // this,flags
        .UpdateOverlayZOrder = D3,    // this,flags,surf
        // IDirectDrawSurface7 extras:
        .GetDDInterface = D2,         // this,dd
        .PageLock = D2,               // this,flags
        .PageUnlock = D2,             // this,flags
        .SetSurfaceDesc = D3,         // this,desc,flags
        .SetPrivateData = D5,         // this,guid,data,size,flags
        .GetPrivateData = D4,         // this,guid,data,size
        .FreePrivateData = D2,        // this,guid
        .GetUniquenessValue = D2,     // this,val
        .ChangeUniquenessValue = D1,
        .SetPriority = D2,            // this,pri
        .GetPriority = D2,            // this,pri
        .SetLOD = D2,                 // this,lod
        .GetLOD = D2,                 // this,lod
    };

    global_ddraw.lpVtbl = &ddraw_vtbl;
    global_primary_surface.lpVtbl = &surface_vtbl;
    global_clipper.lpVtbl = &clipper_vtbl;

    const builtin_module = "DDRAW.dll";
    try environment.addBuiltinExportComptime(builtin_module, "DirectDrawCreate", stub_DirectDrawCreate);
    try environment.addBuiltinExportComptime(builtin_module, "DirectDrawCreateEx", stub_DirectDrawCreateEx);
    try environment.addBuiltinExportComptime(builtin_module, "DirectDrawEnumerateExA", stub_DirectDrawEnumerateExA);
    
    environment.addBuiltinVtableComptime(IDirectDrawVtbl, &ddraw_vtbl);
    environment.addBuiltinVtableComptime(IDirectDrawSurfaceVtbl, &surface_vtbl);
    environment.addBuiltinVtableComptime(IDirectDrawClipperVtbl, &clipper_vtbl);
}

fn stub_DirectDrawCreate(lpGUID: usize, lplpDD: *?*IDirectDraw, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpGUID;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DDRAW: DirectDrawCreate()\n", .{});

    lplpDD.* = &global_ddraw;
    return w32.DD_OK;
}

fn stub_DirectDrawCreateEx(lpGUID: usize, lplpDD: *?*anyopaque, iid: usize, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpGUID;
    _ = iid;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DDRAW: DirectDrawCreateEx()\n", .{});
    lplpDD.* = @ptrCast(&global_ddraw);
    return w32.DD_OK;
}

fn stub_DirectDrawEnumerateExA(lpCallback: usize, lpContext: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwFlags;
    if (trace.enable_tracing) trace.print("DDRAW: DirectDrawEnumerateExA()\n", .{});
    if (lpCallback != 0) {
        // Call back once with NULL GUID = primary display device
        // Must pass valid string pointers — the game's callback reads them
        const cb = @as(*const fn (usize, usize, usize, usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(lpCallback));
        _ = cb(0, @intFromPtr("Primary Display Driver\x00".ptr), @intFromPtr("display\x00".ptr), lpContext, 0);
    }
    return w32.DD_OK;
}
