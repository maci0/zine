//! MSVCP60.dll export definitions
//! Microsoft Visual C++ 6.0 runtime stubs for std::basic_string and related.

const w32cc = @import("win32").calling_convention;

comptime {
    _ = @import("dll_common.zig");

    // basic_string constructor/destructor
    @export(&stub_noop_thiscall, .{ .name = "??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@ABV01@@Z" });
    @export(&stub_noop_thiscall, .{ .name = "??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@PBD@Z" });
    @export(&stub_noop_thiscall, .{ .name = "??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@PBDI@Z" });
    @export(&stub_noop_thiscall, .{ .name = "??0?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@XZ" });
    @export(&stub_noop_thiscall, .{ .name = "??1?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAE@XZ" });

    // basic_string operators
    @export(&stub_noop_thiscall, .{ .name = "??4?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV01@ABV01@@Z" });
    @export(&stub_noop_thiscall, .{ .name = "??4?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV01@PBD@Z" });
    @export(&stub_noop_thiscall, .{ .name = "??Y?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV01@ABV01@@Z" });
    @export(&stub_noop_thiscall, .{ .name = "??Y?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV01@PBD@Z" });
    @export(&stub_noop_thiscall, .{ .name = "??A?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAADI@Z" });

    // basic_string comparison
    @export(&stub_noop_thiscall, .{ .name = "??8std@@YA_NABV?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@0@0@Z" });
    @export(&stub_noop_thiscall, .{ .name = "??8std@@YA_NABV?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@0@PBD@Z" });

    // basic_string methods
    @export(&stub_noop_thiscall, .{ .name = "?c_str@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QBEPBDXZ" });
    @export(&stub_noop_thiscall, .{ .name = "?length@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QBEIXZ" });
    @export(&stub_noop_thiscall, .{ .name = "?size@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QBEIXZ" });
    @export(&stub_noop_thiscall, .{ .name = "?empty@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QBE_NXZ" });
    @export(&stub_noop_thiscall, .{ .name = "?find@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QBEIPBDII@Z" });
    @export(&stub_noop_thiscall, .{ .name = "?erase@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV12@II@Z" });
    @export(&stub_noop_thiscall, .{ .name = "?insert@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QAEAAV12@IPBD@Z" });
    @export(&stub_noop_thiscall, .{ .name = "?substr@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@QBE?AV12@II@Z" });

    // npos constant and null string
    @export(&npos_value, .{ .name = "?npos@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@2IB" });
    @export(&nullstr, .{ .name = "?_C@?1??_Nullstr@?$basic_string@DU?$char_traits@D@std@@V?$allocator@D@2@@std@@CAPBDXZ@4DB" });

    // _Lockit
    @export(&stub_noop_thiscall, .{ .name = "??0_Lockit@std@@QAE@XZ" });
    @export(&stub_noop_thiscall, .{ .name = "??1_Lockit@std@@QAE@XZ" });
}

fn stub_noop_thiscall() callconv(w32cc.WINAPI) void {}

var npos_value: u32 = 0xFFFFFFFF;
var nullstr: u8 = 0;
