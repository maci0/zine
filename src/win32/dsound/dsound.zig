const std = @import("std");
const env = @import("../../loader/env.zig");
const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const w32 = @import("../../win32_constants.zig");
const w32cc = @import("../../calling_convention.zig");

// --- COM VTables ---
//
// COM vtable structs MUST use u32 fields to match the 32-bit COM ABI.
// On x86_64, usize and function pointers are 8 bytes, which breaks the
// 4-byte-per-slot layout that 32-bit guest code expects when it does
// e.g. CALL [vtable + 0x10].

const IDirectSoundBufferVtbl = extern struct {
    QueryInterface: u32, // 0
    AddRef: u32, // 1
    Release: u32, // 2
    GetCaps: u32, // 3
    GetCurrentPosition: u32, // 4
    GetFormat: u32, // 5
    GetVolume: u32, // 6
    GetPan: u32, // 7
    GetFrequency: u32, // 8
    GetStatus: u32, // 9
    Initialize: u32, // 10
    Lock: u32, // 11
    Play: u32, // 12
    SetCurrentPosition: u32, // 13
    SetFormat: u32, // 14
    SetVolume: u32, // 15
    SetPan: u32, // 16
    SetFrequency: u32, // 17
    Stop: u32, // 18
    Unlock: u32, // 19
    Restore: u32, // 20
};

const IDirectSoundBuffer = extern struct {
    lpVtbl: u32, // guest pointer to vtable (u32 for 32-bit COM)
};

const IDirectSoundVtbl = extern struct {
    QueryInterface: u32, // 0
    AddRef: u32, // 1
    Release: u32, // 2
    CreateSoundBuffer: u32, // 3
    GetCaps: u32, // 4
    DuplicateSoundBuffer: u32, // 5
    SetCooperativeLevel: u32, // 6
    Compact: u32, // 7
    GetSpeakerConfig: u32, // 8
    SetSpeakerConfig: u32, // 9
    Initialize: u32, // 10
};

