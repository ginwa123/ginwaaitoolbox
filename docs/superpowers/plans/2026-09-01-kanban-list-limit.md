# Kanban List — Limit Context Bloat (Pagination)

> **For agentic workers:** Use subagent-driven-development or executing-plans. Steps use checkbox syntax.

**Goal:** `kanban_list` currently dumps ALL tasks (330 on this board) into LLM context. Add `limit`/`offset` pagination with sane defaults so a single call stays lean. Keep backward compat (no limit = capped default).

**Problem:** `src/modules/agent/tools/kanban_list.zig:151` `listKanbanTasks` does `SELECT ... WHERE workspace_item_id = ? ORDER BY ...` with no LIMIT. `executeKanbanListToString` builds `TaskSummary` for every row and `toXml` emits `<task>` for each. On `sprint bulan juni` (item_1785055824163739523) that's 330 `<task>` blocks per call. The agent is *forced* to call `kanban_list` at start (`prompts_make_kanban_context.zig:86`), so every session pays the cost.

**Architecture:** 3 layers, same file:

1. **Input + tool definition** — `KanbanListInput` gains `limit: ?u32` + `offset: ?u32`. Tool `parameters.properties` gains two new optional integer fields. Description documents pagination + defaults.
2. **Storage** — `listKanbanTasks(allocator, db, workspace_item_id, limit, offset)` adds `LIMIT ? OFFSET ?` when limit is set. New helper `countKanbanTasks(allocator, db, workspace_item_id, column_id)` returns total for the `<total_count>` hint. When `column_id` filter is set, both count and list are scoped to that column.
3. **Wire** — `toXml` gains `total_count`, `limit`, `offset`, `has_more` attributes (or child elements). `executeKanbanListToString` computes `has_more = offset+returned < total` and appends `<pagination><total_count>330</total_count><limit>20</limit><offset>0</offset><has_more>true</has_more></pagination>` + a `<hint>` when truncated ("330 tasks total, showing 20 — call kanban_list with offset=20 to see more, or filter by column_id").

**Defaults:** `limit` default 20, max 100, `offset` default 0. When caller omits both, we cap at 20 (not 330). This is a *behavior change* but safe: the LLM can paginate, and the existing `column_id` filter already lets it narrow. No migration, no DB schema change.

**Tech Stack:** Zig 0.16, SQLite via `SqliteBackend`, `std.ArrayList`, `xmlEscape` helper. Tests inline in `kanban_list.zig` (like existing `executeKanbanListToString` tests). Frontend `KanbanList.vue` is display-only — update to show pagination hint if present, but not required for correctness.

## What exists today

- `KanbanListInput { workspace_id, item_id, column_id: ?[]const u8 }` at `kanban_list.zig:60`
- `kanban_list_tool` at `kanban_list.zig:85` with 3 properties, required = workspace_id+item_id
- `listKanbanTasks(allocator, db, workspace_item_id)` at `kanban_list.zig:151` — no limit
- `executeKanbanListToString` at `kanban_list.zig:247` — reads all tasks, builds summaries, calls `toXml`
- `toXml(allocator, workspace_id, item_id, columns, tasks)` at `kanban_list.zig:400` — emits `<kanban><workspace_id>...<columns>...<tasks>...`
- `prompts_make_kanban_context.zig:86` forces `kanban_list` at start
- Tests at `kanban_list.zig:995` etc. cover columns, filtering, validation, empty board

## File Structure

### Edited files

```
src/modules/agent/tools/kanban_list.zig          # Input + tool def + listKanbanTasks + count helper + execute + toXml + tests
src/ai_workflow/tui/agentic_loop/tools_exec_kanban_list.zig  # No change (just passes input through)
src/apps/desktop/src/components/tool_outputs/KanbanList.vue   # Show pagination hint if present
docs/superpowers/plans/2026-09-01-kanban-list-limit.md        # This plan
```

### NOT changed

- `kanban_model.zig` — column storage unchanged
- `tools_equipped.zig` / `tools.zig` — registry unchanged (tool name same)
- `prompts_build_messages_for_agent_prompt.zig` — optional doc update, not required
- No migration, no new table

## Design Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Default limit 20, max 100 | 20 is enough to find your own task in most boards; 100 caps worst-case at ~1/3 of current 330. LLM can paginate with offset. |
| 2 | `limit`/`offset` as `?u32` (nullable) | Mirrors `column_id: ?[]const u8` pattern. Null = use default. Keeps JSON schema simple (integer, not string). |
| 3 | `total_count` + `has_more` in XML | LLM needs to know there are more tasks without counting. `has_more` is a convenience so it doesn't have to do math. |
| 4 | Keep `column_id` filter orthogonal | `column_id` + `limit`/`offset` compose: count and list are both scoped when column_id is set. |
| 5 | No `search` param | Out of scope. The user asked to limit, not to search. Search can be a follow-up. |
| 6 | Worktree outside main folder | User request: `/tmp/kanban-list-limit` (not `~/.worktrees`). |

## Implementation Steps

- [ ] Step 1: Add `limit`/`offset` to `KanbanListInput` + tool definition (2 new properties, update description)
- [ ] Step 2: Add `countKanbanTasks` helper + update `listKanbanTasks` to accept limit/offset and emit LIMIT/OFFSET SQL
- [ ] Step 3: Update `executeKanbanListToString` to parse limit/offset, clamp (1..100, default 20), fetch total, fetch page, build summaries, pass pagination to `toXml`
- [ ] Step 4: Update `toXml` to emit `<pagination>` block + truncated hint
- [ ] Step 5: Update `KanbanList.vue` to render pagination hint (optional, display-only)
- [ ] Step 6: Add tests: default limit caps at 20, limit=5 returns 5, offset=20 returns next page, total_count correct, column_id+limit composes, limit>100 clamped, offset beyond total returns empty
- [ ] Step 7: Verify `zig build test --summary all` + `zig build pabrik-desktop --summary all` + manual `kanban_list` call

## Verification

- `zig build test --summary all` — new tests pass, existing 6+ tests still pass
- `zig build pabrik-desktop --summary all` — 21/21 steps OK
- Manual: `kanban_list` with no limit returns 20 tasks + `<total_count>330</total_count><has_more>true</has_more>`; with `limit=5 offset=10` returns 5 tasks starting at position 10; with `column_id=col_...` returns only that column's tasks capped by limit
