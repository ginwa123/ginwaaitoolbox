//! Skill agent tools: `list_skills` + `use_skill` + `remove_skill` +
//! `add_skill` + `edit_skill`.
//!
//! Storage lives in the `skills` SQLite table (`skills_db.zig`); this file is
//! the tool-shaped surface over it. A skill used to BE a file
//! (`<root>/<name>/SKILL.MD`) and the filesystem path was the handle the LLM
//! passed around — `use_skill` now takes a `skill_name` instead.
//!
//! Every tool result is a JSON object built with `std.json.Stringify.valueAlloc`.
//!
//! Two invariants the DB layer cannot enforce for us:
//!   1. Writes are **row first, mirror second**. The row is the truth; the
//!      `SKILL.MD` mirror is best-effort and log-and-continue, so a repo that
//!      tracks `.nalar/skills/` keeps working and a failed mirror never fails
//!      the tool call.
//!   2. The importer is `INSERT OR IGNORE` (see `skills_db.importFromDisk`), so
//!      hand-editing a `SKILL.MD` after the row exists no longer changes what
//!      the agent sees. Re-import deliberately: `remove_skill`, then let the
//!      next boot pick the file back up.
//!
//! Plan: docs/plans/2026-09-28-skills-sqlite-table.md (W3)

const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");
const skills_db = @import("../../../agentic_loop/skills_db.zig");
const helpers = @import("helpers");
const nalarcore = @import("nalarcore");

const SqliteBackend = nalarcore.sqlite.SqliteBackend;

/// Substring check shared by the tool tests below.
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Cap on a single skill body, mirroring `skills.MAX_SKILLS_SIZE`. The
/// filesystem era applied it only to the listing path and let `use_skill` read
/// unbounded; a row can be just as large, so the cap now applies on load too.
/// An oversized skill returns `loaded: false` with its byte count rather than
/// silently flooding the context.
pub const MAX_SKILL_BYTES: usize = 100 * 1024;

/// Free a `skills.SkillInfo` list held in an ArrayList that has not been
/// converted to a slice yet (the `errdefer` path in listAllSkills).
fn freeSkillInfoList(allocator: std.mem.Allocator, list: *std.ArrayList(skills.SkillInfo)) void {
    for (list.items) |item| {
        allocator.free(item.name);
        allocator.free(item.description);
        allocator.free(item.tags);
        allocator.free(item.path);
    }
    list.deinit(allocator);
}

// ─── list_skills ───

/// Shared data structure for skills list - used by both HTTP handler and AI agent tool
pub const SkillsListData = struct {
    global_skills: []const skills.SkillInfo,
    local_skills: []const skills.SkillInfo,
    cwd: ?[]const u8,
};

/// Tool definition for list_skills
pub const list_skills_tool_system_prompt =
    \\## List Skills Tool — Behavior
    \\Use `list_skills` to discover available skills (global + local).
    \\- Call to refresh the skill list before picking a skill to load. No parameters required beyond `cwd`.
    \\
    \\Each entry carries `name`, `description`, `tags` and `path`. `tags` are
    \\`'||'`-joined — read them to decide whether a skill is relevant before
    \\loading it. `path` is provenance and is often empty; it is NOT the handle
    \\for `use_skill`.
    \\
;

pub const list_skills_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_skills",
        .description = "List all available skills with brief descriptions. Use this to discover what capabilities you can load.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Absolute working directory for the command. REQUIRED — always set explicitly. " ++
                        "Never assume the current directory. All relative paths in the command resolve from here.",
                },
            },
            .required = &.{},
        },
        .system_prompt = list_skills_tool_system_prompt,
    },
};

/// List all skills (global + local) and return the data structure
/// Caller owns the returned memory and must free it with freeSkillsListData()
///
/// Reads the `skills` table. The `{global_skills, local_skills, cwd}` shape is
/// unchanged from the filesystem era because it is simultaneously the REST
/// response body AND the `list_skills` tool's `data` payload — changing it
/// would change prompt bytes as well as the wire contract.
pub fn listAllSkills(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *SqliteBackend,
    cwd_param: ?[]const u8,
) !SkillsListData {
    // A missing cwd is normal: the importer populates global rows, and a
    // global-only listing needs no workspace.
    var canonical: []u8 = &.{};
    if (cwd_param) |c| {
        if (c.len > 0) canonical = try skills_db.canonicalCwd(allocator, io, c);
    }
    defer allocator.free(canonical);

    const rows = try skills_db.listSkills(allocator, db, null, if (canonical.len == 0) null else canonical);
    defer skills_db.freeSkillRows(allocator, rows);

    var global_skills: std.ArrayList(skills.SkillInfo) = .empty;
    errdefer freeSkillInfoList(allocator, &global_skills);
    var local_skills: std.ArrayList(skills.SkillInfo) = .empty;
    errdefer freeSkillInfoList(allocator, &local_skills);

    for (rows) |row| {
        const entry = skills.SkillInfo{
            .name = try allocator.dupe(u8, row.name),
            .description = try allocator.dupe(u8, row.description),
            .tags = try allocator.dupe(u8, row.tags),
            // `source_path` is provenance only, and empty for rows the agent
            // created — so `path` may legitimately be "".
            .path = try allocator.dupe(u8, row.source_path),
        };
        const target = if (row.is_global) &global_skills else &local_skills;
        target.append(allocator, entry) catch |err| {
            // Undo the dupes we just made; the list itself is freed by errdefer.
            allocator.free(entry.name);
            allocator.free(entry.description);
            allocator.free(entry.tags);
            allocator.free(entry.path);
            return err;
        };
    }

    return SkillsListData{
        .global_skills = try global_skills.toOwnedSlice(allocator),
        .local_skills = try local_skills.toOwnedSlice(allocator),
        .cwd = cwd_param,
    };
}

/// Free memory allocated by listAllSkills()
pub fn freeSkillsListData(allocator: std.mem.Allocator, data: SkillsListData) void {
    skills.free_skills_list(allocator, data.global_skills);
    skills.free_skills_list(allocator, data.local_skills);
}

/// Serialize SkillsListData to JSON string
/// Caller owns the returned memory and must free it with allocator.free()
pub fn toJson(allocator: std.mem.Allocator, data: SkillsListData) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, data, .{});
}

