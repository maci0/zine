const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");

pub fn register(environment: *env.Environment) !void {
    const builtin_module = "MFC42.DLL";
    const ordinals = [_]u32{
        500,
        533,
        536,
        537,
        540,
        772,
        798,
        800,
        823,
        825,
        858,
        859,
        860,
        922,
        924,
        964,
        1265,
        1997,
        2606,
        2808,
        2915,
        2917,
        3176,
        3180,
        3183,
        3318,
        3511,
        3724,
        4182,
        5194,
        5448,
        5465,
        5466,
        5572,
        5710,
        5778,
        5860,
        6010,
        6317,
        6392,
        6407,
    };

    for (ordinals) |ord| {
        const name = try std.fmt.allocPrint(environment.allocator, "ordinal_{d}", .{ord});
        try environment.addBuiltinExport(builtin_module, name, @intFromPtr(&stub_mfc_dummy));
    }
}

fn stub_mfc_dummy() callconv(.winapi) usize {
    if (trace.enable_tracing) trace.print("MFC42: dummy called from {x}\n", .{@returnAddress()});
    return 0;
}
