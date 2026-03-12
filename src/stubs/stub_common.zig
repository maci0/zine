/// Generic stub functions for unimplemented Win32 APIs.
///
/// These are variadic no-op stubs that accept N arguments and return 0.
/// Used as placeholders in DLL export tables when a function hasn't been
/// implemented yet but needs a valid entry point.

const std = @import("std");
const trace = @import("../trace.zig");
const w32cc = @import("../calling_convention.zig");

pub fn stub_args0() callconv(w32cc.WINAPI) usize {
    return 0;
}

pub fn stub_args1(a: usize) callconv(w32cc.WINAPI) u32 {
    _ = a;
    if (trace.enable_tracing) {
        const x86_thunks = @import("../x86/thunks.zig");
        const ret_addr = @returnAddress();
        if (x86_thunks.lookupUnresolvedName(ret_addr)) |name| {
            trace.print("generic stub1 [{s}] called from {x}\n", .{ name, ret_addr });
        } else {
            trace.print("generic stub1 called from {x}\n", .{ret_addr});
        }
    }
    return 0;
}

pub fn stub_args2(a: usize, b: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    if (trace.enable_tracing) {
        const x86_thunks = @import("../x86/thunks.zig");
        const ret_addr = @returnAddress();
        if (x86_thunks.lookupUnresolvedName(ret_addr)) |name| {
            trace.print("generic stub2 [{s}] called from {x}\n", .{ name, ret_addr });
        } else {
            trace.print("generic stub2 called from {x}\n", .{ret_addr});
        }
    }
    return 0;
}

pub fn stub_args3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    if (trace.enable_tracing) trace.print("generic stub3 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    if (trace.enable_tracing) trace.print("generic stub4 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    if (trace.enable_tracing) trace.print("generic stub5 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    if (trace.enable_tracing) {
        const x86_thunks = @import("../x86/thunks.zig");
        const ret_addr = @returnAddress();
        if (x86_thunks.lookupUnresolvedName(ret_addr)) |name| {
            trace.print("generic stub6 [{s}] called from {x}\n", .{ name, ret_addr });
        } else {
            trace.print("generic stub6 called from {x}\n", .{ret_addr});
        }
    }
    return 0;
}

pub fn stub_args7(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    if (trace.enable_tracing) {
        const x86_thunks = @import("../x86/thunks.zig");
        const ret_addr = @returnAddress();
        if (x86_thunks.lookupUnresolvedName(ret_addr)) |name| {
            trace.print("generic stub7 [{s}] called from {x}\n", .{ name, ret_addr });
        } else {
            trace.print("generic stub7 called from {x}\n", .{ret_addr});
        }
    }
    return 0;
}

pub fn stub_args8(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    _ = h;
    if (trace.enable_tracing) trace.print("generic stub8 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args9(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize, i: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    _ = h;
    _ = i;
    if (trace.enable_tracing) trace.print("generic stub9 called from {x}\n", .{@returnAddress()});
    return 0;
}

pub fn stub_args10(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize, i: usize, j: usize) callconv(w32cc.WINAPI) usize {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
    _ = f;
    _ = g;
    _ = h;
    _ = i;
    _ = j;
    if (trace.enable_tracing) trace.print("generic stub10 called from {x}\n", .{@returnAddress()});
    return 0;
}
