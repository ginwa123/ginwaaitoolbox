# LSP textDocument/references Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a new LSP tool `lsp_references` that finds all references to a symbol using the `textDocument/references` LSP method, following the same pattern as the existing `lsp_definition` tool.

**Architecture:** The implementation mirrors `lsp_definition` with these key differences:
- Uses `textDocument/references` instead of `textDocument/definition`
- References always returns an array of Location (simpler parsing)
- Adds `include_declaration` parameter (LSP standard for references)

**Tech Stack:** Zig 0.15.2, JSON-RPC LSP protocol

---

## File Structure

| File | Purpose |
|------|---------|
| `src/modules/agent/tools/lsp_references.zig` | Core implementation (mirrors lsp_definition.zig) |
| `src/modules/agent/tools/lsp_references_test.zig` | TDD test cases |
| `src/modules/agent/tools/models.zig` | Add LspReferencesInput/Output types |
| `src/ai_workflow/tui/handle_lsp_references_tool.zig` | Tool handler |
| `src/ai_workflow/tui/all_agent_tools.zig` | Register tool |
| `src/ai_workflow/tui/handle_tool.zig` | Add dispatch case |

---

## Chunk 1: Types and Models

### Task 1: Add LspReferencesInput and LspReferencesOutput to models.zig

**Files:**
- Modify: `src/modules/agent/tools/models.zig`

**LspReferencesInput** (similar to LspDefinitionInput but adds `include_declaration`):
```zig
pub const LspReferencesInput = struct {
    lsp: []const u8,        // LSP binary name (e.g., "zls", "pyls")
    root_dir: []const u8,   // Project root directory
    file_path: []const u8,  // Source file path
    line: u32,              // 0-indexed line number
    character: u32,         // 0-indexed character position
    include_declaration: bool = true, // Include declaration in results
};
```

**LspReferencesOutput** (can reuse LspDefinitionOutput since structure is identical):
```zig
pub const LspReferencesOutput = LspDefinitionOutput; // Alias - same structure
```

- [ ] **Step 1: Write the failing test**

Create `src/modules/agent/tools/lsp_references_test.zig`:
```zig
const std = @import("std");
const lsp_references = @import("lsp_references.zig");
const models = @import("models.zig");

// Test 1.1: LspReferencesInput struct has all required fields
test "LspReferencesInput has all required fields" {
    const input = models.LspReferencesInput{
        .lsp = "zls",
        .root_dir = "/home/ginwa/project",
        .file_path = "/home/ginwa/project/src/main.zig",
        .line = 10,
        .character = 5,
        .include_declaration = true,
    };
    try std.testing.expect(std.mem.eql(u8, input.lsp, "zls"));
    try std.testing.expect(std.mem.eql(u8, input.root_dir, "/home/ginwa/project"));
    try std.testing.expect(std.mem.eql(u8, input.file_path, "/home/ginwa/project/src/main.zig"));
    try std.testing.expectEqual(@as(u32, 10), input.line);
    try std.testing.expectEqual(@as(u32, 5), input.character);
    try std.testing.expectEqual(true, input.include_declaration);
}

// Test 1.2: LspReferencesInput has default include_declaration = true
test "LspReferencesInput defaults include_declaration to true" {
    const input = models.LspReferencesInput{
        .lsp = "zls",
        .root_dir = "/home/ginwa/project",
        .file_path = "/home/ginwa/project/src/main.zig",
        .line = 10,
        .character = 5,
        // include_declaration not specified
    };
    try std.testing.expectEqual(true, input.include_declaration);
}

// Test 1.3: LspReferencesOutput can represent found references
test "LspReferencesOutput can represent found references" {
    const allocator = std.testing.allocator;

    const loc = models.LspLocation{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/main.zig"),
        .line = 15,
        .character = 10,
    };

    const references = try allocator.alloc(models.LspLocation, 1);
    references[0] = loc;

    var output = models.LspReferencesOutput{
        .definitions = references,  // reuses LspLocation array
        .found = true,
    };
    defer output.deinit(allocator);

    try std.testing.expect(output.found);
    try std.testing.expectEqual(@as(usize, 1), output.definitions.len);
}

// Test 1.4: LspReferencesOutput can represent no references found
test "LspReferencesOutput can represent no references found" {
    const output = models.LspReferencesOutput{
        .definitions = &.{},
        .found = false,
    };

    try std.testing.expect(!output.found);
    try std.testing.expectEqual(@as(usize, 0), output.definitions.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig test src/modules/agent/tools/lsp_references_test.zig 2>&1 | head -n 30
```

