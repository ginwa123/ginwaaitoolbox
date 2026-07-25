# Functional Tests With Real Data (Isolated in `tmp`)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

## ⛔ Safety Invariant — Read Before Touching Anything

The functional test harness **NEVER** deletes a path outside an isolated tempdir. This is enforced in three layers; do not weaken any of them without an explicit review:

1. **Captured local var, not env.** The harness captures the tempdir as a Python `pathlib.Path` instance variable on the harness object. Teardown rmtree's THIS attribute, never `os.environ["HOME"]` (which a buggy caller could have re-assigned mid-test).
2. **`is_safe_tmp()` allow-list validator.** Before any rmtree, the harness calls `is_safe_tmp(self.temp_dir, self.orig_home)`. If the path does not (a) start with `/tmp/`, `/private/tmp/`, `/private/var/folders/`, or `tempfile.gettempdir() + "/"`, AND (b) contain the `nalar-func-` substring, AND (c) not equal the real `$HOME`, the harness **refuses to delete** and raises `RuntimeError`. The tempdir is leaked (acceptable); the developer's home is never touched.
3. **`ORIG_HOME` snapshot.** Before `os.environ["HOME"] = self.temp_dir`, the harness saves `orig_home = os.environ["HOME"]`. After teardown it restores. If the binary writes anything outside `$HOME` (e.g., `~/.local/state/nalar/state.json` from the service subcommand), that write still goes to the tempdir.

Three additional defensive rules in every functional test script:

- **No `~` in any path.** All paths are absolute, captured, validated. Any string interpolation that uses `os.path.expanduser()` is banned.
- **`NALAR_FUNCTIONAL_DRY_RUN=1`** env var disables the actual rmtree and prints what WOULD be deleted. Useful for paranoia-debugging a new suite.
- **Pytest `try/finally` in every fixture.** If a test asserts-fail mid-execution, the tempdir is still rmtree'd. If the rmtree itself raises (because validation failed), the test reports the leak rather than masking it.

If you find a code path that bypasses these guards, fix it before merging. A test that deletes `/Users/<developer>` is a P0 incident.

## Goal

Add a **functional test harness** that exercises the real `nalar` HTTP API against non-trivial, realistic data — but with every byte of state (DB, config, on-disk design files, attachments) living in a fresh, per-test tempdir under `/tmp/nalar-func-*`. No `:memory:` DBs. No mocks. No `unimplemented!` stubs. The harness must:

1. Boot a freshly-built `nalar` binary against `HOME=$temp_dir` (so all 64 migrations run, all GinwaServer handlers are wired, all on-disk side-effects happen for real).
2. Drive the API with non-trivial payloads (5–30 items per workspace, multi-page designs, multi-column kanbans with cross-column task moves).
3. Tear down the tempdir on success **or** failure — but never delete anything that fails `is_safe_tmp()`.
4. Run in CI on Linux + macOS self-hosted runners.
5. Take ≤ 5 minutes wall-clock for the full suite (15–25 suites, 5–10s each).

## Architecture

**Python 3.10+ + pytest.** Single shared harness module (`tests/functional/harness.py`) provides a `FunctionalHarness` class with a `boot()` classmethod that returns a ready-to-use instance, an `http()` method for typed API calls, and a `teardown()` method that rmtree's the isolated tmpdir. Each suite is a `tests/functional/<feature>_test.py` file with pytest fixtures and `def test_<scenario>()` functions.

**Why Python over bash:**
- JSON assertions read like English (`assert r.json()["count"] == 7` vs `assert_eq "$(echo "$BODY" | jq -r .count)" "7"`).
- SSE is one `for line in response.iter_lines():` loop, not a curl-and-awk hack.
- Cross-platform quoting is uniform (no macOS-vs-Linux bash differences on `[[ ]]` vs `[ ]`).
- `pytest` gives fixtures for free — no manual `trap cleanup EXIT` bookkeeping.
- The codebase already invokes `python3` from build scripts (`scripts/fetch-vendor-sqlite3.sh` uses `python3 -m zipfile`); a `requirements.txt` is cheap.

**Why one process per test (not one shared process across all tests):**
- Isolation: each test gets a fresh `$HOME` + fresh DB + fresh port. No state pollution between tests.
- Parallelism: `pytest -n auto` (via `pytest-xdist`) runs N processes in parallel; no shared state to reason about.
- Failure clarity: a crash in one test does not leave a zombie nalar poisoning the next test's `/tmp`.

