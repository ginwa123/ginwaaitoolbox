
#Mandatory
DONT KILL THE PORT 8081 SERVER,
for testing use another port like 8080

## Verification — Always Use Functional Tests, Never a Live Server

When verifying HTTP behavior (route order, wire payloads, error messages, JSON
serialization, authentication), do NOT spin up a live `nalar` binary and `curl`
it. Three recurring failure modes only surface from a real wire round-trip and
NONE of them are visible from unit tests:

1. **Route-order shadowing** — `matchRoute` walks routes in registration order
   (see `src/modules/custom_http_server/src/router.zig:182`), so a literal
   `/foo/reorder` registered AFTER `/foo/:bar` is captured with `bar="reorder"`.
   Unit tests on the useCase don't exercise routing.
2. **Empty-slice-as-NULL binding** — `SqliteBackend.exec` binds `""` slices as
   SQL NULL, which violates `NOT NULL` columns (precedent: Migration 079's
   `content` column). Unit tests that pass `""` directly to a SQLite column via
   `INSERT VALUES ('')` work, but PATCH flows that pass `""` through
   `useCase` don't — the bind collapses to NULL mid-execution.
3. **Strict validators treating `""` as a value** — `std.fs.path.isAbsolute("")`
   is false, so an empty `file_path` from an "atomic mode switch" payload fails
   validation. Unit tests usually pass a non-empty path; the empty case is only
   exercised by the frontend's real wire body.

**What to do instead — write an isolated functional test** that boots a fresh
`nalar` binary against an isolated tmpdir HOME per test, then replays the EXACT
JSON body the frontend sends:

```python
# tests/functional/agent_knowledge_edit_test.py — PR #291 follow-up
def test_text_mode_save_clears_file_path_and_sets_content(harness):
    """The edit dialog's Text-mode save sends {label, content, file_path:""}."""
    ws = _create_workspace(harness)
    agent = _create_agent(harness, ws)
    row = _add_file_knowledge(harness, agent)
    updated = _patch(harness, agent, row["id"], {
        "label": "Switched to text",
        "content": "inline body after switch",
        "file_path": "",
    })
    assert updated["file_path"] == ""
    assert updated["content"] == "inline body after switch"
```

The harness at `tests/functional/harness.py` does all the heavy lifting:
- Picks a free port in 8080..8199 (excluding 8081 — see the mandatory note above).
- Sets `HOME` to an isolated tmpdir (`/tmp/nalar-func-<uuid>/`) — the harness's
  `is_safe_tmp()` validator gates every `rmtree` so your real `$HOME` is never
  touched (see `tests/functional/README.md` ⛔ section).
- Tears down the binary + tmpdir on test exit (even on assert-fail).
- Runs `zig-out/bin/nalarcore-linux-x86_64` (or whatever `$NALAR_BIN` points at).

For static checks (route order, function signatures, error mappings), prefer a
Zig static-contract test in the same file as the impl (`<feature>_test.zig`
inline with `pub const` exports + greps). For Zig-only behavior, an in-memory
SQLite test in the same `useCase` file is enough — but for any HTTP route or
wire payload, ALWAYS graduate to the python functional harness.

**Anti-pattern: `nohup ./zig-out/bin/nalar... --port 8080` + `curl`.** Leaks the
process across tool calls, conflicts with the harness, and is exactly what
missed the bugs in PR #291.

**Verification command** for any HTTP-layer fix:
```bash
NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 \
  python3 -m pytest tests/functional/<your>_test.py -v
zig build test --summary all   # unit + static-contract tests still pass
```

Concrete worked example + lesson at
`.nalar/skills/replay-frontend-wire-payload-in-functional-tests`.

## Per-Request Arena Cleanup — Don't `defer free` in handlers

The HTTP server (`src/modules/custom_http_server/src/http_server.zig:349-362`) allocates a fresh `std.heap.ArenaAllocator` for every request and `deinit()`s it when the request scope ends:

```zig
const arena = self.allocator.create(std.heap.ArenaAllocator) catch {...};
arena.* = std.heap.ArenaAllocator.init(self.allocator);
group.concurrent(self.io, struct {
    fn handle(server: *GinwaServer, arena_allocator: *std.heap.ArenaAllocator, fd: SocketFd) void {
        defer {
            arena_allocator.deinit();  // ← frees every arena-backed allocation
            server.allocator.destroy(arena_allocator);
        }
        const allocator = arena_allocator.allocator();
        ...
    }
}.handle, ...);
```

**The `allocator` passed to every handler (`ctx.allocator`) IS this arena.** When the request scope exits, the arena wipes every byte allocated through it in one shot — there's no per-allocation free needed.

### What this means in practice

Inside a handler, **do NOT write**:

```zig
// ❌ WRONG — pointless churn; arena will free the bytes anyway
const body = try allocator.dupe(u8, "...");
defer allocator.free(body);
return res.jsonResponse(.{ .data = body, ... });
```

