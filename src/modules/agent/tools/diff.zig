const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Types ─────────────────────────────────────────────────────────────────────

pub const Kind = enum { eq, insert, delete };

pub const Chunk = struct {
    kind: Kind,
    text: []const u8, // slice into the original before/after strings
};

pub const DiffResult = struct {
    chunks: []Chunk,

    pub fn deinit(self: DiffResult, allocator: Allocator) void {
        allocator.free(self.chunks);
    }
};

// ── LCS diff ──────────────────────────────────────────────────────────────────
//
// Works on any granularity: pass raw bytes, or split into lines first.
//
// For large files, prefer line-level diff (split on '\n' then pass slices).
// For small files / short snippets, byte-level works fine.

pub fn diff(allocator: Allocator, before: []const u8, after: []const u8) !DiffResult {
    const n = before.len;
    const m = after.len;

    // Build LCS length table: dp[i][j] = LCS length of before[0..i] vs after[0..j]
    // We use a flat array of (n+1)*(m+1) u32s.
    const dp = try allocator.alloc(u32, (n + 1) * (m + 1));
    defer allocator.free(dp);
    @memset(dp, 0);

    for (1..n + 1) |i| {
        for (1..m + 1) |j| {
            dp[i * (m + 1) + j] = if (before[i - 1] == after[j - 1])
                dp[(i - 1) * (m + 1) + (j - 1)] + 1
            else
                @max(dp[(i - 1) * (m + 1) + j], dp[i * (m + 1) + (j - 1)]);
        }
    }

    // Backtrack to collect chunks
    var chunks = std.ArrayList(Chunk).empty;
    errdefer chunks.deinit(allocator);

    var i: usize = n;
    var j: usize = m;

    // We'll accumulate runs of the same kind into single chunks
    var buf_kind: ?Kind = null;
    var buf_start_b: usize = 0; // start index in `before`
    var buf_start_a: usize = 0; // start index in `after`
    var buf_end_b: usize = 0;
    var buf_end_a: usize = 0;

    // Collect ops in reverse, then reverse the list
    while (i > 0 or j > 0) {
        const kind: Kind = blk: {
            if (i > 0 and j > 0 and before[i - 1] == after[j - 1]) {
                i -= 1; j -= 1;
                break :blk .eq;
            } else if (j > 0 and (i == 0 or dp[i * (m + 1) + (j - 1)] >= dp[(i - 1) * (m + 1) + j])) {
                j -= 1;
                break :blk .insert;
            } else {
                i -= 1;
                break :blk .delete;
            }
        };

        // Extend or flush the current run
        if (buf_kind == kind) {
            // extend backwards
            if (kind == .eq or kind == .delete) buf_start_b = i;
            if (kind == .eq or kind == .insert) buf_start_a = j;
        } else {
            if (buf_kind) |k| {
                try chunks.append(allocator, .{
                    .kind = k,
                    .text = switch (k) {
                        .eq, .delete => before[buf_start_b..buf_end_b],
                        .insert      => after[buf_start_a..buf_end_a],
                    },
                });
            }
            buf_kind = kind;
            buf_start_b = i;
            buf_end_b   = if (kind == .eq or kind == .delete) i + 1 else i;
            buf_start_a = j;
            buf_end_a   = if (kind == .eq or kind == .insert) j + 1 else j;
        }
    }

    // Flush last run
    if (buf_kind) |k| {
        try chunks.append(allocator, .{
            .kind = k,
            .text = switch (k) {
                .eq, .delete => before[buf_start_b..buf_end_b],
                .insert      => after[buf_start_a..buf_end_a],
            },
        });
    }

    // Reverse (we built it backwards)
    const slice = try chunks.toOwnedSlice(allocator);
    std.mem.reverse(Chunk, slice);
    return .{ .chunks = slice };
}

// ── Line-level wrapper ────────────────────────────────────────────────────────
//
// If you want line-level granularity (like git diff), use this instead.
// It diffs the line arrays, which is much faster on large files.

pub const LineDiff = struct {
    chunks: []LineChunk,
    pub fn deinit(self: LineDiff, allocator: Allocator) void {
        allocator.free(self.chunks);
    }
};

pub const LineChunk = struct {
    kind: Kind,
    lines: []const []const u8,
};

pub fn diffLines(
    allocator: Allocator,
    before_lines: []const []const u8,
    after_lines: []const []const u8,
) !LineDiff {
    const n = before_lines.len;
    const m = after_lines.len;

    const dp = try allocator.alloc(u32, (n + 1) * (m + 1));
    defer allocator.free(dp);
    @memset(dp, 0);

    for (1..n + 1) |i| {
        for (1..m + 1) |j| {
            dp[i * (m + 1) + j] = if (std.mem.eql(u8, before_lines[i - 1], after_lines[j - 1]))
                dp[(i - 1) * (m + 1) + (j - 1)] + 1
            else
                @max(dp[(i - 1) * (m + 1) + j], dp[i * (m + 1) + (j - 1)]);
        }
    }

    var ops = std.ArrayList(struct { kind: Kind, bi: usize, ai: usize }).empty;
    defer ops.deinit(allocator);

    var i: usize = n;
    var j: usize = m;
    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, before_lines[i - 1], after_lines[j - 1])) {
            i -= 1; j -= 1;
            try ops.append(allocator, .{ .kind = .eq, .bi = i, .ai = j });
        } else if (j > 0 and (i == 0 or dp[i * (m + 1) + (j - 1)] >= dp[(i - 1) * (m + 1) + j])) {
            j -= 1;
            try ops.append(allocator, .{ .kind = .insert, .bi = i, .ai = j });
        } else {
            i -= 1;
            try ops.append(allocator, .{ .kind = .delete, .bi = i, .ai = j });
        }
    }
    std.mem.reverse(@TypeOf(ops.items[0]), ops.items);

    // Group consecutive same-kind ops into LineChunks
    var chunks = std.ArrayList(LineChunk).empty;
    errdefer chunks.deinit(allocator);

    var idx: usize = 0;
    while (idx < ops.items.len) {
        const kind = ops.items[idx].kind;
        const start = idx;
        while (idx < ops.items.len and ops.items[idx].kind == kind) idx += 1;

        // Collect the line slice for this chunk
        const lines = switch (kind) {
            .eq, .delete => before_lines[ops.items[start].bi..ops.items[idx - 1].bi + 1],
            .insert      => after_lines[ops.items[start].ai..ops.items[idx - 1].ai + 1],
        };
        try chunks.append(allocator, .{ .kind = kind, .lines = lines });
    }

    return .{ .chunks = try chunks.toOwnedSlice(allocator) };
}

