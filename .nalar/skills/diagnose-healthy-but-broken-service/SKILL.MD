---
name: diagnose-healthy-but-broken-service
description: "Use when a service/webview \"works the first time then breaks later\" (blank page, 404, stale assets) — the procedure for finding the dependency its liveness probe does not cover, and proving it at the wire level."
---
---
name: diagnose-healthy-but-broken-service
description: Use when a service/webview "works the first time then breaks later" (blank page, 404, stale assets) — the procedure for finding the dependency its liveness probe does not cover, and proving it at the wire level.
tags: [debug, pattern, http, webview, probe]
---

## When to Use

Any bug shaped like **"it worked, then it didn't, and the process looks fine"**:

- a desktop/webview window shows a blank page or `404 Not Found` on the *second*
  launch but not the first;
- a client attaches to a service that answers its health/liveness endpoint but
  serves garbage (or nothing) for the real request;
- assets/"config"/"template" appear stale after an update;
- logs say "healthy" while the user sees an error page.

The tell: **a liveness probe that does not exercise the dependency the client
actually needs.** `/health` proves the *process* is up; it says nothing about a
static dir, a mounted volume, a template root, a DB file, or a license file.

## Context

Worked example (ginwaaitoolbox, 2026-09-11, PR #453): the nalar desktop
extracted its webapp into a per-pid temp dir, spawned a DETACHED
`nalar --static-dir <that dir>`, then `rm -rf`'d the dir when the window closed.
The daemon outlived the window by design, so it answered `/health` 200 while
`GET /` returned `404 Not Found`. The next launch probed only `/health`,
attached to the orphan, and rendered the 404.

Generalised: **who deletes/moves the thing, and who still depends on it
afterwards?** Two objects with different lifetimes sharing a path.

## Procedure

1. **Reproduce at the wire level, on the live machine, before reading code.**
   Do not trust a screenshot. Hit the two endpoints and compare:
   ```bash
   curl -s -i http://127.0.0.1:PORT/          # what the client asks for
   curl -s -i http://127.0.0.1:PORT/health    # what the client probes to decide
   ```
   A `404`/`000` on the first with `200` on the second IS the bug, proven.
   Never kill the process you are probing (dev servers can be load-bearing).
2. **Find the process and its arguments** — the dependency is usually an argv:
   ```bash
   ps -eo pid,ppid,etime,cmd | grep -i <svc>
   ```
   `PPID 1` + a long `etime` means an orphaned/daemonised process that outlived
   its launcher. That is the population most likely to be holding a dead path.
3. **Check whether the path it was handed still exists**:
   `ls -ld <the --static-dir/--config/... value from step 2>`.
   ENOENT here + a live process = confirmed.
4. **Find who deletes it.** Grep the client for the lifetime mismatch:
   search for the extraction/creation call and for any `cleanup`/`deleteTree`/
   `rm -rf`/`defer ...unlink` on that path, then check whether the deleting
   process is the same one that owns the consumer. Different lifetimes ⇒ bug.
5. **Classify the fix.** Two independent layers, and you usually want both:
   - *Make the artefact outlive every consumer.* Prefer a persistent,
     content-addressed dir (hash of the content, marker file written last,
     staged + atomic rename) over a per-pid temp dir. It also fixes "the
     runtime dir is wiped on logout/reboot", which a per-run temp dir cannot.
   - *Make the probe cover the dependency.* Probe the REAL request (the page,
     the asset) and require the content to look right, not just a 2xx from a
     neighbouring route.
6. **Close the attach/spawn trap.** If the client spawns the service, note that
   spawning into an ALREADY-OCCUPIED port can "succeed": the child fails to
   bind and dies, while the squatter's own health endpoint answers your
   readiness poll, so you report success for a port you do not own. Check the
   port is free first (bind-probe it) and pick an ephemeral one if not.
7. **Write the regression test at the layer that failed, not the layer that
   passed.** For this class that means a wire-level test: boot the real binary
   with a real dependency dir, assert 200, then remove the dir behind the
   server's back and assert the 404 **while also asserting the health endpoint
   still says 200** (the asymmetry is the whole bug). See
   `tests/functional/desktop_webapp_404_test.py` and the path-aware mock server
   in `src/apps/desktop_app/attach_test.zig` for both shapes.

## Pitfalls

- **A "passing" test suite can be structurally blind here.** The client's own
  unit-test target may not be wired into CI at all, and its tests may not have
  been runnable for months (missing generated file). Check whether the suite you
  are extending actually executes in CI before trusting it as the guard.
- **Cross-platform test guards.** If your mock/helpers use `std.os.linux.*`
  syscalls, guard with `if (builtin.os.tag != .linux) return error.SkipZigTest;`
  — a bare `return` reports a PASS with zero coverage, which is worse than a
  skip.
- **Zig's test runner fails a run when `std.log.err` fires.** Deliberately
  driving production error paths (a failed spawn, a refused connection) turns a
  green suite red. Test the SUCCESS path with a working fake (a script that
  binds the port it is given and self-exits) instead of a deliberate failure.
- **Do not weaken production logging to satisfy a test runner.** Prefer a
  test-side fake over downgrading a real `.err` to `.warn`.
- **Verifying by hand can break something else.** If you start servers for a
  manual check, use a distinctive port, and never touch a port the user has
  declared off-limits. Beware `pkill -f <pattern>`: the shell running your
  command has the pattern in its own cmdline, so it kills itself (see the
  `pkill-f-pattern-kills-own-shell` memory).
- **Post-spawn verification kills healthy children on a probe false negative.**
  If you verify a freshly spawned child by probing it and terminate it on
  failure, make the probe robust (loop partial writes, generous read timeout,
  sniff only what the real app reliably serves) — one flaky probe must not nuke
  a good process.

## Verification

- The pre-fix code, patched only with the failing assertions, FAILS: assert the
  404-plus-200-health asymmetry against the old code path.
- The symptom is gone on the real binary: `GET /` 200 with real content after a
  close/reopen cycle, and it stays 200 across a machine-logout-equivalent
  (delete the old temp base, leave the persistent one).
- The fix is observable in the logs: the refused server is named and skipped
  ("…is alive but does not serve the webapp at / — ignoring it") rather than
  silently used.
- Residual risk is written down, not hidden. Here: a pre-existing orphan on the
  default port makes each launch spawn its own instance on a random port
  (a plain-spawned service writes no state file), so daemons can accumulate
  until the squatter is stopped.

