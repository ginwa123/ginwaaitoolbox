# LSP Tools Integration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create AI tools for LSP (Language Server Protocol) functionality in Zig, enabling "go to definition" and other LSP features similar to test_lsp.py.

**Architecture:** The LSP tools will follow the existing agent tool pattern with a core client module handling JSON-RPC communication, type definitions for LSP protocol, and individual tool modules for each LSP feature (definition, diagnostics, hover, references). The system uses a session-based approach where LSP servers are spawned and managed per workspace.

**Tech Stack:** Zig 0.15.2, JSON-RPC over stdio, zls (Zig LSP) or pylsp (Python LSP) for testing

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/modules/agent/tools/lsp_types.zig` | LSP protocol type definitions (Position, Range, Location, errors) |
| `src/modules/agent/tools/lsp_client_core.zig` | Core LSP client: spawn, initialize, read/write JSON-RPC messages |
| `src/modules/agent/tools/lsp_start.zig` | Tool to start LSP session |
| `src/modules/agent/tools/lsp_stop.zig` | Tool to stop LSP session |
| `src/modules/agent/tools/lsp_definition.zig` | Tool: go to definition |
| `src/modules/agent/tools/lsp_diagnostics.zig` | Tool: get diagnostics |
| `src/modules/agent/tools/lsp_hover.zig` | Tool: hover information |
| `src/modules/agent/tools/lsp_references.zig` | Tool: find references |
| `src/modules/agent/tools/models.zig` | Update to add LSP input/output structs |

---

## Chunk 1: Core Types and Infrastructure

### Task 1: Create lsp_types.zig

**Files:**
- Create: `src/modules/agent/tools/lsp_types.zig`
- Test: `src/modules/agent/tools/lsp_types_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const lsp_types = @import("lsp_types.zig");

test "LspError error set contains expected errors" {
    const err = lsp_types.LspError.BinaryNotFound;
    _ = err;
}

test "Position struct has correct fields" {
    const pos = lsp_types.Position{ .line = 10, .character = 5 };
    try std.testing.expectEqual(@as(u32, 10), pos.line);
    try std.testing.expectEqual(@as(u32, 5), pos.character);
}

test "Range struct contains start and end positions" {
    const range = lsp_types.Range{
        .start = .{ .line = 10, .character = 5 },
        .end = .{ .line = 10, .character = 15 },
    };
    try std.testing.expectEqual(@as(u32, 10), range.start.line);
    try std.testing.expectEqual(@as(u32, 15), range.end.character);
}

