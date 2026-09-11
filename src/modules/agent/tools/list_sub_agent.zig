//! Agent-callable tool: `list_sub_agent` — list the subagents configured
//! on the agent's current profile, with full specs.
//!
//! Wire shape:
//!   input:  {} (no params — profile_name is implicit from
//!           `ToolExecContext.selected_profile_model` in the exec adapter)
//!   output: <list_sub_agent><profile>NAME</profile><count>N</count>
//!           <sub_agents><sub_agent>...</sub_agent>...</sub_agents></list_sub_agent>
//!   or:     <list_sub_agent><profile>NAME</profile><empty/></list_sub_agent>
//!           (empty profile_name, unknown profile, or zero rows after
//!           skipping empty sa.name entries)
//!
//! Per-row shape:
//!   <sub_agent><name>..</name><model>..</model><url_style>..</url_style>
//!   <thinking>..</thinking><temperature>..</temperature>
//!   [<max_capacity_tokens>..</max_capacity_tokens>]
//!   [<compaction_threshold_percent>..</compaction_threshold_percent>]
//!   [<thinking_budget_tokens>..</thinking_budget_tokens>]
//!   [<reasoning_effort>..</reasoning_effort>]
//!   <system_prompt><![CDATA[FULL text]]></system_prompt></sub_agent>
//!
//! Rules (per plan):
//!   - String fields (name/model/url_style/thinking/temperature) are
//!     emitted verbatim even when empty.
//!   - Numeric/optional tags are emitted ONLY when non-null (absent tag
//!     means 'inherits the profile default').
//!   - system_prompt is the FULL text in CDATA (never truncated), with
//!     the `]]>` -> `]]><![CDATA[>` split (same pattern as
//!     `get_plan.zig` / `enrichCompactionXml`).
//!   - NEVER emit api_key/base_url tags or values (secrets stay off
//!     the wire).
//!   - Top-level `config.sub_agents` is DEPRECATED — never read it.
//!     Only the profile's own `sub_agents` list is listed.
//!
//! Design choices (mirror `get_plan.zig`):
//!   - `profile_name` is passed explicitly (NOT via `ToolExecContext`)
//!     so this pure fn is testable in isolation. The exec adapter
//!     pulls `ctx.selected_profile_model` and forwards it here.
//!   - The `<profile>` echo is verbatim (even when empty/unknown) so
//!     the LLM can correlate the result with the profile it asked about.

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const config_mod = nalarcore.config;

/// Input for `list_sub_agent`. Empty struct — no params, profile_name is implicit.
pub const ListSubAgentInput = struct {};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to call this tool — it explicitly
/// names `spawn_sub_agent` / `agent_name` as the follow-up so the
/// agent knows to call this first when unsure which sub-agent fits.
pub const list_sub_agent_tool_system_prompt =
    \\## List Sub Agent Tool — Behavior
    \\Use `list_sub_agent` to list the subagents configured on your current profile.
    \\- No parameters. Returns full specs (model, tuning, system prompt) for each sub-agent.
    \\- Call this before `spawn_sub_agent` when you are unsure which `agent_name` values exist or which one fits the job.
    \\- Absent optional tags mean 'inherits the profile default'. Read-only, no side effects.
    \\
;

pub const list_sub_agent_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_sub_agent",
        .description =
            \\List the subagents configured on your current profile with their full specs (model, tuning, system prompt). Call this before spawn_sub_agent when you are unsure which agent_name values exist or which one fits the job. Absent optional tags mean 'inherits the profile default'. Read-only, no side effects.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
        .system_prompt = list_sub_agent_tool_system_prompt,
    },
};

/// Append `s` inside a CDATA section, splitting on the literal `]]>`
/// sequence (which would otherwise terminate the CDATA section early
/// and break the XML envelope). Mirrors the `get_plan.zig` slow path
/// / `enrichCompactionXml` session_skills pattern: close the current
/// section with the `]]` (already in the data), reopen with
/// `<![CDATA[`, and emit the literal `>` as content of the new
/// section. On the wire this reads as `...]]><![CDATA[>...`.
fn appendCdataSplit(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    if (std.mem.indexOf(u8, s, "]]>") == null) {
        try out.appendSlice(allocator, s);
        return;
    }
    var rest = s;
    while (std.mem.indexOf(u8, rest, "]]>")) |idx| {
        try out.appendSlice(allocator, rest[0..idx]);
        try out.appendSlice(allocator, "]]><![CDATA[>");
        rest = rest[idx + 3 ..];
    }
    try out.appendSlice(allocator, rest);
}

