# Simple LSP Definition Tool Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a single AI tool `lsp_definition` that spawns an LSP server, initializes it, gets the definition for a symbol, and returns the result - just like test_lsp.py but in Zig.

**Architecture:** One-shot LSP client that spawns the server, sends the full handshake (initialize → initialized → didOpen → definition), parses the response, kills the process, and returns the definition location. No session management, no persistent state.

**Tech Stack:** Zig 0.15.2, JSON-RPC over stdio, zls (Zig LSP)

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/modules/agent/tools/lsp_definition.zig` | Single tool: spawn LSP, initialize, get definition, cleanup |
| `src/modules/agent/tools/lsp_definition_test.zig` | TDD tests for the tool |
| `src/modules/agent/tools/models.zig` | Add LspDefinitionInput and LspDefinitionOutput structs |

---

## Chunk 1: Core Types

### Task 1: Add LSP types to models.zig

**Files:**
- Modify: `src/modules/agent/tools/models.zig`

- [ ] **Step 1: Write the failing test**

Add to `src/modules/agent/tools/lsp_definition_test.zig`:

```zig
const std = @import("std");
const models = @import("models.zig");

test "LspDefinitionInput has all required fields" {
    const input = models.LspDefinitionInput{
        .file_path = "/home/ginwa/project/src/main.zig",
        .line = 10,
        .character = 5,
    };
    try std.testing.expect(std.mem.eql(u8, input.file_path, "/home/ginwa/project/src/main.zig"));
    try std.testing.expectEqual(@as(u32, 10), input.line);
    try std.testing.expectEqual(@as(u32, 5), input.character);
}

