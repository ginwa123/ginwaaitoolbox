# LSP Workspace/Symbol Tool Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement an LSP tool for workspace/symbol that allows searching for symbols across the entire workspace using LSP's `workspace/symbol` method.

**Architecture:** The tool follows the same pattern as existing LSP tools (lsp_definition, lsp_references). It spawns an LSP binary, initializes it, sends a `workspace/symbol` request with a query string, and parses the response containing symbol information from across the workspace.

**Tech Stack:** Zig 0.15.2, LSP JSON-RPC protocol

---

## Background

The LSP `workspace/symbol` method is different from `textDocument/definition` and `textDocument/references`:
- It doesn't require a file_path, line, or character - it searches across the entire workspace
- It takes a `query` parameter which is the search string
- It returns `SymbolInformation[]` or `WorkspaceSymbol[]` which contains:
  - name: symbol name
  - kind: symbol kind (function, variable, class, etc.)
  - location: file path and position
  - containerName: optional parent container name

## Files to Create/Modify

### New Files:
1. `src/modules/agent/tools/lsp_workspace_symbol.zig` - Main tool implementation
2. `src/modules/agent/tools/lsp_workspace_symbol_test.zig` - Unit tests
3. `src/ai_workflow/tui/handle_lsp_workspace_symbol_tool.zig` - TUI handler

### Modified Files:
4. `src/modules/agent/tools/models.zig` - Add types and export
5. `src/ai_workflow/tui/handle_tool.zig` - Add tool handling

---

## Task 1: Add Types to models.zig

**Files:**
- Modify: `src/modules/agent/tools/models.zig`

- [ ] **Step 1.1: Add LspWorkspaceSymbolInput struct**

Add after LspReferencesInput:
```zig
// LSP Workspace/Symbol Tool Types
pub const LspWorkspaceSymbolInput = struct {
    lsp: []const u8, // LSP binary name (e.g., "zls", "pyls") or absolute path
    root_dir: []const u8, // Absolute path to project root directory
    query: []const u8, // Search query string
    max_output: ?u32 = 100, // Maximum number of results to return (default: 100)
};
```

- [ ] **Step 1.2: Add LspWorkspaceSymbol struct**

Add after LspLocation:
```zig
/// Represents a single workspace symbol
pub const LspWorkspaceSymbol = struct {
    name: []u8, // Symbol name
    kind: u32, // Symbol kind (LSP SymbolKind enum value)
    file_path: []u8, // Absolute path to file
    line: u32, // 0-indexed line number
    character: u32, // 0-indexed character position
    container_name: ?[]u8 = null, // Optional parent container name

    /// Free all allocated memory
    pub fn deinit(self: *const LspWorkspaceSymbol, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.file_path);
        if (self.container_name) |cn| {
            allocator.free(cn);
        }
    }
};
```

- [ ] **Step 1.3: Add LspWorkspaceSymbolOutput struct**

Add after LspWorkspaceSymbol:
```zig
/// LSP workspace/symbol response
pub const LspWorkspaceSymbolOutput = struct {
    symbols: []LspWorkspaceSymbol, // Array of symbols (empty if not found)
    found: bool, // true if at least one symbol found

    /// Free all allocated memory in symbols array
    pub fn deinit(self: *const LspWorkspaceSymbolOutput, allocator: std.mem.Allocator) void {
        for (self.symbols) |sym| {
            sym.deinit(allocator);
        }
        allocator.free(self.symbols);
    }
};
```

- [ ] **Step 1.4: Add import and export**

Add after lsp_references import:
```zig
pub const lsp_workspace_symbol = @import("lsp_workspace_symbol.zig");
```

Add after lspReferencesTool export:
```zig
pub const lspWorkspaceSymbolTool = lsp_workspace_symbol.lspWorkspaceSymbolTool;
```

---

## Task 2: Create lsp_workspace_symbol.zig