/// Execute the list_skills tool - returns a JSON string for AI agent
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_list_skills(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *SqliteBackend,
    cwd_param: ?[]const u8,
) ![]const u8 {
    const data = try listAllSkills(allocator, io, db, cwd_param);
    defer freeSkillsListData(allocator, data);
    return toJson(allocator, data);
}

/// Parsed shape of `execute_list_skills` output, for tests.
pub const ListSkillsOutput = struct {
    global_skills: []skills.SkillInfo,
    local_skills: []skills.SkillInfo,
    cwd: ?[]const u8 = null,
};

// ─── use_skill ───

/// Input structure for use_skill tool
pub const UseSkillInput = struct {
    /// The skill's name, as reported by `list_skills`. This replaces the old
    /// `path` field: a skill used to BE a file, so the filesystem path was the
    /// only handle the LLM had. The row is the source of truth now, so the
    /// name is. Deliberately no `path` fallback — a compatibility shim would
    /// re-create the dual source of truth this removed.
    skill_name: ?[]const u8 = null,
    /// null (the default) resolves local-first, then global. Set explicitly to
    /// pin one branch.
    is_global: ?bool = null,
};

/// Result structure for use_skill tool
pub const UseSkillResult = struct {
    skill_name: []const u8,
    content: []const u8,
    loaded: bool,
    err_msg: ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

/// Tool definition for use_skill
pub const use_skill_tool_system_prompt =
    \\## Use Skill Tool — Behavior
    \\Use `use_skill` to load a skill's full instructions by NAME (from `list_skills`).
    \\- Pass `skill_name` exactly as `list_skills` reported it. Do NOT construct a filesystem path — `path` in the listing is provenance and is often empty.
    \\- Omit `is_global` to get local-first resolution; set it only to disambiguate a name that exists in both scopes.
    \\
;

pub const use_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "use_skill",
        .description = "Load a skill's full content by name. Use this when you need detailed guidance for a specific capability. Pass the skill name (as reported by list_skills) via the `skill_name` argument.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact skill name to load, e.g. 'code-review-pattern'. Take it verbatim from list_skills.",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "Optional. Omit for local-first resolution. Set true to load only the global skill, false to load only the workspace-local one.",
                },
            },
            .required = &.{"skill_name"},
        },
        .system_prompt = use_skill_tool_system_prompt,
    },
};

/// JSON payload for use_skill results.
///
/// Frozen: `tools_exec_skills.execUseSkill` parses this to produce the
/// `skill_save` that feeds `session_skills`, and the compaction drift detector
/// depends on it. Field order and names are load-bearing.
pub const UseSkillJSON = struct {
    skill_name: []const u8,
    content: []const u8,
    loaded: bool,
    @"error": ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

/// Parsed shape of `execute_use_skill_to_string` output, for tests.
pub const UseSkillOutput = struct {
    skill_name: []const u8 = "",
    content: []const u8 = "",
    loaded: bool = false,
    @"error": ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

fn useSkillJsonError(allocator: std.mem.Allocator, skill_name: []const u8, err_msg: []const u8) ![]const u8 {
    const clean_name = try helpers.sanitize_control_chars(allocator, skill_name);
    defer allocator.free(clean_name);
    const clean_err = try helpers.sanitize_control_chars(allocator, err_msg);
    defer allocator.free(clean_err);
    return try std.json.Stringify.valueAlloc(allocator, UseSkillJSON{
        .skill_name = clean_name,
        .content = "",
        .loaded = false,
        .@"error" = clean_err,
        .available_skills = null,
    }, .{});
}

/// Execute the use_skill tool.
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_use_skill_to_string(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *SqliteBackend,
    input: UseSkillInput,
) ![]const u8 {
    const name = input.skill_name orelse
        return useSkillJsonError(allocator, "", "skill_name is required — pass the name from list_skills, not a file path");

    // Resolution is local-first, which needs a workspace to compare against.
    // The tools are always dispatched with a ctx.cwd; the "." fallback only
    // matters for a direct unit call.
    const canonical = skills_db.canonicalCwd(allocator, io, ".") catch &.{};
    defer allocator.free(canonical);

    const row = skills_db.getSkill(allocator, db, name, input.is_global, canonical) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "use_skill failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return useSkillJsonError(allocator, name, msg);
    } orelse {
        // Naming `skill_name` back is what makes this self-healing: a model
        // still sending the old `path` argument corrects itself in one turn.
        const msg = try std.fmt.allocPrint(
            allocator,
            "Skill '{s}' not found. Call list_skills and pass the exact name in `skill_name` — a filesystem path is no longer accepted.",
            .{name},
        );
        defer allocator.free(msg);
        return useSkillJsonError(allocator, name, msg);
    };
    defer skills_db.freeSkillRow(allocator, row);

    if (row.content.len > MAX_SKILL_BYTES) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "Skill '{s}' is {d} bytes, over the {d}-byte limit. Skipping it rather than flooding the context.",
            .{ name, row.content.len, MAX_SKILL_BYTES },
        );
        defer allocator.free(msg);
        return useSkillJsonError(allocator, name, msg);
    }

    const clean_name = try helpers.sanitize_control_chars(allocator, row.name);
    defer allocator.free(clean_name);
    const clean_content = try helpers.sanitize_control_chars(allocator, row.content);
    defer allocator.free(clean_content);
    return try std.json.Stringify.valueAlloc(allocator, UseSkillJSON{
        .skill_name = clean_name,
        .content = clean_content,
        .loaded = true,
        .@"error" = null,
        .available_skills = null,
    }, .{});
}

// ─── remove_skill ───

/// Input structure for remove_skill tool
pub const RemoveSkillInput = struct {
    skill_name: []const u8,
    session_id: []const u8,
    /// If true, remove the global row; if false, the workspace-local one.
    is_global: bool = false,
};

/// Result structure for remove_skill tool
pub const RemoveSkillResult = struct {
    skill_name: []const u8,
    removed: bool,
    err_msg: ?[]const u8 = null,
};

