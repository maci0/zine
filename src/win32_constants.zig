// Win32 API named constants — matches official Microsoft SDK naming.
// Use these instead of magic numbers throughout stubs.

// ============================================================
// HRESULT / General COM
// ============================================================

pub const S_OK: i32 = 0;

// ============================================================
// DirectDraw
// ============================================================

pub const DD_OK: i32 = 0;

// DDSURFACEDESC dwFlags
pub const DDSD_CAPS: u32 = 0x00000001;
pub const DDSD_HEIGHT: u32 = 0x00000002;
pub const DDSD_WIDTH: u32 = 0x00000004;
pub const DDSD_PITCH: u32 = 0x00000008;
pub const DDSD_BACKBUFFERCOUNT: u32 = 0x00000020;
pub const DDSD_PIXELFORMAT: u32 = 0x00001000;

// DDPIXELFORMAT dwFlags
pub const DDPF_RGB: u32 = 0x00000040;

// DDSCAPS dwCaps
pub const DDSCAPS_PRIMARYSURFACE: u32 = 0x00000200;
pub const DDSCAPS_FLIP: u32 = 0x00000010;
pub const DDSCAPS_COMPLEX: u32 = 0x00000008;
pub const DDSCAPS_OFFSCREENPLAIN: u32 = 0x00000040;
pub const DDSCAPS_BACKBUFFER: u32 = 0x00000004;

// ============================================================
// DirectDraw Struct Definitions (32-bit layout)
// ============================================================

/// DDCOLORKEY — 8 bytes
pub const DDCOLORKEY = extern struct {
    dwColorSpaceLowValue: u32 = 0,
    dwColorSpaceHighValue: u32 = 0,
};

/// DDPIXELFORMAT — 32 bytes
pub const DDPIXELFORMAT = extern struct {
    dwSize: u32 = 32,
    dwFlags: u32 = 0,
    dwFourCC: u32 = 0,
    dwRGBBitCount: u32 = 0, // union with dwYUVBitCount, dwZBufferBitDepth, etc.
    dwRBitMask: u32 = 0,
    dwGBitMask: u32 = 0,
    dwBBitMask: u32 = 0,
    dwRGBAlphaBitMask: u32 = 0,
};

/// DDSCAPS — 4 bytes
pub const DDSCAPS = extern struct {
    dwCaps: u32 = 0,
};

/// DDSURFACEDESC — 108 bytes (DirectDraw 1/2 variant used by 32-bit apps)
pub const DDSURFACEDESC = extern struct {
    dwSize: u32 = 108,
    dwFlags: u32 = 0,
    dwHeight: u32 = 0,
    dwWidth: u32 = 0,
    lPitch: u32 = 0, // union with dwLinearSize
    dwBackBufferCount: u32 = 0,
    dwRefreshRate: u32 = 0, // union with dwMipMapCount, dwZBufferBitDepth
    dwAlphaBitDepth: u32 = 0,
    dwReserved: u32 = 0,
    lpSurface: u32 = 0, // 32-bit pointer in guest memory
    ddckCKDestOverlay: DDCOLORKEY = .{},
    ddckCKDestBlt: DDCOLORKEY = .{},
    ddckCKSrcOverlay: DDCOLORKEY = .{},
    ddckCKSrcBlt: DDCOLORKEY = .{},
    ddpfPixelFormat: DDPIXELFORMAT = .{},
    ddsCaps: DDSCAPS = .{},
};

// ============================================================
// DirectSound
// ============================================================

pub const DS_OK: i32 = 0;

// DSBUFFERDESC dwFlags
pub const DSBCAPS_PRIMARYBUFFER: u32 = 0x00000001;

// IDirectSoundBuffer::Lock dwFlags
pub const DSBLOCK_FROMWRITECURSOR: u32 = 0x00000001;
pub const DSBLOCK_ENTIREBUFFER: u32 = 0x00000002;

// IDirectSoundBuffer::GetStatus
pub const DSBSTATUS_PLAYING: u32 = 0x00000001;
pub const DSBSTATUS_LOOPING: u32 = 0x00000004;

