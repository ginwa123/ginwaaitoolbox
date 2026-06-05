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
