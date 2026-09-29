//! Fuzz harness for the .rc resource compiler behind RCDLL's `RC` export.
//!
//! One input is one `.rc` script's whole text, exactly as RC.EXE hands it to
//! the compiler. The script is guest-supplied, so every offset, length and
//! count the parser derives comes from these bytes: the `#define` table, the
//! STRINGTABLE entries, the MENU and DIALOG statements and the ICON paths.
//! The harness asserts the `.res` image the compiler emits is a sequence of
//! well-formed resource records, and that a second run produces the same one,
//! since the `#define` table is process state.

const std = @import("std");
const rcdll = @import("../win32/rcdll.zig");

/// Seed corpus: the statement forms a real script uses, then the truncations
/// and degenerate forms a script can reach: an unterminated quote, a block
/// with no terminator, a number too long for its field, a menu item with
/// neither name nor id, a define that shadows a numeric id, and an empty
/// script.
pub const seeds = [_][]const u8{
    "#define IDD_MAIN 101\r\n#define IDC_OK 1\r\nSTRINGTABLE\r\nBEGIN\r\n1, \"hello\"\r\n2, \"world\"\r\nEND\r\n",
    "1 MENU BEGIN\nPOPUP \"&File\"\nBEGIN\nMENUITEM \"&Open\", 100\nMENUITEM SEPARATOR\nMENUITEM \"E&xit\", IDC_QUIT\nEND\nEND\n",
    "IDD_MAIN DIALOG 0, 0, 200, 100\nSTYLE DS_SETFONT | WS_POPUP | WS_CAPTION\nCAPTION \"Test\"\nBEGIN\nPUSHBUTTON \"OK\", IDC_OK, 7, 7, 50, 14\nEDITTEXT IDC_EDIT, 7, 25, 100, 12, ES_AUTOHSCROLL\nEND\n",
    "1 ICON \"main.ico\"\n2 ICON \"other.ico\"\n",
    "STRINGTABLE\n{\n0x20, \"block two\"\n0x21, \"another\"\n}\n",
    "STRINGTABLE\nBEGIN\n1, \"unterminated\n",
    "STRINGTABLE BEGIN\n",
    "1 MENU BEGIN\nPOPUP\nBEGIN\nMENUITEM\nEND\nEND\n",
    "1 DIALOG 0,0,10,10\nBEGIN\nLTEXT\nEND\n",
    "1 DIALOG 0,0,10,10\nBEGIN\nLTEXT \"\", 1, 99999999999999999999, 1, 1, 1, WS_CHILD | NOTASTYLE\nEND\n",
    "#define\n#define A\n#define A 4294967295\n1 MENU BEGIN\nMENUITEM \"x\", A\nEND\n",
    "1 MENU BEGIN\nEND\n",
    "MENUITEM",
    "1 DIALOG",
    "1 ICON\n",
    "",
    " ",
    "\r\n\r\n",
};

/// Ways the emitted image can break the `.res` contract. A resource loader
/// walks the records by their headers, so a wrong header, an unknown type or
/// a size that runs past the image is what turns a malformed script into a
/// bad load.
pub const Failure = error{
    /// A record header that is not the 32 bytes every record starts with.
    HeaderSizeWrong,
    /// A resource type the loader does not know: the compiler emits 3, 4, 5,
    /// 6 and 14 only.
    TypeUnknown,
    /// A record whose data size runs past the end of the image.
    RecordOverruns,
    /// An image with trailing bytes no record accounts for.
    TrailingBytes,
    /// Two runs of the same script produced different images, so state from
    /// the first run (the `#define` table) reached the second.
    RunNotDeterministic,
    OutOfMemory,
};

const resource_header_len = 32;
const known_types = [_]u32{ 3, 4, 5, 6, 14 };

/// Compile one script and check the image, then compile it again and check the
/// two agree. The buffer is exactly `res_capacity`, the size the compiler
/// documents, so a parser that emits past what the counts allow panics here
/// rather than writing over a neighbour.
pub fn harness(allocator: std.mem.Allocator, data: []const u8) Failure!void {
    const first = try compile(allocator, data);
    defer first.deinit(allocator);
    const second = try compile(allocator, data);
    defer second.deinit(allocator);
    if (!std.mem.eql(u8, first.bytes[0..first.len], second.bytes[0..second.len])) {
        return error.RunNotDeterministic;
    }
}

const Image = struct {
    bytes: []u8,
    len: usize,

    fn deinit(image: Image, allocator: std.mem.Allocator) void {
        allocator.free(image.bytes);
    }
};

fn compile(allocator: std.mem.Allocator, data: []const u8) Failure!Image {
    const buf = allocator.alloc(u8, rcdll.res_capacity) catch return error.OutOfMemory;
    const len = rcdll.buildResImage(data, buf) orelse {
        // A script with no resource data compiles to nothing, which is an
        // answer, not a malformed image. Zero it so the comparison below
        // still holds for a script that compiles one way and not another.
        @memset(buf, 0);
        return .{ .bytes = buf, .len = 0 };
    };
    try check(buf[0..len]);
    return .{ .bytes = buf, .len = len };
}

/// Walk the records: each starts with a 32-byte header whose data size must
/// fit in what is left, and the walk must land on the end of the image.
fn check(image: []const u8) Failure!void {
    var pos: usize = 0;
    while (pos < image.len) {
        if (image.len - pos < resource_header_len) return error.HeaderSizeWrong;
        const header = image[pos..][0..resource_header_len];
        if (std.mem.readInt(u32, header[4..8], .little) != resource_header_len) return error.HeaderSizeWrong;
        const type_id = std.mem.readInt(u32, header[8..12], .little);
        if (!isKnownType(type_id)) return error.TypeUnknown;
        const data_size = std.mem.readInt(u32, header[0..4], .little);
        pos += resource_header_len;
        if (data_size > image.len - pos) return error.RecordOverruns;
        pos += data_size;
    }
}

fn isKnownType(type_id: u32) bool {
    for (known_types) |known| {
        if (known == type_id) return true;
    }
    return false;
}
