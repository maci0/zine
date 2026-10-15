//! CLI Spec 0.3 for the native zine entry point.
//! `schema` and `-o` are resolved before log or config init, so the document
//! needs no environment and loads no guest.

const std = @import("std");
const runtime = @import("runtime.zig");
const version = @import("version.zig");

pub const Mode = enum { auto, text, json };
pub var mode: Mode = .auto;

pub fn wantsJson() bool {
    return mode == .json;
}

pub fn usageExit() noreturn {
    if (mode == .json) {
        std.debug.print("{s}", .{"{\"error\":{\"kind\":\"usage\",\"message\":\"invalid arguments\"}}\n"});
    }
    std.process.exit(@as(u8, 2));
}

pub fn setMode(value: []const u8) void {
    if (std.mem.eql(u8, value, "auto")) {
        mode = .auto;
    } else if (std.mem.eql(u8, value, "text")) {
        mode = .text;
    } else if (std.mem.eql(u8, value, "json")) {
        mode = .json;
    } else {
        mode = .auto;
        std.debug.print("{s}", .{"Error: --output requires auto, text, or json.\nTry 'zine --help' for more information.\n"});
        std.process.exit(@as(u8, 2));
    }
}

const Cmd = struct {
    name: []const u8,
    description: []const u8,
    effects: []const u8,
    body: []const u8,
};

const cmds = [_]Cmd{
    .{
        .name = "schema",
        .effects = "read_only",
        .description = "Print this CLI Spec document. schema <command> returns the same document filtered to that command.",
        .body = "\"output_kind\":\"opaque\",\"media_type\":\"application/json\"",
    },
    .{
        .name = "version",
        .effects = "read_only",
        .description = "Print the zine version. Invoked with -v or --version. The bare word version is a target name.",
        .body = "\"cardinality\":\"single\",\"output_fields\":[{\"name\":\"version\",\"type\":\"string\",\"description\":\"Release version\"}]",
    },
    .{
        .name = "run",
        .effects = "non_idempotent",
        .description = "Run the target executable. The word run is not typed. zine -- schema runs a file named schema. Guest stdout is unchanged in every output mode. A guest exit status is the process status. A retry is not safe.",
        .body = "\"output_kind\":\"opaque\",\"media_type\":\"application/octet-stream\"",
    },
};

fn selected(name: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (std.mem.eql(u8, name, filter)) return true;
    return name.len > filter.len and std.mem.startsWith(u8, name, filter) and name[filter.len] == ' ';
}

fn emit(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try list.appendSlice(alloc, s);
}

fn render(alloc: std.mem.Allocator, filter: []const u8) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(alloc);
    try emit(&list, alloc, "{\"clispec\":\"0.3\",\"name\":\"zine\",\"version\":\"");
    try emit(&list, alloc, version.string);
    try emit(&list, alloc, "\",\"description\":\"Run a Win32 PE executable on Linux.\",\"output\":{\"tty\":\"text\",\"piped\":\"text\"},\"global_args\":[{\"name\":\"--output\",\"short\":\"-o\",\"type\":\"string\",\"required\":false,\"description\":\"Before the target. auto stays text when piped. Guest stdout is unchanged.\",\"default\":\"auto\",\"enum\":[\"auto\",\"text\",\"json\"]}],\"commands\":[");
    var count: usize = 0;
    for (cmds) |cmd| {
        if (!selected(cmd.name, filter)) continue;
        if (count != 0) try emit(&list, alloc, ",");
        try emit(&list, alloc, "{\"name\":\"");
        try emit(&list, alloc, cmd.name);
        try emit(&list, alloc, "\",\"description\":\"");
        try emit(&list, alloc, cmd.description);
        try emit(&list, alloc, "\",\"effects\":\"");
        try emit(&list, alloc, cmd.effects);
        try emit(&list, alloc, "\",");
        try emit(&list, alloc, cmd.body);
        try emit(&list, alloc, "}");
        count += 1;
    }
    if (count == 0) return error.UnknownPath;
    try emit(&list, alloc, "],\"errors\":[{\"kind\":\"usage\",\"exit_code\":2,\"retryable\":false,\"description\":\"The arguments are not valid, or a ZINE_* setting was rejected.\"},{\"kind\":\"failure\",\"exit_code\":1,\"retryable\":false,\"description\":\"The target could not be started. A guest exit status is not this error.\"}]}\n");
    return list.toOwnedSlice(alloc);
}

/// Scan argv for `-o` and `schema` before config init. Schema exits the process.
pub fn prepare(init: std.process.Init) void {
    const alloc = init.arena.allocator();
    var args = init.minimal.args.iterateAllocator(alloc) catch {
        std.debug.print("{s}", .{"Error: failed to read arguments.\nTry 'zine --help' for more information.\n"});
        usageExit();
    };
    defer args.deinit();
    _ = args.next();

    var end_of_options = false;
    var saw_positional = false;
    var saw_schema = false;
    var filt: std.ArrayListUnmanaged(u8) = .empty;
    defer filt.deinit(alloc);

    while (args.next()) |arg| {
        if (!end_of_options and std.mem.eql(u8, arg, "--")) {
            end_of_options = true;
            continue;
        }
        if (!end_of_options and (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output"))) {
            const value = args.next() orelse {
                std.debug.print("{s}", .{"Error: --output requires auto, text, or json.\nTry 'zine --help' for more information.\n"});
                mode = .auto;
                usageExit();
            };
            setMode(value);
            continue;
        }
        if (!end_of_options and std.mem.startsWith(u8, arg, "--output=")) {
            setMode(arg["--output=".len..]);
            continue;
        }
        if (!end_of_options and std.mem.eql(u8, arg, "--argv0")) {
            _ = args.next();
            continue;
        }
        if (!end_of_options and std.mem.startsWith(u8, arg, "--argv0=")) continue;
        if (!end_of_options and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            if (saw_schema) {
                runtime.writeCliOut("usage: zine schema [command]\n");
                std.process.exit(0);
            }
            continue;
        }
        if (!end_of_options and arg.len > 1 and arg[0] == '-') {
            if (saw_schema) {
                std.debug.print("{s}", .{"Error: unknown option.\nTry 'zine --help' for more information.\n"});
                usageExit();
            }
            continue;
        }
        if (!end_of_options and !saw_positional and std.mem.eql(u8, arg, "schema")) {
            saw_schema = true;
            saw_positional = true;
            continue;
        }
        if (saw_schema and !end_of_options) {
            if (filt.items.len != 0) filt.append(alloc, ' ') catch usageExit();
            filt.appendSlice(alloc, arg) catch usageExit();
            continue;
        }
        saw_positional = true;
    }

    if (!saw_schema) return;
    const doc = render(alloc, filt.items) catch {
        std.debug.print("{s}", .{"unknown command path\n"});
        usageExit();
    };
    runtime.writeCliOut(doc);
    std.process.exit(0);
}

test "schema selection keeps an exact command name" {
    try std.testing.expect(selected("run", ""));
    try std.testing.expect(selected("run", "run"));
    try std.testing.expect(!selected("run", "schema"));
    try std.testing.expect(!selected("schema", "sche"));
}
