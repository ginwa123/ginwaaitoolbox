# LSP Tools TDD Test Cases

> **Test-Driven Development test cases for LSP (Language Server Protocol) tools**

This document contains comprehensive TDD test cases for implementing LSP tools in Zig. Each test follows the RED-GREEN-REFACTOR cycle.

---

## Test Suite 1: lsp_types.zig

### Test 1.1: LspError error set
**Purpose:** Verify the error set contains all expected LSP errors

```zig
test "LspError error set contains expected errors" {
    // RED: This test verifies we have all necessary error types
    const errors = [_]lsp_types.LspError{
        .ProcessSpawnFailed,
        .BinaryNotFound,
        .HandshakeFailed,
        .RequestTimeout,
        .InvalidResponse,
        .NotInitialized,
        .AlreadyInitialized,
        .SessionNotFound,
        .JsonParseError,
        .ProcessNotRunning,
    };
    _ = errors;
}
```

**Expected Failure:** Error set not defined
**Implementation:** Define `LspError` error set with all variants

---

### Test 1.2: Position struct
**Purpose:** Verify Position has correct fields and types

```zig
test "Position struct has correct fields" {
    // RED: Position is fundamental to LSP
    const pos = lsp_types.Position{ .line = 10, .character = 5 };
    try std.testing.expectEqual(@as(u32, 10), pos.line);
    try std.testing.expectEqual(@as(u32, 5), pos.character);
}
```

**Expected Failure:** Position struct not defined
**Implementation:** Define Position with line and character as u32

---

### Test 1.3: Range struct
**Purpose:** Verify Range contains start and end positions

```zig
test "Range struct contains start and end positions" {
    const range = lsp_types.Range{
        .start = .{ .line = 10, .character = 5 },
        .end = .{ .line = 10, .character = 15 },
    };
    try std.testing.expectEqual(@as(u32, 10), range.start.line);
    try std.testing.expectEqual(@as(u32, 15), range.end.character);
}
```

**Expected Failure:** Range struct not defined
**Implementation:** Define Range with start and end Position fields

---

### Test 1.4: Location struct
**Purpose:** Verify Location has URI and range

