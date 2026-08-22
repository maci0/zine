const std = @import("std");
const runtime = @import("../../runtime.zig");
const trace = @import("../../trace.zig");
const renderer = if (@import("builtin").os.tag != .windows) @import("../../gui/renderer.zig") else struct {
    pub fn setVolume(_: anytype) void {}
};
const dsound_stubs = @import("../dsound/dsound.zig");
const platform = @import("../../platform.zig");
const w32 = @import("../constants.zig");
const w32cc = @import("../calling_convention.zig");
const winmm = @import("../winmm.zig");

/// timeGetTime
/// Implementation status: Partially implemented
pub fn timeGetTime() callconv(w32cc.WINAPI) u32 {
    // Called in tight timing loops; yield to avoid 100% CPU usage.
    platform.yield();

    // Milliseconds since system start: monotonic so guest frame/animation
    // deltas survive wall-clock steps.
    return @intCast(runtime.monoMilliTimestamp() & 0xFFFFFFFF);
}

/// waveOutSetVolume
/// Implementation status: Partially implemented
pub fn waveOutSetVolume(hwo: u32, dwVolume: u32) callconv(w32cc.WINAPI) u32 {
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

/// waveOutGetVolume
/// Implementation status: Partially implemented
pub fn waveOutGetVolume(hwo: u32, pdwVolume: usize) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    if (pdwVolume != 0) {
        @as(*align(1) u32, @ptrFromInt(pdwVolume)).* = winmm.waveout_volume;
    }
    if (trace.enable_tracing) trace.print("WINMM: waveOutGetVolume() -> 0x{x:0>8}\n", .{winmm.waveout_volume});
    return 0; // MMSYSERR_NOERROR
}

/// stub_PlaySoundA
/// Implementation status: No-op fallback
pub fn stub_PlaySoundA(pszSound: usize, hmod: usize, fdwSound: u32) callconv(w32cc.WINAPI) i32 {
    _ = pszSound;
    _ = hmod;
    _ = fdwSound;
    if (trace.enable_tracing) trace.print("WINMM: PlaySoundA\n", .{});
    return 1;
}

/// --- Timer functions for Europa 1400 ---
/// Implementation status: Stub
pub fn stub_timeGetDevCaps(ptc: usize, cbtc: u32) callconv(w32cc.WINAPI) u32 {
    _ = cbtc;
    if (ptc != 0) {
        const tc = @as(*w32.TIMECAPS, @ptrFromInt(ptc));
        tc.wPeriodMin = 1; // 1ms
        tc.wPeriodMax = 1000000;
    }
    return 0; // TIMERR_NOERROR
}

/// stub_timeBeginPeriod
/// Implementation status: Stub
pub fn stub_timeBeginPeriod(uPeriod: u32) callconv(w32cc.WINAPI) u32 {
    _ = uPeriod;
    return 0; // TIMERR_NOERROR
}

/// stub_timeEndPeriod
/// Implementation status: Stub
pub fn stub_timeEndPeriod(uPeriod: u32) callconv(w32cc.WINAPI) u32 {
    _ = uPeriod;
    return 0; // TIMERR_NOERROR
}

var timer_id_counter: u32 = 1;

const MAX_MM_TIMERS = 8;

pub const MmTimer = struct {
    active: bool = false,
    id: u32 = 0,
    delay_ms: u32 = 0,
    callback: usize = 0,
    user_data: usize = 0,
    periodic: bool = false,
    pending_fire: bool align(4) = false,
    thread: if (platform.is_native) ?std.Thread else void = if (platform.is_native) null else {},
};

pub var mm_timers: [MAX_MM_TIMERS]MmTimer = [_]MmTimer{.{}} ** MAX_MM_TIMERS;

