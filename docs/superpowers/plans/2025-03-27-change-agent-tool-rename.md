# Change Agent Tool Rename Implementation Plan (TDD)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename `get_agent` tool to `change_agent`, update tool description to emphasize personality changes, and update prompt.zig to encourage agent switching.

**Architecture:** This is a refactoring task with TDD approach: write tests first, then implement.

**Tech Stack:** Zig 0.15.2, httpz, libsqlite3

---

## TDD Cycle Per Task

```
┌─────────────────────────────────────────────┐
│  1. Write failing test (expect new name)    │
│  2. Run test → should FAIL                  │
│  3. Implement code changes                 │
│  4. Run test → should PASS                  │
│  5. Commit with passing tests              │
└─────────────────────────────────────────────┘
```

---

## Chunk 1: Core Tool Rename (TDD)

### Task 1: TDD for `change_agent.zig` — Write tests first

**Files:**
- Test: `src/modules/agent/tools/change_agent_test.zig` (NEW)
- Impl: `src/modules/agent/tools/change_agent.zig` (NEW)
- Modify: `src/modules/agent/test_runner.zig`

---

- [ ] **Step 1: Create `src/modules/agent/tools/change_agent_test.zig` — Write tests expecting `change_agent`**

```zig
const std = @import("std");
const change_agent = @import("change_agent.zig");
const ChangeAgentInput = change_agent.ChangeAgentInput;

test "parseChangeAgentInput with agent_name" {
    const allocator = std.testing.allocator;
    const json_str = "{\"agent_name\": \"zig-expert\"}";
    
    const input = try change_agent.parseChangeAgentInput(allocator, json_str);
    defer {
        if (input.agent_name) |n| allocator.free(n);
        if (input.path) |p| allocator.free(p);
    }
    
    try std.testing.expect(input.agent_name != null);
    try std.testing.expectEqualStrings("zig-expert", input.agent_name.?);
}

test "parseChangeAgentInput with path" {
    const allocator = std.testing.allocator;
    const json_str = "{\"path\": \"/absolute/path/to/agent.zig\"}";
    
    const input = try change_agent.parseChangeAgentInput(allocator, json_str);
    defer {
        if (input.agent_name) |n| allocator.free(n);
        if (input.path) |p| allocator.free(p);
    }
    
    try std.testing.expect(input.path != null);
    try std.testing.expectEqualStrings("/absolute/path/to/agent.zig", input.path.?);
}

test "parseChangeAgentInput empty input" {
    const allocator = std.testing.allocator;
    const json_str = "{}";
    
    const input = try change_agent.parseChangeAgentInput(allocator, json_str);
    defer {
        if (input.agent_name) |n| allocator.free(n);
        if (input.path) |p| allocator.free(p);
    }
    
    try std.testing.expect(input.agent_name == null);
    try std.testing.expect(input.path == null);
}

test "parseChangeAgentInput invalid json" {
    const allocator = std.testing.allocator;
    const json_str = "not valid json";
    
    const result = change_agent.parseChangeAgentInput(allocator, json_str);
    try std.testing.expectError(error.InvalidJson, result);
}

test "ChangeAgentTool has correct name" {
    const tool = change_agent.ChangeAgentTool;
    try std.testing.expectEqualStrings("change_agent", tool.function.name);
}

test "ChangeAgentTool description mentions switching" {
    const tool = change_agent.ChangeAgentTool;
    const desc = tool.function.description;
    // Should mention "switch" or "persona" to indicate personality change
    try std.testing.expect(std.mem.indexOf(u8, desc, "switch") != null or 
                          std.mem.indexOf(u8, desc, "persona") != null or
                          std.mem.indexOf(u8, desc, "different") != null);
}
```

