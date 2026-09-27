//! DirectDraw (DDRAW.dll) implementation.
//!
//! This module provides the DirectDraw and DirectDraw7 COM interfaces,
//! as well as surface and clipper management. It uses the renderer
//! abstraction for pixel presentation.

const env = @import("../../loader/env.zig");
const x86_memory = @import("../../x86/memory.zig");
const trace = @import("../../trace.zig");
const log = @import("../../log.zig");
const renderer = @import("../../gui/renderer.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const d3d7 = @import("../d3d7/d3d7.zig");
const display_surface = @import("../display_surface.zig");

// --- COM VTables ---

/// DirectDraw COM object.
const IDirectDraw = extern struct {
    lpVtbl: *const IDirectDrawVtbl,
};

/// DirectDraw surface COM object.
const IDirectDrawSurface = extern struct {
    lpVtbl: *const IDirectDrawSurfaceVtbl,
};

/// IDirectDraw7 vtable (superset of IDirectDraw — 30 entries).
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
    SetDisplayMode: *const fn (*IDirectDraw, u32, u32, u32, u32, u32) callconv(w32cc.WINAPI) i32,
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

/// DirectDraw clipper COM object.
const IDirectDrawClipper = extern struct {
    lpVtbl: *const IDirectDrawClipperVtbl,
};

/// IDirectDrawClipper vtable.
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

/// IDirectDrawSurface7 vtable (superset of IDirectDrawSurface — 40+ entries).
const IDirectDrawSurfaceVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, usize, *?*anyopaque) callconv(w32cc.WINAPI) i32,
    AddRef: usize,
    Release: *const fn (*anyopaque) callconv(w32cc.WINAPI) u32,
    AddAttachedSurface: usize,
    AddOverlay: usize,
    Blt: *const fn (*IDirectDrawSurface, usize, usize, usize, u32, usize) callconv(w32cc.WINAPI) i32,
    BltBatch: usize,
    BltFast: *const fn (*IDirectDrawSurface, u32, u32, usize, usize, u32) callconv(w32cc.WINAPI) i32,
    DeleteAttachedSurface: usize,
    EnumAttachedSurfaces: usize,
    EnumOverlayZOrders: usize,
    Flip: *const fn (*IDirectDrawSurface, usize, u32) callconv(w32cc.WINAPI) i32,
    GetAttachedSurface: *const fn (*IDirectDrawSurface, usize, *?*IDirectDrawSurface) callconv(w32cc.WINAPI) i32,
    GetBltStatus: usize,
    GetCaps: *const fn (*IDirectDrawSurface, usize) callconv(w32cc.WINAPI) i32,
    GetClipper: usize,
    GetColorKey: usize,
    GetDC: *const fn (*IDirectDrawSurface, *u32) callconv(w32cc.WINAPI) i32,
    GetFlipStatus: usize,
    GetOverlayPosition: usize,
    GetPalette: usize,
    GetPixelFormat: *const fn (*IDirectDrawSurface, usize) callconv(w32cc.WINAPI) i32,
    GetSurfaceDesc: *const fn (*IDirectDrawSurface, usize) callconv(w32cc.WINAPI) i32,
    Initialize: usize,
    IsLost: *const fn (*IDirectDrawSurface) callconv(w32cc.WINAPI) i32,
    Lock: *const fn (*IDirectDrawSurface, usize, usize, u32, usize) callconv(w32cc.WINAPI) i32,
    ReleaseDC: *const fn (*IDirectDrawSurface, u32) callconv(w32cc.WINAPI) i32,
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

// Windows DirectDraw had no fixed surface count limit (bounded by VRAM/sysmem).
// 256 is effectively unlimited for any real game.
const MAX_SURFACES = 256;
var surface_pool: [MAX_SURFACES]IDirectDrawSurface = undefined;
var surface_widths: [MAX_SURFACES]u32 = [_]u32{0} ** MAX_SURFACES;
var surface_heights: [MAX_SURFACES]u32 = [_]u32{0} ** MAX_SURFACES;

var surface_count: u32 = 0;

// Per-surface buffer map: keyed by `this` pointer address.
// Works with dxwrapper (different `this` pointers) and native surfaces alike.
const MAX_SURFACE_BUFS = 64;
var sbuf_keys: [MAX_SURFACE_BUFS]usize = [_]usize{0} ** MAX_SURFACE_BUFS;
var sbuf_ptrs: [MAX_SURFACE_BUFS]?[*]u8 = [_]?[*]u8{null} ** MAX_SURFACE_BUFS;
var sbuf_sizes: [MAX_SURFACE_BUFS]usize = [_]usize{0} ** MAX_SURFACE_BUFS;
var sbuf_count: u32 = 0;

// The backbuffer surface (largest offscreen) — set during CreateSurface
var backbuffer_surface: ?*IDirectDrawSurface = null;
var backbuffer_w: u32 = 0;
var backbuffer_h: u32 = 0;

/// Look up the dimensions for a given surface pointer.
fn getSurfaceDims(surf: *IDirectDrawSurface) struct { w: u32, h: u32 } {
    for (0..surface_count) |i| {
        if (&surface_pool[i] == surf) {
            return .{ .w = surface_widths[i], .h = surface_heights[i] };
        }
    }
    return .{ .w = renderer.global_width, .h = renderer.global_height };
}

/// Get or allocate a per-surface buffer keyed by `this` pointer address.
fn getOrAllocSurfaceBuffer(this_addr: usize) ?[*]u8 {
    // Look up existing entry
    for (0..sbuf_count) |i| {
        if (sbuf_keys[i] == this_addr) return sbuf_ptrs[i];
    }
    // Allocate new buffer
    if (sbuf_count >= MAX_SURFACE_BUFS) return null;
    const w = renderer.global_width;
    const h = renderer.global_height;
    const size = @as(usize, w) * @as(usize, h) * 4;
    if (@import("../kernel32.zig").global_env) |genv| {
        const buf = genv.allocator.alloc(u8, size) catch return null;
        @memset(buf, 0);
        sbuf_keys[sbuf_count] = this_addr;
        sbuf_ptrs[sbuf_count] = buf.ptr;
        sbuf_sizes[sbuf_count] = size;
        sbuf_count += 1;
        if (trace.enable_tracing) trace.print("DDRAW: Allocated surface buffer for 0x{x} ({d}x{d}) buf=0x{x} trunc=0x{x}\n", .{ this_addr, w, h, @intFromPtr(buf.ptr), @as(u32, @truncate(@intFromPtr(buf.ptr))) });
        return buf.ptr;
    }
    return null;
}