/// Execute list_sub_agent. Returns an XML string for the LLM.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
///
/// `profile_name` is passed explicitly (NOT via `ToolExecContext`) so
/// this pure fn is testable in isolation. The exec adapter pulls
/// `ctx.selected_profile_model` and forwards it here.
///
/// Empty `profile_name`, a `getProfile` miss, or zero rows (after
/// skipping empty `sa.name` entries) all yield the `<empty/>` shape
/// with `<profile>` echoed verbatim.
pub fn executeListSubAgent(
    allocator: std.mem.Allocator,
    config: *const config_mod.LlmConfig,
    profile_name: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "<list_sub_agent><profile>");
    try out.appendSlice(allocator, profile_name);
    try out.appendSlice(allocator, "</profile>");

    const profile = if (profile_name.len == 0) null else config.getProfile(profile_name);
    if (profile == null) {
        try out.appendSlice(allocator, "<empty/></list_sub_agent>");
        return out.toOwnedSlice(allocator);
    }

    // Count non-empty names first so <count> is exact.
    var count: usize = 0;
    for (profile.?.sub_agents) |sa| {
        if (sa.name.len == 0) continue;
        count += 1;
    }
    if (count == 0) {
        try out.appendSlice(allocator, "<empty/></list_sub_agent>");
        return out.toOwnedSlice(allocator);
    }

    try out.appendSlice(allocator, "<count>");
    {
        const n_str = try std.fmt.allocPrint(allocator, "{d}", .{count});
        defer allocator.free(n_str);
        try out.appendSlice(allocator, n_str);
    }
    try out.appendSlice(allocator, "</count><sub_agents>");

    for (profile.?.sub_agents) |sa| {
        if (sa.name.len == 0) continue;
        try out.appendSlice(allocator, "<sub_agent><name>");
        try out.appendSlice(allocator, sa.name);
        try out.appendSlice(allocator, "</name><model>");
        try out.appendSlice(allocator, sa.model);
        try out.appendSlice(allocator, "</model><url_style>");
        try out.appendSlice(allocator, sa.url_style);
        try out.appendSlice(allocator, "</url_style><thinking>");
        try out.appendSlice(allocator, sa.thinking);
        try out.appendSlice(allocator, "</thinking><temperature>");
        try out.appendSlice(allocator, sa.temperature);
        try out.appendSlice(allocator, "</temperature>");
        if (sa.max_capacity_tokens) |v| {
            try out.appendSlice(allocator, "<max_capacity_tokens>");
            {
                const n_str = try std.fmt.allocPrint(allocator, "{d}", .{v});
                defer allocator.free(n_str);
                try out.appendSlice(allocator, n_str);
            }
            try out.appendSlice(allocator, "</max_capacity_tokens>");
        }
        if (sa.compaction_threshold_percent) |v| {
            try out.appendSlice(allocator, "<compaction_threshold_percent>");
            {
                const n_str = try std.fmt.allocPrint(allocator, "{d}", .{v});
                defer allocator.free(n_str);
                try out.appendSlice(allocator, n_str);
            }
            try out.appendSlice(allocator, "</compaction_threshold_percent>");
        }
        if (sa.thinking_budget_tokens) |v| {
            try out.appendSlice(allocator, "<thinking_budget_tokens>");
            {
                const n_str = try std.fmt.allocPrint(allocator, "{d}", .{v});
                defer allocator.free(n_str);
                try out.appendSlice(allocator, n_str);
            }
            try out.appendSlice(allocator, "</thinking_budget_tokens>");
        }
        if (sa.reasoning_effort) |v| {
            try out.appendSlice(allocator, "<reasoning_effort>");
            try out.appendSlice(allocator, v);
            try out.appendSlice(allocator, "</reasoning_effort>");
        }
        try out.appendSlice(allocator, "<system_prompt><![CDATA[");
        try appendCdataSplit(&out, allocator, sa.system_prompt);
        try out.appendSlice(allocator, "]]></system_prompt></sub_agent>");
    }

    try out.appendSlice(allocator, "</sub_agents></list_sub_agent>");
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

