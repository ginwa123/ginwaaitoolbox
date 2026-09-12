//! Agent-callable tools for progressive tool search: `search_tool`,
//! `view_tool`, `use_tool`.
//!
//! The agent does not receive every tool up front. These three let it
//! browse a CATALOG of tools it does not currently have and enable one for
//! the rest of the session:
//!
//!   search_tool  → query the catalog (name/description substring)
//!   view_tool    → read one entry's full parameter schema (read-only)
//!   use_tool     → enable it for this session (`session_progressive_tool`)
//!
//! The catalog is defined in `src/agentic_loop/progressive_catalog.zig`.
//! The RENDERERS for these three live there too, not here: this module sits
//! under `src/modules/` and must not import from `src/agentic_loop/`
//! (that would close an import cycle through the `nalarcore` root). Keep
//! this file pure data — AgentTool literals, prompts and input structs —
//! exactly like the other `src/modules/agent/tools/*.zig` definitions.
//!
//! Plan: docs/superpowers/plans/2026-09-12-progressive-tool-search.md

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// Input for `search_tool`. Both fields optional: no args returns the first
/// page of the whole catalog.
pub const SearchToolInput = struct {
    query: ?[]const u8 = null,
    server: ?[]const u8 = null,
};

/// Input for `view_tool`.
pub const ViewToolInput = struct {
    name: ?[]const u8 = null,
};

/// Input for `use_tool`.
pub const UseToolInput = struct {
    name: ?[]const u8 = null,
};

pub const search_tool_system_prompt =
    \\## Search Tool — Behavior
    \\Some tools are NOT loaded into your context by default. `search_tool` finds them.
    \\- Query matches tool names and descriptions (case-insensitive). `server` narrows to one MCP server.
    \\- Results show `kind` (builtin/mcp), `server` and whether the entry is already enabled for this session.
    \\- Tools you already have in your tool list are NOT listed — check your own tool definitions first before concluding a capability is missing.
    \\- After finding a candidate, call `view_tool` for its full parameters, then `use_tool` to enable it.
    \\
;

pub const search_tool_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search_tool",
        .description =
        \\Search the catalog of tools that are NOT currently enabled for this session (MCP tools and built-in tools this agent does not have). Returns name, kind, server, enabled state and a one-line summary — never the full parameter schema; call view_tool for that. Tools already in your tool list are excluded, so a zero-result search means 'look at your existing tools'. Call this whenever a task needs a capability you do not seem to have.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "query",
                    .type = "string",
                    .description = "Case-insensitive substring to match against tool name and description. Omit to list the start of the catalog.",
                },
                .{
                    .name = "server",
                    .type = "string",
                    .description = "Optional exact MCP server name filter (e.g. 'context7'). Ignored for built-in tools.",
                },
            },
            .required = &.{},
        },
        .system_prompt = search_tool_system_prompt,
    },
};

pub const view_tool_system_prompt =
    \\## View Tool — Behavior
    \\Use `view_tool` to inspect ONE catalog entry's full parameter schema before committing to it.
    \\- Read-only: it never enables anything and writes nothing.
    \\- Pass the exact `name` from `search_tool`.
    \\- Use it when you need the real argument names/types, or to confirm a tool does what you need.
    \\- If the name is unknown you get a did-you-mean list — do not guess a name twice.
    \\
;

pub const view_tool_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "view_tool",
        .description =
        \\Show one catalog tool's full definition (description + JSON parameter schema) WITHOUT enabling it. Use the exact name returned by search_tool. Read-only, no side effects. Follow with use_tool to make it callable.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Exact tool name from search_tool (e.g. 'mcp_context7_query-docs' or 'kanban_list').",
                },
            },
            .required = &.{"name"},
        },
        .system_prompt = view_tool_system_prompt,
    },
};

pub const use_tool_system_prompt =
    \\## Use Tool — Behavior
    \\Use `use_tool` to ENABLE a catalog tool for the rest of this session.
    \\- It takes effect on your NEXT turn — the current turn's tool list was already sent. The result includes the full parameter schema so you can write the call correctly right away.
    \\- It is idempotent: enabling an already-enabled tool writes nothing and reports inserted=false.
    \\- You cannot invent a name: unknown names are rejected with suggestions and nothing is written.
    \\- This only affects THIS session. It never changes the user's saved tool configuration.
    \\
