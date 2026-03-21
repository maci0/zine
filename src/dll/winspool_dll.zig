//! WINSPOOL.DRV export definitions

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&stub_ret0_3, .{ .name = "OpenPrinterA" });
    @export(&stub_ret0_1, .{ .name = "ClosePrinter" });
    @export(&stub_ret0_3, .{ .name = "StartDocPrinterA" });
    @export(&stub_ret0_1, .{ .name = "EndDocPrinter" });
    @export(&stub_ret0_1, .{ .name = "StartPagePrinter" });
    @export(&stub_ret0_1, .{ .name = "EndPagePrinter" });
    @export(&stub_WritePrinter, .{ .name = "WritePrinter" });
    @export(&stub_EnumPrintersA, .{ .name = "EnumPrintersA" });
    @export(&stub_ret0_6, .{ .name = "DocumentPropertiesA" });
    @export(&stub_ret0_3, .{ .name = "OpenPrinterW" });
    @export(&stub_ret0_6, .{ .name = "GetPrinterDriverW" });
}

fn stub_ret0_1(a: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    return 0;
}
fn stub_ret0_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c };
    return 0;
}
fn stub_ret0_6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d, e, f };
    return 0;
}
fn stub_WritePrinter(hPrinter: usize, pBuf: usize, cbBuf: u32, pcWritten: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ hPrinter, pBuf };
    if (pcWritten != 0) @as(*u32, @ptrFromInt(pcWritten)).* = cbBuf;
    return 1;
}
fn stub_EnumPrintersA(Flags: u32, Name: usize, Level: u32, pPrinterEnum: usize, cbBuf: u32, pcbNeeded: usize, pcReturned: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ Flags, Name, Level, pPrinterEnum, cbBuf };
    if (pcbNeeded != 0) @as(*u32, @ptrFromInt(pcbNeeded)).* = 0;
    if (pcReturned != 0) @as(*u32, @ptrFromInt(pcReturned)).* = 0;
    return 1;
}
