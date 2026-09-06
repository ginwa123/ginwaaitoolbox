# Plan: Default agent tools on workspace item (agent / kanban) creation

Date: 2026-09-06
Task: `task_1788683896254_0` — "when i create workspace items agent or kanban, the agents tools is empty"
Type: PLAN ONLY (no code in this task; implementation is a follow-up)

## 1. Problem

Creating a workspace item today leaves tools empty:

- `POST /api/workspaces/:ws/items/agent` → inserts `workspace_items (agent)` + `agents` row, **zero rows** in `agent_tools`. Doc header says it explicitly (`workspace_items_create_agent.zig:25-27`: "No seed data — empty tool allowlist, zero tools by default per spec D1 — secure-by-default").
- `POST /api/workspaces/:ws/items/kanban` → inserts `workspace_items (kanban)` + 3 `kanban_columns`, **no `agent_kanbans` row at all** and zero rows in `agent_kanban_tools`. First tool enable lazily `INSERT OR IGNORE`s the parent (`agent_kanban_tools_create.zig:118-123`).

User-visible symptom: open Tools tab right after creation → `0 / N enabled`, unconfigured banner (`KanbanToolsPanel.vue:285-300` `kanban-tools-unconfigured`), preset row "Use recommended starter set" (`:421-446`). Agent-view mirror shows "No visible tools are enabled" (`AgentView.vue:333`). The agent therefore does nothing useful until the user hand-ticks tools.

User ask: seed a sensible default toolset at creation time so a fresh agent/kanban is immediately usable.

## 2. Current state (verified 2026-09-06)

| Path | Handler | Tables written | Tools seeded |
|---|---|---|---|
| agent | `src/ai_workflow/tui/http_handlers/workspace_items_create_agent.zig:120-142` (BEGIN/COMMIT, 2 INSERTs) | `workspace_items` + `agents (id, workspace_item_id)` | none |
| kanban | `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig:148-154` (single INSERT + `kanban_model.seedDefaultColumns`) | `workspace_items` + 3× `kanban_columns` | none (no `agent_kanbans` row either) |
| kanban tools CRUD | `agent_kanban_tools_{list,create,delete}.zig`, routes `src/main.zig:487-489` | `agent_kanban_tools (id, kanban_id, tool_name, enabled=1)` + lazy parent seed | opt-in only |
| agent tools CRUD | `agent_tools_{list,create,delete}.zig`, `agents_get.zig:175` | `agent_tools (UNIQUE(agent_id,tool_name))` | opt-in only |

Key semantics that constrain the design:

1. **Empty means different things per world.** Agent world: empty allowlist → `""` → zero tools (secure-by-default, `workflow.zig:415-422`, `agent_tools_allowed.zig:11-18`). Kanban world: `names.len==0` → `return false`, caller defaults untouched, never passes `""` (`workflow.zig:2198-2202`, comment `:2145-2146`). So seeding kanban tools is *enabling an override* that previously didn't exist; seeding agent tools is *relaxing* secure-by-default.
2. **Only frontend "default" today is a preset, not data.** `KanbanToolsPanel.vue:76-79` `RECOMMENDED_TOOLS = ['command','read_file','write_file']`, `handleApplyRecommended (:185-224)` POSTs each. `bash`/`pwsh` are dead names (removed 2026-09-04, `UnknownTool` — `agent_kanban_tools_create.zig:305-313`).
3. **Only creation-time seeding precedent is kanban columns** (`kanban_model.seedDefaultColumns`, `kanban_model.zig:207-227`: todo/in-progress/done). Knowledge / system-prompt / tools have never been seeded.
4. **Registry is canonical.** `tools_equipped.UNIFIED_TOOL_REGISTRY()` is the `isKnownTool` gate (`agent_kanban_tools_create.zig:73-79`); anything seeded must be a subset of it or creation returns 400/500.

## 3. Goal / non-goals

Goal: fresh `agent` and fresh `kanban` items are born with a small, safe, immediately-useful toolset so the user can chat/run without opening the Tools tab first.

Non-goals (follow-ups, not this plan):
- No per-workspace / per-user customizable default set, no settings UI.
- No migration backfilling existing empty items (creation-path only; existing boards stay as-is).
- No schema change, no new endpoint, no new SSE event.
- No change to `design` / `folder` item types.

## 4. Proposed default set

