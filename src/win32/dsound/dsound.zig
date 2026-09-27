//! DirectSound implementation.
const std = @import("std");
const runtime = @import("../../runtime.zig");
const env = @import("../../loader/env.zig");
const ordinals = @import("../ordinals.zig");
const trace = @import("../../trace.zig");
const renderer = @import("../../gui/renderer.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");

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

// --- Audio Buffer Pool ---

const MAX_SOUND_BUFFERS = 16;

/// Per-buffer state for secondary DirectSound buffers.
const SoundBufferState = struct {
    com_obj: IDirectSoundBuffer = undefined,
    data: [*]u8 = undefined,
    size: u32 = 0,
    volume: i32 = 0, // hundredths of dB, -10000..0
    pan: i32 = 0, // -10000 (left) to 10000 (right)
    playing: bool = false,
    looping: bool = false,
    play_start_ns: i128 = 0,
    play_cursor: u32 = 0,
    sample_rate: u32 = 44100,
    channels: u16 = 2,
    bits_per_sample: u16 = 16,
    block_align: u16 = 4,
    bytes_per_sec: u32 = 176400,
    allocated: bool = false,
};

var buffer_pool: [MAX_SOUND_BUFFERS]SoundBufferState = [_]SoundBufferState{.{}} ** MAX_SOUND_BUFFERS;
var buffer_pool_count: u32 = 0;

/// Look up buffer state by `this` COM pointer.
inline fn findBuffer(this: usize) ?*SoundBufferState {
    for (&buffer_pool, 0..) |*buf, i| {
        if (i >= buffer_pool_count) break;
        if (@intFromPtr(&buf.com_obj) == this) return buf;
    }
    // Fall back to buffer 0 if found
    if (buffer_pool_count > 0) return &buffer_pool[0];
    return null;
}

// --- COM Instances ---

var global_dsound: IDirectSound = undefined;
var global_dsbuffer_primary: IDirectSoundBuffer = undefined;
var dsound_vtbl: IDirectSoundVtbl = undefined;
var dsbuffer_vtbl: IDirectSoundBufferVtbl = undefined;

/// Truncate a host pointer to a 32-bit address for COM vtable entries
/// and register it as a native import with correct param count.
const comPtr = @import("../../x86/thunks.zig").comPtr;

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

        // Secondary buffer: allocate from pool
        if (buffer_pool_count < MAX_SOUND_BUFFERS) {
            const idx = buffer_pool_count;
            var buf = &buffer_pool[idx];
            buf.allocated = true;
            buf.com_obj.lpVtbl = @truncate(@intFromPtr(&dsbuffer_vtbl));

            // Set buffer size
            const buf_size = if (desc.dwBufferBytes > 0) @min(desc.dwBufferBytes, 262144) else 65536;
            buf.size = buf_size;

            // Allocate audio data
            if (@import("../kernel32.zig").global_env) |genv| {
                const data = genv.allocator.alloc(u8, buf_size) catch {
                    if (ppDSBuffer != 0) @as(*align(1) u32, @ptrFromInt(ppDSBuffer)).* = @truncate(@intFromPtr(&buf.com_obj));
                    buffer_pool_count += 1;
                    return 0;
                };
                @memset(data, 0);
                buf.data = data.ptr;
            }

            // Parse format if provided
            if (desc.lpwfxFormat != 0) {
                parseWaveFormatInto(buf, desc.lpwfxFormat);
            }

            buffer_pool_count += 1;
            if (trace.enable_tracing) trace.print("DSOUND:   -> secondary buffer #{d}, size={d}\n", .{ idx, buf_size });

            if (ppDSBuffer != 0) {
                @as(*align(1) u32, @ptrFromInt(ppDSBuffer)).* = @truncate(@intFromPtr(&buf.com_obj));
            }
            return 0;
        }
    }

    // Fallback: return first buffer
    if (ppDSBuffer != 0 and buffer_pool_count > 0) {
        @as(*align(1) u32, @ptrFromInt(ppDSBuffer)).* = @truncate(@intFromPtr(&buffer_pool[0].com_obj));
    }
    return 0;
}

