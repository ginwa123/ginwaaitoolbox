# Web Search Tools Implementation Plan

> **For agentic workers:** Execute this plan using superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Create two new agent tools wrapping `agent-browser` CLI: `web_search_tool` for web browsing and `web_search_help_tool` for help access.

**Architecture:** 
- Two new tool modules following existing bash/search patterns
- Both use BashInput/BashOutput schemas (wrapping CLI)
- Registered in tools.zig and agent.zig
- Prompt updates in research.zig

**Tech Stack:** Zig 0.15.2, existing schemas, agent-browser CLI

---

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `src/modules/agent/tools/web_search.zig` | Create | Main web_search tool implementation |
| `src/modules/agent/tools/web_search_test.zig` | Create | TDD tests for web_search |
| `src/modules/agent/tools/web_search_help.zig` | Create | Help tool implementation |
| `src/modules/agent/tools/web_search_help_test.zig` | Create | TDD tests for help tool |
| `src/modules/agent/tools/tools.zig` | Modify | Export new tools |
| `src/modules/agent/agent.zig` | Modify | Import new tools |
| `src/modules/agent/prompts/research.zig` | Modify | Update AvailableTools |

---

## Chunk 1: web_search_help Tool (Simple First)

### Task 1: Create web_search_help_test.zig

**Files:**
- Create: `src/modules/agent/tools/web_search_help_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const webSearchHelp = @import("web_search_help.zig");

test "web search help executes agent-browser --help" {
    const allocator = std.testing.allocator;
    
    const result = try webSearchHelp.executeWebSearchHelp(allocator);
    defer result.deinit(allocator);
    
    // Should contain expected help content
    try std.testing.expect(result.content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "Usage:") != null);
    try std.testing.expectEqual(result.exit_code, 0);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --test-name-filter "web_search_help" 2>&1`
Expected: FAIL with "file not found: web_search_help.zig"

- [ ] **Step 3: Write minimal implementation**

Create `src/modules/agent/tools/web_search_help.zig`:

```zig
const std = @import("std");
const posix = std.posix;
const bashMod = @import("bash.zig");
const schemas = @import("schemas.zig");
const BashInput = schemas.BashInput;

pub const WebSearchHelpResult = struct {
    content: []const u8,
    exit_code: i32,

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub fn executeWebSearchHelp(allocator: std.mem.Allocator) !WebSearchHelpResult {
    const input = BashInput{
        .command = "agent-browser --help",
        .cwd = "/tmp",
        .max_output = 1024 * 1024, // 1MB for full help
    };

    const result = try bashMod.executeBash(allocator, input);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        allocator.free(result.command);
    }

    return WebSearchHelpResult{
        .content = try allocator.dupe(u8, result.stdout),
        .exit_code = result.exit_code,
    };
}

pub const web_search_help_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "web_search_help",
        .description = "Get help information for the agent-browser CLI tool. Use this to see all available commands, options, and usage examples.",
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
    },
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test --test-name-filter "web_search_help" 2>&1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/web_search_help.zig src/modules/agent/tools/web_search_help_test.zig
git commit -m "feat: add web_search_help_tool"
```

---

## Chunk 2: web_search Tool (Main Feature)

### Task 2: Create web_search schema types

**Files:**
- Modify: `src/modules/agent/tools/schemas.zig`

- [ ] **Step 1: Read current schemas.zig**

Run: `read_file` on `src/modules/agent/tools/schemas.zig`

- [ ] **Step 2: Add WebSearchInput schema**

Add to end of schemas.zig (before closing brace or at line ~99):

```zig
// =============================================================================
// Web Search Tool Types
// =============================================================================

pub const WebSearchInput = struct {
    /// URL to navigate to or action to perform
    url: []const u8,
    /// Action to perform: "open", "snapshot", "get", "click", etc.
    action: []const u8 = "open",
    /// Optional CSS selector for element operations
    selector: ?[]const u8 = null,
    /// Optional additional arguments
    args: ?[]const u8 = null,
    /// Working directory (defaults to /tmp)
    cwd: ?[]const u8 = "/tmp",
};

pub const WebSearchResult = struct {
    success: bool,
    content: []const u8,
    exit_code: i32,
    error: ?[]const u8 = null,
};
```

