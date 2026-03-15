const std = @import("std");
const env = @import("../../loader/env.zig");
const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

// --- COM VTables ---

const IDirectSoundBufferVtbl = extern struct {
    QueryInterface: usize, // 0
    AddRef: usize, // 1
    Release: usize, // 2
    GetCaps: usize, // 3
    GetCurrentPosition: usize, // 4
    GetFormat: usize, // 5
    GetVolume: usize, // 6
    GetPan: usize, // 7
    GetFrequency: usize, // 8
    GetStatus: usize, // 9
    Initialize: usize, // 10
    Lock: *const fn (*IDirectSoundBuffer, u32, u32, usize, usize, usize, usize, u32) callconv(w32cc.WINAPI) i32, // 11
    Play: *const fn (*IDirectSoundBuffer, u32, u32, u32) callconv(w32cc.WINAPI) i32, // 12
    SetCurrentPosition: usize, // 13
    SetFormat: usize, // 14
    SetVolume: usize, // 15
    SetPan: usize, // 16
    SetFrequency: usize, // 17
    Stop: usize, // 18
    Unlock: *const fn (*IDirectSoundBuffer, usize, u32, usize, u32) callconv(w32cc.WINAPI) i32, // 19
    Restore: usize, // 20
};

const IDirectSoundBuffer = extern struct {
    lpVtbl: *IDirectSoundBufferVtbl,
};

const IDirectSoundVtbl = extern struct {
    QueryInterface: usize, // 0
    AddRef: usize, // 1
    Release: usize, // 2
    CreateSoundBuffer: *const fn (*IDirectSound, usize, *?*IDirectSoundBuffer, usize) callconv(w32cc.WINAPI) i32, // 3
    GetCaps: usize, // 4
    DuplicateSoundBuffer: usize, // 5
    SetCooperativeLevel: *const fn (*IDirectSound, usize, u32) callconv(w32cc.WINAPI) i32, // 6
    Compact: usize, // 7
    GetSpeakerConfig: usize, // 8
    SetSpeakerConfig: usize, // 9
    Initialize: usize, // 10
};

const IDirectSound = extern struct {
    lpVtbl: *IDirectSoundVtbl,
};

// --- Audio State ---

var audio_sample_rate: u32 = 44100;
var audio_channels: u16 = 2;
var audio_bits_per_sample: u16 = 16;
var audio_block_align: u16 = 4;
var audio_bytes_per_sec: u32 = 176400;
var audio_buffer_size: u32 = 65536;
var audio_playing: bool = false;
var audio_play_start_ns: i128 = 0;
var format_sent: bool = false;

// DirectSound volume: hundredths of dB, -10000 (silence) to 0 (full)
pub var dsound_volume: i32 = 0;

var audio_buffer: [262144]u8 = [_]u8{0} ** 262144;
var play_cursor: u32 = 0;

// --- COM Instances ---

var global_dsound: IDirectSound = undefined;
var global_dsbuffer: IDirectSoundBuffer = undefined;
var global_dsbuffer_primary: IDirectSoundBuffer = undefined;
var dsound_vtbl: IDirectSoundVtbl = undefined;
var dsbuffer_vtbl: IDirectSoundBufferVtbl = undefined;

// --- IDirectSound Implementation ---

fn dsound_Dummy(this: *anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DSOUND: DummyStub1\n", .{});
    return 0;
}

fn dsound_Dummy2(a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    if (trace.enable_tracing) trace.print("DSOUND: DummyStub2\n", .{});
    return 0;
}

fn dsound_Dummy3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    _ = c;
    if (trace.enable_tracing) trace.print("DSOUND: DummyStub3\n", .{});
    return 0;
}

fn dsound_Dummy4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    if (trace.enable_tracing) trace.print("DSOUND: DummyStub4\n", .{});
    return 0;
}

fn dsound_QueryInterface(this: *anyopaque, riid: usize, ppvObj: *?*anyopaque) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = riid;
    ppvObj.* = @ptrCast(&global_dsound);
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSound::QueryInterface\n", .{});
    return 0; // S_OK
}

