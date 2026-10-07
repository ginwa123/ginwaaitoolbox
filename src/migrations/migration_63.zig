const std = @import("std");
const common = @import("common.zig");

const SqliteBackend = common.SqliteBackend;
const addColumnIfMissing = common.addColumnIfMissing;
const dropColumnIfExists = common.dropColumnIfExists;
const renameColumnIfExists = common.renameColumnIfExists;
const helpers = @import("helpers");

/// Migration 063 — per-session opt-in for unattended long-running mode.
///
/// ## Why this migration exists
///
/// Today, when `workflow.zig`'s LLM call fails 10 times in a row, the
/// workflow returns `error.TooManyRetries` (see workflow.zig:425-465)
/// and the session goes idle. For overnight / unattended sessions where
/// the user wants the workflow to keep retrying through transient
/// upstream errors (network blips, rate limits, timeouts), this bail
/// is the wrong default — the user expects the session to keep running
/// until the LLM finally returns, or until the user manually stops it.
///
/// This migration adds two columns to `sessions`:
///   - `is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0` — the opt-in
///     flag. 0 = today's behavior (10-attempt bail). 1 = unattended mode
///     (no bail; keep retrying forever, respecting `config.retry_delay_ms`).
///   - `last_finish_reason TEXT` — the most recent `finish_reason` the
///     workflow observed for the session. Nullable so application code can
///     distinguish "never had a successful turn" from "had a turn that
///     returned 'stop'".
///
/// ## What this does
///
/// Both columns go through `addColumnIfMissing` so:
///   - Fresh-DB installs that already declare the columns in their
///     canonical CREATE TABLE for `sessions` short-circuit cleanly
///     (no `duplicate column name` error).
///   - Upgrade-from-v1 installs get the ALTER applied.
///
/// Plan: docs/superpowers/plans/2026-07-16-session-auto-retry-until-stop.md
///   (Chunk 1, Task 1.1)
pub const Migration063AddSessionAutoRetry = struct {
    pub const version: u32 = 63;
    pub const name = "add_session_auto_retry_until_stop";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Boolean opt-in flag, default off. INTEGER NOT NULL DEFAULT 0
        // matches the convention used by Migration 062 for booleans
        // and avoids NULL handling at the API edge (NULL → COALESCE
        // default would still work, but NOT NULL is more honest).
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "is_auto_retry_until_stop",
            "is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0",
        );
        // Cache column — nullable; stays NULL until workflow.zig writes
        // the first value (see workflow.zig's new
        // `updateSessionLastFinishReason` call site, Chunk 2 Task 2.1).
        try addColumnIfMissing(
            .{ .db = db },
            allocator,
            "sessions",
            "last_finish_reason",
            "last_finish_reason TEXT",
        );
    }
};