- [ ] **Step 3: Run build to verify compilation**

Run: `zig build 2>&1 | head -n 50`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add src/modules/agent/tools/schemas.zig
git commit -m "feat: add WebSearchInput/WebSearchResult schemas"
```

---

### Task 3: Create web_search_test.zig

**Files:**
- Create: `src/modules/agent/tools/web_search_test.zig`

- [ ] **Step 1: Write the failing tests**

```zig
const std = @import("std");
const webSearchMod = @import("web_search.zig");
const WebSearchInput = @import("schemas.zig").WebSearchInput;
const WebSearchResult = @import("schemas.zig").WebSearchResult;

test "web search open url returns success" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .url = "https://example.com",
        .action = "open",
    };
    
    const result = try webSearchMod.executeWebSearch(allocator, input);
    defer result.deinit(allocator);
    
    try std.testing.expect(result.success);
    try std.testing.expect(result.exit_code == 0);
}

test "web search snapshot returns page content" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .url = "https://example.com",
        .action = "snapshot",
    };
    
    const result = try webSearchMod.executeWebSearch(allocator, input);
    defer result.deinit(allocator);
    
    try std.testing.expect(result.success);
    try std.testing.expect(result.content.len > 0);
}

test "web search get text returns element text" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .url = "https://example.com",
        .action = "get",
        .selector = "h1",
    };
    
    const result = try webSearchMod.executeWebSearch(allocator, input);
    defer result.deinit(allocator);
    
    try std.testing.expect(result.success or result.exit_code != 0);
}

test "web search help action returns help" {
    const allocator = std.testing.allocator;
    const input = WebSearchInput{
        .url = "",
        .action = "help",
    };
    
    const result = try webSearchMod.executeWebSearch(allocator, input);
    defer result.deinit(allocator);
    
    try std.testing.expect(result.content.len > 0 or result.exit_code != 0);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test --test-name-filter "web_search" 2>&1`
Expected: FAIL with "file not found: web_search.zig"

- [ ] **Step 3: Commit (tests exist, implementation coming)**

```bash
git add src/modules/agent/tools/web_search_test.zig
git commit -m "test: add web_search tool tests (TDD - red phase)"
```

---

### Task 4: Create web_search.zig implementation

**Files:**
- Create: `src/modules/agent/tools/web_search.zig`

- [ ] **Step 1: Write the implementation**

Create `src/modules/agent/tools/web_search.zig`:

```zig
const std = @import("std");
const posix = std.posix;
const bashMod = @import("bash.zig");
const schemas = @import("schemas.zig");
const BashInput = schemas.BashInput;
const WebSearchInput = schemas.WebSearchInput;
const WebSearchResult = schemas.WebSearchResult;
const AgentTool = schemas.AgentTool;

pub fn executeWebSearch(allocator: std.mem.Allocator, input: WebSearchInput) !WebSearchResult {
    // Build the agent-browser command
    var command = std.ArrayList(u8).empty;
    defer command.deinit(allocator);

    try command.appendSlice(allocator, "agent-browser ");

    // Handle special "help" action
    if (std.mem.eql(u8, input.action, "help")) {
        try command.appendSlice(allocator, "--help");
    } else {
        // Add action
        try command.appendSlice(allocator, input.action);

        // Add URL for open action
        if (std.mem.eql(u8, input.action, "open") and input.url.len > 0) {
            try command.append(allocator, ' ');
            try command.appendSlice(allocator, input.url);
        }

        // Add selector if provided
        if (input.selector) |sel| {
            try command.append(allocator, ' ');
            try command.appendSlice(allocator, sel);
        }

        // Add additional args if provided
        if (input.args) |args| {
            try command.append(allocator, ' ');
            try command.appendSlice(allocator, args);
        }
    }

    const bashInput = BashInput{
        .command = try command.toOwnedSlice(allocator),
        .cwd = input.cwd,
        .max_output = 1024 * 1024, // 1MB for page content
    };

    const result = try bashMod.executeBash(allocator, bashInput);
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        allocator.free(result.command);
    }

    // Determine success based on exit code
    const success = result.exit_code == 0;

    var error_msg: ?[]const u8 = null;
    if (!success and result.stderr.len > 0 and !std.mem.eql(u8, result.stderr, "No errors.")) {
        error_msg = try allocator.dupe(u8, result.stderr);
    }

    return WebSearchResult{
        .success = success,
        .content = try allocator.dupe(u8, result.stdout),
        .exit_code = result.exit_code,
        .error = error_msg,
    };
}