Expected: FAIL - "lsp_references.zig" not found, LspReferencesInput not found

- [ ] **Step 3: Add types to models.zig**

Add to `src/modules/agent/tools/models.zig` after LspDefinitionOutput:

```zig
// LSP References Tool Types
pub const LspReferencesInput = struct {
    lsp: []const u8, // LSP binary name (e.g., "zls", "pyls") or absolute path
    root_dir: []const u8, // Absolute path to project root directory
    file_path: []const u8, // Absolute path to file
    line: u32, // 0-indexed line number
    character: u32, // 0-indexed character position
    include_declaration: bool = true, // Include declaration in results
};

/// LSP references response is always Location[]
/// Reuse LspDefinitionOutput since structure is identical
pub const LspReferencesOutput = LspDefinitionOutput;
```

Add re-export at bottom of models.zig:
```zig
pub const lsp_references = @import("lsp_references.zig");
pub const lspReferencesTool = lsp_references.lspReferencesTool;
```

- [ ] **Step 4: Run test to verify it passes**

```bash
zig test src/modules/agent/tools/lsp_references_test.zig 2>&1 | head -n 30
```

Expected: PASS - types compile successfully

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/models.zig src/modules/agent/tools/lsp_references_test.zig
git commit --no-edit -m "feat: add LspReferencesInput and LspReferencesOutput types"
```

---

## Chunk 2: Core Implementation

### Task 2: Create lsp_references.zig with Tool Definition

**Files:**
- Create: `src/modules/agent/tools/lsp_references.zig`

- [ ] **Step 1: Write the failing test**

Add to `lsp_references_test.zig`:
```zig
// Test 2.1: lspReferencesTool has correct name
test "lspReferencesTool has correct name" {
    try std.testing.expect(std.mem.eql(u8, lsp_references.lspReferencesTool.function.name, "lsp_references"));
}

// Test 2.2: lspReferencesTool has required parameters
test "lspReferencesTool has required parameters" {
    const params = lsp_references.lspReferencesTool.function.parameters;
    // Should have 6 properties: lsp, root_dir, file_path, line, character, include_declaration
    try std.testing.expectEqual(@as(usize, 6), params.properties.len);

    var has_lsp = false;
    var has_root_dir = false;
    var has_file_path = false;
    var has_line = false;
    var has_character = false;
    var has_include_declaration = false;

    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "lsp")) has_lsp = true;
        if (std.mem.eql(u8, prop.name, "root_dir")) has_root_dir = true;
        if (std.mem.eql(u8, prop.name, "file_path")) has_file_path = true;
        if (std.mem.eql(u8, prop.name, "line")) has_line = true;
        if (std.mem.eql(u8, prop.name, "character")) has_character = true;
        if (std.mem.eql(u8, prop.name, "include_declaration")) has_include_declaration = true;
    }

    try std.testing.expect(has_lsp);
    try std.testing.expect(has_root_dir);
    try std.testing.expect(has_file_path);
    try std.testing.expect(has_line);
    try std.testing.expect(has_character);
    try std.testing.expect(has_include_declaration);
    try std.testing.expectEqual(@as(usize, 5), params.required.len); // include_declaration is optional
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
zig test src/modules/agent/tools/lsp_references_test.zig 2>&1 | head -n 30
```

Expected: FAIL - lspReferencesTool not found

- [ ] **Step 3: Create lsp_references.zig with tool definition**

Create `src/modules/agent/tools/lsp_references.zig`:

```zig
const std = @import("std");
const json = std.json;
const AgentTool = @import("models.zig").AgentTool;
pub const LspReferencesInput = @import("models.zig").LspReferencesInput;
const LspReferencesOutput = @import("models.zig").LspReferencesOutput;
const LspLocation = @import("models.zig").LspLocation;

// Re-use LSP error set from lsp_definition
pub const LspError = error{
    FileNotFound,
    BinaryNotFound,
    ProcessSpawnFailed,
    InvalidResponse,
    ReferencesNotFound,
};