/// IDirectDrawSurface::BltFast — fast blt from source surface to (dwX,dwY) on this surface.
/// Implementation status: Partially implemented (supports clipping and bpp conversion)
fn surface_BltFast(this: *IDirectDrawSurface, dwX: u32, dwY: u32, lpDDSrcSurface_raw: usize, lpSrcRect: usize, dwTrans: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwTrans;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawSurface::BltFast(dst=0x{x} x={d} y={d} src=0x{x})\n", .{ @intFromPtr(this), dwX, dwY, lpDDSrcSurface_raw });

    if (lpDDSrcSurface_raw == 0) return w32.DD_OK;

    // Get destination buffer
    const dst_buf = getOrAllocSurfaceBuffer(@intFromPtr(this)) orelse return w32.DD_OK;
    const dst_dims = getSurfaceDims(this);
    const dst_w = dst_dims.w;
    const dst_h = dst_dims.h;

    // Get source buffer
    const src_buf = getOrAllocSurfaceBuffer(lpDDSrcSurface_raw) orelse return w32.DD_OK;
    const src_surf: *IDirectDrawSurface = @ptrFromInt(lpDDSrcSurface_raw);
    const src_dims = getSurfaceDims(src_surf);
    var src_w = src_dims.w;
    var src_h = src_dims.h;

    // Parse source rect if provided (RECT: left, top, right, bottom — each i32)
    var src_left: u32 = 0;
    var src_top: u32 = 0;
    if (lpSrcRect != 0) {
        const rect = @as(*const [4]i32, @ptrFromInt(lpSrcRect));
        src_left = @intCast(@max(0, rect[0]));
        src_top = @intCast(@max(0, rect[1]));
        const right: u32 = @intCast(@max(0, rect[2]));
        const bottom: u32 = @intCast(@max(0, rect[3]));
        src_w = if (right > src_left) right - src_left else 0;
        src_h = if (bottom > src_top) bottom - src_top else 0;
    }

    const bpp: u32 = if (display_surface.bpp == 16) 2 else 4;

    // Copy pixels
    const copy_w = @min(src_w, if (dst_w > dwX) dst_w - dwX else 0);
    const copy_h = @min(src_h, if (dst_h > dwY) dst_h - dwY else 0);

    const src_pitch = src_dims.w * bpp;
    const dst_pitch = dst_w * bpp;

    for (0..copy_h) |y| {
        const src_off = (src_top + @as(u32, @intCast(y))) * src_pitch + src_left * bpp;
        const dst_off = (dwY + @as(u32, @intCast(y))) * dst_pitch + dwX * bpp;
        const row_bytes = copy_w * bpp;
        @memcpy(dst_buf[dst_off .. dst_off + row_bytes], src_buf[src_off .. src_off + row_bytes]);
    }

    return w32.DD_OK;
}

// --- Implementations ---

/// IDirectDraw::QueryInterface — queries the object for a specific interface.
/// Implementation status: Partially implemented (supports IDirect3D3 and IDirect3D7)
fn ddraw_QueryInterface(this: *anyopaque, riid: usize, ppvObj: *?*anyopaque) callconv(w32cc.WINAPI) i32 {
    if (riid != 0) {
        const first_dword = @as(*const u32, @ptrFromInt(riid)).*;
        if (trace.enable_tracing) trace.print("DDRAW: QueryInterface(riid=0x{x}, guid_dword=0x{x:0>8})\n", .{ riid, first_dword });
        if (first_dword == 0xBB223240) { // IID_IDirect3D3
            if (trace.enable_tracing) trace.print("DDRAW: QueryInterface -> IDirect3D3\n", .{});
            ppvObj.* = @ptrCast(&d3d7.global_d3d3);
            return w32.S_OK;
        }
        if (first_dword == 0xF5049E77 or // IID_IDirect3D7
            first_dword == 0x84E63dE0) // IID_IDirect3D
        {
            if (trace.enable_tracing) trace.print("DDRAW: QueryInterface -> IDirect3D7\n", .{});
            ppvObj.* = @ptrCast(&d3d7.global_d3d7);
            return w32.S_OK;
        }
        if (first_dword == 0x93281502) { // IID_IDirect3DTexture2
            if (trace.enable_tracing) trace.print("DDRAW: QueryInterface -> IDirect3DTexture2\n", .{});
            ppvObj.* = @ptrCast(d3d7.allocTexture());
            return w32.S_OK;
        }
    } else {
        if (trace.enable_tracing) trace.print("DDRAW: QueryInterface(riid=NULL)\n", .{});
    }

    // For IDirectDraw upgrades (IDirectDraw4, IDirectDraw7, etc.), return self
    ppvObj.* = this;
    return w32.S_OK;
}

/// Release a surface's pixel buffer, if it owns one.
/// Returns the buffer size in bytes, or null when this address owns none.
fn releaseSurfaceBuffer(this_addr: usize) ?usize {
    for (0..sbuf_count) |i| {
        if (sbuf_keys[i] != this_addr) continue;
        const size = sbuf_sizes[i];
        if (@import("../kernel32.zig").global_env) |genv| {
            if (sbuf_ptrs[i]) |p| genv.allocator.free(p[0..size]);
        }
        sbuf_count -= 1;
        if (i != sbuf_count) {
            sbuf_keys[i] = sbuf_keys[sbuf_count];
            sbuf_ptrs[i] = sbuf_ptrs[sbuf_count];
            sbuf_sizes[i] = sbuf_sizes[sbuf_count];
        }
        sbuf_keys[sbuf_count] = 0;
        sbuf_ptrs[sbuf_count] = null;
        return size;
    }
    return null;
}

/// IDirectDraw::Release — decrements the reference count.
/// For IDirectDrawSurface this also returns the surface's pixel buffer, which
/// is a full w*h*4 allocation; without this the per-surface table fills up and
/// every later surface renders as a blank source.
/// Implementation status: Stub
fn ddraw_Release(this: *anyopaque) callconv(w32cc.WINAPI) u32 {
    _ = releaseSurfaceBuffer(@intFromPtr(this));
    return 0;
}

/// IDirectDraw::Dummy — placeholder for unimplemented methods.
/// Implementation status: Stub
fn ddraw_Dummy(this: *anyopaque) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DDRAW: Dummy(this=0x{x})\n", .{@intFromPtr(this)});
    return w32.DD_OK;
}

