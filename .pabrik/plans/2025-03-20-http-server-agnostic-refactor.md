# HTTP Server Agnostic Refactor Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `http_server.zig` into a pure transport layer that is completely agnostic to application logic. All kerjabot and TUI-specific handlers, routes, and imports will be moved out.

**Architecture:** Three-layer design:
1. **Transport Layer** (`http_server.zig`) — Pure HTTP/SSE/polling transport, no application logic
2. **Routing Layer** — Caller registers routes via callback interface
3. **Handler Layer** — Application handlers in separate modules (kerjabot, tui, etc.)

**Tech Stack:** Zig 0.15.2, httpz

---

## Phase 1: Exploration & Design (COMPLETED)

**Findings:**
| Finding | Evidence | Action |
|---------|----------|--------|
| Kerjabot handlers (485-689) couple to kerjabot modules | `kerjabot_create_session`, `kerjabot_get_session`, `kerjabot_get_list_session` | Extract to `kerjabot_http_handlers.zig` |
| TUI handlers (394-460) couple to pabrikcore session helpers | `tui_check_session_exists`, `session_helpers.getLatestSessionByDir` | Extract to `tui_http_handlers.zig` |
| Inline `@import("pabrikcore")` in handler functions (404, 430) | Runtime import anti-pattern | Remove by using injected interfaces |
| Top-level imports (3-6) couple to pabrikcore | `sqlite`, `kerjabot_*` imports | Remove from http_server.zig |
| SSE ConnectionManager (89-239) is TUI-scoped | Session-based SSE with TUI context | Keep in transport layer (generic) |
| Global server pattern (245, 248) | `global_server`, `getGlobalSseManager()` | Convert to injectable interface |
| Hardcoded routes in `runWithConfig` | `HttpRoutes` struct with inline setup | Move to caller via route registration |

---

## Phase 2: Interface Design

### 2.1 Define Handler Interface

Create a generic handler interface that any application can implement:

```zig
// src/modules/http_server/interfaces.zig

/// Handler interface - implementations provide application-specific logic
pub const HandlerInterface = struct {
    pub const Context = struct {
        allocator: std.mem.Allocator,
        // Application can extend this
    };
    
    pub const HandlerFn = *const fn (req: *Request, res: *Response, ctx: *Context) anyerror!void;
    
    pub const Route = struct {
        method: Method,
        path: []const u8,
        handler: HandlerFn,
    };
    
    pub const Method = enum {
        get,
        post,
        put,
        delete,
        patch,
    };
    
    pub const Request = httpz.Request;
    pub const Response = httpz.Response;
};
```

### 2.2 Define SSE Interface

SSE broadcasting abstraction:

```zig
pub const SseBroadcaster = struct {
    pub const EventType = enum {
        message,
        panic,
        custom,
    };
    
    pub const Event = struct {
        event_type: EventType,
        data: []const u8,
        session_id: ?[]const u8,  // null = broadcast to all
    };
    
    pub const Interface = struct {
        broadcast: *const fn (event: Event) void,
        sendToSession: *const fn (session_id: []const u8, data: []const u8) void,
    };
};
```

### 2.3 Define Panic Broadcast Interface

```zig
pub const PanicHandler = struct {
    pub const PanicEvent = struct {
        message: []const u8,
        stack_trace: ?[]const u8,
    };
    
    pub const Interface = struct {
        onPanic: *const fn (event: PanicEvent) void,
    };
};
```

---

## Phase 3: Refactor http_server.zig (Pure Transport)

### Task 1: Create Clean Transport Server

**Files:**
- Modify: `src/modules/http_server/http_server.zig` — Remove all handlers, imports, application logic
- Modify: `src/modules/http_server/interfaces.zig` — Create new interface definitions
- Test: `src/modules/http_server/http_server_test.zig`

- [ ] **Step 1: Read current http_server.zig to identify exact lines to remove**

```bash
wc -l src/modules/http_server/http_server.zig
head -n 10 src/modules/http_server/http_server.zig
```

- [ ] **Step 2: Create interfaces.zig with handler, SSE, and panic interfaces**

Write the new interface definitions (see Section 2 above).

- [ ] **Step 3: Refactor HttpServer struct — remove application-specific fields**

Current struct (lines 266-276):
```zig
pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    message_handler: ?*const fn (session_id: []const u8, message: []const u8, resp: *httpz.Response, ctx: *anyopaque) anyerror!void,
    message_handler_ctx: ?*anyopaque,
    session_handler: ?*const fn (action: []const u8, body: []const u8, ctx: *anyopaque) anyerror!SessionResponse,
    session_handler_ctx: ?*anyopaque,
    db: ?*sqlite.SqliteBackend = null,
    // ... more fields
};
```