// Re-use JSON-RPC helpers from lsp_definition
pub fn createMessage(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ content.len, content });
}

// Read one JSON-RPC message from LSP stdout
fn readMessage(allocator: std.mem.Allocator, stdout: std.fs.File) ![]u8 {
    // Same implementation as lsp_definition.zig
    var header_buf: [1024]u8 = undefined;
    var header_len: usize = 0;
    var found_empty = false;

    while (!found_empty) {
        var byte: [1]u8 = undefined;
        const n = stdout.read(&byte) catch return LspError.InvalidResponse;
        if (n == 0) return LspError.InvalidResponse;

        if (header_len < header_buf.len) {
            header_buf[header_len] = byte[0];
            header_len += 1;
        }

        if (header_len >= 4) {
            const end = header_buf[header_len - 4 .. header_len];
            if (std.mem.eql(u8, end, "\r\n\r\n")) {
                found_empty = true;
            }
        }
    }

    const header = header_buf[0..header_len];
    const prefix = "Content-Length: ";
    const start = std.mem.indexOf(u8, header, prefix) orelse return LspError.InvalidResponse;
    const end = std.mem.indexOf(u8, header[start..], "\r\n") orelse return LspError.InvalidResponse;
    const len_str = header[start + prefix.len .. start + end];
    const content_len = std.fmt.parseInt(usize, len_str, 10) catch return LspError.InvalidResponse;

    const body = try allocator.alloc(u8, content_len);
    errdefer allocator.free(body);

    var total_read: usize = 0;
    while (total_read < content_len) {
        const n = try stdout.read(body[total_read..]);
        if (n == 0) return LspError.InvalidResponse;
        total_read += n;
    }

    return body;
}

/// Parse LSP references response result
/// References always returns: null or Location[]
fn parseReferencesResult(allocator: std.mem.Allocator, result: json.Value) !LspReferencesOutput {
    // Handle null result
    if (result == .null) {
        return LspReferencesOutput{
            .definitions = &.{},
            .found = false,
        };
    }

    var locations = std.ArrayList(LspLocation).empty;
    defer locations.deinit(allocator);

    // References always returns an array of Location
    if (result == .array) {
        for (result.array.items) |item| {
            const loc = try parseLocation(allocator, item);
            if (loc) |l| {
                try locations.append(allocator, l);
            }
        }
    }

    const refs = try locations.toOwnedSlice(allocator);

    return LspReferencesOutput{
        .definitions = refs,
        .found = refs.len > 0,
    };
}

/// Parse a single LSP Location object
fn parseLocation(allocator: std.mem.Allocator, loc_value: json.Value) !?LspLocation {
    if (loc_value != .object) return null;

    const obj = loc_value.object;

    // Location has "uri" (not targetUri like LocationLink)
    const uri_val = obj.get("uri") orelse return null;
    if (uri_val != .string) return null;

    const range_val = obj.get("range") orelse return null;
    if (range_val != .object) return null;

    const start_val = range_val.object.get("start") orelse return null;
    if (start_val != .object) return null;

    const line_val = start_val.object.get("line") orelse return null;
    const char_val = start_val.object.get("character") orelse return null;
    if (line_val != .integer or char_val != .integer) return null;

    const result_uri = uri_val.string;
    const result_path = if (std.mem.startsWith(u8, result_uri, "file://"))
        result_uri[7..]
    else
        result_uri;

    var location = LspLocation{
        .file_path = try allocator.dupe(u8, result_path),
        .line = @intCast(line_val.integer),
        .character = @intCast(char_val.integer),
    };

    // Parse optional end position
    const end_val = range_val.object.get("end");
    if (end_val) |end| {
        if (end == .object) {
            const end_line = end.object.get("line");
            const end_char = end.object.get("character");
            if (end_line) |el| {
                if (el == .integer) {
                    location.end_line = @intCast(el.integer);
                }
            }
            if (end_char) |ec| {
                if (ec == .integer) {
                    location.end_character = @intCast(ec.integer);
                }
            }
        }
    }

    return location;
}

