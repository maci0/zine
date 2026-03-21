//! MSS32.dll (Miles Sound System) export definitions

const miles = @import("win32").mss32.miles;

comptime {
    _ = @import("dll_common.zig");

    @export(&miles.stub_startup, .{ .name = "_AIL_startup@0" });
    @export(&miles.stub_last_error, .{ .name = "_AIL_last_error@0" });
    @export(&miles.stub_get_timer_highest_delay, .{ .name = "_AIL_get_timer_highest_delay@0" });
    @export(&miles.waveOutOpen, .{ .name = "_AIL_waveOutOpen@16" });
    @export(&miles.stub_allocate_sample, .{ .name = "_AIL_allocate_sample_handle@4" });
    @export(&miles.stub_sample_status, .{ .name = "_AIL_sample_status@4" });
    @export(&miles.stub_open_stream, .{ .name = "_AIL_open_stream@12" });
    @export(&miles.stub_noop0, .{ .name = "_AIL_shutdown@0" });
    @export(&miles.stub_noop1, .{ .name = "_AIL_waveOutClose@4" });
    @export(&miles.stub_noop1, .{ .name = "_AIL_release_sample_handle@4" });
    @export(&miles.stub_noop1, .{ .name = "_AIL_init_sample@4" });
    @export(&miles.stub_noop1, .{ .name = "_AIL_start_sample@4" });
    @export(&miles.stub_noop1, .{ .name = "_AIL_stop_sample@4" });
    @export(&miles.stub_noop1, .{ .name = "_AIL_end_sample@4" });
    @export(&miles.stub_noop1, .{ .name = "_AIL_resume_sample@4" });
    @export(&miles.stub_noop1, .{ .name = "_AIL_close_stream@4" });
    @export(&miles.stub_noop1, .{ .name = "_AIL_start_stream@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_sample_playback_rate@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_sample_volume@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_sample_pan@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_sample_loop_count@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_active_sample_count@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_sample_position@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_stream_status@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_stream_playback_rate@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_stream_volume@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_stream_pan@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_stream_loop_count@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_digital_handle_release@4" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_digital_handle_reacquire@4" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_sample_playback_rate@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_sample_volume@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_sample_pan@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_sample_loop_count@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_preference@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_digital_master_volume@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_register_EOS_callback@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_stream_playback_rate@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_stream_volume@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_stream_pan@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_stream_loop_count@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_stream_ms_position@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_set_sample_ms_position@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_pause_stream@8" });
    @export(&miles.stub_noop2, .{ .name = "_AIL_register_stream_callback@8" });
    @export(&miles.stub_ret0_1, .{ .name = "_AIL_get_preference@4" });
    @export(&miles.stub_noop3, .{ .name = "_AIL_sample_ms_position@12" });
    @export(&miles.stub_noop3, .{ .name = "_AIL_stream_ms_position@12" });
    @export(&miles.stub_noop3, .{ .name = "_AIL_set_sample_type@12" });
    @export(&miles.stub_noop5, .{ .name = "_AIL_set_named_sample_file@20" });
    @export(&miles.stub_noop3, .{ .name = "_AIL_set_sample_file@12" });
}
