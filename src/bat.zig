//! Windows batch file (.bat / .cmd) parser and environment manager.
//!
//! Provides variable expansion (%VAR%, %0–9, %~dp0) and a simplified
//! interpreter for SET, CALL, and IF statements used in MSVC toolchain
//! batch scripts (e.g. VCVARS32.BAT).

const std = @import("std");
const runtime = @import("runtime.zig");

pub const BatEnv = struct {
    allocator: std.mem.Allocator,
    env: std.StringHashMap([]const u8),

    /// Initializes a new batch environment.
    pub fn init(allocator: std.mem.Allocator) !BatEnv {
        var self = BatEnv{
            .allocator = allocator,
            .env = std.StringHashMap([]const u8).init(allocator),
        };
        errdefer self.deinit();
        // Load initial env
        var it = runtime.environ().createMap(allocator) catch |e| {
            std.debug.print("bat: failed to load environment: {}\n", .{e});
            return e;
        };
        defer it.deinit();

        var env_it = it.iterator();
        while (env_it.next()) |entry| {
            try self.setVariable(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Default MSVC environment expectations
        try self.setVariable("OS", "Windows_NT");
        return self;
    }

    /// Frees all resources associated with the batch environment.
    pub fn deinit(self: *BatEnv) void {
        var it = self.env.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env.deinit();
    }

    fn setVariable(self: *BatEnv, name: []const u8, value: []const u8) !void {
        if (value.len == 0) {
            self.removeVariable(name);
            return;
        }
        const key_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        const gop = try self.env.getOrPut(key_copy);
        if (gop.found_existing) {
            self.allocator.free(gop.key_ptr.*);
            self.allocator.free(gop.value_ptr.*);
        }
        gop.key_ptr.* = key_copy;
        gop.value_ptr.* = value_copy;
    }

    /// Removes a variable, freeing its owned key and value.
    fn removeVariable(self: *BatEnv, name: []const u8) void {
        if (self.env.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    fn expand(self: *BatEnv, input: []const u8, args: [][]const u8, current_bat_dir: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '%') {
                if (i + 1 < input.len and input[i + 1] == '*') {
                    var first = true;
                    if (args.len > 1) {
                        for (args[1..]) |arg| {
                            if (!first) try out.append(self.allocator, ' ');
                            try out.appendSlice(self.allocator, arg);
                            first = false;
                        }
                    }
                    i += 2;
                    continue;
                }

                if (i + 1 < input.len and input[i + 1] >= '0' and input[i + 1] <= '9') {
                    const arg_idx = input[i + 1] - '0';
                    if (arg_idx < args.len) {
                        try out.appendSlice(self.allocator, args[arg_idx]);
                    }
                    i += 2;
                    continue;
                }

                if (i + 5 <= input.len and std.mem.eql(u8, input[i .. i + 5], "%~dp0")) {
                    try out.appendSlice(self.allocator, current_bat_dir);
                    try out.append(self.allocator, '\\');
                    i += 5;
                    continue;
                }

                if (std.mem.indexOfScalarPos(u8, input, i + 1, '%')) |end_idx| {
                    const var_name = input[i + 1 .. end_idx];
                    var found = false;

                    // Case insensitive matching for environment variables
                    var env_it = self.env.iterator();
                    while (env_it.next()) |entry| {
                        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, var_name)) {
                            try out.appendSlice(self.allocator, entry.value_ptr.*);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        // Windows batch expands undefined variables to empty string
                    }
                    i = end_idx + 1;
                    continue;
                }
            }
            try out.append(self.allocator, input[i]);
            i += 1;
        }

        return try out.toOwnedSlice(self.allocator);
    }

    /// Parses a Windows batch file and returns the final command to execute.
    /// This is a simplified interpreter that handles SET and CALL.
    pub fn parseFile(self: *BatEnv, bat_path: []const u8, args: [][]const u8) !?[][]const u8 {
        var open_path = bat_path;
        if (open_path.len >= 2 and open_path[1] == ':' and std.ascii.isAlphabetic(open_path[0])) {
            open_path = open_path[2..];
        }
        const io = runtime.io();
        var file = std.Io.Dir.cwd().openFile(io, open_path, .{}) catch {
            std.debug.print("Error: failed to open batch file '{s}'.\n", .{open_path});
            return null;
        };
        defer file.close(io);

        // Read the entire file into a string
        var reader_buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &reader_buf);
        const file_content = try file_reader.interface.allocRemaining(self.allocator, .limited(10 * 1024 * 1024));
        defer self.allocator.free(file_content);

        // Resolve absolute dir of the bat file for %~dp0
        const abs_path = try std.Io.Dir.cwd().realPathFileAlloc(io, open_path, self.allocator);
        defer self.allocator.free(abs_path);

        const parent_dir = std.fs.path.dirname(abs_path) orelse ".";

        // Convert to Windows style path
        const win_parent_dir = try self.allocator.dupe(u8, parent_dir);
        defer self.allocator.free(win_parent_dir);
        std.mem.replaceScalar(u8, win_parent_dir, '/', '\\');

        var line_it = std.mem.splitScalar(u8, file_content, '\n');

        const win_parent_dir_c = try std.fmt.allocPrint(self.allocator, "C:{s}", .{win_parent_dir});
        defer self.allocator.free(win_parent_dir_c);

        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (line.len == 0) continue;

            if (std.ascii.startsWithIgnoreCase(line, "@echo ")) continue;
            if (std.ascii.startsWithIgnoreCase(line, "echo ")) continue;
            if (std.ascii.startsWithIgnoreCase(line, "echo.")) continue;
            if (std.ascii.startsWithIgnoreCase(line, "rem ") or std.ascii.startsWithIgnoreCase(line, "rem")) continue;

            const expanded = try self.expand(line, args, win_parent_dir_c);
            defer self.allocator.free(expanded);

            var cmd_line = expanded;

            // Handle "if" conditions
            if (std.ascii.startsWithIgnoreCase(cmd_line, "if ")) {
                cmd_line = std.mem.trimStart(u8, cmd_line[3..], " \t");
                var is_not = false;
                if (std.ascii.startsWithIgnoreCase(cmd_line, "not ")) {
                    is_not = true;
                    cmd_line = std.mem.trimStart(u8, cmd_line[4..], " \t");
                }

                if (cmd_line.len > 0 and cmd_line[0] == '"') {
                    if (std.mem.indexOfScalarPos(u8, cmd_line, 1, '"')) |quote_end| {
                        const lhs = cmd_line[1..quote_end];
                        const rest1 = std.mem.trimStart(u8, cmd_line[quote_end + 1 ..], " \t");
                        if (std.ascii.startsWithIgnoreCase(rest1, "==")) {
                            const rest2 = std.mem.trimStart(u8, rest1[2..], " \t");
                            if (rest2.len > 0 and rest2[0] == '"') {
                                if (std.mem.indexOfScalarPos(u8, rest2, 1, '"')) |quote2_end| {
                                    const rhs = rest2[1..quote2_end];
                                    const cond_met = std.ascii.eqlIgnoreCase(lhs, rhs);
                                    if (cond_met != is_not) {
                                        cmd_line = std.mem.trimStart(u8, rest2[quote2_end + 1 ..], " \t");
                                    } else {
                                        continue; // skip this line
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (std.ascii.startsWithIgnoreCase(cmd_line, "set ")) {
                const assign = std.mem.trimStart(u8, cmd_line[4..], " \t");
                if (std.mem.indexOfScalar(u8, assign, '=')) |eq_idx| {
                    const key = std.mem.trim(u8, assign[0..eq_idx], " \t");
                    const val = std.mem.trim(u8, assign[eq_idx + 1 ..], " \t");

                    // Windows SET can just unset variable if value is empty
                    try self.setVariable(key, val);
                }
                continue;
            }

            if (std.ascii.startsWithIgnoreCase(cmd_line, "call ")) {
                var call_target = std.mem.trimStart(u8, cmd_line[5..], " \t");
                if (call_target.len == 0) continue;
                if (call_target[0] == '"') {
                    if (std.mem.indexOfScalarPos(u8, call_target, 1, '"')) |q| {
                        call_target = call_target[1..q];
                    }
                }

                // Call target might be a Windows path, convert back to POSIX
                const unix_target = try self.allocator.dupe(u8, call_target);
                defer self.allocator.free(unix_target);
                std.mem.replaceScalar(u8, unix_target, '\\', '/');

                _ = try self.parseFile(unix_target, &[_][]const u8{});
                continue;
            }

            // Unrecognized command — treat as the final executable invocation.
            // Split by whitespace with basic quote stripping.
            var final_args: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, cmd_line, " \t");
            while (it.next()) |token| {
                if (token.len > 0 and token[0] == '"' and token[token.len - 1] == '"' and token.len >= 2) {
                    try final_args.append(self.allocator, try self.allocator.dupe(u8, token[1 .. token.len - 1]));
                } else {
                    try final_args.append(self.allocator, try self.allocator.dupe(u8, token));
                }
            }
            if (final_args.items.len > 0) {
                return try final_args.toOwnedSlice(self.allocator);
            }
        }

        return null;
    }

    /// Builds an environment vector (envp) from the current batch environment.
    pub fn buildEnvp(self: *BatEnv) !?[*]?[*:0]u8 {
        var envp_list: std.ArrayList(?[*:0]u8) = .empty;
        var it = self.env.iterator();
        while (it.next()) |entry| {
            const str = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            defer self.allocator.free(str);
            const strZ = try self.allocator.dupeZ(u8, str);
            try envp_list.append(self.allocator, strZ.ptr);
        }

        // Sort the array (excluding the null terminator we will add)
        const lessThan = struct {
            fn lessThan(context: void, lhs: ?[*:0]u8, rhs: ?[*:0]u8) bool {
                _ = context;
                const l = std.mem.span(lhs.?);
                const r = std.mem.span(rhs.?);
                return std.ascii.orderIgnoreCase(l, r) == .lt;
            }
        }.lessThan;
        std.mem.sort(?[*:0]u8, envp_list.items, {}, lessThan);

        try envp_list.append(self.allocator, null);
        return (try envp_list.toOwnedSlice(self.allocator)).ptr;
    }
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

fn testBatEnv() BatEnv {
    return .{
        .allocator = testing.allocator,
        .env = std.StringHashMap([]const u8).init(testing.allocator),
    };
}

test "expand: literal text passes through" {
    var bat = testBatEnv();
    defer bat.deinit();

    const result = try bat.expand("hello world", &.{}, "C:\\bat");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello world", result);
}

test "expand: ordinal args %0-%9" {
    var bat = testBatEnv();
    defer bat.deinit();

    var args = [_][]const u8{ "script.bat", "arg1", "arg2" };
    const result = try bat.expand("%0 %1 %2", &args, "C:\\bat");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("script.bat arg1 arg2", result);
}

test "expand: %* expands all args after %0" {
    var bat = testBatEnv();
    defer bat.deinit();

    var args = [_][]const u8{ "cmd.bat", "first", "second", "third" };
    const result = try bat.expand("echo %*", &args, "C:\\bat");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("echo first second third", result);
}

test "expand: %* with no extra args" {
    var bat = testBatEnv();
    defer bat.deinit();

    var args = [_][]const u8{"cmd.bat"};
    const result = try bat.expand("echo %*", &args, "C:\\bat");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("echo ", result);
}

test "expand: environment variable" {
    var bat = testBatEnv();
    defer bat.deinit();
    try bat.env.put(try testing.allocator.dupe(u8, "FOO"), try testing.allocator.dupe(u8, "bar"));

    const result = try bat.expand("value=%FOO%", &.{}, "C:\\bat");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("value=bar", result);
}

test "expand: env var case insensitive" {
    var bat = testBatEnv();
    defer bat.deinit();
    try bat.env.put(try testing.allocator.dupe(u8, "MyVar"), try testing.allocator.dupe(u8, "hello"));

    const result = try bat.expand("%myvar%", &.{}, "C:\\bat");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "expand: undefined env var expands to empty" {
    var bat = testBatEnv();
    defer bat.deinit();

    const result = try bat.expand("x%UNDEFINED%y", &.{}, "C:\\bat");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("xy", result);
}

test "expand: %~dp0 expands to bat dir with backslash" {
    var bat = testBatEnv();
    defer bat.deinit();

    const result = try bat.expand("%~dp0file.exe", &.{}, "C:\\tools");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("C:\\tools\\file.exe", result);
}

test "expand: out of range ordinal arg" {
    var bat = testBatEnv();
    defer bat.deinit();

    var args = [_][]const u8{"only_one"};
    const result = try bat.expand("%1", &args, "C:\\bat");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "parseFile: state machine and env tracking" {
    var bat = testBatEnv();
    defer bat.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const bat_name = "test_script.bat";
    const bat_content =
        \\@echo off
        \\set TEST_VAR=old
        \\set TEST_VAR=123
        \\set REMOVED_VAR=value
        \\set REMOVED_VAR=
        \\if "%TEST_VAR%"=="123" set COND_VAR=success
        \\if not "%TEST_VAR%"=="456" set NOT_VAR=yes
        \\final_target.exe "arg1"
    ;
    const test_io = runtime.io();
    try tmp_dir.dir.writeFile(test_io, .{ .sub_path = bat_name, .data = bat_content });

    const abs_path = try tmp_dir.dir.realPathFileAlloc(test_io, bat_name, testing.allocator);
    defer testing.allocator.free(abs_path);

    // Call parseFile
    const final_args = try bat.parseFile(abs_path, &[_][]const u8{});
    defer if (final_args) |args| {
        for (args) |arg| testing.allocator.free(arg);
        testing.allocator.free(args);
    };

    try testing.expect(final_args != null);
    try testing.expectEqual(@as(usize, 2), final_args.?.len);
    try testing.expectEqualStrings("final_target.exe", final_args.?[0]);
    try testing.expectEqualStrings("arg1", final_args.?[1]);

    const test_var = bat.env.get("TEST_VAR");
    try testing.expect(test_var != null);
    try testing.expectEqualStrings("123", test_var.?);

    try testing.expect(bat.env.get("REMOVED_VAR") == null);

    const cond_var = bat.env.get("COND_VAR");
    try testing.expect(cond_var != null);
    try testing.expectEqualStrings("success", cond_var.?);

    const not_var = bat.env.get("NOT_VAR");
    try testing.expect(not_var != null);
    try testing.expectEqualStrings("yes", not_var.?);
}

test "parseFile: empty expansion of if/call lines does not crash" {
    var bat = testBatEnv();
    defer bat.deinit();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // %UNDEF% expands to an empty string, leaving bare "if " / "call "
    // commands that previously indexed past the end of the line.
    const bat_content =
        \\if %UNDEF%
        \\call %UNDEF%
        \\final_target.exe
    ;
    const test_io = runtime.io();
    try tmp_dir.dir.writeFile(test_io, .{ .sub_path = "empty_expand.bat", .data = bat_content });

    const abs_path = try tmp_dir.dir.realPathFileAlloc(test_io, "empty_expand.bat", testing.allocator);
    defer testing.allocator.free(abs_path);

    const final_args = try bat.parseFile(abs_path, &[_][]const u8{});
    defer if (final_args) |args| {
        for (args) |arg| testing.allocator.free(arg);
        testing.allocator.free(args);
    };

    try testing.expect(final_args != null);
    try testing.expectEqual(@as(usize, 1), final_args.?.len);
    try testing.expectEqualStrings("final_target.exe", final_args.?[0]);
}
