//! Progressive tool catalog.
//!
//! The agent does not receive every tool up front. This module answers the
//! question "what could this session enable that it does not already have?"
//! and is the single definition used by BOTH the search/view/use exec
//! adapters and the workflow's meta-tool gate — so the tools the agent is
//! offered can never drift from the tools the LLM actually receives.
//!
//! Catalog definition (see docs/superpowers/plans/2026-09-12-progressive-tool-search.md):
//!
//!     catalog = (registered built-ins − enabled built-ins − session-equipped)
//!               ∪ (mcp tools − session-equipped)
//!
//! where "enabled" is whatever `tool_eligibility.allowlistFilter` yields for
//! this session's `allowed_tools` plus the workspace-item-type policy. A
//! tool that is already in the LLM's tool list is deliberately NOT a search
//! result: the tools array IS the index of what is enabled.

const std = @import("std");
const nalarcore = @import("nalarcore");
const agent = nalarcore.agent;
const AgentTool = agent.AgentTool;
const tool_eligibility = @import("tool_eligibility.zig");

pub const Kind = enum { builtin, mcp };

/// Whether the entry is already enabled for this session. `no` means
/// `use_tool` would actually insert a row. A natively-enabled tool never
/// reaches the catalog, so it has no variant here.
pub const Equipped = enum { session, no };

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    /// MCP server id parsed from `mcp_<server>_<tool>` (same split as
    /// `handle_mcp_tool.zig`). Empty for built-ins.
    server: []const u8,
    equipped: Equipped,
    /// Borrowed from the registered tool definition.
    tool: AgentTool,
};

/// The server segment of an MCP tool name.
///
/// Mirrors `handle_mcp_tool.zig:35-43` exactly: everything between the
/// `mcp_` prefix and the FIRST underscore. That split is lossy when a
/// server name itself contains an underscore, but it is what dispatch
/// uses, so using anything else here would disagree with reality.
pub fn serverOf(name: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, name, "mcp_")) return "";
    const after_mcp = name["mcp_".len..];
    const idx = std.mem.indexOf(u8, after_mcp, "_") orelse return "";
    return after_mcp[0..idx];
}

pub fn isMcpName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mcp_");
}

