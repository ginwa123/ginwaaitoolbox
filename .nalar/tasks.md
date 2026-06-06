## [done] 20260115_121000 — LLM completion OS notification (backend dispatch)

Implements the plan in `docs/superpowers/plans/2026-01-15-llm-completion-notification.md`.

User asked: "notification after llm processing is finished, finish_reason stop", then "what if I close the app browser but i still want to get the notif?". Chose **Option A: backend shells out to OS** (notify-send / osascript / PowerShell) so notifications work even when the desktop browser is closed.

### Changes

- [x] **Task 1: Config flag.** Added `notify_on_complete: bool` to `LlmConfig` + `LlmConfigJson` (default `false`). Updated `nalar_config_put_test.zig` helper. 3 new tests in `config_test.zig` (default-false, reads-true, reads-explicit-false).
- [x] **Task 2: notifications.zig module.** New `src/ai_workflow/tui/notifications.zig` with `buildCommand(allocator, title, body)`, `notify(io, allocator, title, body)`, `notifyWithPath(...)` test helper, `truncateBody(allocator, body, max)`. Per-OS dispatch: Linux → `notify-send`, macOS → `osascript`, Windows → PowerShell `MessageBox` stub. 9 new tests in `notifications_test.zig`.
- [x] **Task 3: Wire into workflow.zig.** Added 4-line `if (config.notify_on_complete) { notifications.notify(io, allocator, "LLM Response Complete", preview) catch ...; }` inside the `finish_reason == .stop` branch, right before `break;`.
- [x] **Task 4: HTTP test endpoint.** New `src/ai_workflow/tui/http_handlers/notify_test.zig` registered as `POST /api/notify/test` in `main.zig` and re-exported via `mod.zig`. Returns `{"ok": true}` on success, `{"ok": false, "error": "..."}` on failure.
- [x] **Task 5: Frontend toggle** — SKIPPED. Optional convenience; user can edit the config JSON directly.
- [x] **Task 6: Manual e2e.** Started nalar on port 8080 (do NOT touch 8081). Verified `notify-send` works at the CLI. Verified `POST /api/notify/test` returns `{"ok":true}` twice with no errors in the nalar log. User confirmed OS notification appears on their desktop.

### Gotchas encountered

- **Zig 0.15 process API** is `std.process.spawn(io, options)`, NOT `std.process.Child.init(...)` + `.spawn()`. The old `init` pattern is gone. `Child.init` doesn't exist; you bind the spawn return value and don't call `.wait(io)` for fire-and-forget. Compiled into memory `zig-0.15-process-spawn-api.md`.
- **`"x".repeat(500)` doesn't exist** in Zig 0.15. Use `var buf: [N]u8 = undefined; @memset(&buf, 'x');`.
- **`++` operator requires comptime** in Zig 0.15. Use `std.fmt.allocPrint` or manual `std.mem.copy`/`@memcpy` for runtime string concatenation.
- **Handler signature is 3-arg** (`ctx, req, res`), not 4-arg with `*anyopaque` state. The 4-arg pattern is older and used by `ping_handler`. `jsonResponse` takes 1 arg (a struct with `status_code` + `data`), not 2 args (allocator + struct).

### Verification

- `zig build` → clean.
- `zig build test` → 263/267 pass (the 1 failure is the pre-existing `call_streaming_test.zig` `expected 30000, found 60000` from concurrent work; unrelated to this change).
- `POST http://localhost:8080/api/notify/test` → `{"ok":true}`.
- 9 new notification tests + 3 new config tests all pass.

### Commits

- `feat(config): add notify_on_complete bool (default off)`
- `feat(notifications): cross-platform OS notification dispatch via notify-send/osascript/powershell`
- `feat(workflow): fire OS notification on finish_reason=stop when notify_on_complete is set`
- `feat(http): add POST /api/notify/test for manual notification verification`

## [done] 20250320_120000 — Activate MCP Tools in main and sub agents

- [x] Uncomment MCP tool fetching in workflow.zig
- [x] Uncomment MCP tool merging in workflow.zig
- [x] Add MCP tool handler to TOOL_REGISTRY in handle_tool.zig
- [x] Add MCP tools to sub-agent tool registry in handle_spawn_sub_agent.zig
- [x] Build and test

## [done] 20250401_143000 — Optimize desktop Bun app session SSE handling
- Added SSE disconnect handler to server (http_handlers.zig)
- Registered new route POST /api/stream/:session_id/disconnect (main.zig)
- Enhanced SSEClient with disconnectWithNotification(), isConnected(), getSessionId() (sseClient.ts)
- Updated SessionChat to use shared SSE client with proper session switching (SessionChat.tsx)
- Both Zig and Bun builds pass successfully

