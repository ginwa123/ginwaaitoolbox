const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const search_tool_mod = nalarcore.search_tool;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const args = tc.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    const parsed = std.json.parseFromSlice(
        search_tool_mod.SearchInput,
        ctx.allocator,
        args_to_parse,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "search failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    var search_result = search_tool_mod.executeSearch(ctx.allocator, ctx.io, ctx.cwd, parsed.value) catch |err| {
        // Map the new domain errors to LLM-friendly messages. Each one
        // names the fix the LLM can try (different pattern, narrower
        // path, smaller max_output, etc).
        const err_msg: []const u8 = blk: {
            switch (err) {
                error.StreamTooLong => break :blk "Search output exceeded max_output limit. Use a larger max_output value (e.g. 5242880 for 5MB), narrow your search path, or use a more specific pattern.",
                error.EmptyPattern => break :blk "search pattern was empty — pass a non-empty pattern (this is a caller bug, not 'no match')",
                error.PatternContainsNulByte => break :blk "search pattern contained a NUL (0x00) byte — patterns must be valid UTF-8 with no embedded NULs",
                error.InvalidMaxOutput => break :blk "max_output must be > 0 (use 1048576 for the 1MB default)",
                error.MaxOutputTooLarge => break :blk "max_output exceeded the 100MB hard ceiling — narrow your search path or use a more specific pattern to reduce output",
                error.InvalidMaxResults => break :blk "max_results must be > 0 (use the default of 50 if you don't need a specific cap)",
                error.InvalidHeadTail => break :blk "head/tail must be > 0 — omit the flag (or use max_results) instead of passing 0, which would look like a no-match",
                error.GlobContainsNulByte => break :blk "the glob filter contained a NUL (0x00) byte — globs must be valid UTF-8 with no embedded NULs",
                error.RegexParseError => break :blk "search pattern is not a valid regex — check for unmatched parentheses, unescaped metacharacters, or an invalid character class",
                error.PathError => break :blk "could not access search path — verify the path exists, is readable, and that cwd is set correctly",
                error.Timeout => break :blk "search timed out (30s default) — narrow your search path, use a more specific pattern, or pass a larger timeout_ms",
                error.RgNotFound => break :blk "ripgrep (rg) is not installed or not on PATH — install it first, then retry the search",
                else => {},
            }
            // Fall-through for unrecognised errors: build the allocPrint
            // result and break with that (allocated memory leaks here
            // because the catch returns; we accept the leak for unknown
            // errors which are rare).
            const msg = std.fmt.allocPrint(ctx.allocator, "search failed: {s}", .{@errorName(err)}) catch "search failed with an unknown error";
            break :blk msg;
        };
        const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    if (search_result.matches.items.len == 0) {
        // No matches — route through the formatter so the <search
        // pattern="..." path="..."> wrapper is emitted alongside the
        // <warning>no matches for pattern "X" in path "Y"</warning>
        // body. The frontend's parser relies on the wrapper to render
        // the actual pattern + path in the toast header (without it,
        // the operator sees "unknown" / "unknown" everywhere — the
        // bug this branch previously masked). See
        // docs/superpowers/plans/2026-08-06-search-better-error.md.
    }

    // Honor group_by_file flag — was previously dead code (always called
    // the grouped variant). Use the flat variant when the caller asked
    // for ungrouped output. Both branches handle the empty-matches case
    // by emitting `<search pattern="X" path="Y"><warning>...</warning></search>`
    // so the frontend always has the wrapper attributes to extract.
    const inner = if (parsed.value.group_by_file)
        try search_tool_mod.search_result_to_string_grouped(
            ctx.allocator,
            search_result,
            parsed.value.pattern,
            parsed.value.path,
        )
    else
        try search_tool_mod.search_result_to_string_flat(
            ctx.allocator,
            search_result,
            parsed.value.pattern,
            parsed.value.path,
        );
    search_result.deinit(ctx.allocator);
    const output = try wrapToolOutput(ctx.allocator, "search", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}