/// One-line summary for the search index: whitespace-collapsed and
/// truncated to `max` bytes on a word boundary where possible.
pub fn summaryOf(description: []const u8, max: usize) []const u8 {
    // Collapse leading whitespace/newlines so the summary is one line.
    var start: usize = 0;
    while (start < description.len and (description[start] == ' ' or
        description[start] == '\n' or description[start] == '\r' or description[start] == '\t')) : (start += 1)
    {}
    const trimmed = description[start..];
    if (trimmed.len <= max) return trimmed;

    // Cut at the last space inside the budget so words are not split.
    var cut = max;
    while (cut > 0 and trimmed[cut] != ' ') : (cut -= 1) {}
    if (cut == 0) cut = max;
    return trimmed[0..cut];
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Build the catalog. `registered` is the full built-in registry
/// (`tools_equipped.equips()`); `mcp` is the live MCP tool cache (null =
/// none configured/fetched); `equipped_names` are this session's
/// `session_progressive_tool` rows.
pub fn buildCatalog(
    allocator: std.mem.Allocator,
    registered: []const AgentTool,
    allowed_tools: []const u8,
    is_sub_agent: bool,
    mcp: ?[]const AgentTool,
    equipped_names: []const []const u8,
    self_item_type: []const u8,
) ![]Entry {
    const enabled = try tool_eligibility.allowlistFilter(allocator, registered, allowed_tools, is_sub_agent);

    // Candidates = registered but NOT enabled, i.e. the built-ins this
    // session could add. Enabled names are already in the LLM's tool list.
    var candidates: std.ArrayList(AgentTool) = .empty;
    for (registered) |tool| {
        var is_enabled = false;
        for (enabled) |e| {
            if (std.mem.eql(u8, e.function.name, tool.function.name)) {
                is_enabled = true;
                break;
            }
        }
        if (!is_enabled) try candidates.append(allocator, tool);
    }

    // Apply the same item-type policy the prompt filtering uses, so the
    // catalog can never offer a tool the item type is not allowed to have.
    const allowed_candidates = tool_eligibility.itemTypeStrip(candidates.items, self_item_type);

    var out: std.ArrayList(Entry) = .empty;
    for (allowed_candidates) |tool| {
        const name = tool.function.name;
        // Anti-recursion invariant: a sub-agent must not be able to
        // discover its way back to spawn_sub_agent.
        if (is_sub_agent and std.mem.eql(u8, name, "spawn_sub_agent")) continue;
        if (containsName(equipped_names, name)) continue;
        try out.append(allocator, .{
            .name = name,
            .kind = .builtin,
            .server = "",
            .equipped = .no,
            .tool = tool,
        });
    }

    if (mcp) |mcp_tools| {
        for (mcp_tools) |tool| {
            const name = tool.function.name;
            if (is_sub_agent and std.mem.eql(u8, name, "spawn_sub_agent")) continue;
            if (containsName(equipped_names, name)) continue;
            try out.append(allocator, .{
                .name = name,
                .kind = .mcp,
                .server = serverOf(name),
                .equipped = .no,
                .tool = tool,
            });
        }
    }

    // Names that are already session-equipped are excluded above, but mark
    // the ones that a previous iteration recorded so the agent does not
    // re-request them unnecessarily when they appear via another route.
    for (out.items) |*entry| {
        if (containsName(equipped_names, entry.name)) entry.equipped = .session;
    }

    return try out.toOwnedSlice(allocator);
}

/// Case-insensitive substring match over name + description, plus an exact
/// `server` filter when provided.
pub fn matchQuery(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    query: []const u8,
    server: []const u8,
) ![]const Entry {
    var matched: std.ArrayList(Entry) = .empty;
    for (entries) |entry| {
        if (server.len > 0 and !std.mem.eql(u8, entry.server, server)) continue;
        if (query.len == 0) {
            try matched.append(allocator, entry);
            continue;
        }
        if (containsIgnoreCase(entry.name, query)) {
            try matched.append(allocator, entry);
            continue;
        }
        if (containsIgnoreCase(entry.tool.function.description, query)) {
            try matched.append(allocator, entry);
        }
    }
    return try matched.toOwnedSlice(allocator);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn findByName(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Cheap "did you mean" candidates for an unknown name: ASCII
/// case-insensitive, separators (`_`/`-`) folded away, then a substring
/// sweep in both directions. Enough to catch `kanban_listt` →
/// `kanban_list` and `mcp_context7_query_docs` → `mcp_context7_query-docs`.
pub fn didYouMean(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    name: []const u8,
    max: usize,
) ![]const []const u8 {
    var hits: std.ArrayList([]const u8) = .empty;

    // Pass 1: normalised equality (separators + case ignored).
    for (entries) |entry| {
        if (normalizedEqual(entry.name, name)) {
            try hits.append(allocator, entry.name);
            if (hits.items.len >= max) return try hits.toOwnedSlice(allocator);
        }
    }

    // Pass 2: one name contains a meaningful prefix of the other.
    const needle = normalize(allocator, name) catch return try hits.toOwnedSlice(allocator);
    if (needle.len >= 4) {
        for (entries) |entry| {
            if (containsName(hits.items, entry.name)) continue;
            const candidate = normalize(allocator, entry.name) catch continue;
            if (std.mem.indexOf(u8, candidate, needle) != null or
                std.mem.indexOf(u8, needle, candidate) != null)
            {
                try hits.append(allocator, entry.name);
                if (hits.items.len >= max) break;
            }
        }
    }

    return try hits.toOwnedSlice(allocator);
}

/// Lowercase with `_` and `-` removed, so `mcp_context7_query-docs` and
/// `mcp_context7_query_docs` compare equal.
fn normalize(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, name.len);
    var n: usize = 0;
    for (name) |c| {
        if (c == '_' or c == '-') continue;
        out[n] = std.ascii.toLower(c);
        n += 1;
    }
    return out[0..n];
}

fn normalizedEqual(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        while (ai < a.len and (a[ai] == '_' or a[ai] == '-')) ai += 1;
        while (bi < b.len and (b[bi] == '_' or b[bi] == '-')) bi += 1;
        if (ai >= a.len and bi >= b.len) return true;
        if (ai >= a.len or bi >= b.len) return false;
        if (std.ascii.toLower(a[ai]) != std.ascii.toLower(b[bi])) return false;
        ai += 1;
        bi += 1;
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn makeTool(allocator: std.mem.Allocator, name: []const u8, description: []const u8) !AgentTool {
    return .{
        .type = "function",
        .function = .{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .parameters = .{ .type = "object", .properties = &.{}, .required = &.{} },
        },
    };
}

fn makeToolList(allocator: std.mem.Allocator, specs: []const [2][]const u8) ![]AgentTool {
    const out = try allocator.alloc(AgentTool, specs.len);
    for (specs, 0..) |s, i| out[i] = try makeTool(allocator, s[0], s[1]);
    return out;
}

// "Nothing enabled" cannot be expressed with "" — an empty allowed_tools
// means NO FILTERING (every tool enabled), which is the pre-existing
// semantics tool_eligibility.allowlistFilter deliberately preserves. A CSV
// that matches no registered name is how a test says "nothing is enabled".
const NONE_ENABLED = "zzz_nothing_enabled";

const registered_specs = [_][2][]const u8{
    .{ "read_file", "Read a file from disk." },
    .{ "glob", "Find files by pattern." },
    .{ "kanban_list", "List a kanban board." },
    .{ "set_design_page", "Set the active design page." },
    .{ "spawn_sub_agent", "Spawn a sub-agent." },
};

test "serverOf: mirrors the dispatch split (first underscore after mcp_)" {
    try testing.expectEqualStrings("context7", serverOf("mcp_context7_query-docs"));
    try testing.expectEqualStrings("graphify", serverOf("mcp_graphify_query_graph"));
    // Lossy by design — same answer dispatch would give.
    try testing.expectEqualStrings("my", serverOf("mcp_my_server_do_thing"));
    try testing.expectEqualStrings("", serverOf("read_file"));
    try testing.expectEqualStrings("", serverOf("mcp_nounderscore"));
}

test "summaryOf: collapses leading whitespace, truncates on a word boundary" {
    try testing.expectEqualStrings("Read a file.", summaryOf("\n   Read a file.", 120));
    try testing.expectEqualStrings("Read a", summaryOf("Read a file from disk", 8));
    // Short enough → unchanged (after leading-trim).
    try testing.expectEqualStrings("abc", summaryOf("abc", 120));
}

test "buildCatalog: enabled built-ins are excluded, disabled ones included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    // Only read_file + glob are enabled for this agent.
    const catalog = try buildCatalog(a, registered, "read_file,glob", false, null, &.{}, "agent");

    try testing.expectEqual(@as(usize, 3), catalog.len);
    try testing.expectEqualStrings("kanban_list", catalog[0].name);
    try testing.expectEqualStrings("set_design_page", catalog[1].name);
    try testing.expectEqualStrings("spawn_sub_agent", catalog[2].name);
    for (catalog) |e| {
        try testing.expectEqual(Kind.builtin, e.kind);
        try testing.expectEqual(Equipped.no, e.equipped);
        try testing.expectEqualStrings("", e.server);
    }
}

test "buildCatalog: allowlist \"all\" leaves nothing but MCP discoverable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    const mcp_specs = [_][2][]const u8{.{ "mcp_ctx_query", "Query docs." }};
    const mcp = try makeToolList(a, &mcp_specs);

    const catalog = try buildCatalog(a, registered, "all", false, mcp, &.{}, "agent");
    try testing.expectEqual(@as(usize, 1), catalog.len);
    try testing.expectEqualStrings("mcp_ctx_query", catalog[0].name);
    try testing.expectEqual(Kind.mcp, catalog[0].kind);
    try testing.expectEqualStrings("ctx", catalog[0].server);
}

test "buildCatalog: session-equipped names are not offered again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    const catalog = try buildCatalog(a, registered, "read_file", false, null, &.{"glob"}, "agent");
    for (catalog) |e| {
        try testing.expect(!std.mem.eql(u8, e.name, "glob"));
    }
}

