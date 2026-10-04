// Exec wrappers for the skill agent tools (`search_skills` / `use_skill` /
// `remove_skill` / `add_skill` / `edit_skill`) — merged 2026-09-11
// skills-merge refactor: one file, five exec fns. The public names
// (`execSearchSkills` / `execUseSkill` / `execRemoveSkill` / `execAddSkill` /
// `execEditSkill`) and behavior are unchanged.
//
// `search_skills` replaced the old `list_skills`: same skill library, but the
// agent now narrows with a regex query and pages through the matches instead
// of pulling every row into context. Matching + rendering live in
// `skills_search.zig` (next to `progressive_catalog.zig`), because the regex
// engine is under `src/agentic_loop/` and `src/modules/` must not import it.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");
const skills_search = @import("skills_search.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const SkillSaveInfo = tools.SkillSaveInfo;
const agent = pabrikcore.agent;
const skill_tools_mod = pabrikcore.skill_tools;
const wrapToolOutput = tools.wrapToolOutput;

/// Turn a JSON parse failure into a message the model can act on.
///
/// The old form was `"add_skill failed: MissingField"` — an error NAME.
/// It named no field, showed none of what was received, and gave nothing
/// to correct itself from, so a model that omitted `description` simply
/// emitted the same call again. With every `*SkillInput` field defaulted
/// this path is now only reachable for genuinely malformed JSON or a
/// wrong-typed field; it still has to say WHICH and show the payload.
///
/// Caller owns the returned slice.
fn describeParseFailure(
    allocator: std.mem.Allocator,
    arguments: []const u8,
    err: anyerror,
    summary: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} ({s}). Arguments must be a JSON object whose keys are the tool's own parameters, each with the declared type — `name`/`description`/`content` are strings and `is_global` is a boolean, not the string \"true\". Received: {s}", .{
        summary,
        @errorName(err),
        arguments,
    });
}

// ─── search_skills ───

pub fn execSearchSkills(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        skill_tools_mod.SearchSkillsInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        const output = try wrapToolOutput(
            ctx.allocator,
            "search_skills",
            tc.function.arguments,
            false,
            "search_skills failed to parse input (expected {\"query\"?: string, \"literal\"?: bool, \"scope\"?: string, \"limit\"?: number, \"offset\"?: number, \"cwd\"?: string})",
            "",
        );
        return .{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // ── Paging bounds ──
    // Rejected, never silently clamped: the model pages by offset from the
    // `total` it was shown, so a quiet clamp would make its next call land on
    // the wrong window. The messages name the accepted range.
    const limit: usize = blk: {
        const raw = parsed.value.limit orelse @as(i64, @intCast(skills_search.DEFAULT_SEARCH_LIMIT));
        if (raw < 1) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "search_skills: limit must be at least 1 (got {d})", .{raw});
            const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        if (raw > @as(i64, @intCast(skills_search.MAX_SEARCH_LIMIT))) {
            const msg = try std.fmt.allocPrint(
                ctx.allocator,
                "search_skills: limit must be at most {d} (got {d})",
                .{ skills_search.MAX_SEARCH_LIMIT, raw },
            );
            const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        break :blk @intCast(raw);
    };
    const offset: usize = blk: {
        const raw = parsed.value.offset orelse 0;
        if (raw < 0) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "search_skills: offset must not be negative (got {d})", .{raw});
            const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, msg, "");
            return .{ .output = output, .output_allocated = true };
        }
        break :blk @intCast(raw);
    };

    // An unparseable scope is an explicit error, never a zero-row answer:
    // "no skills matched" and "you named a tier that does not exist" are
    // different facts and the model needs the second one.
    const scope_filter: ?skills_search.Scope = blk: {
        const raw = parsed.value.scope orelse break :blk null;
        if (raw.len == 0) break :blk null;
        if (skills_search.parseScope(raw)) |s| break :blk s;
        const msg = try std.fmt.allocPrint(ctx.allocator, "search_skills: unknown scope '{s}' — {s}", .{ raw, skills_search.ACCEPTED_SCOPES_MSG });
        const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, msg, "");
        return .{ .output = output, .output_allocated = true };
    };

    // Prefer the model's explicit `cwd`, else the session's own workspace —
    // the same directory add_skill/edit_skill/remove_skill write to, and the
    // one the old `execListSkills` regression test pinned (it once passed
    // null here, which made local skills invisible to the agent).
    const cwd = parsed.value.cwd orelse ctx.cwd;

    const data = skill_tools_mod.listAllSkills(ctx.allocator, ctx.io, cwd, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "search_skills failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, false, err_msg, "");
        return .{ .output = output, .output_allocated = true };
    };
    defer skill_tools_mod.freeSkillsListData(ctx.allocator, data);

    const rows = try skills_search.collectRows(ctx.allocator, data);
    defer ctx.allocator.free(rows);

    const query = parsed.value.query orelse "";
    const outcome = try skills_search.matchQuery(ctx.allocator, rows, query, .{
        .literal = parsed.value.literal orelse false,
        .scope = scope_filter,
    });
    defer ctx.allocator.free(outcome.rows);

    const page = skills_search.pageSlice(outcome.rows, offset, limit);
    const inner = try skills_search.renderSearchResult(ctx.allocator, page, .{
        .total = outcome.rows.len,
        .offset = offset,
        .limit = limit,
        .query = query,
        .scope = scope_filter,
        .mode = outcome.mode,
        .warning = outcome.warning,
    });
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, "search_skills", tc.function.arguments, true, null, inner);
    return .{ .output = output, .output_allocated = true };
}

