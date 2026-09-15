# Plan: replace `search_history` with workspace-scoped `read_workspace_session` (with FTS)

## Goal
One-sentence: DELETE the global `search_history` tool and replace it with a single workspace-scoped `read_workspace_session` tool that lists, reads, AND full-text-searches other chat sessions in the SAME workspace — so the agent can find and read other conversations without ever leaking across workspaces.

Non-goals (v1): no cross-workspace search, no write/edit of other sessions, no vector/semantic search, no realtime subscription, no per-session "private" flag, no permission UI beyond the existing agent-tools allowlist.

## Decision log
- 2026-09-15 (user): delete `search_history`, replace with `read_workspace_session`; the new tool must also search (FTS), not just read by id. Single tool, not two. This doc (v2) supersedes the earlier two-tool + keep-`search_history` draft.

## Background (what exists today)

### `search_history` — to be deleted
- Definition: `src/modules/agent/tools/search_history.zig:10` (`SearchHistoryInput`) + `:113` (`search_history_tool`). Modes `mode="text"` (FTS) / `mode="session"` (fetch by id).
- Engine: SQLite FTS5. Text path → `src/agentic_loop/llm_history.zig:2165` `searchMessagesFts` (`JOIN messages_fts ... WHERE messages_fts MATCH ?`, BM25, 10-token snippet). Index `src/migrations/migration.zig:1530` (`messages_fts`, triggers `llm_history_ai/ad/au`). Sanitizer `llm_history.zig:1974` `escapeFtsQuery` (phrase-quote tokens, join `OR`). Session path → `llm_history.zig:1741` `getCompactedMessages` (+ `:1887` `getMessagesByIds`).
- Why it goes away: **global scope** (no workspace filter — leaks across workspaces), **no discovery** (must already know `session_id`), FTS on `response_content` only, OR-only recall, dead `relative_window` params, no session metadata. Patching scope onto it keeps the confusing two-mode schema; a clean scoped replacement is smaller to learn and safer to gate.

### Session storage + workspace linkage (the hard part, unchanged)
- Messages = `llm_history` rows. `sessions(id, name, status, cwd, ...)` (`migration.zig` `017`), `sessions.workspace_id` added in `025` (`:429-435`) but **ALWAYS NULL in practice** — creators at `llm_history.zig:1227`, `:3190`, `workflow.zig:3024` never write it.
- Real linkage: `session_id = workspace_item_tasks.id → workspace_items.id → workspace_id` (kanban/routine chats); plain chats only via `sessions.cwd` prefix heuristic. Backfill + creator fix are still REQUIRED (see §Backend step 2).

### Deletion scope — ZERO mentions (all references mapped 2026-09-15)
Rule: after implementation, `rg 'search_history|SearchHistory|search-history'` over the repo must return NOTHING except this plan doc itself (the historical deletion record). Every row below is reworded, deleted, or renamed — no "see also the old tool" leftovers.