test "buildCatalog: item-type policy strips design tools for a kanban item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    // kanban item with only read_file enabled → kanban_list is discoverable,
    // set_design_page must NOT be.
    const catalog = try buildCatalog(a, registered, "read_file", false, null, &.{}, "kanban");
    var found_design = false;
    var found_kanban = false;
    for (catalog) |e| {
        if (std.mem.eql(u8, e.name, "set_design_page")) found_design = true;
        if (std.mem.eql(u8, e.name, "kanban_list")) found_kanban = true;
    }
    try testing.expect(!found_design);
    try testing.expect(found_kanban);
}

test "buildCatalog: a sub-agent never discovers spawn_sub_agent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    const catalog = try buildCatalog(a, registered, "read_file", true, null, &.{}, "agent");
    for (catalog) |e| {
        try testing.expect(!std.mem.eql(u8, e.name, "spawn_sub_agent"));
    }
}

test "buildCatalog: MCP tools are always candidates (they bypass the allowlist)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const registered = try makeToolList(a, &registered_specs);
    const mcp_specs = [_][2][]const u8{
        .{ "mcp_ctx_query-docs", "Query documentation." },
        .{ "mcp_ctx_resolve-library-id", "Resolve a library." },
    };
    const mcp = try makeToolList(a, &mcp_specs);

    // read_file enabled → the remaining 4 built-ins + 2 MCP.
    const catalog = try buildCatalog(a, registered, "read_file", false, mcp, &.{}, "agent");
    try testing.expectEqual(@as(usize, 6), catalog.len);
    try testing.expectEqualStrings("mcp_ctx_query-docs", catalog[4].name);
    try testing.expectEqual(Kind.mcp, catalog[4].kind);
    try testing.expectEqualStrings("mcp_ctx_resolve-library-id", catalog[5].name);
}

