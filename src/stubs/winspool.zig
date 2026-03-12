const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const w32cc = @import("../calling_convention.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "WINSPOOL.DRV";
    try environment.addBuiltinExportComptime(m, "OpenPrinterA", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "ClosePrinter", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "StartDocPrinterA", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "EndDocPrinter", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "StartPagePrinter", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "EndPagePrinter", stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "WritePrinter", stub_WritePrinter);
    try environment.addBuiltinExportComptime(m, "EnumPrintersA", stub_EnumPrintersA);
    try environment.addBuiltinExportComptime(m, "DocumentPropertiesA", stub_ret0_6);
    try environment.addBuiltinExportComptime(m, "OpenPrinterW", stub_ret0_3);
    try environment.addBuiltinExportComptime(m, "GetPrinterDriverW", stub_ret0_6);
}

fn stub_ret0_1(a: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    return 0;
}
fn stub_ret0_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    _ = c;
    return 0;
}
fn stub_ret0_6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    return 0;
}
fn stub_WritePrinter(hPrinter: usize, pBuf: usize, cbBuf: u32, pcWritten: usize) callconv(w32cc.WINAPI) i32 {
    _ = hPrinter;
    _ = pBuf;
    if (pcWritten != 0) @as(*u32, @ptrFromInt(pcWritten)).* = cbBuf;
    return 1;
}
fn stub_EnumPrintersA(Flags: u32, Name: usize, Level: u32, pPrinterEnum: usize, cbBuf: u32, pcbNeeded: usize, pcReturned: usize) callconv(w32cc.WINAPI) i32 {
    _ = Flags;
    _ = Name;
    _ = Level;
    _ = pPrinterEnum;
    _ = cbBuf;
    if (pcbNeeded != 0) @as(*u32, @ptrFromInt(pcbNeeded)).* = 0;
    if (pcReturned != 0) @as(*u32, @ptrFromInt(pcReturned)).* = 0;
    return 1; // success with 0 printers
}
