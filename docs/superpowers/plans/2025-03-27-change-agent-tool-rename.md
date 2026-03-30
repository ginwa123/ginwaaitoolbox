# Change Agent Tool Rename Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename `get_agent` tool to `change_agent`, update tool description to emphasize personality changes, and update prompt.zig to encourage agent switching.

**Architecture:** This is a refactoring task. We rename the tool, update all references, and enhance the prompt to encourage users to change agents for different personality traits/specializations.

**Tech Stack:** Zig 0.15.2, httpz, libsqlite3

---

## Chunk 1: Core Tool Rename

### Task 1: Rename `src/modules/agent/tools/get_agent.zig` → `change_agent.zig`

**Files:**
- Rename: `src/modules/agent/tools/get_agent.zig` → `src/modules/agent/tools/change_agent.zig`

- [ ] **Step 1: Create the new file with renamed content**

```bash
mv src/modules/agent/tools/get_agent.zig src/modules/agent/tools/change_agent.zig
```

- [ ] **Step 2: Update the tool definition name and description**

In `src/modules/agent/tools/change_agent.zig`, update:

```zig
// Line 182-184: Change tool name
pub const ChangeAgentTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "change_agent",  // was: "get_agent"
        .description = "Switch to a different agent persona with specialized capabilities. Use when you need a different expertise, perspective, or approach. Examples: 'code-reviewer' for quality feedback, 'zig-expert' for Zig guidance, 'frontend-engineer' for UI work.",  // Enhanced description
```

- [ ] **Step 3: Update struct names**

```zig
// Line 162: Rename struct
pub const ChangeAgentInput = struct {  // was: GetAgentInput

// Line 168: Rename struct  
pub const ChangeAgentResult = struct {  // was: GetAgentResult
```

- [ ] **Step 4: Update function names**

```zig
// Line 203: Rename function
pub fn parseChangeAgentInput(...)  // was: parseGetAgentInput

// Line 228: Rename function
pub fn executeChangeAgentToString(...)  // was: executeGetAgentToString

// Line 237: Rename function (internal)
fn loadAgentFromPath(...) → fn loadAgentFromPath(...)  // same, no change needed

// Line 273: Rename function (internal)
fn loadAgentByName(...) → fn loadAgentByName(...)  // same, no change needed
```

- [ ] **Step 5: Update test import**

```zig
// Line 333
    _ = @import("change_agent_test.zig");  // was: get_agent_test.zig
```

- [ ] **Step 6: Commit**

```bash
git add src/modules/agent/tools/get_agent.zig src/modules/agent/tools/change_agent.zig
git rm src/modules/agent/tools/get_agent.zig
git add src/modules/agent/tools/change_agent.zig
git commit -m "refactor: rename get_agent.zig to change_agent.zig"
```

---

### Task 2: Create `src/modules/agent/tools/change_agent_test.zig`

**Files:**
- Create: `src/modules/agent/tools/change_agent_test.zig` (rename from `get_agent_test.zig`)

- [ ] **Step 1: Create renamed test file**

```bash
mv src/modules/agent/tools/get_agent_test.zig src/modules/agent/tools/change_agent_test.zig
```

- [ ] **Step 2: Update imports and references in the test file**

Update all occurrences of:
- `const get_agent = @import("get_agent.zig");` → `const change_agent = @import("change_agent.zig");`
- `const GetAgentInput` → `const ChangeAgentInput`
- `const result = get_agent.parseGetAgentInput(...)` → `change_agent.parseChangeAgentInput(...)`
- `const result = get_agent.executeGetAgentToString(...)` → `change_agent.executeChangeAgentToString(...)`
- `const tool = get_agent.GetAgentTool;` → `const tool = change_agent.ChangeAgentTool;`
- `try std.testing.expectEqualStrings("get_agent", ...)` → `try std.testing.expectEqualStrings("change_agent", ...)`

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/change_agent_test.zig
git rm src/modules/agent/tools/get_agent_test.zig
git commit -m "test: rename get_agent_test.zig to change_agent_test.zig"
```

---

### Task 3: Update `src/modules/agent/test_runner.zig`

**Files:**
- Modify: `src/modules/agent/test_runner.zig`

- [ ] **Step 1: Update import**

```zig
// Line 8
    _ = @import("tools/change_agent_test.zig");  // was: get_agent_test.zig
