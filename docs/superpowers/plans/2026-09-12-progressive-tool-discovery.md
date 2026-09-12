# Progressive Tool Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop sending every tool schema on every LLM call. Ship a small always-present *core* toolset plus two meta-tools (`list_tools`, `load_tool`) so the agent discovers and enables the remaining 27 built-ins and *all* MCP tools on demand, per session.

**Architecture:** A pure resolver (`tool_discovery.zig`) sits at the single existing choke point — `filterAndMergeTools` (`src/agentic_loop/workflow.zig:1739`), called once per loop iteration at `workflow.zig:1022` and consumed by both `buildMessages` (`:1028`) and `callDynamicAgentNew` (`:1050`). It returns `core ++ loaded` instead of `everything`, ordered so discovered tools are **appended at the end** (never spliced), with all names deduped and the total byte/count budget enforced. "Loaded" state is per-session (`session_tools` table, mirroring `session_skills`) plus a safety union of every tool name already used in the session's history — so a resumed session never sends a `tool_use` whose definition is missing from `tools[]`. The design is provider-agnostic (works identically for OpenAI chat, OpenAI Responses and Anthropic) because it only ever changes *which* schemas are in the `tools` array.

**Tech Stack:** Zig 0.16 (`AgentTool` + `ToolExecContext` + `wrapToolOutput`), SQLite (Migration 085 `session_tools`), Vue 3 + vitest (`ToolDiscovery.vue` card), python functional harness (isolated tmpdir HOME + log-tail assertions).

## Global Constraints

- **Never touch the process on port 8081.** Functional tests use the harness's random port (`tests/functional/harness.py`), which reserves 8081.
- **`tool_discovery_enabled` defaults to `false`** in this plan. While false, the resolved set must be **byte-identical** to today's `filterAndMergeTools` output — no reordering, no dropping. Task 10 contains the explicit flip-to-true gate.
- **Append-only invariant.** Discovered/deferred schemas are appended after the core block. Never insert into the middle, never reorder core. `tools[0..core.len]` must be byte-stable across iterations for a given session. (This is what both Anthropic's deferred-tool `tool_reference` and OpenAI's tool-search contract do to preserve prompt caching; nalar sends no `cache_control` today, so this rule is forward-proofing, not a present-day cache win.)
- **No `// NEW (plan: …)` comments.** Explain *why* in one plain sentence or not at all.
- Per-request arena: `ctx.allocator` is arena-backed — do NOT `defer free` arena slices inside exec adapters.
- Do not change the meaning of `allowed_tools == ""`. Today the code treats it as **zero tools** (`workflow.zig:1749`) while the doc comment claims the opposite; a sub-agent spawned without `tools` is therefore bricked to MCP-only. Fixing that is a separate decision — see Design Decision 6.
- Worktree/PR flow: work in `/home/ginwa/ginwaaitoolbox/.worktree/worktrees_agent_<name>`, push with `--no-verify` for docs-only commits, open a PR against `main`.
- Verification gates: `zig build test --summary all`, `pnpm test:unit` (in `src/apps/desktop`), `bun run build`, and `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/<file> -v`.

## Current State (verified 2026-09-12 in this worktree)

The one place the tool set is decided:

| Step | Where | What |
|---|---|---|
| Registry | `src/agentic_loop/tools_equipped.zig:66-119` | `equips()` → comptime `&[_]AgentTool{…}`, **37 entries**, `allocator.dupe` on every call (called **twice** in one expression at `workflow.zig:1745-1746`) |
| Allowlist | `workflow.zig:1749-1768` | CSV filter, `""` = skip filter (= all), `"all"` = all |
| Sub-agent strip | `workflow.zig:1770-1779` | drops `spawn_sub_agent` |
| MCP merge | `workflow.zig:1782-1786` | appends MCP tools, **no dedup, no cap** |
| Per-item-type strip | `prompts_build_messages_for_agent_prompt.zig:1221-1266` | `filteringTools`: kanban↔design exclusion. **Mutates its input slice in place** (`removeTools`, `:1203-1219`) |
| Consumed | `workflow.zig:1022` → `:1028` (prompt) + `:1050` (LLM call) | per loop iteration |

Schema struct: `AgentToolFunction{name, description, parameters, system_prompt}` + `AgentTool{type, function}` (`src/modules/agent/tools/schemas.zig:52-67`). The three serializers each pick fields explicitly — Anthropic `Agent.zig:1500-1519` (`tools[].input_schema`), OpenAI chat `Agent.zig:1711-1733` (`tools[].function.parameters`), Responses `Agent.zig:1953-1972`.

### Measured baseline (this worktree, `/tmp/tools_baseline3.py`)

Script: masks Zig string literals (line-based, offset-preserving), brace-matches every `pub const <x>_tool = AgentTool{…}`, sums literal bytes for the 37 equipped names. Only `text_replace` is missed (declared `pub const text_replace_tool: AgentTool = .{` at `text_replace.zig:562`).

