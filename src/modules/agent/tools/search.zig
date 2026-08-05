const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const sanitize = @import("../../../helpers/sanitize.zig");

pub const SearchError = error{
    /// Pattern was an empty string — almost certainly a caller bug, not a
    /// "no match" condition. ripgrep accepts empty patterns but the tool
    /// should reject them so the LLM/operator sees a clear error.
    EmptyPattern,
    /// Pattern contained a NUL byte. ripgrep silently truncates at NUL,
    /// which would mean the LLM's intended search runs against a shorter
    /// (and likely wrong) pattern. Reject up-front instead.
    PatternContainsNulByte,
    /// max_output was 0. Passing stdout_limit = .limited(0) to ripgrep
    /// produces zero output and a confusing failure mode.
    InvalidMaxOutput,
    /// max_output exceeded the hard ceiling (100 MB). Prevents a single
    /// search from OOM-ing the process.
    MaxOutputTooLarge,
    /// max_results was 0. Returns empty matches + "<warning>pattern not
    /// found" which looks identical to a real no-match and confuses the
    /// LLM. Treat as a caller bug.
    InvalidMaxResults,
    /// ripgrep could not parse the pattern as a valid regex (exit 2
    /// with a "regex parse error" / "regex error" signature in stderr).
    RegexParseError,
    /// ripgrep could not access the path (path doesn't exist, permission
    /// denied, etc). Wraps the ripgrep stderr text in the error name.
    PathError,
};

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
    /// When true (default), ripgrep respects .gitignore / .ignore / .rgignore.
    /// When false, appends `--no-ignore` to rg's argv so it searches
    /// gitignored paths (build/, node_modules/, etc.). Mirrors rg's
    /// --no-ignore flag, which disables ALL ignore-file filtering.
    respect_ignore_files: bool = true,
    /// When true, appends `-w` to rg's argv: matches must be at a word
    /// boundary (start/end of file, or between word and non-word chars).
    /// ripgrep's default Unicode word rule treats underscore as a word
    /// char, so `foo` with -w does NOT match inside `foo_bar`. Hyphen,
    /// plus, parens, brackets, etc. ARE boundaries.
    word_boundary: bool = false,
    /// When true, the pattern is treated as a literal string (no regex
    /// metacharacters are interpreted). Maps to rg's `-F` / `--fixed-strings`.
    /// Default false (regex mode). NOTE: Chunk 2 will wire the `-F`
    /// argv branch; for Chunk 1 this field exists in the struct but
    /// has no effect on rg's behavior.
    literal: bool = false,
    /// When true, only the matched substring is shown per line (instead
    /// of the full line content). Maps to rg's `-o` / `--only-matching`.
    /// Useful for fast extraction (e.g. all email addresses in a file)
    /// without the surrounding context. NOTE: Chunk 3 will wire the `-o`
    /// argv branch and the snippet-rendering logic; for Chunk 1 this
    /// field exists in the struct but has no effect on rg's behavior.
    only_matching: bool = false,
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

/// Hard ceiling on max_output to prevent a single search from OOM-ing the
/// process. 100 MB is large enough for any practical search (genuinely huge
/// codebases will still fit) but small enough to bound the worst case.
pub const max_output_hard_limit: usize = 100 * 1024 * 1024;