fn dsound_GetCaps(this: *IDirectSound, pDSCaps: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSound::GetCaps(pDSCaps={x})\n", .{pDSCaps});
    if (pDSCaps != 0) {
        // DSCAPS structure (96 bytes)
        const caps = @as([*]u8, @ptrFromInt(pDSCaps));
        const declared_size = @as(*u32, @ptrFromInt(pDSCaps)).*;
        @memset(caps[0..@min(declared_size, 96)], 0);

        // dwSize
        @as(*u32, @ptrFromInt(pDSCaps + 0)).* = @min(declared_size, 96);
        // dwFlags: DSCAPS_PRIMARYMONO | DSCAPS_PRIMARYSTEREO | DSCAPS_PRIMARY8BIT | DSCAPS_PRIMARY16BIT |
        //          DSCAPS_SECONDARYMONO | DSCAPS_SECONDARYSTEREO | DSCAPS_SECONDARY8BIT | DSCAPS_SECONDARY16BIT
        @as(*u32, @ptrFromInt(pDSCaps + 4)).* = 0x00000FF0;
        // dwMinSecondarySampleRate
        @as(*u32, @ptrFromInt(pDSCaps + 8)).* = 100;
        // dwMaxSecondarySampleRate
        @as(*u32, @ptrFromInt(pDSCaps + 12)).* = 200000;
        // dwPrimaryBuffers
        @as(*u32, @ptrFromInt(pDSCaps + 16)).* = 1;
        // dwMaxHwMixingAllBuffers
        @as(*u32, @ptrFromInt(pDSCaps + 20)).* = 32;
        // dwMaxHwMixingStaticBuffers
        @as(*u32, @ptrFromInt(pDSCaps + 24)).* = 32;
        // dwMaxHwMixingStreamingBuffers
        @as(*u32, @ptrFromInt(pDSCaps + 28)).* = 32;
        // dwFreeHwMixingAllBuffers = same as max
        @as(*u32, @ptrFromInt(pDSCaps + 32)).* = 32;
        @as(*u32, @ptrFromInt(pDSCaps + 36)).* = 32;
        @as(*u32, @ptrFromInt(pDSCaps + 40)).* = 32;
        // dwTotalHwMemBytes
        @as(*u32, @ptrFromInt(pDSCaps + 56)).* = 16 * 1024 * 1024;
        // dwFreeHwMemBytes
        @as(*u32, @ptrFromInt(pDSCaps + 60)).* = 16 * 1024 * 1024;
    }
    return 0;
}

fn dsound_SetCooperativeLevel(this: *IDirectSound, hwnd: usize, dwLevel: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = hwnd;
    _ = dwLevel;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSound::SetCooperativeLevel\n", .{});
    return 0;
}

fn dsound_CreateSoundBuffer(this: *IDirectSound, pcDSBufferDesc: usize, ppDSBuffer: *?*IDirectSoundBuffer, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSound::CreateSoundBuffer\n", .{});

    if (pcDSBufferDesc != 0) {
        const desc = @as(*const w32.DSBUFFERDESC, @ptrFromInt(pcDSBufferDesc));
        if (trace.enable_tracing) trace.print("DSOUND:   desc: size={d} flags={x} bytes={d} lpwfxFormat={x}\n", .{ desc.dwSize, desc.dwFlags, desc.dwBufferBytes, desc.lpwfxFormat });

        // DSBCAPS_PRIMARYBUFFER
        if (desc.dwFlags & w32.DSBCAPS_PRIMARYBUFFER != 0) {
            if (trace.enable_tracing) trace.print("DSOUND:   -> primary buffer\n", .{});
            ppDSBuffer.* = &global_dsbuffer_primary;
            return 0;
        }

        // Secondary buffer: capture format and buffer size
        if (desc.dwBufferBytes > 0) {
            audio_buffer_size = @min(desc.dwBufferBytes, @as(u32, @intCast(audio_buffer.len)));
            if (trace.enable_tracing) trace.print("DSOUND:   -> secondary buffer, size={d}\n", .{audio_buffer_size});
        }

        if (desc.lpwfxFormat != 0) {
            parseWaveFormat(desc.lpwfxFormat);
        }
    }

    ppDSBuffer.* = &global_dsbuffer;
    return 0;
}

