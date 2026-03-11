const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "mss32.dll";

    // Miles Sound System stubs - all decorated names with @N suffixes
    try environment.addBuiltinExport(m, "_AIL_startup@0", @intFromPtr(&stub_startup));
    try environment.addBuiltinExport(m, "_AIL_shutdown@0", @intFromPtr(&stub_noop0));
    try environment.addBuiltinExport(m, "_AIL_last_error@0", @intFromPtr(&stub_last_error));
    try environment.addBuiltinExport(m, "_AIL_get_timer_highest_delay@0", @intFromPtr(&stub_get_timer_highest_delay));
    try environment.addBuiltinExport(m, "_AIL_set_preference@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_get_preference@4", @intFromPtr(&stub_noop1));
    try environment.addBuiltinExport(m, "_AIL_waveOutOpen@16", @intFromPtr(&stub_waveOutOpen));
    try environment.addBuiltinExport(m, "_AIL_waveOutClose@4", @intFromPtr(&stub_noop1));
    try environment.addBuiltinExport(m, "_AIL_set_digital_master_volume@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_allocate_sample_handle@4", @intFromPtr(&stub_allocate_sample));
    try environment.addBuiltinExport(m, "_AIL_release_sample_handle@4", @intFromPtr(&stub_noop1));
    try environment.addBuiltinExport(m, "_AIL_init_sample@4", @intFromPtr(&stub_noop1));
    try environment.addBuiltinExport(m, "_AIL_set_named_sample_file@20", @intFromPtr(&stub_noop5));
    try environment.addBuiltinExport(m, "_AIL_set_sample_file@12", @intFromPtr(&stub_noop3));
    try environment.addBuiltinExport(m, "_AIL_set_sample_type@12", @intFromPtr(&stub_noop3));
    try environment.addBuiltinExport(m, "_AIL_set_sample_loop_count@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_start_sample@4", @intFromPtr(&stub_noop1));
    try environment.addBuiltinExport(m, "_AIL_stop_sample@4", @intFromPtr(&stub_noop1));
    try environment.addBuiltinExport(m, "_AIL_resume_sample@4", @intFromPtr(&stub_noop1));
    try environment.addBuiltinExport(m, "_AIL_end_sample@4", @intFromPtr(&stub_noop1));
    try environment.addBuiltinExport(m, "_AIL_set_sample_playback_rate@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_sample_playback_rate@4", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "_AIL_set_sample_volume@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_sample_volume@4", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "_AIL_set_sample_pan@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_sample_pan@4", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "_AIL_active_sample_count@4", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "_AIL_sample_loop_count@4", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "_AIL_sample_ms_position@12", @intFromPtr(&stub_noop3));
    try environment.addBuiltinExport(m, "_AIL_sample_position@4", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "_AIL_set_sample_ms_position@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_register_EOS_callback@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_sample_status@4", @intFromPtr(&stub_sample_status));
    try environment.addBuiltinExport(m, "_AIL_digital_handle_release@4", @intFromPtr(&stub_noop1));
    try environment.addBuiltinExport(m, "_AIL_digital_handle_reacquire@4", @intFromPtr(&stub_noop1));

    // Stream functions
    try environment.addBuiltinExport(m, "_AIL_open_stream@12", @intFromPtr(&stub_open_stream));
    try environment.addBuiltinExport(m, "_AIL_close_stream@4", @intFromPtr(&stub_noop1));
    try environment.addBuiltinExport(m, "_AIL_start_stream@4", @intFromPtr(&stub_noop1));
    try environment.addBuiltinExport(m, "_AIL_pause_stream@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_set_stream_playback_rate@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_set_stream_volume@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_set_stream_pan@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_set_stream_loop_count@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_set_stream_ms_position@8", @intFromPtr(&stub_noop2));
    try environment.addBuiltinExport(m, "_AIL_stream_status@4", @intFromPtr(&stub_sample_status));
    try environment.addBuiltinExport(m, "_AIL_stream_playback_rate@4", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "_AIL_stream_volume@4", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "_AIL_stream_pan@4", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "_AIL_stream_loop_count@4", @intFromPtr(&stub_ret0_1));
    try environment.addBuiltinExport(m, "_AIL_stream_ms_position@12", @intFromPtr(&stub_noop3));
    try environment.addBuiltinExport(m, "_AIL_register_stream_callback@8", @intFromPtr(&stub_noop2));
}

fn stub_startup() callconv(.winapi) i32 {
    if (trace.enable_tracing) trace.print("MSS32: AIL_startup\n", .{});
    return 1; // Success
}

fn stub_last_error() callconv(.winapi) usize {
    return @intFromPtr(&no_error_str);
}

var no_error_str: [1]u8 = .{0};

fn stub_get_timer_highest_delay() callconv(.winapi) u32 {
    return 1000;
}

fn stub_waveOutOpen(driver: usize, frequency: u32, bits: u32, channels: u32) callconv(.winapi) usize {
    _ = driver; _ = frequency; _ = bits; _ = channels;
    if (trace.enable_tracing) trace.print("MSS32: AIL_waveOutOpen\n", .{});
    return 0xBEEF0030; // Fake digital driver handle
}

fn stub_allocate_sample(driver: usize) callconv(.winapi) usize {
    _ = driver;
    return 0xBEEF0031; // Fake sample handle
}

fn stub_sample_status(sample: usize) callconv(.winapi) u32 {
    _ = sample;
    return 2; // SMP_DONE / SMP_STOPPED
}

fn stub_open_stream(driver: usize, filename: usize, mem_size: u32) callconv(.winapi) usize {
    _ = driver; _ = mem_size;
    if (trace.enable_tracing and filename != 0) {
        const name = trace.c_span(filename);
        trace.print("MSS32: AIL_open_stream('{s}')\n", .{name});
    }
    return 0xBEEF0032; // Fake stream handle
}

fn stub_noop0() callconv(.winapi) void {}
fn stub_noop1(a: usize) callconv(.winapi) void { _ = a; }
fn stub_noop2(a: usize, b: usize) callconv(.winapi) void { _ = a; _ = b; }
fn stub_noop3(a: usize, b: usize, c: usize) callconv(.winapi) void { _ = a; _ = b; _ = c; }
fn stub_noop5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(.winapi) void { _ = a; _ = b; _ = c; _ = d; _ = e; }
fn stub_ret0_1(a: usize) callconv(.winapi) u32 { _ = a; return 0; }
