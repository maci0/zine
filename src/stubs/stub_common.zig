/// Generic stub functions for unimplemented Win32 APIs.
///
/// These are variadic no-op stubs that accept N arguments and return 0.
/// Used as placeholders in DLL export tables when a function hasn't been
/// implemented yet but needs a valid entry point.

const std = @import("std");
const trace = @import("../trace.zig");
const w32cc = @import("../calling_convention.zig");

/// Shared tracing logic for all stubs. Must be `inline` so that
/// `@returnAddress()` resolves to the caller of the stub, not this helper.
inline fn traceStub(comptime n: comptime_int) void {
    if (trace.enable_tracing) {
        const x86_thunks = @import("../x86/thunks.zig");
        const ret_addr = @returnAddress();
        const label = "generic " ++ std.fmt.comptimePrint("stub{d}", .{n});
        if (x86_thunks.lookupUnresolvedName(ret_addr)) |name| {
            trace.print(label ++ " [{s}] called from {x}\n", .{ name, ret_addr });
        } else {
            trace.print(label ++ " called from {x}\n", .{ret_addr});
        }
    }
}

pub fn stub_args0() callconv(w32cc.WINAPI) usize {
    traceStub(0);
    return 0;
}

pub fn stub_args1(a: usize) callconv(w32cc.WINAPI) u32 {
    _ = a;
    traceStub(1);
    return 0;
}

pub fn stub_args2(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b };
    traceStub(2);
    return 0;
}

pub fn stub_args3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c };
    traceStub(3);
    return 0;
}

pub fn stub_args4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d };
    traceStub(4);
    return 0;
}

pub fn stub_args5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e };
    traceStub(5);
    return 0;
}

pub fn stub_args6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f };
    traceStub(6);
    return 0;
}

pub fn stub_args7(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f, g };
    traceStub(7);
    return 0;
}

pub fn stub_args8(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f, g, h };
    traceStub(8);
    return 0;
}

pub fn stub_args9(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize, i: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f, g, h, i };
    traceStub(9);
    return 0;
}

pub fn stub_args10(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize, i: usize, j: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ a, b, c, d, e, f, g, h, i, j };
    traceStub(10);
    return 0;
}
