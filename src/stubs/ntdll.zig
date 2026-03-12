const env = @import("../loader/env.zig");

const kernel32 = @import("kernel32.zig");
const stubs = @import("ntdll/stubs.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "ntdll.dll";

    // Core NT functions
    try environment.addBuiltinExportComptime(m, "RtlFreeAnsiString", stubs.stub_RtlFreeAnsiString);
    try environment.addBuiltinExportComptime(m, "RtlUnicodeStringToAnsiString", stubs.stub_RtlUnicodeStringToAnsiString);
    try environment.addBuiltinExportComptime(m, "NtQuerySystemInformation", stubs.stub_NtQuerySystemInformation);
    try environment.addBuiltinExportComptime(m, "RtlTimeToElapsedTimeFields", stubs.stub_RtlTimeToElapsedTimeFields);

    // Version/SID functions
    try environment.addBuiltinExportComptime(m, "VerSetConditionMask", stubs.stub_VerSetConditionMask);
    try environment.addBuiltinExportComptime(m, "NtOpenProcessToken", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "RtlAllocateAndInitializeSid", stubs.stub_RtlAllocateAndInitializeSid);
    try environment.addBuiltinExportComptime(m, "NtQueryInformationToken", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "RtlFreeSid", stubs.stub_RtlFreeSid);
    try environment.addBuiltinExportComptime(m, "RtlEqualSid", stubs.stub_RtlEqualSid);
    try environment.addBuiltinExportComptime(m, "NtClose", stubs.stub_NtClose);
    try environment.addBuiltinExportComptime(m, "RtlInitUnicodeString", stubs.stub_RtlInitUnicodeString);
    try environment.addBuiltinExportComptime(m, "RtlUnicodeStringToInteger", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "RtlLargeIntegerToChar", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "RtlAnsiStringToUnicodeString", stubs.stub_RtlUnicodeStringToAnsiString);
    try environment.addBuiltinExportComptime(m, "NtOpenThread", kernel32.stub_args4);

    // CRT intrinsics
    try environment.addBuiltinExport(m, "_chkstk", @intFromPtr(stubs.stub_chkstk));
    try environment.addBuiltinExport(m, "_allmul", @intFromPtr(stubs.stub_allmul));
    try environment.addBuiltinExport(m, "_alldiv", @intFromPtr(stubs.stub_alldiv));

    // String/memory functions
    try environment.addBuiltinExportComptime(m, "RtlUnwind", stubs.stub_RtlUnwind);
    try environment.addBuiltinExportComptime(m, "strrchr", stubs.stub_strrchr);
    try environment.addBuiltinExportComptime(m, "_wcsicmp", stubs.stub_wcsicmp);
    try environment.addBuiltinExportComptime(m, "memmove", stubs.stub_memmove);
}