test "Location struct has uri and range" {
    const allocator = std.testing.allocator;
    const loc = lsp_types.Location{
        .uri = try allocator.dupe(u8, "file:///test.zig"),
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 10 },
        },
    };
    defer allocator.free(loc.uri);
    try std.testing.expect(std.mem.eql(u8, loc.uri, "file:///test.zig"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/modules/agent/tools/lsp_types_test.zig`
Expected: FAIL with "file not found" or "import failed"

- [ ] **Step 3: Write minimal implementation**

```zig
const std = @import("std");

pub const LspError = error{
    ProcessSpawnFailed,
    BinaryNotFound,
    HandshakeFailed,
    RequestTimeout,
    InvalidResponse,
    NotInitialized,
    AlreadyInitialized,
    SessionNotFound,
    JsonParseError,
    ProcessNotRunning,
};

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const ServerCapabilities = struct {
    text_document_sync: ?i32 = null,
    hover_provider: ?bool = null,
    definition_provider: ?bool = null,
    references_provider: ?bool = null,
};

pub const InitializeResult = struct {
    capabilities: ServerCapabilities,
};

// Binary search paths
pub const common_binary_paths = [_][]const u8{
    "/usr/bin",
    "/usr/local/bin",
    "/home/.local/bin",
    "/home/.local/share/nvim/mason/bin",
    "/opt/homebrew/bin",
};

test {
    _ = @import("lsp_types_test.zig");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/modules/agent/tools/lsp_types.zig`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/lsp_types.zig src/modules/agent/tools/lsp_types_test.zig
git commit --no-edit -m "feat: add LSP types module"
```

---

## Chunk 2: LSP Client Core

### Task 2: Create lsp_client_core.zig

**Files:**
- Create: `src/modules/agent/tools/lsp_client_core.zig`
- Test: `src/modules/agent/tools/lsp_client_core_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const lsp_client_core = @import("lsp_client_core.zig");

test "LspClient can be initialized" {
    const allocator = std.testing.allocator;
    const client = try allocator.create(lsp_client_core.LspClient);
    defer allocator.destroy(client);
    
    client.* = try lsp_client_core.LspClient.init(allocator, "test-session", "file:///test");
    defer client.deinit();
    
    try std.testing.expect(std.mem.eql(u8, client.session_id, "test-session"));
    try std.testing.expect(std.mem.eql(u8, client.workspace_uri, "file:///test"));
    try std.testing.expect(!client.initialized);
}

test "findBinary returns error for non-existent binary" {
    const allocator = std.testing.allocator;
    const result = lsp_client_core.findBinary(allocator, "nonexistent_binary_12345");
    try std.testing.expectError(lsp_client_core.LspError.BinaryNotFound, result);
}

test "writeMessage formats JSON-RPC correctly" {
    // This will be tested via integration
}

test "readMessage parses JSON-RPC correctly" {
    // This will be tested via integration
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/modules/agent/tools/lsp_client_core_test.zig`
Expected: FAIL with "file not found"

- [ ] **Step 3: Write minimal implementation**

Create `src/modules/agent/tools/lsp_client_core.zig` with:
- `LspClient` struct with fields: allocator, process, stdin, stdout, session_id, workspace_uri, server_capabilities, initialized, next_request_id
- `LspClient.init()` and `LspClient.deinit()` methods
- `findBinary()` function to locate LSP binaries
- Global sessions map for managing multiple LSP sessions
- `writeMessage()` for sending JSON-RPC messages
- `readMessage()` for receiving JSON-RPC messages (stub for now)

See reference implementation in `.worktrees/fix-sse-session/src/modules/agent/tools/lsp_client_core.zig`

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/modules/agent/tools/lsp_client_core.zig`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/lsp_client_core.zig src/modules/agent/tools/lsp_client_core_test.zig
git commit --no-edit -m "feat: add LSP client core module"
```

---

## Chunk 3: LSP Start Tool

### Task 3: Create lsp_start.zig

**Files:**
- Create: `src/modules/agent/tools/lsp_start.zig`
- Test: `src/modules/agent/tools/lsp_start_test.zig`
- Modify: `src/modules/agent/tools/models.zig` - add LspStartInput, LspStartOutput

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const lsp_start = @import("lsp_start.zig");
const lsp_client_core = @import("lsp_client_core.zig");

test "LspStartInput can be instantiated" {
    const input = lsp_start.LspStartInput{
        .session_id = "test-session",
        .binary_name = "zls",
        .workspace_uri = "file:///test",
    };
    try std.testing.expect(std.mem.eql(u8, input.session_id, "test-session"));
}

test "lspStartTool has correct name and parameters" {
    try std.testing.expect(std.mem.eql(u8, lsp_start.lspStartTool.function.name, "lsp_start"));
    
    const params = lsp_start.lspStartTool.function.parameters;
    var has_session_id = false;
    var has_binary_name = false;
    var has_workspace_uri = false;
    
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "session_id")) has_session_id = true;
        if (std.mem.eql(u8, prop.name, "binary_name")) has_binary_name = true;
        if (std.mem.eql(u8, prop.name, "workspace_uri")) has_workspace_uri = true;
    }
    
    try std.testing.expect(has_session_id);
    try std.testing.expect(has_binary_name);
    try std.testing.expect(has_workspace_uri);
}