**Port management:** harness picks the first free port starting from 8080 (per project memory: NEVER 8081, the always-running dev port). Default test port 8080; if busy, scan 8082–8199.

**Build integration:** a new `zig build functional-test` step that (1) builds `nalar` via `install:linux:system`, (2) invokes `python3 -m pytest tests/functional/`. Fails if any test fails.

**CI integration:** a new step in `.github/workflows/ci.yml` after the existing `Smoke test: criteria pass` step, gated on the same `matrix.target.step != '__SKIP__'`.

## Tech Stack

- **Python 3.10+** (stdlib `urllib`, `tempfile`, `subprocess`, `pathlib`, `json` — no `requests` dep needed for the basic path)
- **`pytest`** (fixtures, parametrization, tmp_path integration)
- **`pytest-xdist`** (parallel test execution, `-n auto`)
- **`sseclient-py`** (only for Chunk 7 — SSE end-to-end coverage; not a baseline dep)
- **`zig` 0.16** (the binary under test)

## File Structure

### New files (production test infra)
- `tests/functional/__init__.py` — empty, marks the dir as a Python package so pytest discovery is consistent.
- `tests/functional/harness.py` — `FunctionalHarness` class + `is_safe_tmp()` validator + `FunctionalHarnessError` exception type. ~250 lines.
- `tests/functional/conftest.py` — shared pytest fixtures (`default_nalar_bin`, `free_port_pool`). ~50 lines.
- `tests/functional/requirements.txt` — `pytest>=7`, `pytest-xdist>=3`, `sseclient-py>=1.8`. Pinned.
- `tests/functional/README.md` — how to run locally, how to add a new suite, how the safety guards work.
- `tests/functional/_scratch/` — gitignored; suites can write intermediate fixtures here if needed.

### New files (test suites — one per feature area)
- `tests/functional/workspace_lifecycle_test.py` — CRUD + reorder + cascade-delete (Chunk 3)
- `tests/functional/kanban_lifecycle_test.py` — item create + 3 default cols + add col + add task + move + delete cascade (Chunk 4)
- `tests/functional/design_lifecycle_test.py` — page CRUD + element CRUD + on-disk HTML file verification + geometry PATCH (Chunk 5)
- `tests/functional/memories_skills_test.py` — global + local memories + skills CRUD (Chunk 6)
- `tests/functional/sessions_and_llm_test.py` — session create/list/messages without LLM (use a stub profile), `/test/shutdown` (Chunk 7)
- `tests/functional/sse_endtoend_test.py` — open `/api/events` EventSource, trigger an event, assert it arrives within 1s (Chunk 8)

### Modified files
- `build.zig` — add `functional_test` step (depends on `install:linux:system`, invokes `python3 -m pytest`).
- `.gitignore` — add `tests/functional/_scratch/` and `.pytest_cache/`.
- `.github/workflows/ci.yml` — new "Functional tests: real-data isolation suites" step (Chunk 9).
- `scripts/fetch-vendor-sqlite3.sh` (or a new `scripts/setup-python-env.sh`) — install Python deps on CI runners.

### Total delta
- ~400 LoC harness infra (harness.py + conftest.py + README)
- ~1200 LoC test suites (6 suites × ~200 LoC)
- ~30 LoC build.zig + ~30 LoC CI yaml changes

---

## Chunk 1: The Harness (with safety guards baked in)

> **Why Chunk 1:** everything else depends on `FunctionalHarness`. The safety guards (`is_safe_tmp`, ORIG_HOME snapshot, dry-run mode) live in this file. Getting them wrong is a P0 incident.

### Task 1.1: Create `tests/functional/__init__.py`

Empty file. Marks the dir as a Python package.

### Task 1.2: Create `tests/functional/harness.py`

The full module. Sections, in order:

**A. Safety constants (top of file, with a giant banner comment):**

