# Functional Tests

Real-data, isolated-in-`/tmp` end-to-end coverage for pabrik. Each test
boots a fresh `pabrik` binary against an isolated tempdir HOME, exercises
the HTTP API with non-trivial data, and rmtree's the tempdir on
teardown.

## ⛔ Safety Invariant

**The harness NEVER deletes the developer's real `$HOME`.** Three
defensive layers enforce this:

1. **`is_safe_tmp(path, orig_home)` allow-list validator** — runs
   before every `shutil.rmtree`. Returns True only if the path
   (a) starts with `/tmp/`, `/private/tmp/`, `/private/var/folders/`,
   or `tempfile.gettempdir() + "/"`, AND (b) contains the literal
   substring `pabrik-func-`, AND (c) does not resolve to the real
   `$HOME` (catches symlinks via `os.path.realpath`).
2. **Captured `Path` attribute, not `$HOME`** — `h.temp_dir` is set
   once at boot. `teardown()` rmtree's THIS attribute. A test that
   re-exports `HOME=/Users/alice` mid-run cannot trick the cleanup
   into touching the real home.
3. **`ORIG_HOME` snapshot + restore** — `orig_home = os.environ["HOME"]`
   is captured before `os.environ["HOME"] = temp_dir`. Restored in
   `teardown()`'s first step.

The five negative tests in `harness_safety_test.py` guard these
invariants against regression. **If any of them fail, the harness
has a P0 bug — do not merge.**

## Running

### Quick smoke (no binary required)

```bash
pip install -r tests/functional/requirements.txt
pytest tests/functional/harness_safety_test.py -v
# Expect: 12 passed.
```

### Full suite (requires a built pabrik)

```bash
# Option A: use an existing binary
PABRIK_BIN=/path/to/pabrik pytest tests/functional/

# Option B: build first, then run
zig build install:linux:system
pytest tests/functional/

# Option C: let zig build do everything
zig build functional-test
```

### Single suite

```bash
PABRIK_BIN=./zig-out/bin/pabrik pytest tests/functional/workspace_lifecycle_test.py -v
```

### Dry-run mode (skip rmtree; useful for debugging)

```bash
PABRIK_FUNCTIONAL_DRY_RUN=1 PABRIK_BIN=./zig-out/bin/pabrik pytest tests/functional/smoke_boot_test.py -v -s
# tempdirs are NOT cleaned up; you can inspect them after the run.
```

### Parallel

```bash
PABRIK_BIN=./zig-out/bin/pabrik pytest tests/functional/ -n auto
# Each worker gets its own pabrik process, its own port, its own tempdir.
```

## TUI suites (pty-driven, no HTTP)

`tui_perf_test.py` covers `pabrik-tui`'s memory + input-latency behaviour. It is
different in kind from the HTTP suites:

* it drives the **TUI binary inside a pty** (`tui_perf_probe.py`) because the TUI
  refuses to start without a TTY and its symptoms (RSS growth per redraw,
  key-to-echo latency) only exist at the terminal layer;
* it is **hermetic** — the TUI is pointed at an unreachable backend, so no port is
  bound, no server boots and nothing is written to disk;
* it **skips** (does not fail) when `pabrik-tui` is missing, because CI's
  functional-test step installs only the `pabrik` binary.

```bash
zig build install:tui
python3 tests/functional/tui_perf_probe.py --binary zig-out/bin/pabrik-tui   # standalone report
python3 -m pytest tests/functional/tui_perf_test.py -v                      # gate
PABRIK_TUI_BIN=/path/to/pabrik-tui python3 -m pytest tests/functional/tui_perf_test.py -v
```

Background: `docs/superpowers/plans/2026-09-13-audit-pabrik-tui-memory-and-latency.md`.

## Adding a new suite

1. Create `tests/functional/<feature>_lifecycle_test.py` (or
   `<feature>_test.py`).
2. Use the `harness` fixture from `conftest.py` — it provides a
   fresh `FunctionalHarness` with the API client.
3. Write `def test_<scenario>()` functions. Each test is a fresh
   boot (function-scoped fixture) and ~5-10s of API work.
4. Use non-trivial data: ≥ 5 items per workspace, ≥ 30 tasks across
   kanban columns, ≥ 10 elements per design page. The point of
   functional tests is to exercise real shapes.
5. Verify locally with `pytest tests/functional/<your>_test.py -v`.
6. Add the test file to the build target (it auto-discovers, so
   no extra registration is needed).

## Test anatomy

```python
def test_workspace_create_returns_201(harness: FunctionalHarness) -> None:
    r = harness.http("POST", "/api/workspaces", json_body={"name": "x"}, expect=201)
    assert r.json()["id"].startswith("ws_")
```

That's it. The fixture handles boot + teardown; the harness
handles HTTP, JSON, and the safety net.

## How isolation works