fn mmTimerThread(idx: usize) void {
    const timer = &mm_timers[idx];
    const delay_ns: u64 = @as(u64, timer.delay_ms) * 1_000_000;
    const teb = @import("../teb.zig");
    const builtin = @import("builtin");

    while (timer.active) {
        @import("../../platform.zig").sleep(delay_ns);
        if (!timer.active) break;

        if (timer.callback != 0) {
            // Save current FS base and set TEB FS base for x86 context.
            // The game's timer callback accesses TEB via fs: segment,
            // so we must set FS to point to the TEB before calling it.
            if (comptime builtin.target.cpu.arch == .x86_64) {
                if (teb.teb_address != 0) {
                    // Save Zig's FS base
                    var saved_fs: usize = 0;
                    asm volatile ("syscall"
                        :
                        : [num] "{rax}" (@as(usize, 158)), // __NR_arch_prctl
                          [arg1] "{rdi}" (@as(usize, 0x1003)), // ARCH_GET_FS
                          [arg2] "{rsi}" (@intFromPtr(&saved_fs)),
                        : .{ .rax = true, .rcx = true, .r11 = true, .memory = true });

                    // Set TEB as FS base
                    asm volatile ("syscall"
                        :
                        : [num] "{rax}" (@as(usize, 158)), // __NR_arch_prctl
                          [arg1] "{rdi}" (@as(usize, 0x1002)), // ARCH_SET_FS
                          [arg2] "{rsi}" (teb.teb_address),
                        : .{ .rax = true, .rcx = true, .r11 = true, .memory = true });

                    // Call the game's timer callback
                    const cb = @as(*const fn (u32, u32, usize, usize, usize) callconv(w32cc.WINAPI) void, @ptrFromInt(timer.callback));
                    cb(timer.id, 0, timer.user_data, 0, 0);
                    if (trace.enable_tracing) {
                        if (comptime builtin.target.cpu.arch == .x86) {
                            // Read re-entrancy flag via asm to avoid Zig optimizing away the read
                            // (game-specific absolute addresses, only valid on 32-bit)
                            var flag_val: u32 = undefined;
                            asm volatile ("movl 0x6333dc, %[out]"
                                : [out] "=r" (flag_val),
                                :
                                : .{ .memory = true });
                            var gui_gate: u32 = undefined;
                            var res_ptr: u32 = undefined;
                            var dat_6f22bc: u32 = undefined;
                            asm volatile ("movl 0x75e8c0, %[out]"
                                : [out] "=r" (gui_gate),
                                :
                                : .{ .memory = true });
                            asm volatile ("movl 0xf8f0a0, %[out]"
                                : [out] "=r" (res_ptr),
                                :
                                : .{ .memory = true });
                            asm volatile ("movl 0x6f22bc, %[out]"
                                : [out] "=r" (dat_6f22bc),
                                :
                                : .{ .memory = true });
                            var res_byte0: u8 = 0;
                            if (res_ptr != 0) {
                                res_byte0 = @as(*const u8, @ptrFromInt(res_ptr)).*;
                            }
                            trace.print("WINMM: TimeProc cb (timer {d}) flag={d} gui_gate={d} res_ptr=0x{x} res_byte0=0x{x} dat_6f22bc=0x{x}\n", .{ timer.id, flag_val, gui_gate, res_ptr, res_byte0, dat_6f22bc });
                        } else {
                            trace.print("WINMM: TimeProc cb (timer {d})\n", .{timer.id});
                        }
                    }

                    // Restore Zig's FS base
                    asm volatile ("syscall"
                        :
                        : [num] "{rax}" (@as(usize, 158)), // __NR_arch_prctl
                          [arg1] "{rdi}" (@as(usize, 0x1002)), // ARCH_SET_FS
                          [arg2] "{rsi}" (saved_fs),
                        : .{ .rax = true, .rcx = true, .r11 = true, .memory = true });
                }
            } else if (comptime builtin.target.cpu.arch == .x86) {
                // x86 (32-bit): Save/restore FS selector for game's TEB
                if (teb.teb_fs_selector != 0) {
                    // Save current Zig FS selector
                    var saved_fs: u16 = undefined;
                    asm volatile ("mov %%fs, %[out]"
                        : [out] "=r" (saved_fs),
                    );

                    // Set FS to TEB selector
                    asm volatile ("mov %[sel], %%fs"
                        :
                        : [sel] "r" (teb.teb_fs_selector),
                    );

                    if (trace.enable_tracing) {
                        trace.print("WINMM: TimeProc (timer {d}) callback=0x{x}\n", .{ timer.id, timer.callback });
                        // One-shot dump of game function table after 500 ticks
                        const FTDump = struct {
                            var tick: u32 = 0;
                            var dumped: bool = false;
                        };
                        FTDump.tick += 1;
                        if (!FTDump.dumped and FTDump.tick >= 500) {
                            FTDump.dumped = true;
                            // Dump key game state flags
                            const pause_flag = @as(*const u32, @ptrFromInt(0x6333e0)).*;
                            const reentry_guard = @as(*const u32, @ptrFromInt(0x6333dc)).*;
                            const timer_rearm = @as(*const u32, @ptrFromInt(0x6333e4)).*;
                            const tick_counter = @as(*const u32, @ptrFromInt(0x6333cc)).*;
                            const new_game_flag = @as(*const u32, @ptrFromInt(0x6f25a4)).*;
                            const game_state = @as(*const u32, @ptrFromInt(0x6f23f8)).*;
                            const world_flag = @as(*const u32, @ptrFromInt(0x6ed9d4)).*;
                            const init_flag = @as(*const u32, @ptrFromInt(0x6f2358)).*;
                            trace.print("WINMM: Game state dump:\n", .{});
                            trace.print("  DAT_006333e0 (pause)    = {d}\n", .{pause_flag});
                            trace.print("  DAT_006333dc (reentry)  = {d}\n", .{reentry_guard});
                            trace.print("  DAT_006333e4 (rearm)    = {d}\n", .{timer_rearm});
                            trace.print("  DAT_006333cc (tick)     = {d}\n", .{tick_counter});
                            trace.print("  DAT_006f25a4 (new_game) = {d}\n", .{new_game_flag});
                            trace.print("  DAT_006f23f8 (state)    = 0x{x}\n", .{game_state});
                            trace.print("  DAT_006ed9d4 (world)    = {d}\n", .{world_flag});
                            trace.print("  DAT_006f2358 (init)     = {d}\n", .{init_flag});
                            // Resource table state
                            const res_count = @as(*const i32, @ptrFromInt(0x6f2620)).*;
                            trace.print("  DAT_006f2620 (res_cnt)  = {d}\n", .{res_count});
                            // Dump first several resource table entries
                            var ri: usize = 0;
                            while (ri < 8) : (ri += 1) {
                                const res_ptr = @as(*const u32, @ptrFromInt(0x74db40 + ri * 4)).*;
                                if (res_ptr != 0) {
                                    const res_byte0 = @as(*const u8, @ptrFromInt(res_ptr)).*;
                                    trace.print("  res[{d}] ptr=0x{x} type/flags=0x{x}\n", .{ ri, res_ptr, res_byte0 });
                                }
                            }
                            // Check the DAT_006f259c flag that gates rendering
                            const render_gate = @as(*const u32, @ptrFromInt(0x6f259c)).*;
                            trace.print("  DAT_006f259c (render_gate) = {d}\n", .{render_gate});
                            // Overlay table at 0x75f780
                            const overlay_count = @as(*const i32, @ptrFromInt(0x6f229c)).*;
                            const overlay_a0 = @as(*const i32, @ptrFromInt(0x6f22a0)).*;
                            const overlay_a4 = @as(*const i32, @ptrFromInt(0x6f22a4)).*;
                            trace.print("  DAT_006f229c (ovl_cnt)  = {d}\n", .{overlay_count});
                            trace.print("  DAT_006f22a0 (ovl_a0)   = {d}\n", .{overlay_a0});
                            trace.print("  DAT_006f22a4 (ovl_a4)   = {d}\n", .{overlay_a4});
                            {
                                var oi: usize = 0;
                                while (oi < 4) : (oi += 1) {
                                    const ovl_ptr = @as(*const u32, @ptrFromInt(0x75f780 + oi * 8)).*;
                                    const ovl_val = @as(*const u32, @ptrFromInt(0x75f780 + oi * 8 + 4)).*;
                                    if (ovl_ptr != 0) {
                                        trace.print("  ovl[{d}] ptr=0x{x} val=0x{x}\n", .{ oi, ovl_ptr, ovl_val });
                                    }
                                }
                            }
                            // Check tick counter comparison target
                            const tick_target = @as(*const u32, @ptrFromInt(0xa687e4)).*;
                            trace.print("  DAT_00a687e4 (tick_tgt) = {d}\n", .{tick_target});
                            // Key rendering flags
                            const anim_flag = @as(*const u8, @ptrFromInt(0x6f25ac)).*;
                            const render_flag = @as(*const u8, @ptrFromInt(0x633451)).*;
                            const subsys1 = @as(*const u32, @ptrFromInt(0x6f2580)).*;
                            const subsys2 = @as(*const u32, @ptrFromInt(0x6f257c)).*;
                            const subsys3 = @as(*const u32, @ptrFromInt(0x6f2578)).*;
                            trace.print("  DAT_006f25ac (anim)     = {d}\n", .{anim_flag});
                            trace.print("  DAT_00633451 (render)   = {d}\n", .{render_flag});
                            const render_counter = @as(*const i32, @ptrFromInt(0x633b04)).*;
                            const render_mode_50 = @as(*const u8, @ptrFromInt(0x633450)).*;
                            const d3d_check = @as(*const u8, @ptrFromInt(0x631222)).*;
                            trace.print("  DAT_00633b04 (rndr_cnt) = {d}\n", .{render_counter});
                            trace.print("  DAT_00633450 (rndr_mod) = {d}\n", .{render_mode_50});
                            trace.print("  DAT_00631222 (d3d_chk)  = {d}\n", .{d3d_check});
                            trace.print("  DAT_006f2580 (sub1)     = {d}\n", .{subsys1});
                            trace.print("  DAT_006f257c (sub2)     = {d}\n", .{subsys2});
                            trace.print("  DAT_006f2578 (sub3)     = {d}\n", .{subsys3});
                            const overlay_state = @as(*const u32, @ptrFromInt(0x760440)).*;
                            const d3d_extra = @as(*const u32, @ptrFromInt(0x6f0dbc)).*;
                            trace.print("  DAT_00760440 (overlay)  = 0x{x}\n", .{overlay_state});
                            trace.print("  DAT_006f0dbc (d3d_ext)  = 0x{x}\n", .{d3d_extra});
                            const game_tick = @as(*const u32, @ptrFromInt(0x6333cc)).*;
                            const timer_val = @as(*const u32, @ptrFromInt(0xa687e4)).*;
                            const ui_state = @as(*const u32, @ptrFromInt(0x6f259c)).*;
                            trace.print("  DAT_006333cc (tick)     = {d}\n", .{game_tick});
                            trace.print("  DAT_00a687e4 (timer)    = {d}\n", .{timer_val});
                            trace.print("  DAT_006f259c (ui_state) = {d}\n", .{ui_state});
                            const gui_process = @as(*const i32, @ptrFromInt(0x1460ae0)).*;
                            const gui_list1 = @as(*const u32, @ptrFromInt(0xf81160)).*;
                            const gui_list2 = @as(*const u32, @ptrFromInt(0xf81180)).*;
                            trace.print("  DAT_01460ae0 (gui_proc) = {d}\n", .{gui_process});
                            trace.print("  DAT_00f81160 (gui_lst1) = 0x{x}\n", .{gui_list1});
                            trace.print("  DAT_00f81180 (gui_lst2) = 0x{x}\n", .{gui_list2});
                            // Critical gate flags for FUN_00472a50 (sets GUI ready bit)
                            const gui_gate = @as(*const u32, @ptrFromInt(0x75e8c0)).*;
                            const earlyout = @as(*const u32, @ptrFromInt(0x6f22bc)).*;
                            trace.print("  DAT_0075e8c0 (gui_gate) = {d}\n", .{gui_gate});
                            trace.print("  DAT_006f22bc (earlyout) = {d}\n", .{earlyout});
                            const camera_state = @as(*const u32, @ptrFromInt(0x6f2584)).*;
                            const quit_flag = @as(*const u32, @ptrFromInt(0x6f25b4)).*;
                            trace.print("  DAT_006f2584 (camera)   = {d}\n", .{camera_state});
                            trace.print("  DAT_006f25b4 (quit)     = {d}\n", .{quit_flag});
                            // D3D device/scene pointers
                            const d3d_scene = @as(*const u32, @ptrFromInt(0x1467398)).*;
                            const d3d_scene2 = @as(*const u32, @ptrFromInt(0x14673a0)).*;
                            const d3d_scene3 = @as(*const u32, @ptrFromInt(0x14673a8)).*;
                            const scene_data1 = @as(*const u32, @ptrFromInt(0x6f2308)).*;
                            const scene_data2 = @as(*const u32, @ptrFromInt(0x6f230c)).*;
                            trace.print("  DAT_01467398 (d3d_scn)  = 0x{x}\n", .{d3d_scene});
                            trace.print("  DAT_014673a0 (d3d_sc2)  = 0x{x}\n", .{d3d_scene2});
                            trace.print("  DAT_014673a8 (d3d_sc3)  = 0x{x}\n", .{d3d_scene3});
                            trace.print("  DAT_006f2308 (scn_dat1) = 0x{x}\n", .{scene_data1});
                            trace.print("  DAT_006f230c (scn_dat2) = 0x{x}\n", .{scene_data2});
                            const d3d_init_state = @as(*const u8, @ptrFromInt(0x1468410)).*;
                            trace.print("  DAT_01468410 (d3d_init) = 0x{x} ({d})\n", .{ d3d_init_state, d3d_init_state });
                            // Critical rendering pipeline pointers
                            const backbuffer = @as(*const u32, @ptrFromInt(0xfc2dec)).*;
                            const d3d_device_struct = @as(*const u32, @ptrFromInt(0x633448)).*;
                            const primary_surface = @as(*const u32, @ptrFromInt(0xfc2930)).*;
                            const ddraw_obj = @as(*const u32, @ptrFromInt(0x633738)).*;
                            trace.print("  DAT_00fc2dec (backbuf)  = 0x{x}\n", .{backbuffer});
                            trace.print("  DAT_00633448 (d3d_dev)  = 0x{x}\n", .{d3d_device_struct});
                            trace.print("  DAT_00fc2930 (primary)  = 0x{x}\n", .{primary_surface});
                            trace.print("  DAT_00633738 (ddraw)    = 0x{x}\n", .{ddraw_obj});
                            // GUI resource table at 0xf8f0a0
                            trace.print("  GUI resource table (0xf8f0a0):\n", .{});
                            {
                                var gi: usize = 0;
                                while (gi < 4) : (gi += 1) {
                                    const gui_ptr = @as(*const u32, @ptrFromInt(0xf8f0a0 + gi * 4)).*;
                                    if (gui_ptr != 0) {
                                        const gui_byte0 = @as(*const u8, @ptrFromInt(gui_ptr)).*;
                                        trace.print("    gui[{d}] ptr=0x{x} byte0=0x{x} (ready={d})\n", .{ gi, gui_ptr, gui_byte0, gui_byte0 & 4 });
                                    }
                                }
                            }
                            trace.print("WINMM: Function table dump (0xfe7aa0):\n", .{});
                            var addr: usize = 0xfe7aa0;
                            var entry_idx: u32 = 0;
                            while (addr < 0xfe7c20) : (addr += 12) {
                                const func = @as(*const u32, @ptrFromInt(addr)).*;
                                const divisor = @as(*const u32, @ptrFromInt(addr + 4)).*;
                                const flag = @as(*const u32, @ptrFromInt(addr + 8)).*;
                                if (func != 0) {
                                    trace.print("  [{d}] func=0x{x} div={d} flag={d}\n", .{ entry_idx, func, divisor, flag });
                                }
                                entry_idx += 1;
                            }
                        }
                    }

                    const cb = @as(*const fn (u32, u32, usize, usize, usize) callconv(w32cc.WINAPI) void, @ptrFromInt(timer.callback));
                    cb(timer.id, 0, timer.user_data, 0, 0);

                    if (trace.enable_tracing) {
                        trace.print("WINMM: TimeProc returned (timer {d})\n", .{timer.id});
                    }

                    // Restore Zig's FS selector
                    asm volatile ("mov %[sel], %%fs"
                        :
                        : [sel] "r" (saved_fs),
                    );
                }
            } else {
                // Other architectures: just call without FS setup
                if (trace.enable_tracing) trace.print("WINMM: firing TimeProc callback 0x{x} (timer {d})\n", .{ timer.callback, timer.id });
                const cb = @as(*const fn (u32, u32, usize, usize, usize) callconv(w32cc.WINAPI) void, @ptrFromInt(timer.callback));
                cb(timer.id, 0, timer.user_data, 0, 0);
                if (trace.enable_tracing) trace.print("WINMM: TimeProc callback returned (timer {d})\n", .{timer.id});
            }
        }

        if (!timer.periodic) {
            timer.active = false;
            break;
        }
    }
}

