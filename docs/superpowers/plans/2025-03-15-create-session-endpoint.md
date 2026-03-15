# Create Session Endpoint Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new synchronous endpoint `/api/session/create` for kerjabot to create sessions and get the session ID in the HTTP response. Keep existing `/api/command` endpoint as fire-and-forget for long-running commands.

**Architecture:** 
- Add new `/api/session/create` endpoint that handles session creation synchronously
- Existing `/api/command` remains unchanged (fire-and-forget for run_llm, etc.)
- Separate concerns: quick operations (session CRUD) vs long-running (LLM execution)

**Tech Stack:** Zig 0.15, httpz web framework

---

## File Structure

- **Modify:** `src/modules/http_server/http_server.zig` — Add new synchronous session endpoint
- **Modify:** `src/main.zig` — Add handler for the new session creation endpoint

---

## Chunk 1: Add new session endpoint in http_server.zig

- [ ] **Step 1: Read current http_server.zig routes section**

Check lines around 295-310 for the current route setup.

- [ ] **Step 2: Add new session routes**

Add after the existing routes (after line 303):

```zig
// Session management endpoints (synchronous for quick operations)
router.post("/api/session/create", sessionCreateHandler, .{});
router.get("/api/session/:session_id", sessionGetHandler, .{});
router.delete("/api/session/:session_id", sessionDeleteHandler, .{});
```

- [ ] **Step 3: Add session handlers**

Add before the `HttpServer` struct definition (around line 200):

```zig
/// Session create handler - synchronous, returns session ID in response
fn sessionCreateHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    if (global_server) |server| {
        if (server.session_handler) |sess_handler| {
            const body = req.body() orelse "";
            
            // Run synchronously - session creation is quick
            var arena = std.heap.ArenaAllocator.init(server.allocator);
            defer arena.deinit();
            sess_handler(arena.allocator(), body, server.ctx, res);
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"No session handler\"}";
}

/// Session get handler
fn sessionGetHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.status = 200;
    res.body = "{\"sessions\":[]}";
}

/// Session delete handler  
fn sessionDeleteHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const session_id = req.param("session_id") orelse "";
    _ = session_id;
    res.status = 200;
    res.body = "{\"deleted\":true}";
}
```

- [ ] **Step 4: Add session_handler field to HttpServer**

Find the HttpServer struct and add:

```zig
pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    port: u16,
    sse_manager: SseManager,
    message_handler: ?*const fn (std.mem.Allocator, []const u8, ?*anyopaque) void = null,
    session_handler: ?*const fn (std.mem.Allocator, []const u8, ?*anyopaque, *httpz.Response) void = null, // NEW
    ctx: ?*anyopaque = null,
    // ...
};
```

- [ ] **Step 5: Add setSessionHandler method**

Add in the impl section of HttpServer:

```zig
/// Set the session management handler (for synchronous operations like create/delete session)
pub fn setSessionHandler(self: *HttpServer, handler: *const fn (std.mem.Allocator, []const u8, ?*anyopaque, *httpz.Response) void) void {
    self.session_handler = handler;
}
```

- [ ] **Step 6: Verify build**

Run: `timeout 60 zig build 2>&1 | head -n 50`
Expected: Compiles, may have main.zig errors (expected)

---

## Chunk 2: Update main.zig to set session handler

- [ ] **Step 1: Add session handler after message handler setup**

Find where `server.setMessageHandler` is called (around line 327) and add after it:

```zig
// Set session handler for synchronous operations (create/get/delete sessions)
server.setSessionHandler(struct {
    fn handler(allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque, res: *httpz.Response) void {
        std.debug.print("session handler called with: {s}\n", .{data});

        const ctxTui = @as(*ai_workflow_mod.ContextIPCTui, @ptrCast(@alignCast(ctx)));
        
        // Parse the request body as JSON
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
            res.status = 400;
            res.body = "{\"error\":\"Invalid JSON\"}";
            return;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        
        // Get optional agent_type from request
        var agent_type: []const u8 = "general";
        if (root.get("agent_type")) |v| {
            agent_type = v.string;
        }

        // Generate session ID
        var session_id_buf: [64]u8 = undefined;
        const session_id = std.fmt.bufPrint(&session_id_buf, "session_{}", .{std.time.timestamp()}) catch "session_error";

        // Return JSON response
        var response_buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "{{\"sessionId\":\"{s}\",\"agentType\":\"{s}\"}}", .{ session_id, agent_type }) catch unreachable;

        res.status = 200;
        res.body = response;
        
        std.debug.print("Created session: {s} with agentType: {s}\n", .{ session_id, agent_type });
    }
}.handler);
```

- [ ] **Step 2: Verify build**

Run: `timeout 60 zig build 2>&1 | head -n 80`
Expected: Compiles without errors

---

## Chunk 3: Update frontend to use new endpoint

- [ ] **Step 1: Update backendApi.ts createSession function**

Modify `src/apps/kerjabot/src/services/backendApi.ts`:

Replace the createSession function (lines 17-35):

```typescript
export const createSession = async (agentType: string = 'general'): Promise<{ sessionId: string }> => {
  const response = await fetch('/api/session/create', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      agent_type: agentType,
    }),
  });

  if (!response.ok) {
    throw new Error(`Failed to create session: ${response.status}`);
  }

  return response.json();
};
```

- [ ] **Step 2: Test build**

Run: `cd src/apps/kerjabot && npm run build`
Expected: Builds without errors

---

## Chunk 4: Test the endpoint

- [ ] **Step 1: Start the backend**

Run: `./zig-out/bin/nalar &` (or start from IDE)
Expected: Backend starts, listens on port 8080

- [ ] **Step 2: Test new session endpoint**

Run: `curl -X POST http://127.0.0.1:8080/api/session/create -H "Content-Type: application/json" -d '{"agent_type":"general"}'`
Expected: Response like `{"sessionId":"session_1234567890","agentType":"general"}`

- [ ] **Step 3: Verify existing /api/command still works**

Run: `curl -X POST http://127.0.0.1:8080/api/command -H "Content-Type: application/json" -d '{"app_type":"web","command_type":"ping"}'`
Expected: Returns "ok" (fire-and-forget, doesn't wait for response)

- [ ] **Step 4: Test with frontend**

Start frontend: `cd src/apps/kerjabot && npm run dev`
Open browser: http://localhost:3000
Create a new session
Expected: Session is created and session ID is returned

---

## Chunk 5: Commit

- [ ] **Step 1: Git add and commit**

```bash
git add src/modules/http_server/http_server.zig src/main.zig src/apps/kerjabot/src/services/backendApi.ts
git commit -m "feat(kerjabot): add synchronous session creation endpoint

- Added new /api/session/create endpoint for kerjabot web app
- Returns sessionId directly in HTTP response (synchronous)
- Existing /api/command remains fire-and-forget for long-running commands
- Updated frontend to use new endpoint"
```
