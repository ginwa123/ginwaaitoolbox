# Fix MCP stdio: agent tools not listing + backend SEGV on large payload

> **For agentic workers:** REQUIRED SUB-SKILL: Use `test-driven-development` and `systematic-debugging` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two related MCP stdio bugs reported together:
1. **Agent doesn't see MCP tools** — Settings → Edit MCP server → Test shows "Connected — 10 tools discovered" (graphify), but the agent says "No `mcp_graphify_*` tools are currently exposed — only the default tools (bash, read_file, ...) are available."
2. **Backend SEGV on large payload** — When MCP is enabled and a tool returns ~120 KB (graph data), the backend crashes: `DEBUG_HANDLER: req.body.len=120533` → `SEGV (signal 11)` → `run exe nalar failure (139)`.

Both bugs are in the stdio transport path. HTTP transport is unaffected.

**Worktree:** `worktree/fix-mcp-stdio-agent-tools` on branch `worktree/fix-mcp-stdio-agent-tools`.

---

## What exists today (read this before changing anything)

- **MCP stdio client** — `src/modules/agent/mcp/mcp/mcp_stdio.zig` (1200 lines, 3 sections: framing + StdioClient + StdioRegistry). `readFramed` auto-detects Content-Length vs NDJSON on read; `writeFramed` always emits Content-Length. `StdioRegistry` is a process-global singleton keyed by server name, lazy spawn, `markStale` for self-healing.
- **Tool discovery (agent path)** — `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig:413 buildMCPToolsRun` → `fetchToolsFromServerStdio` (line 607). Builds argv from `command` + `args`, calls `reg.getOrSpawn`, sends `{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}` via `client.send` (Content-Length), reads one response via `client.recv(30s, cancel_fn)`, parses `result.tools[]` into `AgentTool[]`. Called **once** before the workflow loop (`workflow.zig:564`), result cached as `mcp_tools_fetched` for the entire run. On any error: `catch |err| { log.warn(...); continue; }` — silent, no retry, no user-visible diagnostic.
- **Tool discovery (Test path)** — `src/ai_workflow/tui/http_handlers/mcp_test.zig:173 testStdio`. Builds argv the same way, but uses a **preview name** (`__mcp_test_preview_<nano>`), sends a **3-message handshake** (`initialize` → `notifications/initialized` → `tools/list`) as **NDJSON** (`\n`-delimited, via `writeStreamingAll`), reads **two responses** (initialize + tools/list), retries up to **20 times** on `UnexpectedEof` (cold-start race), drains stderr for diagnostics. This is why Test succeeds while the agent fails.
- **Tool execution** — `src/ai_workflow/tui/agentic_loop/handle_mcp_tool.zig:190 callViaStdio`. Same argv building, same `getOrSpawn`, same Content-Length framing, same single `tools/call` without handshake, 60s deadline, no cancel callback, no retry.
- **Config** — `src/modules/config/Config.zig:986 parseMcpServerConfig` accepts exactly one of `url` (HTTP) or `command` (stdio). `mcpServers()` returns the `json.Value` mirror used by `buildMCPToolsRun`. The user's graphify config is `{"command": "/home/ginwa/.local/share/uv/tools/graphifyy/bin/python", "args": ["-m", "graphify.serve", "graphify-out/graph.json"]}` — valid, parses correctly.
- **Crash site** — `src/ai_workflow/tui/http_handlers/session_create.zig:71` has a debug print `DEBUG_HANDLER: req.body.len={}, body_start_20={}` that prints `req.body.len` twice (bug: second arg should be `req.body[0..@min(20, req.body.len)]`). The 120533-byte body that crashes is likely a large MCP tool result being round-tripped through session creation or a large `queue_message`/`body_message` in the agent loop. The SEGV stack trace (21 frames, no symbols) suggests a buffer overread or use-after-free with large allocations. Candidates: fixed-size header buffers (`[64]u8` in `writeFramed`, `[4096]u8` reader buf, `[8*1024]u8` header buf), arena lifetime issues, or JSON parsing of large payloads.
- **Workflow wiring** — `workflow.zig:564` fetches MCP tools once before the loop with a 30s deadline + cancel thunk. `workflow.zig:1043` merges them via `filterAndMergeTools`. No per-iteration re-fetch, no retry, no handshake.