```python
# ============================================================================
# ⛔ SAFETY INVARIANTS — DO NOT WEAKEN WITHOUT REVIEW ⛔
#
# 1. is_safe_tmp(path, orig_home) is the single source of truth for "may
#    this path be deleted by the harness". ANY rmtree call MUST be
#    gated by it. There is no second code path.
#
# 2. The harness NEVER calls os.environ["HOME"] inside teardown. It
#    uses the captured `self.temp_dir` attribute, which is set once
#    at boot and not subject to mid-test env mutation.
#
# 3. The harness NEVER uses ~, expanduser, or relative paths. All
#    paths are absolute.
#
# 4. If is_safe_tmp() returns False, teardown RAISES instead of
#    deleting. The tempdir is leaked; the developer's home is never
#    touched. This is the correct trade-off.
# ============================================================================

ALLOWED_TMP_PREFIXES: tuple[str, ...] = (
    "/tmp/",
    "/private/tmp/",
    "/private/var/folders/",
    "/var/folders/",
    tempfile.gettempdir() + "/",
)
REQUIRED_TMP_SUBSTR = "nalar-func-"
```

**B. `is_safe_tmp()` validator:**

```python
def is_safe_tmp(path: str, orig_home: str) -> bool:
    """Return True iff `path` is a tmpdir the harness is allowed to rmtree.

    Returns False for: empty strings, non-absolute paths, paths outside
    the allow-list of tmpdir prefixes, paths missing the nalar-func-
    substring, paths that resolve to the real $HOME, and paths whose
    realpath resolves outside any allowed prefix (e.g. symlinks to
    ~/<something>).
    """
    if not path:
        return False
    real = os.path.realpath(path)
    if not real.startswith(ALLOWED_TMP_PREFIXES):
        return False
    if REQUIRED_TMP_SUBSTR not in real:
        return False
    if real == os.path.realpath(orig_home):
        return False
    return True
```

**C. `FunctionalHarnessError`** (custom exception, easy to catch in fixtures).

**D. `Response` dataclass** wrapping `(status: int, body: bytes)` with a `json()` helper.

**E. `FunctionalHarness` dataclass** with the API surface:

```python
@dataclass
class FunctionalHarness:
    port: int
    nalar_bin: Path
    temp_dir: Path
    orig_home: str
    log_path: Path
    pid: int | None = None
    dry_run: bool = False

    @classmethod
    def boot(cls, nalar_bin: Path | None = None, *,
             port: int = 8080,
             ready_timeout_s: float = 30.0) -> "FunctionalHarness":
        # 1. Snapshot HOME before we shadow it.
        orig_home = os.environ.get("HOME", "")
        if not orig_home:
            raise FunctionalHarnessError(
                "HOME not set; refusing to boot. "
                "Functional tests must run in a normal user shell."
            )

        # 2. Pick a free port (default 8080, scan 8082-8199).
        chosen_port = _find_free_port(port)

        # 3. mkdtemp. Returns a fresh, never-before-existing dir.
        temp_dir = Path(tempfile.mkdtemp(prefix=REQUIRED_TMP_SUBSTR))

        # 4. Validate BEFORE shadowing HOME.
        if not is_safe_tmp(str(temp_dir), orig_home):
            raise FunctionalHarnessError(
                f"mkdtemp produced an unsafe path: {temp_dir}\n"
                f"Expected prefix in {ALLOWED_TMP_PREFIXES}\n"
                f"With substring {REQUIRED_TMP_SUBSTR!r}\n"
                f"Refusing to proceed; tempdir leaked."
            )

        # 5. Resolve nalar binary.
        bin_path = nalar_bin or _default_nalar_bin()
        if not bin_path.exists() or not os.access(bin_path, os.X_OK):
            raise FunctionalHarnessError(f"nalar binary not executable: {bin_path}")

        # 6. Spawn. start_new_session=True so we can killpg later.
        log_path = temp_dir / "nalar.log"
        env = os.environ.copy()
        env["HOME"] = str(temp_dir)
        proc = subprocess.Popen(
            [str(bin_path), "--port", str(chosen_port)],
            stdout=log_path.open("wb"),
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )

        # 7. Wait for readiness (poll /health).
        try:
            _wait_ready(chosen_port, ready_timeout_s, proc, log_path)
        except Exception:
            proc.kill()
            raise

        return cls(
            port=chosen_port, nalar_bin=bin_path, temp_dir=temp_dir,
            orig_home=orig_home, log_path=log_path,
            pid=proc.pid, dry_run=os.environ.get("NALAR_FUNCTIONAL_DRY_RUN") == "1",
        )

    def http(self, method: str, path: str, *,
             json_body: dict | None = None,
             params: dict | None = None,
             expect: int | tuple[int, ...] = 200) -> Response:
        # urllib-based, no external deps. Returns Response.
        # Asserts status matches expect; raises AssertionError with body
        # excerpt on mismatch.

    def teardown(self) -> None:
        # 1. Restore HOME first.
        os.environ["HOME"] = self.orig_home
        # 2. Kill the binary (SIGTERM, then SIGKILL fallback).
        # 3. Validate temp_dir with is_safe_tmp(); raise if False.
        # 4. shutil.rmtree(self.temp_dir) — or skip if dry_run.
```

