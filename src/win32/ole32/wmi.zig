//! Minimal WMI stub for cpuidsdk.dll
//! Implements: IWbemLocator → IWbemServices → IEnumWbemClassObject → IWbemClassObject
//!
//! cpuidsdk queries "SELECT * FROM Win32_Processor" and reads properties
//! like "Name", "MaxClockSpeed", "NumberOfCores", etc.

const std = @import("std");
const trace = @import("../../trace.zig");
const w32cc = @import("../calling_convention.zig");
const shared = @import("../shared.zig");

/// CLSID for WbemLocator: {4590F811-1D3A-11D0-891F-00AA004B2E24}
pub const CLSID_WbemLocator = [16]u8{
    0x11, 0xF8, 0x90, 0x45, 0x3A, 0x1D, 0xD0, 0x11,
    0x89, 0x1F, 0x00, 0xAA, 0x00, 0x4B, 0x2E, 0x24,
};

// --- Common COM stubs ---

fn comQueryInterface(this: usize, riid: usize, ppv: usize) callconv(w32cc.WINAPI) i32 {
    _ = riid;
    if (ppv != 0) @as(*usize, @ptrFromInt(ppv)).* = this; // return self
    return 0; // S_OK
}
fn comAddRef(_: usize) callconv(w32cc.WINAPI) u32 {
    return 1;
}
fn comRelease(_: usize) callconv(w32cc.WINAPI) u32 {
    return 1;
}
fn comStub4(_: usize, _: usize, _: usize, _: usize, _: usize) callconv(w32cc.WINAPI) i32 {
    return 0;
}
fn comStub5(_: usize, _: usize, _: usize, _: usize, _: usize, _: usize) callconv(w32cc.WINAPI) i32 {
    return 0;
}
fn comStub7(_: usize, _: usize, _: usize, _: usize, _: usize, _: usize, _: usize, _: usize) callconv(w32cc.WINAPI) i32 {
    return 0;
}

// --- IWbemLocator ---
// vtable[3] = ConnectServer

fn wbemLocatorConnectServer(
    this: usize,
    strNetworkResource: usize,
    strUser: usize,
    strPassword: usize,
    strLocale: usize,
    lSecurityFlags: i32,
    strAuthority: usize,
    pCtx: usize,
    ppNamespace: usize,
) callconv(w32cc.WINAPI) i32 {
    _ = .{ this, strNetworkResource, strUser, strPassword, strLocale, lSecurityFlags, strAuthority, pCtx };
    if (trace.enable_tracing) trace.print("WMI: IWbemLocator::ConnectServer\n", .{});
    if (ppNamespace != 0) {
        initAll();
        @as(*usize, @ptrFromInt(ppNamespace)).* = @intFromPtr(&wbem_services_obj);
    }
    return 0; // S_OK (WBEM_S_NO_ERROR)
}

var wbem_locator_vtable: [4]usize = undefined;
/// IWbemLocator instance.
pub var wbem_locator_obj: [1]usize = undefined;

// --- IWbemServices ---
// vtable[20] = ExecQuery

fn wbemServicesCreateInstanceEnum(
    this: usize,
    strFilter: usize,
    lFlags: i32,
    pCtx: usize,
    ppEnum: usize,
) callconv(w32cc.WINAPI) i32 {
    _ = .{ this, strFilter, lFlags, pCtx };
    if (trace.enable_tracing) trace.print("WMI: IWbemServices::CreateInstanceEnum\n", .{});
    if (ppEnum != 0) {
        initAll();
        enum_returned = false;
        @as(*usize, @ptrFromInt(ppEnum)).* = @intFromPtr(&wbem_enum_obj);
    }
    return 0; // WBEM_S_NO_ERROR
}

fn wbemServicesExecQuery(
    this: usize,
    strQueryLanguage: usize,
    strQuery: usize,
    lFlags: i32,
    pCtx: usize,
    ppEnum: usize,
) callconv(w32cc.WINAPI) i32 {
    _ = .{ this, strQueryLanguage, lFlags, pCtx };
    if (trace.enable_tracing) {
        if (strQuery != 0) {
            // Read BSTR (wide string at strQuery, length prefix at strQuery-4)
            const wptr = @as([*]const u16, @ptrFromInt(strQuery));
            var buf: [128]u8 = undefined;
            var len: usize = 0;
            while (len < 127 and wptr[len] != 0) : (len += 1) buf[len] = @truncate(wptr[len]);
            trace.print("WMI: IWbemServices::ExecQuery('{s}')\n", .{buf[0..len]});
        }
    }
    if (ppEnum != 0) {
        initAll();
        enum_returned = false; // reset enumerator
        @as(*usize, @ptrFromInt(ppEnum)).* = @intFromPtr(&wbem_enum_obj);
    }
    return 0; // WBEM_S_NO_ERROR
}

