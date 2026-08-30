### 2026-08-28: MCP stdio timeout + cancel-callback + self-healing respawn (fixes CI test_mcp_test_stdio_success)

**Root cause.** A hung/unresponsive MCP stdio server previously froze the agent workflow indefinitely. `client.recv()` / `client.send()` in `mcp_stdio.zig` were fully blocking with no timeout, no cancel-check, and no respawn-on-hang. The CI test `test_mcp_test_stdio_success_lists_hello_world_tools` (in `tests/functional/mcp_test_test.py`) was hitting this directly: the SDK's first byte read blocked, the recv hung, and the test's 10s deadline fired with `RecvTimeout` instead of returning the tools list.

**Fix layers** (all in `src/modules/agent/mcp/mcp/mcp_stdio.zig`):

1. **Deadline semantics.** `deadline_ns` is a RELATIVE duration in nanoseconds (0 = no timeout), not an absolute timestamp — computed `deadline_abs = now + deadline_ns` on entry so the per-byte deadline check is a single `i128` comparison. The v1 mistake was treating `deadline_ns` as an absolute timestamp (callers passed `30 * std.time.ns_per_s` = 30 seconds since epoch = always in the past).

2. **`readFramed` / `writeFramed`** poll the deadline + optional `?*const fn () bool` cancel-callback between every `readSliceShort` / `writeStreamingAll` call. Cancel fires within one syscall; the deadline fires as soon as the deadline check runs after a byte read.

3. **`StdioClient.send` / `recv`** accept `deadline_ns: u64` + `is_cancelled: ?*const fn () bool`. New `sendNoTimeout` / `recvNoTimeout` overloads preserve the old API for the in-repo tests + any external callers.

4. **`StdioError.RecvTimeout` / `SendTimeout`** new variants. Both production callers (`buildMCPToolsRun`, `callViaStdio`) catch them, log a clear message, and continue.

5. **`StdioRegistry.markStale(name)`** flips a per-slot `dirty: std.atomic.Value(bool)` flag. `getOrSpawn` checks the flag on entry: if dirty, kills the cached child + spawns fresh. Self-healing: a hung call doesn't brick subsequent calls.

6. **`Entry`** in `StdioRegistry` grew the `dirty` field; `entries` map value type changed from `*StdioClient` to `*Entry` (3 in-repo call sites updated). Existing `dropAndRespawn` unchanged.

**Wiring through to the workflow.** `buildMCPToolsRun` (workflow entry, called ONCE before the loop): 30s deadline + workflow's `isWorkerCancelled`-derived cancel-callback. `workflow.zig:564` builds a `mcp_cancel_thunk` closure (`*const fn () bool`) backed by a thread-local `McpCancelCtx { db, session_id }`. The state box is allocated on the workflow's parent arena (lifetime = the whole run) so the cancel-callback survives across the workflow's many recvs.

**Files.** 4 EDIT (`mcp_stdio.zig`, `prompts_build_messages_for_agent_prompt.zig`, `handle_mcp_tool.zig`, `workflow.zig`) + 2 NEW (`tests/functional/mcp_stdio_hang_test.py`, `tests/functional/fixtures/hung-server.sh`) + 1 NALAR.md changelog entry. No migration, no schema change, no frontend change. Hardcoded default timeouts in v1 (`30s tools/list`, `60s tools/call`); a v2 follow-up will add `LlmConfig.mcp_tools_timeout_ms` / `mcp_call_timeout_ms` with frontend wiring.

**Also ports the mcp-test-button PR** (commit 2a3528c4) into this branch: `src/ai_workflow/tui/http_handlers/mcp_test.zig` (the `POST /api/mcp/test` probe) + `mod.zig` re-export + `main.zig` route registration + frontend modal/component updates. The mcp-test-button code was adapted to use the new `recv(deadline_ns, null)` signature with a 10s per-call deadline, and `markStale` is called on timeout so the next probe gets a fresh child.