**F. Helper functions:**
- `_find_free_port(start: int) -> int` — bind to `127.0.0.1:start`, close, return; loop until success or hit 8199.
- `_default_nalar_bin() -> Path` — checks `$ZIG_OUT_BIN/nalar`, then `./zig-out/bin/nalar`, then `./zig-out/bin/nalarcore-linux-x86_64`. First hit wins.
- `_wait_ready(port, timeout, proc, log_path)` — poll `/health` every 100ms; surface proc returncode + log on failure.

### Task 1.3: Verify the safety guards actually work

Three negative tests, run BEFORE any other suite (would be a P0 if they regress):

- [ ] `test_is_safe_tmp_rejects_empty_string` — `is_safe_tmp("", "/home/x") is False`.
- [ ] `test_is_safe_tmp_rejects_real_home` — `is_safe_tmp("/home/alice", "/home/alice") is False`.
- [ ] `test_is_safe_tmp_rejects_symlink_to_home` — create a symlink `/tmp/nalar-func-sneaky` → `/home/alice`; assert `is_safe_tmp` returns False (the `os.path.realpath` check catches it).
- [ ] `test_is_safe_tmp_accepts_valid_tmpdir` — `mkdtemp(prefix="nalar-func-")` then `is_safe_tmp` returns True.
- [ ] `test_teardown_refuses_unsafe_path` — manually construct a harness with `temp_dir=Path("/home/alice")`; assert `teardown()` raises `FunctionalHarnessError` and does NOT delete `/home/alice` (assert by `os.path.exists` after).

These five tests live in `tests/functional/harness_safety_test.py`. They run with no nalar binary required — pure unit tests.

### Verification for Chunk 1

```bash
cd /Users/ginwa/ginwaaitoolbox
python3 -m venv .venv-func
source .venv-func/bin/activate
pip install -r tests/functional/requirements.txt
python3 -m pytest tests/functional/harness_safety_test.py -v
# Expect: 5 passed.
```

`harness_safety_test.py` is intentionally the ONLY test that can run without a built `nalar` binary. All other suites depend on `install:linux:system` having produced `zig-out/bin/nalar`.

---

## Chunk 2: Build Target + `conftest.py`

### Task 2.1: `tests/functional/conftest.py`

```python
import os
import pytest
from pathlib import Path
from harness import FunctionalHarness

@pytest.fixture(scope="session")
def default_nalar_bin() -> Path:
    """Resolve the nalar binary once per test session."""
    candidates = [
        os.environ.get("NALAR_BIN"),
        "./zig-out/bin/nalar",
        "./zig-out/bin/nalarcore-linux-x86_64",
        "./zig-out/bin/nalarcore-macos-aarch64",
    ]
    for c in candidates:
        if c and Path(c).exists():
            return Path(c).resolve()
    pytest.skip(f"No nalar binary found. Run `zig build install:linux:system` first.")

@pytest.fixture
def harness(default_nalar_bin) -> FunctionalHarness:
    """Boot a fresh nalar per test. Teardown runs even on assertion failure."""
    h = FunctionalHarness.boot(default_nalar_bin)
    try:
        yield h
    finally:
        h.teardown()
```

Note the `try/finally` — this is the second line of defense (the first is `is_safe_tmp` inside `teardown`). If `yield` raises an `AssertionError` mid-test, `teardown()` still runs.

### Task 2.2: `tests/functional/requirements.txt`

```
pytest>=7.4,<9
pytest-xdist>=3.3,<4
sseclient-py>=1.8,<2
```