fn testConfig(allocator: std.mem.Allocator) !config_mod.LlmConfig {
    var cfg: config_mod.LlmConfig = .{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "top-key"),
        .model = try allocator.dupe(u8, "top-model"),
        .base_url = try allocator.dupe(u8, "https://top"),
        .url_style = try allocator.dupe(u8, "openai"),
        .model_compaction_size_kb = 100,
        .retry_delay_ms = 0,
        .max_capacity_token_model = null,
        .compaction_threshold_percent = null,
        .active_profile = null,
        .mcpServers_parsed = null,
        .mcp_servers = config_mod.LlmConfig.McpServersMap.init(allocator),
        .profiles_models = config_mod.LlmConfig.ProfilesMap.init(allocator),
        .sub_agents = &.{},
        .random_names = &.{},
    };
    errdefer cfg.deinit();
    var agents = std.ArrayList(config_mod.LlmConfig.SubAgentConfig).empty;
    errdefer agents.deinit(allocator);
    try agents.append(allocator, .{
        .name = try allocator.dupe(u8, "coder"),
        .model = try allocator.dupe(u8, "gpt-4o"),
        .base_url = try allocator.dupe(u8, "https://secret.example"),
        .thinking = try allocator.dupe(u8, "on"),
        .temperature = try allocator.dupe(u8, "0.2"),
        .url_style = try allocator.dupe(u8, "openai"),
        .api_key = try allocator.dupe(u8, "sk-secret"),
        .system_prompt = try allocator.dupe(u8, "You are a strict code reviewer with deep expertise in systems programming, testing, refactoring, and mentoring junior engineers across many languages."),
        .max_capacity_tokens = 128000,
        .compaction_threshold_percent = 80,
        .thinking_budget_tokens = null,
        .reasoning_effort = try allocator.dupe(u8, "high"),
    });
    try agents.append(allocator, .{
        .name = try allocator.dupe(u8, "helper"),
        .model = try allocator.dupe(u8, ""),
        .base_url = try allocator.dupe(u8, ""),
        .thinking = try allocator.dupe(u8, ""),
        .temperature = try allocator.dupe(u8, ""),
        .url_style = try allocator.dupe(u8, ""),
        .api_key = try allocator.dupe(u8, ""),
        .system_prompt = try allocator.dupe(u8, "helpful"),
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    });
    // Empty-name row must be skipped (never counted, never rendered).
    try agents.append(allocator, .{
        .name = try allocator.dupe(u8, ""),
        .model = try allocator.dupe(u8, "ghost"),
        .base_url = try allocator.dupe(u8, ""),
        .thinking = try allocator.dupe(u8, ""),
        .temperature = try allocator.dupe(u8, ""),
        .url_style = try allocator.dupe(u8, ""),
        .api_key = try allocator.dupe(u8, ""),
        .system_prompt = try allocator.dupe(u8, "ghost"),
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    });
    const owned = try agents.toOwnedSlice(allocator);
    try cfg.profiles_models.put(try allocator.dupe(u8, "dev"), .{
        .model = try allocator.dupe(u8, "dev-model"),
        .base_url = try allocator.dupe(u8, "https://dev"),
        .thinking = try allocator.dupe(u8, "auto"),
        .temperature = try allocator.dupe(u8, "auto"),
        .api_key = try allocator.dupe(u8, "dev-key"),
        .url_style = try allocator.dupe(u8, "openai"),
        .sub_agents = owned,
        .max_capacity_tokens = null,
        .compaction_threshold_percent = null,
        .thinking_budget_tokens = null,
        .reasoning_effort = null,
    });
    return cfg;
}

// ─── Test 1: populated 2-row — full prompt, no truncation, verbatim tuning ──