| Area | Files |
|---|---|
| Tool impl | `src/modules/agent/tools/search_history.zig` (DELETE file; includes `SearchHistoryInput` struct) |
| Exec wrapper | `src/agentic_loop/tools_exec_search_history.zig` (DELETE file; includes `execSearchHistory`) |
| Registry | `src/agentic_loop/tools_equipped.zig:17,88,194,299` (remove import + `equips()` + `UNIFIED_TOOL_REGISTRY` + `DEFAULT_AGENT_TOOLS`); `src/agentic_loop/tools.zig:21` (remove re-export); `src/root.zig:643` (remove re-export) |
| Prompt rule | `src/modules/agent/prompts.zig:37` (`SearchHistoryToolRule` re-export — DELETE), `src/modules/agent/prompts/prompts.zig:29` (re-export — DELETE), `src/modules/agent/prompts/core.zig` (`SearchHistoryToolRule` const — DELETE, add `ReadWorkspaceSessionToolRule`); `src/modules/agent/prompts_test.zig:1465` (reword comment) |
| Prompt/catalog | `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig:49` (remove import); `src/agentic_loop/progressive_catalog.zig:632,670,672,767` (remove entry + fix tests) |
| Test runners | `src/modules/agent/test_runner.zig:66`, `src/ai_workflow/tui/test_runner.zig:223` (remove imports) |
| Backend comments | `llm_history.zig` (`:1559,1572,1582,1594,1611,1635,1699,1741,1775,1887` + `:1758,8765,9115` plan-path refs), `migration.zig` (`:1476,1481,1507,1510,1999,2056,2060` — reword to "FTS5 table for workspace history" + drop plan-path refs), `migration_058_test.zig:2,33,36`, `migration_059_test.zig:10,20,61`, `migration_060_test.zig:12`, `migrations/test_runner.zig:25`, `Agent.zig:849`, `agent_memories.zig:240`, `workflow_compact_message.zig` (`:1054,1144,1195,1205,1233,3927,3943,4091,4173` — note `:1205` is a USER-VISIBLE envelope hint, must update or compacted sessions point the LLM at a dead tool), `memory.zig:80,346` — all reworded to `read_workspace_session` |
| Frontend code | DELETE `tool_outputs/SearchHistory.vue`; `ChatView.vue:73,3610-3611` (remove import + dispatch branch, add new-tool branch) |
| Frontend comments | `SaveMemory.vue:32`, `LoadMemory.vue:49,200,224,461` (reword analog/styling refs to the new card); `SaveMemory.spec.ts:19`, `LoadMemory.spec.ts:24,139`, `ChatView.tool-parameters.spec.ts:48` (reword or repoint) |
| Frontend specs | DELETE `__tests__/SearchHistory.spec.ts`, `__tests__/SearchHistory.emptyArgs.spec.ts`, `__tests__/SearchHistory.inprogress.spec.ts` (port cases into new-tool specs) |
| Functional tests | `agent_tools_toggle_test.py:172`, `agent_tools_defaults_test.py:37,67`, `agent_kanbans_test.py:81`, `command_tool_test.py:130,132,170` (remove `search_history`, add `read_workspace_session`) |
| Live docs | `docs/SPEC.md:135,140,793,1082` (reword history-table rows to the new tool name) |
| Obsolete archive docs | `docs/superpowers/plans/2026-08-04-search-history-v2.md`, `docs/superpowers/specs/2026-08-06-search-history-v2.md`, plus `search_history` mentions in `2026-08-06-save-load-memory-fts5-design.md`, `2026-08-06-save-load-memory-fts5.md`, `2026-09-11-agentic-loop-perf-memory.md`, `2026-08-06-enhance-save-load-memory-prompts.md`, `2026-09-08-tool-output-parameters-visible.md`, `2026-08-18-fix-load-memory-strict-search.md`, `2026-08-23-move-build-agent-prompt-body.md` — DELETE the two pure v2 docs (tool no longer exists, plans are obsolete), reword the passing mentions in the rest |
| Keep (not deleted) | FTS infra itself: `messages_fts` table/triggers/backfill, `searchMessagesFts`, `escapeFtsQuery`, `getCompactedMessages`, `getMessagesByIds` — the new tool reuses them with a workspace join/filter |

## Proposal: single tool `read_workspace_session`

