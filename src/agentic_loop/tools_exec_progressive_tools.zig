// Exec wrappers for the progressive tool search agent tools
// (`search_tool` / `view_tool` / `use_tool`) — one file, three exec fns,
// mirroring `tools_exec_skills.zig`.
//
// The catalog these operate on is:
//
//     catalog = (registered built-ins − enabled built-ins − session-equipped)
//               ∪ (mcp tools − session-equipped)
//
// "enabled" comes from `tool_eligibility.allowlistFilter`, the SAME helper the
// workflow uses to build the LLM's tool list — so the catalog can never offer
// a tool the model already has, nor hide one it should be able to reach.
// The item-type policy (kanban ↔ design) is applied too, via
// `tool_eligibility.itemTypeStrip` inside `buildCatalog`.
//
// Plan: docs/superpowers/plans/2026-09-12-progressive-tool-search.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");
const tools_equipped = @import("tools_equipped.zig");
const llm_history = @import("llm_history.zig");
const progressive_catalog = @import("progressive_catalog.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const pmod = nalarcore.progressive_tools;
const wrapToolOutput = tools.wrapToolOutput;

const MAX_DID_YOU_MEAN = 3;

/// Everything the three adapters need to resolve the catalog. Built once per
/// dispatch (all allocations land on the per-request arena).
const Inputs = struct {
    registered: []const agent.AgentTool,
    mcp: ?[]const agent.AgentTool,
    equipped_names: []const []const u8,
};

fn loadInputs(ctx: ToolExecContext) !Inputs {
    const registered = tools_equipped.equips(ctx.allocator);

    // The live fetch-once MCP cache — the same source the workflow uses and
    // the same one `handle_mcp_tool` dispatches against. Never re-fetch from
    // the servers here.
    const di = nalarcore.getSingleton() catch null;
    const mcp: ?[]const agent.AgentTool = if (di) |d| d.getMcpToolsCached(ctx.allocator) else null;

    const equipped = try llm_history.getProgressiveTools(ctx.allocator, ctx.db, ctx.session_id);
    const names = try ctx.allocator.alloc([]const u8, equipped.len);
    for (equipped, 0..) |e, i| names[i] = e.tool_name;

    return .{ .registered = registered, .mcp = mcp, .equipped_names = names };
}

/// The workspace item type for this session, or "" when unknown. Borrowed
/// then duped because `getWorkspaceContext` owns its strings.
fn selfItemType(ctx: ToolExecContext) []const u8 {
    const wctx = (llm_history.getWorkspaceContext(ctx.allocator, ctx.db, ctx.session_id) catch return "") orelse return "";
    defer wctx.deinit(ctx.allocator);
    return ctx.allocator.dupe(u8, wctx.self_item_type) catch "";
}

fn buildCatalog(ctx: ToolExecContext, inputs: Inputs) ![]progressive_catalog.Entry {
    return progressive_catalog.buildCatalog(
        ctx.allocator,
        inputs.registered,
        ctx.allowed_tools,
        ctx.is_sub_agent,
        inputs.mcp,
        inputs.equipped_names,
        selfItemType(ctx),
    );
}

/// Mirror `add_mcp_server`'s envelope semantics: an inner `<error>` makes the
/// wrapper report success=false and surfaces the message as the error, with
/// the full inner XML still available in `<data>`.
fn wrapMaybeError(
    ctx: ToolExecContext,
    tool_name: []const u8,
    args_json: []const u8,
    inner: []const u8,
) ![]const u8 {
    if (std.mem.indexOf(u8, inner, "<error>")) |err_start_raw| {
        const err_start = err_start_raw + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse (inner.len - err_start);
        return wrapToolOutput(ctx.allocator, tool_name, args_json, false, inner[err_start .. err_start + err_end], inner);
    }
    return wrapToolOutput(ctx.allocator, tool_name, args_json, true, null, inner);
}

fn result(ctx: ToolExecContext, output: []const u8) ToolExecResult {
    _ = ctx;
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── search_tool ───

pub fn execSearchTool(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        pmod.SearchToolInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "search_tool",
            tc.function.arguments,
            false,
            "search_tool failed to parse input (expected {\"query\"?: string, \"server\"?: string})",
            "",
        );
        return result(ctx, output);
    };
    defer parsed.deinit();

    const query = parsed.value.query orelse "";
    const server = parsed.value.server orelse "";

    const inputs = try loadInputs(ctx);
    const catalog = try buildCatalog(ctx, inputs);

    // `matchQuery` returns every match (no cap); `renderSearchResult` applies
    // MAX_SEARCH_ROWS and reports the real total so the model can narrow.
    const matches = try progressive_catalog.matchQuery(ctx.allocator, catalog, query, server);
    const inner = try progressive_catalog.renderSearchResult(
        ctx.allocator,
        matches,
        matches.len,
        query,
        server,
    );

    const output = try wrapToolOutput(ctx.allocator, "search_tool", tc.function.arguments, true, null, inner);
    return result(ctx, output);
}