/// JSON payload for remove_skill results.
pub const RemoveSkillJSON = struct {
    skill_name: []const u8,
    removed: bool,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Parsed shape of `execute_remove_skill_to_string` output, for tests.
pub const RemoveSkillOutput = struct {
    skill_name: []const u8 = "",
    removed: bool = false,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Create JSON error output for remove_skill
pub fn removeSkillJsonError(allocator: std.mem.Allocator, skill_name: []const u8, err_msg: []const u8) []const u8 {
    const clean_name = helpers.sanitize_control_chars(allocator, skill_name) catch return "";
    defer allocator.free(clean_name);
    const clean_err = helpers.sanitize_control_chars(allocator, err_msg) catch return "";
    defer allocator.free(clean_err);
    return std.json.Stringify.valueAlloc(allocator, RemoveSkillJSON{
        .skill_name = clean_name,
        .removed = false,
        .path = null,
        .@"error" = clean_err,
    }, .{}) catch "";
}

fn removeSkillJsonSuccess(allocator: std.mem.Allocator, skill_name: []const u8, path: []const u8) []const u8 {
    const clean_name = helpers.sanitize_control_chars(allocator, skill_name) catch return "";
    defer allocator.free(clean_name);
    const clean_path = helpers.sanitize_control_chars(allocator, path) catch return "";
    defer allocator.free(clean_path);
    return std.json.Stringify.valueAlloc(allocator, RemoveSkillJSON{
        .skill_name = clean_name,
        .removed = true,
        .path = clean_path,
        .@"error" = null,
    }, .{}) catch "";
}

/// Tool definition for remove_skill
pub const remove_skill_tool_system_prompt =
    \\## Remove Skill Tool — Behavior
    \\Use `remove_skill` to permanently delete a skill.
    \\- Provide `skill_name` and `session_id`. Use only when the skill is obsolete or the user asks to remove it.
    \\
;

pub const remove_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "remove_skill",
        .description = "Remove a skill permanently — the row is deleted and the mirrored SKILL.MD folder is removed too.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact name of the skill to remove",
                },
                .{
                    .name = "session_id",
                    .type = "string",
                    .description = "The session ID (unused, kept for compatibility)",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "If true, remove the global skill; if false, the workspace-local one. Default: false",
                },
            },
            .required = &.{ "skill_name", "session_id" },
        },
        .system_prompt = remove_skill_tool_system_prompt,
    },
};

/// Execute the remove_skill tool.
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_remove_skill_to_string(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *SqliteBackend,
    cwd: []const u8,
    environment: ?*const std.process.Environ.Map,
    input: RemoveSkillInput,
) ![]const u8 {
    if (input.skill_name.len == 0) {
        return removeSkillJsonError(allocator, "", "skill_name cannot be empty");
    }

    const canonical = try skills_db.canonicalCwd(allocator, io, cwd);
    defer allocator.free(canonical);

    // Read the row first: `source_path` is what we need to clean the mirror,
    // and knowing it exists is what separates a 404 from a success.
    const row = (try skills_db.getSkill(allocator, db, input.skill_name, input.is_global, canonical)) orelse
        return removeSkillJsonError(allocator, input.skill_name, "Skill not found");
    defer skills_db.freeSkillRow(allocator, row);

    _ = try skills_db.deleteSkill(allocator, db, input.skill_name, input.is_global, canonical);

    // Mirror cleanup is best-effort: the row is gone, which is what the tool
    // promised. A stale folder is re-importable; a failed tool call is not.
    if (row.source_path.len > 0) {
        // source_path is <dir>/<name>/SKILL.MD; the folder is its parent.
        const folder = std.fs.path.dirname(row.source_path) orelse "";
        if (folder.len > 0) {
            std.Io.Dir.cwd().deleteTree(io, folder) catch {};
        }
    }

    const out = removeSkillJsonSuccess(allocator, input.skill_name, row.source_path);
    _ = environment;
    return out;
}

/// Generate error JSON response for parse failures (no name available)
pub fn removeSkillJsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return removeSkillJsonError(allocator, "", error_msg);
}

// ─── add_skill ───

/// Input structure for add_skill tool
pub const AddSkillInput = struct {
    /// Skill identifier (required)
    name: []const u8,
    /// When to trigger this skill (required)
    description: []const u8,
    /// Skill body content (required)
    content: []const u8,
    /// Comma-separated tags, stored `'||'`-joined. Optional — most skills
    /// have none, and an empty value round-trips as "" (never SQL NULL).
    tags: []const u8 = "",
    /// Auto-create the mirrored skill directory if needed (default: true)
    create_with_dir: bool = true,
    /// If true, save as a global skill; if false, workspace-local.
    is_global: bool = false,
};

/// Tool definition for add_skill
pub const add_skill_tool_system_prompt =
    \\## Add Skill Tool — Behavior
    \\Use `add_skill` to create a new reusable skill.
    \\- Provide `name`, `description`, and markdown `content`. Optionally add comma-separated `tags` so the skill is discoverable by topic.
    \\- Check for existing skill with `list_skills` first to avoid duplicates.
    \\
;

pub const add_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "add_skill",
        .description = "Create a new skill. Use this when the user wants to save a workflow, pattern, or reusable instructions as a skill for future use.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "The unique identifier name for the skill (e.g., 'my-workflow', 'code-review-pattern')",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "When to use this skill - describe the trigger conditions and what the skill accomplishes",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "The full skill content/markdown body that will be loaded when the skill is invoked",
                },
                .{
                    .name = "tags",
                    .type = "string",
                    .description = "Optional comma-separated tags, e.g. 'workflow, environment, api'. Stored '||'-joined and shown by list_skills.",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "If true, save as a global skill; if false, workspace-local. Default: false",
                },
            },
            .required = &.{ "name", "description", "content" },
        },
        .system_prompt = add_skill_tool_system_prompt,
    },
};

/// JSON payload for add_skill results. Both `skill_name` and `name` carry
/// the skill name: `skill_name` matches the tool schema, `name` matches the
/// legacy tag name read by existing JSON parsers.
pub const AddSkillJSON = struct {
    skill_name: []const u8,
    name: []const u8,
    created: bool,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Parsed shape of `executeAddSkillToString` output, for tests.
pub const AddSkillOutput = struct {
    skill_name: []const u8 = "",
    name: []const u8 = "",
    created: bool = false,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Absolute path of the mirrored SKILL.MD for a skill, or null when the
/// skills root cannot be resolved (no environment).
fn mirrorDirFor(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    is_global: bool,
    environment: ?*const std.process.Environ.Map,
) !?[]u8 {
    if (is_global) {
        if (environment) |env| {
            if (skills.get_global_skills_path_from_env(allocator, env)) |p| {
                defer allocator.free(p);
                return try allocator.dupe(u8, p);
            }
        }
        return null;
    }
    return try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "skills" });
}