### Task 2.3: `build.zig` — add `functional-test` step

```zig
const functional_test_step = b.step("functional-test", "Run functional tests against a real nalar with isolated tmpdir data");
const python_path = b.option([]const u8, "python", "Path to python3 binary (default: 'python3')") orelse "python3";
const functional_test_cmd = b.addSystemCommand(&.{
    python_path, "-m", "pytest", "tests/functional/", "-v", "--tb=short",
});
functional_test_cmd.setCwd(b.path(""));
functional_test_cmd.step.dependOn(&linux_system_step);  // ensures nalar binary exists
functional_test_step.dependOn(&functional_test_cmd.step);
```

The step depends on `install:linux:system` so the binary exists. Users run `zig build functional-test` and get a passing/failing test report.

### Task 2.4: `tests/functional/README.md`

~50 lines. Documents:
- How to run: `zig build functional-test` (full suite) or `pytest tests/functional/workspace_lifecycle_test.py -v` (single suite).
- The safety invariant (link to the top of `harness.py`).
- The "real data" requirement: suites must create ≥ 5 items, ≥ 30 tasks, ≥ 10 elements — not minimal seeds.
- How to add a new suite: copy `workspace_lifecycle_test.py` as a template.
- How to debug a flake: `NALAR_FUNCTIONAL_DRY_RUN=1` prints what would be deleted.

### Verification for Chunk 2

```bash
cd /Users/ginwa/ginwaaitoolbox
zig build install:linux:system
zig build functional-test --summary all
# Expect: 5 passed (just harness_safety_test, other suites not yet added).
```

---

## Chunk 3: Workspace Lifecycle Functional Test

> **Why Chunk 3 first:** every other suite depends on workspaces existing. Get this one right and you have the template for the rest.

### Task 3.1: `tests/functional/workspace_lifecycle_test.py`

Coverage (each is a `def test_*()` function, 8 tests total):

1. `test_create_workspace_returns_201_with_id` — POST `/api/workspaces {"name":"functional-test"}` → 201, response has `.id` starting with `ws_`.
2. `test_list_workspaces_returns_created` — POST one, GET `/api/workspaces`, assert count == 1 and the id matches.
3. `test_create_workspace_rejects_empty_name` — POST `{"name":""}` → 400.
4. `test_create_workspace_rejects_missing_name` — POST `{}` → 400.
5. `test_update_workspace_name` — POST, then PUT `/api/workspaces/<id> {"name":"renamed"}` → 200, GET shows new name.
6. `test_create_seven_items_in_workspace` — POST 7 items of mixed types (3 chat, 2 kanban, 2 design), GET `/api/workspaces/<id>/items` → 7 items returned.
7. `test_delete_workspace_cascades_to_items` — POST workspace + 3 items, DELETE workspace, GET items → 0 (cascade).
8. `test_reorder_workspaces_changes_position` — POST 3 workspaces, POST `/api/workspaces/reorder {"order":[id3,id2,id1]}`, GET → workspaces come back in [id3,id2,id1] order.

Each test is ~15–25 lines. Total file: ~200 lines.

### Task 3.2: Static-contract test that the suite actually exists

Add to `tests/functional/_static_test.py`:

```python
def test_workspace_suite_exists():
    p = Path(__file__).parent / "workspace_lifecycle_test.py"
    assert p.exists(), f"workspace_lifecycle_test.py missing at {p}"
```

This catches the "deleted the suite file by accident" failure mode. Run via `zig build functional-test`.

### Verification for Chunk 3

```bash
zig build functional-test
# Expect: 5 (safety) + 1 (static) + 8 (workspace) = 14 passed.
```

---

## Chunk 4: Kanban Lifecycle Functional Test

Mirrors `workspace_lifecycle_test.py` shape. Coverage (10 tests):

