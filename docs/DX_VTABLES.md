# DirectX COM Vtable Reference (from Wine headers)

Status: reference for the `src/win32/ddraw/` and `src/win32/d3d7/` vtable layouts; slot counts are checked against those files.

## IDirect3D3

| Slot | Offset | Method |
|------|--------|--------|
| 0 | 0x00 | QueryInterface |
| 1 | 0x04 | AddRef |
| 2 | 0x08 | Release |
| 3 | 0x0C | EnumDevices |
| 4 | 0x10 | CreateLight |
| 5 | 0x14 | CreateMaterial |
| 6 | 0x18 | CreateViewport |
| 7 | 0x1C | FindDevice |
| 8 | 0x20 | CreateDevice |
| 9 | 0x24 | CreateVertexBuffer |
| 10 | 0x28 | EnumZBufferFormats |
| 11 | 0x2C | EvictManagedTextures |

## IDirect3DDevice3

| Slot | Offset | Method |
|------|--------|--------|
| 0 | 0x00 | QueryInterface(REFIID, void**) |
| 1 | 0x04 | AddRef() |
| 2 | 0x08 | Release() |
| 3 | 0x0C | GetCaps(D3DDEVICEDESC*, D3DDEVICEDESC*) |
| 4 | 0x10 | GetStats(D3DSTATS*) |
| 5 | 0x14 | AddViewport(IDirect3DViewport3*) |
| 6 | 0x18 | DeleteViewport(IDirect3DViewport3*) |
| 7 | 0x1C | NextViewport(IDirect3DViewport3*, IDirect3DViewport3**, DWORD) |
| 8 | 0x20 | EnumTextureFormats(LPD3DENUMPIXELFORMATSCALLBACK, void*) |
| 9 | 0x24 | BeginScene() |
| 10 | 0x28 | EndScene() |
| 11 | 0x2C | GetDirect3D(IDirect3D3**) |
| 12 | 0x30 | SetCurrentViewport(IDirect3DViewport3*) |
| 13 | 0x34 | GetCurrentViewport(IDirect3DViewport3**) |
| 14 | 0x38 | SetRenderTarget(IDirectDrawSurface4*, DWORD) |
| 15 | 0x3C | GetRenderTarget(IDirectDrawSurface4**) |
| 16 | 0x40 | Begin(D3DPRIMITIVETYPE, DWORD, DWORD) |
| 17 | 0x44 | BeginIndexed(D3DPRIMITIVETYPE, DWORD, void*, DWORD, DWORD) |
| 18 | 0x48 | Vertex(void*) |
| 19 | 0x4C | Index(WORD) |
| 20 | 0x50 | End(DWORD) |
| 21 | 0x54 | GetRenderState(D3DRENDERSTATETYPE, DWORD*) |
| 22 | 0x58 | SetRenderState(D3DRENDERSTATETYPE, DWORD) |
| 23 | 0x5C | GetLightState(D3DLIGHTSTATETYPE, DWORD*) |
| 24 | 0x60 | SetLightState(D3DLIGHTSTATETYPE, DWORD) |
| 25 | 0x64 | SetTransform(D3DTRANSFORMSTATETYPE, D3DMATRIX*) |
| 26 | 0x68 | GetTransform(D3DTRANSFORMSTATETYPE, D3DMATRIX*) |
| 27 | 0x6C | MultiplyTransform(D3DTRANSFORMSTATETYPE, D3DMATRIX*) |
| 28 | 0x70 | DrawPrimitive(D3DPRIMITIVETYPE, DWORD, void*, DWORD, DWORD) |
| 29 | 0x74 | DrawIndexedPrimitive(D3DPRIMITIVETYPE, DWORD, void*, DWORD, WORD*, DWORD, DWORD) |
| 30 | 0x78 | SetClipStatus(D3DCLIPSTATUS*) |
| 31 | 0x7C | GetClipStatus(D3DCLIPSTATUS*) |
| 32 | 0x80 | DrawPrimitiveStrided(D3DPRIMITIVETYPE, DWORD, D3DDRAWPRIMITIVESTRIDEDDATA*, DWORD, DWORD) |
| 33 | 0x84 | DrawIndexedPrimitiveStrided(...) |
| 34 | 0x88 | DrawPrimitiveVB(D3DPRIMITIVETYPE, IDirect3DVertexBuffer*, DWORD, DWORD, DWORD) |
| 35 | 0x8C | DrawIndexedPrimitiveVB(D3DPRIMITIVETYPE, IDirect3DVertexBuffer*, WORD*, DWORD, DWORD) |
| 36 | 0x90 | ComputeSphereVisibility(D3DVECTOR*, D3DVALUE*, DWORD, DWORD, DWORD*) |
| 37 | 0x94 | GetTexture(DWORD, IDirect3DTexture2**) |
| 38 | 0x98 | SetTexture(DWORD, IDirect3DTexture2*) |
| 39 | 0x9C | GetTextureStageState(DWORD, D3DTEXTURESTAGESTATETYPE, DWORD*) |
| 40 | 0xA0 | SetTextureStageState(DWORD, D3DTEXTURESTAGESTATETYPE, DWORD) |
| 41 | 0xA4 | ValidateDevice(DWORD*) |

