const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

pub const SearchMatch = struct {
    file: []const u8,
    line_number: usize,
    file_total_lines: usize,
    snippet: []const u8,
};

/// Internal struct for grouped file matches
const MatchInFile = struct {
    line_number: usize,
    snippet: []const u8,
};

pub const SearchInput = struct {
    pattern: []const u8,
    path: []const u8,
    max_results: ?usize = null,
    head: ?usize = null,
    tail: ?usize = null,
    max_output: ?usize = 1024 * 1024, // default 1MB
    group_by_file: bool = true, // when true, results are grouped by file
    cwd: ?[]const u8 = null,
};

pub const SearchResult = struct {
    matches: std.ArrayList(SearchMatch),
    content: []const u8,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        for (self.matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.snippet);
        }
        self.matches.deinit(allocator);
        allocator.free(self.content);
    }
};

fn getTextFromJson(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .object) {
            if (val.object.get("text")) |text_val| {
                if (text_val == .string) {
                    return text_val.string;
                }
            }
        }
    }
    return null;
}

fn getMatchedLines(obj: *const std.json.ObjectMap) ?usize {
    if (obj.get("stats")) |stats| {
        if (stats == .object) {
            if (stats.object.get("matched_lines")) |ml| {
                if (ml == .integer) {
                    return @intCast(ml.integer);
                }
            }
            if (stats.object.get("lines_with_matches")) |lw| {
                if (lw == .integer) {
                    return @intCast(lw.integer);
                }
            }
        }
    }
    return null;
}

pub fn executeSearch(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, input: SearchInput) !SearchResult {
    // Validate head/tail are mutually exclusive
    if (input.head != null and input.tail != null) {
        return error.HeadAndTailMutuallyExclusive;
    }

    const max_results = input.max_results orelse 50;

    const argv = &[_][]const u8{
        "rg",
        "--json",
        "--line-number",
        input.pattern,
        input.path,
    };

    const max_output = input.max_output orelse 1024 * 1024;
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(max_output),
        .cwd = .{ .path = input.cwd orelse cwd },
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var matches = std.ArrayList(SearchMatch).empty;
    errdefer {
        for (matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.snippet);
        }
        matches.deinit(allocator);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var file_stats = std.StringHashMap(usize).init(allocator);
    defer file_stats.deinit();

    const stdout_slice = result.stdout;
    var line_start: usize = 0;
    var current_file: ?[]const u8 = null;

    while (line_start < stdout_slice.len) {
        const line_end = std.mem.indexOfScalarPos(u8, stdout_slice, line_start, '\n') orelse stdout_slice.len;
        const line = stdout_slice[line_start..line_end];

        if (line.len > 0) {
            const parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, line, .{}) catch continue;

            if (parsed.value.object.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "begin")) {
                    if (parsed.value.object.get("data")) |data| {
                        if (data == .object) {
                            if (getTextFromJson(&data.object, "path")) |path_text| {
                                current_file = path_text;
                            }
                        }
                    }
                } else if (type_val == .string and std.mem.eql(u8, type_val.string, "match")) {
                    if (parsed.value.object.get("data")) |data| {
                        if (data == .object) {
                            var match_file: []const u8 = "";
                            var match_snippet: []const u8 = "";
                            var line_num: usize = 0;
                            var has_required = false;

                            if (getTextFromJson(&data.object, "path")) |path_text| {
                                match_file = path_text;
                            }

                            if (getTextFromJson(&data.object, "lines")) |lines_text| {
                                match_snippet = lines_text;
                            }

                            if (data.object.get("line_number")) |ln| {
                                if (ln == .integer) {
                                    line_num = @intCast(ln.integer);
                                    has_required = true;
                                }
                            }

                            if (has_required) {
                                const owned_file = try allocator.dupe(u8, match_file);
                                errdefer allocator.free(owned_file);

                                const owned_snippet = try allocator.dupe(u8, match_snippet);
                                errdefer allocator.free(owned_snippet);

                                const match = SearchMatch{
                                    .file = owned_file,
                                    .line_number = line_num,
                                    .file_total_lines = 0,
                                    .snippet = owned_snippet,
                                };
                                try matches.append(allocator, match);
                                if (matches.items.len >= max_results) break;
                            }
                        }
                    }
                } else if (type_val == .string and std.mem.eql(u8, type_val.string, "end")) {
                    if (current_file != null) {
                        if (parsed.value.object.get("data")) |data| {
                            if (data == .object) {
                                if (getMatchedLines(&data.object)) |ml| {
                                    try file_stats.put(current_file.?, ml);
                                }
                            }
                        }
                    }
                }
            }
        }
        line_start = line_end + 1;
    }

    for (matches.items) |*m| {
        if (file_stats.get(m.file)) |total| {
            m.file_total_lines = total;
        }
    }

    // Apply head/tail slicing after max_results limit
    if (input.head) |head_n| {
        if (head_n < matches.items.len) {
            // Keep only first head_n matches
            const to_remove = matches.items.len - head_n;
            for (0..to_remove) |i| {
                const idx = matches.items.len - 1 - i;
                allocator.free(matches.items[idx].file);
                allocator.free(matches.items[idx].snippet);
            }
            matches.shrinkRetainingCapacity(head_n);
        }
    } else if (input.tail) |tail_n| {
        if (tail_n < matches.items.len) {
            // Keep only last tail_n matches
            const start_idx = matches.items.len - tail_n;
            for (0..start_idx) |i| {
                allocator.free(matches.items[i].file);
                allocator.free(matches.items[i].snippet);
            }
            // Shift remaining to start
            const kept = matches.items[start_idx..];
            matches.shrinkRetainingCapacity(tail_n);
            @memcpy(matches.items, kept);
        }
    }

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    for (matches.items) |m| {
        const line = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}\n", .{ m.file, m.line_number, m.snippet });
        try output.appendSlice(allocator, line);
        allocator.free(line);
    }

    if (matches.items.len == 0) {
        if (result.stderr.len > 0) {
            try output.appendSlice(allocator, "<warning>");
            try output.appendSlice(allocator, result.stderr);
            try output.appendSlice(allocator, "</warning>");
        } else {
            try output.appendSlice(allocator, "<warning>pattern not found</warning>");
        }
    }

    return SearchResult{
        .matches = matches,
        .content = try output.toOwnedSlice(allocator),
    };
}