fn parseWaveFormat(fmt_addr: u32) void {
    if (fmt_addr == 0) return;
    const fmt = @as(*const w32.WAVEFORMATEX, @ptrFromInt(fmt_addr));

    // Validate format before applying
    if (fmt.nChannels == 0 or fmt.nChannels > 8 or
        fmt.nSamplesPerSec == 0 or fmt.nSamplesPerSec > 200000 or
        (fmt.wBitsPerSample != 8 and fmt.wBitsPerSample != 16 and
        fmt.wBitsPerSample != 24 and fmt.wBitsPerSample != 32))
    {
        if (trace.enable_tracing) trace.print("DSOUND:   format INVALID: {d}Hz {d}ch {d}bit — skipping\n", .{ fmt.nSamplesPerSec, fmt.nChannels, fmt.wBitsPerSample });
        return;
    }

    audio_channels = fmt.nChannels;
    audio_sample_rate = fmt.nSamplesPerSec;
    audio_bytes_per_sec = fmt.nAvgBytesPerSec;
    audio_block_align = fmt.nBlockAlign;
    audio_bits_per_sample = fmt.wBitsPerSample;

    if (trace.enable_tracing) trace.print("DSOUND:   format: {d}Hz {d}ch {d}bit (block={d}, bps={d})\n", .{ audio_sample_rate, audio_channels, audio_bits_per_sample, audio_block_align, audio_bytes_per_sec });
}

// --- IDirectSoundBuffer Implementation ---

fn dsbuffer_SetFormat(this: *IDirectSoundBuffer, pcfxFormat: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::SetFormat\n", .{});
    if (pcfxFormat != 0) {
        parseWaveFormat(@intCast(pcfxFormat));
        format_sent = false; // re-send format on next unlock
    }
    return 0;
}

fn dsbuffer_GetFormat(this: *IDirectSoundBuffer, pwfxFormat: usize, dwSizeAllocated: u32, pdwSizeWritten: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::GetFormat(buf={x}, size={d})\n", .{ pwfxFormat, dwSizeAllocated });

    // WAVEFORMATEX is 18 bytes in Win32 (no padding), not @sizeOf which adds alignment
    const wfx_size: u32 = 18;

    if (pdwSizeWritten != 0) {
        @as(*u32, @ptrFromInt(pdwSizeWritten)).* = wfx_size;
    }

    if (pwfxFormat != 0 and dwSizeAllocated >= wfx_size) {
        const fmt = @as(*w32.WAVEFORMATEX, @ptrFromInt(pwfxFormat));
        fmt.wFormatTag = 1; // WAVE_FORMAT_PCM
        fmt.nChannels = audio_channels;
        fmt.nSamplesPerSec = audio_sample_rate;
        fmt.nAvgBytesPerSec = audio_bytes_per_sec;
        fmt.nBlockAlign = audio_block_align;
        fmt.wBitsPerSample = audio_bits_per_sample;
        fmt.cbSize = 0;
    }

    return 0;
}

fn dsbuffer_GetCaps(this: *IDirectSoundBuffer, pDSBCaps: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::GetCaps(pDSBCaps={x})\n", .{pDSBCaps});
    if (pDSBCaps != 0) {
        // DSBCAPS structure:
        // DWORD dwSize;       // 0
        // DWORD dwFlags;      // 4
        // DWORD dwBufferBytes; // 8
        // DWORD dwUnlockTransferRate; // 12
        // DWORD dwPlayCpuOverhead;    // 16
        const caps = @as([*]u8, @ptrFromInt(pDSBCaps));
        const size = @as(*u32, @ptrFromInt(pDSBCaps));
        // Zero out the struct first
        @memset(caps[0..@min(size.*, 20)], 0);
        // Fill key fields
        size.* = 20; // dwSize
        @as(*u32, @ptrFromInt(pDSBCaps + 4)).* = 0x000180E0; // dwFlags
        @as(*u32, @ptrFromInt(pDSBCaps + 8)).* = audio_buffer_size; // dwBufferBytes
    }
    return 0;
}

