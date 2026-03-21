//! RCDLL.dll export definitions
//! Resource compiler DLL stubs for RC.EXE compatibility.

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    @export(&rc_main, .{ .name = "RC" });
    @export(&rc_handler, .{ .name = "Handler" });
}

fn rc_main(argc: i32, argv: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ argc, argv };
    return 0; // Success
}

fn rc_handler(action: usize) callconv(w32cc.WINAPI) void {
    _ = action;
}