**Tests.** `zig build test --summary all`: 2859/2865 pass + 6 baseline-skip (was 2829/2865 before — 4 new tests added to `mcp_stdio.zig` inline tests). `zig build nalar-desktop --summary all`: 22/22 steps OK. `pytest tests/functional/`: includes 2 new tests in `mcp_stdio_hang_test.py` (hung-child wire-level behavior, hung-child can be replaced by fresh process). End-to-end manual smoke test against `mcp-hello-world`: `POST /api/mcp/test` returns `{"ok": true, "transport": "stdio", "tools": [...]}` in <100ms (was previously failing with `RecvTimeout` due to the deadline semantic bug).

**Plan:** docs/superpowers/plans/2026-08-28-fix-mcp-stdio-blocking.md
**Branch:** worktree/fix-mcp-stdio-blocking
**Task:** task_1787930150605_0
### 2026-08-29: Chat sidebar `last_human_touched_at` — human-time pill + amber stale dot

**What landed.** The sidebar's per-chat time pill (e.g. "2h", "now") used to source from `sessions.updated_at` — a column bumped by *everything* (the agent's per-loop `update_worker` tick, profile change, error emit, etc). When a long-running agent kept the chat alive, the sidebar showed "now" / "0s" even if the user had walked away 2 hours ago. Now the sidebar's time pill is sourced from `formatRelativeTime(last_human_touched_at ?? updated_at)`, a sibling of the existing `workspace_item_tasks.last_human_touched_at_nano` (kanban). A new **amber `chat-stale-dot`** appears when `updated_at > last_human_touched_at` (i.e. the AI has touched the chat since the user's last touch) so users see at a glance "AI is ahead of you". Hover tooltips distinguish the two timestamp sources. Mirrors the kanban ⚠ indicator (which uses orange) but at amber-400 so the sidebar doesn't visually shout.

**Wire shape.** `SessionInfo.last_human_touched_at: []const u8` (Migration 075 convention: SQL column is `_nano` suffix, JSON wire field is bare). `buildSessionListJson` includes it on every list response. SELECT-layer converts unix-ms → SQLite datetime UTC (`'YYYY-MM-DD HH:MM:SS'`) via `strftime()` so the wire shape matches `updated_at` (the frontend `formatRelativeTime` helper only parses the datetime shape). Legacy NULL rows render as `''` (empty string, not null) so the `?? updated_at` fallback is a defined check. No new SSE event — the new column rides on the existing `session.updated` event.

