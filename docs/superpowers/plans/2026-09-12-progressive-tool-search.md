# Progressive Tool Search Implementation Plan (rev 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the agent discover and equip tools on demand instead of receiving every schema up front. Three new agent tools — `search_tool`, `view_tool`, `use_tool` — cover a **catalog** made of (a) built-in tools that are **not enabled** for this agent/kanban and (b) **all MCP tools**. Equipping writes one row to a new `session_progressive_tool` table; from the next iteration the tool is injected like any other. Built-ins that *are* enabled keep being injected exactly as today, unchanged.

**Architecture:** Two edits plus three new tools.

1. A shared, pure **eligibility** helper makes "what is enabled" and "what the item type may have" single-source-of-truth, so the catalog the adapter offers can never drift from the list the LLM actually receives.
2. `filterAndMergeTools` (`src/agentic_loop/workflow.zig:1739`) stops being `base ++ all_mcp` and becomes `enabled_builtins ++ session_equipped`, where `session_equipped` is read from `session_progressive_tool`. The same function appends the three meta-tools when the catalog is non-empty.
3. The three meta-tools are exempt from the `allowed_tools` allowlist (exactly as MCP tools already are at `:1749-1768`), otherwise every existing agent — whose `agent_tools` rows predate them — would silently never see them.

Everything upstream is reused untouched: the fetch-once MCP cache (`workflow.zig:573-586`, `root.zig:119/302/315`), the `mcp_<server>_<tool>` naming (`prompts_build_messages_for_agent_prompt.zig:526-537`), and dispatch (`handle_mcp_tool.zig` matches the live cache, not `tools[]`).

