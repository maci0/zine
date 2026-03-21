//! WINMM.dll export definitions

const mm = @import("win32").winmm.multimedia;

comptime {
    _ = @import("dll_common.zig");

    @export(&mm.timeGetTime, .{ .name = "timeGetTime" });
    @export(&mm.waveOutSetVolume, .{ .name = "waveOutSetVolume" });
    @export(&mm.waveOutGetVolume, .{ .name = "waveOutGetVolume" });
    @export(&mm.stub_PlaySoundA, .{ .name = "PlaySoundA" });
    @export(&mm.stub_timeGetDevCaps, .{ .name = "timeGetDevCaps" });
    @export(&mm.stub_timeBeginPeriod, .{ .name = "timeBeginPeriod" });
    @export(&mm.stub_timeEndPeriod, .{ .name = "timeEndPeriod" });
    @export(&mm.timeSetEvent, .{ .name = "timeSetEvent" });
    @export(&mm.timeKillEvent, .{ .name = "timeKillEvent" });
    @export(&mm.stub_waveOutGetNumDevs, .{ .name = "waveOutGetNumDevs" });
    @export(&mm.waveOutOpen, .{ .name = "waveOutOpen" });
    @export(&mm.stub_waveOutClose_, .{ .name = "waveOutClose" });
    @export(&mm.stub_waveOutReset, .{ .name = "waveOutReset" });
    @export(&mm.waveOutWrite, .{ .name = "waveOutWrite" });
    @export(&mm.waveOutPrepareHeader, .{ .name = "waveOutPrepareHeader" });
    @export(&mm.stub_waveOutUnprepareHeader, .{ .name = "waveOutUnprepareHeader" });
    @export(&mm.waveOutGetDevCapsA, .{ .name = "waveOutGetDevCapsA" });
    @export(&mm.stub_waveOutGetID, .{ .name = "waveOutGetID" });
    @export(&mm.midiOutOpen, .{ .name = "midiOutOpen" });
}
