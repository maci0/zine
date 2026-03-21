//! Re-export of win32 stub modules for DLL builds.
//! This file exists at the src/ level so Zig's module system can reach
//! all win32 submodules. DLL entry points in src/dll/ import this via
//! the named module "win32" configured in build.zig.

pub const msvcrt = struct {
    pub const string = @import("win32/msvcrt/string.zig");
    pub const mem = @import("win32/msvcrt/mem.zig");
    pub const path = @import("win32/msvcrt/path.zig");
    pub const time = @import("win32/msvcrt/time.zig");
    pub const misc = @import("win32/msvcrt/misc.zig");
};

pub const kernel32 = struct {
    pub const file = @import("win32/kernel32/file.zig");
    pub const console = @import("win32/kernel32/console.zig");
    pub const process = @import("win32/kernel32/process.zig");
    pub const sync = @import("win32/kernel32/sync.zig");
    pub const sysinfo = @import("win32/kernel32/sysinfo.zig");
    pub const path = @import("win32/kernel32/path.zig");
    pub const profile = @import("win32/kernel32/profile.zig");
};

pub const advapi32 = struct {
    pub const registry = @import("win32/advapi32/registry.zig");
    pub const security = @import("win32/advapi32/security.zig");
    pub const services = @import("win32/advapi32/services.zig");
};

pub const user32 = struct {
    pub const window = @import("win32/user32/window.zig");
    pub const message = @import("win32/user32/message.zig");
    pub const resource = @import("win32/user32/resource.zig");
};

pub const gdi32 = struct {
    pub const drawing = @import("win32/gdi32/drawing.zig");
    pub const object = @import("win32/gdi32/object.zig");
    pub const dc = @import("win32/gdi32/dc.zig");
};

pub const shell32 = struct {
    pub const shell = @import("win32/shell32/shell.zig");
};

pub const ole32 = struct {
    pub const com = @import("win32/ole32/com.zig");
};

pub const winmm = struct {
    pub const multimedia = @import("win32/winmm/multimedia.zig");
};

pub const comctl32 = struct {
    pub const controls = @import("win32/comctl32/controls.zig");
};

pub const comdlg32 = struct {
    pub const dialogs = @import("win32/comdlg32/dialogs.zig");
};

pub const ntdll = struct {
    pub const ntapi = @import("win32/ntdll/ntapi.zig");
};

pub const mss32 = struct {
    pub const miles = @import("win32/mss32/miles.zig");
};

pub const ws2_32 = struct {
    pub const winsock = @import("win32/ws2_32/winsock.zig");
};

pub const rpcrt4 = @import("win32/rpcrt4.zig");

pub const calling_convention = @import("win32/calling_convention.zig");
