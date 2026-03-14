const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn GetConsoleMode(hConsoleHandle: usize, lpMode_ptr: usize) callconv(w32cc.WINAPI) i32 {
    _ = hConsoleHandle;
    if (lpMode_ptr != 0) {
        const lpMode = @as(*u32, @ptrFromInt(lpMode_ptr));
        lpMode.* = 0x0007; // ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT (dummy)
        return 1; // TRUE
    }
    return 0; // FALSE
}

pub fn GetConsoleScreenBufferInfo(hConsoleOutput: usize, lpConsoleScreenBufferInfo: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn ReadConsoleW(hConsoleInput: usize, lpBuffer: usize, nNumberOfCharsToRead: u32, lpNumberOfCharsRead: usize, pInputControl: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn WriteConsoleW(hConsoleOutput: usize, lpBuffer_ptr: usize, nNumberOfCharsToWrite: u32, lpNumberOfCharsWritten_ptr: usize, lpReserved: usize) callconv(w32cc.WINAPI) i32 {
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

pub fn WriteConsoleA(hConsoleOutput: usize, lpBuffer: usize, nNumberOfCharsToWrite: u32, lpNumberOfCharsWritten: usize, lpReserved: usize) callconv(w32cc.WINAPI) i32 {
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

// GetConsoleOutputCP: returns console output code page
pub fn stub_GetConsoleOutputCP() callconv(w32cc.WINAPI) u32 {
    return 437; // OEM United States
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
