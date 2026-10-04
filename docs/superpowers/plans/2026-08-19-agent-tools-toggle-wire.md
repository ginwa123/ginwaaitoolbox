# Agent Mode: wire checkbox toggles to INSERT/DELETE `agent_tools`

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Date:** 2026-08-19
**Task:** `task_1787213301062_0` — "agent mode: checklist tool"
**User's spec (verbatim):** *"when checkist or uncheclist it should insert and delete table agent_tool"*
**Branch / worktree:** `worktree/agent-tools-toggle-wire` (create from current `in_review_planning` task; per the project rule, do all work in a git worktree and open a PR for review).
**Related:** docs/superpowers/specs/2026-08-15-agent-mode-design.md (the Agent Mode spec that shipped v1 with a stub handler), docs/superpowers/plans/2026-08-15-agent-mode.md.

**Goal:** When the user checks a tool checkbox in AgentView's Tools panel, INSERT a row into `agent_tools` (Migration 076 table). When the user unchecks, DELETE the matching row. The existing stub `handleAgentToggleTool` in `AppLayout.vue` is the place to wire this up — it's currently a no-op.

**Architecture:** The Agent Mode spec (2026-08-15) shipped 4 backend handlers + 4 API wrappers + 1 store + 1 view, but `handleAgentToggleTool` is currently a no-op stub (`void toolName; void enabled`). This plan wires it. The existing DELETE endpoint takes `:tool_id` (from Migration 076 era) but the toggle UX only knows `tool_name` (the checkbox label). Switch the DELETE path to `:tool_name` — cleaner REST for the toggle use case, and no external consumers exist yet (shipped 4 days ago). The frontend `disableAgentTool` wrapper signature changes accordingly. Toggle handler: optimistic local update (add/remove from `agentTools` ref) → await the API call → on failure, revert + `console.error`. No per-tool loading state for v1 — the SQLite-backed endpoint is sub-millisecond and double-click is harmless (UNIQUE → 409).

**Tech Stack:** Zig 0.16 (backend), Vue 3 + TypeScript + Vitest (frontend), SQLite via `pabrikcore.sqlite.SqliteBackend`. No new deps, no migration (the `agent_tools` table already exists from Migration 076).

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows. Verify with `zig build test --summary all` + `bun run build` + `bunx vitest run`.
- **No port 8081**: smoke tests use port 8080.
- **TDD**: failing test FIRST for every behavioural change. Run the test, confirm it fails for the right reason, then implement.
- **Surgical patches**: do not refactor unrelated code. Only touch the files listed below.
- **No new comments above `logger.infoFmt(...)` calls** (see `~/.config/pabrik/memories/no-comments-on-logger-calls.md`).
- **Agent Mode inline-test convention** (per `mem_6b93a3d74434c6d9`): helper-layer tests are INLINE in the impl file. NO new `_test.zig` files for handler changes — extend the existing `useCase` test block in `agent_tools_delete.zig`.
- **No frontend `_test.zig` parallel**: this is a Vue/TS change, so the Vitest spec file (`AppLayout.agentToolsToggle.spec.ts`) lives under `src/apps/desktop/src/__tests__/` per the existing convention.
- **Optimistic update with rollback on failure** — matches typical Vue patterns; safer than "wait for server then update".
- **The wire contract for ALL OTHER agent_tools endpoints stays unchanged** — only DELETE's path param name changes (`:tool_id` → `:tool_name`); the POST handler keeps `tool_name` in the body; the GET/list response shape is unchanged.

## File Structure

```
EDIT src/ai_workflow/tui/http_handlers/agent_tools_delete.zig  (useCase takes tool_name, SQL by (agent_id,tool_name), update 4 inline tests)
EDIT src/main.zig                                                (route :tool_id → :tool_name)
EDIT src/apps/desktop/src/api/index.ts                           (disableAgentTool signature: agentId, toolName)
EDIT src/apps/desktop/src/components/AppLayout.vue               (wire handleAgentToggleTool)
NEW  src/apps/desktop/src/__tests__/AppLayout.agentToolsToggle.spec.ts  (Vitest: mounting, toggle triggers correct API)
```

