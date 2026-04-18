const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

// ============================================================================
// Glob Constants - Protection for LLM Context Windows
// ============================================================================

/// Default maximum number of results to return
/// Protects LLM context windows from being overwhelmed
pub const DEFAULT_MAX_RESULTS: usize = 100;

/// Default maximum output size in bytes (~50KB)
/// Prevents overwhelming LLM context windows with huge outputs
pub const DEFAULT_MAX_OUTPUT_BYTES: usize = 50 * 1024;

/// Maximum recommended results for a single glob call
/// Above this, users should use more specific patterns
pub const MAX_RECOMMENDED_RESULTS: usize = 500;

// ============================================================================
// Glob Types
// ============================================================================

/// Input for the glob tool - mimics node-glob API
pub const GlobInput = struct {
    /// Glob pattern to match (e.g., "*.zig", "**/*.ts", "{*.js,*.ts}")
    pattern: []const u8 = "*",
    /// Directory to search (default: ".")
    path: []const u8 = ".",
    /// Maximum number of results to return (default: 100)
    max_results: ?usize = null,
    /// Skip first N results for pagination
    offset: ?usize = null,
    /// Include hidden files (files starting with .)
    hidden: bool = false,
    /// Case insensitive matching
    ignore_case: bool = false,
    /// File type filter: "f" for files only, "d" for directories only
    file_type: ?[]const u8 = null,
    /// Follow symlinks
    follow: bool = false,
};

/// A single glob match result
pub const GlobMatch = struct {
    /// The matched file/directory path
    path: []const u8,
};

/// Result from executing a glob search
pub const GlobResult = struct {
    matches: std.ArrayList(GlobMatch),
    /// Number of results that were truncated due to max_results limit
    truncated_count: usize = 0,
    /// Total number of matches found (before truncation)
    total_found: usize = 0,
    /// Number of results skipped due to offset
    offset_applied: usize = 0,
    /// Whether output was truncated due to byte size limit
    truncated_by_size: bool = false,

    /// Free all allocated memory
    pub fn deinit(self: *GlobResult, allocator: std.mem.Allocator) void {
        for (self.matches.items) |m| {
            allocator.free(m.path);
        }
        self.matches.deinit(allocator);
    }
};

// ============================================================================
// Brace Expansion (like minimatch brace expansion)
// ============================================================================

/// Check if pattern contains brace expansion characters
fn hasBraceExpansion(pattern: []const u8) bool {
    var in_brace = false;
    for (pattern) |c| {
        if (c == '{') in_brace = true
        else if (c == '}') return in_brace
        else if (c == ',' and in_brace) return true;
    }
    return false;
}