test "executeListSubAgent: populated profile returns 2 rows with full prompt verbatim" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "dev");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<list_sub_agent>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "</list_sub_agent>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<profile>dev</profile>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<count>2</count>") != null);
    // >80-char prompt must survive in FULL (no truncation).
    try testing.expect(std.mem.indexOf(u8, out, "mentoring junior engineers across many languages.") != null);
    // Tuning verbatim.
    try testing.expect(std.mem.indexOf(u8, out, "<model>gpt-4o</model>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<thinking>on</thinking>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<temperature>0.2</temperature>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<max_capacity_tokens>128000</max_capacity_tokens>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<compaction_threshold_percent>80</compaction_threshold_percent>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<reasoning_effort>high</reasoning_effort>") != null);
    // No <empty/> on the populated branch.
    try testing.expect(std.mem.indexOf(u8, out, "<empty/>") == null);
}

// ─── Test 2: null-omission — absent optional tags on the sparse row ──────────

test "executeListSubAgent: null optionals omitted, empty strings emitted verbatim" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "dev");
    defer alloc.free(out);

    // Sparse row renders with empty-string tags verbatim.
    try testing.expect(std.mem.indexOf(u8, out, "<name>helper</name>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<model></model>") != null);
    // Optional tags appear exactly ONCE each (only the populated row).
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "<max_capacity_tokens>"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "<compaction_threshold_percent>"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "<reasoning_effort>"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "<thinking_budget_tokens>"));
}

// ─── Test 3: empty-name skip ─────────────────────────────────────────────────

test "executeListSubAgent: empty sa.name rows are skipped" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "dev");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "ghost") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<count>2</count>") != null);
}

// ─── Test 4: unknown profile → <empty/> with verbatim echo ───────────────────

test "executeListSubAgent: unknown profile returns <empty/> with verbatim echo" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "nope");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<profile>nope</profile>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<empty/>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<count>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<sub_agents>") == null);
}

// ─── Test 5: empty profile name → <empty/> ───────────────────────────────────

test "executeListSubAgent: empty profile name returns <empty/>" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<profile></profile>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<empty/>") != null);
}

// ─── Test 6: secrets absence ─────────────────────────────────────────────────

test "executeListSubAgent: never emits api_key/base_url tags or values" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    const out = try executeListSubAgent(alloc, &cfg, "dev");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "sk-secret") == null);
    try testing.expect(std.mem.indexOf(u8, out, "secret.example") == null);
    try testing.expect(std.mem.indexOf(u8, out, "api_key") == null);
    try testing.expect(std.mem.indexOf(u8, out, "base_url") == null);
    try testing.expect(std.mem.indexOf(u8, out, "dev-key") == null);
}

// ─── Test 7: CDATA split on `]]>` inside system_prompt ───────────────────────

test "executeListSubAgent: splits CDATA on `]]>` inside system_prompt" {
    const alloc = testing.allocator;
    var cfg = try testConfig(alloc);
    defer cfg.deinit();
    // Patch the first row's prompt to embed a `]]>` boundary.
    {
        const entry = cfg.profiles_models.getEntry("dev") orelse return error.MissingProfile;
        alloc.free(entry.value_ptr.sub_agents[0].system_prompt);
        entry.value_ptr.sub_agents[0].system_prompt = try alloc.dupe(u8, "before ]]> after");
    }
    const out = try executeListSubAgent(alloc, &cfg, "dev");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "before ]]><![CDATA[> after") != null);
}

// ─── Test 8: JSON schema shape ───────────────────────────────────────────────

test "list_sub_agent_tool JSON schema: name='list_sub_agent', no required params, no properties" {
    const tool = list_sub_agent_tool;

    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("list_sub_agent", tool.function.name);

    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "spawn_sub_agent") != null);
    try testing.expect(std.mem.indexOf(u8, description, "agent_name") != null);
    try testing.expect(std.mem.indexOf(u8, description, "Read-only, no side effects.") != null);

    try testing.expectEqual(@as(usize, 0), tool.function.parameters.required.len);
    try testing.expectEqual(@as(usize, 0), tool.function.parameters.properties.len);
}
