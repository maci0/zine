const env = @import("../loader/env.zig");
const stubs = @import("ole32/stubs.zig");

pub fn register(environment: *env.Environment) !void {
    // ole32.dll
    const m = "ole32.dll";
    try environment.addBuiltinExportComptime(m, "CoInitialize", stubs.stub_CoInitialize);
    try environment.addBuiltinExportComptime(m, "CoInitializeEx", stubs.stub_CoInitializeEx);
    try environment.addBuiltinExportComptime(m, "CoUninitialize", stubs.stub_CoUninitialize);
    try environment.addBuiltinExportComptime(m, "CoCreateInstance", stubs.stub_CoCreateInstance);
    try environment.addBuiltinExportComptime(m, "CoTaskMemAlloc", stubs.stub_CoTaskMemAlloc);
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

    // --- Notepad2 OLE32 stubs ---
    try environment.addBuiltinExportComptime(m, "RegisterDragDrop", kernel32.stub_args2);
    try environment.addBuiltinExportComptime(m, "RevokeDragDrop", kernel32.stub_args1);
}