**Files:**
- Create: `src/modules/agent/tools/lsp_workspace_symbol.zig`

- [ ] **Step 2.1: Create file with imports and error set**

```zig
const std = @import("std");
const json = std.json;
const AgentTool = @import("models.zig").AgentTool;
pub const LspWorkspaceSymbolInput = @import("models.zig").LspWorkspaceSymbolInput;
const LspWorkspaceSymbolOutput = @import("models.zig").LspWorkspaceSymbolOutput;
const LspWorkspaceSymbol = @import("models.zig").LspWorkspaceSymbol;

// LSP error set
pub const LspError = error{
    BinaryNotFound,
    ProcessSpawnFailed,
    InvalidResponse,
    SymbolsNotFound,
};
```

- [ ] **Step 2.2: Copy JSON-RPC helpers from lsp_definition.zig**

Copy `createMessage` and `readMessage` functions (same as lsp_definition.zig).

- [ ] **Step 2.3: Implement parseSymbol function**

Parse a single SymbolInformation or WorkspaceSymbol object:
```zig
fn parseSymbol(allocator: std.mem.Allocator, sym_value: json.Value) !?LspWorkspaceSymbol {
    if (sym_value != .object) return null;
    const obj = sym_value.object;

    // Get name
    const name_val = obj.get("name") orelse return null;
    if (name_val != .string) return null;

    // Get kind
    const kind_val = obj.get("kind") orelse return null;
    if (kind_val != .integer) return null;

    // Get location (for SymbolInformation) or directly from object (for WorkspaceSymbol)
    var file_path: []u8 = undefined;
    var line: u32 = 0;
    var character: u32 = 0;

    const loc_val = obj.get("location");
    if (loc_val) |loc| {
        // SymbolInformation format
        if (loc != .object) return null;
        const uri_val = loc.object.get("uri") orelse return null;
        if (uri_val != .string) return null;

        const result_uri = uri_val.string;
        file_path = if (std.mem.startsWith(u8, result_uri, "file://"))
            try allocator.dupe(u8, result_uri[7..])
        else
            try allocator.dupe(u8, result_uri);

        const range_val = loc.object.get("range") orelse return null;
        if (range_val != .object) return null;

        const start_val = range_val.object.get("start") orelse return null;
        if (start_val != .object) return null;

        const line_val = start_val.object.get("line") orelse return null;
        const char_val = start_val.object.get("character") orelse return null;
        if (line_val != .integer or char_val != .integer) return null;

        line = @intCast(line_val.integer);
        character = @intCast(char_val.integer);
    } else {
        // WorkspaceSymbol format - has uri directly
        const uri_val = obj.get("uri") orelse return null;
        if (uri_val != .string) return null;

        const result_uri = uri_val.string;
        file_path = if (std.mem.startsWith(u8, result_uri, "file://"))
            try allocator.dupe(u8, result_uri[7..])
        else
            try allocator.dupe(u8, result_uri);

        // WorkspaceSymbol may have range or selectionRange
        const range_val = obj.get("range") orelse obj.get("selectionRange");
        if (range_val) |r| {
            if (r == .object) {
                const start_val = r.object.get("start") orelse null;
                if (start_val) |s| {
                    if (s == .object) {
                        const line_val = s.object.get("line");
                        const char_val = s.object.get("character");
                        if (line_val) |lv| {
                            if (lv == .integer) line = @intCast(lv.integer);
                        }
                        if (char_val) |cv| {
                            if (cv == .integer) character = @intCast(cv.integer);
                        }
                    }
                }
            }
        }
    }

    // Get optional containerName
    var container_name: ?[]u8 = null;
    const container_val = obj.get("containerName");
    if (container_val) |cv| {
        if (cv == .string) {
            container_name = try allocator.dupe(u8, cv.string);
        }
    }

    return LspWorkspaceSymbol{
        .name = try allocator.dupe(u8, name_val.string),
        .kind = @intCast(kind_val.integer),
        .file_path = file_path,
        .line = line,
        .character = character,
        .container_name = container_name,
    };
}
```