/// Execute the add_skill tool — row first, then the mirror.
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeAddSkillToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *SqliteBackend,
    cwd: []const u8,
    environment: ?*const std.process.Environ.Map,
    input: AddSkillInput,
) []const u8 {
    if (input.name.len == 0) return addSkillJsonError(allocator, input.name, "Skill name cannot be empty");
    if (input.description.len == 0) return addSkillJsonError(allocator, input.name, "Description cannot be empty");
    if (input.content.len == 0) return addSkillJsonError(allocator, input.name, "Content cannot be empty");

    const normalized_tags = skills_db.normalizeTags(allocator, input.tags) catch
        return addSkillJsonError(allocator, input.name, "Failed to normalise tags");
    defer allocator.free(normalized_tags);

    const canonical = skills_db.canonicalCwd(allocator, io, cwd) catch
        return addSkillJsonError(allocator, input.name, "Failed to resolve workspace path");
    defer allocator.free(canonical);

    // ── row first: this is the source of truth ──
    const skills_dir: ?[]u8 = mirrorDirFor(allocator, canonical, input.is_global, environment) catch null;
    defer if (skills_dir) |d| allocator.free(d);

    var mirrored_path: []const u8 = "";
    var mirrored_buf: ?[]u8 = null;
    if (skills_dir) |dir| {
        if (std.fs.path.join(allocator, &[_][]const u8{ dir, input.name, "SKILL.MD" })) |p| {
            mirrored_buf = p;
            mirrored_path = p;
        } else |_| {}
    }

    const row_id = skills_db.upsertSkill(allocator, db, .{
        .name = input.name,
        .description = input.description,
        .tags = normalized_tags,
        .content = input.content,
        .is_global = input.is_global,
        .cwd = canonical,
        .source_path = mirrored_path,
    }) catch return addSkillJsonError(allocator, input.name, "Failed to save skill");
    defer allocator.free(row_id);

    // ── mirror second: best-effort, never fails the call ──
    if (skills_dir) |dir| {
        writeMirror(allocator, io, dir, input, normalized_tags) catch {};
    }

    const path_json = if (mirrored_buf) |p| p else "";
    defer if (mirrored_buf) |p| allocator.free(p);
    return addSkillJsonSuccess(allocator, input.name, path_json);
}

/// Write the `<dir>/<name>/SKILL.MD` mirror. The `tags:` line matters: without
/// it a later import drops the tags, and nothing complains.
fn writeMirror(
    allocator: std.mem.Allocator,
    io: std.Io,
    skills_dir: []const u8,
    input: AddSkillInput,
    normalized_tags: []const u8,
) !void {
    const skill_dir = try std.fs.path.join(allocator, &[_][]const u8{ skills_dir, input.name });
    defer allocator.free(skill_dir);
    const skill_file = try std.fs.path.join(allocator, &[_][]const u8{ skill_dir, "SKILL.MD" });
    defer allocator.free(skill_file);

    if (input.create_with_dir) {
        try std.Io.Dir.cwd().createDirPath(io, skill_dir);
    }

    const file_content = buildSkillContent(allocator, input, normalized_tags);
    defer allocator.free(file_content);
    if (file_content.len == 0) return error.MirrorWriteFailed;

    const file = try std.Io.Dir.cwd().createFile(io, skill_file, .{});
    defer std.Io.File.close(file, io);
    try std.Io.File.writeStreamingAll(file, io, file_content);
}

/// Build skill file content with YAML frontmatter
pub fn buildSkillContent(allocator: std.mem.Allocator, input: AddSkillInput, normalized_tags: []const u8) []const u8 {
    // Escape quotes in description for YAML string
    const escaped_desc = addSkillEscapeYamlString(allocator, input.description);
    defer allocator.free(escaped_desc);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    result.appendSlice(allocator, "---\n") catch return "";
    result.appendSlice(allocator, "name: ") catch return "";
    result.appendSlice(allocator, input.name) catch return "";
    result.appendSlice(allocator, "\n") catch return "";
    result.appendSlice(allocator, "description: \"") catch return "";
    result.appendSlice(allocator, escaped_desc) catch return "";
    result.appendSlice(allocator, "\"\n") catch return "";
    // Emitted unconditionally so a skill with no tags round-trips as an empty
    // list rather than as a missing key.
    result.appendSlice(allocator, "tags: [") catch return "";
    result.appendSlice(allocator, normalized_tags) catch return "";
    result.appendSlice(allocator, "]\n") catch return "";
    result.appendSlice(allocator, "---\n") catch return "";
    result.appendSlice(allocator, input.content) catch return "";
    result.appendSlice(allocator, "\n") catch return "";

    return result.toOwnedSlice(allocator) catch "";
}

/// Escape special characters in a YAML string value
/// Handles: double quotes, backslashes
fn addSkillEscapeYamlString(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var needs_escape = false;

    for (s) |c| {
        if (c == '"' or c == '\\') {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) {
        return allocator.dupe(u8, s) catch return s;
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => result.appendSlice(allocator, "\\\"") catch return s,
            '\\' => result.appendSlice(allocator, "\\\\") catch return s,
            else => result.append(allocator, c) catch return s,
        }
    }

    return result.toOwnedSlice(allocator) catch return s;
}

/// Generate success JSON response
fn addSkillJsonSuccess(allocator: std.mem.Allocator, name: []const u8, path: []const u8) []const u8 {
    const clean_name = helpers.sanitize_control_chars(allocator, name) catch return "";
    defer allocator.free(clean_name);
    const clean_path = helpers.sanitize_control_chars(allocator, path) catch return "";
    defer allocator.free(clean_path);
    return std.json.Stringify.valueAlloc(allocator, AddSkillJSON{
        .skill_name = clean_name,
        .name = clean_name,
        .created = true,
        .path = clean_path,
        .@"error" = null,
    }, .{}) catch "";
}

/// Generate error JSON response
pub fn addSkillJsonError(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    const clean_name = helpers.sanitize_control_chars(allocator, name) catch return "";
    defer allocator.free(clean_name);
    const clean_err = helpers.sanitize_control_chars(allocator, error_msg) catch return "";
    defer allocator.free(clean_err);
    return std.json.Stringify.valueAlloc(allocator, AddSkillJSON{
        .skill_name = clean_name,
        .name = clean_name,
        .created = false,
        .path = null,
        .@"error" = clean_err,
    }, .{}) catch "";
}

