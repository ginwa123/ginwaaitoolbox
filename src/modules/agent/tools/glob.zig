const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

// ============================================================================
// Gitignore Types
// ============================================================================

pub const GitignoreEntry = struct {
    negated: bool,
    directory_only: bool,
    anchor_to_root: bool,
    pattern: []const u8,
};

const Gitignore = struct {
    entries: []GitignoreEntry,
    cwd: []const u8,

    fn deinit(self: *Gitignore, allocator: std.mem.Allocator) void {
        for (self.entries) |e| allocator.free(e.pattern);
        allocator.free(self.entries);
        allocator.free(self.cwd);
    }
};

/// Check if pattern starts with ! (gitignore negation)
fn isGitignoreNegation(pattern: []const u8) bool {
    return pattern.len > 0 and pattern[0] == '!';
}

/// Get content after gitignore negation prefix
fn getGitignoreNegationContent(pattern: []const u8) []const u8 {
    std.debug.assert(isGitignoreNegation(pattern));
    return pattern[1..];
}

/// Parse a single .gitignore line into a GitignoreEntry
pub fn parseGitignoreLine(line: []const u8) ?GitignoreEntry {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    var negated = false;
    var pattern = trimmed;

    if (pattern[0] == '!') {
        negated = true;
        pattern = pattern[1..];
    }

    // Strip trailing / (directory-only marker)
    var directory_only = false;
    if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
        directory_only = true;
        pattern = pattern[0 .. pattern.len - 1];
    }

    // Trim again after stripping negation/trailing
    pattern = std.mem.trim(u8, pattern, &std.ascii.whitespace);
    if (pattern.len == 0) return null;

    // Leading / means anchor to root of this .gitignore's directory
    var anchor_to_root = false;
    if (pattern[0] == '/') {
        anchor_to_root = true;
        pattern = pattern[1..];
    }

    return GitignoreEntry{
        .negated = negated,
        .directory_only = directory_only,
        .anchor_to_root = anchor_to_root,
        .pattern = pattern,
    };
}

/// Load and parse a .gitignore file from a directory
fn loadGitignore(allocator: std.mem.Allocator, dir_path: []const u8) !?Gitignore {
    const gitignore_path = std.fs.path.join(allocator, &.{ dir_path, ".gitignore" }) catch return error.OutOfMemory;
    defer allocator.free(gitignore_path);

    var file = std.fs.openFileAbsolute(gitignore_path, .{}) catch return null;
    defer std.fs.File.close(file);

    const content = file.readToEndAllocOptions(allocator, 1024 * 64, null, @alignOf(u32), 0) catch return null;
    defer allocator.free(content);

    var entries = std.ArrayList(GitignoreEntry).empty;
    errdefer entries.deinit(allocator);

    var line_start: usize = 0;
    while (line_start < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const line = content[line_start..line_end];

        if (parseGitignoreLine(line)) |entry| {
            entries.append(allocator, entry) catch continue;
        }

        line_start = line_end + 1;
    }

    if (entries.items.len == 0) return null;

    const cwd = try allocator.dupe(u8, dir_path);
    return Gitignore{
        .entries = try entries.toOwnedSlice(allocator),
        .cwd = cwd,
    };
}

/// Check if a path is ignored by gitignore rules
fn isIgnoredByGitignore(gitignore: *const Gitignore, path: []const u8, is_dir: bool) bool {
    // Get path relative to gitignore cwd
    const rel_path = if (std.mem.startsWith(u8, path, gitignore.cwd)) {
        const rest = path[gitignore.cwd.len..];
        if (rest.len > 0 and rest[0] == '/') rest[1..] else rest;
    } else path;

    for (gitignore.entries) |entry| {
        // Directory-only patterns don't match files
        if (entry.directory_only and !is_dir) continue;

        // Anchor to root: pattern only matches at root level
        const effective_pattern = if (entry.anchor_to_root) entry.pattern else entry.pattern;

        if (matchGitignorePattern(effective_pattern, rel_path, is_dir)) {
            // Negated entries (whitelist) return false (not ignored)
            // Regular entries return true (ignored)
            return !entry.negated;
        }
    }

    return false;
}

/// Match a single gitignore pattern against a relative path
fn matchGitignorePattern(pattern: []const u8, rel_path: []const u8) bool {
    // Get basename for patterns that don't contain /
    const basename = std.fs.path.basename(rel_path);

    // Check both full path and basename
    return gitignoreGlobMatch(pattern, basename, false) or
        gitignoreGlobMatch(pattern, rel_path, false);
}

