//! Static regression checks for the `HttpClient.zig` FD-leak fix.
//!
//! Why this file exists
//! ────────────────────
//! The `HttpClient.zig` file spawns `bash -c "curl ..."` for HTTP
//! requests. In Zig 0.16, `std.process.Child` has no `deinit(io)`
//! method (and `child.kill(io)` does NOT close the pipe FDs — see
//! `/usr/local/lib/zig/std/Io/Threaded.zig:15320` `childKillPosix`,
//! which only sends SIGTERM and `waitpid`s, never closes the pipes).
//! Without explicit cleanup, any error path between spawn and
//! `child.wait(self.io)` — e.g. an OOM in `toOwnedSlice` — drops
//! `child` on the floor and leaks 2 FDs (stdout + stderr pipes).
//!
//! Empirically (before the fix): 50 errored spawns -> 112 FDs in
//! `/proc/<pid>/fd` vs a ~14-FD infrastructure baseline.
//!
//! The fix: a `defer` block immediately after each `std.process.spawn`
//! that closes `child.stdout` / `child.stderr` if they're non-null.
//! On the success path, `child.wait()` already nulls those fields via
//! `childCleanupPosix`, so the defer is a no-op; on error paths,
//! the defer is what actually closes the FDs.
//!
//! Plan: docs/superpowers/plans/2026-07-14-fd-quota-leak.md (HttpClient chunk)
//!       (plan not yet committed to this worktree — see PR #52 SSE FD-leak
//!        fix from 2026-06-30 for the parallel sse_manager.zig fix that
//!        inspired this one)
//!
//! The checks here verify the structural invariants:
//!   1. Both spawn sites (in `getWithCurl` and `postWithCurl`) are
//!      immediately followed by a `defer` block that closes the pipes.
//!   2. The defer uses `child.stdout`/`child.stderr` (not local
//!      copies) — i.e. it reads the post-spawn state of the Child.
//!   3. The fix comment ("FIX 2026-07-14") appears at both sites so
//!      a future grep can find both in one shot.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HTTP_CLIENT_PATH = "src/modules/http/HttpClient.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

/// Locate the byte offset of the n-th (0-indexed) occurrence of `needle` in `hay`.
/// Returns null if there are fewer than n+1 occurrences.
fn indexOfNth(hay: []const u8, needle: []const u8, n: usize) ?usize {
    var idx: usize = 0;
    var current: usize = 0;
    while (idx <= n) : (idx += 1) {
        const next = std.mem.indexOf(u8, hay[current..], needle) orelse return null;
        current += next;
        if (idx == n) return current;
        current += needle.len;
    }
    return null;
}

/// Anchor for locating each `std.process.spawn(...)` call's closing `});` line.
/// The needle includes the trailing `\n` + 8 spaces + `});` so the
/// returned offset points at the START of `.stderr = .pipe,` and we
/// can skip past the entire anchor via `offset + SPAWN_ANCHOR.len`
/// to avoid matching it again when searching for the next `});`.
const SPAWN_ANCHOR = ".stderr = .pipe,\n        });";

/// Find the offset of the n-th spawn close. Returns null if there are
/// fewer than n+1 occurrences.
fn spawnCloseOffset(hay: []const u8, n: usize) ?usize {
    return indexOfNth(hay, SPAWN_ANCHOR, n);
}

/// Return the slice of `hay` starting from `from` to the next
/// `});` line that's NOT the one at `from` itself, or to the end of
/// the buffer. The defer block at each spawn site ends well before
/// the next `});` so this gives a generous, position-stable window.
///
/// The caller passes the offset of the START of the spawn close
/// needle (`.stderr = .pipe,\n        });`). We start the search at
/// `from + needle.len` so we don't accidentally match the spawn close
/// itself (the trailing `\n        });` at the end of `from..from+needle.len`
/// would otherwise match the search starting at `from`).
fn sliceUntilNextClose(hay: []const u8, from: usize, needle_len: usize) []const u8 {
    const close_marker = "\n        });";
    const start = from + needle_len; // skip past the spawn close itself
    if (start >= hay.len) return hay[from..];
    const next = std.mem.indexOf(u8, hay[start..], close_marker) orelse return hay[from..];
    return hay[from .. start + next + close_marker.len];
}

