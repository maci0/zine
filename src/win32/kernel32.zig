//! KERNEL32.dll function stubs and state.
//!
//! This module provides the registration logic for KERNEL32 API stubs.
//! Most implementations are delegated to sub-modules in `win32/kernel32/`.
//! It also maintains global state such as the main module handle and
//! application code bounds for error recovery.
//!
//! Stubs are categorized into:
//! - File I/O: CreateFile, ReadFile, WriteFile, etc.
//! - Memory: VirtualAlloc, HeapAlloc, GlobalAlloc, etc.
//! - Process/Thread: GetCurrentProcess, GetProcAddress, CreateThread (stub), etc.
//! - System Info: GetVersion, GetSystemTime, GetLocaleInfo, etc.
//! - Synchronization: CreateEvent, EnterCriticalSection, etc.

const std = @import("std");
const env = @import("../loader/env.zig");
const w32 = @import("constants.zig");

pub var global_env: ?*env.Environment = null;
pub var main_module_handle: usize = 0;
pub var main_exe_dir: [512]u8 = undefined;
pub var main_exe_dir_len: usize = 0;

/// Bounds of the main PE's executable code (.text section).
/// Set during PE loading so the SIGSEGV handler can distinguish
/// code addresses from data addresses during stack recovery.
pub var app_code_start: usize = 0x401000;
pub var app_code_end: usize = 0x700000;

const kernel32_file = @import("kernel32/file.zig");
const kernel32_mem = @import("kernel32/mem.zig");
const kernel32_process = @import("kernel32/process.zig");
const kernel32_misc = @import("kernel32/misc.zig");
const kernel32_sync = @import("kernel32/sync.zig");
const kernel32_time = @import("kernel32/time.zig");
const kernel32_locale = @import("kernel32/locale.zig");
const kernel32_console = @import("kernel32/console.zig");
const kernel32_error = @import("kernel32/error.zig");
const kernel32_sysinfo = @import("kernel32/sysinfo.zig");
const kernel32_resource = @import("kernel32/resource.zig");
const kernel32_profile = @import("kernel32/profile.zig");
const kernel32_path = @import("kernel32/path.zig");
const w32cc = @import("calling_convention.zig");

