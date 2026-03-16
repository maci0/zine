const std = @import("std");

pub const BatEnv = struct {
    allocator: std.mem.Allocator,
    env: std.StringHashMap([]const u8),

    /// Initializes a new batch environment.
    pub fn init(allocator: std.mem.Allocator) !BatEnv {
        var self = BatEnv{
            .allocator = allocator,
            .env = std.StringHashMap([]const u8).init(allocator),
        };
        // Load initial env
        var it = std.process.getEnvMap(allocator) catch unreachable;
        defer it.deinit();

        var env_it = it.iterator();
        while (env_it.next()) |entry| {
            try self.env.put(try self.allocator.dupe(u8, entry.key_ptr.*), try self.allocator.dupe(u8, entry.value_ptr.*));
        }

        // Default MSVC environment expectations
        try self.env.put("OS", "Windows_NT");
        return self;
    }

    /// Frees all resources associated with the batch environment.
    pub fn deinit(self: *BatEnv) void {
        self.env.deinit();
    }

    fn expand(self: *BatEnv, input: []const u8, args: [][]const u8, current_bat_dir: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .{};
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
        var file = std.fs.cwd().openFile(open_path, .{}) catch |err| {
            std.debug.print("Failed to open bat file {s}: {s}\n", .{open_path, @errorName(err)});
            return null;
        };
        defer file.close();

        // Read the entire file into a string
        const file_content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB max
        defer self.allocator.free(file_content);

        // Resolve absolute dir of the bat file for %~dp0
        const abs_path = try std.fs.cwd().realpathAlloc(self.allocator, open_path);
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
                cmd_line = std.mem.trimLeft(u8, cmd_line[3..], " \t");
                var is_not = false;
                if (std.ascii.startsWithIgnoreCase(cmd_line, "not ")) {
                    is_not = true;
                    cmd_line = std.mem.trimLeft(u8, cmd_line[4..], " \t");
                }

                if (cmd_line[0] == '"') {
                    if (std.mem.indexOfScalarPos(u8, cmd_line, 1, '"')) |quote_end| {
                        const lhs = cmd_line[1..quote_end];
                        const rest1 = std.mem.trimLeft(u8, cmd_line[quote_end + 1 ..], " \t");
                        if (std.ascii.startsWithIgnoreCase(rest1, "==")) {
                            const rest2 = std.mem.trimLeft(u8, rest1[2..], " \t");
                            if (rest2[0] == '"') {
                                if (std.mem.indexOfScalarPos(u8, rest2, 1, '"')) |quote2_end| {
                                    const rhs = rest2[1..quote2_end];
                                    const cond_met = std.ascii.eqlIgnoreCase(lhs, rhs);
                                    if (cond_met != is_not) {
                                        cmd_line = std.mem.trimLeft(u8, rest2[quote2_end + 1 ..], " \t");
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
                const assign = std.mem.trimLeft(u8, cmd_line[4..], " \t");
                if (std.mem.indexOfScalar(u8, assign, '=')) |eq_idx| {
                    const key = std.mem.trim(u8, assign[0..eq_idx], " \t");
                    const val = std.mem.trim(u8, assign[eq_idx + 1 ..], " \t");
                    
                    // Windows SET can just unset variable if value is empty
                    if (val.len == 0) {
                        _ = self.env.remove(key);
                    } else {
                        try self.env.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, val));
                    }
                }
                continue;
            }

            if (std.ascii.startsWithIgnoreCase(cmd_line, "call ")) {
                var call_target = std.mem.trimLeft(u8, cmd_line[5..], " \t");
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

            // If we get here and the command isn't a known keyword, it's the final execution command!
            // We just return it as args.
            // Simplified parsing by spaces, ignoring quotes for simplicity, but let's do a naive split
            var final_args: std.ArrayList([]const u8) = .{};
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
        var envp_list: std.ArrayList(?[*:0]u8) = .{};
        var it = self.env.iterator();
        while (it.next()) |entry| {
            const str = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{entry.key_ptr.*, entry.value_ptr.*});
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