test "matchQuery: name and description substring, case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // MCP tools arrive via the `mcp` argument, never via `registered`.
    const reg_specs = [_][2][]const u8{
        .{ "kanban_list", "List a kanban board." },
        .{ "glob", "Find files by PATTERN." },
    };
    const mcp_specs = [_][2][]const u8{.{ "mcp_ctx_query-docs", "Query documentation." }};
    const reg = try makeToolList(a, &reg_specs);
    const mcp_list = try makeToolList(a, &mcp_specs);
    const entries = try buildCatalog(a, reg, NONE_ENABLED, false, mcp_list, &.{}, "agent");

    const by_name = try matchQuery(a, entries, "KANBAN", "");
    try testing.expectEqual(@as(usize, 1), by_name.len);
    try testing.expectEqualStrings("kanban_list", by_name[0].name);

    const by_desc = try matchQuery(a, entries, "pattern", "");
    try testing.expectEqual(@as(usize, 1), by_desc.len);
    try testing.expectEqualStrings("glob", by_desc[0].name);

    // Server filter.
    const by_server = try matchQuery(a, entries, "", "ctx");
    try testing.expectEqual(@as(usize, 1), by_server.len);
    try testing.expectEqualStrings("mcp_ctx_query-docs", by_server[0].name);

    const no_match = try matchQuery(a, entries, "zzzz", "");
    try testing.expectEqual(@as(usize, 0), no_match.len);
}