/// timeSetEvent
/// Implementation status: Partially implemented
pub fn timeSetEvent(uDelay: u32, uResolution: u32, fptc: usize, dwUser: usize, fuEvent: u32) callconv(w32cc.WINAPI) u32 {
    _ = uResolution;
    if (trace.enable_tracing) trace.print("WINMM: timeSetEvent(delay={d}, callback=0x{x}, flags=0x{x})\n", .{ uDelay, fptc, fuEvent });

    const TIME_PERIODIC = 1;

    // Find a free timer slot
    var slot: ?usize = null;
    for (&mm_timers, 0..) |*t, i| {
        if (!t.active) {
            slot = i;
            break;
        }
    }
    const idx = slot orelse return 0; // No free slots

    const id = timer_id_counter;
    timer_id_counter += 1;

    mm_timers[idx] = .{
        .active = true,
        .id = id,
        .delay_ms = if (uDelay < 1) 1 else uDelay,
        .callback = fptc,
        .user_data = dwUser,
        .periodic = (fuEvent & TIME_PERIODIC) != 0,
        .thread = if (platform.is_native) null else {},
    };

    // Spawn timer thread (only on native — WASM is single-threaded)
    if (comptime platform.is_native) {
        mm_timers[idx].thread = std.Thread.spawn(.{}, mmTimerThread, .{idx}) catch {
            mm_timers[idx].active = false;
            return 0;
        };
    } else {
        // On WASM, just mark as pending — we can't spawn threads
        mm_timers[idx].pending_fire = true;
    }

    return id;
}

