# Fix "wrong profile select" — kanban New Task dialog profile lost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user picks a Profile in the kanban New Task dialog (e.g. `900ribu`), the created chat session must persist and display that profile — not fall back to the default (`alpha model`).

**Architecture:** The bug is a backend INSERT-ordering conflict. `kanban_tasks_create.zig` forwards `is_auto_retry_until_stop` to `task_create.useCase`, which inserts a **bare** `sessions` row (no `selected_profile_model` column). The handler's later profile-bearing `INSERT OR IGNORE INTO sessions` then hits the existing PK and is **silently ignored** → profile lost. Fix: only forward the unattended flag to `useCase` for legacy `mode='create'`; for `create_session`/`create_and_run`, step 5's full INSERT is the authoritative row. Tests: Zig static-contract + HTTP functional wire + Playwright functional_ui.

**Tech Stack:** Zig 0.16 backend (custom HTTP server, SQLite), Vue 3 + TS desktop frontend, pytest + Playwright (functional_ui), python functional harness.

## Global Constraints

- **Never kill the port 8081 server.** Functional tests use the harness (ports 8080, 8082–8199); UI tests use Vite ports 5180–5299.
- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/fix-kanban-profile-select` (branch `worktree/fix-kanban-profile-select`) — already created.
- Vendor dirs are gitignored: copy `src/modules/custom_http_client/vendor/{curl,openssl}` from the main repo into the worktree before `zig build test` (see memory `zig-build-test-worktree-vendor-copy`).
- Tests live at the BOTTOM of impl files as inline `test "..."` blocks (2026-08-23 convention), EXCEPT HTTP handler `_test.zig` files which remain split (kanban_tasks_create_test.zig precedent).
- No comments above `logger.infoFmt(...)` calls. No new SSE event names (reuse `session_created`).
- PR flow only — never push to `main`. Kanban card moves to `in_review_task` after PR; `merged` is human-only.

## Root Cause (verified)

Wire path is correct end-to-end (frontend unit-tested; backend handler reads + binds the field). The failure is INSERT ordering:

1. Dialog **always** sends `is_auto_retry_until_stop` (`'0'` or `'1'`) — `KanbanTaskDetailDialog.vue:800` (`is_auto_retry_until_stop: unattended.value`, ref initialized `'0'` at line 271).
2. `api/index.ts:869-870` forwards it whenever defined → both buttons always include it.
3. `kanban_tasks_create.zig:169` forwards it into `TaskCreateRequest` → `task_create.useCase`.
4. `task_create.zig:626-638`: `if (input.body.is_auto_retry_until_stop) |flag|` → **bare** `INSERT OR IGNORE INTO sessions (id, name, status, is_auto_retry_until_stop)` — runs FIRST, creates the row WITHOUT `selected_profile_model`.
5. `kanban_tasks_create.zig:237-247`: profile-bearing `INSERT OR IGNORE INTO sessions (...)` → PK conflict → **silently ignored**.
6. `sessions.selected_profile_model` stays NULL → `GET /api/llm/session/:id/messages` returns `''` (COALESCE) → `ChatView.vue:1488` coerces to null → `effectiveProfile` falls back to `activeProfile` = "alpha model".

Deterministic for BOTH buttons whenever the dialog is used (the toggle always sends the field). Legacy `mode='create'` is unaffected (no session insert in step 5 to conflict with).

## Fix Shape

In `kanban_tasks_create.zig` step 4 (the `std_req` construction, line ~165-173): gate the flag forwarding on `is_create_only`:

```zig
const std_req = http_response.TaskCreateRequest{
    .name = parsed.name,
    .description = parsed.description,
    .task_type = "standard",
    // Only legacy mode='create' forwards the unattended flag into the
    // use-case (its bare sessions INSERT is the ONLY sessions write on
    // that path). For create_session / create_and_run, step 5 below
    // inserts the FULL sessions row (profile + flag) — forwarding the
    // flag here would make useCase insert a bare row first, and this
    // handler's INSERT OR IGNORE would then no-op on the PK conflict,
    // silently dropping selected_profile_model (bug: "wrong profile
    // select", task_1787494153778_2).
    .is_auto_retry_until_stop = if (is_create_only) parsed.is_auto_retry_until_stop else null,
    .tags = parsed.tags,
    .image_urls = parsed.image_urls,
    .cwd = parsed.cwd,
};
```

No frontend change. No migration. Step 5's INSERT already persists both `selected_profile_model` and `is_auto_retry_until_stop`, so the flag is not lost — it just moves to the authoritative INSERT.

---

## Task 1 — Zig static-contract regression test (fails first)

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/kanban_tasks_create_test.zig`

**Steps:**

- [ ] Write the failing test at the bottom of `kanban_tasks_create_test.zig`:

