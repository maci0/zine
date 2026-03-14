const std = @import("std");
const trace = @import("../../trace.zig");
const kernel32 = @import("../kernel32.zig");
const kernel32_mem = @import("mem.zig");
const platform = @import("../../platform.zig");
const w32cc = @import("../../calling_convention.zig");

pub const EXCEPTION_RECORD = extern struct {
    ExceptionCode: u32,
    ExceptionFlags: u32,
    ExceptionRecord: u32, // pointer
    ExceptionAddress: u32, // pointer
    NumberParameters: u32,
    ExceptionInformation: [15]u32,
};

pub const CONTEXT = extern struct {
    ContextFlags: u32,
    Dr0: u32,
    Dr1: u32,
    Dr2: u32,
    Dr3: u32,
    Dr6: u32,
    Dr7: u32,
    FloatSave: [112]u8, // dummy
    SegGs: u32,
    SegFs: u32,
    SegEs: u32,
    SegDs: u32,
    Edi: u32,
    Esi: u32,
    Ebx: u32,
    Edx: u32,
    Ecx: u32,
    Eax: u32,
    Ebp: u32,
    Eip: u32,
    SegCs: u32,
    EFlags: u32,
    Esp: u32,
    SegSs: u32,
    ExtendedRegisters: [512]u8,
};

pub const EXCEPTION_REGISTRATION_RECORD = extern struct {
    Next: u32,
    Handler: u32,
};

pub fn stub_RaiseException(dwExceptionCode: u32, dwExceptionFlags: u32, nNumberOfArguments: u32, lpArguments: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) {
        trace.print("KERNEL32: RaiseException(code={x})\n", .{dwExceptionCode});
    }

    const exception_list: u32 = platform.readExceptionList();

    var rec = std.mem.zeroes(EXCEPTION_RECORD);
    rec.ExceptionCode = dwExceptionCode;
    rec.ExceptionFlags = dwExceptionFlags;
    rec.NumberParameters = nNumberOfArguments;
    if (nNumberOfArguments > 0 and lpArguments != 0) {
        const args = @as([*]u32, @ptrFromInt(lpArguments));
        const limit = @min(nNumberOfArguments, 15);
        for (0..limit) |i| {
            rec.ExceptionInformation[i] = args[i];
        }
    }

    var ctx = std.mem.zeroes(CONTEXT);
    ctx.ContextFlags = 0x1003f; // CONTEXT_ALL

    var current_node = exception_list;
    while (current_node != 0 and current_node != 0xFFFFFFFF) {
        if (trace.enable_tracing) trace.print("  SEH Node: {x}\n", .{current_node});
        const node = @as(*EXCEPTION_REGISTRATION_RECORD, @ptrFromInt(current_node));
        const handler = node.Handler;

        if (handler != 0) {
            if (trace.enable_tracing) trace.print("  Calling SEH Handler: {x}\n", .{handler});
            const HandlerFn = *const fn (record: *EXCEPTION_RECORD, establisherFrame: u32, contextRecord: *CONTEXT, dispatcherContext: u32) callconv(w32cc.WINAPI) u32; // SEH handlers use C calling convention

            const func = @as(HandlerFn, @ptrFromInt(handler));
            const disp = func(&rec, current_node, &ctx, 0);
            if (trace.enable_tracing) trace.print("  Handler returned: {d}\n", .{disp});

            if (disp == 0) { // ExceptionContinueExecution
                if (trace.enable_tracing) trace.print("  ExceptionContinueExecution requested!\n", .{});
                return;
            } else if (disp == 1) { // ExceptionContinueSearch
            } else {
                if (trace.enable_tracing) trace.print("  Unknown disposition or unwound natively.\n", .{});
            }
        }

        current_node = node.Next;
    }

    // If we get here, no SEH handler handled the exception.
    // Software exceptions (bit 29 set, e.g. 0xE0005031 from MSVC CRT longjmp)
    // are non-fatal control flow mechanisms.  Return gracefully instead of
    // crashing — the guest code may be able to continue.
    if (dwExceptionCode & 0x20000000 != 0) {
        if (trace.enable_tracing) trace.print("KERNEL32: RaiseException(code={x}) — software exception, returning\n", .{dwExceptionCode});
        return;
    }

    if (trace.enable_tracing) trace.print("KERNEL32: Unhandled exception! Terminating.\n", .{});
    platform.exitProcess(1);
}

pub fn stub_GetConsoleMode(hConsoleHandle: usize, lpMode_ptr: usize) callconv(w32cc.WINAPI) i32 {
    _ = hConsoleHandle;
    if (lpMode_ptr != 0) {
        const lpMode = @as(*u32, @ptrFromInt(lpMode_ptr));
        lpMode.* = 0x0007; // ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT (dummy)
        return 1; // TRUE
    }
    return 0; // FALSE
}

