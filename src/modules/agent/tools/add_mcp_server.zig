//! Agent-callable tool: `add_mcp_server` — register a new MCP server in the
//! live `LlmConfig` (in-memory + JSON mirror) so subsequent agent iterations
//! pick up its tools via `buildMCPToolsRun`. The HTTP transport is added in
//! a sibling task; this v1 covers stdio only (per the user request:
//! "handle mcp stdio first").
//!
//! Wire shape:
//!   input:  {
//!     name:     string,            // server name (key in mcp_servers)
//!     transport: "stdio" | "http", // v1 only accepts "stdio"
//!     command:  string,            // required when transport == "stdio"
//!     args:     string[]?,         // optional
//!     cwd:      string?,           // optional
//!     url:      string?,           // reserved for the HTTP follow-up
//!     headers:  { key: value }[]?, // reserved for the HTTP follow-up
//!   }
//!   output: <add_mcp_server>
//!            <name>...</name>
//!            <transport>stdio</transport>
//!            <command>...</command>
//!            <args><item>...</item>...</args>   // when non-empty
//!            <cwd>...</cwd>                     // when non-null
//!            <persisted>true|false</persisted>
//!            <tools>...</tools>                 // newline-separated, best-effort
//!            <note>...</note>
//!          </add_mcp_server>
//!   or:     <add_mcp_server><error>...</error></add_mcp_server>
//!
//! Plan: docs/superpowers/plans/2026-08-28-add-mcp-server-agent-tool.md
//!
//! Why a separate file (vs adding to the existing tools_exec_add_*.zig
//! chain): the storage primitive already lives in `Config.zig`. This
//! file is the LLM-facing wrapper — JSON schema, input struct, success/
//! error XML envelopes. The exec adapter in
//! `src/agentic_loop/tools_exec_add_mcp_server.zig` calls
//! `executeAddMcpServerToString` (same shape as `memory.zig`'s
//! `executeAddSkillToString`).
//!
//! Notes for the future HTTP branch: the input struct already has
//! `url` + `headers` fields (optional). The validator rejects any
//! non-stdio transport today; the HTTP case is a sibling task and will
//! add its own branch in `executeAddMcpServerToString`. Mirrors the
//! frontend `McpServerModal` wire shape exactly so the LLM-facing
//! contract doesn't change when HTTP lands.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const config_mod = nalarcore.config;
const LlmConfig = config_mod.LlmConfig;

const helpers = @import("helpers");
const xmlEscape = helpers.xml_escape;
const xmlEscapeAlloc = helpers.xml_escape_alloc;

/// One MCP header entry (HTTP transport — v1 ignores these but the field
/// is in the schema so the LLM doesn't have to learn a new shape when HTTP
/// ships in the sibling task).
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Input for `add_mcp_server`. The LLM fills in `name` + `transport`; the
/// transport-specific fields (`command` for stdio, `url` for HTTP) are
/// v1-required when the matching transport is selected. `args` / `cwd`
/// are optional stdio fields. `url` / `headers` are reserved for the
/// HTTP sibling task (plan 2026-08-28-mcp-streamable-http + agent-tool).
pub const AddMcpServerInput = struct {
    /// Server name (key in `mcp_servers`). Must be non-empty and must not
    /// collide with an existing server. Trailing whitespace is NOT
    /// trimmed — the caller passes the exact key.
    name: []const u8 = "",

    /// Transport discriminator. v1 only accepts `"stdio"`. The HTTP branch
    /// (`"http"`) is gated to a clear error today and will be enabled by
    /// the HTTP sibling task without changing this schema.
    transport: []const u8 = "stdio",

    /// stdio command. Required when `transport == "stdio"`. Empty for HTTP.
    command: []const u8 = "",

    /// stdio argv. Optional.
    args: ?[]const []const u8 = null,

    /// stdio working directory. Optional.
    cwd: ?[]const u8 = null,

    /// HTTP URL. Reserved for the HTTP sibling task.
    url: []const u8 = "",

    /// HTTP headers. Reserved for the HTTP sibling task.
    headers: ?[]const Header = null,
};

