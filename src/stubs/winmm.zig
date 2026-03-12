const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const renderer = @import("../gui/renderer.zig");
const dsound = @import("dsound.zig");
const dsound_stubs = @import("dsound/stubs.zig");
const platform = @import("../platform.zig");
const w32 = @import("../win32_constants.zig");
const w32cc = @import("../calling_convention.zig");

// waveOut volume: low word = left (0-0xFFFF), high word = right (0-0xFFFF)
var waveout_volume: u32 = 0xFFFFFFFF; // max volume

pub fn register(environment: *env.Environment) !void {
    const builtin_module = "WINMM.dll";
    try environment.addBuiltinExportComptime(builtin_module, "timeGetTime", stub_timeGetTime);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutSetVolume", stub_waveOutSetVolume);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutGetVolume", stub_waveOutGetVolume);
    try environment.addBuiltinExportComptime(builtin_module, "PlaySoundA", stub_PlaySoundA);
    try environment.addBuiltinExportComptime(builtin_module, "timeGetDevCaps", stub_timeGetDevCaps);
    try environment.addBuiltinExportComptime(builtin_module, "timeBeginPeriod", stub_timeBeginPeriod);
    try environment.addBuiltinExportComptime(builtin_module, "timeEndPeriod", stub_timeEndPeriod);
    try environment.addBuiltinExportComptime(builtin_module, "timeSetEvent", stub_timeSetEvent);
    try environment.addBuiltinExportComptime(builtin_module, "timeKillEvent", stub_timeKillEvent);

    // --- Remaining WINMM stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExportComptime(builtin_module, "PlaySoundW", stub_PlaySoundA);
    try environment.addBuiltinExportComptime(builtin_module, "auxGetDevCapsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "mixerGetDevCapsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutGetNumDevs", stub_waveOutGetNumDevs);
    try environment.addBuiltinExportComptime(builtin_module, "waveInGetNumDevs", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(builtin_module, "mixerGetNumDevs", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(builtin_module, "mixerGetControlDetailsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "mixerGetLineControlsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "mixerSetControlDetails", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutGetDevCapsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "midiOutGetDevCapsW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "midiOutGetNumDevs", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(builtin_module, "mixerOpen", kernel32.stub_args5);
    try environment.addBuiltinExportComptime(builtin_module, "mixerGetID", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "auxGetNumDevs", kernel32.stub_args0);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutMessage", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(builtin_module, "waveInMessage", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(builtin_module, "mixerClose", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(builtin_module, "mixerGetLineInfoW", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "mixerMessage", kernel32.stub_args4);

    // --- MSS32.DLL required WINMM imports ---
    // waveOut functions
    try environment.addBuiltinExportComptime(builtin_module, "waveOutOpen", stub_waveOutOpen);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutClose", stub_waveOutClose_);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutReset", stub_waveOutReset);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutWrite", stub_waveOutWrite);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutPrepareHeader", stub_waveOutPrepareHeader);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutUnprepareHeader", stub_waveOutUnprepareHeader);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutGetDevCapsA", stub_waveOutGetDevCapsA);
    try environment.addBuiltinExportComptime(builtin_module, "waveOutGetID", stub_waveOutGetID);

    // midiOut functions
    try environment.addBuiltinExportComptime(builtin_module, "midiOutOpen", stub_midiOutOpen);
    try environment.addBuiltinExportComptime(builtin_module, "midiOutClose", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(builtin_module, "midiOutReset", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(builtin_module, "midiOutShortMsg", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(builtin_module, "midiOutLongMsg", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "midiOutPrepareHeader", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "midiOutUnprepareHeader", kernel32.stub_args3);

    // aux functions (A variants)
    try environment.addBuiltinExportComptime(builtin_module, "auxGetDevCapsA", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "auxGetVolume", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(builtin_module, "auxSetVolume", kernel32.stub_args2);

    // mixer functions (A variants)
    try environment.addBuiltinExportComptime(builtin_module, "mixerGetControlDetailsA", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "mixerGetLineInfoA", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "mixerGetLineControlsA", kernel32.stub_args3);

    // mci
    try environment.addBuiltinExportComptime(builtin_module, "mciSendCommandA", kernel32.stub_args4);

    // waveIn functions
    try environment.addBuiltinExportComptime(builtin_module, "waveInOpen", kernel32.stub_args6);
    try environment.addBuiltinExportComptime(builtin_module, "waveInClose", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(builtin_module, "waveInReset", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(builtin_module, "waveInStart", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(builtin_module, "waveInAddBuffer", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "waveInPrepareHeader", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(builtin_module, "waveInUnprepareHeader", kernel32.stub_args3);

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

fn stub_timeGetTime() callconv(w32cc.WINAPI) u32 {
    // Called in tight timing loops; yield to avoid 100% CPU usage.
    platform.yield();

    const ts = std.time.milliTimestamp();
    return @intCast(ts & 0xFFFFFFFF);
}

fn stub_waveOutSetVolume(hwo: u32, dwVolume: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    waveout_volume = dwVolume;

    // Average left and right channels, convert 0-0xFFFF to 0.0-1.0
    const left: u32 = dwVolume & 0xFFFF;
    const right: u32 = (dwVolume >> 16) & 0xFFFF;
    const avg: f32 = @as(f32, @floatFromInt(left + right)) / (2.0 * 65535.0);

    if (trace.enable_tracing) trace.print("WINMM: waveOutSetVolume(0x{x:0>8}) -> linear={d:.3}\n", .{ dwVolume, avg });

    // Also sync DirectSound volume state (convert linear to hundredths-of-dB)
    if (avg <= 0.0001) {
        dsound_stubs.dsound_volume = -10000;
    } else {
        const db100: i32 = @intFromFloat(@round(@log10(@as(f64, avg)) * 2000.0));
        dsound_stubs.dsound_volume = std.math.clamp(db100, -10000, 0);
    }

    renderer.setVolume(avg);
    return 0; // MMSYSERR_NOERROR
}

fn stub_waveOutGetVolume(hwo: u32, pdwVolume: usize) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    if (pdwVolume != 0) {
        @as(*align(1) u32, @ptrFromInt(pdwVolume)).* = waveout_volume;
    }
    if (trace.enable_tracing) trace.print("WINMM: waveOutGetVolume() -> 0x{x:0>8}\n", .{waveout_volume});
    return 0; // MMSYSERR_NOERROR
}

fn stub_PlaySoundA(pszSound: usize, hmod: usize, fdwSound: u32) callconv(w32cc.WINAPI) i32 {
    _ = pszSound;
    _ = hmod;
    _ = fdwSound;
    if (trace.enable_tracing) trace.print("WINMM: PlaySoundA\n", .{});
    return 1;
}

// --- Timer functions for Europa 1400 ---

fn stub_timeGetDevCaps(ptc: usize, cbtc: u32) callconv(w32cc.WINAPI) u32 {
    _ = cbtc;
    if (ptc != 0) {
        const tc = @as(*w32.TIMECAPS, @ptrFromInt(ptc));
        tc.wPeriodMin = 1;       // 1ms
        tc.wPeriodMax = 1000000;
    }
    return 0; // TIMERR_NOERROR
}

fn stub_timeBeginPeriod(uPeriod: u32) callconv(w32cc.WINAPI) u32 {
    _ = uPeriod;
    return 0; // TIMERR_NOERROR
}

fn stub_timeEndPeriod(uPeriod: u32) callconv(w32cc.WINAPI) u32 {
    _ = uPeriod;
    return 0; // TIMERR_NOERROR
}

var timer_id_counter: u32 = 1;

fn stub_timeSetEvent(uDelay: u32, uResolution: u32, fptc: usize, dwUser: usize, fuEvent: u32) callconv(w32cc.WINAPI) u32 {
    _ = uResolution;
    _ = fptc;
    _ = dwUser;
    _ = fuEvent;
    if (trace.enable_tracing) trace.print("WINMM: timeSetEvent(delay={d})\n", .{uDelay});
    const id = timer_id_counter;
    timer_id_counter += 1;
    return id;
}

fn stub_timeKillEvent(uTimerID: u32) callconv(w32cc.WINAPI) u32 {
    _ = uTimerID;
    return 0; // TIMERR_NOERROR
}

// --- waveOut stubs for MSS32.DLL ---

fn stub_waveOutGetNumDevs() callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("WINMM: waveOutGetNumDevs -> 1\n", .{});
    return 1; // One audio device available
}

// MMRESULT waveOutOpen(LPHWAVEOUT phwo, UINT uDeviceID, LPCWAVEFORMATEX pwfx, DWORD_PTR dwCallback, DWORD_PTR dwInstance, DWORD fdwOpen)
fn stub_waveOutOpen(phwo: usize, uDeviceID: u32, pwfx: usize, dwCallback: usize, dwInstance: usize, fdwOpen: u32) callconv(w32cc.WINAPI) u32 {
    _ = uDeviceID; _ = pwfx; _ = dwCallback; _ = dwInstance; _ = fdwOpen;
    if (trace.enable_tracing) trace.print("WINMM: waveOutOpen\n", .{});
    // Write a fake handle to *phwo
    if (phwo != 0) {
        @as(*align(1) u32, @ptrFromInt(phwo)).* = 0xBEEF0040;
    }
    return 0; // MMSYSERR_NOERROR
}

fn stub_waveOutClose_(hwo: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    if (trace.enable_tracing) trace.print("WINMM: waveOutClose\n", .{});
    return 0; // MMSYSERR_NOERROR
}

fn stub_waveOutReset(hwo: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    return 0;
}

// MMRESULT waveOutWrite(HWAVEOUT hwo, LPWAVEHDR pwh, UINT cbwh)
fn stub_waveOutWrite(hwo: u32, pwh: usize, cbwh: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo; _ = cbwh;
    // Mark the buffer as done immediately (set WHDR_DONE flag = 0x1)
    if (pwh != 0) {
        const flags_ptr = @as(*align(1) u32, @ptrFromInt(pwh + 16)); // dwFlags offset in WAVEHDR
        flags_ptr.* |= 0x1; // WHDR_DONE
    }
    return 0;
}

// MMRESULT waveOutPrepareHeader(HWAVEOUT hwo, LPWAVEHDR pwh, UINT cbwh)
fn stub_waveOutPrepareHeader(hwo: u32, pwh: usize, cbwh: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo; _ = cbwh;
    // Set WHDR_PREPARED flag
    if (pwh != 0) {
        const flags_ptr = @as(*align(1) u32, @ptrFromInt(pwh + 16));
        flags_ptr.* |= 0x2; // WHDR_PREPARED
    }
    return 0;
}

fn stub_waveOutUnprepareHeader(hwo: u32, pwh: usize, cbwh: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo; _ = cbwh;
    if (pwh != 0) {
        const flags_ptr = @as(*align(1) u32, @ptrFromInt(pwh + 16));
        flags_ptr.* &= ~@as(u32, 0x2); // Clear WHDR_PREPARED
    }
    return 0;
}

// MMRESULT waveOutGetDevCapsA(UINT uDeviceID, LPWAVEOUTCAPS pwoc, UINT cbwoc)
fn stub_waveOutGetDevCapsA(uDeviceID: u32, pwoc: usize, cbwoc: u32) callconv(w32cc.WINAPI) u32 {
    _ = uDeviceID;
    if (trace.enable_tracing) trace.print("WINMM: waveOutGetDevCapsA\n", .{});
    if (pwoc != 0 and cbwoc >= 52) {
        // Fill WAVEOUTCAPS struct
        @memset(@as([*]u8, @ptrFromInt(pwoc))[0..cbwoc], 0);
        // wMid = 1, wPid = 1 (generic)
        @as(*align(1) u16, @ptrFromInt(pwoc)).* = 1;
        @as(*align(1) u16, @ptrFromInt(pwoc + 2)).* = 1;
        // szPname = "Zine Audio"
        const name = "Zine Audio";
        @memcpy(@as([*]u8, @ptrFromInt(pwoc + 8))[0..name.len], name);
        // dwFormats - support common formats
        @as(*align(1) u32, @ptrFromInt(pwoc + 40)).* = 0xFFF; // All standard formats
        // wChannels = 2
        @as(*align(1) u16, @ptrFromInt(pwoc + 44)).* = 2;
        // dwSupport
        @as(*align(1) u32, @ptrFromInt(pwoc + 48)).* = 0x0C; // WAVECAPS_VOLUME | WAVECAPS_LRVOLUME
    }
    return 0;
}

fn stub_waveOutGetID(hwo: u32, puDeviceID: usize) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    if (puDeviceID != 0) {
        @as(*align(1) u32, @ptrFromInt(puDeviceID)).* = 0; // Device ID 0
    }
    return 0;
}

// MMRESULT midiOutOpen(LPHMIDIOUT phmo, UINT uDeviceID, DWORD_PTR dwCallback, DWORD_PTR dwInstance, DWORD fdwOpen)
fn stub_midiOutOpen(phmo: usize, uDeviceID: u32, dwCallback: usize, dwInstance: usize, fdwOpen: u32) callconv(w32cc.WINAPI) u32 {
    _ = uDeviceID; _ = dwCallback; _ = dwInstance; _ = fdwOpen;
    if (phmo != 0) {
        @as(*align(1) u32, @ptrFromInt(phmo)).* = 0xBEEF0050;
    }
    return 0;
}