/// timeKillEvent
/// Implementation status: Partially implemented
pub fn timeKillEvent(uTimerID: u32) callconv(w32cc.WINAPI) u32 {
    for (&mm_timers) |*t| {
        if (t.active and t.id == uTimerID) {
            t.active = false;
            if (comptime platform.is_native) {
                if (t.thread) |thread| {
                    thread.detach();
                }
                t.thread = null;
            }
            break;
        }
    }
    return 0; // TIMERR_NOERROR
}

/// --- waveOut stubs for MSS32.DLL ---
/// Implementation status: No-op fallback
pub fn stub_waveOutGetNumDevs() callconv(w32cc.WINAPI) u32 {
    if (trace.enable_tracing) trace.print("WINMM: waveOutGetNumDevs -> 1\n", .{});
    return 1; // One audio device available
}

/// MMRESULT waveOutOpen(LPHWAVEOUT phwo, UINT uDeviceID, LPCWAVEFORMATEX pwfx, DWORD_PTR dwCallback, DWORD_PTR dwInstance, DWORD fdwOpen)
/// Implementation status: Partially implemented
pub fn waveOutOpen(phwo: usize, uDeviceID: u32, pwfx: usize, dwCallback: usize, dwInstance: usize, fdwOpen: u32) callconv(w32cc.WINAPI) u32 {
    _ = uDeviceID;
    _ = pwfx;
    _ = dwCallback;
    _ = dwInstance;
    _ = fdwOpen;
    if (trace.enable_tracing) trace.print("WINMM: waveOutOpen\n", .{});
    // Write a fake handle to *phwo
    if (phwo != 0) {
        @as(*align(1) u32, @ptrFromInt(phwo)).* = 0xBEEF0040;
    }
    return 0; // MMSYSERR_NOERROR
}

