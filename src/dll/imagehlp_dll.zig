//! IMAGEHLP.dll export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub_UnDecorateSymbolName, .{ .name = "UnDecorateSymbolName" });
}

fn stub_UnDecorateSymbolName(lpName_ptr: usize, lpOutput_ptr: usize, nSize: u32, Flags: u32) callconv(w32cc.WINAPI) u32 {
    _ = Flags;
    if (lpOutput_ptr == 0 or nSize == 0) return 0;
    if (lpName_ptr == 0) {
        @as([*]u8, @ptrFromInt(lpOutput_ptr))[0] = 0;
        return 0;
    }
    // Copy the decorated name as-is (basic fallback)
    const name = @as([*:0]const u8, @ptrFromInt(lpName_ptr));
    const out = @as([*]u8, @ptrFromInt(lpOutput_ptr));
    var i: u32 = 0;
    while (i < nSize - 1 and name[i] != 0) : (i += 1) {
        out[i] = name[i];
    }
    out[i] = 0;
    return i;
}