## IDirect3DViewport3

| Slot | Offset | Method |
|------|--------|--------|
| 0 | 0x00 | QueryInterface |
| 1 | 0x04 | AddRef |
| 2 | 0x08 | Release |
| 3 | 0x0C | Initialize |
| 4 | 0x10 | GetViewport |
| 5 | 0x14 | SetViewport |
| 6 | 0x18 | TransformVertices |
| 7 | 0x1C | LightElements |
| 8 | 0x20 | SetBackground |
| 9 | 0x24 | GetBackground |
| 10 | 0x28 | SetBackgroundDepth |
| 11 | 0x2C | GetBackgroundDepth |
| 12 | 0x30 | Clear |
| 13 | 0x34 | AddLight |
| 14 | 0x38 | DeleteLight |
| 15 | 0x3C | NextLight |
| 16 | 0x40 | GetViewport2 |
| 17 | 0x44 | SetViewport2 |
| 18 | 0x48 | SetBackgroundDepth2 |
| 19 | 0x4C | GetBackgroundDepth2 |
| 20 | 0x50 | Clear2 |

## IDirectDrawSurface

| Slot | Offset | Method |
|------|--------|--------|
| 0 | 0x00 | QueryInterface |
| 1 | 0x04 | AddRef |
| 2 | 0x08 | Release |
| 3 | 0x0C | AddAttachedSurface |
| 4 | 0x10 | AddOverlayDirtyRect |
| 5 | 0x14 | Blt |
| 6 | 0x18 | BltBatch |
| 7 | 0x1C | BltFast |
| 8 | 0x20 | DeleteAttachedSurface |
| 9 | 0x24 | EnumAttachedSurfaces |
| 10 | 0x28 | EnumOverlayZOrders |
| 11 | 0x2C | Flip |
| 12 | 0x30 | GetAttachedSurface |
| 13 | 0x34 | GetBltStatus |
| 14 | 0x38 | GetCaps |
| 15 | 0x3C | GetClipper |
| 16 | 0x40 | GetColorKey |
| 17 | 0x44 | GetDC |
| 18 | 0x48 | GetFlipStatus |
| 19 | 0x4C | GetOverlayPosition |
| 20 | 0x50 | GetPalette |
| 21 | 0x54 | GetPixelFormat |
| 22 | 0x58 | GetSurfaceDesc |
| 23 | 0x5C | Initialize |
| 24 | 0x60 | IsLost |
| 25 | 0x64 | Lock |
| 26 | 0x68 | ReleaseDC |
| 27 | 0x6C | Restore |
| 28 | 0x70 | SetClipper |
| 29 | 0x74 | SetColorKey |
| 30 | 0x78 | SetOverlayPosition |
| 31 | 0x7C | SetPalette |
| 32 | 0x80 | Unlock |
| 33 | 0x84 | UpdateOverlay |
| 34 | 0x88 | UpdateOverlayDisplay |
| 35 | 0x8C | UpdateOverlayZOrder |