pub fn stub_GetConsoleScreenBufferInfo(hConsoleOutput: usize, lpConsoleScreenBufferInfo: usize) callconv(w32cc.WINAPI) i32 {
    _ = hConsoleOutput;
    if (trace.enable_tracing) trace.print("KERNEL32: GetConsoleScreenBufferInfo\n", .{});
    if (lpConsoleScreenBufferInfo != 0) {
        // CONSOLE_SCREEN_BUFFER_INFO: 11 WORDs (22 bytes)
        const info = @as(*[11]u16, @ptrFromInt(lpConsoleScreenBufferInfo));
        info[0] = 80; // dwSize.X (buffer width)
        info[1] = 300; // dwSize.Y (buffer height)
        info[2] = 0; // dwCursorPosition.X
        info[3] = 0; // dwCursorPosition.Y
        info[4] = 0x07; // wAttributes (light gray on black)
        info[5] = 0; // srWindow.Left
        info[6] = 0; // srWindow.Top
        info[7] = 79; // srWindow.Right
        info[8] = 24; // srWindow.Bottom
        info[9] = 80; // dwMaximumWindowSize.X
        info[10] = 25; // dwMaximumWindowSize.Y
        return 1;
    }
    return 0;
}

pub fn stub_ReadConsoleW(hConsoleInput: usize, lpBuffer: usize, nNumberOfCharsToRead: u32, lpNumberOfCharsRead: usize, pInputControl: usize) callconv(w32cc.WINAPI) i32 {
    _ = hConsoleInput;
    _ = pInputControl;
    if (trace.enable_tracing) trace.print("KERNEL32: ReadConsoleW(max={d})\n", .{nNumberOfCharsToRead});
    if (lpBuffer == 0 or nNumberOfCharsToRead == 0) return 0;

    // Read from host stdin (fd 0)
    const stdin = std.fs.File{ .handle = 0 };
    var narrow_buf: [4096]u8 = undefined;
    const max_read = @min(nNumberOfCharsToRead, narrow_buf.len);
    const bytes_read = stdin.read(narrow_buf[0..max_read]) catch return 0;
    if (bytes_read == 0) return 0;

    // Convert to wide chars
    const wide_buf = @as([*]u16, @ptrFromInt(lpBuffer));
    for (0..bytes_read) |i| {
        wide_buf[i] = narrow_buf[i];
    }

    if (lpNumberOfCharsRead != 0) {
        @as(*u32, @ptrFromInt(lpNumberOfCharsRead)).* = @intCast(bytes_read);
    }
    return 1;
}

pub fn stub_WriteConsoleW(hConsoleOutput: usize, lpBuffer_ptr: usize, nNumberOfCharsToWrite: u32, lpNumberOfCharsWritten_ptr: usize, lpReserved: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpReserved;
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hConsoleOutput))));
    if (lpBuffer_ptr != 0) {
        const buf_w = @as([*]const u16, @ptrFromInt(lpBuffer_ptr));
        var buf_a: [4096]u8 = undefined;
        const len = @min(nNumberOfCharsToWrite, buf_a.len);
        for (0..len) |i| {
            buf_a[i] = @intCast(buf_w[i] & 0xFF);
        }
        const file = std.fs.File{ .handle = fd };
        const written = file.write(buf_a[0..len]) catch return 0;
        if (lpNumberOfCharsWritten_ptr != 0) {
            @as(*u32, @ptrFromInt(lpNumberOfCharsWritten_ptr)).* = @intCast(written);
        }
        return 1; // TRUE
    }
    return 0; // FALSE
}

pub fn stub_WriteConsoleA(hConsoleOutput: usize, lpBuffer: usize, nNumberOfCharsToWrite: u32, lpNumberOfCharsWritten: usize, lpReserved: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpReserved;
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hConsoleOutput))));
    if (lpBuffer != 0) {
        const buf = @as([*]const u8, @ptrFromInt(lpBuffer))[0..nNumberOfCharsToWrite];
        const file = std.fs.File{ .handle = fd };
        const written = file.write(buf) catch return 0;
        if (lpNumberOfCharsWritten != 0) {
            @as(*u32, @ptrFromInt(lpNumberOfCharsWritten)).* = @intCast(written);
        }
        return 1;
    }
    return 0;
}

pub fn stub_SetFileApisToOEM() callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing) trace.print("KERNEL32: SetFileApisToOEM()\n", .{});
}