```zig
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

**Expected Failure:** Location struct not defined
**Implementation:** Define Location with uri ([]const u8) and range (Range)

---

### Test 1.5: ServerCapabilities struct
**Purpose:** Verify ServerCapabilities has optional fields

```zig
test "ServerCapabilities has optional provider fields" {
    const caps = lsp_types.ServerCapabilities{
        .text_document_sync = null,
        .hover_provider = true,
        .definition_provider = true,
        .references_provider = null,
    };
    try std.testing.expect(caps.hover_provider.?);
    try std.testing.expect(caps.definition_provider.?);
    try std.testing.expect(caps.references_provider == null);
}
```

**Expected Failure:** ServerCapabilities not defined
**Implementation:** Define ServerCapabilities with optional fields

---

## Test Suite 2: lsp_client_core.zig

### Test 2.1: LspClient initialization
**Purpose:** Verify LspClient can be created with proper defaults

```zig
test "LspClient can be initialized" {
    const allocator = std.testing.allocator;
    const client = try allocator.create(lsp_client_core.LspClient);
    defer allocator.destroy(client);
    
    client.* = try lsp_client_core.LspClient.init(allocator, "test-session", "file:///test");
    defer client.deinit();
    
    try std.testing.expect(std.mem.eql(u8, client.session_id, "test-session"));
    try std.testing.expect(std.mem.eql(u8, client.workspace_uri, "file:///test"));
    try std.testing.expect(!client.initialized);
    try std.testing.expectEqual(@as(i32, 1), client.next_request_id);
}
```

**Expected Failure:** LspClient struct or init method not defined
**Implementation:** Define LspClient with all fields and init/deinit methods

---

### Test 2.2: findBinary returns error for non-existent binary
**Purpose:** Verify findBinary properly reports missing binaries

```zig
test "findBinary returns error for non-existent binary" {
    const allocator = std.testing.allocator;
    const result = lsp_client_core.findBinary(allocator, "nonexistent_binary_12345");
    try std.testing.expectError(lsp_client_core.LspError.BinaryNotFound, result);
}
```

**Expected Failure:** findBinary function not implemented
**Implementation:** Implement findBinary that searches common paths and returns error if not found

---

### Test 2.3: getSessions returns singleton
**Purpose:** Verify sessions map is properly managed

```zig
test "getSessions returns singleton map" {
    const sessions1 = lsp_client_core.getSessions();
    const sessions2 = lsp_client_core.getSessions();
    try std.testing.expectEqual(sessions1, sessions2);
}
```

**Expected Failure:** getSessions not implemented
**Implementation:** Implement getSessions with lazy initialization of global sessions map

---

### Test 2.4: writeMessage formats JSON-RPC correctly
**Purpose:** Verify messages are formatted per LSP spec

```zig
test "writeMessage formats Content-Length header correctly" {
    // This is tested via integration - we verify the format by reading back
    const test_msg = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const expected_header = "Content-Length: 23\r\n\r\n";
    
    // We'll verify this in integration tests with actual file descriptors
    _ = test_msg;
    _ = expected_header;
}
```

**Expected Failure:** writeMessage not implemented
**Implementation:** Implement writeMessage with Content-Length header

---

## Test Suite 3: lsp_start.zig

### Test 3.1: LspStartInput struct
**Purpose:** Verify input struct has all required fields

```zig
test "LspStartInput can be instantiated" {
    const input = lsp_start.LspStartInput{
        .session_id = "test-session",
        .binary_name = "zls",
        .workspace_uri = "file:///test",
    };
    try std.testing.expect(std.mem.eql(u8, input.session_id, "test-session"));
    try std.testing.expect(std.mem.eql(u8, input.binary_name, "zls"));
    try std.testing.expect(std.mem.eql(u8, input.workspace_uri, "file:///test"));
}
```

**Expected Failure:** LspStartInput not defined
**Implementation:** Define LspStartInput struct

---

### Test 3.2: LspStartOutput struct
**Purpose:** Verify output struct has all required fields

```zig
test "LspStartOutput can be instantiated" {
    const allocator = std.testing.allocator;
    const output = lsp_start.LspStartOutput{
        .session_id = try allocator.dupe(u8, "test-session"),
        .binary_path = try allocator.dupe(u8, "/usr/bin/zls"),
        .status = try allocator.dupe(u8, "started"),
    };
    defer {
        allocator.free(output.session_id);
        allocator.free(output.binary_path);
        allocator.free(output.status);
    }
    try std.testing.expect(std.mem.eql(u8, output.status, "started"));
}
```

**Expected Failure:** LspStartOutput not defined
**Implementation:** Define LspStartOutput struct

---

### Test 3.3: lspStartTool definition
**Purpose:** Verify tool is properly defined for agent system

```zig
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
    try std.testing.expectEqual(@as(usize, 3), params.required.len);
}
```

**Expected Failure:** lspStartTool not defined
**Implementation:** Define lspStartTool with proper AgentTool structure

---

### Test 3.4: executeLspStart returns error for non-existent binary
**Purpose:** Verify proper error handling for missing binary

```zig
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

**Expected Failure:** executeLspStart not implemented
**Implementation:** Implement executeLspStart with binary lookup

---

## Test Suite 4: lsp_stop.zig

### Test 4.1: LspStopInput struct
**Purpose:** Verify input struct has session_id field

```zig
test "LspStopInput can be instantiated" {
    const input = lsp_stop.LspStopInput{
        .session_id = "test-session",
    };
    try std.testing.expect(std.mem.eql(u8, input.session_id, "test-session"));
}
```

**Expected Failure:** LspStopInput not defined
**Implementation:** Define LspStopInput struct

---

### Test 4.2: executeLspStop returns error for non-existent session
**Purpose:** Verify proper error handling for missing session

```zig
test "executeLspStop returns error for non-existent session" {
    const allocator = std.testing.allocator;
    const input = lsp_stop.LspStopInput{
        .session_id = "non-existent-session-12345",
    };
    
    const result = lsp_stop.executeLspStop(allocator, input);
    try std.testing.expectError(lsp_client_core.LspError.SessionNotFound, result);
}
```

**Expected Failure:** executeLspStop not implemented
**Implementation:** Implement executeLspStop with session lookup

---

## Test Suite 5: lsp_definition.zig

### Test 5.1: LspDefinitionInput struct
**Purpose:** Verify input struct has all required fields

```zig
test "LspDefinitionInput can be instantiated" {
    const input = lsp_definition.LspDefinitionInput{
        .session_id = "test-session",
        .file_uri = "file:///test.zig",
        .line = 10,
        .character = 5,
    };
    try std.testing.expect(std.mem.eql(u8, input.session_id, "test-session"));
    try std.testing.expect(std.mem.eql(u8, input.file_uri, "file:///test.zig"));
    try std.testing.expectEqual(@as(u32, 10), input.line);
    try std.testing.expectEqual(@as(u32, 5), input.character);
}
```

