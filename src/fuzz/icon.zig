//! Fuzz harness for the PE icon resource parser.
//!
//! One input carries both untrusted resources the parser crosses: the
//! RT_GROUP_ICON directory comes first (the 20 bytes it reads, when the input
//! is long enough) and the RT_ICON payload it points at follows, so a single
//! input drives the group header, the icon entry, and the ICO output.

const std = @import("std");
const icon = @import("../loader/icon_parser.zig");

/// The group directory is 6 header bytes plus the 14-byte first entry; a real
/// group holds more entries but the parser only ever reads the first.
const group_dir_len = 6 + 14;

/// Seed corpus: a well-formed group with a 32bpp entry, a group with the
/// wrong magic, a zero-entry group, a group with a huge declared size, and an
/// empty payload.
pub const seeds = [_][]const u8{
    // 32x32 32bpp icon, 4 bytes of payload, resource id 1.
    &.{
        0, 0, 1, 0, 1, 0, // reserved 0, type 1 (icon), count 1
        32, 32, 0, 0, 1, 0, 32, 0, // entry: 32x32, 1 plane, 32bpp
        4, 0, 0, 0, 1, 0, // bytes in res 4, id 1
        0xDE, 0xAD, 0xBE, 0xEF, // icon payload
    },
    // Wrong idType (2 = cursor), a rejection the fuzzer must reach.
    &.{ 0, 0, 2, 0, 1, 0, 32, 32, 0, 0, 1, 0, 32, 0, 4, 0, 0, 0, 1, 0, 0xFF },
    // Zero entries: nothing to point at.
    &.{ 0, 0, 1, 0, 0, 0, 32, 32, 0, 0, 1, 0, 32, 0, 4, 0, 0, 0, 1, 0 },
    // Declared size far larger than the payload, and a u16-sized icon.
    &.{ 0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 4, 0, 0xFF, 0xFF, 0, 0, 0xFF, 0xFE, 0x01, 0x02, 0x03, 0x04 },
    // Header only: no icon entry at all.
    &.{ 0, 0, 1, 0, 1, 0 },
};

/// Errors that mean the parser produced something impossible.
pub const Failure = error{
    IconOutputNotValidJson,
    IconOutputNotAnObject,
    IconOutputBadType,
    IconOutputMissingBase64,
    IconOutputBase64NotAString,
    IconOutputBase64Invalid,
    IconHeaderTooShort,
    IconHeaderBadCount,
    IconHeaderBadOffset,
    IconPayloadLengthMismatch,
    /// Reported by the allocator, not by a parser contract violation.
    OutOfMemory,
};

/// The ICONDIR plus one ICONDIRENTRY header the parser writes before the
/// payload: 6 + 16 bytes.
const ico_header_len = 22;

/// Runs one input through the parser and checks the JSON contract plus the ICO
/// structure the base64 field decodes to: a header claiming one image, an
/// image length that matches the bytes the parser actually received, and a
/// payload that starts exactly where the header ends.
pub fn harness(allocator: std.mem.Allocator, data: []const u8) Failure!void {
    const group = data[0..@min(data.len, group_dir_len)];
    const json = icon.parseIconData(allocator, group, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A group the header rejects is the documented outcome.
        else => return,
    } orelse return;
    defer allocator.free(json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return error.IconOutputNotValidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.IconOutputNotAnObject;

    const type_value = parsed.value.object.get("type") orelse return error.IconOutputBadType;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "set_icon"))
        return error.IconOutputBadType;

    const base64_value = parsed.value.object.get("base64") orelse return error.IconOutputMissingBase64;
    if (base64_value != .string) return error.IconOutputBase64NotAString;

    const decoder = std.base64.standard.Decoder;
    const ico_len = decoder.calcSizeForSlice(base64_value.string) catch
        return error.IconOutputBase64Invalid;
    const ico = try allocator.alloc(u8, ico_len);
    defer allocator.free(ico);
    decoder.decode(ico, base64_value.string) catch return error.IconOutputBase64Invalid;
    if (ico_len != ico_header_len + data.len) return error.IconPayloadLengthMismatch;

    if (ico_len < ico_header_len) return error.IconHeaderTooShort;
    const image_count = std.mem.readInt(u16, ico[4..6], .little);
    if (image_count != 1) return error.IconHeaderBadCount;
    if (std.mem.readInt(u32, ico[18..22], .little) != ico_header_len) return error.IconHeaderBadOffset;
    if (!std.mem.eql(u8, ico[ico_header_len..], data)) return error.IconPayloadLengthMismatch;
}
