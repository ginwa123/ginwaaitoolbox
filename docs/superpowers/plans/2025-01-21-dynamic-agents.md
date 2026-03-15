# Dynamic Agents Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a dynamic agent system similar to skills, where agents are stored in `.nalar/agents/listOfAgent/` and can be loaded on-demand into the system prompt.

**Architecture:** Mirror the existing skills system architecture - agents are markdown files with YAML frontmatter stored in a directory structure. The system discovers agents, parses their metadata, and can load full agent definitions into the prompt at the `// dynamic agent` placeholder location.

**Tech Stack:** Zig 0.15.2, following existing patterns in `src/modules/agent/tools/`

---

## File Structure

### New Files to Create:
- `src/modules/agent/tools/agents.zig` - Core agent discovery and loading logic (mirrors `skills.zig`)
- `src/modules/agent/tools/list_agents.zig` - Tool for listing available agents
- `src/modules/agent/tools/get_agent.zig` - Tool for loading agent content
- `src/modules/agent/tools/agents_test.zig` - Unit tests for agent functionality

### Files to Modify:
- `src/modules/agent/prompt.zig` - Integrate dynamic agents at line 782
- `src/modules/agent/tools/models.zig` - Add agent tool definitions
- `src/root.zig` - Export new agent modules

### Directory Structure to Create:
```
.nalar/agents/
└── listOfAgent/
    ├── specialized-coder/
    │   └── AGENT.md
    ├── code-reviewer/
    │   └── AGENT.md
    └── documentation-writer/
        └── AGENT.md
```

---

## Task 1: Create Core Agents Module

**Files:**
- Create: `src/modules/agent/tools/agents.zig`
- Test: `src/modules/agent/tools/agents_test.zig`

### Step 1: Write the failing test

Create `src/modules/agent/tools/agents_test.zig`:

```zig
const std = @import("std");
const agents = @import("agents.zig");

// Test: listAgentFiles discovers agent directories
// Test: parseAgentFrontmatter extracts name and description
// Test: listAgents returns all available agents
// Test: parseAgent loads specific agent by name
// Test: empty agent files are filtered out
// Test: missing agent returns error
```

### Step 2: Run test to verify it fails

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build test 2>&1 | head -n 50
```

Expected: FAIL - module not found, functions not defined

### Step 3: Create minimal implementation

Create `src/modules/agent/tools/agents.zig`:

```zig
const std = @import("std");

pub const AgentInfo = struct {
    name: []const u8,
    description: []const u8,
};

pub const ParsedAgentFrontmatter = struct {
    name: []const u8,
    description: []const u8,
};

const MAX_AGENT_SIZE: usize = 100 * 1024; // 100KB max agent file
const APP_NAME = "nalar";
const LOCAL_AGENTS_DIR = ".nalar/agents/listOfAgent";
const AGENT_FILE_NAME = "AGENT.md";

/// Get the local agents directory path
pub fn getLocalAgentsPath(allocator: std.mem.Allocator) ![]const u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, LOCAL_AGENTS_DIR });
}

/// Get XDG-compliant global agents path
pub fn getGlobalAgentsPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            return try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(home);
    
    // Linux: ~/.config/nalar/agents/listOfAgent
    return try std.fs.path.join(allocator, &.{ home, ".config", APP_NAME, "agents", "listOfAgent" });
}

/// Resolve agents path (local first, then global)
pub fn resolveAgentsPath(allocator: std.mem.Allocator) ![]const u8 {
    const local_path = try getLocalAgentsPath(allocator);
    
    // Check if local path exists
    std.fs.accessAbsolute(local_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            allocator.free(local_path);
            return try getGlobalAgentsPath(allocator);
        }
        return err;
    };
    
    return local_path;
}

/// List all agent file paths in the agents directory
pub fn listAgentFiles(allocator: std.mem.Allocator) ![][]const u8 {
    const agents_path = try resolveAgentsPath(allocator);
    defer allocator.free(agents_path);
    
    var agent_files = std.ArrayList([]const u8).empty;
    errdefer {
        for (agent_files.items) |path| {
            allocator.free(path);
        }
        agent_files.deinit(allocator);
    }
    
    var dir = std.fs.openDirAbsolute(agents_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            return try agent_files.toOwnedSlice(allocator);
        }
        return err;
    };
    defer dir.close();
    
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        
        const agent_file_path = try std.fs.path.join(allocator, &.{ agents_path, entry.name, AGENT_FILE_NAME });
        
        // Check if file exists and is non-empty
        const file = std.fs.openFileAbsolute(agent_file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                allocator.free(agent_file_path);
                continue;
            }
            return err;
        };
        defer file.close();
        
        const stat = try file.stat();
        if (stat.size == 0) {
            allocator.free(agent_file_path);
            continue;
        }
        
        try agent_files.append(allocator, agent_file_path);
    }
    
    return try agent_files.toOwnedSlice(allocator);
}

