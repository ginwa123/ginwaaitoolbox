const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;

/// Batch file diff endpoint — collapses the SidebarDiffPanel N+1 fan-out
/// (one `GET /api/git/file/diff` per changed file) into at most 2 git
/// spawns. The panel's `loadFullList` used `Promise.allSettled` over N
/// files, so 20 dirty files held 20 Io workers for 6-10s each and
/// starved cheap routes like `queue_messages`. This endpoint runs one
/// `git diff -- <unstaged...>` and one `git diff --cached -- <staged...>`
/// then splits per file server-side.
pub const MAX_BATCH_FILES: usize = 200;
pub const MAX_PER_FILE_BYTES: usize = 512 * 1024;

pub const BatchFileItem = struct {
    file: []const u8,
    staged: bool = false,
};

pub const BatchDiffBody = struct {
    path: []const u8,
    files: []BatchFileItem,
};

pub const BatchDiffEntry = struct {
    path: []const u8,
    diff_content: []const u8,
    staged: bool,
};

pub const BatchDiffResponse = struct {
    diffs: []BatchDiffEntry,
};

/// Split a combined `git diff` output into per-file chunks.
/// Returns slices into `combined` — caller keeps `combined` alive.
pub fn splitCombinedDiff(allocator: std.mem.Allocator, combined: []const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    if (combined.len == 0) return map;
    const marker = "diff --git ";
    var starts = std.ArrayList(usize).empty;
    defer starts.deinit(allocator);
    var idx: usize = 0;
    while (std.mem.indexOf(u8, combined[idx..], marker)) |rel| {
        starts.append(allocator, idx + rel) catch break;
        idx += rel + marker.len;
    }
    for (starts.items, 0..) |start, i| {
        const end = if (i + 1 < starts.items.len) starts.items[i + 1] else combined.len;
        const chunk = combined[start..end];
        const path = extractDiffPath(chunk) orelse continue;
        // First chunk wins for a path; duplicates shouldn't happen within
        // one (staged|unstaged) output.
        if (!map.contains(path)) {
            map.put(path, chunk) catch continue;
        }
    }
    return map;
}

/// Extract the repo-relative path from one `diff --git` chunk.
/// Prefers `+++ b/<path>`, falls back to `--- a/<path>`, then the
/// `diff --git a/<x> b/<y>` header's b-side.
fn extractDiffPath(chunk: []const u8) ?[]const u8 {
    // +++ b/<path>
    if (std.mem.indexOf(u8, chunk, "\n+++ b/")) |pos| {
        const s = pos + "\n+++ b/".len;
        const e = std.mem.indexOfScalar(u8, chunk[s..], '\n') orelse (chunk.len - s);
        const p = std.mem.trim(u8, chunk[s .. s + e], " \t\r");
        if (p.len > 0) return p;
    }
    // --- a/<path> (deleted files have /dev/null on the +++ side)
    if (std.mem.indexOf(u8, chunk, "\n--- a/")) |pos| {
        const s = pos + "\n--- a/".len;
        const e = std.mem.indexOfScalar(u8, chunk[s..], '\n') orelse (chunk.len - s);
        const p = std.mem.trim(u8, chunk[s .. s + e], " \t\r");
        if (p.len > 0 and !std.mem.eql(u8, p, "/dev/null")) return p;
    }
    // diff --git a/<x> b/<y>
    if (std.mem.indexOf(u8, chunk, "diff --git ")) |pos| {
        const rest = chunk[pos + "diff --git ".len ..];
        // rest = "a/<x> b/<y>\n..."
        if (std.mem.indexOf(u8, rest, " b/")) |bpos| {
            const s = bpos + " b/".len;
            const e = std.mem.indexOfAny(u8, rest[s..], " \t\n\r") orelse (rest.len - s);
            const p = rest[s .. s + e];
            if (p.len > 0) return p;
        }
    }
    return null;
}

/// Marker appended to a diff that exceeded MAX_PER_FILE_BYTES.
pub const TRUNCATION_SUFFIX = "\n... [truncated]\n";