test "LspDefinitionOutput has all required fields" {
    const allocator = std.testing.allocator;
    const output = models.LspDefinitionOutput{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/lib.zig"),
        .line = 20,
        .character = 8,
        .found = true,
    };
    defer allocator.free(output.file_path);
    
    try std.testing.expect(output.found);
    try std.testing.expectEqual(@as(u32, 20), output.line);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/modules/agent/tools/lsp_definition_test.zig`
Expected: FAIL with "LspDefinitionInput not found"

- [ ] **Step 3: Write minimal implementation**

Add to `src/modules/agent/tools/models.zig`:

```zig
pub const LspDefinitionInput = struct {
    file_path: []const u8,  // Absolute path to file
    line: u32,              // 0-indexed line number
    character: u32,         // 0-indexed character position
};

pub const LspDefinitionOutput = struct {
    file_path: []u8,        // Absolute path to definition
    line: u32,              // 0-indexed line number
    character: u32,         // 0-indexed character position
    found: bool,            // true if definition found
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/modules/agent/tools/lsp_definition_test.zig`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/models.zig src/modules/agent/tools/lsp_definition_test.zig
git commit --no-edit -m "feat: add LspDefinitionInput and LspDefinitionOutput types"
```

---

## Chunk 2: LSP Definition Tool

### Task 2: Create lsp_definition.zig

**Files:**
- Create: `src/modules/agent/tools/lsp_definition.zig`
- Create: `src/modules/agent/tools/lsp_definition_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const lsp_definition = @import("lsp_definition.zig");

test "lspDefinitionTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_definition.lspDefinitionTool.function.name, "lsp_definition"));
}

test "lspDefinitionTool has required parameters" {
    const params = lsp_definition.lspDefinitionTool.function.parameters;
    try std.testing.expectEqual(@as(usize, 3), params.properties.len);
    
    var has_file_path = false;
    var has_line = false;
    var has_character = false;
    
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "file_path")) has_file_path = true;
        if (std.mem.eql(u8, prop.name, "line")) has_line = true;
        if (std.mem.eql(u8, prop.name, "character")) has_character = true;
    }
    
    try std.testing.expect(has_file_path);
    try std.testing.expect(has_line);
    try std.testing.expect(has_character);
}

test "executeLspDefinition returns error for non-existent file" {
    const allocator = std.testing.allocator;
    const input = .{
        .file_path = "/nonexistent/path/file.zig",
        .line = 0,
        .character = 0,
    };
    
    const result = lsp_definition.executeLspDefinition(allocator, input);
    try std.testing.expectError(error.FileNotFound, result);
}

test "lspDefinitionToString formats found definition" {
    const allocator = std.testing.allocator;
    const output = .{
        .file_path = "/home/ginwa/project/src/lib.zig",
        .line = 20,
        .character = 8,
        .found = true,
    };
    
    const str = try lsp_definition.lspDefinitionToString(allocator, output);
    defer allocator.free(str);
    
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "file_path"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "/home/ginwa/project/src/lib.zig"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "line"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "found: true"));
}

test "lspDefinitionToString formats not found" {
    const allocator = std.testing.allocator;
    const output = .{
        .file_path = "",
        .line = 0,
        .character = 0,
        .found = false,
    };
    
    const str = try lsp_definition.lspDefinitionToString(allocator, output);
    defer allocator.free(str);
    
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "found: false"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/modules/agent/tools/lsp_definition_test.zig`
Expected: FAIL with "file not found"

- [ ] **Step 3: Write minimal implementation**

Create `src/modules/agent/tools/lsp_definition.zig`:

```zig
const std = @import("std");
const json = std.json;
const AgentTool = @import("models.zig").AgentTool;
const LspDefinitionInput = @import("models.zig").LspDefinitionInput;
const LspDefinitionOutput = @import("models.zig").LspDefinitionOutput;

// LSP error set
const LspError = error{
    FileNotFound,
    BinaryNotFound,
    ProcessSpawnFailed,
    InvalidResponse,
    DefinitionNotFound,
};

// JSON-RPC message helpers
fn createMessage(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ content.len, content });
}

// Read one JSON-RPC message from LSP stdout
fn readMessage(allocator: std.mem.Allocator, stdout: std.fs.File) ![]u8 {
    // Read headers until empty line
    var header_buf: [1024]u8 = undefined;
    var header_len: usize = 0;
    var found_empty = false;
    
    while (!found_empty) {
        const byte = stdout.reader().readByte() catch return LspError.InvalidResponse;
        if (header_len < header_buf.len) {
            header_buf[header_len] = byte;
            header_len += 1;
        }
        
        // Check for \r\n\r\n
        if (header_len >= 4) {
            const end = header_buf[header_len - 4 .. header_len];
            if (std.mem.eql(u8, end, "\r\n\r\n")) {
                found_empty = true;
            }
        }
    }
    
    // Parse Content-Length
    const header = header_buf[0..header_len];
    const prefix = "Content-Length: ";
    const start = std.mem.indexOf(u8, header, prefix) orelse return LspError.InvalidResponse;
    const end = std.mem.indexOf(u8, header[start..], "\r\n") orelse return LspError.InvalidResponse;
    const len_str = header[start + prefix.len .. start + end];
    const content_len = std.fmt.parseInt(usize, len_str, 10) catch return LspError.InvalidResponse;
    
    // Read body
    const body = try allocator.alloc(u8, content_len);
    errdefer allocator.free(body);
    
    var total_read: usize = 0;
    while (total_read < content_len) {
        const n = try stdout.reader().read(body[total_read..]);
        if (n == 0) return LspError.InvalidResponse;
        total_read += n;
    }
    
    return body;
}

// Find zls binary
fn findZls(allocator: std.mem.Allocator) ![]u8 {
    const paths = &[_][]const u8{
        "/usr/bin/zls",
        "/usr/local/bin/zls",
        "/home/ginwa/.local/bin/zls",
        "/home/ginwa/.local/share/nvim/mason/bin/zls",
        "/opt/homebrew/bin/zls",
    };
    
    for (paths) |path| {
        if (std.fs.accessAbsolute(path, .{})) {
            return try allocator.dupe(u8, path);
        } else |_| {}
    }
    
    // Try `which zls`
    var which_child = std.process.Child.init(&.{ "which", "zls" }, allocator);
    which_child.stdout_behavior = .Pipe;
    which_child.stderr_behavior = .Ignore;
    
    which_child.spawn() catch return LspError.BinaryNotFound;
    
    var buf: [256]u8 = undefined;
    const n = which_child.stdout.?.read(&buf) catch return LspError.BinaryNotFound;
    _ = which_child.wait() catch {};
    
    if (n > 0) {
        const path = std.mem.trim(u8, buf[0..n], " \n\r");
        if (path.len > 0 and path[0] == '/') {
            return try allocator.dupe(u8, path);
        }
    }
    
    return LspError.BinaryNotFound;
}

pub fn executeLspDefinition(allocator: std.mem.Allocator, input: LspDefinitionInput) !LspDefinitionOutput {
    // Verify file exists
    std.fs.accessAbsolute(input.file_path, .{}) catch return LspError.FileNotFound;
    
    // Read file content
    const file = try std.fs.cwd().openFile(input.file_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    
    // Find zls binary
    const zls_path = try findZls(allocator);
    defer allocator.free(zls_path);
    
    // Spawn zls
    var child = std.process.Child.init(&.{zls_path}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    
    try child.spawn();
    defer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }
    
    const stdin = child.stdin.?;
    const stdout = child.stdout.?;
    
    // Build file URI
    const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{input.file_path});
    defer allocator.free(uri);
    
    // 1. Send initialize
    const init_msg = try createMessage(allocator, 
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}
    );
    defer allocator.free(init_msg);
    try stdin.writeAll(init_msg);
    
    // Read initialize response
    const init_response = try readMessage(allocator, stdout);
    defer allocator.free(init_response);
    
    // 2. Send initialized notification
    const initialized_msg = try createMessage(allocator, 
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    defer allocator.free(initialized_msg);
    try stdin.writeAll(initialized_msg);
    
    // 3. Send didOpen
    const didopen_json = try std.fmt.allocPrint(allocator, 
        \\
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","languageId":"zig","version":1,"text":"{s}"}}}}}}
        \\
    , .{ uri, std.json.encodeString(content) });
    defer allocator.free(didopen_json);
    const didopen_msg = try createMessage(allocator, didopen_json);
    defer allocator.free(didopen_msg);
    try stdin.writeAll(didopen_msg);
    
    // 4. Send definition request
    const def_json = try std.fmt.allocPrint(allocator, 
        \\
        \\{{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}}}}}
        \\
    , .{ uri, input.line, input.character });
    defer allocator.free(def_json);
    const def_msg = try createMessage(allocator, def_json);
    defer allocator.free(def_msg);
    try stdin.writeAll(def_msg);
    
    // 5. Read definition response
    const def_response = try readMessage(allocator, stdout);
    defer allocator.free(def_response);
    
    // Parse response
    var parsed = try json.parseFromSlice(json.Value, allocator, def_response, .{});
    defer parsed.deinit();
    
    if (parsed.value != .object) return LspError.InvalidResponse;
    
    const result_opt = parsed.value.object.get("result");
    if (result_opt == null or result_opt.? == .null) {
        return LspDefinitionOutput{
            .file_path = try allocator.dupe(u8, ""),
            .line = 0,
            .character = 0,
            .found = false,
        };
    }
    
    const result = result_opt.?;
    
    // Handle single location or array
    var loc_obj: ?json.Value = null;
    if (result == .object) {
        loc_obj = result;
    } else if (result == .array and result.array.items.len > 0) {
        loc_obj = result.array.items[0];
    }
    
    if (loc_obj == null or loc_obj.? != .object) {
        return LspDefinitionOutput{
            .file_path = try allocator.dupe(u8, ""),
            .line = 0,
            .character = 0,
            .found = false,
        };
    }
    
    const obj = loc_obj.?;
    const uri_val = obj.object.get("uri") orelse return LspError.InvalidResponse;
    const range_val = obj.object.get("range") orelse return LspError.InvalidResponse;
    
    if (uri_val != .string or range_val != .object) return LspError.InvalidResponse;
    
    const start_val = range_val.object.get("start") orelse return LspError.InvalidResponse;
    if (start_val != .object) return LspError.InvalidResponse;
    
    const line_val = start_val.object.get("line") orelse return LspError.InvalidResponse;
    const char_val = start_val.object.get("character") orelse return LspError.InvalidResponse;
    
    if (line_val != .integer or char_val != .integer) return LspError.InvalidResponse;
    
    // Extract file path from URI
    const result_uri = uri_val.string;
    const result_path = if (std.mem.startsWith(u8, result_uri, "file://")) 
        result_uri[7..] 
    else 
        result_uri;
    
    return LspDefinitionOutput{
        .file_path = try allocator.dupe(u8, result_path),
        .line = @intCast(line_val.integer),
        .character = @intCast(char_val.integer),
        .found = true,
    };
}

pub fn lspDefinitionToString(allocator: std.mem.Allocator, result: LspDefinitionOutput) ![]const u8 {
    if (result.found) {
        return try std.fmt.allocPrint(allocator,
            \\<file_path>{s}</file_path>
            \\n<line>{d}</line>
            \\n<character>{d}</character>
            \\n<found>true</found>
        , .{ result.file_path, result.line, result.character });
    } else {
        return try allocator.dupe(u8, "<found>false</found>");
    }
}

pub const lspDefinitionTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_definition",
        .description = 
        \\Go to definition of symbol at cursor position using LSP.
        \\nSpawns zls (Zig Language Server), initializes it, and queries the definition.
        \\nReturns the file path, line, and character of the definition.
        \\n
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "file_path",
                    .type = "string",
                    .description = "Absolute path to the source file",
                },
                .{
                    .name = "line",
                    .type = "number",
                    .description = "Line number (0-indexed)",
                },
                .{
                    .name = "character",
                    .type = "number",
                    .description = "Character position (0-indexed)",
                },
            },
            .required = &.{ "file_path", "line", "character" },
        },
    },
};

test {
    _ = @import("lsp_definition_test.zig");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/modules/agent/tools/lsp_definition.zig`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/lsp_definition.zig src/modules/agent/tools/lsp_definition_test.zig
git commit --no-edit -m "feat: add simple lsp_definition tool"
```

---

## Chunk 3: Integration Test

### Task 3: Add integration test

**Files:**
- Modify: `src/modules/agent/tools/lsp_definition_test.zig`

- [ ] **Step 1: Write integration test**

Add to `lsp_definition_test.zig`:

```zig
test "integration: lsp_definition finds definition in real Zig file" {
    const allocator = std.testing.allocator;
    
    // Create a temporary test file
    const test_content = 
        \\
        const std = @import("std");
        \\
        
        \\
        const MyStruct = struct {
        \\
            value: i32,
        \\
        };
        \\
        
        \\
        pub fn main() void {
        \\
            const s = MyStruct{ .value = 42 };
        \\
            _ = s;
        \\
        }
        \\
    ;
    
    const temp_path = "/tmp/lsp_test_main.zig";
    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = test_content,
    });
    defer std.fs.cwd().deleteFile(temp_path) catch {};
    
    // Request definition of "MyStruct" on line 8 (0-indexed: 7)
    const input = LspDefinitionInput{
        .file_path = temp_path,
        .line = 7,      // Line with "const s = MyStruct..."
        .character = 16, // Position of "MyStruct"
    };
    
    const output = lsp_definition.executeLspDefinition(allocator, input) catch |e| {
        // If zls not installed, skip test
        if (e == error.BinaryNotFound) {
            std.debug.print("Skipping integration test - zls not found\n", .{});
            return;
        }
        return e;
    };
    defer {
        if (output.found) {
            allocator.free(output.file_path);
        }
    }
    
    // Should find definition at line 2 (0-indexed)
    try std.testing.expect(output.found);
    try std.testing.expect(std.mem.eql(u8, output.file_path, temp_path));
    try std.testing.expectEqual(@as(u32, 2), output.line); // MyStruct defined on line 3 (0-indexed: 2)
}
```

- [ ] **Step 2: Run integration test**

Run: `zig test src/modules/agent/tools/lsp_definition_test.zig --test-filter integration`
Expected: PASS (or skip if zls not installed)

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/lsp_definition_test.zig
git commit --no-edit -m "test: add lsp_definition integration test"
```