// Dummy stubs for different argument counts (stdcall requires callee cleanup)
fn ddraw_Dum2(a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    if (trace.enable_tracing) trace.print("DDRAW: Dummy2\n", .{});
    return w32.DD_OK;
}

fn ddraw_Dum3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DDRAW: Dummy3(this=0x{x}, 0x{x}, 0x{x})\n", .{ a, b, c });
    return w32.DD_OK;
}

fn ddraw_Dum4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    if (trace.enable_tracing) trace.print("DDRAW: Dummy4\n", .{});
    return w32.DD_OK;
}

fn ddraw_Dum5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DDRAW: Dummy5(this=0x{x}, 0x{x}, 0x{x}, 0x{x}, 0x{x})\n", .{ a, b, c, d, e });
    return w32.DD_OK;
}

// Comptime-generic traced stubs for DDraw surface methods
fn surf_tn1(comptime name: []const u8) fn (usize) callconv(w32cc.WINAPI) i32 {
    return struct {
        fn func(_: usize) callconv(w32cc.WINAPI) i32 {
            if (trace.enable_tracing) trace.print("DDRAW.Surf: " ++ name ++ "\n", .{});
            return 0;
        }
    }.func;
}
fn surf_tn2(comptime name: []const u8) fn (usize, usize) callconv(w32cc.WINAPI) i32 {
    return struct {
        fn func(_: usize, _: usize) callconv(w32cc.WINAPI) i32 {
            if (trace.enable_tracing) trace.print("DDRAW.Surf: " ++ name ++ "\n", .{});
            return 0;
        }
    }.func;
}
fn surf_tn3(comptime name: []const u8) fn (usize, usize, usize) callconv(w32cc.WINAPI) i32 {
    return struct {
        fn func(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
            if (trace.enable_tracing) trace.print("DDRAW.Surf: " ++ name ++ "(0x{x}, 0x{x}, 0x{x})\n", .{ a, b, c });
            return 0;
        }
    }.func;
}
fn surf_tn4(comptime name: []const u8) fn (usize, usize, usize, usize) callconv(w32cc.WINAPI) i32 {
    return struct {
        fn func(_: usize, _: usize, _: usize, _: usize) callconv(w32cc.WINAPI) i32 {
            if (trace.enable_tracing) trace.print("DDRAW.Surf: " ++ name ++ "\n", .{});
            return 0;
        }
    }.func;
}
fn surf_tn5(comptime name: []const u8) fn (usize, usize, usize, usize, usize) callconv(w32cc.WINAPI) i32 {
    return struct {
        fn func(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) i32 {
            if (trace.enable_tracing) trace.print("DDRAW.Surf: " ++ name ++ "(0x{x}, 0x{x}, 0x{x}, 0x{x}, 0x{x})\n", .{ a, b, c, d, e });
            return 0;
        }
    }.func;
}
fn surf_tn6(comptime name: []const u8) fn (usize, usize, usize, usize, usize, usize) callconv(w32cc.WINAPI) i32 {
    return struct {
        fn func(_: usize, _: usize, _: usize, _: usize, _: usize, _: usize) callconv(w32cc.WINAPI) i32 {
            if (trace.enable_tracing) trace.print("DDRAW.Surf: " ++ name ++ "\n", .{});
            return 0;
        }
    }.func;
}

/// IDirectDrawClipper::SetHWnd — sets the window handle to be used for clipping.
/// Implementation status: Stub
fn clipper_SetHWnd(this: *IDirectDrawClipper, dwFlags: u32, hWnd: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = dwFlags;
    _ = hWnd;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawClipper::SetHWnd\n", .{});
    return w32.DD_OK;
}

/// IDirectDraw::CreateClipper — creates a DirectDrawClipper object.
/// Implementation status: Partially implemented (returns global instance)
fn ddraw_CreateClipper(this: *IDirectDraw, dwFlags: u32, lplpDDClipper: *?*IDirectDrawClipper, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = dwFlags;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::CreateClipper\n", .{});
    lplpDDClipper.* = &global_clipper;
    return w32.DD_OK;
}

/// IDirectDraw::CreateSurface — creates a DirectDrawSurface object.
/// Implementation status: Partially implemented (supports primary, backbuffer, and offscreen surfaces)
fn ddraw_CreateSurface(this: *IDirectDraw, lpDDSurfaceDesc: usize, lplpDDSurface: *?*IDirectDrawSurface, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = pUnkOuter;

    // Ensure shared surface buffer exists (fallback for shared operations)
    if (display_surface.buffer.len == 0) {
        if (@import("../kernel32.zig").global_env) |genv| {
            display_surface.buffer = genv.allocator.alloc(u8, 2048 * 2048 * 4) catch {
                log.err("ddraw: failed to allocate 16MB surface buffer", .{});
                return @bitCast(@as(u32, 0x8007000E)); // E_OUTOFMEMORY
            };
            @memset(display_surface.buffer, 0);
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

    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::CreateSurface({d}x{d} flags=0x{x} caps=0x{x} bbcount={d} size={d})\n", .{ w, h, flags, caps, back_buffer_count, if (lpDDSurfaceDesc != 0) @as(*u32, @ptrFromInt(lpDDSurfaceDesc)).* else @as(u32, 0) });

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

            // Track as backbuffer only if it matches the display mode dimensions
            // (don't let offscreen sprite/texture surfaces override the resolution)
            if (w == display_surface.width and h == display_surface.height and backbuffer_surface == null) {
                backbuffer_surface = &surface_pool[idx];
                backbuffer_w = w;
                backbuffer_h = h;
            }
        } else {
            lplpDDSurface.* = &global_primary_surface;
        }
    } else {
        // Primary surface (no explicit dimensions)
        lplpDDSurface.* = &global_primary_surface;

        // In fullscreen mode, set resolution and create implicit backbuffer
        const is_fullscreen = display_surface.bpp != 32 or display_surface.width != 640 or display_surface.height != 480;
        if (is_fullscreen or back_buffer_count > 0) {
            renderer.setResolution(display_surface.width, display_surface.height);

            // Create an implicit backbuffer in the pool
            if (surface_count < MAX_SURFACES) {
                const idx = surface_count;
                surface_pool[idx].lpVtbl = &surface_vtbl;
                surface_widths[idx] = display_surface.width;
                surface_heights[idx] = display_surface.height;
                surface_count += 1;
                backbuffer_surface = &surface_pool[idx];
                backbuffer_w = display_surface.width;
                backbuffer_h = display_surface.height;
            }
        }
    }
    return w32.DD_OK;
}

