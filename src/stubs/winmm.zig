const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const renderer = @import("../gui/renderer.zig");
const dsound_stubs = @import("dsound/stubs.zig");
const stubs = @import("winmm/stubs.zig");

// waveOut volume: low word = left (0-0xFFFF), high word = right (0-0xFFFF)
pub var waveout_volume: u32 = 0xFFFFFFFF; // max volume

pub fn register(environment: *env.Environment) !void {
    const m = "WINMM.dll";
    try environment.addBuiltinExportComptime(m, "timeGetTime", stubs.stub_timeGetTime);
    try environment.addBuiltinExportComptime(m, "waveOutSetVolume", stubs.stub_waveOutSetVolume);
    try environment.addBuiltinExportComptime(m, "waveOutGetVolume", stubs.stub_waveOutGetVolume);
    try environment.addBuiltinExportComptime(m, "PlaySoundA", stubs.stub_PlaySoundA);
    try environment.addBuiltinExportComptime(m, "timeGetDevCaps", stubs.stub_timeGetDevCaps);
    try environment.addBuiltinExportComptime(m, "timeBeginPeriod", stubs.stub_timeBeginPeriod);
    try environment.addBuiltinExportComptime(m, "timeEndPeriod", stubs.stub_timeEndPeriod);
    try environment.addBuiltinExportComptime(m, "timeSetEvent", stubs.stub_timeSetEvent);
    try environment.addBuiltinExportComptime(m, "timeKillEvent", stubs.stub_timeKillEvent);

    // --- Remaining WINMM stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExportComptime(m, "PlaySoundW", stubs.stub_PlaySoundA);
    try environment.addBuiltinExportComptime(m, "auxGetDevCapsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "mixerGetDevCapsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "waveOutGetNumDevs", stubs.stub_waveOutGetNumDevs);
    try environment.addBuiltinExportComptime(m, "waveInGetNumDevs", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(m, "mixerGetNumDevs", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(m, "mixerGetControlDetailsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "mixerGetLineControlsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "mixerSetControlDetails", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "waveOutGetDevCapsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "midiOutGetDevCapsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "midiOutGetNumDevs", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(m, "mixerOpen", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(m, "mixerGetID", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "auxGetNumDevs", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(m, "waveOutMessage", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "waveInMessage", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "mixerClose", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "mixerGetLineInfoW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "mixerMessage", kernel32.stub_args4);

    // --- MSS32.DLL required WINMM imports ---
    // waveOut functions
    try environment.addBuiltinExportComptime(m, "waveOutOpen", stubs.stub_waveOutOpen);
    try environment.addBuiltinExportComptime(m, "waveOutClose", stubs.stub_waveOutClose_);
    try environment.addBuiltinExportComptime(m, "waveOutReset", stubs.stub_waveOutReset);
    try environment.addBuiltinExportComptime(m, "waveOutWrite", stubs.stub_waveOutWrite);
    try environment.addBuiltinExportComptime(m, "waveOutPrepareHeader", stubs.stub_waveOutPrepareHeader);
    try environment.addBuiltinExportComptime(m, "waveOutUnprepareHeader", stubs.stub_waveOutUnprepareHeader);
    try environment.addBuiltinExportComptime(m, "waveOutGetDevCapsA", stubs.stub_waveOutGetDevCapsA);
    try environment.addBuiltinExportComptime(m, "waveOutGetID", stubs.stub_waveOutGetID);

    // midiOut functions
    try environment.addBuiltinExportComptime(m, "midiOutOpen", stubs.stub_midiOutOpen);
    try environment.addBuiltinExportComptime(m, "midiOutClose", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "midiOutReset", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "midiOutShortMsg", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "midiOutLongMsg", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "midiOutPrepareHeader", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "midiOutUnprepareHeader", kernel32.stub_args3);

    // aux functions (A variants)
    try environment.addBuiltinExportComptime(m, "auxGetDevCapsA", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "auxGetVolume", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "auxSetVolume", kernel32.stub_args2);

    // mixer functions (A variants)
    try environment.addBuiltinExportComptime(m, "mixerGetControlDetailsA", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "mixerGetLineInfoA", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "mixerGetLineControlsA", kernel32.stub_args3);

    // mci
    try environment.addBuiltinExportComptime(m, "mciSendCommandA", kernel32.stub_args4);

    // waveIn functions
    try environment.addBuiltinExportComptime(m, "waveInOpen", kernel32.stub_args6);
    try environment.addBuiltinExportComptime(m, "waveInClose", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "waveInReset", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "waveInStart", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "waveInAddBuffer", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "waveInPrepareHeader", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "waveInUnprepareHeader", kernel32.stub_args3);

    renderer.on_volume_change = &handleVolumeFromUI;
}

fn handleVolumeFromUI(linear: f32) void {
    // UI slider changed — sync waveOut and DirectSound volume state
    const vol16: u32 = @intFromFloat(std.math.clamp(linear, 0.0, 1.0) * 65535.0);
    waveout_volume = vol16 | (vol16 << 16);

    if (linear <= 0.0001) {
        dsound_stubs.dsound_volume = -10000;
    } else {
        const db100: i32 = @intFromFloat(@round(@log10(@as(f64, linear)) * 2000.0));
        dsound_stubs.dsound_volume = std.math.clamp(db100, -10000, 0);
    }
    if (trace.enable_tracing) trace.print("WINMM: UI volume -> linear={d:.3}, waveOut=0x{x:0>8}, dsound={d}\n", .{ linear, waveout_volume, dsound_stubs.dsound_volume });
}