The `defer allocator.free(body)` is harmless but dead code — the arena deinit will release it. Worse, it can hide ownership: a future refactor that swaps `allocator` for a non-arena allocator will silently double-free.

### What's still required

`defer` is still needed for **non-memory resources** (the arena can't free these — they're not heap bytes):

- **SQLite statement handles** — `rows.deinit()` calls `sqlite3_finalize(stmt)`. KEEP this defer; the arena won't finalize the stmt.
- **File handles / sockets** — close them explicitly.
- **Anything NOT allocated via `ctx.allocator`** — `server.allocator`, `di.db`, mutex-protected globals, etc. Those outlive the request and need their own cleanup.

### Quick test: should I `defer free` here?

Ask "is this slice/struct memory allocated through `ctx.allocator`?" If yes, **no** — the arena handles it. If no, you probably need a free.

### Concrete example (workspace_get.zig, 2026-08-18)

Initial implementation `defer allocator.free(data.id); ... free(data.name); ...` for the four duped `[]const u8` strings in the response. All four were arena-allocated (via `allocator.dupe(u8, row.values[N])`). Removed the defers; the test suite (78/78 functional + 2391/2397 Zig tests) still passes.

## SSE Wire-Format Contract — Always Add Event Names in Pairs

The browser's `EventSource` drops named events whose listener isn't pre-registered. There is **no error, no warning** — the event just vanishes at the wire. User-visible symptom: "feature X never updates live, only after I refresh the page".

When you add (or rename) any SSE event_type name, change **all three** sites together — they're one contract, not three independent changes:

1. **Backend emitter** (`src/ai_workflow/tui/**/on_event_sent*.zig` or `agentic_loop/sse_on_event_send_*.zig`): add the action → `event_type` mapping to the `event_type_name` if/else.
2. **Frontend pre-registration** (`src/apps/desktop/src/api/index.ts` → `additionalEventTypes`): add the name to the list passed to `createSseClient`.
3. **Frontend dispatch check** (same file → named-event `if (eventType === ...)` chain): add the name to the branch that routes to `opts.channels.<channel>`.

If only one side changes, the bug is silent. Skip a step, and users see "doesn't update until refresh" — no error in the console, no failed test, no broken type check.

**Verification (before claiming done):** grep for the new event_type name across the codebase. It must appear in:

- All backend `onEventSend*` functions that emit it
- `additionalEventTypes` in `api/index.ts`
- The named-event dispatch chain in `api/index.ts`

If any of those is missing, the wire contract is broken.