/// Cap a per-file diff at MAX_PER_FILE_BYTES.
///
/// Every length below is derived from the literal itself. A hand-written
/// slack constant silently drifts out of sync with the suffix whenever the
/// suffix is reworded, and `@memcpy` then panics on its length check —
/// which is an `abort()`, not an error, so it takes the whole process down.
/// The buffer length is also what the caller sees, so it must be the exact
/// written length; anything longer would serialize uninitialized heap bytes
/// to the client.
fn capDiff(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len <= MAX_PER_FILE_BYTES) return try allocator.dupe(u8, s);
    const total = MAX_PER_FILE_BYTES + TRUNCATION_SUFFIX.len;
    const buf = try allocator.alloc(u8, total);
    @memcpy(buf[0..MAX_PER_FILE_BYTES], s[0..MAX_PER_FILE_BYTES]);
    @memcpy(buf[MAX_PER_FILE_BYTES..total], TRUNCATION_SUFFIX);
    return buf;
}

fn buildNewFileDiff(allocator: std.mem.Allocator, file_path: []const u8, content: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var line_count: usize = 0;
    for (content) |c| {
        if (c == '\n') line_count += 1;
    }
    if (content.len > 0 and content[content.len - 1] != '\n') line_count += 1;
    try buf.appendSlice(allocator, "diff --git a/");
    try buf.appendSlice(allocator, file_path);
    try buf.appendSlice(allocator, " b/");
    try buf.appendSlice(allocator, file_path);
    try buf.appendSlice(allocator, "\nnew file mode\n--- /dev/null\n+++ b/");
    try buf.appendSlice(allocator, file_path);
    try buf.appendSlice(allocator, "\n@@ -0,0 +1,");
    const n_str = try std.fmt.allocPrint(allocator, "{}", .{line_count});
    defer allocator.free(n_str);
    try buf.appendSlice(allocator, n_str);
    try buf.appendSlice(allocator, " @@\n");
    var start: usize = 0;
    while (std.mem.indexOfScalar(u8, content[start..], '\n')) |rel| {
        try buf.appendSlice(allocator, "+");
        try buf.appendSlice(allocator, content[start .. start + rel]);
        try buf.append(allocator, '\n');
        start += rel + 1;
    }
    if (start < content.len) {
        try buf.appendSlice(allocator, "+");
        try buf.appendSlice(allocator, content[start..]);
        try buf.append(allocator, '\n');
    }
    return try buf.toOwnedSlice(allocator);
}

fn syntheticFallback(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8, file: []const u8) ![]const u8 {
    const full = try std.fs.path.join(allocator, &.{ repo_path, file });
    defer allocator.free(full);
    // `openFileAbsolute` ASSERTS the path is absolute and ABORTS the whole
    // process (Debug/ReleaseSafe) instead of returning an error, so never hand it
    // a relative path — `repo_path` is validated at the handler boundary, this
    // keeps the helper safe for any future caller.
    if (!std.fs.path.isAbsolute(full)) return try allocator.dupe(u8, "");
    const f = std.Io.Dir.openFileAbsolute(io, full, .{}) catch return try allocator.dupe(u8, "");
    defer f.close(io);
    var read_buf: [8192]u8 = undefined;
    var reader = f.reader(io, &read_buf);
    const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch return try allocator.dupe(u8, "");
    defer allocator.free(content);
    if (content.len == 0) return try allocator.dupe(u8, "");
    return try buildNewFileDiff(allocator, file, content);
}