1. `test_create_kanban_seeds_three_default_columns` — POST `/api/workspaces/<w>/items/kanban {"name":"sprint"}` → 201; GET `/.../kanban/columns` → 3 columns (todo/in-progress/done).
2. `test_add_fourth_column` — POST `/.../kanban/columns {"name":"backlog","position":0}` → 201; columns list now has 4 items, "backlog" first.
3. `test_add_twelve_tasks_across_columns` — POST 12 tasks spread across the 4 columns (3 per column). Each task gets a unique name.
4. `test_move_task_across_columns_updates_parent` — POST task under col-A, PATCH `/.../tasks/<t>/move {"column_id":"col-B"}` → 200; GET column-B → task present, GET column-A → task absent.
5. `test_move_task_to_same_column_is_noop` — same move twice; second response 200, no DB churn (verify by counting list length before/after).
6. `test_delete_column_moves_tasks_to_first_column` — DELETE column-3 (with 3 tasks); those tasks now appear under column-1 (cascade behavior per `kanban_columns_delete.zig`).
7. `test_pin_task_makes_it_appear_first` — POST task, POST `/.../tasks/<t>/pin` → 200; GET `/.../tasks` shows it first.
8. `test_task_attachment_upload_and_download_round_trip` — POST a small text attachment, GET it back, byte-equal.
9. `test_copy_spec_from_kanban_replaces_columns` — create kanban-A with 4 cols, kanban-B with 1 col; POST `/.../kanban/copy_spec_from/A {"mode":"replace"}` → 200; B now has 4 cols.
10. `test_delete_kanban_item_removes_columns_and_tasks` — DELETE the kanban item → 200; subsequent GET on columns → 404 or empty.

### Verification for Chunk 4

```bash
zig build functional-test
# Expect: 14 (prior) + 10 (kanban) = 24 passed.
```

---

## Chunk 5: Design Lifecycle Functional Test

> **The on-disk HTML files are the differentiator.** This chunk is the one that catches regressions where the DB row updates but the `<item>/.nalar/design/<page>/<element>.html` file is missing or stale.

Coverage (12 tests):