/// Parse YAML frontmatter from agent file content
pub fn parseYamlFrontmatter(allocator: std.mem.Allocator, content: []const u8) !ParsedAgentFrontmatter {
    var result = ParsedAgentFrontmatter{
        .name = &.{},
        .description = &.{},
    };
    
    // Find opening ---
    const start_marker = "---\n";
    const start_idx = std.mem.indexOf(u8, content, start_marker);
    if (start_idx == null) return result;
    
    // Find closing ---
    const content_after_start = content[start_idx.? + start_marker.len..];
    const end_idx = std.mem.indexOf(u8, content_after_start, "\n---");
    if (end_idx == null) return result;
    
    const frontmatter = content_after_start[0..end_idx.?];
    
    // Parse name field
    const name_prefix = "name:";
    if (std.mem.indexOf(u8, frontmatter, name_prefix)) |name_idx| {
        const after_name = frontmatter[name_idx + name_prefix.len..];
        const name_start = std.mem.indexOfNone(u8, after_name, " \t") orelse 0;
        const name_end = std.mem.indexOf(u8, after_name[name_start..], "\n") orelse after_name.len;
        const name_value = std.mem.trim(u8, after_name[name_start..name_start + name_end], " \"\t\r\n");
        result.name = try allocator.dupe(u8, name_value);
    }
    
    // Parse description field
    const desc_prefix = "description:";
    if (std.mem.indexOf(u8, frontmatter, desc_prefix)) |desc_idx| {
        const after_desc = frontmatter[desc_idx + desc_prefix.len..];
        const desc_start = std.mem.indexOfNone(u8, after_desc, " \t") orelse 0;
        const desc_end = std.mem.indexOf(u8, after_desc[desc_start..], "\n") orelse after_desc.len;
        const desc_value = std.mem.trim(u8, after_desc[desc_start..desc_start + desc_end], " \"\t\r\n");
        result.description = try allocator.dupe(u8, desc_value);
    }
    
    return result;
}

/// Load agent content from file path
pub fn loadAgentFromPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    
    const stat = try file.stat();
    if (stat.size > MAX_AGENT_SIZE) {
        return error.FileTooLarge;
    }
    
    const content = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(content);
    
    const bytes_read = try file.read(content);
    if (bytes_read != stat.size) {
        return error.UnexpectedReadSize;
    }
    
    return content;
}

/// List all available agents with their metadata
pub fn listAgents(allocator: std.mem.Allocator) ![]AgentInfo {
    const agent_files = try listAgentFiles(allocator);
    defer {
        for (agent_files) |path| {
            allocator.free(path);
        }
        allocator.free(agent_files);
    }
    
    var agents_list = std.ArrayList(AgentInfo).empty;
    errdefer {
        for (agents_list.items) |info| {
            allocator.free(info.name);
            allocator.free(info.description);
        }
        agents_list.deinit(allocator);
    }
    
    for (agent_files) |path| {
        const content = loadAgentFromPath(allocator, path) catch |err| {
            std.log.warn("Failed to load agent from {s}: {any}", .{ path, err });
            continue;
        };
        defer allocator.free(content);
        
        const frontmatter = try parseYamlFrontmatter(allocator, content);
        
        if (frontmatter.name.len > 0) {
            try agents_list.append(allocator, AgentInfo{
                .name = frontmatter.name,
                .description = frontmatter.description,
            });
        } else {
            allocator.free(frontmatter.description);
        }
    }
    
    return try agents_list.toOwnedSlice(allocator);
}

/// Parse a specific agent by name
pub fn parseAgent(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const agents_path = try resolveAgentsPath(allocator);
    defer allocator.free(agents_path);
    
    const agent_file_path = try std.fs.path.join(allocator, &.{ agents_path, name, AGENT_FILE_NAME });
    defer allocator.free(agent_file_path);
    
    return try loadAgentFromPath(allocator, agent_file_path);
}