test "findByName + didYouMean: fuzzy recovery for a mistyped name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const specs = [_][2][]const u8{
        .{ "kanban_list", "List a kanban board." },
        .{ "mcp_ctx_query-docs", "Query documentation." },
    };
    const entries_tools = try makeToolList(a, &specs);
    const entries = try buildCatalog(a, entries_tools, NONE_ENABLED, false, null, &.{}, "agent");

    try testing.expect(findByName(entries, "kanban_list") != null);
    try testing.expect(findByName(entries, "kanban_lst") == null);

    const hits = try didYouMean(a, entries, "kanban_listt", 3);
    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("kanban_list", hits[0]);

    // Separator-folded match: the underscore variant resolves.
    const hits2 = try didYouMean(a, entries, "mcp_ctx_query_docs", 3);
    try testing.expect(hits2.len >= 1);
    try testing.expectEqualStrings("mcp_ctx_query-docs", hits2[0]);

    // Nothing close → empty, never a fabricated name.
    const none = try didYouMean(a, entries, "zzzzzzzzzz", 3);
    try testing.expectEqual(@as(usize, 0), none.len);
}

// ============================================================================
// Result renderers
//
// These produce the INNER body of each tool result; the standard
// `wrapToolOutput` envelope is applied by the exec adapter, exactly like
// every other tool.
//
// They live here rather than in `src/modules/agent/tools/progressive_tools.zig`
// because they operate on `Entry`, and a `modules → agentic_loop` import
// would close a cycle through the `nalarcore` root.
// ============================================================================

pub const MAX_SEARCH_ROWS: usize = 40;
pub const SUMMARY_MAX: usize = 120;

fn xmlEscapeInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '&' => try out.appendSlice(allocator, "&amp;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, c),
        }
    }
}

fn jsonEscapeInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try out.appendSlice(allocator, "\\u00");
                    const hex = "0123456789abcdef";
                    try out.append(allocator, hex[c >> 4]);
                    try out.append(allocator, hex[c & 0xf]);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
}

/// Append `s` inside a CDATA section, splitting on a literal `]]>` so the
/// section cannot be terminated early (same idiom as get_plan/list_sub_agent).
fn appendCdata(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    var rest = s;
    while (std.mem.indexOf(u8, rest, "]]>")) |idx| {
        try out.appendSlice(allocator, rest[0..idx]);
        try out.appendSlice(allocator, "]]><![CDATA[>");
        rest = rest[idx + 3 ..];
    }
    try out.appendSlice(allocator, rest);
}

/// The tool's parameter schema as compact JSON:
/// `{"type":"object","properties":{...},"required":[...]}`.
fn appendToolJsonSchema(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tool: AgentTool) !void {
    const params = tool.function.parameters;
    try out.appendSlice(allocator, "{\"type\":");
    try out.append(allocator, '"');
    try jsonEscapeInto(out, allocator, params.type);
    try out.appendSlice(allocator, "\",\"properties\":{");

    for (params.properties, 0..) |prop, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.append(allocator, '"');
        try jsonEscapeInto(out, allocator, prop.name);
        try out.appendSlice(allocator, "\":{\"type\":\"");
        try jsonEscapeInto(out, allocator, prop.type);
        try out.appendSlice(allocator, "\",\"description\":\"");
        try jsonEscapeInto(out, allocator, prop.description);
        try out.appendSlice(allocator, "\"}");
    }

    try out.appendSlice(allocator, "},\"required\":[");
    for (params.required, 0..) |req, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.append(allocator, '"');
        try jsonEscapeInto(out, allocator, req);
        try out.append(allocator, '"');
    }
    try out.appendSlice(allocator, "]}");
}

fn appendEntryRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, entry: Entry) !void {
    try out.appendSlice(allocator, "<tool><name>");
    try xmlEscapeInto(out, allocator, entry.name);
    try out.appendSlice(allocator, "</name><kind>");
    try out.appendSlice(allocator, switch (entry.kind) {
        .builtin => "builtin",
        .mcp => "mcp",
    });
    try out.appendSlice(allocator, "</kind><server>");
    try xmlEscapeInto(out, allocator, entry.server);
    try out.appendSlice(allocator, "</server><equipped>");
    try out.appendSlice(allocator, switch (entry.equipped) {
        .session => "session",
        .no => "no",
    });
    try out.appendSlice(allocator, "</equipped><summary>");
    try xmlEscapeInto(out, allocator, summaryOf(entry.tool.function.description, SUMMARY_MAX));
    try out.appendSlice(allocator, "</summary></tool>");
}