1. `test_create_design_item_requires_path` — POST `/items {"item_type":"design"}` (no path) → 400 (`ItemPathMissing`).
2. `test_create_page_with_three_elements` — POST page, POST 3 elements (rectangle, text, ellipse), GET page → 3 elements present.
3. `test_element_html_file_written_to_disk` — POST element with `html="<p>hi</p>"`; assert file exists at `<item_path>/.nalar/design/<page>/<element>.html`; assert content byte-equal to `html`.
4. `test_update_html_atomically_rewrites_file` — PUT element with new `html`; assert file content matches new html (atomic write — no leftover content from old version).
5. `test_geometry_patch_does_not_touch_html` — PATCH `/.../elements/<e>/geometry {"x":99}` → 200; assert HTML file unchanged (byte-for-byte).
6. `test_delete_element_removes_html_file` — DELETE element; assert file gone (not orphaned).
7. `test_delete_page_removes_entire_directory` — POST page with 2 elements (each with HTML), DELETE page → 200; assert the entire `.nalar/design/<page>/` directory is gone.
8. `test_get_html_returns_stored_content` — round-trip: POST element with multi-line HTML, GET `/.../html` returns it intact.
9. `test_sanitize_filename_handles_slashes` — POST element `name="login/card"` → element is created with sanitized name (no `/` in the on-disk filename).
10. `test_design_pages_list_groups_by_item` — POST 2 design items with 2 pages each; GET `/items/<i1>/design/pages` returns 2, same for i2 — no cross-item leakage.
11. `test_corrupt_html_file_recovers_on_update` — manually delete the HTML file for an element; PUT element with new `html` → 200, file recreated (per `update_element.zig`'s "orphan file is recreated automatically" behavior).
12. `test_geometry_throttle_handles_60_patches_per_sec` — fire 60 PATCH `/geometry` calls in 1 second; assert all return 200 and the final position matches the last patch.

### Verification for Chunk 5

```bash
zig build functional-test
# Expect: 24 (prior) + 12 (design) = 36 passed.
```

---

## Chunk 6: Memories + Skills CRUD Functional Test

Coverage (8 tests):

1. `test_create_global_memory` — POST `/api/memories {"name":"foo","content":"bar"}` → 201, file at `$temp_dir/.config/nalar/memories/foo.md`.
2. `test_list_memories_returns_created` — POST 3, GET → 3.
3. `test_update_memory_overwrites_file` — POST, PUT with new content, assert file content matches.
4. `test_delete_memory_removes_file` — DELETE, assert file gone.
5. `test_create_local_memory_under_cwd` — POST `/api/local-memories {"name":"x","content":"y","cwd":"<temp_subdir>"}` → file at `<temp_subdir>/.nalar/memories/x.md`.
6. `test_skill_create_list_delete` — POST skill → 201, GET → present, DELETE → 200, GET → absent.
7. `test_skill_create_rejects_empty_name` — POST `{"name":"","content":"..."}` → 400.
8. `test_memory_and_skill_namespaces_dont_collide` — POST memory `{"name":"foo"}` and skill `{"name":"foo"}` → both succeed (separate tables).

### Verification for Chunk 6

```bash
zig build functional-test
# Expect: 36 + 8 = 44 passed.
```

---

## Chunk 7: Sessions + `/test/shutdown` Without an LLM

> **The trick:** nalar refuses to start LLM calls without a profile in `config.json`. We pre-create a stub profile in the tempdir's `$HOME/.config/nalar/config.json` before boot.

### Task 7.1: Stub config helper in `harness.py`

Add `FunctionalHarness.boot(..., stub_llm_profile: bool = False)`:

```python
if stub_llm_profile:
    config_dir = temp_dir / ".config" / "nalar"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "config.json").write_text(json.dumps({
        "profiles_models": {
            "stub": {
                "model": "stub-model",
                "base_url": "http://127.0.0.1:1",  # never reachable
                "api_key": "stub-key",
            },
        },
        "selected_profile_model": "stub",
    }))
```

`base_url` points to a port that never responds — session create will fail when it tries to call the LLM, but session list/get/messages work without an LLM.

### Task 7.2: `tests/functional/sessions_and_llm_test.py`

Coverage (6 tests):

1. `test_health_endpoint_returns_ok` — GET `/health` → 200, `{"status":"ok"}`.
2. `test_session_create_returns_session_id` — POST `/api/llm/session {"session_name":"test"}` → 201, `.id` starts with `task_` (per the `task.id == session_id` convention).
3. `test_session_list_includes_created` — POST 3 sessions, GET `/api/llm/session` → 3.
4. `test_session_messages_empty_for_new_session` — POST session, GET `/api/llm/session/<id>/messages` → 200, body has `messages: []`.
5. `test_test_shutdown_endpoint_stops_server` — POST `/test/shutdown` → 200; next HTTP request returns connection-refused (the server actually shut down). Then `teardown()` runs and is a no-op for the kill step.
6. `test_no_state_leaked_to_real_home` — assert `$HOME/.config/nalar/agent.db` does NOT exist (i.e., the real developer's home was untouched). Belt-and-suspenders for the safety invariant.

### Verification for Chunk 7

```bash
zig build functional-test
# Expect: 44 + 6 = 50 passed.
```

---

## Chunk 8: SSE End-to-End Functional Test

> **Why a separate chunk:** SSE is the project's trickiest wire (see project memory "SSE `net::ERR_INCOMPLETE_CHUNKED_ENCODING`"). A functional test that opens `/api/events`, triggers a DB write, and asserts the SSE event arrives catches the class of "SSE silently dead" bugs.

### Task 8.1: `tests/functional/sse_endtoend_test.py`

Uses the `sseclient-py` library (added to `requirements.txt` in Chunk 2).

Coverage (5 tests):

1. `test_sse_handshake_returns_200` — GET `/api/events` with `Accept: text/event-stream` → 200, headers include `Content-Type: text/event-stream`.
2. `test_sse_connected_event_fires_on_subscribe` — open EventSource, first event is `event: connected` with `data: {...}` JSON.
3. `test_design_create_emits_sse_event` — open EventSource in a thread, POST design page → event `event: design_page` arrives within 1s.
4. `test_kanban_move_emits_sse_event` — open EventSource, PATCH `/.../tasks/<t>/move` → `event: kanban_task` arrives within 1s.
5. `test_sse_drops_quietly_when_client_closes` — open EventSource, close it, nalar does not crash (verify by POSTing a workspace afterward → still 201).

### Verification for Chunk 8

```bash
zig build functional-test
# Expect: 50 + 5 = 55 passed.
```

---

## Chunk 9: CI Wiring

### Task 9.1: `.github/workflows/ci.yml` — new step

Insert after the existing `Smoke test: criteria pass` step (line 297):

```yaml
- name: "Functional tests: real-data isolation suites"
  if: matrix.target.step != '__SKIP__'
  shell: bash
  # Same isolation pattern as the smoke test: per-run tempdir, fresh
  # nalar binary, all suites run in sequence (or xdist-parallel).
  #
  # The Python harness enforces the "never delete real $HOME"
  # invariant via is_safe_tmp(); see tests/functional/harness.py.
  #
  # Time budget: 5 min wall-clock for 55 tests × ~5s each.
  run: |
    set -u
    python3 -m venv /tmp/nalar-func-venv-$$
    source /tmp/nalar-func-venv-$$/bin/activate
    pip install -r tests/functional/requirements.txt
    rm -rf /tmp/nalar-func-venv-$$
    zig build functional-test
```

The CI runner has Python 3.11+ on both Linux and macOS self-hosted images. The venv is created in `/tmp/` (matching the safety allow-list) and rm'd via the `/tmp/nalar-func-venv-$$` pattern that the Python harness wouldn't touch (it's an external cleanup, not the harness).

Wait — the venv cleanup uses `rm -rf /tmp/nalar-func-venv-$$`. This is NOT going through the Python harness. That's fine for CI (CI is ephemeral), but **must not be replicated in any local development script without the same is_safe_tmp guard**. Add a comment to that effect in the yaml.

### Task 9.2: Document the new step in `docs/ci.md`

Append to the existing `docs/ci.md` (if it exists; otherwise create). Section: "Functional tests". Notes:
- The safety invariant (link to `harness.py` top comment).
- The 5-min budget.
- How to debug a failure locally: `zig build install:linux:system && python3 -m pytest tests/functional/<suite>.py -v`.

### Verification for Chunk 9

After merge: trigger CI on the PR, confirm the new step runs and reports `55 passed` in ~5 minutes.

---

## Out of Scope (Deliberate)

- **Frontend (Vue) functional tests.** The `bunx vitest run` already covers the Vue layer. Mixing it with the Python harness adds cross-stack complexity for marginal value. The `desktop-frontend-build` skill already covers Vue test patterns.
- **LLM call coverage.** Requires a real API key in CI (cost + flakiness). The "stub profile" in Chunk 7 lets us test the wire without the LLM. Real LLM coverage belongs in a separate `llm-integration-test` job that runs on-demand, not on every PR.
- **Cross-platform Windows runs in CI.** The Linux + macOS CI matrix is what matters; Windows runs are added if/when a self-hosted Windows runner joins the matrix. The Python harness is cross-platform by construction.
- **`zig build test` integration.** Functional tests are too slow to mix with unit tests; they live in their own build step (`zig build functional-test`).
- **Performance / load testing.** Out of scope for "functional correctness". A future `tests/load/` could use `locust` or `k6` if needed.

---

## Verification (Project-Level)

After all 9 chunks land:

```bash
cd /Users/ginwa/ginwaaitoolbox
rm -rf zig-out/bin
timeout 360 zig build install:linux:system  # builds nalar
timeout 360 zig build functional-test       # runs the 55 functional tests
# Expect: "55 passed in 4m32s"

# CI verification:
gh pr create --fill
gh pr checks   # wait for "Functional tests: real-data isolation suites" to pass
```

Cross-check the safety invariant one more time:

```bash
# Before any functional test, the developer's home is untouched:
ls -la ~/.config/nalar/   # shows only the user's real config.json + agent.db
# After running the suite:
ls -la ~/.config/nalar/   # SAME files, SAME sizes — no leak from the tempdir
```

The harness has done its job if the developer cannot tell that 55 functional tests just ran on their machine.

---

## Reference

- **Smoke test precedent:** `scripts/ci-smoke-test.sh` (boots nalar against `mktemp -d` HOME; same `mktemp` pattern the Python harness uses).
- **Safety invariants:** top of `tests/functional/harness.py` (this plan's Chunk 1.2).
- **Project memory "Mandatory: Dont ever kill the process port 8081":** the harness uses port 8080 by default, never 8081.
- **Project memory "SSE `net::ERR_INCOMPLETE_CHUNKED_ENCODING`":** Chunk 8's SSE test catches the class of bugs described there.
- **Project memory "Smoke testing on port 8080 (NEVER 8081)":** ditto.
- **Related plan:** `docs/superpowers/plans/2026-07-08-design-mode-redesign.md` (the design API surface this plan's Chunk 5 exercises).
