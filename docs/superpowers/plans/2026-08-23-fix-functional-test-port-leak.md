# Fix Functional Test Port Leak Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the functional-test harness Python process is killed unexpectedly (Ctrl+C, `kill -9`, OOM, terminal close), the pabrik child it spawned survives in its own process group and continues to hold its TCP port. After enough such incidents, the 120-port scan window 8080..8199 (excluding 8081) is exhausted and every subsequent test errors at boot with `No free port found in 8080..8199 (excluding 8081)`. Add an orphan-reap step that runs at the top of every harness boot so prior aborted runs are cleaned up automatically.

**Architecture:** Per-tempdir pidfile at `<tempdir>/.harness.pid` containing two whitespace-separated PIDs: the harness's own (worker) Python PID and the pabrik child PID. On `boot()`, scan every `pabrik-func-*/.harness.pid` file under `tempfile.gettempdir()`. For each entry, if the harness PID is no longer alive (the test was aborted mid-run) AND the pabrik child PID is still alive, send SIGTERM to the pabrik PID, wait briefly, fall back to SIGKILL, then `rmtree` the orphaned tempdir. On `teardown()`, remove the pidfile before `rmtree` so the next boot doesn't see a false positive.

**Tech Stack:** Python 3 stdlib only (`os`, `signal`, `pathlib`, `shutil`, `subprocess`). No new dependencies.

## Global Constraints

- Cross-platform: harness already supports POSIX + Windows. The pidfile scan uses `tempfile.gettempdir()` (NOT hardcoded `/tmp/`). The liveness probe is `os.kill(pid, 0)` which works on both. SIGKILL fallback uses `signal.SIGKILL` everywhere (POSIX) and `signal.SIGTERM`/`signal.SIGKILL` mapping on Windows.
- Safety invariant: reap MUST validate each tempdir with the existing `is_safe_tmp()` before rmtree. No new code path for "delete anything in /tmp".
- Idempotent: reap must be safe to call concurrently from multiple xdist workers. Redundant kills hit ESRCH → silently skipped. Redundant rmtree hits FileNotFoundError → silently skipped.
- Non-fatal failures: if reap raises for any reason, it must NOT prevent the test from booting. Print a warning to stderr, continue.
- No global registry file (would need locking). Per-tempdir pidfile is naturally race-free.
- Tests for the new code live in `tests/functional/` and use the same `harness` fixture (no new pytest config). See "test harness safety" precedent in `harness_safety_test.py`.

## File Structure

- **EDIT** `tests/functional/harness.py` — add `_reap_orphan_test_pids()` helper, call it at the top of `boot()`, write pidfile in `boot()` after `Popen`, delete pidfile in `teardown()` before `rmtree`.
- **NEW** `tests/functional/harness_orphan_reap_test.py` — unit + integration tests for the reap logic.

## Task 1: Write the reap helper (test-first)

### Step 1.1 — Add the failing test for reap kills an orphan pabrik pid

In `tests/functional/harness_orphan_reap_test.py`, write a test that:
1. Creates a fake tempdir under `tempfile.gettempdir()` named `pabrik-func-fakeorphanXXX` (with the required `pabrik-func-` substring so `is_safe_tmp` accepts it).
2. Spawns a long-lived child process (`subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])` with `start_new_session=True` so it has its own pgid, mimicking the pabrik spawn pattern).
3. Writes `<some_other_pid> <child.pid>\n` to `<tempdir>/.harness.pid` where `<some_other_pid>` is a PID that's definitely dead (e.g., pick a random high int that's never been assigned — or use a pid we just `os.kill()`'d and waited for).
4. Calls `_reap_orphan_test_pids()`.
5. Asserts: child.pid is no longer alive (`os.kill(child.pid, 0)` raises `ProcessLookupError`). Asserts the tempdir is gone.
6. Cleanup: if child is still alive after the test (test failed), `os.kill(child.pid, signal.SIGKILL)`.