Seed exactly the frontend's existing curated set so backend and UI agree:

```
DEFAULT_TOOLS = ['command', 'read_file', 'write_file']
```

Why this set:
- Already user-vetted as "safe-by-default starter set" (`KanbanToolsPanel.vue:76-79` comment).
- `command` is the unified shell (post-2026-09-04 `bash`/`pwsh` removal); `read_file`/`write_file` are the minimal file loop. No destructive tools (`remove_file`, `text_replace`), no network/browser, no git-worktree, no memory/skill writes.
- Both `agent_tools` and `agent_kanban_tools` accept all three (all in `UNIFIED_TOOL_REGISTRY`).

Open question for owner (confirm before implementing): **same 3 for both worlds, or richer for `agent`?** Recommendation: same 3 for both — one constant, one mental model, frontend preset row stays as fallback. If `agent` wants more later, extend the constant once.

Single source of truth: new shared helper (e.g. `src/ai_workflow/tui/agentic_loop/default_tools.zig` or a `pub const DEFAULT_TOOLS` next to `tools_equipped`) returning `&[_][]const u8{"command","read_file","write_file"}`. Both create handlers + frontend preset import it conceptually (frontend keeps its local const but comment-points at backend constant; no codegen needed).

## 5. Implementation steps

### Step 1 — shared constant + seed helper (backend, 1 new file or 1 new fn)

- Add `pub const DEFAULT_AGENT_TOOLS: []const []const u8 = &.{ "command", "read_file", "write_file" }` near `tools_equipped.UNIFIED_TOOL_REGISTRY`.
- Add `seedDefaultTools(allocator, db, parent_id, table_kind)` that loops the constant and INSERTs with `enabled=1`, id prefixes `at_<nanos>_<i>` for `agent_tools` / `akt_<nanos>_<i>` for `agent_kanban_tools` (matches existing `agent_kanban_tools_create.zig:126-127` convention). Use `INSERT OR IGNORE` so a retry never 409s. Validate each name against `isKnownTool`/registry at seed time; on unknown, log + skip (never fail creation because the registry renamed a tool).
- Unit-test the helper in isolation (all-3-inserted, idempotent re-run, unknown-name skipped).

### Step 2 — agent creation path (`workspace_items_create_agent.zig:120-142`)

- Inside the existing BEGIN/COMMIT (so the 3rd write is atomic with the first two), after the `agents` INSERT, call `seedDefaultTools(..., item_id, .agent_tools)`.
- New error variant `SeedToolsFailed` → map to 500 like `DatabaseError`; on seed failure ROLLBACK (via existing `errdefer ROLLBACK`) so we never leave a half-seeded agent. Alternative (softer): swallow + log like kanban's `seed-listColumns` non-fatal path (`workspace_items_create_kanban.zig:163-180`) — **recommend hard-fail/rollback** for agent because empty here means zero-tools agent (broken), whereas kanban empty just means no-override (harmless). Call out the choice in the impl PR.
- Update doc header `:25-27` (remove "empty tool allowlist" line, point at `DEFAULT_AGENT_TOOLS`).
- Note existing oddity at `:136-139`: second bind is `input.workspace_id` where `workspace_item_id` is expected — do NOT fix in this PR, just don't propagate the pattern into the seed helper (bind `item_id` twice: `id=item_id, agent_id=item_id`).

### Step 3 — kanban creation path (`workspace_items_create_kanban.zig:148-154`)

