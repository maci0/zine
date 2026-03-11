const std = @import("std");
const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const renderer = @import("../gui/renderer.zig");
const w32 = @import("win32_constants.zig");

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
    Lock: *const fn (*IDirectSoundBuffer, u32, u32, usize, usize, usize, usize, u32) callconv(.winapi) i32, // 11
    Play: *const fn (*IDirectSoundBuffer, u32, u32, u32) callconv(.winapi) i32, // 12
    SetCurrentPosition: usize, // 13
    SetFormat: usize, // 14
    SetVolume: usize, // 15
    SetPan: usize, // 16
    SetFrequency: usize, // 17
    Stop: usize, // 18
    Unlock: *const fn (*IDirectSoundBuffer, usize, u32, usize, u32) callconv(.winapi) i32, // 19
    Restore: usize, // 20
};

const IDirectSoundBuffer = extern struct {
    lpVtbl: *IDirectSoundBufferVtbl,
};

const IDirectSoundVtbl = extern struct {
    QueryInterface: usize, // 0
    AddRef: usize, // 1
    Release: usize, // 2
    CreateSoundBuffer: *const fn (*IDirectSound, usize, *?*IDirectSoundBuffer, usize) callconv(.winapi) i32, // 3
    GetCaps: usize, // 4
    DuplicateSoundBuffer: usize, // 5
    SetCooperativeLevel: *const fn (*IDirectSound, usize, u32) callconv(.winapi) i32, // 6
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

fn dsound_Dummy(this: *anyopaque) callconv(.winapi) i32 {
    _ = this;
    return 0;
}

fn dsound_SetCooperativeLevel(this: *IDirectSound, hwnd: usize, dwLevel: u32) callconv(.winapi) i32 {
    _ = this;
    _ = hwnd;
    _ = dwLevel;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSound::SetCooperativeLevel\n", .{});
    return 0;
}

fn dsound_CreateSoundBuffer(this: *IDirectSound, pcDSBufferDesc: usize, ppDSBuffer: *?*IDirectSoundBuffer, pUnkOuter: usize) callconv(.winapi) i32 {
    _ = this;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSound::CreateSoundBuffer\n", .{});

    if (pcDSBufferDesc != 0) {
        const desc = @as(*const w32.DSBUFFERDESC, @ptrFromInt(pcDSBufferDesc));

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
    const fmt = @as(*const w32.WAVEFORMATEX, @ptrFromInt(fmt_addr));
    audio_channels = fmt.nChannels;
    audio_sample_rate = fmt.nSamplesPerSec;
    audio_bytes_per_sec = fmt.nAvgBytesPerSec;
    audio_block_align = fmt.nBlockAlign;
    audio_bits_per_sample = fmt.wBitsPerSample;

    if (trace.enable_tracing) trace.print("DSOUND:   format: {d}Hz {d}ch {d}bit (block={d}, bps={d})\n", .{ audio_sample_rate, audio_channels, audio_bits_per_sample, audio_block_align, audio_bytes_per_sec });
}

// --- IDirectSoundBuffer Implementation ---

fn dsbuffer_SetFormat(this: *IDirectSoundBuffer, pcfxFormat: usize) callconv(.winapi) i32 {
    _ = this;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::SetFormat\n", .{});
    if (pcfxFormat != 0) {
        parseWaveFormat(@intCast(pcfxFormat));
        format_sent = false; // re-send format on next unlock
    }
    return 0;
}

fn dsbuffer_Lock(this: *IDirectSoundBuffer, dwOffset: u32, dwBytes: u32, ppvAudioPtr1: usize, pdwAudioBytes1: usize, ppvAudioPtr2: usize, pdwAudioBytes2: usize, dwFlags: u32) callconv(.winapi) i32 {
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

fn dsbuffer_Unlock(this: *IDirectSoundBuffer, pvAudioPtr1: usize, dwAudioBytes1: u32, pvAudioPtr2: usize, dwAudioBytes2: u32) callconv(.winapi) i32 {
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

fn dsbuffer_Play(this: *IDirectSoundBuffer, dwReserved1: u32, dwPriority: u32, dwFlags: u32) callconv(.winapi) i32 {
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

fn dsbuffer_Stop(this: *IDirectSoundBuffer) callconv(.winapi) i32 {
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

fn dsbuffer_GetCurrentPosition(this: *IDirectSoundBuffer, pdwCurrentPlayCursor: usize, pdwCurrentWriteCursor: usize) callconv(.winapi) i32 {
    _ = this;

    const pc = getPlayCursor();
    const wc = getWriteCursor();

    if (pdwCurrentPlayCursor != 0) {
        @as(*u32, @ptrFromInt(pdwCurrentPlayCursor)).* = pc;
    }
    if (pdwCurrentWriteCursor != 0) {
        @as(*u32, @ptrFromInt(pdwCurrentWriteCursor)).* = wc;
    }

    return 0;
}

fn dsbuffer_GetStatus(this: *IDirectSoundBuffer, pdwStatus: usize) callconv(.winapi) i32 {
    _ = this;
    if (pdwStatus != 0) {
        @as(*u32, @ptrFromInt(pdwStatus)).* = if (audio_playing) w32.DSBSTATUS_PLAYING | w32.DSBSTATUS_LOOPING else 0;
    }
    return 0;
}

fn dsbuffer_SetCurrentPosition(this: *IDirectSoundBuffer, dwNewPosition: u32) callconv(.winapi) i32 {
    _ = this;
    _ = dwNewPosition;
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::SetCurrentPosition\n", .{});
    return 0;
}

fn dsbuffer_SetVolume(this: *IDirectSoundBuffer, lVolume: i32) callconv(.winapi) i32 {
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

fn dsbuffer_GetVolume(this: *IDirectSoundBuffer, plVolume: usize) callconv(.winapi) i32 {
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

    dsound_vtbl = .{
        .QueryInterface = p_dummy,
        .AddRef = p_dummy,
        .Release = p_dummy,
        .CreateSoundBuffer = dsound_CreateSoundBuffer,
        .GetCaps = p_dummy,
        .DuplicateSoundBuffer = p_dummy,
        .SetCooperativeLevel = dsound_SetCooperativeLevel,
        .Compact = p_dummy,
        .GetSpeakerConfig = p_dummy,
        .SetSpeakerConfig = p_dummy,
        .Initialize = p_dummy,
    };

    dsbuffer_vtbl = .{
        .QueryInterface = p_dummy,
        .AddRef = p_dummy,
        .Release = p_dummy,
        .GetCaps = p_dummy,
        .GetCurrentPosition = @intFromPtr(&dsbuffer_GetCurrentPosition),
        .GetFormat = p_dummy,
        .GetVolume = @intFromPtr(&dsbuffer_GetVolume),
        .GetPan = p_dummy,
        .GetFrequency = p_dummy,
        .GetStatus = @intFromPtr(&dsbuffer_GetStatus),
        .Initialize = p_dummy,
        .Lock = dsbuffer_Lock,
        .Play = dsbuffer_Play,
        .SetCurrentPosition = @intFromPtr(&dsbuffer_SetCurrentPosition),
        .SetFormat = @intFromPtr(&dsbuffer_SetFormat),
        .SetVolume = @intFromPtr(&dsbuffer_SetVolume),
        .SetPan = p_dummy,
        .SetFrequency = p_dummy,
        .Stop = @intFromPtr(&dsbuffer_Stop),
        .Unlock = dsbuffer_Unlock,
        .Restore = p_dummy,
    };

    global_dsound.lpVtbl = &dsound_vtbl;
    global_dsbuffer.lpVtbl = &dsbuffer_vtbl;
    global_dsbuffer_primary.lpVtbl = &dsbuffer_vtbl;

    const builtin_module = "DSOUND.dll";
    try environment.addBuiltinExport(builtin_module, "ordinal_1", @intFromPtr(&stub_DirectSoundCreate));
}

fn stub_DirectSoundCreate(pcGuidDevice: usize, ppDS: *?*IDirectSound, pUnkOuter: usize) callconv(.winapi) i32 {
    _ = pcGuidDevice;
    _ = pUnkOuter;
    if (trace.enable_tracing) trace.print("DSOUND: DirectSoundCreate()\n", .{});
    ppDS.* = &global_dsound;
    return 0;
}