fn dsbuffer_Lock(this: *IDirectSoundBuffer, dwOffset: u32, dwBytes: u32, ppvAudioPtr1: usize, pdwAudioBytes1: usize, ppvAudioPtr2: usize, pdwAudioBytes2: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::Lock(off={d}, bytes={d}, flags={x})\n", .{ dwOffset, dwBytes, dwFlags });

    var offset = dwOffset;
    var bytes = dwBytes;

    // DSBLOCK_FROMWRITECURSOR
    if (dwFlags & w32.DSBLOCK_FROMWRITECURSOR != 0) {
        offset = getWriteCursor();
    }
    // DSBLOCK_ENTIREBUFFER
    if (dwFlags & w32.DSBLOCK_ENTIREBUFFER != 0) {
        offset = 0;
        bytes = audio_buffer_size;
    }

    // Clamp to buffer size
    if (offset >= audio_buffer_size) offset = 0;
    if (bytes > audio_buffer_size) bytes = audio_buffer_size;

    const ptr1 = @as(*usize, @ptrFromInt(ppvAudioPtr1));
    const bytes1 = @as(*u32, @ptrFromInt(pdwAudioBytes1));

    if (offset + bytes <= audio_buffer_size) {
        // Single contiguous region
        ptr1.* = @intFromPtr(&audio_buffer) + offset;
        bytes1.* = bytes;
        if (ppvAudioPtr2 != 0) {
            @as(*usize, @ptrFromInt(ppvAudioPtr2)).* = 0;
        }
        if (pdwAudioBytes2 != 0) {
            @as(*u32, @ptrFromInt(pdwAudioBytes2)).* = 0;
        }
    } else {
        // Wraps around: two regions
        const first_part = audio_buffer_size - offset;
        ptr1.* = @intFromPtr(&audio_buffer) + offset;
        bytes1.* = first_part;
        if (ppvAudioPtr2 != 0) {
            @as(*usize, @ptrFromInt(ppvAudioPtr2)).* = @intFromPtr(&audio_buffer);
        }
        if (pdwAudioBytes2 != 0) {
            @as(*u32, @ptrFromInt(pdwAudioBytes2)).* = bytes - first_part;
        }
    }

    return 0;
}

fn dsbuffer_Unlock(this: *IDirectSoundBuffer, pvAudioPtr1: usize, dwAudioBytes1: u32, pvAudioPtr2: usize, dwAudioBytes2: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::Unlock(bytes1={d}, bytes2={d})\n", .{ dwAudioBytes1, dwAudioBytes2 });

    if (!format_sent) {
        renderer.setAudioFormat(audio_sample_rate, audio_channels, audio_bits_per_sample);
        format_sent = true;
    }

    // Stream captured audio to renderer
    if (dwAudioBytes1 > 0 and pvAudioPtr1 != 0) {
        const data = @as([*]const u8, @ptrFromInt(pvAudioPtr1))[0..dwAudioBytes1];
        renderer.pushAudio(data);
    }
    if (dwAudioBytes2 > 0 and pvAudioPtr2 != 0) {
        const data = @as([*]const u8, @ptrFromInt(pvAudioPtr2))[0..dwAudioBytes2];
        renderer.pushAudio(data);
    }

    return 0;
}

fn dsbuffer_Play(this: *IDirectSoundBuffer, dwReserved1: u32, dwPriority: u32, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = dwReserved1;
    _ = dwPriority;
    _ = dwFlags;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::Play\n", .{});
    audio_playing = true;
    audio_play_start_ns = std.time.nanoTimestamp();

    if (!format_sent) {
        renderer.setAudioFormat(audio_sample_rate, audio_channels, audio_bits_per_sample);
        format_sent = true;
    }
    return 0;
}

