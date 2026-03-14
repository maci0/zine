const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../../calling_convention.zig");

pub fn CharNextA(lpsz: [*:0]const u8) callconv(w32cc.WINAPI) [*:0]const u8 {
    if (lpsz[0] == 0) return lpsz;
    return lpsz + 1;
}

pub fn CharPrevA(lpszStart: usize, lpszCurrent: usize) callconv(w32cc.WINAPI) usize {
    _ = lpszStart;
    if (lpszCurrent > 0) return lpszCurrent - 1;
    return 0;
}

pub fn CharToOemA(lpszSrc: usize, lpszDst: usize) callconv(w32cc.WINAPI) i32 {
    if (lpszSrc == 0 or lpszDst == 0) return 0;
    if (lpszSrc != lpszDst) {
        const src = trace.c_span(lpszSrc);
        const dst = @as([*]u8, @ptrFromInt(lpszDst));
        @memcpy(dst[0..src.len], src);
        dst[src.len] = 0;
    }
    return 1;
}

// Identity copy — we don't distinguish ANSI and OEM codepages.
pub fn OemToCharA(lpszSrc: usize, lpszDst: usize) callconv(w32cc.WINAPI) i32 {
    return CharToOemA(lpszSrc, lpszDst);
}

pub fn CharLowerA(lpsz: usize) callconv(w32cc.WINAPI) usize {
    if (lpsz > 0xFFFF) {
        const span = trace.c_span(lpsz);
        const buf = @as([*]u8, @ptrFromInt(lpsz));
        for (0..span.len) |i| {
            if (buf[i] >= 'A' and buf[i] <= 'Z') {
                buf[i] = buf[i] + 32;
            }
        }
    }
    return lpsz;
}

pub fn CharUpperW(lpsz: usize) callconv(w32cc.WINAPI) usize {
    if (lpsz <= 0xFFFF) {
        // Single character — convert and return
        const ch: u16 = @truncate(lpsz);
        if (ch >= 'a' and ch <= 'z') return lpsz - 32;
        return lpsz;
    }
    // In-place string conversion
    const ptr = @as([*]u16, @ptrFromInt(lpsz));
    var i: usize = 0;
    while (ptr[i] != 0) : (i += 1) {
        if (ptr[i] >= 'a' and ptr[i] <= 'z') ptr[i] -= 32;
    }
    return lpsz;
}

pub fn CharLowerW(lpsz: usize) callconv(w32cc.WINAPI) usize {
    if (lpsz <= 0xFFFF) {
        const ch: u16 = @truncate(lpsz);
        if (ch >= 'A' and ch <= 'Z') return lpsz + 32;
        return lpsz;
    }
    const ptr = @as([*]u16, @ptrFromInt(lpsz));
    var i: usize = 0;
    while (ptr[i] != 0) : (i += 1) {
        if (ptr[i] >= 'A' and ptr[i] <= 'Z') ptr[i] += 32;
    }
    return lpsz;
}

pub fn CharNextW(lpsz: usize) callconv(w32cc.WINAPI) usize {
    if (lpsz == 0) return 0;
    const ptr = @as([*]const u16, @ptrFromInt(lpsz));
    if (ptr[0] == 0) return lpsz;
    return lpsz + 2; // advance by one u16
}