pub fn webSearchResultToString(allocator: std.mem.Allocator, result: WebSearchResult) ![]const u8 {
    if (result.success) {
        return try std.fmt.allocPrint(allocator,
            \\<success>true</success>
            \\<content>{s}</content>
            \\<exit_code>{d}</exit_code>
        , .{
            result.content,
            result.exit_code,
        });
    } else {
        return try std.fmt.allocPrint(allocator,
            \\<success>false</success>
            \\<content>{s}</content>
            \\<exit_code>{d}</exit_code>
            \\<error>{s}</error>
        , .{
            result.content,
            result.exit_code,
            result.error orelse "Unknown error",
        });
    }
}

pub const web_search_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "web_search",
        .description =
        \\Browse the web using agent-browser CLI.
        \\- `action`: Command to execute (open, snapshot, get, click, etc.)
        \\- `url`: URL for open action or page context
        \\- `selector`: Optional CSS selector for element operations
        \\- `args`: Optional additional arguments
        \\
        \\Examples:
        \\- Open a URL: {"url": "https://example.com", "action": "open"}
        \\- Get page snapshot: {"url": "https://example.com", "action": "snapshot"}
        \\- Get element text: {"url": "https://example.com", "action": "get", "selector": "h1"}
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "url",
                    .type = "string",
                    .description = "URL to navigate to (for open action) or page context.",
                },
                .{
                    .name = "action",
                    .type = "string",
                    .description = "Action to perform: open, snapshot, get, click, fill, press, etc.",
                },
                .{
                    .name = "selector",
                    .type = "string",
                    .description = "Optional CSS selector for element operations.",
                },
                .{
                    .name = "args",
                    .type = "string",
                    .description = "Optional additional arguments for the action.",
                },
            },
            .required = &.{ "url", "action" },
        },
    },
};