fn parseWaveFormatInto(buf: *SoundBufferState, fmt_addr: u32) void {
    if (fmt_addr == 0) return;
    const fmt = @as(*const w32.WAVEFORMATEX, @ptrFromInt(fmt_addr));

    if (fmt.nChannels == 0 or fmt.nChannels > 8 or
        fmt.nSamplesPerSec == 0 or fmt.nSamplesPerSec > 200000 or
        (fmt.wBitsPerSample != 8 and fmt.wBitsPerSample != 16 and
            fmt.wBitsPerSample != 24 and fmt.wBitsPerSample != 32))
    {
        if (trace.enable_tracing) trace.print("DSOUND:   format INVALID: {d}Hz {d}ch {d}bit — skipping\n", .{ fmt.nSamplesPerSec, fmt.nChannels, fmt.wBitsPerSample });
        return;
    }

    buf.channels = fmt.nChannels;
    buf.sample_rate = fmt.nSamplesPerSec;
    buf.bytes_per_sec = fmt.nAvgBytesPerSec;
    buf.block_align = fmt.nBlockAlign;
    buf.bits_per_sample = fmt.wBitsPerSample;

    if (trace.enable_tracing) trace.print("DSOUND:   format: {d}Hz {d}ch {d}bit\n", .{ buf.sample_rate, buf.channels, buf.bits_per_sample });
}

/// Legacy wrapper for primary buffer format parsing.
var format_sent: bool = false;

// --- IDirectSoundBuffer Implementation ---

/// DirectSound volume: highest (most recent) per-buffer volume for external access.
pub var dsound_volume: i32 = 0;

fn dsbuffer_SetFormat(this: usize, pcfxFormat: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::SetFormat\n", .{});
    if (pcfxFormat != 0) {
        if (findBuffer(this)) |buf| {
            parseWaveFormatInto(buf, @intCast(pcfxFormat));
        }
        format_sent = false;
    }
    return 0;
}

fn dsbuffer_GetFormat(this: usize, pwfxFormat: usize, dwSizeAllocated: u32, pdwSizeWritten: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::GetFormat\n", .{});
    const wfx_size: u32 = 18;
    if (pdwSizeWritten != 0) @as(*u32, @ptrFromInt(pdwSizeWritten)).* = wfx_size;

    if (pwfxFormat != 0 and dwSizeAllocated >= wfx_size) {
        const buf = findBuffer(this) orelse return 0;
        const fmt = @as(*w32.WAVEFORMATEX, @ptrFromInt(pwfxFormat));
        fmt.wFormatTag = 1;
        fmt.nChannels = buf.channels;
        fmt.nSamplesPerSec = buf.sample_rate;
        fmt.nAvgBytesPerSec = buf.bytes_per_sec;
        fmt.nBlockAlign = buf.block_align;
        fmt.wBitsPerSample = buf.bits_per_sample;
        fmt.cbSize = 0;
    }
    return 0;
}

fn dsbuffer_GetCaps(this: usize, pDSBCaps: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DSOUND: IDirectSoundBuffer::GetCaps\n", .{});
    if (pDSBCaps != 0) {
        const buf = findBuffer(this) orelse return 0;
        const caps = @as([*]u8, @ptrFromInt(pDSBCaps));
        const size = @as(*u32, @ptrFromInt(pDSBCaps));
        @memset(caps[0..@min(size.*, 20)], 0);
        size.* = 20;
        @as(*u32, @ptrFromInt(pDSBCaps + 4)).* = 0x000180E0;
        @as(*u32, @ptrFromInt(pDSBCaps + 8)).* = buf.size;
    }
    return 0;
}