// ── Helpers ───────────────────────────────────────────────────────────────────

pub fn splitLines(allocator: Allocator, text: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try list.append(allocator, line);
    if (list.items.len > 0 and list.getLast().len == 0) _ = list.pop();
    return try list.toOwnedSlice(allocator);
}

// ── Formatters ────────────────────────────────────────────────────────────────

/// Format diff as ANSI-colored text (for terminal display)
pub fn formatAnsi(allocator: Allocator, result: DiffResult) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (result.chunks) |c| {
        const prefix: u8 = switch (c.kind) { .eq => ' ', .insert => '+', .delete => '-' };
        const color = switch (c.kind) {
            .eq     => "\x1b[0m",
            .insert => "\x1b[32m",
            .delete => "\x1b[31m",
        };
        try out.appendSlice(allocator, color);
        try out.append(allocator, prefix);
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, c.text);
        try out.appendSlice(allocator, "\x1b[0m");
    }

    return try out.toOwnedSlice(allocator);
}

/// Format line-level diff as ANSI-colored split view (vimdiff style)
/// Left = before, Right = after - lines aligned side by side
pub fn formatLinesAnsi(allocator: Allocator, result: LineDiff) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // ANSI codes
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";

    // Track line numbers for both sides
    var before_line_num: usize = 1;
    var after_line_num: usize = 1;

    for (result.chunks) |c| {
        switch (c.kind) {
            .eq => {
                for (c.lines) |line| {
                    // Format: "    N  │  N    line content"
                    const left_num = std.fmt.allocPrint(allocator, "{d:>4}  ", .{before_line_num}) catch "";
                    defer allocator.free(left_num);
                    const right_num = std.fmt.allocPrint(allocator, "  {d:<4}", .{after_line_num}) catch "";
                    defer allocator.free(right_num);

                    try out.appendSlice(allocator, dim);
                    try out.appendSlice(allocator, left_num);
                    try out.appendSlice(allocator, "│");
                    try out.appendSlice(allocator, right_num);
                    try out.appendSlice(allocator, reset);
                    try out.appendSlice(allocator, " ");
                    try out.appendSlice(allocator, line);
                    try out.append(allocator, '\n');

                    before_line_num += 1;
                    after_line_num += 1;
                }
            },
            .delete => {
                for (c.lines) |line| {
                    const left_num = std.fmt.allocPrint(allocator, "{d:>4}  ", .{before_line_num}) catch "";
                    defer allocator.free(left_num);

                    try out.appendSlice(allocator, red);
                    try out.appendSlice(allocator, left_num);
                    try out.appendSlice(allocator, "│");
                    try out.appendSlice(allocator, dim);
                    try out.appendSlice(allocator, "     ");
                    try out.appendSlice(allocator, reset);
                    try out.appendSlice(allocator, " ");
                    try out.appendSlice(allocator, line);
                    try out.appendSlice(allocator, reset);
                    try out.append(allocator, '\n');

                    before_line_num += 1;
                }
            },
            .insert => {
                for (c.lines) |line| {
                    const right_num = std.fmt.allocPrint(allocator, "  {d:<4}", .{after_line_num}) catch "";
                    defer allocator.free(right_num);

                    try out.appendSlice(allocator, dim);
                    try out.appendSlice(allocator, "    ");
                    try out.appendSlice(allocator, "│");
                    try out.appendSlice(allocator, green);
                    try out.appendSlice(allocator, right_num);
                    try out.appendSlice(allocator, reset);
                    try out.appendSlice(allocator, " ");
                    try out.appendSlice(allocator, line);
                    try out.appendSlice(allocator, reset);
                    try out.append(allocator, '\n');

                    after_line_num += 1;
                }
            },
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// Format diff as plain text (no ANSI colors)
pub fn formatPlain(allocator: Allocator, result: DiffResult) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (result.chunks) |c| {
        const prefix: u8 = switch (c.kind) { .eq => ' ', .insert => '+', .delete => '-' };
        try out.append(allocator, prefix);
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, c.text);
    }

    return try out.toOwnedSlice(allocator);
}

/// Format line-level diff as plain text (no ANSI colors)
pub fn formatLinesPlain(allocator: Allocator, result: LineDiff) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (result.chunks) |c| {
        const prefix: u8 = switch (c.kind) { .eq => ' ', .insert => '+', .delete => '-' };
        for (c.lines) |line| {
            try out.append(allocator, prefix);
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }

    return try out.toOwnedSlice(allocator);
}

