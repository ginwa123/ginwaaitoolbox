# Nalar — Project Specification

> **Compiled**: 2026-08-06 (re-consolidated from the 17 plans + 1 SSE plan that accumulated since the 2026-07-26 cut)
> **Source**: Originally compiled from 178 plan files in `docs/superpowers/plans/` + `docs/plans/` on 2026-07-26; the second consolidation on 2026-08-06 adds all plans from `docs/superpowers/plans/2026-07-28-*` through `docs/superpowers/plans/2026-08-06-*` plus `docs/sse-reconnect-plan.md`. The plan folders were deleted on 2026-07-26 and again on 2026-08-06 after each consolidation; see `§10.2` for the historical inventory.
> **Purpose**: Single source of truth for what the project is, what it has, and what is still pending.

---

## 1. Project Overview

**Nalar** is an AI agent workspace tool built around three pillars:

1. **Backend** — A Zig 0.16 agent runtime that orchestrates LLM calls, runs tools in a managed file-descriptor and process environment, and persists state to SQLite.
2. **Frontend** — A Vue 3 + TypeScript + Pinia single-page app that presents the workspace to the user (chat, kanban, design canvas, file tree, settings).
3. **Desktop Shell** — A native webview wrapper (`nalar-desktop`) that embeds the webapp and runs the backend in a managed service.

### 1.1 Tech Stack (Current)

