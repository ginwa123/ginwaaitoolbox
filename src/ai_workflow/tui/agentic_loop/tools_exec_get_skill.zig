const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const SkillSaveInfo = tools.SkillSaveInfo;
const agent = nalarcore.agent;
const get_skill_mod = nalarcore.get_skill_tool;
const wrapToolOutput = tools.wrapToolOutput;
const testing = std.testing;

pub fn execGetSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        get_skill_mod.GetSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    // Security: reject absolute paths.
    if (parsed.value.path) |path| {
        if (try nalarcore.path_security.rejectAbsolutePath(
            ctx.allocator, "get_skill", "path", path, ctx.cwd
        )) |err_msg| {
            defer ctx.allocator.free(err_msg);
            const output = try wrapToolOutput(ctx.allocator, "get_skill", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    }

    // Resolve the relative path against ctx.cwd_override ?? ctx.cwd
    // when present. The underlying loadSkillFromPath uses
    // std.Io.Dir.cwd() (the OS process cwd), NOT ctx.cwd — so without
    // this resolution the LLM-supplied relative path would be loaded
    // from the wrong directory.
    var resolved_path_opt: ?[]u8 = null;
    defer if (resolved_path_opt) |p| ctx.allocator.free(p);
    var relative_output_path_opt: ?[]u8 = null;
    defer if (relative_output_path_opt) |p| ctx.allocator.free(p);
    var skill_input = parsed.value;
    if (parsed.value.path) |p| {
        const resolved = try nalarcore.path_security.resolveCwd(
            ctx.allocator, ctx.cwd, ctx.cwd_override, p
        );
        resolved_path_opt = resolved;
        skill_input.path = resolved;

        // Compute the relative path used in error messages (so the
        // LLM sees "src/main.zig" instead of the absolute path in
        // <error>Failed to open file "{path}"</error>).
        const base = ctx.cwd_override orelse ctx.cwd;
        relative_output_path_opt = try nalarcore.path_security.relativePath(
            ctx.allocator, base, resolved
        );
    }

    const raw_inner = get_skill_mod.execute_get_skill_to_string(ctx.allocator, ctx.io, skill_input, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "get_skill failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "get_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // The underlying error messages embed the absolute resolved path.
    // Swap that for the relative form so the LLM doesn't see the
    // server's filesystem layout. Only applied when the path was
    // provided (resolved_path_opt != null).
    const inner = if (resolved_path_opt != null and relative_output_path_opt != null)
        try std.mem.replaceOwned(
            u8,
            ctx.allocator,
            raw_inner,
            resolved_path_opt.?,
            relative_output_path_opt.?,
        )
    else
        raw_inner;
    defer if (resolved_path_opt != null and relative_output_path_opt != null)
        ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "get_skill", tc.function.arguments, true, null, inner);

    // Check if skill was successfully loaded and extract skill info for auto-save.
    // The skill_save detection now looks for <success>true</success> in the WRAPPED
    // envelope, not <loaded>true</loaded> in the inner XML (which is now inside
    // <data>...</data>).
    if (std.mem.indexOf(u8, output, "<success>true</success>") != null) {
        // Extract skill name from <skill_name>...</skill_name>
        const name_start = (std.mem.indexOf(u8, output, "<skill_name>") orelse 0) + "<skill_name>".len;
        const name_end = std.mem.indexOf(u8, output[name_start..], "</skill_name>") orelse {
            return ToolExecResult{ .output = output, .output_allocated = true };
        };
        const skill_name = output[name_start .. name_start + name_end];

        // Extract content from <content>...</content>
        const content_start = (std.mem.indexOf(u8, output, "<content>") orelse 0) + "<content>".len;
        const content_begin = content_start + "<content>".len;
        const content_end = std.mem.indexOf(u8, output[content_begin..], "</content>") orelse {
            return ToolExecResult{ .output = output, .output_allocated = true };
        };
        const skill_content = output[content_begin .. content_begin + content_end];

        // Return with skill_save info so handle_tool can auto-save to session_skills
        return ToolExecResult{
            .output = output,
            .output_allocated = true,
            .skill_save = SkillSaveInfo{
                .name = skill_name,
                .content = skill_content,
            },
        };
    }

    return ToolExecResult{ .output = output, .output_allocated = true };
}
// 2026-08-14 — end-to-end proof that RELATIVE paths work on every
// tool wired with the absolute-path ban (PR #259 follow-up).
test "execGetSkill: relative path resolves and loads skill content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = try a.dupe(u8, path_buf[0..n]);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "SKILL.MD",
        .data =
        \\---
        \\name: relative-skill-test
        \\description: a test skill
        \\---
        \\
        \\# Skill Body
        \\proof that relative path works.
        ,
    });

    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    const ctx = ToolExecContext{
        .allocator = a, .io = testing.io, .db = undefined,
        .logger = undefined, .session_id = "test", .model = "test",
        .cwd = root_abs, .api_key = "test", .base_url = "test",
        .config = undefined, .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool, .environment = null,
        .active_loops = undefined,
    };
    const tc = agent.ToolCall{
        .id = "call_1", .type = "function",
        .function = .{ .name = "get_skill", .arguments = "{\"path\":\"SKILL.MD\"}" },
    };

    const result = try execGetSkill(ctx, tc);
    defer if (result.output_allocated) a.free(result.output);

    try testing.expect(std.mem.indexOf(u8, result.output, "absolute paths are not allowed") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "relative-skill-test") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "proof that relative path works") != null);
}