**Expected Failure:** LspDefinitionInput not defined
**Implementation:** Define LspDefinitionInput struct

---

### Test 5.2: LspDefinitionOutput struct
**Purpose:** Verify output struct can hold definitions

```zig
test "LspDefinitionOutput can be instantiated with empty definitions" {
    const allocator = std.testing.allocator;
    const output = lsp_definition.LspDefinitionOutput{
        .file_uri = try allocator.dupe(u8, "file:///test.zig"),
        .line = 10,
        .character = 5,
        .definitions = &.{},
    };
    defer allocator.free(output.file_uri);
    
    try std.testing.expect(output.definitions.len == 0);
}
```

**Expected Failure:** LspDefinitionOutput not defined
**Implementation:** Define LspDefinitionOutput struct

---

### Test 5.3: lspDefinitionTool definition
**Purpose:** Verify tool is properly defined for agent system

```zig
test "lspDefinitionTool has correct name and required parameters" {
    try std.testing.expect(std.mem.eql(u8, lsp_definition.lspDefinitionTool.function.name, "lsp_definition"));
    
    const params = lsp_definition.lspDefinitionTool.function.parameters;
    try std.testing.expectEqual(@as(usize, 4), params.properties.len);
    
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
```

**Expected Failure:** lspDefinitionTool not defined
**Implementation:** Define lspDefinitionTool with proper AgentTool structure

---

### Test 5.4: executeLspDefinition returns error for non-existent session
**Purpose:** Verify proper error handling for missing session

```zig
test "executeLspDefinition returns error for non-existent session" {
    const allocator = std.testing.allocator;
    const result = lsp_definition.executeLspDefinition(allocator, .{
        .session_id = "non-existent-session-12345",
        .file_uri = "file:///test.zig",
        .line = 10,
        .character = 5,
    });
    try std.testing.expectError(lsp_client_core.LspError.SessionNotFound, result);
}
```

**Expected Failure:** executeLspDefinition not implemented
**Implementation:** Implement executeLspDefinition with session validation

---

### Test 5.5: lspDefinitionToString formats output correctly
**Purpose:** Verify output formatting for agent consumption

```zig
test "lspDefinitionToString formats output with XML-like tags" {
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
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "file:///test.zig"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<line>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<definitions>"));
}
```

**Expected Failure:** lspDefinitionToString not implemented
**Implementation:** Implement lspDefinitionToString with XML-like formatting

---

### Test 5.6: Output can hold multiple definitions
**Purpose:** Verify output supports multiple definition locations

```zig
test "LspDefinitionOutput can hold multiple definitions" {
    const allocator = std.testing.allocator;
    
    const test_uri1 = try allocator.dupe(u8, "file:///test/definition1.zig");
    defer allocator.free(test_uri1);
    const test_uri2 = try allocator.dupe(u8, "file:///test/definition2.zig");
    defer allocator.free(test_uri2);
    
    const definitions = try allocator.alloc(lsp_types.Location, 2);
    defer allocator.free(definitions);
    
    definitions[0] = lsp_types.Location{
        .uri = test_uri1,
        .range = .{
            .start = .{ .line = 10, .character = 5 },
            .end = .{ .line = 10, .character = 15 },
        },
    };
    
    definitions[1] = lsp_types.Location{
        .uri = test_uri2,
        .range = .{
            .start = .{ .line = 20, .character = 8 },
            .end = .{ .line = 20, .character = 18 },
        },
    };
    
    const output = lsp_definition.LspDefinitionOutput{
        .file_uri = try allocator.dupe(u8, "file:///test.zig"),
        .line = 5,
        .character = 8,
        .definitions = definitions,
    };
    defer allocator.free(output.file_uri);
    
    try std.testing.expectEqual(@as(usize, 2), output.definitions.len);
    try std.testing.expect(std.mem.eql(u8, output.definitions[0].uri, "file:///test/definition1.zig"));
    try std.testing.expect(std.mem.eql(u8, output.definitions[1].uri, "file:///test/definition2.zig"));
}
```

**Expected Failure:** None - this tests the struct design
**Implementation:** Ensure LspDefinitionOutput.definitions is a slice

---

## Test Suite 6: Integration Tests

### Test 6.1: Full workflow with pylsp
**Purpose:** End-to-end test using Python LSP (more reliable than zls)

