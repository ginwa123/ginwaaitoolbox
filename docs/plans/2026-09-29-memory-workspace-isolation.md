# Per-workspace isolation for `save_memory` / `load_memory`

**Date:** 2026-09-29
**Task:** `task_1790706267782_3` — "is tool load_memory, save_memory, have column workspace_id ?" → "we need to isolate per workspace, so another workspace cannot see the memory"

## Problem

`agent_memories` (Migration 070) has no owner column at all:

```
id | content | tags | created_at | updated_at
```

The `save_memory` tool description said so in as many words:

> Global scope: memories are visible across all workspaces and sessions.
> There is no per-workspace filter.

Every workspace on a machine shared one note pool. A note written while
working on project X was recalled verbatim by an agent whose cwd was
project Y, and `load_memory {id}` returned the *full* body (up to 1 MiB,
no snippet cap) of a note belonging to a different workspace.

## Design

### Scope is server-side, never a tool parameter

`workspace_id` is a plain function parameter on
`memory.executeSaveMemory` / `executeLoadMemory`, resolved in
`tools_exec_memory.zig` from `ctx.session_id` via the existing
`workspace_scope.resolveWorkspaceId`. It is deliberately **absent** from
`SaveMemoryInput` / `LoadMemoryInput` and from both tool schemas, so
there is no JSON payload — however crafted — that moves a read or a
write into another workspace. This mirrors `read_workspace_session`,
which scopes itself the same way.

### Both read paths are scoped

| Path | Function | Scope |
|---|---|---|
| FTS search | `loadMemoriesByFts` | `AND m.workspace_id = ?` **inside** the FTS subquery |
| by-id lookup | `getMemoryById` | `WHERE id = ? AND workspace_id = ?` |
| `with_content` hydration | `getMemoryById` | same scoped call |

The by-id path is the one that would leak most (full content, no snippet
cap), so it is the one that must never be reachable cross-workspace. A
cross-workspace by-id miss is reported as `not found`, not as `denied` —
"denied" would confirm the id is real.

The workspace filter sits inside the subquery on purpose:
`COUNT(*) OVER ()` is evaluated over the subquery's rows, so a filter
applied outside would report the *global* match count next to a
workspace-scoped `results` array, and the agent would page with an
`offset` derived from rows it can never see.

### `''` is a bucket, not an exemption

`workspace_id TEXT NOT NULL DEFAULT ''` — `''` means "this session has no
workspace". `saveMemory` **omits** the column when the id is empty so the
schema `DEFAULT` applies; binding a zero-length slice would land as SQL
NULL (`SqliteBackend.exec` → `sqlite3_bind_null`) and violate NOT NULL.

A session that cannot be resolved (bare CLI chat, cwd matching no
`workspace_items.path`) writes into `''`, which is shared with other
workspace-less sessions and invisible to every real workspace. Fail-closed
in the direction that matters, without turning the tool off for the
workspace-less case.

### No FTS reindex

`agent_memories_fts` still indexes `content` + `tags` only. The filter is
a JOIN predicate on the source table (the query already joins
`agent_memories` for `snippet()`), so there is no FTS rebuild, no trigger
change and no re-tokenization.

## Legacy rows

Pre-existing rows (329 on the dev machine) backfill to `''` for free —
`NOT NULL DEFAULT ''` on an ADD COLUMN is an O(1) metadata change. They
stop being visible to workspace sessions. That is intentional: re-homing
300+ rows that span every workspace the user ever typed into would either
guess a workspace or copy the same note into all of them, and the second
is the exact leak this change exists to close.

To keep one:

```sql
UPDATE agent_memories SET workspace_id = 'ws_...' WHERE id = 'mem_...';
```

## Files touched

- `src/migrations/migration.zig` — Migration 095 `add_workspace_id_to_agent_memories`,
  registered in `allMigrations`, + 3 inline tests
- `src/agentic_loop/agent_memories.zig` — `SaveMemoryArgs.workspace_id`,
  `MemoryRow.workspace_id`, scoped `getMemoryById`, `LoadOptions.workspace_id`,
  dynamic INSERT, + 4 inline tests
- `src/modules/agent/tools/memory.zig` — `workspace_id` threaded through
  `executeSaveMemory` / `executeLoadMemory` / `executeById` / the
  `with_content` loop, echoed in both success payloads, descriptions and
  system prompt rewritten
- `src/agentic_loop/tools_exec_memory.zig` — `resolveScope` from
  `ctx.session_id`, + 2 inline tests

## Tests

- `saveMemory` stamps `workspace_id`; an empty one lands in `''` (not NULL)
- `loadMemoriesByFts` never returns another workspace's rows, and
  `total_count` is the scoped count
- `getMemoryById` returns null for another workspace's id
- legacy `''` rows are invisible to workspace sessions, visible to `''`
- exec layer: two sessions in two workspaces, isolation end to end
  (search + by-id + the `workspace_id` echo)
- exec layer: an unresolvable session writes to `''`
- Migration 095: backfill, index, idempotency, registration