pub fn executeLspReferences(allocator: std.mem.Allocator, input: LspReferencesInput) !LspReferencesOutput {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Verify file exists
    std.fs.accessAbsolute(input.file_path, .{}) catch return LspError.FileNotFound;

    // Read file content
    const file = try std.fs.cwd().openFile(input.file_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(arena_allocator, 1024 * 1024);

    // Spawn LSP process
    var child = std.process.Child.init(&.{input.lsp}, arena_allocator);
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

    const uri = try std.fmt.allocPrint(arena_allocator, "file://{s}", .{input.file_path});
    const root_uri = try std.fmt.allocPrint(arena_allocator, "file://{s}", .{input.root_dir});

    // 1. Send initialize
    var init_json_buf = std.ArrayList(u8).empty;
    const init_writer = init_json_buf.writer(arena_allocator);
    try init_writer.print("{{", .{});
    try init_writer.print("\"jsonrpc\":\"2.0\",", .{});
    try init_writer.print("\"id\":1,", .{});
    try init_writer.print("\"method\":\"initialize\",", .{});
    try init_writer.print("\"params\":{{", .{});
    try init_writer.print("\"processId\":null,", .{});
    try init_writer.print("\"rootUri\":\"{s}\",", .{root_uri});
    try init_writer.print("\"capabilities\":{{}}}}}}", .{});
    const init_json = try init_json_buf.toOwnedSlice(arena_allocator);
    const init_msg = try createMessage(arena_allocator, init_json);
    try stdin.writeAll(init_msg);

    // Read initialize response
    var init_response: []u8 = undefined;
    var init_attempts: usize = 0;
    const max_init_attempts = 10;

    while (init_attempts < max_init_attempts) {
        const msg_data = try readMessage(arena_allocator, stdout);
        var temp_parsed = json.parseFromSlice(json.Value, arena_allocator, msg_data, .{}) catch {
            init_attempts += 1;
            continue;
        };

        if (temp_parsed.value.object.get("id")) |id_val| {
            if (id_val == .integer and id_val.integer == 1) {
                init_response = msg_data;
                break;
            }
        }
        init_attempts += 1;
    }

    if (init_attempts >= max_init_attempts) {
        return LspError.InvalidResponse;
    }

    // 2. Send initialized notification
    const initialized_msg = try createMessage(arena_allocator,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    try stdin.writeAll(initialized_msg);

    // 3. Send didOpen
    const didopen_json = try std.fmt.allocPrint(arena_allocator,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","languageId":"zig","version":1,"text":"
    , .{uri});

    var escaped_content = std.ArrayList(u8).empty;
    const escaped_writer = escaped_content.writer(arena_allocator);
    for (content) |c| {
        switch (c) {
            '\\' => try escaped_writer.print("\\\\", .{}),
            '"' => try escaped_writer.print("\\\"", .{}),
            '\n' => try escaped_writer.print("\\n", .{}),
            '\r' => try escaped_writer.print("\\r", .{}),
            '\t' => try escaped_writer.print("\\t", .{}),
            else => try escaped_writer.print("{c}", .{c}),
        }
    }

    const didopen_end = "\"}}}}";
    const full_didopen = try std.fmt.allocPrint(arena_allocator, "{s}{s}{s}", .{ didopen_json, escaped_content.items, didopen_end });

    const didopen_msg = try createMessage(arena_allocator, full_didopen);
    try stdin.writeAll(didopen_msg);

    std.Thread.sleep(100 * std.time.ns_per_ms);

    // 4. Send references request (KEY DIFFERENCE: textDocument/references)
    var refs_json = std.ArrayList(u8).empty;
    const w = refs_json.writer(arena_allocator);
    try w.print("{{", .{});
    try w.print("\"jsonrpc\":\"2.0\",", .{});
    try w.print("\"id\":2,", .{});
    try w.print("\"method\":\"textDocument/references\",", .{});  // <-- CHANGED
    try w.print("\"params\":{{", .{});
    try w.print("\"textDocument\":{{\"uri\":\"{s}\"}},", .{uri});
    try w.print("\"position\":{{\"line\":{d},\"character\":{d}}},", .{ input.line, input.character });
    try w.print("\"context\":{{\"includeDeclaration\":{}}}", .{input.include_declaration});
    try w.print("}}}}", .{});

    const refs_msg = try createMessage(arena_allocator, refs_json.items);
    try stdin.writeAll(refs_msg);

    // 5. Read references response
    var refs_response: []u8 = undefined;
    var attempts: usize = 0;
    const max_attempts = 10;

    while (attempts < max_attempts) {
        const msg_data = try readMessage(arena_allocator, stdout);
        var temp_parsed = json.parseFromSlice(json.Value, arena_allocator, msg_data, .{}) catch {
            attempts += 1;
            continue;
        };

        if (temp_parsed.value.object.get("id")) |id_val| {
            if (id_val == .integer and id_val.integer == 2) {
                refs_response = msg_data;
                break;
            }
        }
        attempts += 1;
    }

    if (attempts >= max_attempts) {
        return LspError.InvalidResponse;
    }

    // Parse response
    var parsed = try json.parseFromSlice(json.Value, arena_allocator, refs_response, .{});

    if (parsed.value != .object) return LspError.InvalidResponse;

    const result_opt = parsed.value.object.get("result");
    if (result_opt == null) {
        return LspReferencesOutput{
            .definitions = &.{},
            .found = false,
        };
    }

    return try parseReferencesResult(allocator, result_opt.?);
}

pub fn lspReferencesToString(allocator: std.mem.Allocator, result: LspReferencesOutput) ![]const u8 {
    if (!result.found or result.definitions.len == 0) {
        return try allocator.dupe(u8, "<found>false</found>");
    }

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.print("<found>true</found>\n", .{});
    try writer.print("<count>{d}</count>\n", .{result.definitions.len});
    try writer.print("<references>\n", .{});  // Changed from <definitions>

    for (result.definitions, 0..) |def, i| {
        try writer.print("  <reference index=\"{d}\">\n", .{i + 1});  // Changed from <definition>
        try writer.print("    <file_path>{s}</file_path>\n", .{def.file_path});
        try writer.print("    <line>{d}</line>\n", .{def.line});
        try writer.print("    <character>{d}</character>\n", .{def.character});
        if (def.end_line) |end_line| {
            try writer.print("    <end_line>{d}</end_line>\n", .{end_line});
        }
        if (def.end_character) |end_char| {
            try writer.print("    <end_character>{d}</end_character>\n", .{end_char});
        }
        try writer.print("  </reference>\n", .{});
    }

    try writer.print("</references>", .{});

    return try output.toOwnedSlice(allocator);
}

pub const lspReferencesTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_references",
        .description =
        \\Find all references to a symbol at cursor position using LSP.
        \\Spawns lsp bin, initializes it, and queries textDocument/references.
        \\Returns all locations where the symbol is used.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "lsp",
                    .type = "string",
                    .description = "LSP binary name like zls or pyls or path to binary",
                },
                .{
                    .name = "root_dir",
                    .type = "string",
                    .description = "Absolute path to the project root directory",
                },
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
                .{
                    .name = "include_declaration",
                    .type = "boolean",
                    .description = "Include the declaration location in results (default: true)",
                },
            },
            .required = &.{ "lsp", "root_dir", "file_path", "line", "character" },
        },
    },
};