One tool, three behaviors selected by which params are set (mirrors the "single round-trip" rationale from the old tool's own comment block):

| Params given | Behavior | Replaces |
|---|---|---|
| neither `query` nor `session_id` | **LIST** sessions in my workspace (name, status, message_count, last_activity, ~100-char preview of latest human msg; own session excluded) | old gap (no discovery) |
| `query` only | **SEARCH** workspace-scoped FTS over message content across my workspace's sessions (BM25 rank, snippet + session id/name per hit) | old `mode="text"` but scoped |
| `session_id` only | **READ** that session's messages (role/order/since/until filters, 16 KB per-msg cap) with same-workspace gate → `<denied>` on cross-workspace | old `mode="session"` but gated |
| BOTH `query` + `session_id` | **SEARCH-WITHIN**: FTS restricted to that one session (must still pass the workspace gate) | old `mode="text"` + `session_id` scope |

### Schema (draft)
- `session_id: string = ""` — target session for READ / SEARCH-WITHIN. Required for those behaviors; `""` → validation `<error>` BEFORE any DB bind (avoids the `""`-as-NULL trap from PR #291).
- `query: string = ""` — FTS query for SEARCH / SEARCH-WITHIN. Same `escapeFtsQuery` sanitizer (OR semantics kept in v1; AND/phrase knobs are future work). Empty-after-sanitize → 0 hits, not an error (same as today).
- `message_ids: string = ""` — CSV, max 50, full `<content>` for these ids (same guards as today; scoped to workspace sessions — unlike the old deliberately-unscoped lookup).
- `role, since, until, live_only/compacted_only, tool_name, parent_session_id, agent` — same exact-match/time/feed filters as today, forwarded into `SearchOptions`/`CompactedMessagesOptions`.
- `limit: u32 = 20` (clamp `1..200`; LIST clamps `1..50` to stay cheap), `offset: u32 = 0` (SEARCH pagination), `order: "asc"|"desc"` (READ pagination; SEARCH orders by BM25 rank, same asymmetry as today).
- NO `workspace_id` param — scope is derived server-side from the caller's session (see below). A client-supplied workspace id would be a spoofing vector.
- Fix carried over: implement the dead `since_relative/until_relative/relative_window` expansion OR drop the params (recommend drop — fewer dead knobs; relative time can return as a follow-up).

### Backend (Zig)
1. **Workspace resolver** (new, shared), e.g. `src/agentic_loop/workspace_scope.zig`: `resolveWorkspaceId(caller_session_id)` via (a) `workspace_item_tasks → workspace_items` exact join, (b) `sessions.cwd` longest-prefix fallback; NULL → fail-closed `<error>` (never fall back to global). `isSameWorkspace(caller, target)` for the READ/SEARCH-WITHIN gate → `<denied session_id="…">` (distinct from `<error>` so the LLM learns boundary vs bug). In-memory SQLite unit tests.
2. **Backfill migration + creator fix (REQUIRED)**: `UPDATE sessions SET workspace_id=(SELECT ... WHERE t.id=sessions.id) WHERE workspace_id IS NULL`; patch creators (`llm_history.zig:1227,:3190`, `workflow.zig:3024`) to write `workspace_id` at creation; migration test (seed NULL → backfilled; cwd-only stays NULL by design).
3. **New tool** `src/modules/agent/tools/read_workspace_session.zig`: `Input` + `AgentTool{name="read_workspace_session"}` + `execute_read_workspace_session` dispatching LIST/SEARCH/READ/SEARCH-WITHIN, returning `<read_workspace_session behavior="list|search|read">…</…>` XML (new envelope name — frontend parses the new tag; old `<search_history>` tag disappears with the tool). Reuse `searchMessagesFts` + `getCompactedMessages` + `getMessagesByIds` with an added workspace join/filter (`h.session_id IN (workspace session set)` for FTS; pre-gate for READ). In-file static-contract + validation tests.
4. **Swap registration**: DELETE the two `search_history` files; add exec wrapper `tools_exec_read_workspace_session.zig` (`parse → execute → wrapToolOutput`); update `tools.zig`, `tools_equipped.zig` (both registries + defaults — recommend default-ON, same risk class as before), `root.zig`, prompt import, `progressive_catalog.zig`, test runners. Reword backend doc comments; update the compaction-envelope hint at `workflow_compact_message.zig:1205`.
5. **Prompt**: 3–4 line usage note (LIST to discover → SEARCH to find → READ to deep-dive; scope is automatic).

### Frontend (Vue)
6. Replace card: DELETE `SearchHistory.vue`, add `ReadWorkspaceSession.vue` rendering all three behaviors (session rows for LIST with name/count/activity/preview; hit list with snippets for SEARCH; message list for READ; distinct denied-state UI). Parser: add `parseReadWorkspaceSession` (check `_shared/toolOutputParser.ts` — no `search_history` refs there today, parsing lives in the `.vue`:99-153 regexes — carry the pattern over, don't leave dead regexes). `ChatView.vue:3611` branch swapped to `msg.tool_name === 'read_workspace_session'`. Specs: port the three deleted spec files to the new envelope (list/search/read/denied/empty cases).

### Verification (no live-server curl — use harnesses)
- **Zig**: tool def-shape + validation + clamp + `""` reject tests; `workspace_scope` in-memory tests (task-linked resolves; unknown → NULL → fail-closed; cross-workspace `false`); FTS-scoping test (seed 2 workspaces, assert SEARCH from A never returns B rows).
- **Migration test**: NULL → backfilled; cwd-only stays NULL; new kanban-task session created non-NULL.
- **Frontend**: parser + card specs (list rows, search snippets, denied state, empty state).
- **Functional (wire round-trip — MANDATORY)**: `tests/functional/agent_workspace_history_test.py` via `harness.py` (fresh binary, tmpdir HOME, free port ≠ 8081 — NEVER 8081): workspace A (2 sessions, distinct messages) + workspace B (1 session); LIST from A excludes own + excludes B; SEARCH for a B-only term from A returns 0 hits (the leak test); READ of B session from A returns `<denied>`; `session_id:""` → clean `<error>`; update the four existing expected-tool-list tests. Catches route shadowing, NULL binding, empty-string validator traps — unit tests alone miss these.

## Risks / open questions
1. **Clean break (DECIDED 2026-09-15: no alias/shim).** Anything referencing the old name (custom prompts, skills, old compaction text in DB rows) gets tool-not-found; the new prompt steers the LLM. Old DB row content is inert data (see Acceptance). No `unknown tool search_history, use ...` shim — the name must not appear anywhere, including error strings.
2. **Cwd-heuristic false joins** (plain chats): longest-prefix-wins + fail-closed on ambiguity.
3. **Token blowup**: keep 20/200/16 KB/100-char guards; LIST clamped to 50.
4. **Single-tool schema complexity**: 4 behaviors in one schema risks LLM confusion. Mitigation: crisp description + behavior-selection truth table in the tool description itself (the old tool did exactly this and worked).
5. **Backfill scale**: single UPDATE, sessions table is small — fine, one txn, idempotent.

## Steps (execution order)
- [ ] 1. `workspace_scope.zig` resolver + in-memory tests
- [ ] 2. Backfill migration + 3 creator patches + migration test
- [ ] 3. `read_workspace_session.zig` (LIST/SEARCH/READ/SEARCH-WITHIN) + in-file tests (FTS workspace-scoping test included) + new `ReadWorkspaceSessionToolRule` prompt rule (replacing `SearchHistoryToolRule`)
- [ ] 4. DELETE `search_history.zig` + `tools_exec_search_history.zig`; add exec wrapper; swap all registrations/imports/catalog/test-runners/prompt-rule; scrub ALL backend comments + migration comments + compaction hint (see table)
- [ ] 5. Frontend: new card + parser + `ChatView` swap + ported specs; DELETE old card + old specs; scrub `SaveMemory`/`LoadMemory`/spec comments
- [ ] 6. Update 4 functional expected-tool-list tests + write `agent_workspace_history_test.py` (list/search/denied/`""` cases), port ≠ 8081; reword `docs/SPEC.md`; delete/reword obsolete archive docs
- [ ] 7. ZERO-MENTION GATE (acceptance, must pass before PR): run the three greps below — all must return empty (except this plan doc, the historical deletion record)
- [ ] 8. PR from the requested worktree (`we-need-a-tools-to-agent-see-other-chat-history-se-1789493337619`, Base: main) for human review

## Acceptance — zero-mention gate
```bash
timeout 30 rg -l 'search_history' src tests src/apps/desktop docs/SPEC.md 2>&1 | head -n 20   # expect: no output
timeout 30 rg -l 'SearchHistory' src tests src/apps/desktop docs/SPEC.md 2>&1 | head -n 20   # expect: no output
timeout 30 rg -l 'search-history' src tests src/apps/desktop docs/SPEC.md 2>&1 | head -n 20  # expect: no output
timeout 30 rg -l "search_history|SearchHistory|search-history" docs/superpowers 2>&1 | head -n 20  # expect: no output (archive scrubbed)
```
Known exception (not scrubbed): historical `llm_history` ROWS in existing user DBs may contain the literal string inside old message content or compaction envelopes — content data, not code; the tool name resolves via the registry, so old text is inert. No alias/shim for the old name (clean break per user decision).

## Files to touch (expected)
- NEW: `src/agentic_loop/workspace_scope.zig`, `src/modules/agent/tools/read_workspace_session.zig`, `src/agentic_loop/tools_exec_read_workspace_session.zig`, `src/apps/desktop/src/components/tool_outputs/ReadWorkspaceSession.vue`, `tests/functional/agent_workspace_history_test.py`
- DELETE: `src/modules/agent/tools/search_history.zig`, `src/agentic_loop/tools_exec_search_history.zig`, `src/apps/desktop/src/components/tool_outputs/SearchHistory.vue`, `__tests__/SearchHistory.spec.ts`, `__tests__/SearchHistory.emptyArgs.spec.ts`, `__tests__/SearchHistory.inprogress.spec.ts`
- EDIT: `src/migrations/migration.zig` (register backfill + scrub comments), `migration_058_test.zig`, `migration_059_test.zig`, `migration_060_test.zig`, `migrations/test_runner.zig`, `src/agentic_loop/llm_history.zig` (creators + comments), `src/agentic_loop/workflow.zig` (creator), `src/agentic_loop/workflow_compact_message.zig` (envelope hint + comments), `src/agentic_loop/tools.zig`, `src/agentic_loop/tools_equipped.zig`, `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig`, `src/agentic_loop/progressive_catalog.zig`, `src/agentic_loop/agent_memories.zig` (comment), `src/root.zig`, `src/modules/agent/test_runner.zig`, `src/ai_workflow/tui/test_runner.zig`, `src/modules/agent/Agent.zig` (comment), `src/modules/agent/tools/memory.zig` (comments), `src/modules/agent/prompts.zig`, `src/modules/agent/prompts/prompts.zig`, `src/modules/agent/prompts/core.zig` (rule swap), `src/modules/agent/prompts_test.zig` (comment), `src/apps/desktop/src/components/views/ChatView.vue`, `src/apps/desktop/src/components/tool_outputs/SaveMemory.vue`, `src/apps/desktop/src/components/tool_outputs/LoadMemory.vue`, `__tests__/SaveMemory.spec.ts`, `__tests__/LoadMemory.spec.ts`, `__tests__/ChatView.tool-parameters.spec.ts`, `docs/SPEC.md`, archive docs (delete 2 obsolete v2 docs, reword passing mentions in 7 others)
