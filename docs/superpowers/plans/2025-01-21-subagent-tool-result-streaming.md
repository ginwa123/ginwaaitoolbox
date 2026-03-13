# Sub-Agent Tool Result Streaming Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send tool results to the frontend immediately after each tool executes within sub-agent loop, instead of waiting until all tools complete.

**Architecture:** 
- Pass `session_id` and `logger` into `runSubAgent` function
- After each tool executes, call `send_tool_result.run()` immediately
- On error, send error result and continue loop
- Final response still sent once at end (per-loop)

**Tech Stack:** Zig 0.15, SSE (Server-Sent Events)

---
## Files

- Modify: `src/ai_workflow/tui/handle_spawn_sub_agent.zig` - Add session_id/logger params, send tool result after each tool

---

## Chunk 1: Update runSubAgent Function Signature

### Task 1: Add session_id and logger parameters to runSubAgent

**Files:**
- Modify: `src/ai_workflow/tui/handle_spawn_sub_agent.zig:71-92`

- [ ] **Step 1: Read current function signature (lines 71-92)**

```zig
fn runSubAgent(
    allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    instruction: []const u8,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    config: *const config_mod.LlmConfig,
    allowed_tools: ?[]const []const u8,
    loop_index: u32,
    agent_temperature: f32,
    is_thinking: bool,
    agent_name: []const u8,
    parent_session_id: ?[]const u8,
    parent_id: ?[]const u8,
) ![]const u8 {
```

- [ ] **Step 2: Add session_id parameter after db**

```zig
fn runSubAgent(
    allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,  // NEW: needed for send_tool_result
    cwd: []const u8,
    instruction: []const u8,
    ...
```

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/handle_spawn_sub_agent.zig
git commit -m "feat(subagent): add session_id parameter to runSubAgent"
```

---

### Task 2: Update all call sites of runSubAgent

**Files:**
- Modify: `src/ai_workflow/tui/handle_spawn_sub_agent.zig` (thread spawn around line 380)

- [ ] **Step 1: Find the thread spawn call**

Look for where `runSubAgent` is called in the thread. Find this pattern:

```zig
const run_result = runSubAgent(
    thread_alloc,
    log,
    database,
    instruction,
    ...
);
```

- [ ] **Step 2: Add session_id parameter**

```zig
const run_result = runSubAgent(
    thread_alloc,
    log,
    database,
    parent_sess,  // session_id
    workdir,
    instruction,
    ...
);
```

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/handle_spawn_sub_agent.zig
git commit -m "feat(subagent): pass session_id to runSubAgent in thread"
```

---

## Chunk 2: Send Tool Result After Each Tool Executes

### Task 3: Add send_tool_result after each tool executes

**Files:**
- Modify: `src/ai_workflow/tui/handle_spawn_sub_agent.zig:200-250`

- [ ] **Step 1: Find the tool execution block**

Look for where tools are executed inline (around line 200):

```zig
if (std.mem.eql(u8, tc.function.name, "bash")) {
    const result = try bash_tool.executeBash(allocator, try parseBashInput(allocator, tc.function.arguments));
    tool_result = try bash_tool.bashResultToString(allocator, result);
} else if ...
```

- [ ] **Step 2: Wrap each tool execution in error handling with send_tool_result**

Replace each tool block to catch errors and send result:

```zig
if (std.mem.eql(u8, tc.function.name, "bash")) {
    const result = bash_tool.executeBash(allocator, try parseBashInput(allocator, tc.function.arguments)) catch |err| {
        const err_str = try std.fmt.allocPrint(allocator, "ERROR: bash failed: {s}", .{@errorName(err)});
        send_tool_result.run(allocator, session_id, logger, err_str, tc.id, "bash", null);
        allocator.free(err_str);
        // Add error message to conversation and continue
        tool_result = try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)});
    };
    if (result) |r| {
        tool_result = try bash_tool.bashResultToString(allocator, r);
    }
    // Send tool result after execution
    send_tool_result.run(allocator, session_id, logger, tool_result, tc.id, "bash", null);
} else if (std.mem.eql(u8, tc.function.name, "read_file")) {
    tool_result = handle_read_file_tool.run(allocator, tc) catch |err| {
        const err_str = try std.fmt.allocPrint(allocator, "ERROR: read_file failed: {s}", .{@errorName(err)});
        send_tool_result.run(allocator, session_id, logger, err_str, tc.id, "read_file", null);
        allocator.free(err_str);
        tool_result = try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)});
    };
    send_tool_result.run(allocator, session_id, logger, tool_result, tc.id, "read_file", null);
} ...
```

**IMPORTANT:** Use this pattern for ALL tools:
1. Execute tool with `catch |err| { handle error }`
2. On error: create error string, send via `send_tool_result`, set tool_result to error message, continue
3. After successful execution: send tool_result via `send_tool_result`

- [ ] **Step 2: Verify build**

```bash
zig build 2>&1 | head -n 30
```

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/handle_spawn_sub_agent.zig
git commit -m "feat(subagent): send tool result after each tool executes"
```

---

## Chunk 3: Test & Verify

### Task 4: Verify the implementation works

- [ ] **Step 1: Build the project**

```bash
zig build 2>&1 | tail -n 10
```

Expected: No errors

- [ ] **Step 2: Run existing tests**

```bash
zig test 2>&1 | tail -n 20
```

Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add .
git commit -m "feat(subagent): stream tool results per loop in sub-agents

- Add session_id parameter to runSubAgent for SSE messaging
- Send tool result immediately after each tool executes
- Handle errors by sending error result and continuing loop
- Matches behavior of non-subagent tool execution"
```

---