// IDirectSoundBuffer::SetVolume range (hundredths of dB)
pub const DSBVOLUME_MIN: i32 = -10000;
pub const DSBVOLUME_MAX: i32 = 0;

// ============================================================
// DirectSound Struct Definitions (32-bit layout)
// ============================================================

/// WAVEFORMATEX — 18 bytes
pub const WAVEFORMATEX = extern struct {
    wFormatTag: u16 = 0,
    nChannels: u16 = 0,
    nSamplesPerSec: u32 = 0,
    nAvgBytesPerSec: u32 = 0,
    nBlockAlign: u16 = 0,
    wBitsPerSample: u16 = 0,
    cbSize: u16 = 0,
};

/// DSBUFFERDESC — 20 bytes (DirectSound 1)
pub const DSBUFFERDESC = extern struct {
    dwSize: u32 = 20,
    dwFlags: u32 = 0,
    dwBufferBytes: u32 = 0,
    dwReserved: u32 = 0,
    lpwfxFormat: u32 = 0, // 32-bit pointer in guest memory
};

// ============================================================
// Direct3D 8
// ============================================================

pub const D3D_OK: i32 = 0;
pub const D3DERR_INVALIDCALL: u32 = 0x80070057;
pub const D3DERR_OUTOFVIDEOMEMORY: u32 = 0x8876086C;

// D3DFORMAT
pub const D3DFMT_X8R8G8B8: u32 = 22;

// D3DDEVTYPE
pub const D3DDEVTYPE_HAL: u32 = 1;

// ============================================================
// Direct3D 8 Struct Definitions (32-bit layout)
// ============================================================

/// D3DDISPLAYMODE — 16 bytes
pub const D3DDISPLAYMODE = extern struct {
    Width: u32 = 0,
    Height: u32 = 0,
    RefreshRate: u32 = 0,
    Format: u32 = 0,
};

/// D3DPRESENT_PARAMETERS — 56 bytes
pub const D3DPRESENT_PARAMETERS = extern struct {
    BackBufferWidth: u32 = 0,
    BackBufferHeight: u32 = 0,
    BackBufferFormat: u32 = 0,
    BackBufferCount: u32 = 0,
    MultiSampleType: u32 = 0,
    SwapEffect: u32 = 0,
    hDeviceWindow: u32 = 0, // 32-bit HWND
    Windowed: u32 = 0,
    EnableAutoDepthStencil: u32 = 0,
    AutoDepthStencilFormat: u32 = 0,
    Flags: u32 = 0,
    FullScreen_RefreshRateInHz: u32 = 0,
    FullScreen_PresentationInterval: u32 = 0,
};

/// D3DVIEWPORT8 — 24 bytes
pub const D3DVIEWPORT8 = extern struct {
    X: u32 = 0,
    Y: u32 = 0,
    Width: u32 = 0,
    Height: u32 = 0,
    MinZ: f32 = 0.0,
    MaxZ: f32 = 1.0,
};

/// D3DLOCKED_RECT — 8 bytes (32-bit: Pitch + pBits pointer)
pub const D3DLOCKED_RECT = extern struct {
    Pitch: u32 = 0,
    pBits: u32 = 0, // 32-bit pointer in guest memory
};

// ============================================================
// Window Messages (WM_*)
// ============================================================

pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_ACTIVATE: u32 = 0x0006;
pub const WM_ACTIVATEAPP: u32 = 0x001C;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_QUIT: u32 = 0x0012;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_KEYDOWN: u32 = 0x0100;
pub const WM_KEYUP: u32 = 0x0101;
pub const WM_SYSKEYDOWN: u32 = 0x0104;
pub const WM_SYSKEYUP: u32 = 0x0105;
pub const WM_COMMAND: u32 = 0x0111;
pub const WM_INITDIALOG: u32 = 0x0110;

// Mouse messages
pub const WM_MOUSEMOVE: u32 = 0x0200;
pub const WM_LBUTTONDOWN: u32 = 0x0201;
pub const WM_LBUTTONUP: u32 = 0x0202;
pub const WM_RBUTTONDOWN: u32 = 0x0204;
pub const WM_RBUTTONUP: u32 = 0x0205;
pub const WM_MBUTTONDOWN: u32 = 0x0207;
pub const WM_MBUTTONUP: u32 = 0x0208;

