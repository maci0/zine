//! DDRAW.dll registration.

const stubs = @import("ddraw/ddraw.zig");
pub const register = stubs.register;