test "executeLspStart returns error for non-existent binary" {
    const allocator = std.testing.allocator;
    const input = lsp_start.LspStartInput{
        .session_id = "test-session",
        .binary_name = "nonexistent_binary_12345",
        .workspace_uri = "file:///test",
    };
    
    const result = lsp_start.executeLspStart(allocator, input);
    try std.testing.expectError(lsp_client_core.LspError.BinaryNotFound, result);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/modules/agent/tools/lsp_start_test.zig`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

Create `src/modules/agent/tools/lsp_start.zig` with:
- `LspStartInput` struct: session_id, binary_name, workspace_uri
- `LspStartOutput` struct: session_id, binary_path, status
- `executeLspStart()` function that spawns LSP and sends initialize request
- `lspStartTool` AgentTool definition

See reference implementation in `.worktrees/fix-sse-session/src/modules/agent/tools/lsp_start.zig`

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/modules/agent/tools/lsp_start.zig`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/lsp_start.zig src/modules/agent/tools/lsp_start_test.zig
git commit --no-edit -m "feat: add LSP start tool"
```

---

## Chunk 4: LSP Stop Tool

### Task 4: Create lsp_stop.zig

**Files:**
- Create: `src/modules/agent/tools/lsp_stop.zig`
- Test: `src/modules/agent/tools/lsp_stop_test.zig`
- Modify: `src/modules/agent/tools/models.zig` - add LspStopInput, LspStopOutput

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const lsp_stop = @import("lsp_stop.zig");
const lsp_client_core = @import("lsp_client_core.zig");

test "LspStopInput can be instantiated" {
    const input = lsp_stop.LspStopInput{
        .session_id = "test-session",
    };
    try std.testing.expect(std.mem.eql(u8, input.session_id, "test-session"));
}

test "executeLspStop returns error for non-existent session" {
    const allocator = std.testing.allocator;
    const input = lsp_stop.LspStopInput{
        .session_id = "non-existent-session",
    };
    
    const result = lsp_stop.executeLspStop(allocator, input);
    try std.testing.expectError(lsp_client_core.LspError.SessionNotFound, result);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/modules/agent/tools/lsp_stop_test.zig`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

Create `src/modules/agent/tools/lsp_stop.zig` with:
- `LspStopInput` struct: session_id
- `LspStopOutput` struct: session_id, status
- `executeLspStop()` function that stops LSP process and cleans up
- `lspStopTool` AgentTool definition

See reference implementation in `.worktrees/fix-sse-session/src/modules/agent/tools/lsp_stop.zig`

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/modules/agent/tools/lsp_stop.zig`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/lsp_stop.zig src/modules/agent/tools/lsp_stop_test.zig
git commit --no-edit -m "feat: add LSP stop tool"
```

---

## Chunk 5: LSP Definition Tool (Main Feature)

### Task 5: Create lsp_definition.zig

**Files:**
- Create: `src/modules/agent/tools/lsp_definition.zig`
- Test: `src/modules/agent/tools/lsp_definition_test.zig`
- Modify: `src/modules/agent/tools/models.zig` - add LspDefinitionInput, LspDefinitionOutput

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const lsp_definition = @import("lsp_definition.zig");
const lsp_client_core = @import("lsp_client_core.zig");

test "LspDefinitionInput can be instantiated" {
    const input = lsp_definition.LspDefinitionInput{
        .session_id = "test-session",
        .file_uri = "file:///test.zig",
        .line = 10,
        .character = 5,
    };
    try std.testing.expect(std.mem.eql(u8, input.file_uri, "file:///test.zig"));
    try std.testing.expectEqual(@as(u32, 10), input.line);
}

test "lspDefinitionTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_definition.lspDefinitionTool.function.name, "lsp_definition"));
}

test "lspDefinitionTool has required parameters" {
    const params = lsp_definition.lspDefinitionTool.function.parameters;
    try std.testing.expect(params.properties.len == 4);
    
    var has_session_id = false;
    var has_file_uri = false;
    var has_line = false;
    var has_character = false;
    
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "session_id")) has_session_id = true;
        if (std.mem.eql(u8, prop.name, "file_uri")) has_file_uri = true;
        if (std.mem.eql(u8, prop.name, "line")) has_line = true;
        if (std.mem.eql(u8, prop.name, "character")) has_character = true;
    }
    
    try std.testing.expect(has_session_id);
    try std.testing.expect(has_file_uri);
    try std.testing.expect(has_line);
    try std.testing.expect(has_character);
}

test "executeLspDefinition returns error for non-existent session" {
    const allocator = std.testing.allocator;
    const result = lsp_definition.executeLspDefinition(allocator, .{
        .session_id = "non-existent-session",
        .file_uri = "file:///test.zig",
        .line = 10,
        .character = 5,
    });
    try std.testing.expectError(lsp_client_core.LspError.SessionNotFound, result);
}