---

## Chunk 4: Final Verification

### Task 4: Run all tests

- [ ] **Step 1: Run all agent tool tests**

Run: `zig build test`
Expected: All tests PASS

- [ ] **Step 2: Verify build succeeds**

Run: `zig build`
Expected: Build succeeds with no errors

- [ ] **Step 3: Final commit**

```bash
git commit --no-edit -m "feat: complete simple lsp_definition tool

- One-shot LSP client: spawn, init, define, cleanup
- No session management - simple and stateless
- Works like test_lsp.py but in Zig
- Includes comprehensive TDD tests"
```

---

## Testing Commands

```bash
# Test the LSP definition tool
zig test src/modules/agent/tools/lsp_definition.zig

# Run all tests
zig build test

# Build
zig build
```

## Usage Example

```zig
const input = LspDefinitionInput{
    .file_path = "/home/ginwa/project/src/main.zig",
    .line = 10,
    .character = 5,
};

const output = try executeLspDefinition(allocator, input);
if (output.found) {
    std.debug.print("Definition at: {s}:{d}:{d}\n", .{
        output.file_path, output.line, output.character
    });
} else {
    std.debug.print("Definition not found\n", .{});
}
```

## Comparison to test_lsp.py

| test_lsp.py | lsp_definition.zig |
|-------------|-------------------|
| Spawns `zls` subprocess | Spawns `zls` subprocess |
| Sends initialize | Sends initialize |
| Sends initialized | Sends initialized |
| Sends didOpen | Sends didOpen |
| Sends definition | Sends definition |
| Parses JSON response | Parses JSON response |
| Prints result | Returns structured output |
| Exits | Cleans up and returns |