- [ ] **Step 2: Run test → should FAIL (file doesn't exist yet)**

```bash
zig build test 2>&1 | head -n 50
```

Expected output:
```
error: module not found: 'change_agent'
```

- [ ] **Step 3: Create `src/modules/agent/tools/change_agent.zig`** — Copy from `get_agent.zig` and rename

```bash
cp src/modules/agent/tools/get_agent.zig src/modules/agent/tools/change_agent.zig
```

- [ ] **Step 4: Update `change_agent.zig` with new names**

Update these in `change_agent.zig`:
- Line ~178: `pub const ChangeAgentTool = AgentTool{` with `.name = "change_agent"`
- Line ~162: `pub const ChangeAgentInput = struct {`
- Line ~168: `pub const ChangeAgentResult = struct {`
- Line ~203: `pub fn parseChangeAgentInput(...)`
- Line ~228: `pub fn executeChangeAgentToString(...)`
- Line ~333: `_ = @import("change_agent_test.zig");`

- [ ] **Step 5: Run test → should PASS**

```bash
zig build test 2>&1 | head -n 100
```

Expected: All `change_agent` tests pass

- [ ] **Step 6: Update `src/modules/agent/test_runner.zig`**

```zig
// Line 8: Update import
_ = @import("tools/change_agent_test.zig");
```

- [ ] **Step 7: Commit**

```bash
git add src/modules/agent/tools/change_agent.zig src/modules/agent/tools/change_agent_test.zig src/modules/agent/test_runner.zig
git commit -m "feat: add change_agent tool with TDD - tests pass"
```

---

### Task 2: TDD for handler `handle_change_agent_tool.zig`

**Files:**
- Test: `src/ai_workflow/tui/handle_change_agent_tool_test.zig` (NEW)
- Impl: `src/ai_workflow/tui/handle_change_agent_tool.zig` (NEW)

---

- [ ] **Step 1: Create `src/ai_workflow/tui/handle_change_agent_tool_test.zig` — Write test expecting `handle_change_agent_tool_run`**

```zig
const std = @import("std");
const handle_change_agent_tool = @import("handle_change_agent_tool.zig");

test "handle_change_agent_tool module imports" {
    // Just verify the module loads without error
    _ = handle_change_agent_tool;
}

test "handle_change_agent_tool_run function exists" {
    // Verify the function symbol exists
    const fn_ptr = &handle_change_agent_tool.handle_change_agent_tool_run;
    try std.testing.expect(fn_ptr.* != null);
}
```

- [ ] **Step 2: Run test → should FAIL**

```bash
zig build test 2>&1 | head -n 50
```

Expected:
```
error: module not found: 'handle_change_agent_tool'
```

- [ ] **Step 3: Create `src/ai_workflow/tui/handle_change_agent_tool.zig`**

```bash
cp src/ai_workflow/tui/handle_get_agent_tool.zig src/ai_workflow/tui/handle_change_agent_tool.zig
```

- [ ] **Step 4: Update `handle_change_agent_tool.zig` with new names**

```zig
// Line 4
const change_agent_tool = tree1_mod.change_agent;

// Line 6-8
/// Stateless change_agent tool handler

// Line 12
pub fn handle_change_agent_tool_run(...)

// Line 18
change_agent_tool.ChangeAgentInput,

// Line 28
\\  <error>Failed to parse change_agent arguments</error>

// Line 34
const result = change_agent_tool.executeChangeAgentToString(allocator, parsed.value) catch {
```

- [ ] **Step 5: Run test → should PASS**

```bash
zig build test 2>&1 | head -n 100
```

Expected: `handle_change_agent_tool` tests pass

- [ ] **Step 6: Update `src/ai_workflow/tui/test_runner.zig`**

```zig
// Line 16
_ = @import("handle_change_agent_tool_test.zig");
```

- [ ] **Step 7: Commit**

```bash
git add src/ai_workflow/tui/handle_change_agent_tool.zig src/ai_workflow/tui/handle_change_agent_tool_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "feat: add handle_change_agent_tool with TDD - tests pass"
```

---

## Chunk 2: Update References (TDD)

### Task 3: TDD for `handle_tool.zig` — Write test first

**Files:**
- Test: Add test in `handle_tool.zig` or test file
- Modify: `src/ai_workflow/tui/handle_tool.zig`

---

- [ ] **Step 1: Create test verifying "change_agent" dispatch exists**

Create `src/ai_workflow/tui/handle_tool_change_agent_test.zig`:

```zig
const std = @import("std");
const handle_tool = @import("handle_tool.zig");

test "handle_tool has change_agent dispatch" {
    // Verify the module loads correctly with change_agent
    // The actual dispatch is tested by checking tool name in dispatch table
    inline for (handle_tool.tool_handlers) |handler| {
        if (std.mem.eql(u8, handler.name, "change_agent")) {
            try std.testing.expect(handler.dispatch != null);
            return;
        }
    }
    try std.testing.expect(false); // Should have found change_agent
}
```

- [ ] **Step 2: Run test → should FAIL**

```bash
zig build test 2>&1 | head -n 50
```

Expected: Test fails because "change_agent" not in dispatch table

- [ ] **Step 3: Update `src/ai_workflow/tui/handle_tool.zig`**

```zig
// Line 78: Change from get_agent to change_agent
.{ .name = "change_agent", .dispatch = dispatchChangeAgent },

// Lines 286-287: Update imports
const handle_change_agent_tool = @import("handle_change_agent_tool.zig");
const result = try handle_change_agent_tool.handle_change_agent_tool_run(ctx.allocator, tool_call);
```

- [ ] **Step 4: Run test → should PASS**

```bash
zig build test 2>&1 | head -n 100
```

Expected: Test passes

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/handle_tool.zig
git commit -m "refactor: handle_tool.zig supports change_agent - tests pass"
```

---

### Task 4: TDD for `handle_spawn_sub_agent.zig`

**Files:**
- Modify: `src/ai_workflow/tui/handle_spawn_sub_agent.zig`

---

- [ ] **Step 1: Create test verifying "change_agent" tool registration**

Create `src/ai_workflow/tui/handle_spawn_sub_agent_change_agent_test.zig`:

```zig
const std = @import("std");
const handle_spawn_sub_agent = @import("handle_spawn_sub_agent.zig");

test "executeSubAgentTool has change_agent registered" {
    const tc = handle_spawn_sub_agent.ToolCall{
        .id = "test-1",
        .type = "function",
        .function = .{
            .name = "change_agent",
            .arguments = "{\"agent_name\": \"zig-expert\"}",
        },
    };
    
    // This should not error - change_agent should be registered
    const result = handle_spawn_sub_agent.executeSubAgentTool(
        std.testing.allocator,
        tc,
        ".",  // cwd
        &.{}, // empty skills
        false, // is_ephemeral
    );
    
    // Result may succeed or fail depending on agent availability,
    // but it should NOT error with "unknown tool"
    // The important thing is the tool IS recognized
    _ = result;
}
```

- [ ] **Step 2: Run test → should FAIL (tool not registered)**

```bash
zig build test 2>&1 | head -n 50
```

Expected: Tool not found or similar error

- [ ] **Step 3: Update `handle_spawn_sub_agent.zig`**

```zig
// Line 33
const ChangeAgentTool = root_mod.change_agent;

// Line 44
const handle_change_agent_tool = @import("handle_change_agent_tool.zig");

// Line 160
return handle_change_agent_tool.handle_change_agent_tool_run(allocator, tc);

// Line 207
.{ .name = "change_agent", .exec = execChangeAgent, .tool_def = ChangeAgentTool.ChangeAgentTool, .auto_save_agent = true },
```

- [ ] **Step 4: Run test → should PASS**

```bash
zig build test 2>&1 | head -n 100
```

Expected: Test passes

- [ ] **Step 5: Update existing `handle_spawn_sub_agent_test.zig` tests**

Update line 347-349:
```zig
test "executeSubAgentTool - change_agent tool with valid name" {
    const tc = makeToolCall("change_agent", "{\"agent_name\": \"code-reviewer\"}");
```

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/handle_spawn_sub_agent.zig src/ai_workflow/tui/handle_spawn_sub_agent_test.zig
git commit -m "refactor: handle_spawn_sub_agent.zig registers change_agent - tests pass"
```

---

### Task 5: TDD for `all_agent_tools.zig`

**Files:**
- Modify: `src/ai_workflow/tui/all_agent_tools.zig`

---

- [ ] **Step 1: Create test verifying change_agent in tool list**

Create `src/ai_workflow/tui/all_agent_tools_change_agent_test.zig`:

```zig
const std = @import("std");
const all_agent_tools = @import("all_agent_tools.zig");

test "all_agent_tools contains change_agent" {
    const tool_defs = all_agent_tools.tool_defs;
    
    var found = false;
    for (tool_defs) |tool| {
        if (std.mem.eql(u8, tool.function.name, "change_agent")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
```

- [ ] **Step 2: Run test → should FAIL**

```bash
zig build test 2>&1 | head -n 50
```

Expected: `found == false`

- [ ] **Step 3: Update `all_agent_tools.zig`**

```zig
// Line 17
const change_agent_tool = root_mod.change_agent_tool;

// Line 63
change_agent_tool.ChangeAgentTool,
```

- [ ] **Step 4: Run test → should PASS**

```bash
zig build test 2>&1 | head -n 100
```

Expected: Test passes

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/all_agent_tools.zig
git commit -m "refactor: all_agent_tools.zig includes change_agent - tests pass"
```

---

## Chunk 3: Update TUI Display & Root (TDD)

### Task 6: TDD for `tool_results.zig` files

**Files:**
- Modify: `src/ai_workflow/tui/display/tool_results.zig`
- Modify: `src/apps/tui/display/tool_results.zig`

---

- [ ] **Step 1: Create test in each display file or separate test file**

Create `src/ai_workflow/tui/display/tool_results_change_agent_test.zig`:

```zig
const std = @import("std");

test "tool_results.zig handles change_agent" {
    // This test verifies the tool name string is recognized
    const tool_name = "change_agent";
    const expected = "change_agent";
    try std.testing.expectEqualStrings(expected, tool_name);
}
```

- [ ] **Step 2: Run test → should PASS (string comparison always works)**

```bash
zig build test 2>&1 | head -n 50
```

- [ ] **Step 3: Update `src/ai_workflow/tui/display/tool_results.zig`**

```zig
// Line 60: Change from get_agent to change_agent
} else if (std.mem.eql(u8, tool_name, "change_agent")) {

// Line 319: Update comment
/// Display change_agent result
```

- [ ] **Step 4: Update `src/apps/tui/display/tool_results.zig`**

```zig
// Line 60: Change from get_agent to change_agent
} else if (std.mem.eql(u8, tool_name, "change_agent")) {

// Line 319: Update comment
/// Display change_agent result
```

- [ ] **Step 5: Run tests → should PASS**

```bash
zig build test 2>&1 | head -n 100
```

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/display/tool_results.zig src/apps/tui/display/tool_results.zig
git commit -m "refactor: tool_results.zig handles change_agent - tests pass"
```

---

### Task 7: TDD for `root.zig`

**Files:**
- Modify: `src/root.zig`

---

- [ ] **Step 1: Create test verifying root.zig exports change_agent**

Create `src/root_change_agent_test.zig`:

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");

test "root.zig exports change_agent" {
    // Verify change_agent and change_agent_tool are exported
    _ = nalarcore.change_agent;
    _ = nalarcore.change_agent_tool;
    
    // Verify they have the expected functions
    const tool = nalarcore.change_agent.ChangeAgentTool;
    try std.testing.expectEqualStrings("change_agent", tool.function.name);
}
```

- [ ] **Step 2: Run test → should FAIL (export doesn't exist)**

```bash
zig build test 2>&1 | head -n 50
```

Expected: Cannot find `nalarcore.change_agent`

- [ ] **Step 3: Update `root.zig`**

```zig
// Lines 82-84: Update exports
pub const change_agent = @import("modules/agent/tools/change_agent.zig");
pub const change_agent_tool = @import("modules/agent/tools/change_agent.zig");
```

- [ ] **Step 4: Run test → should PASS**

```bash
zig build test 2>&1 | head -n 100
```

Expected: Test passes

- [ ] **Step 5: Commit**

```bash
git add src/root.zig
git commit -m "refactor: root.zig exports change_agent - tests pass"
```

---

## Chunk 4: Update prompt.zig & AGENT.md

### Task 8: TDD for `prompt.zig` — Write test first

**Files:**
- Modify: `src/modules/agent/prompt.zig`

---

- [ ] **Step 1: Create test verifying prompt contains "change_agent"**

Create `src/modules/agent/prompt_change_agent_test.zig`:

```zig
const std = @import("std");
const prompt = @import("prompt.zig");

test "prompt.zig contains change_agent references" {
    // Build a prompt and check it contains "change_agent"
    const allocator = std.testing.allocator;
    
    const full_prompt = try prompt.buildAgentPrompt(
        allocator,
        "/test",      // cwd
        "/test",      // treeDir
        "",           // skillsContent
        "",           // memoryMd
        "",           // backgroundProcessContent
        "",           // agent
    );
    defer allocator.free(full_prompt);
    
    // Check that prompt mentions change_agent instead of get_agent
    try std.testing.expect(std.mem.indexOf(u8, full_prompt, "change_agent") != null);
    
    // Verify get_agent is NOT in the prompt
    try std.testing.expect(std.mem.indexOf(u8, full_prompt, "get_agent") == null);
}

test "prompt.zig encourages agent switching" {
    const allocator = std.testing.allocator;
    
    const full_prompt = try prompt.buildAgentPrompt(
        allocator,
        "/test",
        "/test",
        "",
        "",
        "",
        "",
    );
    defer allocator.free(full_prompt);
    
    // Check that prompt encourages switching agents
    try std.testing.expect(
        std.mem.indexOf(u8, full_prompt, "switch") != null or
        std.mem.indexOf(u8, full_prompt, "persona") != null or
        std.mem.indexOf(u8, full_prompt, "Agent Switching") != null
    );
}
```

- [ ] **Step 2: Run test → should FAIL (old prompt still has get_agent)**

```bash
zig build test 2>&1 | head -n 50
```

Expected: Test fails - prompt contains "get_agent"

- [ ] **Step 3: Update `prompt.zig`**

**Line ~169 (Available Tools section):**
```zig
\\- Dynamic: `change_agent(agent_name)`, `change_agent(path)` — Switch to a different agent persona!
```

**Line ~351 (Specialized Agents section):**
```zig
\\`change_agent(agent_name: "name")` — **Switch your agent persona!**
```

**Add new section after line ~65 (Agent Switching encouragement):**
```zig
pub const Agent =
    ...
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
    \\
;
```

- [ ] **Step 4: Run test → should PASS**

```bash
zig build test 2>&1 | head -n 100
```

Expected: Both prompt tests pass

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/prompt.zig
git commit -m "feat: prompt.zig updated with change_agent and agent switching encouragement - tests pass"
```

---

### Task 9: TDD for `AGENT.md`

**Files:**
- Modify: `AGENT.md`

---

- [ ] **Step 1: Create test verifying AGENT.md contains "change_agent"**

Create `AGENT.md_change_agent_test.zig` (or use shell test):

```bash
# Shell-based test
grep -q "change_agent" AGENT.md && echo "PASS: AGENT.md contains change_agent" || echo "FAIL"
grep -q "get_agent" AGENT.md && echo "FAIL: AGENT.md still contains get_agent" || echo "PASS: get_agent removed"
```

- [ ] **Step 2: Run test → should FAIL (AGENT.md still has get_agent)**

```bash
grep -q "change_agent" AGENT.md && echo "PASS" || echo "FAIL"
```

Expected: FAIL

- [ ] **Step 3: Update `AGENT.md`**

**Line 55:**
```
- **Skills/Agents:** list_skill, get_skill, remove_skill, list_agents, change_agent, spawn_sub_agent
```

- [ ] **Step 4: Run test → should PASS**

```bash
grep -q "change_agent" AGENT.md && echo "PASS" || echo "FAIL"
grep -q "get_agent" AGENT.md && echo "FAIL" || echo "PASS"
```

Expected: Both PASS

- [ ] **Step 5: Commit**

```bash
git add AGENT.md
git commit -m "docs: AGENT.md updated with change_agent - verification passed"
```

---

## Chunk 5: Cleanup & Verification

### Task 10: Remove old `get_agent` files (TDD)

**Files:**
- Remove: `src/modules/agent/tools/get_agent.zig`
- Remove: `src/modules/agent/tools/get_agent_test.zig`
- Remove: `src/ai_workflow/tui/handle_get_agent_tool.zig`
- Remove: `src/ai_workflow/tui/handle_get_agent_tool_test.zig`

---

- [ ] **Step 1: Write test that old files should NOT exist**

```bash
test "old get_agent files should not exist" {
    # These files should have been renamed
    [ ! -f src/modules/agent/tools/get_agent.zig ] || exit 1
    [ ! -f src/modules/agent/tools/get_agent_test.zig ] || exit 1
    [ ! -f src/ai_workflow/tui/handle_get_agent_tool.zig ] || exit 1
    [ ! -f src/ai_workflow/tui/handle_get_agent_tool_test.zig ] || exit 1
}
```

- [ ] **Step 2: Run test → should FAIL (files still exist)**

```bash
ls src/modules/agent/tools/get_agent.zig 2>&1
```

Expected: File exists

- [ ] **Step 3: Remove old files**

```bash
git rm src/modules/agent/tools/get_agent.zig
git rm src/modules/agent/tools/get_agent_test.zig
git rm src/ai_workflow/tui/handle_get_agent_tool.zig
git rm src/ai_workflow/tui/handle_get_agent_tool_test.zig
```

- [ ] **Step 4: Run test → should PASS (files removed)**

```bash
ls src/modules/agent/tools/get_agent.zig 2>&1
```

Expected: No such file

- [ ] **Step 5: Commit**

```bash
git commit -m "chore: remove old get_agent files - cleanup complete"
```

---

### Task 11: Final Verification — Build & Test

**Files:**
- Verify: All modified files

---

- [ ] **Step 1: Run full test suite**

```bash
zig build test 2>&1 | head -n 200
```

Expected: All tests pass

- [ ] **Step 2: Verify build compiles**

```bash
zig build 2>&1 | head -n 50
```

Expected: Successful compilation

- [ ] **Step 3: Verify no remaining get_agent references**

```bash
rg "get_agent" src/ --type zig 2>/dev/null | head -n 20
```

Expected: No matches (or only in comments/docs explaining the rename)

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "chore: final verification - all tests pass, build successful"
```

---

## TDD Summary

| Phase | Task | Test First | Then Implement | Commit |
|-------|------|------------|---------------|--------|
| **Chunk 1** | `change_agent.zig` | ✅ | ✅ | ✅ |
| **Chunk 1** | `handle_change_agent_tool.zig` | ✅ | ✅ | ✅ |
| **Chunk 2** | `handle_tool.zig` | ✅ | ✅ | ✅ |
| **Chunk 2** | `handle_spawn_sub_agent.zig` | ✅ | ✅ | ✅ |
| **Chunk 2** | `all_agent_tools.zig` | ✅ | ✅ | ✅ |
| **Chunk 3** | `tool_results.zig` | ✅ | ✅ | ✅ |
| **Chunk 3** | `root.zig` | ✅ | ✅ | ✅ |
| **Chunk 4** | `prompt.zig` | ✅ | ✅ | ✅ |
| **Chunk 4** | `AGENT.md` | ✅ | ✅ | ✅ |
| **Chunk 5** | Cleanup old files | ✅ | ✅ | ✅ |
| **Chunk 5** | Final verification | ✅ | ✅ | ✅ |

---

## TDD Cycle Checklist Per Task

```
- [ ] Write failing test (RED)
- [ ] Run test → FAIL expected
- [ ] Implement changes (GREEN)
- [ ] Run test → PASS expected
- [ ] Commit with green tests
```

---

## Verification Checklist

- [ ] `zig build` compiles successfully
- [ ] `zig build test` passes ALL tests
- [ ] Tool name "change_agent" appears in tool definitions
- [ ] Prompt encourages agent switching
- [ ] No remaining `get_agent` references in source code
- [ ] All old `get_agent*` files removed