## D3DPRIMCAPS (56 bytes / 14 DWORDs)

| Offset | Field |
|--------|-------|
| 0x00 | dwSize |
| 0x04 | dwMiscCaps |
| 0x08 | dwRasterCaps |
| 0x0C | dwZCmpCaps |
| 0x10 | dwSrcBlendCaps |
| 0x14 | dwDestBlendCaps |
| 0x18 | dwAlphaCmpCaps |
| 0x1C | dwShadeCaps |
| 0x20 | dwTextureCaps |
| 0x24 | dwTextureFilterCaps |
| 0x28 | dwTextureBlendCaps |
| 0x2C | dwTextureAddressCaps |
| 0x30 | dwStippleWidth |
| 0x34 | dwStippleHeight |

## D3DDEVICEDESC (252 bytes)

| Offset | Field |
|--------|-------|
| 0x00 | dwSize |
| 0x04 | dwFlags |
| 0x08 | dcmColorModel (1=MONO, 2=RGB) |
| 0x0C | dwDevCaps |
| 0x10 | dtcTransformCaps.dwSize (=8) |
| 0x14 | dtcTransformCaps.dwCaps |
| 0x18 | bClipping |
| 0x1C | dlcLightingCaps.dwSize (=16) |
| 0x20 | dlcLightingCaps.dwCaps |
| 0x24 | dlcLightingCaps.dwLightingModel |
| 0x28 | dlcLightingCaps.dwNumLights |
| 0x2C | dpcLineCaps (56 bytes) |
| 0x64 | dpcTriCaps (56 bytes) |
| 0x9C | dwDeviceRenderBitDepth |
| 0xA0 | dwDeviceZBufferBitDepth |
| 0xA4 | dwMaxBufferSize |
| 0xA8 | dwMaxVertexCount |
| 0xAC | dwMinTextureWidth |
| 0xB0 | dwMinTextureHeight |
| 0xB4 | dwMaxTextureWidth |
| 0xB8 | dwMaxTextureHeight |
| 0xBC | dwMinStippleWidth |
| 0xC0 | dwMaxStippleWidth |
| 0xC4 | dwMinStippleHeight |
| 0xC8 | dwMaxStippleHeight |
| 0xCC | dwMaxTextureRepeat |
| 0xD0 | dwMaxTextureAspectRatio |
| 0xD4 | dwMaxAnisotropy |
| 0xD8 | dvGuardBandLeft (float) |
| 0xDC | dvGuardBandTop (float) |
| 0xE0 | dvGuardBandRight (float) |
| 0xE4 | dvGuardBandBottom (float) |
| 0xE8 | dvExtentsAdjust (float) |
| 0xEC | dwStencilCaps |
| 0xF0 | dwFVFCaps |
| 0xF4 | dwTextureOpCaps |
| 0xF8 | wMaxTextureBlendStages (WORD) |
| 0xFA | wMaxSimultaneousTextures (WORD) |

Total = 0xFC = 252 bytes ✓

## D3DCOLORMODEL Values

- D3DCOLOR_MONO = 1
- D3DCOLOR_RGB = 2

## DDBD_ (Bit Depth) Flags

- DDBD_1 = 0x00004000
- DDBD_2 = 0x00002000
- DDBD_4 = 0x00001000
- DDBD_8 = 0x00000800
- DDBD_16 = 0x00000400
- DDBD_24 = 0x00000200
- DDBD_32 = 0x00000100
