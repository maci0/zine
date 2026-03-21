//! ADVAPI32.dll export definitions

const w32 = @import("win32");
const registry = w32.advapi32.registry;
const security = w32.advapi32.security;
const services = w32.advapi32.services;

comptime {
    _ = @import("dll_common.zig");

    // Registry
    @export(&registry.RegOpenKeyExA, .{ .name = "RegOpenKeyExA" });
    @export(&registry.RegQueryValueExA, .{ .name = "RegQueryValueExA" });
    @export(&registry.RegCreateKeyExA, .{ .name = "RegCreateKeyExA" });
    @export(&registry.RegQueryInfoKeyA, .{ .name = "RegQueryInfoKeyA" });
    @export(&registry.RegDeleteKeyA, .{ .name = "RegDeleteKeyA" });
    @export(&registry.RegEnumKeyA, .{ .name = "RegEnumKeyA" });

    // Security
    @export(&security.OpenProcessToken, .{ .name = "OpenProcessToken" });
    @export(&security.EqualSid, .{ .name = "EqualSid" });
    @export(&security.GetLengthSid, .{ .name = "GetLengthSid" });
    @export(&security.FreeSid, .{ .name = "FreeSid" });
    @export(&security.AccessCheck, .{ .name = "AccessCheck" });

    // User / Services
    @export(&services.GetUserNameA, .{ .name = "GetUserNameA" });
}
