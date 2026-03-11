const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "WINSPOOL.DRV";
    try environment.addBuiltinExport(m, "OpenPrinterA", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "ClosePrinter", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "StartDocPrinterA", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "EndDocPrinter", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "StartPagePrinter", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "EndPagePrinter", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "WritePrinter", @intFromPtr(&stub_WritePrinter));
    try environment.addBuiltinExport(m, "EnumPrintersA", @intFromPtr(&stub_EnumPrintersA));
    try environment.addBuiltinExport(m, "DocumentPropertiesA", @intFromPtr(&stub_ret0_6));
    try environment.addBuiltinExport(m, "OpenPrinterW", @intFromPtr(&stub_ret0_3));
    try environment.addBuiltinExport(m, "GetPrinterDriverW", @intFromPtr(&stub_ret0_6));
}

fn stub_ret0_1(a: usize) callconv(.winapi) i32 {
    _ = a;
    return 0;
}
fn stub_ret0_3(a: usize, b: usize, c: usize) callconv(.winapi) i32 {
    _ = a;
    _ = b;
    _ = c;
    return 0;
}
fn stub_ret0_6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(.winapi) i32 {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    return 0;
}
fn stub_WritePrinter(hPrinter: usize, pBuf: usize, cbBuf: u32, pcWritten: usize) callconv(.winapi) i32 {
    _ = hPrinter;
    _ = pBuf;
    if (pcWritten != 0) @as(*u32, @ptrFromInt(pcWritten)).* = cbBuf;
    return 1;
}
fn stub_EnumPrintersA(Flags: u32, Name: usize, Level: u32, pPrinterEnum: usize, cbBuf: u32, pcbNeeded: usize, pcReturned: usize) callconv(.winapi) i32 {
    _ = Flags;
    _ = Name;
    _ = Level;
    _ = pPrinterEnum;
    _ = cbBuf;
    if (pcbNeeded != 0) @as(*u32, @ptrFromInt(pcbNeeded)).* = 0;
    if (pcReturned != 0) @as(*u32, @ptrFromInt(pcReturned)).* = 0;
    return 1; // success with 0 printers
}
