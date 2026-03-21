//! NTDLL.dll export definitions

const nt = @import("win32").ntdll.ntapi;

comptime {
    _ = @import("dll_common.zig");

    @export(&nt.stub_RtlFreeAnsiString, .{ .name = "RtlFreeAnsiString" });
    @export(&nt.stub_RtlUnicodeStringToAnsiString, .{ .name = "RtlUnicodeStringToAnsiString" });
    @export(&nt.stub_RtlTimeToElapsedTimeFields, .{ .name = "RtlTimeToElapsedTimeFields" });
    @export(&nt.stub_NtClose, .{ .name = "NtClose" });
    @export(&nt.stub_RtlFreeSid, .{ .name = "RtlFreeSid" });
    @export(&nt.stub_RtlUnwind, .{ .name = "RtlUnwind" });
    @export(&nt.NtQuerySystemInformation, .{ .name = "NtQuerySystemInformation" });
    @export(&nt.VerSetConditionMask, .{ .name = "VerSetConditionMask" });
    @export(&nt.RtlInitUnicodeString, .{ .name = "RtlInitUnicodeString" });
    @export(&nt.RtlAllocateAndInitializeSid, .{ .name = "RtlAllocateAndInitializeSid" });
    @export(&nt.RtlEqualSid, .{ .name = "RtlEqualSid" });
    @export(&nt.strrchr, .{ .name = "strrchr" });
    @export(&nt.wcsicmp, .{ .name = "_wcsicmp" });
    @export(&nt.memmove, .{ .name = "memmove" });
}