test "lspDefinitionToString formats output correctly" {
    const allocator = std.testing.allocator;
    const output = lsp_definition.LspDefinitionOutput{
        .file_uri = try allocator.dupe(u8, "file:///test.zig"),
        .line = 10,
        .character = 5,
        .definitions = &.{},
    };
    defer allocator.free(output.file_uri);
    
    const str = try lsp_definition.lspDefinitionToString(allocator, output);
    defer allocator.free(str);
    
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<file_uri>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<definitions>"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/modules/agent/tools/lsp_definition_test.zig`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

Create `src/modules/agent/tools/lsp_definition.zig` with:
- `LspDefinitionInput` struct: session_id, file_uri, line, character
- `LspDefinitionOutput` struct: file_uri, line, character, definitions (array of Location)
- `executeLspDefinition()` function that sends textDocument/definition request
- `lspDefinitionToString()` for formatting output
- `lspDefinitionTool` AgentTool definition

See reference implementation in `.worktrees/fix-sse-session/src/modules/agent/tools/lsp_definition.zig`

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/modules/agent/tools/lsp_definition.zig`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/lsp_definition.zig src/modules/agent/tools/lsp_definition_test.zig
git commit --no-edit -m "feat: add LSP definition tool"
```

---

## Chunk 6: Update Models and Integration

### Task 6: Update models.zig

**Files:**
- Modify: `src/modules/agent/tools/models.zig`

- [ ] **Step 1: Add LSP input/output structs to models.zig**

Add to `src/modules/agent/tools/models.zig`:

```zig
// LSP Tool Inputs/Outputs
pub const LspStartInput = struct {
    session_id: []const u8,
    binary_name: []const u8,
    workspace_uri: []const u8,
};

pub const LspStartOutput = struct {
    session_id: []const u8,
    binary_path: []const u8,
    status: []const u8,
};

pub const LspStopInput = struct {
    session_id: []const u8,
};

pub const LspStopOutput = struct {
    session_id: []const u8,
    status: []const u8,
};

pub const LspDefinitionInput = struct {
    session_id: []const u8,
    file_uri: []const u8,
    line: u32,
    character: u32,
};

pub const LspDefinitionOutput = struct {
    file_uri: []u8,
    line: u32,
    character: u32,
    definitions: []lsp_types.Location,
};
```

- [ ] **Step 2: Add LSP module imports**

Add to bottom of models.zig:

```zig
// LSP modules
pub const lsp_types = @import("lsp_types.zig");
pub const lsp_start = @import("lsp_start.zig");
pub const lsp_stop = @import("lsp_stop.zig");
pub const lsp_definition = @import("lsp_definition.zig");

// LSP tools
pub const lspStartTool = lsp_start.lspStartTool;
pub const lspStopTool = lsp_stop.lspStopTool;
pub const lspDefinitionTool = lsp_definition.lspDefinitionTool;
```

- [ ] **Step 3: Run tests to verify integration**

Run: `zig test src/modules/agent/tools/models.zig`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/modules/agent/tools/models.zig
git commit --no-edit -m "feat: integrate LSP tools into models"
```

---

## Chunk 7: Integration Test

### Task 7: Create integration test

**Files:**
- Create: `src/modules/agent/tools/lsp_integration_test.zig`

- [ ] **Step 1: Write integration test**

Create a test that:
1. Starts an LSP session (using pylsp for reliability)
2. Opens a test file
3. Requests definition
4. Verifies the response
5. Stops the session

See reference in `.worktrees/fix-sse-session/src/modules/agent/tools/lsp_definition_test.zig` for the integration test pattern.

- [ ] **Step 2: Run integration test**

Run: `zig test src/modules/agent/tools/lsp_integration_test.zig`
Expected: PASS (may skip if pylsp not installed)

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/lsp_integration_test.zig
git commit --no-edit -m "test: add LSP integration test"
```

---

## Chunk 8: Final Verification

### Task 8: Run all tests

- [ ] **Step 1: Run all agent tool tests**

Run: `zig build test`
Expected: All tests PASS

- [ ] **Step 2: Verify build succeeds**

Run: `zig build`
Expected: Build succeeds with no errors

- [ ] **Step 3: Final commit**

```bash
git commit --no-edit -m "feat: complete LSP tools integration

- Add lsp_types.zig with LSP protocol types
- Add lsp_client_core.zig for JSON-RPC communication
- Add lsp_start.zig to spawn LSP servers
- Add lsp_stop.zig to clean up sessions
- Add lsp_definition.zig for go-to-definition
- Integrate all LSP tools into agent tool system
- Add comprehensive tests"
```

---

## Testing Commands Reference

```bash
# Test individual modules
zig test src/modules/agent/tools/lsp_types.zig
zig test src/modules/agent/tools/lsp_client_core.zig
zig test src/modules/agent/tools/lsp_start.zig
zig test src/modules/agent/tools/lsp_stop.zig
zig test src/modules/agent/tools/lsp_definition.zig

# Test all agent tools
zig test src/modules/agent/tools/

# Full build and test
zig build test
```

## Reference Implementation

The complete reference implementation exists in:
`.worktrees/fix-sse-session/src/modules/agent/tools/`

Key files to reference:
- `lsp_types.zig` - Type definitions
- `lsp_client_core.zig` - Core client functionality
- `lsp_definition.zig` - Go to definition tool
- `lsp_definition_test.zig` - Test patterns including integration test
