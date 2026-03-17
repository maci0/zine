const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");
const host_io = @import("../host_io.zig");

/// Retrieves the current input mode of a console's input buffer.
pub fn GetConsoleMode(hConsoleHandle: usize, lpMode: *u32) callconv(w32cc.WINAPI) i32 {
    _ = hConsoleHandle;
    lpMode.* = 0x0007; // ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT
    return 1;
}

/// Retrieves information about the specified console screen buffer.
pub fn GetConsoleScreenBufferInfo(hConsoleOutput: usize, info: *[11]u16) callconv(w32cc.WINAPI) i32 {
    _ = hConsoleOutput;
    if (trace.enable_tracing) trace.print("KERNEL32: GetConsoleScreenBufferInfo\n", .{});
    info[0] = 80; // dwSize.X
    info[1] = 300; // dwSize.Y
    info[2] = 0; // dwCursorPosition.X
    info[3] = 0; // dwCursorPosition.Y
    info[4] = 0x07; // wAttributes
    info[5] = 0; // srWindow.Left
    info[6] = 0; // srWindow.Top
    info[7] = 79; // srWindow.Right
    info[8] = 24; // srWindow.Bottom
    info[9] = 80; // dwMaximumWindowSize.X
    info[10] = 25; // dwMaximumWindowSize.Y
    return 1;
}

/// Reads character input from the console input buffer.
pub fn ReadConsoleW(hConsoleInput: usize, lpBuffer: [*]u16, nNumberOfCharsToRead: u32, lpNumberOfCharsRead: ?*u32, pInputControl: usize) callconv(w32cc.WINAPI) i32 {
    _ = hConsoleInput;
    _ = pInputControl;
    if (trace.enable_tracing) trace.print("KERNEL32: ReadConsoleW(max={d})\n", .{nNumberOfCharsToRead});
    if (nNumberOfCharsToRead == 0) return 0;

    const stdin = host_io.fileFromFd(0);
    var narrow_buf: [4096]u8 = undefined;
    const max_read = @min(nNumberOfCharsToRead, narrow_buf.len);
    const bytes_read = stdin.read(narrow_buf[0..max_read]) catch return 0;
    if (bytes_read == 0) return 0;

    for (0..bytes_read) |i| {
        lpBuffer[i] = narrow_buf[i];
    }
    if (lpNumberOfCharsRead) |p| p.* = @intCast(bytes_read);
    return 1;
}

/// Writes a wide character string to a console screen buffer.
pub fn WriteConsoleW(hConsoleOutput: usize, lpBuffer: [*]const u16, nNumberOfCharsToWrite: u32, lpNumberOfCharsWritten: ?*u32, lpReserved: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpReserved;
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hConsoleOutput))));
    var buf_a: [4096]u8 = undefined;
    const len = @min(nNumberOfCharsToWrite, buf_a.len);
    for (0..len) |i| {
        buf_a[i] = @intCast(lpBuffer[i] & 0xFF);
    }
    const file = host_io.fileFromFd(fd);
    const written = file.write(buf_a[0..len]) catch return 0;
    if (lpNumberOfCharsWritten) |p| p.* = @intCast(written);
    return 1;
}

/// Writes a narrow character string to a console screen buffer.
pub fn WriteConsoleA(hConsoleOutput: usize, lpBuffer: [*]const u8, nNumberOfCharsToWrite: u32, lpNumberOfCharsWritten: ?*u32, lpReserved: usize) callconv(w32cc.WINAPI) i32 {
    _ = lpReserved;
    const fd = @as(i32, @bitCast(@as(u32, @truncate(hConsoleOutput))));
    const buf = lpBuffer[0..nNumberOfCharsToWrite];
    const file = host_io.fileFromFd(fd);
    const written = file.write(buf) catch return 0;
    if (lpNumberOfCharsWritten) |p| p.* = @intCast(written);
    return 1;
}

/// Retrieves the output code page used by the console.
pub fn stub_GetConsoleOutputCP() callconv(w32cc.WINAPI) u32 {
    return 437;
}

/// Dummy helper that always returns TRUE (1).
pub fn stub_ret_true_1(a: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    return 1;
}

/// Dummy helper that always returns TRUE (1).
pub fn stub_ret_true_2(a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    return 1;
}
