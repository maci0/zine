//! OLE32.dll export definitions

const com = @import("win32").ole32.com;

comptime {
    _ = @import("dll_common.zig");

    @export(&com.stub_CoInitialize, .{ .name = "CoInitialize" });
    @export(&com.stub_CoInitializeEx, .{ .name = "CoInitializeEx" });
    @export(&com.stub_CoUninitialize, .{ .name = "CoUninitialize" });
    @export(&com.stub_CoCreateInstance, .{ .name = "CoCreateInstance" });
    @export(&com.CoTaskMemAlloc, .{ .name = "CoTaskMemAlloc" });
    @export(&com.stub_CoTaskMemFree, .{ .name = "CoTaskMemFree" });
    @export(&com.stub_DoDragDrop, .{ .name = "DoDragDrop" });
}
