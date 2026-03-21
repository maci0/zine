//! MPR.dll (Multiple Provider Router) — Windows Networking stubs.
//! Provides WNet* functions for network drive/resource access.

const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "MPR.dll";
    // All WNet functions return ERROR_NOT_SUPPORTED (50) or NO_ERROR (0) as stubs
    try environment.addBuiltinExportComptime(m, "WNetAddConnectionA", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "WNetAddConnection2A", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "WNetAddConnection2W", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "WNetAddConnection3A", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "WNetCancelConnectionA", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "WNetCancelConnection2A", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "WNetCancelConnection2W", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "WNetGetConnectionA", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "WNetGetConnectionW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "WNetOpenEnumA", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "WNetOpenEnumW", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "WNetEnumResourceA", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "WNetEnumResourceW", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "WNetCloseEnum", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "WNetGetUniversalNameA", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "WNetUseConnectionA", kernel32.stub_args8);
    try environment.addBuiltinExportComptime(m, "WNetGetNetworkInformationA", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "WNetGetResourceInformationA", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "WNetGetLastErrorA", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "WNetGetLastErrorW", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "WNetGetUserA", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "WNetGetProviderNameA", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "WNetAddConnection3W", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "WNetConnectionDialog", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "WNetDisconnectDialog", kernel32.stub_args2);
}