pub fn stub_GetSystemInfo(lpSystemInfo_ptr: usize) callconv(w32cc.WINAPI) void {
    if (lpSystemInfo_ptr != 0) {
        const lpSystemInfo = @as(*[9]u32, @ptrFromInt(lpSystemInfo_ptr));
        lpSystemInfo[0] = 0; // wProcessorArchitecture
        lpSystemInfo[1] = 4096; // dwPageSize
        lpSystemInfo[2] = 0x10000; // lpMinimumApplicationAddress
        lpSystemInfo[3] = 0x7FFEFFFF; // lpMaximumApplicationAddress
        lpSystemInfo[4] = 1; // dwActiveProcessorMask
        lpSystemInfo[5] = 1; // dwNumberOfProcessors
        lpSystemInfo[6] = 0; // dwProcessorType
        lpSystemInfo[7] = 65536; // dwAllocationGranularity
        lpSystemInfo[8] = 0; // wProcessorLevel
    }
}

pub fn stub_GetNativeSystemInfo(lpSystemInfo_ptr: usize) callconv(w32cc.WINAPI) void {
    // On x86, GetNativeSystemInfo returns the same as GetSystemInfo
    stub_GetSystemInfo(lpSystemInfo_ptr);
}

pub fn stub_SetErrorMode(uMode: u32) callconv(w32cc.WINAPI) u32 {
    _ = uMode;
    return 0; // Return old mode
}

pub var current_directory: [1024]u8 = undefined;
pub var current_directory_len: usize = 0;

pub fn stub_GetCurrentDirectoryA(nBufferLength: u32, lpBuffer: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCurrentDirectoryA(len={d})\n", .{nBufferLength});
    if (current_directory_len == 0) {
        const cwd = "C:\\";
        @memcpy(current_directory[0..cwd.len], cwd);
        current_directory_len = cwd.len;
    }

    if (lpBuffer != 0 and nBufferLength > current_directory_len) {
        const buf = @as([*]u8, @ptrFromInt(lpBuffer));
        @memcpy(buf[0..current_directory_len], current_directory[0..current_directory_len]);
        buf[current_directory_len] = 0;
        return @intCast(current_directory_len);
    }
    return @intCast(current_directory_len + 1);
}

pub fn stub_GetCurrentDirectoryW(nBufferLength: u32, lpBuffer: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetCurrentDirectoryW(len={d})\n", .{nBufferLength});
    if (current_directory_len == 0) {
        const cwd = "C:\\";
        @memcpy(current_directory[0..cwd.len], cwd);
        current_directory_len = cwd.len;
    }
    if (lpBuffer != 0 and nBufferLength > current_directory_len) {
        const buf = @as([*]u16, @ptrFromInt(lpBuffer));
        for (0..current_directory_len) |i| {
            buf[i] = current_directory[i];
        }
        buf[current_directory_len] = 0;
        return @intCast(current_directory_len);
    }
    return @intCast(current_directory_len + 1);
}

pub fn stub_SetCurrentDirectoryA(lpPathName: usize) callconv(w32cc.WINAPI) i32 {
    if (lpPathName == 0) return 0;
    const path = trace.c_span(lpPathName);
    if (trace.enable_tracing) trace.print("KERNEL32: SetCurrentDirectoryA('{s}')\n", .{path});

    const copy_len = @min(path.len, 1023);
    @memcpy(current_directory[0..copy_len], path[0..copy_len]);
    current_directory_len = copy_len;
    current_directory[current_directory_len] = 0;
    return 1;
}

pub fn stub_GetWindowsDirectoryA(lpBuffer: usize, uSize: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetWindowsDirectoryA(buffer={x}, size={d})\n", .{ lpBuffer, uSize });
    const win_dir = "C:\\WINDOWS";
    if (lpBuffer != 0 and uSize > win_dir.len) {
        const buf = @as([*]u8, @ptrFromInt(lpBuffer));
        @memcpy(buf[0..win_dir.len], win_dir);
        buf[win_dir.len] = 0;
        return @intCast(win_dir.len);
    }
    return @intCast(win_dir.len + 1);
}

pub fn stub_MulDiv(nNumber: i32, nNumerator: i32, nDenominator: i32) callconv(w32cc.WINAPI) i32 {
    if (nDenominator == 0) return -1;
    const result = @divTrunc(@as(i64, nNumber) * @as(i64, nNumerator), @as(i64, nDenominator));
    if (result > 0x7FFFFFFF or result < -0x80000000) return -1;
    return @intCast(result);
}

pub fn stub_HeapSize(hHeap: usize, dwFlags: u32, lpMem: usize) callconv(w32cc.WINAPI) usize {
    _ = hHeap;
    _ = dwFlags;
    if (lpMem == 0) return 0;
    // raw_alloc layout: [usize size header][user data] -- header is at ptr-8
    const header = @as(*const usize, @ptrFromInt(lpMem - 8));
    return header.*;
}

pub fn stub_HeapValidate(hHeap: usize, dwFlags: u32, lpMem: usize) callconv(w32cc.WINAPI) i32 {
    _ = hHeap;
    _ = dwFlags;
    _ = lpMem;
    return 1; // TRUE = valid
}

pub fn stub_Beep(dwFreq: u32, dwDuration: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwFreq;
    _ = dwDuration;
    return 1;
}

