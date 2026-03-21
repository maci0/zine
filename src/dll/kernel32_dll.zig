//! KERNEL32.dll export definitions

const w32 = @import("win32");
const file = w32.kernel32.file;
const console = w32.kernel32.console;
const process = w32.kernel32.process;
const sync = w32.kernel32.sync;
const sysinfo = w32.kernel32.sysinfo;
const path_mod = w32.kernel32.path;

comptime {
    _ = @import("dll_common.zig");

    // File I/O
    @export(&file.GetFileSize, .{ .name = "GetFileSize" });
    @export(&file.GetFileInformationByHandle, .{ .name = "GetFileInformationByHandle" });
    @export(&file.SetFilePointer, .{ .name = "SetFilePointer" });
    @export(&file.ReadFile, .{ .name = "ReadFile" });
    @export(&file.WriteFile, .{ .name = "WriteFile" });
    @export(&file.GetDiskFreeSpaceA, .{ .name = "GetDiskFreeSpaceA" });
    @export(&file.GetFileAttributesA, .{ .name = "GetFileAttributesA" });
    @export(&file.FindFirstFileA, .{ .name = "FindFirstFileA" });
    @export(&file.FindNextFileA, .{ .name = "FindNextFileA" });

    // Console
    @export(&console.GetConsoleMode, .{ .name = "GetConsoleMode" });
    @export(&console.GetConsoleScreenBufferInfo, .{ .name = "GetConsoleScreenBufferInfo" });
    @export(&console.WriteConsoleA, .{ .name = "WriteConsoleA" });
    @export(&console.WriteConsoleW, .{ .name = "WriteConsoleW" });
    @export(&console.ReadConsoleW, .{ .name = "ReadConsoleW" });

    // Process
    @export(&process.GetStartupInfoA, .{ .name = "GetStartupInfoA" });

    // Sync
    @export(&sync.InterlockedIncrement, .{ .name = "InterlockedIncrement" });
    @export(&sync.InterlockedDecrement, .{ .name = "InterlockedDecrement" });

    // System info
    @export(&sysinfo.GetProcessAffinityMask, .{ .name = "GetProcessAffinityMask" });
    @export(&sysinfo.GetSystemInfo, .{ .name = "GetSystemInfo" });
    @export(&sysinfo.GetNativeSystemInfo, .{ .name = "GetNativeSystemInfo" });
    @export(&sysinfo.GlobalMemoryStatusEx, .{ .name = "GlobalMemoryStatusEx" });

    // Path
    @export(&path_mod.GetCurrentDirectoryA, .{ .name = "GetCurrentDirectoryA" });
    @export(&path_mod.GetFullPathNameA, .{ .name = "GetFullPathNameA" });
    @export(&path_mod.GetWindowsDirectoryA, .{ .name = "GetWindowsDirectoryA" });
}