fn dsbuffer_Lock(this: usize, dwOffset: u32, dwBytes: u32, ppvAudioPtr1: usize, pdwAudioBytes1: usize, ppvAudioPtr2: usize, pdwAudioBytes2: usize, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    const buf = findBuffer(this) orelse return 0;
    if (trace.enable_tracing) trace.print("DSOUND: Lock(off={d}, bytes={d}, size={d})\n", .{ dwOffset, dwBytes, buf.size });

    var offset = dwOffset;
    var bytes = dwBytes;
    if (buf.size == 0) return 0;

    if (dwFlags & w32.DSBLOCK_FROMWRITECURSOR != 0) offset = getWriteCursorFor(buf);
    if (dwFlags & w32.DSBLOCK_ENTIREBUFFER != 0) {
        offset = 0;
        bytes = buf.size;
    }
    if (offset >= buf.size) offset = 0;
    if (bytes > buf.size) bytes = buf.size;

    const ptr1 = @as(*align(1) u32, @ptrFromInt(ppvAudioPtr1));
    const bytes1 = @as(*align(1) u32, @ptrFromInt(pdwAudioBytes1));

    if (offset + bytes <= buf.size) {
        ptr1.* = @truncate(@intFromPtr(buf.data) + offset);
        bytes1.* = bytes;
        if (ppvAudioPtr2 != 0) @as(*align(1) u32, @ptrFromInt(ppvAudioPtr2)).* = 0;
        if (pdwAudioBytes2 != 0) @as(*align(1) u32, @ptrFromInt(pdwAudioBytes2)).* = 0;
    } else {
        const first_part = buf.size - offset;
        ptr1.* = @truncate(@intFromPtr(buf.data) + offset);
        bytes1.* = first_part;
        if (ppvAudioPtr2 != 0) @as(*align(1) u32, @ptrFromInt(ppvAudioPtr2)).* = @truncate(@intFromPtr(buf.data));
        if (pdwAudioBytes2 != 0) @as(*align(1) u32, @ptrFromInt(pdwAudioBytes2)).* = bytes - first_part;
    }
    return 0;
}

/// Scratch buffer for applying volume/pan without modifying the original buffer data.
var scratch_buf: [65536]u8 align(2) = undefined;

/// Apply per-buffer volume and pan to 16-bit PCM data into a scratch buffer.
/// Volume: hundredths of dB (-10000..0), Pan: hundredths of dB (-10000..10000)
fn applyVolumeAndPan(dst: []u8, src: []const u8, volume: i32, pan: i32, channels: u16, bits: u16) void {
    @memcpy(dst[0..src.len], src);
    if (volume == 0 and pan == 0) return; // No attenuation needed

    // Convert volume from hundredths of dB to linear: 10^(vol/2000)
    const vol_f: f64 = @floatFromInt(volume);
    const vol_linear: f32 = @floatCast(std.math.pow(f64, 10.0, vol_f / 2000.0));

    // Convert pan to L/R multipliers
    var left_mul: f32 = vol_linear;
    var right_mul: f32 = vol_linear;
    if (pan < 0) {
        const pan_f: f64 = @floatFromInt(pan);
        right_mul *= @floatCast(std.math.pow(f64, 10.0, pan_f / 2000.0));
    } else if (pan > 0) {
        const pan_f: f64 = @floatFromInt(-pan);
        left_mul *= @floatCast(std.math.pow(f64, 10.0, pan_f / 2000.0));
    }

    if (bits == 16 and channels == 2) {
        const aligned: []align(2) u8 = @alignCast(dst[0..src.len]);
        const samples = std.mem.bytesAsSlice(i16, aligned);
        var i: usize = 0;
        while (i + 1 < samples.len) : (i += 2) {
            samples[i] = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(samples[i])) * left_mul, -32768.0, 32767.0));
            samples[i + 1] = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(samples[i + 1])) * right_mul, -32768.0, 32767.0));
        }
    } else if (bits == 16 and channels == 1) {
        const aligned: []align(2) u8 = @alignCast(dst[0..src.len]);
        const samples = std.mem.bytesAsSlice(i16, aligned);
        for (samples) |*s| {
            s.* = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(s.*)) * vol_linear, -32768.0, 32767.0));
        }
    }
}

fn pushAudioWithEffects(buf: *SoundBufferState, raw: []const u8) void {
    if (raw.len == 0) return;
    if (buf.volume == 0 and buf.pan == 0) {
        renderer.pushAudio(raw);
        return;
    }
    // Process in chunks that fit the scratch buffer
    var offset: usize = 0;
    while (offset < raw.len) {
        const chunk = @min(raw.len - offset, scratch_buf.len);
        applyVolumeAndPan(scratch_buf[0..chunk], raw[offset..][0..chunk], buf.volume, buf.pan, buf.channels, buf.bits_per_sample);
        renderer.pushAudio(scratch_buf[0..chunk]);
        offset += chunk;
    }
}

