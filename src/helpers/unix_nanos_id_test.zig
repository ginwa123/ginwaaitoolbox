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
//! `item_<nanos>`, `task_<nanos>`, `at_<nanos>_<i>`.

const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers");

/// Windows-only. See the module docstring for why the POSIX path is
/// excluded from the uniqueness assertions.
const is_windows = builtin.os.tag == .windows;

test "unixTimestampNanos: concurrent calls from many threads never repeat (Windows id-collision guard)" {
    // WHY WINDOWS ONLY.
    //
    // On Windows the in-tick tie-break is the whole point of the test: the
    // tie-break used to be a `threadlocal` counter, and
    // `GetSystemTimeAsFileTime` advances only once per system timer tick —
    // measured at ~1.6 ms on a stock host (4000 reads in a tight loop
    // spanned a single tick). So two threads reading it inside one tick
    // each started their own counter at 0 and returned the IDENTICAL value.
    //
    // That was the ordinary path, not a race: kabelweb's server is
    // thread-per-connection (`kabelweb/src/server/event_loop.zig`), and the
    // functional harness opens a fresh connection per request. So
    // `POST /api/workspaces` — which mints the default project's
    // `item_<nanos>` — and the `POST /api/workspaces/:id/items/agent` that
    // follows it about a millisecond later ran on two threads and minted
    // the same id. The second INSERT died on the primary key:
    //
    //     warning: sqlite3 step failed: UNIQUE constraint failed:
    //              workspace_items.id
    //     POST /api/workspaces/:ws/items/agent -> 500
    //     {"error":"Failed to create agent item"}
    //
    // Reproduced on windows-2022 (~36 failures per functional shard) and
    // locally.
    //
    // NOT asserted on POSIX, on purpose. `clock_gettime(CLOCK_REALTIME)`
    // advances at nanosecond granularity in practice, so back-to-back calls
    // almost always differ — but that is a property of the clock, not a
    // promise of the implementation, and `unixTimestampNanosPosix` adds no
    // tie-break of its own. macOS in particular hands out `CLOCK_REALTIME`
    // at a coarse enough granularity that a tight loop of a few thousand
    // calls DOES see repeats: a first cut of this test asserted distinctness
    // everywhere and went red on `backend (macOS ARM64)` while passing on
    // Linux and Windows. Asserting it there would be asserting something
    // the POSIX code never claimed to deliver.
    //
    // (Whether the POSIX path *should* get the same process-wide tie-break
    // as Windows is a real question, and it is deliberately NOT answered in
    // this change — it would alter id values on Linux and macOS.)
    if (!is_windows) return;

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

test "unixTimestampNanos: successive calls strictly increase (Windows in-tick tie-break)" {
    // Consumers treat the value as a time-ordered id — "newest first"
    // listings sort on it — so on Windows the tie-break must push values
    // FORWARD and never repeat. This is the half that the uniqueness test
    // above cannot see: two threads could each be internally monotonic and
    // still overlap.
    //
    // POSIX is excluded for the same reason as above; `CLOCK_REALTIME` can
    // legitimately repeat, and can step backwards on an NTP adjustment.
    if (!is_windows) return;

    var prev = helpers.unixTimestampNanos();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const cur = helpers.unixTimestampNanos();
        try std.testing.expect(cur > prev);
        prev = cur;
    }
}

test "unixTimestampNanos: stays anchored to wall-clock time, not just a counter" {
    // Runs on every platform, and it is the assertion that catches the
    // opposite mistake: a "fix" that made ids unique by incrementing a
    // counter and ignoring the clock would pass the tests above on Windows
    // while drifting arbitrarily far from real time. Values must remain a
    // real date — roughly now, not monotonically inflating into the future.
    const ns = helpers.unixTimestampNanos();
    try std.testing.expect(ns > 1_577_836_800 * std.time.ns_per_s); // > 2020-01-01
    try std.testing.expect(ns < 4_102_444_800 * std.time.ns_per_s); // < 2100-01-01
}