var wbem_services_vtable: [26]usize = undefined;
var wbem_services_obj: [1]usize = undefined;

// --- IEnumWbemClassObject ---
// vtable[4] = Next

var enum_returned: bool = false;

fn wbemEnumNext(
    this: usize,
    lTimeout: i32,
    uCount: u32,
    apObjects: usize,
    puReturned: usize,
) callconv(w32cc.WINAPI) i32 {
    _ = .{ this, lTimeout };
    if (trace.enable_tracing) trace.print("WMI: IEnumWbemClassObject::Next(count={d})\n", .{uCount});
    if (!enum_returned and uCount >= 1 and apObjects != 0) {
        enum_returned = true;
        initAll();
        @as(*usize, @ptrFromInt(apObjects)).* = @intFromPtr(&wbem_class_obj);
        if (puReturned != 0) @as(*u32, @ptrFromInt(puReturned)).* = 1;
        return 0; // WBEM_S_NO_ERROR
    }
    if (puReturned != 0) @as(*u32, @ptrFromInt(puReturned)).* = 0;
    return 1; // WBEM_S_FALSE (no more items)
}

var wbem_enum_vtable: [8]usize = undefined;
var wbem_enum_obj: [1]usize = undefined;

// --- IWbemClassObject ---
// vtable[4] = Get(name, flags, pVal, pType, pFlavor)

fn wbemClassGet(
    this: usize,
    wszName: usize,
    lFlags: i32,
    pVal: usize,
    pType: usize,
    plFlavor: usize,
) callconv(w32cc.WINAPI) i32 {
    _ = .{ this, lFlags };
    if (plFlavor != 0) @as(*u32, @ptrFromInt(plFlavor)).* = 0;
    if (pType != 0) @as(*u32, @ptrFromInt(pType)).* = 0;
    if (wszName == 0 or pVal == 0) return 0;

    // Read property name
    const wname = @as([*]const u16, @ptrFromInt(wszName));
    var nbuf: [64]u8 = undefined;
    var nlen: usize = 0;
    while (nlen < 63 and wname[nlen] != 0) : (nlen += 1) nbuf[nlen] = @truncate(wname[nlen]);
    const name = nbuf[0..nlen];

    if (trace.enable_tracing) trace.print("WMI: IWbemClassObject::Get('{s}')\n", .{name});

    // VARIANT at pVal: [vt:u16][pad:6][data:8]
    @memset(@as([*]u8, @ptrFromInt(pVal))[0..16], 0);

    // Return property values for Win32_Processor
    if (std.ascii.eqlIgnoreCase(name, "Name") or std.ascii.eqlIgnoreCase(name, "Caption")) {
        setVariantBstr(pVal, "Intel Compatible Processor");
    } else if (std.ascii.eqlIgnoreCase(name, "MaxClockSpeed") or std.ascii.eqlIgnoreCase(name, "CurrentClockSpeed")) {
        setVariantI4(pVal, 3000); // 3000 MHz
    } else if (std.ascii.eqlIgnoreCase(name, "NumberOfCores")) {
        setVariantI4(pVal, 1);
    } else if (std.ascii.eqlIgnoreCase(name, "NumberOfLogicalProcessors") or std.ascii.eqlIgnoreCase(name, "ThreadCount")) {
        setVariantI4(pVal, 1);
    } else if (std.ascii.eqlIgnoreCase(name, "L2CacheSize")) {
        setVariantI4(pVal, 256); // 256 KB
    } else if (std.ascii.eqlIgnoreCase(name, "L3CacheSize")) {
        setVariantI4(pVal, 8192); // 8 MB
    } else if (std.ascii.eqlIgnoreCase(name, "Manufacturer")) {
        setVariantBstr(pVal, "GenuineIntel");
    } else if (std.ascii.eqlIgnoreCase(name, "Description") or std.ascii.eqlIgnoreCase(name, "ProcessorId")) {
        setVariantBstr(pVal, "x86 Family 6 Model 8 Stepping 3");
    } else if (std.ascii.eqlIgnoreCase(name, "Architecture")) {
        setVariantI4(pVal, 0); // x86
    } else if (std.ascii.eqlIgnoreCase(name, "Family")) {
        setVariantI4(pVal, 6);
    } else if (std.ascii.eqlIgnoreCase(name, "Model")) {
        setVariantBstr(pVal, "Unknown");
    } else if (std.ascii.eqlIgnoreCase(name, "TotalPhysicalMemory")) {
        setVariantBstr(pVal, "2147483648"); // 2 GB
    } else if (std.ascii.eqlIgnoreCase(name, "SMBiosMajorVersion")) {
        setVariantI4(pVal, 2); // SMBIOS 2.x
    } else if (std.ascii.eqlIgnoreCase(name, "SMBiosMinorVersion")) {
        setVariantI4(pVal, 3); // SMBIOS 2.3
    } else if (std.ascii.eqlIgnoreCase(name, "Size")) {
        setVariantI4(pVal, 100); // table size
    } else if (std.ascii.eqlIgnoreCase(name, "SMBiosData")) {
        // Return a minimal SMBIOS table with Type 4 (Processor Information)
        // VT_ARRAY|VT_UI1 = 0x2011
        setVariantSmbios(pVal);
    } else {
        // Return VT_NULL for unknown properties
        @as(*u16, @ptrFromInt(pVal)).* = 1; // VT_NULL
    }
    return 0; // S_OK
}

