const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "MAG_HOOK.dll";
    try environment.addBuiltinExport(m, "_FakeCursorMove@8", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "_SetZoomRect@8", @intFromPtr(&kernel32.stub_args2));
    try environment.addBuiltinExport(m, "_InstallEventHook@4", @intFromPtr(&kernel32.stub_args1));
}