// --- Error handling ---

pub var last_error: u32 = 0;

pub fn stub_SetLastError(dwErrCode: u32) callconv(w32cc.WINAPI) void {
    last_error = dwErrCode;
}

pub var unhandled_exception_filter: usize = 0;

pub fn stub_SetUnhandledExceptionFilter(lpTopLevelExceptionFilter: usize) callconv(w32cc.WINAPI) usize {
    const prev = unhandled_exception_filter;
    unhandled_exception_filter = lpTopLevelExceptionFilter;
    return prev;
}

pub fn stub_OutputDebugStringA(lpOutputString: usize) callconv(w32cc.WINAPI) void {
    if (trace.enable_tracing and lpOutputString != 0) {
        const s = trace.c_span(lpOutputString);
        trace.print("KERNEL32: OutputDebugStringA('{s}')\n", .{s});
    }
}

pub fn stub_GetFullPathNameA(lpFileName: usize, nBufferLength: u32, lpBuffer: usize, lpFilePart: usize) callconv(w32cc.WINAPI) u32 {
    if (lpFileName == 0) return 0;
    const name = trace.c_span(lpFileName);
    if (trace.enable_tracing) trace.print("KERNEL32: GetFullPathNameA('{s}')\n", .{name});
    if (lpBuffer != 0 and nBufferLength > name.len) {
        const buf = @as([*]u8, @ptrFromInt(lpBuffer));
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        if (lpFilePart != 0) {
            var last_sep: usize = 0;
            for (0..name.len) |i| {
                if (name[i] == '\\' or name[i] == '/') last_sep = i + 1;
            }
            @as(*usize, @ptrFromInt(lpFilePart)).* = lpBuffer + last_sep;
        }
        return @intCast(name.len);
    }
    return @intCast(name.len + 1);
}

pub fn stub_CreateDirectoryA(lpPathName: usize, lpSecurityAttributes: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpSecurityAttributes;
    if (lpPathName == 0) return 0;
    const path = trace.c_span(lpPathName);
    if (trace.enable_tracing) trace.print("KERNEL32: CreateDirectoryA('{s}')\n", .{path});
    var fixed: [1024]u8 = undefined;
    const len = @min(path.len, 1023);
    @memcpy(fixed[0..len], path[0..len]);
    std.mem.replaceScalar(u8, fixed[0..len], '\\', '/');
    fixed[len] = 0;
    std.fs.cwd().makeDir(fixed[0..len]) catch return 0;
    return 1;
}

pub fn stub_IsProcessorFeaturePresent(ProcessorFeature: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("KERNEL32: IsProcessorFeaturePresent({d})\n", .{ProcessorFeature});
    // PF_FLOATING_POINT_EMULATED=1 -> FALSE (we have real FP)
    // PF_MMX_INSTRUCTIONS_AVAILABLE=3 -> TRUE
    // PF_XMMI_INSTRUCTIONS_AVAILABLE=6 (SSE) -> TRUE
    return switch (ProcessorFeature) {
        1 => 0, // Not emulated
        3 => 1, // MMX available
        6 => 1, // SSE available
        else => 0,
    };
}

pub fn stub_IsBadReadPtr(lp: usize, ucb: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucb;
    return if (lp == 0) 1 else 0; // Only NULL is "bad"
}

pub fn stub_IsBadWritePtr(lp: usize, ucb: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucb;
    return if (lp == 0) 1 else 0;
}

pub fn stub_IsBadCodePtr(lpfn: usize) callconv(w32cc.WINAPI) i32 {
    return if (lpfn == 0) 1 else 0;
}

pub fn stub_IsBadStringPtrA(lpsz: usize, ucchMax: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucchMax;
    return if (lpsz == 0) 1 else 0;
}

pub fn stub_IsBadStringPtrW(lpsz: usize, ucchMax: usize) callconv(w32cc.WINAPI) i32 {
    _ = ucchMax;
    return if (lpsz == 0) 1 else 0;
}

// --- INI file support ---