/// Generate error JSON response for parse failures (no name available)
pub fn addSkillJsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return addSkillJsonError(allocator, "", error_msg);
}

// ─── edit_skill ───

/// Input structure for edit_skill tool
pub const EditSkillInput = struct {
    /// Skill identifier (required)
    skill_name: []const u8,
    /// New description (optional - omit to keep existing)
    description: ?[]const u8 = null,
    /// New skill content (optional - omit to keep existing)
    content: ?[]const u8 = null,
    /// New comma-separated tags (optional - omit to keep existing)
    tags: ?[]const u8 = null,
    /// If true, edit the global skill; if false, the workspace-local one.
    is_global: bool = false,
};

/// Tool definition for edit_skill
pub const edit_skill_tool_system_prompt =
    \\## Edit Skill Tool — Behavior
    \\Use `edit_skill` to update an existing skill's description, tags, or body.
    \\- Provide `skill_name` and any new `description`/`tags`/`content`. Use to fix or improve a skill after learning a better approach.
    \\
;

pub const edit_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "edit_skill",
        .description = "Edit an existing skill. Updates the description, tags, and/or content of a skill. At least one of description, tags, or content must be provided.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact name of the skill to edit (e.g., 'my-workflow')",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "New description for the skill - when to use this skill and what it accomplishes",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "New skill content/markdown body that will be loaded when the skill is invoked",
                },
                .{
                    .name = "tags",
                    .type = "string",
                    .description = "New comma-separated tags. Omit to keep the existing tags.",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "If true, edit the global skill; if false, the workspace-local one. Default: false",
                },
            },
            .required = &.{"skill_name"},
        },
        .system_prompt = edit_skill_tool_system_prompt,
    },
};

/// JSON payload for edit_skill results. `skill_name`/`name` and
/// `updated`/`edited` are duplicated: the first of each pair matches the
/// tool schema, the second matches the legacy tag name.
pub const EditSkillJSON = struct {
    skill_name: []const u8,
    name: []const u8,
    updated: bool,
    edited: bool,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Parsed shape of `executeEditSkillToString` output, for tests.
pub const EditSkillOutput = struct {
    skill_name: []const u8 = "",
    name: []const u8 = "",
    updated: bool = false,
    edited: bool = false,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Execute the edit_skill tool — row first, then the mirror.
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeEditSkillToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *SqliteBackend,
    cwd: []const u8,
    environment: ?*const std.process.Environ.Map,
    input: EditSkillInput,
) ![]const u8 {
    if (input.skill_name.len == 0) {
        return editSkillJsonError(allocator, input.skill_name, "Skill name cannot be empty");
    }
    if (input.description == null and input.content == null and input.tags == null) {
        return editSkillJsonError(allocator, input.skill_name, "At least one of description, tags, or content must be provided");
    }

    const normalized_tags: ?[]u8 = if (input.tags) |t|
        try skills_db.normalizeTags(allocator, t)
    else
        null;
    defer if (normalized_tags) |t| allocator.free(t);

    // Freed on every exit path, including the "not found" early return below.
    const canonical = try skills_db.canonicalCwd(allocator, io, cwd);
    defer allocator.free(canonical);

    const existing = skills_db.getSkill(allocator, db, input.skill_name, input.is_global, canonical) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "edit_skill failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return editSkillJsonError(allocator, input.skill_name, msg);
    } orelse {
        return editSkillJsonError(allocator, input.skill_name, "Skill not found");
    };
    defer skills_db.freeSkillRow(allocator, existing);

    // ── row first ──
    const updated = skills_db.updateSkill(allocator, db, .{
        .name = input.skill_name,
        .is_global = input.is_global,
        .cwd = canonical,
        .description = input.description,
        .tags = normalized_tags,
        .content = input.content,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "edit_skill failed: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        return editSkillJsonError(allocator, input.skill_name, msg);
    };
    defer skills_db.freeSkillRow(allocator, updated);

    // ── mirror second: rewrite the whole file, including the tags line, so the
    // next import sees exactly what the row says ──
    const skills_dir: ?[]u8 = mirrorDirFor(allocator, canonical, input.is_global, environment) catch null;
    defer if (skills_dir) |d| allocator.free(d);
    if (skills_dir) |dir| {
        const mirror_input = AddSkillInput{
            .name = input.skill_name,
            .description = updated.description,
            .content = updated.content,
            .tags = updated.tags,
            .create_with_dir = true,
            .is_global = input.is_global,
        };
        writeMirror(allocator, io, dir, mirror_input, updated.tags) catch {};
    }

    return try editSkillJsonSuccess(allocator, input.skill_name, updated.source_path);
}

/// Generate success JSON response
fn editSkillJsonSuccess(allocator: std.mem.Allocator, name: []const u8, path: []const u8) ![]const u8 {
    const clean_name = try helpers.sanitize_control_chars(allocator, name);
    defer allocator.free(clean_name);
    const clean_path = try helpers.sanitize_control_chars(allocator, path);
    defer allocator.free(clean_path);
    return try std.json.Stringify.valueAlloc(allocator, EditSkillJSON{
        .skill_name = clean_name,
        .name = clean_name,
        .updated = true,
        .edited = true,
        .path = clean_path,
        .@"error" = null,
    }, .{});
}

/// Generate error JSON response
pub fn editSkillJsonError(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    const clean_name = helpers.sanitize_control_chars(allocator, name) catch return "";
    defer allocator.free(clean_name);
    const clean_err = helpers.sanitize_control_chars(allocator, error_msg) catch return "";
    defer allocator.free(clean_err);
    return std.json.Stringify.valueAlloc(allocator, EditSkillJSON{
        .skill_name = clean_name,
        .name = clean_name,
        .updated = false,
        .edited = false,
        .path = null,
        .@"error" = clean_err,
    }, .{}) catch "";
}

/// Generate error JSON response for parse failures (no name available)
pub fn editSkillJsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return editSkillJsonError(allocator, "", error_msg);
}

// ─── tests ──────────────────────────────────────────────────────────────
//
// Every test here seeds the `skills` table in an in-memory DB rather than
// writing a `SKILL.MD` on disk. The filesystem is now only an importer and a
// mirror, so a disk fixture would exercise the wrong half of the system.

const testing = std.testing;
const Migration094CreateSkills = @import("../../../migrations/migration.zig").Migration094CreateSkills;