Total: **1 NEW, 4 EDIT. No migration, no schema change, no new dependencies.**

---

## Root Cause (read this before chunking — saves re-discovery)

### What's broken today

The Agent Mode feature shipped on 2026-08-15 with a complete backend + frontend surface, but the toggle handler was deliberately stubbed (per the spec's "v1.1 wiring" note). Today:

```ts
// src/apps/desktop/src/components/AppLayout.vue:1072
async function handleAgentToggleTool(toolName: string, enabled: boolean) {
  // v1.1 wiring. For now, no-op.
  void toolName; void enabled
}
```

User clicks a checkbox in `AgentView.vue:147-154` → `@change` fires `handleToggleTool` → emits `toggleTool` → AppLayout's `handleAgentToggleTool` runs → does nothing. The UI shows a checkmark, but the `agent_tools` table is never touched. Opening a chat under that agent reveals the LLM has no tools (secure-by-default), regardless of what the user "enabled" in the UI.

### Why the DELETE endpoint needs to change

The existing DELETE endpoint is `DELETE /api/agents/:agent_id/tools/:tool_id`. The UI's `tools` prop is `string[]` (tool_names only). To toggle a checkbox OFF, we'd need to:
- (a) Look up the `tool_id` for the `tool_name` before calling DELETE — extra round trip + a refetch every time
- (b) Change the DELETE path to `:tool_name` — one round trip, REST-friendly

Going with (b). The endpoint was just shipped 4 days ago; no external consumers exist.

### What the spec said (for context)

Spec §3.4 line 141: `DELETE /api/agents/:agentId/tools/:toolId`. The spec called for `:toolId`, but the spec was written before the toggle UX was designed. The toggle UX wasn't actually built until commit 88b0ef06 (which also left the stub). This plan corrects the wire shape to match the UX reality.

---

## Task 1 — Backend: switch DELETE to `:tool_name` (TDD)

> **Outcome**: `agent_tools_delete.zig` useCase takes `tool_name` instead of `tool_id`. SQL becomes `DELETE FROM agent_tools WHERE agent_id=? AND tool_name=?`. The 4 inline tests in the file are updated for the new signature. Handler test `agent_tools_delete` (in `http_handlers/test_runner.zig`) still compiles. `zig build test --summary all` is green.

### Step 1.1 — Update the 4 existing tests to fail

Edit `src/ai_workflow/tui/http_handlers/agent_tools_delete.zig`. Rewrite the test block (lines ~186-243) so each test calls `useCase` with `tool_name` instead of `tool_id`, and the seed/assert SQL matches `(agent_id, tool_name)` scoping. Specifically:

- `test "useCase: empty agent_id returns IdsRequired"` — change input to `tool_name: "bash"` (already correct shape; rename the param)
- `test "useCase: empty tool_id returns IdsRequired"` — rename to `"empty tool_name returns IdsRequired"`, change input to `tool_name: ""`
- `test "useCase: matches scoped by both id AND agent_id (no cross-agent delete)"` — rename to `"matches scoped by both tool_name AND agent_id (no cross-agent delete)"`. Replace the `at_1`/`at_2` id-based scoping with tool_name-based scoping. New seed: agent 1 has `('at_1', 'ws_item_1', 'bash')`, agent 2 has `('at_2', 'ws_item_2', 'read_file')`. Try `tool_name: 'read_file'` with `agent_id: 'ws_item_1'` (should be no-op — wrong agent). Then `tool_name: 'bash'` with `agent_id: 'ws_item_1'` (should delete). Verify agent 2's `read_file` untouched.
- `test "useCase: non-matching tool_id is a no-op (no error)"` — rename to `"non-matching tool_name is a no-op (no error)"`. Call with `tool_name: 'totally_nonexistent'`. Verify count stays at 1.

Also rename:
- `ToolDeleteInput.tool_id` → `ToolDeleteInput.tool_name`
- `ToolDeleteError.IdsRequired` message field references update accordingly
- `countToolsForAgent` helper stays the same (already filters by agent_id)

Run the tests, expect FAIL:

```bash
cd /home/ginwa/.worktrees/agent-tools-toggle-wire && timeout 180 zig build test --summary all 2>&1 | tail -n 40
```

Expect `agent_tools_delete.zig` compile errors (useCase signature mismatch) — that's the right kind of failure.

- [ ] Failing tests confirmed

### Step 1.2 — Implement the useCase change

Edit `src/ai_workflow/tui/http_handlers/agent_tools_delete.zig`. In the `useCase` function (lines ~46-59) and `ToolDeleteInput` struct (lines ~33-36):

- Rename `tool_id: []const u8` → `tool_name: []const u8` in `ToolDeleteInput`
- Rename `input.tool_id` → `input.tool_name` in the `if` check (line 51) and the SQL `&[_][]const u8{...}` (line 57)
- Change SQL from `DELETE FROM agent_tools WHERE id = ? AND agent_id = ?` → `DELETE FROM agent_tools WHERE tool_name = ? AND agent_id = ?`
- Update the `ToolDeleteError` doc comment for `IdsRequired` to mention "agent_id and tool_name required"
- Update the handler `agentToolsDeleteHandler` (line ~79): `req.params.get("tool_id")` → `req.params.get("tool_name")`. Update the call to `useCase` to pass `tool_name`.
- Update the error message string at line ~90: `"agent_id and tool_id required"` → `"agent_id and tool_name required"`

Run the tests:

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 40
```

Expect all tests green. Inline tests in `agent_tools_delete.zig` should now exercise the new signature.

- [ ] `zig build test` green (all 4 inline tests in `agent_tools_delete.zig` pass + no regressions elsewhere)

### Step 1.3 — Commit

```bash
git add src/ai_workflow/tui/http_handlers/agent_tools_delete.zig
git commit -m "agent mode: switch DELETE /agents/:id/tools to use :tool_name

The toggle UX in AgentView only knows tool_name (the checkbox label),
not tool_id. Switching the path param from :tool_id to :tool_name makes
the wire shape match the UX reality and avoids an extra round trip
to look up the id before each DELETE. No external consumers yet
(shipped 4 days ago in the Agent Mode plan).

- useCase signature: ToolDeleteInput.tool_id → tool_name
- SQL: DELETE WHERE id=? AND agent_id=? → DELETE WHERE tool_name=? AND agent_id=?
- Handler reads req.params.get(\"tool_name\")
- 4 inline tests updated to exercise (agent_id, tool_name) scoping"
```

---

## Task 2 — Backend: route registration update

> **Outcome**: The DELETE route in `src/main.zig:412` is registered with `:tool_name` instead of `:tool_id`. `zig build test` still green. Manual `curl -X DELETE /api/agents/foo/tools/bash` works.

### Step 2.1 — Update the route

Edit `src/main.zig:412`:

```zig
// Before
try gs.router.delete("/api/agents/:agent_id/tools/:tool_id", ai_mod.http_handlers.agentToolsDeleteHandler);
// After
try gs.router.delete("/api/agents/:agent_id/tools/:tool_name", ai_mod.http_handlers.agentToolsDeleteHandler);
```

(The param name only affects the variable name the handler reads via `req.params.get` — already updated in Task 1.)

### Step 2.2 — Verify

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 20
```

Expect green.

### Step 2.3 — Commit

```bash
git add src/main.zig
git commit -m "agent mode: rename DELETE route path param :tool_id → :tool_name

Matches the handler rename in the previous commit. Pure cosmetic from
the router's perspective — the param name is opaque to the router."
```

---

## Task 3 — Frontend: update `disableAgentTool` API wrapper signature

> **Outcome**: `disableAgentTool(agentId: string, toolName: string)` takes `toolName` instead of `toolId`. The DELETE URL template uses `/tools/${toolName}` (template literal — Zig path-safe). No other call sites exist. `bunx tsc --noEmit` clean.

### Step 3.1 — Find all call sites

```bash
cd /home/ginwa/.worktrees/agent-tools-toggle-wire
grep -rn "disableAgentTool" src/apps/desktop/src
```

Expect 1 hit: the wrapper itself in `src/apps/desktop/src/api/index.ts` (around line 3774). No call sites yet (the wire-up is the whole point of this plan). The TypeScript compiler will catch any missed rename once Task 4 wires it up.

### Step 3.2 — Update the wrapper

Edit `src/apps/desktop/src/api/index.ts` around line 3774:

```ts
// Before
export async function disableAgentTool(
  agentId: string,
  toolId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(
    `/agents/${agentId}/tools/${toolId}`,
    { method: 'DELETE' },
  )
}
// After
export async function disableAgentTool(
  agentId: string,
  toolName: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(
    `/agents/${agentId}/tools/${toolName}`,
    { method: 'DELETE' },
  )
}
```

Also update the doc comment above the function: `"Delete a tool by tool_name (no longer needs the tool_id lookup)"`.

### Step 3.3 — Type-check

```bash
cd /home/ginwa/.worktrees/agent-tools-toggle-wire
bunx vitest run src/apps/desktop/src/__tests__/agentToolsStore.spec.ts 2>&1 | tail -n 20
```

Expect green (the store test doesn't call `disableAgentTool`, but the tsc pass verifies the wrapper signature compiles).

### Step 3.4 — Commit

```bash
git add src/apps/desktop/src/api/index.ts
git commit -m "agent mode: disableAgentTool takes toolName instead of toolId

Matches the backend route rename. The toggle UX knows the tool_name
(the checkbox label) but never the tool_id, so taking toolName
avoids a lookup round trip. No call sites to update — the wire-up
is the next commit."
```

---

## Task 4 — Frontend: wire `handleAgentToggleTool` in AppLayout.vue

> **Outcome**: Clicking a tool checkbox in AgentView results in a `POST /api/agents/:id/tools` (insert row) or `DELETE /api/agents/:id/tools/:tool_name` (delete row). The local `agentTools.value` ref updates optimistically; on error, the checkbox state reverts and a `console.error` fires. Vitest test `AppLayout.agentToolsToggle.spec.ts` verifies the wiring without rendering the full AppLayout.

### Step 4.1 — Write the failing Vitest spec

Create `src/apps/desktop/src/__tests__/AppLayout.agentToolsToggle.spec.ts`. This test does NOT mount AppLayout (it has too many dependencies — Vue Router, etc.). Instead, it extracts the `handleAgentToggleTool` function as a pure helper that can be unit-tested directly.

Refactor first (in `AppLayout.vue`):

```ts
// New helper file: src/apps/desktop/src/stores/agentToolToggle.ts
//
// Pure helper: given the current local tools list, the toggle
// event, and a pair of API callbacks, returns the new local list
// AND a promise that resolves when the API call lands. On API
// failure, the caller can revert.
//
// Kept in a separate file (not inline in AppLayout) so Vitest can
// import it without booting the full AppLayout component tree.
import type { string } from '../types' // types are just `string`
// (the above import is illustrative — TS uses primitive types directly)

export interface ToggleCallbacks {
  enableAgentTool: (agentId: string, toolName: string) => Promise<unknown>
  disableAgentTool: (agentId: string, toolName: string) => Promise<unknown>
  refetchAgentTools: (agentId: string) => Promise<string[]>
}

export interface ToggleResult {
  /** The new local list to show in the UI immediately (optimistic). */
  nextLocal: string[]
  /** Resolves to the canonical server list (post-mutation). On
   *  failure, the caller reverts `nextLocal` and logs. */
  serverPromise: Promise<{ canonical: string[] } | { error: unknown }>
}

export function buildToggle(
  currentLocal: string[],
  toolName: string,
  enabled: boolean,
  agentId: string,
  cbs: ToggleCallbacks,
): ToggleResult {
  const nextLocal = enabled
    ? [...new Set([...currentLocal, toolName])] // dedupe
    : currentLocal.filter((n) => n !== toolName)

  const serverPromise = (async () => {
    try {
      if (enabled) {
        await cbs.enableAgentTool(agentId, toolName)
      } else {
        await cbs.disableAgentTool(agentId, toolName)
      }
      const canonical = await cbs.refetchAgentTools(agentId)
      return { canonical }
    } catch (error) {
      return { error }
    }
  })()

  return { nextLocal, serverPromise }
}
```

Then the Vitest spec:

```ts
// src/apps/desktop/src/__tests__/AppLayout.agentToolsToggle.spec.ts
import { describe, it, expect, vi } from 'vitest'
import { buildToggle } from '../stores/agentToolToggle'

describe('buildToggle (handleAgentToggleTool extracted helper)', () => {
  it('returns nextLocal WITH toolName when enabled=true', () => {
    const r = buildToggle(
      ['bash'], 'read_file', true, 'agent_1',
      { enableAgentTool: vi.fn(), disableAgentTool: vi.fn(), refetchAgentTools: vi.fn() },
    )
    expect(r.nextLocal).toEqual(['bash', 'read_file'])
  })

  it('returns nextLocal WITHOUT toolName when enabled=false', () => {
    const r = buildToggle(
      ['bash', 'read_file'], 'bash', false, 'agent_1',
      { enableAgentTool: vi.fn(), disableAgentTool: vi.fn(), refetchAgentTools: vi.fn() },
    )
    expect(r.nextLocal).toEqual(['read_file'])
  })

  it('nextLocal is idempotent on enable (dedupe)', () => {
    const r = buildToggle(
      ['bash'], 'bash', true, 'agent_1',
      { enableAgentTool: vi.fn(), disableAgentTool: vi.fn(), refetchAgentTools: vi.fn() },
    )
    expect(r.nextLocal).toEqual(['bash'])
  })

  it('calls enableAgentTool when enabled=true', async () => {
    const enableAgentTool = vi.fn().mockResolvedValue({})
    const disableAgentTool = vi.fn()
    const refetchAgentTools = vi.fn().mockResolvedValue(['bash'])
    const r = buildToggle([], 'bash', true, 'agent_1',
      { enableAgentTool, disableAgentTool, refetchAgentTools })
    await r.serverPromise
    expect(enableAgentTool).toHaveBeenCalledWith('agent_1', 'bash')
    expect(disableAgentTool).not.toHaveBeenCalled()
  })

  it('calls disableAgentTool when enabled=false', async () => {
    const enableAgentTool = vi.fn()
    const disableAgentTool = vi.fn().mockResolvedValue({ ok: true })
    const refetchAgentTools = vi.fn().mockResolvedValue([])
    const r = buildToggle(['bash'], 'bash', false, 'agent_1',
      { enableAgentTool, disableAgentTool, refetchAgentTools })
    await r.serverPromise
    expect(disableAgentTool).toHaveBeenCalledWith('agent_1', 'bash')
    expect(enableAgentTool).not.toHaveBeenCalled()
  })

  it('returns the canonical server list via refetchAgentTools', async () => {
    const r = buildToggle([], 'bash', true, 'agent_1', {
      enableAgentTool: vi.fn().mockResolvedValue({}),
      disableAgentTool: vi.fn(),
      refetchAgentTools: vi.fn().mockResolvedValue(['bash', 'read_file']),
    })
    const out = await r.serverPromise
    expect(out).toEqual({ canonical: ['bash', 'read_file'] })
  })

  it('catches API failure and returns { error } (does not throw)', async () => {
    const r = buildToggle([], 'bash', true, 'agent_1', {
      enableAgentTool: vi.fn().mockRejectedValue(new Error('409 Conflict')),
      disableAgentTool: vi.fn(),
      refetchAgentTools: vi.fn(),
    })
    const out = await r.serverPromise
    expect(out).toEqual({ error: expect.any(Error) })
  })
})
```

Run, expect FAIL:

```bash
cd /home/ginwa/.worktrees/agent-tools-toggle-wire
bunx vitest run src/apps/desktop/src/__tests__/AppLayout.agentToolsToggle.spec.ts 2>&1 | tail -n 30
```

Expect "Cannot find module" or compile error — the helper file doesn't exist yet.

- [ ] Failing test confirmed

### Step 4.2 — Implement the helper

Create `src/apps/desktop/src/stores/agentToolToggle.ts` with the `buildToggle` function from Step 4.1 (no changes — the spec drove the design).

Run the tests:

```bash
bunx vitest run src/apps/desktop/src/__tests__/AppLayout.agentToolsToggle.spec.ts 2>&1 | tail -n 30
```

Expect all 7 tests green.

### Step 4.3 — Wire AppLayout.vue to use the helper

Edit `src/apps/desktop/src/components/AppLayout.vue:1072`:

```ts
// Before
async function handleAgentToggleTool(toolName: string, enabled: boolean) {
  // v1.1 wiring. For now, no-op.
  void toolName; void enabled
}
// After
async function handleAgentToggleTool(toolName: string, enabled: boolean) {
  if (!activeWorkspaceItem.value) return
  const agentId = activeWorkspaceItem.value.id
  const { nextLocal, serverPromise } = buildToggle(
    agentTools.value, toolName, enabled, agentId,
    {
      enableAgentTool: api.enableAgentTool,
      disableAgentTool: api.disableAgentTool,
      refetchAgentTools: async (id) => {
        const data = await api.getAgentTools(id)
        return data.tools
      },
    },
  )
  // Optimistic update.
  agentTools.value = nextLocal
  const out = await serverPromise
  if ('error' in out) {
    // Revert + log.
    agentTools.value = enabled
      ? agentTools.value.filter((n) => n !== toolName)
      : [...agentTools.value, toolName]
    console.error('[AppLayout] toggle tool failed:', out.error)
    return
  }
  // Canonical state from server.
  agentTools.value = out.canonical
}
```

Add the import at the top of `<script setup>`:

```ts
import { buildToggle } from '../stores/agentToolToggle'
```

### Step 4.4 — Verify

```bash
cd /home/ginwa/.worktrees/agent-tools-toggle-wire
bunx vitest run src/apps/desktop/src/__tests__/AppLayout.agentToolsToggle.spec.ts 2>&1 | tail -n 20
```

Expect green.

Also run the full frontend test suite to confirm no regressions:

```bash
bunx vitest run 2>&1 | tail -n 20
```

Expect green (2401+ tests pass; the new test brings the count to +7).

### Step 4.5 — Commit

```bash
git add src/apps/desktop/src/components/AppLayout.vue src/apps/desktop/src/stores/agentToolToggle.ts src/apps/desktop/src/__tests__/AppLayout.agentToolsToggle.spec.ts
git commit -m "agent mode: wire handleAgentToggleTool to INSERT/DELETE agent_tools

Closes task_1787213301062_0 (\"agent mode: checklist tool\").

The AgentView Tools panel emits 'toggle-tool' on every checkbox
@change. AppLayout's handler was a no-op stub. This commit wires it:

- enable → POST /api/agents/:id/tools (INSERT row, tool_name)
- disable → DELETE /api/agents/:id/tools/:tool_name (DELETE row)

Optimistic local-first: agentTools.value updates immediately for snappy
UX, then awaits the API. On failure, the local state reverts and
a console.error fires. On success, the canonical server list
(refetched via GET /api/agents/:id/tools) replaces the optimistic
update — handles 409 duplicate gracefully.

Extracted the toggle logic into stores/agentToolToggle.ts so
it's unit-testable without booting the full AppLayout tree
(which has Vue Router, Pinia, etc. dependencies). The Vitest spec
covers: enable/disable branch, dedupe on re-enable, server
promise shape, error catch."
```

---

## Task 5 — Full build + manual smoke

> **Outcome**: All 3 build commands green. Manual smoke confirms a checkbox click persists to `agent_tools`. No port 8081.

### Step 5.1 — Full build

```bash
cd /home/ginwa/.worktrees/agent-tools-toggle-wire
timeout 300 zig build test --summary all 2>&1 | tail -n 30
timeout 180 bun run build 2>&1 | tail -n 30
timeout 180 bunx vitest run 2>&1 | tail -n 30
```

Expect all green. Existing baseline: 2401 pass, 6 skip, 0 fail (from 2026-08-19 cleanup-stale-worker-cron plan). After this plan: +7 inline tests in agent_tools_delete.zig (5 of the 4 originals stay, but one renames + adds a new variant — net 5) + 7 Vitest tests = +12 tests.

Wait — the inline tests are 4 originals, but Step 1.1 rewrites all 4 (still 4). So +0 net from inline. New Vitest file contributes +7. Total: +7 tests, 0 skip, 0 fail.

### Step 5.2 — Manual smoke

```bash
# Terminal 1: backend
cd /home/ginwa/.worktrees/agent-tools-toggle-wire
zig build run -Dport=8080  # custom port to avoid 8081
```

In the desktop app (separate window):
1. Navigate to a workspace, add an Agent (if none exists).
2. Click `bash` in the Tools panel → checkbox ticks.
3. Run `sqlite3 ~/.config/pabrik/main.db "SELECT * FROM agent_tools;"` (or the project DB path) → row exists with `tool_name='bash'`.
4. Click `bash` again → checkbox un-ticks.
5. Re-run the SELECT → row gone.

If any step fails, use `systematic-debugging` skill to diagnose.

### Step 5.3 — Final commit (if smoke surfaced fixes)

```bash
git add -A
git commit -m "agent mode: toggle smoke fixes (if any)"
```

(Only if Step 5.2 surfaced something. Empty if no fixes needed.)

---

## Task 6 — Open PR

> **Outcome**: PR open against `main`, ready for human review. PR description links this plan + the spec.

### Step 6.1 — Push + open PR

```bash
cd /home/ginwa/.worktrees/agent-tools-toggle-wire
git push -u origin worktree/agent-tools-toggle-wire
gh pr create \
  --base main \
  --head worktree/agent-tools-toggle-wire \
  --title "agent mode: wire handleAgentToggleTool to INSERT/DELETE agent_tools" \
  --body "Closes task_1787213301062_0.

Implements docs/superpowers/plans/2026-08-19-agent-tools-toggle-wire.md.

- backend: DELETE /api/agents/:id/tools now uses :tool_name (was :tool_id)
- frontend: handleAgentToggleTool inserts/deletes agent_tools rows
- 7 new Vitest tests; 4 existing inline tests updated (signature rename)"
```

### Step 6.2 — Move kanban to in_review_task

```bash
# Use the kanban_move_task tool with:
#   workspace_id: ws_1785055733544_28e79c9db8950100
#   item_id:      item_1785055824163739523
#   task_id:      task_1787213301062_0
#   target_column_id: col_1826ecca367f0000  (in_review_task)
```

---

## Out of scope (deferred)

- **Per-tool loading spinner** — the API is sub-millisecond; double-click is harmless (UNIQUE → 409). Add only if user reports flakiness.
- **Toast notification on toggle failure** — currently logs to console. A proper notification UI is a separate kanban task.
- **Multi-window sync** — if the user has the same Agent open in two tabs and toggles in one, the other tab's `agentTools` ref stays stale until reload. SSE event for agent_tools mutations is a separate plan (the `on_event_sent.zig` table doesn't yet have an agent_tools channel).
- **`enabled=0` toggle** — the `agent_tools.enabled` column exists but the UI never toggles it. The toggle UX is INSERT/DELETE only. If "temporarily disable without losing config" becomes a use case, add an `enabled` checkbox alongside the `id` checkbox in AgentView.
- **Optimistic update race** — if the user spams toggle rapidly, requests queue up. The current impl awaits each one, so the queue is bounded by user click speed. If this becomes a problem, add a per-tool in-flight flag.
- **DELETE-by-tool_id endpoint** — fully removed by this plan. If a future use case (admin "purge tool row X") needs it, add a second DELETE route `/api/agents/:id/tools/by-id/:tool_id` rather than re-introducing the dual-mode wire.

## Risks

- **The spec said `:toolId`, this plan changes it to `:tool_name`.** The spec was written before the toggle UX was designed. The change is small, the rationale is sound, and there are no external consumers. Mitigation: noted in the plan's "Why the DELETE endpoint needs to change" section; PR description explains the deviation.
- **Optimistic update flicker on slow networks.** If the network is slow, the user sees the checkbox tick, then if the API fails, it un-ticks. Confusing UX. Mitigation: the canonical refetch happens within a few hundred ms in normal conditions; if the user reports flicker, the follow-up is to disable the checkbox during the in-flight period.
- **The `agentToolToggle.ts` helper is a new file.** It contains pure logic that's only used by AppLayout.vue. Could be inlined. Mitigation: extracting it enables the Vitest spec without booting the full AppLayout tree (which has Vue Router, Pinia, etc. dependencies). The cost of the new file is one extra import; the benefit is testability.