pub fn executeSearch(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, input: SearchInput) !SearchResult {
    // === Up-front validation (no ripgrep invocation if any fail) ===

    // Validate head/tail are mutually exclusive
    if (input.head != null and input.tail != null) {
        return error.HeadAndTailMutuallyExclusive;
    }

    // Pattern must be non-empty. ripgrep accepts empty patterns but the
    // result is meaningless — reject so the caller sees a clear error.
    if (input.pattern.len == 0) return error.EmptyPattern;

    // Reject patterns containing NUL bytes. ripgrep's C-string handling
    // truncates at NUL, which would mean the LLM's intended pattern is
    // silently mutated. Refuse the call entirely.
    if (std.mem.indexOfScalar(u8, input.pattern, 0) != null) {
        return error.PatternContainsNulByte;
    }

    // Validate max_output bounds up-front. Zero is meaningless; over the
    // hard ceiling risks OOM.
    const max_output = input.max_output orelse 1024 * 1024;
    if (max_output == 0) return error.InvalidMaxOutput;
    if (max_output > max_output_hard_limit) return error.MaxOutputTooLarge;

    // Validate max_results. Zero is indistinguishable from "no match" and
    // is almost certainly a caller bug.
    const max_results = input.max_results orelse 50;
    if (max_results == 0) return error.InvalidMaxResults;

    // === Build ripgrep argv with flag-injection defense ===
    //
    // We use `-e <pattern>` to tell ripgrep "next arg is the pattern", which
    // means a pattern starting with `-` (e.g. `--help`, `--`, `-z`) is
    // treated as a literal search string and NOT as a flag. We then put
    // `--` before the path so that even if someone passes a path like
    // `--pre-glob=...` it can't be misinterpreted.
    //
    // `--no-config` blocks `~/.ripgreprc` / `.ripgreprc` from being loaded,
    // which is an attacker-controlled flag surface on multi-user systems.
    // `--no-messages` suppresses ripgrep's stderr (we surface the errors
    // ourselves via the exit-code mapping below).
    //
    // The optional flags (`--no-ignore`, `-w`, `-F`, `-o`) are appended
    // conditionally — the const-array shape can't scale to that, so we
    // build a runtime ArrayList. Each entry is a `[]const u8` that
    // already lives in static memory or is owned by `input`; we don't
    // allocate per-flag, only the ArrayList's backing storage.
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, "rg");
    try args.append(allocator, "--json");
    try args.append(allocator, "--line-number");
    try args.append(allocator, "--no-config");
    try args.append(allocator, "--no-messages");
    if (!input.respect_ignore_files) {
        try args.append(allocator, "--no-ignore");
    }
    if (input.word_boundary) {
        // -w: only match whole words (word-boundary semantics).
        // rg's default Unicode word rule treats underscore as a word
        // char, so this matches what `-w` says, not what an English
        // speaker might expect for `foo_bar`.
        try args.append(allocator, "-w");
    }
    // Chunk 2: literal / -F flag. Treat the pattern as opaque bytes
    // instead of a regex. With -F, rg cannot fail to parse the pattern
    // (it's just a literal byte sequence), so the stderr-based
    // RegexParseError mapping at search.zig:245-250 should never fire
    // for `literal = true` calls.
    if (input.literal) {
        try args.append(allocator, "-F");
    }
    if (input.only_matching) {
        // -o / --only-matching: rg emits ONLY the matched substring
        // per line (via data.submatches[]), NOT the full surrounding
        // line. Used for fast extraction (e.g. all email addresses
        // in a file) without surrounding context.
        try args.append(allocator, "-o");
    }
    try args.append(allocator, "-e");
    try args.append(allocator, input.pattern);
    try args.append(allocator, "--");
    try args.append(allocator, input.path);

    const result = std.process.run(allocator, io, .{
        .argv = args.items,
        .stdout_limit = std.Io.Limit.limited(max_output),
        .cwd = .{ .path = input.cwd orelse cwd },
    }) catch |err| {
        // Map clear errors to our domain:
        // - FileNotFound on cwd → tell the caller the working directory is wrong
        if (err == error.FileNotFound) return error.PathError;
        return err;
    };

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // === Map ripgrep exit code to a domain error or accept stdout ===
    //
    // ripgrep exit codes (from rg --help):
    //   0 — match found
    //   1 — no match (empty stdout, stderr empty)
    //   2 — error (regex parse error, file/dir not found, permission denied)
    //   signal/stopped/unknown — process-level oddities
    //
    // We can't tell exit_code 2's sub-cause from the code alone, but we
    // CAN pattern-match on stderr text. The heuristics here are deliberately
    // conservative — if the heuristic misses, we still surface a clear
    // error.
    switch (result.term) {
        .exited => |code| switch (code) {
            0 => {}, // success — fall through
            1 => {}, // no match — fall through (empty matches list will yield "pattern not found" later)
            else => {
                // exit 2 (or other non-zero) → distinguish by stderr
                const stderr_text = result.stderr;
                if (std.mem.indexOf(u8, stderr_text, "regex") != null or
                    std.mem.indexOf(u8, stderr_text, "Regex") != null or
                    std.mem.indexOf(u8, stderr_text, "pattern") != null)
                {
                    return error.RegexParseError;
                }
                return error.PathError;
            },
        },
        .signal, .stopped, .unknown => {
            // rg was killed by signal (e.g. ulimit, OOM) or terminated
            // abnormally. Surface as a path/I/O error so the LLM retries
            // with a different path or smaller pattern.
            return error.PathError;
        },
    }

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
                            // Tracks whether match_snippet is a heap-owned
                            // allocation we must free (true only when built
                            // from the comma-joined multi-submatch path).
                            // The single-submatch and default-line paths
                            // borrow slices from the JSON arena, which
                            // lives until this function returns.
                            var match_snippet_owned = false;
                            var line_num: usize = 0;
                            var line_num_valid = false;
                            var file_ok = false;

                            if (getTextFromJson(&data.object, "path")) |path_text| {
                                if (path_text.len > 0) {
                                    match_file = path_text;
                                    file_ok = true;
                                }
                            }

                            if (input.only_matching) {
                                // --only-matching: snippet = matched
                                // substring(s) from submatches[]. With -o,
                                // rg emits a single match event per line
                                // even when the regex matches multiple
                                // times on that line; ALL submatches live
                                // in one match event's submatches[] array.
                                // We flatten into one SearchMatch with a
                                // comma-joined snippet (single-string shape
                                // is preserved for downstream callers).
                                if (data.object.get("submatches")) |submatches_val| {
                                    if (submatches_val == .array) {
                                        const submatch_list = submatches_val.array;
                                        if (submatch_list.items.len == 1) {
                                            // Single submatch: use its match.text directly.
                                            if (getTextFromJson(&submatch_list.items[0].object, "match")) |match_text| {
                                                match_snippet = match_text;
                                            }
                                        } else if (submatch_list.items.len > 1) {
                                            // Multiple submatches on same line:
                                            // comma-join into one snippet string.
                                            // We need a fresh heap allocation here
                                            // (not a slice of a local ArrayList),
                                            // because `match_snippet` must outlive
                                            // this block — it's read later by
                                            // sanitizeUtf8 at line 393. A slice
                                            // into a local ArrayList would be
                                            // freed when the ArrayList goes out
                                            // of scope, causing a use-after-free
                                            // (see project memory
                                            // zig-slice-headers-across-defer-lifetimes).
                                            var combined: std.ArrayList(u8) = .empty;
                                            defer combined.deinit(allocator);
                                            for (submatch_list.items, 0..) |sub, i| {
                                                if (i > 0) try combined.append(allocator, ',');
                                                if (getTextFromJson(&sub.object, "match")) |m| {
                                                    try combined.appendSlice(allocator, m);
                                                }
                                            }
                                            // Heap-owned dupe (allocator.dupe)
                                            // so the slice outlives the
                                            // ArrayList's defer. We track this
                                            // allocation via match_snippet_owned
                                            // (see below) so we can free it after
                                            // sanitizeUtf8 reads it.
                                            const owned = allocator.dupe(u8, combined.items) catch {
                                                // OOM: skip this match
                                                continue;
                                            };
                                            match_snippet = owned;
                                            match_snippet_owned = true;
                                        }
                                        // If submatch_list.items.len == 0
                                        // (shouldn't happen for a real match
                                        // event), match_snippet stays "".
                                    }
                                }
                            } else {
                                // Default: snippet = full surrounding line.
                                if (getTextFromJson(&data.object, "lines")) |lines_text| {
                                    match_snippet = lines_text;
                                }
                            }

                            if (data.object.get("line_number")) |ln| {
                                if (ln == .integer) {
                                    // Validate before casting: rg emits
                                    // positive line numbers, so 0 or
                                    // negative is corrupt. Previously
                                    // the code did @intCast(ln.integer)
                                    // which PANICS in safe builds on
                                    // negative values, and wraps to a
                                    // huge usize in release-fast.
                                    if (ln.integer >= 1 and ln.integer <= std.math.maxInt(usize)) {
                                        line_num = @intCast(ln.integer);
                                        line_num_valid = true;
                                    }
                                }
                            }

                            if (line_num_valid and file_ok) {
                                // The multi-submatch path heap-allocates
                                // match_snippet via allocator.dupe; the
                                // default-line and single-submatch paths
                                // borrow slices from the JSON arena. Track
                                // ownership with a local that we free on
                                // EVERY exit (success, error, continue).
                                defer if (match_snippet_owned) allocator.free(match_snippet);

                                // Sanitize the snippet to ensure valid
                                // UTF-8. rg emits snippets in the file's
                                // encoding; binary files can contain
                                // invalid UTF-8 bytes which break the
                                // XML output (zig's std.json.fmt emits
                                // them as JSON arrays of integers instead
                                // of strings — see project memory
                                // zig-0.16-std-json-fmt-emits-invalid-utf8-as-array).
                                // sanitizeUtf8 ALWAYS returns a fresh
                                // heap allocation (it's a toOwnedSlice),
                                // so we always own the result.
                                const sanitized_snippet = sanitize.sanitizeUtf8(allocator, match_snippet) catch continue;
                                errdefer allocator.free(sanitized_snippet);

                                const owned_file = try allocator.dupe(u8, match_file);
                                errdefer allocator.free(owned_file);

                                const match = SearchMatch{
                                    .file = owned_file,
                                    .line_number = line_num,
                                    .file_total_lines = 0,
                                    .snippet = sanitized_snippet,
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
            // ripgrep surfaced an error (regex parse error, permission
            // denied, etc). Surface stderr verbatim — it already names the
            // root cause. Don't append pattern/path because the stderr is
            // the source of truth.
            try output.appendSlice(allocator, "<warning>");
            try output.appendSlice(allocator, result.stderr);
            try output.appendSlice(allocator, "</warning>");
        } else {
            // Clean no-match (rg exit code 1, empty stderr). Include the
            // pattern + path the LLM passed so the operator can see exactly
            // what was searched — without this the frontend falls back to
            // "unknown pattern not found" and the operator can't tell
            // whether the LLM typed a typo or just got unlucky. See
            // docs/superpowers/plans/2026-08-06-search-better-error.md.
            try output.appendSlice(allocator, "<warning>no matches for pattern \"");
            try output.appendSlice(allocator, input.pattern);
            try output.appendSlice(allocator, "\" in path \"");
            try output.appendSlice(allocator, input.path);
            try output.appendSlice(allocator, "\"</warning>");
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
        // No matches — include the warning body (which now carries the
        // pattern + path the LLM passed) inside the <search> tag. The
        // frontend's parser relies on pattern="..." path="..." being
        // present so it can render the actual args in the toast header;
        // if we close the tag here without the body, the operator sees
        // "unknown" / "unknown" in the chatview (the bug this commit
        // fixes). See docs/superpowers/plans/2026-08-06-search-better-error.md.
        try output.appendSlice(allocator, result.content);
        try output.appendSlice(allocator, "\n");
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

/// Flat (non-grouped) output: one match per <m> element inside <search>.
/// Same XML shape as the per-match entries in the grouped output, so the
/// LLM frontend can iterate over <m> elements uniformly. Used when
/// SearchInput.group_by_file == false (the LLM doesn't care about which
/// file a match came from, e.g. when searching a single known file).
pub fn search_result_to_string_flat(allocator: std.mem.Allocator, result: SearchResult, pattern: []const u8, search_path: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, "<search pattern=\"");
    try output.appendSlice(allocator, pattern);
    try output.appendSlice(allocator, "\" path=\"");
    try output.appendSlice(allocator, search_path);
    try output.appendSlice(allocator, "\" group_by_file=\"false\">\n");

    if (result.matches.items.len == 0) {
        // No matches — include the warning body inside the <search> tag
        // (see search_result_to_string_grouped comment for rationale).
        try output.appendSlice(allocator, result.content);
        try output.appendSlice(allocator, "\n");
        try output.appendSlice(allocator, "</search>\n");
        return try output.toOwnedSlice(allocator);
    }

    for (result.matches.items) |m| {
        const trimmed_snippet = std.mem.trim(u8, m.snippet, &std.ascii.whitespace);
        const trimmed_path = std.mem.trim(u8, m.file, &std.ascii.whitespace);
        const match_xml = try std.fmt.allocPrint(allocator,
            \\  <m><f>{s}</f><l>{d}</l><s>{s}</s></m>
        , .{
            trimmed_path,
            m.line_number,
            trimmed_snippet,
        });
        try output.appendSlice(allocator, match_xml);
        try output.appendSlice(allocator, "\n");
        allocator.free(match_xml);
    }

    try output.appendSlice(allocator, "</search>\n");

    return try output.toOwnedSlice(allocator);
}

pub const search_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search",
        .description =
        \\PRIMARY search tool for code navigation. Use THIS tool — not `bash rg`,
        \\`bash grep`, `bash grep -r`, or `bash find` — to search the codebase.
        \\
        \\WHY THIS TOOL OVER `bash rg ...`
        \\- Structured XML output with line numbers and file paths — no shell
        \\  parsing or `rg --line-number --no-heading` flag-juggling required.
        \\- Automatically respects .gitignore / .ignore / .rgignore (skips
        \\  build/, node_modules/, .git/, target/, vendor/).
        \\- Pattern is passed via argv, not a shell — no injection risk from
        \\  regex-looking patterns, no need to escape quotes or backticks.
        \\- Capped output (max_results + max_output) prevents runaway results
        \\  from filling the context window.
        \\- Identical behavior across platforms — no per-OS rg-flag differences.
        \\
        \\Fall back to `bash rg` ONLY when you need an rg flag this tool does
        \\not expose (rare — word_boundary / literal / only_matching cover the
        \\common cases below).
        \\
        \\WHEN TO USE
        \\- "Where is X defined?" — symbol, function, type, constant lookup.
        \\- "Which files use / call Y?" — finding references across the project.
        \\- "Does this pattern or feature already exist in the codebase?" before
        \\  writing new code (check first to avoid duplication).
        \\- "Which file produced this error / log line?"
        \\- Understanding any non-trivial code path or control flow.
        \\
        \\WHEN NOT TO USE
        \\- You already know the exact file path → use read_file.
        \\- You want to find files BY NAME (not by content) → use glob.
        \\- You need a real ripgrep flag this tool does not expose → `bash rg`
        \\  fallback, but first check whether the flag has a parameter here.
        \\
        \\RESPONSE FORMAT
        \\Results are wrapped in a <search> tag with pattern/path attributes.
        \\By default matches are grouped per file (<file> wrapper):
        \\
        \\<search pattern="regex" path="path">
        \\  <file path="path/to/file.zig" total="100" count="3">
        \\    <m><l>10</l><s>snippet at line 10</s></m>
        \\    <m><l>25</l><s>snippet at line 25</s></m>
        \\  </file>
        \\</search>
        \\
        \\Field meanings: `total` = the file's total line count. `count` =
        \\number of matches in this file. `l` = match line number (1-indexed).
        \\`s` = snippet (~100 chars of context around the match).
        \\
        \\No matches returns: <search pattern="..." path="..."></search>
        \\(empty body).
        \\
        \\Set `group_by_file: false` for a flat list (one <m> per match, no
        \\<file> wrapper):
        \\<search pattern="..." path="..." group_by_file="false">
        \\  <m><f>path/to/file.zig</f><l>10</l><s>snippet</s></m>
        \\</search>
        \\
        \\MATCHING MODES (all default false; can be combined freely)
        \\- word_boundary: whole-word match. "foo" matches "foo bar" but NOT
        \\  "foobar". Use for identifier lookups where partial matches would
        \\  be noise.
        \\- literal: treat pattern as a literal string — regex metacharacters
        \\  like '.', '*', '[', '(', '\\' are matched verbatim. Safer for
        \\  code-shaped patterns like "fn(", "*.zig", ".{".
        \\- only_matching: return just the matched substring, not the
        \\  surrounding line. Useful for short tokens in noisy lines
        \\  (extracting IDs, version strings, dates).
        \\
        \\PIPELINE HINT (important for agentic loops)
        \\Run search to identify candidate file:line, then call read_file with
        \\offset/limit to view the surrounding context. Two focused calls are
        \\faster and more accurate than reading whole files blind.
        \\
        \\EDGE CASES
        \\- Pattern starting with `-` is treated as a literal (rg's `-e` flag
        \\  is used internally) — searching for the literal text "--help"
        \\  works without escaping.
        \\- Pattern must be non-empty and contain no NUL bytes.
        \\- max_results and max_output must be > 0.
        \\- max_output is hard-capped at 100MB.
        \\- respect_ignore_files (default true): set false to search
        \\  gitignored paths (build/, node_modules/, .git/, target/, vendor/).
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "pattern",
                    .type = "string",
                    .description = "Regex or literal string to search for. Must be non-empty and contain no NUL bytes.",
                },
                .{
                    .name = "path",
                    .type = "string",
                    .description = "File or directory to search in.",
                },
                .{
                    .name = "max_results",
                    .type = "number",
                    .description = "Max matches to return. Default: 50. Must be > 0.",
                },
                .{
                    .name = "head",
                    .type = "number",
                    .description = "Return first N matches from result set. Mutually exclusive with tail.",
                },
                .{
                    .name = "tail",
                    .type = "number",
                    .description = "Return last N matches from result set. Mutually exclusive with head.",
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description = "Max output size in bytes. Default: 1048576 (1MB). Hard cap: 100MB. Must be > 0.",
                },
                .{
                    .name = "group_by_file",
                    .type = "boolean",
                    .description = "Group matches by file. Default: true. Set false for flat output.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Current working directory, default is cwd projects selected",
                },
                .{
                    .name = "respect_ignore_files",
                    .type = "boolean",
                    .description = "Respect .gitignore/.ignore/.rgignore. Default: true. Set false to search gitignored paths (build/, node_modules/, .git/, etc.).",
                },
                .{
                    .name = "word_boundary",
                    .type = "boolean",
                    .description = "Match whole words only (-w flag). Pattern 'foo' matches 'foo bar' but NOT 'foobar'. Default: false.",
                },
                .{
                    .name = "literal",
                    .type = "boolean",
                    .description = "Treat pattern as a literal string (-F flag). Regex metacharacters like '.', '*', '[' are matched verbatim. Default: false.",
                },
                .{
                    .name = "only_matching",
                    .type = "boolean",
                    .description = "Return only the matched substring (-o flag), not the full surrounding line. Useful for short tokens in noisy lines. Default: false.",
                },
            },
            .required = &.{ "pattern", "path" },
        },
    },
};

test {
    // Tests removed - see search_test.zig (registered in
    // src/modules/agent/test_runner.zig) for the 14+ edge case tests
    // that exercise this tool.
}