**Tech Stack:** Zig 0.16 (`AgentTool`, `ToolExecContext`, `wrapToolOutput`), SQLite (Migration 085), Vue 3 + vitest, python functional harness (isolated tmpdir HOME + the repo's hello-world MCP servers).

## Global Constraints

- **The agent never mutates `agent_tools` / `agent_kanban_tools`.** `use_tool` writes only `session_progressive_tool`, which is session-scoped. Unchecking a tool in the Tools tab must remain unchecking after the agent runs.
- **`enabled` is the definition of "not discoverable".** A built-in whose name resolves as enabled for this item is *not* in the catalog — it is already in the LLM's tool list.
- **Built-ins that are enabled are injected byte-identically to today**, same names, same order.
- **The three tool names are exactly** `search_tool`, `view_tool`, `use_tool`. Put all three in one new module `src/modules/agent/tools/progressive_tools.zig` imported as `progressive_tools_mod`. Do **not** declare a bare `const search_tool = …` or a `search_tool_mod` alias in `tools_equipped.zig` — `:55` already has `search_tool_mod = nalarcore.search_tool` (the codebase-search tool). Qualified access keeps them distinct.
- **`use_tool` must never insert when the tool is already equipped.** Two layers: an explicit check (built-in-enabled, or already in `session_progressive_tool`) returning `inserted=false` with **zero writes**, plus `PRIMARY KEY(session_id, tool_name)` + `INSERT OR IGNORE` at the DB level. Set the persistence signal **only** when the insert actually happened.
- **Never register an unknown name.** Validate against the catalog first; unknown → `equipped=false`, nothing written.
- **No import cycles.** The exec adapters live below `workflow.zig`, so they must not import it. All shared logic goes in a leaf module (see the eligibility helper below); anything reaching the DB (the workspace context) goes through `llm_history.zig`, which is already a shared leaf.
- **Never touch the process on port 8081.** Functional tests use the harness's random port.
- Per-request arena: `ctx.allocator` is arena-backed — do NOT `defer free` arena slices inside exec adapters.
- No `// NEW (plan: …)` comments.
- Verification gates: `zig build test --summary all`, `pnpm test:unit` (from `src/apps/desktop`), `bun run build`, `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/<file> -v` (rebuild with `zig build install:linux` first — `zig build nalar-desktop` does NOT produce `nalarcore-linux-x86_64`).

## Current State (verified 2026-09-12 in this worktree)

### The toggle semantics (this is why the design is safe)

| Handler | SQL | Effect |
|---|---|---|
| `agent_tools_create.zig` | `INSERT INTO agent_tools (id, agent_id, tool_name, enabled, …) VALUES (…, 1, …)`, guarded by `isKnownTool` against `UNIFIED_TOOL_REGISTRY` | enabling a tool |
| `agent_tools_delete.zig:56` | `DELETE FROM agent_tools WHERE tool_name = ? AND agent_id = ?` | **disabling a tool** |

`enabled` is read everywhere (`agent_tools_allowed.zig:57-61`, `agents_get.zig:175`, `agent_kanban_tools_allowed.zig:48-52`) and is in the schema (`Migration 076`, `DEFAULT 1`), but **no write path ever sets it to 0**. So "not enabled" means "no row", `session_progressive_tool` is the only new state, and the agent's equip can never overwrite the user's Tools-tab configuration. The same holds for the kanban mirror (`agent_kanban_tools_create.zig:133`, `agent_kanban_tools_delete.zig`).

### What decides the tool list

| Step | Where | What |
|---|---|---|
| Registry | `tools_equipped.zig:66-119` | `equips()` → 37 built-ins, `allocator.dupe` per call (called twice at `workflow.zig:1745-1746`) |
| Allowlist | `workflow.zig:1749-1768` | CSV filter. `""`/`"all"` skip the filter (= all tools) |
| Sub-agent strip | `workflow.zig:1770-1779` | drops `spawn_sub_agent` |
| MCP merge | `workflow.zig:1782-1786` | appends **all** MCP tools — no dedup, no cap. **This is what becomes progressive** |
| Item-type strip | `prompts_build_messages_for_agent_prompt.zig:1221-1266` | kanban↔design exclusion; `removeTools` (`:1203-1219`) **mutates its input in place** |
| Consumed | `workflow.zig:1022` → `:1028` + `:1050` | once per loop iteration, both from the same `merged_tools` |
| Enabled names read | `agent_tools_allowed.zig:35-76`, `agent_kanban_tools_allowed.zig` | `SELECT tool_name … WHERE agent_id = ? AND enabled = 1 ORDER BY tool_name ASC` |
| Overrides | `workflow.zig:1997` (agent) and `:2077` (kanban) | both **private** (`fn`, not `pub fn`) — see the threading requirement |
| MCP catalog | `workflow.zig:573-586`, `:626-647` | fetch-once cache on the singleton; `getMcpToolsCached` deep-dupes |

### The wiring gap (why this plan has an extra task)

`ToolExecContext` (`tools.zig:78-113`) carries `db`, `session_id`, `config`, `cwd`, … but **not** `allowed_tools` or `is_sub_agent`. The catalog needs to know what is enabled, so those must be threaded:

```
workflow.zig:1276   handle_tool(… 18 positional args …)
  └─ handle_tool.zig:316  pub fn handle_tool(…)      → builds ToolContext (:38)
       └─ handle_tool.zig:190  dispatchFromRegistry   → builds tools.ToolExecContext
            └─ exec adapter                            → needs allowed_tools + is_sub_agent
```

`ToolExecContext` has precedent for defaulted new fields (`tool_call_id` `:112`, `active_page_id` `:106`), so adding two defaulted fields breaks no existing call site.

### Pre-existing facts worth knowing

- `is_sub_agent` is currently derived by substring: `std.mem.indexOf(u8, sess_id, "subagent") != null` (`tools_exec_spawn_sub_agent.zig:249`). Thread the authoritative flag rather than re-deriving.
- `filteringTools` mutates its input slice in place — never share a buffer with it (`prompts_build_messages_for_agent_prompt.zig:1203-1219`).
- MCP tools always serialize `required: []` because `inputSchema.required` is never parsed (`prompts_build_messages_for_agent_prompt.zig:580-585`, existing TODO). `view_tool` will surface that.
- Next free migration number: **085** (084 = `workspace_routines`).
- `session_skills` (Migration 008, column renamed in 075) + `saveSkill`/`getSessionSkills` (`llm_history.zig:3678-3759`) is the persistence pattern to mirror.

## Design Decisions (for reviewer)

1. **Catalog = not-enabled built-ins ∪ MCP tools.** Per review: built-ins already enabled stay injected and are not searchable (they are literally in the LLM's tool list); built-ins that are not enabled are searchable, viewable and equippable, and the equip record goes in `session_progressive_tool`.
2. **The catalog never exceeds what the item type may have.** It reuses the existing `filteringTools` policy (kanban↔design exclusion), extracted into the shared helper. Without this, a kanban agent could equip design tools that the item type deliberately excludes — the catalog would be a hole in an existing policy.
3. **The agent's equip is session-scoped, never persistent.** Because the toggle is INSERT/DELETE and nothing writes `enabled=0`, `use_tool` can only add a `session_progressive_tool` row. The Tools tab stays exactly as the user left it, and starting a new session reverts everything. This is the property that makes "the agent can enable a tool you turned off" acceptable rather than a privilege escalation. *If you want unchecking to be a hard deny the agent cannot override, that needs a real `enabled=0` write path plus catalog exclusion — say the word and it becomes a small extra task.*
4. **Equip = one hop, and the result says so.** `merged_tools` is resolved at `:1022` before the LLM call, so an equipped tool is callable from the **next** iteration. The `use_tool` result carries the full parameter schema so the model can already write the call correctly, and states the one-turn delay explicitly. (Same lag `use_skill` has.)
5. **`use_tool` equips; it does not invoke.** "view a tool before load" reads as inspect → commit. *Open question:* `use_tool(name, arguments)` would equip **and** invoke in one call, removing a round trip at the cost of a pass-through `arguments` object. Not in v1; additive later if the dogfood says the hop hurts.
6. **The three meta-tools are exempt from the allowlist.** Otherwise every existing agent (whose `agent_tools` rows predate them) silently never sees them. MCP tools are already exempt in this exact function.
7. **Gated on a non-empty catalog.** When nothing is discoverable — allowlist covers all built-ins *and* no MCP servers — the three tools are not injected at all. Note the honest consequence: because a typical kanban item enables only 2 built-ins, its catalog is ~35 tools, so the gate is effectively always open. The old "non-MCP sessions are byte-identical" claim no longer holds; what holds is "an item whose allowlist covers everything and has no MCP is byte-identical".
8. **No config flag in v1.** The change is "some tools are one hop away", not a capability removal, and it is revertible by starting a new session. If the dogfood shows the agent failing to reach for `search_tool`, the mitigation is a one-task follow-up: `mcp_progressive_enabled: bool = false` on `LlmConfig`, mirroring `web_launch_enabled` (`Config.zig:49`).
9. **`server_name` is a real column** (empty for built-ins). `mcp_<server>_<tool>` parsing is lossy the moment a server name contains `_`.
10. **Ordering is stable and append-only.** Enabled built-ins keep their current order; session-equipped tools are appended in `loaded_at_nano` order. Nothing is spliced into the middle.
11. **Search results mark already-equipped entries.** Even though enabled built-ins are excluded from the catalog, a result can still be `equipped=session` (equipped earlier this session) — reporting that prevents a pointless second `use_tool`.

## Wire Contract

### Table (Migration 085)

```sql
CREATE TABLE IF NOT EXISTS session_progressive_tool (
  session_id     TEXT NOT NULL,
  tool_name      TEXT NOT NULL,
  server_name    TEXT NOT NULL DEFAULT '',   -- '' for built-ins; '<server>' for mcp_* tools
  loaded_at_nano INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (session_id, tool_name)
);
CREATE INDEX IF NOT EXISTS idx_session_progressive_tool_session
  ON session_progressive_tool(session_id);
```

### Eligibility + catalog (the shared, pure definition)

```
registered        = tools_equipped.equips()                                  # 37 built-ins
enabled_builtins  = allowlistFilter(registered, allowed_tools, is_sub_agent)  # what ships today
                    then itemTypeStrip(…, self_item_type)                    # existing kanban↔design policy
equipped_names    = SELECT tool_name FROM session_progressive_tool WHERE session_id = ?
catalog           = (registered − enabled_builtins − equipped_names)          # built-ins you can add
                    ∪ (mcp_tools − equipped_names)                           # MCP tools you can add
```

Extract `allowlistFilter` from `workflow.zig:1749-1779` and `itemTypeStrip` from `prompts_build_messages_for_agent_prompt.zig:1203-1266` into a leaf module so `filterAndMergeTools` **and** the exec adapters call the same code. `filteringTools` keeps its `getWorkspaceContext` lookup (in `llm_history.zig`, importable) and delegates the strip.

### Resolution rule (the only behavioural change)

```
final = enabled_builtins                                   # unchanged, same order
      ++ session_equipped_builtins                          # NEW: names in session_progressive_tool ∩ registered
      ++ session_equipped_mcp                               # NEW: names in session_progressive_tool ∩ mcp_tools
      ++ [search_tool, view_tool, use_tool]                 # NEW, only when catalog is non-empty and not allowlist-filtered
```

Dedup by name, first wins (built-in beats MCP) — today a server tool named `read_file` would ship twice.

### `search_tool`

Input (both optional; no args = first page of the catalog):
```json
{ "query": "docs", "server": "context7" }
```

Success:
```xml
<search_tool><query>docs</query><count>2</count><total>2</total>
<tools>
<tool><name>mcp_context7_query-docs</name><kind>mcp</kind><server>context7</server><equipped>no</equipped><summary>Retrieves up-to-date documentation and code examples...</summary></tool>
<tool><name>kanban_list</name><kind>builtin</kind><server></server><equipped>no</equipped><summary>List a kanban board's columns and tasks...</summary></tool>
</tools>
<hint>Call view_tool for the full parameter schema, then use_tool to enable it for this session. Tools you already have in your tool list are NOT listed here.</hint>
</search_tool>
```

- Match: case-insensitive substring over tool name + description; `server` is an exact filter. `equipped` is `session` or `no` (an enabled built-in is never a result).
- Cap `MAX_SEARCH_ROWS = 40`, summaries 120 chars; when clipped, `<truncated/><hint>Showing 40 of 61 — narrow with query.</hint>`.
- No match → `<count>0</count><tools/>` plus `<hint>… check your tool list first; already-enabled tools are not searchable.</hint>`. Not an error.

### `view_tool` (read-only — never inserts)

```json
{ "name": "mcp_context7_query-docs" }
```
```xml
<view_tool><name>mcp_context7_query-docs</name><kind>mcp</kind><server>context7</server><equipped>no</equipped>
<description>Retrieves up-to-date documentation and code examples for any library...</description>
<parameters><![CDATA[{"type":"object","properties":{"libraryId":{"type":"string","description":"..."}},"required":["libraryId"]}]]></parameters>
<hint>Call use_tool with this name to enable it for this session.</hint>
</view_tool>
```
Already equipped → `<equipped>session</equipped>` + `<note>Already enabled — call it directly.</note>`. Not found → `found=false` with `<did_you_mean>` (e.g. `mcp_context7_query_docs` → `mcp_context7_query-docs`) and a hint.

### `use_tool`

Input: `{ "name": "kanban_list" }`

Inserted (works for both kinds — this is the requested built-in equip):
```xml
<use_tool><name>kanban_list</name><kind>builtin</kind><equipped>true</equipped><inserted>true</inserted><wait_next_turn>true</wait_next_turn>
<parameters><![CDATA[{...}]]></parameters>
<note>Enabled for this session. Call it directly from your next turn onward — the current turn's tool list was already sent.</note>
</use_tool>
```

Already equipped (**the validation rule — no insert**):
```xml
<use_tool><name>read_file</name><kind>builtin</kind><equipped>true</equipped><inserted>false</inserted><source>session</source>
<note>Already enabled for this session. Call it directly.</note>
</use_tool>
```
`source` is `session` (a `session_progressive_tool` row exists). A name that is enabled *natively* is not in the catalog at all, so the genuinely-reachable "already equipped" case is the session one — but the check must still cover the native case defensively and return `inserted=false`.

Unknown name (**no insert**, never fails open):
```xml
<use_tool><name>kanban_listt</name><equipped>false</equipped><inserted>false</inserted>
<error>unknown tool 'kanban_listt' — not in this session's discoverable catalog</error>
<did_you_mean><name>kanban_list</name></did_you_mean>
<hint>Call search_tool, then view_tool, then use_tool with the exact name.</hint>
</use_tool>
```

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/migrations/migration.zig` | EDIT | Migration 085 + register in `allMigrations` + inline tests (shape of the 081/084 blocks at `:4864+`) |
| `src/agentic_loop/tool_eligibility.zig` | NEW | **Leaf module.** Pure `allowlistFilter(tools, allowed_tools, is_sub_agent)` (moved from `workflow.zig:1749-1779`) and `itemTypeStrip(tools, self_item_type)` (moved from `prompts_build_messages_for_agent_prompt.zig:1203-1266`). Imported by `workflow.zig`, the prompt builder and the exec adapter — no cycles |
| `src/agentic_loop/tool_eligibility_test.zig` | NEW | Pure tests: CSV filter, `""`/`"all"`, sub-agent strip, kanban↔design strip, and that the extracted helpers reproduce the old behaviour exactly |
| `src/agentic_loop/progressive_catalog.zig` | NEW | `Equipped = enum { session, no }`, `Kind = enum { builtin, mcp }`, `Entry`, `collectCatalog(...)`, `matchQuery`, `findByName`, `didYouMean` |
| `src/agentic_loop/progressive_catalog_test.zig` | NEW | Pure tests: catalog = registered − enabled − equipped ∪ mcp − equipped; enabled built-ins absent; unknown names never returned |
| `src/modules/agent/tools/progressive_tools.zig` | NEW | `search_tool` / `view_tool` / `use_tool` `AgentTool` literals + `system_prompt` strings + `renderSearchResult` / `renderViewTool` / `renderUseTool` |
| `src/agentic_loop/tools_exec_progressive_tools.zig` | NEW | `execSearchTool` / `execViewTool` / `execUseTool`; `execUseTool` sets `progressive_tool_save` only on a real insert |
| `src/agentic_loop/llm_history.zig` | EDIT | `saveProgressiveTool` (returns `!bool`), `getProgressiveTools`, `isProgressiveToolEquipped`, `deleteProgressiveTool` beside the session-skills block (`:3678-3759`) |
| `src/agentic_loop/tools.zig` | EDIT | +3 exec re-exports; `ToolExecContext` gains `allowed_tools: []const u8 = ""` + `is_sub_agent: bool = false`; `ToolExecResult` gains `progressive_tool_save` |
| `src/agentic_loop/handle_tool.zig` | EDIT | `ToolContext` (`:38`) + `handle_tool` (`:316`) gain the two fields; `dispatchFromRegistry` (`:190-212`) passes them through; persist `progressive_tool_save` next to `skill_saved` (`:617-621`) |
| `src/agentic_loop/workflow.zig` | EDIT | `filterAndMergeTools` uses `tool_eligibility` + the progressive filter + the catalog-gated meta-tools; `:1022` reads `getProgressiveTools`; `:1276` passes `copy_allowed_tools`/`copy_is_sub_agent`; extend the `[CHECKPOINT] tools resolved` log (`:1023-1026`); **rewrite** the test at `:2426-2467` |
| `src/agentic_loop/tools_equipped.zig` | EDIT | +2 imports, +3 lines in `equips()`, +3 rows in `UNIFIED_TOOL_REGISTRY()`; correct the stale `add_mcp_server` comments (`:51`, `:153-154`) |
| `src/modules/agent/tools/add_mcp_server.zig` | EDIT | description (`:103`) + comment (`:174`): the new server's tools are discoverable via `search_tool` and must be enabled with `use_tool` |
| `src/modules/agent/prompts/core.zig` | EDIT | +`ProgressiveToolRule` |
| `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig` | EDIT | delegate `filteringTools` to `tool_eligibility.itemTypeStrip`; append `ProgressiveToolRule` when `search_tool` is present |
| `src/apps/desktop/src/components/tool_outputs/ProgressiveTool.vue` | NEW | one card for all three (search rows + `kind`/`equipped` chips, view detail with collapsible schema, use inserted vs already-enabled) |
| `src/apps/desktop/src/components/tool_outputs/ProgressiveTool.spec.ts` | NEW | vitest, 9 cases |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT | three `v-else-if` branches (`:3329-3378`, before the generic `v-else` at `:3379`) |
| `tests/functional/progressive_tool_test.py` | NEW | built-in equip end-to-end; MCP fetched-not-injected; duplicate insert rejected; non-MCP item unaffected |
| `docs/superpowers/plans/2026-09-12-progressive-tool-search.md` | THIS FILE | Plan under review |

## Tasks

### Task 1 — Extract the eligibility helpers (pure refactor, no behaviour change)

- [ ] Create `src/agentic_loop/tool_eligibility.zig` with `allowlistFilter(allocator, tools, allowed_tools, is_sub_agent) ![]const AgentTool` moved verbatim from `workflow.zig:1749-1779`, and `itemTypeStrip(tools, self_item_type) []const AgentTool` moved from `prompts_build_messages_for_agent_prompt.zig:1203-1266`.
- [ ] `filterAndMergeTools` calls `allowlistFilter`; `filteringTools` calls `itemTypeStrip` after its own `getWorkspaceContext` lookup. No duplicate implementations remain (`search(pattern="enabled = 1")`-style check is not enough — diff the logic by eye).
- [ ] `tool_eligibility_test.zig`: CSV allowlist keeps exactly the listed names; `""` and `"all"` keep everything; sub-agent strips `spawn_sub_agent`; `itemTypeStrip` on `"kanban"` removes the 7 design names, on `"design"` removes the 3 kanban names, on `"folder"` removes both, on `"agent"`/`"chat"` removes nothing. The reference is the pre-change behaviour — for each case, assert the resulting name list, not just the length.
- [ ] Keep the existing `filterAndMergeTools` tests green (they are the regression net for this refactor).
- [ ] Register both new files in `src/ai_workflow/tui/test_runner.zig` (root.zig:880 imports that aggregator; the pattern there is `_ = @import("../../agentic_loop/<file>.zig");`).
- [ ] `Commit:` `refactor(agentic-loop): extract allowlist + item-type eligibility into a leaf module`

### Task 2 — Migration 085 + persistence helpers

- [ ] Add `Migration085AddSessionProgressiveTool` (DDL above); register in `allMigrations`.
- [ ] Inline migration tests: columns exist; idempotent on re-run; registered in `allMigrations`; `PRIMARY KEY(session_id, tool_name)` rejects a duplicate.
- [ ] `llm_history.zig`: `saveProgressiveTool(...) !bool` using `INSERT OR IGNORE` — `true` iff a row was inserted (the caller needs that to emit `inserted`); no-op when `session_id.len == 0`. Plus `isProgressiveToolEquipped`, `getProgressiveTools` (names + server + loaded_at, caller-owned), `deleteProgressiveTool`.
- [ ] Inline tests: first call `true`, second `false`, one row; unknown session → empty; empty `session_id` writes nothing.
- [ ] `Commit:` `feat(db): migration 085 session_progressive_tool + persistence helpers`

### Task 3 — Catalog + the three tool definitions

- [ ] `progressive_catalog.zig`: `collectCatalog(allocator, registered, enabled_builtins, mcp_tools, equipped_names, …)`, `matchQuery`, `findByName`, `didYouMean`. The catalog must never include an enabled built-in or an already-equipped name.
- [ ] `src/modules/agent/tools/progressive_tools.zig` (one module, `skill_tools.zig` shape) exporting the three tools with wire names `search_tool` / `view_tool` / `use_tool`, each with a `system_prompt` teaching the flow, that tools are lazily enabled, and that already-enabled tools are not searchable.
- [ ] Renderers producing the Wire Contract envelopes: `MAX_SEARCH_ROWS = 40`, 120-char summaries, `<truncated/>`, did-you-mean.
- [ ] Inline tests: catalog excludes a name in `enabled_builtins`; a built-in like `kanban_list` is found by name and by description substring; `equipped=session` after its name is in `equipped_names`; `server` filter; row cap; empty catalog → `count=0` not an error; `view_tool` unknown → `found=false` + did-you-mean; `use_tool` renderer takes `inserted` from the caller, never guesses.
- [ ] Register both new files in `src/ai_workflow/tui/test_runner.zig`.
- [ ] `Commit:` `feat(tools): progressive catalog + search_tool/view_tool/use_tool definitions`

### Task 4 — Thread `allowed_tools` + `is_sub_agent` to the exec layer

- [ ] `tools.zig` `ToolExecContext` (`:78-113`): add `allowed_tools: []const u8 = ""` and `is_sub_agent: bool = false` (defaulted, so no existing construction site breaks).
- [ ] `handle_tool.zig` `ToolContext` (`:38`): add both fields; set them where the `ToolContext` is built inside `handle_tool`.
- [ ] `handle_tool.zig:316` `handle_tool(...)`: add both parameters (positional — update the one call site). Pass `ctx.allowed_tools` / `ctx.is_sub_agent` into the `ToolExecContext` built at `:191-212`.
- [ ] `workflow.zig:1276`: pass `copy_allowed_tools` and `copy_is_sub_agent`.
- [ ] If any other `handle_tool` / `dispatchFromRegistry` caller or test exists outside `workflow.zig:1276`, update it too (the compiler will list them).
- [ ] Assert the thread is real: an inline test that dispatches a probe tool and checks the ctx sees a known `allowed_tools` value. Keep it as a permanent test rather than deleting it.
- [ ] `Commit:` `feat(agentic-loop): thread allowed_tools + is_sub_agent into ToolExecContext`

### Task 5 — Exec adapters + registry wiring + persistence signal

- [ ] `tools_exec_progressive_tools.zig`. All three need the catalog: `nalarcore.getSingleton()` → `di.getMcpToolsCached(ctx.allocator)` (the same call the workflow makes at `:573-574`), `getProgressiveTools(ctx.session_id)`, the registered set from `tools_equipped.equips`, the eligible base via `tool_eligibility.allowlistFilter(equips, ctx.allowed_tools, ctx.is_sub_agent)`, and `self_item_type` via `llm_history.getWorkspaceContext(ctx.db, ctx.session_id)` for `itemTypeStrip`. Do **not** refetch from MCP servers — the cache is the source of truth and dispatch already matches it.
- [ ] `execUseTool`: catalog lookup → miss = not-found envelope, zero writes → hit = `isProgressiveToolEquipped` check (already `session` ⇒ `inserted=false`, zero writes) → else `saveProgressiveTool`; set `progressive_tool_save` **only when it returned `true`**.
- [ ] `tools.zig`: `pub const ProgressiveToolSaveInfo = struct { name: []const u8, server_name: []const u8 };` + `progressive_tool_save: ?ProgressiveToolSaveInfo = null` on `ToolExecResult` (`:115-127`).
- [ ] `handle_tool.zig`: after the `skill_saved` block (`:617-621`), persist `progressive_tool_save` via `saveProgressiveTool`; log-and-continue on failure.
- [ ] `tools_equipped.zig`: `+const progressive_tools_mod = nalarcore.progressive_tools;`, +3 lines in `equips()`, +3 rows in `UNIFIED_TOOL_REGISTRY()`; `tools.zig` +3 re-exports.
- [ ] Static-contract test (copy `tools_exec_list_sub_agent.zig:252-272`): `equips()`, `UNIFIED_TOOL_REGISTRY()` and `tools.zig` all agree the three names exist.
- [ ] Inline DB test for the validation rule: unknown name writes nothing; first `use_tool` on a **built-in** (`kanban_list`) inserts exactly one row; a second call is `inserted=false` with the table still at one row.
- [ ] `Commit:` `feat(tools): progressive search/view/use adapters + registry wiring`

### Task 6 — Make it real at the choke point

- [ ] `workflow.zig:1739`: `filterAndMergeTools` takes `progressive_equipped: []const []const u8`; merge becomes enabled built-ins → equipped built-ins → equipped MCP tools; append the three meta-tools when the catalog is non-empty and after the allowlist filter (so they are exempt); dedup by name, built-in wins.
- [ ] `workflow.zig:1022`: read `getProgressiveTools(allocator, db, copy_session_id)` first and pass the names; keep the single `merged_tools` feeding `:1028` and `:1050`.
- [ ] Extend the `[CHECKPOINT] tools resolved` log (`:1023-1026`) with `catalog={d} builtin_equipped={d} mcp_catalog={d} mcp_equipped={d}` — nothing parses this line today, so widening it is free, and it is the functional test's hook.
- [ ] **Rewrite** the test at `:2426-2467` into three: MCP tools are absent when the progressive set is empty (the new contract); present and appended last when passed in; an enabled built-in is never duplicated, and a built-in passed in the progressive set appears even when the allowlist excluded it.
- [ ] Update every `filterAndMergeTools` call site the compiler flags.
- [ ] `Commit:` `feat(agentic-loop): not-enabled built-ins and MCP tools are discoverable and session-equippable`

### Task 7 — Prompt rule + description truth-up

- [ ] `core.zig`: `pub const ProgressiveToolRule = …` — short: some tools are not loaded; `search_tool` finds them (already-enabled tools are not listed, check your tool list first); `view_tool` shows parameters; `use_tool` enables one for this session from the next turn. A missing capability means "search", never "give up".
- [ ] Append it in `prompts_build_messages_for_agent_prompt.zig` when `hasTool(filtered_tools, "search_tool")` — the idiom at `:99-124`.
- [ ] `add_mcp_server.zig:103` promises "The new server's tools appear on the NEXT iteration." Reword: appear in `search_tool` next iteration, callable after `use_tool`. Same for the comment at `:174`, `tools_equipped.zig:51`/`:153-154`, `tools.zig:66`.
- [ ] `Commit:` `docs(prompt): document progressive tools; correct add_mcp_server contract`

### Task 8 — Frontend card

- [ ] `ProgressiveTool.vue` handling all three names: `search_tool` rows with `kind` + `equipped` chips; `view_tool` description + collapsible `<details>` schema; `use_tool` with a clear visual split between `inserted=true` and already-enabled. Reuse `unwrapToolOutput` (`helpers/unwrapToolOutput.ts:62`).
- [ ] `ProgressiveTool.spec.ts` (9 cases): search rows; builtin vs mcp chip; `equipped=session` chip; empty catalog state; truncated hint; view schema collapsed then expanded; use-inserted; use-already-enabled; unknown + did-you-mean; malformed envelope fallback.
- [ ] `ChatView.vue`: three `v-else-if` branches (`:3329-3378`, before the generic `v-else` at `:3379`). Mirror in `src/apps/desktop/src/components/nalar/SubAgentPeekPanel.vue` if it has its own chain.
- [ ] `pnpm test:unit` + `bun run build`; delete any `.js` files `vue-tsc --build` emits next to `.ts` sources.
- [ ] `Commit:` `feat(desktop): progressive tool output card`

### Task 9 — Functional tests

- [ ] `tests/functional/progressive_tool_test.py` with `FunctionalHarness.boot(stub_llm_profile=True)` and the repo's hello-world MCP servers (`harness.py:1082`, `:1113`).
- [ ] Test 1 (built-in equip drives the prompt): create a kanban item (allowlist = the 2 seeded kanban tools), queue a message, wait for the `[CHECKPOINT] tools resolved` line, note `merged_count`; insert a `session_progressive_tool` row for a built-in the allowlist excluded (e.g. `glob`); re-queue; assert `builtin_equipped=1` and `merged_count` grew by exactly 1.
- [ ] Test 2 (MCP fetched, not injected): configure the MCP server; assert `mcp_catalog > 0` and `mcp_equipped=0`, and that `merged_count` excludes all `mcp_*` names.
- [ ] Test 3 (duplicate rejected): insert the same name twice via SQL into the harness tmpdir `agent.db` and assert the PK/`INSERT OR IGNORE` leaves exactly one row — the DB half of the validation rule.
- [ ] Test 4 (item-type policy holds): with the catalog non-empty, assert `search_tool`'s catalog for a kanban item contains no design names and no `spawn_sub_agent` for a sub-agent session.
- [ ] Run `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/progressive_tool_test.py -v` after `zig build install:linux`.
- [ ] `Commit:` `test(functional): progressive tool catalog — built-in equip + MCP not injected`

### Task 10 — Measurement + PR body

- [ ] From Test 2, quantify what left the context: the MCP tool count × their serialized size (literal text + ~18% JSON, the convention used for the built-in baseline), and the per-call token delta for an MCP-heavy session.
- [ ] Record honestly that built-ins are **not** trimmed by design; the win is MCP-only plus the ability to reach excluded built-ins without a config change.
- [ ] Note the follow-up trigger: if the dogfood shows the agent failing to reach for `search_tool`, add `mcp_progressive_enabled` (Design Decision 8 / Open Question 2).
- [ ] `Commit:` `docs: record progressive tool search measurements`

## Verification

- `zig build test --summary all` — green, including the extracted eligibility helpers (behaviour-identical to before), the rewritten `filterAndMergeTools` tests, the migration tests and the static-contract tests.
- `pnpm test:unit` (from `src/apps/desktop`) — green, including `ProgressiveTool.spec.ts`.
- `bun run build` — clean.
- `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/progressive_tool_test.py -v` — 4 passed.
- **Refactor gate:** Task 1 changes no behaviour — every pre-existing `filterAndMergeTools` / `filteringTools` test passes unmodified before Task 6 lands.
- **No-regression gate:** for an item whose allowlist covers all built-ins and with no MCP configured, the resolved list is identical (names AND order) to pre-change, and `catalog=0` so the three meta-tools are absent.
- **Discovery gate:** an enabled built-in never appears in `search_tool` results; a not-enabled built-in does, and `use_tool` on it makes it appear in the next resolution.
- **Persistence gate:** the agent's `use_tool` writes only `session_progressive_tool`; `agent_tools` / `agent_kanban_tools` row counts are unchanged after the run (assert this explicitly in Test 1 — it is the safety property of the whole design).
- **Validation gate:** `use_tool` on an already-equipped name performs zero writes and reports `inserted=false`; on an unknown name, zero writes and `equipped=false`.
- Port 8081 was never touched.

## Out of Scope (explicit non-goals)

- Trimming or tiering **enabled** built-in tools. They stay fully injected.
- A **hard-deny** state for tools the user unchecks (i.e. making `enabled=0` meaningful and excluding those names from the catalog). Design Decision 3 explains why it is not needed today — the toggle is DELETE, so there is no deny flag to violate. Adding it later is a small, self-contained task.
- `use_tool` enabling *and* invoking in one call (Decision 5, open question).
- A config flag (Decision 8 — the trigger for adding one is recorded).
- BM25/embedding ranking for `search_tool`; v1 is substring + exact server filter.
- Auto-unequipping session tools that go unused, and any eviction limit on the equipped set.
- Fixing the MCP `required: []` TODO (`prompts_build_messages_for_agent_prompt.zig:580-585`), which `view_tool` inherits.
- Fixing the pre-existing `allowed_tools == ""` ambiguity (`workflow.zig:1749` treats it as "no filter" while its doc comment and `maybeOverrideAllowedToolsForAgent` imply "no tools"). Task 1 must preserve the existing behaviour exactly, wart included.
- A settings-UI toggle or a per-session tool inspector.
- New SSE event types (tool results already ride inside `llm_full`; a new named event would need the frontend's `additionalEventTypes` pre-registration at `api/index.ts:3295`).

## Open Questions for the reviewer

1. **Kanban capability expansion.** A kanban item seeds only 2 built-ins (`DEFAULT_KANBAN_TOOLS`), so its catalog is ~35 tools — the agent could equip `spawn_sub_agent`, memory tools, `command`, and (for a kanban item, after the item-type strip) everything except design. Is that intended? Options: accept it; or restrict the catalog to a curated per-item-type allowlist; or add the hard-deny flag from Out of Scope. **The plan implements "accept it"** because it follows your rule literally, and the item-type strip already blocks the one policy that exists.
2. **Equip+invoke in one call** (Decision 5).
3. **`search_tool` finds nothing for an already-enabled capability.** By your rule, enabled built-ins are not searchable, so searching for "memory" returns 1 result (the MCP side) instead of 4 built-ins that are already in the prompt. The mitigation is the hint text plus `ProgressiveToolRule`; if the dogfood shows the model concluding a capability is missing, listing enabled built-ins as `equipped=native` rows is a one-line change to the catalog.
4. **Flag or no flag** (Decision 8).

## Risks

1. **The agent never calls `search_tool`** → tools look missing although dispatch would still execute an MCP call. Mitigations: `ProgressiveToolRule`; the failure envelopes always name the next step; Test 1/2's checkpoint counters give a dogfood metric (`builtin_equipped` / `mcp_equipped` per session). Fallback: the flag.
2. **The exec adapter's catalog drifts from what the LLM actually has.** This is the sharpest risk, because "enabled" would then be computed twice. Hard mitigation: Task 1 extracts one implementation and both callers use it; the functional test asserts `catalog + merged = registered + mcp` for a given item. Do not let the implementer "simplify" this into a second CSV parse.
3. **`allowed_tools=""` ambiguity leaks into the catalog.** `""` means "no filter" to the code and "no tools" to `maybeOverrideAllowedToolsForAgent`. The catalog is derived from the **post-filter result**, not the raw string, so the ambiguity cannot change the catalog — but Task 1's tests must pin both readings.
4. **Threading churn** (`ToolExecContext` → `ToolContext` → `handle_tool` → `workflow.zig:1276`) touches a `pub fn` with 18 positional params. Mechanical, but the compiler is the only safety net; keep the two new fields defaulted so unrelated call sites and tests keep compiling.
5. **A resumed session.** If a `tool_use` from an enabled tool is in the transcript but the row was deleted from `session_progressive_tool`, the schema is missing from `tools[]`. Mitigation: `use_tool` persists in the dispatch loop (Task 5), not only in the tool result; add a test that resumes a session with a pre-existing equip row and asserts it is still resolved.
6. **Name collisions.** A server tool named `glob` collides with the built-in. Dedup is first-wins (built-in), and `search_tool` will not offer `glob` twice.
7. **`getMcpToolsCached` deep-dupes.** Called by three adapters ⇒ up to three dupes per dispatch, all on the per-request arena (no leak). If `search_tool` turns out hot, snapshot once per iteration instead.
8. **`view_tool` inherits the `required: []` wart** for MCP tools, so it can show a schema with no required fields. Separate fix; noted so the reviewer is not surprised.

## Plan saved checklist

- [ ] Plan saved to `docs/superpowers/plans/2026-09-12-progressive-tool-search.md`
- [ ] Header includes Goal / Architecture / Tech Stack / Global Constraints
- [ ] Bite-sized steps with `- [ ]` checkboxes and per-task commits
- [ ] User reviewed before execution
