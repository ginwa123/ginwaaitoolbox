const std = @import("std");
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

pub const SearchMatch = struct {
    file: []const u8,
    line_number: usize,
    file_total_lines: usize,
    snippet: []const u8,
};

pub const SearchInput = struct {
    pattern: []const u8,
    path: []const u8,
    max_results: ?usize = null,
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

pub fn executeSearch(allocator: std.mem.Allocator, input: SearchInput) !SearchResult {
    const max_results = input.max_results orelse 50;

    const argv = &[_][]const u8{
        "rg",
        "--json",
        "--line-number",
        input.pattern,
        input.path,
    };

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
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

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    for (matches.items) |m| {
        const line = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}\n", .{ m.file, m.line_number, m.snippet });
        try output.appendSlice(allocator, line);
        allocator.free(line);
    }

    if (matches.items.len == 0 and result.stderr.len > 0) {
        try output.appendSlice(allocator, "No matches found. ");
        try output.appendSlice(allocator, result.stderr);
    }

    return SearchResult{
        .matches = matches,
        .content = try output.toOwnedSlice(allocator),
    };
}

/// Convert SearchResult to XML string format
pub fn searchResultToString(allocator: std.mem.Allocator, result: SearchResult) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, "<results>\n");

    for (result.matches.items) |m| {
        const match_xml = try std.fmt.allocPrint(allocator,
            \\<match>
            \\<file>{s}</file>
            \\<line_number>{d}</line_number>
            \\<file_total_lines>{d}</file_total_lines>
            \\<snippet>{s}</snippet>
            \\</match>
        , .{
            m.file,
            m.line_number,
            m.file_total_lines,
            m.snippet,
        });
        try output.appendSlice(allocator, match_xml);
        allocator.free(match_xml);
    }

    try output.appendSlice(allocator, "</results>");

    return try output.toOwnedSlice(allocator);
}

pub const searchTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search",
        .description =
        \\Search for a pattern in files using ripgrep.
        \\Returns: file, line_number, file_total_lines, snippet for each match.
        \\
        \\- Use this to locate symbols, functions, or types before reading.
        \\- file_total_lines tells you if pagination is needed in read_file.
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
            },
            .required = &.{ "pattern", "path" },
        },
    },
};


test {
    _ = @import("search_test.zig");
}