fn readIniValue(lpFileName: usize, lpAppName: usize, lpKeyName: usize) ?[]const u8 {
    if (lpFileName == 0 or lpAppName == 0 or lpKeyName == 0) return null;

    const file_path_raw = trace.c_span(lpFileName);
    const section_name = trace.c_span(lpAppName);
    const key_name = trace.c_span(lpKeyName);

    // Convert Windows path to POSIX using canonical mapping
    const path_utils = @import("../../path_utils.zig");
    var path_buf: [1024]u8 = undefined;
    const path_len = path_utils.win32ToPosix(file_path_raw, &path_buf);
    const path = path_buf[0..path_len];

    // Try to open the file
    const file = blk: {
        if (std.fs.path.isAbsolute(path)) {
            break :blk std.fs.openFileAbsolute(path, .{}) catch {
                // Try lowercase filename
                var lower_buf: [1024]u8 = undefined;
                var last_slash: usize = 0;
                @memcpy(lower_buf[0..path_len], path);
                for (0..path_len) |i| {
                    if (lower_buf[i] == '/') last_slash = i + 1;
                }
                for (last_slash..path_len) |i| {
                    lower_buf[i] = std.ascii.toLower(lower_buf[i]);
                }
                break :blk std.fs.openFileAbsolute(lower_buf[0..path_len], .{}) catch return null;
            };
        } else {
            break :blk std.fs.cwd().openFile(path, .{}) catch {
                var lower_buf: [1024]u8 = undefined;
                var last_slash: usize = 0;
                @memcpy(lower_buf[0..path_len], path);
                for (0..path_len) |i| {
                    if (lower_buf[i] == '/') last_slash = i + 1;
                }
                for (last_slash..path_len) |i| {
                    lower_buf[i] = std.ascii.toLower(lower_buf[i]);
                }
                break :blk std.fs.cwd().openFile(lower_buf[0..path_len], .{}) catch return null;
            };
        }
    };
    defer file.close();

    // Read the file (up to 16KB)
    var content_buf: [16384]u8 = undefined;
    const bytes_read = file.readAll(&content_buf) catch return null;
    const content = content_buf[0..bytes_read];

    // Parse INI: find [section] then key=value
    var in_section = false;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        // Trim \r and whitespace
        var line = std.mem.trimRight(u8, raw_line, "\r \t");
        line = std.mem.trimLeft(u8, line, " \t");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            // Section header
            if (std.mem.indexOfScalar(u8, line, ']')) |end| {
                const sec = line[1..end];
                in_section = std.ascii.eqlIgnoreCase(sec, section_name);
            }
            continue;
        }

        if (in_section) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const k = std.mem.trimRight(u8, line[0..eq], " \t");
                if (std.ascii.eqlIgnoreCase(k, key_name)) {
                    return std.mem.trimLeft(u8, line[eq + 1 ..], " \t");
                }
            }
        }
    }
    return null;
}

pub fn stub_GetPrivateProfileStringA(lpAppName: usize, lpKeyName: usize, lpDefault: usize, lpReturnedString: usize, nSize: u32, lpFileName: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        const app = if (lpAppName != 0) trace.c_span(lpAppName) else "(null)";
        const key = if (lpKeyName != 0) trace.c_span(lpKeyName) else "(null)";
        const fname = if (lpFileName != 0) trace.c_span(lpFileName) else "(null)";
        trace.print("KERNEL32: GetPrivateProfileStringA('{s}', '{s}', file='{s}')\n", .{ app, key, fname });
    }
    if (lpReturnedString == 0 or nSize == 0) return 0;
    const buf = @as([*]u8, @ptrFromInt(lpReturnedString));

    // Try to read actual value from INI file
    if (readIniValue(lpFileName, lpAppName, lpKeyName)) |value| {
        const copy_len = @min(value.len, @as(usize, nSize) - 1);
        @memcpy(buf[0..copy_len], value[0..copy_len]);
        buf[copy_len] = 0;
        if (trace.enable_tracing) trace.print("  -> '{s}'\n", .{buf[0..copy_len]});
        return @intCast(copy_len);
    }

    // Fall back to default
    if (lpDefault != 0) {
        const def = trace.c_span(lpDefault);
        const copy_len = @min(def.len, @as(usize, nSize) - 1);
        @memcpy(buf[0..copy_len], def[0..copy_len]);
        buf[copy_len] = 0;
        return @intCast(copy_len);
    }
    buf[0] = 0;
    return 0;
}

pub fn stub_GetPrivateProfileIntA(lpAppName: usize, lpKeyName: usize, nDefault: i32, lpFileName: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        const app = if (lpAppName != 0) trace.c_span(lpAppName) else "(null)";
        const key = if (lpKeyName != 0) trace.c_span(lpKeyName) else "(null)";
        trace.print("KERNEL32: GetPrivateProfileIntA('{s}', '{s}', default={d})\n", .{ app, key, nDefault });
    }
    if (readIniValue(lpFileName, lpAppName, lpKeyName)) |value| {
        const result = std.fmt.parseInt(i32, value, 10) catch return @bitCast(nDefault);
        if (trace.enable_tracing) trace.print("  -> {d}\n", .{result});
        return @bitCast(result);
    }
    return @bitCast(nDefault);
}

pub fn stub_WritePrivateProfileStringA(lpAppName: usize, lpKeyName: usize, lpString: usize, lpFileName: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpAppName;
    _ = lpKeyName;
    _ = lpString;
    _ = lpFileName;
    return 1; // Success
}

