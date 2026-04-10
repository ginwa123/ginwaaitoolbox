const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// Input for the glob tool.
/// Uses flexible any-style arguments that map to fd CLI options:
/// - pattern: the search pattern (positional arg)
/// - path: directory to search (positional arg, default: ".")
/// - e: file extension filter (e.g., "zig", "ts")
/// - g, glob: glob pattern (alternative to positional pattern)
/// - H, hidden: include hidden files
/// - t, type: file type (f=file, d=directory, l=symlink, x=executable)
/// - j, threads: number of threads
/// - F, flat: show results in flat format
/// - I, ignore-case: case insensitive search
/// - L, follow: follow symlinks
/// - p, permission: filter by permissions (e.g., "755", "644")
pub const GlobInput = struct {
    /// Flexible arguments passed directly to fd CLI.
    /// Supports: e cs | grep Service | grep -v Test -style arguments.
    /// Common patterns:
    ///   -e zig = file extension "zig"
    ///   -H = include hidden files
    ///   -t f = files only, -t d = directories only
    ///   --max-results 50 = limit results
    ///   -I = case insensitive
    any: []const u8 = "",
};

/// A single glob match result.
pub const GlobMatch = struct {
    /// The matched file/directory path
    path: []const u8,
};

/// Result from executing a glob search.
pub const GlobResult = struct {
    matches: std.ArrayList(GlobMatch),
    /// Number of results that were truncated due to max_results limit.
    /// 0 means not truncated.
    truncated_count: usize = 0,

    /// Free all allocated memory.
    pub fn deinit(self: *GlobResult, allocator: std.mem.Allocator) void {
        for (self.matches.items) |m| {
            allocator.free(m.path);
        }
        self.matches.deinit(allocator);
    }
};

/// Tokenize a shell-like argument string, respecting quotes and escaping.
/// Handles: pattern, -e zig, -H, --max-results 50, "quoted args"
fn tokenizeArgs(input: []const u8, allocator: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
    var args = std.ArrayListUnmanaged([]const u8){};
    errdefer args.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        // Skip whitespace
        while (i < input.len) {
            if (input[i] == ' ') {
                i += 1;
            } else break;
        }
        if (i >= input.len) break;

        // Check for quoted string
        if (input[i] == '"' or input[i] == '\'') {
            const quote = input[i];
            i += 1;
            const start = i;
            while (i < input.len and input[i] != quote) {
                i += 1;
            }
            const value = input[start..i];
            i += 1; // skip closing quote
            try args.append(allocator, try allocator.dupe(u8, value));
        } else {
            // Regular token
            const start = i;
            while (i < input.len and input[i] != ' ') {
                i += 1;
            }
            const token = input[start..i];
            if (token.len > 0) {
                try args.append(allocator, try allocator.dupe(u8, token));
            }
        }
    }

    return args;
}

/// Check if a token looks like a path (contains / or is a directory-like path)
fn looksLikePath(token: []const u8) bool {
    // Contains path separator
    if (std.mem.indexOfScalar(u8, token, '/') != null) return true;
    // Is "." or ".."
    if (token.len > 0 and token[0] == '.') return true;
    return false;
}

/// Parse tokens into positional args (pattern, path) and fd options.
/// fd CLI: fd [OPTIONS] pattern [path]
/// Handles the case where fd is strict about paths - a path ending with / won't work.
fn parseGlobArgs(tokens: [][]const u8, allocator: std.mem.Allocator) !struct {
    pattern: []const u8,
    path: []const u8,
    options: std.ArrayListUnmanaged([]const u8),
} {
    var pattern: []const u8 = "";
    var path: []const u8 = ".";
    var options = std.ArrayListUnmanaged([]const u8){};

    var i: usize = 0;
    while (i < tokens.len) {
        const token = tokens[i];
        if (std.mem.startsWith(u8, token, "-")) {
            // It's an option
            try options.append(allocator, token);
            i += 1;
            // Check if this option has a value (not a flag)
            if (i < tokens.len and !std.mem.startsWith(u8, tokens[i], "-")) {
                try options.append(allocator, tokens[i]);
                i += 1;
            }
        } else if (looksLikePath(token)) {
            // Looks like a path - use as path if we haven't set one yet
            if (path.len == 1) {
                // Remove trailing slash from path (fd doesn't like it)
                if (token.len > 1 and token[token.len - 1] == '/') {
                    path = token[0..token.len - 1];
                } else {
                    path = token;
                }
            }
            i += 1;
        } else {
            // It's a pattern
            if (pattern.len == 0) {
                pattern = token;
            } else if (path.len == 1) {
                // Second non-option non-path token - treat as path
                path = token;
            }
            i += 1;
        }
    }

    return .{ .pattern = pattern, .path = path, .options = options };
}

