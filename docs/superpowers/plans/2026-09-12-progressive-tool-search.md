# Progressive Tool Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop injecting MCP tool schemas into the LLM context. Add three agent tools — `search_tool`, `view_tool`, `use_tool` — so the agent searches, inspects and equips an MCP tool on demand, recording what it equipped per session in a new `session_progressive_tool` table. Built-in tools are untouched and keep being injected exactly as today.

**Architecture:** One behavioural change at the existing single choke point. `filterAndMergeTools` (`src/agentic_loop/workflow.zig:1739`) currently returns `base_tools ++ mcp_tools` (`:1782-1786`) — unbounded, undeduped, uncapped. It becomes `base_tools ++ (mcp_tools ∩ session_progressive_tool)`, so MCP tools reach `tools[]` only after `use_tool` recorded them. Everything upstream (the fetch-once MCP cache, the `mcp_<server>_<tool>` naming, the dispatch path in `handle_mcp_tool.zig`) is reused unchanged. The three new tools are exempt from the `allowed_tools` allowlist (as MCP tools already are) and are only injected when the MCP catalog is non-empty, so sessions without MCP servers are byte-identical to today.

**Tech Stack:** Zig 0.16 (`AgentTool` + `ToolExecContext` + `wrapToolOutput`), SQLite (Migration 085 `session_progressive_tool`), Vue 3 + vitest (tool-output cards), python functional harness (isolated tmpdir HOME + the repo's existing hello-world MCP servers).

## Global Constraints

- **Built-ins are not touched.** Every built-in tool that survives the `agent_tools` / `agent_kanban_tools` allowlist is injected exactly as today, in the same order. No tiering, no deferral, no renaming.
- **MCP schemas must not reach `tools[]` unless equipped.** That is the entire point of the change.
- **The three tool names are exactly** `search_tool`, `view_tool`, `use_tool`. Zig const naming: put all three in one new module `src/modules/agent/tools/progressive_tools.zig` and import it in `tools_equipped.zig` as `progressive_tools_mod`. Do **not** name the import or any const `search_tool*` unqualified — `tools_equipped.zig:55` already has `search_tool_mod = nalarcore.search_tool` (the codebase-search tool) and its AgentTool const is `search_tool` (`search.zig`). Qualified access keeps them distinct; a bare `const search_tool = …` in `tools_equipped.zig` would collide.
- **`use_tool` must never insert when the tool is already equipped.** Two layers: an explicit `isEquipped` check (returns `inserted=false`, no write) and `PRIMARY KEY(session_id, tool_name)` + `INSERT OR IGNORE` as the DB-level guard.
- **Never register an unknown name.** `use_tool` validates against the live MCP catalog first; an unknown name returns `<equipped>false</equipped>` and writes nothing.
- **Never touch the process on port 8081.** Functional tests use the harness's random port.
- Per-request arena: `ctx.allocator` is arena-backed — do NOT `defer free` arena slices inside exec adapters.
- No `// NEW (plan: …)` comments.
- Verification gates: `zig build test --summary all`, `pnpm test:unit` (from `src/apps/desktop`), `bun run build`, and `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/<file> -v` (rebuild with `zig build install:linux` first — `zig build nalar-desktop` does NOT produce `nalarcore-linux-x86_64`).

## Current State (verified 2026-09-12 in this worktree)

| Step | Where | What |
|---|---|---|
| MCP catalog fetch | `workflow.zig:573-586` | once per process into `mcp_tools`; cache lives on the singleton (`src/root.zig:119`, `getMcpToolsCached` `:302`, `storeMcpToolsCache` `:315`); absent cache → `fetchMcpToolsFresh` (`workflow.zig:370`) |
| MCP live refresh | `workflow.zig:626-647` | re-fetch + re-point `mcp_tools` when config invalidates the cache |
| Naming | `prompts_build_messages_for_agent_prompt.zig:526-537` | `convertMcpToolsToAgentTools` builds `mcp_<server>_<tool>`; `required` is currently always empty (TODO `:580-585`) |
| Merge | `workflow.zig:1739-1789` | `filterAndMergeTools`: allowlist filter → sub-agent strip → `appendSlice(base)` then `appendSlice(mcp)`. **MCP bypasses the allowlist**; no dedup, no cap |
| Consumed | `workflow.zig:1022` → `:1028` (prompt) + `:1050` (LLM call) | once per loop iteration; both read the same `merged_tools` |
| MCP dispatch | `handle_mcp_tool.zig` | parses the `mcp_` prefix and matches the live cache — **independent of whether the tool was in `tools[]`** |
| Built-in allowlist | `agent_tools` (Mig 076) / `agent_kanban_tools` (Mig 081) | read by `maybeOverrideAllowedToolsForAgent` (`workflow.zig:1997`) and `…ForKanban` (`:2077`) |
| Existing test to rewrite | `workflow.zig:2426-2467` | `"filterAndMergeTools: MCP tools appear in agent tool list (agent sees MCP)"` — asserts the old contract |
| Persistence precedent | `session_skills` (Mig 008, column renamed in 075) + `saveSkill`/`getSessionSkills` (`llm_history.zig:3678-3759`) | the shape to mirror |
| Next free migration | **085** (084 = `workspace_routines`) | |

Why the cost is worth attacking here and not on built-ins: built-ins are **bounded** (37 registered, `tools_equipped.zig:66-119`) and already curated per agent/kanban by the user, so their schemas are stable across a session. The MCP count is **unbounded** and decided by whoever wrote the server — a Context7-style server adds 30+ tools, several servers add hundreds, and a search_history-shaped description on one of them costs ~6 KB on its own. Every MCP schema currently ships on every LLM call of every session, forever.

## Design Decisions (for reviewer)

1. **Scope is MCP only.** Built-ins stay injected. This keeps the blast radius to one function plus three new tools, and leaves the `agent_tools` / `agent_kanban_tools` curation the user already controls completely untouched.
2. **Three tools, mirroring an existing repo pattern.** The repo already does index → detail → use: `list_skills` (index) → `use_skill` (load) → the body; `list_sub_agent` (index) → `spawn_sub_agent` (use); `load_memory` (snippet) → `load_memory(with_content=true)` (detail). `search_tool` / `view_tool` / `use_tool` is that same shape with the detail step made explicit, which matters because an MCP tool's parameter schema is the thing you must not guess.
3. **`use_tool` equips; it does not invoke.** "view a tool before load" implies the load is the commitment step. Equip-then-call costs one extra round trip but keeps `use_tool`'s arguments tiny and its semantics obvious. *Open question for the reviewer:* a variant where `use_tool(name, arguments)` equips **and** invokes in one call would remove that round trip at the cost of a pass-through `arguments` object. Not implemented in v1; it is additive later if the dogfood shows the hop is painful.
4. **`search_tool` searches built-ins too, and reports what is already equipped.** Otherwise the agent asks "is there a tool for memory?", sees nothing (because `save_memory` is a built-in and therefore never in the MCP catalog) and concludes the capability is missing. Results carry `equipped = native | session | no`, so an already-available tool is visible and unmistakably usable.
5. **The three tools are exempt from the `allowed_tools` allowlist.** They are infrastructure, not user-curated capability. Making them allowlistable would mean every existing agent (whose `agent_tools` rows predate them) silently never sees them. MCP tools are already exempt in this exact function — same precedent.
6. **Gated on a non-empty MCP catalog.** With no MCP servers there is nothing to discover, so the three tools are not injected at all and a non-MCP session's `tools[]` is byte-identical to today. The gate is computed from `mcp_tools.len` at resolution time, so adding a server mid-session turns the feature on for the next iteration.
7. **No config flag in v1.** The user-visible change is "MCP tools are one hop away instead of free", not a capability removal, and the feature is already invisible for non-MCP users (Decision 6). A flag would double the config + settings-UI + test surface. If the dogfood run shows the agent stalling because it does not reach for `search_tool`, the mitigation is a one-task follow-up: `mcp_progressive_enabled: bool = false` on `LlmConfig`, mirroring `web_launch_enabled` (`Config.zig:49`), consulted only in `filterAndMergeTools`.
8. **`server_name` is a column, not a parsed suffix.** The tool name is `mcp_<server>_<tool>`, and that split is lossy the moment a server name contains `_`. Storing the server makes `search_tool`'s grouping, the frontend card and future debugging honest, for one column.
9. **Append-only ordering.** Built-ins keep their existing order; progressive tools are appended in `loaded_at_nano` order. Nothing is spliced into the middle, so a session's tool list only ever grows at the end.

## Wire Contract

### Table (Migration 085)

```sql
CREATE TABLE IF NOT EXISTS session_progressive_tool (
  session_id     TEXT NOT NULL,
  tool_name      TEXT NOT NULL,
  server_name    TEXT NOT NULL DEFAULT '',
  loaded_at_nano INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (session_id, tool_name)
);
CREATE INDEX IF NOT EXISTS idx_session_progressive_tool_session
  ON session_progressive_tool(session_id);
```

### Resolution rule (the only behavioural change)

```
base_tools        = built-ins surviving the agent/kanban allowlist (+ sub-agent strip)   # unchanged
equipped_names    = SELECT tool_name FROM session_progressive_tool WHERE session_id = ?
mcp_tools         = fetch-once catalog                                                  # unchanged
progressive_tools = [t for t in mcp_tools if t.function.name in equipped_names]         # NEW
merged_tools      = base_tools ++ progressive_tools                                     # was base_tools ++ mcp_tools
```

The three meta-tools are appended to `merged_tools` after the allowlist filter, only when `mcp_tools` is non-empty.

### `search_tool`

Input (both optional → no args returns the first page of everything):
```json
{ "query": "docs", "server": "context7" }
```

Success:
```xml
<search_tool><query>docs</query><count>3</count><total>3</total>
<tools>
<tool><name>mcp_context7_query-docs</name><server>context7</server><equipped>no</equipped><summary>Retrieves up-to-date documentation and code examples...</summary></tool>
<tool><name>mcp_context7_resolve-library-id</name><server>context7</server><equipped>session</equipped><summary>Resolves a package/product name to a Context7-compatible library ID...</summary></tool>
<tool><name>search</name><server></server><equipped>native</equipped><summary>PRIMARY search tool for code navigation...</summary></tool>
</tools>
<hint>Call view_tool for the full parameter schema, then use_tool to make it callable.</hint>
</search_tool>
```

- Match: case-insensitive substring over tool name + description; `server` is an exact filter. To be extended to name-token/BM25 ranking later if substring proves too weak (Out of Scope).
- `equipped`: `native` (built-in, already in the prompt) · `session` (already recorded by `use_tool`) · `no`.
- Rows capped at `MAX_SEARCH_ROWS = 40`, summaries at 120 chars, with `<truncated/><hint>Showing 40 of 214 — narrow with query.</hint>` when clipped.
- Empty catalog and no match both → `<search_tool><query>…</query><count>0</count><tools/></search_tool>` (not an error).

### `view_tool` (read-only — never inserts)

Input:
```json
{ "name": "mcp_context7_query-docs" }
```

Success:
```xml
<view_tool><name>mcp_context7_query-docs</name><server>context7</server><equipped>no</equipped>
<description>Retrieves up-to-date documentation and code examples for any library...</description>
<parameters><![CDATA[{"type":"object","properties":{"libraryId":{"type":"string","description":"..."}},"required":["libraryId"]}]]></parameters>
<hint>Call use_tool with this name to make it callable.</hint>
</view_tool>
```

Already-equipped view works the same way with `<equipped>native</equipped>` (or `session`) and `<note>Already equipped — call it directly.</note>` instead of the hint.

Not found:
```xml
<view_tool><name>mcp_context7_query_docs</name><found>false</found>
<error>unknown tool 'mcp_context7_query_docs' — not in this session's tool catalog</error>
<did_you_mean><name>mcp_context7_query-docs</name></did_you_mean>
<hint>Call search_tool to list candidates.</hint></view_tool>
```

### `use_tool`

Input:
```json
{ "name": "mcp_context7_query-docs" }
```

Equipped (row inserted):
```xml
<use_tool><name>mcp_context7_query-docs</name><equipped>true</equipped><inserted>true</inserted><source>session</source><wait_next_turn>true</wait_next_turn>
<parameters><![CDATA[{...}]]></parameters>
<note>Equipped for this session. Call it directly from your next turn onward — the current turn's tool list was already sent.</note>
</use_tool>
```

Already equipped (the validation rule — **no insert**):
```xml
<use_tool><name>read_file</name><equipped>true</equipped><inserted>false</inserted><source>native</source>
<note>Already equipped (built-in). Call it directly.</note>
</use_tool>
```
`source` is `native` (built-in) or `session` (already in `session_progressive_tool`).

Unknown name (**no insert**, never fails open):
```xml
<use_tool><name>mcp_context7_query_docs</name><equipped>false</equipped><inserted>false</inserted>
<error>unknown tool '…' — not in this session's tool catalog</error>
<did_you_mean><name>mcp_context7_query-docs</name></did_you_mean>
<hint>Call search_tool, then view_tool, then use_tool with the exact name.</hint>
</use_tool>
```

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/migrations/migration.zig` | EDIT | Migration 085 `session_progressive_tool` + register in `allMigrations` + inline tests (copy the 081/084 blocks at `:4864+`) |
| `src/agentic_loop/llm_history.zig` | EDIT | `saveProgressiveTool` / `getProgressiveTools` / `isProgressiveToolEquipped` / `deleteProgressiveTool` beside the session-skills block (`:3678-3759`) |
| `src/agentic_loop/progressive_catalog.zig` | NEW | Pure helpers: `collectCatalog(base_tools, mcp_tools, equipped)` → entries with `equipped` state; `findByName`; `didYouMean`; `matchQuery(query, server)` |
| `src/agentic_loop/progressive_catalog_test.zig` | NEW | Pure unit tests for search matching, the `equipped` classification, did-you-mean, row cap |
| `src/modules/agent/tools/progressive_tools.zig` | NEW | `search_tool` / `view_tool` / `use_tool` `AgentTool` literals + `system_prompt` strings + pure `renderSearchResult` / `renderViewTool` / `renderUseTool` |
| `src/agentic_loop/tools_exec_progressive_tools.zig` | NEW | `execSearchTool` / `execViewTool` / `execUseTool`; `execUseTool` sets `progressive_tool_save = .{ .name, .server_name }` on a real insert only |
| `src/agentic_loop/tools.zig` | EDIT | +3 exec re-exports; `ToolExecResult` gains `progressive_tool_save: ?ProgressiveToolSaveInfo` (mirrors `skill_save`) |
| `src/agentic_loop/handle_tool.zig` | EDIT | persist `progressive_tool_save` next to the `skill_saved` block (`:617-621`) |
| `src/agentic_loop/tools_equipped.zig` | EDIT | +1 import, +3 lines in `equips()`, +3 rows in `UNIFIED_TOOL_REGISTRY()`; refresh the stale `add_mcp_server` comments (`:51`, `:153-154`) |
| `src/agentic_loop/workflow.zig` | EDIT | `filterAndMergeTools` gains the progressive filter + the MCP-gated meta-tools; `:1022` reads `getProgressiveTools` and passes it; extend the `[CHECKPOINT] tools resolved` log (`:1023-1026`); **rewrite** the test at `:2426-2467` |
| `src/modules/agent/tools/add_mcp_server.zig` | EDIT | description (`:103`) + comment (`:174`): the new server's tools are discoverable via `search_tool` and must be equipped with `use_tool` |
| `src/agentic_loop/tools.zig` | EDIT | comment at `:66` |
| `src/modules/agent/prompts/core.zig` | EDIT | +`ProgressiveToolRule` (names the three tools, says MCP tools are lazy) |
| `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig` | EDIT | append `ProgressiveToolRule` when `search_tool` is present |
| `src/apps/desktop/src/components/tool_outputs/ProgressiveTool.vue` | NEW | one card handling all three: search rows (`equipped` chip), view detail (collapsible schema), use result (inserted vs already-equipped) |
| `src/apps/desktop/src/components/tool_outputs/ProgressiveTool.spec.ts` | NEW | vitest: search rows + chips, empty result, view schema collapsed, use inserted, use already-equipped, did-you-mean, malformed envelope fallback |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT | three `v-else-if` branches (`:3329-3378`, before the generic `v-else` at `:3379`) |
| `tests/functional/progressive_tool_test.py` | NEW | MCP fetched but not injected; `use_tool` → row → next resolution includes it; no duplicate row on re-use |
| `docs/superpowers/plans/2026-09-12-progressive-tool-search.md` | THIS FILE | Plan under review |

## Tasks

### Task 1 — Migration 085 + persistence helpers

- [ ] Add `Migration085AddSessionProgressiveTool` to `src/migrations/migration.zig` with the DDL above; register it in `allMigrations`.
- [ ] Inline migration tests (shape of the `Migration084` tests at `migration.zig:4965+`): table + columns exist; idempotent on re-run; registered in `allMigrations`; `PRIMARY KEY(session_id, tool_name)` rejects a duplicate insert.
- [ ] In `src/agentic_loop/llm_history.zig`, beside `saveSkill` (`:3699`): `saveProgressiveTool(allocator, db, logger, session_id, tool_name, server_name)` using `INSERT OR IGNORE` and returning `!bool` (`true` = a row was inserted, `false` = already present) — the caller needs that distinction to emit `inserted`, and skip the write entirely when `session_id.len == 0`.
- [ ] `isProgressiveToolEquipped(...) !bool`, `getProgressiveTools(...) ![]ProgressiveToolInfo` (names + server + loaded_at, caller-owned), `deleteProgressiveTool(...)`.
- [ ] Inline tests: first `saveProgressiveTool` returns `true`, second with the same name returns `false` and leaves exactly one row; `getProgressiveTools` on an unknown session returns empty; empty `session_id` writes nothing.
- [ ] Register the new files in `src/ai_workflow/tui/test_runner.zig` (root.zig:880 imports this aggregator; the pattern in that file is `_ = @import("../../agentic_loop/<file>.zig");`).
- [ ] `Commit:` `feat(db): migration 085 session_progressive_tool + persistence helpers`

### Task 2 — Search/view/use tool definitions + pure renderers

- [ ] Create `src/modules/agent/tools/progressive_tools.zig` (one module, following the merged-file shape of `skill_tools.zig`) exporting `search_tool_tool`, `view_tool_tool`, `use_tool_tool` with wire names `search_tool`, `view_tool`, `use_tool`.
- [ ] Each carries a `system_prompt`: `search_tool` teaches the flow ("MCP tools are not loaded by default; search → view → use"); `view_tool` says read-only, inspect before committing; `use_tool` says it equips for the session and takes effect next turn.
- [ ] Create `src/agentic_loop/progressive_catalog.zig`: `pub const Equipped = enum { native, session, no };` + `Entry{name, server, equipped, summary}`; `collectCatalog(allocator, base_tools, mcp_tools, equipped_names)`, `matchQuery(query, server, entries)`, `findByName(entries, name)`, `didYouMean(allocator, entries, name)`.
- [ ] Pure renderers in the same module as the tool defs: `renderSearchResult`, `renderViewTool`, `renderUseTool` producing the Wire Contract envelopes, with `MAX_SEARCH_ROWS = 40` and 120-char summaries.
- [ ] Inline tests: `search_tool` finds an MCP tool by description substring and a built-in by name; `equipped` is `native` for a built-in, `session` for an equipped MCP tool, `no` otherwise; `server` filter; the row cap emits `<truncated/>`; empty catalog → `<count>0</count>` and not an error; `view_tool` on an unknown name → `found=false` + did-you-mean matching `mcp_context7_query_docs` → `mcp_context7_query-docs`; `use_tool` renderer emits `inserted` from the caller's flag, not from a guess.
- [ ] Register both new files in `src/ai_workflow/tui/test_runner.zig`.
- [ ] `Commit:` `feat(tools): search_tool / view_tool / use_tool definitions + catalog helpers`

### Task 3 — Exec adapters + registry wiring + persistence signal

- [ ] Create `src/agentic_loop/tools_exec_progressive_tools.zig`. All three adapters need the live MCP catalog: `const di = try nalarcore.getSingleton();` then `di.getMcpToolsCached(ctx.allocator)` (`src/root.zig:302`, returns a deep dupe — same call the workflow makes at `:573-574`). Do **not** re-fetch from servers; the cache is the source of truth and dispatch already matches against it.
- [ ] `execSearchTool`: build entries from `tools_equipped.equips` + the cached MCP tools + `getProgressiveTools(ctx.session_id)`, render, wrap.
- [ ] `execViewTool`: `findByName` → render; unknown → not-found envelope. **Must not write anything.**
- [ ] `execUseTool`: validate the name is in the catalog (else not-found envelope, no write) → `isProgressiveToolEquipped`; if a built-in (`native`) or already equipped (`session`), return `inserted=false` without touching the DB → otherwise `saveProgressiveTool` and set `progressive_tool_save = .{ .name, .server_name }` **only when it returned `true`**.
- [ ] `src/agentic_loop/tools.zig`: add `pub const ProgressiveToolSaveInfo = struct { name: []const u8, server_name: []const u8 };` and `progressive_tool_save: ?ProgressiveToolSaveInfo = null` to `ToolExecResult` (`:115-127`).
- [ ] `src/agentic_loop/handle_tool.zig`: after the `skill_saved` block (`:617-621`), call `saveProgressiveTool(...)` when the field is set; log and continue on failure rather than aborting the turn.
- [ ] `src/agentic_loop/tools_equipped.zig`: `+const progressive_tools_mod = nalarcore.progressive_tools;`, +3 lines in `equips()`, +3 rows in `UNIFIED_TOOL_REGISTRY()`.
- [ ] `src/agentic_loop/tools.zig`: +3 re-exports.
- [ ] Static-contract test (copy `tools_exec_list_sub_agent.zig:252-272`): `equips()`, `UNIFIED_TOOL_REGISTRY()` and `tools.zig` all agree the three names exist — this is what catches a forgotten registry row.
- [ ] Inline test for `execUseTool`'s validation rule against a real DB: unknown name writes nothing; first use inserts; second use returns `inserted=false` and the table still has exactly one row; a built-in name never inserts.
- [ ] `Commit:` `feat(tools): progressive search/view/use adapters + registry wiring`

### Task 4 — Make MCP progressive at the choke point

- [ ] `workflow.zig:1739`: add a `progressive_equipped: []const []const u8` parameter to `filterAndMergeTools` and change the merge (`:1782-1786`) to append only MCP tools whose name is in that set. Keep the built-in path, the allowlist semantics and the sub-agent strip byte-identical.
- [ ] In the same function, append the three meta-tools **after** the allowlist filter and only when `mcp_tools` is non-empty — i.e. exempt from `allowed_tools`, exactly as MCP tools are today.
- [ ] Dedup by name on merge (first wins, built-ins beat MCP) — today a server tool named `read_file` would ship twice.
- [ ] `workflow.zig:1022`: read `getProgressiveTools(allocator, db, copy_session_id)` before the call and pass the names in; keep `merged_tools` feeding both `:1028` and `:1050`.
- [ ] Extend the `[CHECKPOINT] tools resolved` log (`:1023-1026`) with `mcp_catalog={d} mcp_equipped={d} progressive_tools={d}` — this is the functional test's observability hook (nothing parses this line today, so widening it is free).
- [ ] **Rewrite** the test at `:2426-2467` into two: (a) MCP tools are NOT in the merged list when the progressive set is empty — the new contract; (b) they ARE present, appended after the built-ins, when their names are passed in. Keep the existing "null MCP still yields base tools" assertion.
- [ ] Update the other `filterAndMergeTools` call sites (the test at `:2447`/`:2457` plus any others the compiler flags) for the new parameter.
- [ ] `Commit:` `feat(agentic-loop): MCP tools become progressive, injected only when equipped`

### Task 5 — Prompt rule + description/comment truth-up

- [ ] `src/modules/agent/prompts/core.zig`: add `pub const ProgressiveToolRule = …` — keep it short: MCP tools are not loaded by default; `search_tool` finds them (and shows what is already equipped); `view_tool` shows a tool's parameters; `use_tool` makes it callable from the next turn. A missing capability means "search", never "give up".
- [ ] Append it in `prompts_build_messages_for_agent_prompt.zig` when `hasTool(filtered_tools, "search_tool")` — same idiom as the gates at `:99-124`.
- [ ] `src/modules/agent/tools/add_mcp_server.zig:103`: the description currently promises "The new server's tools appear on the NEXT iteration." Reword to: appear in `search_tool` on the next iteration and become callable after `use_tool`. Update the comment at `:174`.
- [ ] `src/agentic_loop/tools_equipped.zig:51` and `:153-154`, and `src/agentic_loop/tools.zig:66`: same correction in the comments.
- [ ] `Commit:` `docs(prompt): document progressive MCP tools; correct add_mcp_server contract`

### Task 6 — Frontend card

- [ ] Create `ProgressiveTool.vue` in `src/apps/desktop/src/components/tool_outputs/` handling all three names: `search_tool` → rows with a server label and an `equipped` chip (`native` / `session` / —); `view_tool` → description + parameters in a `<details>` collapsed by default; `use_tool` → name + distinct visual for `inserted=true` vs `already equipped`. Reuse `unwrapToolOutput` (`helpers/unwrapToolOutput.ts:62`) like the other cards.
- [ ] `ProgressiveTool.spec.ts` (vitest, 9 cases): search rows render; `native` chip vs `session` chip vs no chip; empty result renders an explicit empty state; truncated hint; view shows schema collapsed then expands; use-inserted state; use-already-equipped state; unknown-name error + did-you-mean; malformed envelope falls back to raw.
- [ ] `ChatView.vue`: three `v-else-if` branches in the dispatcher chain (`:3329-3378`, before the generic `v-else` at `:3379`). Mirror in `src/apps/desktop/src/components/nalar/SubAgentPeekPanel.vue` if it carries its own chain.
- [ ] Run `pnpm test:unit` from `src/apps/desktop` and `bun run build`; delete any `.js` files `vue-tsc --build` emits next to `.ts` sources before committing.
- [ ] `Commit:` `feat(desktop): progressive tool search output card`

### Task 7 — Functional tests

- [ ] Create `tests/functional/progressive_tool_test.py` using `FunctionalHarness.boot(stub_llm_profile=True)` and the repo's existing hello-world MCP servers (`harness.mcp_hello_world_bin()` `:1082`, `mcp_http_hello_world_bin()` `:1113`) as the catalog source.
- [ ] Test 1 (MCP not injected): configure the server, create a session, queue a message, wait for the `[CHECKPOINT] tools resolved` line via `harness.tail_log()`, assert `mcp_catalog > 0` **and** `mcp_equipped=0` **and** `merged_count` equals the built-in count — i.e. the catalog was fetched but nothing MCP reached `tools[]`.
- [ ] Test 2 (no MCP → byte-identical): boot with no MCP servers, assert no `search_tool` in the resolved list and `mcp_catalog=0`.
- [ ] Test 3 (equip → visible): insert a row directly into the harness tmpdir `agent.db` (`sqlite3 <tmpdir>/.config/nalar/agent.db "INSERT INTO session_progressive_tool …"`, tool name = the hello-world server's tool), re-queue a message, assert the next `[CHECKPOINT] tools resolved` shows `mcp_equipped=1` and `merged_count` grew by exactly 1. This is the end-to-end proof that the table drives the prompt.
- [ ] Test 4 (no duplicate row): insert the same name twice via SQL and assert the PK rejects it (`INSERT OR IGNORE` leaves one row) — the DB-level half of the validation rule.
- [ ] Run `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/progressive_tool_test.py -v` after `zig build install:linux`.
- [ ] `Commit:` `test(functional): MCP tools are progressive — fetched but not injected until equipped`

### Task 8 — Measurement + PR body

- [ ] Parse the two `[CHECKPOINT] tools resolved` values from Test 1 into a before/after line for the PR body: MCP tool count, their serialized bytes (use the literal-text measurement from the plan-doc appendix below), and the per-call token delta.
- [ ] Record in the PR body what the change does and does not buy: **MCP schemas leave the context entirely until used**; built-in schemas are unchanged by design.
- [ ] Note the follow-up trigger explicitly: if the dogfood run shows the agent failing to reach for `search_tool`, add the `mcp_progressive_enabled` flag (Design Decision 7).
- [ ] `Commit:` `docs: record progressive tool search measurements`

## Verification

- `zig build test --summary all` — green, including the rewritten `filterAndMergeTools` tests, the migration tests and the three static-contract tests.
- `pnpm test:unit` (from `src/apps/desktop`) — green, including `ProgressiveTool.spec.ts`.
- `bun run build` — clean.
- `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/progressive_tool_test.py -v` — 4 passed.
- **No-regression gate (non-MCP):** with no MCP servers configured, the resolved tool list is identical (names AND order) to pre-change. Asserted by Test 2 and by a unit test.
- **MCP gate:** with MCP configured, `mcp_catalog > 0` and `mcp_equipped = 0` on a fresh session — no MCP schema in `tools[]`.
- **Validation gate:** `use_tool` on an already-equipped name (built-in or session) performs zero writes and reports `inserted=false`; on an unknown name, zero writes and `equipped=false`. Asserted at both unit and functional level.
- **Ordering gate:** when a tool is equipped mid-session, the built-in prefix of `tools[]` is unchanged and the new schema is the last element.
- Port 8081 was never touched.

## Out of Scope (explicit non-goals)

- Any tiering, deferral or trimming of **built-in** tools. Built-ins stay fully injected.
- `use_tool` equipping *and* invoking in one call (Design Decision 3, open question).
- A config flag for the feature (Design Decision 7 — the follow-up is described there if the dogfood needs it).
- BM25/embedding ranking for `search_tool`. v1 is case-insensitive substring + exact server filter.
- Auto-unequipping progressive tools that go unused, and any eviction/limit on the equipped set. Revisit only if a session equips enough MCP tools to matter.
- A settings-UI toggle or a per-session tool inspector.
- Emitting a new SSE event type for equip events. Tool results already ride inside `llm_full`; adding a new named event would need the frontend's `additionalEventTypes` pre-registration (`api/index.ts:3295`) and buys nothing here.
- Fixing the pre-existing `allowed_tools == ""` ambiguity (`workflow.zig:1749` treats it as "no filter"/all while the doc comment says "no tools").

## Risks

1. **The agent never calls `search_tool`** → MCP capabilities look missing even though `handle_mcp_tool.zig` would still execute them. Mitigations: `ProgressiveToolRule` names the three tools; `search_tool` also surfaces already-equipped built-ins so the first search a curious model makes is rewarding; `search_tool`/`use_tool` failure envelopes always name the next step. Watch metric in the dogfood: MCP-tool invocations per session, and whether `use_tool` is ever called. Fallback: the flag in Design Decision 7.
2. **A resumed session.** An MCP `tool_use` already in the transcript whose schema is no longer in `tools[]` would be a provider error. Because `session_progressive_tool` persists the equip, the schema comes back on the next resolution — but only if the equip was persisted. That is exactly why `saveProgressiveTool` must be wired into the dispatch loop (Task 3) and not only into the tool result. Test: equip in one session, resume, assert the tool is still resolved.
3. **A tool the agent calls straight from `search_tool` output without `use_tool`.** Since dispatch matches the cache rather than `tools[]`, the call may actually succeed — so the failure mode is inconsistent rather than clean. Decide and test: this plan returns a normal tool result (the call works), and `use_tool` exists so the tool is also *advertised* in the prompt for later turns. Worth an explicit test so the behavior is intentional, not accidental.
4. **MCP server removed/renamed between sessions.** `session_progressive_tool` keeps names; a stale name simply never matches the catalog, so it silently contributes nothing. Fine, but `getProgressiveTools` should not choke on it — covered by the unknown-name test.
5. **Name collisions.** A server tool named `read_file` collides with the built-in. The merge dedups first-wins (built-in), and `search_tool` shows it as `native`, so `use_tool` on it is a no-op. Recorded here because the current code ships both.
6. **`filterAndMergeTools` signature churn.** It is `pub` and has several test call sites; the compiler will find them, but the tests at `:2447`/`:2457` need real thought (they encode the old contract). Task 4 covers the rewrite explicitly.
7. **`getMcpToolsCached` deep-dupes.** Calling it from three exec adapters means three dupes per dispatch. They land on the per-request arena so there is no leak, but if `search_tool` proves hot, hoist one catalog snapshot per iteration instead. Not a correctness risk.
8. **The catalog's `required` field is currently always empty** for MCP tools (`prompts_build_messages_for_agent_prompt.zig:580-585` TODO). `view_tool` will therefore show `required: []` for MCP tools, which can mislead the model into omitting mandatory arguments. Fixing that TODO is a separate small task; the plan does not depend on it, but the reviewer should know `view_tool` inherits the wart.

## Appendix — how to measure the MCP payload removed

Literal-text measurement, same method as the plan's sizing work (no compiled dump):

1. Get the catalog from a running instance: the `[CHECKPOINT] tools resolved` line gives `mcp_catalog=<N>`.
2. For the byte figure, sum each MCP tool's `name` + `description` + every property `description` (the `AgentTool` fields that serialize) and add ~18% for JSON structure — the same convention used for the built-in baseline (70,008 B of literals for 36/37 built-ins → ≈83 KB on the wire → ≈21k tokens at bytes/4).
3. Quote the method alongside the number, and prefer the functional test's `mcp_catalog` count as the primary evidence — it is measured, not reconstructed.

## Plan saved checklist

- [ ] Plan saved to `docs/superpowers/plans/2026-09-12-progressive-tool-search.md`
- [ ] Header includes Goal / Architecture / Tech Stack / Global Constraints
- [ ] Bite-sized steps with `- [ ]` checkboxes and per-task commits
- [ ] User reviewed before execution