fn dsbuffer_Stop(this: *IDirectSoundBuffer) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::Stop\n", .{});
    audio_playing = false;
    return 0;
}

fn getPlayCursor() u32 {
    if (!audio_playing or audio_bytes_per_sec == 0) return play_cursor;
    const now: i128 = std.time.nanoTimestamp();
    const elapsed = now - audio_play_start_ns;
    if (elapsed <= 0) return play_cursor;
    const elapsed_u: u128 = @intCast(elapsed);
    const bytes: u128 = (elapsed_u * audio_bytes_per_sec) / 1_000_000_000;
    play_cursor = @intCast(bytes % audio_buffer_size);
    return play_cursor;
}

fn getWriteCursor() u32 {
    const play = getPlayCursor();
    // Write cursor leads play cursor by ~15ms worth of data
    const lead = @as(u32, audio_block_align) * 256;
    return (play + lead) % audio_buffer_size;
}

fn dsbuffer_GetCurrentPosition(this: *IDirectSoundBuffer, pdwCurrentPlayCursor: usize, pdwCurrentWriteCursor: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;

    const pc = getPlayCursor();
    const wc = getWriteCursor();

    if (pdwCurrentPlayCursor != 0) {
        @as(*align(1) u32, @ptrFromInt(pdwCurrentPlayCursor)).* = pc;
    }
    if (pdwCurrentWriteCursor != 0) {
        @as(*align(1) u32, @ptrFromInt(pdwCurrentWriteCursor)).* = wc;
    }

    return 0;
}

fn dsbuffer_GetStatus(this: *IDirectSoundBuffer, pdwStatus: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (pdwStatus != 0) {
        @as(*u32, @ptrFromInt(pdwStatus)).* = if (audio_playing) w32.DSBSTATUS_PLAYING | w32.DSBSTATUS_LOOPING else 0;
    }
    return 0;
}

fn dsbuffer_SetCurrentPosition(this: *IDirectSoundBuffer, dwNewPosition: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = dwNewPosition;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::SetCurrentPosition\n", .{});
    return 0;
}

fn dsbuffer_SetVolume(this: *IDirectSoundBuffer, lVolume: i32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    // lVolume: hundredths of dB, DSBVOLUME_MIN (-10000) to DSBVOLUME_MAX (0)
    dsound_volume = std.math.clamp(lVolume, w32.DSBVOLUME_MIN, w32.DSBVOLUME_MAX);
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::SetVolume({d})\n", .{dsound_volume});

    // Convert hundredths-of-dB to linear: 10^(vol/2000)
    const vol_f: f64 = @floatFromInt(dsound_volume);
    const linear = std.math.pow(f64, 10.0, vol_f / 2000.0);
    renderer.setVolume(@floatCast(linear));
    return 0;
}

fn dsbuffer_GetVolume(this: *IDirectSoundBuffer, plVolume: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (plVolume != 0) {
        @as(*align(1) i32, @ptrFromInt(plVolume)).* = dsound_volume;
    }
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::GetVolume() -> {d}\n", .{dsound_volume});
    return 0;
}

// --- Registration ---