/// Registers KERNEL32.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    global_env = environment;
    const m = "KERNEL32.dll";

    // --- File I/O (file.zig) ---
    try environment.addBuiltinExportComptime(m, "CreateFileA", kernel32_file.CreateFileA);
    try environment.addBuiltinExportComptime(m, "CreateFileW", kernel32_file.CreateFileW);
    try environment.addBuiltinExportComptime(m, "CloseHandle", kernel32_file.CloseHandle);
    try environment.addBuiltinExportComptime(m, "ReadFile", kernel32_file.ReadFile);
    try environment.addBuiltinExportComptime(m, "WriteFile", kernel32_file.WriteFile);
    try environment.addBuiltinExportComptime(m, "SetFilePointer", kernel32_file.SetFilePointer);
    try environment.addBuiltinExportComptime(m, "SetEndOfFile", kernel32_file.SetEndOfFile);
    try environment.addBuiltinExportComptime(m, "GetFileSize", kernel32_file.GetFileSize);
    try environment.addBuiltinExportComptime(m, "GetFileType", kernel32_file.GetFileType);
    try environment.addBuiltinExportComptime(m, "GetFileInformationByHandle", kernel32_file.GetFileInformationByHandle);
    try environment.addBuiltinExportComptime(m, "GetFileAttributesA", kernel32_file.GetFileAttributesA);
    try environment.addBuiltinExportComptime(m, "GetFileAttributesW", kernel32_file.GetFileAttributesW);
    try environment.addBuiltinExportComptime(m, "SetFileAttributesA", kernel32_file.stub_SetFileAttributesA);
    try environment.addBuiltinExportComptime(m, "GetStdHandle", kernel32_file.GetStdHandle);
    try environment.addBuiltinExportComptime(m, "SetStdHandle", kernel32_file.stub_SetStdHandle);
    try environment.addBuiltinExportComptime(m, "FlushFileBuffers", kernel32_file.FlushFileBuffers);
    try environment.addBuiltinExportComptime(m, "DeleteFileA", kernel32_file.DeleteFileA);
    try environment.addBuiltinExportComptime(m, "FindFirstFileA", kernel32_file.FindFirstFileA);
    try environment.addBuiltinExportComptime(m, "FindNextFileA", kernel32_file.FindNextFileA);
    try environment.addBuiltinExportComptime(m, "FindClose", kernel32_file.FindClose);
    try environment.addBuiltinExportComptime(m, "CreateFileMappingA", kernel32_file.CreateFileMappingA);
    try environment.addBuiltinExportComptime(m, "MapViewOfFile", kernel32_file.MapViewOfFile);
    try environment.addBuiltinExportComptime(m, "MapViewOfFileEx", kernel32_file.MapViewOfFileEx);
    try environment.addBuiltinExportComptime(m, "UnmapViewOfFile", kernel32_file.UnmapViewOfFile);
    try environment.addBuiltinExportComptime(m, "OpenFileMappingA", kernel32_file.stub_OpenFileMappingA);
    try environment.addBuiltinExportComptime(m, "CopyFileA", kernel32_file.CopyFileA);
    try environment.addBuiltinExportComptime(m, "SearchPathA", kernel32_file.SearchPathA);
    try environment.addBuiltinExportComptime(m, "GetTempPathA", kernel32_file.GetTempPathA);
    try environment.addBuiltinExportComptime(m, "GetTempFileNameA", kernel32_file.GetTempFileNameA);
    try environment.addBuiltinExportComptime(m, "GetSystemDirectoryA", kernel32_file.GetSystemDirectoryA);
    try environment.addBuiltinExportComptime(m, "GetDiskFreeSpaceA", kernel32_file.GetDiskFreeSpaceA);
    try environment.addBuiltinExportComptime(m, "GetFileTime", kernel32_file.GetFileTime);
    try environment.addBuiltinExportComptime(m, "SetFileTime", kernel32_file.stub_SetFileTime);
    try environment.addBuiltinExportComptime(m, "SetHandleCount", kernel32_file.SetHandleCount);
    try environment.addBuiltinExportComptime(m, "SetCommBreak", stub_args1);
    try environment.addBuiltinExportComptime(m, "ClearCommBreak", stub_args1);
    try environment.addBuiltinExportComptime(m, "GetCommState", stub_args2);
    try environment.addBuiltinExportComptime(m, "SetCommState", stub_args2);
    try environment.addBuiltinExportComptime(m, "SetCommTimeouts", stub_args2);
    try environment.addBuiltinExportComptime(m, "GetOverlappedResult", stub_args4);
    try environment.addBuiltinExportComptime(m, "CreateFileMappingW", kernel32_file.CreateFileMappingA);
    try environment.addBuiltinExportComptime(m, "DeleteFileW", kernel32_file.DeleteFileA);

    // --- Memory (mem.zig) ---
    try environment.addBuiltinExportComptime(m, "HeapCreate", kernel32_mem.HeapCreate);
    try environment.addBuiltinExportComptime(m, "HeapDestroy", kernel32_mem.HeapDestroy);
    try environment.addBuiltinExportComptime(m, "HeapAlloc", kernel32_mem.HeapAlloc);
    try environment.addBuiltinExportComptime(m, "HeapReAlloc", kernel32_mem.HeapReAlloc);
    try environment.addBuiltinExportComptime(m, "HeapFree", kernel32_mem.HeapFree);
    try environment.addBuiltinExportComptime(m, "HeapSetInformation", stub_args4);
    try environment.addBuiltinExportComptime(m, "HeapSize", kernel32_sysinfo.HeapSize);
    try environment.addBuiltinExportComptime(m, "HeapValidate", kernel32_sysinfo.stub_HeapValidate);
    try environment.addBuiltinExportComptime(m, "GetProcessHeap", kernel32_mem.GetProcessHeap);
    try environment.addBuiltinExportComptime(m, "LocalAlloc", kernel32_mem.LocalAlloc);
    try environment.addBuiltinExportComptime(m, "LocalFree", kernel32_mem.LocalFree);
    try environment.addBuiltinExportComptime(m, "GlobalAlloc", kernel32_mem.GlobalAlloc);
    try environment.addBuiltinExportComptime(m, "GlobalFree", kernel32_mem.GlobalFree);
    try environment.addBuiltinExportComptime(m, "GlobalLock", kernel32_mem.GlobalLock);
    try environment.addBuiltinExportComptime(m, "GlobalUnlock", kernel32_mem.GlobalUnlock);
    try environment.addBuiltinExportComptime(m, "GlobalSize", kernel32_mem.GlobalSize);
    try environment.addBuiltinExportComptime(m, "GlobalHandle", kernel32_mem.GlobalHandle);
    try environment.addBuiltinExportComptime(m, "GlobalMemoryStatus", kernel32_mem.GlobalMemoryStatus);
    try environment.addBuiltinExportComptime(m, "VirtualAlloc", kernel32_mem.VirtualAlloc);
    try environment.addBuiltinExportComptime(m, "VirtualFree", kernel32_mem.VirtualFree);
    try environment.addBuiltinExportComptime(m, "VirtualProtect", kernel32_mem.VirtualProtect);
    try environment.addBuiltinExportComptime(m, "VirtualQuery", kernel32_mem.VirtualQuery);
    try environment.addBuiltinExportComptime(m, "LocalLock", kernel32_mem.LocalLock);
    try environment.addBuiltinExportComptime(m, "LocalUnlock", kernel32_mem.LocalUnlock);
    try environment.addBuiltinExportComptime(m, "LocalSize", kernel32_mem.LocalSize);
    try environment.addBuiltinExportComptime(m, "LocalReAlloc", kernel32_mem.LocalReAlloc);

    // --- Process & Module (process.zig) ---
    try environment.addBuiltinExportComptime(m, "ExitProcess", kernel32_process.ExitProcess);
    try environment.addBuiltinExportComptime(m, "CreateProcessA", kernel32_process.CreateProcessA);
    try environment.addBuiltinExportComptime(m, "GetCurrentProcess", kernel32_process.GetCurrentProcess);
    try environment.addBuiltinExportComptime(m, "GetCurrentProcessId", kernel32_process.GetCurrentProcessId);
    try environment.addBuiltinExportComptime(m, "GetCurrentThread", kernel32_process.GetCurrentThread);
    try environment.addBuiltinExportComptime(m, "GetCurrentThreadId", kernel32_process.GetCurrentThreadId);
    try environment.addBuiltinExportComptime(m, "CreateThread", kernel32_process.CreateThread);
    try environment.addBuiltinExportComptime(m, "ExitThread", kernel32_process.stub_ExitThread);
    try environment.addBuiltinExportComptime(m, "GetStartupInfoA", kernel32_process.GetStartupInfoA);
    try environment.addBuiltinExportComptime(m, "GetCommandLineA", kernel32_process.GetCommandLineA);
    try environment.addBuiltinExportComptime(m, "GetCommandLineW", kernel32_process.GetCommandLineW);
    try environment.addBuiltinExportComptime(m, "LoadLibraryA", kernel32_process.LoadLibraryA);
    try environment.addBuiltinExportComptime(m, "LoadLibraryW", kernel32_process.LoadLibraryW);
    try environment.addBuiltinExportComptime(m, "FreeLibrary", kernel32_process.stub_FreeLibrary);
    try environment.addBuiltinExportComptime(m, "GetModuleHandleA", kernel32_process.GetModuleHandleA);
    try environment.addBuiltinExportComptime(m, "GetProcAddress", kernel32_process.GetProcAddress);
    try environment.addBuiltinExportComptime(m, "GetModuleFileNameA", kernel32_misc.GetModuleFileNameA);
    try environment.addBuiltinExportComptime(m, "GetModuleFileNameW", kernel32_process.GetModuleFileNameW);
    try environment.addBuiltinExportComptime(m, "SetConsoleCtrlHandler", kernel32_process.stub_SetConsoleCtrlHandler);
    try environment.addBuiltinExportComptime(m, "DisableThreadLibraryCalls", kernel32_process.stub_DisableThreadLibraryCalls);
    try environment.addBuiltinExportComptime(m, "OpenProcess", kernel32_process.stub_OpenProcess);
    try environment.addBuiltinExportComptime(m, "TerminateProcess", kernel32_process.stub_TerminateProcess);
    try environment.addBuiltinExportComptime(m, "SetPriorityClass", kernel32_process.stub_SetPriorityClass);
    try environment.addBuiltinExportComptime(m, "SetThreadPriority", kernel32_process.stub_SetThreadPriority);
    try environment.addBuiltinExportComptime(m, "ResumeThread", kernel32_process.stub_ResumeThread);
    try environment.addBuiltinExportComptime(m, "SuspendThread", kernel32_process.stub_SuspendThread);
    try environment.addBuiltinExportComptime(m, "GetProcessTimes", stub_args5);
    try environment.addBuiltinExportComptime(m, "GetThreadTimes", stub_args5);
    try environment.addBuiltinExportComptime(m, "GetExitCodeProcess", kernel32_process.GetExitCodeProcess);
    try environment.addBuiltinExportComptime(m, "DebugBreak", stub_args0);
    try environment.addBuiltinExportComptime(m, "SetHandleInformation", kernel32_process.stub_SetHandleInformation);
    try environment.addBuiltinExportComptime(m, "CreatePipe", kernel32_process.CreatePipe);
    try environment.addBuiltinExportComptime(m, "PeekNamedPipe", stub_args6); // stub — returns 0 (no data)
    try environment.addBuiltinExportComptime(m, "DuplicateHandle", kernel32_sync.DuplicateHandle);
    try environment.addBuiltinExportComptime(m, "ReadProcessMemory", stub_args5);
    try environment.addBuiltinExportComptime(m, "GenerateConsoleCtrlEvent", stub_args2);
    try environment.addBuiltinExportComptime(m, "FindFirstFileW", kernel32_file.FindFirstFileW);
    try environment.addBuiltinExportComptime(m, "FindNextFileW", kernel32_file.FindNextFileW);
    try environment.addBuiltinExportComptime(m, "GetExitCodeThread", stub_args2); // same shape as GetExitCodeProcess, returns 0
    try environment.addBuiltinExportComptime(m, "SetThreadAffinityMask", stub_args2); // returns previous mask (0 is ok)
    try environment.addBuiltinExportComptime(m, "SignalObjectAndWait", stub_args4); // returns WAIT_OBJECT_0 (0)

    // --- Environment (process.zig) ---
    try environment.addBuiltinExportComptime(m, "GetEnvironmentStrings", kernel32_process.GetEnvironmentStringsA);
    try environment.addBuiltinExportComptime(m, "GetEnvironmentStringsA", kernel32_process.GetEnvironmentStringsA);
    try environment.addBuiltinExportComptime(m, "GetEnvironmentStringsW", kernel32_process.GetEnvironmentStringsW);
    try environment.addBuiltinExportComptime(m, "FreeEnvironmentStringsA", kernel32_process.FreeEnvironmentStringsA);
    try environment.addBuiltinExportComptime(m, "FreeEnvironmentStringsW", kernel32_process.FreeEnvironmentStringsW);
    try environment.addBuiltinExportComptime(m, "GetEnvironmentVariableA", kernel32_process.GetEnvironmentVariableA);
    try environment.addBuiltinExportComptime(m, "SetEnvironmentVariableA", kernel32_process.SetEnvironmentVariableA);

    // --- Synchronization (sync.zig) ---
    try environment.addBuiltinExportComptime(m, "InitializeCriticalSection", kernel32_sync.InitializeCriticalSection);
    try environment.addBuiltinExportComptime(m, "EnterCriticalSection", kernel32_sync.EnterCriticalSection);
    try environment.addBuiltinExportComptime(m, "LeaveCriticalSection", kernel32_sync.LeaveCriticalSection);
    try environment.addBuiltinExportComptime(m, "DeleteCriticalSection", kernel32_sync.DeleteCriticalSection);
    try environment.addBuiltinExportComptime(m, "InterlockedIncrement", kernel32_sync.InterlockedIncrement);
    try environment.addBuiltinExportComptime(m, "InterlockedDecrement", kernel32_sync.InterlockedDecrement);
    try environment.addBuiltinExportComptime(m, "InterlockedExchange", kernel32_sync.InterlockedExchange);
    try environment.addBuiltinExportComptime(m, "CreateEventA", kernel32_sync.stub_CreateEventA);
    try environment.addBuiltinExportComptime(m, "SetEvent", kernel32_sync.stub_SetEvent);
    try environment.addBuiltinExportComptime(m, "ResetEvent", kernel32_sync.stub_ResetEvent);
    try environment.addBuiltinExportComptime(m, "OpenEventA", kernel32_sync.stub_OpenEventA);
    try environment.addBuiltinExportComptime(m, "CreateMutexA", kernel32_sync.stub_CreateMutexA);
    try environment.addBuiltinExportComptime(m, "ReleaseMutex", kernel32_sync.stub_ReleaseMutex);
    try environment.addBuiltinExportComptime(m, "CreateSemaphoreA", kernel32_sync.stub_CreateSemaphoreA);
    try environment.addBuiltinExportComptime(m, "WaitForSingleObject", kernel32_sync.WaitForSingleObject);
    try environment.addBuiltinExportComptime(m, "WaitForMultipleObjects", kernel32_sync.stub_WaitForMultipleObjects);
    try environment.addBuiltinExportComptime(m, "ReleaseSemaphore", kernel32_sync.stub_ReleaseSemaphore);
    try environment.addBuiltinExportComptime(m, "TlsAlloc", kernel32_sync.TlsAlloc);
    try environment.addBuiltinExportComptime(m, "TlsGetValue", kernel32_sync.TlsGetValue);
    try environment.addBuiltinExportComptime(m, "TlsSetValue", kernel32_sync.TlsSetValue);
    try environment.addBuiltinExportComptime(m, "TlsFree", kernel32_sync.TlsFree);

    // --- Time & Version (time.zig) ---
    try environment.addBuiltinExportComptime(m, "GetTickCount", kernel32_time.GetTickCount);
    try environment.addBuiltinExportComptime(m, "Sleep", kernel32_time.Sleep);
    try environment.addBuiltinExportComptime(m, "QueryPerformanceCounter", kernel32_time.QueryPerformanceCounter);
    try environment.addBuiltinExportComptime(m, "QueryPerformanceFrequency", kernel32_time.QueryPerformanceFrequency);
    try environment.addBuiltinExportComptime(m, "GetLocalTime", kernel32_time.GetLocalTime);
    try environment.addBuiltinExportComptime(m, "GetSystemTime", kernel32_time.GetSystemTime);
    try environment.addBuiltinExportComptime(m, "GetSystemTimeAsFileTime", kernel32_time.GetSystemTimeAsFileTime);
    try environment.addBuiltinExportComptime(m, "GetSystemTimeAdjustment", kernel32_time.GetSystemTimeAdjustment);
    try environment.addBuiltinExportComptime(m, "GetTimeZoneInformation", kernel32_time.GetTimeZoneInformation);
    try environment.addBuiltinExportComptime(m, "SystemTimeToFileTime", kernel32_time.SystemTimeToFileTime);
    try environment.addBuiltinExportComptime(m, "FileTimeToSystemTime", kernel32_time.FileTimeToSystemTime);
    try environment.addBuiltinExportComptime(m, "FileTimeToLocalFileTime", kernel32_time.FileTimeToLocalFileTime);
    try environment.addBuiltinExportComptime(m, "GetVersion", kernel32_time.GetVersion);
    try environment.addBuiltinExportComptime(m, "GetVersionExA", kernel32_time.GetVersionExA);

    // --- Locale, Codepage & Strings (locale.zig) ---
    try environment.addBuiltinExportComptime(m, "GetUserDefaultLangID", kernel32_locale.GetUserDefaultLangID);
    try environment.addBuiltinExportComptime(m, "GetACP", kernel32_locale.GetACP);
    try environment.addBuiltinExportComptime(m, "GetOEMCP", kernel32_locale.GetACP);
    try environment.addBuiltinExportComptime(m, "GetCPInfo", kernel32_locale.GetCPInfo);
    try environment.addBuiltinExportComptime(m, "IsValidCodePage", kernel32_locale.IsValidCodePage);
    try environment.addBuiltinExportComptime(m, "IsDBCSLeadByte", kernel32_locale.IsDBCSLeadByte);
    try environment.addBuiltinExportComptime(m, "IsDBCSLeadByteEx", kernel32_locale.IsDBCSLeadByteEx);
    try environment.addBuiltinExportComptime(m, "MultiByteToWideChar", kernel32_locale.MultiByteToWideChar);
    try environment.addBuiltinExportComptime(m, "WideCharToMultiByte", kernel32_locale.WideCharToMultiByte);
    try environment.addBuiltinExportComptime(m, "FormatMessageA", kernel32_locale.FormatMessageA);
    try environment.addBuiltinExportComptime(m, "GetStringTypeW", kernel32_locale.GetStringTypeW);
    try environment.addBuiltinExportComptime(m, "GetStringTypeA", kernel32_locale.GetStringTypeA);
    try environment.addBuiltinExportComptime(m, "CompareStringA", kernel32_locale.CompareStringA);
    try environment.addBuiltinExportComptime(m, "CompareStringW", kernel32_locale.CompareStringW);
    try environment.addBuiltinExportComptime(m, "LCMapStringA", kernel32_locale.LCMapStringA);
    try environment.addBuiltinExportComptime(m, "LCMapStringW", kernel32_locale.LCMapStringW);
    try environment.addBuiltinExportComptime(m, "GetSystemDefaultLCID", kernel32_locale.GetSystemDefaultLCID);
    try environment.addBuiltinExportComptime(m, "GetUserDefaultLCID", kernel32_locale.GetUserDefaultLCID);
    try environment.addBuiltinExportComptime(m, "GetLocaleInfoA", kernel32_locale.GetLocaleInfoA);
    try environment.addBuiltinExportComptime(m, "GetLocaleInfoW", kernel32_locale.GetLocaleInfoW);
    try environment.addBuiltinExportComptime(m, "GetThreadLocale", kernel32_locale.GetThreadLocale);
    try environment.addBuiltinExportComptime(m, "IsValidLocale", kernel32_locale.stub_IsValidLocale);
    try environment.addBuiltinExportComptime(m, "EnumSystemLocalesA", kernel32_locale.EnumSystemLocalesA);
    try environment.addBuiltinExportComptime(m, "GetDateFormatA", kernel32_locale.stub_GetDateFormatA);
    try environment.addBuiltinExportComptime(m, "GetTimeFormatA", kernel32_locale.stub_GetTimeFormatA);
    try environment.addBuiltinExportComptime(m, "lstrcpynA", kernel32_locale.lstrcpynA);
    try environment.addBuiltinExportComptime(m, "lstrcmpA", kernel32_locale.lstrcmpA);
    try environment.addBuiltinExportComptime(m, "lstrcpyA", kernel32_locale.lstrcpyA);
    try environment.addBuiltinExportComptime(m, "lstrlenA", kernel32_locale.lstrlenA);
    try environment.addBuiltinExportComptime(m, "lstrcatA", kernel32_locale.lstrcatA);
    try environment.addBuiltinExportComptime(m, "lstrcmpiA", kernel32_locale.lstrcmpiA);
    try environment.addBuiltinExportComptime(m, "lstrcpyW", kernel32_locale.lstrcpyW);
    try environment.addBuiltinExportComptime(m, "lstrcpynW", kernel32_locale.lstrcpynW);
    try environment.addBuiltinExportComptime(m, "lstrcatW", kernel32_locale.lstrcatW);
    try environment.addBuiltinExportComptime(m, "lstrcmpW", kernel32_locale.lstrcmpW);
    try environment.addBuiltinExportComptime(m, "lstrcmpiW", kernel32_locale.lstrcmpiW);
    try environment.addBuiltinExportComptime(m, "lstrlenW", kernel32_locale.lstrlenW);
    try environment.addBuiltinExportComptime(m, "FormatMessageW", stub_args7);
    try environment.addBuiltinExportComptime(m, "FoldStringW", stub_args5);
    try environment.addBuiltinExportComptime(m, "GetDateFormatW", stub_args6);
    try environment.addBuiltinExportComptime(m, "GetTimeFormatW", stub_args6);

    // --- Misc (misc.zig) ---
    try environment.addBuiltinExportComptime(m, "RaiseException", kernel32_error.RaiseException);
    try environment.addBuiltinExportComptime(m, "SetUnhandledExceptionFilter", kernel32_error.SetUnhandledExceptionFilter);
    try environment.addBuiltinExportComptime(m, "UnhandledExceptionFilter", kernel32_process.UnhandledExceptionFilter);
    try environment.addBuiltinExportComptime(m, "RtlUnwind", kernel32_error.RtlUnwind);
    try environment.addBuiltinExportComptime(m, "FatalAppExitA", kernel32_error.FatalAppExitA);
    try environment.addBuiltinExportComptime(m, "SetLastError", kernel32_error.SetLastError);
    try environment.addBuiltinExportComptime(m, "GetLastError", kernel32_error.GetLastError);
    try environment.addBuiltinExportComptime(m, "SetErrorMode", kernel32_error.stub_SetErrorMode);
    try environment.addBuiltinExportComptime(m, "GetSystemInfo", kernel32_sysinfo.GetSystemInfo);
    try environment.addBuiltinExportComptime(m, "IsProcessorFeaturePresent", kernel32_sysinfo.IsProcessorFeaturePresent);
    try environment.addBuiltinExportComptime(m, "IsBadReadPtr", kernel32_sysinfo.IsBadReadPtr);
    try environment.addBuiltinExportComptime(m, "IsBadWritePtr", kernel32_sysinfo.IsBadWritePtr);
    try environment.addBuiltinExportComptime(m, "IsBadCodePtr", kernel32_sysinfo.IsBadCodePtr);
    try environment.addBuiltinExportComptime(m, "IsBadStringPtrA", kernel32_sysinfo.IsBadStringPtrA);
    try environment.addBuiltinExportComptime(m, "IsBadStringPtrW", kernel32_sysinfo.IsBadStringPtrW);
    try environment.addBuiltinExportComptime(m, "MulDiv", kernel32_sysinfo.MulDiv);
    try environment.addBuiltinExportComptime(m, "Beep", kernel32_sysinfo.stub_Beep);
    try environment.addBuiltinExportComptime(m, "OutputDebugStringA", kernel32_error.OutputDebugStringA);
    try environment.addBuiltinExportComptime(m, "GetConsoleMode", kernel32_console.GetConsoleMode);
    try environment.addBuiltinExportComptime(m, "GetConsoleCP", kernel32_locale.GetACP); // same as ANSI codepage
    try environment.addBuiltinExportComptime(m, "GetConsoleScreenBufferInfo", kernel32_console.GetConsoleScreenBufferInfo);
    try environment.addBuiltinExportComptime(m, "SetConsoleTitleA", stub_args1);
    try environment.addBuiltinExportComptime(m, "FreeConsole", stub_args0);
    try environment.addBuiltinExportComptime(m, "AllocConsole", stub_args0);
    try environment.addBuiltinExportComptime(m, "ReadConsoleInputA", stub_args4); // returns 0 (no input)
    try environment.addBuiltinExportComptime(m, "WriteConsoleA", kernel32_console.WriteConsoleA);
    try environment.addBuiltinExportComptime(m, "WriteConsoleW", kernel32_console.WriteConsoleW);
    try environment.addBuiltinExportComptime(m, "GetCurrentDirectoryA", kernel32_path.GetCurrentDirectoryA);
    try environment.addBuiltinExportComptime(m, "SetCurrentDirectoryA", kernel32_path.SetCurrentDirectoryA);
    try environment.addBuiltinExportComptime(m, "GetWindowsDirectoryA", kernel32_path.GetWindowsDirectoryA);
    try environment.addBuiltinExportComptime(m, "GetFullPathNameA", kernel32_path.GetFullPathNameA);
    try environment.addBuiltinExportComptime(m, "CreateDirectoryA", kernel32_path.CreateDirectoryA);
    try environment.addBuiltinExportComptime(m, "SetFileApisToOEM", kernel32_sysinfo.stub_SetFileApisToOEM);
    try environment.addBuiltinExportComptime(m, "AreFileApisANSI", kernel32_console.stub_ret_true_1); // Returns TRUE
    try environment.addBuiltinExportComptime(m, "LoadLibraryExA", kernel32_process.LoadLibraryExA);
    try environment.addBuiltinExportComptime(m, "GetDriveTypeA", kernel32_path.stub_GetDriveTypeA);
    try environment.addBuiltinExportComptime(m, "MoveFileA", stub_args2); // returns TRUE (1 -> stub_args2 returns 0, need real stub)
    try environment.addBuiltinExportComptime(m, "FindFirstFileExA", kernel32_file.FindFirstFileExA);
    try environment.addBuiltinExportComptime(m, "SleepEx", kernel32_sysinfo.SleepEx);
    try environment.addBuiltinExportComptime(m, "GlobalMemoryStatusEx", kernel32_sysinfo.GlobalMemoryStatusEx);
    try environment.addBuiltinExportComptime(m, "GetPrivateProfileStringA", kernel32_profile.GetPrivateProfileStringA);
    try environment.addBuiltinExportComptime(m, "GetPrivateProfileIntA", kernel32_profile.GetPrivateProfileIntA);
    try environment.addBuiltinExportComptime(m, "WritePrivateProfileStringA", kernel32_profile.stub_WritePrivateProfileStringA);
    try environment.addBuiltinExportComptime(m, "GetProfileStringA", kernel32_profile.stub_GetProfileStringA);
    try environment.addBuiltinExportComptime(m, "FindResourceA", kernel32_resource.FindResourceA);
    try environment.addBuiltinExportComptime(m, "FindResourceW", kernel32_resource.FindResourceW);
    try environment.addBuiltinExportComptime(m, "LoadResource", kernel32_resource.LoadResource);
    try environment.addBuiltinExportComptime(m, "SizeofResource", kernel32_resource.stub_SizeofResource);
    try environment.addBuiltinExportComptime(m, "LockResource", kernel32_resource.LockResource);
    try environment.addBuiltinExportComptime(m, "OpenFile", kernel32_misc.stub_OpenFile);
    try environment.addBuiltinExportComptime(m, "DeviceIoControl", kernel32_file.DeviceIoControl);

    // W variants needed by win2k apps
    try environment.addBuiltinExportComptime(m, "GetModuleHandleW", kernel32_process.GetModuleHandleW);
    try environment.addBuiltinExportComptime(m, "CreateEventW", kernel32_sync.stub_CreateEventA);
    try environment.addBuiltinExportComptime(m, "GetStartupInfoW", kernel32_process.GetStartupInfoA);
    try environment.addBuiltinExportComptime(m, "GlobalReAlloc", kernel32_mem.GlobalReAlloc);
    try environment.addBuiltinExportComptime(m, "GetProfileIntW", stub_args3);
    try environment.addBuiltinExportComptime(m, "GetProfileStringW", stub_args5);
    try environment.addBuiltinExportComptime(m, "WriteProfileStringW", stub_args3);
    try environment.addBuiltinExportComptime(m, "GetPrivateProfileIntW", kernel32_profile.GetPrivateProfileIntA);
    try environment.addBuiltinExportComptime(m, "GetPrivateProfileStringW", kernel32_profile.GetPrivateProfileStringW);
    try environment.addBuiltinExportComptime(m, "WritePrivateProfileStringW", kernel32_profile.stub_WritePrivateProfileStringW);
    try environment.addBuiltinExportComptime(m, "CreateProcessW", kernel32_process.CreateProcessW);
    try environment.addBuiltinExportComptime(m, "ExpandEnvironmentStringsW", stub_args3);
    try environment.addBuiltinExportComptime(m, "CreateDirectoryW", kernel32_path.CreateDirectoryA);
    try environment.addBuiltinExportComptime(m, "SetCurrentDirectoryW", kernel32_path.SetCurrentDirectoryW);
    try environment.addBuiltinExportComptime(m, "GetCurrentDirectoryW", kernel32_path.GetCurrentDirectoryW);
    try environment.addBuiltinExportComptime(m, "GetShortPathNameW", stub_args3);
    try environment.addBuiltinExportComptime(m, "GetNumberFormatW", stub_args6);
    try environment.addBuiltinExportComptime(m, "GetVersionExW", kernel32_time.GetVersionExA);
    try environment.addBuiltinExportComptime(m, "GetComputerNameW", stub_args2);
    try environment.addBuiltinExportComptime(m, "GetComputerNameA", stub_args2);
    try environment.addBuiltinExportComptime(m, "GlobalAddAtomA", stub_args1);
    try environment.addBuiltinExportComptime(m, "GlobalDeleteAtom", stub_args1);
    try environment.addBuiltinExportComptime(m, "GetEnvironmentVariableW", stub_args3);
    try environment.addBuiltinExportComptime(m, "SetEnvironmentVariableW", stub_args2);
    try environment.addBuiltinExportComptime(m, "OutputDebugStringW", kernel32_error.OutputDebugStringA);
    try environment.addBuiltinExportComptime(m, "SetConsoleTitleW", stub_args1);
    try environment.addBuiltinExportComptime(m, "GetWindowsDirectoryW", kernel32_path.GetWindowsDirectoryA);
    try environment.addBuiltinExportComptime(m, "GetFullPathNameW", kernel32_path.GetFullPathNameW);
    try environment.addBuiltinExportComptime(m, "GetSystemDirectoryW", kernel32_file.GetSystemDirectoryA);

    // --- Remaining KERNEL32 stubs for 100% win2k coverage ---
    try environment.addBuiltinExportComptime(m, "GlobalCompact", stub_args1);
    try environment.addBuiltinExportComptime(m, "FlushConsoleInputBuffer", kernel32_console.stub_ret_true_1);
    try environment.addBuiltinExportComptime(m, "FillConsoleOutputCharacterW", stub_args5);
    try environment.addBuiltinExportComptime(m, "SetConsoleCursorPosition", stub_args2);
    try environment.addBuiltinExportComptime(m, "ReadConsoleW", kernel32_console.ReadConsoleW);
    try environment.addBuiltinExportComptime(m, "SetLocalTime", stub_args1);
    try environment.addBuiltinExportComptime(m, "SetConsoleMode", kernel32_console.stub_ret_true_2);
    try environment.addBuiltinExportComptime(m, "GetVDMCurrentDirectories", stub_args2);
    try environment.addBuiltinExportComptime(m, "GetBinaryTypeW", stub_args2);
    try environment.addBuiltinExportComptime(m, "MoveFileExW", stub_args3);
    try environment.addBuiltinExportComptime(m, "SearchPathW", stub_args6);
    try environment.addBuiltinExportComptime(m, "GetVolumeInformationW", stub_args8);
    try environment.addBuiltinExportComptime(m, "GetConsoleTitleW", stub_args2);
    try environment.addBuiltinExportComptime(m, "GetDriveTypeW", kernel32_path.stub_GetDriveTypeW);
    try environment.addBuiltinExportComptime(m, "GetFileAttributesExW", stub_args3);
    try environment.addBuiltinExportComptime(m, "ScrollConsoleScreenBufferW", stub_args5);
    try environment.addBuiltinExportComptime(m, "SetConsoleTextAttribute", stub_args2);
    try environment.addBuiltinExportComptime(m, "FillConsoleOutputAttribute", stub_args5);
    try environment.addBuiltinExportComptime(m, "SetFileAttributesW", stub_args2);
    try environment.addBuiltinExportComptime(m, "CopyFileW", stub_args3);
    try environment.addBuiltinExportComptime(m, "RemoveDirectoryW", stub_args1);
    try environment.addBuiltinExportComptime(m, "RemoveDirectoryA", stub_args1);
    try environment.addBuiltinExportComptime(m, "CompareFileTime", kernel32_time.CompareFileTime);
    try environment.addBuiltinExportComptime(m, "GetConsoleOutputCP", kernel32_console.stub_GetConsoleOutputCP);
    try environment.addBuiltinExportComptime(m, "SetThreadLocale", kernel32_console.stub_ret_true_1);
    try environment.addBuiltinExportComptime(m, "CmdBatNotification", stub_args1);
    try environment.addBuiltinExportComptime(m, "MoveFileW", stub_args2);
    try environment.addBuiltinExportComptime(m, "GetDiskFreeSpaceExW", stub_args4);
    try environment.addBuiltinExportComptime(m, "GetTempPathW", kernel32_file.GetTempPathA);
    try environment.addBuiltinExportComptime(m, "GetTempFileNameW", stub_args4);
    try environment.addBuiltinExportComptime(m, "CreateMutexW", kernel32_sync.stub_CreateMutexA);
    try environment.addBuiltinExportComptime(m, "SetProcessShutdownParameters", kernel32_console.stub_ret_true_2);
    try environment.addBuiltinExportComptime(m, "GetPriorityClass", kernel32_process.stub_GetPriorityClass);
    try environment.addBuiltinExportComptime(m, "SetProcessAffinityMask", kernel32_console.stub_ret_true_2);
    try environment.addBuiltinExportComptime(m, "GetProcessAffinityMask", kernel32_sysinfo.GetProcessAffinityMask);
    try environment.addBuiltinExportComptime(m, "VerifyVersionInfoW", stub_args4);
    try environment.addBuiltinExportComptime(m, "GetPrivateProfileStringW", stub_args6);
    try environment.addBuiltinExportComptime(m, "DeleteAtom", stub_args1);
    try environment.addBuiltinExportComptime(m, "GlobalAddAtomW", stub_args1);
    try environment.addBuiltinExportComptime(m, "GlobalGetAtomNameW", stub_args3);
    try environment.addBuiltinExportComptime(m, "EnumDateFormatsW", stub_args3);
    try environment.addBuiltinExportComptime(m, "EnumTimeFormatsW", stub_args3);

    // --- Notepad2 KERNEL32 stubs ---
    try environment.addBuiltinExportComptime(m, "InterlockedCompareExchange", kernel32_sync.InterlockedCompareExchange);
    try environment.addBuiltinExportComptime(m, "FreeResource", stub_args1);
    try environment.addBuiltinExportComptime(m, "FindFirstChangeNotificationW", kernel32_sync.stub_FindFirstChangeNotificationW);
    try environment.addBuiltinExportComptime(m, "FindNextChangeNotification", kernel32_sync.stub_FindNextChangeNotification);
    try environment.addBuiltinExportComptime(m, "FindCloseChangeNotification", stub_args1);
    try environment.addBuiltinExportComptime(m, "GetLongPathNameW", kernel32_path.GetLongPathNameW);
    try environment.addBuiltinExportComptime(m, "GetPrivateProfileSectionW", stub_args4);
    try environment.addBuiltinExportComptime(m, "WritePrivateProfileSectionW", stub_args3);

    // --- hgb.exe KERNEL32 stubs ---
    try environment.addBuiltinExportComptime(m, "TerminateThread", stub_args2);
    try environment.addBuiltinExportComptime(m, "FileTimeToDosDateTime", stub_args3);

    // --- DxWrapper / MSVC CRT stubs ---
    try environment.addBuiltinExportComptime(m, "LoadLibraryExW", kernel32_process.LoadLibraryExW);
    try environment.addBuiltinExportComptime(m, "GetModuleHandleExW", kernel32_process.GetModuleHandleExW);
    try environment.addBuiltinExportComptime(m, "IsDebuggerPresent", kernel32_process.IsDebuggerPresent);
    try environment.addBuiltinExportComptime(m, "GetNativeSystemInfo", kernel32_sysinfo.GetNativeSystemInfo);
    try environment.addBuiltinExportComptime(m, "InitializeSListHead", kernel32_sync.InitializeSListHead);
    try environment.addBuiltinExportComptime(m, "InterlockedFlushSList", kernel32_sync.InterlockedFlushSList);
    try environment.addBuiltinExportComptime(m, "InitializeCriticalSectionEx", kernel32_sync.InitializeCriticalSectionEx);
    try environment.addBuiltinExportComptime(m, "InitializeCriticalSectionAndSpinCount", kernel32_sync.InitializeCriticalSectionAndSpinCount);
    try environment.addBuiltinExportComptime(m, "EncodePointer", kernel32_sync.EncodePointer);
    try environment.addBuiltinExportComptime(m, "DecodePointer", kernel32_sync.DecodePointer);
    try environment.addBuiltinExportComptime(m, "FlsAlloc", kernel32_sync.FlsAlloc);
    try environment.addBuiltinExportComptime(m, "FlsGetValue", kernel32_sync.FlsGetValue);
    try environment.addBuiltinExportComptime(m, "FlsSetValue", kernel32_sync.FlsSetValue);
    try environment.addBuiltinExportComptime(m, "FlsFree", kernel32_sync.FlsFree);
    try environment.addBuiltinExportComptime(m, "GetFileSizeEx", kernel32_file.GetFileSizeEx);
    try environment.addBuiltinExportComptime(m, "SetFilePointerEx", kernel32_file.SetFilePointerEx);
    try environment.addBuiltinExportComptime(m, "FindFirstFileExW", kernel32_file.FindFirstFileExW);
    try environment.addBuiltinExportComptime(m, "LCMapStringEx", kernel32_locale.LCMapStringEx);
    try environment.addBuiltinExportComptime(m, "EnumSystemLocalesW", kernel32_locale.EnumSystemLocalesW);

    // SRW locks (used by MinGW UCRT for thread-safe printf)
    try environment.addBuiltinExportComptime(m, "AcquireSRWLockExclusive", stub_args1);
    try environment.addBuiltinExportComptime(m, "ReleaseSRWLockExclusive", stub_args1);
    try environment.addBuiltinExportComptime(m, "AcquireSRWLockShared", stub_args1);
    try environment.addBuiltinExportComptime(m, "ReleaseSRWLockShared", stub_args1);
    try environment.addBuiltinExportComptime(m, "InitializeSRWLock", stub_args1);

    // Toolhelp (used by MinGW CRT startup for module enumeration)
    try environment.addBuiltinExportComptime(m, "CreateToolhelp32Snapshot", stub_args2);
    try environment.addBuiltinExportComptime(m, "Module32First", stub_args2);
    try environment.addBuiltinExportComptime(m, "Module32Next", stub_args2);
    try environment.addBuiltinExportComptime(m, "K32GetModuleFileNameExW", stub_args4);
    try environment.addBuiltinExportComptime(m, "RtlCaptureContext", stub_args1);
    try environment.addBuiltinExportComptime(m, "RtlCaptureStackBackTrace", stub_args4);

    // --- 7-Zip KERNEL32 stubs ---
    try environment.addBuiltinExportComptime(m, "OpenEventW", kernel32_sync.stub_CreateEventA);
    try environment.addBuiltinExportComptime(m, "OpenFileMappingW", stub_args3);
    try environment.addBuiltinExportComptime(m, "GetDiskFreeSpaceW", stub_args5);
    try environment.addBuiltinExportComptime(m, "GetLogicalDriveStringsW", stub_args2);
    try environment.addBuiltinExportComptime(m, "CreateSemaphoreW", kernel32_sync.stub_CreateSemaphoreA);
    try environment.addBuiltinExportComptime(m, "LocalFileTimeToFileTime", kernel32_time.FileTimeToLocalFileTime);
    try environment.addBuiltinExportComptime(m, "DosDateTimeToFileTime", stub_args3);
}

// Re-export generic stubs from stub_common for backward compatibility
const stub_common = @import("shared.zig");
pub const stub_args0 = stub_common.stub_args0;
pub const stub_args1 = stub_common.stub_args1;
pub const stub_args2 = stub_common.stub_args2;
pub const stub_args3 = stub_common.stub_args3;
pub const stub_args4 = stub_common.stub_args4;
pub const stub_args5 = stub_common.stub_args5;
pub const stub_args6 = stub_common.stub_args6;
pub const stub_args7 = stub_common.stub_args7;
pub const stub_args8 = stub_common.stub_args8;
pub const stub_args9 = stub_common.stub_args9;
pub const stub_args10 = stub_common.stub_args10;