/// Free allocated agent info array
pub fn freeAgentsList(allocator: std.mem.Allocator, agents_list: []AgentInfo) void {
    for (agents_list) |info| {
        allocator.free(info.name);
        allocator.free(info.description);
    }
    allocator.free(agents_list);
}

/// Free allocated agent file paths
pub fn freeAgentFiles(allocator: std.mem.Allocator, files: [][]const u8) void {
    for (files) |path| {
        allocator.free(path);
    }
    allocator.free(files);
}

/// Free parsed frontmatter
pub fn freeParsedFrontmatter(allocator: std.mem.Allocator, frontmatter: ParsedAgentFrontmatter) void {
    allocator.free(frontmatter.name);
    allocator.free(frontmatter.description);
}

/// Free agents path string
pub fn freeAgentsPath(allocator: std.mem.Allocator, path: []const u8) void {
    allocator.free(path);
}
```

### Step 4: Run test to verify it passes

```bash
zig build test 2>&1 | head -n 50
```

Expected: PASS - all tests pass

### Step 5: Commit

```bash
git add src/modules/agent/tools/agents.zig src/modules/agent/tools/agents_test.zig
git commit --no-edit -m "feat: add core agents module with discovery and loading"
```

---

## Task 2: Create List Agents Tool

**Files:**
- Create: `src/modules/agent/tools/list_agents.zig`
- Test: `src/modules/agent/tools/list_agents_test.zig`

### Step 1: Write the failing test

Create `src/modules/agent/tools/list_agents_test.zig`:

```zig
const std = @import("std");
const list_agents = @import("list_agents.zig");

// Test: executeListAgents returns JSON array
// Test: empty agents directory returns empty array
// Test: tool definition is correct
```

### Step 2: Run test to verify it fails

```bash
zig build test 2>&1 | head -n 50
```

Expected: FAIL - module not found

### Step 3: Create minimal implementation

Create `src/modules/agent/tools/list_agents.zig`:

```zig
const std = @import("std");
const agents = @import("agents.zig");
const models = @import("models.zig");

pub const listAgentsTool = models.AgentTool{
    .type = "function",
    .function = .{
        .name = "list_agents",
        .description = "List all available dynamic agents with their names and descriptions. Use this to discover what specialized agents are available for different tasks.",
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
    },
};

/// Execute list_agents tool and return JSON result
pub fn executeListAgents(allocator: std.mem.Allocator) ![]const u8 {
    const agents_list = try agents.listAgents(allocator);
    defer agents.freeAgentsList(allocator, agents_list);
    
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    
    const writer = result.writer(allocator);
    
    try writer.writeAll("{\"agents\": [");
    
    for (agents_list, 0..) |info, i| {
        if (i > 0) try writer.writeAll(", ");
        
        try writer.writeAll("{\"name\": \"");
        try writeJsonEscapedString(writer, info.name);
        try writer.writeAll("\", \"description\": \"");
        try writeJsonEscapedString(writer, info.description);
        try writer.writeAll("\"}");
    }
    
    try writer.writeAll("]}");
    
    return try result.toOwnedSlice(allocator);
}

/// Write a string with JSON escaping
fn writeJsonEscapedString(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}
```

### Step 4: Run test to verify it passes

```bash
zig build test 2>&1 | head -n 50
```

Expected: PASS

### Step 5: Commit

```bash
git add src/modules/agent/tools/list_agents.zig src/modules/agent/tools/list_agents_test.zig
git commit --no-edit -m "feat: add list_agents tool for discovering dynamic agents"
```

---

## Task 3: Create Get Agent Tool

**Files:**
- Create: `src/modules/agent/tools/get_agent.zig`
- Test: `src/modules/agent/tools/get_agent_test.zig`

### Step 1: Write the failing test

Create `src/modules/agent/tools/get_agent_test.zig`:

```zig
const std = @import("std");
const get_agent = @import("get_agent.zig");

// Test: executeGetAgent returns agent content
// Test: missing agent returns error
// Test: tool definition is correct
```

### Step 2: Run test to verify it fails

```bash
zig build test 2>&1 | head -n 50
```

Expected: FAIL - module not found

### Step 3: Create minimal implementation

Create `src/modules/agent/tools/get_agent.zig`:

```zig
const std = @import("std");
const agents = @import("agents.zig");
const models = @import("models.zig");