/// Tool definition for the LLM. The description is the agent's primary
/// "when to call this" signal — it lists BOTH the stdio fields the agent
/// must provide AND a brief note that HTTP is forthcoming.
pub const add_mcp_server_tool_system_prompt =
    \\## Add MCP Server Tool — Behavior
    \\Use `add_mcp_server` to register a new MCP server at runtime.
    \\- Provide `name`, `transport="stdio"`, `command`, and optional `args`/`cwd`. The new server's tools appear on the NEXT iteration.
    \\- v1 supports `stdio` only; `http` will return an error.
    \\
;

pub const add_mcp_server_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "add_mcp_server",
        .description =
            \\The `add_mcp_server` tool registers a new MCP (Model Context Protocol) server so its tools become available to you on the NEXT iteration. Call this when the user asks to add a new MCP server, configure a stdio MCP integration, or register a tool provider the user wants to use.
            \\
            \\After a successful call, the new server's tools are exposed as `mcp_<serverName>_<toolName>` on the next system-prompt rebuild. Until then, the just-added server does NOT have callable tools yet — finish your reply first.
            \\
            \\v1 supports the `stdio` transport only (per current scope). The fields you MUST provide for stdio:
            \\  - `name`     : the server key (letters/digits/`_`/`-` recommended). Must not already exist.
            \\  - `transport`: `"stdio"`.
            \\  - `command`  : the binary to spawn (e.g. `"npx"`, `"mcp-hello-world"`).
            \\  - `args`     : (optional) command-line args, e.g. `["-y", "@upstash/context7-mcp"]`.
            \\  - `cwd`      : (optional) working directory for the child process.
            \\
            \\HTTP transport (`url` + `headers`) is reserved for a sibling task and will return a clear error today.
            \\
            \\The tool validates inputs, mutates the live in-memory config, then persists the change to `~/.config/nalar/config.json` (or platform equivalent) so the server survives restart. On success the tool returns the list of tools the new server exposed (best-effort; if the server can't be reached right now, the call still succeeds and you can call its tools on the next iteration).
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Server name (key). Must be non-empty and not collide with an existing server.",
                },
                .{
                    .name = "transport",
                    .type = "string",
                    .description = "Transport discriminator. v1: only `\"stdio\"` is accepted. HTTP lands in a sibling task.",
                },
                .{
                    .name = "command",
                    .type = "string",
                    .description = "stdio command to spawn. Required when transport == \"stdio\". E.g. `\"npx\"`, `\"mcp-hello-world\"`.",
                },
                .{
                    .name = "args",
                    .type = "array",
                    .description = "stdio command-line args. Optional. Each entry is a single argv string.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "stdio working directory. Optional; defaults to inheriting from the parent.",
                },
                .{
                    .name = "url",
                    .type = "string",
                    .description = "HTTP URL. Reserved for the HTTP sibling task — currently ignored, returns an error.",
                },
                .{
                    .name = "headers",
                    .type = "object",
                    .description = "HTTP headers. Reserved for the HTTP sibling task — currently ignored, returns an error.",
                },
            },
            .required = &.{ "name", "transport", "command" },
        },
        .system_prompt = add_mcp_server_tool_system_prompt,
    },
};