pub fn stub_WritePrivateProfileStringW(lpAppName: usize, lpKeyName: usize, lpString: usize, lpFileName: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpAppName;
    _ = lpKeyName;
    _ = lpString;
    _ = lpFileName;
    if (trace.enable_tracing) trace.print("KERNEL32: WritePrivateProfileStringW\n", .{});
    return 1; // Success
}

fn wideToNarrow(wide_ptr: usize, buf: []u8) []const u8 {
    if (wide_ptr == 0) return "";
    const wide = @as([*]const u16, @ptrFromInt(wide_ptr));
    var i: usize = 0;
    while (i < buf.len - 1 and wide[i] != 0) : (i += 1) {
        buf[i] = @intCast(wide[i] & 0xFF);
    }
    buf[i] = 0;
    return buf[0..i];
}

pub fn stub_GetPrivateProfileStringW(lpAppName: usize, lpKeyName: usize, lpDefault: usize, lpReturnedString: usize, nSize: u32, lpFileName: usize) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) {
        var app_buf: [256]u8 = undefined;
        var key_buf: [256]u8 = undefined;
        const app = wideToNarrow(lpAppName, &app_buf);
        const key = wideToNarrow(lpKeyName, &key_buf);
        trace.print("KERNEL32: GetPrivateProfileStringW('{s}', '{s}')\n", .{ app, key });
    }
    if (lpReturnedString == 0 or nSize == 0) return 0;

    const out = @as([*]u16, @ptrFromInt(lpReturnedString));

    // Try to read from INI file using narrow conversion
    var app_buf: [256]u8 = undefined;
    var key_buf: [256]u8 = undefined;
    var fname_buf: [512]u8 = undefined;
    _ = wideToNarrow(lpAppName, &app_buf);
    _ = wideToNarrow(lpKeyName, &key_buf);
    _ = wideToNarrow(lpFileName, &fname_buf);

    // Use narrow INI reader
    var narrow_result: [1024]u8 = undefined;
    const a_result = stub_GetPrivateProfileStringA(
        @intFromPtr(&app_buf),
        @intFromPtr(&key_buf),
        0, // no default for A version, handle W default below
        @intFromPtr(&narrow_result),
        @min(nSize, 1024),
        @intFromPtr(&fname_buf),
    );

    if (a_result > 0) {
        const len = @min(@as(usize, a_result), @as(usize, nSize) - 1);
        for (0..len) |i| out[i] = narrow_result[i];
        out[len] = 0;
        return @intCast(len);
    }

    // Fall back to wide default
    if (lpDefault != 0) {
        const def = @as([*]const u16, @ptrFromInt(lpDefault));
        var i: usize = 0;
        while (i < nSize - 1 and def[i] != 0) : (i += 1) {
            out[i] = def[i];
        }
        out[i] = 0;
        return @intCast(i);
    }

    out[0] = 0;
    return 0;
}

pub fn stub_FatalAppExitA(uAction: u32, lpMessageText: usize) callconv(w32cc.WINAPI) void {
    _ = uAction;
    if (lpMessageText != 0) {
        const msg = trace.c_span(lpMessageText);
        trace.print("KERNEL32: FatalAppExitA: {s}\n", .{msg});
    }
    platform.exitProcess(1);
}

pub fn stub_GetDriveTypeA(lpRootPathName: usize) callconv(w32cc.WINAPI) u32 {
    _ = lpRootPathName;
    return 3; // DRIVE_FIXED
}

pub fn stub_FindResourceA(hModule: usize, lpName: usize, lpType: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) {
        const name_s = if (lpName > 0xFFFF) trace.c_span(lpName) else "INTRESOURCE";
        const type_s = if (lpType > 0xFFFF) trace.c_span(lpType) else "INTRESOURCE";
        trace.print("KERNEL32: FindResourceA(hMod={x}, name={s}({x}), type={s}({x}))\n", .{ hModule, name_s, lpName, type_s, lpType });
    }
    return findResourceImpl(hModule, lpName, lpType);
}

pub fn stub_FindResourceW(hModule: usize, lpName: usize, lpType: usize) callconv(w32cc.WINAPI) usize {
    if (trace.enable_tracing) {
        trace.print("KERNEL32: FindResourceW(hMod={x}, name={x}, type={x})\n", .{ hModule, lpName, lpType });
    }
    return findResourceImpl(hModule, lpName, lpType);
}