```zig
test "kanban_tasks_create forwards unattended flag to useCase ONLY for mode=create" {
    // Regression for task_1787494153778_2 ("wrong profile select").
    // The useCase's bare `INSERT OR IGNORE INTO sessions` (task_create.zig)
    // runs BEFORE this handler's profile-bearing INSERT OR IGNORE. If the
    // flag is forwarded for create_session/create_and_run, the bare row
    // wins the PK race and selected_profile_model is silently dropped.
    // Contract: the std_req construction must gate the flag on
    // is_create_only.
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    const req_pos = std.mem.indexOf(u8, source, "TaskCreateRequest{") orelse
        return error.TaskCreateRequestMissing;
    const req_end = std.mem.indexOfPos(u8, source, req_pos, "};") orelse
        return error.TaskCreateRequestUnterminated;
    const req_block = source[req_pos..req_end];

    // The flag line must exist...
    const flag_pos = std.mem.indexOf(u8, req_block, ".is_auto_retry_until_stop = ") orelse
        return error.UnattendedFlagNotForwarded;
    // ...and must be gated on is_create_only (ternary or if-expression).
    const gate_pos = std.mem.indexOfPos(u8, req_block, flag_pos, "is_create_only") orelse
        return error.UnattendedFlagNotGatedOnCreateOnly;
    _ = gate_pos;
}
```

- [ ] Run: `zig build test --summary all 2>&1 | tail -20` — the new test must FAIL with `UnattendedFlagNotGatedOnCreateOnly`.
- [ ] Commit: `git add -A && git commit -m "test(kanban): failing static-contract test for profile-select bug"`