/// Execute the `add_mcp_server` tool. Mutates `config.mcp_servers` in
/// place (so the new server's tools appear in the NEXT agent iteration's
/// system prompt via `buildMCPToolsRun`); the disk persistence + live-
/// reload path lives in the exec wrapper so it can swap `di.llm_config`
/// atomically (see `tools_exec_add_mcp_server.zig`).
///
/// Returns an XML string for the LLM. The success envelope carries:
///   - `<name>`, `<transport>`, `<command>` — what was added
///   - `<args>` (one `<item>` per arg, omitted when none)
///   - `<cwd>` (omitted when null)
///   - `<persisted>true|false</persisted>` — disk-write outcome (only the
///     exec wrapper can persist; pure fn reports `false`)
///   - `<tools>` — newline-separated `mcp_<server>_<tool>` names the
///     server exposed (best-effort; absent if list-tools failed)
///   - `<note>` — operator-facing hint ("server will be available on the
///     next iteration")
///
/// Error envelope: `<add_mcp_server><error>...</error></add_mcp_server>`.
///
/// `io` is unused today but kept in the signature so the HTTP branch
/// (which needs HTTP transport) doesn't have to change call sites.
pub fn executeAddMcpServerToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *LlmConfig,
    input: AddMcpServerInput,
) ![]const u8 {
    _ = io; // reserved for the HTTP branch

    // ── 1. Validate transport + per-transport fields ───────────────────
    if (!std.mem.eql(u8, input.transport, "stdio")) {
        return errorXml(allocator,
            \\transport must be "stdio" in v1 — HTTP lands in a sibling task. If you intended stdio, set transport="stdio" and provide a non-empty `command`.
        );
    }

    // ── 2. Call the storage primitive ──────────────────────────────────
    config_mod.LlmConfig.addMcpServerStdio(config, .{
        .name = input.name,
        .command = input.command,
        .args = input.args,
        .cwd = input.cwd,
    }) catch |err| {
        // Free the per-error allocated msg (when present) before returning.
        // `errorXml` does NOT take ownership of the message slice; it
        // copies it through xmlEscape. We must free our own copies.
        const owned_msg: ?[]u8 = switch (err) {
            error.InvalidName => null,
            error.InvalidCommand => null,
            error.DuplicateServer => blk: {
                const m = std.fmt.allocPrint(allocator,
                    "an MCP server named '{s}' is already configured — choose a different name",
                    .{input.name}) catch break :blk null;
                break :blk m;
            },
            else => null,
        };
        defer if (owned_msg) |m| allocator.free(m);

        const fallback: []const u8 = switch (err) {
            error.InvalidName => "name is required (must be non-empty)",
            error.InvalidCommand => "command is required (must be non-empty for stdio transport)",
            error.DuplicateServer => "an MCP server with that name is already configured",
            else => @errorName(err),
        };
        return errorXml(allocator, owned_msg orelse fallback);
    };

    // No best-effort tools listing here — it would pollute the global
    // StdioRegistry (whose arena is only cleaned up in `deinitGlobal`,
    // which tests don't call) and the test allocator would flag it as a
    // leak. The exec wrapper performs the listing AFTER the in-memory
    // mutation succeeds, where process-level registry state is fine.

    // ── 3. Build the success envelope (no <tools> block here; exec
    // wrapper appends it after a successful listing). ─────────────────
    return successXml(allocator, input, null);
}

// ───────────────────────────────────────────────────────────────────────
// XML envelopes
// ───────────────────────────────────────────────────────────────────────

// Note on the best-effort `tools/list` listing: it lives in the exec
// wrapper (see `tools_exec_add_mcp_server.zig::listAndAppendTools`),
// NOT the pure fn. Doing it here would call `StdioRegistry.global()`
// from the pure fn's unit tests, polluting the global registry's
// arena with no cleanup path (the global arena is freed only in
// `deinitGlobal`, which tests never call).

