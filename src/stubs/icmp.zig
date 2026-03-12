const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "ICMP.dll";
    try environment.addBuiltinExportComptime(m, "IcmpCreateFile", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(m, "IcmpSendEcho2", kernel32.stub_args8);
    try environment.addBuiltinExportComptime(m, "IcmpCloseHandle", kernel32.stub_args1);
}