/// Execute a glob search using the `fd` CLI tool.
///
/// Parses the `any` field as shell-like arguments and passes them to fd CLI:
/// - First non-option arg = pattern (default: "")
/// - Second non-option arg = path (default: ".")
/// - Options are passed through directly to fd (e.g., -e zig, -H, -t f)
///
/// Examples:
///   - "*.zig" → fd "*.zig" .
///   - "*.zig src/" → fd "*.zig" src/ (trailing / removed)
///   - "-e zig" → fd -e zig .  (file extension)
///   - "-e zig src/ -H" → fd -e zig src/ -H
pub fn executeGlob(allocator: std.mem.Allocator, input: GlobInput) !GlobResult {
    // Tokenize the any arguments
    var tokens = try tokenizeArgs(input.any, allocator);
    defer {
        for (tokens.items) |t| allocator.free(t);
        tokens.deinit(allocator);
    }

    // Parse into pattern, path, and options
    var parsed = try parseGlobArgs(tokens.items, allocator);

    // Build argument list for fd
    var args = std.ArrayListUnmanaged([]const u8){};
    errdefer args.deinit(allocator);

    // fd path
    try args.append(allocator, "/usr/sbin/fd");

    // Add options first
    for (parsed.options.items) |opt| {
        try args.append(allocator, opt);
    }

    // The pattern (use "" if not specified - fd matches everything with empty pattern)
    try args.append(allocator, if (parsed.pattern.len > 0) parsed.pattern else "");

    // Path to search
    try args.append(allocator, parsed.path);

    // Run fd
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.items,
        .max_output_bytes = 10 * 1024 * 1024, // 10MB max
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Free options memory
    for (parsed.options.items) |opt| allocator.free(opt);
    parsed.options.clearAndFree(allocator);

    // Parse results
    var matches = std.ArrayListUnmanaged(GlobMatch){};
    errdefer {
        for (matches.items) |m| {
            allocator.free(m.path);
        }
        matches.deinit(allocator);
    }

    // Split stdout by newlines
    var line_start: usize = 0;
    while (line_start < result.stdout.len) {
        const line_end = std.mem.indexOfScalarPos(u8, result.stdout, line_start, '\n') orelse result.stdout.len;
        if (line_end > line_start) {
            const line = result.stdout[line_start..line_end];
            if (line.len > 0) {
                const owned_path = try allocator.dupe(u8, line);
                errdefer allocator.free(owned_path);
                try matches.append(allocator, .{ .path = owned_path });
            }
        }
        line_start = line_end + 1;
    }

    return GlobResult{ .matches = matches, .truncated_count = 0 };
}

/// Convert GlobResult to XML string format with <f> tags.
/// Returns a warning message if no matches are found.
/// Returns a truncation warning if results were limited.
pub fn globResultToString(allocator: std.mem.Allocator, result: GlobResult) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    for (result.matches.items) |m| {
        const match_xml = try std.fmt.allocPrint(allocator,
            \\<f>{s}</f>
        , .{m.path});
        try output.appendSlice(allocator, match_xml);
        allocator.free(match_xml);
    }

    // Return a warning if no matches found
    if (output.items.len == 0) {
        return try std.fmt.allocPrint(allocator, "<warning>No files found matching the glob pattern.</warning>", .{});
    }

    // Add truncation warning if results were limited
    if (result.truncated_count > 0) {
        const truncation_warning = try std.fmt.allocPrint(allocator,
            "\n<truncated>{d} files truncated. Consider using offset/max_results or more specific patterns.</truncated>",
            .{result.truncated_count});
        defer allocator.free(truncation_warning);
        try output.appendSlice(allocator, truncation_warning);
    }

    return try output.toOwnedSlice(allocator);
}

/// OpenAI-compatible glob tool definition.
pub const glob_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "glob",
        .description =
        \\Find files using the fd CLI.
        \\Returns: <f>path</f> for each match.
        \\Supports shell-like arguments:
        \\  - First non-option arg = pattern (default: "*")
        \\  - Second non-option arg = path (default: ".")
        \\  - Options: -e zig (extension), -H (hidden), -t f/d (type), -I (ignore case)
        \\  - --max-results N = limit results
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "any",
                    .type = "string",
                    .description =
                    \\Shell-like arguments passed to fd CLI.
                    \\Examples:
                    \\  "*.zig" -e zig -H src/
                    \\  "-e zig src/ -H --max-results 50"
                    \\  "cs -I -t f"
                    \\fd will be called with these args directly.
                    ,
                },
            },
            .required = &.{},
        },
    },
};
