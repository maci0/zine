//! MSS32.dll registration.

const env = @import("../loader/env.zig");
const stubs = @import("mss32/miles.zig");

/// Registers MSS32.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    const m = "mss32.dll";

    // Miles Sound System stubs - all decorated names with @N suffixes
    try environment.addBuiltinExportComptime(m, "_AIL_startup@0", stubs.stub_startup);
    try environment.addBuiltinExportComptime(m, "_AIL_shutdown@0", stubs.stub_noop0);
    try environment.addBuiltinExportComptime(m, "_AIL_last_error@0", stubs.stub_last_error);
    try environment.addBuiltinExportComptime(m, "_AIL_get_timer_highest_delay@0", stubs.stub_get_timer_highest_delay);
    try environment.addBuiltinExportComptime(m, "_AIL_set_preference@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_get_preference@4", stubs.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_AIL_waveOutOpen@16", stubs.waveOutOpen);
    try environment.addBuiltinExportComptime(m, "_AIL_waveOutClose@4", stubs.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_AIL_set_digital_master_volume@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_allocate_sample_handle@4", stubs.stub_allocate_sample);
    try environment.addBuiltinExportComptime(m, "_AIL_release_sample_handle@4", stubs.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_AIL_init_sample@4", stubs.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_AIL_set_named_sample_file@20", stubs.stub_noop5);
    try environment.addBuiltinExportComptime(m, "_AIL_set_sample_file@12", stubs.stub_noop3);
    try environment.addBuiltinExportComptime(m, "_AIL_set_sample_type@12", stubs.stub_noop3);
    try environment.addBuiltinExportComptime(m, "_AIL_set_sample_loop_count@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_start_sample@4", stubs.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_AIL_stop_sample@4", stubs.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_AIL_resume_sample@4", stubs.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_AIL_end_sample@4", stubs.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_AIL_set_sample_playback_rate@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_sample_playback_rate@4", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "_AIL_set_sample_volume@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_sample_volume@4", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "_AIL_set_sample_pan@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_sample_pan@4", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "_AIL_active_sample_count@4", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "_AIL_sample_loop_count@4", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "_AIL_sample_ms_position@12", stubs.stub_noop3);
    try environment.addBuiltinExportComptime(m, "_AIL_sample_position@4", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "_AIL_set_sample_ms_position@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_register_EOS_callback@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_sample_status@4", stubs.stub_sample_status);
    try environment.addBuiltinExportComptime(m, "_AIL_digital_handle_release@4", stubs.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_AIL_digital_handle_reacquire@4", stubs.stub_noop1);

    // Stream functions
    try environment.addBuiltinExportComptime(m, "_AIL_open_stream@12", stubs.stub_open_stream);
    try environment.addBuiltinExportComptime(m, "_AIL_close_stream@4", stubs.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_AIL_start_stream@4", stubs.stub_noop1);
    try environment.addBuiltinExportComptime(m, "_AIL_pause_stream@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_set_stream_playback_rate@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_set_stream_volume@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_set_stream_pan@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_set_stream_loop_count@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_set_stream_ms_position@8", stubs.stub_noop2);
    try environment.addBuiltinExportComptime(m, "_AIL_stream_status@4", stubs.stub_sample_status);
    try environment.addBuiltinExportComptime(m, "_AIL_stream_playback_rate@4", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "_AIL_stream_volume@4", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "_AIL_stream_pan@4", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "_AIL_stream_loop_count@4", stubs.stub_ret0_1);
    try environment.addBuiltinExportComptime(m, "_AIL_stream_ms_position@12", stubs.stub_noop3);
    try environment.addBuiltinExportComptime(m, "_AIL_register_stream_callback@8", stubs.stub_noop2);
}