When a test starts:

1. `harness = FunctionalHarness.boot(bin)` runs.
2. `boot()` calls `tempfile.mkdtemp(prefix="pabrik-func-")` — a fresh
   dir like `/var/folders/.../T/pabrik-func-0v1e3wyf`.
3. `is_safe_tmp()` validates the new path. If it fails, boot
   aborts and the test errors with `FunctionalHarnessError`.
4. `os.environ["HOME"]` is shadowed to the tempdir. The pabrik
   process inherits this via `subprocess.Popen(env=...)`.
5. pabrik's `helpers.db_path.getDbPath(allocator, io, environment)`
   reads `HOME` from the env and creates `$HOME/.config/pabrik/agent.db`
   (Linux) or `$HOME/Library/Application Support/pabrik/config.json`
   (macOS). **Both paths land inside the tempdir.**
6. pabrik runs all 64 migrations, listens on the chosen port, and
   the test drives the API.

When the test ends:

1. The fixture's `try/finally` calls `h.teardown()`.
2. `teardown()` restores `os.environ["HOME"]` to `orig_home`.
3. `teardown()` SIGTERMs pabrik (then SIGKILLs after 5s).
4. `teardown()` calls `is_safe_tmp()` again as a safety net.
5. If validation passes, `shutil.rmtree(temp_dir)` removes the
   entire tempdir.
6. If validation fails, teardown raises `FunctionalHarnessError`
   and the tempdir is **leaked** (the correct trade-off vs.
   deleting the wrong tree).

## Port allocation

Per project memory "Mandatory: Dont ever kill the process port 8081",
the harness never uses port 8081 (the always-running dev pabrik).

### Random by default

The harness picks a **random** port from a wide range
(`[20000, 32000]`, see `RANDOM_PORT_START` / `RANDOM_PORT_END` in
`harness.py`). The range deliberately sits below Linux's default
`net.ipv4.ip_local_port_range` (32768-60999): the original 40000-60000
window lived inside the kernel's outgoing-source pool, so a port chosen
by a probe bind could be re-allocated before the child bound its real
listener (commit f131e6c4). With 12,000 ports of headroom and 50
attempts per boot, the probability of collision is effectively zero for
any realistic host occupancy.

This replaced the previous sequential scan (`8080, 8082, ..., 8199`)
that caused two recurring CI failures:

  1. **Sequential consumption** — long test suites filled the narrow
     120-port window and later tests errored with
     "No free port found in 8080..8199".
  2. **TIME_WAIT saturation** — even with `SO_REUSEADDR`, a CI runner
     holding 100+ TIME_WAITs could collide with the narrow scan range.

### Legacy sequential path still works

The old sequential scan is preserved as `_find_free_port_sequential`
and triggered only when a caller passes an explicit `start=` (used by
the orphan-reap TIME_WAIT regression test in
`harness_orphan_reap_test.py`). Production boot uses the random path.

### Reserved ports

The random picker skips `(8081,)` by default (the dev backend). The UI
harness extends this to `(5173, 8081)` so vite never lands on its own
default or the dev backend.

### TIME_WAIT reuse

The probe socket sets `SO_REUSEADDR` so it can bind ports in TIME_WAIT
state. pabrik's listener also sets `SO_REUSEADDR` (see
`kabelweb repo src/server/http_server.zig:201 setReuseAddr`),
so it can subsequently bind the same port despite lingering server-side
TIME_WAITs from prior runs.

### Debugging

Pass an explicit port to force a deterministic value::

    FunctionalHarness.boot(pabrik_bin, port=8123)
    # Falls back to the legacy sequential scan from 8123.

For tests that need a specific port, the random pick can be bypassed
by passing `port=` to `FunctionalHarness.boot`.

## Why Python, not bash?

- JSON assertions read like English: `assert r.json()["count"] == 7`.
- SSE is one `for line in response.iter_lines():` loop.
- Cross-platform quoting is uniform (no macOS-vs-Linux bash differences).
- `pytest` gives fixtures for free (no manual `trap cleanup EXIT`).
- The codebase already invokes `python3` from build scripts.

The existing shell smoke tests (`scripts/ci-smoke-test.sh`,
`scripts/design-mode-smoke.sh`) keep working as-is. The Python
harness is the new home for **systematic** functional coverage.

## What's NOT in scope

- **Vue frontend tests** — `bunx vitest run` covers those.
- **Real LLM call coverage** — too costly + flaky for PR-gating.
  The `stub_llm_profile=True` option lets the wire be tested
  without an API key.
- **Performance / load testing** — out of scope for "functional
  correctness".
- **Windows CI** — handled if/when a Windows runner joins the
  matrix; the harness is cross-platform by construction.

## Reference

- Safety guards: top of `tests/functional/harness.py`
- Safety tests: `tests/functional/harness_safety_test.py`
