const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const renderer = @import("../gui/renderer.zig");
const dsound = @import("dsound.zig");
const platform = @import("../platform.zig");
const w32 = @import("win32_constants.zig");

// waveOut volume: low word = left (0-0xFFFF), high word = right (0-0xFFFF)
var waveout_volume: u32 = 0xFFFFFFFF; // max volume

pub fn register(environment: *env.Environment) !void {
    const builtin_module = "WINMM.dll";
    try environment.addBuiltinExport(builtin_module, "timeGetTime", @intFromPtr(&stub_timeGetTime));
    try environment.addBuiltinExport(builtin_module, "waveOutSetVolume", @intFromPtr(&stub_waveOutSetVolume));
    try environment.addBuiltinExport(builtin_module, "waveOutGetVolume", @intFromPtr(&stub_waveOutGetVolume));
    try environment.addBuiltinExport(builtin_module, "PlaySoundA", @intFromPtr(&stub_PlaySoundA));
    try environment.addBuiltinExport(builtin_module, "timeGetDevCaps", @intFromPtr(&stub_timeGetDevCaps));
    try environment.addBuiltinExport(builtin_module, "timeBeginPeriod", @intFromPtr(&stub_timeBeginPeriod));
    try environment.addBuiltinExport(builtin_module, "timeEndPeriod", @intFromPtr(&stub_timeEndPeriod));
    try environment.addBuiltinExport(builtin_module, "timeSetEvent", @intFromPtr(&stub_timeSetEvent));
    try environment.addBuiltinExport(builtin_module, "timeKillEvent", @intFromPtr(&stub_timeKillEvent));

    // --- Remaining WINMM stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExport(builtin_module, "PlaySoundW", @intFromPtr(&stub_PlaySoundA));
    try environment.addBuiltinExport(builtin_module, "auxGetDevCapsW", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(builtin_module, "mixerGetDevCapsW", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(builtin_module, "waveOutGetNumDevs", @intFromPtr(&kernel32.stub_args0));
    try environment.addBuiltinExport(builtin_module, "waveInGetNumDevs", @intFromPtr(&kernel32.stub_args0));
    try environment.addBuiltinExport(builtin_module, "mixerGetNumDevs", @intFromPtr(&kernel32.stub_args0));
    try environment.addBuiltinExport(builtin_module, "mixerGetControlDetailsW", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(builtin_module, "mixerGetLineControlsW", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(builtin_module, "mixerSetControlDetails", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(builtin_module, "waveOutGetDevCapsW", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(builtin_module, "midiOutGetDevCapsW", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(builtin_module, "midiOutGetNumDevs", @intFromPtr(&kernel32.stub_args0));
    try environment.addBuiltinExport(builtin_module, "mixerOpen", @intFromPtr(&kernel32.stub_args5));
    try environment.addBuiltinExport(builtin_module, "mixerGetID", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(builtin_module, "auxGetNumDevs", @intFromPtr(&kernel32.stub_args0));
    try environment.addBuiltinExport(builtin_module, "waveOutMessage", @intFromPtr(&kernel32.stub_args4));
    try environment.addBuiltinExport(builtin_module, "waveInMessage", @intFromPtr(&kernel32.stub_args4));
    try environment.addBuiltinExport(builtin_module, "mixerClose", @intFromPtr(&kernel32.stub_args1));
    try environment.addBuiltinExport(builtin_module, "mixerGetLineInfoW", @intFromPtr(&kernel32.stub_args3));
    try environment.addBuiltinExport(builtin_module, "mixerMessage", @intFromPtr(&kernel32.stub_args4));

    renderer.on_volume_change = &handleVolumeFromUI;
}

fn handleVolumeFromUI(linear: f32) void {
    // UI slider changed — sync waveOut and DirectSound volume state
    const vol16: u32 = @intFromFloat(std.math.clamp(linear, 0.0, 1.0) * 65535.0);
    waveout_volume = vol16 | (vol16 << 16);

    if (linear <= 0.0001) {
        dsound.dsound_volume = -10000;
    } else {
        const db100: i32 = @intFromFloat(@round(@log10(@as(f64, linear)) * 2000.0));
        dsound.dsound_volume = std.math.clamp(db100, -10000, 0);
    }
    if (trace.enable_tracing) trace.print("WINMM: UI volume -> linear={d:.3}, waveOut=0x{x:0>8}, dsound={d}\n", .{ linear, waveout_volume, dsound.dsound_volume });
}

fn stub_timeGetTime() callconv(.winapi) u32 {
    // Called in tight timing loops; yield to avoid 100% CPU usage.
    platform.yield();

    const ts = std.time.milliTimestamp();
    return @intCast(ts & 0xFFFFFFFF);
}

fn stub_waveOutSetVolume(hwo: u32, dwVolume: u32) callconv(.winapi) u32 {
    _ = hwo;
    waveout_volume = dwVolume;

    // Average left and right channels, convert 0-0xFFFF to 0.0-1.0
    const left: u32 = dwVolume & 0xFFFF;
    const right: u32 = (dwVolume >> 16) & 0xFFFF;
    const avg: f32 = @as(f32, @floatFromInt(left + right)) / (2.0 * 65535.0);

    if (trace.enable_tracing) trace.print("WINMM: waveOutSetVolume(0x{x:0>8}) -> linear={d:.3}\n", .{ dwVolume, avg });

    // Also sync DirectSound volume state (convert linear to hundredths-of-dB)
    if (avg <= 0.0001) {
        dsound.dsound_volume = -10000;
    } else {
        const db100: i32 = @intFromFloat(@round(@log10(@as(f64, avg)) * 2000.0));
        dsound.dsound_volume = std.math.clamp(db100, -10000, 0);
    }

    renderer.setVolume(avg);
    return 0; // MMSYSERR_NOERROR
}

fn stub_waveOutGetVolume(hwo: u32, pdwVolume: usize) callconv(.winapi) u32 {
    _ = hwo;
    if (pdwVolume != 0) {
        @as(*align(1) u32, @ptrFromInt(pdwVolume)).* = waveout_volume;
    }
    if (trace.enable_tracing) trace.print("WINMM: waveOutGetVolume() -> 0x{x:0>8}\n", .{waveout_volume});
    return 0; // MMSYSERR_NOERROR
}

fn stub_PlaySoundA(pszSound: usize, hmod: usize, fdwSound: u32) callconv(.winapi) i32 {
    _ = pszSound;
    _ = hmod;
    _ = fdwSound;
    if (trace.enable_tracing) trace.print("WINMM: PlaySoundA\n", .{});
    return 1;
}

// --- Timer functions for Europa 1400 ---

fn stub_timeGetDevCaps(ptc: usize, cbtc: u32) callconv(.winapi) u32 {
    _ = cbtc;
    if (ptc != 0) {
        const tc = @as(*w32.TIMECAPS, @ptrFromInt(ptc));
        tc.wPeriodMin = 1;       // 1ms
        tc.wPeriodMax = 1000000;
    }
    return 0; // TIMERR_NOERROR
}

fn stub_timeBeginPeriod(uPeriod: u32) callconv(.winapi) u32 {
    _ = uPeriod;
    return 0; // TIMERR_NOERROR
}

fn stub_timeEndPeriod(uPeriod: u32) callconv(.winapi) u32 {
    _ = uPeriod;
    return 0; // TIMERR_NOERROR
}

var timer_id_counter: u32 = 1;

fn stub_timeSetEvent(uDelay: u32, uResolution: u32, fptc: usize, dwUser: usize, fuEvent: u32) callconv(.winapi) u32 {
    _ = uResolution;
    _ = fptc;
    _ = dwUser;
    _ = fuEvent;
    if (trace.enable_tracing) trace.print("WINMM: timeSetEvent(delay={d})\n", .{uDelay});
    const id = timer_id_counter;
    timer_id_counter += 1;
    return id;
}

fn stub_timeKillEvent(uTimerID: u32) callconv(.winapi) u32 {
    _ = uTimerID;
    return 0; // TIMERR_NOERROR
}