- [ ] **Step 2.4: Implement parseWorkspaceSymbolResult function**

```zig
fn parseWorkspaceSymbolResult(allocator: std.mem.Allocator, result: json.Value, max_output: ?u32) !LspWorkspaceSymbolOutput {
    if (result == .null) {
        return LspWorkspaceSymbolOutput{
            .symbols = &.{},
            .found = false,
        };
    }

    var symbols = std.ArrayList(LspWorkspaceSymbol).empty;
    defer symbols.deinit(allocator);

    const limit = max_output orelse 100;

    if (result == .array) {
        for (result.array.items) |item| {
            if (symbols.items.len >= limit) break;
            const sym = try parseSymbol(allocator, item);
            if (sym) |s| {
                try symbols.append(allocator, s);
            }
        }
    }

    const syms = try symbols.toOwnedSlice(allocator);

    return LspWorkspaceSymbolOutput{
        .symbols = syms,
        .found = syms.len > 0,
    };
}
```

- [ ] **Step 2.5: Implement executeLspWorkspaceSymbol function**

Similar to executeLspDefinition but:
- No file_path parameter needed
- No didOpen needed (workspace-wide search)
- Sends `workspace/symbol` request with query parameter

Key differences:
```zig
// 4. Send workspace/symbol request
var symbol_json = std.ArrayList(u8).empty;
const w = symbol_json.writer(arena_allocator);
try w.print("{{", .{});
try w.print("\"jsonrpc\":\"2.0\",", .{});
try w.print("\"id\":2,", .{});
try w.print("\"method\":\"workspace/symbol\",", .{});
try w.print("\"params\":{{", .{});
try w.print("\"query\":\"{s}\"", .{input.query});
try w.print("}}}}", .{});
```

- [ ] **Step 2.6: Implement lspWorkspaceSymbolToString function**

Format output as XML with symbol information:
```zig
pub fn lspWorkspaceSymbolToString(allocator: std.mem.Allocator, result: LspWorkspaceSymbolOutput) ![]const u8 {
    if (!result.found or result.symbols.len == 0) {
        return try allocator.dupe(u8, "<found>false</found>");
    }

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.print("<found>true</found>\n", .{});
    try writer.print("<count>{d}</count>\n", .{result.symbols.len});
    try writer.print("<symbols>\n", .{});

    for (result.symbols, 0..) |sym, i| {
        try writer.print("  <symbol index=\"{d}\">\n", .{i + 1});
        try writer.print("    <name>{s}</name>\n", .{sym.name});
        try writer.print("    <kind>{d}</kind>\n", .{sym.kind});
        try writer.print("    <file_path>{s}</file_path>\n", .{sym.file_path});
        try writer.print("    <line>{d}</line>\n", .{sym.line});
        try writer.print("    <character>{d}</character>\n", .{sym.character});
        if (sym.container_name) |cn| {
            try writer.print("    <container_name>{s}</container_name>\n", .{cn});
        }
        try writer.print("  </symbol>\n", .{});
    }

    try writer.print("</symbols>", .{});

    return try output.toOwnedSlice(allocator);
}
```

- [ ] **Step 2.7: Define lspWorkspaceSymbolTool**

```zig
pub const lspWorkspaceSymbolTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_workspace_symbol",
        .description =
        \\Search for symbols across the entire workspace using LSP.
        \\Spawns lsp bin, initializes it, and queries workspace/symbol.
        \\Returns all matching symbols with their names, kinds, and locations.
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
                    .name = "query",
                    .type = "string",
                    .description = "Search query string to find symbols",
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description = "Maximum number of results to return (default: 100)",
                },
            },
            .required = &.{ "lsp", "root_dir", "query" },
        },
    },
};

test {
    _ = @import("lsp_workspace_symbol_test.zig");
}
```

