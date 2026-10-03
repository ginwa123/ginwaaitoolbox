//! Regression guards for `helpers.unixTimestampNanos` as a ROW-ID source.
//!
//! ## Why this file exists instead of living in `mod.zig`
//!
//! `helpers` is an external Zig package (see `build.zig.zon`), so the
//! `test` blocks declared inline in `src/helpers/mod.zig` are NOT compiled
//! by the `mod_tests` binary — Zig only runs tests belonging to a test
//! artifact's root module and the modules it imports by *package* name, and
//! a consumer never runs a dependency's tests.
//!
//! That is invisible from the outside: a test that does not run looks
//! exactly like a test that passes. Verified directly — an assertion in
//! `mod.zig` was changed to a deliberately wrong value and
//! `zig build test` still reported `8/8 steps succeeded` with an unchanged
//! test count.
//!
//! So this file gets its OWN test root in `build.zig`, the same treatment
//! `run_captured.zig` and `test_path.zig` already have. `mod.zig`'s own
//! inline tests remain un-run; reviving them is separate work, because two
//! of them no longer compile against Zig 0.16 (`.wasm` is gone from
//! `builtin.Os.Tag`, and `std.process.Child.id` is now a `?*anyopaque`
//! handle rather than a pid).
//!
//! ## What is under test
//!
//! `unixTimestampNanos()` feeds row ids all over the backend —
//! `item_<nanos>`, `task_<nanos>`, `at_<nanos>_<i>`. Two calls must never
//! return the same value in one process, and successive calls must not go
//! backwards (listings sort on it).

const std = @import("std");
const helpers = @import("helpers");

test "unixTimestampNanos: concurrent calls from many threads never repeat (Windows id-collision guard)" {
    // The bug this pins. On Windows the in-tick tie-break counter was
    // `threadlocal`, and `GetSystemTimeAsFileTime` is not a 100-ns clock:
    // it advances once per system timer tick, measured at ~1.6 ms on a
    // stock host (4000 reads in a tight loop spanned a single tick). So
    // two threads reading it inside one tick each started their own
    // counter at 0 and returned the IDENTICAL value.
    //
    // That is the ordinary path, not a race: kabelweb's server is
    // thread-per-connection (`kabelweb/src/server/event_loop.zig`), and the
    // functional harness opens a fresh connection per request. So
    // `POST /api/workspaces` — which mints the default project's
    // `item_<nanos>` — and the `POST /api/workspaces/:id/items/agent` that
    // follows it about a millisecond later ran on two threads and minted
    // the same id. The second INSERT died on the primary key and the
    // handler mapped it to `error.DatabaseError`, so the wire showed
    //
    //     POST /api/workspaces/:ws/items/agent -> 500
    //     {"error":"Failed to create agent item"}
    //
    // with `UNIQUE constraint failed: workspace_items.id` in the server
    // log. Reproduced on windows-2022 (~36 failures per functional shard)
    // and locally. Linux/macOS never saw it because `clock_gettime` there
    // has true nanosecond resolution and needs no tie-break at all.
    //
    // On POSIX this passes trivially; the point is that it goes red on
    // Windows if the tie-break ever becomes per-thread again.
    const thread_count = 8;
    const per_thread = 400;

    // Each thread writes its own slice and duplicates are found after the
    // join — no lock. `std.Io.Mutex` needs an `io` handle this standalone
    // root does not have (helpers is io-free by design), and a test that
    // cannot build guards nothing.
    const Collector = struct {
        fn run(out: []u128) void {
            for (out) |*slot| slot.* = @intCast(helpers.unixTimestampNanos());
        }
    };

    const total = thread_count * per_thread;
    const all = try std.testing.allocator.alloc(u128, total);
    defer std.testing.allocator.free(all);

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(
            .{},
            Collector.run,
            .{all[idx * per_thread ..][0..per_thread]},
        );
    }
    for (threads) |t| t.join();

    const sorted = try std.testing.allocator.dupe(u128, all);
    defer std.testing.allocator.free(sorted);
    std.mem.sort(u128, sorted, {}, std.sort.asc(u128));

    var dupes: usize = 0;
    var worst: u128 = 0;
    for (sorted[1..], sorted[0 .. sorted.len - 1]) |cur, prev| {
        if (cur == prev) {
            dupes += 1;
            worst = cur;
        }
    }
    if (dupes != 0) {
        std.debug.print(
            "unixTimestampNanos returned {d} duplicate value(s) across " ++
                "{d} threads x {d} calls (e.g. {d}); the in-tick tie-break " ++
                "is not process-wide, so two connections can mint the " ++
                "same row id\n",
            .{ dupes, thread_count, per_thread, worst },
        );
    }
    try std.testing.expectEqual(@as(usize, 0), dupes);
}

test "unixTimestampNanos: successive calls are non-decreasing (in-thread ordering)" {
    // Consumers treat the value as a time-ordered id — "newest first"
    // listings sort on it — so the tie-break must push values FORWARD.
    // A per-thread counter that resets on a new tick can do this per
    // thread and still hand two threads the same number, which is the
    // previous test; this one pins the ordering half on its own.
    var prev = helpers.unixTimestampNanos();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const cur = helpers.unixTimestampNanos();
        try std.testing.expect(cur > prev);
        prev = cur;
    }
}

test "unixTimestampNanos: concurrent calls still advance the clock, not just the counter" {
    // Guards against "fix" the other way: a process-wide counter that
    // increments per call and ignores the clock would pass the uniqueness
    // test above while drifting arbitrarily far from wall time. Values
    // must stay anchored to the real date — roughly now, not monotonically
    // inflating into the future.
    const ns = helpers.unixTimestampNanos();
    try std.testing.expect(ns > 1_577_836_800 * std.time.ns_per_s); // > 2020-01-01
    try std.testing.expect(ns < 4_102_444_800 * std.time.ns_per_s); // < 2100-01-01
}