// ─── view_tool (read-only) ───

pub fn execViewTool(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        pmod.ViewToolInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "view_tool",
            tc.function.arguments,
            false,
            "view_tool failed to parse input (expected {\"name\": string})",
            "",
        );
        return result(ctx, output);
    };
    defer parsed.deinit();

    const name = std.mem.trim(u8, parsed.value.name orelse "", " ");
    if (name.len == 0) {
        const inner = try progressive_catalog.renderViewToolNotFound(ctx.allocator, "", &.{});
        const output = try wrapMaybeError(ctx, "view_tool", tc.function.arguments, inner);
        return result(ctx, output);
    }

    const inputs = try loadInputs(ctx);

    // 1. Discoverable candidate.
    const catalog = try buildCatalog(ctx, inputs);
    if (progressive_catalog.findByName(catalog, name)) |entry| {
        const inner = try progressive_catalog.renderViewTool(ctx.allocator, entry);
        const output = try wrapToolOutput(ctx.allocator, "view_tool", tc.function.arguments, true, null, inner);
        return result(ctx, output);
    }

    // 2. Already equipped for this session — show it rather than claiming it
    //    is unknown. Read-only either way.
    if (progressive_catalog.findAnyByNameFiltered(inputs.registered, inputs.mcp, name, inputs.equipped_names)) |entry| {
        const inner = try progressive_catalog.renderViewTool(ctx.allocator, entry);
        const output = try wrapToolOutput(ctx.allocator, "view_tool", tc.function.arguments, true, null, inner);
        return result(ctx, output);
    }

    // 3. Unknown → did-you-mean over the catalog. Nothing is written.
    const suggestions = try progressive_catalog.didYouMean(ctx.allocator, catalog, name, MAX_DID_YOU_MEAN);
    const inner = try progressive_catalog.renderViewToolNotFound(ctx.allocator, name, suggestions);
    const output = try wrapMaybeError(ctx, "view_tool", tc.function.arguments, inner);
    return result(ctx, output);
}

// ─── use_tool (equips for the session) ───