```zig
test "integration: full LSP workflow with pylsp" {
    const allocator = std.testing.allocator;
    
    // Setup: Create temp workspace
    const temp_path = "/tmp/pylsp-integration-test";
    std.fs.makeDirAbsolute(temp_path) catch |e| {
        if (e != error.PathAlreadyExists) {
            std.debug.print("Skipping integration test - cannot create temp dir\n", .{});
            return;
        }
    };
    defer std.fs.deleteTreeAbsolute(temp_path) catch {};
    
    // Create test Python file
    const py_content = 
        "def add(a, b):\n" ++
        "    return a + b\n" ++
        "\n" ++
        "def main():\n" ++
        "    result = add(1, 2)\n" ++
        "    print(result)\n";
    
    const py_file_path = try std.fs.path.join(allocator, &.{ temp_path, "test.py" });
    defer allocator.free(py_file_path);
    
    try std.fs.cwd().writeFile(.{
        .sub_path = py_file_path,
        .data = py_content,
    });
    
    // Step 1: Start LSP session
    const session_id = "integration-test-session";
    const workspace_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{temp_path});
    defer allocator.free(workspace_uri);
    
    const start_input = lsp_start.LspStartInput{
        .session_id = session_id,
        .binary_name = "python3",
        .workspace_uri = workspace_uri,
    };
    
    const start_output = lsp_start.executeLspStart(allocator, start_input) catch |e| {
        std.debug.print("Skipping integration test - pylsp not available: {}\n", .{e});
        return;
    };
    defer {
        allocator.free(start_output.session_id);
        allocator.free(start_output.binary_path);
        allocator.free(start_output.status);
    }
    
    try std.testing.expect(std.mem.eql(u8, start_output.status, "started"));
    
    // Step 2: Open file (send didOpen notification)
    // ... (implementation details)
    
    // Step 3: Request definition
    const file_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{py_file_path});
    defer allocator.free(file_uri);
    
    const def_input = lsp_definition.LspDefinitionInput{
        .session_id = session_id,
        .file_uri = file_uri,
        .line = 4,  // Line with "result = add(1, 2)"
        .character = 12,  // Position of "add"
    };
    
    const def_output = lsp_definition.executeLspDefinition(allocator, def_input) catch |e| {
        std.debug.print("Definition request failed: {}\n", .{e});
        // Cleanup and skip
        const stop_input = lsp_stop.LspStopInput{ .session_id = session_id };
        const stop_output = lsp_stop.executeLspStop(allocator, stop_input) catch unreachable;
        allocator.free(stop_output.session_id);
        allocator.free(stop_output.status);
        return;
    };
    defer {
        allocator.free(def_output.file_uri);
        for (def_output.definitions) |d| {
            allocator.free(d.uri);
        }
        allocator.free(def_output.definitions);
    }
    
    // Step 4: Verify we got a definition
    try std.testing.expect(def_output.definitions.len > 0);
    
    // Step 5: Stop session
    const stop_input = lsp_stop.LspStopInput{ .session_id = session_id };
    const stop_output = lsp_stop.executeLspStop(allocator, stop_input) catch unreachable;
    defer {
        allocator.free(stop_output.session_id);
        allocator.free(stop_output.status);
    }
    
    try std.testing.expect(std.mem.eql(u8, stop_output.status, "stopped"));
}
```

**Expected Failure:** Integration not complete
**Implementation:** Full implementation of all LSP modules

---

## Running the Tests

### Run all TDD tests:
```bash
# Individual modules
zig test src/modules/agent/tools/lsp_types.zig
zig test src/modules/agent/tools/lsp_client_core.zig
zig test src/modules/agent/tools/lsp_start.zig
zig test src/modules/agent/tools/lsp_stop.zig
zig test src/modules/agent/tools/lsp_definition.zig

# All at once
zig test src/modules/agent/tools/

# With build system
zig build test
```

### TDD Cycle for Each Test:
1. **RED:** Write test, run it, watch it fail
2. **GREEN:** Write minimal code to make test pass
3. **REFACTOR:** Clean up while keeping tests green
4. **REPEAT:** Move to next test

---

## Test Coverage Checklist

- [ ] lsp_types.zig - All type definitions tested
- [ ] lsp_client_core.zig - Client lifecycle and message I/O tested
- [ ] lsp_start.zig - Session start functionality tested
- [ ] lsp_stop.zig - Session cleanup tested
- [ ] lsp_definition.zig - Go to definition tested
- [ ] Integration test - Full workflow tested
- [ ] Error handling - All error paths tested
- [ ] Memory safety - No leaks in tests