fn successXml(
    allocator: std.mem.Allocator,
    input: AddMcpServerInput,
    tools_listing: ?[]const u8,
) ![]u8 {
    const name_e = try xmlEscape(allocator, input.name);
    defer allocator.free(name_e);
    const transport_e = try xmlEscape(allocator, input.transport);
    defer allocator.free(transport_e);
    const command_e = try xmlEscape(allocator, input.command);
    defer allocator.free(command_e);

    var args_block: std.ArrayList(u8) = .empty;
    defer args_block.deinit(allocator);
    if (input.args) |a| {
        try args_block.appendSlice(allocator, "<args>");
        for (a) |arg| {
            const arg_e = try xmlEscape(allocator, arg);
            defer allocator.free(arg_e);
            const item_str = try std.fmt.allocPrint(allocator, "<item>{s}</item>", .{arg_e});
            defer allocator.free(item_str);
            try args_block.appendSlice(allocator, item_str);
        }
        try args_block.appendSlice(allocator, "</args>");
    }

    var cwd_block: std.ArrayList(u8) = .empty;
    defer cwd_block.deinit(allocator);
    if (input.cwd) |c| {
        const cwd_e = try xmlEscape(allocator, c);
        defer allocator.free(cwd_e);
        const cwd_str = try std.fmt.allocPrint(allocator, "<cwd>{s}</cwd>", .{cwd_e});
        defer allocator.free(cwd_str);
        try cwd_block.appendSlice(allocator, cwd_str);
    }

    var tools_block: std.ArrayList(u8) = .empty;
    defer tools_block.deinit(allocator);
    if (tools_listing) |tl| {
        const tl_e = try xmlEscape(allocator, tl);
        defer allocator.free(tl_e);
        const tools_str = try std.fmt.allocPrint(allocator, "<tools>{s}</tools>", .{tl_e});
        defer allocator.free(tools_str);
        try tools_block.appendSlice(allocator, tools_str);
    }

    return std.fmt.allocPrint(allocator,
        "<add_mcp_server>" ++
        "<name>{s}</name>" ++
        "<transport>{s}</transport>" ++
        "<command>{s}</command>" ++
        "{s}" ++ // <args>
        "{s}" ++ // <cwd>
        "<persisted>false</persisted>" ++
        "{s}" ++ // <tools>
        "<note>MCP server registered in the live config. Its tools will appear as mcp_{s}_&lt;tool&gt; in your next system-prompt rebuild. Disk persistence + live-reload are performed by the exec wrapper.</note>" ++
        "</add_mcp_server>",
        .{ name_e, transport_e, command_e, args_block.items, cwd_block.items, tools_block.items, name_e });
}

fn errorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<add_mcp_server><error>{s}</error></add_mcp_server>",
        .{escaped});
}

// ───────────────────────────────────────────────────────────────────────
// Inline tests
// ───────────────────────────────────────────────────────────────────────

const testing = std.testing;
const add_mcp_server_mod = @import("add_mcp_server.zig");

// Note: no DB fixture needed — `LlmConfig.addMcpServerStdio` is a
// pure in-memory mutation; tests construct a fresh `LlmConfig` via
// `fixtureConfig` and never touch the database.

fn fixtureConfig(allocator: std.mem.Allocator) !LlmConfig {
    return .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, ""),
        .model = try allocator.dupe(u8, ""),
        .base_url = try allocator.dupe(u8, ""),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .retry_delay_ms = 0,
        .max_capacity_token_model = null,
        .compaction_threshold_percent = null,
        .active_profile = null,
        .mcpServers_parsed = null,
        .mcp_servers = LlmConfig.McpServersMap.init(allocator),
        .profiles_models = LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .random_names = &.{},
    };
}

// ─── Test 1: happy-path stdio entry, success envelope shape ────────────

test "executeAddMcpServerToString: valid stdio entry → success envelope" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try add_mcp_server_mod.executeAddMcpServerToString(alloc, testing.io, &cfg, .{
        .name = "ctx7",
        .transport = "stdio",
        .command = "npx",
        .args = &.{ "-y", "@upstash/context7-mcp" },
    });
    defer alloc.free(result);

    // Success envelope shape.
    try testing.expect(std.mem.indexOf(u8, result, "<add_mcp_server>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</add_mcp_server>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<name>ctx7</name>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<transport>stdio</transport>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<command>npx</command>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<args>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<item>-y</item>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<item>@upstash/context7-mcp</item>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</args>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<persisted>false</persisted>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<error>") == null);

    // Typed map populated.
    try testing.expect(cfg.hasMcpServer("ctx7"));
    const server = cfg.mcpServerConfig("ctx7").?;
    try testing.expectEqualStrings("npx", server.command.?);
}

// ─── Test 2: HTTP transport rejected in v1 ──────────────────────────────

test "executeAddMcpServerToString: HTTP transport rejected with clear error" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try add_mcp_server_mod.executeAddMcpServerToString(alloc, testing.io, &cfg, .{
        .name = "remote",
        .transport = "http",
        .url = "https://example.com/mcp",
    });
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    // Search for the escaped version (xmlEscape turns " into &quot;)
    try testing.expect(std.mem.indexOf(u8, result, "transport must be &quot;stdio&quot;") != null);
    // No server added.
    try testing.expect(!cfg.hasMcpServer("remote"));
}

