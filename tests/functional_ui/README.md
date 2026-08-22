# Functional UI Tests

Real-data, isolated-in-`/tmp` end-to-end coverage for the nalar **web
app** — boots a real `nalar` backend AND a real Vite dev server, then
drives the running UI with [Playwright Python](https://playwright.dev/python/).

Mirrors the isolation guarantees of the sibling `tests/functional/`
suite — the developer's real `$HOME` is never touched.

## ⛔ Safety Invariant

Same as `tests/functional/`:

1. **`is_safe_tmp(path, orig_home)` allow-list validator** — runs
   before any `shutil.rmtree`. The UI harness delegates ALL rmtree to
   `FunctionalHarness.teardown`, which is gated by this validator.
2. **Captured `Path` attribute, not `$HOME`** — `h.temp_dir` is set
   once at boot. Teardown rmtree's THIS attribute.
3. **`ORIG_HOME` snapshot + restore** — captured at boot, restored in
   teardown's first step.

The new dimension for the UI suite:

4. **Vite proxy target is per-test** — `vite.config.ts` reads
   `VITE_API_PROXY_TARGET` from the env; the harness sets it to
   `http://127.0.0.1:<backend_port>` so the running web app talks to
   the TEST backend, not the developer's always-on `:8081`.
5. **Cross-platform isolation** (macOS, Linux, Windows):
   - `is_safe_tmp` is OS-aware (Windows uses native backslash prefix).
   - npm is resolved via `shutil.which("npm") or shutil.which("npm.cmd")`.
   - Vite signal handling uses `os.killpg` on POSIX, `os.kill` on Windows.

See `harness_safety_test.py` for 11 cross-platform safety tests.
**If any of them fail, the harness has a P0 bug — do not merge.**

## Running

### One-time setup

```bash
# Install Python deps (including playwright).
pip install -r tests/functional_ui/requirements.txt

# Download Chromium binary (~150 MB to ~/.cache/ms-playwright).
playwright install chromium
```

### Quick smoke (no binary required)

```bash
PYTHONPATH=tests/functional:. pytest tests/functional_ui/harness_safety_test.py -v
# Expect: 11 passed.
```

### Full suite (requires a built nalar + Playwright Chromium)

```bash
# Option A: use an existing binary
NALAR_BIN=/path/to/nalar pytest tests/functional_ui/

# Option B: let zig build do everything
zig build functional-test-ui
```

### Single suite

```bash
NALAR_BIN=./zig-out/bin/nalar pytest tests/functional_ui/kanban_lifecycle_ui_test.py -v
```

### Dry-run mode (skip rmtree; useful for debugging)

```bash
NALAR_FUNCTIONAL_DRY_RUN=1 NALAR_BIN=./zig-out/bin/nalar pytest tests/functional_ui/smoke_boot_test.py -v -s
# tempdirs are NOT cleaned up; you can inspect them after the run.
```

### Parallel

```bash
NALAR_BIN=./zig-out/bin/nalar pytest tests/functional_ui/ -n auto
# Each worker gets its own nalar + Vite, its own ports, its own tempdir.
```

## Adding a new suite

1. Create `tests/functional_ui/<feature>_ui_test.py`.
2. Use the `ui_harness` and `page` fixtures from `conftest.py`. They
   provide a fresh `UIHarness` + Playwright `Page` per test.
3. Write `def test_<scenario>()` functions. Each test is a fresh
   backend + Vite boot (~5-10s for nalar, +5-15s for Vite's first
   compile) plus ~10s of UI interaction.
4. Drive the UI with Playwright's locators (see Playwright's
   [locator docs](https://playwright.dev/python/docs/locators)). Prefer
   semantic locators (`get_by_role`, `get_by_text`) over CSS selectors
   so tests survive small DOM refactors.
5. Use non-trivial data: ≥ 5 items per workspace, ≥ 30 tasks across
   kanban columns. The point is to exercise real shapes.
6. Verify locally with
   `pytest tests/functional_ui/<your>_ui_test.py -v`.
7. No build-side registration needed — pytest auto-discovers files
   matching `*_test.py` in the test directory.

## Test anatomy

```python
def test_create_kanban_task_via_ui(ui_harness: UIHarness, page) -> None:
    h = ui_harness
    # 1. Pre-create workspace + kanban via the API (faster than UI)
    ws_id = h.http("POST", "/api/workspaces", json_body={"name": "x"}, expect=201).json()["id"]
    kanban_id = h.http("POST", f"/api/workspaces/{ws_id}/items/kanban",
                       json_body={"name": "sprint"}, expect=201).json()["item"]["id"]

    # 2. Drive the UI to create a task
    page.goto(h.web_url(f"/w/{ws_id}/k/{kanban_id}"))
    page.get_by_role("button", name="Add task").click()
    page.get_by_placeholder("Task title").fill("first task")
    page.keyboard.press("Enter")

    # 3. Verify via API (more reliable than DOM scraping)
    tasks = h.http("GET", f"/api/workspaces/{ws_id}/items/{kanban_id}/kanban/tasks").json()["tasks"]
    assert any(t["name"] == "first task" for t in tasks)
```

## How isolation works

When a test starts:

1. `UIHarness.boot()` runs.
2. `FunctionalHarness.boot()` boots nalar against an isolated tmpdir HOME.
3. `UIHarness.boot()` then resolves the frontend source tree (default:
   `src/apps/desktop/`) and spawns `npm run dev -- --port <vite_port>`.
4. The env var `VITE_API_PROXY_TARGET=http://127.0.0.1:<backend_port>`
   is set so Vite's `/api/*` proxy targets the test backend.
5. Vite's HTTP root is polled until it returns 200 (~5-15s for first
   build, faster on warm cache).
6. Playwright opens a fresh browser context, navigates to `h.web_url("/")`,
   and drives the running Vue app.

When the test ends:

1. The fixture's `try/finally` calls `h.teardown()`.
2. `teardown()` stops Vite first (so the frontend stops proxying).
3. `teardown()` stops the backend (via `FunctionalHarness.teardown`).
4. `FunctionalHarness.teardown()` restores HOME, validates the tempdir
   with `is_safe_tmp()`, and rmtree's it.
5. Screenshots taken on failure are saved to
   `tests/functional_ui/artifacts/<test_name>/<timestamp>.png` —
   these are SEPARATE from the tempdir and survive the run.

## Port allocation

Per project memory "Don't ever kill the process port 8081":

| Service  | Range      | Notes                                    |
|----------|------------|------------------------------------------|
| Backend  | 8080, 8082–8199 | Skips 8081 (dev port)                |
| Vite     | 5180–5299  | Skips 5173 (Vite's default) and 8081     |

The harness scans each range and binds+closes to verify the port is
free (not just that nothing is listening — important for TIME_WAIT
reuse).

## Why Playwright, not just HTTP?

- Real browser = real DOM = real Vue reactivity. An HTTP-only test
  can pass while a broken CSS rule makes the UI unusable.
- Playwright's locator API is resilient to small DOM refactors
  (`get_by_role("button", name="...")` survives class-name churn).
- Screenshots on failure give a post-mortem without manual repro.
- The same suite can be extended later to test Monaco editor,
  drag-and-drop, file uploads, etc. — anything that needs a real
  browser.

## What's NOT in scope

- **Vitest component tests** — `bunx vitest run` covers those for
  pure component logic.
- **Cross-browser testing** — Chromium only. Firefox/WebKit can be
  added later by tweaking the `browser` fixture in `conftest.py`.
- **Mobile viewports** — desktop only (1280x800). Add a `mobile_page`
  fixture if needed.
- **Performance / load testing** — out of scope for "functional
  correctness".

## Reference

- Plan: `docs/SPEC.md` §3.13 (Testing / Tooling)
- Sibling suite: `tests/functional/README.md`
- Parent harness: `tests/functional/harness.py` (where `FunctionalHarness`
  and `is_safe_tmp` live — the UI suite reuses them via composition)
- Vite proxy override: `src/apps/desktop/vite.config.ts`
- Chatview plan: `docs/superpowers/plans/2026-08-20-functional-ui-chatview-test.md`

## Chatview DB-seeded tests

`tests/functional_ui/chatview_ui_test.py` covers the chatview's
**render path** by seeding pre-shaped `sessions` + `llm_history` rows
directly into the harness's isolated `agent.db` — no real LLM is
invoked. The chatview's `GET /api/llm/session/<id>/messages` reads
these exact rows, so DB-seeding exercises the same wire shape the
production agent emits.

### Why DB-seed (not HTTP-seed)?

- **Honest** — tests the exact wire shape including edge cases the
  LLM never produces (malformed `tool_calls_json`, empty content,
  very long reasoning).
- **Fast** — `sqlite3` INSERTs are O(ms); no agent-loop warm-up.
- **Reproducible** — no LLM non-determinism.
- **Cheap** — no API-key quota burned.

### How it works

Each test does:

1. Boot harness (function-scoped, fresh `agent.db` per test).
2. Open Python `sqlite3` against `temp_dir/.config/nalar/agent.db`.
3. INSERT `sessions` + `llm_history` rows via the `ChatviewSeed`
   helper in `tests/functional_ui/chatview_fixtures.py`.
4. Navigate headless Chromium to `/app/chat/<session_id>` and
   assert the rendered DOM matches the seeded data.

The `ChatviewSeed` helper validates the DB path with `is_safe_tmp`
as belt-and-suspenders — the harness already validated the
tempdir, but a regression there would let a test touch the real
home. The double-check raises `FunctionalHarnessError` and aborts
the test before any INSERT runs.

### Available helpers (`chatview_fixtures.py`)

```python
seed = ChatviewSeed(h.temp_dir / ".config" / "nalar" / "agent.db")
with seed.connect() as conn:
    sid = "sess_test_001"
    seed.seed_session(conn, sid, "Test Chat")
    seed.seed_user_message(conn, sid, "hi")
    seed.seed_assistant_message(conn, sid, "hello!")
    seed.seed_tool_result(conn, sid, "call_1", "bash", "stdout")
    seed.seed_compaction_user_message(conn, sid, summary="...", message_count=12)
```

`ChatviewSeed.baseline_timestamps(count=8)` returns a chronologically
spaced list of UTC ISO strings — useful for tests that seed
multiple messages and need them in `created_at_at_nano` order.

### Covered scenarios (10 tests)

1. Empty state — no messages show the "How can I help you?" placeholder
2. Plain user/assistant exchange
3. Multi-turn conversation (4 user + 4 assistant bubbles)
4. Assistant with tool calls (no result yet)
5. Tool call + matching tool result (Bash card renders stdout)
6. Markdown rendering (heading, bold, code, fenced block)
7. User with attached images (2 thumbnails)
8. Reasoning content (collapsible thinking trace)
9. Code block copy button
10. Compaction card (`<compact_messages>` envelope)