- After `seedDefaultColumns`, `INSERT OR IGNORE INTO agent_kanbans (id, workspace_item_id) VALUES (?, ?)` with `(item_id, item_id)` (same shape as `agent_kanban_tools_create.zig:120-123`), then `seedDefaultTools(..., item_id, .agent_kanban_tools)`.
- Wrap the whole sequence (workspace_item INSERT + columns + agent_kanbans + tools) in BEGIN/COMMIT — currently kanban has **no transaction** (unlike agent). Add it; map seed failure to existing `SeedFailed`.
- No SSE for tools (columns already emit `kanban_column created x3`; tools have no SSE today — keep it that way).
- Response envelope `CreateKanbanResponseFull {item, columns}` stays unchanged (don't add `tools` — saves a frontend contract bump; the Tools tab reads via existing `GET .../agent_kanban` bundle on mount).

### Step 4 — frontend (minimal)

- No required change: `KanbanToolsPanel.load()` will now see `config != null, tools=[command,read_file,write_file]` on a fresh board, so the unconfigured banner (`:285-300`) and preset row (`:421-446`, gated on `enabledCount===0`) simply stop appearing for new items — correct behavior for free.
- Optional polish (same PR or follow-up): keep the preset row as-is (harmless fallback for pre-existing empty boards); update its comment to note backend now seeds the same set at creation.
- `AgentView` empty states unchanged (only pre-existing agents hit them).

### Step 5 — tests

- Zig unit (in-file, mirroring existing style):
  - `workspace_items_create_agent_test`: fresh create → `SELECT tool_name FROM agent_tools WHERE agent_id=?` returns exactly the 3 defaults sorted; seed is inside the transaction (forced failure rolls back workspace_item too).
  - `workspace_items_create_kanban_test`: fresh create → `agent_kanbans` row exists + `agent_kanban_tools` has exactly the 3 defaults; legacy `seedDefaultColumns` still 3 columns.
  - `default_tools_test`: idempotent re-seed (no dupes via OR IGNORE), unknown registry name skipped.
- Functional (harness, per repo rule — replay the exact frontend wire bodies):
  - `POST /api/workspaces/:ws/items/agent {name, path}` → `GET .../items/:id/agent` bundle shows 3 tools.
  - `POST /api/workspaces/:ws/items/kanban {name, path?}` → `GET /api/agent-kanbans/:id/tools` shows 3 tools; `GET .../items/:item/tools` bundle non-null (previously 404 NotConfigured).
  - Pre-existing empty board (created before this change) still returns `[]`/404-null — no backfill.
- Full gates: `zig build test --summary all`, `pnpm test:unit` (if frontend touched), `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/<new>_test.py -v`. Never `curl` a live 8081 server (mandatory repo rule — use the harness on another port).

## 6. Risks / edge cases

1. **Secure-by-default reversal (agent world).** Seeding relaxes spec D1 (`2026-08-15-agent-mode-design.md:291`). Mitigation: the 3 tools are read/write-local + shell — the same set the UI already one-clicks; destructive/network tools stay opt-in. Call out in PR description.
2. **Kanban D5 semantics.** Seeded kanban now always overrides (`maybeOverrideAllowedToolsForKanban` returns true). Previously unconfigured boards ran caller defaults. The 3-tool override is narrower than full defaults, so behavior changes only from "all tools" → "3 tools" for fresh boards. Existing boards unaffected (no backfill).
3. **Registry drift.** If a default name is ever removed from `UNIFIED_TOOL_REGISTRY`, creation must not 500. Helper skips unknown names with a `log.warn` (same non-fatal philosophy as kanban's seed-listColumns path).
4. **ID collisions.** `unixTimestampNanos` twice in one request could collide if called in the same nanosecond — suffix seed ids with `_<index>` (or reuse one timestamp + index suffix) to keep `id` PK unique.
5. **The `agents.workspace_item_id = workspace_id` oddity** (`workspace_items_create_agent.zig:138`). Out of scope; flag in PR, don't fix here.
6. **No migration.** Creation-path only. If owner later wants backfill, that's a separate `INSERT ... SELECT ... WHERE NOT EXISTS` migration — explicitly not in this plan.

## 7. Verification (impl PR must show)

- `zig build test --summary all` green (new unit tests included).
- New functional test file green via harness (agent + kanban fresh-create paths + legacy-empty-board untouched).
- Manual: create agent → Tools tab shows 3 enabled, no banner; create kanban → Settings → Tools shows 3 enabled, no banner; disable one → persists; old empty board still shows banner + preset row.

## 8. Files to touch (impl PR estimate: ~4 EDIT + 1 NEW + 2 test)

- NEW: shared `default_tools` helper (or const + fn next to `tools_equipped.zig`).
- EDIT: `src/ai_workflow/tui/http_handlers/workspace_items_create_agent.zig` (seed in txn + doc header + test).
- EDIT: `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig` (txn wrap + parent seed + tools seed + test).
- EDIT (comment-only, optional): `KanbanToolsPanel.vue:76-79` preset comment → point at backend constant.
- NEW: `tests/functional/agent_tools_defaults_test.py` (or extend `agent_tools_toggle_test.py`).
- No migration, no route change (`src/main.zig` untouched), no SSE contract change.