fn dsbuffer_Unlock(this: usize, pvAudioPtr1: usize, dwAudioBytes1: u32, pvAudioPtr2: usize, dwAudioBytes2: u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DSOUND: Unlock(bytes1={d}, bytes2={d})\n", .{ dwAudioBytes1, dwAudioBytes2 });

    const buf = findBuffer(this) orelse return 0;
    if (!format_sent) {
        renderer.setAudioFormat(buf.sample_rate, buf.channels, buf.bits_per_sample);
        format_sent = true;
    }

    if (dwAudioBytes1 > 0 and pvAudioPtr1 != 0) {
        const data = @as([*]const u8, @ptrFromInt(pvAudioPtr1))[0..dwAudioBytes1];
        pushAudioWithEffects(buf, data);
    }
    if (dwAudioBytes2 > 0 and pvAudioPtr2 != 0) {
        const data = @as([*]const u8, @ptrFromInt(pvAudioPtr2))[0..dwAudioBytes2];
        pushAudioWithEffects(buf, data);
    }
    return 0;
}

fn dsbuffer_Play(this: usize, dwReserved1: u32, dwPriority: u32, dwFlags: u32) callconv(w32cc.WINAPI) i32 {
    _ = dwReserved1;
    _ = dwPriority;
    if (trace.enable_tracing) trace.print("DSOUND: Play\n", .{});
    if (findBuffer(this)) |buf| {
        buf.playing = true;
        buf.looping = (dwFlags & 1) != 0; // DSBPLAY_LOOPING
        buf.play_start_ns = runtime.monoNanoTimestamp();
        if (!format_sent) {
            renderer.setAudioFormat(buf.sample_rate, buf.channels, buf.bits_per_sample);
            format_sent = true;
        }
    }
    return 0;
}

fn dsbuffer_Stop(this: usize) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("DSOUND: Stop\n", .{});
    if (findBuffer(this)) |buf| buf.playing = false;
    return 0;
}

fn getPlayCursorFor(buf: *SoundBufferState) u32 {
    if (!buf.playing or buf.bytes_per_sec == 0 or buf.size == 0) return buf.play_cursor;
    // Elapsed playback time on the monotonic clock; pairs with play_start_ns.
    const now: i128 = runtime.monoNanoTimestamp();
    const elapsed = now - buf.play_start_ns;
    if (elapsed <= 0) return buf.play_cursor;
    const elapsed_u: u128 = @intCast(elapsed);
    const bytes: u128 = (elapsed_u * buf.bytes_per_sec) / 1_000_000_000;
    buf.play_cursor = @intCast(bytes % buf.size);
    return buf.play_cursor;
}

fn getWriteCursorFor(buf: *SoundBufferState) u32 {
    const play = getPlayCursorFor(buf);
    const lead = @as(u32, buf.block_align) * 256;
    return if (buf.size > 0) (play + lead) % buf.size else 0;
}

fn dsbuffer_GetCurrentPosition(this: usize, pdwCurrentPlayCursor: usize, pdwCurrentWriteCursor: usize) callconv(w32cc.WINAPI) i32 {
    const buf = findBuffer(this) orelse return 0;
    if (pdwCurrentPlayCursor != 0) @as(*align(1) u32, @ptrFromInt(pdwCurrentPlayCursor)).* = getPlayCursorFor(buf);
    if (pdwCurrentWriteCursor != 0) @as(*align(1) u32, @ptrFromInt(pdwCurrentWriteCursor)).* = getWriteCursorFor(buf);
    return 0;
}

fn dsbuffer_GetStatus(this: usize, pdwStatus: usize) callconv(w32cc.WINAPI) i32 {
    if (pdwStatus != 0) {
        const buf = findBuffer(this) orelse return 0;
        @as(*u32, @ptrFromInt(pdwStatus)).* = if (buf.playing) w32.DSBSTATUS_PLAYING | w32.DSBSTATUS_LOOPING else 0;
    }
    return 0;
}

fn dsbuffer_SetCurrentPosition(this: usize, dwNewPosition: u32) callconv(w32cc.WINAPI) i32 {
    if (findBuffer(this)) |buf| {
        buf.play_cursor = if (buf.size > 0) dwNewPosition % buf.size else 0;
    }
    return 0;
}

fn dsbuffer_SetVolume(this: usize, lVolume: i32) callconv(w32cc.WINAPI) i32 {
    const vol = std.math.clamp(lVolume, w32.DSBVOLUME_MIN, w32.DSBVOLUME_MAX);
    if (findBuffer(this)) |buf| buf.volume = vol;
    dsound_volume = vol;
    if (trace.enable_tracing) trace.print("DSOUND: SetVolume({d})\n", .{vol});
    return 0;
}