```
equipped tools counted : 36/37
TOTAL tools[] literals : 70,008 bytes   (~17,502 tokens at bytes/4)
Excludes JSON structure (~+18%) and system_prompt text
```

| Items | Bytes | ~Tokens |
|---|---|---|
| Literal text of the 37 equipped schemas | 70.0 KB (+`text_replace` ≈ 0.7 KB) | ~17.5k |
| + JSON structure (`{"type":…,"function":…,"properties":{…}}`) | ≈ 83 KB | **≈ 21k** |
| Per-tool `system_prompt` aggregated into the system message | ≈ 16 KB | ≈ 4k |
| MCP tools | **unbounded** — no count or byte cap anywhere | — |

Largest schemas: `search_history` 5,989 B · `create_kanban_task` 4,982 B · `search` 4,930 B · `spawn_sub_agent` 4,665 B · `command` 4,562 B · `show_preview` 3,060 B · `generate_image` 2,907 B · `add_element` 2,897 B · `load_memory` 2,857 B. Smallest: `list_skills` 305 B · `remove_file` 324 B · `list_sub_agent` 331 B.

All of this is **re-sent on every iteration of every session**, stateless (no cache): `buildJson*Request` rebuilds the body per call, and `Agent` holds no `tools` field — tools arrive per-call via `AgentCall.tools` (`Agent.zig:1117-1122`).

## Design Decisions (for reviewer)

1. **Meta-tools, not a provider feature.** Anthropic ships a GA `tool_search_tool_regex_20251119` / `tool_search_tool_bm25_20251119` tool type with `"defer_loading": true` per definition, and OpenAI has `{"type":"tool_search"}` (Responses, `gpt-5.4+`). Both are model-gated: Anthropic requires Opus 4.5+/Sonnet 4.5+/Haiku 4.5+, and nalar users point `base_url` at arbitrary proxies/models. So the portable baseline is our own `list_tools`/`load_tool` pair, which works on every provider. The native path is recorded as an optional fast-path (Task 10, Out of Scope for v1).
2. **A separate catalog table, not a new struct field.** Adding `.tier = …` to `AgentToolFunction` would touch all 37 tool files and the literal text would grow. Instead `src/agentic_loop/tool_catalog.zig` holds one comptime table `name → {tier, category, summary}`. Classification becomes a single reviewable diff, and a static test asserts the table covers exactly `equips()` (no missing, no extra).
3. **Persist names, not schemas.** `session_tools(session_id, tool_name, loaded_at_nano)` stores only names — a tool definition change ships instantly on the next turn instead of being shadowed by a stale cached copy. (`session_skills` stores bodies because skill *content* is user-authored data; tool schemas are code.)
4. **History union as the correctness backstop.** If a session is resumed after the loop has already run a tool whose schema is no longer in `tools[]`, providers reject the transcript (a `tool_use` referencing an undefined tool). The resolver therefore unions in every tool name found in the session's `llm_history` tool calls. Cheap: the loop already has `db_messages` in hand at `workflow.zig:991`.
5. **`load_tool` takes effect on the NEXT call, and says so.** `merged_tools` is resolved before the LLM call at `:1022`, so a tool loaded mid-iteration is callable from the following iteration. This is the same one-turn lag `use_skill` has; the `load_tool` result carries the full schema so the model can already plan the call correctly.
6. **Empty allowlist semantics are left alone.** `allowed_tools == ""` keeps meaning "zero base tools" for v1, because `maybeOverrideAllowedToolsForAgent` (`workflow.zig:1997-2055`) *relies* on that. With discovery enabled a zero-tool sub-agent would get nothing at all — so this plan adds an explicit, tested carve-out: when discovery is on **and** the allowlist resolved to zero base tools **and** `is_sub_agent` is true, grant the core set. Flagged here because it is the only intended behaviour change for non-default config.
7. **Budget guard is part of v1, not a follow-up.** MCP is the unbounded vector (a Context7-style server can add 30+ tools, several servers unbounded). `MAX_LOADED_TOOLS = 12` and `MAX_TOOLS_BYTES = 64 * 1024` are enforced in the resolver; over-budget deferred tools are dropped oldest-first with a `<warning>` injected into the prompt.
8. **All MCP tools are deferred when the flag is on.** The agent reaches them through `list_tools(query=…)` + `load_tool`. That is the single biggest context win and the reason the index needs a `query` parameter.
9. **A boolean, not a mode enum.** The obvious shape is `tool_discovery: off|auto|aggressive`, but every equivalent global toggle in this repo is a bool (`web_launch_enabled`, `notify_on_complete`, `notify_on_error`), a bool needs no new `LoadError` variant, and it round-trips through the existing PUT/GET plumbing unchanged. The realistic threshold for an `aggressive` tier is unknown, so shipping it unmeasured would be speculative config surface. If the dogfood run (Task 10) shows the 12-tool core is still too fat, adding a third mode is a small, additive change.

