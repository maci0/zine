---
phase: 12
plan: 1
title: DirectSound Gap Closure
wave: 1
depends_on: []
files_modified:
  - src/win32/dsound/dsound.zig
  - src/gui/renderer.zig
autonomous: true
requirements_addressed: [DSND-01, DSND-02]
---

# Plan 01: DirectSound Gap Closure

<objective>
Close DirectSound gaps: implement SetPan with dB-to-linear stereo conversion, add per-buffer volume during Unlock, and support correct multi-buffer mixing by pushing per-buffer PCM with volume/pan applied.
</objective>

<must_haves>
- SetPan stores pan value and applies L/R attenuation when pushing audio
- Per-buffer volume is applied during Unlock (not globally via renderer)
- Multiple buffers can push audio simultaneously without overwriting each other
- Existing single-buffer audio path does not regress
</must_haves>

## Tasks

### Task 1: Implement dsbuffer_SetPan

<read_first>
- src/win32/dsound/dsound.zig (lines 446-455 — SetVolume as reference pattern)
- src/win32/dsound/dsound.zig (lines 68-84 — SoundBufferState fields)
</read_first>

<action>
Replace the `d2` dummy for SetPan in the vtable with a real implementation:

```zig
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
```

Update the vtable registration:
```diff
-.GetPan = d2,
+.GetPan = comPtr(dsbuffer_GetPan, "IDirectSoundBuffer::GetPan"),
-.SetPan = d2,
+.SetPan = comPtr(dsbuffer_SetPan, "IDirectSoundBuffer::SetPan"),
```
</action>

<acceptance_criteria>
- `sync.zig` — N/A
- `dsound.zig` contains `fn dsbuffer_SetPan(`
- `dsound.zig` contains `fn dsbuffer_GetPan(`
- vtable `.SetPan =` uses `comPtr(dsbuffer_SetPan, ...)`
- vtable `.GetPan =` uses `comPtr(dsbuffer_GetPan, ...)`
</acceptance_criteria>

---

### Task 2: Apply per-buffer volume and pan during Unlock

<read_first>
- src/win32/dsound/dsound.zig (lines 364-383 — dsbuffer_Unlock)
- src/win32/dsound/dsound.zig (lines 446-455 — dsbuffer_SetVolume)
</read_first>

<action>
Modify `dsbuffer_Unlock` to apply the buffer's volume and pan before pushing audio to the renderer. Create a helper function that processes PCM data in-place (or into a scratch buffer) with volume/pan attenuation.

```zig
/// Apply per-buffer volume and pan to 16-bit stereo PCM data.
/// Volume: hundredths of dB (-10000..0), Pan: hundredths of dB (-10000..10000)
fn applyVolumeAndPan(data: []u8, volume: i32, pan: i32, channels: u16, bits: u16) void {
    if (volume == 0 and pan == 0) return; // No attenuation needed

    // Convert volume from hundredths of dB to linear: 10^(vol/2000)
    const vol_f: f64 = @floatFromInt(volume);
    const vol_linear: f32 = @floatCast(std.math.pow(f64, 10.0, vol_f / 2000.0));

    // Convert pan to L/R multipliers
    // Pan -10000 = full left, 0 = center, 10000 = full right
    var left_mul: f32 = vol_linear;
    var right_mul: f32 = vol_linear;
    if (pan < 0) {
        // Attenuate right channel
        const pan_f: f64 = @floatFromInt(pan);
        right_mul *= @floatCast(std.math.pow(f64, 10.0, pan_f / 2000.0));
    } else if (pan > 0) {
        // Attenuate left channel
        const pan_f: f64 = @floatFromInt(-pan);
        left_mul *= @floatCast(std.math.pow(f64, 10.0, pan_f / 2000.0));
    }

    if (bits == 16 and channels == 2) {
        const samples = std.mem.bytesAsSlice(i16, data);
        var i: usize = 0;
        while (i + 1 < samples.len) : (i += 2) {
            samples[i] = @intFromFloat(@as(f32, @floatFromInt(samples[i])) * left_mul);
            samples[i + 1] = @intFromFloat(@as(f32, @floatFromInt(samples[i + 1])) * right_mul);
        }
    } else if (bits == 16 and channels == 1) {
        const samples = std.mem.bytesAsSlice(i16, data);
        for (samples) |*s| {
            s.* = @intFromFloat(@as(f32, @floatFromInt(s.*)) * vol_linear);
        }
    }
    // 8-bit: skip attenuation (rare, can be added later)
}
```

Update `dsbuffer_Unlock` to call `applyVolumeAndPan` on a copy of the data before pushing:
- If volume == 0 and pan == 0, push directly (no copy needed)
- Otherwise, copy to a thread-local scratch buffer, apply, then push

Also remove the global `renderer.setVolume()` call from `dsbuffer_SetVolume` (volume is now applied per-buffer during Unlock).
</action>

<acceptance_criteria>
- `dsound.zig` contains `fn applyVolumeAndPan(`
- `dsbuffer_Unlock` applies volume/pan per-buffer before `renderer.pushAudio()`
- `dsbuffer_SetVolume` no longer calls `renderer.setVolume()`
- Audio with volume=0 (max) and pan=0 (center) passes through unchanged
</acceptance_criteria>

---

### Task 3: Remove global volume coupling

<read_first>
- src/win32/dsound/dsound.zig (lines 446-455 — dsbuffer_SetVolume with renderer.setVolume)
- src/gui/renderer.zig — setVolume function (check if other callers exist)
</read_first>

<action>
Remove `renderer.setVolume(@floatCast(linear))` from `dsbuffer_SetVolume`. Keep the volume storage in the buffer state (it's used by `applyVolumeAndPan` during Unlock).

Keep `dsound_volume` pub var for external access (UI slider) but don't apply it globally to the renderer — it's now informational only.

Check if `renderer.setVolume()` is called from anywhere else. If the web UI volume slider calls it, that's fine — it's a master volume separate from per-buffer DirectSound volume.
</action>

<acceptance_criteria>
- `dsbuffer_SetVolume` does NOT contain `renderer.setVolume`
- `dsbuffer_SetVolume` still stores `buf.volume = vol` and `dsound_volume = vol`
- Build passes with no errors
</acceptance_criteria>

---

## Verification

### Build verification
```bash
cd /home/maci/Desktop/Projects/zine && zig build 2>&1 | head -20
```

### Manual verification
- Run Europa 1400 Gold and verify audio still plays
- Check that the volume slider in the web UI still works (it uses renderer.setVolume independently)
- If multiple sound effects play simultaneously, they should not cut each other off