;

pub const use_tool_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "use_tool",
        .description =
        \\Enable a catalog tool for this session so you can call it from your next turn onward (the current turn's tool list was already sent). Takes the exact name from search_tool/view_tool. Idempotent — enabling an already-enabled tool is a no-op that reports inserted=false. Unknown names are rejected with suggestions and nothing is written. Session-scoped only: the user's saved tool configuration is never modified.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Exact tool name to enable (from search_tool / view_tool).",
                },
            },
            .required = &.{"name"},
        },
        .system_prompt = use_tool_system_prompt,
    },
};

/// Every progressive tool name, in the order they should be appended to the
/// tools array. The workflow and the exec-registry static contracts both
/// reference this so a renamed tool cannot drift.
pub const PROGRESSIVE_TOOL_NAMES = [_][]const u8{
    search_tool_tool.function.name,
    view_tool_tool.function.name,
    use_tool_tool.function.name,
};

/// The three definitions as a slice, for callers that append them to the
/// eligible tool set.
pub const ALL_PROGRESSIVE_TOOLS = [_]AgentTool{
    search_tool_tool,
    view_tool_tool,
    use_tool_tool,
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "progressive tools: wire names are exactly search_tool/view_tool/use_tool" {
    try testing.expectEqualStrings("search_tool", search_tool_tool.function.name);
    try testing.expectEqualStrings("view_tool", view_tool_tool.function.name);
    try testing.expectEqualStrings("use_tool", use_tool_tool.function.name);
    try testing.expectEqual(@as(usize, 3), ALL_PROGRESSIVE_TOOLS.len);
    try testing.expectEqual(@as(usize, 3), PROGRESSIVE_TOOL_NAMES.len);
    for (ALL_PROGRESSIVE_TOOLS, PROGRESSIVE_TOOL_NAMES) |tool, name| {
        try testing.expectEqualStrings(name, tool.function.name);
    }
}

test "search_tool: both params optional; description points at view_tool/use_tool" {
    try testing.expectEqualStrings("function", search_tool_tool.type);
    try testing.expectEqual(@as(usize, 0), search_tool_tool.function.parameters.required.len);
    try testing.expectEqual(@as(usize, 2), search_tool_tool.function.parameters.properties.len);
    const d = search_tool_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, d, "view_tool") != null);
    try testing.expect(std.mem.indexOf(u8, d, "MCP tools") != null);
    // The "already-enabled tools are not listed" caveat must be in the
    // description too, not only the system prompt — the description is the
    // signal the model reads when deciding whether to call.
    try testing.expect(std.mem.indexOf(u8, d, "already in your tool list are excluded") != null);
}

test "view_tool: name is required; description states read-only" {
    try testing.expectEqual(@as(usize, 1), view_tool_tool.function.parameters.required.len);
    try testing.expectEqualStrings("name", view_tool_tool.function.parameters.required[0]);
    try testing.expect(std.mem.indexOf(u8, view_tool_tool.function.description, "Read-only") != null);
}

test "use_tool: name is required; description states idempotence + session scope" {
    try testing.expectEqual(@as(usize, 1), use_tool_tool.function.parameters.required.len);
    try testing.expectEqualStrings("name", use_tool_tool.function.parameters.required[0]);
    const d = use_tool_tool.function.description;
    try testing.expect(std.mem.indexOf(u8, d, "Idempotent") != null);
    try testing.expect(std.mem.indexOf(u8, d, "inserted=false") != null);
    try testing.expect(std.mem.indexOf(u8, d, "Session-scoped only") != null);
}

test "every progressive tool carries a non-empty system_prompt" {
    for (ALL_PROGRESSIVE_TOOLS) |tool| {
        try testing.expect(tool.function.system_prompt.len > 0);
        try testing.expect(tool.function.description.len > 0);
    }
}