/// `<search_tool>` result. `total` is the pre-cap match count so the model
/// can tell how much it is not seeing.
pub fn renderSearchResult(
    allocator: std.mem.Allocator,
    matches: []const Entry,
    total: usize,
    query: []const u8,
    server: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<search_tool><query>");
    try xmlEscapeInto(&out, allocator, query);
    try out.appendSlice(allocator, "</query>");
    if (server.len > 0) {
        try out.appendSlice(allocator, "<server>");
        try xmlEscapeInto(&out, allocator, server);
        try out.appendSlice(allocator, "</server>");
    }
    {
        const n = try std.fmt.allocPrint(allocator, "<count>{d}</count><total>{d}</total><tools>", .{
            @min(matches.len, MAX_SEARCH_ROWS),
            total,
        });
        defer allocator.free(n);
        try out.appendSlice(allocator, n);
    }

    const shown = @min(matches.len, MAX_SEARCH_ROWS);
    for (matches[0..shown]) |entry| try appendEntryRow(&out, allocator, entry);
    try out.appendSlice(allocator, "</tools>");

    if (total > shown) {
        const n = try std.fmt.allocPrint(
            allocator,
            "<truncated/><hint>Showing {d} of {d} — narrow with query.</hint>",
            .{ shown, total },
        );
        defer allocator.free(n);
        try out.appendSlice(allocator, n);
    } else {
        try out.appendSlice(allocator,
            "<hint>Call view_tool for the full parameter schema, then use_tool to enable it for this session. Tools you already have in your tool list are NOT listed here.</hint>",
        );
    }

    try out.appendSlice(allocator, "</search_tool>");
    return try out.toOwnedSlice(allocator);
}

/// `<view_tool>` result for a found entry.
pub fn renderViewTool(allocator: std.mem.Allocator, entry: Entry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<view_tool><name>");
    try xmlEscapeInto(&out, allocator, entry.name);
    try out.appendSlice(allocator, "</name><kind>");
    try out.appendSlice(allocator, switch (entry.kind) {
        .builtin => "builtin",
        .mcp => "mcp",
    });
    try out.appendSlice(allocator, "</kind><server>");
    try xmlEscapeInto(&out, allocator, entry.server);
    try out.appendSlice(allocator, "</server><equipped>");
    try out.appendSlice(allocator, switch (entry.equipped) {
        .session => "session",
        .no => "no",
    });
    try out.appendSlice(allocator, "</equipped><description>");
    try xmlEscapeInto(&out, allocator, entry.tool.function.description);
    try out.appendSlice(allocator, "</description><parameters><![CDATA[");
    try appendToolJsonSchema(&out, allocator, entry.tool);
    try out.appendSlice(allocator, "]]></parameters>");

    if (entry.equipped == .session) {
        try out.appendSlice(allocator,
            "<note>Already enabled for this session — call it directly.</note>",
        );
    } else {
        try out.appendSlice(allocator,
            "<hint>Call use_tool with this name to enable it for this session.</hint>",
        );
    }
    try out.appendSlice(allocator, "</view_tool>");
    return try out.toOwnedSlice(allocator);
}

fn appendDidYouMean(out: *std.ArrayList(u8), allocator: std.mem.Allocator, suggestions: []const []const u8) !void {
    if (suggestions.len == 0) return;
    try out.appendSlice(allocator, "<did_you_mean>");
    for (suggestions) |s| {
        try out.appendSlice(allocator, "<name>");
        try xmlEscapeInto(out, allocator, s);
        try out.appendSlice(allocator, "</name>");
    }
    try out.appendSlice(allocator, "</did_you_mean>");
}