fn setVariantBstr(pVal: usize, comptime str: []const u8) void {
    // VT_BSTR = 8
    @as(*u16, @ptrFromInt(pVal)).* = 8;
    // Allocate BSTR
    const bstr = allocBstrFromAscii(str);
    @as(*align(1) u32, @ptrFromInt(pVal + 8)).* = @intCast(bstr);
}

fn setVariantI4(pVal: usize, val: i32) void {
    // VT_I4 = 3
    @as(*u16, @ptrFromInt(pVal)).* = 3;
    @as(*align(1) i32, @ptrFromInt(pVal + 8)).* = val;
}

fn setVariantSmbios(pVal: usize) void {
    // Build a minimal SMBIOS table with just a Type 4 (Processor) entry.
    // SMBIOS Type 4 structure (minimal, 32-bit spec):
    //   Header: type(1), length(1), handle(2)
    //   Socket Designation str index(1), Processor Type(1), Processor Family(1),
    //   Processor Manufacturer str index(1), Processor ID(8), Processor Version str index(1),
    //   Voltage(1), External Clock(2), Max Speed(2), Current Speed(2), ...
    // Followed by strings section (null-terminated strings, double-null at end)
    const proc_name = "Intel Compatible Processor";

    // SMBIOS Type 4 entry (length=0x2A = 42 bytes for 2.3 spec)
    var smbios_data: [128]u8 = @as([128]u8, @splat(0));
    var pos: usize = 0;
    // Type 4 header
    smbios_data[pos] = 4;
    pos += 1; // Type
    smbios_data[pos] = 0x2A;
    pos += 1; // Length (42 bytes)
    smbios_data[pos] = 0x01;
    pos += 1; // Handle low
    smbios_data[pos] = 0x00;
    pos += 1; // Handle high
    smbios_data[pos] = 1;
    pos += 1; // Socket Designation (string index 1)
    smbios_data[pos] = 3;
    pos += 1; // Processor Type: Central Processor
    smbios_data[pos] = 0xFE;
    pos += 1; // Processor Family: see Family2
    smbios_data[pos] = 2;
    pos += 1; // Processor Manufacturer (string index 2)
    // Processor ID (8 bytes) — CPUID(1) result
    smbios_data[pos] = 0x33;
    pos += 1; // EAX: Family 6, Model 8, Stepping 3
    smbios_data[pos] = 0x06;
    pos += 1;
    smbios_data[pos] = 0x00;
    pos += 1;
    smbios_data[pos] = 0x00;
    pos += 1;
    smbios_data[pos] = 0xFF;
    pos += 1; // EDX feature flags
    smbios_data[pos] = 0xFB;
    pos += 1;
    smbios_data[pos] = 0x8B;
    pos += 1;
    smbios_data[pos] = 0x07;
    pos += 1;
    smbios_data[pos] = 3;
    pos += 1; // Processor Version (string index 3)
    smbios_data[pos] = 0x80;
    pos += 1; // Voltage: 3.3V
    smbios_data[pos] = 0x64;
    pos += 1; // External Clock: 100 MHz (low)
    smbios_data[pos] = 0x00;
    pos += 1; // External Clock: (high)
    smbios_data[pos] = 0xB8;
    pos += 1; // Max Speed: 3000 MHz (low)
    smbios_data[pos] = 0x0B;
    pos += 1; // Max Speed: (high)
    smbios_data[pos] = 0xB8;
    pos += 1; // Current Speed: 3000 MHz (low)
    smbios_data[pos] = 0x0B;
    pos += 1; // Current Speed: (high)
    // Fill remaining bytes to reach length 0x2A
    while (pos < 4 + 0x2A) : (pos += 1) smbios_data[pos] = 0;
    pos = 4 + 0x2A;
    // Strings section: string1\0string2\0string3\0\0
    @memcpy(smbios_data[pos .. pos + 7], "Socket0");
    pos += 7;
    smbios_data[pos] = 0;
    pos += 1;
    @memcpy(smbios_data[pos .. pos + 12], "GenuineIntel");
    pos += 12;
    smbios_data[pos] = 0;
    pos += 1;
    @memcpy(smbios_data[pos .. pos + proc_name.len], proc_name);
    pos += proc_name.len;
    smbios_data[pos] = 0;
    pos += 1;
    smbios_data[pos] = 0;
    pos += 1; // double-null terminator

    // End-of-table marker (Type 127)
    smbios_data[pos] = 127;
    pos += 1; // Type
    smbios_data[pos] = 4;
    pos += 1; // Length
    smbios_data[pos] = 0xFF;
    pos += 1; // Handle
    smbios_data[pos] = 0xFF;
    pos += 1;
    smbios_data[pos] = 0;
    pos += 1; // no strings
    smbios_data[pos] = 0;
    pos += 1; // double-null

    // Create a SAFEARRAY(VT_UI1) containing the SMBIOS data
    // SAFEARRAY: cDims(2), fFeatures(2), cbElements(4), cLocks(4),
    //            pvData(4), rgsabound[0]={cElements(4), lLbound(4)}
    const data_size: u32 = @intCast(pos);
    const sa_size = 24 + data_size; // SAFEARRAY header + data
    const sa_ptr = shared.raw_alloc(sa_size) orelse return;
    const sa = @intFromPtr(sa_ptr);
    @memset(@as([*]u8, @ptrFromInt(sa))[0..sa_size], 0);
    @as(*align(1) u16, @ptrFromInt(sa)).* = 1; // cDims = 1
    @as(*align(1) u16, @ptrFromInt(sa + 2)).* = 0x0010; // fFeatures = FADF_FIXEDSIZE
    @as(*align(1) u32, @ptrFromInt(sa + 4)).* = 1; // cbElements = 1 byte
    @as(*align(1) u32, @ptrFromInt(sa + 12)).* = @intCast(sa + 24); // pvData
    @as(*align(1) u32, @ptrFromInt(sa + 16)).* = data_size; // rgsabound[0].cElements
    // Copy SMBIOS data
    @memcpy(@as([*]u8, @ptrFromInt(sa + 24))[0..data_size], smbios_data[0..data_size]);

    // Set VARIANT: VT_ARRAY|VT_UI1 = 0x2011
    @as(*u16, @ptrFromInt(pVal)).* = 0x2011;
    @as(*align(1) u32, @ptrFromInt(pVal + 8)).* = @intCast(sa);
}

