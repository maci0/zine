//! OLE32.dll registration.

const env = @import("../loader/env.zig");
const stubs = @import("ole32/com.zig");

/// Registers OLE32.dll functions with the environment.
/// Implementation status: Partially implemented
pub fn register(environment: *env.Environment) !void {
    // ole32.dll
    const m = "ole32.dll";
    try environment.addBuiltinExportComptime(m, "CoInitialize", stubs.stub_CoInitialize);
    try environment.addBuiltinExportComptime(m, "CoInitializeEx", stubs.stub_CoInitializeEx);
    try environment.addBuiltinExportComptime(m, "CoUninitialize", stubs.stub_CoUninitialize);
    try environment.addBuiltinExportComptime(m, "CoCreateInstance", stubs.stub_CoCreateInstance);
    try environment.addBuiltinExportComptime(m, "CoTaskMemAlloc", stubs.CoTaskMemAlloc);
    try environment.addBuiltinExportComptime(m, "CoTaskMemFree", stubs.stub_CoTaskMemFree);
    try environment.addBuiltinExportComptime(m, "DoDragDrop", stubs.stub_DoDragDrop);

    // --- Remaining OLE32 stubs for 100% win2k coverage ---
    const kernel32 = @import("kernel32.zig");
    try environment.addBuiltinExportComptime(m, "StringFromCLSID", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "WriteFmtUserTypeStg", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "WriteClassStg", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "OleUninitialize", stubs.stub_CoUninitialize);
    try environment.addBuiltinExportComptime(m, "StgOpenStorage", kernel32.stub_args6);
    try environment.addBuiltinExportComptime(m, "OleRegGetUserType", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ReadClassStg", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "StgCreateDocfileOnILockBytes", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "CreateILockBytesOnHGlobal", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "ReleaseStgMedium", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "OleInitialize", stubs.stub_CoInitialize);

    try environment.addBuiltinExportComptime(m, "RegisterDragDrop", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "RevokeDragDrop", kernel32.stub_args1);
    try environment.addBuiltinExportComptime(m, "CoInitializeSecurity", kernel32.stub_args9);
    try environment.addBuiltinExportComptime(m, "CoSetProxyBlanket", kernel32.stub_args8);

    // --- Additional OLE32 stubs ---
    try environment.addBuiltinExportComptime(m, "CreateStreamOnHGlobal", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "CreateItemMoniker", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "StgCreateDocfile", kernel32.stub_args4);
    try environment.addBuiltinExportComptime(m, "CLSIDFromString", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "CoGetInterfaceAndReleaseStream", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "CoMarshalInterThreadInterfaceInStream", kernel32.stub_args3);
    try environment.addBuiltinExportComptime(m, "CoGetMalloc", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "IsEqualGUID", kernel32.stub_args2);
}
