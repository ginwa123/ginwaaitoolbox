//! Test runner for the schedulers module.
//!
//! Aggregates all scheduler-level unit tests so they are discovered by
//! the project's top-level `zig build test` target (which imports this
//! file via `src/root.zig`).
//!
//! Follows the same convention as `src/migrations/test_runner.zig`:
//! every file with inline tests must be imported here, otherwise its
//! tests are silently compiled out and the count stays at the
//! pre-import baseline.

test {
    _ = @import("cleanup_stale_worker.zig"); // cronjob: delete stale worker rows + clear matching ActiveLoops (plan: docs/superpowers/plans/2026-08-19-cleanup-stale-worker-cron.md)
}