/// IDirectDraw::SetCooperativeLevel — determines how the application interacts with the display.
/// Implementation status: Stub
fn ddraw_SetCooperativeLevel(this: *IDirectDraw, hWnd: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = hWnd;
    _ = dwFlags;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::SetCooperativeLevel\n", .{});
    return w32.DD_OK;
}

/// IDirectDraw::SetDisplayMode — sets the mode of the display-device hardware.
/// Implementation status: Partially implemented (updates internal state and renderer resolution)
fn ddraw_SetDisplayMode(this: *IDirectDraw, dwWidth: u32, dwHeight: u32, dwBPP: u32, dwRefreshRate: u32, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = dwRefreshRate;
    _ = dwFlags;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::SetDisplayMode({d}x{d} @ {d}bpp)\n", .{ dwWidth, dwHeight, dwBPP });
    display_surface.width = dwWidth;
    display_surface.height = dwHeight;
    display_surface.bpp = dwBPP;

    // In fullscreen DDraw mode, the window client area equals the display mode.
    // This ensures GetClientRect returns correct dimensions if the game cached
    // them during WM_CREATE (before SetWindowPos expanded the window).
    const user32 = @import("../user32.zig");
    user32.current_client_width = @intCast(dwWidth);
    user32.current_client_height = @intCast(dwHeight);

    // Reset surface pool — app will create new surfaces
    surface_count = 0;
    backbuffer_surface = null;
    backbuffer_w = 0;
    backbuffer_h = 0;
    return w32.DD_OK;
}

/// IDirectDraw::RestoreDisplayMode — restores the display mode to the original mode.
/// Implementation status: Partially implemented (resets to 640x480x32)
fn ddraw_RestoreDisplayMode(this: *IDirectDraw) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::RestoreDisplayMode\n", .{});
    display_surface.width = 640;
    display_surface.height = 480;
    display_surface.bpp = 32;
    return w32.DD_OK;
}

/// IDirectDraw::WaitForVerticalBlank — waits for the vertical blank interval.
/// Implementation status: Stub
fn ddraw_WaitForVerticalBlank(this: *IDirectDraw, dwFlags: u32, hEvent: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = dwFlags;
    _ = hEvent;
    return w32.DD_OK;
}

/// IDirectDraw::GetDisplayMode — retrieves the current display mode.
/// Implementation status: Partially implemented (returns current width, height, and pixel format)
fn ddraw_GetDisplayMode(this: *IDirectDraw, lpDDSurfaceDesc: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    const ret_addr = @returnAddress();
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::GetDisplayMode (ret: 0x{x})\n", .{ret_addr});

    if (lpDDSurfaceDesc != 0) {
        const desc = @as(*w32.DDSURFACEDESC, @ptrFromInt(lpDDSurfaceDesc));
        desc.dwSize = 108;
        desc.dwFlags = w32.DDSD_WIDTH | w32.DDSD_HEIGHT | w32.DDSD_PIXELFORMAT;
        desc.dwHeight = display_surface.height;
        desc.dwWidth = display_surface.width;

        desc.ddpfPixelFormat.dwSize = 32;
        desc.ddpfPixelFormat.dwFlags = w32.DDPF_RGB;
        desc.ddpfPixelFormat.dwFourCC = 0;
        desc.ddpfPixelFormat.dwRGBBitCount = display_surface.bpp;
        if (display_surface.bpp == 16) {
            desc.ddpfPixelFormat.dwRBitMask = 0xF800; // RGB565
            desc.ddpfPixelFormat.dwGBitMask = 0x07E0;
            desc.ddpfPixelFormat.dwBBitMask = 0x001F;
            desc.ddpfPixelFormat.dwRGBAlphaBitMask = 0;
        } else {
            desc.ddpfPixelFormat.dwRBitMask = 0x00FF0000; // BGRA8888
            desc.ddpfPixelFormat.dwGBitMask = 0x0000FF00;
            desc.ddpfPixelFormat.dwBBitMask = 0x000000FF;
            desc.ddpfPixelFormat.dwRGBAlphaBitMask = 0xFF000000;
        }
    }
    return w32.DD_OK;
}

/// IDirectDraw::EnumDisplayModes — enumerates all of the display modes the hardware supports.
/// Implementation status: Partially implemented (enumerates several common modes)
fn ddraw_EnumDisplayModes(this: *IDirectDraw, dwFlags: u32, lpDDSurfaceDesc: usize, lpContext: usize, lpEnumCallback: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = dwFlags;
    _ = lpDDSurfaceDesc;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDraw::EnumDisplayModes\n", .{});
    if (lpEnumCallback != 0) {
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

            const cont = ddrawCallEnumCallback(lpEnumCallback, @intFromPtr(&desc), lpContext);
            if (cont == 0) break; // DDENUMRET_CANCEL
        }
    }
    return w32.DD_OK;
}

