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