const TestCtx = struct {
    db: SqliteBackend,
    threaded: std.Io.Threaded,

    fn deinit(self: *TestCtx) void {
        // `threaded` must outlive `db` — the backend's Io lives inside it.
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration094CreateSkills.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Seed one row directly, bypassing the tools, so a test can set up a state the
/// tools cannot currently produce.
fn seedRow(
    alloc: std.mem.Allocator,
    ctx: *TestCtx,
    name: []const u8,
    description: []const u8,
    tags: []const u8,
    is_global: bool,
    cwd: []const u8,
) !void {
    const g_str = try std.fmt.allocPrint(alloc, "{d}", .{@intFromBool(is_global)});
    defer alloc.free(g_str);
    // The id must be unique per (name, is_global, cwd) — the twin test seeds
    // the same name in both branches and a name-derived id would collide.
    const id = try std.fmt.allocPrint(alloc, "seed_{s}_{d}_{s}", .{ name, @intFromBool(is_global), cwd });
    defer alloc.free(id);
    try ctx.db.exec(alloc,
        \\INSERT INTO skills (id, name, description, tags, content, is_global, cwd, created_at, updated_at)
        \\  VALUES (?, ?, COALESCE(?, ''), COALESCE(?, ''), 'body', ?, COALESCE(?, ''), datetime('now'), datetime('now'))
    , &.{ id, name, description, tags, g_str, cwd });
}

// ─── list_skills ───

test "toJson on empty lists parses to empty arrays and null cwd" {
    const alloc = testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.global_skills.len);
    try testing.expectEqual(@as(usize, 0), parsed.value.local_skills.len);
    try testing.expect(parsed.value.cwd == null);
}

test "toJson carries raw skill fields, parsed" {
    const alloc = testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{
            .{
                .name = "test <skill>",
                .description = "desc & more",
                .tags = "a||b",
                .path = "/path/with \"quotes\"",
            },
        },
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.global_skills.len);
    try testing.expectEqualStrings("test <skill>", parsed.value.global_skills[0].name);
    try testing.expectEqualStrings("desc & more", parsed.value.global_skills[0].description);
    try testing.expectEqualStrings("a||b", parsed.value.global_skills[0].tags);
    try testing.expectEqualStrings("/path/with \"quotes\"", parsed.value.global_skills[0].path);
}

test "toJson includes cwd when present, parsed" {
    const alloc = testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = "/test/cwd",
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("/test/cwd", parsed.value.cwd orelse "");
}

test "toJson generates valid JSON" {
    const alloc = testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    try testing.expect(std.mem.startsWith(u8, json, "{"));
    try testing.expect(std.mem.endsWith(u8, json, "}"));
    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.global_skills.len);
    try testing.expectEqual(@as(usize, 0), parsed.value.local_skills.len);
}

test "freeSkillsListData handles empty arrays" {
    const alloc = testing.allocator;
    freeSkillsListData(alloc, .{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    });
}

test "execute_list_skills - global rows land in global_skills" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    try seedRow(alloc, &ctx, "global-one", "Global description", "workflow||api", true, "");

    const output = try execute_list_skills(alloc, io, &ctx.db, null);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.global_skills.len);
    try testing.expectEqualStrings("global-one", parsed.value.global_skills[0].name);
    try testing.expectEqualStrings("Global description", parsed.value.global_skills[0].description);
    try testing.expectEqualStrings("workflow||api", parsed.value.global_skills[0].tags);
}

test "execute_list_skills - local row is scoped to its own workspace" {
    // The regression this pins: a local skill must not leak into another
    // workspace's listing. The old bug was the exec wrapper passing null for
    // cwd, so everything resolved against the server's own directory.
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const ws_a = try skills_db.canonicalCwd(alloc, io, "/tmp");
    defer alloc.free(ws_a);
    const ws_b = try skills_db.canonicalCwd(alloc, io, "/tmp/nalar-list-skills-different-cwd");
    defer alloc.free(ws_b);

    try seedRow(alloc, &ctx, "local-one", "Local description", "", false, ws_a);

    const seen = try execute_list_skills(alloc, io, &ctx.db, ws_a);
    defer alloc.free(seen);
    const seen_parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, seen, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer seen_parsed.deinit();
    try testing.expectEqual(@as(usize, 1), seen_parsed.value.local_skills.len);
    try testing.expectEqualStrings("local-one", seen_parsed.value.local_skills[0].name);
    try testing.expectEqualStrings(ws_a, seen_parsed.value.cwd orelse "");

    const unseen = try execute_list_skills(alloc, io, &ctx.db, ws_b);
    defer alloc.free(unseen);
    const unseen_parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, unseen, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer unseen_parsed.deinit();
    try testing.expectEqual(@as(usize, 0), unseen_parsed.value.local_skills.len);
}

test "execute_list_skills - a row with no tags and no source_path lists cleanly" {
    // The agent-created case: source_path is "" and tags is "". Both must
    // survive as empty strings rather than becoming NULL or vanishing.
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    try seedRow(alloc, &ctx, "no-meta", "", "", true, "");

    const output = try execute_list_skills(alloc, io, &ctx.db, null);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.global_skills.len);
    try testing.expectEqualStrings("", parsed.value.global_skills[0].tags);
    try testing.expectEqualStrings("", parsed.value.global_skills[0].path);
}

// ─── use_skill ───

test "use_skill_tool - has correct tool definition" {
    try testing.expectEqualStrings("use_skill", use_skill_tool.function.name);
    // skill_name + is_global
    try testing.expectEqual(@as(usize, 2), use_skill_tool.function.parameters.properties.len);
}

test "use_skill_tool - requires skill_name, and does NOT accept path" {
    // The whole point of the migration: `path` is gone. A model still sending
    // it gets a validation error naming skill_name, which self-heals in one
    // turn. Pinning it here means nobody quietly re-adds a shim.
    try testing.expectEqual(@as(usize, 1), use_skill_tool.function.parameters.required.len);
    try testing.expectEqualStrings("skill_name", use_skill_tool.function.parameters.required[0]);

    for (use_skill_tool.function.parameters.properties) |prop| {
        try testing.expect(!std.mem.eql(u8, prop.name, "path"));
    }
}

test "use_skill_tool - schema declares is_global property as boolean" {
    var found_is_global = false;
    for (use_skill_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "is_global")) {
            found_is_global = true;
            try testing.expectEqualStrings("boolean", prop.type);
            break;
        }
    }
    try testing.expect(found_is_global);
}