/// Invoke a 32-bit guest callback with (arg0, arg1): direct on native x86,
/// via the compat dispatcher on native x86_64 (a direct 64-bit call
/// misdecodes the 32-bit machine code), interpreter on WASM.
fn ddrawCallEnumCallback(cb_addr: usize, arg0: usize, arg1: usize) i32 {
    const platform = @import("../../platform.zig");
    if (comptime platform.is_x86) {
        const cb = @as(*const fn (usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(cb_addr));
        return cb(arg0, arg1);
    }
    if (comptime platform.is_x86_64) {
        const compat = @import("../../x86/compat_thunks.zig");
        return @bitCast(compat.callCompat32_4(@truncate(cb_addr), @truncate(arg0), @truncate(arg1), 0, 0));
    }
    // WASM: interpreter.
    const x86_cpu = @import("../../x86/cpu.zig");
    const x86_execute = @import("../../x86/execute.zig");
    var cpu = x86_cpu.Cpu{};
    if (x86_memory.guest_memory) |gm| cpu.memory = gm.*;
    var stack: [256]u8 = undefined;
    cpu.esp = @truncate(@intFromPtr(&stack) + stack.len - 16);
    cpu.push32(@intCast(arg1));
    cpu.push32(@intCast(arg0));
    cpu.push32(0);
    cpu.eip = @intCast(cb_addr);
    x86_execute.run(&cpu);
    return @bitCast(cpu.eax);
}

/// IDirectDrawSurface::Blt — performs a bit block transfer.
/// Implementation status: Partially implemented (supports color fill and basic blitting to primary)
fn surface_Blt(this: *IDirectDrawSurface, lpDestRect: usize, lpDDSrcSurface_raw: usize, lpSrcRect: usize, dwFlags: u32, lpDDBltFx: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) {
        trace.print("DDRAW: IDirectDrawSurface::Blt (dst=0x{x} src=0x{x} flags=0x{x})\n", .{ @intFromPtr(this), lpDDSrcSurface_raw, dwFlags });
        if (lpDestRect != 0) {
            const dr = @as(*const [4]i32, @ptrFromInt(lpDestRect));
            trace.print("DDRAW:   dstRect=({d},{d})-({d},{d})\n", .{ dr[0], dr[1], dr[2], dr[3] });
        }
        if (lpSrcRect != 0) {
            const sr = @as(*const [4]i32, @ptrFromInt(lpSrcRect));
            trace.print("DDRAW:   srcRect=({d},{d})-({d},{d})\n", .{ sr[0], sr[1], sr[2], sr[3] });
        }
    }

    const DDBLT_COLORFILL = 0x00000400;

    // Color fill — write to the per-surface buffer for THIS surface
    if (lpDDSrcSurface_raw == 0) {
        if ((dwFlags & DDBLT_COLORFILL) != 0 and lpDDBltFx != 0) {
            const fill_color = @as(*align(1) u32, @ptrFromInt(lpDDBltFx + 76)).*;
            if (trace.enable_tracing) trace.print("DDRAW: Blt color fill = 0x{x:0>8}\n", .{fill_color});
            const buf = getOrAllocSurfaceBuffer(@intFromPtr(this)) orelse return w32.DD_OK;
            const w = renderer.global_width;
            const h = renderer.global_height;
            const pixels = @as(usize, w) * @as(usize, h);
            if (display_surface.bpp == 16) {
                // In 16bpp mode, fill_color is a raw 16-bit value
                const fill16: u16 = @truncate(fill_color);
                const lo: u8 = @truncate(fill16);
                const hi: u8 = @truncate(fill16 >> 8);
                for (0..pixels) |i| {
                    buf[i * 2 + 0] = lo;
                    buf[i * 2 + 1] = hi;
                }
            } else {
                const b: u8 = @intCast(fill_color & 0xFF);
                const g: u8 = @intCast((fill_color >> 8) & 0xFF);
                const r: u8 = @intCast((fill_color >> 16) & 0xFF);
                for (0..pixels) |i| {
                    buf[i * 4 + 0] = b;
                    buf[i * 4 + 1] = g;
                    buf[i * 4 + 2] = r;
                    buf[i * 4 + 3] = 255;
                }
            }
            // Don't push frame here — the game will call Flip() to present.
            // Pushing on every Blt color-fill causes flickering (black frames).
        }
        return w32.DD_OK;
    }

    // Blt with source to PRIMARY surface = windowed-mode present.
    // Only push frame when blitting TO the primary surface (this == primary).
    if (this == &global_primary_surface) {
        const src_buf = getOrAllocSurfaceBuffer(lpDDSrcSurface_raw) orelse display_surface.buffer.ptr;
        const src_surf: *IDirectDrawSurface = @ptrFromInt(lpDDSrcSurface_raw);
        const src_dims = getSurfaceDims(src_surf);
        pushSurfaceFrameFrom(src_buf, src_dims.w, src_dims.h);
    } else {
        // Blt between offscreen surfaces — just copy pixels, don't present
        const src_buf = getOrAllocSurfaceBuffer(lpDDSrcSurface_raw) orelse return w32.DD_OK;
        const dst_buf = getOrAllocSurfaceBuffer(@intFromPtr(this)) orelse return w32.DD_OK;
        const src_surf: *IDirectDrawSurface = @ptrFromInt(lpDDSrcSurface_raw);
        const src_dims = getSurfaceDims(src_surf);
        const bpp: u32 = if (display_surface.bpp == 16) 2 else 4;
        const size = @as(usize, src_dims.w) * @as(usize, src_dims.h) * bpp;
        @memcpy(dst_buf[0..size], src_buf[0..size]);
    }

    return w32.DD_OK;
}

/// Push frame from a specific source buffer (used for Blt to primary).
/// Supports nearest-neighbor scaling when source dims differ from viewport.
fn pushSurfaceFrameFrom(src: [*]u8, w: u32, h: u32) void {
    const vw = renderer.global_width;
    const vh = renderer.global_height;

    if (renderer.global_framebuf.len < vw * vh * 4) return;
    if (w == 0 or h == 0) return;

    if (w == vw and h == vh) {
        // Fast path: source matches viewport — direct pixel copy
        if (display_surface.bpp == 16) {
            for (0..@as(usize, vh)) |y| {
                for (0..@as(usize, vw)) |x| {
                    const si = y * @as(usize, w) + x;
                    const di = y * @as(usize, vw) + x;
                    display_surface.unpack16To32(src, si, di);
                }
            }
        } else {
            for (0..@as(usize, vh)) |y| {
                for (0..@as(usize, vw)) |x| {
                    const si = y * @as(usize, w) + x;
                    const di = y * @as(usize, vw) + x;
                    display_surface.unpack32To32(src, si, di);
                }
            }
        }
    } else {
        // Scaled path: nearest-neighbor resampling from source to viewport
        if (display_surface.bpp == 16) {
            for (0..@as(usize, vh)) |dy| {
                const sy = (dy * @as(usize, h)) / @as(usize, vh);
                for (0..@as(usize, vw)) |dx| {
                    const sx = (dx * @as(usize, w)) / @as(usize, vw);
                    const si = sy * @as(usize, w) + sx;
                    const di = dy * @as(usize, vw) + dx;
                    display_surface.unpack16To32(src, si, di);
                }
            }
        } else {
            for (0..@as(usize, vh)) |dy| {
                const sy = (dy * @as(usize, h)) / @as(usize, vh);
                for (0..@as(usize, vw)) |dx| {
                    const sx = (dx * @as(usize, w)) / @as(usize, vw);
                    const si = sy * @as(usize, w) + sx;
                    const di = dy * @as(usize, vw) + dx;
                    display_surface.unpack32To32(src, si, di);
                }
            }
        }
    }
    renderer.pushFrame();
}