/// Expand brace patterns like {a,b,c} or {1..5}
/// Returns array of expanded patterns
fn expandBracePatterns(pattern: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    // Find the outermost brace pair
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;

    while (i < pattern.len) {
        switch (pattern[i]) {
            '{' => {
                if (depth == 0) start = i;
                depth += 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    // Found outer brace pair
                    const prefix = if (start > 0) pattern[0..start] else "";
                    const suffix = if (i + 1 < pattern.len) pattern[i + 1..] else "";
                    const inner = pattern[start + 1 .. i];

                    // Parse inner content
                    var alternatives = std.ArrayListUnmanaged([]const u8){};
                    errdefer alternatives.deinit(allocator);

                    // Handle numeric range like 1..5
                    if (std.mem.indexOf(u8, inner, "..")) |range_idx| {
                        const before = inner[0..range_idx];
                        const after = inner[range_idx + 2..];
                        if (std.mem.allEqual(u8, before, '0') or
                            std.mem.allEqual(u8, before, '1') or
                            std.mem.allEqual(u8, before, '2') or
                            std.mem.allEqual(u8, before, '3') or
                            std.mem.allEqual(u8, before, '4') or
                            std.mem.allEqual(u8, before, '5') or
                            std.mem.allEqual(u8, before, '6') or
                            std.mem.allEqual(u8, before, '7') or
                            std.mem.allEqual(u8, before, '8') or
                            std.mem.allEqual(u8, before, '9')) {
                            if (std.mem.allEqual(u8, after, '0') or
                                std.mem.allEqual(u8, after, '1') or
                                std.mem.allEqual(u8, after, '2') or
                                std.mem.allEqual(u8, after, '3') or
                                std.mem.allEqual(u8, after, '4') or
                                std.mem.allEqual(u8, after, '5') or
                                std.mem.allEqual(u8, after, '6') or
                                std.mem.allEqual(u8, after, '7') or
                                std.mem.allEqual(u8, after, '8') or
                                std.mem.allEqual(u8, after, '9')) {
                                // It's a numeric range
                                const start_num = std.fmt.parseInt(i64, before, 10) catch 0;
                                const end_num = std.fmt.parseInt(i64, after, 10) catch 0;
                                const step: i64 = if (start_num <= end_num) 1 else -1;
                                var num = start_num;
                                while (true) {
                                    const num_str = try std.fmt.allocPrint(allocator, "{d}", .{num});
                                    errdefer allocator.free(num_str);
                                    const expanded = try std.mem.concat(allocator, u8, &.{
                                        prefix, num_str, suffix
                                    });
                                    errdefer allocator.free(expanded);
                                    try alternatives.append(allocator, expanded);
                                    if (num == end_num) break;
                                    num += step;
                                }
                                return try alternatives.toOwnedSlice(allocator);
                            }
                        }
                    }

                    // Parse comma-separated alternatives
                    var seg_start: usize = 0;
                    var j: usize = 0;
                    while (j <= inner.len) {
                        if (j == inner.len or inner[j] == ',') {
                            const seg = inner[seg_start..j];
                            if (seg.len > 0) {
                                const expanded = try std.mem.concat(allocator, u8, &.{
                                    prefix, seg, suffix
                                });
                                errdefer allocator.free(expanded);
                                try alternatives.append(allocator, expanded);
                            }
                            seg_start = j + 1;
                        }
                        j += 1;
                    }
                    return try alternatives.toOwnedSlice(allocator);
                }
            },
            else => {},
        }
        i += 1;
    }

    // No braces found, return single pattern
    const result = try allocator.alloc([]const u8, 1);
    result[0] = try allocator.dupe(u8, pattern);
    return result;
}

/// Recursively expand all braces in a pattern
fn expandAllBraces(pattern: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    if (!hasBraceExpansion(pattern)) {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, pattern);
        return result;
    }

    // Find first opening brace
    var brace_start: ?usize = null;
    var depth: usize = 0;
    for (pattern, 0..) |c, i| {
        if (c == '{') {
            if (depth == 0) brace_start = i;
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0 and brace_start != null) {
                // Expand this brace level
                const prefix = pattern[0..brace_start.?];
                const inner = pattern[brace_start.? + 1 .. i];
                const suffix = if (i + 1 < pattern.len) pattern[i + 1..] else "";

                // Expand inner braces first
                const inner_expanded = try expandAllBraces(inner, allocator);
                defer {
                    for (inner_expanded) |e| allocator.free(e);
                    allocator.free(inner_expanded);
                }

                // Generate all combinations
                var results = std.ArrayListUnmanaged([]const u8){};
                errdefer {
                    for (results.items) |r| allocator.free(r);
                    results.deinit(allocator);
                }

                for (inner_expanded) |inner_seg| {
                    const combined = try std.mem.concat(allocator, u8, &.{ prefix, inner_seg, suffix });
                    errdefer allocator.free(combined);

                    if (hasBraceExpansion(combined)) {
                        // Recurse for nested braces
                        const nested = try expandAllBraces(combined, allocator);
                        defer {
                            for (nested) |n| allocator.free(n);
                            allocator.free(nested);
                        }
                        for (nested) |n| {
                            const owned = try allocator.dupe(u8, n);
                            errdefer allocator.free(owned);
                            try results.append(allocator, owned);
                        }
                    } else {
                        try results.append(allocator, combined);
                    }
                }

                return try results.toOwnedSlice(allocator);
            }
        }
    }

    // No braces found
    const result = try allocator.alloc([]const u8, 1);
    result[0] = try allocator.dupe(u8, pattern);
    return result;
}