## Catalog (the split when the flag is on)

Core (12 — always sent). Chosen as the universal coding loop plus the two meta-tools; every one is either required to read/verify code or gates an existing static prompt section (`hasTool` at `prompts_build_messages_for_agent_prompt.zig:99-124`). `get_plan` is included even though it gates nothing, because the Task Planning section that `update_plan` gates explicitly tells the model to use it.

| Core tool | Bytes (literals) | Gates which prompt section |
|---|---|---|
| `command` | 4,562 | `GitPrompt` |
| `search` | 4,930 | `SearchToolRule` |
| `read_file` | 490 | — |
| `write_file` | 458 | — |
| `text_replace` | ≈700 | — |
| `glob` | 1,476 | — |
| `list_directory` | 936 | — |
| `update_plan` | 1,296 | Task Planning |
| `get_plan` | 994 | — |
| `update_activity` | 672 | `UpdateActivityRule` |
| `list_tools` (NEW) | ≈900 | `ToolDiscoveryRule` (NEW) |
| `load_tool` (NEW) | ≈600 | — |
| **total** | **≈ 18.0 KB → ≈21 KB with JSON ≈ 5.3k tokens** | |

Deferred (27 built-ins, all deferred when the flag is on): `spawn_sub_agent` · `list_sub_agent` · `add_mcp_server` · `list_skills` · `use_skill` · `remove_skill` · `add_skill` · `edit_skill` · `save_memory` · `load_memory` · `delete_memory` · `search_history` · `remove_file` · `generate_image` · `set_git_worktree` · `show_preview` · `kanban_list` · `kanban_move_task` · `create_kanban_task` · `set_design_page` · `add_element` · `update_element` · `group_elements` · `set_element_parent` · `move_design_element` · `get_design_context` · `preview_design_page` — **plus every MCP tool**.

Expected effect with the flag on: **≈83 KB → ≈21 KB of `tools[]` per LLM call (−75%, ≈15.5k tokens)**, and the per-tool `system_prompt` block drops with the deferred set (~16 KB → ~4 KB).

## Wire Contract

### `list_tools` (input)

```json
{
  "query": "optional case-insensitive substring filter over tool name + description",
  "category": "optional exact category: files|shell|memory|skills|plan|sub_agent|kanban|design|preview|media|mcp|meta"
}
```

### `list_tools` (success)

Core tools are deliberately **not** enumerated (they are already visible in `tools[]`); only their count is echoed. Rows are the *deferred* tools, capped at `MAX_INDEX_ROWS = 60` with one-line summaries truncated to 120 chars.

```xml
<list_tools><count>27</count><core_count>12</core_count><loaded_count>2</loaded_count>
<tools>
<tool><name>generate_image</name><tier>deferred</tier><category>media</category><loaded>false</loaded><summary>Generate an image from a text prompt. Saves to disk and returns a path; call show_preview to display it.</summary></tool>
<tool><name>mcp_context7_query-docs</name><tier>deferred</tier><category>mcp</category><loaded>true</loaded><summary>Retrieves up-to-date documentation and code examples...</summary></tool>
</tools>
<hint>Call load_tool with an exact name to enable one for your next turn. Use query to narrow when truncated.</hint>
</list_tools>
```

Truncated variant replaces `<hint>` with `<truncated/><hint>Showing 60 of 214. Re-run with query=… to narrow.</hint>`.

### `load_tool` (input)

```json
{ "name": "generate_image" }
```

### `load_tool` (success)

```xml
<load_tool><name>generate_image</name><loaded>true</loaded><already_loaded>false</already_loaded><wait_next_turn>true</wait_next_turn>
<schema><![CDATA[{"type":"function","function":{"name":"generate_image","description":"...","parameters":{...}}}]></schema>
<note>Full parameter schema above. This tool becomes directly callable from your next turn (the current turn's tool list was already sent).</note>
</load_tool>
```

### `load_tool` (unknown name — never fails open)

```xml
<load_tool><name>generat_image</name><loaded>false</loaded>
<error>unknown tool 'generat_image' — not in this session's eligible tool set</error>
<did_you_mean><name>generate_image</name></did_you_mean>
<hint>Call list_tools to see every available name.</hint></load_tool>
```

### Config

A single global boolean, mirroring the existing `web_launch_enabled` (`Config.zig:49`) / `notify_on_complete` (`:32`):

```json
{ "tool_discovery_enabled": false }
```

`false` (default this plan) = today's behaviour exactly. `true` = the core/deferred split. It travels as a normal global config field through `GET`/`PUT /api/config/nalar` (both handlers already carry the same bool fields), and `LlmConfig` gains `tool_discovery_enabled: bool = false` beside `web_launch_enabled`. Global-only in v1 (per-profile override is Out of Scope). No new `LoadError` variant is needed — a missing key takes the default and a non-boolean is rejected by the existing JSON parse.