/// IDirectDrawSurface::Lock — obtains a pointer to the surface memory.
/// Implementation status: Partially implemented (returns pointer to per-surface buffer)
fn surface_Lock(this: *IDirectDrawSurface, lpDestRect: usize, lpDDSurfaceDesc: usize, dwFlags: u32, hEvent: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpDestRect;
    _ = dwFlags;
    _ = hEvent;
    const bytes_per_pixel: u32 = if (display_surface.bpp == 16) 2 else 4;
    const dims = getSurfaceDims(this);
    const w = dims.w;
    const h = dims.h;
    if (trace.enable_tracing) {
        trace.print("DDRAW: IDirectDrawSurface::Lock (this=0x{x} dims={d}x{d} pitch={d} bpp={d})\n", .{ @intFromPtr(this), w, h, w * bytes_per_pixel, display_surface.bpp });
    }
    if (lpDDSurfaceDesc != 0) {
        const desc = @as(*w32.DDSURFACEDESC, @ptrFromInt(lpDDSurfaceDesc));
        // Get or allocate per-surface buffer keyed by this pointer
        const buf = getOrAllocSurfaceBuffer(@intFromPtr(this)) orelse display_surface.buffer.ptr;
        desc.lpSurface = @truncate(@intFromPtr(buf));
        desc.lPitch = w * bytes_per_pixel;
        desc.dwWidth = w;
        desc.dwHeight = h;
    }
    return w32.DD_OK;
}

/// IDirectDrawSurface::GetDC — retrieves a device context for the surface.
/// Implementation status: Stub (returns dummy DC handle)
fn surface_GetDC(this: *IDirectDrawSurface, lphDC: *u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawSurface::GetDC(this=0x{x})\n", .{@intFromPtr(this)});
    // Return a dummy DC handle (non-zero so caller thinks it succeeded)
    lphDC.* = 0xDC000001;
    return w32.DD_OK;
}

/// IDirectDrawSurface::ReleaseDC — releases the device context.
/// Implementation status: Stub
fn surface_ReleaseDC(this: *IDirectDrawSurface, hDC: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawSurface::ReleaseDC(hDC=0x{x})\n", .{hDC});
    return w32.DD_OK;
}

/// IDirectDrawSurface::Unlock — notifies DirectDraw that the surface memory is no longer being used.
/// Implementation status: Stub
fn surface_Unlock(this: *IDirectDrawSurface, lpRect: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpRect;
    if (trace.enable_tracing) {
        // Check if the surface buffer has any non-zero data
        if (getOrAllocSurfaceBuffer(@intFromPtr(this))) |buf| {
            var non_zero: u32 = 0;
            const check_len: usize = @min(1024 * 768 * 2, 4096); // check first 4KB
            for (0..check_len) |i| {
                if (buf[i] != 0) non_zero += 1;
            }
            trace.print("DDRAW: IDirectDrawSurface::Unlock (this=0x{x}, non-zero bytes in first 4KB: {d})\n", .{ @intFromPtr(this), non_zero });
        } else {
            trace.print("DDRAW: IDirectDrawSurface::Unlock (no buffer)\n", .{});
        }
    }
    // Don't push frame on Unlock — the game will call Flip() to present.
    // Pushing on every Unlock causes flickering (partial frames).
    return w32.DD_OK;
}

/// IDirectDrawSurface::Flip — makes the surface memory associated with the back buffer associated with the primary surface.
/// Implementation status: Partially implemented (presents the backbuffer to the renderer)
fn surface_Flip(this: *IDirectDrawSurface, lpDDSurfaceTargetOverride: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwFlags;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawSurface::Flip (this=0x{x} override=0x{x} bb=0x{x})\n", .{
        @intFromPtr(this),
        lpDDSurfaceTargetOverride,
        if (backbuffer_surface) |bb| @intFromPtr(bb) else @as(usize, 0),
    });

    // In fullscreen mode, Flip presents the backbuffer.
    // Try the explicit target override first, then the backbuffer surface.
    var src_buf: ?[*]u8 = null;

    if (lpDDSurfaceTargetOverride != 0) {
        // Explicit target: look up its per-surface buffer
        src_buf = getOrAllocSurfaceBuffer(lpDDSurfaceTargetOverride);
    }

    if (src_buf == null) {
        // Try the backbuffer surface's pool address
        if (backbuffer_surface) |bb| {
            src_buf = getOrAllocSurfaceBuffer(@intFromPtr(bb));
        }
    }

    if (src_buf == null) {
        // Last resort: scan all allocated surface buffers for the first non-primary one
        for (0..sbuf_count) |i| {
            if (sbuf_keys[i] != @intFromPtr(&global_primary_surface)) {
                src_buf = sbuf_ptrs[i];
                break;
            }
        }
    }

    if (src_buf) |buf| {
        pushSurfaceFrameFrom(buf, renderer.global_width, renderer.global_height);
    } else {
        display_surface.pushFrame();
    }
    return w32.DD_OK;
}

/// IDirectDrawSurface::GetAttachedSurface — retrieves the attached surface.
/// Implementation status: Partially implemented (returns the backbuffer)
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

/// IDirectDrawSurface::GetCaps — retrieves the capabilities of the surface.
/// Implementation status: Stub
fn surface_GetCaps(this: *IDirectDrawSurface, lpDDSCaps: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (lpDDSCaps != 0) {
        @as(*align(1) u32, @ptrFromInt(lpDDSCaps)).* = w32.DDSCAPS_OFFSCREENPLAIN;
    }
    return w32.DD_OK;
}