/// Multiple matches in the same file are grouped together under a <file> element
/// Wrapped in <search> tag containing the pattern and path used
pub fn search_result_to_string_grouped(allocator: std.mem.Allocator, result: SearchResult, pattern: []const u8, search_path: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    // Opening <search> tag with pattern and path
    try output.appendSlice(allocator, "<search pattern=\"");
    try output.appendSlice(allocator, pattern);
    try output.appendSlice(allocator, "\" path=\"");
    try output.appendSlice(allocator, search_path);
    try output.appendSlice(allocator, "\">\n");

    if (result.matches.items.len == 0) {
        try output.appendSlice(allocator, "</search>\n");
        return try output.toOwnedSlice(allocator);
    }

    // Group matches by file
    var file_groups = std.StringHashMap(std.ArrayList(MatchInFile)).init(allocator);
    defer {
        var it = file_groups.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
        }
        file_groups.deinit();
    }

    // Collect all matches grouped by file
    for (result.matches.items) |m| {
        const file_entry = try file_groups.getOrPut(m.file);
        if (!file_entry.found_existing) {
            file_entry.value_ptr.* = std.ArrayList(MatchInFile).empty;
        }
        try file_entry.value_ptr.append(allocator, .{
            .line_number = m.line_number,
            .snippet = m.snippet,
        });
    }

    // Get total_lines for each file
    var file_totals = std.StringHashMap(usize).init(allocator);
    defer file_totals.deinit();

    for (result.matches.items) |m| {
        if (m.file_total_lines > 0) {
            try file_totals.put(m.file, m.file_total_lines);
        }
    }

    // Output grouped format
    var it = file_groups.iterator();
    while (it.next()) |entry| {
        const file_path = entry.key_ptr.*;
        const matches_in_file = entry.value_ptr.*;

        const total = file_totals.get(file_path) orelse 0;
        const trimmed_path = std.mem.trim(u8, file_path, &std.ascii.whitespace);

        // File header
        try output.appendSlice(allocator, "  <file path=\"");
        try output.appendSlice(allocator, trimmed_path);
        try output.appendSlice(allocator, "\" total=\"");
        const total_str = try std.fmt.allocPrint(allocator, "{d}", .{total});
        try output.appendSlice(allocator, total_str);
        allocator.free(total_str);
        try output.appendSlice(allocator, "\" count=\"");
        const count_str = try std.fmt.allocPrint(allocator, "{d}", .{matches_in_file.items.len});
        try output.appendSlice(allocator, count_str);
        allocator.free(count_str);
        try output.appendSlice(allocator, "\">\n");

        // Each match in this file
        for (matches_in_file.items) |m| {
            const trimmed_snippet = std.mem.trim(u8, m.snippet, &std.ascii.whitespace);
            const match_xml = try std.fmt.allocPrint(allocator,
                \\    <m><l>{d}</l><s>{s}</s></m>\n
            , .{
                m.line_number,
                trimmed_snippet,
            });
            try output.appendSlice(allocator, match_xml);
            allocator.free(match_xml);
        }

        try output.appendSlice(allocator, "  </file>\n");
    }

    try output.appendSlice(allocator, "</search>\n");

    return try output.toOwnedSlice(allocator);
}

pub const search_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search",
        .description =
        \\Search for a pattern in files using ripgrep.
        \\Results wrapped in <search> tag with pattern/path attributes.
        \\No matches returns: <search pattern="..." path="..."></search>
        \\Response format:
        \\<search pattern="regex" path="path">
        \\  <file path="path/to/file.zig" total="100" count="3">
        \\    <m><l>10</l><s>snippet at line 10</s></m>
        \\    <m><l>25</l><s>snippet at line 25</s></m>
        \\  </file>
        \\</search>
        \\Where: total=file total lines, count=number of matches in this file.
        \\
        \\- Use this to locate symbols, functions, or types before reading.
        \\- Prefer this over bash+rg for code navigation.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "pattern",
                    .type = "string",
                    .description = "Regex or literal string to search for.",
                },
                .{
                    .name = "path",
                    .type = "string",
                    .description = "File or directory to search in.",
                },
                .{
                    .name = "max_results",
                    .type = "number",
                    .description = "Max matches to return. Default: 50.",
                },
                .{
                    .name = "head",
                    .type = "number",
                    .description = "Return first N matches from result set.",
                },
                .{
                    .name = "tail",
                    .type = "number",
                    .description = "Return last N matches from result set.",
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description = "Max output size in bytes. Default: 1048576 (1MB). Use larger value if you encounter StdoutStreamTooLong error.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Current working directory, default is cwd projects selected",
                },
            },
            .required = &.{ "pattern", "path" },
        },
    },
};

test {
    // Tests removed - search_test.zig removed due to API changes
}