// Mouse key flags (wParam for mouse messages)
pub const MK_LBUTTON: usize = 0x0001;
pub const MK_RBUTTON: usize = 0x0002;

// PeekMessage wRemoveMsg
pub const PM_REMOVE: u32 = 0x0001;

// WM_ACTIVATE wParam
pub const WA_ACTIVE: usize = 1;

// WM_SIZE wParam
pub const SIZE_RESTORED: usize = 0;

// ============================================================
// Window Styles
// ============================================================

pub const WS_CHILD: u32 = 0x40000000;

// Edit control styles
pub const ES_MULTILINE: u32 = 0x0004;

// CreateWindowEx special position
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

// ============================================================
// GetWindowLong / SetWindowLong indices
// ============================================================

pub const GWL_WNDPROC: i32 = -4;
pub const GWL_HWNDPARENT: i32 = -8;
pub const GWL_ID: i32 = -12;
pub const GWL_USERDATA: i32 = -21;
pub const GWL_HINSTANCE: i32 = -6;
pub const GWL_STYLE: i32 = -16;
pub const GWL_EXSTYLE: i32 = -20;

// ============================================================
// SetWindowPos flags
// ============================================================

pub const SWP_NOSIZE: u32 = 0x0001;

// ============================================================
// SystemParametersInfo actions
// ============================================================

pub const SPI_GETNONCLIENTMETRICS: u32 = 0x0029;
pub const SPI_GETWORKAREA: u32 = 0x0030;

// ============================================================
// GDI Device Caps indices
// ============================================================

pub const TECHNOLOGY: i32 = 2;
pub const HORZRES: i32 = 8;
pub const VERTRES: i32 = 10;
pub const BITSPIXEL: i32 = 12;
pub const PLANES: i32 = 14;
pub const NUMCOLORS: i32 = 24;
pub const LOGPIXELSX: i32 = 88;
pub const LOGPIXELSY: i32 = 90;
pub const SIZEPALETTE: i32 = 104;
pub const DESKTOPVERTRES: i32 = 117;
pub const DESKTOPHORZRES: i32 = 118;

// ============================================================
// Common Dialog flags (OPENFILENAME)
// ============================================================

pub const OFN_NOCHANGEDIR: u32 = 0x00000008;
pub const OFN_ENABLEHOOK: u32 = 0x00000020;

// ============================================================
// User32 Struct Definitions (32-bit layout)
// ============================================================

/// WNDCLASSA — 40 bytes
pub const WNDCLASSA = extern struct {
    style: u32 = 0,
    lpfnWndProc: u32 = 0, // 32-bit function pointer
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: u32 = 0,
    hIcon: u32 = 0,
    hCursor: u32 = 0,
    hbrBackground: u32 = 0,
    lpszMenuName: u32 = 0, // 32-bit string pointer
    lpszClassName: u32 = 0, // 32-bit string pointer
};

/// LOGFONTA — 60 bytes
pub const LOGFONTA = extern struct {
    lfHeight: i32 = 0,
    lfWidth: i32 = 0,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = 0,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    lfCharSet: u8 = 0,
    lfOutPrecision: u8 = 0,
    lfClipPrecision: u8 = 0,
    lfQuality: u8 = 0,
    lfPitchAndFamily: u8 = 0,
    lfFaceName: [32]u8 = [_]u8{0} ** 32,
};

/// NONCLIENTMETRICSA — 340 bytes (Win2K)
pub const NONCLIENTMETRICSA = extern struct {
    cbSize: u32 = 340,
    iBorderWidth: i32 = 0,
    iScrollWidth: i32 = 0,
    iScrollHeight: i32 = 0,
    iCaptionWidth: i32 = 0,
    iCaptionHeight: i32 = 0,
    lfCaptionFont: LOGFONTA = .{},
    iSmCaptionWidth: i32 = 0,
    iSmCaptionHeight: i32 = 0,
    lfSmCaptionFont: LOGFONTA = .{},
    iMenuWidth: i32 = 0,
    iMenuHeight: i32 = 0,
    lfMenuFont: LOGFONTA = .{},
    lfStatusFont: LOGFONTA = .{},
    lfMessageFont: LOGFONTA = .{},
};