**Stamp sites (3):** the single funnel `root.zig::emit_run_agent` (covers ChatView send, kanban "create & run", kanban "Start agent", `+ Chat` — every "user sends a message" path delegates here); `session_update.zig::useCase` (any real field edit, no-op bodies don't stamp); `workflow.zig::saveRetryAttemptMessage` (any retry/bail, so the sidebar surfaces "agent errored" via the human-time bump — the in-chat ⚠ `AgentErrorCard` already covers the in-chat rendering).

**Files.** 16 (8 NEW + 8 EDIT). Backend: Migration 082 + 5 tests (`migration_082_test.zig`); `llm_history.updateSessionLastHumanTouchedAt` helper + 6 tests + `SessionInfo.last_human_touched_at` field + 2 SELECT-layer tests + `buildSessionListJson` mapper test; `root.zig::emit_run_agent` stamp; `session_update.zig::useCase` stamp + 1 static-contract test; `workflow.zig::saveRetryAttemptMessage` stamp; `session_create.zig` static-contract test (NO redundant session-side stamp in create handler — the funnel handles it); new `test_runner.zig` registrations. Frontend: `api.getChats` mapper + 4 tests in `apiGetChats.spec.ts`; `Chat` interface gets `updated_at?: string` (pre-existing latent type bug — was accessed at runtime but never declared); `ChatsList.vue` swaps time source + adds stale dot + hover tooltips + 6 tests in `ChatsList.lastHumanTouched.spec.ts`; `relativeTime.ts` now accepts BOTH SQLite datetime UTC strings (REST GET wire shape) AND unix-ms integer strings (SSE event emit shape — `on_event_sent.zig` bypasses the SELECT conversion). Functional: 5 end-to-end tests in `session_human_touched_at_test.py`. Docs: 1 plan + 1 spec.

**Tests.** `zig build test --summary all`: 2916/2922 pass (6 skip, 0 fail, 0 leak) — was 2855/2861 baseline (+61 net: 5 migration + 6 helper + 2 SELECT-layer + 1 buildSessionListJson + 1 session_update static-contract + 2 emit_run_agent static-contract + 1 session_create static-contract + 1 saveRetryAttemptMessage + …). `pnpm test:unit`: 2802/2802 pass across 299 files — was 2737 baseline (+65 net: 4 apiGetChats + 6 ChatsList relativeTime + frontend spec fix). `zig build nalar-desktop --summary all`: 21/21 steps succeed. `pytest tests/functional/session_human_touched_at_test.py -v`: 5/5 pass (PUT stamps column, GET returns SQLite datetime, legacy NULL returns `''`, list endpoint surfaces the field, subsequent PUTs overwrite).

**Plan:** docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
**Branch:** worktree/chat-sidebar-last-human-touched
**Task:** task_1788004921757_1

### 2026-08-28: `add_mcp_server` agent tool — runtime MCP registration (stdio in v1)

**What landed.** nalar's agent can now **add new MCP servers at runtime** via the new `add_mcp_server` agent tool (LLM-callable, mirrors the frontend `McpServerModal` wire shape). The LLM passes `{name, transport, command, args?, cwd?}` and the tool validates the input, mutates the live `LlmConfig.mcp_servers` typed map + `mcpServers_parsed` JSON mirror (so `buildMCPToolsRun` picks up the new server's tools on the NEXT iteration's system prompt), then persists to `~/.config/nalar/config.json` and atomically swaps `di.llm_config` via `setLlmConfig` — the same write+reload sequence `PUT /api/config/nalar` already uses, just triggered by the agent instead of the settings UI. v1 covers the **stdio** transport only (per the user's "handle mcp stdio first" scope); HTTP lands in a sibling task (`task_1787928601804_8`) without changing the wire shape — the input struct already has `url` + `headers` fields reserved, gated to a clear "transport must be stdio in v1" error today. On success the tool returns the just-added server's tools via a best-effort `tools/list` JSON-RPC roundtrip (production-only — test path skips it to avoid polluting the global `StdioRegistry`); failures there DON'T fail the call (the server IS registered; the next iteration's prompt reflects the new tools regardless).

**Wire shape.** `<add_mcp_server>...<persisted>true|false</persisted><tools>...</tools></add_mcp_server>` — `<persisted>` reports the disk-write outcome (separate from the in-memory mutation, which already succeeded); `<tools>` is a newline-separated list of `mcp_<server>_<tool>` names the server exposed. Errors return `<add_mcp_server><error>...</error></add_mcp_server>` for: empty name (InvalidName), empty command (InvalidCommand), duplicate name (DuplicateServer — message includes the conflicting key), or non-stdio transport (HTTP deferred to sibling task). All string fields are deep-copied; mutating the input slices after the call leaves the typed map's values untouched (regression test guards against shallow-copy).

**Files.** 5 NEW + 4 EDIT (1 storage primitive in Config.zig, 1 tool module, 1 exec wrapper, 1 functional test, `root.zig` module export, `tools.zig` re-export, `tools_equipped.zig` registry entry, two test_runner.zig registrations).

**Tests.** `zig build test --summary all`: 2875/2881 pass (6 skipped, 0 fail) — up from 2863/2869 baseline (+12 net new tests across 3 layers: 7 storage-primitive + 9 tool-module + 3 exec-wrapper; 0 leaks, 0 crashes). `pytest tests/functional/agent_add_mcp_server_test.py -v`: 1 new functional test passes (persistence + live-reload via the same write path the tool uses). `pytest tests/functional/mcp_stdio_test.py -v`: 6 existing pass, no regressions. `zig build nalar-desktop --summary all`: 22/22 steps succeed.

**Plan:** docs/superpowers/plans/2026-08-28-add-mcp-server-agent-tool.md
**Branch:** worktree/add-mcp-agent-tool
**Task:** task_1787929165057_9
### 2026-08-29: Per-session LLM loading slider

**What landed.** Each LLM session now surfaces its "still working" state as a thin yellow sliding bar at the **bottom edge of its sidebar chat row** — replacing the 9-line yellow spinner circle that used to float next to each chat name when that session's worker was running. New `SessionSlider.vue` component (one prop: `sessionId: string`; reads the existing `processingState` map via Vue inject from `App.vue:10-11`; hidden iff `!processingState[sessionId]`). CSS-only animation (`@keyframes session-slider-slide`, 1.4 s loop), respects `prefers-reduced-motion`. **Sessions are independent**: three concurrent running chats show three separate sliders in three separate rows — the sidebar is the glance view for "which sessions are alive". NOT mounted in `ChatView` or `SubAgentPeekPanel` — the sidebar row IS the one indicator for "this session is busy"; adding a duplicate slider in another surface would double-deal the same signal (design memory `design-no-redundant-loading-indicators`).

**Files.** 4 files: 2 NEW (`SessionSlider.vue`, `SessionSlider.spec.ts`), 1 EDIT (`ChatsList.vue` — replaced the per-row spinner block at lines 467-475 with a single `<SessionSlider>` and added `relative overflow-hidden` to the chat-row button so the absolutely-positioned slider stays inside the rounded row boundaries), 1 doc (`docs/SPEC.md` §10.1 entry). No backend, no migration, no Zig changes, no new dependencies.

**Plan:** docs/superpowers/plans/2026-08-29-bottom-loading-slider.md
**Branch:** worktree/bottom-loading-slider
**Task:** task_1787973036360_2
### 2026-08-28: MCP Streamable HTTP transport for the agent AI

**What landed.** nalar's agent can now talk to MCP servers that expose a single HTTP endpoint accepting POST ([MCP Streamable HTTP spec](https://modelcontextprotocol.io/specification/draft/basic/transports/streamable-http)). The server is free to answer each request as either a single `application/json` object or a `text/event-stream` (SSE) stream carrying progress notifications + the final JSON-RPC response — the client handles both. Required request metadata headers (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`) are emitted on every POST. stdio is untouched (backward compat). For self-testing we ship a separate **`mcp-http-hello-world`** Node binary (sibling of the existing stdio `mcp-hello-world`) per the user's "one binary per transport" preference — no `--http` flag dispatch, single-purpose, easier to reason about. Built via `zig build mcp-http-hello-world` → `zig-out/bin/mcp-http-hello-world`. Functional harness runs it as a subprocess, points `mcp_servers.url` at it, asserts the spec-compliant wire.

**Wire shape.** Each MCP HTTP server maps to one cached `HttpClient` (URL + custom headers + connection pool), stored in a process-global `HttpRegistry` keyed by server name (same shape as `mcp_stdio.StdioRegistry`). All HTTP-specific code lives in **one zig file** (`src/modules/agent/mcp/mcp/mcp_http.zig`, ~750 lines with inline tests): the SSE event parser (`readSseEvent` — multi-`data:` join with `\n`, case-insensitive field names, comment-line skipping, per-spec value-strip-one-leading-space), the spec-compliant header builder (`buildMcpHeaders` — 4 always-emitted spec headers FIRST in the slice so libcurl's first-match-wins uses the spec value over a user's accidental custom override), the `HttpClient` (one POST, JSON-or-SSE response dispatch), the `HttpRegistry` (process-global, thread-safe, lazy init, arena-backed), and the `listTools` helper for the session-start tool enumeration. `handle_mcp_tool.zig` and `prompts_build_messages_for_agent_prompt.zig` lose ~140 lines of inline HTTP plumbing each and delegate to `mcp_http.HttpRegistry.getOrConnect + HttpClient.callTool/listTools`.

**Spec revision target.** `2025-11-25` — the latest revision `@modelcontextprotocol/sdk` v1.30.0 actually implements. The spec page's "current" `2026-07-28` revision is not yet implemented by any SDK or client in the ecosystem; targeting it would mean our HTTP client can't talk to ANY real server today. When an SDK ships `2026-07-28`, the bump is a 1-line constant change.

**Wire details discovered during TDD.** The SDK takes the spec's "MAY" (lenient) path for missing `MCP-Protocol-Version` headers — treats them as `2025-03-26`. We document this in `test_http_mcp_missing_protocol_version_is_lenient` so future client code knows the server is lenient BUT the client should still always send the header (spec-required for revisions ≥ 2025-06-18). The SDK always streams via SSE for our request shapes (not `application/json`); both shapes are supported by the client.

**Files.** 15 (1 NEW backend module, 5 NEW test fixture, 1 NEW functional test, 1 NEW plan, 5 EDIT backend/build/test, 1 changelog entry). No new migration, no new config schema column, no new PUT endpoint.

**Tests.** `zig build test --summary all` adds 18 new tests in `mcp_http.zig` (8 SSE parser + 4 header builder + 2 HttpClient + 3 HttpRegistry + 1 listTools) — 2873/2879 pass (6 skipped, 0 fail, 0 leak; was 2855/2861 baseline). `zig build nalar-desktop --summary all`: full desktop build succeeds. `zig build mcp-http-hello-world --summary all`: 7/7 build steps. `npm test` in `src/apps/mcp_http_hello_world`: 1/1 vitest pass. `pytest tests/functional/mcp_http_test.py -v`: 5/5 functional tests pass (direct wire roundtrip + lenient-missing-version + bogus-version-400 + nalar-config-roundtrip + nalar-http-client-against-real-server).

**Plan:** docs/superpowers/plans/2026-08-28-mcp-streamable-http.md
**Branch:** worktree/mcp-streamable-http
**Task:** task_1787928601804_8

### 2026-08-27: MCP stdio transport for the agent AI

**What landed.** nalar's agent can now talk to MCP servers that expose themselves as a child-process command (stdio transport, per the [MCP stdio spec](https://modelcontextprotocol.io/specification/draft/basic/transports/stdio)) in addition to the existing HTTP transport. The two transports are auto-detected per server entry: presence of `command` ⇒ stdio, presence of `url` ⇒ http. Config schema accepts both shapes; HTTP entries are unchanged for backward compat. We ship a tiny `zig-out/bin/mcp-hello-world` test server that registers 3 tools (`print_hello`, `print_name`, `print_exit`) using the canonical `@modelcontextprotocol/sdk` TypeScript — useful as a self-test target and a working reference implementation. Frontend settings dialog gains a transport toggle: `[HTTP]` keeps the URL+headers form, `[stdio]` reveals a fresh command/args/env/cwd form.

**Wire shape.** Each stdio server spawns one child process on first use (lazy), reuses it across all `tools/list` and `tools/call` requests, and respawns on exit. All stdio code lives in **one zig file** (`src/modules/agent/mcp/mcp/mcp_stdio.zig`) with inline tests — Content-Length framing + `StdioClient` (spawn child, framed read/write) + `StdioRegistry` (process-global, keyed by server name, lazy spawn, clean shutdown). The framing layer auto-detects newline-delimited JSON (the canonical SDK default — `JSON.stringify(msg) + '\n'`) AND Content-Length (the MCP spec default) by peeking the first byte of each response — real-world MCP servers split across both styles today. MCP server config continues to live in `config.json` under the existing `mcp_servers` key — stdio entries just use `{"command": "...", "args": [...]}` instead of `{"url": "...", "headers": {...}}`.

**Files.** 8 NEW + EDIT (1 zig file for stdio client, 1 TS file for hello-world server, 1 zig edit for config schema, 1 zig edit for dispatch, 1 zig edit for `readFramed` NDJSON detection, 1 zig edit for `StdioRegistry.global()` to own its `std.Io.Threaded`, 1 frontend `McpServer` type + modal + section edit, 1 `McpServerModal.stdio.spec.ts`, 1 `tests/functional/mcp_stdio_test.py`, `harness.mcp_hello_world_bin()` helper, build.zig chain for `zig build mcp-hello-world`). No migration, no DB changes, no breaking changes to existing HTTP MCP servers, no new config file.

**Tests.** `zig build test --summary all` adds 3 new NDJSON framing tests (with-trailing-\n, no-trailing-\n EOF, CRLF terminator) — 2832/2838 pass (was 2829). `npm run test:unit` adds 6 modal tests — 2718/2718 pass. `pytest tests/functional/mcp_stdio_test.py -v` adds 6 functional tests (3 direct stdio roundtrip + 3 nalar config round-trip, including multi-server + http/stdio mix) — 244/244 functional tests pass with no regressions.

**Plan:** docs/superpowers/plans/2026-08-27-mcp-stdio.md
**Branch:** worktree/mcp-stdio
**Task:** task_1787843426969_1

### 2026-08-27: Kanban agent config — modal dialog → settings page (4 tabs)

**What landed.** The per-board agent config (Knowledge / System Prompt / Tools) used to live in a centered modal `KanbanAgentSettings` (538 lines) that opened when the user clicked 🤖 Agent on a kanban header. Now it lives as **two separate top-level tabs** inside the existing dedicated Kanban Settings page: **🛠 Tools** (the agent_kanban_tools allowlist) and **🧠 Knowledge** (Knowledge rows + System Prompt blocks — merged since both are persona content injected into the agent's system prompt). The tab strip is now 4 tabs: Columns / Local Memories / Tools / Knowledge. The 🤖 Agent toolbar button navigates to `/app/kanban/:itemId/settings?tab=tools` (the more security-critical config) instead of opening a modal — reload-safe, deep-linkable, Back returns to the kanban board naturally. The active tab is URL-backed via a writable `settingsMode` computed that reads `route.query.tab` and writes via `router.replace`; default `'columns'` strips the query so the URL stays clean; unknown tab values fall back to `'columns'`. The tab strip is always visible (no `item.path` gate on the whole strip) — the Local Memories button is individually gated on `item.path`; the Tools + Knowledge buttons are always visible.

**Files.** 9 + iteration-2 split (3 NEW + 2 RENAME + 2 EDIT + 2 docs): NEW `KanbanToolsPanel.vue`, `KanbanToolsPanel.spec.ts`, `KanbanKnowledgePanel.spec.ts`; RENAME `KanbanAgentPanel.vue` → `KanbanKnowledgePanel.vue`, `KanbanAgentPanel.spec.ts` → `KanbanKnowledgePanel.spec.ts`; EDIT `KanbanSettingsView.vue` (4-tab strip + 2 new body branches), `KanbanSettingsView.spec.ts` (URL contract for tools + knowledge), `KanbanView.vue` (Agent button → `?tab=tools`), `KanbanView.spec.ts`, `AppLayout.vue` (stripped `KanbanAgentSettings` mount + handlers). DELETE: `KanbanAgentSettings.vue` (538 lines), `KanbanAgentPanel.spec.ts` (replaced by `KanbanKnowledgePanel.spec.ts`). Zero backend changes — all 14 `/api/agent-kanbans/...` endpoints (Migration 081) are reused unchanged.

**Verification.** `zig build test --summary all`: 2803 pass / 6 skip / 0 fail. `npm run test:unit` (vitest): **2737/2737** pass across 290 files (+6 net from iteration 2: +6 new KanbanToolsPanel tests + 9 new KanbanKnowledgePanel tests + 3 new KanbanSettingsView tests − 12 deleted old KanbanAgentPanel tests + 0 KanbanView changes). `npx vue-tsc --noEmit -p tsconfig.app.json`: clean. No functional wire changes (Migration 081 endpoints + payloads untouched); `tests/functional/agent_kanbans_test.py` wire contract unchanged.

**Plan:** docs/superpowers/plans/2026-08-27-kanban-agent-as-tab.md
**Branch:** worktree/kanban-agent-as-tab
**Task:** task_1787843016481_0

### 2026-09-02: Kanban settings: centered modal → dedicated page

**What landed.** Clicking ⚙ on a kanban board header used to open `KanbanSettingsDialog` as a centered modal. Now navigates to the vue-router path route `/app/kanban/:itemId/settings` and renders the new `KanbanSettingsView` (full-page layout mirroring `SettingsView`'s 240px sidebar + content panel shape). The URL is the source of truth — reload preserves the page, **← Back** returns to the kanban board. `<KanbanSettingsDialog>` + its spec are deleted. `useCurrentMainView` gains a `{ kind: 'kanban-settings', workspaceId, itemId }` variant that parses `route.path` + `route.params`. AppLayout's `currentView` computed recognizes the new path via regex (before the route.query.view fallthrough). Sidebar's `WorkspaceItem.isCurrentMainView` now also matches `kind === 'kanban-settings'` so the parent kanban row stays highlighted while the user is on its settings page.

**Files.** 11 files: 2 NEW (`KanbanSettingsView.vue`, `KanbanSettingsView.spec.ts`), 5 EDIT (`useCurrentMainView.ts`, `useCurrentMainView.spec.ts`, `router/index.ts`, `AppLayout.vue`, `WorkspaceItem.vue`), 2 DELETE (`KanbanSettingsDialog.vue`, `KanbanSettingsDialog.spec.ts`), 2 docs. No backend changes, no migration.

**Plan:** docs/superpowers/plans/2026-09-02-kanban-settings-as-page.md
**Branch:** worktree/kanban-settings-page
**Task:** task_1787662453096_0

### 2026-08-19: Agent tools `update_plan` + `get_plan` — session-scoped markdown plan with checklist

**What landed.** Two new agent-callable tools (`update_plan` overwrites the plan; `get_plan` fetches it) backed by a new `session_plan` SQLite table (1:1 with `sessions`, `session_id TEXT PRIMARY KEY`, `plan_md TEXT NOT NULL DEFAULT ''`, `updated_at DATETIME DEFAULT CURRENT_TIMESTAMP`). Migration 076 (`create_session_plan`) creates the table on a fresh DB. The plan is plain markdown with a `- [ ]` / `- [x]` checklist; the agent overwrites on every call (UPSERT, 256 KiB hard cap). Plan is re-injected into every agent iteration via the system prompt (new `prompts_make_plan_context.zig` adds a `## Current Plan` section under the existing `agent_memories` block) AND embedded as a `<plan>` section in the compaction envelope (via `enrichCompactionXml`) so the next agent after compaction knows what the prior agent was doing. CDATA-escaping splits `]]>` sequences the same way `enrichCompactionXml`'s `session_skills` block does. No FK constraint to `sessions.id` (matches the `session_activity` / `llm_history` precedent). `session_id` is implicit (pulled from `ToolExecContext`); the LLM never passes it. `update_plan` returns `<update_plan><session_id>...</session_id><updated_at>...</updated_at></update_plan>`; `get_plan` returns `<get_plan><plan><![CDATA[...markdown...]]></plan></get_plan>` or `<get_plan><empty/></get_plan>` when no plan row exists. Optional UI: `UpdatePlan.vue` + `GetPlan.vue` Vue components render the tool result as a collapsible checklist card in the chatview. Both files in `src/apps/desktop/src/components/tool_outputs/`; wired into `ChatView.vue`'s per-tool dispatcher alongside `LoadMemory` / `SaveMemory`. The chip on the chat bubble shows a checkbox-count summary (`3/5 done`); clicking expands the full checklist.

**Wire (backend).** Two new LLM tools registered in `UNIFIED_TOOL_REGISTRY`: `update_plan` (input: `content: string` — the markdown body; rejects empty string with `<error>`) and `get_plan` (no input). Both delegate to the pure-fn helpers in `src/ai_workflow/tui/agentic_loop/session_plan.zig` (`savePlan` / `getPlan` / `getPlanOpt`). The exec adapter at `src/ai_workflow/tui/agentic_loop/tools_exec_update_plan.zig` pulls `ctx.session_id` from `ToolExecContext` and threads it into the helper. New system-prompt context builder `src/ai_workflow/tui/agentic_loop/prompts_make_plan_context.zig` reads the plan via `getPlanOpt` and emits the `## Current Plan` block when present (omitted entirely when no plan row exists — same convention as the existing `agent_memories` block). New `fetchSessionPlan` helper in `workflow_compact_message.zig` + a new `plan: ?PlanRow` parameter on `enrichCompactionXml`; the caller in `workflow_commpact_message.zig` fetches the plan BEFORE `mark_history_not_for_llmrun` so the enriched INSERT carries the plan forward.

**Files.** 13 (5 NEW, 8 EDIT). Backend + frontend + migration. No schema changes beyond the new table.

**Plan:** docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
**Branch:** worktree/agent-plan-tool
**Task:** task_1787066122956_5

### 2026-08-13: kanban task name = session name

**What landed.** Kanban task `name` and the linked session `name` now bind to the same trimmed title at create time. The sidebar (ChatsList), chat header (`ChatView.chatName`), and kanban card (`task.name`) all show the same string the user typed at create time — no manual rename, no LLM auto-rename required.

**Files.** 6 (1 NEW, 5 EDIT). Backend-only — no migration, no schema change, no frontend change.

**Plan:** docs/superpowers/plans/2026-08-13-kanban-task-session-name-match.md
**Branch:** worktree/kanban-task-session-name-match
**Task:** task_1786626864861

### 2026-08-18: kanban task detail — Start agent button

**What landed.** New `▶ Start agent` button in the kanban task-detail dialog (edit mode only). Mirrors the create-mode `▶ Create task & run agent` button. Clicking kicks off an LLM worker on the task's existing session WITHOUT queueing a new user message; the agent runs on whatever chat history is already in the session. The button is `:disabled` while `processingState[task.id]` is true (via the existing App.vue map), so it's safe to spam and discoverable as "greyed out = a worker is already running". On success the dialog closes and the user stays on the kanban; on failure the dialog stays open with an errorMessage banner.

**Wire (backend).** New dedicated endpoint `POST /api/workspaces/:ws/items/:i/tasks/:task_id/start_agent` — NOT a wrapper around `/api/llm/session` (which always queues a message). Validates task exists (404), no worker running (409), then calls `di.emit_run_agent` with a new `skip_initial_queue_message: true` flag that threads through `EmitRunAgentInput` → `RunParamsNew` → `runAgenticMultiStepnew`. The workflow's `insertQueueMessage` call is wrapped in `if (!params.skip_initial_queue_message)`, so the agent loop runs on the existing chat history alone.

**Files.** 14 (5 NEW, 9 EDIT). Backend + frontend, no migration, no schema change.

**Plan:** docs/superpowers/plans/2026-08-18-kanban-task-detail-start-agent.md
**Spec:** docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent-design.md
**Branch:** worktree/kanban-task-detail-start-agent
**Task:** task_1787036138314_0

### 2026-08-19: Kanban "Create task" now inits session, no agent run

**What landed.** The plain `Create task` button in the kanban New Task dialog now also inserts a `sessions` row + emits the `session_created` SSE (new mode `'create_session'` on the existing `POST /api/workspaces/:wid/items/:iid/kanban/tasks` endpoint) but does NOT call `emit_run_agent`. The user can click the card to open the chatview on a pre-existing empty session with no lazy-creation race when they type their first message. The chatview's profile picker + unattended toggle now reflect the dialog's choice immediately (selected_profile_model is persisted on the new sessions row). Two-button story: `Create task` = prep everything, you open the chat yourself; `Create task & run agent` = prep everything + kick off the agent with the title + description as the first message. Backward compat: legacy `mode='create'` on the API surface keeps the old behaviour (no session insert) for any external consumer.

**Wire (backend).** New mode value `'create_session'` on the existing `POST /api/workspaces/:wid/items/:iid/kanban/tasks` endpoint. Shares the sessions-INSERT + session_created-SSE plumbing with `create_and_run`, but the `emit_run_agent` call is narrowed behind a fresh `if (is_create_and_run)` guard so the worker never fires for the new mode. Response wire: `status: 'idle'` (vs `'send'` for create_and_run) so the frontend can distinguish at a glance. 5 new static-contract tests in `kanban_tasks_create_test.zig` lock in the wire contract.

**Files.** 8 (2 NEW, 6 EDIT). Backend + frontend, no migration, no schema change.

**Plan:** docs/superpowers/plans/2026-08-19-kanban-create-task-inits-session.md
**Branch:** worktree/kanban-create-task-inits-session
**Task:** task_1787066122956_5