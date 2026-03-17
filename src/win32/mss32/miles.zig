const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");

/// stub_startup
/// Implementation status: No-op fallback
pub fn stub_startup() callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("MSS32: AIL_startup\n", .{});
    return 1; // Success
}

/// stub_last_error
/// Implementation status: No-op fallback
pub fn stub_last_error() callconv(w32cc.WINAPI) [*:0]const u8 {
    return @ptrCast(&no_error_str);
}

var no_error_str: [1]u8 = .{0};

/// stub_get_timer_highest_delay
/// Implementation status: No-op fallback
pub fn stub_get_timer_highest_delay() callconv(w32cc.WINAPI) u32 {
    return 1000;
}

/// waveOutOpen
/// Implementation status: Partially implemented
pub fn waveOutOpen(driver: usize, frequency: u32, bits: u32, channels: u32) callconv(w32cc.WINAPI) usize {
    _ = driver;
    _ = frequency;
    _ = bits;
    _ = channels;
    if (trace.enable_tracing) trace.print("MSS32: AIL_waveOutOpen\n", .{});
    return 0xBEEF0030; // Fake digital driver handle
}

/// stub_allocate_sample
/// Implementation status: Stub
pub fn stub_allocate_sample(driver: usize) callconv(w32cc.WINAPI) usize {
    _ = driver;
    return 0xBEEF0031; // Fake sample handle
}

/// stub_sample_status
/// Implementation status: No-op fallback
pub fn stub_sample_status(sample: usize) callconv(w32cc.WINAPI) u32 {
    _ = sample;
    return 2; // SMP_DONE / SMP_STOPPED
}

/// stub_open_stream
/// Implementation status: Stub
pub fn stub_open_stream(driver: usize, filename: usize, mem_size: u32) callconv(w32cc.WINAPI) usize {
    _ = driver;
    _ = mem_size;
    if (trace.enable_tracing and filename != 0) {
        const name = trace.c_span(filename);
        trace.print("MSS32: AIL_open_stream('{s}')\n", .{name});
    }
    return 0xBEEF0032; // Fake stream handle
}

/// stub_noop0
/// Implementation status: Stub
pub fn stub_noop0() callconv(w32cc.WINAPI) void {}
/// stub_noop1
/// Implementation status: Stub
pub fn stub_noop1(a: usize) callconv(w32cc.WINAPI) void {
    _ = a;
}
/// stub_noop2
/// Implementation status: Stub
pub fn stub_noop2(a: usize, b: usize) callconv(w32cc.WINAPI) void {
    _ = a;
    _ = b;
}
/// stub_noop3
/// Implementation status: Stub
pub fn stub_noop3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) void {
    _ = a;
    _ = b;
    _ = c;
}
/// stub_noop5
/// Implementation status: Stub
pub fn stub_noop5(a: usize, b: usize, c: usize, d: usize, e: usize) callconv(w32cc.WINAPI) void {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    _ = e;
}
/// stub_ret0_1
/// Implementation status: Stub
pub fn stub_ret0_1(a: usize) callconv(w32cc.WINAPI) u32 {
    _ = a;
    return 0;
}