/// `<view_tool>` result for an unknown name. Never writes anything.
pub fn renderViewToolNotFound(
    allocator: std.mem.Allocator,
    name: []const u8,
    suggestions: []const []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<view_tool><name>");
    try xmlEscapeInto(&out, allocator, name);
    try out.appendSlice(allocator, "</name><found>false</found><error>unknown tool '");
    try xmlEscapeInto(&out, allocator, name);
    try out.appendSlice(allocator, "' — not in this session's tool catalog</error>");
    try appendDidYouMean(&out, allocator, suggestions);
    try out.appendSlice(allocator, "<hint>Call search_tool to list candidates.</hint></view_tool>");
    return try out.toOwnedSlice(allocator);
}

/// `<use_tool>` result. `inserted` must come from the caller's real DB
/// outcome (a `saveProgressiveTool` that returned true) — never guessed.
pub fn renderUseTool(
    allocator: std.mem.Allocator,
    entry: Entry,
    inserted: bool,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<use_tool><name>");
    try xmlEscapeInto(&out, allocator, entry.name);
    try out.appendSlice(allocator, "</name><kind>");
    try out.appendSlice(allocator, switch (entry.kind) {
        .builtin => "builtin",
        .mcp => "mcp",
    });
    try out.appendSlice(allocator, "</kind><equipped>true</equipped>");

    if (inserted) {
        try out.appendSlice(allocator, "<inserted>true</inserted><wait_next_turn>true</wait_next_turn>");
        try out.appendSlice(allocator, "<parameters><![CDATA[");
        try appendToolJsonSchema(&out, allocator, entry.tool);
        try out.appendSlice(allocator, "]]></parameters>");
        try out.appendSlice(allocator,
            "<note>Enabled for this session. Call it directly from your next turn onward — the current turn's tool list was already sent.</note>",
        );
    } else {
        try out.appendSlice(allocator, "<inserted>false</inserted><source>session</source>");
        try out.appendSlice(allocator,
            "<note>Already enabled for this session. Call it directly.</note>",
        );
    }

    try out.appendSlice(allocator, "</use_tool>");
    return try out.toOwnedSlice(allocator);
}

/// `<use_tool>` result for an unknown name. Never writes anything — this is
/// the "never fails open" guard.
pub fn renderUseToolNotFound(
    allocator: std.mem.Allocator,
    name: []const u8,
    suggestions: []const []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<use_tool><name>");
    try xmlEscapeInto(&out, allocator, name);
    try out.appendSlice(allocator, "</name><equipped>false</equipped><inserted>false</inserted><error>unknown tool '");
    try xmlEscapeInto(&out, allocator, name);
    try out.appendSlice(allocator, "' — not in this session's tool catalog</error>");
    try appendDidYouMean(&out, allocator, suggestions);
    try out.appendSlice(allocator,
        "<hint>Call search_tool, then view_tool, then use_tool with the exact name.</hint>",
    );
    try out.appendSlice(allocator, "</use_tool>");
    return try out.toOwnedSlice(allocator);
}

test "renderSearchResult: rows, chips and the not-listed hint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const reg_specs = [_][2][]const u8{.{ "kanban_list", "List a kanban board." }};
    const mcp_specs = [_][2][]const u8{.{ "mcp_ctx_query-docs", "Query documentation for a library." }};
    const reg = try makeToolList(a, &reg_specs);
    const mcp_list = try makeToolList(a, &mcp_specs);
    const entries = try buildCatalog(a, reg, NONE_ENABLED, false, mcp_list, &.{}, "agent");

    const matches = try matchQuery(a, entries, "", "");
    const out = try renderSearchResult(a, matches, matches.len, "", "");

    try testing.expect(std.mem.indexOf(u8, out, "<count>2</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<name>kanban_list</name>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<kind>builtin</kind>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<kind>mcp</kind>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<server>ctx</server>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<equipped>no</equipped>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "NOT listed here") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<truncated/>") == null);
}