---

## Task 3: Create lsp_workspace_symbol_test.zig

**Files:**
- Create: `src/modules/agent/tools/lsp_workspace_symbol_test.zig`

- [ ] **Step 3.1: Create test file with basic struct tests**

Follow the same pattern as lsp_definition_test.zig:
- Test LspWorkspaceSymbolInput has all required fields
- Test LspWorkspaceSymbolOutput can represent found symbols
- Test LspWorkspaceSymbolOutput can represent not found
- Test LspWorkspaceSymbolOutput can hold multiple symbols

- [ ] **Step 3.2: Add tool definition tests**

- Test lspWorkspaceSymbolTool has correct name
- Test lspWorkspaceSymbolTool has required parameters

- [ ] **Step 3.3: Add formatting tests**

- Test lspWorkspaceSymbolToString formats found symbols
- Test lspWorkspaceSymbolToString formats not found

---

## Task 4: Create handle_lsp_workspace_symbol_tool.zig

**Files:**
- Create: `src/ai_workflow/tui/handle_lsp_workspace_symbol_tool.zig`

- [ ] **Step 4.1: Create handler file**

Follow the same pattern as handle_lsp_definition_tool.zig:
```zig
const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const lsp_workspace_symbol_tool = tree1_mod.tool_models.lsp_workspace_symbol;

/// Stateless lsp_workspace_symbol tool handler
pub fn run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    const parsed = std.json.parseFromSlice(
        lsp_workspace_symbol_tool.LspWorkspaceSymbolInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    ) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to parse lsp_workspace_symbol arguments: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer parsed.deinit();

    const result = lsp_workspace_symbol_tool.executeLspWorkspaceSymbol(allocator, parsed.value) catch |err| {
        return try std.fmt.allocPrint(allocator,
            "<error>Failed to search workspace symbols: {s}</error>",
            .{@errorName(err)},
        );
    };
    defer result.deinit(allocator);

    return lsp_workspace_symbol_tool.lspWorkspaceSymbolToString(allocator, result);
}
```

---

## Task 5: Update handle_tool.zig

**Files:**
- Modify: `src/ai_workflow/tui/handle_tool.zig`

- [ ] **Step 5.1: Add import**

Add after handle_lsp_references_tool import:
```zig
const handle_lsp_workspace_symbol_tool = @import("handle_lsp_workspace_symbol_tool.zig");
```

- [ ] **Step 5.2: Add tool handling**

Add after lsp_references handling block:
```zig
if (std.mem.eql(u8, tool_call.function.name, "lsp_workspace_symbol")) {
    const result = handle_lsp_workspace_symbol_tool.run(allocator, tool_call) catch |err|
        try std.fmt.allocPrint(allocator, "ERROR: lsp_workspace_symbol failed: {s}", .{@errorName(err)});
    defer allocator.free(result);

    try handleToolResult(ctx, tool_call, result);
    continue;
}
```

---

## Task 6: Build and Test

- [ ] **Step 6.1: Build the project**

Run: `zig build`
Expected: Build succeeds with no errors

- [ ] **Step 6.2: Run tests**

Run: `zig build test`
Expected: All tests pass

- [ ] **Step 6.3: Verify tool is registered**

Check that lspWorkspaceSymbolTool is accessible via tool_models

---

## Symbol Kind Reference (LSP)

For reference, common LSP SymbolKind values:
- 1: File
- 2: Module
- 3: Namespace
- 4: Package
- 5: Class
- 6: Method
- 7: Property
- 8: Field
- 9: Constructor
- 10: Enum
- 11: Interface
- 12: Function
- 13: Variable
- 14: Constant
- 15: String
- 16: Number
- 17: Boolean
- 18: Array
- 19: Object
- 20: Key
- 21: Null
- 22: EnumMember
- 23: Struct
- 24: Event
- 25: Operator
- 26: TypeParameter