fn allocBstrFromAscii(comptime str: []const u8) usize {
    const byte_len = str.len * 2;
    const alloc_size = 4 + byte_len + 2;
    const ptr = shared.raw_alloc(alloc_size) orelse return 0;
    const base = @intFromPtr(ptr);
    @as(*align(1) u32, @ptrFromInt(base)).* = @intCast(byte_len);
    const data = base + 4;
    const dst = @as([*]u16, @ptrFromInt(data));
    for (0..str.len) |i| dst[i] = str[i];
    dst[str.len] = 0;
    return data;
}

var wbem_class_vtable: [27]usize = undefined;
var wbem_class_obj: [1]usize = undefined;

// --- Initialization ---

var wmi_initialized: bool = false;

fn initAll() void {
    if (wmi_initialized) return;

    // IWbemLocator
    wbem_locator_vtable[0] = @intFromPtr(&comQueryInterface);
    wbem_locator_vtable[1] = @intFromPtr(&comAddRef);
    wbem_locator_vtable[2] = @intFromPtr(&comRelease);
    wbem_locator_vtable[3] = @intFromPtr(&wbemLocatorConnectServer);
    wbem_locator_obj[0] = @intFromPtr(&wbem_locator_vtable);

    // IWbemServices — 26 methods, ExecQuery at [20]
    for (0..26) |i| {
        wbem_services_vtable[i] = switch (i) {
            0 => @intFromPtr(&comQueryInterface),
            1 => @intFromPtr(&comAddRef),
            2 => @intFromPtr(&comRelease),
            18 => @intFromPtr(&wbemServicesCreateInstanceEnum),
            20 => @intFromPtr(&wbemServicesExecQuery),
            else => @intFromPtr(&comStub7), // safe stub for unused methods
        };
    }
    wbem_services_obj[0] = @intFromPtr(&wbem_services_vtable);

    // IEnumWbemClassObject — 8 methods, Next at [4]
    for (0..8) |i| {
        wbem_enum_vtable[i] = switch (i) {
            0 => @intFromPtr(&comQueryInterface),
            1 => @intFromPtr(&comAddRef),
            2 => @intFromPtr(&comRelease),
            4 => @intFromPtr(&wbemEnumNext),
            else => @intFromPtr(&comStub4),
        };
    }
    wbem_enum_obj[0] = @intFromPtr(&wbem_enum_vtable);

    // IWbemClassObject — 27 methods, Get at [4]
    for (0..27) |i| {
        wbem_class_vtable[i] = switch (i) {
            0 => @intFromPtr(&comQueryInterface),
            1 => @intFromPtr(&comAddRef),
            2 => @intFromPtr(&comRelease),
            4 => @intFromPtr(&wbemClassGet),
            else => @intFromPtr(&comStub5),
        };
    }
    wbem_class_obj[0] = @intFromPtr(&wbem_class_vtable);

    // IUnsecuredApartment — 4 methods
    unsecured_vtable[0] = @intFromPtr(&comQueryInterface);
    unsecured_vtable[1] = @intFromPtr(&comAddRef);
    unsecured_vtable[2] = @intFromPtr(&comRelease);
    unsecured_vtable[3] = @intFromPtr(&unsecuredCreateObjectStub);
    unsecured_obj[0] = @intFromPtr(&unsecured_vtable);

    wmi_initialized = true;
}