test "renderSearchResult: empty match count is not an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const out = try renderSearchResult(a, &.{}, 0, "memory", "");
    try testing.expect(std.mem.indexOf(u8, out, "<count>0</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<tools></tools>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
}

test "renderSearchResult: caps rows and emits <truncated/> with the real total" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build MAX_SEARCH_ROWS + 2 entries.
    var specs: [MAX_SEARCH_ROWS + 2][2][]const u8 = undefined;
    var names: [MAX_SEARCH_ROWS + 2][]const u8 = undefined;
    for (0..MAX_SEARCH_ROWS + 2) |i| {
        names[i] = try std.fmt.allocPrint(a, "tool_{d}", .{i});
        specs[i] = .{ names[i], "desc" };
    }
    const tools_list = try makeToolList(a, &specs);
    const entries = try buildCatalog(a, tools_list, NONE_ENABLED, false, null, &.{}, "agent");
    try testing.expectEqual(MAX_SEARCH_ROWS + 2, entries.len);

    const matches = try matchQuery(a, entries, "", "");
    const out = try renderSearchResult(a, matches, matches.len, "", "");
    try testing.expect(std.mem.indexOf(u8, out, "<truncated/>") != null);
    const expect_count = try std.fmt.allocPrint(a, "<count>{d}</count>", .{MAX_SEARCH_ROWS});
    try testing.expect(std.mem.indexOf(u8, out, expect_count) != null);
    const expect_total = try std.fmt.allocPrint(a, "<total>{d}</total>", .{MAX_SEARCH_ROWS + 2});
    try testing.expect(std.mem.indexOf(u8, out, expect_total) != null);
}

test "renderViewTool: full schema in CDATA, hint to enable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tool = try makeTool(a, "kanban_list", "List a kanban board.");
    const entry = Entry{ .name = "kanban_list", .kind = .builtin, .server = "", .equipped = .no, .tool = tool };
    const out = try renderViewTool(a, entry);

    try testing.expect(std.mem.indexOf(u8, out, "<name>kanban_list</name>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<equipped>no</equipped>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<parameters><![CDATA[{") != null);
    try testing.expect(std.mem.indexOf(u8, out, "]]></parameters>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Call use_tool") != null);
}

test "renderViewToolNotFound / renderUseToolNotFound: found=false + did-you-mean, no writes implied" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const view = try renderViewToolNotFound(a, "kanban_lst", &.{"kanban_list"});
    try testing.expect(std.mem.indexOf(u8, view, "<found>false</found>") != null);
    try testing.expect(std.mem.indexOf(u8, view, "<name>kanban_list</name>") != null);
    try testing.expect(std.mem.indexOf(u8, view, "<error>") != null);

    const use = try renderUseToolNotFound(a, "kanban_lst", &.{"kanban_list"});
    try testing.expect(std.mem.indexOf(u8, use, "<equipped>false</equipped>") != null);
    try testing.expect(std.mem.indexOf(u8, use, "<inserted>false</inserted>") != null);
    try testing.expect(std.mem.indexOf(u8, use, "<did_you_mean>") != null);
}

test "renderUseTool: inserted=true carries the schema; inserted=false does not claim a wait" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tool = try makeTool(a, "glob", "Find files.");
    const entry = Entry{ .name = "glob", .kind = .builtin, .server = "", .equipped = .no, .tool = tool };

    const inserted = try renderUseTool(a, entry, true);
    try testing.expect(std.mem.indexOf(u8, inserted, "<inserted>true</inserted>") != null);
    try testing.expect(std.mem.indexOf(u8, inserted, "<wait_next_turn>true</wait_next_turn>") != null);
    try testing.expect(std.mem.indexOf(u8, inserted, "<parameters><![CDATA[") != null);

    const already = try renderUseTool(a, entry, false);
    try testing.expect(std.mem.indexOf(u8, already, "<inserted>false</inserted>") != null);
    try testing.expect(std.mem.indexOf(u8, already, "<wait_next_turn>") == null);
    try testing.expect(std.mem.indexOf(u8, already, "Already enabled") != null);
}