### Migration 085

```sql
CREATE TABLE IF NOT EXISTS session_tools (
  session_id     TEXT NOT NULL,
  tool_name      TEXT NOT NULL,
  loaded_at_nano INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (session_id, tool_name)
);
CREATE INDEX IF NOT EXISTS idx_session_tools_session ON session_tools(session_id);
```

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/agentic_loop/tool_catalog.zig` | NEW | `Tier` enum, comptime `name → {tier, category, summary}` table, `lookup(name)`, `coreCount()` |
| `src/agentic_loop/tool_discovery.zig` | NEW | Pure resolver: `resolveEquipped(allocator, eligible, loaded_names, history_names, is_sub_agent, mode) !ResolvedSet` + `ResolvedSet{core, deferred_loaded, dropped, bytes}`, budget enforcement, dedup, history union |
| `src/agentic_loop/tool_discovery_test.zig` | NEW | Pure unit tests for the resolver + the byte/count budget + append-only ordering (no DB, no HTTP) |
| `src/modules/agent/tools/tool_discovery_tools.zig` | NEW | `list_tools_tool` + `load_tool_tool` defs, their `system_prompt` strings, pure `renderToolIndex(...)` / `renderToolSchema(...)` |
| `src/agentic_loop/tools_exec_tool_discovery.zig` | NEW | `execListTools` / `execLoadTool` adapters; `load_tool` returns `tool_load = .{name}` on success |
| `src/agentic_loop/tools_equipped.zig` | EDIT | +2 imports, +2 lines in `equips()`, +2 rows in `UNIFIED_TOOL_REGISTRY()` |
| `src/agentic_loop/tools.zig` | EDIT | +2 exec re-exports; `ToolExecResult` gains `tool_load: ?ToolLoadInfo` (mirrors `skill_save`) |
| `src/agentic_loop/handle_tool.zig` | EDIT | persist `tool_load` next to the existing `skill_saved`/`agent_saved` block (`:616-628`) |
| `src/agentic_loop/llm_history.zig` | EDIT | `saveTool` / `getSessionTools` / `isToolLoaded` next to the session-skills block (`:3678-3759`) |
| `src/agentic_loop/workflow.zig` | EDIT | `:1022` — wrap `filterAndMergeTools` with the resolver; extend the `[CHECKPOINT] tools resolved` log with core/loaded/deferred counts |
| `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig` | EDIT | `hasTool` gates + `appendToolBehaviorSection` consume the **resolved** set; append `ToolDiscoveryRule` when `list_tools` is present |
| `src/modules/agent/prompts/core.zig` | EDIT | +`ToolDiscoveryRule` static text |
| `src/modules/config/Config.zig` | EDIT | `LlmConfig.tool_discovery_enabled: bool = false` (beside `web_launch_enabled`, `:49`) + `LlmConfigJson` mirror + parse |
| `src/http_handlers/nalar_config_put.zig` / `nalar_config_get.zig` | EDIT | accept/emit the new bool (same plumbing as `web_launch_enabled`) |
| `src/migrations/migration.zig` | EDIT | Migration 085 `add_session_tools` + inline tests (pattern: the 081/084 blocks at `:4864+`) |
| `src/apps/desktop/src/components/tool_outputs/ToolDiscovery.vue` | NEW | Card for `list_tools` (grouped rows + loaded chips) and `load_tool` (name + ok/err + collapsible schema) |
| `src/apps/desktop/src/components/tool_outputs/ToolDiscovery.spec.ts` | NEW | vitest: index rows, empty index, unknown-name error + did-you-mean, schema collapsed by default |
| `src/apps/desktop/src/components/views/ChatView.vue` | EDIT | two `v-else-if` branches in the dispatcher chain (`:3329-3378`, before the `mcp_` branch at `:3373` and the generic `v-else` at `:3379`) |
| `tests/functional/tool_discovery_test.py` | NEW | wire-level proof via harness log tail + `session_tools` round-trip |
| `docs/superpowers/plans/2026-09-12-progressive-tool-discovery.md` | THIS FILE | Plan under review |

## Tasks

### Task 1 — Byte-exact baseline (red → green)

- [ ] Add `src/agentic_loop/tool_discovery_test.zig` with one test that builds a request body from `tools.all_agent_tools(arena)` + a single user message via `Agent.buildJsonAnthropicRequest` (`Agent.zig:1310`, `pub fn`) and prints `body.len` and `body.len / 4`. If constructing an `Agent` + `AgentCall` from that file is awkward, put the test in `src/modules/agent/anthropic_request_test.zig` (which already builds one) and keep only the resolver tests in the new file.
- [ ] Register it in `src/ai_workflow/tui/test_runner.zig` following the existing `_ = @import("../../agentic_loop/workflow.zig");` pattern (root.zig:880 imports this aggregator).
- [ ] Run `zig build test --summary all 2>&1 | tail -20` and record the printed byte count. Assert it is within `[75_000, 100_000]` so the number is pinned but not brittle.
- [ ] Add the same measurement for the OpenAI chat builder and record both numbers in this file's table (replace the script estimate with the compiled one).
- [ ] Delete `Excludes JSON structure (~+18%)` from this doc's table and put the real figure in.
- [ ] `Commit:` `test(agentic-loop): pin the serialized tools[] baseline`

### Task 2 — Tool catalog

- [ ] Create `src/agentic_loop/tool_catalog.zig` with `pub const Tier = enum { core, deferred };`, `pub const Category = enum { files, shell, memory, skills, plan, sub_agent, kanban, design, preview, media, mcp, meta };` and `pub const entries = [_]Entry{ … }` covering the Catalog section above verbatim.
- [ ] `pub fn lookup(name: []const u8) ?Entry`, `pub fn coreCount() usize`, `pub fn summary(name) []const u8`.
- [ ] Inline tests: table has exactly 37+2 = 39 entries; every `equips()` name is present exactly once (import `tools_equipped.zig`, iterate `equips(std.testing.allocator)`); the 2 meta names are present; `coreCount() == 12`.
- [ ] Inline test: no `equips()` name is `Tier.core` without also being in the Catalog core table (guards against a silent tier flip).
- [ ] **Failing-first check:** before writing `entries`, assert the test fails with a missing-entry report — then fill the table.
- [ ] `Commit:` `feat(agentic-loop): add tool catalog (tier + category + one-line summary)`

### Task 3 — Migration 085 + persistence helpers

- [ ] Add `Migration085AddSessionTools` to `src/migrations/migration.zig` (SQL from the Wire Contract) + register it in `allMigrations`.
- [ ] Inline migration tests, copying the shape of the `Migration081`/`Migration084` tests at `migration.zig:4864+`: creates the table with the right columns; is idempotent on re-run; is registered in `allMigrations`; `PRIMARY KEY(session_id, tool_name)` rejects a duplicate.
- [ ] Add to `src/agentic_loop/llm_history.zig` beside `saveSkill` (`:3699`): `saveTool(allocator, db, logger, session_id, tool_name)` (`INSERT OR REPLACE`, skip when `session_id.len == 0`), `isToolLoaded(...) -> !bool`, `getSessionTools(...) -> ![][]u8` (names only, caller-owned), `deleteSessionTool(...)`.
- [ ] Register `tool_discovery.zig` + `tool_discovery_test.zig` in `src/ai_workflow/tui/test_runner.zig`.
- [ ] Inline test: `saveTool` twice with the same name leaves one row; `getSessionTools` on an unknown session returns an empty slice; empty `session_id` is a no-op.
- [ ] `Commit:` `feat(db): migration 085 session_tools + persistence helpers`

### Task 4 — Pure resolver

- [ ] Create `src/agentic_loop/tool_discovery.zig`:
      `pub const Mode = enum { off, auto };`
      `pub const ResolvedSet = struct { core: []const AgentTool, deferred_loaded: []const AgentTool, dropped: []const []const u8, bytes: usize, fn all(self) []const AgentTool };`
      `pub fn resolveEquipped(allocator, eligible: []const AgentTool, loaded_names: []const []const u8, history_names: []const []const u8, is_sub_agent: bool, mode: Mode) !ResolvedSet`
- [ ] `Mode.off` returns `eligible` unchanged and in the original order (assert pointer-content equality, not just length) — this is the no-regression contract for Global Constraints.
- [ ] `Mode.auto`: partition by `tool_catalog.lookup(name).tier`; include a deferred tool iff its name is in `loaded_names ∪ history_names`; order `core ++ deferred_loaded`; drop `spawn_sub_agent` from core when `is_sub_agent`; dedup by name keeping the first occurrence (built-ins win over MCP).
- [ ] Budget: stop adding deferred tools once `deferred_loaded.len == MAX_LOADED_TOOLS (12)` or the summed literal bytes of `core ++ deferred_loaded` exceeds `MAX_TOOLS_BYTES (64 * 1024)`; record the skipped names in `dropped`, **oldest first** (order by `loaded_names` position). Never drop a core tool, and never drop a tool found in `history_names`.
- [ ] **Known hazard:** `filteringTools` mutates its input in place (`removeTools`, `prompts_build_messages_for_agent_prompt.zig:1203-1219`). The resolver must `allocator.dupe` the slice it is given before partitioning, and the caller must pass the copy it wants mutated.
- [ ] Tests in `tool_discovery_test.zig`: off-mode identity; auto keeps exactly the loaded deferred tool; append-only ordering (`all()[0..core.len]` equals the core slice of a later, larger set); dedup when a name is both loaded and in history; budget drop order; MCP-named tools treated as deferred; sub-agent strips `spawn_sub_agent`.
- [ ] `Commit:` `feat(agentic-loop): pure progressive tool resolver + budget guard`

### Task 5 — Meta-tool definitions

- [ ] Create `src/modules/agent/tools/tool_discovery_tools.zig` with `list_tools_tool` and `load_tool_tool` (`AgentTool{…}` literals, `system_prompt` fields) following `skill_tools.zig`'s merged-file shape.
- [ ] `list_tools` description must state: index only; call `load_tool(name)` to enable; use `query` when the result is truncated.
- [ ] `load_tool` description must state: exact name from `list_tools`; takes effect next turn; unknown names are rejected.
- [ ] Pure `renderToolIndex(allocator, entries, loaded, query, category) ![]const u8` producing the `<list_tools>` envelope of the Wire Contract, with `MAX_INDEX_ROWS = 60` and 120-char summaries; `renderToolSchema(allocator, tool) ![]const u8` producing `<load_tool>` success/failure (failure includes did-you-mean via a simple substring/`std.mem.startsWith` ranking over eligible names).
- [ ] Inline tests: index omits core rows but counts them; `query` filters case-insensitively; truncation emits `<truncated/>`; unknown name → `<loaded>false</loaded>` + no `tool_load` signal; did-you-mean finds `generate_image` for `generat_image`.
- [ ] `Commit:` `feat(tools): list_tools + load_tool definitions`

### Task 6 — Exec adapters + registry wiring + persistence signal

- [ ] Create `src/agentic_loop/tools_exec_tool_discovery.zig`: `execListTools(ctx, tc)` (builds the eligible list from `tools_equipped.equips`, reads `getSessionTools`, renders the index) and `execLoadTool(ctx, tc)` (validates against the eligible set, returns the schema envelope, and on success sets `tool_load = .{ .name = name }` in `ToolExecResult`).
- [ ] `src/agentic_loop/tools.zig`: add `pub const ToolLoadInfo = struct { name: []const u8 };` and `tool_load: ?ToolLoadInfo = null` to `ToolExecResult` (`:115-127`), next to `skill_save`.
- [ ] `src/agentic_loop/handle_tool.zig`: after the `skill_saved` block (`:617-621`), call `llm_history.saveTool(...)` when `exec_result.tool_load` is set; log a failure instead of aborting the turn.
- [ ] `src/agentic_loop/tools_equipped.zig`: +2 imports, +2 lines in `equips()`, +2 rows in `UNIFIED_TOOL_REGISTRY()` with `.exec = tools.execListTools/execLoadTool`.
- [ ] `src/agentic_loop/tools.zig`: +2 re-exports.
- [ ] Static-contract test in `tools_exec_tool_discovery.zig` (copy `tools_exec_list_sub_agent.zig:252-272`): the registry, `equips()` and the catalog all agree the two meta names exist.
- [ ] `Commit:` `feat(tools): wire list_tools/load_tool into the registry + persist on load`

### Task 7 — Wire it into the loop + prompt + config

- [ ] `src/agentic_loop/workflow.zig:1022`: resolve `merged_tools = filterAndMergeTools(...)` (unchanged), then `loaded = getSessionTools(...)`, then `resolved = tool_discovery.resolveEquipped(allocator, merged_tools, loaded, historyToolNames(db_messages), copy_is_sub_agent, config.toolDiscoveryMode())`, then pass `resolved.all()` to both `buildMessages` (`:1028`) and `callDynamicAgentNew` (`:1050`).
- [ ] Add `fn historyToolNames(allocator, db_messages) ![][]const u8` — collect distinct `tool_name` values from the already-fetched `db_messages` (no new query).
- [ ] Extend the `[CHECKPOINT] tools resolved` log (`:1023-1026`) with `core={d} deferred_loaded={d} dropped={d} tools_bytes={d} mode={s}` — this line is the functional test's observability hook.
- [ ] When `resolved.dropped.len > 0`, append a short `<dropped_tools>` block to the system prompt (after `ToolDiscoveryRule`) naming the dropped tools and telling the model to re-`list_tools` if it needs one — so a budget drop is visible instead of silent.
- [ ] `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig`: pass the resolved set in; leave `filteringTools` where it is (it already ran upstream) but ensure the slice it receives is the resolver's dup, not the caller's buffer.
- [ ] `src/modules/agent/prompts/core.zig`: add `pub const ToolDiscoveryRule = …` — one short block naming `list_tools`/`load_tool`, stating that tools are lazy, and that a missing capability means "call `list_tools`", never "give up".
- [ ] Append `ToolDiscoveryRule` when `hasTool(filtered_tools, "list_tools")` (same idiom as the `:99-124` gates).
- [ ] `src/modules/config/Config.zig`: add `tool_discovery_enabled: bool = false` beside `web_launch_enabled` (`:49`), mirror it on the JSON struct, and thread it through the config PUT/GET handlers exactly as `web_launch_enabled` is threaded. Expose `pub fn toolDiscoveryMode(self: *const LlmConfig) tool_discovery.Mode` returning `.off` when the flag is false.
- [ ] Test: with the flag false, the end-to-end `tools[]` array is identical to pre-change (same names, same order) — the load-bearing regression test.
- [ ] `Commit:` `feat(agentic-loop): progressive tool discovery wired behind a config flag`

### Task 8 — Frontend card

- [ ] Create `ToolDiscovery.vue` in `src/apps/desktop/src/components/tool_outputs/`: one component handling both names — `list_tools` renders grouped rows (category header, name, loaded chip, summary); `load_tool` renders name + ok/err + the schema inside a `<details>` collapsed by default. Reuse `unwrapToolOutput` (`helpers/unwrapToolOutput.ts:58`) like the other cards.
- [ ] `ToolDiscovery.spec.ts` (vitest, 8 cases): index renders N rows; core count shown but core rows absent; `loaded` chip; truncated hint; `load_tool` success shows schema collapsed; unknown-name shows error + did-you-mean; malformed envelope falls back to raw; long summary truncates with ellipsis.
- [ ] `ChatView.vue`: add `v-else-if="msg.tool_name === 'list_tools'"` and `'load_tool'` branches in the dispatcher chain (`:3329-3378`, before the generic `v-else` at `:3379`); mirror in `src/apps/desktop/src/components/nalar/SubAgentPeekPanel.vue` (it carries its own `:deep(.chat-tool-card)` mirror).
- [ ] Run `pnpm test:unit` from `src/apps/desktop` and `bun run build`.
- [ ] `Commit:` `feat(desktop): tool discovery output card`

### Task 9 — Functional wire proof

- [ ] Create `tests/functional/tool_discovery_test.py` using `FunctionalHarness.boot(stub_llm_profile=True)`.
- [ ] Test 1 (default off): create a session + queue a message with the stock harness config, wait for the `[CHECKPOINT] tools resolved` line in `harness.tail_log()`, assert `mode=off` and `deferred_loaded=0`.
- [ ] Test 2 (enabled): PUT `{"tool_discovery_enabled":true}` via `/api/config/nalar`, repeat, assert `core=12`, `deferred_loaded=0`, `tools_bytes < 30000`, and — the key assertion — that the same line shows a `merged_count` unchanged from today while `tools_bytes` collapsed. This is the wire-level proof that the resolver, not the allowlist, is doing the work.
- [ ] Test 3 (persistence): read `session_tools` directly from the harness tmpdir `agent.db` with `sqlite3` and assert a row written by `load_tool` survives; then assert a session resumed afterwards logs `deferred_loaded=1`.
- [ ] Test 4 (config round-trip): PUT `{"tool_discovery_enabled":true}` → `GET /api/config/nalar` shows `true`; PUT `false` → GET shows `false`; a body omitting the key leaves the live value unchanged.
- [ ] Optional stretch (only if cheap): a local `HTTPServer` upstream capturing the outbound LLM body, following `tests/functional/mcp_test_test.py:433-493`, asserting the exact `tools[].function.name` list for call #1 vs call #2 (append-at-end). If nalar's streaming-response parsing makes the canned SSE response fiddly, skip it and say so in the PR body — the log-tail assertions in Tests 1-3 are the mandatory proof.
- [ ] `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/tool_discovery_test.py -v` (rebuild the binary first with `zig build install:linux` — `zig build nalar-desktop` does NOT produce `nalarcore-linux-x86_64`).
- [ ] `Commit:` `test(functional): progressive tool discovery wire + persistence`

### Task 10 — Rollout + measurement

- [ ] Re-run Task 1's measurement with the flag enabled and put a before/after table in the PR body: `tools[]` bytes, estimated tokens, per-call saving, and the `system_prompt` block delta.
- [ ] Flip the default to `true` **only when** all of: Task 1's number shows ≥60% reduction; Task 9 Tests 1-3 pass; a manual 20-minute dogfood session in this repo completes a normal coding task without the agent stalling on a missing tool. Otherwise leave it `false` and document what blocked the flip.
- [ ] Add one line to `NALAR.md` / the plan index describing the flag and where to turn it off.
- [ ] Optional (not required for this PR): Anthropic-native fast path — when `eff.url_style == "anthropic"` **and** the model is in the supported set, emit `tool_search_tool_regex_20251119` with `"defer_loading": true` on deferred definitions instead of the meta-tools. Gate strictly; never on by default.
- [ ] `Commit:` `docs: record progressive tool discovery rollout + measurements`

## Verification

- `zig build test --summary all` — green, including the new resolver, catalog, migration and static-contract tests.
- `pnpm test:unit` (from `src/apps/desktop`) — green, including `ToolDiscovery.spec.ts`.
- `bun run build` — clean (`vue-tsc` + vite); delete any `.js` files `vue-tsc --build` emits next to `.ts` sources before committing.
- `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/tool_discovery_test.py -v` — 4 passed.
- **No-regression gate:** with the flag false the resolved tool list is identical (names AND order) to `filterAndMergeTools`'s output — asserted by a unit test and by Task 9 Test 1.
- **Append-only gate:** for a session that loads a tool mid-run, `tools[0..core.len]` is byte-identical before and after, and the newly loaded schema is the last element.
- Numeric gate: `tools_bytes` with the flag enabled < 30,000 (vs the Task 1 baseline ≈83,000).
- Port 8081 was never touched; every functional run used the harness's random port.

## Out of Scope (explicit non-goals)

- Trimming verbose tool descriptions. `search` alone carries 4,930 B of prose, `search_history` 5,989 B — a real independent win, but it changes model-visible instructions and belongs in its own plan.
- Adding prompt caching (`cache_control`/`ephemeral`). The append-only invariant is written down so this lands cleanly later; it is not implemented here.
- Per-profile `tool_discovery_enabled` override (global-only in v1).
- A third discovery mode (an `aggressive` core of 4 tools). Design Decision 9 explains why v1 ships a bool; the enum is additive later if measurements justify it.
- Redefining `allowed_tools == ""` as "inherit" for sub-agents. Design Decision 6 carves out the discovery-on case only; a general fix needs its own migration story for existing rows.
- Semantic/embedding retrieval over tool descriptions. v1 is substring + category.
- Migrating the `UNIFIED_TOOL_REGISTRY` double-bookkeeping into the catalog (two registries is a wart; unrelated to this feature).
- Auto-unloading a tool that has not been used for N turns. Dropping a tool mid-session risks the history-union problem; v1 only caps.
- Frontend UI to inspect/clear a session's loaded tools.

## Risks

1. **The model never calls `list_tools`** → deferred tools become unreachable and the agent reports it cannot do something it could. Mitigations: core holds the 10 most-used built-ins plus both meta-tools; `ToolDiscoveryRule` explicitly tells the model that lazy tools mean "call `list_tools`"; the `load_tool` failure envelope names `list_tools`. Watch metric: count of `list_tools` calls and deferred `load_tool` calls per session in the dogfood run (Task 10).
2. **Hallucinated tool name.** `load_tool` must never register anything outside the eligible set. Enforced by validating against the eligible names before touching the DB, plus did-you-mean. Unit-tested.
3. **Resumed-session transcript rejection.** A `tool_use` in history whose definition is missing from `tools[]` is a provider error. The history union (`historyToolNames`) is the fix; test it with a fixture where a tool was used in turn 1 and the session resumes at turn 5 with an empty `session_tools`.
4. **Cache-hostile ordering.** Any future `cache_control` work assumes `tools[0..core.len]` is stable. The append-only rule plus its test is the guard; if a future change needs to reorder core, it must be treated as a breaking change.
5. **Extra round trips.** Every `load_tool` costs one iteration. Mitigated by a 12-tool core and by `list_tools` returning enough to load in one shot. If dogfooding shows >2 loads per task on average, widen the core rather than adding a "load many" tool.
6. **`filteringTools` aliasing.** It mutates in place (`prompts_build_messages_for_agent_prompt.zig:1203-1219`). If the resolver and the prompt builder end up sharing a buffer, the tail of `merged_tools` holds stale duplicates and `merged_tools.len` lies. The resolver dupes; the wiring task must not "optimize away" that dupe.
7. **MCP name collisions.** `filterAndMergeTools` currently appends MCP tools with no dedup (`:1782-1786`), so a server tool named `read_file` would ship twice and the model would see two identical names. The resolver dedups by name, first-wins (built-ins win). Note this is a behaviour *fix* that shows up in the off-mode comparison — if off-mode must stay byte-identical, do the dedup in the resolver only when `mode != .off`.
8. **Frontend degradation.** An unregistered tool name falls through to ChatView's generic `v-else` expandable (`:3379-3410`) — ugly but functional, so Tasks 5-7 are not blocked on Task 8.
9. **Allowlists interacting with discovery.** The agent allowlist path can emit `""` (zero tools) and the kanban path can emit a 1-tool list; combined with discovery the agent may get zero *core* tools. Test both `maybeOverrideAllowedToolsForAgent` and `maybeOverrideAllowedToolsForKanban` paths with the flag on and assert core is always present.
10. **Baseline number drift.** My 70 KB figure is a literal-text reconstruction, not a compiled dump. Task 1 replaces it; if the real number is far off, the expected-savings percentages in this plan must be recomputed before the rollout decision.

## Plan saved checklist

- [ ] Plan saved to `docs/superpowers/plans/2026-09-12-progressive-tool-discovery.md`
- [ ] Header includes Goal / Architecture / Tech Stack / Global Constraints
- [ ] Bite-sized steps with `- [ ]` checkboxes and per-task commits
- [ ] User reviewed before execution