test "HttpClient.zig: getWithCurl spawn has a pipe-close defer after it" {
    const source = try readSource(testing.allocator, HTTP_CLIENT_PATH);
    defer testing.allocator.free(source);

    // First spawn (getWithCurl, line ~71)
    const close_offset = spawnCloseOffset(source, 0) orelse {
        std.debug.print("!! HttpClient.zig: cannot find first spawn close (`.stderr = .pipe,\\n        }});`) !!\n", .{});
        return error.SpawnCloseNotFound;
    };

    const window = sliceUntilNextClose(source, close_offset, SPAWN_ANCHOR.len);

    // The defer must close BOTH pipes (not just one).
    if (std.mem.indexOf(u8, window, "if (child.stdout) |out|") == null) {
        std.debug.print("!! HttpClient.zig getWithCurl: missing `if (child.stdout) |out|` in the post-spawn defer !!\n", .{});
        return error.PipeCloseDeferMissing;
    }
    if (std.mem.indexOf(u8, window, "if (child.stderr) |err_pipe|") == null) {
        std.debug.print("!! HttpClient.zig getWithCurl: missing `if (child.stderr) |err_pipe|` in the post-spawn defer !!\n", .{});
        return error.PipeCloseDeferMissing;
    }
    // And it must use child.stdout (not a captured local) so it sees the
    // post-spawn state.
    if (std.mem.indexOf(u8, window, "out.close(self.io)") == null) {
        std.debug.print("!! HttpClient.zig getWithCurl: defer does not call `out.close(self.io)` !!\n", .{});
        return error.PipeCloseCallMissing;
    }
    if (std.mem.indexOf(u8, window, "err_pipe.close(self.io)") == null) {
        std.debug.print("!! HttpClient.zig getWithCurl: defer does not call `err_pipe.close(self.io)` !!\n", .{});
        return error.PipeCloseCallMissing;
    }
}

test "HttpClient.zig: postWithCurl spawn has a pipe-close defer after it" {
    const source = try readSource(testing.allocator, HTTP_CLIENT_PATH);
    defer testing.allocator.free(source);

    // Second spawn (postWithCurl, line ~204)
    const close_offset = spawnCloseOffset(source, 1) orelse {
        std.debug.print("!! HttpClient.zig: cannot find second spawn close (`.stderr = .pipe,\\n        }});`) !!\n", .{});
        return error.SpawnCloseNotFound;
    };

    const window = sliceUntilNextClose(source, close_offset, SPAWN_ANCHOR.len);

    if (std.mem.indexOf(u8, window, "if (child.stdout) |out|") == null) {
        std.debug.print("!! HttpClient.zig postWithCurl: missing `if (child.stdout) |out|` in the post-spawn defer !!\n", .{});
        return error.PipeCloseDeferMissing;
    }
    if (std.mem.indexOf(u8, window, "if (child.stderr) |err_pipe|") == null) {
        std.debug.print("!! HttpClient.zig postWithCurl: missing `if (child.stderr) |err_pipe|` in the post-spawn defer !!\n", .{});
        return error.PipeCloseDeferMissing;
    }
    if (std.mem.indexOf(u8, window, "out.close(self.io)") == null) {
        std.debug.print("!! HttpClient.zig postWithCurl: defer does not call `out.close(self.io)` !!\n", .{});
        return error.PipeCloseCallMissing;
    }
    if (std.mem.indexOf(u8, window, "err_pipe.close(self.io)") == null) {
        std.debug.print("!! HttpClient.zig postWithCurl: defer does not call `err_pipe.close(self.io)` !!\n", .{});
        return error.PipeCloseCallMissing;
    }
}

test "HttpClient.zig: FIX 2026-07-14 comment marker appears at both spawn sites" {
    // Locks in the search anchor: future contributors removing either
    // defer block will break this test, which points them at the right
    // search string to find both sites.
    const source = try readSource(testing.allocator, HTTP_CLIENT_PATH);
    defer testing.allocator.free(source);

    var iter = std.mem.splitSequence(u8, source, "FIX 2026-07-14");
    var count: usize = 0;
    while (iter.next()) |_| count += 1;
    // `splitSequence` produces N+1 segments for N occurrences, so subtract 1.
    const occurrences = count -| 1;

    if (occurrences < 2) {
        std.debug.print("!! HttpClient.zig: expected >= 2 `FIX 2026-07-14` markers (one per spawn site), found {d} !!\n", .{occurrences});
        return error.FixMarkerMissing;
    }
}