| Layer | Technology | Notes |
|---|---|---|
| Backend language | **Zig 0.16** | Vendored sqlite3 amalgamation; vendored libcurl on non-Linux; `linkSystemLibrary` on Linux |
| Backend HTTP | **Custom HTTP server** | `src/modules/custom_http_server/` — per-request arena allocator, `Io.Threaded` runtime |
| HTTP client | **Custom libcurl wrapper** | `src/modules/custom_http_client/` — replaces `std.http`; cross-platform |
| Database | **SQLite** (via `nalarcore.sqlite`) | Migrated from scratch (54 migrations); transaction support added |
| LLM providers | Anthropic, OpenAI-style, custom base URLs | `LlmConfig` with per-profile `base_url`/`model`/`api_key` |
| Frontend | **Vue 3 + TypeScript + Pinia** | Composition API, `<script setup lang="ts" generic>`, Vitest |
| Frontend build | **Vite + Bun** | `bunx vitest run` + `bun run build` (vue-tsc + vite) |
| Desktop wrapper | **Native webview** | WebKitGTK 4.1 (Linux) / WKWebView (macOS) / WebView2 (Windows) — three C/C++/ObjC++ shims under `src/apps/desktop_app/platform/` |
| SSE | **`/api/events?channels=...`** | Single global stream (PR #51), per-channel routing keys |
| Tests | **Zig** (`zig build test`) + **Vitest** + **pytest** (functional, isolated-`$HOME`) | Three-layer test pyramid |

### 1.2 Repository Layout

```
src/
├── ai_workflow/tui/               # LLM workflow + tool dispatch
│   ├── agentic_loop/              # 33+ execX tools moved here (was tool_registry.zig)
│   ├── http_handlers/             # REST endpoints (thin wrappers)
│   ├── routines/                  # Scheduled task fire pipeline
│   ├── llm_history.zig, models.zig, ...
│   └── prompts.zig                # System prompt assembly
├── modules/
│   ├── agent/                     # Agent struct, tool registry, prompts submodule
│   │   ├── tools/                 # 50+ agent tools (zig)
│   │   └── prompts/               # Prompt section helpers
│   ├── custom_http_client/        # libcurl wrapper (replaces std.http)
│   ├── custom_http_server/        # Per-request arena HTTP server
│   ├── databases/sqlite/          # SqliteBackend + Transactions
│   ├── daemon/                    # Cross-platform nalar service (POSIX + Win32)
│   ├── event_bus/                 # pub/sub for SSE fan-out
│   ├── gilvec_db/                 # Semantic-search vector store
│   ├── http/                      # Bash-tool HTTP client (separate from custom_http_client)
│   ├── logger/                    # Stdout/stderr/dedup logger
│   ├── nalar_browser/             # HTTP handlers + scripts for the browser tool
│   └── signal_handlers/           # SIGTERM/SIGINT equivalents
├── apps/
│   ├── desktop/                   # Vue 3 + TS webapp (the UI)
│   │   └── src/
│   │       ├── components/        # 10 domain-grouped subdirs (after PR #106)
│   │       ├── composables/       # useDesignHandlers, useKanbanScrollRestore, …
│   │       ├── stores/            # Pinia stores (workspaces, profiles, notifications, …)
│   │       ├── api/               # apiFetch wrapper + REST endpoints
│   │       ├── helpers/           # unwrapToolOutput, sseBus, scrollLogger, …
│   │       └── __tests__/
│   └── desktop_app/               # Native webview wrapper (nalar-desktop)
│       ├── main.zig
│       ├── embedded/              # Codegen outputs (Vue build artifacts)
│       ├── shared/
│       └── platform/              # WebKitGTK/WKWebView/WebView2 shims
├── helpers/                       # Cross-platform helpers (process, getcwd, getenv, …)
├── migrations/                    # 54 SQL migrations (sequential NNN_name.zig)
└── root.zig, main.zig, build.zig
```

### 1.3 Operating Conventions

- **Build**: `zig build` (full) · `zig build test` · `zig build install:linux:system` · `zig build nalar-desktop`
- **Ports**: dev server always on **8081** (DO NOT kill), local smoke on **8080**
- **Cross-platform**: every feature must compile on Linux + macOS + Windows; `zig build-obj -fno-emit-bin -target X` is the cross-compile smoke test
- **Migrations**: sequential `NNN_xxx.zig`; use `addColumnIfMissing` / `dropColumnIfExists` for idempotency
- **No `.zig-cache` left in worktrees**, no `.vue.ts.js` files from `vue-tsc --build` (clean before commit)
- **Functional tests**: `pytest tests/functional/` — never delete dev `$HOME` (safety invariant)

---

## 2. Plan Status Summary

The 178 plan files in `docs/plans/` and `docs/superpowers/plans/` (now deleted, see `§10.2`) were each opened, the first 30–50 lines summarized, and the claim cross-checked against `git log --all`, source-tree searches, and the `NALAR.md` changelog (which records "what landed" entries). Classification after the 2026-08-06 second-round consolidation:

| Status | Count | Meaning |
|---|---|---|
| ✅ **Implemented** | 144 | Landed in current code — verified via PR # or commit ref (+1 from the 2026-08-06 round: `kanban-create-task-run-agent`) |
| 🟡 **In Progress** | 6 | Partially landed; backend or frontend part shipped, not both (unchanged) |
| ⏳ **Pending** | 2 | Plan is current and still relevant; no implementation found (`kanban-task-tags-autocomplete`, `sse-reconnect-plan`) |
| ❌ **Superseded** | 2 | Replaced by a follow-up plan that did land (`constrain-design-elements-to-canvas` → `remove-canvas-background`, `design-per-page-chat-sessions` → `design-page-workspace-item-task-fk`) |
| 🗑️ **Not Relevant** | 0 | (all obsolete-tech plans were already filtered out in the 2026-07-26 round) |
| **Total** | **153** | 142 from the 2026-07-26 round + 11 new entries in the 2026-08-06 round. Historical 178 from the 2026-07-26 round includes 25 design-only specs in `docs/plans/` whose status was inherited from the matching implementation plan in `docs/superpowers/plans/`. |

> **Note on duplicates**: The original `docs/plans/` held design docs while `docs/superpowers/plans/` held implementation plans. When a design + implementation pair both existed, the implementation's status wins. Both folders were deleted after consolidation on 2026-07-26; the second-round 17 plans in `docs/superpowers/plans/2026-07-28-*`–`2026-08-06-*` were deleted on 2026-08-06.

---

## 3. Plans by Domain — What Each Feature Looks Like Today

### 3.1 Backend — Core HTTP / SQLite / Database

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-07-12-sqlite-tx-support.md` | ✅ | `Transaction` struct mirroring Go `sql.Tx` (PR #89) |
| `2026-06-04-sqlite-indexes-for-performance.md` | ✅ | `Migration041AddPerformanceIndexes` — 9 SQL indexes |
| `2026-06-20-pinned-workspace-item-tasks.md` | ✅ | Migration 050 + `task_pin.zig` + `tasks_reorder_pinned.zig` |
| `2026-06-16-workspace-item-position-reorder.md` | ✅ | Migration 045 + `workspace_items_reorder.zig` + frontend drag-drop |
| `2026-07-10-empty-workspace-item-bug.md` | ✅ | `EmptyName` error → 400; `AddItemDialog` shows `nameError` |
| `2026-06-06-workspace-item-task-pagination.md` | ❌ | Superseded by v2 (2026-06-10) which shipped |
| `2026-06-10-workspace-item-task-pagination.md` | ✅ | Cursor-paginated "Load More" v2 |
| `2026-06-11-workspace-item-tasks-sort-by-updated-at.md` | ✅ | `TaskSortField` + `Migration042` index |
| `2026-06-30-edit-workspace-item-name.md` | ✅ | `updateWorkspaceItemName` + inline-rename pencil |

### 3.2 Backend — LLM Workflow + Tools

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-01-15-llm-completion-notification.md` | ✅ | OS notification on `finish_reason=stop` (notify-send / osascript / PowerShell) |
| `2026-03-17-add-is-input-is-output-columns.md` | ✅ | `is_input`/`is_output` INTEGER columns (Migration 016) |
| `2026-06-11-nalar-config-url-style.md` | ✅ | `url_style` per LLM profile + `notify_on_complete` flag |
| `2026-06-11-sub-agents-config-field.md` | ✅ | `SubAgentConfig` type + `sub_agents: SubAgentsList` |
| `2026-06-19-fix-sse-incomplete-chunked-encoding.md` | ✅ | Chunked encoding + `Transfer-Encoding: chunked` (#21) |
| `2026-06-30-fix-sse-blocking-api.md` | ✅ | `SseManager.sendDeferred` + locked reads (#52) |
| `2026-06-30-fix-sse-fd-leak.md` | ✅ | POLL.NVAL sub + TOCTOU race fix (#52) |
| `2026-06-30-single-sse-all-sessions.md` | ✅ | Single global EventSource + central broadcast (#51) |
| `2026-06-30-unify-sse-endpoints.md` | ✅ | 5 routes → `/api/events?channels=…` (#48) |
| `2026-07-03-decoupled-nalar-service.md` | ✅ | `nalar service {start,stop,status,restart}` + `daemon.zig` (#72) |
| `2026-07-16-search-add-rg-flags.md` | ✅ | `word_boundary`/`literal`/`only_matching` (#104) |
| `2026-07-16-search-history-rewrite.md` | ✅ | `search_history` replaces `read_compacted_messages` |
| `2026-07-16-session-auto-retry-until-stop.md` | ✅ | "Unattended mode" — keep retrying (#103) |
| `2026-07-25-custom-http-client-libcurl.md` | ✅ | libcurl-backed HTTP client + macOS+Windows (#120, #123) |
| `2026-07-25-llm-user-identifier.md` | ✅ | End-user identifier UUID for Anthropic + OpenAI (#114) |
| `2026-06-11-tls-init-fast-fail.md` | ❌ | Replaced by `CallError = error{StreamTimeout, …}` + configurable `retry_delay_ms` |
| `2026-06-20-compaction-output-long-context.md` | 🟡 | Envelope landed; `read_compacted_messages` → `search_history` (different tool) |
| `2026-06-24-fix-compaction-envelope-id-mismatch.md` | 🟡 | Real-DB-IDs + role-aware previews (commit `36abea33`) — on worktree, not merged |
| `2026-06-21-llm-stream-watchdog.md` | 🟡 | `StreamWatchdog` (commit `21ec4e92`) — on worktree, not merged |
| `2025-01-13-read_file-hash-only.md` | ⏳ | `hash_only` added then REMOVED in a refactor — feature still relevant |
| `2025-01-13-text-replace-edge-cases.md` | ⏳ | `text_replace.zig` exists but edge-case tests never added |
| `2026-07-29-fix-retry-delay-ms-race.md` | ✅ | Surgical 1-line clamp `@max(deadline_ns - now_ns, 0)` in `src/ai_workflow/tui/agentic_loop/retry_delay_ms.zig` to prevent `panic: integer does not fit in destination type` when wall-clock races between `Clock.now` calls in the retry-sleep path. Single behavioural test (`retry_delay_ms_race_test.zig`) exercises the race window in 200 iterations with `delay_ms = 1`; pre-fix the test binary aborts, post-fix all 200 iterations return cleanly. Out of scope: the upstream "stream returns 0 chunks → error.StreamInterrupted" issue in `Agent.zig` (separate bug; `retry_count > 10` is the eventual guard). |
| `2026-07-30-better-compaction-context.md` | ✅ | Compacted messages now carry the user's full chat history and every `read_file` path the AI touched (forward context, not just the compactor's summary). New `compaction_context.zig` helpers (`fetchUserChatHistory`, `fetchReadFilePaths`, `enrichCompactionXml`, `parseReadFilePath`) wired into `workflow_commpact_message.zig` before `mark_history_not_for_llmrun`. Inline tests per the `agentic_loop/` README convention. Same memory was previously captured in the global memory `zig-mock-state-global-use-after-free-across-tests.md` (mock-state slices go stale across tests when `mockCompactMessagesInMemory` stored a borrowed pointer instead of an owned buffer). |
| `2026-07-29-create-kanban-task-tool.md` | ✅ | New LLM-callable `create_kanban_task` tool — agent can create a kanban task under an existing kanban item directly from chat. Mirrors `kanban_list` / `kanban_move_task` shape: single tool file (`create_kanban_task.zig`) with `CreateKanbanTaskInput`, the `AgentTool` definition, `executeCreateKanbanTaskToString` returning XML (`<kanban_task><success>true</success><task_id>…</task_id><column_id>…</column_id><position>…</position></kanban_task>`), and the `successXml` / `errorXml` / `errorXmlOwned` triplet. Standard `tools_exec_create_kanban_task.zig` wrapper (parse + call + wrap via `wrapToolOutput`). Validates: parent item exists and `item_type='kanban'`; parent has ≥ 1 column (auto-assign to first at `MAX+1` when caller omits `column_id`); empty/null `name` / `workspace_id` / `item_id` → `<error>`. Registered in `UNIFIED_TOOL_REGISTRY` next to `kanban_list` / `kanban_move_task`. |

### 3.3 Backend — Routines / Scheduler / Spawn

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-06-13-add-task-routines.md` | ✅ | Parent plan (PR #8) |
| `2026-06-13-add-task-routines-chunk-4.md` | ✅ | `POST /api/.../tasks/:tid/run` |
| `2026-06-13-add-task-routines-chunks-2-3.md` | ✅ | `fire.zig` + `Scheduler.zig` (in-process, no sub-process) |
| `2026-06-13-add-task-routines-chunks-5.md` | ✅ | Frontend types & API client |
| `2026-06-13-add-task-routines-chunks-5-7.md` | ✅ | Frontend chunks index |
| `2026-06-13-add-task-routines-chunks-6.md` | ✅ | `AddTaskPickerDialog` + `AddRoutineDialog` + `EditRoutineDialog` |
| `2026-06-13-add-task-routines-chunks-6-tests.md` | ✅ | Spec files for the three dialogs |
| `2026-06-13-add-task-routines-chunks-7.md` | ✅ | Routine-task row + Sidebar picker |
| `2026-06-15-spawn-sub-agent-config.md` | ✅ | `agent_name` config-driven sub-agent selection |
| `2026-06-09-spawn-sub-agent-inherited-context.md` | ✅ | `inherited_context` on `SubAgentInput` + helper |
| `2026-05-14-spawn-sub-agent-inherited-context-ui.md` | ✅ | `subAgentArgs` prop + per-agent badge |
| `2026-06-29-sub-agent-peek-progress.md` | ✅ | `SubAgentPeekPanel.vue` + `useSubAgentPeek.ts` (#50) |

### 3.4 Backend — Web / Browser / Search

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-06-12-web-fetching-service-to-nalar-browser.md` | ✅ | `web_fetching_service` → `nalar_browser`; `cloak_browser` → `nalar_browser` |
| `2026-06-17-nalar-browser-tool-output-component.md` | ✅ | `components/tool_outputs/NalarBrowser.vue` |
| `2026-04-08-multifolder-session-dir.md` | 🟡 | Only single `session_dir` filter shipped; array `session_dirs: ?[][]const u8` not added |
| `2026-04-08-multifolder-session-dir-design.md` | ✅ | Multi-folder design (backend partial) |
| `2026-07-08-glob-edge-cases.md` | ✅ | 22+ edge-case hardenings for `glob.zig` (#85) |
| `2026-07-08-search-edge-cases.md` | ✅ | 12+ edge-case hardenings for `search.zig` (#83) |
| `2026-07-15-glob-respect-ignore-files.md` | ✅ | `respect_ignore_files` param (#98) |
| `2026-07-15-search-respect-ignore-files.md` | ✅ | `respect_ignore_files` param (#96) |
| `2026-07-15-retry-delay.md` | ✅ | Configurable retry delay 0–60 000 ms (PR #93) |
| `2025-04-03-web-search-tools-design.md` | ✅ | `web_search.zig` + `execute_web_search` registered |
| `2025-03-18-lsp-definition-simple.md` | 🟡 | Session-based LSP client (not 1-shot as planned) |
| `2025-03-18-lsp-definition-tdd-simple.md` | 🟡 | TDD tests for LSP simple |
| `2025-03-18-lsp-tools-integration.md` | 🟡 | All 5 LSP tools registered (definition/references/hover/document_symbol/workspace_symbol) |
| `2025-03-18-lsp-tools-tdd-testcases.md` | 🟡 | TDD tests for LSP tools |
| `2026-04-04-search-tool-improvements.md` | 🟡 | Mostly superseded by 2026-07-15 / 2026-07-16 plans |

### 3.5 Backend — Bash / Git / File Ops

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-05-02-bash-max-lines-truncation.md` | ✅ | `max_lines` + `stdout_lines`/`stderr_lines` |
| `2026-06-10-bash-cross-platform.md` | ✅ | `bash.zig` works on Linux/macOS/Windows |
| `2026-07-24-bash-tool-pipe-leak.md` | ✅ | Close parent pipe FDs after `waitPidBounded` |
| `2026-06-18-set-git-worktree-tool.md` | ✅ | `set_git_worktree` tool + `sessions.git_worktree_cwd` |
| `2026-06-18-set-git-worktree-cwd-override.md` | ⏳ | `cwd_override` field exists as dead-letter placeholder — never populated |
| `2026-06-18-create-worktree-menu-option.md` | ✅ | "Create worktree" in WorktreeMenu dropdown |
| `2026-06-18-git-worktree-cwd-pr.md` | ✅ | Worktree-aware branch display + Create-PR dropdown |
| `2026-06-20-set-git-worktree-path-already-exists.md` | ✅ | Structured path-conflict handling on `set_git_worktree` |
| `2026-06-20-worktree-path-collision-recovery.md` | ✅ | Recovery doc for `git worktree add` path collisions |
| `2026-06-09-remove-get-skill-name-parameter.md` | ✅ | `GetSkillInput` no longer has `skill_name` |
| `2025-01-13-read_file-hash-only.md` | ⏳ | See Backend — LLM Workflow |

### 3.6 Frontend — Chat / Streaming / Sidebar

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-06-03-session-profile-selection.md` | ✅ | `selected_profile_model` column + `PUT /api/session/:id` |
| `2026-06-05-chatview-loading-overlay.md` | 🗑️ | `LoadingOverlay.vue` was never built |
| `2026-06-05-sidebar-mutually-exclusive-active-state.md` | ✅ | `setActiveWorkspaceItem(null)` on chat/task selection |
| `2026-06-06-load-more-before-edge.md` | ✅ | `computeLoadMoreThreshold` + `loadMoreThresholdRatio` |
| `2026-06-08-sse-client-ids-use-after-free.md` | ✅ | `getListClientsForSession` returns owned copy + SSE lock |
| `2026-06-11-messages-panel-extraction.md` | 🗑️ | `MessagesPanel.vue` was never created |
| `2026-06-11-messages-panel-extraction-design.md` | ❌ | Same — replaced by ChatView-only shape |
| `2026-06-19-api-error-notification.md` | ✅ | `NotificationContainer.vue` + `notifications.ts` + `apiFetch` wrapper |
| `2026-06-19-stop-notification.md` | ⏳ | Backend OS-notification hook fired; frontend toast UI not built |
| `2026-06-19-stop-notification-design.md` | 🟡 | Backend Done; frontend in-flight |
| `2026-06-19-workspace-siblings-in-prompt.md` | ✅ | Workspace Context (siblings list) injected into prompt |
| `2026-06-10-local-cwd-memories-in-prompt.md` | ✅ | Auto-inject `<cwd>/.nalar/memories/*.md` into system prompt |
| `2026-06-04-chat-lazy-load-button.md` | ❌ | Rolled into `chat-load-more-before-edge` |
| `2026-06-04-full-type-only-bubbles.md` | 🟡 | `streamingContent` refactor split; `streaming-` ID-prefix removal not fully done |
| `2026-06-10-scroll-ratcheting-fix.md` | ✅ | Fix scroll position oscillation |
| `2026-06-05-stuck-connecting-badge.md` | ❌ | Folded into global SSE refactor |
| `2026-06-16-streaming-ux-design.md` | 🟡 | Only `show_preview` part shipped; caret/blinking caret/think-block UI deferred |
| `2026-06-05-workspaces-items-endpoint.md` | ✅ | 3-call init flow: workspaces → items → tasks |
| `2026-06-06-workspace-item-task-rename.md` | ✅ | Rename task in sidebar updates linked session + SSE |
| `2026-06-09-scroll-logger-no-container-rename.md` | ✅ | `handleVirtualScroll`'s container never null |
| `2025-03-27-session-messages-lazy-scroll.md` | 🟡 | Cursor-based lazy scroll landed (via Vue 3 VirtualScroller, not SolidJS) |
| `2025-03-30-chatbox-implementation.md` | 🗑️ | SolidJS + Tailwind v4 — replaced by Vue 3 ChatInput |
| `2025-01-15-sidebar-session-dir-filter.md` | ⏳ | `get_sessions_by_dir` exists; Sidebar doesn't wire filter param |
| `2026-08-06-chat-scroll-position-persistence.md` | ✅ | `useChatScrollRestore` composable + `VirtualScroller.scrollToPosition()` + ChatView initial-load branch + `isInitialLoad` guard |
| `sse-reconnect-plan.md` (root) | ⏳ | Frontend SSE auto-reconnect plan — 4 `EventSource` connection sites (`App.vue::initWorkersSse`, `ChatsList.vue::connectSessionsSse`, `ChatView.vue::connectSse` × 2 streams, `Sidebar.vue::connectSessionsSse` stub). Only `App.vue` reconnects (naive `setTimeout(…, 5000)`, contains a bug). Plan calls for exponential backoff + jitter, tab-visibility awareness, online/offline handling, max-retry cap, UI feedback (`onStateChange` channel → "Reconnecting…" badge), per-stream unified protocol. See `docs/sse-reconnect-plan.md` (kept on disk as a protocol reference, not a per-feature plan). |

### 3.7 Frontend — Kanban (Workspace Item Type)

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-06-21-workspace-item-kanban.md` | ✅ | `feature/workspace-item-kanban` — full kanban subsystem |
| `2026-06-21-workspace-item-kanban-design.md` | ✅ | Companion design |
| `2026-06-26-fix-kanban-list-empty-add-sse.md` | ✅ | Shape-validation hints + SSE pipeline |
| `2026-06-27-kanban-column-description-settings.md` | ✅ | Migration 053 + `KanbanSettingsDialog.vue` |
| `2026-06-27-kanban-sse-auto-move.md` | ✅ | `fetchKanbanTasks` on `kanban_task.*` SSE + card auto-move (#43) |
| `2026-06-29-kanban-move-task-sse-emit.md` | ✅ | `kanban_move_task` emits `onEventSendKanbanTask` (#46) |
| `2026-06-30-fix-kanban-drop-position.md` | ⏳ | Plan committed; `KanbanColumn.handleDrop` still hardcodes `position = cardsInColumn.value.length` |
| `2026-07-16-kanban-task-detail-dialog.md` | ✅ | Kanban task detail dialog with persistent description (#101) |
| `2026-07-22-kanban-add-task-via-detail-dialog.md` | ✅ | `KanbanTaskDetailDialog` replaces `AddTaskDialog` for "+ Add" (#102) |
| `2026-07-23-preserve-kanban-horizontal-scroll.md` | ✅ | `useKanbanScrollRestore` composable |
| `2026-07-24-kanban-lazy-load-tasks.md` | ✅ | Initial fetch to 100 + scroll-triggered auto-load (#111) |
| `2026-07-25-kanban-description-rich-editor.md` | ✅ | Rich editor + image paste + @path picker (#124) |
| `2026-07-26-kanban-task-notification-icon.md` | ✅ | **Orange "AI finished — awaiting review" dot + green "reviewed" checkmark** on each standard task card. See §3.7.1 below. |
| `2026-07-04-copy-kanban-spec.md` | ✅ | `POST /kanban/copy_spec_from` + `CopyKanbanSpecDialog.vue` |
| `2026-07-01-change-task-to-card-kanban.md` | ✅ | `WorkspaceItemTask` `variant: 'row' \| 'card'` (#57) |
| `2026-06-27-kanban-status-prompt.md` | ✅ | "Kanban Status Tracking" section in agent prompt |
| `2026-07-30-kanban-task-search.md` | ✅ | Server-side `?q=` filter on `GET /api/.../items/.../tasks` + compact `<KanbanSearchInput>` in the kanban header. See §3.7.2 below. |
| `2026-07-28-kanban-task-tags.md` | ✅ | Free-form string-list `tags` on each kanban task. See §3.7.3 below. |
| `2026-07-30-kanban-task-tags-autocomplete.md` | ⏳ | Plan landed but **not yet implemented**. Backend endpoint + `listKanbanDistinctTags` model + `KanbanTagsInput` autocomplete dropdown are designed. See §3.7.4 below. |
| `2026-08-06-kanban-create-task-run-agent.md` | ✅ | "Create task & run agent" button: primary flow collapses create-task + queue-first-message + navigate into one click. See §3.7.5 below. |

#### 3.7.1 Kanban task "AI finished — awaiting review" notification icon (2026-07-26)

A small affordance on each **standard** kanban task card (routine and memory cards use their own status affordances) that tells the user at a glance which cards the AI is done with and which the user has already engaged with.

**Three terminal states** (mutually exclusive, computed by the SQL `CASE` below):

| State | Trigger | Card UI |
|---|---|---|
| **AI running** | `processingState[task.id] === true` (existing) | Yellow spinner |
| **AI finished, awaiting review** *(new)* | `sessions.last_finish_reason = 'stop'` AND no human action since | 8px **orange dot** (`rgb(251, 146, 60)`) with a 4-pulse ripple animation, then a steady glow. Tooltip: "AI finished — awaiting your review" |
| **AI finished, reviewed** *(new)* | `sessions.last_finish_reason = 'stop'` AND human has touched since | Small **green checkmark** (lucide `check-circle-2`). Tooltip: "Reviewed" |
| **AI never ran** | No `sessions` row for this task, OR no `last_finish_reason = 'stop'` | No icon |

**The "human touch" semantic** matches GitHub's "conversation resolved" model: ANY user action (drag, rename, edit description, pin, send a chat message, open the chat) counts as a review. The icon turns green the moment the user does *anything* with the card. An explicit "Mark as reviewed" button is out of scope (matches the plan, deferred).

**Data model** — minimal, no new session columns:

- One new column on `workspace_item_tasks` (Migration 065): `last_human_touched_at INTEGER` (unix ms, NULL = never).
- AI state reuses `sessions.last_finish_reason` + `sessions.updated_at` (both already on the sessions table from Migration 063 — no new session columns).
- The kanban-list `CASE` predicate (new column 20 in `listWorkspaceItemTasksWithCursor`):

  ```sql
  CASE WHEN COALESCE(s.last_finish_reason, '') = 'stop'
            AND (t.last_human_touched_at IS NULL
                 OR t.last_human_touched_at < CAST(strftime('%s', s.updated_at) AS INTEGER) * 1000)
       THEN 1 ELSE 0 END
  ```

  The `* 1000` is the seconds→unix-ms conversion (sessions.updated_at is TEXT in `YYYY-MM-DD HH:MM:SS`; `last_human_touched_at` is INTEGER unix-ms).

#### 3.7.2 Kanban task search input (2026-07-30)

A compact `<KanbanSearchInput>` renders in the kanban board header (to the left of ⚙️ Settings). Typing filters visible tasks by `name`, `description`, and `tags` via a new `?q=` query param on the existing `GET /api/workspaces/:ws/items/:item/tasks` endpoint.

**Server-side filter** (NOT a frontend `.filter()` over `item.tasks`): the kanban loads only the first 100 tasks per page (`MAX_PAGE_SIZE`). A frontend `.filter()` would miss tasks on later pages — exactly the failure mode the user is trying to avoid when their board has 200+ tasks.

**SQL** — `WHERE LOWER(t.name) LIKE ? ESCAPE '\\' OR LOWER(COALESCE(t.description, '')) LIKE ? ESCAPE '\\' OR LOWER(COALESCE(t.tags, '')) LIKE ? ESCAPE '\\'` when `q` is set. User-supplied `%`, `_`, `\` are escaped to literal `\%`, `\_`, `\\` before binding — without the `ESCAPE` clause, a user typing `%` would match every row (LIKE wildcard). Cursor pagination advances through the **filtered** set, not the unfiltered set.

**Empty / missing `q`** → no filter (the original efficient WHERE on `workspace_item_id` alone).

**`tags` matching** uses substring on the JSON-encoded TEXT column (e.g. `["bug","urgent"]` matches `bug`). Substring `bug` also matches `["debug"]` and `["bugfix"]` — accepted as the typical kanban-search UX (Trello/Linear both do this). Strict `json_each`-based exact-tag match is deferred.

**Frontend UX** — the input is debounced 300ms (hand-rolled `setTimeout`; `@vueuse/core` is not installed in this project). Cursor resets to `undefined` (page 1 of the filtered set) on every query change. Press `Esc` or click the ✕ clear button to reset. Component-local state — closing the kanban clears the query automatically.

**Empty state** — a `No tasks match "..."` banner renders between the header and columns when `tasks.length === 0 && searchQuery.trim() !== ''`.

**SSE wire** — the `kanban_task.*` SSE handler in `stores/kanbanSse.ts` reads the active q from `workspacesStore.activeSearchQueries: Map<itemId, string>` and forwards it on refetch. Without this, a remote task move/edit during a search would silently reset the user's narrowed view to the unfiltered list.

**Out of scope** — fuzzy / regex matching, search history, URL persistence, highlight inside card text, multi-page auto-load (search only sees the first 100 matches per page), `json_each` exact-tag match.

**SSE wire** — extends the existing `kanban_task` event with a new `human_touched` action + `needs_human_review: bool` payload. The frontend `kanbanSse` store already handles `'task_id' in event` to trigger `fetchKanbanTasks` — no consumer change needed.

**Stamp call sites** (every HTTP handler that mutates a task on behalf of a human user fire-and-forget `updateTaskLastHumanTouchedAt(null)`):

| Handler | Action stamped |
|---|---|
| `task_update.zig` | Rename, description edit, pin/unpin |
| `task_create.zig` | Any new task (user owns the empty slot) |
| `tasks_move.zig` | Drag to another column |
| `session_create.zig` | Sending a chat message (POST `/api/llm/session`; `task.id == session.id` per project convention) |
| `task_mark_human_touched.zig` (new) | `PUT /api/workspaces/:w/items/:i/tasks/:t/touched` — fired by the frontend the moment the user opens a task's chat |

**Frontend wiring** — `workspacesStore.setActiveTask` (canonical entry point for every "user opens a task" call) fires-and-forgets `api.markTaskHumanTouched(workspaceId, itemId, taskId)` so opening a card to "just read" the AI's output also counts as a review.

**Out of scope** — Routine/memory cards (existing routine status dot / memory accent stripe already cover AI state). Per-column "X awaiting review" aggregate badge. Sidebar notification badge. Explicit "Mark as reviewed" button.

#### 3.7.3 Kanban task tags — free-form string list (2026-07-28)

Each kanban task can carry **0+ tags** — short lowercase strings rendered as colored chips on the card and edited via a chip input on the task detail dialog. No managed vocabulary, no tag management page, no filtering — forward-compatible with a future managed-tag migration.

**Data model** — one new column on `workspace_item_tasks` (Migration 067): `tags TEXT NOT NULL DEFAULT ''` — stores a **JSON-encoded array of strings** (e.g. `'["bug","urgent","frontend"]'`); empty string = "no tags". The JSON-on-the-wire shape keeps the DB column as TEXT (matching the existing `description` Migration 062 pattern) and the frontend `string[]` interface unchanged.

**Validation** (`tags_validation.zig::validateAndNormalizeTags`) — char whitelist `[a-zA-Z0-9_-]` (GitHub-label style), per-tag length cap 50, case-insensitive dedupe (first-occurrence casing wins), empty-string rejected. Empty list → wire shape `''` (the SQL `DEFAULT ''` sentinel; the per-handler split-INSERT pattern for the `NOT NULL DEFAULT ''` column is the same one used for `description`).

**Wire shape** — `WorkspaceItemTaskResponse.tags: ?[]const u8` (JSON-encoded string), `TaskCreateRequest.tags: ?[]const u8`, `TaskUpdateRequest.tags: ?[]const u8`. The frontend API wrapper does `JSON.stringify(arr)` on the way out; `normalizeTaskTags(task)` (called at every fetch site) parses the JSON string into `string[]` once per fetch, falling back to `[]` on malformed input (defensive against legacy rows).

**Two list endpoints** needed updates because they bypass `WorkspaceItemTaskInfo`:
- `tasks_list.zig` — uses `WorkspaceItemTaskInfo` (tags already at index 21); just append `.tags = task.tags`.
- `workspaces_list.zig` — has its own SELECT; add `t.tags` at column index 9 and `.tags = row.values[9]` in the constructor.

**Frontend UI** — `<KanbanTagsInput>` (chip input, type + Enter to add, ✕ to remove, Backspace on empty removes last chip, 6-color deterministic palette via djb2 hash of lowercase tag). Rendered in `KanbanTaskDetailDialog` (between description and unattended-mode toggle, in both create and edit modes) and as a row of up to 3 colored chips on `WorkspaceItemTaskCard` (with `+N more` link when the task has > 3 tags).

**Why JSON-string-on-the-wire and not JSON-array** — three reasons:
1. **Single source of truth for JSON shape.** The DB column is TEXT, the wire type is `?[]const u8` (a string). One less transformation: backend reads → parses → validates → re-encodes → writes. Frontend parses → caches.
2. **Defensive against malformed JSON.** Frontend `normalizeTaskTags` treats `tags` as defensive — if the parse fails, fall back to `[]`. Chip render never crashes on malformed input.
3. **Forward-compatible with a managed-tag migration.** The JSON-encoded array is the natural source of truth for a future migration that reads `json_each(t.tags)` and creates proper tag rows + a join table.

**Out of scope (v1)** — tag filtering on the kanban board (substring search later if needed); tag management page; tag autocomplete (see §3.7.4 for the planned design); tag rename propagation; per-tag user-chosen colors.

#### 3.7.4 Kanban task tags autocomplete — PLANNED, NOT YET BUILT (2026-07-30)

`docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md` is a fully designed but unimplemented follow-up to §3.7.3. Adds a suggestions dropdown to the `<KanbanTagsInput>` chip input — top-N most-used tags (frequency DESC, then last-used DESC) for the active kanban item, lazily fetched on focus, infinite-scrolled client-side after the first 8, filtered case-insensitive by typed prefix.

**Architecture** — new endpoint `GET /api/workspaces/:ws/items/:item/kanban/tags?limit=8&offset=0` returning `{ tags: [{name, count, last_used_at}], has_more: bool }`. Backend uses `json_each()` over the existing `tags` column with `GROUP BY je.value`, `COUNT(*)`, `MAX(updated_at)`, the `LIMIT N+1 OFFSET K` trick for `has_more` from a single query. Frontend `getKanbanTagSuggestions` API wrapper; the dropdown paginates client-side after the first 8 (no extra fetches for in-memory list).

**Why pending** — the plan landed (2026-07-30) but the implementation never started; the user's priority shifted to design-mode features (group drag, layer DnD, undo/redo) and then to memory compaction. Tracked in §5 Pending as a follow-up that piggybacks on §3.7.3's tag infrastructure.

**Out of scope (planned)** — cross-tag-prefix filtering server-side (only client-side); tag-creation from the dropdown (always uses the existing chip-commit path); tag merge/rename; per-tag-color override.

#### 3.7.5 "Create task & run agent" button (2026-08-06)

The New Task dialog (`KanbanTaskDetailDialog`, `mode: 'create'`) gets a secondary `▶ Create task & run agent` button next to the primary `Create task` button. The new button collapses the three-step ceremony (create task → click card → type description into chatbox) into one click.

**Wire.** The dialog adds a new `create-and-run` emit with the same payload as `create` (different `mode: 'create_and_run'` discriminator). The host (`KanbanView.handleCreateTaskSave`) branches on `mode`:

| Mode | Flow |
|---|---|
| `create` | Today's behavior: `addTask` → `moveTaskToColumn` → close dialog |
| `create_and_run` | `addTask` → `moveTaskToColumn` → `runAgentOnNewTask` (wraps `api.sendChatMessage`) → on `status: 'send'`, emit `selectTask(taskId)` so the existing `AppLayout → Sidebar` chain does `setActiveTask` + `router.replace` to the new chat view. On failure, surface a `notifyError` toast and skip navigation. |

**Queued message composition.** `title + '\n\n' + description` when description is non-empty, else just `title`. The title is the first line the LLM sees; the description is the body. Empty description is allowed (the message is just the title).

**Unattended toggle.** The dialog's existing `is_auto_retry_until_stop` toggle flows through as `is_auto_retry_until_stop` to `api.sendChatMessage`. Same as the routine task fire path.

**Files.** 5 (3 NEW tests, 2 EDIT impl). Frontend-only — no backend changes, no migration, no Zig changes. The two endpoints (`POST /api/workspaces/:ws/items/:item/tasks` and `POST /api/llm/session`) already exist and compose cleanly.

**Plan:** `docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md`

### 3.8 Frontend — Design Canvas (Workspace Item Type)

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-07-05-design-mode.md` | ❌ | v5 (panzoom/5 tools) — superseded by Figma-lite redesign |
| `2026-07-05-design-mode-design.md` | ❌ | Same |
| `2026-07-08-design-mode-redesign.md` | ✅ | Figma-lite redesign (PR #90) — 9 HTTP handlers, 6 element types |
| `2026-07-08-design-mode-redesign-design.md` | ✅ | Companion design |
| `2026-07-08-design-mode-deferred.md` | 🟡 | Deferred items list (marquee, smart-spacing, lock/hide, etc.) |
| `2026-07-19-design-preview-mode-design.md` | ✅ | Preview/Edit mode toggle (`#123`) |
| `2026-07-19-design-hand-pan-mode.md` | ✅ | Hold Space + drag to pan |
| `2026-07-25-design-element-drag-and-drop.md` | ✅ | Drag-wire + multi-select + snap + nudge (#125) |
| `2026-07-25-design-page-delete-button.md` | ✅ | Wire tab-strip × button delete end-to-end (#126) |
| `2026-07-28-design-per-page-chat-sessions.md` | ✅ | Per-page chat scoping (each design page gets a disjoint "Design Chat: <pageName>" task) + one-shot legacy migration |
| `2026-07-28-design-page-workspace-item-task-fk.md` | ✅ | 1:1 FK design_pages.workspace_item_task_id → workspace_item_tasks.id (replaces the brittle name-based lookup) |
| `2026-07-29-remove-canvas-background.md` | ✅ | Canvas background removed (no visible page rectangle, no W × H header inputs, no drag/nudge clamps, no snap-to-canvas-edges). Pages are purely logical containers; elements can be placed at any coordinates. |
| `2026-07-30-design-undo-redo.md` | ✅ | Element-level undo/redo (`Cmd+Z` / `Cmd+Shift+Z` / `Cmd+Y` + toolbar buttons). Per-page history stacks (100-entry cap), localStorage-persisted (debounced 500ms, `:v1:` schema version). Captures drag/resize/nudge/PropertiesPanel/delete/reorder/group at gesture boundaries (one entry per gesture; arrow nudge = 1 per keypress). Includes wire-up of 2 silently-dropped emits (LayersPanel ▲/▼, Monaco Save) as prerequisite. |
| `2026-07-30-design-drag-debounce-batch.md` | ✅ | Backend loads no longer die when the user drags a multi-element selection. Two-layer fix: (a) new `POST .../elements/geometry-batch` handler collapses N per-element PATCHes into one for multi-element drag (5× reduction for a 5-element selection); (b) module-level `recentLocalMutations: Map<element_id, expiry_ms>` in `workspaces.ts` with a 1500 ms TTL — every locally-issued geometry PATCH registers the affected element ids; the SSE handler in `stores/designSse.ts` skips the `fetchDesignElements` GET fan-out when the incoming event is for a locally-mutated element (strict-superset dedupe — any unknown id falls through to the normal fetch path). New SSE event `design_elements_geometry_batch_updated` carries `element_ids[]`. Combined: a 5-element drag drops from ~200 req/sec to ~2 req/sec. A `useDesignDragDebounce` composable (trailing-edge 250 ms debounce + `flush()` on pointerup) is implemented but NOT wired into `DesignElement.vue` — the existing 50 ms throttle stays because the element's visual transform is bound to `props.element.x/y` (no local optimistic state mutation yet), and a pure trailing-edge debounce would freeze the visual until pointerup. The debounce wires up naturally once local optimistic state mutation lands. |
| `2026-07-29-constrain-design-elements-to-canvas.md` | ❌ | Replaced by `2026-07-29-remove-canvas-background.md` — the "canvas as boundary" concept was rejected by the user; no rectangle is rendered, no clamp is applied, no W × H header inputs. See §6. |
| `2026-07-29-design-element-parent-id-tools.md` | ✅ | Closed three compounding tool gaps that prevented the LLM from correctly nesting elements under an existing `group`/`frame`. (1) `set_design_page` response now emits a `parent_id` attribute per `<element>` block so the LLM can see the existing hierarchy. (2) `add_element` tool gained `parent_id: ?[]const u8 = null` with validation: parent must exist on same page, must be `group` or `frame` (`ParentNotContainer` otherwise); the SQL binds NULL via the `SqliteBackend.exec`-empty-slice-as-NULL trick (see `zig-sqlite-patterns.md` §"empty slice as NULL"). (3) New `set_element_parent` tool with cycle detection via recursive CTE (`WHERE dpe.parent_id IS NOT NULL` bounds the walk). Three layers' worth of TDD-red-then-green tests in `design_model_add_element_parent_test.zig` + `design_model_set_element_parent_test.zig` + `set_design_page_test.zig`. |
| `2026-07-29-design-right-click-group-menu.md` | ✅ | Right-click context menu on LayersPanel rows AND design canvas. Group selection · Select all · Bring to front · Bring forward · Send backward · Send to back · Delete. Canvas Shift+click now supports multi-select (was always replace). Keyboard shortcuts: `Cmd+A`, `Cmd+[` / `]`, `Cmd+Shift+[` / `]`, `Backspace`. Behind the scenes: introduced the missing `POST /elements/reorder` endpoint so the four "Bring / Send" actions actually persist to the DB (a pre-existing bug — the per-row ▲/▼ buttons on the layers panel only updated the local layer-panel view, not the backend). Plus the `Cmd+Shift+G` Ungroup shortcut wired to `ungroupElements` (reparents children to the group's parent, deletes the group row; 400 on `EmptyGroup` / `NotAGroup`). |
| `2026-07-30-design-layer-drag-join-or-leave-group.md` | ✅ | Figma-style drag-and-drop in the LayersPanel. Drag a row onto another `group`/`frame` row → join (last-children, preserving multi-selection order); drag onto a top-level drop zone → leave group / move to top-level; multi-select drag drops the whole selection into the same target. `reparentElements(alloc, db, input)` model with cycle preflight (recursive CTE walks `parent_id` upward, rejects any reparent that would close a cycle). New `POST .../elements/reparent-batch` endpoint, `api.reparentDesignElementsBatch`, `useLayerDragDrop` composable, `LayerRow kind="drop-zone"` non-draggable row with `TOP_LEVEL_SENTINEL = '__design_top_level__'` id, and `useDesignHandlers.reparentLayers`. 13-layer file touch map (model, handler, route, API, store, composable, LayerRow, LayersPanel, DesignView, useDesignHandlers) + 6 commits ending `d40e7a19`. |
| `2026-07-30-fix-design-resize-handles-bubble-bug.md` | ✅ | 1-line fix in `DesignElement.vue::startDrag`: `event.stopPropagation()` whenever `mode !== 'move'` — prevents the parent wrapper's `@pointerdown` from starting a second gesture that steals pointer capture from the handle. Existing tests stub the handle's `addEventListener` and bypass the wrapper, so they couldn't catch the bug; new behavioural regression test counts `select` emits (pre-fix: 2 from both handle + wrapper; post-fix: 1 from handle only). Pattern captured as cross-project memory `design-resize-handle-pointerdown-bubbles-to-wrapper.md` so future agents don't re-introduce the bug when adding new interactive children to gesture-driven components. |
| `2026-08-06-move-element-with-descendants.md` | ✅ | **Server-side cascade move.** New `POST .../elements/move-batch` accepts `{ items: [{ element_id, dx, dy, width?, height?, rotation? }] }`. Each item's `(dx, dy)` applies to the root + every transitive descendant via a single recursive CTE inside one SQL transaction. `width`/`height`/`rotation` apply ONLY to the root (Figma convention — resize is per-element, not per-subtree). One SSE event per request carrying every affected `element_id`. The frontend's drag path shrinks from N x/y pairs (with client-side `expandSelectionWithDescendants` walk) to N (dx, dy) pairs (typically one — the dragged root). New LLM tool `move_design_element` with `apply_to_children` default `true` matches the user mental model. |
### 3.9 Frontend — Settings / Profiles / Nalar

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-06-05-delete-profile.md` | ✅ | `DELETE /api/config/nalar/profiles/:name` + `useProfileDelete` |
| `2026-06-17-nalar-settings-revamp.md` | ✅ | 4-sub-tab Nalar settings IA |
| `2026-06-17-nalar-settings-revamp-design.md` | ✅ | Companion design |
| `2026-06-17-add-memories-settings-menu.md` | ✅ | Memories tab in Settings (CRUD) |
| `2026-07-02-auto-init-config.md` | ✅ | `writeDefaultConfig` + relaxed `validate()` |
| `2026-07-06-configurable-compaction.md` | ❌ | Per-profile Compaction tab — replaced by inline |
| `2026-07-07-compaction-inline.md` | ✅ | Inlined `max_capacity_tokens` / `compaction_threshold_percent` |
| `2026-07-21-local-memories-workspace-item.md` | ✅ | Local memories when clicking workspace item with path (#94) |

### 3.10 Frontend — Workspace / File Tree / Dialogs

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-06-12-workspace-drag-and-drop.md` | ✅ | HTML5 drag-and-drop reorder of workspaces |
| `2026-07-04-preview-panel-resize.md` | ✅ | Drag-resizable `PreviewSidePanel.vue` + localStorage (#75) |
| `2026-07-04-preview-panel-resize-design.md` | ✅ | Companion design |
| `2026-07-01-agent-show-preview.md` | ✅ | `show_preview` Zig tool + `<PreviewSidePanel>` + `<ShowPreview>` card (#55, #56) |
| `2026-07-01-agent-show-preview-design.md` | ✅ | Companion design |
| `2026-06-19-file-input-microphone.md` | ✅ | MicButton in FileInput + `/api/transcribe` |
| `2026-06-18-fix-glob-duplicate-results.md` | ✅ | `walkDir` dual-recursion 2^N fix |
| `2026-06-18-add-show-file-tool.md` | ❌ | Replaced by `show_preview` (2026-07-01) |

### 3.11 Frontend — Tool Output Components + Composition

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-06-30-enhance-frontend-tool-output.md` | ✅ | Shared `DiffView`/`ToolCardHeader` + 18 component migrations |
| `2026-07-01-is-input-output-bool-consistency.md` | ✅ | `is_input`/`is_output` → JSON boolean end-to-end (#60) |
| `2026-07-17-frontend-error-logs.md` | ✅ | Frontend errors → backend `logs` table (PR #105) |
| `2026-07-17-frontend-error-logs-design.md` | ✅ | Companion design |
| `2026-07-17-refactor-frontend-components-folder.md` | ✅ | 67 `.vue` files into 10 domain subdirs (PR #106) |
| `2026-07-17-refactor-frontend-components-folder-design.md` | ✅ | Companion design |

### 3.12 Desktop / Packaging / CI

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-06-10-nalar-desktop-app.md` | ✅ | `nalar-desktop` webview wrapper — Linux/macOS/Windows |
| `2026-06-10-desktop-webview-app-design.md` | ✅ | Companion design |
| `2026-06-10-nalar-static-dir.md` | ✅ | `--static-dir` flag + SPA fallback |
| `2026-07-04-nalar-desktop-ci-cd.md` | ✅ | 2-cell self-hosted CI matrix (#58) |
| `2026-06-28-multi-platform-ci-cd-pipeline.md` | ✅ | GitHub Actions matrix for Linux/Windows/macOS |

### 3.13 Testing / Tooling

| Plan | Status | Key file / PR |
|---|---|---|
| `2026-07-26-functional-tests-with-real-data.md` | ✅ | Functional tests with isolated `$HOME` (PR #128) |

### 3.14 Cross-Platform / Bash

(Plans here covered in §3.5; cross-platform sections in §3.1 SQLite, §3.4 LSP, §3.12 Desktop cover the rest.)

### 3.15 Web Search + Earlier Tooling

| Plan | Status | Key file / PR |
|---|---|---|
| `2025-01-15-tool-registry-envelope.md` | ✅ | `<tool>` envelope in `agentic_loop/tools.wrapToolOutput` |
| `2025-01-15-standardize-tool-output.md` | ❌ | No envelope, just `<success>`/`<error>` — superseded by envelope |
| `2025-01-15-tool-registry-refactor.md` | ❌ | Counter-proposal to envelope — superseded |
| `2025-03-27-change-agent-tool-rename.md` | ✅ | `change_agent.zig` + `prompts/memory.zig` |
| `2025-03-28-sessions-table.md` | ✅ | `Migration017CreateSessionsTable` |
| `2025-03-29-biomejs-linter-integration.md` | ✅ | Biome was adopted then DELETED in Bun tear-out; replaced by `oxlint`/`eslint` |
| `2025-03-31-session-queue-messages.md` | ✅ | `Migration018CreateSessionQueueMessages` |
| `2026-06-19-performance-indexes.md` | ✅ | SQLite index on `chat-list` + routine scheduler |
| `2026-06-10-virtual-scroller-buffer-fix.md` | ✅ | `+200` hardcoded overscan removed; `renderedCount` exposed |
| `2026-06-12-virtual-scroller-tall-item-scroll-jump.md` | 🗑️ | Per-item estimated-height callback never built |
| `2026-06-07-virtual-scroller-fixed-height.md` | 🟡 | Buffer/overscan fix landed; full fixed-item-height rewrite didn't |
| `2026-03-19-tui-read-file-display.md` | ✅ | TUI `[read_file]` filename display — though TUI itself was later removed |
| `2026-03-31-tree-dir-tool.md` | ❌ | Zig `tree_dir` removed; replaced with CLI wrapper |
| `2026-04-10-tool-parser-zig-tui-migration.md` | ❌ | TUI XML/tool parsers removed; logic now in `toolOutputParser.ts` |
| `2025-01-15-get-skill-relative-path-panic.md` | ✅ | `get_skill.zig` now accepts both absolute and relative paths |
| `2025-01-21-folder-picker-design.md` | ✅ | `FolderExplorer.vue` (commit `d9ce15aa`) |
| `2025-01-21-folder-picker.md` | ❌ | SolidJS + Electrobun version — replaced by Vue 3 |
| `2025-03-30-chatbox-design.md` | ✅ | Chat input bar; design-only doc |
| `2025-03-27-desktop-process-discovery-design.md` | 🗑️ | Old `desktop-bun` referencing `127.0.0.1:8080` — replaced by nalar-desktop service |

---

## 4. In-Progress Items (worktree branches, not yet merged)

| Plan | Block | Open piece |
|---|---|---|
| `2026-04-08-multifolder-session-dir.md` | Backend partial | `session_dirs: ?[][]const u8` array — only single `session_dir` filter shipped |
| `2026-06-20-compaction-output-long-context.md` | Done via different tool | `read_compacted_messages` → `search_history` |
| `2026-06-24-fix-compaction-envelope-id-mismatch.md` | Worktree branch | `36abea33` — real-DB-IDs + role-aware previews (worktree, not merged) |
| `2026-06-21-llm-stream-watchdog.md` | Worktree branch | `21ec4e92` — `StreamWatchdog` (worktree, not merged) |
| `2026-06-19-stop-notification.md` | Frontend toast | Backend OS-notification hook fired; frontend toast UI not built |
| `2026-06-04-full-type-only-bubbles.md` | ID-prefix removal | `streamingContent` refactor split; `streaming-` ID-prefix removal not fully done |
| `2026-06-16-streaming-ux-design.md` | UI deferred | Only `show_preview` part shipped; caret/blinking caret/think-block deferred |
| `2026-07-08-design-mode-deferred.md` | Deferred items | Marquee, smart-spacing, lock/hide, drag-into-frame |
| `2026-06-30-single-sse-all-sessions-design.md` | Migration in-flight | `sseBus` exists; individual call sites still need migration |
| `2026-06-01-load-more-before-edge.md` | Roll-up bookkeeping | Rolled into `chat-load-more-before-edge` merge without separate fix commit |
| `2026-04-04-search-tool-improvements.md` | Superseded | Covered by 2026-07-15 / 2026-07-16 plans |
| `2026-06-07-virtual-scroller-fixed-height.md` | Partial | Buffer/overscan fix landed; full fixed-item-height rewrite didn't |
| `2025-03-18-lsp-*-plans` | Different architecture | Session-based LSP client shipped (not 1-shot as planned); tools registered |
| `2025-03-27-session-messages-lazy-scroll.md` | Different frontend | Vue 3 VirtualScroller shipped (not SolidJS + TanStack Query as planned) |

---

## 5. Pending Items (still relevant, no implementation found)

| Plan | What it proposes | Why pending |
|---|---|---|
| `2026-06-18-set-git-worktree-cwd-override.md` | Runtime `cwd_override` for `bash`/`read_file`/etc after `set_git_worktree` | Field is dead-letter placeholder; project memory says "do NOT depend on this" |
| `2026-06-19-stop-notification.md` | Frontend toast when LLM generation stops | Backend hook only; in-app notifications not built |
| `2026-06-30-fix-kanban-drop-position.md` | Drop at cursor position, not column end | Plan committed; `KanbanColumn.handleDrop` still hardcodes position |
| `2025-01-13-read_file-hash-only.md` | `hash_only` read_file option for fast file checksums | Was added then REMOVED in a refactor — feature still relevant |
| `2025-01-13-text-replace-edge-cases.md` | Edge-case tests for `text_replace.zig` (escapes, unicode, control chars) | Test file exists but specific edge cases never added |
| `2025-01-15-sidebar-session-dir-filter.md` | Sidebar filter param wired to `session_dir` | `get_sessions_by_dir` exists in backend; UI never wired |
| `2026-07-30-kanban-task-tags-autocomplete.md` | Suggestions dropdown for `<KanbanTagsInput>` — top-N most-used tags, lazy fetch on focus, infinite-scroll, case-insensitive prefix filter | Plan landed but **not yet implemented**. See §3.7.4 for design. |

---

## 6. Superseded Plans (replaced by a follow-up plan that landed)

| Original Plan | Replaced by |
|---|---|
| `2025-01-15-standardize-tool-output.md` | `2025-01-15-tool-registry-envelope.md` (envelope approach) |
| `2025-01-15-tool-registry-refactor.md` | `2025-01-15-tool-registry-envelope.md` |
| `2025-01-21-folder-picker.md` | Vue 3 `FolderExplorer.vue` (commit `d9ce15aa`) |
| `2025-01-20-clay-declarative-dsl-design.md` | Whole Clay DSL abandoned; frontend rewrote to Vue 3 |
| `2026-06-06-workspace-item-task-pagination.md` | `2026-06-10-workspace-item-task-pagination.md` (v2) |
| `2026-06-11-messages-panel-extraction.md` | ChatView-only shape kept |
| `2026-06-11-tls-init-fast-fail.md` | `CallError = error{StreamTimeout, ...}` + `retry_delay_ms` after libcurl migration |
| `2026-06-30-unify-frontend-sse.md` | `2026-06-30-single-sse-all-sessions.md` (PR #51) |
| `2026-07-05-design-mode.md` | `2026-07-08-design-mode-redesign.md` (PR #90, Figma-lite) |
| `2026-07-06-configurable-compaction.md` | `2026-07-07-compaction-inline.md` |
| `2026-06-04-chat-lazy-load-button.md` | Rolled into `chat-load-more-before-edge` |
| `2026-06-05-stuck-connecting-badge.md` | `SseStatusBadge` state-machine rewrite (PR #48/#51) |
| `2026-06-18-add-show-file-tool.md` | `2026-07-01-agent-show-preview.md` (renamed/reshaped) |
| `2026-03-31-tree-dir-tool.md` | tree CLI wrapper |
| `2026-04-10-tool-parser-zig-tui-migration.md` | TUI removed; tool parser logic in `toolOutputParser.ts` |
| `2026-07-28-design-per-page-chat-sessions.md` | `2026-07-28-design-page-workspace-item-task-fk.md` (1:1 FK via `design_pages.workspace_item_task_id`) — name-pattern lookup eliminated entirely |
| `2026-07-29-constrain-design-elements-to-canvas.md` | `2026-07-29-remove-canvas-background.md` (concept of "canvas as boundary" was rejected by the user; the page is now a logical container, no rectangle is rendered, no clamp is applied) |

---

## 7. Not-Relevant Plans (refers to obsolete tech — kept for history)

| Plan | Why not relevant |
|---|---|
| `2025-01-13-sqlite-bun-drizzle.md` | Bun + Drizzle + `apps/desktop-bun/` — all obsolete (current SQLite is via Zig vendored amalgamation, no Drizzle) |
| `2025-01-20-desktop-moonfly-implementation.md` | Uno Platform + WinUI + C# Markup — replaced by Vue 3 + native webview |
| `2025-01-20-desktop-moonfly-design.md` | Uno Platform Moonfly design only — obsolete stack |
| `2025-03-27-desktop-process-discovery.md` | Scans `/proc/*/cmdline` via Bun runtime in `src/apps/desktop-bun/`; runtime is gone |
| `2025-03-27-desktop-process-discovery-design.md` | Same as above, design only |
| `2025-03-30-chatbox-implementation.md` | SolidJS + Tailwind v4 `ChatInput.tsx` — replaced by Vue 3 `ChatInput` |
| `2026-06-11-messages-panel-extraction.md` | `MessagesPanel.vue` never built; ChatView owns the wrapper |
| `2026-06-05-chatview-loading-overlay.md` | `LoadingOverlay.vue` reusable component never built |
| `2026-06-12-virtual-scroller-tall-item-scroll-jump.md` | Per-item estimated-height callback never built |

> **Note**: When the project's stack changed (Bun → Vue 3, SolidJS → Vue 3, nalar-desktop replacing WebView/WinUI), many plans became not-relevant even though their underlying feature survived under a different tool stack. The 2025 plans in `§7` are kept for historical context but should not be used as current implementation guidance.

---

## 8. Implementation-Plan → Spec Reference (renamed to dashboard)

The docs filesystem after the 2026-08-06 consolidation (the second round — first was 2026-07-26):

```
docs/
├── SPEC.md                        # ← this file (the single source of truth)
├── superpowers/
│   └── specs/                     # Pure design specs (the "why we do it") — 5 files
├── agent-tools.md                 # Tool registry reference
├── ci.md                          # CI pipeline layout
└── sse-reconnect-plan.md          # SSE auto-reconnect protocol (this file is still on disk — its content is summarized in §3.6 and the §10.2 inventory)
```

> **Heads-up**: `docs/plans/` and `docs/superpowers/plans/` (the original per-feature plan files) were deleted on 2026-07-26 (the original 178) and again on 2026-08-06 (the +17 from `2026-07-28-*` to `2026-08-06-*`). Their content is consolidated into §3, §5, §6, §10.2 of this SPEC.md. AGENTS.md tells every new agent to read SPEC.md first.

**`sse-reconnect-plan.md` carve-out**: this root-level doc is NOT a plan file (no per-feature implementation steps), it's a protocol reference for the SSE auto-reconnect subsystem — 4 `EventSource` connection sites enumerated with their current behavior (naive reconnect in `App.vue`, no reconnect in `ChatsList.vue` / `ChatView.vue` × 2 streams, stub in `Sidebar.vue`), and the planned fixes (exponential backoff + jitter, tab-visibility awareness, online/offline handling, max-retry cap, UI feedback, `onStateChange` channel). Kept on disk as a protocol reference; its high-level summary is in §3.6. Reclassification candidate: move to `docs/superpowers/specs/2026-07-31-sse-reconnect-design.md` in a future cleanup round.

**Rule of thumb**: when starting a new feature, look in `docs/SPEC.md` §3 first (the closest architectural neighbor), then `docs/superpowers/specs/` for design rationale, then `docs/ci.md` / `docs/agent-tools.md` / `docs/sse-reconnect-plan.md` for protocol details. Always check `§5 Pending` before proposing — you may be redoing something already planned.

---

## 9. Verification Methodology (how this spec was built)

For each plan file in the 178-file input set:

1. **Read** the first 30–50 lines to extract the goal, architecture, and key file paths.
2. **Search** `git log --all --grep` for matching commit messages (e.g. `fix(VirtualScroller): remove hardcoded +200 overscan`).
3. **Search** `git log --all -- <file>` for the affected source file paths.
4. **Grep** the current source tree for symbols, route paths, component names, and CLI flags mentioned in the plan.
5. **Cross-reference** `NALAR.md` changelog entries (which record "what landed" with a one-line summary).
6. **Classify** by the section in `§2` above.

> **Verification gap**: a few "✅ Implemented" results may have been partially overwritten by a later refactor. The git log traces the original ship; the current state may differ — re-check components before assuming the original implementation is still fully present. This is the project-wide discipline called out in `nalar-data-and-routines.md` (verify migrations, not just commit messages).

---

## 10. Appendices

### 10.1 PR / Issue index (landed plans)

```
#3   config: add sub_agents array to LlmConfig and LlmProfile
#8   Add Task Routines — backend
#9   Rename web_fetching_service → nalar_browser
#21  fix(sse): chunked encoding + Transfer-Encoding: chunked
#43  feat(kanban): SSE auto-move on kanban_task.*
#46  feat(kanban): kanban_move_task emits onEventSendKanbanTask
#48  feat(sse): unify 5 SSE routes → /api/events?channels=…
#50  feat(sub-agent): SubAgentPeekPanel + useSubAgentPeek
#51  feat(sse): single global EventSource + central broadcast
#52  fix(sse-manager): TOCTOU + heartbeat + POLL.NVAL
#55  feat(agent): show_preview tool + PreviewSidePanel
#56  feat(frontend): ShowPreview card component
#156 feat(agent): show_preview 'html' content_type (sandboxed iframe)
#57  feat(frontend): task variant: 'row' | 'card'
#58  ci: 2-cell nalar-desktop-build matrix
#60  refactor: is_input/is_output JSON boolean (#60)
#72  feat(svc): nalar service {start,stop,status,restart}
#75  feat(ui): drag-resizable PreviewSidePanel
#83  feat(search): edge-case hardenings
#85  feat(glob): edge-case hardenings
#89  feat(sqlite): Transaction struct
#93  feat(retry): configurable retry delay
#96  feat(search): respect_ignore_files
#98  feat(glob): respect_ignore_files
#101 feat(kanban): task detail dialog
#102 feat(kanban): add-task via detail dialog
#103 feat(session): auto-retry-until-stop
#104 feat(search): word_boundary/literal/only_matching
#105 feat(frontend): error logs → backend
#106 refactor(frontend): components folder reorg
#110 feat(desktop-app): native webview wrapper v1
#111 feat(kanban): lazy-load tasks
#114 feat(llm): end-user identifier UUID
#120 feat(http-client): libcurl wrapper
#123 feat(desktop): Preview/Edit mode
#123 feat(http-client): cross-platform (macOS/Windows)
#125 feat(design): element drag-and-drop (Figma-style)
#126 feat(design): wire tab-strip × button delete
#128 feat(tests): functional tests with real data
#136 feat(design): grouped layers (frame/group nesting) on design canvas
#138 feat(design): per-page chat sessions (each design page → one task)
#139 feat(design): 1:1 FK design_pages.workspace_item_task_id
#140 feat(design): remove canvas background (no visible rectangle, no clamps)
#141 feat(design): element-level undo/redo (Cmd+Z / Cmd+Shift+Z / Cmd+Y)
#142 feat(design): drag debounce batch (5× reduction for multi-element drag)
#143 feat(design): resize handles pointerdown bubble fix
#144 feat(kanban): task tags (free-form string list, JSON column)
#146 feat(kanban): task search (server-side ?q= filter)
#147 feat(design): element parent_id tooling (set_parent + add_element.parent_id)
#148 feat(agent): create_kanban_task tool (LLM can create kanban tasks)
#149 feat(workflow): better compaction context (enriched XML envelope)
#150 feat(design): right-click group/ungroup menu (Cmd+Shift+G ungroup)
#151 feat(design): layer drag-to-join-or-leave-group (Figma-style)
#153 feat(chat): scroll position persistence (close → reopen keeps scroll)
#154 feat(kanban): task notification icon (orange dot / green check)
#155 feat(service): OS-level crash signal handler (POSIX + Win32)
#156 feat(agent): show_preview 'html' content_type (sandboxed iframe)
#157 feat(config): set_active_profile default
#158 feat(profile): chatview profile persists across page refresh
#TBD feat(kanban): Create task & run agent (this PR)
```

### 10.2 Plan file inventory (all 178 files)

#### 10.2.1 `docs/superpowers/plans/` (107 files) — **DELETED 2026-07-26**

The 107 implementation plans once held here have been consolidated into this SPEC.md. Below is the historical inventory — kept for grep-ability and traceback to the original commit that shipped each plan. (The files themselves are gone; this is a one-line summary per file.)

```
2025-01-13-read_file-hash-only                 ⏳ feature still relevant
2025-01-13-sqlite-bun-drizzle                  🗑️ obsolete tech
2025-01-13-text-replace-edge-cases             ⏳ feature still relevant
2025-01-15-sidebar-session-dir-filter          ⏳ backend exists, UI not wired
2025-01-15-standardize-tool-output             ❌ superseded by envelope
2025-01-15-tool-registry-envelope              ✅ landed
2025-01-15-tool-registry-refactor              ❌ superseded by envelope
2025-01-20-desktop-moonfly-implementation      🗑️ obsolete stack
2025-01-21-folder-picker                       ❌ superseded by Vue 3 FolderExplorer
2025-03-18-lsp-definition-simple               🟡 session-based, not 1-shot
2025-03-18-lsp-definition-tdd-simple           🟡 tests landed
2025-03-18-lsp-tools-integration               🟡 5 tools registered
2025-03-18-lsp-tools-tdd-testcases             🟡 tests landed
2025-03-27-change-agent-tool-rename            ✅ landed
2025-03-27-desktop-process-discovery           🗑️ obsolete (Bun-runtime)
2025-03-27-session-messages-lazy-scroll        🟡 different frontend stack
2025-03-28-sessions-table                      ✅ Migration017
2025-03-29-biomejs-linter-integration          ✅ installed then removed
2025-03-30-chatbox-implementation              🗑️ SolidJS — replaced by Vue 3
2025-03-31-session-queue-messages              ✅ Migration018
2025-04-03-web-search-tools-design             ✅ web_search.zig
2026-01-15-llm-completion-notification         ✅ OS notification
2026-03-17-add-is-input-is-output-columns      ✅ Migration016
2026-03-19-tui-read-file-display               ✅ TUI existed, then removed
2026-03-31-tree-dir-tool                       ❌ replaced by tree CLI wrapper
2026-04-08-multifolder-session-dir             🟡 single dir only
2026-04-10-tool-parser-zig-tui-migration       ❌ TUI removed
2026-05-02-bash-max-lines-truncation           ✅ landed
2026-05-14-spawn-sub-agent-inherited-context-ui ✅ landed
2026-06-03-session-profile-selection           ✅ landed
2026-06-04-sqlite-indexes-for-performance      ✅ Migration041
2026-06-05-chatview-loading-overlay            🗑️ never built
2026-06-05-delete-profile                      ✅ landed
2026-06-05-sidebar-mutually-exclusive-active-state ✅ landed
2026-06-06-load-more-before-edge               ✅ landed
2026-06-08-sse-client-ids-use-after-free       ✅ lock + owned copy
2026-06-09-remove-get-skill-name-parameter     ✅ landed
2026-06-09-spawn-sub-agent-inherited-context   ✅ landed
2026-06-10-nalar-desktop-app                   ✅ landed
2026-06-10-nalar-static-dir                    ✅ landed
2026-06-10-virtual-scroller-buffer-fix         ✅ landed
2026-06-11-messages-panel-extraction           🗑️ never built
2026-06-11-nalar-config-url-style              ✅ landed
2026-06-11-sub-agents-config-field             ✅ landed
2026-06-11-tls-init-fast-fail                  ❌ replaced by CallError
2026-06-11-workspace-item-tasks-sort-by-updated-at ✅ Migration042
2026-06-12-virtual-scroller-tall-item-scroll-jump 🗑️ never built
2026-06-12-web-fetching-service-to-nalar-browser ✅ renamed
2026-06-13-add-task-routines                   ✅ landed (PR #8)
2026-06-13-add-task-routines-chunk-4          ✅ HTTP handlers
2026-06-13-add-task-routines-chunks-2-3       ✅ in-process fire
2026-06-13-add-task-routines-chunks-5          ✅ frontend types
2026-06-13-add-task-routines-chunks-5-7       ✅ frontend index
2026-06-13-add-task-routines-chunks-6         ✅ dialogs
2026-06-13-add-task-routines-chunks-6-tests   ✅ spec files
2026-06-13-add-task-routines-chunks-7         ✅ task row + sidebar
2026-06-16-workspace-item-position-reorder     ✅ Migration045
2026-06-17-nalar-browser-tool-output-component ✅ landed
2026-06-19-api-error-notification              ✅ NotificationContainer
2026-06-19-fix-sse-incomplete-chunked-encoding ✅ landed (#21)
2026-06-19-stop-notification                   ⏳ backend only, frontend pending
2026-06-20-compaction-output-long-context      🟡 tool renamed
2026-06-20-pinned-workspace-item-tasks         ✅ Migration050
2026-06-21-workspace-item-kanban               ✅ landed
2026-06-26-fix-kanban-list-empty-add-sse       ✅ landed
2026-06-27-kanban-column-description-settings  ✅ Migration053
2026-06-27-kanban-sse-auto-move                ✅ landed (#43)
2026-06-29-kanban-move-task-sse-emit           ✅ landed (#46)
2026-06-29-sub-agent-peek-progress             ✅ landed (#50)
2026-06-30-edit-workspace-item-name            ✅ landed
2026-06-30-fix-kanban-drop-position            ⏳ cursor drop position not wired
2026-06-30-fix-sse-blocking-api                ✅ landed
2026-06-30-fix-sse-fd-leak                     ✅ landed (#52)
2026-06-30-single-sse-all-sessions             ✅ landed (#51)
2026-06-30-unify-frontend-sse                  ❌ superseded by single-sse
2026-06-30-unify-sse-endpoints                 ✅ landed (#48)
2026-07-01-agent-show-preview                 ✅ landed (#55, #56)
2026-07-02-auto-init-config                    ✅ landed
2026-07-03-decoupled-nalar-service             ✅ landed (#72)
2026-07-04-copy-kanban-spec                    ✅ landed
2026-07-04-nalar-desktop-ci-cd                 ✅ landed (#58)
2026-07-04-preview-panel-resize                ✅ landed (#75)
2026-07-05-design-mode                         ❌ superseded by redesign
2026-07-06-configurable-compaction             ❌ superseded by inline
2026-07-07-compaction-inline                   ✅ landed
2026-07-08-design-mode-redesign                ✅ landed (PR #90)
2026-07-08-glob-edge-cases                     ✅ landed (#85)
2026-07-08-search-edge-cases                   ✅ landed (#83)
2026-07-10-empty-workspace-item-bug            ✅ landed
2026-07-12-sqlite-tx-support                   ✅ landed (PR #89)
2026-07-15-glob-respect-ignore-files           ✅ landed (#98)
2026-07-15-retry-delay                         ✅ landed (PR #93)
2026-07-15-search-respect-ignore-files         ✅ landed (#96)
2026-07-16-kanban-task-detail-dialog           ✅ landed (#101)
2026-07-16-search-add-rg-flags                 ✅ landed (#104)
2026-07-16-search-history-rewrite              ✅ landed
2026-07-16-session-auto-retry-until-stop       ✅ landed (#103)
2026-07-17-frontend-error-logs                 ✅ landed (PR #105)
2026-07-17-refactor-frontend-components-folder ✅ landed (PR #106)
2026-07-19-design-hand-pan-mode                ✅ landed
2026-07-21-local-memories-workspace-item       ✅ landed (#94)
2026-07-22-kanban-add-task-via-detail-dialog   ✅ landed (#102)
2026-07-23-preserve-kanban-horizontal-scroll    ✅ landed
2026-07-24-bash-tool-pipe-leak                 ✅ landed
2026-07-24-kanban-lazy-load-tasks              ✅ landed (#111)
2026-07-25-custom-http-client-libcurl          ✅ landed (#120, #123)
2026-07-25-design-element-drag-and-drop        ✅ landed (#125)
2026-07-25-design-page-delete-button           ✅ landed (#126)
2026-07-25-kanban-description-rich-editor      ✅ landed (#124)
2026-07-25-llm-user-identifier                 ✅ landed (#114)
2026-07-26-functional-tests-with-real-data     ✅ landed (PR #128)
2026-07-26-kanban-task-notification-icon        ✅ landed (PR #132)
```

#### 10.2.2 `docs/plans/` (71 files — design docs) — **DELETED 2026-07-26**

The 71 design documents once held here have been consolidated into this SPEC.md. Below is the historical inventory — kept for grep-ability and traceback. (The files themselves are gone.)

```
2025-01-15-get-skill-relative-path-panic       ✅ landed
2025-01-20-clay-declarative-dsl-design         ❌ Clay DSL abandoned
2025-01-20-desktop-moonfly-design             🗑️ obsolete stack
2025-01-21-folder-picker-design               ✅ landed (FolderExplorer.vue)
2025-03-27-desktop-process-discovery-design   🗑️ obsolete (Bun-runtime)
2025-03-30-chatbox-design                     ✅ design doc (Vue 3 implementation)
2026-04-04-search-tool-improvements           🟡 covered by 2026-07-15/16 plans
2026-04-08-multifolder-session-dir-design     ✅ design doc (backend partial)
2026-05-14-spawn-sub-agent-inherited-context-ui-design ✅ design doc
2026-06-04-chat-lazy-load-button              ❌ superseded by load-more-before-edge
2026-06-04-full-type-only-bubbles             🟡 partial
2026-06-05-stuck-connecting-badge             ❌ folded into SSE refactor
2026-06-05-workspaces-items-endpoint          ✅ landed
2026-06-06-workspace-item-task-pagination     ❌ superseded by 2026-06-10 v2
2026-06-06-workspace-item-task-rename         ✅ landed
2026-06-07-virtual-scroller-fixed-height      🟡 partial
2026-06-09-scroll-logger-no-container-rename  ✅ landed
2026-06-09-spawn-sub-agent-inherited-context-design ✅ design doc
2026-06-10-bash-cross-platform                ✅ landed
2026-06-10-desktop-webview-app-design         ✅ design doc
2026-06-10-local-cwd-memories-in-prompt       ✅ landed
2026-06-10-scroll-ratcheting-fix              ✅ landed
2026-06-10-workspace-item-task-pagination     ✅ landed (v2)
2026-06-11-messages-panel-extraction-design   ❌ MessagesPanel.vue never built
2026-06-12-web-fetching-service-to-nalar-browser-design ✅ design doc
2026-06-12-workspace-drag-and-drop            ✅ landed
2026-06-13-add-task-routines-design           ✅ design doc
2026-06-15-spawn-sub-agent-config             ✅ landed
2026-06-16-streaming-ux-design                🟡 partial
2026-06-17-add-memories-settings-menu         ✅ landed
2026-06-17-nalar-settings-revamp              ✅ landed
2026-06-17-nalar-settings-revamp-design       ✅ design doc
2026-06-18-add-show-file-tool                 ❌ replaced by show_preview
2026-06-18-create-worktree-menu-option        ✅ landed
2026-06-18-fix-glob-duplicate-results         ✅ landed
2026-06-18-git-worktree-cwd-pr                ✅ landed
2026-06-18-set-git-worktree-cwd-override      ⏳ field is dead-letter placeholder
2026-06-18-set-git-worktree-tool              ✅ landed
2026-06-19-api-error-notification-design      ✅ design doc
2026-06-19-file-input-microphone              ✅ landed
2026-06-19-performance-indexes                ✅ landed
2026-06-19-stop-notification-design           🟡 backend done, frontend pending
2026-06-19-workspace-siblings-in-prompt       ✅ landed
2026-06-20-set-git-worktree-path-already-exists ✅ landed
2026-06-20-worktree-path-collision-recovery   ✅ landed
2026-06-21-llm-stream-watchdog                🟡 on worktree branch
2026-06-21-workspace-item-kanban-design       ✅ design doc
2026-06-24-fix-compaction-envelope-id-mismatch 🟡 on worktree branch
2026-06-27-kanban-status-prompt               ✅ landed
2026-06-28-multi-platform-ci-cd-pipeline      ✅ landed
2026-06-30-enhance-frontend-tool-output       ✅ landed
2026-06-30-single-sse-all-sessions-design     🟡 migration in-flight
2026-06-30-unify-frontend-sse                 ❌ superseded by single-sse
2026-07-01-agent-show-preview-design          ✅ design doc
2026-07-01-change-task-to-card-kanban         ✅ landed (#57)
2026-07-01-is-input-output-bool-consistency   ✅ landed (#60)
2026-07-03-decoupled-nalar-service-design     ✅ design doc
2026-07-04-preview-panel-resize-design        ✅ design doc
2026-07-05-design-mode-design                 ❌ superseded by redesign
2026-07-08-design-mode-deferred               🟡 deferred items
2026-07-08-design-mode-redesign-design        ✅ design doc
2026-07-15-glob-respect-ignore-files-design   ✅ design doc
2026-07-15-search-respect-ignore-files-design ✅ design doc
2026-07-17-frontend-error-logs-design         ✅ design doc
2026-07-17-refactor-frontend-components-folder-design ✅ design doc
2026-07-19-design-preview-mode-design         ✅ design doc
2026-07-25-llm-user-identifier-design         ✅ design doc
```

#### 10.2.3 `docs/superpowers/plans/` (17 files) — **DELETED 2026-08-06**

The 17 implementation plans added between 2026-07-28 and 2026-08-06 have been consolidated into this SPEC.md. Below is the historical inventory — kept for grep-ability and traceback. (The files themselves are gone.)

```
2026-07-28-kanban-task-tags                    ✅ NEW §3.7.3 + Migration 067
2026-07-28-design-page-workspace-item-task-fk  ✅ already in §3.8 (Migration 066) — from prior round
2026-07-28-design-per-page-chat-sessions       ❌ NEW ❌ entry in §6 (superseded by FK version above)
2026-07-29-constrain-design-elements-to-canvas ❌ NEW ❌ entry in §3.8 + §6 (superseded by remove-canvas-background)
2026-07-29-remove-canvas-background            ✅ already in §3.8 (above) — from prior round
2026-07-29-create-kanban-task-tool            ✅ NEW in §3.2 (create_kanban_task LLM tool)
2026-07-29-design-element-parent-id-tools     ✅ NEW in §3.8 (3 compounding tool gaps)
2026-07-29-design-right-click-group-menu      ✅ NEW in §3.8 (context menu + reorder endpoint)
2026-07-29-fix-retry-delay-ms-race             ✅ NEW in §3.2 (1-line @max clamp)
2026-07-30-better-compaction-context          ✅ NEW in §3.2 (<user_history> + <read_files>)
2026-07-30-design-drag-debounce-batch         ✅ already in §3.8 (above) — from prior round
2026-07-30-design-layer-drag-join-or-leave-group ✅ NEW in §3.8 (POST .../reparent-batch)
2026-07-30-design-undo-redo                    ✅ already in §3.8 (above) — from prior round
2026-07-30-fix-design-resize-handles-bubble-bug ✅ NEW in §3.8 (stopPropagation in startDrag)
2026-07-30-kanban-task-search                  ✅ already in §3.7 (server-side ?q=) — from prior round
2026-07-30-kanban-task-tags-autocomplete       ⏳ NEW ⏳ entry in §3.7.4 + §5 (designed but not built)
2026-08-06-chat-scroll-position-persistence    ✅ already in §3.6 (above) — from prior round

NEW entries in this round: 8 ✅ + 2 ❌ + 1 ⏳ = 11 entries total.
Already-consolidated: 6 plans were folded into existing rows in §3 of this SPEC.md.
The net addition to §3 / §5 / §6 of this SPEC is 11 rows.
```

#### 10.2.4 `docs/superpowers/specs/` (5 files) — **DELETED 2026-08-06**

The 5 design specs at consolidation time. Their content is folded into the corresponding plan rows above + §3.7.3 (kanban task tags design rationale) + §3.8 (right-click group menu, undo/redo, chat scroll position design). The one surviving protocol spec is `docs/sse-reconnect-plan.md` (kept on disk as a non-plan reference).

```
2026-06-07-virtual-scroller-preserve-fix      ✅ design folded into §3.6 (already shipped)
2026-07-28-kanban-task-tags-design             ✅ design rationale in §3.7.3
2026-07-29-design-right-click-group-menu      ✅ design rationale in §3.8 row
2026-07-30-design-undo-redo                    ✅ design rationale in §3.8 row
2026-07-30-kanban-task-search-design           ✅ design rationale in §3.7.2
```

#### 10.2.5 `docs/sse-reconnect-plan.md` (root) — **KEPT, NOT DELETED**

This is a protocol reference (not a per-feature implementation plan). Its 4 `EventSource` connection sites + planned auto-reconnect protocol are referenced in §3.6 (the row above the new entries). Reclassification candidate: move to `docs/superpowers/specs/2026-07-31-sse-reconnect-design.md` in a future cleanup round.

---

## 11. Where to go next

1. **For new contributors**: Read `AGENTS.md` (project conventions), then `§1.1` (tech stack), then `§3` (what's built). Pick a `§5 Pending` item to start.
2. **For new features**: Look at `§3` for the closest architectural neighbor, then update this SPEC.md (`§3`, `§5`, `§10.1`) with the new feature's status — the spec is the single source of truth that replaces the old per-feature plan files.
3. **For refactors**: See `nalar-backend-architecture.md`, `nalar-frontend-patterns.md`, `nalar-data-and-routines.md` in `.nalar/memories/`.
4. **For cross-platform work**: See `zig-cross-platform.md` and `AGENTS.md` "Cross-platform matrix" section.
5. **For bugs**: Check `§5 Pending` first — the project already has plans for many latent bugs.

**Always verify before merge**: every implementation must pass `zig build test`, `zig build install:linux:system`, `rm -rf zig-out/bin && zig build`, `cd src/apps/desktop && bun run build && bunx vitest run`, and `pytest tests/functional/`. See `AGENTS.md` "Pre-commit checklist".