/// POST /api/git/file/diffs — batch diffs for N files in <=2 spawns.
/// Body: `{ "path": "<repo>", "files": [{ "file": "<rel>", "staged": bool }] }`.
pub fn gitFileDiffsHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    if (req.body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Request body required") });
    }
    const parsed = std.json.parseFromSliceLeaky(BatchDiffBody, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Invalid JSON body") });
    };
    if (parsed.path.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path") });
    }
    // `parsed.path` is the repo root used as the BASE of every
    // `std.fs.path.join` below, and the joined values reach
    // `std.Io.Dir.openFileAbsolute` in `syntheticFallback`. That API asserts
    // `path.isAbsolute(...)`, and a failed assertion ABORTS the whole process
    // (Debug/ReleaseSafe) instead of returning an error — reject it here.
    if (!std.fs.path.isAbsolute(parsed.path)) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "path must be an absolute directory") });
    }
    if (parsed.files.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "No files") });
    }
    if (parsed.files.len > MAX_BATCH_FILES) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Too many files (max 200)") });
    }

    var staged = std.ArrayList([]const u8).empty;
    defer staged.deinit(allocator);
    var unstaged = std.ArrayList([]const u8).empty;
    defer unstaged.deinit(allocator);
    for (parsed.files) |f| {
        if (f.file.len == 0) continue;
        if (f.staged) {
            staged.append(allocator, f.file) catch continue;
        } else {
            unstaged.append(allocator, f.file) catch continue;
        }
    }

    var staged_out: []u8 = &.{};
    var unstaged_out: []u8 = &.{};
    // Run at most 2 git processes instead of N.
    if (staged.items.len > 0) {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        argv.appendSlice(allocator, &.{ "git", "-C", parsed.path, "diff", "--cached", "--" }) catch {};
        argv.appendSlice(allocator, staged.items) catch {};
        if (std.process.run(allocator, io, .{ .argv = argv.items })) |result| {
            defer allocator.free(result.stderr);
            if (result.term.exited == 0 or result.term.exited == 1) {
                staged_out = result.stdout;
            } else {
                allocator.free(result.stdout);
            }
        } else |_| {}
    }
    if (unstaged.items.len > 0) {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        argv.appendSlice(allocator, &.{ "git", "-C", parsed.path, "diff", "--" }) catch {};
        argv.appendSlice(allocator, unstaged.items) catch {};
        if (std.process.run(allocator, io, .{ .argv = argv.items })) |result| {
            defer allocator.free(result.stderr);
            if (result.term.exited == 0 or result.term.exited == 1) {
                unstaged_out = result.stdout;
            } else {
                allocator.free(result.stdout);
            }
        } else |_| {}
    }
    defer {
        if (staged_out.len > 0) allocator.free(staged_out);
        if (unstaged_out.len > 0) allocator.free(unstaged_out);
    }

    var staged_map = try splitCombinedDiff(allocator, staged_out);
    defer staged_map.deinit();
    var unstaged_map = try splitCombinedDiff(allocator, unstaged_out);
    defer unstaged_map.deinit();

    var entries = std.ArrayList(BatchDiffEntry).empty;
    defer entries.deinit(allocator);
    for (parsed.files) |f| {
        if (f.file.len == 0) continue;
        const map = if (f.staged) &staged_map else &unstaged_map;
        var content: []const u8 = map.get(f.file) orelse "";
        var owned: []const u8 = "";
        var need_free = false;
        if (content.len == 0) {
            owned = syntheticFallback(allocator, io, parsed.path, f.file) catch "";
            need_free = owned.len > 0;
            content = owned;
        }
        const capped = capDiff(allocator, content) catch "";
        if (need_free) allocator.free(owned);
        entries.append(allocator, .{ .path = f.file, .diff_content = capped, .staged = f.staged }) catch continue;
    }

    const response = BatchDiffResponse{ .diffs = entries.items };
    const data = try std.json.Stringify.valueAlloc(allocator, response, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

// ─── Tests ──────────────────────────────────────────────────────────────
// Splitter is pure (no IO) so it is unit-testable here.

test "splitCombinedDiff splits two files" {
    const allocator = std.testing.allocator;
    const combined =
        "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n" ++
        "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-x\n+y\n";
    var map = try splitCombinedDiff(allocator, combined);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 2), map.count());
    try std.testing.expect(map.get("a.txt") != null);
    try std.testing.expect(map.get("b.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, map.get("a.txt").?, "+new") != null);
}

test "extractDiffPath prefers b-side" {
    const chunk = "diff --git a/old.txt b/new.txt\n--- a/old.txt\n+++ b/new.txt\n@@ -1 +1 @@\n-x\n+y\n";
    try std.testing.expectEqualStrings("new.txt", extractDiffPath(chunk).?);
}

test "extractDiffPath handles deleted file" {
    const chunk = "diff --git a/gone.txt b/gone.txt\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n";
    try std.testing.expectEqualStrings("gone.txt", extractDiffPath(chunk).?);
}

test "splitCombinedDiff empty input" {
    const allocator = std.testing.allocator;
    var map = try splitCombinedDiff(allocator, "");
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "capDiff passes through content at or below the cap" {
    const allocator = std.testing.allocator;
    const exact = try allocator.alloc(u8, MAX_PER_FILE_BYTES);
    defer allocator.free(exact);
    @memset(exact, 'x');

    // Exactly at the cap — boundary, must NOT truncate.
    const at = try capDiff(allocator, exact);
    defer allocator.free(at);
    try std.testing.expectEqual(MAX_PER_FILE_BYTES, at.len);
    try std.testing.expectEqualSlices(u8, exact, at);

    // One below the cap.
    const under = try capDiff(allocator, exact[0 .. MAX_PER_FILE_BYTES - 1]);
    defer allocator.free(under);
    try std.testing.expectEqual(MAX_PER_FILE_BYTES - 1, under.len);
    try std.testing.expectEqualSlices(u8, exact[0 .. MAX_PER_FILE_BYTES - 1], under);
}

test "capDiff truncates one byte over the cap" {
    const allocator = std.testing.allocator;
    const over = try allocator.alloc(u8, MAX_PER_FILE_BYTES + 1);
    defer allocator.free(over);
    @memset(over, 'a');

    // This is the call that used to abort the process: it panicked with
    // "source and destination arguments have non-equal lengths" because the
    // destination slice was 24 bytes and the suffix literal was 17.
    const capped = try capDiff(allocator, over);
    defer allocator.free(capped);

    // Exactly the bytes written. A longer slice would ship uninitialized
    // heap memory to the client through the JSON response.
    try std.testing.expectEqual(MAX_PER_FILE_BYTES + TRUNCATION_SUFFIX.len, capped.len);
    try std.testing.expectEqualSlices(u8, over[0..MAX_PER_FILE_BYTES], capped[0..MAX_PER_FILE_BYTES]);
    try std.testing.expectEqualStrings(TRUNCATION_SUFFIX, capped[MAX_PER_FILE_BYTES..]);
}

test "capDiff output length is independent of how far over the cap the input is" {
    const allocator = std.testing.allocator;
    for ([_]usize{ MAX_PER_FILE_BYTES + 1, MAX_PER_FILE_BYTES + 2, MAX_PER_FILE_BYTES * 4 }) |len| {
        const over = try allocator.alloc(u8, len);
        defer allocator.free(over);
        @memset(over, 'q');

        const capped = try capDiff(allocator, over);
        defer allocator.free(capped);
        try std.testing.expectEqual(MAX_PER_FILE_BYTES + TRUNCATION_SUFFIX.len, capped.len);
        try std.testing.expectEqualStrings(TRUNCATION_SUFFIX, capped[MAX_PER_FILE_BYTES..]);
    }
}

test "capDiff allocates its buffer length from the suffix literal" {
    // Static contract: the truncation branch must never carry a hand-written
    // slack constant next to the suffix literal. Such a constant silently
    // drifts when the literal is edited, and @memcpy's length check turns
    // that drift into a process-wide abort.
    const src = @embedFile("git_file_diffs.zig");
    // Both needles are assembled from fragments on purpose. A literal here
    // would live inside `src` and satisfy its own search, making the check
    // vacuous — the first draft of this test did exactly that and passed
    // against the very bug it was meant to catch.
    const slack = "MAX_PER_FILE_BYTES + " ++ "24";
    const derived = "MAX_PER_FILE_BYTES + " ++ "TRUNCATION_SUFFIX.len";
    try std.testing.expect(!std.mem.containsAtLeast(u8, src, 1, slack));
    try std.testing.expect(std.mem.containsAtLeast(u8, src, 1, derived));
}