// --- IUnsecuredApartment ---
// CLSID: {49bd2028-1523-11d1-ad79-00c04fd8fdff}
const CLSID_UnsecuredApartment = [16]u8{
    0x28, 0x20, 0xBD, 0x49, 0x23, 0x15, 0xD1, 0x11,
    0xAD, 0x79, 0x00, 0xC0, 0x4F, 0xD8, 0xFD, 0xFF,
};

// vtable[3] = CreateObjectStub(pObject, ppStub)
fn unsecuredCreateObjectStub(this: usize, pObject: usize, ppStub: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    // Just return the original object as the "stub" (no cross-apartment marshaling needed)
    if (ppStub != 0) @as(*usize, @ptrFromInt(ppStub)).* = pObject;
    if (trace.enable_tracing) trace.print("WMI: IUnsecuredApartment::CreateObjectStub\n", .{});
    return 0; // S_OK
}

var unsecured_vtable: [4]usize = undefined;
var unsecured_obj: [1]usize = undefined;

// CLSID for WbemContext: {674B6698-EE92-11D0-AD71-00C04FD8FDFF}
// Also match alternate CLSID {C71566F2-561E-11D1-AD76-00C04FD8FDFF}
const CLSID_WbemContext1 = [16]u8{
    0x98, 0x66, 0x4B, 0x67, 0x92, 0xEE, 0xD0, 0x11,
    0xAD, 0x71, 0x00, 0xC0, 0x4F, 0xD8, 0xFD, 0xFF,
};
const CLSID_WbemContext2 = [16]u8{
    0xF2, 0x66, 0x15, 0xC7, 0x1E, 0x56, 0xD1, 0x11,
    0xAD, 0x87, 0x00, 0xC0, 0x4F, 0xD8, 0xFD, 0xFF,
};

