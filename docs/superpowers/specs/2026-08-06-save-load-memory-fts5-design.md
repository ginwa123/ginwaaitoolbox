# Spec: `save_memory` + `load_memory` tools (SQLite FTS5)

**Date:** 2026-08-06
**Task:** `task_1785958319567`
**Branch:** `worktree/save-load-memory-fts5`

## Context

The agent has two existing memory surfaces, neither of which fits the
"short, structured note with full-text search" use case:

1. **File-based memories** (`src/modules/agent/tools/memories.zig`) —
   markdown files in `~/.config/nalar/memories/` and `<cwd>/.nalar/memories/`.
   `list_memory` enumerates them by H1 title. Already large, no
   search — `read_file` is the only way to look at content.
2. **LLM history** (`llm_history` + `messages_fts`) — every chat
   turn. Inadvertently used as a "memory" by agents who
   the legacy history search for past facts, but polluted with tool outputs
   and limited to session-driven rows.

The gap: the agent needs to **persist a note** ("remember: the user
prefers `claude-sonnet-4-5` for this project" / "remember: the user's
company is XYZ") and **recall it later** via free-text search. The
existing file-based memories are too heavy (markdown, no FTS5); the
the existing legacy history search is the wrong surface (it's for forensic
search of past messages, not for first-class notes).

## Mental model

Two new LLM-callable tools that operate on a dedicated `agent_memories`
SQLite table + `agent_memories_fts` FTS5 virtual table:

- **`save_memory`** — append-or-update a note tagged with optional
  tags. Returns the persisted `id` + `created_at` / `updated_at`.
- **`load_memory`** — FTS5 search over note content + tags. Returns
  ranked hits with snippets.

This is a **second, separate memory system** that does NOT replace
the existing file-based memories. The two are complementary:

| System | When to use |
|---|---|
| `list_memory` / `read_file` (file-based) | Long-form markdown knowledge: project docs, system prompts, how-tos |
| `save_memory` / `load_memory` (SQLite FTS5) | Short, structured notes: facts, preferences, decisions, lookup keys |

The new tools live in the same `nalar` SQLite database the rest of
the agent uses (so they survive project resets via the existing
backup mechanism), keyed by a unique `id` the agent picks or that
the tool auto-generates as `mem_<unix_ms>`.

## Wire shape

### `save_memory`

```json
{
  "content": "User's preferred model: claude-sonnet-4-5 (set 2026-08-06)",
  "tags": ["preferences", "user"],
  "id": "user-preferred-model"          // optional
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `content` | string | yes | 1 KiB – 1 MiB. The note text. |
| `tags` | string[] | no | Optional labels. Stored as `\|\|`-joined string (matches `image_urls` / `kanban-row-tags` conventions). FTS5-indexed. |
| `id` | string | no | Caller-provided slug. If it matches an existing row → UPSERT (update content + tags). If absent → INSERT with auto-generated `mem_<unix_ms>`. |

Response:
```xml
<save_memory>
  <id>user-preferred-model</id>
  <created_at>2026-08-06 14:30:12</created_at>
  <updated_at>2026-08-06 14:30:12</updated_at>
</save_memory>
```

### `load_memory`

```json
{
  "query": "preferred model",
  "tags": ["preferences"],               // optional AND filter
  "limit": 10,                          // default 10, max 50
  "offset": 0                           // for pagination
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `query` | string | yes | FTS5 phrase. Sanitized via `escapeFtsQuery` (existing helper). |
| `tags` | string[] | no | AND filter: every tag must be present in the row's tags. Empty = no filter. |
| `limit` | number | no | Default 10, max 50. |
| `offset` | number | no | Default 0. Use `<total_count>` to know when to stop. |

Response:
```xml
<load_memory query="preferred model" limit="10" offset="0">
  <count>2</count>
  <total_count>2</total_count>
  <results>
    <memory id="user-preferred-model" tags="preferences,user" created_at="2026-08-06 14:30:12" updated_at="2026-08-06 14:30:12">
      <snippet>User's preferred model: claude-sonnet-4-5 (set 2026-08-06)</snippet>
    </memory>
    <memory id="...">
      <snippet>... [match] ...</snippet>
    </memory>
  </results>
</load_memory>
```

Snippets use FTS5's `snippet()` with the same 10-token / `[match]`
marker convention as the legacy history search (the LLM can see what matched).

## Architecture

### Migration 070 — `agent_memories` + `agent_memories_fts`

```sql
CREATE TABLE IF NOT EXISTS agent_memories (
    id TEXT PRIMARY KEY,
    content TEXT NOT NULL,
    tags TEXT NOT NULL DEFAULT '',                     -- ||-joined
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_agent_memories_updated ON agent_memories(updated_at DESC);

CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts USING fts5(
    content,
    tags,
    tokenize='porter unicode61 remove_diacritics 2',
    content='agent_memories',           -- external-content
    content_rowid='rowid'
);

-- Sync triggers (mirrors messages_fts pattern from migration 058)
CREATE TRIGGER IF NOT EXISTS agent_memories_ai AFTER INSERT ON agent_memories BEGIN
  INSERT INTO agent_memories_fts(rowid, content, tags) VALUES (new.rowid, new.content, new.tags);
END;
CREATE TRIGGER IF NOT EXISTS agent_memories_ad AFTER DELETE ON agent_memories BEGIN
  INSERT INTO agent_memories_fts(agent_memories_fts, rowid, content, tags) VALUES('delete', old.rowid, old.content, old.tags);
END;
CREATE TRIGGER IF NOT EXISTS agent_memories_au AFTER UPDATE ON agent_memories BEGIN
  INSERT INTO agent_memories_fts(agent_memories_fts, rowid, content, tags) VALUES('delete', old.rowid, old.content, old.tags);
  INSERT INTO agent_memories_fts(rowid, content, tags) VALUES (new.rowid, new.content, new.tags);
END;
```

**Why external-content (per migration 058's lessons learned):** the
external-content form lets the FTS5 table act as a view over the
source table, saving disk space. The `snippet()` / `highlight()`
helpers work on external-content tables WHEN the query reads BOTH
the FTS table AND the source table via a JOIN — see
`searchMessagesFts` in `llm_history.zig` for the exact pattern to
copy.

### Tool files (new)

```
src/modules/agent/tools/save_memory.zig          + save_memory_test.zig
src/modules/agent/tools/load_memory.zig          + load_memory_test.zig
```

Pattern mirrors `kanban_list.zig` + the legacy history tool file:
- `*_tool` constant (`AgentTool` shape)
- `execute_*` function returning XML
- `successXml` / `errorXml` helpers
- Inline `*_test.zig` file (per `agentic_loop/` convention)

### Exec wrappers (new)

```
src/ai_workflow/tui/agentic_loop/tools_exec_save_memory.zig
src/ai_workflow/tui/agentic_loop/tools_exec_load_memory.zig
```

Pattern mirrors `tools_exec_kanban_list.zig` (parse → exec → wrap → detect `<error>`).

### Registration

- `tools.zig` — add `pub const save_memory = @import("save_memory.zig");` + `pub const load_memory = ...;`
- `tools_equipped.zig` — add to `all_agent_tools` and to the `tool_dispatch` `.exec` table
- `nalarcore` re-export via `src/root.zig`

### Frontend

**No frontend changes.** Both tools are LLM-side only. The user
sees the agent save/load memory via the conversation transcript
only (same UX as the legacy history search, `bash`, etc.).

## Architecture decisions

1. **Two tools, not one with `action` param.** The user explicitly
   asked for "save memory" and "load memory" — two separate tool
   names. Matches the existing tool surface (`add_skill` /
   `edit_skill` / `view_skill` are separate, not one `skill` tool).

2. **Global-only scope for v1.** No workspace_id, no session_id.
   The use case is "remember this across sessions, across projects."
   Workspace-scoping is a separate feature; defer.

3. **Caller-provided `id` slug, with auto-fallback.** The agent
   should be able to update a memory by providing its slug (e.g.
   `"user-preferred-model"`). Without an id, we generate
   `mem_<unix_ms>` for the create case. Matches the convention
   `llm_history` uses for message ids.

4. **Tags as `||`-joined string.** Matches `image_urls` (Migration
   069) and `tags` (Migration 067) — the project standard for
   string-list columns. Avoids json serialization overhead at the
   SQL layer.

5. **FTS5 sanitization via existing `escapeFtsQuery`.** Don't
   reinvent; reuse the same FTS helper the legacy history search uses. User
   input with `.`, `-`, `:`, `*`, etc. is already handled.

6. **`count` cap on `load_memory` is 50 (not 200 like the legacy history search).**
   Memory loads are typically more focused (the agent is
   retrieving a specific note) — 50 hits is plenty. Matches the
   `kanban_list` 50-row cap convention.

7. **No `delete_memory` in v1.** YAGNI. The agent can overwrite
   a memory by saving with the same id (UPSERT). Explicit deletion
   is a hygiene feature that can land in a follow-up if the user
   asks.

8. **Per-row size cap: 1 MiB. Total cap: 10K rows.** These are
   sane defaults to prevent a runaway agent from filling the DB.
   Caps are configurable in the tool description (the LLM sees them
   in the agent's prompt and self-limits).

9. **Tags are FTS5-indexed.** The agent can search by tag (`tags:
   "preferences"`) the same way it searches by content. The user's
   `tags` field is `||`-joined; the FTS5 tokenizer splits on `|`
   just like any other non-word character.

10. **Snippets use `snippet(agent_memories_fts, 0, '[', ']', '…', 10)`.**
    Same 10-token window + `[match]` markers as `messages_fts`. LLM
    sees `... [match] ...` and knows what matched.

## Test plan

### `migration_070_test.zig` (5 tests)

- A: column exists, schema is right
- B: idempotent on re-run
- C: pre-existing rows backfill into the FTS5 table
- D: insert/update/delete triggers stay in sync with the source table
- E: registered in `allMigrations`

### `save_memory_test.zig` (8 tests)

- A: insert with no id → auto-generated `mem_<unix_ms>` id
- B: insert with explicit id → uses the caller-provided id
- C: insert with same id twice → UPDATE (UPSERT), updated_at bumps
- D: row count grows by 1 on insert, unchanged on UPSERT
- E: tags `||`-joined for storage, split on retrieval
- F: empty content → `<error>` (1 KiB minimum)
- G: content > 1 MiB → `<error>` (truncate/reject?)
- H: returns consistent `id` + `created_at` + `updated_at`

### `load_memory_test.zig` (10 tests)

- A: empty query → `<error>`
- B: FTS5 sanitization (queries with `.`, `-`, `:` don't crash)
- C: phrase match returns ranked hits
- D: snippet contains `[match]` markers
- E: tags filter AND-narrows the result set
- F: limit + offset paginate correctly
- G: total_count reflects the full filtered set
- H: 0 results → `<count>0</count>` + empty `<results>`
- I: limit > 50 capped to 50
- J: insert + UPSERT + search round-trip

### Tool wiring tests (3 tests in each test file)

- tool name is correct
- tool is present in `UNIFIED_TOOL_REGISTRY`
- description mentions FTS5 + matches the user's request

## Open questions for the user

1. **Scope confirmation:** Global only (no workspace_id / session_id)?
   Or do you want workspace-scoped memories too?
2. **Auto-generated id format:** `mem_<unix_ms>` (predictable, no
   collision) or random `mem_<16-hex>` (collision-free, no
   timestamp leak)?
3. **Delete in v1:** skip (rely on UPSERT), or include a `delete_memory`
   tool?
4. **Per-row size cap:** 1 MiB per memory (reasonable for notes,
   prevents abuse)? Or unlimited?
5. **Should `save_memory` overwrite existing memories WITHOUT comparing
   tags first?** (current design: blind UPSERT — content + tags
   both replaced.)

## Affected files

| File | Change |
|---|---|
| `src/migrations/migration.zig` | + `Migration070AddAgentMemories` |
| `src/migrations/migration_070_test.zig` | NEW (5 tests) |
| `src/migrations/test_runner.zig` | + register the new test |
| `src/modules/agent/tools/save_memory.zig` | NEW (tool + execute*) |
| `src/modules/agent/tools/save_memory_test.zig` | NEW (8 tests) |
| `src/modules/agent/tools/load_memory.zig` | NEW (tool + execute*) |
| `src/modules/agent/tools/load_memory_test.zig` | NEW (10 tests) |
| `src/modules/agent/tools/tools.zig` | + re-exports |
| `src/ai_workflow/tui/agentic_loop/tools_exec_save_memory.zig` | NEW |
| `src/ai_workflow/tui/agentic_loop/tools_exec_load_memory.zig` | NEW |
| `src/ai_workflow/tui/agentic_loop/tools.zig` | + `execSaveMemory` / `execLoadMemory` declarations |
| `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` | + entries in `all_agent_tools` + `.exec` table |
| `src/root.zig` | + `nalarcore.save_memory` / `nalarcore.load_memory` re-exports |
| `docs/SPEC.md` | + changelog row |
| `AGENTS.md` | + changelog block |

## Out of scope (deferred)

- `delete_memory` tool (rely on UPSERT for "delete + recreate")
- Workspace-scoped / session-scoped memories
- Per-workspace memory count limits
- Memory TTL / expiration
- Migration of existing file-based memories into the new SQLite store
- Frontend UI (memory manager pane)
- Memory deduplication (the agent can re-save with the same id)
- Cross-language / cross-machine memory sync

## Verification

- `zig build test --summary all` — all tests pass, no leaks
- `zig build install:linux:system` — compiles
- `rm -rf zig-out/bin && zig build` — all 3 binaries produced
- Cross-compile smoke: `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` + `-target aarch64-macos` — clean
- Live smoke on port 8080: save a memory → load with FTS5 query → confirm hit