New struct:
```zig
pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    // SSE and routing injected via interfaces
    sse_manager: *SseConnectionManager,
    // No application-specific fields
};
```

- [ ] **Step 4: Extract SSE ConnectionManager to separate module**

Move `SseConnectionManager` (lines 89-239) and `SseEvent` (lines 24-85) to new file `sse_manager.zig`.

- [ ] **Step 5: Remove all handler functions from http_server.zig**

Delete:
- `commandHandler` (lines 329-357)
- `sessionCreateHandler` (lines 360-374)
- `sessionListHandler` (lines 377-390)
- `sessionExistsHandler` (lines 394-414)
- `getLatestSessionByDirHandler` (lines 417-460)
- `pingHandler` (lines 464-482)
- `kerjabotSessionCreateHandler` (lines 485-558)
- `kerjabotGetSessionHandler` (lines 561-627)
- `kerjabotListSessionsHandler` (lines 630-689)
- `streamHandler` (lines 748-777)
- `sseStreamHandler` (lines 698-746)

- [ ] **Step 6: Remove top-level pabrikcore imports**

Delete lines 3-6:
```zig
const sqlite = @import("pabrikcore").sqlite;
const kerjabot_get_session = @import("pabrikcore").kerjabot_get_session;
const kerjabot_create_session = @import("pabrikcore").kerjabot_create_session;
const kerjabot_get_list_session = @import("pabrikcore").kerjabot_get_list_session;
```

- [ ] **Step 7: Remove inline `@import("pabrikcore")` calls in SSE handlers**

Delete lines 404, 430 (the inline imports in sessionExistsHandler and getLatestSessionByDirHandler).

- [ ] **Step 8: Simplify `runWithConfig` to use route registration interface**

Replace inline `HttpRoutes` struct with route registration callback pattern.

- [ ] **Step 9: Remove `Command` struct and parseCommand function**

These are TUI-specific (lines 10-22, 248-261).

- [ ] **Step 10: Update panic broadcasting to use SSE interface**

- [ ] **Step 11: Verify build**

```bash
zig build 2>&1 | head -n 50
```

