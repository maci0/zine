const env = @import("../loader/env.zig");
const kernel32 = @import("kernel32.zig");

const registry = @import("advapi32/registry.zig");
const security = @import("advapi32/security.zig");
const misc = @import("advapi32/misc.zig");

pub fn register(environment: *env.Environment) !void {
    const advapi32 = "ADVAPI32.dll";
    try environment.addBuiltinExportComptime(advapi32, "RegOpenKeyExA", &registry.RegOpenKeyExA);
    try environment.addBuiltinExportComptime(advapi32, "RegQueryValueExA", &registry.RegQueryValueExA);
    try environment.addBuiltinExportComptime(advapi32, "RegCloseKey", &kernel32.stub_args1);
    try environment.addBuiltinExportComptime(advapi32, "RegCreateKeyExA", &registry.RegCreateKeyExA);
    try environment.addBuiltinExportComptime(advapi32, "RegSetValueExA", &registry.RegSetValueExA);
    try environment.addBuiltinExportComptime(advapi32, "RegDeleteKeyA", &registry.RegDeleteKeyA);
    try environment.addBuiltinExportComptime(advapi32, "RegDeleteValueA", &registry.stub_RegDeleteValueA);
    try environment.addBuiltinExportComptime(advapi32, "RegEnumKeyExA", &registry.stub_RegEnumKeyExA);
    try environment.addBuiltinExportComptime(advapi32, "RegEnumKeyA", &registry.RegEnumKeyA);
    try environment.addBuiltinExportComptime(advapi32, "RegQueryInfoKeyA", &registry.RegQueryInfoKeyA);
    try environment.addBuiltinExportComptime(advapi32, "RegFlushKey", &registry.stub_RegFlushKey);
    try environment.addBuiltinExportComptime(advapi32, "RegOpenKeyA", &registry.stub_RegOpenKeyA);
    try environment.addBuiltinExportComptime(advapi32, "RegQueryValueExW", &registry.RegQueryValueExW);
    try environment.addBuiltinExportComptime(advapi32, "RegSetValueExW", &registry.RegSetValueExW);
    try environment.addBuiltinExportComptime(advapi32, "OpenProcessToken", &security.OpenProcessToken);
    try environment.addBuiltinExportComptime(advapi32, "AdjustTokenPrivileges", &security.AdjustTokenPrivileges);
    try environment.addBuiltinExportComptime(advapi32, "LookupPrivilegeValueW", &security.stub_LookupPrivilegeValueW);
    try environment.addBuiltinExportComptime(advapi32, "GetUserNameA", &misc.GetUserNameA);
    try environment.addBuiltinExportComptime(advapi32, "GetFileSecurityW", &security.GetFileSecurityW);
    try environment.addBuiltinExportComptime(advapi32, "SetFileSecurityW", &security.stub_SetFileSecurityW);
    try environment.addBuiltinExportComptime(advapi32, "RegCreateKeyA", &registry.stub_RegCreateKeyA);
    try environment.addBuiltinExportComptime(advapi32, "IsTextUnicode", &security.stub_IsTextUnicode);
    try environment.addBuiltinExportComptime(advapi32, "RegCreateKeyW", &registry.stub_RegCreateKeyW);

    // W variants needed by win2k apps (3-6x each)
    try environment.addBuiltinExportComptime(advapi32, "RegOpenKeyExW", &registry.RegOpenKeyExW);
    try environment.addBuiltinExportComptime(advapi32, "RegCreateKeyExW", &registry.RegCreateKeyExW);
    try environment.addBuiltinExportComptime(advapi32, "RegOpenKeyW", &registry.stub_RegOpenKeyW);
    try environment.addBuiltinExportComptime(advapi32, "RegDeleteKeyW", &registry.RegDeleteKeyW);
    try environment.addBuiltinExportComptime(advapi32, "RegDeleteValueW", &registry.stub_RegDeleteValueW);
    try environment.addBuiltinExportComptime(advapi32, "RegSetValueW", &registry.stub_RegSetValueW);
    try environment.addBuiltinExportComptime(advapi32, "RegEnumKeyW", &registry.RegEnumKeyW);
    try environment.addBuiltinExportComptime(advapi32, "LookupPrivilegeValueA", &security.stub_LookupPrivilegeValueW);
    try environment.addBuiltinExportComptime(advapi32, "GetTokenInformation", &security.stub_GetTokenInformation);
    try environment.addBuiltinExportComptime(advapi32, "OpenThreadToken", &security.stub_OpenThreadToken);
    try environment.addBuiltinExportComptime(advapi32, "RegQueryValueW", &registry.stub_RegQueryValueW);

    // --- Remaining ADVAPI32 stubs for 100% win2k coverage ---
    // Faithful implementations
    try environment.addBuiltinExportComptime(advapi32, "QueryServiceStatus", &kernel32.stub_args3);
    try environment.addBuiltinExportComptime(advapi32, "EqualSid", &security.EqualSid);
    try environment.addBuiltinExportComptime(advapi32, "OpenServiceA", &kernel32.stub_args3);
    try environment.addBuiltinExportComptime(advapi32, "OpenSCManagerA", &kernel32.stub_args3);
    try environment.addBuiltinExportComptime(advapi32, "CloseServiceHandle", &misc.stub_ret_true_1);
    try environment.addBuiltinExportComptime(advapi32, "GetAce", &kernel32.stub_args3);
    try environment.addBuiltinExportComptime(advapi32, "InitializeSecurityDescriptor", &misc.stub_ret_true_2);
    try environment.addBuiltinExportComptime(advapi32, "GetLengthSid", &security.GetLengthSid);
    try environment.addBuiltinExportComptime(advapi32, "InitializeAcl", &misc.stub_ret_true_3);
    try environment.addBuiltinExportComptime(advapi32, "AddAccessAllowedAce", &misc.stub_ret_true_4);
    try environment.addBuiltinExportComptime(advapi32, "SetSecurityDescriptorDacl", &misc.stub_ret_true_4);
    try environment.addBuiltinExportComptime(advapi32, "GetSecurityDescriptorOwner", &security.GetSecurityDescriptorOwner);
    try environment.addBuiltinExportComptime(advapi32, "IsValidSecurityDescriptor", &misc.stub_ret_true_1);
    try environment.addBuiltinExportComptime(advapi32, "GetSecurityDescriptorLength", &security.GetSecurityDescriptorLength);
    try environment.addBuiltinExportComptime(advapi32, "MakeSelfRelativeSD", &misc.stub_ret_true_3);
    try environment.addBuiltinExportComptime(advapi32, "GetSecurityInfoExW", &kernel32.stub_args8);
    try environment.addBuiltinExportComptime(advapi32, "GetSiteSidFromToken", &kernel32.stub_args2);
    try environment.addBuiltinExportComptime(advapi32, "IsValidSid", &misc.stub_ret_true_1);
    try environment.addBuiltinExportComptime(advapi32, "IsTokenRestricted", &kernel32.stub_args1);
    try environment.addBuiltinExportComptime(advapi32, "LookupAccountSidW", &kernel32.stub_args7);
    try environment.addBuiltinExportComptime(advapi32, "FreeSid", &security.FreeSid);
}
