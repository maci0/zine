//! ADVAPI32 user management, service control, and generic stub helpers.

const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");

// -------------------------------------------------------------------------
// User management
// -------------------------------------------------------------------------

/// Retrieves the name of the user associated with the current thread.
/// Implementation status: Partially implemented (returns hardcoded "User")
pub fn GetUserNameA(lpBuffer: ?[*]u8, pcbBuffer: ?*u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("ADVAPI32: GetUserNameA\n", .{});
    const name = "User";
    if (lpBuffer) |buf| {
        if (pcbBuffer) |cb| {
            if (cb.* >= name.len + 1) {
                @memcpy(buf[0..name.len], name);
                buf[name.len] = 0;
                cb.* = @intCast(name.len + 1);
                return 1;
            }
        }
    }
    if (pcbBuffer) |cb| cb.* = @intCast(name.len + 1);
    return 0;
}

/// Wide-char version of GetUserNameA. Returns hardcoded L"User".
/// Implementation status: Partially implemented (returns hardcoded "User")
pub fn GetUserNameW(lpBuffer: ?[*]u16, pcbBuffer: ?*u32) callconv(w32cc.WINAPI) i32 {
    if (trace.enable_tracing) trace.print("ADVAPI32: GetUserNameW\n", .{});
    const name = [_]u16{ 'U', 's', 'e', 'r', 0 };
    const name_chars: u32 = 5; // 4 chars + null
    if (lpBuffer) |buf| {
        if (pcbBuffer) |cb| {
            if (cb.* >= name_chars) {
                for (0..name_chars) |i| buf[i] = name[i];
                cb.* = name_chars;
                return 1;
            }
        }
    }
    if (pcbBuffer) |cb| cb.* = name_chars;
    return 0;
}

// -------------------------------------------------------------------------
// Generic stub helpers (returns TRUE)
// -------------------------------------------------------------------------

/// Helper function that takes 1 argument and always returns TRUE (1).
pub fn stub_ret_true_1(a: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    return 1; // TRUE
}

/// Helper function that takes 2 arguments and always returns TRUE (1).
pub fn stub_ret_true_2(a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    return 1;
}

/// Helper function that takes 3 arguments and always returns TRUE (1).
pub fn stub_ret_true_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    _ = c;
    return 1;
}

/// Helper function that takes 4 arguments and always returns TRUE (1).
pub fn stub_ret_true_4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    _ = b;
    _ = c;
    _ = d;
    return 1;
}

// -------------------------------------------------------------------------
// Service Control Manager
// -------------------------------------------------------------------------

/// Next available handle for Service Control Manager stubs.
pub var next_sc_handle: usize = 0xFE100001;

/// Establishes a connection to the service control manager.
pub fn OpenSCManagerA(lpMachineName: usize, lpDatabaseName: usize, dwDesiredAccess: u32) callconv(w32cc.WINAPI) usize {
    _ = .{ lpMachineName, lpDatabaseName, dwDesiredAccess };
    if (trace.enable_tracing) trace.print("ADVAPI32: OpenSCManagerA -> fake handle\n", .{});
    next_sc_handle +%= 1;
    return next_sc_handle - 1;
}

/// Opens an existing service.
pub fn OpenServiceA(hSCManager: usize, lpServiceName: usize, dwDesiredAccess: u32) callconv(w32cc.WINAPI) usize {
    _ = .{ hSCManager, dwDesiredAccess };
    if (trace.enable_tracing) {
        const name = if (lpServiceName != 0) trace.c_span(lpServiceName) else "(null)";
        trace.print("ADVAPI32: OpenServiceA('{s}') -> fake handle\n", .{name});
    }
    next_sc_handle +%= 1;
    return next_sc_handle - 1;
}

/// Creates a service object and adds it to the specified service control manager database.
pub fn CreateServiceA(hSCManager: usize, lpServiceName: usize, lpDisplayName: usize, dwDesiredAccess: u32, dwServiceType: u32, dwStartType: u32, dwErrorControl: u32, lpBinaryPathName: usize, a9: usize) callconv(w32cc.WINAPI) usize {
    _ = .{ hSCManager, lpDisplayName, dwDesiredAccess, dwServiceType, dwStartType, dwErrorControl, lpBinaryPathName, a9 };
    if (trace.enable_tracing) {
        const name = if (lpServiceName != 0) trace.c_span(lpServiceName) else "(null)";
        trace.print("ADVAPI32: CreateServiceA('{s}') -> fake handle\n", .{name});
    }
    next_sc_handle +%= 1;
    return next_sc_handle - 1;
}

/// Starts a service.
pub fn StartServiceA(hService: usize, dwNumServiceArgs: u32, lpServiceArgVectors: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ hService, dwNumServiceArgs, lpServiceArgVectors };
    if (trace.enable_tracing) trace.print("ADVAPI32: StartServiceA -> TRUE\n", .{});
    return 1; // TRUE
}

/// Sends a control code to a service.
pub fn ControlService(hService: usize, dwControl: u32, lpServiceStatus: usize) callconv(w32cc.WINAPI) i32 {
    _ = hService;
    if (trace.enable_tracing) trace.print("ADVAPI32: ControlService(control={d})\n", .{dwControl});
    if (lpServiceStatus != 0) {
        const status = @as([*]u32, @ptrFromInt(lpServiceStatus));
        status[0] = 0x10; // SERVICE_WIN32_OWN_PROCESS
        // INTERROGATE (4) → RUNNING, STOP (1) → STOP_PENDING
        status[1] = if (dwControl == 1) @as(u32, 3) else @as(u32, 4);
        status[2] = 0x05; // SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_PAUSE_CONTINUE
        status[3] = 0;
        status[4] = 0;
        status[5] = 0;
        status[6] = 0;
    }
    return 1; // TRUE
}

/// Retrieves the current status of the specified service.
pub fn QueryServiceStatus(hService: usize, lpServiceStatus: usize) callconv(w32cc.WINAPI) i32 {
    _ = hService;
    if (lpServiceStatus != 0) {
        const status = @as([*]u32, @ptrFromInt(lpServiceStatus));
        status[0] = 0x10; // SERVICE_WIN32_OWN_PROCESS
        status[1] = 1; // SERVICE_STOPPED
        status[2] = 0; // dwControlsAccepted
        status[3] = 0; // dwWin32ExitCode
        status[4] = 0; // dwServiceSpecificExitCode
        status[5] = 0; // dwCheckPoint
        status[6] = 0; // dwWaitHint
    }
    return 1; // TRUE
}

// =============================================================================
// Tests
// =============================================================================

test "stub_ret_true_2 always returns TRUE" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, 1), stub_ret_true_2(0x1234, 1));
    try std.testing.expectEqual(@as(i32, 1), stub_ret_true_2(0, 0));
}