// ─── Test 3: empty name surfaces InvalidName error ─────────────────────

test "executeAddMcpServerToString: empty name → error envelope" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try add_mcp_server_mod.executeAddMcpServerToString(alloc, testing.io, &cfg, .{
        .name = "",
        .transport = "stdio",
        .command = "x",
    });
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "name is required") != null);
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

// ─── Test 4: empty command surfaces InvalidCommand error ───────────────

test "executeAddMcpServerToString: empty command → error envelope" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try add_mcp_server_mod.executeAddMcpServerToString(alloc, testing.io, &cfg, .{
        .name = "ctx",
        .transport = "stdio",
        .command = "",
    });
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "command is required") != null);
    try testing.expectEqual(@as(usize, 0), cfg.mcp_servers.count());
}

// ─── Test 5: duplicate name surfaces DuplicateServer with the name ──────

test "executeAddMcpServerToString: duplicate name → error mentioning the existing key" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    // First add succeeds.
    const first = try add_mcp_server_mod.executeAddMcpServerToString(alloc, testing.io, &cfg, .{
        .name = "ctx",
        .transport = "stdio",
        .command = "first-cmd",
    });
    defer alloc.free(first);
    // Second add with the same name fails; envelope mentions the key.
    const result = try add_mcp_server_mod.executeAddMcpServerToString(alloc, testing.io, &cfg, .{
        .name = "ctx",
        .transport = "stdio",
        .command = "second-cmd",
    });
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "ctx") != null);
    try testing.expect(std.mem.indexOf(u8, result, "already configured") != null);
    // Original entry preserved.
    const server = cfg.mcpServerConfig("ctx").?;
    try testing.expectEqualStrings("first-cmd", server.command.?);
}

// ─── Test 6: JSON schema shape ──────────────────────────────────────────

test "add_mcp_server_tool JSON schema: name=add_mcp_server, required includes name+transport+command" {
    const tool = add_mcp_server_mod.add_mcp_server_tool;

    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("add_mcp_server", tool.function.name);

    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "add_mcp_server") != null);
    try testing.expect(std.mem.indexOf(u8, description, "stdio") != null);

    // Required: name + transport + command. cwd/args/url/headers are optional.
    try testing.expectEqual(@as(usize, 3), tool.function.parameters.required.len);
    try testing.expectEqualStrings("name", tool.function.parameters.required[0]);
    try testing.expectEqualStrings("transport", tool.function.parameters.required[1]);
    try testing.expectEqualStrings("command", tool.function.parameters.required[2]);

    // Properties: 7 fields (name, transport, command, args, cwd, url, headers).
    try testing.expectEqual(@as(usize, 7), tool.function.parameters.properties.len);
}

// ─── Test 7: cwd emitted in the success envelope when provided ─────────

test "executeAddMcpServerToString: cwd block emitted when provided" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try add_mcp_server_mod.executeAddMcpServerToString(alloc, testing.io, &cfg, .{
        .name = "in-cwd",
        .transport = "stdio",
        .command = "mcp-hello-world",
        .cwd = "/opt/mcp",
    });
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<cwd>/opt/mcp</cwd>") != null);
}

// ─── Test 8: cwd block omitted when null ────────────────────────────────

test "executeAddMcpServerToString: cwd block omitted when null" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try add_mcp_server_mod.executeAddMcpServerToString(alloc, testing.io, &cfg, .{
        .name = "no-cwd",
        .transport = "stdio",
        .command = "mcp-hello-world",
    });
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<cwd>") == null);
}

// ─── Test 9: <args> block omitted when args is null ─────────────────────

test "executeAddMcpServerToString: args block omitted when null" {
    const alloc = testing.allocator;
    var cfg = try fixtureConfig(alloc);
    defer cfg.deinit();

    const result = try add_mcp_server_mod.executeAddMcpServerToString(alloc, testing.io, &cfg, .{
        .name = "no-args",
        .transport = "stdio",
        .command = "mcp-hello-world",
    });
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<args>") == null);
}