**Concrete example** (task_1786507100896, PR #215): backend's `onEventSendSessions` had an `event_type_name` if/else that knew about `created` and `deleted` and fell through to `session_unknown` for everything else. `action="updated"` (the most common case — fired by the auto-rename-on-first-message cascade in `workflow.zig` and the unattended toggle in `llm_history.zig`) reached the wire as `event: session_unknown`, which the frontend's `additionalEventTypes` didn't pre-register. The browser silently dropped it. Sidebar task rows kept showing "New Chat" until a manual page refresh.

## Code Exploration with Graphify

Before exploring or making changes in an unfamiliar or large codebase, use the `graphify` CLI to build a knowledge graph of the repo instead of manually grepping through files.

**Setup (once per environment):**


> **Audience:** any AI agent (Claude, GPT, sub-agent, future-me) that writes,
> edits, reviews, or tests code in this repo. Humans may also find it useful.
>
> **Authority:** this file is loaded automatically by every agent at session
> start. Treat the rules below as non-negotiable. If a rule conflicts with a
> specific task, surface the conflict to the user before acting.


**Usage:**
- `graphify ./path` — build the knowledge graph for a project or folder
- `graphify query "<question>"` — ask a question against the graph
- `graphify path <A> <B>` — trace the relationship/path between two nodes (e.g., functions, files)
- `graphify explain <node>` — get an explanation of what a specific node does and why

**When to use it:**
- Onboarding to an unfamiliar repo or module
- Before refactoring, to see what depends on what
- Tracing how a function, class, or file is used across the codebase
- Investigating "god nodes" (highly-connected core components) or unexpected cross-file connections

**Why:** Graphify combines Tree-sitter static analysis with LLM-driven semantic extraction to produce an interactive `graph.html`, a queryable `graph.json`, and a `GRAPH_REPORT.md` audit report in `graphify-out/`. It only sends semantic descriptions to the AI model — never raw source code.


## Recent changes

- **`show_preview` default flips back to side + inline CTA strip below iframe (2026-08-29)**: Two surgical polish fixes for `task_1787988286635_2`. (1) `usePreviewDisplayMode.DEFAULT_MODE` flips from `'inline'` back to `'side'` — the 2026-08-06 spec said side, someone flipped it after merging, and the inline path was crushing the iframe in the narrow chat column with a horizontal scrollbar that overlapped content. New users land on the side panel; existing inline users keep their localStorage value (no migration). (2) The floating "↗ Open full" button inside the iframe's top-right corner is replaced by a small CTA strip BELOW the iframe container with "↗ Open in side panel" (primary) + an optional "Preview wider than chat — scroll for full content" hint (visible only when the iframe reports its inner content is wider than the chat column via the existing postMessage protocol, extended to also report `width`). No new files, 4 file edits (1 component + 1 helper + 2 test files), no backend/migration/Zig changes. `pnpm test:unit`: 2768/2768 pass (was 2765 baseline; +3 new tests). Branch: `worktree/show-preview-inline-default`. Plan: `docs/superpowers/plans/2026-08-29-show-preview-inline-default-and-ux.md`. 2 commits: default flip (d24b06cd) → CTA strip + width hint (a7e82d23).
- **Migrate package manager from npm → pnpm** (2026-08-28): User asked "use pnpm, make adjustment in build and the ci.yml". Replaces the npm-based chain that landed on 2026-08-25. Scope: webapp (`src/apps/desktop/`), mcp-hello-world test server (`src/apps/mcp_hello_world/`), the workspace `.npmrc`, the build.zig webapp + mcp chains, the `tests/functional_ui/` harness that spawns vite, and the 3 CI jobs that touch webapp deps (backend `Install pnpm + webapp dependencies`, frontend, frontend-windows). OUT OF SCOPE: `src/modules/nalar_browser/` (separate bun project, no CI involvement, no build.zig involvement — left alone per the user's exact ask). Lockfiles: `package-lock.json` × 2 → `pnpm-lock.yaml` × 2 via `pnpm import` (then the json files deleted). `pnpm-workspace.yaml` (allowBuilds.esbuild: true) is the only postinstall allowlist pnpm 11 reads (the legacy `pnpm.onlyBuiltDependencies` field in package.json + the `onlyBuiltDependencies` line in .npmrc are both ignored in pnpm 11 — see `pnpm-workspace.yaml` for the rationale; mcp_hello_world is the only project that needs it because vitest 2 pulls esbuild as a direct devDependency, whereas vitest 4 in the webapp marks esbuild optional so no allowlist is generated there). Workspace `.npmrc` pins `node-linker=hoisted` (flat node_modules layout — vite + vue-tsc + eslint plugin chain all resolve sibling node_modules paths the npm way) + `engine-strict=false` (don't fail when a developer's node misses the strict engines range). build.zig: mcp chain (3 steps) + webapp chain (4 steps) all use `pnpm install --frozen-lockfile` / `pnpm run build` / `pnpm test`; `check_webapp_node` pre-flight now requires `node` + `pnpm` on PATH (was `node` + `npm`) with platform-correct install hints. CI: `actions/setup-node@v4` (unchanged) + new `pnpm/action-setup@v4 version: 11`; `actions/cache` key prefix `npm-` → `pnpm-` (so old npm caches don't shadow new pnpm caches); install = `pnpm install --frozen-lockfile` (replaces `npm ci --no-audit --no-fund`); all script invocations `npm run` → `pnpm run`; `BUN_VERSION` env comment replaced with `pnpm migration (2026-08-28)`. Harness: `ui_harness.py` resolves `pnpm` / `pnpm.cmd` (was `npm` / `npm.cmd`); `harness_safety_test.py` test renamed `test_pnpm_resolves_on_this_os`; `tests/functional_ui/README.md` updated. `.gitignore`: dropped the now-stale `Bun` block (`bun.lockb`, `*.bun.lock`). Verified locally on the dev box: `pnpm install --frozen-lockfile` clean for both projects (21.9 s webapp cold, 0.7 s mcp_hello_world cold); `pnpm run build` produces a working `dist/` (webapp 1.4 s vite + vue-tsc parallel via run-p; mcp 0.4 s tsc); `pnpm test` webapp 2745/2745 pass in 35 s, mcp_hello_world 7/7 pass in 0.4 s; `zig build mcp-hello-world` 7/7 steps succeed; `zig build build:webapp` 3/3 steps succeed; `zig build nalar-desktop` 21/21 steps succeed (full end-to-end including codegen + relink); `zig build test --summary all` 2855/2861 pass / 6 skip / 0 fail (same skip count as pre-change); `pytest tests/functional_ui/harness_safety_test.py` 11/11 pass (including the renamed `test_pnpm_resolves_on_this_os`); actionlint v1.7.12 exit 0 on both `ci.yml` and `ci-cancel-on-merge.yml`. Branch: `worktree/use-pnpm`. Plan: `docs/superpowers/plans/2026-08-28-use-pnpm.md`. Single commit pending.
- **CI parallel/fast/cached pass + npm-everywhere migration** (2026-08-25): User asked for a faster, cached, more parallel pipeline AND mandated npm (not bun) everywhere "for consistency". Runner fleet is 1 self-hosted runner per OS, so NO new jobs were added (they'd queue, not parallelize) — all wins are inside the existing 5 jobs. Changes: (1) backend's two zig invocations merged into one `zig build test nalar-desktop --summary all` (removes a duplicate dependency-graph walk + vendor-probe pass; verified locally 2665/2671 pass / 6 skip). (2) Zig cache slimmed: `zig-out` (~124 MB binaries/cell) and the regenerated `webapp_assets.zig` dropped from cached paths — they're build OUTPUTS regenerated in seconds from `.zig-cache`; key bumped `v2-zig-` → `v3-zig-`; hashFiles dropped desktop_app/main.zig + bun.lock. (3) Linux cell: package-presence loop (`pacman -Q`) now runs FIRST; `pacman -Sy` only fires when something is missing → steady-state zero network calls. (4) New `NALAR_FUNC_VENV_DIR` env override in build.zig (read at config time via `b.graph.environ_map` — Zig 0.16 removed `std.process.getEnvVarOwned`) relocates the pytest venv outside the git-cleaned workspace; CI sets it to `$runner.temp/nalar-ci-venv` on both functional-test steps and a new cache step persists that venv + `~/.cache/ms-playwright` (chromium ~150 MB) keyed by both requirements.txt files. (5) Backend node_modules: deleted the bun-keyed actions/cache (was racing the npm-tarball mechanism for the same dir); npm tarball cache keyed off package-lock.json sha is the single source. (6) **build.zig webapp chain bun→npm**: `bun install` ×2 → `npm ci --no-audit --no-fund`, `bun run build` ×2 → `npm run build`; stale `bun.lock` (Jul 26 vs package-lock.json Aug 22) DELETED; vue-tsc-needs-real-Node rationale kept (now stronger — npm always uses real Node). (7) frontend + frontend-windows jobs: setup-bun removed, cache re-keyed `npm-<os>-<hash(package-lock.json)>`, install = `npm ci` gated on `steps.npm-cache.outputs.cache-hit != 'true'`; `BUN_VERSION` env removed. Verified: fresh-node_modules run does npm ci (26 s) → vite → codegen → link; second run skips install via node_modules probe; actionlint v1.7.12 exit 0. Publish gates untouched (PR builds stage only; main-only publish to rolling ci-latest with target-triple asset names). Branch: `worktree/ci-parallel-fast-cached-npm`. Plan: `docs/superpowers/plans/2026-08-25-ci-parallel-fast-cached-npm.md`. 8 commits: zig merge (b03ef43b) → cache slim (67164d79) → pacman gate (b6ab227f) → venv override+cache (f15152a5) → backend npm single-source (cb4b27c3) → build.zig npm (1a2e795e) → frontend npm (4921e678) → docs (this entry).
- **Kanban task detail dialog fetches ONE task instead of the whole board** (2026-08-24): User reported `tasks?limit=100` firing on every Task-details dialog open (Network tab screenshot). Root cause: `KanbanView.handleViewTaskDetail` → `workspacesStore.refreshTask` (`workspaces.ts:3592`) called `api.getTasks(ws, item, 100)` and plucked one task — every dialog open downloaded up to 100 rows with routine JOINs, tags, and base64 `image_urls`, plus a `git rev-parse` subprocess per row. Fix, 3 layers: (1) `llm_history.getWorkspaceItemTaskById(allocator, db, workspace_item_id, task_id) !?WorkspaceItemTaskInfo` — same 25-column SELECT + 3 LEFT JOINs (kanban/routines/sessions) as the lister, scoped `WHERE t.workspace_item_id = ? AND t.id = ? LIMIT 1` (item scoping prevents cross-item reads); 5 inline behavioural tests in `llm_history.zig`. (2) New `GET /api/workspaces/:ws/items/:item/tasks/:task_id` (`tasks_get.zig`) returning `{ task: {...} }` in the SAME `WorkspaceItemTaskResponse` shape as the list (frontend `Task` type unchanged); 400 on empty item/task id (empty-slice-as-NULL rule), 404 `task not found` on miss, git-branch fallback chain replicated; registered AFTER the list route in `main.zig` (route-order shadowing guard, static-contract tested); 7 static contracts in `tasks_get_test.zig`; 5 functional tests in `tests/functional/kanban_task_get_test.py` (happy path, 404, item-scoping 404, empty-id 400, list-route-unshadowed). (3) Frontend `api.getTask(ws, item, taskId)` — 404 resolves `null` silently (`silent: true` + `ApiError.status === 404` catch), other errors throw; `refreshTask` rewritten to call it (splice-in-place + `normalizeTaskTags` unchanged, best-effort catch unchanged); regression test asserts `getTasks` is NOT called. Test totals: `zig build test --summary all` 2665 pass / 6 skip / 0 fail (was 2658); `bun run test:unit` 2621 pass / 273 files (was 2578); functional 5/5 + 6/6 image-urls regression suite still green; `vue-tsc --build` clean. Branch: `worktree/kanban-task-detail-single-fetch`. Plan: `docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md`. 4 commits: DB fn (572b732c) → endpoint + functional (12c3253a) → frontend (c535f2c6) → changelog (this entry).
- **`delete_memory` agent tool — permanent row deletion from the SQLite `agent_memories` store** (2026-08-24): New third tool alongside `save_memory` / `load_memory`. The original design ("memory is permanent by your design") is reversed: the user can now ask the agent to forget a note. Layered exactly like the sibling tools — pure storage primitive + tool module + exec wrapper + registry + prompt rule + frontend card. (1) `agent_memories.deleteMemory(allocator, db, id) !bool` — `DELETE FROM agent_memories WHERE id = ?`, returns `true` if a row was removed, `false` for unknown id (idempotent), `error.InvalidId` for empty id. Uses `db.changes()` as the atomic did-it-delete signal. (2) **No migration needed** — Migration 070 already installed the `agent_memories_ad` AFTER DELETE trigger as explicit future-proofing for this feature; the FTS5-sync test proves it works. (3) `src/modules/agent/tools/delete_memory.zig` mirrors `save_memory.zig`: `DeleteMemoryInput { id }`, `delete_memory_tool : AgentTool` with `required: ["id"]`, `executeDeleteMemory` returns `<delete_memory><id>...</id><deleted>true|false</deleted></delete_memory>` on success / `<delete_memory><error>...</error></delete_memory>` on error. (4) Exec wrapper in `src/ai_workflow/tui/agentic_loop/tools_exec_delete_memory.zig` (3-branch envelope like `tools_exec_update_plan.zig`); wired into `UNIFIED_TOOL_REGISTRY()` + `equips()` in `tools_equipped.zig` (3 sites); re-export in `tools.zig`. No edits to `handle_tool.zig` — registry is auto-discovered. (5) `MemoryToolRule` prompt flipped from "TWO TOOLS" to "THREE TOOLS — UPSERT + FTS SEARCH + PERMANENT DELETE" with the new bullet: NEVER delete user-preference memories unless the user explicitly asks; default to UPSERT-with-superseding-content; load the row first to confirm the id. The save_memory tool description pointer also updated. Migration comment at `migration.zig:3464` ("no delete_memory tool by user decision") is left untouched as historical record. (6) Frontend `src/apps/desktop/src/components/tool_outputs/DeleteMemory.vue` mirrors `SaveMemory.vue` with one extra affordance: a header status chip distinguishes `deleted=true` ("removed", red tint) from `deleted=false` ("not found", muted gray), plus a red-tinted permanence warning in the expanded body. Wired into both `ChatView.vue` and `SubAgentPeekPanel.vue` dispatchers. (7) Test totals: `zig build test --summary all`: 2636/2642 pass, 6 skip, 0 fail, 0 leak (was 2628 baseline; +8 new tests: 4 storage + 6 tool module). `bun run test:unit`: 2578 pass (was 2562 baseline; +16 new DeleteMemory.spec.ts tests). Branch: `worktree/delete-memory-agent-tool`. Plan: `docs/superpowers/plans/2026-08-24-delete-memory-agent-tool.md`. 6 commits: storage primitive → tool module → exec wrapper + 3-site registry → prompt flip → frontend card → verification + changelog (this entry).
- **`zig build nalar-desktop` now ALWAYS embeds fresh webapp assets** (2026-08-22): User asked for fresh assets over cache-friendliness — the desktop binary previously could go stale w.r.t. edited `.vue` files because `bun run build` output isn't byte-stable (sourcemap/manifest drift), so Zig's step cache served old embedded assets. New chain: `desktop_exe → webapp_rebuild_codegen` = clean_webapp_cache tool → `bun run build` → codegen → compile+link, on EVERY `zig build nalar-desktop`. New `tools/clean_webapp_cache.zig` replaces the old `sh -c 'rm -rf ...'` clean step (works with native Windows shells, no Git Bash dependency; uses `std.Io.Dir.cwd().deleteTree` — note Zig 0.16 removed `std.fs.cwd()` and deleteTree's error set has NO FileNotFound; a missing path surfaces as AccessDenied). Fresh-checkout fix: conditional `bun install` (`rebuild_install_cmd`) now also attaches to the rebuild bun step when node_modules is missing. Cost accepted: every nalar-desktop build pays vite (~14 s) + exe relink. `webapp-rebuild` remains as a standalone alias for the same chain. Verified: two consecutive `zig build nalar-desktop --summary all` runs BOTH re-ran clean→bun→codegen (14/14 steps each); binaries exist. CI impact ≈ zero (always cold).
- **Bump `worker.last_activity_nano` per loop iteration + CI fix (route through `nalarcore`)** (2026-08-19): Two follow-up commits to PR #269. (1) Moved `updateWorker` from workflow entry (`workflow.zig:499`) to inside the `while(true)` loop body, right after the per-iteration arena `arenaAllocatorWhileLoop` is set up — `ON CONFLICT(id) DO UPDATE` handles both the first iteration (INSERT) and subsequent iterations (UPDATE) seamlessly. Failures are caught and logged via `errFmt` so a transient DB error on one iteration doesn't kill the workflow. Fully resolves the documented trade-off in the plan §2.6 (long-running workflows >10 min used to get wiped by the cleanup cron even though they were alive). (2) CI fix: `zig build nalar-desktop` was failing with `error: file exists in modules 'root' and 'nalarcore'` because `cleanup_stale_worker.zig` was directly @import'ing `../ai_workflow/tui/agentic_loop/ActiveLoops.zig` and `../ai_workflow/tui/agentic_loop/delete_worker.zig` — those files are also in the lib module via `root.zig → mod.zig`, so the exe module's import chain put them in both modules. Fix: route everything through `nalarcore` (the lib module) so the files only exist in ONE module. `src/ai_workflow/tui/mod.zig` adds `delete_worker` re-export, `src/root.zig` adds `pub const cleanup_stale_worker = @import(...)` re-export, `src/main.zig` uses `nalarcore.cleanup_stale_worker` instead of direct @import, `src/schedulers/cleanup_stale_worker.zig` uses `nalarcore.ai_mod.active_loops` and `nalarcore.ai_mod.delete_worker`. The `test_runner.zig` aggregator was deleted to avoid the same-directory-sibling issue. `zig build test --summary all`: 2401 pass, 6 skip, 0 fail, 0 leaks. `zig build nalar-desktop --summary all`: 10/10 steps succeeded. Branch: `worktree/cleanup-stale-worker-cron`. Plan: `docs/superpowers/plans/2026-08-19-cleanup-stale-worker-cron.md`.
- **Cronjob: delete stale `worker` rows + clear matching `ActiveLoops` entries** (2026-08-19): `cleanup_stale_worker.handle` (was a stub printing a debug line at `src/schedulers/cleanup_stale_worker.zig`) is now a real cron tick. Every minute, it `SELECT`s every `worker` row where `last_activity_nano IS NULL OR last_activity_nano < now_unix - 600` (10 min), and for each match: clears the matching `ActiveLoops` entry (idempotent), then `deleteWorker`'s the row (which also emits SSE `action="deleted"` so the UI updates live). Fixes the "kill -9'd workflow leaves the session stuck forever" symptom — without this, a `kill -9` skips the workflow's cleanup defers, so the `worker` row stays AND the `ActiveLoops` entry stays, and every future message on that session gets queued behind a dead worker. Implementation: pure helper `cleanupStaleWorkers(input) !CleanupResult` (testable without globals) + thin `handle(ctx, now_unix) void` wrapper (pulls `*ContextIPCTui` via `getSingleton()` and runs the helper inside a per-tick arena; DB errors are caught + logged, never propagated). Threshold exposed as `pub const stale_threshold_seconds: i64 = 600` so a future env-driven config is a 1-line change. **Honest trade-off** documented in the plan: `updateWorker` is only called once at workflow entry (`workflow.zig:499`), not per-loop-iteration, so a workflow legitimately running >10 min has a stale `last_activity_nano` and gets wiped by the cron even though it's alive. The user-visible cost is one flicker in the worker list + a brief `is_worker_running=false` window until the next message re-creates the row. **Real fix is the follow-up** (bump `last_activity_nano` periodically inside the agentic loop) — tracked as a follow-up kanban card. 10 new unit tests in `cleanup_stale_worker_test.zig` (delete-vs-keep based on threshold, NULL-last-activity treated as stale, multi-row batch, empty table, boundary `<` vs `<=`, per-row isolation, DB-error propagation, active_loops removal); new `schedulers/test_runner.zig` aggregator; one-line `root.zig` import to wire the test runner. No migration / schema / frontend / dependency changes. `zig build test --summary all`: 2402 pass, 6 skip, 0 fail. Branch: `worktree/cleanup-stale-worker-cron`. Plan: `docs/superpowers/plans/2026-08-19-cleanup-stale-worker-cron.md`.
- **FilePickerDialog — Recent tab + tabstrip + pin** (2026-08-14): The shared folder picker now opens on a Recent tab showing the user's previously picked folders (most recent first, pinned at top). A new tabstrip separates the Recent tab from the existing Browse tree. Each Recent row has a folder icon, basename, full path, relative time chip (reuses `formatRelativeTime`: `now` / `2h` / `1d` / `3d` / `1w` / `6mo` / `2y`), and a star button that toggles pin. Selecting a Recent row emits the same `select` event as Browse; the store records the path on every select. The Recent tab is opt-out via `enableRecentHistory: false` (default on). No caller changes — every existing caller gets the new tab. Toolbar (search + hidden + refresh) is hidden under Recent. New `useRecentFoldersStore` Pinia store at `src/apps/desktop/src/stores/recentFolders.ts` with localStorage persistence (`nalar-folder-picker-recent:v1`, 12-entry cap, pinned entries exempt from eviction, 200 ms debounced writes). 12 store tests + 10 dialog tests in `FilePickerDialog.spec.ts`. Dialog `max-height` bumped from `80vh` to `min(80vh, 720px)` so the new tabstrip + Recent list fits on a 720p display without inner-scroll. Branch: `worktree/folder-picker-recent-history`. Plan: `docs/superpowers/plans/2026-08-14-folder-picker-recent-history.md`.
- **Fix design mode group occluding its children — group z_index now sits BELOW children** (2026-08-14): User `Cmd+G`'d two elements (`groupElements` in `src/ai_workflow/tui/design_model.zig`), the group's body appeared on the canvas, but the children inside it disappeared — the dark template fill `#181616` (or any opaque fill) covered them. Even setting `fill: transparent` was a partial workaround (still occluded with a border or iframe children). Root cause: the new group's `z_index` was computed as `max(children.z_index) + 1`, which stacks the container ON TOP of its contents. Fix: track `min_z` alongside `max_z` in the children loop and compute the group's z_index as `min_z - 1` so the container paints BEHIND its children. Behavioural contract test: `groupElements sets z_index below children (min_z - 1, not max_z + 1)` in `src/ai_workflow/tui/design_model_group_test.zig` (greps the function body via `pub fn … pub fn` window, fails closed with `error.GroupZIndexAboveChildren` if a future refactor reverts). Regression asserts `parent.z_index == -1` when children default to 0. Branch: `worktree/group-z-index-below-children`. Plan: `docs/superpowers/plans/2026-08-14-group-z-index-below-children.md`. `zig build test --summary all`: 2264 pass, 6 skip, 0 fail.
- **Fix Anthropic token usage — include `cache_read_input_tokens` in `prompt_tokens` + `total_tokens`** (2026-08-13): Anthropic `url_style` profiles were reporting `total_tokens` ~5× lower than equivalent OpenAI calls — the parser correctly included `cache_creation_input_tokens` but silently dropped `cache_read_input_tokens` from the total. Fix: extend `Agent.Usage` with `cache_creation_input_tokens` + `cache_read_input_tokens` (both default 0, no OpenAI breakage); update the Anthropic SSE parser's `message_delta` formula to `prompt = input + cache_creation + cache_read`; preserve the cache breakdown separately on `Usage` so future billing code can charge cache writes at ~1.25× and cache reads at ~0.1× input rate. Migration 074 adds the 2 columns to `llm_history` (idempotent via the existing `addColumnIfMissing` helper). Cost-log formula at `Agent.zig:2066` is NOT updated in this PR — `prompt_tokens` is no longer safe as a billable metric; an explicit NOTE comment flags the follow-up. 5 commits on `worktree/fix-anthropic-total-tokens`. Plan: `docs/superpowers/plans/2026-08-13-fix-anthropic-total-tokens.md`. Spec: `docs/superpowers/specs/2026-08-13-fix-anthropic-total-tokens-design.md`. `zig build test --summary all`: 2235 pass, 6 skip, 0 fail.
- **Fix CI Linux — build.zig vendor race + build-vendor-curl.sh bugs** (2026-08-13): `zig build test` raced the `fetch-vendor-curl` step on a fresh checkout (`test_step`'s children ran in parallel — the test compile started before `libcurl.a` was written). CI run 31706196476 reproduced the race ("error: .../vendor/curl/linux_x86_64/lib/libcurl.a: file not found"). Fix: attach the fetch deps to the COMPILE step directly (`mod_tests.step.dependOn(...)`, `linux_exe.step.dependOn(...)`, etc., NOT `run_mod_tests.step` — `addRunArtifact` wraps the Compile in a Run step, and adding deps to the Run step makes the fetch a sibling of the compile, not a prerequisite; the Compile step needs to be the dependent) — 8 sites in `build.zig` patched. Same patch surfaced 4 latent bugs in `build-vendor-curl.sh` that were masked by the race: (1) `ar t missing_file` exits 9 and `set -euo pipefail` propagates that out of a `$(...)` substitution — append `|| true`; (2) `cp -r include/openssl` copies from the build dir, which only has 28 generated `.h` files — copy from `${OPENSSL_SRC_DIR}/include/openssl/` (113 plain `.h` files like `pem.h`, `ssl.h`, `evp.h`) first, then overlay; (3) `nm libcurl.a | grep 'T sym'` is a false-negative because `nm` on an archive reports only UNDEFINED references — extract the archive and `nm` each member; (4) the script unconditionally cross-compiled all 3 targets (linux + 2 macOS), wasting 30+ min on a Linux CI runner that only needs Linux — add a `TARGETS` env var defaulting to the host OS targets. Branch: `worktree/fix-ci-linux-vendor-race`. Plan: `docs/superpowers/plans/2026-08-13-fix-ci-linux-vendor-race.md`. `zig build test --summary all`: 2201 pass, 6 skip, 0 fail.
- **Anthropic profile SSE parsing + raw-error surfacing** (2026-08-13): `src/modules/agent/Agent.zig` now parses Anthropic's `/v1/messages` SSE events (`message_start` / `content_block_delta` / `content_block_start` / `message_delta` / `message_stop`) and surfaces raw server output in the retry-log error message when parsing fails. 3 commits on `worktree/anthropic-sse-parsing`: `4a783794` (raw SSE sample), `c137ebc9` (Anthropic SSE parser + UrlStyle dispatch), `c4d6853e` (also capture non-SSE lines). Plan: `docs/superpowers/plans/2026-08-13-anthropic-profile-sse-parsing.md`.
- **Fix Anthropic profile SEGV in iter 2** (2026-08-13): `buildJsonAnthropicRequest` was constructing `AnthropicContentBlock` structs via `.{ .text = rc }` / `.{ .tool_use = ... }` — Zig 0.16's anonymous struct literal only initializes named fields, leaving `.tool_use` / `.tool_result` as the arena's uninitialized bytes (0xAA debug poison). `AnthropicContentBlock.jsonStringify`'s `if (self.text)` then misread the poisoned bytes as a slice pointer → SEGV in `utf8ValidateSlice` on the second iteration (after arena memory had been reused+re-poisoned). Fix: initialize ALL three optional fields explicitly. Also dropped a premature `defer arena_alloc.free(content_blocks)` that was rewinding the arena bump pointer mid-function. New regression test: `buildJsonAnthropicRequest: assistant message with tool_calls + null reasoning_content survives` in `src/modules/agent/parse_anthropic_sse_test.zig`. 4th commit on `worktree/anthropic-sse-parsing`.
- **Fix Anthropic image upload (content_parts dropped on Anthropic wire)** (2026-08-13): `buildJsonAnthropicRequest` previously ignored `msg.content_parts` entirely — it only emitted `content` as a single text string OR as `tool_use` blocks for assistant messages. So user-attached images (stored correctly in `llm_history.image_urls` and rendered correctly in the frontend) were silently dropped before reaching Anthropic, and the model replied "I don't see any image". OpenAI-style `buildJsonOpenAIRequest` was already handling `content_parts`. Fix: add an `image` variant to `AnthropicContentBlock` (serializes as `{type:"image", source:{type:"url", url:"data:image/..."}}` — Anthropic accepts the `data:` URL shorthand via `source.url`); make the user/system branch of `buildJsonAnthropicRequest` build content_blocks from `msg.content_parts` when present, falling back to the legacy `single.text` path when not. 4 new regression tests in `parse_anthropic_sse_test.zig`: with-image, only-image, plain-text-regression, and explicit-wire-shape (asserts the Anthropic-native `source.url` wrapper is used, not the OpenAI-flat `image_url:` key). Branch: `worktree/anthropic-image-content-parts`. `zig build test --summary all`: 2198 pass, 6 skip, 0 fail.
- **System-deps probe — use system libs when present, skip vendor fetch** (2026-08-13): Per the user's "before use vendor script to build, check the current system deps first, if system have the lib no need use vendor" — `custom_http_client/build.zig` and `databases/build.zig` now probe the host system at config time for libcurl/libssl/libcrypto and sqlite3/libpq/openssl respectively. When the host is Linux AND the COMPILE target is Linux AND all required headers + libs are on /usr/include + /usr/lib, the packages `linkSystemLibrary("curl"/"sqlite3"/etc.)` instead of compiling the vendored fat archive + amalgamation. The root `build.zig`'s `fetch-vendor-curl` and `fetch-vendor-sqlite3` steps become no-op `echo "SKIPPED — host has system..."` lines instead of triggering the ~30-min curl+openssl cross-compile / 10 MB sqlite3 amalgamation download. macOS native + cross-compile (Linux→macOS, Linux→Windows) always fall back to vendor because the probe only checks Linux. Override with `-Dforce-vendor=true` on either package to always use the vendored path. `zig build test --summary all`: 2225 pass, 6 skip, 0 fail (same baseline as before). Branch: `worktree/system-deps-first`. Plan: `docs/superpowers/plans/2026-08-14-system-deps-first.md`.