/// Gitignore glob matching (supports *, **, ?, [abc])
pub fn gitignoreGlobMatch(glob: []const u8, text: []const u8, nocase: bool) bool {
    var gi: usize = 0;
    var ti: usize = 0;

    while (gi < glob.len) {
        const g = glob[gi];

        if (g == '*') {
            gi += 1;
            if (gi >= glob.len) return true;

            if (gi < glob.len and glob[gi] == '*') {
                gi += 1;
                if (gi < glob.len and glob[gi] == '/') gi += 1;

                var t = ti;
                while (t <= text.len) {
                    if (gitignoreGlobMatch(glob[gi..], text[t..], nocase)) return true;
                    t += 1;
                }
                return false;
            }

            while (ti < text.len and text[ti] != '/') {
                if (gitignoreGlobMatch(glob[gi..], text[ti..], nocase)) return true;
                ti += 1;
            }
            if (gitignoreGlobMatch(glob[gi..], text[ti..], nocase)) return true;
            return false;
        }

        if (g == '?') {
            if (ti >= text.len or text[ti] == '/') return false;
            gi += 1;
            ti += 1;
            continue;
        }

        if (g == '[') {
            gi += 1;
            if (ti >= text.len) return false;

            var matched = false;
            var negated = false;
            if (gi < glob.len and (glob[gi] == '!' or glob[gi] == '^')) {
                negated = true;
                gi += 1;
            }

            while (gi < glob.len and glob[gi] != ']') {
                if (gi + 2 < glob.len and glob[gi + 1] == '-') {
                    const start = glob[gi];
                    const end = glob[gi + 2];
                    if (text[ti] >= start and text[ti] <= end) matched = true;
                    gi += 3;
                } else {
                    const pc = glob[gi];
                    const tc = text[ti];
                    const match = if (nocase)
                        std.ascii.toLower(pc) == std.ascii.toLower(tc)
                    else
                        pc == tc;
                    if (match) matched = true;
                    gi += 1;
                }
            }
            if (gi < glob.len) gi += 1;

            if (negated) matched = !matched;
            if (matched) {
                ti += 1;
            } else {
                return false;
            }
            continue;
        }

        if (ti >= text.len) return false;
        const tc = text[ti];
        if (g != '/') {
            _ = if (nocase)
                std.ascii.toLower(g) == std.ascii.toLower(tc)
            else
                g == tc;
            if (g != tc) return false;
        }
        gi += 1;
        ti += 1;
    }

    return ti == text.len;
}

// ============================================================================
// Glob Constants
// ============================================================================

pub const DEFAULT_MAX_RESULTS: usize = 100;
pub const DEFAULT_MAX_OUTPUT_BYTES: usize = 50 * 1024;
pub const MAX_RECOMMENDED_RESULTS: usize = 500;

// ============================================================================
// Glob Types
// ============================================================================

pub const GlobInput = struct {
    pattern: []const u8 = "*",
    path: []const u8 = ".",
    max_results: ?usize = null,
    offset: ?usize = null,
    hidden: bool = false,
    ignore_case: bool = false,
    file_type: ?[]const u8 = null,
    follow: bool = false,
};

pub const GlobMatch = struct {
    path: []const u8,
};

pub const GlobResult = struct {
    matches: std.ArrayList(GlobMatch),
    truncated_count: usize = 0,
    total_found: usize = 0,
    offset_applied: usize = 0,
    truncated_by_size: bool = false,

    pub fn deinit(self: *GlobResult, allocator: std.mem.Allocator) void {
        for (self.matches.items) |m| allocator.free(m.path);
        self.matches.deinit(allocator);
    }
};

// ============================================================================
// Simple Glob Pattern Matching (Iterative)
// ============================================================================

/// Check if pattern is a negation pattern like !(*.zig) or !*.zig
fn isNegationPattern(pattern: []const u8) bool {
    return pattern.len > 2 and pattern[0] == '!' and pattern[1] == '(';
}

/// Extract the inner content of a negation pattern like !(*.zig) -> *.zig
fn getNegationContent(pattern: []const u8) []const u8 {
    std.debug.assert(isNegationPattern(pattern));
    return pattern[2 .. pattern.len - 1]; // Skip !(
}

