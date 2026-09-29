//! Static-contract gate: no Zig test may open or create a file at a literal
//! `/tmp/...` path (run 36496521345, job 109177302271 — `backend (Windows X64)`).
//!
//! Seven of the eight Windows-only failures shared one anti-pattern: tests
//! built paths with `allocPrint(..., "/tmp/x_{d}.md", ...)` and passed them to
//! `std.Io.Dir.createFileAbsolute`. On Windows `/tmp/x` is NOT the POSIX temp
//! dir — it resolves against the cwd's drive as `D:\tmp\x`, and `D:\tmp` does
//! not exist, so `NtCreateFile` returns `STATUS_OBJECT_PATH_NOT_FOUND` and Zig
//! surfaces `error.FileNotFound`. Linux passed, so the bug was invisible until
//! the hosted windows-2022 runner.
//!
//! Scope — what this gate does and does NOT catch:
//!
//!   * Catches: a *file*-creating/opening call whose path literal is `/tmp/...`
//!     on the same line. These need the parent directory to already exist,
//!     which `/tmp/x` does not on Windows.
//!   * Ignores: `createDirPath` / `mkdirP` / `makePath` with a `/tmp` path.
//!     These *create* the parent chain, so they succeed on Windows (they just
//!     litter `D:\tmp`) — `service/daemon_test.zig` and
//!     `modules/agent/tools/memories.zig` use that shape and are green.
//!   * Ignores: `/tmp/...` held in a variable and passed on a later line, and
//!     `/tmp/...` used as a plain string (DB fixtures compared with
//!     `expectEqualStrings`, CLI-arg parsing, JSON payloads). Neither touches
//!     the filesystem in a way that breaks.
//!
//! So this is a guard against the exact regression, not a full `/tmp` audit.
//! The replacement is `std.testing.tmpDir(.{})`, which roots under
//! `.zig-cache/tmp/<random>/` on every platform and is deleted by
//! `tmp.cleanup()`.

const std = @import("std");
const testing = std.testing;

/// File-creating/opening entry points: the path must resolve to a real file,
/// so a missing parent directory is a hard error on Windows. Ordered so the
/// longer names are tried first (`createFileAbsolute` before `createFile`).
const file_ops = [_][]const u8{
    "createFileAbsolute",
    "openFileAbsolute",
    "deleteFileAbsolute",
    "createFile",
};

/// Directories that hold no first-party Zig and are expensive to walk.
const pruned_dirs = [_][]const u8{
    "node_modules",
    ".zig-cache",
    "zig-out",
    ".gradle",
    "dist",
    "build",
    "html",
};

/// Returns the index of a `/tmp` that begins a path (so `.zig-cache/tmp/x`
/// does not count), or null when the line has no such token.
fn pathStartTmpIndex(line: []const u8) ?usize {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, line, at, "/tmp")) |i| {
        // A preceding path character means this is a segment of a longer
        // path (e.g. `.zig-cache/tmp`), not a `/tmp` root.
        if (i == 0 or line[i - 1] == '"' or line[i - 1] == '\'' or line[i - 1] == '(') return i;
        at = i + 1;
    }
    return null;
}

/// Returns true when `line` opens/creates a file at a literal `/tmp` path.
fn isTmpPathFileOp(line: []const u8) bool {
    if (pathStartTmpIndex(line) == null) return false;
    for (file_ops) |op| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, line, at, op)) |i| {
            const after = line[i + op.len ..];
            // Require an actual invocation, not the name mentioned in prose.
            if (after.len > 0 and after[0] == '(') return true;
            at = i + op.len;
        }
    }
    return false;
}

test "static contract: no test opens or creates a file at a literal /tmp path" {
    const root = std.Io.Dir.cwd();
    var src = try root.openDir(testing.io, "src", .{ .iterate = true });
    defer src.close(testing.io);

    var walker = try src.walkSelectively(testing.allocator);
    defer walker.deinit();

    var offenders: std.ArrayList([]const u8) = .empty;
    defer {
        for (offenders.items) |o| testing.allocator.free(o);
        offenders.deinit(testing.allocator);
    }

    // `SelectiveWalker` owns the path buffer and invalidates `entry.path` on
    // the next call, so offender strings are copied out with `allocPrint`.
    // Descent is opt-in via `enter`, which is what keeps this off the
    // multi-hundred-megabyte `.zig-cache` / `node_modules` trees.
    // A directory we cannot iterate ends the walk rather than failing —
    // a partial scan beats a crash.
    while (walker.next(testing.io) catch null) |entry| {
        if (entry.kind == .directory) {
            for (pruned_dirs) |pruned| {
                if (std.mem.eql(u8, entry.basename, pruned)) break;
            } else {
                try walker.enter(testing.io, entry);
                continue;
            }
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const contents = src.readFileAlloc(testing.io, entry.path, testing.allocator, .limited(4 << 20)) catch continue;
        defer testing.allocator.free(contents);

        var line_it = std.mem.splitScalar(u8, contents, '\n');
        while (line_it.next()) |line| {
            if (!isTmpPathFileOp(line)) continue;
            try offenders.append(testing.allocator, try std.fmt.allocPrint(
                testing.allocator,
                "src/{s}: {s}",
                .{ entry.path, std.mem.trim(u8, line, " \t") },
            ));
        }
    }

    if (offenders.items.len == 0) return;
    std.debug.print(
        "\n=== {d} Windows-unsafe /tmp file op(s) — these pass on Linux and FAIL on the windows-2022 runner ===\n",
        .{offenders.items.len},
    );
    for (offenders.items) |o| std.debug.print("  {s}\n", .{o});
    std.debug.print(
        "Fix: use `var tmp = testing.tmpDir(.{{}}); defer tmp.cleanup();` + `tmp.dir.writeFile(io, .{{ .sub_path = ..., .data = ... }})`.\n\n",
        .{},
    );
    return error.PosixTmpPathInFileOp;
}
