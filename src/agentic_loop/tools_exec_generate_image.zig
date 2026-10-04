//! `execGenerateImage` — thin wrapper that bridges the agentic loop's
//! `ToolCall` to the `generate_image` tool's `execute_generate_image`
//! implementation.
//!
//! Follows the exact same pattern as `tools_exec_present_files.zig`:
//! 1. Parse the LLM's JSON arguments into `GenerateImageInput`
//! 2. Call `execute_generate_image(...)` with the active profile's
//!    `base_url` + `api_key` + the session's `cwd` (all carried on
//!    `ToolExecContext`)
//! 3. Wrap the JSON payload (`{status:...}`)
//!    via `wrapToolOutput` — surfacing `status:"error"` as `success=false`
//!    to the LLM, mirroring how every other tool handles errors.
//!
//! Plan: docs/superpowers/plans/2026-08-14-generate-image-tool.md

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const generate_image_mod = pabrikcore.generate_image;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execGenerateImage(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // 1. Parse the LLM-provided JSON arguments.
    const parsed = std.json.parseFromSlice(
        generate_image_mod.GenerateImageInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(
            ctx.allocator,
            "generate_image failed to parse input: {s}",
            .{@errorName(err)},
        );
        const output = try wrapToolOutput(
            ctx.allocator,
            "generate_image",
            tc.function.arguments,
            false,
            err_msg,
            "",
        );
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // 2. Call the impl with the active profile's API endpoint + the
    //    session's working directory. Any tool-level error (HTTP,
    //    validation, save-to-disk) is already encoded in the JSON
    //    payload — we just wrap it.
    const inner = generate_image_mod.execute_generate_image(
        ctx.allocator,
        ctx.io,
        parsed.value,
        ctx.base_url,
        ctx.api_key,
        ctx.cwd,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(
            ctx.allocator,
            "generate_image failed: {s}",
            .{@errorName(err)},
        );
        const output = try wrapToolOutput(
            ctx.allocator,
            "generate_image",
            tc.function.arguments,
            false,
            err_msg,
            "",
        );
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // 3. Detect the {status:"error", error:...} shape and surface it
    //    to the LLM as success=false. The full JSON payload is still
    //    passed as `data` so the LLM can read the diagnostic.
    //    A payload that fails to parse is passed through as success —
    //    it came straight from the tool impl, not the wire.
    {
        const inner_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, inner, .{}) catch null;
        if (inner_parsed) |pv| {
            defer pv.deinit();
            if (pv.value == .object) {
                if (pv.value.object.get("error")) |err_val| {
                    if (err_val != .null and err_val == .string) {
                        const output = try wrapToolOutput(
                            ctx.allocator,
                            "generate_image",
                            tc.function.arguments,
                            false,
                            err_val.string,
                            inner,
                        );
                        return ToolExecResult{ .output = output, .output_allocated = true };
                    }
                }
            }
        }
    }

    // 4. Success path — pass the payload through as-is.
    const output = try wrapToolOutput(
        ctx.allocator,
        "generate_image",
        tc.function.arguments,
        true,
        null,
        inner,
    );
    return ToolExecResult{ .output = output, .output_allocated = true };
}