// ============================================================================
// Pattern Matching (minimatch-style)
// ============================================================================

/// Check if pattern contains glob special chars
fn hasGlobChars(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?[]") != null;
}

/// Match a single path component against a pattern (no / allowed)
/// Returns true if the component matches the pattern
fn matchComponent(path_seg: []const u8, pattern: []const u8, options: *const GlobOptions) bool {
    if (std.mem.eql(u8, pattern, "**")) return true;

    var pi: usize = 0;
    var si: usize = 0;

    while (pi < pattern.len and si < path_seg.len) {
        const pc = pattern[pi];
        switch (pc) {
            '*' => {
                pi += 1;
                if (pi >= pattern.len) return true; // * at end matches rest
                // Find next char in pattern to match
                const rest_pattern = pattern[pi..];
                const next_star = std.mem.indexOf(u8, rest_pattern, "*");
                const next_q = std.mem.indexOf(u8, rest_pattern, "?");
                const next_bracket = std.mem.indexOf(u8, rest_pattern, "[");

                var next_special: ?usize = null;
                if (next_star) |s| next_special = s;
                if (next_q) |q| {
                    if (next_special == null or q < (next_special.?)) next_special = q;
                }
                if (next_bracket) |b| {
                    if (next_special == null or b < (next_special.?)) next_special = b;
                }

                if (next_special) |ns| {
                    const target = rest_pattern[ns];
                    var match_pos = si;
                    while (match_pos < path_seg.len) {
                        if (path_seg[match_pos] == target) break;
                        match_pos += 1;
                    }
                    if (match_pos < path_seg.len) {
                        si = match_pos;
                        pi = pi + ns;
                    } else return false;
                } else {
                    // No more special chars, match to end
                    return std.mem.eql(u8, path_seg[si..], rest_pattern);
                }
            },
            '?' => {
                pi += 1;
                si += 1;
            },
            '[' => {
                pi += 1;
                if (pi >= pattern.len or pattern[pi] == '!') return false;
                var matched = false;
                var negated = false;
                if (pattern[pi] == '!') {
                    negated = true;
                    pi += 1;
                }
                while (pi < pattern.len and pattern[pi] != ']') {
                    if (pi + 2 < pattern.len and pattern[pi + 1] == '-') {
                        // Character range [a-z]
                        const start = pattern[pi];
                        const end = pattern[pi + 2];
                        if (si < path_seg.len and path_seg[si] >= start and path_seg[si] <= end) {
                            matched = true;
                        }
                        pi += 3;
                    } else {
                        if (si < path_seg.len and path_seg[si] == pattern[pi]) {
                            matched = true;
                        }
                        pi += 1;
                    }
                }
                if (pi < pattern.len and pattern[pi] == ']') pi += 1;
                if (negated) matched = !matched;
                if (!matched) return false;
                si += 1;
            },
            else => {
                if (!options.nocase and path_seg[si] != pc) return false;
                if (options.nocase and std.ascii.toLower(path_seg[si]) != std.ascii.toLower(pc)) return false;
                pi += 1;
                si += 1;
            },
        }
    }

    // Handle remaining pattern chars
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi >= pattern.len and si >= path_seg.len;
}

/// Match a pattern against a full path with ** support
fn matchPattern(path: []const u8, pattern: []const u8, options: *const GlobOptions) bool {
    // Split pattern and path into segments
    const pattern_segs = splitPath(pattern);
    const path_segs = splitPath(path);

    var pi: usize = 0;
    var si: usize = 0;

    while (pi < pattern_segs.len and si < path_segs.len) {
        const pat = pattern_segs[pi];
        const pseg = path_segs[si];

        if (std.mem.eql(u8, pat, "**")) {
            // ** matches anything including /
            pi += 1;
            if (pi >= pattern_segs.len) return true; // ** at end matches all

            // Look ahead for next non-** pattern
            var next_pi = pi;
            while (next_pi < pattern_segs.len and std.mem.eql(u8, pattern_segs[next_pi], "**")) next_pi += 1;

            if (next_pi >= pattern_segs.len) return true; // Ends with **

            // Try to match remaining pattern
            var test_si = si;
            while (test_si < path_segs.len) {
                if (matchSegments(path_segs[test_si..], pattern_segs[pi..], options)) return true;
                test_si += 1;
            }
            return false;
        } else {
            if (!matchComponent(pseg, pat, options)) return false;
            pi += 1;
            si += 1;
        }
    }

    // Handle trailing **
    while (pi < pattern_segs.len and std.mem.eql(u8, pattern_segs[pi], "**")) pi += 1;
    return pi >= pattern_segs.len and si >= path_segs.len;
}

