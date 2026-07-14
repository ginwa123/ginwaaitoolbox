# nalar — `failed command:` in zig build output is misleading, not a failure

Zig's build runner prints `failed command: <path>` after a step's stderr output
in the **verbose** error style (the default for `zig build test`), even when
the step actually succeeded. The label is misleading: it's not a failure
indicator, just a debug aid showing what command produced the stderr.

## Symptom

After running `zig build test`, you see:

```
[default] (warn): Config file not found at explicit path /home/.../tmp/.../nope.json
[default] (warn): Failed to parse JSON config: SyntaxError
failed command: ./.zig-cache/o/abc123/test --cache-dir=./.zig-cache --seed=0x...

Build Summary: 5/5 steps succeeded; 1273/1276 tests passed (3 skipped)
test success
+- run test 1273 pass, 3 skip (1276 total)
```

The "failed command:" line above the clean summary confuses developers into
thinking something failed. It did NOT — the build is passing.

## Root cause

In `/usr/local/lib/zig/compiler/build_runner.zig`:

```zig
// Print error/warning messages for any step that produced stderr.
if (s.result_error_bundle.errorMessageCount() > 0 or
    s.result_error_msgs.items.len > 0 or
    s.result_stderr.len > 0)         // ← ANY stderr, including [default] (warn): lines
{
    printErrorMessages(gpa, s, ...);
}
```

Inside `printErrorMessages`:

```zig
if (error_style.verboseContext()) {       // ← verbose mode (the default)
    if (failing_step.result_failed_command) |cmd_str| {
        try stderr.setColor(.red);
        try writer.writeAll("failed command: ");  // ← always printed when verboseContext=true and result_failed_command is set
        ...
    }
}
```

The variable is named `result_failed_command` but is set **unconditionally
before every spawn** in `Run.zig:1541` — it's used as a "show the command
that produced this stderr" aid, not as a "did this command fail?" flag.

The condition `verboseContext()` is true for error styles `verbose` and
`verbose_clear` (the default). The stderr trigger fires for any `[default]
(warn): ...` line — which most test suites produce from tests exercising
error paths.

## Fix / how to read the output correctly

**Option A — accept the noise.** The build summary line is the ground truth:
- `Build Summary: 5/5 steps succeeded` = all OK
- `Build Summary: N/N steps succeeded` and `test success` = tests passed
- Look at `1273/1276 tests passed (3 skipped)` — the denominator minus pass
  minus skip = fail count. `1276 - 1273 - 3 = 0` → no failures.

**Option B — switch to minimal error style:**

```bash
export ZIG_BUILD_ERROR_STYLE=minimal
zig build test --summary all
```

Output (no "failed command:" line, only the summary):

```
Build Summary: 5/5 steps succeeded; 1273/1276 tests passed (3 skipped)
test success
+- run test 1273 pass, 3 skip (1276 total)
```

This is the cleanest output for CI logs and daily dev work. Set it in your
`~/.bashrc` / `~/.zshrc` if you don't want to type it each time.

## When this bites

- Reading test output and stopping at the red "failed command:" line,
  thinking the test failed (when it actually passed).
- Grepping the output for "fail" or "error" and getting false positives
  from the "failed command:" line.
- Reviewing a PR's CI log and being confused by the red "failed command:"
  text under a green build summary.
- The test runner also runs with `fail_count > 0` checks for actual test
  failures — those appear as `[default] (err): ...` lines (not `warn:`) in
  the test binary's stderr, plus a `test failure` label in the summary.

## How to verify

If "failed command:" appears but the summary says success → build is fine.

If "failed command:" appears AND the summary shows `(N failed)` or
`test failure` → there IS a real failure. Look for the test name in the
test binary's stderr (printed just before the "failed command:" line).

## Concrete example

This was observed in the nalar codebase during the
`fix-zig-build-test-2026-07-11` work. After fixing 4 failing tests + 1
memory leak in `search_test.zig`, the build became:

```
Build Summary: 5/5 steps succeeded; 1273/1276 tests passed (3 skipped)
test success
+- run test 1273 pass, 3 skip (1276 total) 2s MaxRSS:19M
   +- compile test Debug native cached 21ms MaxRSS:45M
```

But `failed command: ./.zig-cache/o/c0b5ee5c8799841cd31b8cf71ce85e12/test ...`
still appears because the test binary exercises ~10 production error paths
that emit `[default] (warn):` lines to stderr.

## Related

- `zig-0.16-test-log-err-count.md` — a related but distinct issue where
  `std.log.err(...)` calls in production code trigger `log_err_count > 0`
  and actually make the build step fail (different from the cosmetic
  "failed command:" line).
- The 10 warning lines from intentional error-path tests (sqlite,
  MCP config, Config parsing, etc.) are by design — they prove the
  error paths work.