// ============================================================
// GDI32 Struct Definitions (32-bit layout)
// ============================================================

/// TEXTMETRICA — 56 bytes
pub const TEXTMETRICA = extern struct {
    tmHeight: i32 = 0,
    tmAscent: i32 = 0,
    tmDescent: i32 = 0,
    tmInternalLeading: i32 = 0,
    tmExternalLeading: i32 = 0,
    tmAveCharWidth: i32 = 0,
    tmMaxCharWidth: i32 = 0,
    tmWeight: i32 = 0,
    tmOverhang: i32 = 0,
    tmDigitizedAspectX: i32 = 0,
    tmDigitizedAspectY: i32 = 0,
    tmFirstChar: u8 = 0,
    tmLastChar: u8 = 0,
    tmDefaultChar: u8 = 0,
    tmBreakChar: u8 = 0,
    tmItalic: u8 = 0,
    tmUnderlined: u8 = 0,
    tmStruckOut: u8 = 0,
    tmPitchAndFamily: u8 = 0,
    tmCharSet: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

/// SIZE — 8 bytes
pub const SIZE = extern struct {
    cx: i32 = 0,
    cy: i32 = 0,
};

// ============================================================
// Common Dialog Struct Definitions (32-bit layout)
// ============================================================

/// OPENFILENAMEA — 76 bytes (Win2K 32-bit)
pub const OPENFILENAMEA = extern struct {
    lStructSize: u32 = 76,
    hwndOwner: u32 = 0,
    hInstance: u32 = 0,
    lpstrFilter: u32 = 0,
    lpstrCustomFilter: u32 = 0,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 0,
    lpstrFile: u32 = 0, // offset 28
    nMaxFile: u32 = 0, // offset 32
    lpstrFileTitle: u32 = 0, // offset 36
    nMaxFileTitle: u32 = 0, // offset 40
    lpstrInitialDir: u32 = 0,
    lpstrTitle: u32 = 0,
    Flags: u32 = 0, // offset 52
    nFileOffset: u16 = 0, // offset 56
    nFileExtension: u16 = 0, // offset 58
    lpstrDefExt: u32 = 0,
    lCustData: u32 = 0,
    lpfnHook: u32 = 0, // offset 68
    lpTemplateName: u32 = 0,
};

// ============================================================
// Additional Structs
// ============================================================

/// POINT — 8 bytes
pub const POINT = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

/// MONITORINFO — 40 bytes
pub const MONITORINFO = extern struct {
    cbSize: u32 = 40,
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: u32 = 0,
};

/// MONITORINFOF_PRIMARY
pub const MONITORINFOF_PRIMARY: u32 = 1;

/// RECT — 16 bytes  (also in user32.zig but defined here for cross-module use)
pub const RECT = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

/// WINDOWPLACEMENT — 44 bytes
pub const WINDOWPLACEMENT = extern struct {
    length: u32 = 44,
    flags: u32 = 0,
    showCmd: u32 = 0,
    ptMinPosition: POINT = .{},
    ptMaxPosition: POINT = .{},
    rcNormalPosition: RECT = .{},
};

/// WNDCLASSEXA — 48 bytes (has cbSize prefix unlike WNDCLASSA)
pub const WNDCLASSEXA = extern struct {
    cbSize: u32 = 48,
    style: u32 = 0,
    lpfnWndProc: u32 = 0,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: u32 = 0,
    hIcon: u32 = 0,
    hCursor: u32 = 0,
    hbrBackground: u32 = 0,
    lpszMenuName: u32 = 0,
    lpszClassName: u32 = 0,
    hIconSm: u32 = 0,
};

/// UNICODE_STRING — 8 bytes (32-bit)
pub const UNICODE_STRING = extern struct {
    Length: u16 = 0,
    MaximumLength: u16 = 0,
    Buffer: u32 = 0, // 32-bit pointer
};

/// TIMECAPS — 8 bytes
pub const TIMECAPS = extern struct {
    wPeriodMin: u32 = 0,
    wPeriodMax: u32 = 0,
};

/// WSADATA — 400 bytes (Winsock 2)
pub const WSADATA = extern struct {
    wVersion: u16 = 0,
    wHighVersion: u16 = 0,
    szDescription: [257]u8 = [_]u8{0} ** 257,
    szSystemStatus: [129]u8 = [_]u8{0} ** 129,
    iMaxSockets: u16 = 0,
    iMaxUdpDg: u16 = 0,
    lpVendorInfo: u32 = 0, // 32-bit pointer
};

// ============================================================
// Kernel32 Structs
// ============================================================

/// FILETIME — 8 bytes
pub const FILETIME = extern struct {
    dwLowDateTime: u32 = 0,
    dwHighDateTime: u32 = 0,
};

/// SYSTEMTIME — 16 bytes
pub const SYSTEMTIME = extern struct {
    wYear: u16 = 0,
    wMonth: u16 = 0,
    wDayOfWeek: u16 = 0,
    wDay: u16 = 0,
    wHour: u16 = 0,
    wMinute: u16 = 0,
    wSecond: u16 = 0,
    wMilliseconds: u16 = 0,
};

/// OSVERSIONINFOA — 148 bytes
pub const OSVERSIONINFOA = extern struct {
    dwOSVersionInfoSize: u32 = 148,
    dwMajorVersion: u32 = 0,
    dwMinorVersion: u32 = 0,
    dwBuildNumber: u32 = 0,
    dwPlatformId: u32 = 0,
    szCSDVersion: [128]u8 = [_]u8{0} ** 128,
};

/// VER_PLATFORM_WIN32_NT
pub const VER_PLATFORM_WIN32_NT: u32 = 2;

/// MEMORYSTATUS — 32 bytes
pub const MEMORYSTATUS = extern struct {
    dwLength: u32 = 32,
    dwMemoryLoad: u32 = 0,
    dwTotalPhys: u32 = 0,
    dwAvailPhys: u32 = 0,
    dwTotalPageFile: u32 = 0,
    dwAvailPageFile: u32 = 0,
    dwTotalVirtual: u32 = 0,
    dwAvailVirtual: u32 = 0,
};

/// MEMORY_BASIC_INFORMATION — 28 bytes (32-bit)
pub const MEMORY_BASIC_INFORMATION = extern struct {
    BaseAddress: u32 = 0,
    AllocationBase: u32 = 0,
    AllocationProtect: u32 = 0,
    RegionSize: u32 = 0,
    State: u32 = 0,
    Protect: u32 = 0,
    Type: u32 = 0,
};

/// PAGE_READWRITE
pub const PAGE_READWRITE: u32 = 0x04;
/// MEM_COMMIT
pub const MEM_COMMIT: u32 = 0x1000;
/// MEM_MAPPED
pub const MEM_MAPPED: u32 = 0x40000;

/// PROCESS_INFORMATION — 16 bytes
pub const PROCESS_INFORMATION = extern struct {
    hProcess: u32 = 0,
    hThread: u32 = 0,
    dwProcessId: u32 = 0,
    dwThreadId: u32 = 0,
};

/// STARTUPINFOA — 68 bytes
pub const STARTUPINFOA = extern struct {
    cb: u32 = 68,
    lpReserved: u32 = 0,
    lpDesktop: u32 = 0,
    lpTitle: u32 = 0,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: u32 = 0,
    hStdInput: u32 = 0,
    hStdOutput: u32 = 0,
    hStdError: u32 = 0,
};

/// DEVMODEA — 156 bytes (Win2K, no dmDriverExtra)
/// Only the fields we actually fill are named; the rest goes in padding arrays.
pub const DEVMODEA = extern struct {
    dmDeviceName: [32]u8 = [_]u8{0} ** 32, // offset 0
    dmSpecVersion: u16 = 0, // offset 32
    dmDriverVersion: u16 = 0, // offset 34
    dmSize: u16 = 156, // offset 36
    dmDriverExtra: u16 = 0, // offset 38
    dmFields: u32 = 0, // offset 40
    _pad1: [60]u8 = [_]u8{0} ** 60, // offsets 44–103 (position, paper, etc.)
    dmBitsPerPel: u32 = 0, // offset 104
    dmPelsWidth: u32 = 0, // offset 108
    dmPelsHeight: u32 = 0, // offset 112
    _pad2: [4]u8 = [_]u8{0} ** 4, // offset 116 (dmDisplayFlags/dmNup)
    dmDisplayFrequency: u32 = 0, // offset 120
    _pad3: [32]u8 = [_]u8{0} ** 32, // offsets 124–155 (ICM, media, etc.)
};

/// DEVMODE field flags
pub const DM_BITSPERPEL: u32 = 0x00040000;
pub const DM_PELSWIDTH: u32 = 0x00080000;
pub const DM_PELSHEIGHT: u32 = 0x00100000;
pub const DM_DISPLAYFREQUENCY: u32 = 0x00400000;

// ============================================================
// GDI32 Structs
// ============================================================

/// BITMAPINFOHEADER — 40 bytes
pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = 40,
    biWidth: i32 = 0,
    biHeight: i32 = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 0,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

// ============================================================
// File I/O Constants
// ============================================================

pub const INVALID_HANDLE_VALUE: usize = 0xFFFFFFFF;
pub const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
pub const INVALID_FILE_SIZE: u32 = 0xFFFFFFFF;
pub const INVALID_SET_FILE_POINTER: u32 = 0xFFFFFFFF;

pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
pub const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

pub const FILE_TYPE_DISK: u32 = 1;
pub const FILE_TYPE_CHAR: u32 = 2;

pub const FILE_BEGIN: u32 = 0;
pub const FILE_CURRENT: u32 = 1;
pub const FILE_END: u32 = 2;

pub const CREATE_NEW: u32 = 1;
pub const CREATE_ALWAYS: u32 = 2;
pub const OPEN_EXISTING: u32 = 3;
pub const OPEN_ALWAYS: u32 = 4;
pub const TRUNCATE_EXISTING: u32 = 5;

/// BY_HANDLE_FILE_INFORMATION — 52 bytes
pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: u32 = 0,
    ftCreationTime: FILETIME = .{},
    ftLastAccessTime: FILETIME = .{},
    ftLastWriteTime: FILETIME = .{},
    dwVolumeSerialNumber: u32 = 0,
    nFileSizeHigh: u32 = 0,
    nFileSizeLow: u32 = 0,
    nNumberOfLinks: u32 = 0,
    nFileIndexHigh: u32 = 0,
    nFileIndexLow: u32 = 0,
};