/// Match glob pattern against text - simple iterative approach
fn globMatch(glob: []const u8, text: []const u8, nocase: bool) bool {
    var gi: usize = 0;
    var ti: usize = 0;

    while (gi < glob.len) {
        const g = glob[gi];

        if (g == '*') {
            gi += 1;
            if (gi >= glob.len) return true; // * at end matches everything

            // Check for **
            if (gi < glob.len and glob[gi] == '*') {
                gi += 1;
                // Skip / after **
                if (gi < glob.len and glob[gi] == '/') gi += 1;
                // Try matching at each position
                var t = ti;
                while (t <= text.len) {
                    if (globMatch(glob[gi..], text[t..], nocase)) return true;
                    t += 1;
                }
                return false;
            }

            // Single * - match until next glob char or /
            while (ti < text.len and text[ti] != '/') {
                if (globMatch(glob[gi..], text[ti..], nocase)) return true;
                ti += 1;
            }
            if (globMatch(glob[gi..], text[ti..], nocase)) return true;
            return false;
        }

        if (g == '?') {
            if (ti >= text.len or text[ti] == '/') return false;
            gi += 1;
            ti += 1;
            continue;
        }

        if (g == '[') {
            gi += 1;
            if (ti >= text.len) return false;

            var matched = false;
            var negated = false;

            if (gi < glob.len and (glob[gi] == '!' or glob[gi] == '^')) {
                negated = true;
                gi += 1;
            }

            while (gi < glob.len and glob[gi] != ']') {
                if (gi + 2 < glob.len and glob[gi + 1] == '-') {
                    const start = glob[gi];
                    const end = glob[gi + 2];
                    if (text[ti] >= start and text[ti] <= end) matched = true;
                    gi += 3;
                } else {
                    const pc = glob[gi];
                    const tc = text[ti];
                    const match = if (nocase)
                        std.ascii.toLower(pc) == std.ascii.toLower(tc)
                    else
                        pc == tc;
                    if (match) matched = true;
                    gi += 1;
                }
            }
            if (gi < glob.len) gi += 1; // Skip ]

            if (negated) matched = !matched;
            if (matched) {
                ti += 1;
            } else {
                return false;
            }
            continue;
        }

        // Literal character
        if (ti >= text.len) return false;
        const tc = text[ti];
        // Path separator handling
        const sep_match = (g == '/' and tc == '/') or (g == '/' and tc == '\\');
        const char_match = if (nocase)
            std.ascii.toLower(g) == std.ascii.toLower(tc)
        else
            g == tc;
        if (!sep_match and !char_match) return false;
        gi += 1;
        ti += 1;
    }

    return ti == text.len;
}

/// Check if a glob pattern segment contains wildcard metacharacters.
/// Used to decide whether the prefix-aware logic in walkDir applies:
/// literal segments can be safely stripped as directory prefixes;
/// wildcard segments (`*`, `?`, `[`, `**`) must be re-applied at every
/// recursion level.
fn isWildcardPattern(pat: []const u8) bool {
    for (pat) |c| {
        switch (c) {
            '*', '?', '[' => return true,
            else => {},
        }
    }
    return false;
}

// ============================================================================
// Brace Expansion
// ============================================================================

fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn expandBraces(pattern: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    // Find outermost brace
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
                    const prefix = if (start > 0) pattern[0..start] else "";
                    const suffix = if (i + 1 < pattern.len) pattern[i + 1..] else "";
                    const inner = pattern[start + 1 .. i];

                    // Check for negation pattern {![pattern]}
                    if (inner.len > 1 and inner[0] == '!') {
                        const negated_content = inner[1..];
var results: std.ArrayListUnmanaged([]const u8) = .empty;
                        errdefer results.deinit(allocator);

                        // Return the negated pattern marker
                        const marker = try std.fmt.allocPrint(allocator, "!({s})", .{negated_content});
                        try results.append(allocator, marker);
                        return try results.toOwnedSlice(allocator);
                    }

                    // Check for numeric range {1..5}
                    if (std.mem.indexOf(u8, inner, "..")) |idx| {
                        const before = inner[0..idx];
                        const after = inner[idx + 2..];
                        if (isNumeric(before) and isNumeric(after)) {
var results: std.ArrayListUnmanaged([]const u8) = .empty;
                            errdefer results.deinit(allocator);

                            const start_num = std.fmt.parseInt(i64, before, 10) catch 0;
                            const end_num = std.fmt.parseInt(i64, after, 10) catch 0;
                            const step: i64 = if (start_num <= end_num) 1 else -1;
                            var num = start_num;

                            while (true) {
                                const num_str = try std.fmt.allocPrint(allocator, "{d}", .{num});
                                const expanded = try std.mem.concat(allocator, u8, &.{ prefix, num_str, suffix });
                                try results.append(allocator, expanded);
                                if (num == end_num) break;
                                num += step;
                            }
                            return try results.toOwnedSlice(allocator);
                        }
                    }

                    // Parse comma-separated
                    var results: std.ArrayListUnmanaged([]const u8) = .empty;
                    errdefer results.deinit(allocator);

                    var seg_start: usize = 0;
                    var j: usize = 0;
                    while (j <= inner.len) {
                        if (j == inner.len or inner[j] == ',') {
                            const seg = inner[seg_start..j];
                            if (seg.len > 0) {
                                const expanded = try std.mem.concat(allocator, u8, &.{ prefix, seg, suffix });
                                try results.append(allocator, expanded);
                            }
                            seg_start = j + 1;
                        }
                        j += 1;
                    }
                    return try results.toOwnedSlice(allocator);
                }
            },
            else => {},
        }
        i += 1;
    }

    const result = try allocator.alloc([]const u8, 1);
    result[0] = try allocator.dupe(u8, pattern);
    return result;
}

// ============================================================================
// Directory Walking
// ============================================================================