const IDirectSound = extern struct {
    lpVtbl: u32, // guest pointer to vtable (u32 for 32-bit COM)
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

/// Truncate a host pointer to a 32-bit address for COM vtable entries.
fn ptr32(comptime func: anytype) u32 {
    return @truncate(@intFromPtr(&func));
}

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

fn dsound_GetCaps(this: usize, pDSCaps: usize) callconv(w32cc.WINAPI) i32 {
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

fn dsound_SetCooperativeLevel(this: usize, hwnd: usize, dwLevel: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = hwnd;
    _ = dwLevel;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSound::SetCooperativeLevel\n", .{});
    return 0;
}

fn dsound_CreateSoundBuffer(this: usize, pcDSBufferDesc: usize, ppDSBuffer: usize, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSound::CreateSoundBuffer\n", .{});

    if (pcDSBufferDesc != 0) {
        const desc = @as(*const w32.DSBUFFERDESC, @ptrFromInt(pcDSBufferDesc));
        if (trace.enable_tracing) trace.print("DSOUND:   desc: size={d} flags={x} bytes={d} lpwfxFormat={x}\n", .{ desc.dwSize, desc.dwFlags, desc.dwBufferBytes, desc.lpwfxFormat });

        // DSBCAPS_PRIMARYBUFFER
        if (desc.dwFlags & w32.DSBCAPS_PRIMARYBUFFER != 0) {
            if (trace.enable_tracing) trace.print("DSOUND:   -> primary buffer\n", .{});
            if (ppDSBuffer != 0) {
                @as(*align(1) u32, @ptrFromInt(ppDSBuffer)).* = @truncate(@intFromPtr(&global_dsbuffer_primary));
            }
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

    if (ppDSBuffer != 0) {
        @as(*align(1) u32, @ptrFromInt(ppDSBuffer)).* = @truncate(@intFromPtr(&global_dsbuffer));
    }
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

fn dsbuffer_SetFormat(this: usize, pcfxFormat: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::SetFormat\n", .{});
    if (pcfxFormat != 0) {
        parseWaveFormat(@intCast(pcfxFormat));
        format_sent = false; // re-send format on next unlock
    }
    return 0;
}

fn dsbuffer_GetFormat(this: usize, pwfxFormat: usize, dwSizeAllocated: u32, pdwSizeWritten: usize) callconv(w32cc.WINAPI) i32 {
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

fn dsbuffer_GetCaps(this: usize, pDSBCaps: usize) callconv(w32cc.WINAPI) i32 {
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

fn dsbuffer_Lock(this: usize, dwOffset: u32, dwBytes: u32, ppvAudioPtr1: usize, pdwAudioBytes1: usize, ppvAudioPtr2: usize, pdwAudioBytes2: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
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

    // Write pointer and byte count to guest memory (u32 for 32-bit COM)
    const ptr1 = @as(*align(1) u32, @ptrFromInt(ppvAudioPtr1));
    const bytes1 = @as(*align(1) u32, @ptrFromInt(pdwAudioBytes1));

    if (offset + bytes <= audio_buffer_size) {
        // Single contiguous region
        ptr1.* = @truncate(@intFromPtr(&audio_buffer) + offset);
        bytes1.* = bytes;
        if (ppvAudioPtr2 != 0) {
            @as(*align(1) u32, @ptrFromInt(ppvAudioPtr2)).* = 0;
        }
        if (pdwAudioBytes2 != 0) {
            @as(*align(1) u32, @ptrFromInt(pdwAudioBytes2)).* = 0;
        }
    } else {
        // Wraps around: two regions
        const first_part = audio_buffer_size - offset;
        ptr1.* = @truncate(@intFromPtr(&audio_buffer) + offset);
        bytes1.* = first_part;
        if (ppvAudioPtr2 != 0) {
            @as(*align(1) u32, @ptrFromInt(ppvAudioPtr2)).* = @truncate(@intFromPtr(&audio_buffer));
        }
        if (pdwAudioBytes2 != 0) {
            @as(*align(1) u32, @ptrFromInt(pdwAudioBytes2)).* = bytes - first_part;
        }
    }

    return 0;
}

fn dsbuffer_Unlock(this: usize, pvAudioPtr1: usize, dwAudioBytes1: u32, pvAudioPtr2: usize, dwAudioBytes2: u32) callconv(w32cc.WINAPI) i32 {
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

fn dsbuffer_Play(this: usize, dwReserved1: u32, dwPriority: u32, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
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

fn dsbuffer_Stop(this: usize) callconv(w32cc.WINAPI) i32 {
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

fn dsbuffer_GetCurrentPosition(this: usize, pdwCurrentPlayCursor: usize, pdwCurrentWriteCursor: usize) callconv(w32cc.WINAPI) i32 {
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

fn dsbuffer_GetStatus(this: usize, pdwStatus: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (pdwStatus != 0) {
        @as(*u32, @ptrFromInt(pdwStatus)).* = if (audio_playing) w32.DSBSTATUS_PLAYING | w32.DSBSTATUS_LOOPING else 0;
    }
    return 0;
}

fn dsbuffer_SetCurrentPosition(this: usize, dwNewPosition: u32) callconv(w32cc.WINAPI) i32 {
    _ = this;
    _ = dwNewPosition;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::SetCurrentPosition\n", .{});
    return 0;
}

fn dsbuffer_SetVolume(this: usize, lVolume: i32) callconv(w32cc.WINAPI) i32 {
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

fn dsbuffer_GetVolume(this: usize, plVolume: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    if (plVolume != 0) {
        @as(*align(1) i32, @ptrFromInt(plVolume)).* = dsound_volume;
    }
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::GetVolume() -> {d}\n", .{dsound_volume});
    return 0;
}

// --- Registration ---

pub fn register(environment: *env.Environment) !void {
    const p_dummy: u32 = ptr32(dsound_Dummy);
    const p_dummy2: u32 = ptr32(dsound_Dummy2);
    const p_dummy3: u32 = ptr32(dsound_Dummy3);

    dsound_vtbl = .{
        .QueryInterface = ptr32(dsound_QueryInterface),
        .AddRef = p_dummy,
        .Release = p_dummy,
        .CreateSoundBuffer = ptr32(dsound_CreateSoundBuffer),
        .GetCaps = ptr32(dsound_GetCaps),
        .DuplicateSoundBuffer = p_dummy3,
        .SetCooperativeLevel = ptr32(dsound_SetCooperativeLevel),
        .Compact = p_dummy,
        .GetSpeakerConfig = p_dummy2,
        .SetSpeakerConfig = p_dummy2,
        .Initialize = p_dummy2,
    };

    dsbuffer_vtbl = .{
        .QueryInterface = p_dummy3,
        .AddRef = p_dummy,
        .Release = p_dummy,
        .GetCaps = ptr32(dsbuffer_GetCaps),
        .GetCurrentPosition = ptr32(dsbuffer_GetCurrentPosition),
        .GetFormat = ptr32(dsbuffer_GetFormat),
        .GetVolume = ptr32(dsbuffer_GetVolume),
        .GetPan = p_dummy2,
        .GetFrequency = p_dummy2,
        .GetStatus = ptr32(dsbuffer_GetStatus),
        .Initialize = p_dummy3,
        .Lock = ptr32(dsbuffer_Lock),
        .Play = ptr32(dsbuffer_Play),
        .SetCurrentPosition = ptr32(dsbuffer_SetCurrentPosition),
        .SetFormat = ptr32(dsbuffer_SetFormat),
        .SetVolume = ptr32(dsbuffer_SetVolume),
        .SetPan = p_dummy2,
        .SetFrequency = p_dummy2,
        .Stop = ptr32(dsbuffer_Stop),
        .Unlock = ptr32(dsbuffer_Unlock),
        .Restore = p_dummy,
    };

    global_dsound.lpVtbl = @truncate(@intFromPtr(&dsound_vtbl));
    global_dsbuffer.lpVtbl = @truncate(@intFromPtr(&dsbuffer_vtbl));
    global_dsbuffer_primary.lpVtbl = @truncate(@intFromPtr(&dsbuffer_vtbl));

    const builtin_module = "DSOUND.dll";
    try environment.addBuiltinExportComptime(builtin_module, "ordinal_1", stub_DirectSoundCreate);
    try environment.addBuiltinExportComptime(builtin_module, "DirectSoundCreate", stub_DirectSoundCreate);
    try environment.addBuiltinExportComptime(builtin_module, "DirectSoundEnumerateA", stub_DirectSoundEnumerateA);

    environment.addBuiltinVtableComptime(IDirectSoundVtbl, &dsound_vtbl);
    environment.addBuiltinVtableComptime(IDirectSoundBufferVtbl, &dsbuffer_vtbl);
}

fn stub_DirectSoundCreate(pcGuidDevice: usize, ppDS: usize, pUnkOuter: usize) callconv(w32cc.WINAPI) i32 {
    _ = pcGuidDevice;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DSOUND: DirectSoundCreate(ppDS={x})\n", .{ppDS});
    if (ppDS != 0) {
        @as(*align(1) u32, @ptrFromInt(ppDS)).* = @truncate(@intFromPtr(&global_dsound));
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