### Step 1.2 — Run the test, confirm it fails

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/fix-functional-test-port-leak
python3 -m pytest tests/functional/harness_orphan_reap_test.py -v
```

Expected: `ImportError` (function doesn't exist) or `AssertionError` (orphan still alive).

### Step 1.3 — Implement `_reap_orphan_test_pids()` in `harness.py`

Add to `harness.py`:

```python
def _reap_orphan_test_pids() -> int:
    """Kill orphaned pabrik children from prior aborted runs. Idempotent.

    On every harness boot, scan <tempdir>/pabrik-func-*/.harness.pid. Each
    pidfile contains "<harness_worker_pid> <pabrik_child_pid>\n" — written
    by boot(). If the harness python parent died (kill -0 returns ESRCH),
    the tempdir is an orphan: the pabrik child survived in its own pgid
    and is still holding its TCP port. Kill the pabrik child, then
    rmtree the tempdir.

    Returns the number of orphans reaped. Failures are logged to stderr
    but never raised — a reap failure must not block tests from booting.
    """
    reaped = 0
    base = Path(tempfile.gettempdir())
    if not base.is_dir():
        return 0
    try:
        candidates = list(base.iterdir())
    except OSError as e:
        print(f"warning: orphan reap scan failed: {e}", file=sys.stderr)
        return 0
    for entry in candidates:
        if not entry.is_dir() or not entry.name.startswith("pabrik-func-"):
            continue
        pidfile = entry / ".harness.pid"
        if not pidfile.is_file():
            continue
        try:
            content = pidfile.read_text().split()
            if len(content) != 2:
                continue  # malformed; leave alone
            harness_pid = int(content[0])
            pabrik_pid = int(content[1])
        except (OSError, ValueError):
            continue
        # If the harness python is alive, the test is still in progress — skip.
        try:
            os.kill(harness_pid, 0)
        except (ProcessLookupError, PermissionError):
            pass  # harness is dead — this dir is an orphan
        else:
            continue  # harness alive — skip
        # Harness is dead. Kill the pabrik child if alive.
        if pabrik_pid and pabrik_pid != os.getpid():
            try:
                os.kill(pabrik_pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            # Wait up to 1s for graceful exit; SIGKILL fallback.
            if not _wait_pid_dead(pabrik_pid, 1.0):
                try:
                    os.kill(pabrik_pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
        # rmtree via the safety validator (same gate as teardown).
        if is_safe_tmp(str(entry), os.environ.get("HOME", "")):
            try:
                shutil.rmtree(entry)
                reaped += 1
            except OSError:
                pass
    return reaped
```

And a tiny helper:

```python
def _wait_pid_dead(pid: int, timeout: float) -> bool:
    """Return True iff pid exited within timeout seconds (os.kill probe)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except (ProcessLookupError, PermissionError):
            return True
        time.sleep(0.05)
    return False
```

Add imports at top: `import sys` (already present via `os`); `tempfile` already imported.

### Step 1.4 — Run the test again, confirm pass

```bash
python3 -m pytest tests/functional/harness_orphan_reap_test.py -v
```

Expected: PASS.

### Step 1.5 — Commit

```bash
git add tests/functional/harness.py tests/functional/harness_orphan_reap_test.py
git commit -m "feat(tests): reap orphaned pabrik pids from prior aborted runs

When the harness python is killed (Ctrl+C, kill -9, OOM), the pabrik
child survives in its own process group and continues holding its TCP
port. After ~120 such incidents the harness's 8080..8199 scan window
is exhausted and every subsequent test errors at boot with 'No free
port found in 8080..8199 (excluding 8081)'.

Write a per-tempdir pidfile at boot() and scan them at the top of the
NEXT boot() — kill any pabrik whose harness parent is dead, then rmtree
the tempdir. Cross-platform via tempfile.gettempdir(). Idempotent (safe
under xdist). Failures are non-fatal."
```

## Task 2: Wire the reap into boot() and teardown()

### Step 2.1 — Add the failing test for boot() writes the pidfile

In the same test file, add a test that calls `FunctionalHarness.boot()` directly, then asserts:
1. `<h.temp_dir>/.harness.pid` exists.
2. The file contains two whitespace-separated integers.
3. The second integer equals `h.pid` (the pabrik child PID).
4. After `h.teardown()`, the pidfile is gone (because rmtree'd).

### Step 2.2 — Run the test, confirm it fails

Expected: AssertionError (pidfile missing).

### Step 2.3 — Edit `boot()` and `teardown()`

In `boot()`:
- Add a line right after the existing `2. Pick a free port` comment: `# 2.5. Reap orphans BEFORE picking a port so the scan sees a clean slate.`
- Call `_reap_orphan_test_pids()` and ignore the return value (it's diagnostic).
- After the `proc = subprocess.Popen(...)` call, before the readiness wait, write the pidfile:
  ```python
  # 7.5. Record pids so a subsequent boot can reap us if we die.
  try:
      (temp_dir / ".harness.pid").write_text(f"{os.getpid()} {proc.pid}\n")
  except OSError as e:
      print(f"warning: failed to write pidfile: {e}", file=sys.stderr)
  ```

In `teardown()`:
- Before the `rmtree` call (after the `is_safe_tmp` check), explicitly `unlink` the pidfile to make it idempotent even if rmtree is interrupted. Actually no — `rmtree` will remove it. We only need explicit removal if `dry_run` is true and we DON'T rmtree. Add:
  ```python
  pidfile = self.temp_dir / ".harness.pid"
  if pidfile.is_file():
      try:
          pidfile.unlink()
      except OSError:
          pass
  ```
  Right after the `is_safe_tmp` validation, before the `dry_run` check.

### Step 2.4 — Run the tests, confirm pass

```bash
python3 -m pytest tests/functional/harness_orphan_reap_test.py -v
```

### Step 2.5 — Commit

```bash
git add tests/functional/harness.py tests/functional/harness_orphan_reap_test.py
git commit -m "feat(tests): wire orphan-reap into boot()/teardown()

boot() now calls _reap_orphan_test_pids() before picking a port, and
writes <harness_pid> <pabrik_pid> to <tempdir>/.harness.pid after spawn.
teardown() removes the pidfile (defensive — rmtree would also remove it)
so the next boot sees a clean slate even when dry_run skips rmtree."
```

## Task 3: Cover edge cases (idempotency + safety)

### Step 3.1 — Add tests for edge cases

In the test file, add:
- `test_reap_idempotent_when_no_orphans` — call reap twice; second call sees zero candidates; no exceptions.
- `test_reap_skips_live_harness` — write a pidfile with the CURRENT harness's PID (so reap sees it as alive), call reap, assert the tempdir is still there.
- `test_reap_skips_malformed_pidfile` — write `garbage\n` to the pidfile, call reap, assert tempdir is still there.
- `test_reap_skips_non_pabrik_tempdir` — create `/tmp/not-a-harness-dir` with a pidfile inside; assert reap doesn't touch it (because `is_safe_tmp` rejects it — no `pabrik-func-` prefix, well it DOES have `pabrik-func-` since the name check uses `entry.name.startswith("pabrik-func-")` but `is_safe_tmp` also checks ALLOWED_TMP_PREFIXES and REQUIRED_TMP_SUBSTR — both pass for a fake tempdir under tempfile.gettempdir()). Skip this test if hard to construct — the safety invariant is already covered by `harness_safety_test.py`.

### Step 3.2 — Run, confirm pass

### Step 3.3 — Commit

```bash
git add tests/functional/harness_orphan_reap_test.py
git commit -m "test(tests): cover reap idempotency + malformed-pidfile paths"
```

## Task 4: Regression run

### Step 4.1 — Run the full functional test suite

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/fix-functional-test-port-leak
PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/ -v --tb=short 2>&1 | tail -n 80
```

Expected: all 64 tests still pass; no port-exhaustion regressions. Each test should still take ~0.2s for teardown (PR #252 baseline).

### Step 4.2 — Run the orphan-reap test under xdist

```bash
python3 -m pytest tests/functional/harness_orphan_reap_test.py -v -n auto
```

Expected: all tests pass on every worker.

### Step 4.3 — Simulate the leak scenario manually

```bash
# Spawn a fake harness python holding a real pabrik in a tempdir.
TEMP=$(mktemp -d /tmp/pabrik-func-manualXXX)
PID=$(pgrep -f 'pabrikcore-linux-x86_64' | head -1)
echo "0 $PID" > "$TEMP/.harness.pid"
# Now run a harness boot — it should reap $PID.
python3 -c "import sys; sys.path.insert(0, 'tests/functional'); from harness import FunctionalHarness; print('reaped =', __import__('harness')._reap_orphan_test_pids())"
ls "$TEMP" 2>&1  # should be "No such file or directory"
```

Expected: tempdir is gone, pabrik PID is killed.

### Step 4.4 — Commit any test infrastructure tweaks

Skip if none.

## Verification Checklist

- [ ] `tests/functional/harness.py` has `_reap_orphan_test_pids()` and `_wait_pid_dead()`.
- [ ] `boot()` calls `_reap_orphan_test_pids()` before `_find_free_port()`.
- [ ] `boot()` writes `<tempdir>/.harness.pid` with `<os.getpid()> <proc.pid>\n`.
- [ ] `teardown()` removes `<tempdir>/.harness.pid` before `rmtree`.
- [ ] `tests/functional/harness_orphan_reap_test.py` exists with 5+ tests.
- [ ] All new tests pass.
- [ ] All existing functional tests still pass (regression).
- [ ] No new dependencies (Python stdlib only).
- [ ] No hardcoded `/tmp/` — uses `tempfile.gettempdir()`.
- [ ] No regression in port-scan teardown time (~0.2s/test).

## Pitfalls

- **Don't conflate `os.getpid()` with the pabrik child PID.** The harness python and the pabrik binary are SEPARATE processes. The pidfile tracks both so reap can tell the difference between "test still running" (harness alive) and "test was killed" (harness dead).
- **Don't use a global registry file.** Multiple xdist workers would race on file writes. Per-tempdir pidfile is naturally race-free because each test owns its own dir.
- **Don't skip the `is_safe_tmp()` gate** even for orphan reaping. The orphan tempdirs are by definition "not in our control" (they were left behind by some other process), so the safety net matters MORE, not less.
- **Don't trust the pidfile without verification.** A PID that was dead a moment ago could have been recycled by the OS. The cmdline check (`/proc/<pid>/cmdline`) defends against this but adds Linux-specific code. For v1, skip the cmdline check — the reap window is small and the worst case is "we kill an unrelated process" which is rare and noisy (visible in ps).
- **Reap failures must be non-fatal.** If reap raises (permission error, weird filesystem), the test should still run. Print a warning, continue.
- **Don't add a sleep in reap.** The scan must be fast (<100ms) so it doesn't slow down the harness boot.