pub fn register(environment: *env.Environment) !void {
    const p_dummy = @intFromPtr(&dsound_Dummy);
    const p_dummy2 = @intFromPtr(&dsound_Dummy2);
    const p_dummy3 = @intFromPtr(&dsound_Dummy3);

    dsound_vtbl = .{
        .QueryInterface = @intFromPtr(&dsound_QueryInterface), // this,riid,ppv (3 args)
        .AddRef = p_dummy,            // this (1 arg)
        .Release = p_dummy,           // this (1 arg)
        .CreateSoundBuffer = dsound_CreateSoundBuffer,  // 4 args
        .GetCaps = @intFromPtr(&dsound_GetCaps),  // this,pDSCaps (2 args)
        .DuplicateSoundBuffer = p_dummy3, // this,src,dst (3 args)
        .SetCooperativeLevel = dsound_SetCooperativeLevel, // 3 args
        .Compact = p_dummy,           // this (1 arg)
        .GetSpeakerConfig = p_dummy2, // this,pdwSpeakerConfig (2 args)
        .SetSpeakerConfig = p_dummy2, // this,dwSpeakerConfig (2 args)
        .Initialize = p_dummy2,       // this,pcGuidDevice (2 args)
    };

    dsbuffer_vtbl = .{
        .QueryInterface = p_dummy3,    // this,riid,ppv (3 args)
        .AddRef = p_dummy,             // this (1 arg)
        .Release = p_dummy,            // this (1 arg)
        .GetCaps = @intFromPtr(&dsbuffer_GetCaps),  // this,pDSBCaps (2 args)
        .GetCurrentPosition = @intFromPtr(&dsbuffer_GetCurrentPosition),
        .GetFormat = @intFromPtr(&dsbuffer_GetFormat), // this,pwfxFormat,dwSizeAllocated,pdwSizeWritten (4 args)
        .GetVolume = @intFromPtr(&dsbuffer_GetVolume),
        .GetPan = p_dummy2,            // this,plPan (2 args)
        .GetFrequency = p_dummy2,      // this,pdwFrequency (2 args)
        .GetStatus = @intFromPtr(&dsbuffer_GetStatus),
        .Initialize = p_dummy3,        // this,pDirectSound,pcDSBufferDesc (3 args)
        .Lock = dsbuffer_Lock,
        .Play = dsbuffer_Play,
        .SetCurrentPosition = @intFromPtr(&dsbuffer_SetCurrentPosition),
        .SetFormat = @intFromPtr(&dsbuffer_SetFormat),
        .SetVolume = @intFromPtr(&dsbuffer_SetVolume),
        .SetPan = p_dummy2,            // this,lPan (2 args)
        .SetFrequency = p_dummy2,      // this,dwFrequency (2 args)
        .Stop = @intFromPtr(&dsbuffer_Stop),
        .Unlock = dsbuffer_Unlock,
        .Restore = p_dummy,            // this (1 arg)
    };

    global_dsound.lpVtbl = &dsound_vtbl;
    global_dsbuffer.lpVtbl = &dsbuffer_vtbl;
    global_dsbuffer_primary.lpVtbl = &dsbuffer_vtbl;

    const builtin_module = "DSOUND.dll";
    try environment.addBuiltinExportComptime(builtin_module, "ordinal_1", stub_DirectSoundCreate);
    try environment.addBuiltinExportComptime(builtin_module, "DirectSoundCreate", stub_DirectSoundCreate);
    try environment.addBuiltinExportComptime(builtin_module, "DirectSoundEnumerateA", stub_DirectSoundEnumerateA);
    
    environment.addBuiltinVtableComptime(IDirectSoundVtbl, &dsound_vtbl);
    environment.addBuiltinVtableComptime(IDirectSoundBufferVtbl, &dsbuffer_vtbl);
}

fn stub_DirectSoundCreate(pcGuidDevice: usize, ppDS: *?*IDirectSound, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = pcGuidDevice;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DSOUND: DirectSoundCreate(ppDS={x} global_dsound={x} vtbl={x})\n", .{ @intFromPtr(ppDS), @intFromPtr(&global_dsound), @intFromPtr(global_dsound.lpVtbl) });
    ppDS.* = &global_dsound;
    if (trace.enable_tracing) {
        const readback = ppDS.*;
        trace.print("DSOUND:   ppDS now = {x} (expected {x})\n", .{ @intFromPtr(readback), @intFromPtr(&global_dsound) });
    }
    return 0;
}

fn stub_DirectSoundEnumerateA(lpDSEnumCallback: usize, lpContext: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DSOUND: DirectSoundEnumerateA()\n", .{});
    if (lpDSEnumCallback != 0) {
        // Call the callback with NULL GUID (default device)
        const cb = @as(*const fn (usize, usize, usize, usize) callconv(w32cc.WINAPI) i32, @ptrFromInt(lpDSEnumCallback));
        _ = cb(0, @intFromPtr("Primary Sound Driver"), @intFromPtr(""), lpContext);
    }
    return 0;
}
