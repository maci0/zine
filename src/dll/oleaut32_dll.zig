//! OLEAUT32.dll export definitions

const com = @import("win32").ole32.com;

comptime {
    _ = @import("dll_common.zig");

    @export(&com.SysFreeString, .{ .name = "SysFreeString" });
    @export(&com.SysAllocStringLen, .{ .name = "SysAllocStringLen" });
    @export(&com.SysAllocString, .{ .name = "SysAllocString" });
    @export(&com.SysStringLen, .{ .name = "SysStringLen" });
    @export(&com.SysStringByteLen, .{ .name = "SysStringByteLen" });
    @export(&com.VariantClear, .{ .name = "VariantClear" });
    @export(&com.VariantInit, .{ .name = "VariantInit" });
}
