//! `execGenerateImage` — thin wrapper that bridges the agentic loop's
//! `ToolCall` to the `generate_image` tool's `execute_generate_image`
//! implementation.
//!
//! Follows the exact same pattern as `tools_exec_present_files.zig`:
//! 1. Parse the LLM's JSON arguments into `GenerateImageInput`
//! 2. Call `execute_generate_image(...)` with the active profile's
//!    `base_url` + `api_key` + the session's `cwd` (all carried on
//!    `ToolExecContext`)
//! 3. Wrap the XML envelope (`<generate_image>...</generate_image>`)
//!    via `wrapToolOutput` — surfacing `<error>` as `success=false`
//!    to the LLM, mirroring how every other tool handles errors.
//!
//! Plan: docs/superpowers/plans/2026-08-14-generate-image-tool.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const generate_image_mod = nalarcore.generate_image;
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
    //    validation, save-to-disk) is already encoded in the XML
    //    envelope — we just wrap it.
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

    // 3. Detect the <error>...</error> shape and surface it to the LLM
    //    as success=false. The full XML envelope is still passed as
    //    `data` so the LLM can read the diagnostic.
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len - err_start;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(
            ctx.allocator,
            "generate_image",
            tc.function.arguments,
            false,
            err_msg,
            inner,
        );
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    // 4. Success path — pass the envelope through as-is.
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