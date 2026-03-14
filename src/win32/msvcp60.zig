const env = @import("../loader/env.zig");
const stub_common = @import("stub_common.zig");

pub fn register(environment: *env.Environment) !void {
    const m = "msvcp60.dll";

    // --- std::basic_string<char> constructors ---
    // All C++ string operations are mapped to generic stubs.
    // These return 0 (EAX), which makes the guest code think construction/operations
    // "failed" or returned null. This is acceptable for initial launch since Notepad2
    // may not exercise msvcp60 heavily during startup.

    // ??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@ABV?$allocator@D@1@@Z
    //   basic_string(const allocator&)  -- default ctor
    try environment.addBuiltinExportComptime(m, "??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@ABV?$allocator@D@1@@Z", stub_common.stub_args1);

    // ??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@ABV01@@Z
    //   basic_string(const basic_string&)  -- copy ctor
    try environment.addBuiltinExportComptime(m, "??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@ABV01@@Z", stub_common.stub_args1);

    // ??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@PBDABV?$allocator@D@1@@Z
    //   basic_string(const char*, const allocator&) -- from c-str
    try environment.addBuiltinExportComptime(m, "??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@PBDABV?$allocator@D@1@@Z", stub_common.stub_args2);

    // ??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@PBDIABV?$allocator@D@1@@Z
    //   basic_string(const char*, size_t, const allocator&)
    try environment.addBuiltinExportComptime(m, "??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@PBDIABV?$allocator@D@1@@Z", stub_common.stub_args3);

    // ??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@IDABV?$allocator@D@1@@Z
    //   basic_string(size_t, char, const allocator&)
    try environment.addBuiltinExportComptime(m, "??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@IDABV?$allocator@D@1@@Z", stub_common.stub_args3);

    // ??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@ABV01@IIABV?$allocator@D@1@@Z
    //   basic_string(const basic_string&, size_t, size_t, const allocator&) -- substr ctor
    try environment.addBuiltinExportComptime(m, "??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@ABV01@IIABV?$allocator@D@1@@Z", stub_common.stub_args4);

    // ??1?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@XZ
    //   ~basic_string()  -- destructor
    try environment.addBuiltinExportComptime(m, "??1?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@XZ", stub_noop_thiscall);

    // --- Assignment & append ---
    // ??4 = operator=
    try environment.addBuiltinExportComptime(m, "??4?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV01@ABV01@@Z", stub_common.stub_args1);
    try environment.addBuiltinExportComptime(m, "??4?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV01@PBD@Z", stub_common.stub_args1);
    // ??Y = operator+=
    try environment.addBuiltinExportComptime(m, "??Y?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV01@PBD@Z", stub_common.stub_args1);
    try environment.addBuiltinExportComptime(m, "??Y?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV01@D@Z", stub_common.stub_args1);
    
    // --- Accessors ---
    // ??A = operator[]
    try environment.addBuiltinExportComptime(m, "??A?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAADI@Z", stub_npos);

    // --- Comparison operators ---
    // ??8 = operator==, ??9 = operator!=, ??M = operator<
    try environment.addBuiltinExportComptime(m, "??8std@@YA_NABV?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@0@PBD@Z", stub_common.stub_args2);
    try environment.addBuiltinExportComptime(m, "??9std@@YA_NABV?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@0@PBD@Z", stub_common.stub_args2);
    try environment.addBuiltinExportComptime(m, "??9std@@YA_NABV?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@0@0@Z", stub_common.stub_args2);
    try environment.addBuiltinExportComptime(m, "??Mstd@@YA_NABV?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@0@0@Z", stub_common.stub_args2);

    // --- Methods: find, erase, insert ---
    try environment.addBuiltinExportComptime(m, "?find@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QBEIPBDI@Z", stub_npos);
    try environment.addBuiltinExportComptime(m, "?erase@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV12@II@Z", stub_common.stub_args2);
    try environment.addBuiltinExportComptime(m, "?insert@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV12@IPBDI@Z", stub_common.stub_args3);

    // --- npos data export ---
    try environment.addBuiltinExport(m, "?npos@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@2IB", @intFromPtr(&npos_value));

    // --- _Nullstr ---
    try environment.addBuiltinExport(m, "?_C@?1??_Nullstr@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@CAPBDXZ@4DB", @intFromPtr(&nullstr));

    // --- _Lockit ---
    try environment.addBuiltinExportComptime(m, "??0_Lockit@std@@QAE@XZ", stub_noop_thiscall);
    try environment.addBuiltinExportComptime(m, "??1_Lockit@std@@QAE@XZ", stub_noop_thiscall);
}

var npos_value: u32 = 0xFFFFFFFF;
var nullstr: u8 = 0;

const w32cc = @import("../calling_convention.zig");

// thiscall no-op: ignored this pointer, returns void  
fn stub_noop_thiscall() callconv(w32cc.WINAPI) void {}

// return npos (0xFFFFFFFF) for find() and operator[] failure
fn stub_npos(_: usize, _: usize) callconv(w32cc.WINAPI) usize {
    return 0xFFFFFFFF;
}