```

- [ ] **Step 2: Commit**

```bash
git add src/modules/agent/test_runner.zig
git commit -m "test: update test_runner.zig for change_agent_test.zig"
```

---

## Chunk 2: Handler Rename

### Task 4: Rename handler file and update content

**Files:**
- Rename: `src/ai_workflow/tui/handle_get_agent_tool.zig` → `src/ai_workflow/tui/handle_change_agent_tool.zig`

- [ ] **Step 1: Rename the file**

```bash
mv src/ai_workflow/tui/handle_get_agent_tool.zig src/ai_workflow/tui/handle_change_agent_tool.zig
```

- [ ] **Step 2: Update content in handle_change_agent_tool.zig**

```zig
// Line 4: Update import
const change_agent_tool = tree1_mod.change_agent;  // was: get_agent

// Line 6-8: Update comment
/// Stateless change_agent tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute change_agent

// Line 12: Rename function
pub fn handle_change_agent_tool_run(...)  // was: handle_get_agent_tool_run

// Line 18: Update type reference
    change_agent_tool.ChangeAgentInput,  // was: GetAgentInput

// Line 28: Update error message
    \\  <error>Failed to parse change_agent arguments</error>

// Line 34: Update function call
    const result = change_agent_tool.executeChangeAgentToString(allocator, parsed.value) catch {  // was: executeGetAgentToString

// Line 41: Update error message
    \\  <error>Failed to get agent</error>
```

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/handle_change_agent_tool.zig
git rm src/ai_workflow/tui/handle_get_agent_tool.zig
git commit -m "refactor: rename handle_get_agent_tool.zig to handle_change_agent_tool.zig"
```

---

### Task 5: Create `handle_change_agent_tool_test.zig`

**Files:**
- Create: `src/ai_workflow/tui/handle_change_agent_tool_test.zig` (rename from `handle_get_agent_tool_test.zig`)

- [ ] **Step 1: Rename test file**

```bash
mv src/ai_workflow/tui/handle_get_agent_tool_test.zig src/ai_workflow/tui/handle_change_agent_tool_test.zig
```

- [ ] **Step 2: Update content**

```zig
// Line 3: Update test name
test "handle_change_agent_tool module imports" {

// Line 5: Update import
    const handle_change_agent_tool = @import("handle_change_agent_tool.zig");  // was: handle_get_agent_tool.zig

// Line 6: Update reference
    _ = handle_change_agent_tool;
```

- [ ] **Step 3: Update test_runner.zig import**

In `src/ai_workflow/tui/test_runner.zig`:

```zig
// Line 16
    _ = @import("handle_change_agent_tool_test.zig");  // was: handle_get_agent_tool_test.zig
```

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/handle_change_agent_tool_test.zig
git rm src/ai_workflow/tui/handle_get_agent_tool_test.zig
git add src/ai_workflow/tui/test_runner.zig
git commit -m "test: rename handle_get_agent_tool_test.zig to handle_change_agent_tool_test.zig"
```

---

## Chunk 3: Update All References

### Task 6: Update `src/ai_workflow/tui/handle_tool.zig`

**Files:**
- Modify: `src/ai_workflow/tui/handle_tool.zig`

- [ ] **Step 1: Update tool name in dispatch table (line 78)**

```zig
    .{ .name = "change_agent", .dispatch = dispatchChangeAgent },  // was: "get_agent"
```

- [ ] **Step 2: Update import and handler call (lines 286-287)**

```zig
    const handle_change_agent_tool = @import("handle_change_agent_tool.zig");  // was: handle_get_agent_tool.zig
    const result = try handle_change_agent_tool.handle_change_agent_tool_run(ctx.allocator, tool_call);  // was: handle_get_agent_tool_run
```

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/handle_tool.zig
git commit -m "refactor: update handle_tool.zig for change_agent"
```

---

### Task 7: Update `src/ai_workflow/tui/handle_spawn_sub_agent.zig`

**Files:**
- Modify: `src/ai_workflow/tui/handle_spawn_sub_agent.zig`

- [ ] **Step 1: Update import (line 33)**

```zig
const ChangeAgentTool = root_mod.change_agent;  // was: GetAgentTool, root_mod.get_agent
```

- [ ] **Step 2: Update import (line 44)**

```zig
const handle_change_agent_tool = @import("handle_change_agent_tool.zig");  // was: handle_get_agent_tool.zig
```

- [ ] **Step 3: Update handler call (line 160)**

```zig
    return handle_change_agent_tool.handle_change_agent_tool_run(allocator, tc);  // was: handle_get_agent_tool.handle_get_agent_tool_run
```

- [ ] **Step 4: Update tool registration (line 207)**

```zig
    .{ .name = "change_agent", .exec = execChangeAgent, .tool_def = ChangeAgentTool.ChangeAgentTool, .auto_save_agent = true },  // was: .name = "get_agent", .exec = execGetAgent, .tool_def = GetAgentTool.GetAgentTool
```

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/handle_spawn_sub_agent.zig
git commit -m "refactor: update handle_spawn_sub_agent.zig for change_agent"
```

---

### Task 8: Update `src/ai_workflow/tui/handle_spawn_sub_agent_test.zig`

**Files:**
- Modify: `src/ai_workflow/tui/handle_spawn_sub_agent_test.zig`

- [ ] **Step 1: Update test names and content (lines 347-349)**

```zig
test "executeSubAgentTool - change_agent tool with valid name" {
    const tc = makeToolCall("change_agent", "{\"agent_name\": \"code-reviewer\"}");  // was: "get_agent"
```

- [ ] **Step 2: Commit**

```bash
git add src/ai_workflow/tui/handle_spawn_sub_agent_test.zig
git commit -m "test: update handle_spawn_sub_agent_test.zig for change_agent"
```

---

### Task 9: Update `src/ai_workflow/tui/all_agent_tools.zig`

**Files:**
- Modify: `src/ai_workflow/tui/all_agent_tools.zig`

- [ ] **Step 1: Update import (line 17)**

```zig
const change_agent_tool = root_mod.change_agent_tool;  // was: get_agent_tool, root_mod.get_agent_tool
```

- [ ] **Step 2: Update tool in list (line 63)**

```zig
    change_agent_tool.ChangeAgentTool,  // was: get_agent_tool.GetAgentTool
```

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/all_agent_tools.zig
git commit -m "refactor: update all_agent_tools.zig for change_agent"
```

---

### Task 10: Update TUI display files

**Files:**
- Modify: `src/ai_workflow/tui/display/tool_results.zig`
- Modify: `src/apps/tui/display/tool_results.zig`

- [ ] **Step 1: Update tool_results.zig in ai_workflow (line 60)**

```zig
    } else if (std.mem.eql(u8, tool_name, "change_agent")) {  // was: "get_agent"
```

- [ ] **Step 2: Update comment (line 319)**

```zig
/// Display change_agent result  // was: get_agent result
```

- [ ] **Step 3: Update tool_results.zig in apps/tui (line 60)**

```zig
    } else if (std.mem.eql(u8, tool_name, "change_agent")) {  // was: "get_agent"
```

- [ ] **Step 4: Update comment in apps/tui (line 319)**

```zig
/// Display change_agent result  // was: get_agent result
```

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/display/tool_results.zig src/apps/tui/display/tool_results.zig
git commit -m "refactor: update tool_results.zig files for change_agent"
```

---

### Task 11: Update `src/root.zig`

**Files:**
- Modify: `src/root.zig`

- [ ] **Step 1: Update exports (lines 82-84)**

```zig
pub const change_agent = @import("modules/agent/tools/change_agent.zig");
pub const change_agent_tool = @import("modules/agent/tools/change_agent.zig");
```

- [ ] **Step 2: Commit**

```bash
git add src/root.zig
git commit -m "refactor: update root.zig exports for change_agent"
```

---

## Chunk 4: Update prompt.zig

### Task 12: Update `src/modules/agent/prompt.zig`

**Files:**
- Modify: `src/modules/agent/prompt.zig`

- [ ] **Step 1: Update Available Tools section (around line 169)**

Change from:
```
\\- Dynamic: `get_agent(agent_name)`, `get_agent(path)`
```

To:
```
\\- Dynamic: `change_agent(agent_name)`, `change_agent(path)` — Switch to a different agent persona!
```

- [ ] **Step 2: Update Specialized Agents section (around line 351)**

Change from:
```zig
\\`get_agent(agent_name: "name")`
```

To:
```zig
\\`change_agent(agent_name: "name")` — **Switch your agent persona!**
```

- [ ] **Step 3: Add agent switching encouragement in Agent prompt (around line 65)**

Add after "Available Tools" section or near the end of the Agent prompt:

```zig
\\## Agent Switching
\\
\\**💡 Don't be afraid to switch agents!**
\\- Use `change_agent` to get a different perspective or expertise
\\- Example: `change_agent("code-reviewer")` for quality feedback
\\- Example: `change_agent("zig-expert")` for Zig-specific guidance
\\- Example: `change_agent("frontend-engineer")` for UI/UX work
\\
\\**When to switch:**
\\- Task requires specialized knowledge not in your current persona
\\- You need a fresh perspective on a problem
\\- Code review, security audit, or performance analysis
\\- Different phases of development (planning vs implementation)
```

- [ ] **Step 4: Commit**

```bash
git add src/modules/agent/prompt.zig
git commit -m "feat: update prompt.zig to encourage agent switching with change_agent"
```

---

## Chunk 5: Update AGENT.md

### Task 13: Update `AGENT.md`

**Files:**
- Modify: `AGENT.md`

- [ ] **Step 1: Update Skills/Agents line (line 55)**

Change from:
```
- **Skills/Agents:** list_skill, get_skill, remove_skill, list_agents, get_agent, spawn_sub_agent
```

To:
```
- **Skills/Agents:** list_skill, get_skill, remove_skill, list_agents, change_agent, spawn_sub_agent
```

- [ ] **Step 2: Commit**

```bash
git add AGENT.md
git commit -m "docs: update AGENT.md for change_agent"
```

---

## Chunk 6: Verify and Test

### Task 14: Build and test

- [ ] **Step 1: Run build to verify compilation**

```bash
zig build 2>&1 | head -n 50
```

Expected: Successful compilation with no errors

- [ ] **Step 2: Run tests**

```bash
zig build test 2>&1 | head -n 100
```

Expected: All tests pass

- [ ] **Step 3: Run TUI to verify tool registration**

```bash
./zig-out/bin/nalar-dev-tui --port 8082 --process nalar-dev 2>&1 | head -n 50
```

Or check the HTTP API endpoint for tool definitions.

- [ ] **Step 4: Commit final verification**

```bash
git add -A
git commit -m "chore: verify build and tests pass after change_agent rename"
```

---

## Summary of Changes

| Category | Files Changed | Key Changes |
|----------|---------------|-------------|
| Core Tool | 2 files renamed | `get_agent.zig` → `change_agent.zig`, `get_agent_test.zig` → `change_agent_test.zig` |
| Handlers | 2 files renamed | `handle_get_agent_tool.zig` → `handle_change_agent_tool.zig` |
| References | 6 files modified | All tool name references updated |
| TUI Display | 2 files modified | Tool result display updated |
| Root | 1 file modified | Export names updated |
| Prompt | 1 file modified | Tool name changed, encouragement added |
| Documentation | 1 file modified | AGENT.md updated |
| **Total** | **~15 files** | **Complete rename with enhanced functionality** |

---

## Verification Checklist

- [ ] `zig build` compiles successfully
- [ ] `zig build test` passes all tests
- [ ] Tool name "change_agent" appears in tool definitions
- [ ] Prompt encourages agent switching
- [ ] All `get_agent` references replaced with `change_agent`
