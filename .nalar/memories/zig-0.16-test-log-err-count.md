# Zig 0.16 — `expectError` tests that exercise production `std.log.err` exit 1 from `zig build test`

When a Zig 0.16 test exercises a production error path that calls
`std.log.err(...)`, the test framework reports `log_err_count > 0`
to the build runner, which then exits 1 even though the test
assertions themselves passed. The test binary's own exit code is
also 1 (the binary returns non-zero when it logged any err-level
messages during a test).

## Symptom

```
Build Summary: 3/5 steps succeeded (1 failed); 904/907 tests passed (3 skipped)
test transitive failure
+- run test 904 pass, 3 skip (907 total); 2 error logs
```

The "2 error logs" comes from the `std.zig.Server.zig`
`TestResults.flags.log_err_count` field — a counter set by the
default `std.testing` test runner that increments every time
`std.log.err(...)` is called during a test. The
`std/Build/Step/Run.zig:1980-1985` step checks `log_err_count > 0`
and reports it as a build error:

```zig
} else if (log_err_count > 0) {
    const name = md.testName(tr_hdr.index);
    const stderr_bytes = std.mem.trim(u8, stderr.buffered(), "\n");
    stderr.tossBuffered();
    try run.step.addError("'{s}' logged {d} errors:\n{s}", .{ name, log_err_count, stderr_bytes });
}
```

The test binary itself returns the same exit code (verify with
`./test_binary 2>&1 | tail -n 3` — `904 passed; 3 skipped; 0 failed.
2 errors were logged.` followed by exit 1).

## Why this happens

`std.testing` has no logFn override hook. `std.options.logFn` is
`pub const options: Options = if (@hasDecl(root, "std_options"))
root.std_options else .{}` — declared `const`, so it can NOT be
reassigned at runtime by test code. The only ways to set it are:

1. Compile-time `pub const std_options = .{ .logFn = ... }` in
   `root.zig` (global, can't toggle per-test).
2. Catch the err at the call site with `catch |err| switch (err)`
   and DON'T call `std.log.err` from production code on testable
   error paths.

The first option is too coarse (it affects every test in the binary).
The second option requires production code changes.

## Fix (pragmatic, what I do in nalar)

When a test exercises a production error path that legitimately
calls `std.log.err`, accept the `log_err_count > 0` build wrapper
failure as a known artifact and document it. Verify test correctness
by running the test binary directly:

```bash
TEST_BIN=$(find .zig-cache/o -name "test" -type f -executable \
    | xargs file 2>/dev/null | grep "x86-64" | grep -v "windows" \
    | sort | tail -n 1 | cut -d: -f1)
timeout 60 "$TEST_BIN" 2>&1 | tail -n 3
# Expected: "904 passed; 3 skipped; 0 failed. 2 errors were logged."
```

The `0 failed` line confirms the test assertions all passed; the
`2 errors were logged` line is the noise from production code's
observability logging.

## Production-side fix (preferred long-term)

If you control the production code, downgrade `std.log.err` to
`std.log.warn` for paths that are user-input errors (not internal
programmer errors). The Zig 0.16 test harness counts `.err` (level
0) but NOT `.warn` (level 1) by default at `log_level = .warn`.

Example from `Config.zig`:
```zig
// Before (test-hostile): production observability via err
std.log.err("Config file not found at explicit path {s}", .{...});

// After (test-friendly): user-input error, demote to warn
std.log.warn("Config file not found at explicit path {s}", .{...});
```

The `expectError` test then no longer triggers `log_err_count > 0`
and the build wrapper exits 0. Apply this when the production-side
log severity change is semantically correct (user errors are warnings,
not programmer errors).

## Why `std.testing.log_level` doesn't help

`std.testing.log_level = .warn` is the default. The check is
`@intFromEnum(level) <= @intFromEnum(log_level)`. With `log_level =
.warn` (1), `.err` (0) and `.warn` (1) both pass. To suppress `.err`,
you'd need `log_level < .err` — but the enum starts at `.err = 0`,
so there's no smaller value. Setting it to `.err` only shows err
(still shown). The threshold is inclusive-low, so err-level messages
always get through.

## Concrete example in nalar

`src/modules/config/config_test.zig` tests
- `init does NOT auto-create when explicit path is missing`
- `init does NOT auto-create when file exists with parse error`

both call `LlmConfig.init(...)` which has `std.log.err(...)` in
the error path. The `expectError` assertion passes, but the test
binary exits 1 and `zig build test` reports `log_err_count = 2`.
Production-side fix would require demoting these logs to `.warn`,
which is a semantic change that's not in scope for the auto-init
chunk 2 work.

## How to verify test correctness despite the build wrapper noise

```bash
TEST_BIN=$(find .zig-cache/o -name "test" -type f -executable \
    | xargs file 2>/dev/null | grep "x86-64" | grep -v "windows" \
    | sort | tail -n 1 | cut -d: -f1)
# Run JUST the new test by name:
timeout 60 "$TEST_BIN" 2>&1 | grep -E "init auto-creates|init does NOT|FAIL|0 fail" | head -n 10
```

If the assertions pass (`0 fail`) and the new test names appear
with `...OK`, the tests are correct — the build wrapper's exit 1 is
purely cosmetic.

## Related

- `nalar-build-cross-compile-blocked.md` — different "build wrapper
  exits 1" failure (missing system libs at link time).
- `zig-0.16-spawn-cwd-is-not-nullable.md` — different "tests pass
  but install fails" failure (lazy analysis on different module
  graphs).
- `cross-check-claims-against-source.md` — different testing
  discipline (verifying third-party claims before acting).