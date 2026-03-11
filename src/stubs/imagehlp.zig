const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");

pub fn register(environment: *env.Environment) !void {
    const imagehlp = "IMAGEHLP.dll";
    try environment.addBuiltinExport(imagehlp, "UnDecorateSymbolName", @intFromPtr(&stub_UnDecorateSymbolName));
}

fn stub_UnDecorateSymbolName(lpName_ptr: usize, lpOutput_ptr: usize, nSize: u32, Flags: u32) callconv(.winapi) u32 {
    _ = Flags;
    if (lpOutput_ptr == 0) return 0;
    var name: []const u8 = "";
    if (lpName_ptr != 0) {
        name = trace.c_span(lpName_ptr);
    }

    if (name.len == 0) {
        const msvcrt = @import("msvcrt.zig");
        if (msvcrt.global_argc > 1) {
            if (msvcrt.global_argv[@as(usize, @intCast(msvcrt.global_argc - 1))]) |last_arg| {
                name = trace.c_span(@intFromPtr(last_arg));
            }
        }
    }

    if (trace.enable_tracing) trace.print("IMAGEHLP: UnDecorateSymbolName('{s}', size={d})\n", .{ name, nSize });

    const copy_len = @min(name.len, @as(usize, @intCast(nSize)) - 1);
    const out = @as([*]u8, @ptrFromInt(lpOutput_ptr));
    @memcpy(out[0..copy_len], name[0..copy_len]);
    out[copy_len] = 0;
    return @intCast(copy_len);
}