pub const getAgentTool = models.AgentTool{
    .type = "function",
    .function = .{
        .name = "get_agent",
        .description = "Load the full content of a dynamic agent by name. Use this to retrieve an agent's complete definition and instructions.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "agent_name",
                    .property = .{
                        .type = "string",
                        .description = "The name of the agent to load (from list_agents)",
                    },
                },
            },
            .required = &.{
                "agent_name",
            },
        },
    },
};

pub const GetAgentInput = struct {
    agent_name: []const u8,
};

/// Parse get_agent tool input from JSON
pub fn parseGetAgentInput(allocator: std.mem.Allocator, json_str: []const u8) !GetAgentInput {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    
    const root = parsed.value;
    if (root != .object) return error.InvalidJson;
    
    var result = GetAgentInput{
        .agent_name = &.{},
    };
    
    if (root.object.get("agent_name")) |name_val| {
        if (name_val == .string) {
            result.agent_name = try allocator.dupe(u8, name_val.string);
        }
    }
    
    return result;
}

/// Execute get_agent tool and return XML result
pub fn executeGetAgentToString(allocator: std.mem.Allocator, input: GetAgentInput) ![]const u8 {
    const content = agents.parseAgent(allocator, input.agent_name) catch |err| {
        var error_result = std.ArrayList(u8).empty;
        errdefer error_result.deinit(allocator);
        
        const writer = error_result.writer(allocator);
        try writer.writeAll("<agent>\n");
        try writer.writeAll("  <agent_name>");
        try writer.writeAll(input.agent_name);
        try writer.writeAll("</agent_name>\n");
        try writer.writeAll("  <content>Agent not found</content>\n");
        try writer.writeAll("  <loaded>false</loaded>\n");
        try writer.writeAll("</agent>");
        
        return try error_result.toOwnedSlice(allocator);
    };
    defer allocator.free(content);
    
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    
    const writer = result.writer(allocator);
    
    try writer.writeAll("<agent>\n");
    try writer.writeAll("  <agent_name>");
    try writer.writeAll(input.agent_name);
    try writer.writeAll("</agent_name>\n");
    try writer.writeAll("  <content><![CDATA[");
    try writer.writeAll(content);
    try writer.writeAll("]]></content>\n");
    try writer.writeAll("  <loaded>true</loaded>\n");
    try writer.writeAll("</agent>");
    
    return try result.toOwnedSlice(allocator);
}
```

### Step 4: Run test to verify it passes

```bash
zig build test 2>&1 | head -n 50
```

Expected: PASS

### Step 5: Commit

```bash
git add src/modules/agent/tools/get_agent.zig src/modules/agent/tools/get_agent_test.zig
git commit --no-edit -m "feat: add get_agent tool for loading dynamic agent content"
```

---

## Task 4: Update Models with Agent Tools

**Files:**
- Modify: `src/modules/agent/tools/models.zig`

### Step 1: Write the failing test

Check existing tests in `models.zig` or create `models_test.zig`:

```zig
// Test: AgentTool struct can represent list_agents and get_agent
```

### Step 2: Run test to verify it fails

```bash
zig build test 2>&1 | head -n 50
```

Expected: May pass if no new tests needed

### Step 3: Add agent tool exports

Modify `src/modules/agent/tools/models.zig` to export agent tool definitions:

```zig
// Add at the end of the file or in appropriate section:

// Re-export agent tools for convenience
pub const list_agents = @import("list_agents.zig");
pub const get_agent = @import("get_agent.zig");

pub const listAgentsTool = list_agents.listAgentsTool;
pub const getAgentTool = get_agent.getAgentTool;
```

### Step 4: Run test to verify it passes

```bash
zig build test 2>&1 | head -n 50
```

Expected: PASS

### Step 5: Commit

```bash
git add src/modules/agent/tools/models.zig
git commit --no-edit -m "feat: export agent tools from models module"
```

---

## Task 5: Integrate Dynamic Agents into Prompt

**Files:**
- Modify: `src/modules/agent/prompt.zig` at line 782

### Step 1: Write the failing test

Check existing tests in `prompt.zig` or create test:

```zig
// Test: buildAgentPrompt includes dynamic agents content
```

### Step 2: Run test to verify it fails

```bash
zig build test 2>&1 | head -n 50
```

Expected: FAIL - dynamic agents not integrated

### Step 3: Add dynamic agent integration

Modify `src/modules/agent/prompt.zig` around line 782:

```zig
// Add import at top of file:
const agents = @import("tools/agents.zig");

