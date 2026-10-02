//! `execWebSearch` — bridges the agentic loop's `ToolCall` to the search
//! tool.
//!
//! 1. Parse the LLM's `{provider, curl}` arguments.
//! 2. Resolve the providers for THIS session (never `ctx.config` — in
//!    `--auth` mode that singleton does not hold what the user saved; see
//!    `web_search_config.zig` for the full story).
//! 3. Hand off to `execute_web_search`, which owns the pin check and the
//!    `{key}` substitution.
//! 4. Re-wrap the envelope so a payload carrying `error` reaches the model
//!    as `success=false` with the full JSON still available as `data` —
//!    the same shape `tools_exec_generate_image` uses.

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");
const agent = nalarcore.agent;
const web_search_mod = nalarcore.web_search;
const web_search_config = @import("web_search_config.zig");
const config_mod = nalarcore.config;

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const wrapToolOutput = tools.wrapToolOutput;

const Providers = config_mod.LlmConfig.WebSearchProvidersMap;

fn fail(ctx: ToolExecContext, tc: agent.ToolCall, msg: []const u8) !ToolExecResult {
    const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, false, msg, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

fn dispatch(
    ctx: ToolExecContext,
    tc: agent.ToolCall,
    providers: *const Providers,
    provider_name: []const u8,
    curl: []const u8,
) !ToolExecResult {
    const resolved = web_search_mod.resolveProvider(ctx.allocator, providers, provider_name) catch |err| switch (err) {
        // Self-correcting: the envelope names what IS configured, so a model
        // that skipped the discovery call recovers in one turn.
        error.UnknownProvider => {
            const inner = web_search_mod.unknownProviderEnvelope(ctx.allocator, providers, provider_name) catch return err;
            defer ctx.allocator.free(inner);
            const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, false, inner, inner);
            return ToolExecResult{ .output = output, .output_allocated = true };
        },
    };

    const inner = web_search_mod.executeWebSearch(ctx.allocator, resolved, curl) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "web_search failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(msg);
        return fail(ctx, tc, msg);
    };
    defer ctx.allocator.free(inner);

    // An envelope carrying `error` reaches the model as success=false while
    // still exposing the full JSON, so it can read `host_mismatch`,
    // `other_providers` and the reason string.
    {
        const maybe = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch null;
        defer if (maybe) |*p| p.deinit();
        if (maybe) |doc| {
            const value = doc.value;
            if (value == .object) {
                if (value.object.get("error")) |e| {
                    if (e == .string) {
                        const output = try wrapToolOutput(
                            ctx.allocator,
                            "web_search",
                            tc.function.arguments,
                            false,
                            e.string,
                            inner,
                        );
                        return ToolExecResult{ .output = output, .output_allocated = true };
                    }
                }
            }
        }
    }

    const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

pub fn execWebSearch(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        web_search_mod.WebSearchInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "web_search failed to parse input: {s}", .{@errorName(err)});
        defer ctx.allocator.free(msg);
        return fail(ctx, tc, msg);
    };
    defer parsed.deinit();

    if (parsed.value.provider.len == 0 or parsed.value.curl.len == 0) {
        return fail(
            ctx,
            tc,
            "web_search needs both `provider` and `curl`. Call list_web_search_providers to see the configured providers and their templates.",
        );
    }

    // Per-session FIRST — `ctx.config` is the singleton and is empty in
    // `--auth` mode. The singleton is the documented fallback for exactly the
    // cases `resolve` returns null for, and it outlives this call.
    if (web_search_config.resolve(ctx.allocator, ctx.db, ctx.session_id)) |owned| {
        var map = owned;
        defer config_mod.LlmConfig.freeWebSearchProvidersMap(&map, ctx.allocator);
        return dispatch(ctx, tc, &map, parsed.value.provider, parsed.value.curl);
    }

    if (ctx.config.web_search) |*singleton| {
        return dispatch(ctx, tc, singleton, parsed.value.provider, parsed.value.curl);
    }

    const inner = web_search_mod.notConfiguredEnvelope(ctx.allocator) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "web_search failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(msg);
        return fail(ctx, tc, msg);
    };
    defer ctx.allocator.free(inner);
    const output = try wrapToolOutput(ctx.allocator, "web_search", tc.function.arguments, false, inner, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