## Task 2 — Backend fix

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/kanban_tasks_create.zig` (step 4, `std_req` construction ~line 165-173)

**Steps:**

- [ ] Apply the fix shape above (gate `.is_auto_retry_until_stop` on `is_create_only`).
- [ ] Run: `zig build test --summary all 2>&1 | tail -20` — Task 1's test now PASSES; no other test regresses (baseline: ~2400 pass, 6 skip, known pre-existing failures per memory `mem_a1eabbc7daa573fa`).
- [ ] Commit: `git commit -am "fix(kanban): gate unattended-flag forwarding to useCase on mode=create — profile no longer lost to INSERT OR IGNORE PK conflict"`

## Task 3 — Functional wire test (HTTP round-trip)

**Files:**
- Modify: `tests/functional/kanban_create_session_user_message_test.py` (add tests; reuse its `llm_harness` fixture + helpers)

**Steps:**

- [ ] Add helper `_get_session_selected_profile(harness, session_id)` — GET `/api/llm/session/:id/messages?limit=1`, return `body.get("selected_profile_model")`.
- [ ] Add test `test_create_session_persists_selected_profile_model`: create task with `mode='create_session'`, body includes `"is_auto_retry_until_stop": "1"` AND `"selected_profile_model": "stub"` (the harness's stub profile name). Assert GET returns `"stub"` — NOT `""`/None. This is the exact wire the dialog sends with Unattended ON.
- [ ] Add test `test_create_and_run_persists_selected_profile_model`: same but `mode='create_and_run'` with `queue_message`. Assert GET returns `"stub"`.
- [ ] Add test `test_create_session_unattended_flag_still_persists`: assert the flag itself isn't lost by the gating — GET the session row via sqlite3 (`h.temp_dir/.config/nalar/agent.db`, `SELECT is_auto_retry_until_stop FROM sessions WHERE id=?`) and assert `'1'`.
- [ ] Run: `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/kanban_create_session_user_message_test.py -v` — all pass (new tests FAIL before Task 2's fix if run against a stale binary; run after rebuild).
- [ ] Commit: `git commit -am "test(functional): wire round-trip for selected_profile_model on create_session/create_and_run"`

## Task 4 — Functional UI test (Playwright, user-requested)

**Files:**
- Create: `tests/functional_ui/kanban_profile_select_ui_test.py`

**Steps:**

- [ ] Write the suite. Key mechanics:
  - Use the `ui_harness` + `page` fixtures from `conftest.py`.
  - The default `ui_harness` boots WITHOUT a stub profile — the dialog's picker loads profiles from `GET /api/config/nalar` (reads `config.json` fresh per request, `nalar_config_get.zig:33`), so seed a profile into `h.temp_dir/.config/nalar/config.json` AFTER boot (write `{"profiles_models": {"900ribu": {"model": "m", "base_url": "http://127.0.0.1:1", "api_key": "k"}}, "active_profile": "alpha"}` — wait, use profile names that exist in the picker: seed TWO profiles `900ribu` and `alpha` with `active_profile: "alpha"` so the fallback would visibly show `alpha` if the bug regresses).
  - Pre-create workspace + kanban via API (mirror `kanban_lifecycle_ui_test.py` helpers).
  - Navigate to `_kanban_url(h, ws_id, kanban_id)` (`/app?view=workspace&workspaceId=...&itemId=...`), `wait_until="domcontentloaded"`.
  - Open dialog: `[data-testid="kanban-add-task-button"]`.
  - Fill name: `[data-testid="kanban-task-detail-create-name"]`.
  - Pick profile: click `[data-testid="kanban-task-detail-profile-picker"]`, then the dropdown item containing text `900ribu` (`[data-testid="kanban-task-detail-profile-picker-item"]` filtered by `has_text="900ribu"`).
  - Toggle Unattended ON: `[data-testid="kanban-task-detail-unattended-toggle"]` (check it — this is the bug's trigger).
  - Click `[data-testid="kanban-task-detail-save"]` ("Create task").
  - **Assert via API** (reliable, per README guidance): GET `/api/llm/session/<task_id>/messages?limit=1` → `selected_profile_model == "900ribu"`. Get `task_id` from `GET /api/workspaces/:ws/items/:kanban/kanban/tasks` (match by name).
  - Second test: same flow but click `[data-testid="kanban-task-detail-create-and-run"]` ("Create task & run agent") — assert same persistence. (The agent run fails silently against the stub's dead port — fine.)
  - Third test (UI-visible assertion): after "Create task", navigate to the chat (`/app/chat/<task_id>`), wait, and assert the profile chip shows `900ribu` — the chip renders `{{ effectiveProfile ?? 'Default' }}` (ChatView.vue:3300). Locate via `page.locator('button:has-text("900ribu")')` near the bottom bar, or open the picker and check `[data-testid="profile-picker-900ribu"]` has the ✓. Prefer: `page.get_by_test_id("profile-picker-900ribu")` visible after clicking the chip button.
- [ ] Run: `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 PYTHONPATH=tests/functional:tests/functional_ui python3 -m pytest tests/functional_ui/kanban_profile_select_ui_test.py -v` (needs `playwright install chromium` once).
- [ ] Commit: `git commit -am "test(functional-ui): Playwright coverage — dialog profile pick survives create (unattended on)"`

## Task 5 — Full verification + PR

**Steps:**

- [ ] Copy vendor dirs into worktree if not done: `mkdir -p src/modules/custom_http_client/vendor && cp -r ~/ginwaaitoolbox/src/modules/custom_http_client/vendor/{curl,openssl} src/modules/custom_http_client/vendor/` (adjust source path to main repo).
- [ ] `zig build test --summary all` — no new failures vs baseline.
- [ ] `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/kanban_create_session_user_message_test.py tests/functional/kanban_lifecycle_test.py -v` — pass.
- [ ] Functional UI suite: `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 PYTHONPATH=tests/functional:tests/functional_ui python3 -m pytest tests/functional_ui/kanban_profile_select_ui_test.py -v` — pass.
- [ ] Frontend untouched — skip `bun run build` (no `.vue`/`.ts` changes).
- [ ] Revert build noise if any: `git checkout -- src/apps/desktop_app/embedded/webapp_assets.zig` (only if modified).
- [ ] Push + PR: `git push -u origin worktree/fix-kanban-profile-select && gh pr create --title "fix: kanban New Task dialog profile select lost (wrong profile select)" --body "..."`.
- [ ] Move kanban card `task_1787494153778_2` → `in_review_task` (`col_1826ecca367f0000`).

## Pitfalls

- **`zig build test` in a fresh worktree fails on vendor curl** — copy the gitignored vendor dirs first (Global Constraints).
- **The dialog ALWAYS sends the unattended flag** — a test that omits it from the wire body does NOT reproduce the bug. The functional test must include `is_auto_retry_until_stop` to exercise the PK-conflict path.
- **`INSERT OR IGNORE` swallows the failure silently** — no error surfaces in logs; only the missing profile in the GET response reveals it. Assert on the GET, not on create-response status.
- **UI test profile seeding must happen AFTER harness boot** (the harness creates the tmpdir at boot; `config.json` is read fresh per request so post-boot writes are picked up).
- **Playwright `networkidle` never fires** (Vite HMR websocket) — always `wait_until="domcontentloaded"` + `wait_for_timeout`.
- **Port 8081 is off-limits** — the harness already skips it; don't override `port=`.

## Verification

- [ ] New Zig static-contract test passes (and failed before the fix).
- [ ] Functional wire tests pass: profile persists for both create_session and create_and_run with unattended flag present.
- [ ] Functional UI tests pass: dialog pick → DB persistence → chatview chip shows the picked profile.
- [ ] `zig build test --summary all` no new failures vs baseline.
- [ ] PR opened; kanban card in `in_review_task`.