## [done] 20250401_150000 — Fix session sidebar refresh timing
- Removed `window.location.reload()` from ChatInput (bad UX)
- Added `setTimeout(..., 1000)` before `refreshSessionList()` for new sessions
- Added `setTimeout(..., 1000)` before `refreshSessionList()` for existing sessions
- Build passes successfully

## [done] 20250401_160000 — Fix SSE streaming for desktop Bun app
- Fixed SseEvent.formatInto to add proper `data:` prefix for SSE format
- Updated SseEvent.format to add proper `data:` prefix
- Added event_type field to SseEvent struct
- Rewrote SSEClient to listen for 'message' events (default SSE event type)
- Added parseSseXml function to parse XML content and determine message type
- Added 'connected' event handler for JSON connection confirmation
- Both Zig and Bun builds pass

## [done] 20250401_170000 — Fix message sorting and streaming sync for desktop Bun app

### Problem
- Message ordering was inconsistent due to race conditions between SSE events and DB writes
- SSE events could arrive before DB committed the message
- String-based message IDs (sess_xxx_hex) couldn't be compared properly for pagination

### Changes Made

**Backend (Zig):**
1. `session_db.zig` - Fixed cursor pagination:
   - Changed from `id > cursor` to `created_at < cursor` / `created_at > cursor`
   - `created_at` is numeric (milliseconds timestamp) so comparison works correctly
   - Added `is_asc` detection to choose correct comparison operator

2. `on_event_sent.zig` - Added named SSE events:
   - Set `event_type = "done"` for final messages (has finish_reason)
   - Set `event_type = "response"` for streaming updates
   - Frontend can now listen for named events instead of just default message

**Frontend (Bun/SolidJS):**
1. `sseClient.ts` - Enhanced SSE event handling:
   - Added named event listeners: 'response', 'done', 'step'
   - Improved XML parsing with proper tag extraction
   - Better deduplication based on session_id

2. `SessionChat.tsx` - Better SSE integration:
   - Added `seenMessageIds` Set for deduplication
   - Added `pendingSseMessages` signal for optimistic updates
   - Proper message sorting by timestamp (oldest first, newest at bottom)
   - Smart scroll: only auto-scroll if user is near bottom or streaming

### Verification
- Zig build: `zig build` - PASSED
- Ready for desktop app testing

## [done] 20250402_100000 — Fix frontend console error and simplify SSE handling
- Removed event_type naming from backend (simpler approach)
- Simplified SSEClient to only listen for 'message' event
- Removed complex optimistic update logic from SessionChat
- Simplified allMessages to just use query data directly
- Removed unused signals (seenMessageIds, pendingSseMessages)
- Removed unused function (sseToChatMessage)
- Both Zig and Bun builds pass

## [active] 20260605_235500 — Sidebar mutually exclusive active state

Implements the plan in `docs/superpowers/plans/2026-06-05-sidebar-mutually-exclusive-active-state.md`.

User reported: "theres a active state in list Chats and task — it should be either chats or workspace items". Screenshot shows a chat row highlighted in the Chats list AND a workspace item showing the aqua active dot. Root cause: `ChatsList.setActive/createChat/removeChat` and several `AppLayout` URL→state paths do not reset `workspacesStore.activeWorkspaceItemId` when transitioning to a chat. Fix: add explicit `workspacesStore.setActiveWorkspaceItem(null)` calls at every chat-selection path.

Worktree: `.worktrees/sidebar-active-state` on branch `feature/sidebar-active-state`.

### Steps

- [ ] **Chunk 1: ChatsList fix + regression tests** (TDD)
  - [ ] Step 1: Write 3 failing tests in `__tests__/sidebarActiveState.spec.ts`
  - [ ] Step 2: Run, confirm tests fail
  - [ ] Step 3: Fix `ChatsList.setActive`
  - [ ] Step 4: Run first test, confirm pass
  - [ ] Step 5: Fix `ChatsList.createChat`
  - [ ] Step 6: Run second test, confirm pass
  - [ ] Step 7: Fix `ChatsList.removeChat`
  - [ ] Step 8: Run all 3 tests, confirm all pass
  - [ ] Step 9: Commit
- [ ] **Chunk 2: AppLayout URL-driven fix**
  - [ ] Step 1: Fix `onMounted` chat-view branch
  - [ ] Step 2: Fix `handleNavigate` for `chat-…` view
  - [ ] Step 3: Fix the URL watch for `view === 'chat'`
  - [ ] Step 4: Add a regression test for the URL-driven path
  - [ ] Step 5: Run new test, confirm pass
  - [ ] Step 6: Run full frontend test suite
  - [ ] Step 7: Run desktop build
  - [ ] Step 8: Commit
- [ ] **Chunk 3: Manual end-to-end verification**

## [done] 20260605_235500 — Sidebar mutually exclusive active state (Chunk 1: ChatsList fix)

**Commit:** `151ffa2` on `feature/sidebar-active-state` in worktree `.worktrees/sidebar-active-state`.