fn findResourceImpl(hModule: usize, lpName: usize, lpType: usize) usize {
    // Only support MAKEINTRESOURCE (integer IDs <= 0xFFFF) for now
    if (lpType > 0xFFFF or lpName > 0xFFFF) return 0;

    const resource_type: u32 = @intCast(lpType & 0xFFFF);
    const resource_id: u32 = @intCast(lpName & 0xFFFF);

    // Find the module to get its resource data
    if (kernel32.global_env) |genv| {
        var mod_handle = hModule;
        if (mod_handle == 0) mod_handle = kernel32.main_module_handle;

        var it = genv.registry.modules.valueIterator();
        while (it.next()) |m| {
            if (@intFromPtr(m.*.mapped_memory.ptr) == mod_handle) {
                if (m.*.getResource(resource_type, resource_id)) |data| {
                    if (trace.enable_tracing) trace.print("KERNEL32: FindResource -> {x} (size={d})\n", .{ @intFromPtr(data.ptr), data.len });
                    return @intFromPtr(data.ptr);
                }
                break;
            }
        }
    }
    if (trace.enable_tracing) trace.print("KERNEL32: FindResource -> 0 (not found)\n", .{});
    return 0;
}

pub fn stub_LoadResource(hModule: usize, hResInfo: usize) callconv(w32cc.WINAPI) usize {
    _ = hModule;
    // In Win32, LoadResource just returns the HGLOBAL handle.
    // Since our FindResource already returns a direct pointer to the data, just pass it through.
    return hResInfo;
}

pub fn stub_SizeofResource(hModule: usize, hResInfo: usize) callconv(w32cc.WINAPI) u32 {
    _ = hModule;
    // We need to find the size. Since FindResource returned the data pointer,
    // we need to look up the resource again. For now, return 0 — most apps
    // don't need SizeofResource if they know the format.
    _ = hResInfo;
    return 0;
}

pub fn stub_LockResource(hResData: usize) callconv(w32cc.WINAPI) usize {
    // In Win32, LockResource just returns the pointer.
    return hResData;
}

pub fn stub_GetModuleFileNameA(hModule: usize, lpFilename: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("KERNEL32: GetModuleFileNameA(hModule={x})\n", .{hModule});
    if (lpFilename == 0 or nSize == 0) return 0;
    const buf = @as([*]u8, @ptrFromInt(lpFilename));

    // For the main module (hModule == 0 or matches main_module_handle), return real exe path
    if (hModule == 0 or hModule == kernel32.main_module_handle) {
        // Use actual exe name from argv[0] if available
        const process_mod = @import("process.zig");
        const result = process_mod.stub_GetModuleFileNameA(hModule, lpFilename, nSize);
        if (result > 0) return result;

        // Fallback to exe dir + generic name
        const dir = kernel32.main_exe_dir[0..kernel32.main_exe_dir_len];
        const exe_name = "program.exe";
        const total = dir.len + exe_name.len;
        if (total < nSize) {
            @memcpy(buf[0..dir.len], dir);
            @memcpy(buf[dir.len..total], exe_name);
            buf[total] = 0;
            return @intCast(total);
        }
    }

    // Fallback: try to find module name from registry
    if (kernel32.global_env) |genv| {
        var it = genv.registry.modules.valueIterator();
        while (it.next()) |m| {
            if (@intFromPtr(m.*.mapped_memory.ptr) == hModule) {
                const dir = kernel32.main_exe_dir[0..kernel32.main_exe_dir_len];
                const mname = m.*.name;
                const total = dir.len + mname.len;
                if (total < nSize) {
                    @memcpy(buf[0..dir.len], dir);
                    @memcpy(buf[dir.len..total], mname);
                    buf[total] = 0;
                    return @intCast(total);
                }
            }
        }
    }

    // Last resort fallback: use main_exe_dir if available
    if (kernel32.main_exe_dir_len > 0) {
        const dir = kernel32.main_exe_dir[0..kernel32.main_exe_dir_len];
        const exe_name = "program.exe";
        const total = dir.len + exe_name.len;
        if (total < nSize) {
            @memcpy(buf[0..dir.len], dir);
            @memcpy(buf[dir.len..total], exe_name);
            buf[total] = 0;
            return @intCast(total);
        }
    }
    const name = "C:\\program.exe";
    const copy_len = @min(name.len, @as(usize, nSize) - 1);
    @memcpy(buf[0..copy_len], name[0..copy_len]);
    buf[copy_len] = 0;
    return @intCast(copy_len);
}

pub fn stub_OpenFile(lpFileName: usize, lpReOpenBuff: usize, uStyle: u32) callconv(w32cc.WINAPI) i32 {
    _ = lpReOpenBuff;
    _ = uStyle;
    if (trace.enable_tracing) {
        const name = if (lpFileName != 0) trace.c_span(lpFileName) else "(null)";
        trace.print("KERNEL32: OpenFile('{s}')\n", .{name});
    }
    return -1; // HFILE_ERROR
}