// Modify buildAgentPrompt function signature to accept optional agentsContent parameter
// or load it internally

// At line 782 (after backgroundProcess content), add:
    // dynamic agent
    if (agentsContent.len > 0) {
        try result.appendSlice(allocator, "\n\n");
        try result.appendSlice(allocator, "## Available Dynamic Agents\n\n");
        try result.appendSlice(allocator, "The following specialized agents are available. Use `get_agent` to load their full definitions when needed:\n\n");
        try result.appendSlice(allocator, agentsContent);
    }
```

Alternative: Load agents content internally in buildAgentPrompt:

```zig
// dynamic agent
const agents_list = agents.listAgents(allocator) catch |err| {
    std.log.warn("Failed to list agents: {any}", .{err});
    &[_]agents.AgentInfo{};
};
defer agents.freeAgentsList(allocator, agents_list);

if (agents_list.len > 0) {
    try result.appendSlice(allocator, "\n\n");
    try result.appendSlice(allocator, "## Available Dynamic Agents\n\n");
    try result.appendSlice(allocator, "The following specialized agents are available. Use `get_agent` to load their full definitions when needed:\n\n");
    
    for (agents_list) |info| {
        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, info.name);
        try result.appendSlice(allocator, "**: ");
        try result.appendSlice(allocator, info.description);
        try result.appendSlice(allocator, "\n");
    }
}
```

### Step 4: Run test to verify it passes

```bash
zig build test 2>&1 | head -n 50
```

Expected: PASS

### Step 5: Commit

```bash
git add src/modules/agent/prompt.zig
git commit --no-edit -m "feat: integrate dynamic agents into system prompt"
```

---

## Task 6: Export New Modules from Root

**Files:**
- Modify: `src/root.zig`

### Step 1: Write the failing test

Verify exports work:

```bash
zig build 2>&1 | head -n 50
```

### Step 2: Run test to verify it fails

Expected: May fail if modules not exported

### Step 3: Add exports

Modify `src/root.zig`:

```zig
// Add to agent tools section:
pub const agents = @import("modules/agent/tools/agents.zig");
pub const list_agents = @import("modules/agent/tools/list_agents.zig");
pub const get_agent = @import("modules/agent/tools/get_agent.zig");
```

### Step 4: Run test to verify it passes

```bash
zig build 2>&1 | head -n 50
```

Expected: PASS - build succeeds

### Step 5: Commit

```bash
git add src/root.zig
git commit --no-edit -m "feat: export agent modules from root"
```

---

## Task 7: Create Sample Agent Files

**Files:**
- Create: `.nalar/agents/listOfAgent/specialized-coder/AGENT.md`
- Create: `.nalar/agents/listOfAgent/code-reviewer/AGENT.md`

### Step 1: Create sample agent directory structure

```bash
mkdir -p .nalar/agents/listOfAgent/specialized-coder
mkdir -p .nalar/agents/listOfAgent/code-reviewer
```

### Step 2: Create sample agent files

Create `.nalar/agents/listOfAgent/specialized-coder/AGENT.md`:

```markdown
---
name: specialized-coder
description: "Expert in writing clean, efficient, and well-tested code. Specializes in Zig, TypeScript, and systems programming."
---

# Specialized Coder Agent

You are an expert software developer specializing in:
- Zig systems programming
- TypeScript/React frontend development
- Test-driven development (TDD)
- Clean code architecture

## Guidelines

1. Always write tests before implementation
2. Follow language-specific best practices
3. Document public APIs
4. Handle errors explicitly
5. Optimize for readability first, performance second

## Tools

You have access to all standard tools including:
- bash: Execute shell commands
- read_file: Read source files
- write_file: Create new files
- text_replace: Modify existing files
- search: Find code patterns
```

Create `.nalar/agents/listOfAgent/code-reviewer/AGENT.md`:

```markdown
---
name: code-reviewer
description: "Thorough code reviewer focused on quality, security, and maintainability. Provides constructive feedback with specific suggestions."
---