/// Gitignore context that tracks rules from all visited directories
pub const GitignoreContext = struct {
    entries: std.ArrayListUnmanaged(GitignoreEntry),
    root_cwd: []const u8,

    pub fn init(root_cwd: []const u8) @This() {
        return .{
            .entries = .empty,
            .root_cwd = root_cwd,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| allocator.free(e.pattern);
        self.entries.deinit(allocator);
    }

    /// Load .gitignore from a directory and add its entries
    pub fn loadGitignoreForDir(self: *@This(), allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) void {
        const gitignore_path = std.fs.path.join(allocator, &.{ dir_path, ".gitignore" }) catch return;
        defer allocator.free(gitignore_path);

        // Open file - use openFileAbsolute only for absolute paths
        const file: std.Io.File = if (std.fs.path.isAbsolute(gitignore_path))
            std.Io.Dir.openFileAbsolute(io, gitignore_path, .{}) catch return
        else
            std.Io.Dir.cwd().openFile(io, gitignore_path, .{}) catch return;
        defer file.close(io);

        const content = std.Io.Dir.cwd().readFileAlloc(io, gitignore_path, allocator, std.Io.Limit.limited(1024 * 64)) catch return;

        var line_start: usize = 0;
        while (line_start < content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
            const line = content[line_start..line_end];

            if (parseGitignoreLine(line)) |entry| {
                var owned_entry = entry;
                owned_entry.pattern = allocator.dupe(u8, entry.pattern) catch continue;
                self.entries.append(allocator, owned_entry) catch continue;
            }

            line_start = line_end + 1;
        }
        allocator.free(content);
    }

    /// Check if a path is ignored
    pub fn isIgnored(self: *const @This(), path: []const u8) bool {
        // Get relative path from root
        var rel_path: []const u8 = path;
        if (std.mem.startsWith(u8, path, self.root_cwd)) {
            var rest = path[self.root_cwd.len..];
            if (rest.len > 0 and rest[0] == '/') {
                rel_path = rest[1..];
            } else {
                rel_path = rest;
            }
        }

        for (self.entries.items) |entry| {
            if (entry.directory_only) continue;

            // Check basename and full path
            const basename = std.fs.path.basename(rel_path);
            if (gitignoreGlobMatch(entry.pattern, basename, false) or
                gitignoreGlobMatch(entry.pattern, rel_path, false)) {
                return !entry.negated;
            }
        }

        return false;
    }
};

fn walkDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    patterns: []const []const u8,
    opts: GlobOptions,
    results: *std.ArrayListUnmanaged([]const u8),
    depth: usize,
    gitignore_ctx: ?*GitignoreContext,
) void {
    if (opts.max_depth) |max| if (depth >= max) return;

    var dir: std.Io.Dir = if (std.fs.path.isAbsolute(dir_path))
        std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true, .follow_symlinks = opts.follow }) catch return
    else
        std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true, .follow_symlinks = opts.follow }) catch return;

    // Load .gitignore for this directory if we have a gitignore context
    if (gitignore_ctx) |ctx| {
        ctx.loadGitignoreForDir(allocator, io, dir_path);
    }

    // Separate regular patterns from negation patterns
    var negation_patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    var regular_patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    defer negation_patterns.deinit(allocator);
    defer regular_patterns.deinit(allocator);

    for (patterns) |pat| {
        if (isNegationPattern(pat)) {
            negation_patterns.append(allocator, pat) catch continue;
        } else {
            regular_patterns.append(allocator, pat) catch continue;
        }
    }

    var iter = dir.iterate();
    while (true) {
        const entry = iter.next(io) catch break orelse break;
        const name = entry.name;
        if (!opts.dot and name.len > 0 and name[0] == '.') continue;

        const full_path = std.fs.path.join(allocator, &.{ dir_path, name }) catch continue;

        // Check gitignore first
        const is_dir = entry.kind == .directory;
        if (gitignore_ctx) |ctx| {
            if (ctx.isIgnored(full_path)) {
                allocator.free(full_path);
                continue;
            }
        }

        // Check pattern match against name and full path
        var matches = false;
        var negated_match = false;
        for (regular_patterns.items) |pat| {
            if (globMatch(pat, name, opts.nocase) or globMatch(pat, full_path, opts.nocase)) {
                matches = true;
                break;
            }
        }

        // Check negation patterns - if ANY negation pattern matches, this file is excluded
        if (negation_patterns.items.len > 0) {
            for (negation_patterns.items) |pat| {
                const inner = getNegationContent(pat);
                if (globMatch(inner, name, opts.nocase) or globMatch(inner, full_path, opts.nocase)) {
                    negated_match = true;
                    break;
                }
            }

            // If no regular patterns, negation means exclude files that match the pattern
            // If has regular patterns, negation means exclude only if regular pattern also matches
            if (regular_patterns.items.len > 0) {
                // Regular patterns exist - negation only excludes if also matched by regular pattern
                matches = matches and !negated_match;
            } else {
                // No regular patterns - negate means find all that DON'T match
                matches = !negated_match;
            }
        }

        if (matches) {
            const include = (!opts.nodir or !is_dir) and (!opts.onlydir or is_dir);
            if (include) {
                results.append(allocator, allocator.dupe(u8, full_path) catch continue) catch continue;
            }
        }

        if (is_dir) {
            // Build the list of patterns that the "normal recursive descent"
            // will pass down. A pattern is "consumed" when the prefix-aware
            // logic below successfully strips its leading directory segment
            // (e.g. "src/**" → "**" for the "src" child) — re-applying the
            // consumed pattern at the next level would re-match the same
            // files, producing 2^N duplicate results. Unconsumed patterns
            // (those whose first segment is a wildcard, or those that did
            // not match this child's name) are passed down unchanged.
            var unconsumed: std.ArrayListUnmanaged([]const u8) = .empty;
            defer unconsumed.deinit(allocator);

            for (regular_patterns.items) |pat| {
                var consumed = false;
                var pat_idx: usize = 0;

                // Skip the prefix-aware logic entirely for wildcard first
                // segments. The prefix-aware logic recurses with a
                // prefix-stripped pattern; for `**`, `*`, `?`, or `[...]`
                // first segments, the stripped pattern has the wrong
                // semantics (it stops being recursive). Mark the pattern
                // unconsumed and let the fallback recursion handle it.
                // NOTE: we cannot `continue` here because the trailing
                // `if (!consumed)` block would also be skipped — we must
                // append to unconsumed explicitly before continuing.
                {
                    const first_slash = std.mem.indexOfScalar(u8, pat, '/') orelse pat.len;
                    const first_seg = pat[0..first_slash];
                    if (isWildcardPattern(first_seg)) {
                        unconsumed.append(allocator, pat) catch continue;
                        continue;
                    }
                }

                while (pat_idx < pat.len) {
                    const remaining_pat = pat[pat_idx..];
                    const slash_idx = std.mem.indexOfScalar(u8, remaining_pat, '/') orelse remaining_pat.len;
                    const dir_part = remaining_pat[0..slash_idx];

                    if (globMatch(dir_part, name, opts.nocase)) {
                        // Matched a literal prefix segment — recurse with the
                        // prefix-stripped pattern and mark this pattern as
                        // consumed (do NOT also re-apply the full pattern
                        // via the fallback recursion below).
                        const next_idx = pat_idx + slash_idx + 1;
                        if (next_idx < pat.len) {
                            const remaining_pattern = pat[next_idx..];

                            if (remaining_pattern.len >= 2 and
                                remaining_pattern[0] == '*' and
                                remaining_pattern[1] == '*')
                            {
                                // Recursive "**" suffix — recurse with the
                                // inner pattern.
                                var inner_start: usize = 2;
                                if (inner_start < remaining_pattern.len and
                                    remaining_pattern[inner_start] == '/')
                                {
                                    inner_start += 1;
                                }
                                const inner_pattern =
                                    if (inner_start < remaining_pattern.len)
                                        remaining_pattern[inner_start..]
                                    else
                                        "*";

                                var new_patterns: std.ArrayListUnmanaged([]const u8) = .empty;
                                new_patterns.append(allocator, inner_pattern) catch break;
                                walkDir(allocator, io, full_path, new_patterns.items,
                                    opts, results, depth + 1, gitignore_ctx);
                                new_patterns.deinit(allocator);
                            } else {
                                // Non-recursive suffix — recurse with it.
                                var new_patterns: std.ArrayListUnmanaged([]const u8) = .empty;
                                new_patterns.append(allocator, remaining_pattern) catch break;
                                walkDir(allocator, io, full_path, new_patterns.items,
                                    opts, results, depth + 1, gitignore_ctx);
                                new_patterns.deinit(allocator);
                            }
                        } else {
                            // Pattern ends with the matched directory name —
                            // this directory itself matches; recurse to
                            // check children.
                            if (pat[pat_idx + slash_idx - 1] != '*') {
                                walkDir(allocator, io, full_path, patterns,
                                    opts, results, depth + 1, gitignore_ctx);
                            }
                        }
                        consumed = true;
                        break;
                    } else {
                        pat_idx += slash_idx + 1;
                        if (pat_idx > pat.len) break;
                    }
                }

                if (!consumed) {
                    unconsumed.append(allocator, pat) catch continue;
                }
            }

            // Always include negation patterns in the fallback recursion —
            // they have no leading directory prefix and must be re-applied
            // at every level.
            for (negation_patterns.items) |pat| {
                unconsumed.append(allocator, pat) catch continue;
            }

            // Fallback recursion with the unconsumed patterns only.
            // This is the single recursion path that PASSES PATTERNS DOWN.
            // The prefix-aware recursions above recurse with the
            // prefix-stripped pattern; the fallback recurses with the
            // patterns that the prefix-aware did NOT consume.
            if (unconsumed.items.len > 0) {
                walkDir(allocator, io, full_path, unconsumed.items,
                    opts, results, depth + 1, gitignore_ctx);
            }
        }
        allocator.free(full_path);
    }
    std.Io.Dir.close(dir, io);
}

