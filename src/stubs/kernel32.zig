const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const w32 = @import("win32_constants.zig");

pub var global_env: ?*env.Environment = null;
pub var main_module_handle: usize = 0;
pub var main_exe_dir: [512]u8 = undefined;
pub var main_exe_dir_len: usize = 0;

const kernel32_file = @import("kernel32/file.zig");
const kernel32_mem = @import("kernel32/mem.zig");
const kernel32_process = @import("kernel32/process.zig");
const kernel32_misc = @import("kernel32/misc.zig");
const kernel32_sync = @import("kernel32/sync.zig");
const kernel32_time = @import("kernel32/time.zig");
const kernel32_locale = @import("kernel32/locale.zig");

pub fn register(environment: *env.Environment) !void {
    global_env = environment;
    const m = "KERNEL32.dll";

    // --- File I/O (file.zig) ---
    try environment.addBuiltinExport(m, "CreateFileA", @intFromPtr(&kernel32_file.stub_CreateFileA));
    try environment.addBuiltinExport(m, "CreateFileW", @intFromPtr(&kernel32_file.stub_CreateFileW));
    try environment.addBuiltinExport(m, "CloseHandle", @intFromPtr(&kernel32_file.stub_CloseHandle));
    try environment.addBuiltinExport(m, "ReadFile", @intFromPtr(&kernel32_file.stub_ReadFile));
    try environment.addBuiltinExport(m, "WriteFile", @intFromPtr(&kernel32_file.stub_WriteFile));
    try environment.addBuiltinExport(m, "SetFilePointer", @intFromPtr(&kernel32_file.stub_SetFilePointer));
    try environment.addBuiltinExport(m, "SetEndOfFile", @intFromPtr(&kernel32_file.stub_SetEndOfFile));
    try environment.addBuiltinExport(m, "GetFileSize", @intFromPtr(&kernel32_file.stub_GetFileSize));
    try environment.addBuiltinExport(m, "GetFileType", @intFromPtr(&kernel32_file.stub_GetFileType));
    try environment.addBuiltinExport(m, "GetFileInformationByHandle", @intFromPtr(&kernel32_file.stub_GetFileInformationByHandle));
    try environment.addBuiltinExport(m, "GetFileAttributesA", @intFromPtr(&kernel32_file.stub_GetFileAttributesA));
    try environment.addBuiltinExport(m, "GetFileAttributesW", @intFromPtr(&kernel32_file.stub_GetFileAttributesW));
    try environment.addBuiltinExport(m, "SetFileAttributesA", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "GetStdHandle", @intFromPtr(&kernel32_file.stub_GetStdHandle));
    try environment.addBuiltinExport(m, "SetStdHandle", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "FlushFileBuffers", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "DeleteFileA", @intFromPtr(&kernel32_file.stub_DeleteFileA));
    try environment.addBuiltinExport(m, "FindFirstFileA", @intFromPtr(&kernel32_file.stub_FindFirstFileA));
    try environment.addBuiltinExport(m, "FindNextFileA", @intFromPtr(&kernel32_file.stub_FindNextFileA));
    try environment.addBuiltinExport(m, "FindClose", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "CreateFileMappingA", @intFromPtr(&kernel32_file.stub_CreateFileMappingA));
    try environment.addBuiltinExport(m, "MapViewOfFile", @intFromPtr(&kernel32_file.stub_MapViewOfFile));
    try environment.addBuiltinExport(m, "MapViewOfFileEx", @intFromPtr(&kernel32_file.stub_MapViewOfFileEx));
    try environment.addBuiltinExport(m, "UnmapViewOfFile", @intFromPtr(&kernel32_file.stub_UnmapViewOfFile));
    try environment.addBuiltinExport(m, "OpenFileMappingA", @intFromPtr(&kernel32_file.stub_OpenFileMappingA));
    try environment.addBuiltinExport(m, "CopyFileA", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "SearchPathA", @intFromPtr(&kernel32_file.stub_SearchPathA));
    try environment.addBuiltinExport(m, "GetTempPathA", @intFromPtr(&kernel32_file.stub_GetTempPathA));
    try environment.addBuiltinExport(m, "GetTempFileNameA", @intFromPtr(&kernel32_file.stub_GetTempFileNameA));
    try environment.addBuiltinExport(m, "GetSystemDirectoryA", @intFromPtr(&kernel32_file.stub_GetSystemDirectoryA));
    try environment.addBuiltinExport(m, "GetDiskFreeSpaceA", @intFromPtr(&kernel32_file.stub_GetDiskFreeSpaceA));
    try environment.addBuiltinExport(m, "GetFileTime", @intFromPtr(&stub_args4));
    try environment.addBuiltinExport(m, "SetFileTime", @intFromPtr(&stub_args4));
    try environment.addBuiltinExport(m, "SetHandleCount", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "SetCommBreak", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "ClearCommBreak", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "GetCommState", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "SetCommState", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "SetCommTimeouts", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "GetOverlappedResult", @intFromPtr(&stub_args4));
    try environment.addBuiltinExport(m, "CreateFileMappingW", @intFromPtr(&kernel32_file.stub_CreateFileMappingA));
    try environment.addBuiltinExport(m, "DeleteFileW", @intFromPtr(&kernel32_file.stub_DeleteFileA));

    // --- Memory (mem.zig) ---
    try environment.addBuiltinExport(m, "HeapCreate", @intFromPtr(&kernel32_mem.stub_HeapCreate));
    try environment.addBuiltinExport(m, "HeapDestroy", @intFromPtr(&kernel32_mem.stub_HeapDestroy));
    try environment.addBuiltinExport(m, "HeapAlloc", @intFromPtr(&kernel32_mem.stub_HeapAlloc));
    try environment.addBuiltinExport(m, "HeapReAlloc", @intFromPtr(&kernel32_mem.stub_HeapReAlloc));
    try environment.addBuiltinExport(m, "HeapFree", @intFromPtr(&kernel32_mem.stub_HeapFree));
    try environment.addBuiltinExport(m, "HeapSize", @intFromPtr(&kernel32_misc.stub_HeapSize));
    try environment.addBuiltinExport(m, "HeapValidate", @intFromPtr(&kernel32_misc.stub_HeapValidate));
    try environment.addBuiltinExport(m, "GetProcessHeap", @intFromPtr(&kernel32_mem.stub_GetProcessHeap));
    try environment.addBuiltinExport(m, "LocalAlloc", @intFromPtr(&kernel32_mem.stub_LocalAlloc));
    try environment.addBuiltinExport(m, "LocalFree", @intFromPtr(&kernel32_mem.stub_LocalFree));
    try environment.addBuiltinExport(m, "GlobalAlloc", @intFromPtr(&kernel32_mem.stub_GlobalAlloc));
    try environment.addBuiltinExport(m, "GlobalFree", @intFromPtr(&kernel32_mem.stub_GlobalFree));
    try environment.addBuiltinExport(m, "GlobalLock", @intFromPtr(&kernel32_mem.stub_GlobalLock));
    try environment.addBuiltinExport(m, "GlobalUnlock", @intFromPtr(&kernel32_mem.stub_GlobalUnlock));
    try environment.addBuiltinExport(m, "GlobalSize", @intFromPtr(&kernel32_mem.stub_GlobalSize));
    try environment.addBuiltinExport(m, "GlobalHandle", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "GlobalMemoryStatus", @intFromPtr(&kernel32_mem.stub_GlobalMemoryStatus));
    try environment.addBuiltinExport(m, "VirtualAlloc", @intFromPtr(&kernel32_mem.stub_VirtualAlloc));
    try environment.addBuiltinExport(m, "VirtualFree", @intFromPtr(&kernel32_mem.stub_VirtualFree));
    try environment.addBuiltinExport(m, "VirtualProtect", @intFromPtr(&stub_args4));
    try environment.addBuiltinExport(m, "VirtualQuery", @intFromPtr(&kernel32_mem.stub_VirtualQuery));
    try environment.addBuiltinExport(m, "LocalLock", @intFromPtr(&kernel32_mem.stub_LocalLock));
    try environment.addBuiltinExport(m, "LocalUnlock", @intFromPtr(&kernel32_mem.stub_LocalUnlock));
    try environment.addBuiltinExport(m, "LocalSize", @intFromPtr(&kernel32_mem.stub_LocalSize));
    try environment.addBuiltinExport(m, "LocalReAlloc", @intFromPtr(&kernel32_mem.stub_LocalReAlloc));

    // --- Process & Module (process.zig) ---
    try environment.addBuiltinExport(m, "ExitProcess", @intFromPtr(&kernel32_process.stub_ExitProcess));
    try environment.addBuiltinExport(m, "CreateProcessA", @intFromPtr(&kernel32_process.stub_CreateProcessA));
    try environment.addBuiltinExport(m, "GetCurrentProcess", @intFromPtr(&kernel32_process.stub_GetCurrentProcess));
    try environment.addBuiltinExport(m, "GetCurrentProcessId", @intFromPtr(&kernel32_process.stub_GetCurrentProcessId));
    try environment.addBuiltinExport(m, "GetCurrentThread", @intFromPtr(&stub_args0));
    try environment.addBuiltinExport(m, "GetCurrentThreadId", @intFromPtr(&kernel32_process.stub_GetCurrentThreadId));
    try environment.addBuiltinExport(m, "CreateThread", @intFromPtr(&kernel32_process.stub_CreateThread));
    try environment.addBuiltinExport(m, "ExitThread", @intFromPtr(&kernel32_process.stub_ExitThread));
    try environment.addBuiltinExport(m, "GetStartupInfoA", @intFromPtr(&kernel32_process.stub_GetStartupInfoA));
    try environment.addBuiltinExport(m, "GetCommandLineA", @intFromPtr(&kernel32_process.stub_GetCommandLineA));
    try environment.addBuiltinExport(m, "GetCommandLineW", @intFromPtr(&kernel32_process.stub_GetCommandLineW));
    try environment.addBuiltinExport(m, "LoadLibraryA", @intFromPtr(&kernel32_process.stub_LoadLibraryA));
    try environment.addBuiltinExport(m, "LoadLibraryW", @intFromPtr(&kernel32_process.stub_LoadLibraryW));
    try environment.addBuiltinExport(m, "FreeLibrary", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "GetModuleHandleA", @intFromPtr(&kernel32_process.stub_GetModuleHandleA));
    try environment.addBuiltinExport(m, "GetProcAddress", @intFromPtr(&kernel32_process.stub_GetProcAddress));
    try environment.addBuiltinExport(m, "GetModuleFileNameA", @intFromPtr(&kernel32_misc.stub_GetModuleFileNameA));
    try environment.addBuiltinExport(m, "GetModuleFileNameW", @intFromPtr(&kernel32_process.stub_GetModuleFileNameW));
    try environment.addBuiltinExport(m, "SetConsoleCtrlHandler", @intFromPtr(&kernel32_process.stub_SetConsoleCtrlHandler));
    try environment.addBuiltinExport(m, "DisableThreadLibraryCalls", @intFromPtr(&kernel32_process.stub_DisableThreadLibraryCalls));
    try environment.addBuiltinExport(m, "OpenProcess", @intFromPtr(&kernel32_process.stub_OpenProcess));
    try environment.addBuiltinExport(m, "TerminateProcess", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "SetPriorityClass", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "SetThreadPriority", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "ResumeThread", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "SuspendThread", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "GetProcessTimes", @intFromPtr(&stub_args5));
    try environment.addBuiltinExport(m, "GetThreadTimes", @intFromPtr(&stub_args5));
    try environment.addBuiltinExport(m, "GetExitCodeProcess", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "DebugBreak", @intFromPtr(&stub_args0));
    try environment.addBuiltinExport(m, "SetHandleInformation", @intFromPtr(&kernel32_process.stub_SetHandleInformation));
    try environment.addBuiltinExport(m, "CreatePipe", @intFromPtr(&kernel32_process.stub_CreatePipe));
    try environment.addBuiltinExport(m, "DuplicateHandle", @intFromPtr(&stub_args7));
    try environment.addBuiltinExport(m, "ReadProcessMemory", @intFromPtr(&stub_args5));
    try environment.addBuiltinExport(m, "GenerateConsoleCtrlEvent", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "FindFirstFileW", @intFromPtr(&kernel32_process.stub_FindFirstFileW));
    try environment.addBuiltinExport(m, "FindNextFileW", @intFromPtr(&kernel32_process.stub_FindNextFileW));

    // --- Environment (process.zig) ---
    try environment.addBuiltinExport(m, "GetEnvironmentStrings", @intFromPtr(&kernel32_process.stub_GetEnvironmentStringsA));
    try environment.addBuiltinExport(m, "GetEnvironmentStringsA", @intFromPtr(&kernel32_process.stub_GetEnvironmentStringsA));
    try environment.addBuiltinExport(m, "GetEnvironmentStringsW", @intFromPtr(&kernel32_process.stub_GetEnvironmentStringsW));
    try environment.addBuiltinExport(m, "FreeEnvironmentStringsA", @intFromPtr(&kernel32_process.stub_FreeEnvironmentStringsA));
    try environment.addBuiltinExport(m, "FreeEnvironmentStringsW", @intFromPtr(&kernel32_process.stub_FreeEnvironmentStringsW));
    try environment.addBuiltinExport(m, "GetEnvironmentVariableA", @intFromPtr(&kernel32_process.stub_GetEnvironmentVariableA));
    try environment.addBuiltinExport(m, "SetEnvironmentVariableA", @intFromPtr(&kernel32_process.stub_SetEnvironmentVariableA));

    // --- Synchronization (sync.zig) ---
    try environment.addBuiltinExport(m, "InitializeCriticalSection", @intFromPtr(&kernel32_sync.stub_InitializeCriticalSection));
    try environment.addBuiltinExport(m, "EnterCriticalSection", @intFromPtr(&kernel32_sync.stub_EnterCriticalSection));
    try environment.addBuiltinExport(m, "LeaveCriticalSection", @intFromPtr(&kernel32_sync.stub_LeaveCriticalSection));
    try environment.addBuiltinExport(m, "DeleteCriticalSection", @intFromPtr(&kernel32_sync.stub_DeleteCriticalSection));
    try environment.addBuiltinExport(m, "InterlockedIncrement", @intFromPtr(&kernel32_sync.stub_InterlockedIncrement));
    try environment.addBuiltinExport(m, "InterlockedDecrement", @intFromPtr(&kernel32_sync.stub_InterlockedDecrement));
    try environment.addBuiltinExport(m, "InterlockedExchange", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "CreateEventA", @intFromPtr(&kernel32_sync.stub_CreateEventA));
    try environment.addBuiltinExport(m, "SetEvent", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "ResetEvent", @intFromPtr(&kernel32_sync.stub_ResetEvent));
    try environment.addBuiltinExport(m, "OpenEventA", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "CreateMutexA", @intFromPtr(&kernel32_sync.stub_CreateMutexA));
    try environment.addBuiltinExport(m, "ReleaseMutex", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "CreateSemaphoreA", @intFromPtr(&stub_args4));
    try environment.addBuiltinExport(m, "WaitForSingleObject", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "WaitForMultipleObjects", @intFromPtr(&stub_args4));
    try environment.addBuiltinExport(m, "ReleaseSemaphore", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "TlsAlloc", @intFromPtr(&kernel32_sync.stub_TlsAlloc));
    try environment.addBuiltinExport(m, "TlsGetValue", @intFromPtr(&kernel32_sync.stub_TlsGetValue));
    try environment.addBuiltinExport(m, "TlsSetValue", @intFromPtr(&kernel32_sync.stub_TlsSetValue));
    try environment.addBuiltinExport(m, "TlsFree", @intFromPtr(&stub_args1));

    // --- Time & Version (time.zig) ---
    try environment.addBuiltinExport(m, "GetTickCount", @intFromPtr(&kernel32_time.stub_GetTickCount));
    try environment.addBuiltinExport(m, "Sleep", @intFromPtr(&kernel32_time.stub_Sleep));
    try environment.addBuiltinExport(m, "QueryPerformanceCounter", @intFromPtr(&kernel32_time.stub_QueryPerformanceCounter));
    try environment.addBuiltinExport(m, "QueryPerformanceFrequency", @intFromPtr(&kernel32_time.stub_QueryPerformanceFrequency));
    try environment.addBuiltinExport(m, "GetLocalTime", @intFromPtr(&kernel32_time.stub_GetLocalTime));
    try environment.addBuiltinExport(m, "GetSystemTime", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "GetSystemTimeAsFileTime", @intFromPtr(&kernel32_time.stub_GetSystemTimeAsFileTime));
    try environment.addBuiltinExport(m, "GetSystemTimeAdjustment", @intFromPtr(&kernel32_time.stub_GetSystemTimeAdjustment));
    try environment.addBuiltinExport(m, "GetTimeZoneInformation", @intFromPtr(&kernel32_time.stub_GetTimeZoneInformation));
    try environment.addBuiltinExport(m, "SystemTimeToFileTime", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "FileTimeToSystemTime", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "FileTimeToLocalFileTime", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "GetVersion", @intFromPtr(&kernel32_time.stub_GetVersion));
    try environment.addBuiltinExport(m, "GetVersionExA", @intFromPtr(&kernel32_time.stub_GetVersionExA));

    // --- Locale, Codepage & Strings (locale.zig) ---
    try environment.addBuiltinExport(m, "GetUserDefaultLangID", @intFromPtr(&kernel32_locale.stub_GetUserDefaultLangID));
    try environment.addBuiltinExport(m, "GetACP", @intFromPtr(&kernel32_locale.stub_GetACP));
    try environment.addBuiltinExport(m, "GetOEMCP", @intFromPtr(&kernel32_locale.stub_GetACP));
    try environment.addBuiltinExport(m, "GetCPInfo", @intFromPtr(&kernel32_locale.stub_GetCPInfo));
    try environment.addBuiltinExport(m, "IsValidCodePage", @intFromPtr(&kernel32_locale.stub_IsValidCodePage));
    try environment.addBuiltinExport(m, "IsDBCSLeadByte", @intFromPtr(&kernel32_locale.stub_IsDBCSLeadByte));
    try environment.addBuiltinExport(m, "IsDBCSLeadByteEx", @intFromPtr(&kernel32_locale.stub_IsDBCSLeadByteEx));
    try environment.addBuiltinExport(m, "MultiByteToWideChar", @intFromPtr(&kernel32_locale.stub_MultiByteToWideChar));
    try environment.addBuiltinExport(m, "WideCharToMultiByte", @intFromPtr(&kernel32_locale.stub_WideCharToMultiByte));
    try environment.addBuiltinExport(m, "FormatMessageA", @intFromPtr(&kernel32_locale.stub_FormatMessageA));
    try environment.addBuiltinExport(m, "GetStringTypeW", @intFromPtr(&kernel32_locale.stub_GetStringTypeW));
    try environment.addBuiltinExport(m, "GetStringTypeA", @intFromPtr(&kernel32_locale.stub_GetStringTypeA));
    try environment.addBuiltinExport(m, "CompareStringA", @intFromPtr(&kernel32_locale.stub_CompareStringA));
    try environment.addBuiltinExport(m, "CompareStringW", @intFromPtr(&kernel32_locale.stub_CompareStringW));
    try environment.addBuiltinExport(m, "LCMapStringA", @intFromPtr(&stub_args6));
    try environment.addBuiltinExport(m, "LCMapStringW", @intFromPtr(&stub_args6));
    try environment.addBuiltinExport(m, "GetSystemDefaultLCID", @intFromPtr(&kernel32_locale.stub_GetSystemDefaultLCID));
    try environment.addBuiltinExport(m, "GetUserDefaultLCID", @intFromPtr(&kernel32_locale.stub_GetUserDefaultLCID));
    try environment.addBuiltinExport(m, "GetLocaleInfoA", @intFromPtr(&kernel32_locale.stub_GetLocaleInfoA));
    try environment.addBuiltinExport(m, "GetLocaleInfoW", @intFromPtr(&kernel32_locale.stub_GetLocaleInfoW));
    try environment.addBuiltinExport(m, "GetThreadLocale", @intFromPtr(&kernel32_locale.stub_GetThreadLocale));
    try environment.addBuiltinExport(m, "IsValidLocale", @intFromPtr(&kernel32_locale.stub_IsValidLocale));
    try environment.addBuiltinExport(m, "EnumSystemLocalesA", @intFromPtr(&kernel32_locale.stub_EnumSystemLocalesA));
    try environment.addBuiltinExport(m, "GetDateFormatA", @intFromPtr(&kernel32_locale.stub_GetDateFormatA));
    try environment.addBuiltinExport(m, "GetTimeFormatA", @intFromPtr(&kernel32_locale.stub_GetTimeFormatA));
    try environment.addBuiltinExport(m, "lstrcpynA", @intFromPtr(&kernel32_locale.stub_lstrcpynA));
    try environment.addBuiltinExport(m, "lstrcmpA", @intFromPtr(&kernel32_locale.stub_lstrcmpA));
    try environment.addBuiltinExport(m, "lstrcpyA", @intFromPtr(&kernel32_locale.stub_lstrcpyA));
    try environment.addBuiltinExport(m, "lstrlenA", @intFromPtr(&kernel32_locale.stub_lstrlenA));
    try environment.addBuiltinExport(m, "lstrcatA", @intFromPtr(&kernel32_locale.stub_lstrcatA));
    try environment.addBuiltinExport(m, "lstrcmpiA", @intFromPtr(&kernel32_locale.stub_lstrcmpiA));
    try environment.addBuiltinExport(m, "lstrcpyW", @intFromPtr(&kernel32_locale.stub_lstrcpyW));
    try environment.addBuiltinExport(m, "lstrcpynW", @intFromPtr(&kernel32_locale.stub_lstrcpynW));
    try environment.addBuiltinExport(m, "lstrcatW", @intFromPtr(&kernel32_locale.stub_lstrcatW));
    try environment.addBuiltinExport(m, "lstrcmpW", @intFromPtr(&kernel32_locale.stub_lstrcmpW));
    try environment.addBuiltinExport(m, "lstrcmpiW", @intFromPtr(&kernel32_locale.stub_lstrcmpiW));
    try environment.addBuiltinExport(m, "lstrlenW", @intFromPtr(&kernel32_locale.stub_lstrlenW));
    try environment.addBuiltinExport(m, "FormatMessageW", @intFromPtr(&stub_args7));
    try environment.addBuiltinExport(m, "FoldStringW", @intFromPtr(&stub_args5));
    try environment.addBuiltinExport(m, "GetDateFormatW", @intFromPtr(&stub_args6));
    try environment.addBuiltinExport(m, "GetTimeFormatW", @intFromPtr(&stub_args6));

    // --- Misc (misc.zig) ---
    try environment.addBuiltinExport(m, "RaiseException", @intFromPtr(&kernel32_misc.stub_RaiseException));
    try environment.addBuiltinExport(m, "SetUnhandledExceptionFilter", @intFromPtr(&kernel32_misc.stub_SetUnhandledExceptionFilter));
    try environment.addBuiltinExport(m, "UnhandledExceptionFilter", @intFromPtr(&kernel32_process.stub_UnhandledExceptionFilter));
    try environment.addBuiltinExport(m, "RtlUnwind", @intFromPtr(&stub_args4));
    try environment.addBuiltinExport(m, "FatalAppExitA", @intFromPtr(&kernel32_misc.stub_FatalAppExitA));
    try environment.addBuiltinExport(m, "SetLastError", @intFromPtr(&kernel32_misc.stub_SetLastError));
    try environment.addBuiltinExport(m, "GetLastError", @intFromPtr(&stub_args0));
    try environment.addBuiltinExport(m, "SetErrorMode", @intFromPtr(&kernel32_misc.stub_SetErrorMode));
    try environment.addBuiltinExport(m, "GetSystemInfo", @intFromPtr(&kernel32_misc.stub_GetSystemInfo));
    try environment.addBuiltinExport(m, "IsProcessorFeaturePresent", @intFromPtr(&kernel32_misc.stub_IsProcessorFeaturePresent));
    try environment.addBuiltinExport(m, "IsBadReadPtr", @intFromPtr(&kernel32_misc.stub_IsBadReadPtr));
    try environment.addBuiltinExport(m, "IsBadWritePtr", @intFromPtr(&kernel32_misc.stub_IsBadWritePtr));
    try environment.addBuiltinExport(m, "IsBadCodePtr", @intFromPtr(&kernel32_misc.stub_IsBadCodePtr));
    try environment.addBuiltinExport(m, "MulDiv", @intFromPtr(&kernel32_misc.stub_MulDiv));
    try environment.addBuiltinExport(m, "Beep", @intFromPtr(&kernel32_misc.stub_Beep));
    try environment.addBuiltinExport(m, "OutputDebugStringA", @intFromPtr(&kernel32_misc.stub_OutputDebugStringA));
    try environment.addBuiltinExport(m, "GetConsoleMode", @intFromPtr(&kernel32_misc.stub_GetConsoleMode));
    try environment.addBuiltinExport(m, "GetConsoleScreenBufferInfo", @intFromPtr(&kernel32_misc.stub_GetConsoleScreenBufferInfo));
    try environment.addBuiltinExport(m, "SetConsoleTitleA", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "FreeConsole", @intFromPtr(&stub_args0));
    try environment.addBuiltinExport(m, "AllocConsole", @intFromPtr(&stub_args0));
    try environment.addBuiltinExport(m, "WriteConsoleA", @intFromPtr(&kernel32_misc.stub_WriteConsoleA));
    try environment.addBuiltinExport(m, "WriteConsoleW", @intFromPtr(&kernel32_misc.stub_WriteConsoleW));
    try environment.addBuiltinExport(m, "GetCurrentDirectoryA", @intFromPtr(&kernel32_misc.stub_GetCurrentDirectoryA));
    try environment.addBuiltinExport(m, "SetCurrentDirectoryA", @intFromPtr(&kernel32_misc.stub_SetCurrentDirectoryA));
    try environment.addBuiltinExport(m, "GetWindowsDirectoryA", @intFromPtr(&kernel32_misc.stub_GetWindowsDirectoryA));
    try environment.addBuiltinExport(m, "GetFullPathNameA", @intFromPtr(&kernel32_misc.stub_GetFullPathNameA));
    try environment.addBuiltinExport(m, "CreateDirectoryA", @intFromPtr(&kernel32_misc.stub_CreateDirectoryA));
    try environment.addBuiltinExport(m, "SetFileApisToOEM", @intFromPtr(&kernel32_misc.stub_SetFileApisToOEM));
    try environment.addBuiltinExport(m, "GetDriveTypeA", @intFromPtr(&kernel32_misc.stub_GetDriveTypeA));
    try environment.addBuiltinExport(m, "GetPrivateProfileStringA", @intFromPtr(&kernel32_misc.stub_GetPrivateProfileStringA));
    try environment.addBuiltinExport(m, "GetPrivateProfileIntA", @intFromPtr(&kernel32_misc.stub_GetPrivateProfileIntA));
    try environment.addBuiltinExport(m, "WritePrivateProfileStringA", @intFromPtr(&kernel32_misc.stub_WritePrivateProfileStringA));
    try environment.addBuiltinExport(m, "GetProfileStringA", @intFromPtr(&kernel32_misc.stub_GetProfileStringA));
    try environment.addBuiltinExport(m, "FindResourceA", @intFromPtr(&kernel32_misc.stub_FindResourceA));
    try environment.addBuiltinExport(m, "FindResourceW", @intFromPtr(&kernel32_misc.stub_FindResourceW));
    try environment.addBuiltinExport(m, "LoadResource", @intFromPtr(&kernel32_misc.stub_LoadResource));
    try environment.addBuiltinExport(m, "SizeofResource", @intFromPtr(&kernel32_misc.stub_SizeofResource));
    try environment.addBuiltinExport(m, "LockResource", @intFromPtr(&kernel32_misc.stub_LockResource));
    try environment.addBuiltinExport(m, "OpenFile", @intFromPtr(&kernel32_misc.stub_OpenFile));
    try environment.addBuiltinExport(m, "DeviceIoControl", @intFromPtr(&stub_args8));

    // W variants needed by win2k apps
    try environment.addBuiltinExport(m, "GetModuleHandleW", @intFromPtr(&kernel32_process.stub_GetModuleHandleA));
    try environment.addBuiltinExport(m, "CreateEventW", @intFromPtr(&kernel32_sync.stub_CreateEventA));
    try environment.addBuiltinExport(m, "GetStartupInfoW", @intFromPtr(&kernel32_process.stub_GetStartupInfoA));
    try environment.addBuiltinExport(m, "GlobalReAlloc", @intFromPtr(&kernel32_mem.stub_GlobalReAlloc));
    try environment.addBuiltinExport(m, "GetProfileIntW", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "GetProfileStringW", @intFromPtr(&stub_args5));
    try environment.addBuiltinExport(m, "WriteProfileStringW", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "GetPrivateProfileIntW", @intFromPtr(&kernel32_misc.stub_GetPrivateProfileIntA));
    try environment.addBuiltinExport(m, "GetPrivateProfileStringW", @intFromPtr(&kernel32_misc.stub_GetPrivateProfileStringW));
    try environment.addBuiltinExport(m, "WritePrivateProfileStringW", @intFromPtr(&kernel32_misc.stub_WritePrivateProfileStringW));
    try environment.addBuiltinExport(m, "CreateProcessW", @intFromPtr(&kernel32_process.stub_CreateProcessA));
    try environment.addBuiltinExport(m, "ExpandEnvironmentStringsW", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "CreateDirectoryW", @intFromPtr(&kernel32_misc.stub_CreateDirectoryA));
    try environment.addBuiltinExport(m, "SetCurrentDirectoryW", @intFromPtr(&kernel32_misc.stub_SetCurrentDirectoryA));
    try environment.addBuiltinExport(m, "GetCurrentDirectoryW", @intFromPtr(&kernel32_misc.stub_GetCurrentDirectoryW));
    try environment.addBuiltinExport(m, "GetShortPathNameW", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "GetNumberFormatW", @intFromPtr(&stub_args6));
    try environment.addBuiltinExport(m, "GetVersionExW", @intFromPtr(&kernel32_time.stub_GetVersionExA));
    try environment.addBuiltinExport(m, "GetComputerNameW", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "GetComputerNameA", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "GlobalAddAtomA", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "GlobalDeleteAtom", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "GetEnvironmentVariableW", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "SetEnvironmentVariableW", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "OutputDebugStringW", @intFromPtr(&kernel32_misc.stub_OutputDebugStringA));
    try environment.addBuiltinExport(m, "SetConsoleTitleW", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "GetWindowsDirectoryW", @intFromPtr(&kernel32_misc.stub_GetWindowsDirectoryA));
    try environment.addBuiltinExport(m, "GetFullPathNameW", @intFromPtr(&stub_args4));
    try environment.addBuiltinExport(m, "GetSystemDirectoryW", @intFromPtr(&kernel32_file.stub_GetSystemDirectoryA));

    // --- Remaining KERNEL32 stubs for 100% win2k coverage ---
    try environment.addBuiltinExport(m, "GlobalCompact", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "FlushConsoleInputBuffer", @intFromPtr(&kernel32_misc.stub_ret_true_1));
    try environment.addBuiltinExport(m, "FillConsoleOutputCharacterW", @intFromPtr(&stub_args5));
    try environment.addBuiltinExport(m, "SetConsoleCursorPosition", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "ReadConsoleW", @intFromPtr(&kernel32_misc.stub_ReadConsoleW));
    try environment.addBuiltinExport(m, "SetLocalTime", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "SetConsoleMode", @intFromPtr(&kernel32_misc.stub_ret_true_2));
    try environment.addBuiltinExport(m, "GetVDMCurrentDirectories", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "GetBinaryTypeW", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "MoveFileExW", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "SearchPathW", @intFromPtr(&stub_args6));
    try environment.addBuiltinExport(m, "GetVolumeInformationW", @intFromPtr(&stub_args8));
    try environment.addBuiltinExport(m, "GetConsoleTitleW", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "GetDriveTypeW", @intFromPtr(&kernel32_misc.stub_GetDriveTypeW));
    try environment.addBuiltinExport(m, "GetFileAttributesExW", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "ScrollConsoleScreenBufferW", @intFromPtr(&stub_args5));
    try environment.addBuiltinExport(m, "SetConsoleTextAttribute", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "FillConsoleOutputAttribute", @intFromPtr(&stub_args5));
    try environment.addBuiltinExport(m, "SetFileAttributesW", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "CopyFileW", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "RemoveDirectoryW", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "CompareFileTime", @intFromPtr(&kernel32_time.stub_CompareFileTime));
    try environment.addBuiltinExport(m, "GetConsoleOutputCP", @intFromPtr(&kernel32_misc.stub_GetConsoleOutputCP));
    try environment.addBuiltinExport(m, "SetThreadLocale", @intFromPtr(&kernel32_misc.stub_ret_true_1));
    try environment.addBuiltinExport(m, "CmdBatNotification", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "MoveFileW", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "GetDiskFreeSpaceExW", @intFromPtr(&stub_args4));
    try environment.addBuiltinExport(m, "GetTempPathW", @intFromPtr(&kernel32_file.stub_GetTempPathA));
    try environment.addBuiltinExport(m, "GetTempFileNameW", @intFromPtr(&stub_args4));
    try environment.addBuiltinExport(m, "CreateMutexW", @intFromPtr(&kernel32_sync.stub_CreateMutexA));
    try environment.addBuiltinExport(m, "SetProcessShutdownParameters", @intFromPtr(&kernel32_misc.stub_ret_true_2));
    try environment.addBuiltinExport(m, "GetPriorityClass", @intFromPtr(&kernel32_process.stub_GetPriorityClass));
    try environment.addBuiltinExport(m, "SetProcessAffinityMask", @intFromPtr(&stub_args2));
    try environment.addBuiltinExport(m, "GetProcessAffinityMask", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "VerifyVersionInfoW", @intFromPtr(&stub_args4));
    try environment.addBuiltinExport(m, "GetPrivateProfileStringW", @intFromPtr(&stub_args6));
    try environment.addBuiltinExport(m, "DeleteAtom", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "GlobalAddAtomW", @intFromPtr(&stub_args1));
    try environment.addBuiltinExport(m, "GlobalGetAtomNameW", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "EnumDateFormatsW", @intFromPtr(&stub_args3));
    try environment.addBuiltinExport(m, "EnumTimeFormatsW", @intFromPtr(&stub_args3));
}