test "UseSkillInput - has correct defaults" {
    const input = UseSkillInput{};
    try testing.expect(input.skill_name == null);
    try testing.expect(input.is_global == null);
}

test "UseSkillResult - has correct struct fields" {
    const result = UseSkillResult{
        .skill_name = "test",
        .content = "Test content",
        .loaded = true,
    };
    try testing.expectEqualStrings("test", result.skill_name);
    try testing.expectEqualStrings("Test content", result.content);
    try testing.expect(result.loaded == true);
}

test "use_skill - missing skill_name returns a JSON error naming skill_name" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = try execute_use_skill_to_string(alloc, io, &ctx.db, .{});
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(!parsed.value.loaded);
    // Self-healing contract: the message must tell the model what to send.
    try testing.expect(contains(parsed.value.@"error" orelse "", "skill_name"));
}

test "use_skill - loads a global row by name" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    try seedRow(alloc, &ctx, "loadable", "d", "", true, "");

    const output = try execute_use_skill_to_string(alloc, io, &ctx.db, .{ .skill_name = "loadable" });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(parsed.value.loaded);
    try testing.expectEqualStrings("loadable", parsed.value.skill_name);
    try testing.expectEqualStrings("body", parsed.value.content);
    try testing.expect(parsed.value.@"error" == null);
}

test "use_skill - unknown name errors and does not fall back to a path read" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = try execute_use_skill_to_string(alloc, io, &ctx.db, .{ .skill_name = "nope" });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(!parsed.value.loaded);
    try testing.expect(contains(parsed.value.@"error" orelse "", "nope"));
    try testing.expect(contains(parsed.value.@"error" orelse "", "list_skills"));
}

test "use_skill - oversized row is refused instead of flooding the context" {
    // The filesystem era capped only the LISTING at 100 KB and let use_skill
    // read unbounded. A row can be just as large, so the cap applies on load.
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const big = try alloc.alloc(u8, MAX_SKILL_BYTES + 1);
    defer alloc.free(big);
    @memset(big, 'x');

    try ctx.db.exec(alloc,
        \\INSERT INTO skills (id, name, content, is_global) VALUES (?, ?, ?, 1)
    , &.{ "big", "too-big", big });

    const output = try execute_use_skill_to_string(alloc, io, &ctx.db, .{ .skill_name = "too-big" });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(!parsed.value.loaded);
    try testing.expect(contains(parsed.value.@"error" orelse "", "limit"));
}

// ─── add_skill ───

test "add_skill - empty name returns error" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = executeAddSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .name = "",
        .description = "Test description",
        .content = "Test content",
    });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(!parsed.value.created);
    try testing.expectEqualStrings("Skill name cannot be empty", parsed.value.@"error" orelse "");
}

test "add_skill - empty description returns error" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = executeAddSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .name = "test-skill",
        .description = "",
        .content = "Test content",
    });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(!parsed.value.created);
    try testing.expectEqualStrings("Description cannot be empty", parsed.value.@"error" orelse "");
}

test "add_skill - empty content returns error" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = executeAddSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .name = "test-skill",
        .description = "Test description",
        .content = "",
    });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(!parsed.value.created);
    try testing.expectEqualStrings("Content cannot be empty", parsed.value.@"error" orelse "");
}

test "add_skill - tool definition includes is_global parameter" {
    var found = false;
    inline for (add_skill_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "is_global")) {
            found = true;
            try testing.expect(std.mem.eql(u8, prop.type, "boolean"));
        }
    }
    try testing.expect(found);
}

test "add_skill - tool definition has correct required fields" {
    const required = add_skill_tool.function.parameters.required;
    try testing.expectEqual(@as(usize, 3), required.len);
    try testing.expectEqualStrings("name", required[0]);
    try testing.expectEqualStrings("description", required[1]);
    try testing.expectEqualStrings("content", required[2]);
}

test "add_skill - tags are normalised to the '||' form and stored" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = executeAddSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .name = "tagged",
        .description = "has tags",
        .content = "# body",
        .tags = "workflow, api ,agent",
        .is_global = true,
    });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(parsed.value.created);

    const row = (try skills_db.getSkill(alloc, &ctx.db, "tagged", true, "")).?;
    defer skills_db.freeSkillRow(alloc, row);
    try testing.expectEqualStrings("workflow||api||agent", row.tags);
}

test "add_skill - empty tags persist as '' and do not become NULL" {
    // The empty-slice-binds-as-NULL trap. `tags` is the field most likely to
    // be written empty, since most skills carry no tags line.
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = executeAddSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .name = "untagged",
        .description = "no tags",
        .content = "# body",
        .is_global = true,
    });
    defer alloc.free(output);
    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(parsed.value.created);

    const row = (try skills_db.getSkill(alloc, &ctx.db, "untagged", true, "")).?;
    defer skills_db.freeSkillRow(alloc, row);
    try testing.expectEqualStrings("", row.tags);
}

test "add_skill - re-running with the same name OVERWRITES rather than appending" {
    // add_skill has always been truncating-on-purpose: the LLM refines a skill
    // by re-running it. The row write must replace, never duplicate.
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const first = executeAddSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .name = "refined",
        .description = "First version description",
        .content = "# v1\n\nA long original body.",
        .is_global = true,
    });
    defer alloc.free(first);
    const first_parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, first, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer first_parsed.deinit();
    try testing.expect(first_parsed.value.created);

    const second = executeAddSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .name = "refined",
        .description = "Second desc",
        .content = "v2",
        .is_global = true,
    });
    defer alloc.free(second);
    const second_parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, second, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer second_parsed.deinit();
    try testing.expect(second_parsed.value.created);

    const rows = try skills_db.listSkills(alloc, &ctx.db, true, null);
    defer skills_db.freeSkillRows(alloc, rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Second desc", rows[0].description);
    try testing.expectEqualStrings("v2", rows[0].content);
}

