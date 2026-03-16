const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");

/// Retrieves the current input mode of a console's input buffer or the current
/// output mode of a console screen buffer.
/// Implementation status: Stub (returns a dummy mode).
pub fn GetConsoleMode(hConsoleHandle: usize, lpMode_ptr: usize) callconv(w32cc.WINAPI) i32 {
    _ = hConsoleHandle;
    if (lpMode_ptr != 0) {
        const lpMode = @as(*u32, @ptrFromInt(lpMode_ptr));
        lpMode.* = 0x0007; // ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT (dummy)
        return 1; // TRUE
    }
    return 0; // FALSE
}

/// Retrieves information about the specified console screen buffer.
/// Implementation status: Partially implemented (returns fixed 80x25 metrics).
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

/// Reads character input from the console input buffer and removes it from the buffer.
/// Implementation status: Partially implemented (reads from host stdin).
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

/// Writes a character string to a console screen buffer beginning at the current
/// cursor location.
/// Implementation status: Partially implemented (writes to host stdout/stderr).
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

/// Writes a character string to a console screen buffer beginning at the current
/// cursor location.
/// Implementation status: Partially implemented (writes to host stdout/stderr).
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

/// Retrieves the output code page used by the console associated with the
/// calling process.
/// Implementation status: Stub (returns 437).
pub fn stub_GetConsoleOutputCP() callconv(w32cc.WINAPI) u32 {
    return 437; // OEM United States
}

/// Dummy helper that always returns TRUE (1).
/// Implementation status: Stub.
pub fn stub_ret_true_1(a: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    return 1; // TRUE
}

/// Dummy helper that always returns TRUE (1).
/// Implementation status: Stub.
pub fn stub_ret_true_2(a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    return 1;
}