/// IDirectDrawSurface::GetSurfaceDesc — retrieves a description of the surface.
/// Implementation status: Partially implemented (returns dimensions and pixel format)
fn surface_GetSurfaceDesc(this: *IDirectDrawSurface, lpDDSurfaceDesc: usize) callconv(w32cc.WINAPI) i32 {
    const dims = getSurfaceDims(this);
    const bytes_per_pixel: u32 = if (display_surface.bpp == 16) 2 else 4;
    if (lpDDSurfaceDesc != 0) {
        const desc = @as(*w32.DDSURFACEDESC, @ptrFromInt(lpDDSurfaceDesc));
        desc.dwSize = 108;
        desc.dwFlags = w32.DDSD_WIDTH | w32.DDSD_HEIGHT | w32.DDSD_PITCH | w32.DDSD_PIXELFORMAT | w32.DDSD_CAPS;
        desc.dwHeight = dims.h;
        desc.dwWidth = dims.w;
        desc.lPitch = dims.w * bytes_per_pixel;
        // Pixel format
        desc.ddpfPixelFormat.dwSize = 32;
        if (display_surface.bpp == 16) {
            desc.ddpfPixelFormat.dwFlags = 0x40; // DDPF_RGB
            desc.ddpfPixelFormat.dwRGBBitCount = 16;
            desc.ddpfPixelFormat.dwRBitMask = 0xF800;
            desc.ddpfPixelFormat.dwGBitMask = 0x07E0;
            desc.ddpfPixelFormat.dwBBitMask = 0x001F;
            desc.ddpfPixelFormat.dwRGBAlphaBitMask = 0;
        } else {
            desc.ddpfPixelFormat.dwFlags = 0x40; // DDPF_RGB
            desc.ddpfPixelFormat.dwRGBBitCount = 32;
            desc.ddpfPixelFormat.dwRBitMask = 0x00FF0000;
            desc.ddpfPixelFormat.dwGBitMask = 0x0000FF00;
            desc.ddpfPixelFormat.dwBBitMask = 0x000000FF;
            desc.ddpfPixelFormat.dwRGBAlphaBitMask = 0xFF000000;
        }
        // Caps
        desc.ddsCaps.dwCaps = 0x40; // DDSCAPS_OFFSCREENPLAIN
    }
    return w32.DD_OK;
}

/// IDirectDrawSurface::GetPixelFormat — retrieves the pixel format of the surface.
/// Implementation status: Partially implemented (returns current display mode pixel format)
fn surface_GetPixelFormat(this: *IDirectDrawSurface, lpDDPixelFormat: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DDRAW: IDirectDrawSurface::GetPixelFormat\n", .{});
    if (lpDDPixelFormat != 0) {
        const pf = @as(*w32.DDPIXELFORMAT, @ptrFromInt(lpDDPixelFormat));
        pf.dwSize = 32;
        if (display_surface.bpp == 16) {
            pf.dwFlags = 0x40; // DDPF_RGB
            pf.dwRGBBitCount = 16;
            pf.dwRBitMask = 0xF800;
            pf.dwGBitMask = 0x07E0;
            pf.dwBBitMask = 0x001F;
            pf.dwRGBAlphaBitMask = 0;
        } else {
            pf.dwFlags = 0x40; // DDPF_RGB
            pf.dwRGBBitCount = 32;
            pf.dwRBitMask = 0x00FF0000;
            pf.dwGBitMask = 0x0000FF00;
            pf.dwBBitMask = 0x000000FF;
            pf.dwRGBAlphaBitMask = 0xFF000000;
        }
    }
    return w32.DD_OK;
}

/// IDirectDrawSurface::IsLost — determines whether the surface memory has been freed.
/// Implementation status: Stub (always returns DD_OK)
fn surface_IsLost(this: *IDirectDrawSurface) callconv(w32cc.WINAPI) i32 {
    _ = this;
    return w32.DD_OK; // not lost
}

/// IDirectDrawSurface::Restore — restores a surface that has been lost.
/// Implementation status: Stub
fn surface_Restore(this: *IDirectDrawSurface) callconv(w32cc.WINAPI) i32 {
    _ = this;
    return w32.DD_OK;
}

/// IDirectDrawSurface::SetClipper — attaches a clipper object to the surface.
/// Implementation status: Stub
fn surface_SetClipper(this: *IDirectDrawSurface, lpDDClipper: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = lpDDClipper;
    return w32.DD_OK;
}

var clipper_vtbl: IDirectDrawClipperVtbl = undefined;
var ddraw_vtbl: IDirectDrawVtbl = undefined;
var surface_vtbl: IDirectDrawSurfaceVtbl = undefined;