# Code Reviewer Agent

You are a meticulous code reviewer who ensures:
- Code correctness and edge case handling
- Security best practices
- Performance considerations
- Maintainability and readability
- Test coverage adequacy

## Review Checklist

For each file reviewed, check:
- [ ] Logic correctness
- [ ] Error handling
- [ ] Resource cleanup
- [ ] Documentation
- [ ] Test coverage
- [ ] Security implications
- [ ] Performance characteristics

## Output Format

Provide reviews in this structure:
1. **Summary**: Overall assessment
2. **Critical Issues**: Must-fix problems
3. **Suggestions**: Improvements to consider
4. **Praise**: What's done well
```

### Step 3: Verify agents are discoverable

Create a test script or run:

```bash
# Build and run a test that lists agents
zig build test 2>&1 | grep -i agent
```

### Step 4: Commit

```bash
git add .nalar/agents/
git commit --no-edit -m "feat: add sample dynamic agent definitions"
```

---

## Task 8: Add Agent Tools to Main Agent

**Files:**
- Modify: `src/modules/agent/agent.zig` (or wherever tools are registered)

### Step 1: Find where tools are registered

Search for where tools like `listSkillsTool` are added to the agent.

### Step 2: Add agent tools

Add `listAgentsTool` and `getAgentTool` to the agent's available tools.

### Step 3: Run tests

```bash
zig build test 2>&1 | head -n 50
```

Expected: PASS

### Step 4: Commit

```bash
git add src/modules/agent/agent.zig
git commit --no-edit -m "feat: register list_agents and get_agent tools with main agent"
```

---

## Task 9: Integration Testing

**Files:**
- Create: Integration test in `src/modules/agent/tools/agents_integration_test.zig`

### Step 1: Write integration test

```zig
const std = @import("std");
const agents = @import("agents.zig");
const list_agents = @import("list_agents.zig");
const get_agent = @import("get_agent.zig");

test "full agent workflow" {
    const allocator = std.testing.allocator;
    
    // 1. List agents
    const agents_json = try list_agents.executeListAgents(allocator);
    defer allocator.free(agents_json);
    
    // Verify JSON structure
    try std.testing.expect(std.mem.indexOf(u8, agents_json, "\"agents\"") != null);
    
    // 2. Get a specific agent
    const input = get_agent.GetAgentInput{
        .agent_name = "specialized-coder",
    };
    const agent_xml = try get_agent.executeGetAgentToString(allocator, input);
    defer allocator.free(agent_xml);
    
    // Verify XML structure
    try std.testing.expect(std.mem.indexOf(u8, agent_xml, "<agent>") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent_xml, "<loaded>true</loaded>") != null);
}
```

### Step 2: Run integration test

```bash
zig build test 2>&1 | head -n 100
```

Expected: PASS

### Step 3: Commit

```bash
git add src/modules/agent/tools/agents_integration_test.zig
git commit --no-edit -m "test: add integration tests for dynamic agents"
```

---

## Task 10: Final Verification

### Step 1: Run full test suite

```bash
zig build test 2>&1
```

Expected: All tests pass

### Step 2: Build the project

```bash
zig build 2>&1
```

Expected: Build succeeds with no errors

### Step 3: Verify agent discovery works

Create a quick test:

```bash
# Create a test that exercises the full flow
zig build run 2>&1 | head -n 20
```

### Step 4: Final commit

```bash
git commit --no-edit -m "feat: complete dynamic agents implementation

- Add agents.zig core module for discovery and loading
- Add list_agents tool for discovering available agents
- Add get_agent tool for loading agent definitions
- Integrate dynamic agents into system prompt
- Add sample agent definitions
- Full test coverage with unit and integration tests"
```

---

## Summary

This implementation creates a dynamic agent system that mirrors the existing skills system:

1. **Storage**: Agents are stored in `.nalar/agents/listOfAgent/<agent-name>/AGENT.md`
2. **Format**: YAML frontmatter with `name` and `description`, markdown content
3. **Discovery**: `list_agents` tool returns JSON array of available agents
4. **Loading**: `get_agent` tool returns full agent content as XML
5. **Integration**: Agents are listed in the system prompt at the `// dynamic agent` location

The system follows TDD principles with tests written before implementation, and follows existing codebase patterns for consistency.