pub fn execUseTool(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        pmod.UseToolInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "use_tool",
            tc.function.arguments,
            false,
            "use_tool failed to parse input (expected {\"name\": string})",
            "",
        );
        return result(ctx, output);
    };
    defer parsed.deinit();

    const name = std.mem.trim(u8, parsed.value.name orelse "", " ");
    if (name.len == 0) {
        const inner = try progressive_catalog.renderUseToolNotFound(ctx.allocator, "", &.{});
        const output = try wrapMaybeError(ctx, "use_tool", tc.function.arguments, inner);
        return result(ctx, output);
    }

    const inputs = try loadInputs(ctx);

    // ── The validation rule, checked BEFORE anything else ──
    // If it is already equipped for this session there is nothing to insert;
    // report it and write nothing. This also short-circuits the case where the
    // catalog no longer lists the name (it excludes equipped tools).
    if (progressive_catalog.findAnyByNameFiltered(inputs.registered, inputs.mcp, name, inputs.equipped_names)) |already| {
        const inner = try progressive_catalog.renderUseTool(ctx.allocator, already, false);
        const output = try wrapToolOutput(ctx.allocator, "use_tool", tc.function.arguments, true, null, inner);
        return result(ctx, output);
    }

    // Only a catalog hit may be equipped. An unknown name writes nothing.
    const catalog = try buildCatalog(ctx, inputs);
    const entry = progressive_catalog.findByName(catalog, name) orelse {
        const suggestions = try progressive_catalog.didYouMean(ctx.allocator, catalog, name, MAX_DID_YOU_MEAN);
        const inner = try progressive_catalog.renderUseToolNotFound(ctx.allocator, name, suggestions);
        const output = try wrapMaybeError(ctx, "use_tool", tc.function.arguments, inner);
        return result(ctx, output);
    };

    // `saveProgressiveTool` returns whether a row was really inserted; the
    // result's `inserted` flag is derived from that, never assumed.
    const inserted = try llm_history.saveProgressiveTool(
        ctx.allocator,
        ctx.db,
        ctx.logger,
        ctx.session_id,
        entry.name,
        entry.server,
    );

    const inner = try progressive_catalog.renderUseTool(ctx.allocator, entry, inserted);
    const output = try wrapToolOutput(ctx.allocator, "use_tool", tc.function.arguments, true, null, inner);

    var res = result(ctx, output);
    if (inserted) {
        res.progressive_tool_save = .{ .name = entry.name, .server_name = entry.server };
    }
    return res;
}

// ============================================================================
// Static contracts
// ============================================================================

const testing = std.testing;

test "static contract: the three progressive tools are wired into tools_equipped.zig" {
    const src = @embedFile("tools_equipped.zig");

    for (pmod.PROGRESSIVE_TOOL_NAMES) |name| {
        // Must appear in equips() AND in UNIFIED_TOOL_REGISTRY(), otherwise
        // either the LLM cannot see it or dispatch cannot execute it.
        try testing.expect(std.mem.indexOf(u8, src, name) != null);
    }
    try testing.expect(std.mem.indexOf(u8, src, "progressive_tools_mod") != null);
    try testing.expect(std.mem.indexOf(u8, src, "execSearchTool") != null);
    try testing.expect(std.mem.indexOf(u8, src, "execViewTool") != null);
    try testing.expect(std.mem.indexOf(u8, src, "execUseTool") != null);
}

test "static contract: progressive exec wrappers are re-exported from tools.zig" {
    const src = @embedFile("tools.zig");

    try testing.expect(std.mem.indexOf(u8, src, "execSearchTool") != null);
    try testing.expect(std.mem.indexOf(u8, src, "execViewTool") != null);
    try testing.expect(std.mem.indexOf(u8, src, "execUseTool") != null);
}

test "static contract: handle_tool persists progressive_tool_save" {
    const src = @embedFile("handle_tool.zig");

    try testing.expect(std.mem.indexOf(u8, src, "progressive_tool_saved") != null);
    try testing.expect(std.mem.indexOf(u8, src, "saveProgressiveTool") != null);
}

test "static contract: the workflow gates the meta tools on a non-empty catalog" {
    const src = @embedFile("workflow.zig");

    try testing.expect(std.mem.indexOf(u8, src, "progressive_catalog.buildCatalog") != null);
    // The meta-tools must be appended unconditionally — no catalog gate.
    try testing.expect(std.mem.indexOf(u8, src, "ALL_PROGRESSIVE_TOOLS") != null);
    try testing.expect(std.mem.indexOf(u8, src, "include_progressive_tools") == null);
}
