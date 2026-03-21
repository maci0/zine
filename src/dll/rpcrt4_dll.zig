//! RPCRT4.dll export definitions
const rpcrt4 = @import("win32").rpcrt4;
comptime {
    _ = @import("dll_common.zig");
    // UuidCreate and UuidToStringA have platform-specific behavior,
    // export stubs for basic functionality
}