// ============================================================================
// Glob Options
// ============================================================================

pub const GlobOptions = struct {
    dot: bool = true,
    nocase: bool = false,
    nodir: bool = false,
    follow: bool = false,
    onlydir: bool = false,
    max_depth: ?usize = null,
};

// ============================================================================
// Main Glob Execution
// ============================================================================

pub fn executeGlob(allocator: std.mem.Allocator, io: std.Io, input: GlobInput) !GlobResult {
    // Expand brace patterns
    const expanded = try expandBraces(input.pattern, allocator);
    defer {
        for (expanded) |e| allocator.free(e);
        allocator.free(expanded);
    }

    // Build options
    const opts = GlobOptions{
        .dot = input.hidden,
        .nocase = input.ignore_case,
        .follow = input.follow,
        .nodir = if (input.file_type) |ft| std.mem.eql(u8, ft, "f") or std.mem.eql(u8, ft, "file") else false,
        .onlydir = if (input.file_type) |ft| std.mem.eql(u8, ft, "d") or std.mem.eql(u8, ft, "directory") else false,
    };

    // Walk directory
    var results: std.ArrayListUnmanaged([]const u8) = .empty;
    // Free the ArrayList's backing on both error and success. The
    // individual `r` strings (allocator.dupe'd by walkDir) are SHARED
    // with `matches[i].path` below, so result.deinit(allocator) owns
    // freeing them. We must NOT call `allocator.free(r)` on success
    // — that would double-free. On error the `errdefer` does free
    // the items because they never made it into `matches`.
    errdefer {
        for (results.items) |r| allocator.free(r);
        results.deinit(allocator);
    }
    defer {
        // Success path: free the ArrayList's backing slice, but the
        // items (r) are owned by the returned GlobResult's matches.
        results.deinit(allocator);
    }

    // Create gitignore context for the root search path
    var gitignore_ctx = GitignoreContext.init(input.path);
    defer gitignore_ctx.deinit(allocator);

    walkDir(allocator, io, input.path, expanded, opts, &results, 0, &gitignore_ctx);

    // Apply offset and limit
    const total = results.items.len;
    const offset = input.offset orelse 0;
    // Treat max_results=0 as "no limit" (same as null)
    const max_res = @min(input.max_results orelse DEFAULT_MAX_RESULTS, MAX_RECOMMENDED_RESULTS);
    // Ensure max_res is at least 1 if we have results to return
    const effective_max = if (max_res == 0) DEFAULT_MAX_RESULTS else max_res;
    const start = @min(offset, total);
    const end = @min(start + effective_max, total);

    var matches = std.ArrayList(GlobMatch).empty;
    errdefer {
        for (matches.items) |m| allocator.free(m.path);
        matches.deinit(allocator);
    }

    for (results.items[start..end]) |r| {
        try matches.append(allocator, .{ .path = r });
    }

    const truncated = if (total > end) total - end else 0;

    return GlobResult{
        .matches = matches,
        .truncated_count = truncated,
        .total_found = total,
        .offset_applied = offset,
    };
}

