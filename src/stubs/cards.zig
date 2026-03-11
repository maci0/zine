const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "CARDS.dll";
    try environment.addBuiltinExport(m, "cdtInit", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "cdtTerm", @intFromPtr(&kernel32.stub_args0));
    try environment.addBuiltinExport(m, "cdtDraw", @intFromPtr(&kernel32.stub_args6));
    try environment.addBuiltinExport(m, "cdtDrawExt", @intFromPtr(&kernel32.stub_args8));
    try environment.addBuiltinExport(m, "cdtAnimate", @intFromPtr(&kernel32.stub_args4));
}