/// Match path segments array against pattern segments array
fn matchSegments(path_segs: []const []const u8, pat_segs: []const []const u8, options: *const GlobOptions) bool {
    var si: usize = 0;
    var pi: usize = 0;

    while (pi < pat_segs.len and si < path_segs.len) {
        const pat = pat_segs[pi];
        const pseg = path_segs[si];

        if (std.mem.eql(u8, pat, "**")) {
            pi += 1;
            if (pi >= pat_segs.len) return true;
            var next_pi = pi;
            while (next_pi < pat_segs.len and std.mem.eql(u8, pat_segs[next_pi], "**")) next_pi += 1;
            if (next_pi >= pat_segs.len) return true;

            var test_si = si;
            while (test_si < path_segs.len) {
                if (matchSegments(path_segs[test_si..], pat_segs[pi..], options)) return true;
                test_si += 1;
            }
            return false;
        } else {
            if (!matchComponent(pseg, pat, options)) return false;
            pi += 1;
            si += 1;
        }
    }

    while (pi < pat_segs.len and std.mem.eql(u8, pat_segs[pi], "**")) pi += 1;
    return pi >= pat_segs.len and si >= path_segs.len;
}

/// Split path into segments by /
/// Returns slices of the original path (no allocation)
const MAX_PATH_SEGMENTS = 64;

fn splitPath(path: []const u8) []const []const u8 {
    var segments: [MAX_PATH_SEGMENTS][]const u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;

    // Handle leading /
    if (path.len > 0 and path[0] == '/') {
        segments[0] = "";
        count = 1;
        start = 1;
    }

    while (i < path.len) {
        if (path[i] == '/') {
            if (i > start) {
                segments[count] = path[start..i];
                count += 1;
            }
            start = i + 1;
        }
        i += 1;
    }
    if (start < path.len) {
        segments[count] = path[start..];
        count += 1;
    }

    return segments[0..count];
}

// ============================================================================
// Glob Options
// ============================================================================

/// Options for glob matching
pub const GlobOptions = struct {
    dot: bool = true,     // Match files starting with .
    nocase: bool = false, // Case insensitive matching
    nodir: bool = false,  // Don't match directories
    follow: bool = false,  // Follow symlinks
    onlydir: bool = false, // Match only directories
    ignore: ?[][]const u8 = null, // Patterns to ignore
    max_depth: ?usize = null, // Maximum directory depth
};

// ============================================================================
// Glob Implementation (Pure Zig)
// ============================================================================

/// Walk directory tree and collect matches
fn walkDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    patterns: [][]const u8,
    options: *const GlobOptions,
    results: *std.ArrayListUnmanaged([]const u8),
    depth: usize,
) !void {
    if (options.max_depth) |max| {
        if (depth >= max) return;
    }

    var dir: ?std.fs.Dir = null;
    if (std.fs.path.isAbsolute(dir_path)) {
        dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true, .no_follow = !options.follow }) catch return;
    } else {
        dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true, .no_follow = !options.follow }) catch return;
    }
    defer if (dir) |*d| d.close();

    var iter = dir.?.iterate();
    while (true) {
        const entry_opt = iter.next() catch break;
        const entry = entry_opt orelse break;
        const name = entry.name;
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, name });
        errdefer allocator.free(full_path);

        // Check dot option
        if (!options.dot and name[0] == '.') continue;

        const is_dir = entry.kind == .directory;

        // Check ignore patterns
        var should_ignore = false;
        if (options.ignore) |ignores| {
            for (ignores) |ignore_pat| {
                if (matchPattern(name, ignore_pat, options)) {
                    should_ignore = true;
                    break;
                }
            }
        }
        if (should_ignore) continue;

        // Check if matches any pattern
        var matches = false;
        for (patterns) |pat| {
            if (matchPattern(name, pat, options) or matchPattern(full_path, pat, options)) {
                matches = true;
                break;
            }
        }

        if (matches) {
            // Check type filters
            if (options.nodir and is_dir) continue;
            if (options.onlydir and !is_dir) continue;

            const owned = try allocator.dupe(u8, full_path);
            errdefer allocator.free(owned);
            try results.append(allocator, owned);
        }

        // Recurse into directories
        if (is_dir) {
            try walkDirectory(allocator, full_path, patterns, options, results, depth + 1);
        }
    }
}