fn dsbuffer_SetPan(this: usize, lPan: i32) callconv(w32cc.WINAPI) i32 {
    const pan = std.math.clamp(lPan, -10000, 10000);
    if (findBuffer(this)) |buf| buf.pan = pan;
    if (trace.enable_tracing) trace.print("DSOUND: SetPan({d})\n", .{pan});
    return 0;
}

fn dsbuffer_GetPan(this: usize, plPan: usize) callconv(w32cc.WINAPI) i32 {
    if (plPan != 0) {
        const buf = findBuffer(this) orelse return 0;
        @as(*align(1) i32, @ptrFromInt(plPan)).* = buf.pan;
    }
    return 0;
}

fn dsbuffer_GetVolume(this: usize, plVolume: usize) callconv(w32cc.WINAPI) i32 {
    if (plVolume != 0) {
        const buf = findBuffer(this) orelse return 0;
        @as(*align(1) i32, @ptrFromInt(plVolume)).* = buf.volume;
    }
    return 0;
}

/// Registers DSOUND.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const d1 = comPtr(dsound_Dummy, "IDirectSound::Dummy");
    const d2 = comPtr(dsound_Dummy2, "IDirectSound::Dummy2");
    const d3 = comPtr(dsound_Dummy3, "IDirectSound::Dummy3");

    dsound_vtbl = .{
        .QueryInterface = comPtr(dsound_QueryInterface, "IDirectSound::QueryInterface"),
        .AddRef = d1,
        .Release = d1,
        .CreateSoundBuffer = comPtr(dsound_CreateSoundBuffer, "IDirectSound::CreateSoundBuffer"),
        .GetCaps = comPtr(dsound_GetCaps, "IDirectSound::GetCaps"),
        .DuplicateSoundBuffer = d3,
        .SetCooperativeLevel = comPtr(dsound_SetCooperativeLevel, "IDirectSound::SetCooperativeLevel"),
        .Compact = d1,
        .GetSpeakerConfig = d2,
        .SetSpeakerConfig = d2,
        .Initialize = d2,
    };

    dsbuffer_vtbl = .{
        .QueryInterface = d3,
        .AddRef = d1,
        .Release = d1,
        .GetCaps = comPtr(dsbuffer_GetCaps, "IDirectSoundBuffer::GetCaps"),
        .GetCurrentPosition = comPtr(dsbuffer_GetCurrentPosition, "IDirectSoundBuffer::GetCurrentPosition"),
        .GetFormat = comPtr(dsbuffer_GetFormat, "IDirectSoundBuffer::GetFormat"),
        .GetVolume = comPtr(dsbuffer_GetVolume, "IDirectSoundBuffer::GetVolume"),
        .GetPan = comPtr(dsbuffer_GetPan, "IDirectSoundBuffer::GetPan"),
        .GetFrequency = d2,
        .GetStatus = comPtr(dsbuffer_GetStatus, "IDirectSoundBuffer::GetStatus"),
        .Initialize = d3,
        .Lock = comPtr(dsbuffer_Lock, "IDirectSoundBuffer::Lock"),
        .Play = comPtr(dsbuffer_Play, "IDirectSoundBuffer::Play"),
        .SetCurrentPosition = comPtr(dsbuffer_SetCurrentPosition, "IDirectSoundBuffer::SetCurrentPosition"),
        .SetFormat = comPtr(dsbuffer_SetFormat, "IDirectSoundBuffer::SetFormat"),
        .SetVolume = comPtr(dsbuffer_SetVolume, "IDirectSoundBuffer::SetVolume"),
        .SetPan = comPtr(dsbuffer_SetPan, "IDirectSoundBuffer::SetPan"),
        .SetFrequency = d2,
        .Stop = comPtr(dsbuffer_Stop, "IDirectSoundBuffer::Stop"),
        .Unlock = comPtr(dsbuffer_Unlock, "IDirectSoundBuffer::Unlock"),
        .Restore = d1,
    };

    global_dsound.lpVtbl = @truncate(@intFromPtr(&dsound_vtbl));
    global_dsbuffer_primary.lpVtbl = @truncate(@intFromPtr(&dsbuffer_vtbl));

    const builtin_module = "DSOUND.dll";
    try environment.addBuiltinExportComptime(builtin_module, ordinals.DSOUND.DirectSoundCreate, stub_DirectSoundCreate);
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
