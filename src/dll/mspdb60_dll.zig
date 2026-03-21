//! MSPDB60.dll export definitions
//! PDB (Program Database) stubs for CL.EXE / C1.DLL compatibility.

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    // MRE (Minimal Rebuild Engine) exports
    @export(&mre_stub_1, .{ .name = "_MREDrvOneTimeInit@4" });
    @export(&mre_stub_2, .{ .name = "_MREQueryMreDrv@8" });
    @export(&mre_stub_6, .{ .name = "_MREFOpenByName@24" });
    @export(&mre_stub_3, .{ .name = "_MREDrvFUpdateTargetFile@12" });
    @export(&mre_stub_2, .{ .name = "_MREDrvFFilesOutOfDate@8" });
    @export(&mre_release, .{ .name = "_MREDrvFRelease@4" });
    @export(&mre_stub_2, .{ .name = "_MREFClose@8" });
    @export(&mre_stub_4, .{ .name = "_MREDrvFSuccessfulCompile@16" });

    // PDB exports
    @export(&pdb_open_validate3, .{ .name = "?OpenValidate3@PDB@@SAHPBD0PAJQAD2PAK3PAPAU1@@Z" });
    @export(&trunc_st_from_sz, .{ .name = "TruncStFromSz" });
    @export(&sig_for_pb_cb, .{ .name = "SigForPbCb" });
    @export(&pdb_open_ex, .{ .name = "?OpenEx@PDB@@SAHPAD0KJPAJQADPAPAU1@@Z" });
    @export(&stub2_c, .{ .name = "?open@NameMap@@SAHPAUPDB@@HPAPAU1@@Z" });
    @export(&stub2_c, .{ .name = "?open@ILStore@@SAHPAUPDB@@HPAPAU1@@Z" });
    @export(&pdb_query_last_error, .{ .name = "PDBQueryLastError" });
    @export(&pdb_export_validate, .{ .name = "PDBExportValidateInterface" });
    @export(&types_query_ti, .{ .name = "TypesQueryTiForCVRecordEx" });
    @export(&mr_fopen, .{ .name = "?FOpen@MREngine@@SGHPAPAU1@PAUMreToPdb@@HH@Z" });
}

fn mre_stub_1(a: usize) callconv(w32cc.WINAPI) i32 { _ = a; return 1; }
fn mre_stub_2(a: usize, b: usize) callconv(w32cc.WINAPI) i32 { _ = .{ a, b }; return 1; }
fn mre_stub_3(a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 { _ = .{ a, b, c }; return 1; }
fn mre_stub_4(a: usize, b: usize, c: usize, d: usize) callconv(w32cc.WINAPI) i32 { _ = .{ a, b, c, d }; return 1; }
fn mre_stub_6(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) callconv(w32cc.WINAPI) i32 { _ = .{ a, b, c, d, e, f }; return 1; }
fn mre_release(a: usize) callconv(w32cc.WINAPI) void { _ = a; }
fn pdb_open_validate3(a: usize, b: usize, c: usize, d: usize, e: usize, f: usize, g: usize, h: usize, i: usize) callconv(.c) i32 { _ = .{ a, b, c, d, e, f, g, h, i }; return 1; }
fn trunc_st_from_sz(a: usize, b: usize) callconv(.c) void { _ = .{ a, b }; }
fn sig_for_pb_cb(a: usize, b: usize) callconv(.c) u32 { _ = .{ a, b }; return 0; }
fn pdb_open_ex(a: usize, b: usize, c: u32, d: usize, e: usize, f: usize, g: usize) callconv(.c) i32 { _ = .{ a, b, c, d, e, f, g }; return 1; }
fn stub2_c(a: usize, b: usize, c: usize) callconv(.c) i32 { _ = .{ a, b, c }; return 1; }
fn pdb_query_last_error(a: usize, b: usize) callconv(.c) i32 { _ = .{ a, b }; return 0; }
fn pdb_export_validate(a: usize) callconv(.c) i32 { _ = a; return 1; }
fn types_query_ti(a: usize, b: usize, c: usize) callconv(.c) i32 { _ = .{ a, b, c }; return 0; }
fn mr_fopen(a: usize, b: usize, c: i32, d: i32) callconv(w32cc.WINAPI) i32 { _ = .{ a, b, c, d }; return 0; }
