# Functional Tests

Real-data, isolated-in-`/tmp` end-to-end coverage for nalar. Each test
boots a fresh `nalar` binary against an isolated tempdir HOME, exercises
the HTTP API with non-trivial data, and rmtree's the tempdir on
teardown.

## ⛔ Safety Invariant

**The harness NEVER deletes the developer's real `$HOME`.** Three
defensive layers enforce this:

1. **`is_safe_tmp(path, orig_home)` allow-list validator** — runs
   before every `shutil.rmtree`. Returns True only if the path
   (a) starts with `/tmp/`, `/private/tmp/`, `/private/var/folders/`,
   or `tempfile.gettempdir() + "/"`, AND (b) contains the literal
   substring `nalar-func-`, AND (c) does not resolve to the real
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

### Full suite (requires a built nalar)

```bash
# Option A: use an existing binary
NALAR_BIN=/path/to/nalar pytest tests/functional/

# Option B: build first, then run
zig build install:linux:system
pytest tests/functional/

# Option C: let zig build do everything
zig build functional-test
```

### Single suite

```bash
NALAR_BIN=./zig-out/bin/nalar pytest tests/functional/workspace_lifecycle_test.py -v
```

### Dry-run mode (skip rmtree; useful for debugging)

```bash
NALAR_FUNCTIONAL_DRY_RUN=1 NALAR_BIN=./zig-out/bin/nalar pytest tests/functional/smoke_boot_test.py -v -s
# tempdirs are NOT cleaned up; you can inspect them after the run.
```

### Parallel

```bash
NALAR_BIN=./zig-out/bin/nalar pytest tests/functional/ -n auto
# Each worker gets its own nalar process, its own port, its own tempdir.
```

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
2. `boot()` calls `tempfile.mkdtemp(prefix="nalar-func-")` — a fresh
   dir like `/var/folders/.../T/nalar-func-0v1e3wyf`.
3. `is_safe_tmp()` validates the new path. If it fails, boot
   aborts and the test errors with `FunctionalHarnessError`.
4. `os.environ["HOME"]` is shadowed to the tempdir. The nalar
   process inherits this via `subprocess.Popen(env=...)`.
5. nalar's `helpers.db_path.getDbPath(allocator, io, environment)`
   reads `HOME` from the env and creates `$HOME/.config/nalar/agent.db`
   (Linux) or `$HOME/Library/Application Support/nalar/config.json`
   (macOS). **Both paths land inside the tempdir.**
6. nalar runs all 64 migrations, listens on the chosen port, and
   the test drives the API.

When the test ends:

1. The fixture's `try/finally` calls `h.teardown()`.
2. `teardown()` restores `os.environ["HOME"]` to `orig_home`.
3. `teardown()` SIGTERMs nalar (then SIGKILLs after 5s).
4. `teardown()` calls `is_safe_tmp()` again as a safety net.
5. If validation passes, `shutil.rmtree(temp_dir)` removes the
   entire tempdir.
6. If validation fails, teardown raises `FunctionalHarnessError`
   and the tempdir is **leaked** (the correct trade-off vs.
   deleting the wrong tree).

## Port allocation

Per project memory "Mandatory: Dont ever kill the process port 8081",
the harness never uses port 8081 (the always-running dev nalar).

The harness:
- Defaults to port 8080.
- Skips 8081 explicitly during the scan.
- Scans 8080, 8082, 8083, ..., 8199 and binds the first one that's free.
- Binds+closes to verify the port is free (not just that nothing
  is listening — important for TIME_WAIT reuse).

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

- Plan: `docs/SPEC.md` §3.13 (Testing / Tooling)
- Safety guards: top of `tests/functional/harness.py`
- Safety tests: `tests/functional/harness_safety_test.py`