/// Execute glob using pure Zig implementation
pub fn execute_glob_zig(allocator: std.mem.Allocator, input: GlobInput) !GlobResult {
    // Build patterns from input.pattern and expand braces
    var patterns = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (patterns.items) |p| allocator.free(p);
        patterns.deinit(allocator);
    }

    // Expand brace patterns
    const expanded = try expandAllBraces(input.pattern, allocator);
    defer {
        for (expanded) |e| allocator.free(e);
        allocator.free(expanded);
    }
    for (expanded) |e| {
        const owned = try allocator.dupe(u8, e);
        errdefer allocator.free(owned);
        try patterns.append(allocator, owned);
    }

    // Build options from input
    var options = GlobOptions{
        .dot = input.hidden,
        .nocase = input.ignore_case,
        .follow = input.follow,
    };

    // Parse file type filter
    if (input.file_type) |ft| {
        if (std.mem.eql(u8, ft, "f") or std.mem.eql(u8, ft, "file")) {
            options.nodir = true;
        } else if (std.mem.eql(u8, ft, "d") or std.mem.eql(u8, ft, "directory")) {
            options.onlydir = true;
        }
    }

    // Walk directory and collect matches
    var results = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (results.items) |r| allocator.free(r);
        results.deinit(allocator);
    }

    try walkDirectory(allocator, input.path, patterns.items, &options, &results, 0);

    // Convert to GlobMatch array with offset and limit
    var matches = std.ArrayList(GlobMatch).empty;
    errdefer {
        for (matches.items) |m| allocator.free(m.path);
        matches.deinit(allocator);
    }

    // Apply offset and max_results limit
    const total_found = results.items.len;
    const offset = input.offset orelse 0;
    const max_res = input.max_results orelse DEFAULT_MAX_RESULTS;
    const effective_limit = @min(max_res, MAX_RECOMMENDED_RESULTS);

    // Calculate start and end indices
    const start_idx = @min(offset, total_found);
    const end_idx = @min(start_idx + effective_limit, total_found);
    const truncated = if (total_found > end_idx) total_found - end_idx else 0;

    for (results.items[start_idx..end_idx]) |r| {
        try matches.append(allocator, .{ .path = r });
    }

    // Free skipped and extra results
    for (results.items[0..start_idx]) |r| allocator.free(r);
    if (truncated > 0) {
        for (results.items[end_idx..]) |r| allocator.free(r);
    }

    return GlobResult{
        .matches = matches,
        .truncated_count = truncated,
        .total_found = total_found,
        .offset_applied = offset,
    };
}

// ============================================================================
// Backwards Compatibility Alias (uses fd CLI)
// ============================================================================

/// Execute glob using fd CLI (legacy compatibility)
pub fn execute_glob(allocator: std.mem.Allocator, input: GlobInput) !GlobResult {
    return execute_glob_zig(allocator, input);
}

// ============================================================================
// Output Formatting
// ============================================================================