/// Registers the DirectDraw module and its vtables.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const comPtr = @import("../../x86/thunks.zig").comPtr;
    const D1: usize = comPtr(ddraw_Dummy, "IDirectDraw::Dummy1");
    const D2: usize = comPtr(ddraw_Dum2, "IDirectDraw::Dummy2");
    const D3: usize = comPtr(ddraw_Dum3, "IDirectDraw::Dummy3");
    const D4: usize = comPtr(ddraw_Dum4, "IDirectDraw::Dummy4");
    const D5: usize = comPtr(ddraw_Dum5, "IDirectDraw::Dummy5");

    clipper_vtbl = .{
        .QueryInterface = @ptrCast(&ddraw_QueryInterface),
        .AddRef = D1,
        .Release = ddraw_Release,
        .GetClipList = D4, // this,rect,rgn,size
        .GetHWnd = D2, // this,hwnd
        .Initialize = D2, // this,dd
        .IsClipListChanged = D2, // this,changed
        .SetClipList = D3, // this,rgn,flags
        .SetHWnd = clipper_SetHWnd,
    };

    ddraw_vtbl = .{
        .QueryInterface = @ptrCast(&ddraw_QueryInterface),
        .AddRef = D1,
        .Release = ddraw_Release,
        .Compact = D1,
        .CreateClipper = ddraw_CreateClipper,
        .CreatePalette = D5, // this,flags,entries,pal,unk
        .CreateSurface = ddraw_CreateSurface,
        .DuplicateSurface = D3, // this,src,dst
        .EnumDisplayModes = ddraw_EnumDisplayModes,
        .EnumSurfaces = D5, // this,flags,desc,ctx,cb
        .FlipToGDISurface = D1,
        .GetCaps = D3, // this,drivercaps,helcaps
        .GetDisplayMode = ddraw_GetDisplayMode,
        .GetFourCCCodes = D3, // this,numcodes,codes
        .GetGDISurface = D2, // this,surf
        .GetMonitorFrequency = D2, // this,freq
        .GetScanLine = D2, // this,scanline
        .GetVerticalBlankStatus = D2, // this,status
        .Initialize = D2, // this,guid
        .RestoreDisplayMode = @ptrCast(&ddraw_RestoreDisplayMode),
        .SetCooperativeLevel = ddraw_SetCooperativeLevel,
        .SetDisplayMode = ddraw_SetDisplayMode,
        .WaitForVerticalBlank = @ptrCast(&ddraw_WaitForVerticalBlank),
        // IDirectDraw7 extras:
        .GetAvailableVidMem = D4, // this,caps,total,free
        .GetSurfaceFromDC = D3, // this,dc,surf
        .RestoreAllSurfaces = D1,
        .TestCooperativeLevel = D1,
        .GetDeviceIdentifier = D3, // this,devid,flags
        .StartModeTest = D4, // this,modes,count,flags
        .EvaluateMode = D3, // this,flags,timeout
    };

    surface_vtbl = .{
        .QueryInterface = @ptrCast(&ddraw_QueryInterface),
        .AddRef = comPtr(surf_tn1("AddRef"), "IDirectDrawSurface::AddRef"),
        .Release = ddraw_Release,
        .AddAttachedSurface = comPtr(surf_tn2("AddAttachedSurface"), "IDirectDrawSurface::AddAttachedSurface"),
        .AddOverlay = comPtr(surf_tn6("AddOverlayDirtyRect"), "IDirectDrawSurface::AddOverlayDirtyRect"),
        .Blt = surface_Blt,
        .BltBatch = comPtr(surf_tn4("BltBatch"), "IDirectDrawSurface::BltBatch"),
        .BltFast = surface_BltFast,
        .DeleteAttachedSurface = comPtr(surf_tn3("DeleteAttachedSurface"), "IDirectDrawSurface::DeleteAttachedSurface"),
        .EnumAttachedSurfaces = comPtr(surf_tn3("EnumAttachedSurfaces"), "IDirectDrawSurface::EnumAttachedSurfaces"),
        .EnumOverlayZOrders = comPtr(surf_tn4("EnumOverlayZOrders"), "IDirectDrawSurface::EnumOverlayZOrders"),
        .Flip = surface_Flip,
        .GetAttachedSurface = surface_GetAttachedSurface,
        .GetBltStatus = comPtr(surf_tn2("GetBltStatus"), "IDirectDrawSurface::GetBltStatus"),
        .GetCaps = @ptrCast(&surface_GetCaps),
        .GetClipper = comPtr(surf_tn2("GetClipper"), "IDirectDrawSurface::GetClipper"),
        .GetColorKey = comPtr(surf_tn3("GetColorKey"), "IDirectDrawSurface::GetColorKey"),
        .GetDC = surface_GetDC,
        .GetFlipStatus = comPtr(surf_tn2("GetFlipStatus"), "IDirectDrawSurface::GetFlipStatus"),
        .GetOverlayPosition = comPtr(surf_tn3("GetOverlayPosition"), "IDirectDrawSurface::GetOverlayPosition"),
        .GetPalette = comPtr(surf_tn2("GetPalette"), "IDirectDrawSurface::GetPalette"),
        .GetPixelFormat = @ptrCast(&surface_GetPixelFormat),
        .GetSurfaceDesc = @ptrCast(&surface_GetSurfaceDesc),
        .Initialize = comPtr(surf_tn3("Initialize"), "IDirectDrawSurface::Initialize"),
        .IsLost = surface_IsLost,
        .Lock = surface_Lock,
        .ReleaseDC = surface_ReleaseDC,
        .Restore = surface_Restore,
        .SetClipper = surface_SetClipper,
        .SetColorKey = comPtr(surf_tn3("SetColorKey"), "IDirectDrawSurface::SetColorKey"),
        .SetOverlayPosition = comPtr(surf_tn3("SetOverlayPosition"), "IDirectDrawSurface::SetOverlayPosition"),
        .SetPalette = comPtr(surf_tn2("SetPalette"), "IDirectDrawSurface::SetPalette"),
        .Unlock = surface_Unlock,
        .UpdateOverlay = comPtr(surf_tn6("UpdateOverlay"), "IDirectDrawSurface::UpdateOverlay"),
        .UpdateOverlayDisplay = comPtr(surf_tn2("UpdateOverlayDisplay"), "IDirectDrawSurface::UpdateOverlayDisplay"),
        .UpdateOverlayZOrder = comPtr(surf_tn3("UpdateOverlayZOrder"), "IDirectDrawSurface::UpdateOverlayZOrder"),
        // IDirectDrawSurface2+ extras:
        .GetDDInterface = comPtr(surf_tn2("GetDDInterface"), "IDirectDrawSurface::GetDDInterface"),
        .PageLock = comPtr(surf_tn2("PageLock"), "IDirectDrawSurface::PageLock"),
        .PageUnlock = comPtr(surf_tn2("PageUnlock"), "IDirectDrawSurface::PageUnlock"),
        .SetSurfaceDesc = comPtr(surf_tn3("SetSurfaceDesc"), "IDirectDrawSurface::SetSurfaceDesc"),
        .SetPrivateData = comPtr(surf_tn5("SetPrivateData"), "IDirectDrawSurface::SetPrivateData"),
        .GetPrivateData = comPtr(surf_tn4("GetPrivateData"), "IDirectDrawSurface::GetPrivateData"),
        .FreePrivateData = comPtr(surf_tn2("FreePrivateData"), "IDirectDrawSurface::FreePrivateData"),
        .GetUniquenessValue = comPtr(surf_tn2("GetUniquenessValue"), "IDirectDrawSurface::GetUniquenessValue"),
        .ChangeUniquenessValue = comPtr(surf_tn1("ChangeUniquenessValue"), "IDirectDrawSurface::ChangeUniquenessValue"),
        .SetPriority = comPtr(surf_tn2("SetPriority"), "IDirectDrawSurface::SetPriority"),
        .GetPriority = comPtr(surf_tn2("GetPriority"), "IDirectDrawSurface::GetPriority"),
        .SetLOD = comPtr(surf_tn2("SetLOD"), "IDirectDrawSurface::SetLOD"),
        .GetLOD = comPtr(surf_tn2("GetLOD"), "IDirectDrawSurface::GetLOD"),
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

    // Initialize and register D3D7 vtables
    d3d7.init();
    d3d7.registerVtables(environment);
}

/// DirectDrawCreate — creates an instance of a DirectDraw object.
/// Implementation status: Partially implemented (returns global instance)
fn stub_DirectDrawCreate(lpGUID: usize, lplpDD: *?*IDirectDraw, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpGUID;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DDRAW: DirectDrawCreate()\n", .{});

    lplpDD.* = &global_ddraw;
    return w32.DD_OK;
}

/// DirectDrawCreateEx — creates an instance of a DirectDraw object that supports the IDirectDraw7 interface.
/// Implementation status: Partially implemented (returns global instance)
fn stub_DirectDrawCreateEx(lpGUID: usize, lplpDD: *?*anyopaque, iid: usize, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpGUID;
    _ = iid;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DDRAW: DirectDrawCreateEx()\n", .{});
    lplpDD.* = @ptrCast(&global_ddraw);
    return w32.DD_OK;
}

/// DirectDrawEnumerateExA — enumerates all DirectDraw devices.
/// Implementation status: Partially implemented (calls back once with the primary display driver)
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