---

## Root cause analysis

### Bug 1: Agent doesn't see MCP tools (Test works, agent doesn't)

| # | Root cause | Evidence | Impact |
|---|-----------|----------|--------|
| R1 | **Missing MCP handshake** — agent sends bare `tools/list` without `initialize` + `notifications/initialized`. Many MCP servers (including Python's `mcp` SDK used by graphify) require `initialize` before they respond to any other method. Without it, the server either ignores `tools/list` or returns an error, causing `recv` to timeout or parse to fail. | `mcp_test.zig:226-243` sends 3 messages; `prompts_build_messages_for_agent_prompt.zig:648` sends 1. The MCP spec (https://modelcontextprotocol.io/specification/draft/basic/transports/stdio) mandates `initialize` as the first request. | `fetchToolsFromServerStdio` always fails for handshake-requiring servers → `continue` → empty `all_tools` → agent sees 0 MCP tools. |
| R2 | **Framing mismatch** — agent uses Content-Length framing (`writeFramed`), Test uses NDJSON (`\n`). The Python MCP SDK's stdio transport defaults to NDJSON (`JSON.stringify(msg) + '\n'`). If graphify's Python server only handles NDJSON, Content-Length frames are not parsed. | `mcp_stdio.zig:279 writeFramed` emits `Content-Length: N\r\n\r\n<body>`; `mcp_test.zig:308` emits `body + "\n"`. `readFramed` handles both on read, but `writeFramed` only emits one. | Server never sees the request → timeout → no tools. |
| R3 | **No retry on cold-start race** — `process.spawn` returns before the child (sh → python → SDK `connect()` → `_stdin.on('data')`) has attached its stdin listener. The first `tools/list` sits in the pipe buffer unread, `recv` gets `UnexpectedEof` or `RecvTimeout`. Test retries 20× with 500ms sleep; agent tries once and gives up. | `mcp_test.zig:87 TEST_STDIO_MAX_ATTEMPTS=20`; `prompts_build_messages_for_agent_prompt.zig:447` has no retry loop. CI history shows this race caused ~1/100 failures before the retry was added to Test. | Intermittent failure on slow hosts / large graph.json load; even when handshake is fixed, first attempt may still fail. |
| R4 | **Silent failure, no user feedback** — `buildMCPToolsRun` logs `warn` and `continue` on any error. The agent has no way to know MCP failed, and the user sees no diagnostic in chat. The agent's "No mcp_graphify_* tools" message is its own inference from reading `config.json` + seeing empty tool list, not a system diagnostic. | `prompts_build_messages_for_agent_prompt.zig:447-449` — `catch |err| { log.warn(...); continue; }`. No SSE, no chat message, no metric. | User confusion: Test says 10 tools, agent says 0, no error explains why. |
| R5 | **Single fetch before loop, never retried** — `mcp_tools_fetched` is computed once at workflow entry (`workflow.zig:564`). If it fails (R1-R3), the entire workflow run has 0 MCP tools, even if the server becomes ready 500ms later. | `workflow.zig:564` — `const mcp_tools_fetched = (blk: { ... buildMCPToolsRun(...) } catch ... ) orelse &[_]AgentTool{};` — no loop, no re-fetch. | A transient failure at workflow start permanently disables MCP for that run. |

### Bug 2: Backend SEGV on large payload (120 KB)

| # | Root cause | Evidence | Impact |
|---|-----------|----------|--------|
| R6 | **Debug print bug masks the real body** — `session_create.zig:71` prints `req.body.len` twice instead of `req.body[0..20]`. The log `body_start_20=120533` is actually the length again, not the body prefix. This hid the fact that the 120KB body is likely a JSON payload with large embedded content (graph data, tool results). | `std.debug.print("DEBUG_HANDLER: req.body.len={}, body_start_20={}\n", .{ req.body.len, req.body.len });` — second arg should be a slice, not len. | Misleading diagnostics; the real body content is unknown. |
| R7 | **Potential fixed-buffer overflow or large-allocation mishandling** — Several buffers are fixed-size: `header_buf: [64]u8` in `writeFramed`, `reader_buf: [4096]u8` in `readFramed`, `MAX_HEADER_BYTES: 8*1024`. A 120KB tool result or request body could exceed these if the code path incorrectly treats body length as header length, or if JSON parsing allocates large contiguous blocks that exceed arena limits. The SEGV (signal 11) with 21 frames suggests a memory safety violation, not a clean error. | Stack trace has 21 frames but no symbols (release build). Need to reproduce with debug build + `addr2line` or add `std.debug.dumpStackTrace` with symbols. | Backend crash, process exit 139, all sessions lost. |
| R8 | **Large tool results not truncated or streamed** — When graphify returns 120KB of graph data via `tools/call`, `handle_mcp_tool.zig:250-282` dupes the entire response, parses it, then dupes again for the tool result. This 120KB string is then inserted into `llm_history` (`response_content` TEXT), sent via SSE, and fed back to the LLM as a tool result. If any downstream consumer has a fixed buffer or the LLM context window is exceeded, it could cause OOM or truncation issues that manifest as SEGV in release builds. | `handle_mcp_tool.zig:254 errdefer allocator.free(resp);` + `281 return try allocator.dupe(u8, resp);` — two copies of 120KB. `workflow.zig` inserts this as `response_content` without size check. | Large tool results could cause OOM, SSE truncation, or LLM API errors that cascade to crash. |

---

## Design decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **Fix framing to use NDJSON for stdio** (like Test does), not Content-Length. Keep `readFramed`'s dual-mode detection on read, but change `writeFramed` callers for stdio to use NDJSON. Alternatively, make `writeFramed` support both and let the caller choose. | Python MCP SDK (graphify) and Node SDK both default to NDJSON. Content-Length is the spec's alternative, but NDJSON is what real servers expect. Test already proves NDJSON works with graphify. |
| D2 | **Add MCP handshake to agent path** — `initialize` + `notifications/initialized` before `tools/list` (for discovery) and before `tools/call` (for execution, if not already initialized). Cache the "initialized" state per server so subsequent `tools/call` don't re-handshake. | Matches the MCP spec and Test's proven sequence. Without this, handshake-requiring servers will never respond. |
| D3 | **Add retry with backoff to agent's `fetchToolsFromServerStdio`** — mirror Test's 3-attempt retry (not 20; agent path should be faster, 3× with 200ms sleep is enough for cold start). On `UnexpectedEof` or `RecvTimeout`, mark stale, sleep, respawn, retry. | Cold-start race is real and intermittent; one attempt is insufficient. Test's 20 retries are for CI's worst case; agent needs fewer but still needs some. |
| D4 | **Surface MCP discovery failures to the user** — when `buildMCPToolsRun` fails for a server, log a structured warning AND optionally insert a diagnostic message into the chat (or at least log with enough detail for `journalctl` to show). At minimum, the agent's system prompt should include "MCP server 'graphify' failed to connect: <reason>" so the agent can explain to the user. | Current silent `continue` leaves user confused. The agent's own "No mcp_graphify_* tools" message is a workaround, not a fix. |
| D5 | **Fix the debug print and add crash diagnostics** — correct `session_create.zig:71` to print actual body prefix, add bounds checks for large bodies, and ensure large tool results are handled safely (truncate or stream if needed). Build with debug symbols for the SEGV investigation. | The debug print bug hid the real body content. The SEGV needs proper symbolization to pinpoint. |
| D6 | **No new config fields, no migration, no new endpoint** — all fixes are in the existing stdio transport files. The config shape (`command` + `args`) is already correct. | Keeps the change minimal and focused on the transport bug. |

---

## File structure

### Edited files (backend)

```
src/modules/agent/mcp/mcp/mcp_stdio.zig                          # framing: add NDJSON write path or make writeFramed dual-mode
src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig  # fetchToolsFromServerStdio: add handshake + retry + NDJSON
src/ai_workflow/tui/agentic_loop/handle_mcp_tool.zig             # callViaStdio: add handshake + NDJSON + retry
src/ai_workflow/tui/agentic_loop/workflow.zig                    # optional: re-fetch MCP tools on retry or surface error
src/ai_workflow/tui/http_handlers/session_create.zig             # fix debug print, add large-body handling
```

### New files (tests)

```
tests/functional/mcp_stdio_agent_tools_test.py                   # E2E: agent sees graphify tools (reproduces Bug 1)
tests/functional/mcp_large_payload_test.py                       # E2E: large tool result doesn't crash (reproduces Bug 2)
```

### No new migration, no schema change, no frontend change.

---

## Tasks

### Task 1 — Reproduce Bug 1: agent doesn't see MCP tools

**Why:** Confirm the root cause before fixing. The Test handler and agent handler should behave identically for the same server config, but they don't.

**Files:**
- `tests/functional/mcp_stdio_agent_tools_test.py` (NEW)

#### Step 1.1 — Write the reproduction test

```python
def test_agent_sees_stdio_mcp_tools(harness):
    """Reproduces Bug 1: Test shows 10 tools but agent sees 0."""
    ws = harness.create_workspace()
    # Configure graphify-like stdio server (use mcp-hello-world as stand-in,
    # or the real graphify if available)
    harness.put_config({
        "mcp_servers": {
            "graphify": {
                "command": "/home/ginwa/.local/share/uv/tools/graphifyy/bin/python",
                "args": ["-m", "graphify.serve", "graphify-out/graph.json"]
            }
        }
    })
    # Verify Test endpoint sees tools
    test_result = harness.post("/api/mcp/test", {
        "transport": "stdio",
        "command": "/home/ginwa/.local/share/uv/tools/graphifyy/bin/python",
        "args": ["-m", "graphify.serve", "graphify-out/graph.json"]
    })
    assert test_result["ok"] is True
    assert len(test_result["tools"]) == 10  # graphify has 10 tools

    # Now check if agent sees them — send a message asking about MCP tools
    session_id = harness.create_session(ws, "test mcp")
    harness.send_message(session_id, "what mcp tools are available? list them")
    # Wait for agent response
    response = harness.wait_for_assistant(session_id, timeout=30)
    # This currently FAILS — agent says "No mcp_graphify_* tools"
    assert "mcp_graphify" in response.lower() or "query_graph" in response.lower(), \
        f"Agent should see graphify tools but got: {response[:500]}"
```

Alternatively, use `mcp-hello-world` binary for a hermetic test that doesn't depend on graphify being installed:

```python
def test_agent_sees_hello_world_stdio_tools(harness):
    ws = harness.create_workspace()
    hello_bin = harness.mcp_hello_world_bin()
    harness.put_config({
        "mcp_servers": {"hello": {"command": hello_bin, "args": []}}
    })
    harness.restart_nalar()
    session_id = harness.create_session(ws, "test")
    harness.send_message(session_id, "what tools do you have? do you have mcp_hello tools?")
    response = harness.wait_for_assistant(session_id, timeout=30)
    assert "mcp_hello" in response.lower()
```

Run: `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/mcp_stdio_agent_tools_test.py -v`

Expected: FAIL (reproduces bug). If it passes, the bug is already fixed or the test harness is wrong.

#### Step 1.2 — Verify with existing harness

Check `tests/functional/harness.py` for the exact API (`create_workspace`, `put_config`, etc.) and adapt the test to match. Look at `tests/functional/mcp_stdio_test.py` for the existing stdio test pattern.

Commit: `git add tests/functional/mcp_stdio_agent_tools_test.py && git commit -m "test: reproduce MCP stdio agent tools not listing (Bug 1)"`

---

### Task 2 — Fix Bug 1: add handshake + NDJSON + retry to agent path

**Why:** The agent's `fetchToolsFromServerStdio` must match Test's proven sequence.

**Files:**
- `src/modules/agent/mcp/mcp/mcp_stdio.zig` (EDIT)
- `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig` (EDIT)
- `src/ai_workflow/tui/agentic_loop/handle_mcp_tool.zig` (EDIT)

#### Step 2.1 — Add NDJSON write helper to mcp_stdio.zig

Add a new function alongside `writeFramed`:

```zig
/// Write a newline-delimited JSON message (NDJSON). Used for MCP stdio
/// servers that expect `JSON.stringify(msg) + '\n'` (the SDK default).
/// Pair with `readFramed` which already handles both framing styles on read.
fn writeNDJSON(io: std.Io, file: std.Io.File, body: []const u8) !void {
    // Body is already JSON; just append \n and write atomically
    var buf: [4096]u8 = undefined; // stack buffer for small messages
    if (body.len + 1 <= buf.len) {
        @memcpy(buf[0..body.len], body);
        buf[body.len] = '\n';
        try std.Io.File.writeStreamingAll(file, io, buf[0 .. body.len + 1]);
    } else {
        try std.Io.File.writeStreamingAll(file, io, body);
        try std.Io.File.writeStreamingAll(file, io, "\n");
    }
}
```

Or, simpler: change `fetchToolsFromServerStdio` and `callViaStdio` to use `writeStreamingAll` directly with `\n` appended, matching `mcp_test.zig:308`.

#### Step 2.2 — Fix fetchToolsFromServerStdio (tool discovery)

Edit `prompts_build_messages_for_agent_prompt.zig:607 fetchToolsFromServerStdio`:

1. Change framing from Content-Length to NDJSON (append `\n` to each JSON body, use `writeStreamingAll` instead of `client.send` which uses `writeFramed`).
2. Add handshake before `tools/list`:
   ```zig
   // 1. Send initialize
   const init_body = try std.fmt.allocPrint(allocator,
       \\{{"jsonrpc":"2.0","id":"1","method":"initialize","params":{{"protocolVersion":"2024-11-05","capabilities":{{}},"clientInfo":{{"name":"nalar","version":"0.0.1"}}}}}}
   , .{});
   defer allocator.free(init_body);
   // Send as NDJSON
   try writeNDJSON(client.io, client.stdin.?, init_body);
   // Read initialize response (may fail on cold start — retry)
   const init_resp = try client.recv(deadline_ns, cancel_fn);
   defer allocator.free(init_resp);
   // 2. Send initialized notification (no response expected)
   const initialized_body = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";
   try std.Io.File.writeStreamingAll(client.stdin.?, client.io, initialized_body);
   // 3. Send tools/list
   const req = try allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":\"2\",\"method\":\"tools/list\",\"params\":{}}\n");
   defer allocator.free(req);
   try std.Io.File.writeStreamingAll(client.stdin.?, client.io, req);
   const resp = try client.recv(deadline_ns, cancel_fn);
   ```
3. Add retry loop (3 attempts, 200ms sleep on `UnexpectedEof`/`RecvTimeout`):
   ```zig
   var attempt: u8 = 0;
   while (attempt < 3) : (attempt += 1) {
       const client = reg.getOrSpawn(server_name, argv) catch ...;
       // try handshake + tools/list
       // on UnexpectedEof/RecvTimeout and attempt < 2: markStale, sleep 200ms, continue
       // on other error or last attempt: log.warn and return error
   }
   ```
4. Keep the existing JSON parsing for `result.tools[]` unchanged.

#### Step 2.3 — Fix callViaStdio (tool execution)

Edit `handle_mcp_tool.zig:190 callViaStdio` similarly:

1. Check if the server needs initialization (track per-server `initialized` flag in `StdioRegistry` or just always send `initialize` + `initialized` before the first `tools/call` — the server will handle duplicate `initialize` gracefully or we can cache).
2. Simplest: always do handshake before `tools/call` if the client was just spawned (check if it's a new client vs cached). Or, store a `initialized: bool` per `Entry` in `StdioRegistry`.
3. Use NDJSON framing for the `tools/call` request.
4. Add retry on cold-start (same 3-attempt pattern).

#### Step 2.4 — Verify

```bash
zig build test --summary all  # unit tests still pass
NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/mcp_stdio_agent_tools_test.py -v  # now PASSES
```

Commit: `git add -A && git commit -m "fix(mcp): stdio agent tools now do handshake + NDJSON + retry (Bug 1)"`

---

### Task 3 — Investigate and fix Bug 2: SEGV on large payload

**Why:** The 120KB crash is a separate bug that makes MCP unusable even when tools are listed.

**Files:**
- `src/ai_workflow/tui/http_handlers/session_create.zig` (EDIT)
- `src/ai_workflow/tui/agentic_loop/handle_mcp_tool.zig` (EDIT, if large tool results are the cause)
- `src/modules/agent/mcp/mcp/mcp_stdio.zig` (EDIT, if framing buffers are the cause)

#### Step 3.1 — Fix the debug print and add diagnostics

Edit `session_create.zig:71`:

```zig
// Before (bug: prints len twice):
std.debug.print("DEBUG_HANDLER: req.body.len={}, body_start_20={}\n", .{ req.body.len, req.body.len });
// After (correct: prints actual body prefix):
const prefix_len = @min(200, req.body.len);
std.debug.print("DEBUG_HANDLER: req.body.len={}, body_start_200={s}\n", .{ req.body.len, req.body[0..prefix_len] });
```

Also add a guard for very large bodies:

```zig
if (req.body.len > 1024 * 1024) { // 1MB cap for session_create
    std.log.warn("session_create: body too large: {} bytes, truncating", .{req.body.len});
    return res.jsonResponse(.{ .status_code = 413, .data = ... });
}
```

#### Step 3.2 — Symbolize the SEGV

Build with debug symbols and reproduce:

```bash
zig build -Doptimize=Debug nalar --summary all
# Run with the large payload that crashes
# When it SEGVs, use addr2line or llvm-symbolizer:
addr2line -e zig-out/bin/nalar 0x1f32e00 0x1f32faf ...
# Or run under gdb:
gdb --args ./zig-out/bin/nalar --port 8080
# Then: run, trigger crash, bt
```

Check for:
- Fixed buffer overflows (header_buf, reader_buf)
- Arena OOM with large allocations
- JSON parsing of 120KB with deep nesting
- SSE serialization of large tool results

#### Step 3.3 — Fix large tool result handling

If the crash is from large MCP tool results (120KB graph data):

1. In `handle_mcp_tool.zig:callViaStdio`, after extracting `result.content[0].text`, check size and truncate if needed:
   ```zig
   const MAX_TOOL_RESULT_BYTES: usize = 100 * 1024; // 100KB cap
   if (tool_result.len > MAX_TOOL_RESULT_BYTES) {
       logger.warnFmt("MCP tool result too large: {} bytes, truncating to {} bytes", .{ tool_result.len, MAX_TOOL_RESULT_BYTES });
       // Truncate and add notice
       const truncated = try std.fmt.allocPrint(allocator, "{s}\n\n[truncated: original was {} bytes, showing first {} bytes]", .{ tool_result[0..MAX_TOOL_RESULT_BYTES], tool_result.len, MAX_TOOL_RESULT_BYTES });
       allocator.free(tool_result);
       return truncated;
   }
   ```
2. In `mcp_stdio.zig:readFramed`, ensure the `max_line: 10*1024*1024` cap is respected and large NDJSON lines don't cause OOM. The current code already has `if (len >= max_line) return StdioError.InvalidFrame;` — verify this is correct for 120KB (it is, 120KB < 10MB).

#### Step 3.4 — Write reproduction test

```python
def test_large_mcp_tool_result_no_crash(harness):
    """Reproduces Bug 2: large tool result (120KB) should not crash backend."""
    ws = harness.create_workspace()
    # Use a mock MCP server that returns 120KB
    # Or use graphify with a large graph.json
    harness.put_config({
        "mcp_servers": {
            "large": {
                "command": "python",
                "args": ["-m", "mock_large_mcp", "--size", "120000"]
            }
        }
    })
    harness.restart_nalar()
    session_id = harness.create_session(ws, "test large")
    # Call a tool that returns large data
    harness.send_message(session_id, "call the large tool and show me the result")
    # Should not crash — backend should still be alive
    assert harness.is_alive(), "Backend crashed on large tool result"
    response = harness.wait_for_assistant(session_id, timeout=30)
    assert response is not None
```

Run: `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/mcp_large_payload_test.py -v`

Commit: `git add -A && git commit -m "fix(mcp): handle large tool results without SEGV (Bug 2)"`

---

### Task 4 — Surface MCP errors to user and add observability

**Why:** Even after fixing R1-R3, future MCP failures should be visible, not silent.

**Files:**
- `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig` (EDIT)
- `src/ai_workflow/tui/agentic_loop/workflow.zig` (EDIT)

#### Step 4.1 — Log structured MCP diagnostics

In `buildMCPToolsRun`, when a server fails:

```zig
const stdio_tools = fetchToolsFromServerStdio(...) catch |err| {
    std.log.warn("MCP stdio server '{s}' failed: {s} (command: {s}, args: {any})", .{ server_name, @errorName(err), argv[0], argv[1..] });
    // Optionally, store the error for the system prompt
    try failed_servers.append(allocator, .{ .name = server_name, .err = @errorName(err) });
    continue;
};
```

#### Step 4.2 — Include MCP status in system prompt

Add a section to the agent's system prompt when MCP servers are configured but failed:

```
## MCP Servers

- graphify (stdio: /home/ginwa/.local/share/uv/tools/graphifyy/bin/python -m graphify.serve graphify-out/graph.json): FAILED — RecvTimeout (server did not respond to tools/list within 30s). The server may need to be restarted or the command may be wrong. Tools from this server are NOT available.
- hello (stdio: ./zig-out/bin/mcp-hello-world): OK — 3 tools available (mcp_hello_say_hello, ...)
```

This lets the agent explain to the user why tools are missing, instead of saying "No mcp_graphify_* tools are currently exposed" without context.

#### Step 4.3 — Verify

```bash
zig build test --summary all
python3 -m pytest tests/functional/mcp_stdio_agent_tools_test.py -v  # agent now explains MCP status
```

Commit: `git add -A && git commit -m "feat(mcp): surface MCP discovery failures in system prompt"`

---

### Task 5 — Final verification

**Files:**
- `NALAR.md` (EDIT — changelog)

#### Step 5.1 — Run all tests

```bash
zig build test --summary all  # 3000+ tests, 0 fail
zig build nalar-desktop --summary all  # 21/21 steps OK
python3 -m pytest tests/functional/mcp_stdio_agent_tools_test.py tests/functional/mcp_large_payload_test.py -v  # both pass
python3 -m pytest tests/functional/mcp_stdio_test.py tests/functional/mcp_http_test.py -v  # existing MCP tests still pass
```

#### Step 5.2 — Manual smoke test with graphify

```bash
# Configure graphify as the user did
cat ~/.config/nalar/config.json | jq .mcp_servers
# Start nalar, create a session, ask "what mcp tools do you have?"
# Verify the agent lists all 10 graphify tools
# Call one: "query the graph for X"
# Verify no crash, response is correct
```

#### Step 5.3 — Changelog

Append to `NALAR.md`:

```markdown
### 2026-09-02: Fix MCP stdio agent tools not listing + SEGV on large payload

**What landed.** Two MCP stdio bugs fixed: (1) Agent now sees stdio MCP tools — the Test button did a full MCP handshake (initialize → initialized → tools/list) with NDJSON framing and 20 retries, but the agent path sent bare tools/list with Content-Length and no retry, so handshake-requiring servers (like graphify's Python SDK) never responded. Fixed by adding handshake + NDJSON + 3-attempt retry to both tool discovery and tool execution paths. (2) Backend SEGV on 120KB tool results — fixed debug print bug (was printing len twice), added large-result truncation (100KB cap with notice), and verified framing buffers handle large payloads. Also surfaced MCP discovery failures in the system prompt so the agent can explain why tools are missing instead of silently showing 0 tools.

**Files.** 5 EDIT (mcp_stdio.zig, prompts_build_messages_for_agent_prompt.zig, handle_mcp_tool.zig, workflow.zig, session_create.zig) + 2 NEW functional tests. No migration, no schema change, no frontend change.

**Tests.** `zig build test --summary all`: 3000+ pass, 0 fail. `pytest tests/functional/mcp_stdio_agent_tools_test.py tests/functional/mcp_large_payload_test.py`: 2/2 pass. Existing `mcp_stdio_test.py` + `mcp_http_test.py` still pass.

**Plan:** docs/superpowers/plans/2026-09-02-fix-mcp-stdio-agent-tools-and-crash.md
**Branch:** worktree/fix-mcp-stdio-agent-tools
**Task:** task_1788372445618_0
```

Commit: `git add -A && git commit -m "docs: changelog for MCP stdio fix"`

---

## Pitfalls

1. **Don't break HTTP transport** — the fix only touches the `if (server_obj.get("command"))` branch. HTTP path (`url` + `headers`) must remain untouched. Verify with `mcp_http_test.py`.
2. **NDJSON vs Content-Length** — some MCP servers may expect Content-Length. If switching to NDJSON breaks a server that expects Content-Length, make the framing configurable or try both. For now, NDJSON is the safer default (matches both SDKs' defaults and Test's proven path).
3. **Handshake state** — if we cache "initialized" per server, we must handle the case where the child dies and respawns (the new child needs a fresh handshake). `markStale` + respawn should reset the initialized flag.
4. **Large payload truncation** — truncating tool results at 100KB may lose important data. Consider making the cap configurable or streaming large results. For now, truncation with a notice is better than crashing.
5. **Debug print fix** — the `session_create.zig:71` fix is trivial but the SEGV may not be in that file at all. Symbolize the stack trace first before assuming the fix location.

---

## Verification

- [ ] `zig build test --summary all` — 0 failures
- [ ] `zig build nalar-desktop --summary all` — 21/21 steps OK
- [ ] `python3 -m pytest tests/functional/mcp_stdio_agent_tools_test.py -v` — agent sees graphify tools
- [ ] `python3 -m pytest tests/functional/mcp_large_payload_test.py -v` — no crash on 120KB
- [ ] `python3 -m pytest tests/functional/mcp_stdio_test.py tests/functional/mcp_http_test.py -v` — no regressions
- [ ] Manual: configure graphify, ask agent "what mcp tools do you have?", verify 10 tools listed
- [ ] Manual: call `query_graph` with large result, verify no SEGV, response truncated gracefully