/// Check if a CLSID matches WbemLocator, UnsecuredApartment, or WbemContext.
pub fn tryCreateWbemLocator(rclsid: usize, ppv: usize) bool {
    if (rclsid == 0) return false;
    const clsid = @as(*const [16]u8, @ptrFromInt(rclsid));
    if (std.mem.eql(u8, clsid, &CLSID_WbemLocator)) {
        initAll();
        if (ppv != 0) @as(*usize, @ptrFromInt(ppv)).* = @intFromPtr(&wbem_locator_obj);
        if (trace.enable_tracing) trace.print("WMI: Created IWbemLocator\n", .{});
        return true;
    }
    if (std.mem.eql(u8, clsid, &CLSID_UnsecuredApartment)) {
        initAll();
        if (ppv != 0) @as(*usize, @ptrFromInt(ppv)).* = @intFromPtr(&unsecured_obj);
        if (trace.enable_tracing) trace.print("WMI: Created IUnsecuredApartment\n", .{});
        return true;
    }
    // WbemContext — used for query parameters. Return a dummy COM object.
    if (std.mem.eql(u8, clsid, &CLSID_WbemContext1) or std.mem.eql(u8, clsid, &CLSID_WbemContext2)) {
        initAll();
        ensureDummyVtable();
        if (ppv != 0) @as(*usize, @ptrFromInt(ppv)).* = @intFromPtr(&dummy_com_object);
        if (trace.enable_tracing) trace.print("WMI: Created IWbemContext (dummy)\n", .{});
        return true;
    }
    return false;
}

// --- Dummy COM object for interfaces with no real backing store ---

// 64-slot vtable: QueryInterface, AddRef, Release, then methods that zero any
// output pointer handed to them and report S_OK. Callers get a non-NULL
// interface so they can check the HRESULT instead of dereferencing NULL.
var dummy_vtable: [64]usize = undefined;
var dummy_vtable_initialized: bool = false;
var dummy_com_object: [1]usize = undefined;

fn ensureDummyVtable() void {
    if (dummy_vtable_initialized) return;
    dummy_vtable[0] = @intFromPtr(&dummyQueryInterface);
    dummy_vtable[1] = @intFromPtr(&dummyAddRef);
    dummy_vtable[2] = @intFromPtr(&dummyRelease);
    for (3..64) |i| {
        dummy_vtable[i] = switch (i % 3) {
            0 => @intFromPtr(&dummyComMethod1),
            1 => @intFromPtr(&dummyComMethod2),
            2 => @intFromPtr(&dummyComMethod3),
            else => unreachable,
        };
    }
    dummy_com_object[0] = @intFromPtr(&dummy_vtable);
    dummy_vtable_initialized = true;
}

fn zeroIfPointer(p: usize) void {
    if (p > 0x10000 and p < 0xF0000000) @as(*align(1) u32, @ptrFromInt(p)).* = 0;
}

fn dummyComMethod1(this: usize, a: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    zeroIfPointer(a);
    return 0; // S_OK
}
fn dummyComMethod2(this: usize, a: usize, b: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    zeroIfPointer(a);
    zeroIfPointer(b);
    return 0; // S_OK
}
fn dummyComMethod3(this: usize, a: usize, b: usize, c: usize) callconv(w32cc.WINAPI) i32 {
    _ = this;
    zeroIfPointer(a);
    zeroIfPointer(b);
    zeroIfPointer(c);
    return 0; // S_OK
}
fn dummyQueryInterface(this: usize, riid: usize, ppv: usize) callconv(w32cc.WINAPI) i32 {
    _ = .{ this, riid };
    if (ppv != 0) @as(*usize, @ptrFromInt(ppv)).* = @intFromPtr(&dummy_com_object);
    return 0; // S_OK - return self for any interface query
}
fn dummyAddRef(this: usize) callconv(w32cc.WINAPI) u32 {
    _ = this;
    return 1;
}
fn dummyRelease(this: usize) callconv(w32cc.WINAPI) u32 {
    _ = this;
    return 1;
}