/// stub_waveOutClose_
/// Implementation status: Stub
pub fn stub_waveOutClose_(hwo: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    if (trace.enable_tracing) trace.print("WINMM: waveOutClose\n", .{});
    return 0; // MMSYSERR_NOERROR
}

/// stub_waveOutReset
/// Implementation status: Stub
pub fn stub_waveOutReset(hwo: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    return 0;
}

/// MMRESULT waveOutWrite(HWAVEOUT hwo, LPWAVEHDR pwh, UINT cbwh)
/// Implementation status: Partially implemented
pub fn waveOutWrite(hwo: u32, pwh: usize, cbwh: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    _ = cbwh;
    // Mark the buffer as done immediately (set WHDR_DONE flag = 0x1)
    if (pwh != 0) {
        const flags_ptr = @as(*align(1) u32, @ptrFromInt(pwh + 16)); // dwFlags offset in WAVEHDR
        flags_ptr.* |= 0x1; // WHDR_DONE
    }
    return 0;
}

/// MMRESULT waveOutPrepareHeader(HWAVEOUT hwo, LPWAVEHDR pwh, UINT cbwh)
/// Implementation status: Partially implemented
pub fn waveOutPrepareHeader(hwo: u32, pwh: usize, cbwh: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    _ = cbwh;
    // Set WHDR_PREPARED flag
    if (pwh != 0) {
        const flags_ptr = @as(*align(1) u32, @ptrFromInt(pwh + 16));
        flags_ptr.* |= 0x2; // WHDR_PREPARED
    }
    return 0;
}