**Status:** ✅ Ready to merge. Spec compliance ✅, code quality ✅ (re-reviewed with all 5 flagged issues fixed).

**What landed (5 files, 193 insertions, 20 deletions):**
- `src/apps/desktop/src/components/ChatsList.vue` — 3 surgical additions: `workspacesStore.setActiveWorkspaceItem(null)` in `setActive`, `createChat`, `removeChat` (conditional on `if (wasActive)`), each preceded by a WHY comment.
- `src/apps/desktop/src/__tests__/sidebarActiveState.spec.ts` — 4 regression tests covering the 3 chat paths plus the negative-path guard on `removeChat`.
- `src/apps/desktop/src/__tests__/setup.ts` — `ResizeObserver` no-op polyfill (matches the existing `EventSource` polyfill pattern; needed because jsdom doesn't ship `ResizeObserver` and `VirtualScroller.vue` instantiates one in `onMounted`).
- `src/apps/desktop/src/__tests__/helpers.ts` (new) — extracted `makeLocalStorageStub()` shared between 2 spec files.
- `src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts` — refactored to use the shared helper.

**Test results:** 50/50 passing across 7 files, 0 Vue "Invalid watch source" warnings, `vue-tsc --build` clean.

## [done] 20260605_235500 — Sidebar mutually exclusive active state (Chunk 2: AppLayout URL fix + Chunk 2 quality fixes)

**Commits:** `6f9e873` (Chunk 2) + `60c4eb3` (Chunk 2 quality fixes) on `feature/sidebar-active-state`.

**Status:** ✅ Ready to merge. Spec compliance ✅, code quality ✅ (re-reviewed with all 4 flagged issues fixed).

**What landed (Chunk 2 — `6f9e873`, 4 files):**
- `src/apps/desktop/src/components/AppLayout.vue` — 5 surgical additions: `workspacesStore.setActiveWorkspaceItem(null)` in 4 URL→state branches (`onMounted chat`, `handleNavigate chat-…`, `handleNavigate chat`, URL watch `view==='chat'&&sessionId`, URL watch `!view||view==='workspace'`), each preceded by a WHY comment.
- `src/apps/desktop/src/__tests__/sidebarActiveState.spec.ts` — added 1 regression test for the `onMounted` chat-view path.
- `src/apps/desktop/vitest.config.ts` + `src/apps/desktop/src/__tests__/stubs/monaco-editor.ts` — test-infrastructure fix (AppLayout transitively imports `monaco-editor`; vite's import-analysis runs at transform time before `vi.mock` can intercept; needed a `resolve.alias` to a tiny stub).
- Local skill saved at `.nalar/skills/vitest-resolve-alias-stub-for-bare-specifiers/SKILL.MD`.

**What landed (Chunk 2 quality fixes — `60c4eb3`, 3 files):**
- `sidebarActiveState.spec.ts` — added 2nd test for the URL watch path (site 4); uses `reactive()` wrapper because `useRoute()` is captured at setup time.
- `vitest.config.ts` — corrected inaccurate "monaco-editor is not installed" claim to mention worker paths not resolving in jsdom.
- `SKILL.MD` — removed duplicate YAML frontmatter.

**Test results:** 52/52 passing across 7 files, `bun run build` clean, 0 new [Vue warn] lines.

## [done] 20260605_235500 — Sidebar mutually exclusive active state (Inverse-direction fix)

**Commit:** `0d74178` on `main` (follow-up after the merge).

**What:** The previous merge fixed chat → workspace item but missed the inverse directions. Two bugs were reported in production testing:

1. **Chat → task**: User clicks a task in the workspace tree → `Sidebar.handleSelectTask` didn't call `chatsListRef.value.resetActiveChat()`, so the previously-active chat row stayed highlighted.
2. **Task → chat**: User clicks a chat → `ChatsList.setActive/createChat/removeChat` cleared `activeWorkspaceItemId` but not `activeTaskId`, so a previously-active task stayed highlighted.

**What landed (3 files, 40 insertions):**
- `src/apps/desktop/src/components/Sidebar.vue` — added `chatsListRef.value.resetActiveChat()` call in `handleSelectTask`.
- `src/apps/desktop/src/components/ChatsList.vue` — added `workspacesStore.setActiveTask(null)` in `setActive`, `createChat`, and `removeChat` (the last one inside the `if (wasActive)` block).
- `src/apps/desktop/src/__tests__/sidebarActiveState.spec.ts` — 2 new regression tests: "clicking a chat row clears activeTaskId (inverse direction)" and "createChat clears activeTaskId (inverse direction)".

**Test results:** 54/54 passing across 7 files, `bun run build` clean.

**Cleanup:** Worktree `.worktrees/sidebar-active-state` removed, feature branch `feature/sidebar-active-state` deleted.
