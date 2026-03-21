//! Common DLL infrastructure shared by all generated DLLs.

const std = @import("std");
const HINSTANCE = std.os.windows.HINSTANCE;
const BOOL = std.os.windows.BOOL;

pub export fn DllMain(hinstDLL: HINSTANCE, fdwReason: u32, lpvReserved: ?*anyopaque) callconv(.winapi) BOOL {
    _ = .{ hinstDLL, lpvReserved };
    if (fdwReason == 1) { // DLL_PROCESS_ATTACH
        // Initialize character classification tables
        @import("win32").msvcrt.string.init_pctype();
    }
    return 1; // TRUE
}