test "add_skill - mirrors SKILL.MD with a tags: line" {
    // The mirror round-trip. Without a `tags:` line the next import silently
    // drops the tags — the one part of this feature that fails without an
    // error, so it gets its own test.
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const root = try alloc.dupe(u8, "/tmp/nalar-skill-mirror-test");
    defer alloc.free(root);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const output = executeAddSkillToString(alloc, io, &ctx.db, root, null, .{
        .name = "mirrored",
        .description = "Mirror round-trip",
        .content = "# body",
        .tags = "alpha,beta",
    });
    defer alloc.free(output);
    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(parsed.value.created);

    const file = try std.fs.path.join(alloc, &.{ root, ".nalar", "skills", "mirrored", "SKILL.MD" });
    defer alloc.free(file);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, file, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(content);

    try testing.expect(contains(content, "name: mirrored"));
    try testing.expect(contains(content, "Mirror round-trip"));
    // The load-bearing assertion.
    try testing.expect(contains(content, "tags:"));

    // And the mirrored file parses back to the same tags the row holds.
    const fm = skills.parseYamlFrontmatter(alloc, content).?;
    defer skills.freeParsedFrontmatter(alloc, fm);
    try testing.expectEqualStrings("alpha||beta", fm.tags);
}

test "buildSkillContent escapes special characters and always emits tags" {
    const alloc = testing.allocator;

    const content = buildSkillContent(alloc, .{
        .name = "test-skill",
        .description = "Test \"description\" with quotes",
        .content = "Test content with\\backslash",
        .tags = "one",
    }, "one");
    defer alloc.free(content);

    try testing.expect(contains(content, "name: test-skill"));
    try testing.expect(contains(content, "description: \"Test \\\"description\\\" with quotes\""));
    try testing.expect(contains(content, "tags: [one]"));
}

test "normalizeTags accepts bracketed, bare, and already-joined forms" {
    const alloc = testing.allocator;

    const cases = [_][2][]const u8{
        .{ "[a, b]", "a||b" },
        .{ "a, b", "a||b" },
        .{ "a||b", "a||b" },
        .{ "  a ,  b  ", "a||b" },
        .{ "single", "single" },
        .{ "", "" },
        .{ "[]", "" },
    };

    for (cases) |case| {
        const got = try skills_db.normalizeTags(alloc, case[0]);
        defer alloc.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
}

// ─── edit_skill ───

test "edit_skill - empty skill_name returns error" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = try executeEditSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .skill_name = "",
        .description = "New description",
    });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(!parsed.value.updated);
    try testing.expectEqualStrings("Skill name cannot be empty", parsed.value.@"error" orelse "");
}

test "edit_skill - nothing to change returns error" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = try executeEditSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .skill_name = "test-skill",
    });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(!parsed.value.updated);
    try testing.expect(contains(parsed.value.@"error" orelse "", "At least one of"));
}

test "edit_skill - unknown skill returns an error, not a silent no-op" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = try executeEditSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .skill_name = "ghost",
        .description = "d",
    });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(!parsed.value.updated);
    try testing.expectEqualStrings("Skill not found", parsed.value.@"error" orelse "");
}

test "edit_skill - updates description, tags and content" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    try seedRow(alloc, &ctx, "editable", "Old description", "old", true, "");

    const output = try executeEditSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .skill_name = "editable",
        .is_global = true,
        .description = "New description",
        .tags = "new1, new2",
        .content = "new body",
    });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(parsed.value.updated);

    const row = (try skills_db.getSkill(alloc, &ctx.db, "editable", true, "")).?;
    defer skills_db.freeSkillRow(alloc, row);
    try testing.expectEqualStrings("New description", row.description);
    try testing.expectEqualStrings("new1||new2", row.tags);
    try testing.expectEqualStrings("new body", row.content);
}

test "edit_skill - omitted fields keep their existing values" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    try seedRow(alloc, &ctx, "partial", "Keep this description", "keep", true, "");

    const output = try executeEditSkillToString(alloc, io, &ctx.db, "/tmp", null, .{
        .skill_name = "partial",
        .is_global = true,
        .content = "replaced body",
    });
    defer alloc.free(output);

    const row = (try skills_db.getSkill(alloc, &ctx.db, "partial", true, "")).?;
    defer skills_db.freeSkillRow(alloc, row);
    try testing.expectEqualStrings("Keep this description", row.description);
    try testing.expectEqualStrings("keep", row.tags);
    try testing.expectEqualStrings("replaced body", row.content);
}

// ─── remove_skill ───

test "remove_skill - empty skill_name returns error" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = try execute_remove_skill_to_string(alloc, io, &ctx.db, "/tmp", null, .{
        .skill_name = "",
        .session_id = "test-session",
    });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(RemoveSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(!parsed.value.removed);
    try testing.expectEqualStrings("skill_name cannot be empty", parsed.value.@"error" orelse "");
}

test "remove_skill - deletes the row" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    try seedRow(alloc, &ctx, "doomed", "d", "", true, "");

    const output = try execute_remove_skill_to_string(alloc, io, &ctx.db, "/tmp", null, .{
        .skill_name = "doomed",
        .session_id = "s1",
        .is_global = true,
    });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(RemoveSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(parsed.value.removed);
    try testing.expect((try skills_db.getSkill(alloc, &ctx.db, "doomed", true, "")) == null);
}

test "remove_skill - unknown skill reports not found" {
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const output = try execute_remove_skill_to_string(alloc, io, &ctx.db, "/tmp", null, .{
        .skill_name = "ghost",
        .session_id = "s1",
        .is_global = true,
    });
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(RemoveSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(!parsed.value.removed);
    try testing.expectEqualStrings("Skill not found", parsed.value.@"error" orelse "");
}

test "remove_skill - a global delete does not touch the same-named local row" {
    // Two partial unique indexes, two rows. Deleting one must not take the
    // other with it.
    const alloc = testing.allocator;
    const io = testing.io;
    var ctx = try setupDb();
    defer ctx.deinit();

    const ws = try skills_db.canonicalCwd(alloc, io, "/tmp");
    defer alloc.free(ws);
    try seedRow(alloc, &ctx, "twin", "global one", "", true, "");
    try seedRow(alloc, &ctx, "twin", "local one", "", false, ws);

    const output = try execute_remove_skill_to_string(alloc, io, &ctx.db, ws, null, .{
        .skill_name = "twin",
        .session_id = "s1",
        .is_global = true,
    });
    defer alloc.free(output);
    const parsed = try std.json.parseFromSlice(RemoveSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(parsed.value.removed);

    try testing.expect((try skills_db.getSkill(alloc, &ctx.db, "twin", true, "")) == null);
    const survivor = (try skills_db.getSkill(alloc, &ctx.db, "twin", false, ws)).?;
    defer skills_db.freeSkillRow(alloc, survivor);
    try testing.expectEqualStrings("local one", survivor.description);
}