Expected: Compilation errors showing missing handlers (this is expected — we'll fix in Task 2-4)

- [ ] **Step 12: Commit**

```bash
git add src/modules/http_server/http_server.zig src/modules/http_server/interfaces.zig src/modules/http_server/sse_manager.zig
git commit --no-edit -m "refactor(http_server): create pure transport layer with interfaces"
```

---

### Task 2: Create TUI HTTP Handlers Module

**Files:**
- Create: `src/modules/http_server/tui_handlers.zig` — TUI-specific request handlers
- Modify: `src/main.zig` — Register TUI handlers via new interface

- [ ] **Step 1: Create tui_handlers.zig with TUI-specific handlers**

Extract from `http_server.zig`:
- `sessionCreateHandler` → `tui.sessionCreate`
- `sessionListHandler` → `tui.sessionList`
- `sessionExistsHandler` → `tui.sessionExists`
- `getLatestSessionByDirHandler` → `tui.getLatestSessionByDir`
- `pingHandler` → `tui.ping`
- `commandHandler` → `tui.command`
- `streamHandler` + `sseStreamHandler` → `tui.stream`

Each handler takes context that includes:
- Database connection
- Session manager
- SSE broadcaster

- [ ] **Step 2: Update main.zig to register TUI handlers**

```zig
// After server init
const tui_handlers = tui_http_handlers.init(allocator, &server);
tui_handlers.registerRoutes(router);
```

- [ ] **Step 3: Build and fix errors**

```bash
zig build 2>&1 | head -n 100
```

- [ ] **Step 4: Commit**

```bash
git add src/modules/http_server/tui_handlers.zig src/main.zig
git commit --no-edit -m "feat(http_server): extract TUI handlers to separate module"
```

---

### Task 3: Create Kerjabot HTTP Handlers Module

**Files:**
- Create: `src/modules/http_server/kerjabot_handlers.zig` — Kerjabot-specific request handlers
- Modify: `src/main.zig` — Register Kerjabot handlers via new interface

- [ ] **Step 1: Create kerjabot_handlers.zig with kerjabot-specific handlers**

Extract from `http_server.zig`:
- `kerjabotSessionCreateHandler` → `kerjabot.sessionCreate`
- `kerjabotGetSessionHandler` → `kerjabot.getSession`
- `kerjabotListSessionsHandler` → `kerjabot.listSessions`

- [ ] **Step 2: Update main.zig to register Kerjabot handlers**

- [ ] **Step 3: Build and fix errors**

- [ ] **Step 4: Commit**

```bash
git add src/modules/http_server/kerjabot_handlers.zig
git commit --no-edit -m "feat(http_server): extract kerjabot handlers to separate module"
```

---

### Task 4: Update TUI Application Wiring

**Files:**
- Modify: `src/ai_workflow/tui/on_event_sent.zig` — Update SSE access pattern
- Modify: `src/root.zig` — Update panic broadcast integration

- [ ] **Step 1: Update SSE access via injected interface**

Old pattern:
```zig
const sse = http_server.getGlobalSseManager();
sse.send(session_id, event);
```

New pattern — inject SSE interface into TUI context:
```zig
pub const TuiContext = struct {
    allocator: std.mem.Allocator,
    sse_broadcaster: *http_server.SseBroadcaster,
    // ...
};
```

- [ ] **Step 2: Update panic broadcast registration**

Old pattern:
```zig
http_server.broadcastPanic(msg);
```

New pattern — register panic handler:
```zig
server.setPanicHandler(panicHandler);
```

- [ ] **Step 3: Build and verify**

```bash
zig build 2>&1 | head -n 50
```

- [ ] **Step 4: Run full test suite**

```bash
zig build test 2>&1 | head -n 100
```

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/on_event_sent.zig src/root.zig
git commit --no-edit -m "refactor(http_server): update TUI to use injected interfaces"
```

---

### Task 5: Integration Testing

**Files:**
- Modify: `src/apps/tui/main.zig` — If TUI app has direct http_server usage
- Create: `src/modules/http_server/http_server_test.zig` — Transport layer tests

- [ ] **Step 1: Test HTTP server starts with no handlers registered**

- [ ] **Step 2: Test handler registration interface**

- [ ] **Step 3: Test SSE broadcast functionality**

- [ ] **Step 4: Verify all existing functionality still works**

- [ ] **Step 5: Run full test suite**

```bash
zig build test 2>&1
```

- [ ] **Step 6: Commit**

```bash
git add src/modules/http_server/http_server_test.zig
git commit --no-edit -m "test(http_server): add transport layer tests"
```

---

## Phase 4: Verification

### Checkpoints

- [ ] **Checkpoint 1:** `http_server.zig` has ZERO imports from `pabrikcore`
- [ ] **Checkpoint 2:** `http_server.zig` has ZERO handler functions (commandHandler, session*, kerjabot*, stream*)
- [ ] **Checkpoint 3:** `http_server.zig` only contains transport logic: server init, route registration interface, SSE manager, panic broadcasting
- [ ] **Checkpoint 4:** All handlers are in separate modules: `tui_handlers.zig`, `kerjabot_handlers.zig`
- [ ] **Checkpoint 5:** `zig build` succeeds
- [ ] **Checkpoint 6:** `zig build test` succeeds

---

## Phase 5: Final Cleanup

- [ ] **Step 1:** Verify no remaining inline `@import("pabrikcore")` in handler files

```bash
rg '@import\("pabrikcore"\)' src/modules/http_server/ --hidden
```

Expected: No matches

- [ ] **Step 2:** Check circular dependencies resolved

```bash
rg 'http_server' src/pabrikcore --hidden | head -n 20
```

- [ ] **Step 3:** Final build verification

```bash
zig build 2>&1
```

- [ ] **Step 4:** Update AGENT.md with new structure

---

## File Structure After Refactor

```
src/modules/http_server/
├── http_server.zig        # Pure transport layer (NEW: clean)
├── interfaces.zig         # NEW: Handler, SSE, Panic interfaces
├── sse_manager.zig        # NEW: SSE connection management
├── tui_handlers.zig       # NEW: TUI-specific handlers
├── kerjabot_handlers.zig  # NEW: Kerjabot-specific handlers
└── http_server_test.zig   # Transport layer tests
```

---

## Open Questions

1. **Session handler pattern**: The `session_handler` callback in `HttpServer` provides a generic session action interface. Should this be kept as a convenience pattern or fully removed in favor of registered routes?

2. **Command struct**: The `Command` struct is used for parsing. Should it stay in the TUI handlers module or move to a shared helpers module?

3. **SSE session mapping**: The SSE manager maps `session_id -> connection`. Should sessions be a concept in the transport layer (generic) or only in TUI handlers (specific)?

4. **Panic handler**: The panic broadcast pattern is useful for all applications. Keep it in transport layer? Yes → confirmed.

---

## Rollback Plan

If refactoring breaks critical functionality:

```bash
git checkout HEAD~3 -- src/modules/http_server/http_server.zig
git checkout HEAD~3 -- src/main.zig
zig build
```

This reverts to pre-refactor state with 3 commits of changes.
