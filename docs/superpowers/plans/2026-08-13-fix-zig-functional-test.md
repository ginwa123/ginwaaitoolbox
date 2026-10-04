# Fix zig build functional-test regressions

## What broke

`zig build functional-test` regressed from green to 12 failing tests in the
last few days. Three independent root causes — all surfaced together when
chunk 5 of the functional-tests plan added the `deletePage` on-disk cleanup
assertion:

### Root cause #1: kanban create response shape mismatch
`POST /api/workspaces/:wid/items/kanban` returns the wrapped envelope
`{item: {id, item_type, name, ...}, columns: [...]}` (added in PR #215 to
fix the sidebar 'Untitled project' bug). The functional tests were written
against the OLD flat shape and indexed `body["id"]` / `body["item_type"]`
directly, getting `KeyError: 'id'` / `'item_type'`.

**Affected tests:** 9 kanban lifecycle tests + 2 SSE end-to-end tests (both
`_create_kanban` helpers in `sse_endtoend_test.py`).

### Root cause #2: design page delete leaves the page directory behind
`design_model.deletePage` was switched to per-file unlink in PR #197 (after
review feedback) — `deleteFileIfExists` for every tracked HTML file, no
recursive rmdir. That's correct, but the test
`test_delete_page_removes_entire_directory` expected the page FOLDER to
disappear too. Per-file unlink leaves an empty `<item>/.pabrik/design/<page>/`
directory. The test was written against the pre-#197 behavior.

**Affected test:** `tests/functional/design_lifecycle_test.py::test_delete_page_removes_entire_directory`.

### Root cause #3: test fixture isolation required
The user added an explicit reminder: "make sure it's isolated, and don't
touch the real HOME". The harness ALREADY isolates `$HOME` via the
`/tmp/pabrik-func-*` tempdir contract (see `tests/functional/harness.py`
`is_safe_tmp()` + `ALLOWED_TMP_PREFIXES` + the five `harness_safety_test.py`
regression guards). All 12 harness_safety tests passed before AND after
this PR — the isolation was correct; the failure was purely in the
test/handler wire shape.

## Fix

### 1. Unwrap the `{item, columns}` envelope in the test helpers
`tests/functional/kanban_lifecycle_test.py::_create_kanban` and
`tests/functional/sse_endtoend_test.py::_create_kanban` now destructure
`body["item"]` first, then read `item["id"]` / `item["item_type"]`.
Added an assertion that `body["columns"]` is a list (catches anyone
regressing to the flat shape).

No backend change needed — `workspace_items_create_kanban.zig` already
emits the envelope and is guarded by
`workspace_items_create_kanban_test.zig` (4 static regression tests).

### 2. Rmdir the empty page directory after per-file unlink
Added `design_io.deleteDirectoryIfEmpty()` — a new helper that:
- uses `rmdir(2)` on POSIX (returns -1 + errno=ENOTEMPTY when non-empty)
- uses `RemoveDirectoryW` on Windows (returns 0 + GetLastError=145 when non-empty)
- distinguishes `DirNotEmpty` from `RmdirFailed` so the caller can preserve
  user files vs. log+continue on real failures

`design_model.deletePage` now calls this helper AFTER unlinking every
tracked HTML file. Semantics:
- Page had elements, no user files → rmdir succeeds, page dir is gone.
- Page had elements, user dropped a file (`README.md`, `.DS_Store`, …) →
  rmdir fails with `DirNotEmpty`, user file is preserved.
- Page had no elements → nothing to rmdir (no-op, matches the existing
  `test_deletePage succeeds (no-op on disk) when page has no elements yet`).

Critically, this preserves the original PR #197 review feedback: per-file
deletion is the primary cleanup, the rmdir is just a follow-up tidy.
User-dropped files inside the page folder survive.

### 3. New regression tests (Zig-side)
- `design_io_test.zig` — 3 tests pinning the `deleteDirectoryIfEmpty`
  contract: removes empty dirs, no-ops on missing, refuses non-empty.
- `design_model_delete_page_test.zig` — 2 new tests:
  - `deletePage rmdirs the empty page directory (cleans up after per-file unlink)`
  - `deletePage preserves a user-dropped file inside the page directory`

Both files already existed; the new tests slot in next to the existing
per-file unlink regression guards.

### 4. Isolation verification
The functional harness's HOME-isolation contract is already covered by
11 existing tests in `tests/functional/harness_safety_test.py` (all 11
pass). This PR does not touch any isolation code — the regression was
in the per-test wire shape and the per-page rmdir step.

## Files touched (6 files, +300 lines, -4 lines)

```
src/ai_workflow/tui/design_io.zig                  | 66 +++++++++++++++
src/ai_workflow/tui/design_io_test.zig             | 71 ++++++++++++++++
src/ai_workflow/tui/design_model.zig               | 44 ++++++++++
src/ai_workflow/tui/design_model_delete_page_test.zig | 94 ++++++++++++++++++++++
tests/functional/kanban_lifecycle_test.py          | 24 +++++-
tests/functional/sse_endtoend_test.py              |  5 +-
```

## Verification

- `zig build test --summary all` → 2253 pass / 6 skip / 0 fail
  (new tests pass; no regressions)
- `zig build functional-test` → **64/64 functional tests pass**
  (previously: 52/64 pass, 12 fail)
- Linux host binary compiles + runs (the binary boots against the isolated
  tmpdir HOME, no state leaks to the real `$HOME`).
- The `harness_safety_test.py` 11-test isolation contract is unchanged
  and still passes.

## What's NOT in this PR

- The `zig build -Dtarget=x86_64-windows` cross-compile failure (the
  `libcurl.a: file not found` + `codegen_webapp_assets.zig:206: type
  'void' not a function` errors observed during smoke-testing) is a
  pre-existing Windows build issue from commit 8d513a6f ("push webassets")
  and is unrelated to the functional-test regression. Out of scope.
- The 10.02s teardown slowness in the slowest-tests log is the harness's
  `/test/shutdown` + SIGTERM grace period. Pre-existing, not blocking.