pub fn stub_GetProfileStringA(lpAppName: usize, lpKeyName: usize, lpDefault: usize, lpReturnedString: usize, nSize: u32) callconv(w32cc.WINAPI) u32 {
    if (lpReturnedString == 0 or nSize == 0) return 0;
    const buf = @as([*]u8, @ptrFromInt(lpReturnedString));
    if (lpDefault != 0) {
        const def = trace.c_span(lpDefault);
        const copy_len = @min(def.len, @as(usize, nSize) - 1);
        @memcpy(buf[0..copy_len], def[0..copy_len]);
        buf[copy_len] = 0;
        if (trace.enable_tracing) {
            const app = if (lpAppName != 0) trace.c_span(lpAppName) else "(null)";
            const key = if (lpKeyName != 0) trace.c_span(lpKeyName) else "(null)";
            trace.print("KERNEL32: GetProfileStringA('{s}', '{s}') -> default\n", .{ app, key });
        }
        return @intCast(copy_len);
    }
    buf[0] = 0;
    return 0;
}

// --- Return TRUE helpers (for functions that must succeed) ---
pub fn stub_ret_true_1(a: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    return 1; // TRUE
}

pub fn stub_ret_true_2(a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    return 1;
}

// GetDriveTypeW: returns drive type for a root path
// DRIVE_FIXED = 3 (typical for hard drives)
pub fn stub_GetDriveTypeW(lpRootPathName: usize) callconv(w32cc.WINAPI) u32 {
    _ = lpRootPathName;
    return 3; // DRIVE_FIXED
}

// GetConsoleOutputCP: returns console output code page
pub fn stub_GetConsoleOutputCP() callconv(w32cc.WINAPI) u32 {
    return 437; // OEM United States
}

// GetLongPathNameW: just copies the input to the output (identity mapping)
pub fn stub_GetLongPathNameW(lpszShortPath: usize, lpszLongPath: usize, cchBuffer: u32) callconv(w32cc.WINAPI) u32 {
    if (lpszShortPath == 0) return 0;
    const src = @as([*]const u16, @ptrFromInt(lpszShortPath));
    var len: usize = 0;
    while (len < 4096 and src[len] != 0) len += 1;
    if (lpszLongPath != 0 and cchBuffer > len) {
        const dst = @as([*]u16, @ptrFromInt(lpszLongPath));
        for (0..len) |i| dst[i] = src[i];
        dst[len] = 0;
    }
    return @intCast(len);
}

// SetCurrentDirectoryW: properly handle wide string paths
pub fn stub_SetCurrentDirectoryW(lpPathName: usize) callconv(w32cc.WINAPI) i32 {
    if (lpPathName == 0) return 0;
    const wstr = @as([*]const u16, @ptrFromInt(lpPathName));
    // Convert wide to narrow
    var narrow: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < 1023 and wstr[i] != 0) : (i += 1) {
        narrow[i] = @intCast(wstr[i] & 0xFF);
    }
    narrow[i] = 0;
    if (trace.enable_tracing) trace.print("KERNEL32: SetCurrentDirectoryW('{s}')\n", .{narrow[0..i]});
    @memcpy(current_directory[0..i], narrow[0..i]);
    current_directory_len = i;
    current_directory[i] = 0;
    return 1;
}

pub fn stub_SleepEx(dwMilliseconds: u32, bAlertable: i32) callconv(w32cc.WINAPI) u32 {
    _ = bAlertable;
    if (dwMilliseconds > 0) {
        const sleep_ns: u64 = @min(@as(u64, dwMilliseconds) * 1_000_000, 100_000_000); // Cap at 100ms
        std.Thread.sleep(sleep_ns);
    }
    return 0; // The return value is 0 if the specified time interval expired.
}

pub fn stub_GlobalMemoryStatusEx(lpBuffer: usize) callconv(w32cc.WINAPI) i32 {
    if (lpBuffer == 0) return 0;
    // MEMORYSTATUSEX: first field is dwLength (u32), then various 64-bit fields
    // dwLength, dwMemoryLoad, ullTotalPhys, ullAvailPhys, ullTotalPageFile,
    // ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual
    const buf = @as([*]u8, @ptrFromInt(lpBuffer));
    // Zero out the structure (64 bytes)
    @memset(buf[0..64], 0);
    // dwLength = 64
    @as(*align(1) u32, @ptrFromInt(lpBuffer)).* = 64;
    // dwMemoryLoad = 50 (50% used)
    @as(*align(1) u32, @ptrFromInt(lpBuffer + 4)).* = 50;
    // ullTotalPhys = 2GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 8)).* = 2 * 1024 * 1024 * 1024;
    // ullAvailPhys = 1GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 16)).* = 1 * 1024 * 1024 * 1024;
    // ullTotalPageFile = 4GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 24)).* = 4 * 1024 * 1024 * 1024;
    // ullAvailPageFile = 3GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 32)).* = 3 * 1024 * 1024 * 1024;
    // ullTotalVirtual = 2GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 40)).* = 2 * 1024 * 1024 * 1024;
    // ullAvailVirtual = 1.5GB
    @as(*align(1) u64, @ptrFromInt(lpBuffer + 48)).* = 1536 * 1024 * 1024;
    return 1; // TRUE
}