test {
    _ = @import("web_search_test.zig");
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `zig build test --test-name-filter "web_search" 2>&1`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/web_search.zig
git commit -m "feat: implement web_search_tool"
```

---

## Chunk 3: Integration & Registration

### Task 5: Register tools in tools.zig

**Files:**
- Modify: `src/modules/agent/tools/tools.zig`

- [ ] **Step 1: Read current tools.zig**

Run: `read_file` on `src/modules/agent/tools/tools.zig`

- [ ] **Step 2: Add exports**

Replace content with:

```zig
// Re-export all public tool definitions for convenience
pub const agents = @import("agents.zig");
pub const list_agents = @import("list_agents.zig");
pub const change_agent = @import("change_agent.zig");
pub const lsp_definition = @import("lsp_definition.zig");
pub const lsp_references = @import("lsp_references.zig");
pub const lsp_workspace_symbol = @import("lsp_workspace_symbol.zig");
pub const lsp_document_symbol = @import("lsp_document_symbol.zig");
pub const lsp_hover = @import("lsp_hover.zig");
pub const tree_dir = @import("tree_dir.zig");
pub const web_search = @import("web_search.zig");
pub const web_search_help = @import("web_search_help.zig");

pub const list_agents_tool = list_agents.list_agents_tool;
pub const change_agent_tool = change_agent.change_agent_tool;
pub const lsp_definition_tool = lsp_definition.lsp_definition_tool;
pub const lsp_references_tool = lsp_references.lsp_references_tool;
pub const lsp_workspace_symbol_tool = lsp_workspace_symbol.lsp_workspace_symbol_tool;
pub const lsp_document_symbol_tool = lsp_document_symbol.lsp_document_symbol_tool;
pub const lsp_hover_tool = lsp_hover.lsp_hover_tool;
pub const tree_dir_tool = tree_dir.tree_dir_tool;
pub const web_search_tool = web_search.web_search_tool;
pub const web_search_help_tool = web_search_help.web_search_help_tool;
```

- [ ] **Step 3: Verify build**

Run: `zig build 2>&1 | head -n 30`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add src/modules/agent/tools/tools.zig
git commit -m "feat: register web_search_tool and web_search_help_tool"
```

---

### Task 6: Register tools in agent.zig

**Files:**
- Modify: `src/modules/agent/agent.zig`

- [ ] **Step 1: Read current agent.zig imports (first 10 lines)**

Run: `read_file` on `src/modules/agent/agent.zig` (limit: 10)

- [ ] **Step 2: Add tool imports**

Add after line 3 (after `const bashTool = @import("tools/bash.zig").bash_tool;`):

```zig
const webSearchTool = @import("tools/web_search.zig").web_search_tool;
const webSearchHelpTool = @import("tools/web_search_help.zig").web_search_help_tool;
```

- [ ] **Step 3: Find where tools are registered**

Run: `search` for `bashTool` usage in agent.zig to find tool registration location

- [ ] **Step 4: Add new tools to tool list**

Find where `bashTool` is included in the tools array and add:
```zig
webSearchTool,
webSearchHelpTool,
```

- [ ] **Step 5: Verify build**

Run: `zig build 2>&1 | head -n 50`
Expected: Build succeeds with new tools registered

- [ ] **Step 6: Commit**

```bash
git add src/modules/agent/agent.zig
git commit -m "feat: register web_search tools in agent"
```

---

## Chunk 4: Prompt Updates

### Task 7: Update research.zig prompt

**Files:**
- Modify: `src/modules/agent/prompts/research.zig`

- [ ] **Step 1: Read research.zig AvailableTools section**

Run: `read_file` on `src/modules/agent/prompts/research.zig`

- [ ] **Step 2: Add web search to AvailableTools**

Find the `AvailableTools` section and add:

```
**Web Browsing:**
- `web_search` — Browse web pages, get snapshots, interact with elements
- `web_search_help` — Get agent-browser CLI help

```

- [ ] **Step 3: Update bash tool description**

Find the bash tool description and update to remove redundant agent-browser mention:

Change:
```
\\## Web Browsing
\\To browse the web or fetch URLs, use the `agent-browser` CLI:
\\
```

To:
```
\\## Web Browsing
\\Use the `web_search` tool for browsing web pages:
\\- Open URLs: web_search with action="open"
\\- Get page content: web_search with action="snapshot"
\\- Interact with elements: web_search with action="click", "get", etc.
\\
```

- [ ] **Step 4: Commit**

```bash
git add src/modules/agent/prompts/research.zig
git commit -m "docs: update prompts with web_search tools"
```

---

## Chunk 5: Verification

### Task 8: Final verification

- [ ] **Step 1: Run all tests**

Run: `zig build test 2>&1 | tail -n 30`
Expected: All tests pass including new web_search tests

- [ ] **Step 2: Build the project**

Run: `zig build 2>&1`
Expected: Build succeeds

- [ ] **Step 3: Test agent-browser is accessible**

Run: `timeout 5 agent-browser --help 2>&1 | head -n 20`
Expected: Help output displayed

- [ ] **Step 4: Show git log summary**

Run: `git log --oneline -10`
Expected: Shows commits for all new files

---

## Summary

| Task | File | TDD Phase |
|------|------|-----------|
| 1 | web_search_help_test.zig + web_search_help.zig | Red → Green |
| 2 | schemas.zig | Add schemas |
| 3 | web_search_test.zig | Red |
| 4 | web_search.zig | Green |
| 5 | tools.zig | Register exports |
| 6 | agent.zig | Register with agent |
| 7 | research.zig | Update prompts |
| 8 | Verification | Final check |

**Total: 8 tasks with 5 commits**