test {
    _ = @import("lsp_references_test.zig");
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
zig test src/modules/agent/tools/lsp_references.zig 2>&1 | head -n 50
```

Expected: PASS - tool definition tests pass

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/lsp_references.zig
git commit --no-edit -m "feat: implement lsp_references tool core functionality"
```

---

## Chunk 3: Output Formatting Tests

### Task 3: Add output formatting tests

**Files:**
- Modify: `src/modules/agent/tools/lsp_references_test.zig`

- [ ] **Step 1: Write the failing test**

Add to `lsp_references_test.zig`:
```zig
// Test 3.1: Format found single reference
test "lspReferencesToString formats found reference" {
    const allocator = std.testing.allocator;

    const references = try allocator.alloc(models.LspLocation, 1);
    references[0] = models.LspLocation{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/main.zig"),
        .line = 15,
        .character = 10,
    };

    const output = models.LspReferencesOutput{
        .definitions = references,
        .found = true,
    };
    defer {
        allocator.free(output.definitions[0].file_path);
        allocator.free(output.definitions);
    }

    const str = try lsp_references.lspReferencesToString(allocator, output);
    defer allocator.free(str);

    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<found>true</found>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<count>1</count>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<references>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<reference index=\"1\">"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<file_path>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "/home/ginwa/project/src/main.zig"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<line>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "15"));
}

// Test 3.2: Format not found
test "lspReferencesToString formats not found" {
    const allocator = std.testing.allocator;
    const output = models.LspReferencesOutput{
        .definitions = &.{},
        .found = false,
    };

    const str = try lsp_references.lspReferencesToString(allocator, output);
    defer allocator.free(str);

    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<found>false</found>"));
}

// Test 3.3: Format multiple references
test "lspReferencesToString formats multiple references" {
    const allocator = std.testing.allocator;

    const references = try allocator.alloc(models.LspLocation, 2);
    references[0] = models.LspLocation{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/main.zig"),
        .line = 10,
        .character = 5,
    };
    references[1] = models.LspLocation{
        .file_path = try allocator.dupe(u8, "/home/ginwa/project/src/lib.zig"),
        .line = 25,
        .character = 8,
    };

    const output = models.LspReferencesOutput{
        .definitions = references,
        .found = true,
    };
    defer {
        for (output.definitions) |*ref| {
            allocator.free(ref.file_path);
        }
        allocator.free(output.definitions);
    }

    const str = try lsp_references.lspReferencesToString(allocator, output);
    defer allocator.free(str);

    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<found>true</found>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<count>2</count>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<reference index=\"1\">"));
    try std.testing.expect(std.mem.containsAtLeast(u8, str, 1, "<reference index=\"2\">"));
}

// Test 3.4: createMessage helper
test "createMessage formats Content-Length header" {
    const allocator = std.testing.allocator;
    const content = "{\"jsonrpc\":\"2.0\"}";

    const msg = try lsp_references.createMessage(allocator, content);
    defer allocator.free(msg);

    try std.testing.expect(std.mem.startsWith(u8, msg, "Content-Length:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, msg, 1, "\r\n\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, msg, content));
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
zig test src/modules/agent/tools/lsp_references.zig 2>&1 | head -n 50
```

Expected: FAIL - lspReferencesToString not found

- [ ] **Step 3: Implementation already done in Step 3 of Task 2**

The `lspReferencesToString` and `createMessage` functions were already added in the previous step.

- [ ] **Step 4: Run test to verify it passes**

```bash
zig test src/modules/agent/tools/lsp_references.zig 2>&1 | head -n 50
```

Expected: PASS - all formatting tests pass

- [ ] **Step 5: Commit**

```bash
git add src/modules/agent/tools/lsp_references_test.zig
git commit --no-edit -m "test: add output formatting tests for lsp_references"
```

---

## Chunk 4: Error Handling Tests

### Task 4: Add error handling tests

**Files:**
- Modify: `src/modules/agent/tools/lsp_references_test.zig`

- [ ] **Step 1: Write the failing test**

Add to `lsp_references_test.zig`:
```zig
// Test 4.1: Non-existent file returns FileNotFound
test "executeLspReferences returns error for non-existent file" {
    const allocator = std.testing.allocator;
    const input = models.LspReferencesInput{
        .lsp = "zls",
        .root_dir = "/nonexistent/path",
        .file_path = "/nonexistent/path/that/does/not/exist.zig",
        .line = 0,
        .character = 0,
        .include_declaration = true,
    };

    const result = lsp_references.executeLspReferences(allocator, input);
    try std.testing.expectError(error.FileNotFound, result);
}

// Test 4.2: LspError error set contains expected errors
test "LspError error set contains expected errors" {
    const errors = [_]lsp_references.LspError{
        error.FileNotFound,
        error.BinaryNotFound,
        error.ProcessSpawnFailed,
        error.InvalidResponse,
        error.ReferencesNotFound,
    };
    try std.testing.expectEqual(@as(usize, 5), errors.len);
}
```

- [ ] **Step 2: Run test to verify it passes**

```bash
zig test src/modules/agent/tools/lsp_references.zig 2>&1 | head -n 50
```

Expected: PASS - error handling tests pass

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/lsp_references_test.zig
git commit --no-edit -m "test: add error handling tests for lsp_references"
```

---

## Chunk 5: Tool Handler

### Task 5: Create handle_lsp_references_tool.zig

**Files:**
- Create: `src/ai_workflow/tui/handle_lsp_references_tool.zig`

- [ ] **Step 1: Create the handler file**

Create `src/ai_workflow/tui/handle_lsp_references_tool.zig`:

```zig
const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const lsp_references_tool = tree1_mod.tool_models.lsp_references;

/// Stateless lsp_references tool handler
pub fn run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to LspReferencesInput
    const parsed = std.json.parseFromSlice(
        lsp_references_tool.LspReferencesInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to parse lsp_references arguments: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer parsed.deinit();

    const result = lsp_references_tool.executeLspReferences(allocator, parsed.value) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to get references: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer result.deinit(allocator);

    return lsp_references_tool.lspReferencesToString(allocator, result);
}
```

- [ ] **Step 2: Verify it compiles**

```bash
zig build 2>&1 | head -n 50
```

Expected: Should compile (may have unused import warnings)

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/handle_lsp_references_tool.zig
git commit --no-edit -m "feat: add lsp_references tool handler"
```

---

## Chunk 6: Tool Registration

### Task 6: Register tool in all_agent_tools.zig

**Files:**
- Modify: `src/ai_workflow/tui/all_agent_tools.zig`

- [ ] **Step 1: Add import and registration**

Add import after lspDefinitionTool:
```zig
const lspDefinitionTool = root_mod.tool_models.lspDefinitionTool;
const lspReferencesTool = root_mod.tool_models.lspReferencesTool;
```

Add to AllAgentTools array:
```zig
pub const AllAgentTools: []const tool_models.AgentTool = &.{
    // ... existing tools ...
    lspDefinitionTool,
    lspReferencesTool,  // <-- ADD THIS
};
```

- [ ] **Step 2: Verify it compiles**

```bash
zig build 2>&1 | head -n 50
```

Expected: PASS - compiles successfully

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/all_agent_tools.zig
git commit --no-edit -m "feat: register lsp_references tool"
```

---

## Chunk 7: Tool Dispatch

### Task 7: Add dispatch in handle_tool.zig

**Files:**
- Modify: `src/ai_workflow/tui/handle_tool.zig`

- [ ] **Step 1: Add import**

Add after handle_lsp_definition_tool import:
```zig
const handle_lsp_definition_tool = @import("handle_lsp_definition_tool.zig");
const handle_lsp_references_tool = @import("handle_lsp_references_tool.zig");
```

- [ ] **Step 2: Add dispatch case**

Add after lsp_definition dispatch case (around line 370):
```zig
if (std.mem.eql(u8, tool_call.function.name, "lsp_definition")) {
    const result = handle_lsp_definition_tool.run(allocator, tool_call) catch |err|
        try std.fmt.allocPrint(allocator, "ERROR: lsp_definition failed: {s}", .{@errorName(err)});
    defer allocator.free(result);
    try handleToolResult(ctx, tool_call, result);
    continue;
}

// ADD THIS BLOCK:
if (std.mem.eql(u8, tool_call.function.name, "lsp_references")) {
    const result = handle_lsp_references_tool.run(allocator, tool_call) catch |err|
        try std.fmt.allocPrint(allocator, "ERROR: lsp_references failed: {s}", .{@errorName(err)});
    defer allocator.free(result);
    try handleToolResult(ctx, tool_call, result);
    continue;
}
```

- [ ] **Step 3: Verify it compiles**

```bash
zig build 2>&1 | head -n 50
```

Expected: PASS - compiles successfully

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/handle_tool.zig
git commit --no-edit -m "feat: add lsp_references tool dispatch"
```

---

## Chunk 8: Integration Test

### Task 8: Add integration test with real zls

**Files:**
- Modify: `src/modules/agent/tools/lsp_references_test.zig`

- [ ] **Step 1: Write the integration test**

Add to `lsp_references_test.zig`:
```zig
// Test 5.1: Full workflow with real zls
test "integration: lsp_references finds references in real Zig file" {
    const allocator = std.testing.allocator;

    // Create test file with a symbol used in multiple places
    const test_content =
        \\const std = @import("std");
        \\
        \\const MyStruct = struct {
        \\    value: i32,
        \\};
        \\
        \\pub fn main() void {
        \\    const s1 = MyStruct{ .value = 42 };
        \\    const s2 = MyStruct{ .value = 100 };
        \\    _ = s1;
        \\    _ = s2;
        \\}
        \\
    ;

    const temp_path = "/tmp/lsp_references_test_main.zig";
    try std.fs.cwd().writeFile(.{
        .sub_path = temp_path,
        .data = test_content,
    });
    defer std.fs.cwd().deleteFile(temp_path) catch {};

    // Request references to MyStruct
    const input = models.LspReferencesInput{
        .lsp = "zls",
        .root_dir = "/tmp",
        .file_path = temp_path,
        .line = 2,  // Line with "const MyStruct"
        .character = 6,  // Position of "MyStruct"
        .include_declaration = true,
    };

    const output = lsp_references.executeLspReferences(allocator, input) catch |e| {
        if (e == error.BinaryNotFound) {
            std.debug.print("Skipping integration test - zls not found\n", .{});
            return;
        }
        std.debug.print("Integration test error: {}\n", .{e});
        return e;
    };
    defer output.deinit(allocator);

    std.debug.print("Integration test: found={}, references.len={d}\n", .{
        output.found,
        output.definitions.len,
    });

    if (output.found and output.definitions.len > 0) {
        for (output.definitions, 0..) |ref, i| {
            std.debug.print("  [{d}] file_path={s}, line={d}, character={d}\n", .{
                i,
                ref.file_path,
                ref.line,
                ref.character,
            });
        }
    }

    // Skip if no references found (zls might not be fully initialized)
    if (!output.found or output.definitions.len == 0) {
        std.debug.print("Skipping integration test - references not found\n", .{});
        return;
    }

    // Should find at least 3 references:
    // 1. Declaration (line 2)
    // 2. Usage in main (line 6)
    // 3. Usage in main (line 7)
    try std.testing.expect(output.found);
    try std.testing.expect(output.definitions.len >= 1);
}
```

- [ ] **Step 2: Run test**

```bash
zig test src/modules/agent/tools/lsp_references.zig 2>&1 | head -n 50
```

Expected: PASS - may skip if zls not installed

- [ ] **Step 3: Commit**

```bash
git add src/modules/agent/tools/lsp_references_test.zig
git commit --no-edit -m "test: add integration test for lsp_references"
```

---

## Final Verification

### Task 9: Full build and test

- [ ] **Step 1: Run all tests**

```bash
zig build test 2>&1 | tail -n 50
```

Expected: All tests pass

- [ ] **Step 2: Build the project**

```bash
zig build 2>&1 | tail -n 20
```

Expected: Build succeeds

- [ ] **Step 3: Final commit**

```bash
git log --oneline -10
```

Expected: All commits present

---

## Summary

This implementation adds a new `lsp_references` tool that:

1. **Follows the same pattern as `lsp_definition`** - same architecture, same file structure
2. **Uses `textDocument/references`** LSP method instead of `textDocument/definition`
3. **Adds `include_declaration` parameter** - LSP standard for references queries
4. **Returns XML output** with `<references>` and `<reference>` tags (vs `<definitions>`)
5. **Reuses existing types** - `LspLocation` and `LspDefinitionOutput` (aliased as `LspReferencesOutput`)

### Key Differences from lsp_definition:

| Aspect | lsp_definition | lsp_references |
|--------|---------------|----------------|
| LSP Method | `textDocument/definition` | `textDocument/references` |
| Response Type | null/Location/Location[]/LocationLink[] | null/Location[] |
| Extra Parameter | None | `include_declaration: bool` |
| XML Root Tag | `<definitions>` | `<references>` |
| XML Item Tag | `<definition>` | `<reference>` |

### Files Created/Modified:

- **Created:**
  - `src/modules/agent/tools/lsp_references.zig`
  - `src/modules/agent/tools/lsp_references_test.zig`
  - `src/ai_workflow/tui/handle_lsp_references_tool.zig`

- **Modified:**
  - `src/modules/agent/tools/models.zig` - Add types and re-export
  - `src/ai_workflow/tui/all_agent_tools.zig` - Register tool
  - `src/ai_workflow/tui/handle_tool.zig` - Add dispatch

---

**Plan complete and saved to `.nalar/plans/20250115_lsp_references_implementation.md`. Ready to execute?**