/// stub_waveOutUnprepareHeader
/// Implementation status: Stub
pub fn stub_waveOutUnprepareHeader(hwo: u32, pwh: usize, cbwh: u32) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    _ = cbwh;
    if (pwh != 0) {
        const flags_ptr = @as(*align(1) u32, @ptrFromInt(pwh + 16));
        flags_ptr.* &= ~@as(u32, 0x2); // Clear WHDR_PREPARED
    }
    return 0;
}

/// MMRESULT waveOutGetDevCapsA(UINT uDeviceID, LPWAVEOUTCAPS pwoc, UINT cbwoc)
/// Implementation status: Partially implemented
pub fn waveOutGetDevCapsA(uDeviceID: u32, pwoc: usize, cbwoc: u32) callconv(w32cc.WINAPI) u32 {
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

/// stub_waveOutGetID
/// Implementation status: Stub
pub fn stub_waveOutGetID(hwo: u32, puDeviceID: usize) callconv(w32cc.WINAPI) u32 {
    _ = hwo;
    if (puDeviceID != 0) {
        @as(*align(1) u32, @ptrFromInt(puDeviceID)).* = 0; // Device ID 0
    }
    return 0;
}

/// MMRESULT midiOutOpen(LPHMIDIOUT phmo, UINT uDeviceID, DWORD_PTR dwCallback, DWORD_PTR dwInstance, DWORD fdwOpen)
/// Implementation status: Partially implemented
pub fn midiOutOpen(phmo: usize, uDeviceID: u32, dwCallback: usize, dwInstance: usize, fdwOpen: u32) callconv(w32cc.WINAPI) u32 {
    _ = uDeviceID;
    _ = dwCallback;
    _ = dwInstance;
    _ = fdwOpen;
    if (phmo != 0) {
        @as(*align(1) u32, @ptrFromInt(phmo)).* = 0xBEEF0050;
    }
    return 0;
}
