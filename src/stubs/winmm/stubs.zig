const std = @import("std");
const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const dsound_stubs = @import("../dsound/stubs.zig");
const platform = @import("../../platform.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");
const winmm = @import("../winmm.zig");


pub fn stub_timeGetTime() callconv(w32cc.WINAPI) u32 {
    // Called in tight timing loops; yield to avoid 100% CPU usage.
    platform.yield();

    const ts = std.time.milliTimestamp();
    return @intCast(ts & 0xFFFFFFFF);
}

pub fn stub_waveOutSetVolume(hwo: u32, dwVolume: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    winmm.waveout_volume = dwVolume;

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

pub fn stub_waveOutGetVolume(hwo: u32, pdwVolume: usize) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    if (pdwVolume != 0) {
        @as(*align(1) u32, @ptrFromInt(pdwVolume)).* = winmm.waveout_volume;
    }
    if (trace.enable_tracing) trace.print("WINMM: waveOutGetVolume() -> 0x{x:0>8}\n", .{winmm.waveout_volume});
    return 0; // MMSYSERR_NOERROR
}

pub fn stub_PlaySoundA(pszSound: usize, hmod: usize, fdwSound: u32) callconv(w32cc.WINAPI) i32 {
    _ = pszSound;
    _ = hmod;
    _ = fdwSound;
    if (trace.enable_tracing) trace.print("WINMM: PlaySoundA\n", .{});
    return 1;
}

// --- Timer functions for Europa 1400 ---

pub fn stub_timeGetDevCaps(ptc: usize, cbtc: u32) callconv(w32cc.WINAPI) u32 {
    _ = cbtc;
    if (ptc != 0) {
        const tc = @as(*w32.TIMECAPS, @ptrFromInt(ptc));
        tc.wPeriodMin = 1;       // 1ms
        tc.wPeriodMax = 1000000;
    }
    return 0; // TIMERR_NOERROR
}

pub fn stub_timeBeginPeriod(uPeriod: u32) callconv(w32cc.WINAPI) u32 {
    _ = uPeriod;
    return 0; // TIMERR_NOERROR
}

pub fn stub_timeEndPeriod(uPeriod: u32) callconv(w32cc.WINAPI) u32 {
    _ = uPeriod;
    return 0; // TIMERR_NOERROR
}

var timer_id_counter: u32 = 1;

pub fn stub_timeSetEvent(uDelay: u32, uResolution: u32, fptc: usize, dwUser: usize, fuEvent: u32) callconv(w32cc.WINAPI) u32 {
    _ = uResolution;
    _ = fptc;
    _ = dwUser;
    _ = fuEvent;
    if (trace.enable_tracing) trace.print("WINMM: timeSetEvent(delay={d})\n", .{uDelay});
    const id = timer_id_counter;
    timer_id_counter += 1;
    return id;
}

pub fn stub_timeKillEvent(uTimerID: u32) callconv(w32cc.WINAPI) u32 {
    _ = uTimerID;
    return 0; // TIMERR_NOERROR
}

// --- waveOut stubs for MSS32.DLL ---

pub fn stub_waveOutGetNumDevs() callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("WINMM: waveOutGetNumDevs -> 1\n", .{});
    return 1; // One audio device available
}

// MMRESULT waveOutOpen(LPHWAVEOUT phwo, UINT uDeviceID, LPCWAVEFORMATEX pwfx, DWORD_PTR dwCallback, DWORD_PTR dwInstance, DWORD fdwOpen)
pub fn stub_waveOutOpen(phwo: usize, uDeviceID: u32, pwfx: usize, dwCallback: usize, dwInstance: usize, fdwOpen: u32) callconv(w32cc.WINAPI) u32 {
    _ = uDeviceID; _ = pwfx; _ = dwCallback; _ = dwInstance; _ = fdwOpen;
    if (trace.enable_tracing) trace.print("WINMM: waveOutOpen\n", .{});
    // Write a fake handle to *phwo
    if (phwo != 0) {
        @as(*align(1) u32, @ptrFromInt(phwo)).* = 0xBEEF0040;
    }
    return 0; // MMSYSERR_NOERROR
}

pub fn stub_waveOutClose_(hwo: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    if (trace.enable_tracing) trace.print("WINMM: waveOutClose\n", .{});
    return 0; // MMSYSERR_NOERROR
}

pub fn stub_waveOutReset(hwo: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    return 0;
}

// MMRESULT waveOutWrite(HWAVEOUT hwo, LPWAVEHDR pwh, UINT cbwh)
pub fn stub_waveOutWrite(hwo: u32, pwh: usize, cbwh: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo; _ = cbwh;
    // Mark the buffer as done immediately (set WHDR_DONE flag = 0x1)
    if (pwh != 0) {
        const flags_ptr = @as(*align(1) u32, @ptrFromInt(pwh + 16)); // dwFlags offset in WAVEHDR
        flags_ptr.* |= 0x1; // WHDR_DONE
    }
    return 0;
}

// MMRESULT waveOutPrepareHeader(HWAVEOUT hwo, LPWAVEHDR pwh, UINT cbwh)
pub fn stub_waveOutPrepareHeader(hwo: u32, pwh: usize, cbwh: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo; _ = cbwh;
    // Set WHDR_PREPARED flag
    if (pwh != 0) {
        const flags_ptr = @as(*align(1) u32, @ptrFromInt(pwh + 16));
        flags_ptr.* |= 0x2; // WHDR_PREPARED
    }
    return 0;
}

pub fn stub_waveOutUnprepareHeader(hwo: u32, pwh: usize, cbwh: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo; _ = cbwh;
    if (pwh != 0) {
        const flags_ptr = @as(*align(1) u32, @ptrFromInt(pwh + 16));
        flags_ptr.* &= ~@as(u32, 0x2); // Clear WHDR_PREPARED
    }
    return 0;
}

// MMRESULT waveOutGetDevCapsA(UINT uDeviceID, LPWAVEOUTCAPS pwoc, UINT cbwoc)
pub fn stub_waveOutGetDevCapsA(uDeviceID: u32, pwoc: usize, cbwoc: u32) callconv(w32cc.WINAPI) u32 {
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

pub fn stub_waveOutGetID(hwo: u32, puDeviceID: usize) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    if (puDeviceID != 0) {
        @as(*align(1) u32, @ptrFromInt(puDeviceID)).* = 0; // Device ID 0
    }
    return 0;
}

// MMRESULT midiOutOpen(LPHMIDIOUT phmo, UINT uDeviceID, DWORD_PTR dwCallback, DWORD_PTR dwInstance, DWORD fdwOpen)
pub fn stub_midiOutOpen(phmo: usize, uDeviceID: u32, dwCallback: usize, dwInstance: usize, fdwOpen: u32) callconv(w32cc.WINAPI) u32 {
    _ = uDeviceID; _ = dwCallback; _ = dwInstance; _ = fdwOpen;
    if (phmo != 0) {
        @as(*align(1) u32, @ptrFromInt(phmo)).* = 0xBEEF0050;
    }
    return 0;
}
