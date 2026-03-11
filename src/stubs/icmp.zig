const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "ICMP.dll";
    try environment.addBuiltinExport(m, "IcmpCreateFile", @intFromPtr(&kernel32.stub_args0));
    try environment.addBuiltinExport(m, "IcmpSendEcho2", @intFromPtr(&kernel32.stub_args8));
    try environment.addBuiltinExport(m, "IcmpCloseHandle", @intFromPtr(&kernel32.stub_args1));
}
