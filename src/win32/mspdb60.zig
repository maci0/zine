//! MSPDB60.dll stub registration.
//!
//! Provides no-op stubs for the Minimal Rebuild Engine (MRE) and PDB functions
//! imported by CL.EXE and LINK.EXE. Returning 0/failure causes CL to fall back
//! to non-incremental compilation and LINK to skip PDB generation.

const env = @import("../loader/env.zig");
const trace = @import("../trace.zig");
const w32cc = @import("calling_convention.zig");

// ---------------------------------------------------------------------------
// MRE functions (stdcall, used by CL.EXE)
// All return 0 (FALSE) so CL falls back to full (non-incremental) compilation.
// ---------------------------------------------------------------------------

fn mre_stub_1(a: usize) callconv(w32cc.WINAPI) i32 {
    _ = a;
    if (trace.enable_tracing) trace.print("MSPDB60: MRE stub(1) -> 0\n", .{});
    return 0;
}

fn mre_stub_2(a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b };
    if (trace.enable_tracing) trace.print("MSPDB60: MRE stub(2) -> 0\n", .{});
    return 0;
}

fn mre_stub_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c };
    if (trace.enable_tracing) trace.print("MSPDB60: MRE stub(3) -> 0\n", .{});
    return 0;
}

fn mre_stub_4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d };
    if (trace.enable_tracing) trace.print("MSPDB60: MRE stub(4) -> 0\n", .{});
    return 0;
}

fn mre_stub_6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d, e, f };
    if (trace.enable_tracing) trace.print("MSPDB60: MRE stub(6) -> 0\n", .{});
    return 0;
}

fn mre_release(a: usize) callconv(w32cc.WINAPI) void {
    _ = a;
    if (trace.enable_tracing) trace.print("MSPDB60: MREDrvFRelease\n", .{});
}

// ---------------------------------------------------------------------------
// PDB functions (cdecl, used by LINK.EXE)
// OpenValidate3 returns 0 (failure) so LINK skips PDB operations.
// ---------------------------------------------------------------------------

fn pdb_open_validate3(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize) callconv(.c) i32 {
    _ = .{ a, b, c, d, e, f, g, h };
    if (trace.enable_tracing) trace.print("MSPDB60: PDB::OpenValidate3 -> 0 (no PDB)\n", .{});
    return 0;
}

fn trunc_st_from_sz(dst: usize, src: usize) callconv(.c) void {
    _ = .{ dst, src };
}

fn sig_for_pb_cb(pb: usize, cb: usize) callconv(.c) u32 {
    _ = .{ pb, cb };
    return 0;
}

// ---------------------------------------------------------------------------
// Additional PDB/MRE functions (cdecl, used by C1.DLL)
// ---------------------------------------------------------------------------

fn pdb_open_ex(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize) callconv(.c) i32 {
    _ = .{ a, b, c, d, e, f, g };
    if (trace.enable_tracing) trace.print("MSPDB60: PDB::OpenEx -> 0 (no PDB)\n", .{});
    return 0;
}

fn pdb_open_3(a: usize, b: usize, c: usize) callconv(.c) i32 {
    _ = .{ a, b, c };
    if (trace.enable_tracing) trace.print("MSPDB60: open(3) -> 0\n", .{});
    return 0;
}

fn pdb_query_last_error(a: usize, b: usize) callconv(.c) i32 {
    _ = .{ a, b };
    return 0;
}

fn pdb_export_validate(a: usize) callconv(.c) i32 {
    _ = a;
    return 1; // pretend interface is valid
}

fn types_query_ti(a: usize, b: usize, c: usize, d: usize) callconv(.c) i32 {
    _ = .{ a, b, c, d };
    return 0;
}

fn mr_fopen(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ a, b, c, d };
    if (trace.enable_tracing) trace.print("MSPDB60: MREngine::FOpen -> 0\n", .{});
    return 0;
}

/// Registers MSPDB60.dll functions with the environment.
pub fn register(environment: *env.Environment) !void {
    const m = "MSPDB60.dll";

    // MRE functions (stdcall — auto-detected from DLL name)
    try environment.addBuiltinExportComptime(m, "_MREDrvOneTimeInit@4", mre_stub_1);
    try environment.addBuiltinExportComptime(m, "_MREQueryMreDrv@8", mre_stub_2);
    try environment.addBuiltinExportComptime(m, "_MREFOpenByName@24", mre_stub_6);
    try environment.addBuiltinExportComptime(m, "_MREDrvFUpdateTargetFile@12", mre_stub_3);
    try environment.addBuiltinExportComptime(m, "_MREDrvFFilesOutOfDate@8", mre_stub_2);
    try environment.addBuiltinExportComptime(m, "_MREDrvFRelease@4", mre_release);
    try environment.addBuiltinExportComptime(m, "_MREFClose@8", mre_stub_2);
    try environment.addBuiltinExportComptime(m, "_MREDrvFSuccessfulCompile@16", mre_stub_4);

    // PDB functions (cdecl — must specify explicitly)
    try environment.addBuiltinExportComptimeCC(m, "?OpenValidate3@PDB@@SAHPBD0PAJQAD2PAK3PAPAU1@@Z", pdb_open_validate3, true);
    try environment.addBuiltinExportComptimeCC(m, "TruncStFromSz", trunc_st_from_sz, true);
    try environment.addBuiltinExportComptimeCC(m, "SigForPbCb", sig_for_pb_cb, true);

    // C1.DLL PDB imports (cdecl)
    try environment.addBuiltinExportComptimeCC(m, "?OpenEx@PDB@@SAHPAD0KJPAJQADPAPAU1@@Z", pdb_open_ex, true);
    try environment.addBuiltinExportComptimeCC(m, "?open@NameMap@@SAHPAUPDB@@HPAPAU1@@Z", pdb_open_3, true);
    try environment.addBuiltinExportComptimeCC(m, "?open@ILStore@@SAHPAUPDB@@HPAPAU1@@Z", pdb_open_3, true);
    try environment.addBuiltinExportComptimeCC(m, "PDBQueryLastError", pdb_query_last_error, true);
    try environment.addBuiltinExportComptimeCC(m, "PDBExportValidateInterface", pdb_export_validate, true);
    try environment.addBuiltinExportComptimeCC(m, "TypesQueryTiForCVRecordEx", types_query_ti, true);

    // C1.DLL MREngine import (stdcall — @Z suffix with SGH = stdcall)
    try environment.addBuiltinExportComptime(m, "?FOpen@MREngine@@SGHPAPAU1@PAUMreToPdb@@HH@Z", mr_fopen);
}