/// WIN32_FIND_DATAA — 320 bytes
pub const WIN32_FIND_DATAA = extern struct {
    dwFileAttributes: u32 = 0,
    ftCreationTime: FILETIME = .{},
    ftLastAccessTime: FILETIME = .{},
    ftLastWriteTime: FILETIME = .{},
    nFileSizeHigh: u32 = 0,
    nFileSizeLow: u32 = 0,
    dwReserved0: u32 = 0,
    dwReserved1: u32 = 0,
    cFileName: [260]u8 = [_]u8{0} ** 260,
    cAlternateFileName: [14]u8 = [_]u8{0} ** 14,
};

// ============================================================
// NTDLL Structs
// ============================================================

/// SYSTEM_BASIC_INFORMATION — 44 bytes
pub const SYSTEM_BASIC_INFORMATION = extern struct {
    Reserved: u32 = 0,
    TimerResolution: u32 = 0,
    PageSize: u32 = 0,
    NumberOfPhysicalPages: u32 = 0,
    LowestPhysicalPageNumber: u32 = 0,
    HighestPhysicalPageNumber: u32 = 0,
    AllocationGranularity: u32 = 0,
    MinimumUserModeAddress: u32 = 0,
    MaximumUserModeAddress: u32 = 0,
    ActiveProcessorsAffinityMask: u32 = 0,
    NumberOfProcessors: u8 = 0,
    _pad: [3]u8 = [_]u8{0} ** 3,
};