/// Convert GlobResult to XML string format
/// Applies byte-size truncation to protect LLM context windows
pub fn glob_result_to_string(allocator: std.mem.Allocator, result: GlobResult) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var byte_count: usize = 0;
    var truncated_by_size = false;
    var files_written: usize = 0;

    for (result.matches.items) |m| {
        const match_xml = try std.fmt.allocPrint(allocator, "<f>{s}</f>\n", .{m.path});
        const match_len = match_xml.len;

        // Check if adding this match would exceed the byte limit
        if (byte_count + match_len > DEFAULT_MAX_OUTPUT_BYTES and files_written > 0) {
            truncated_by_size = true;
            allocator.free(match_xml);
            break;
        }

        try output.appendSlice(allocator, match_xml);
        allocator.free(match_xml);
        byte_count += match_len;
        files_written += 1;
    }

    if (output.items.len == 0) {
        return try std.fmt.allocPrint(allocator, "<warning>No files found matching the glob pattern.</warning>", .{});
    }

    // Build summary header with stats
    const summary = try std.fmt.allocPrint(allocator,
        \\<glob_summary total="{d}" returned="{d}" offset="{d}" truncated="{d}" byte_size="{d}" max_bytes="{d}">
    , .{
        result.total_found,
        files_written,
        result.offset_applied,
        result.truncated_count + if (truncated_by_size) (result.matches.items.len - files_written) else 0,
        byte_count,
        DEFAULT_MAX_OUTPUT_BYTES,
    });
    errdefer allocator.free(summary);

    // Prepend summary to output
    var final_output = std.ArrayList(u8).empty;
    errdefer final_output.deinit(allocator);

    try final_output.appendSlice(allocator, summary);
    try final_output.appendSlice(allocator, output.items);
    try final_output.appendSlice(allocator, "</glob_summary>\n");

    // Add truncation warnings
    if (result.truncated_count > 0) {
        const warning = try std.fmt.allocPrint(allocator,
            \\<truncated type="count">{d} files truncated. Use more specific patterns or increase limit with -n</truncated>
        , .{result.truncated_count});
        errdefer allocator.free(warning);
        try final_output.appendSlice(allocator, warning);
    }

    if (truncated_by_size) {
        const size_warning = try std.fmt.allocPrint(allocator,
            \\<truncated type="size">Output truncated to {d} bytes to protect LLM context window. Use more specific patterns.</truncated>
        , .{DEFAULT_MAX_OUTPUT_BYTES});
        errdefer allocator.free(size_warning);
        try final_output.appendSlice(allocator, size_warning);
    }

    return try final_output.toOwnedSlice(allocator);
}

// ============================================================================
// Tool Definition
// ============================================================================

/// OpenAI-compatible glob tool definition
pub const glob_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "glob",
        .description =
        \\Find files matching glob patterns (like node-glob).
        \\Returns: <f>path</f> for each match wrapped in <glob_summary> with stats.
        \\
        \\Glob patterns supported:
        \\  * - Match any characters (except /)
        \\  ** - Match any characters including / (recursive)
        \\  ? - Match single character
        \\  [abc] - Character class
        \\  {a,b,c} - Brace expansion
        \\  {1..5} - Numeric range expansion
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "pattern",
                    .type = "string",
                    .description = "Glob pattern (e.g., \"*.zig\", \"**/*.ts\", \"{*.js,*.ts}\"). Default: \"*\"",
                },
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Directory to search. Default: \".\"",
                },
                .{
                    .name = "max_results",
                    .type = "number",
                    .description = "Maximum number of results (default: 100, max: 500)",
                },
                .{
                    .name = "offset",
                    .type = "number",
                    .description = "Skip first N results for pagination. Use with max_results for paging.",
                },
                .{
                    .name = "hidden",
                    .type = "boolean",
                    .description = "Include hidden files (starting with .). Default: false",
                },
                .{
                    .name = "ignore_case",
                    .type = "boolean",
                    .description = "Case insensitive matching. Default: false",
                },
                .{
                    .name = "file_type",
                    .type = "string",
                    .description = "Filter by type: \"f\" for files, \"d\" for directories",
                },
                .{
                    .name = "follow",
                    .type = "boolean",
                    .description = "Follow symlinks. Default: false",
                },
            },
            .required = &.{},
        },
    },
};