// ============================================================================
// Output Formatting
// ============================================================================

pub fn toXmlSuccess(allocator: std.mem.Allocator, result: GlobResult, pattern: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var byte_count: usize = 0;
    var returned: usize = 0;

    for (result.matches.items) |m| {
        const xml = try std.fmt.allocPrint(allocator, "<f>{s}</f>\n", .{m.path});
        if (byte_count + xml.len > DEFAULT_MAX_OUTPUT_BYTES and returned > 0) {
            allocator.free(xml);
            break;
        }
        try output.appendSlice(allocator, xml);
        allocator.free(xml);
        byte_count += xml.len;
        returned += 1;
    }

    if (output.items.len == 0) {
        return try std.fmt.allocPrint(allocator, "<warning>No files found matching the glob pattern.</warning>", .{});
    }

    const total_truncated = result.truncated_count + (result.matches.items.len - returned);
    const summary = try std.fmt.allocPrint(allocator,
        "<glob_summary pattern=\"{s}\" total=\"{d}\" returned=\"{d}\" offset=\"{d}\" truncated=\"{d}\">\n",
        .{ pattern, result.total_found, returned, result.offset_applied, total_truncated }
    );
    errdefer allocator.free(summary);

    var final_out = std.ArrayList(u8).empty;
    errdefer final_out.deinit(allocator);

    try final_out.appendSlice(allocator, summary);
    try final_out.appendSlice(allocator, output.items);
    try final_out.appendSlice(allocator, "</glob_summary>\n");

    if (total_truncated > 0) {
        const warn = try std.fmt.allocPrint(allocator,
            "<truncated>{d} files truncated. Use more specific patterns or pagination.</truncated>",
            .{total_truncated}
        );
        errdefer allocator.free(warn);
        try final_out.appendSlice(allocator, warn);
    }

    return try final_out.toOwnedSlice(allocator);
}

// ============================================================================
// Tool Definition
// ============================================================================

pub const glob_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "glob",
        .description =
        \\Find files matching glob patterns (like node-glob).
        \\Automatically respects .gitignore files - ignored files are excluded from results.
        \\Returns: <f>path</f> for each match wrapped in <glob_summary> with stats.
        \\
        \\Gitignore behavior:
        \\  - Respects .gitignore rules from the search path and subdirectories
        \\  - Files matching gitignore patterns are automatically excluded
        \\  - Use hidden=true to include hidden files (still respects gitignore if file is not gitignored)
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
                    .description = "Skip first N results for pagination.",
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

// ============================================================================
// Test Compatibility Aliases (snake_case names for backward compatibility)
// ============================================================================

