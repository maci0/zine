//! USER32.dll export definitions

const w32 = @import("win32");
const window = w32.user32.window;
const message = w32.user32.message;
const resource = w32.user32.resource;

comptime {
    _ = @import("dll_common.zig");

    // Window
    @export(&window.RegisterClassA, .{ .name = "RegisterClassA" });
    @export(&window.SystemParametersInfoA, .{ .name = "SystemParametersInfoA" });

    // Message
    @export(&message.PeekMessageA, .{ .name = "PeekMessageA" });
    @export(&message.GetMessageA, .{ .name = "GetMessageA" });
    @export(&message.DispatchMessageA, .{ .name = "DispatchMessageA" });

    // Resource
    @export(&resource.LoadStringA, .{ .name = "LoadStringA" });
}