pub fn stub_args0() callconv(.winapi) usize {
    return 0;
}

pub fn stub_args1(a: usize) callconv(.winapi) u32 {
    _ = a;
    if (trace.enable_tracing) trace.print("KERNEL32: generic stub1 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args2(a: usize, b: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    if (trace.enable_tracing) trace.print("KERNEL32: generic stub2 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args3(a: usize, b: usize, c: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    if (trace.enable_tracing) trace.print("KERNEL32: generic stub3 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args4(a: usize, b: usize, c: usize, d: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    if (trace.enable_tracing) trace.print("KERNEL32: generic stub4 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    if (trace.enable_tracing) trace.print("KERNEL32: generic stub5 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    if (trace.enable_tracing) trace.print("KERNEL32: generic stub6 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args7(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    if (trace.enable_tracing) trace.print("KERNEL32: generic stub7 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args8(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    _ = h;
    if (trace.enable_tracing) trace.print("KERNEL32: generic stub8 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args9(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize, i: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    _ = h;
    _ = i;
    if (trace.enable_tracing) trace.print("KERNEL32: generic stub9 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args10(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize, i: usize, j: usize) callconv(.winapi) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    _ = h;
    _ = i;
    _ = j;
    if (trace.enable_tracing) trace.print("KERNEL32: generic stub10 called from {x}\n", .{@returnAddress()});
    return 0;
}