// ─── use_skill ───

pub fn execUseSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = try std.json.parseFromSlice(
        skill_tools_mod.UseSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const inner = skill_tools_mod.execute_use_skill_to_string(ctx.allocator, ctx.io, parsed.value, ctx.environment) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "use_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "use_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    const output = try wrapToolOutput(ctx.allocator, "use_skill", tc.function.arguments, true, null, inner);

    // Check if skill was successfully loaded and extract skill info for auto-save.
    // The inner payload is JSON (`{skill_name, content, loaded, ...}`); parse it
    // and key off `loaded` instead of substring-matching XML tags.
    if (std.json.parseFromSlice(skill_tools_mod.UseSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.loaded) {
            const skill_name = try ctx.allocator.dupe(u8, parsed_inner.value.skill_name);
            const skill_content = try ctx.allocator.dupe(u8, parsed_inner.value.content);
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
    } else |_| {}

    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── remove_skill ───

pub fn execRemoveSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // `ignore_unknown_fields`, same reason as execAddSkill: a stray key
    // must not cost the call.
    const parsed = std.json.parseFromSlice(
        skill_tools_mod.RemoveSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try describeParseFailure(ctx.allocator, tc.function.arguments, err, "remove_skill failed to parse its arguments");
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = skill_tools_mod.execute_remove_skill_to_string(ctx.allocator, ctx.io, ctx.cwd, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "remove_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // If the inner JSON carries an `error`, treat as failure.
    if (std.json.parseFromSlice(skill_tools_mod.RemoveSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    } else |_| {}

    const output = try wrapToolOutput(ctx.allocator, "remove_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── add_skill ───

pub fn execAddSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // `ignore_unknown_fields` — the sibling `execSearchSkills` has always
    // had it, and without it a model that volunteers one extra key
    // (`scope`, `session_id`, …) gets `UnknownField` and the write is
    // lost. Every `*SkillInput` field now carries a default, so an
    // OMITTED field also parses; `executeAddSkillToString` is where the
    // "which argument is missing" message is produced.
    const parsed = std.json.parseFromSlice(
        skill_tools_mod.AddSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try describeParseFailure(ctx.allocator, tc.function.arguments, err, "add_skill failed to parse its arguments");
        const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    // executeAddSkillToString returns a plain []const u8 (no error
    // union); errors are encoded as `error` in the inner JSON object
    // and handled below.
    const inner = skill_tools_mod.executeAddSkillToString(ctx.allocator, ctx.io, ctx.cwd, ctx.environment, parsed.value);

    if (std.json.parseFromSlice(skill_tools_mod.AddSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    } else |_| {}

    const output = try wrapToolOutput(ctx.allocator, "add_skill", tc.function.arguments, true, null, inner);

    // The registry entry has auto_save_skill = true → the dispatcher in
    // handle_tool.zig reads the wrapped JSON `data` (`skill_name`/`content`
    // keys), then saves to session_skills. We return skill_save (not used
    // directly here, but kept for symmetry with execUseSkill's auto-save
    // contract — both rely on the dispatcher's parsing pass over the
    // wrapped output).
    _ = SkillSaveInfo;
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ─── edit_skill ───

pub fn execEditSkill(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    // `ignore_unknown_fields`, same reason as execAddSkill.
    const parsed = std.json.parseFromSlice(
        skill_tools_mod.EditSkillInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try describeParseFailure(ctx.allocator, tc.function.arguments, err, "edit_skill failed to parse its arguments");
        const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = skill_tools_mod.executeEditSkillToString(ctx.allocator, ctx.io, ctx.cwd, ctx.environment, parsed.value) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "edit_skill failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    // If the inner JSON carries an `error`, treat as failure.
    if (std.json.parseFromSlice(skill_tools_mod.EditSkillOutput, ctx.allocator, inner, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })) |parsed_inner| {
        defer parsed_inner.deinit();
        if (parsed_inner.value.@"error") |err_msg| {
            const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, false, err_msg, "");
            return ToolExecResult{ .output = output, .output_allocated = true };
        }
    } else |_| {}

    const output = try wrapToolOutput(ctx.allocator, "edit_skill", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
