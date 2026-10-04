//! Skill agent tools: `search_skills` + `use_skill` + `remove_skill` +
//! `add_skill` + `edit_skill`.
//!
//! Merged from the five `*_skill*.zig` tool modules (2026-09-11
//! skills-merge refactor) — one file, five tools. The public surface is
//! unchanged: every `*Input` struct, `*_tool` definition,
//! `execute_*` entry point, and the `listAllSkills` / `freeSkillsListData`
//! / `toJson` helper shared with the HTTP layer keeps its
//! names. Only colliding private helpers gained per-tool prefixes
//! (`addSkill*` / `editSkill*` / `removeSkill*`); the two identical
//! `contains` test helpers were deduplicated to one. Every tool result
//! is a JSON object built with `std.json.Stringify.valueAlloc`.
//!
//! Note: `skills.zig` next to this file is the storage/filesystem layer
//! (imported here as `skills`), not a tool definition.

const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");
const helpers = @import("helpers");

// Helper to check if string contains substring (shared by the list/use skill tests)
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── search_skills ───

/// Shared data structure for the raw per-tier skill listing. Shared by the
/// HTTP `/skills` handler and by `search_skills`, which flattens the tiers
/// into scope-tagged rows before matching.
pub const SkillsListData = struct {
    global_skills: []const skills.SkillInfo,
    local_skills: []const skills.SkillInfo,
    cwd: ?[]const u8,
};

/// Input for `search_skills`. Every field is optional: no args returns the
/// first page of every installed skill. `query` is a regex unless `literal`
/// is set — the same matching-mode contract as the `search` and `search_tool`
/// agent tools. `limit`/`offset` page the matches so a large skill library
/// cannot flood the context window, and `scope` narrows to one tier
/// (omitted = every tier, because discovery is legitimately multi-tier).
pub const SearchSkillsInput = struct {
    query: ?[]const u8 = null,
    literal: ?bool = null,
    scope: ?[]const u8 = null,
    limit: ?i64 = null,
    offset: ?i64 = null,
    /// Overrides the session cwd for the local tier. Optional; the exec
    /// adapter supplies `ctx.cwd` when the model omits it.
    cwd: ?[]const u8 = null,
};

pub const search_skills_tool_system_prompt =
    \\## Search Skills Tool — Behavior
    \\Use `search_skills` to find installed skills by name or description (global + local tiers).
    \\- `query` is a REGEX (case-insensitive, unanchored) matched against each skill's name AND description. A pattern finds skills a phrase cannot: `doc|documentation`, `^zig`, `\btest\`. A query with no metacharacters still behaves as a plain substring search.
    \\- Set `literal: true` when the query is literal text (e.g. `*.zig`, `fn(`) — otherwise its metacharacters are interpreted.
    \\- Results are PAGED: `limit` (default 40, max 200) caps how many rows you get back, `total` is the real match count, and `offset` skips matches. The `hint` names the exact next offset instead of dumping the whole library into your context.
    \\- An invalid pattern is not a failure: it is matched as a literal substring and the result carries `pattern_warning` listing the supported syntax. Read it instead of retrying blindly.
    \\- `scope` narrows to ONE tier (`global` = `~/.config/pabrik/skills/`, `local` = `<cwd>/.pabrik/skills/`). Omit it to search both. Every row carries its own `scope`.
    \\- Omitting `query` is a valid discovery call — it returns the first page of everything installed.
    \\- Match on the `name`/`description`, then call `use_skill` with that row's EXACT `path`.
    \\
;

pub const search_skills_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "search_skills",
        .description =
        \\Search the installed skills (global + local tiers) by name or description. `query` is a case-insensitive REGEX matched against each skill's name AND description, so one pattern reaches a skill spelled several ways (`doc|documentation`, `^zig`, `\btest\`, `(save|load)_memory`); pass `literal: true` when the query is literal text. Results are PAGED — `limit` (default 40) caps the rows returned, `total` is the real match count, and `offset` continues the listing — so a big skill library never floods your context. Every row carries its `scope` and the exact `path` to pass to use_skill. Omit `query` to page through everything installed; pass `scope` to search one tier only.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "query",
                    .type = "string",
                    .description = "Regex, matched case-insensitively against every installed skill's name and description. A pattern finds skills a phrase cannot: 'doc|documentation' = either spelling in one call, '^zig' = the zig-prefixed ones, '\\btest\\b' = the word without matching 'testify'. Supported: literals, '.', '[...]', '\\d \\w \\s \\b', '*', '+', '?', '{m,n}' ranges, '( )' groups, '|', '^', '$'. A metacharacter-free query is still a plain substring search. An invalid pattern is matched as a literal substring instead and the result says so in pattern_warning. Omit to list the start of the library.",
                },
                .{
                    .name = "literal",
                    .type = "boolean",
                    .description = "Treat `query` as a literal string — regex metacharacters like '.', '*', '[', '(' are matched verbatim. Set this for code-shaped queries ('*.zig', 'fn('). Default false (regex mode).",
                },
                .{
                    .name = "scope",
                    .type = "string",
                    .description = "Optional tier filter: 'global' (~/.config/pabrik/skills/) or 'local' (<cwd>/.pabrik/skills/). Omit to search BOTH tiers. Every result row carries its own `scope`.",
                },
                .{
                    .name = "limit",
                    .type = "number",
                    .description = "Maximum matches in THIS response (default 40, max 200). Results are paged to keep the context window small. The result always reports the true `total` — raise limit, or page with offset, only when you need more.",
                },
                .{
                    .name = "offset",
                    .type = "number",
                    .description = "Skip the first N matches, for paging a broad query (default 0). The previous page's `hint` names the exact offset that continues it.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Absolute working directory the local tier is resolved from. Optional — the session's own working directory is used when omitted.",
                },
            },
            .required = &.{},
        },
        .system_prompt = search_skills_tool_system_prompt,
    },
};

/// List all skills (global + local) and return the data structure
/// Caller owns the returned memory and must free it with freeSkillsListData()
pub fn listAllSkills(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd_param: ?[]const u8,
    environment: ?*const std.process.Environ.Map,
) !SkillsListData {
    // Get global skills path (from environment map - REQUIRED)
    if (environment == null) {
        return error.MissingEnvironment;
    }
    const global_path = skills.get_global_skills_path_from_env(allocator, environment.?);
    defer if (global_path) |p| allocator.free(p);

    // Get local skills path (from cwd or current directory)
    const local_path: ?[]const u8 = if (cwd_param) |cwd|
        skills.get_local_skills_path_for_dir(allocator, cwd)
    else
        skills.get_local_skills_path_from_io(allocator, io);
    defer if (local_path) |p| allocator.free(p);

    // List global skills
    var global_skills: []skills.SkillInfo = &[_]skills.SkillInfo{};
    if (global_path) |path| {
        global_skills = skills.list_skills_from_dir_path(allocator, io, path);
    }

    // List local skills
    var local_skills: []skills.SkillInfo = &[_]skills.SkillInfo{};
    if (local_path) |path| {
        local_skills = skills.list_skills_from_dir_path(allocator, io, path);
    }

    return SkillsListData{
        .global_skills = global_skills,
        .local_skills = local_skills,
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

/// Parsed shape of `toJson`'s output, for tests.
pub const SkillsListDataJson = struct {
    global_skills: []skills.SkillInfo,
    local_skills: []skills.SkillInfo,
    cwd: ?[]const u8 = null,
};

// ─── use_skill ───

/// Input structure for use_skill tool
pub const UseSkillInput = struct {
    /// Load skill from file path. Accepts both absolute paths and relative
    /// paths (resolved against the session's current working directory).
    path: ?[]const u8 = null,
    /// Reserved for forward compatibility — currently has no effect because
    /// the only code path is `loadSkillFromPath`, which reads the file as-is.
    is_global: bool = false,
};

/// Result structure for use_skill tool
pub const UseSkillResult = struct {
    skill_name: []const u8,
    content: []const u8,
    loaded: bool,
    path: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

/// Tool definition for use_skill
pub const use_skill_tool_system_prompt =
    \\## Use Skill Tool — Behavior
    \\Use `use_skill` to load a skill's full instructions by exact file path (from `search_skills`).
    \\- The path is case-sensitive and ends in `SKILL.MD` — don't construct it from the name. Pass it verbatim.
    \\
;

pub const use_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "use_skill",
        .description = "Load a skill's full content from a file path. Use this when you need detailed guidance for a specific capability. Pass the file path (absolute or relative to the session's current working directory) via the `path` argument.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Load skill from file path. Accepts both absolute paths (e.g. /home/user/skill.md) and relative paths (resolved against the session's current working directory).",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "Reserved. Currently has no effect; the file is always loaded as-is from `path`.",
                },
            },
            .required = &.{ "path", "is_global" },
        },
        .system_prompt = use_skill_tool_system_prompt,
    },
};

/// JSON payload for use_skill results.
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

/// Execute the use_skill tool
/// Returns a JSON string with the skill content or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_use_skill_to_string(allocator: std.mem.Allocator, io: std.Io, input: UseSkillInput, environment: ?*const std.process.Environ.Map) ![]const u8 {
    _ = environment; // kept for signature compatibility; not used by the path-only code path
    const path = input.path orelse return error.InvalidInput;
    return loadSkillFromPath(allocator, io, path);
}

/// Load skill from a file path. Accepts both absolute and relative paths —
/// relative paths are resolved against the io's current working directory.
///
/// NOTE: this used to call `std.Io.Dir.openFileAbsolute` which has the
/// precondition `assert(path.isAbsolute(absolute_path))`. In debug builds
/// a non-absolute path triggered `unreachable`, killing the entire worker
/// process and bypassing every catch/try in the call chain
/// (see docs/plans/2025-01-15-get-skill-relative-path-panic.md). We now
/// use `cwd().openFile` which handles both cases — `openFileAbsolute` is
/// literally `openFile(.cwd(), ...)` + that assert.
fn loadSkillFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to open file \"{s}\": {s}", .{ path, @errorName(err) });
        defer allocator.free(msg);
        return try useSkillJsonError(allocator, "", msg);
    };
    defer std.Io.File.close(file, io);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(std.math.maxInt(usize))) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to read file \"{s}\": {s}", .{ path, @errorName(err) });
        defer allocator.free(msg);
        return try useSkillJsonError(allocator, "", msg);
    };
    defer allocator.free(content);

    // Extract skill_name: prefer the YAML frontmatter `name:` field;
    // fall back to the file basename (without extension) for files that
    // don't use the frontmatter convention. In both branches we own the
    // returned slice and free it after the JSON result is built.
    const skill_name: []const u8 = blk: {
        const filename = std.fs.path.basename(path);
        const ext = std.fs.path.extension(filename);
        const basename = filename[0 .. filename.len - ext.len];

        if (skills.parseYamlFrontmatter(allocator, content)) |fm| {
            defer allocator.free(fm.description);
            // Take ownership of fm.name; the defer below frees it after
            // Stringify copies the bytes into the result.
            break :blk fm.name;
        }
        // basename points into `content` (freed below); dupe to give it
        // the same lifetime as the frontmatter branch.
        break :blk try allocator.dupe(u8, basename);
    };
    defer allocator.free(skill_name);

    const clean_name = try helpers.sanitize_control_chars(allocator, skill_name);
    defer allocator.free(clean_name);
    const clean_content = try helpers.sanitize_control_chars(allocator, content);
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

/// Input structure for remove_skill tool. `session_id` is unused and
/// defaulted so a model that omits it (the common case — it is not
/// something the tool needs) does not get `error.MissingField`.
pub const RemoveSkillInput = struct {
    skill_name: []const u8,
    session_id: []const u8 = "",
    /// If true, remove from global skills directory (~/.config/pabrik/skills/)
    /// If false, remove from local skills directory (.pabrik/skills/)
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
    \\Use `remove_skill` to permanently delete a skill file.
    \\- Provide `skill_name` and `session_id`. Use only when the skill is obsolete or the user asks to remove it.
    \\
;

/// Actionable `remove_skill` failure. Exposed for tests.
pub const REMOVE_SKILL_BAD_NAME =
    "remove_skill: `skill_name` must be a single directory name — letters, digits, dots, dashes, underscores; no slashes, spaces, or leading/trailing dot. It is joined onto the skills directory, so a path would delete outside it. Got: '";

pub const remove_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "remove_skill",
        .description = "Remove a skill from the current session AND delete the skill file from .pabrik/skills/. Use this to permanently delete a skill.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact name of the skill to remove and delete",
                },
                .{
                    .name = "session_id",
                    .type = "string",
                    .description = "The session ID (unused, kept for compatibility)",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "If true, remove from global skills directory (~/.config/pabrik/skills/). If false, remove from local directory (.pabrik/skills/). Default: false",
                },
            },
            .required = &.{ "skill_name", "session_id" },
        },
        .system_prompt = remove_skill_tool_system_prompt,
    },
};

/// Execute the remove_skill tool - removes from session AND deletes file
/// Deletes skill file at .pabrik/skills/<skill_name>/ or global ~/.config/pabrik/skills/<skill_name>/
/// Returns a JSON string with the result
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_remove_skill_to_string(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    environment: ?*const std.process.Environ.Map,
    input: RemoveSkillInput,
) ![]const u8 {
    // Validate input
    if (input.skill_name.len == 0) {
        return removeSkillJsonError(allocator, "", "skill_name cannot be empty");
    }
    // Same traversal guard as add_skill/edit_skill: `skill_dir_path` is
    // built by joining this onto the skills directory.
    if (!isValidSkillName(input.skill_name)) {
        const msg = std.fmt.allocPrint(allocator, "{s}{s}'", .{ REMOVE_SKILL_BAD_NAME, input.skill_name }) catch {
            return removeSkillJsonError(allocator, input.skill_name, REMOVE_SKILL_BAD_NAME);
        };
        defer allocator.free(msg);
        return removeSkillJsonError(allocator, input.skill_name, msg);
    }

    // A relative session `cwd` used to resolve against the PROCESS cwd,
    // so remove_skill silently deleted from the wrong place — see
    // `absolutizeCwd`.
    const abs_cwd = try absolutizeCwd(allocator, cwd);
    defer allocator.free(abs_cwd);

    // Determine skills directory based on is_global flag
    const skills_dir: []const u8 = if (input.is_global) blk: {
        if (environment) |env| {
            const path = skills.get_global_skills_path_from_env(allocator, env) orelse {
                return removeSkillJsonError(allocator, input.skill_name, "Failed to get global skills path");
            };
            break :blk path;
        } else {
            return removeSkillJsonError(allocator, input.skill_name, "Environment not available for global skills");
        }
    } else try std.fs.path.join(allocator, &[_][]const u8{ abs_cwd, ".pabrik", "skills" });

    // Build path to skill directory
    // Duplicate skill_name to ensure no aliasing with path.join's internal buffer allocation
    const skill_name_copy = try allocator.dupe(u8, input.skill_name);
    errdefer allocator.free(skill_name_copy);

    const skill_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ skills_dir, skill_name_copy });
    // skill_name_copy is no longer needed after path.join copies it
    allocator.free(skill_name_copy);

    // Check if the skill directory exists
    const dir_exists = blk: {
        std.Io.Dir.cwd().access(io, skill_dir_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!dir_exists) {
        // Skill directory doesn't exist - might be a built-in skill or already removed
        const out = removeSkillJsonError(allocator, input.skill_name, "Skill directory not found");

        if (input.is_global) allocator.free(skills_dir);
        allocator.free(skill_dir_path);
        return out;
    }

    // Delete the skill directory recursively
    std.Io.Dir.cwd().deleteTree(io, skill_dir_path) catch {
        const out = removeSkillJsonError(allocator, input.skill_name, "Failed to delete skill directory");

        if (input.is_global) allocator.free(skills_dir);
        allocator.free(skill_dir_path);
        return out;
    };

    // Return success
    const out = removeSkillJsonSuccess(allocator, input.skill_name, skill_dir_path);

    // Clean up allocated memory
    if (input.is_global) allocator.free(skills_dir);
    allocator.free(skill_dir_path);

    return out;
}

/// Generate error JSON response for parse failures (no name available)
pub fn removeSkillJsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return removeSkillJsonError(allocator, "", error_msg);
}

// ─── shared argument resolution ────────────────────────────────────────
//
// `add_skill` / `edit_skill` / `remove_skill` are the only tools a model
// calls with hand-written prose, and the two mistakes it makes most are
// both handled here rather than at the parse site:
//
//   (a) omitting a required argument. That used to surface as
//       `error.MissingField` — an error NAME that names no field — so
//       the model had nothing to correct itself from and retried.
//   (b) pasting YAML frontmatter into `content`, because every example of
//       "the skill format" shows a `---` block. `buildSkillContent`
//       ALWAYS prepends its own frontmatter, so (b) wrote the block
//       twice: the model's copy became body text, `parseSkillFile` kept
//       it there, and every later `edit_skill` preserved the duplicate.

/// A leading `---` … `---` frontmatter block split off `content`. Both
/// slices point into the input; nothing is allocated.
const FrontmatterSplit = struct {
    /// The text between the fences (no fences), or "" when `content` did
    /// not open with a frontmatter block.
    frontmatter: []const u8,
    /// Everything after the closing fence — the whole input when there
    /// was no frontmatter block.
    body: []const u8,
};

/// Split a leading YAML frontmatter block off `content`.
///
/// The closing fence must start a line and may be followed by `\r`, `\n`,
/// both, or nothing at all (a model that trimmed the final newline is not
/// a reason to write the block twice). A `---` inside the body is only
/// reached when the block is unterminated, which is treated as no
/// frontmatter rather than a guess.
fn splitLeadingFrontmatter(content: []const u8) FrontmatterSplit {
    const none: FrontmatterSplit = .{ .frontmatter = "", .body = content };
    if (!std.mem.startsWith(u8, content, "---\n")) return none;

    const rest = content["---\n".len..];
    var idx: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rest, idx, '-')) |i| {
        idx = i + 1;
        if (i != 0 and rest[i - 1] != '\n') continue;
        if (!std.mem.startsWith(u8, rest[i..], "---")) continue;

        var end = i + 3;
        if (end < rest.len and rest[end] == '\r') end += 1;
        if (end < rest.len and rest[end] == '\n') end += 1;
        // `---x` is not a closing fence; only EOF / `\n` / `\r\n` is.
        if (end != rest.len and end != i + 4 and end != i + 5) continue;

        return .{ .frontmatter = rest[0..i], .body = rest[end..] };
    }
    return none;
}

/// Read `key: value` out of a frontmatter block. Borrowed, trimmed, with
/// one layer of matching quotes removed. Null when the key is absent or
/// its value is empty. Deliberately not `skills.parseYamlFrontmatter` —
/// that allocates and returns null unless BOTH `name` and `description`
/// are present, and here each is wanted independently.
fn frontmatterField(frontmatter: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const after = trimmed[key.len..];
        // Guards `name` matching a `names:` line.
        if (after.len == 0 or after[0] != ':') continue;

        var value = std.mem.trim(u8, after[1..], " \t\r");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        } else if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
            value = value[1 .. value.len - 1];
        }
        if (value.len == 0) return null;
        return value;
    }
    return null;
}

/// The first of `args` that is not empty, else null. Borrowed.
fn firstNonEmpty(args: []const ?[]const u8) ?[]const u8 {
    for (args) |maybe| {
        const v = maybe orelse continue;
        if (v.len != 0) return v;
    }
    return null;
}

/// True when `name` is usable as a single directory name under the skills
/// folder. A separator, whitespace, a leading dot or a `..` segment is
/// rejected because `std.fs.path.join(skills_dir, name)` would then write
/// `<skills_dir>/<name>/SKILL.MD` OUTSIDE the skills directory — a path
/// traversal reachable straight from a tool argument. The frontmatter
/// `name:` is also what every later lookup keys on, so it has to be
/// stable and comparable.
fn isValidSkillName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (name[0] == '.' or name[name.len - 1] == '.') return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
            else => return false,
        }
    }
    return true;
}

/// Resolve a session `cwd` to an absolute path. Caller frees the result.
///
/// `insertWorker` persists the raw `cwd_session` without the `isAbsolute`
/// check the request path applies (src/http_handlers/session_create.zig:402
/// vs :237), so a RELATIVE cwd reaches every tool — and the skills tools
/// then refuse outright with "Skills directory must be an absolute path",
/// which turned a cosmetic input into a dead tool call.
///
/// `std.Io.Dir.cwd().realPath` is deliberately not used here: on Linux it
/// resolves the `AT_FDCWD` sentinel fd and ALWAYS fails with ENOENT (see
/// the note on `skills.get_skills_dir_path`), which is how every
/// project-local skill ended up unresolvable there. `helpers.getcwd` is
/// the portable spelling.
fn absolutizeCwd(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    if (cwd.len == 0) return error.CwdUnavailable;
    if (std.fs.path.isAbsolute(cwd)) return allocator.dupe(u8, cwd);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = helpers.getcwd(&buf) orelse return error.CwdUnavailable;
    // `path.join` treats every argument as one component, so a cwd with a
    // trailing separator does not produce a doubled one.
    return std.fs.path.join(allocator, &[_][]const u8{ base, cwd });
}

// ─── add_skill ───

/// Input structure for add_skill tool.
///
/// Every field carries a default, which makes it optional to
/// `std.json.parseFromSlice`. That is deliberate: with a non-defaulted
/// `name`/`description`/`content`, a model that omitted `description`
/// got `error.MissingField` back — an error name that names no field —
/// and had nothing to correct itself from. Empty is now a value that
/// reaches `executeAddSkillToString`, which reports WHICH argument is
/// missing and what to send. A model may also omit `description` and put
/// it in `content`'s frontmatter; that is lifted, not rejected.
pub const AddSkillInput = struct {
    /// Skill identifier. Required, but may be omitted when `content`
    /// opens with a `name:` frontmatter line.
    name: []const u8 = "",
    /// When to trigger this skill. Required, but may be omitted when
    /// `content` opens with a `description:` frontmatter line.
    description: []const u8 = "",
    /// Skill body. A leading `---` frontmatter block is stripped and its
    /// fields lifted; the body is what gets written after the generated
    /// frontmatter.
    content: []const u8 = "",
    /// Auto-create skills directory if needed (default: true)
    create_with_dir: bool = true,
    /// If true, save to global skills directory (~/.config/pabrik/skills/)
    /// If false, save to local skills directory (.pabrik/skills/)
    is_global: bool = false,
};

/// Tool definition for add_skill.
///
/// The `description` and the parameter docs below are the ONLY per-tool
/// text that reaches the model: `AgentTool.function.system_prompt` is
/// copied into the runtime tool struct (src/root.zig:865) and freed at
/// :884, and never read into any prompt — the one renderer that would
/// consume it (`appendToolListing`) has no call sites. So the guidance
/// has to live here, in the schema the model actually reads.
pub const add_skill_tool_system_prompt =
    \\## Add Skill Tool — Behavior
    \\Use `add_skill` to create a new reusable skill file.
    \\- Provide `name`, `description`, and markdown `content`. Use to capture a proven workflow for future sessions.
    \\- Check for existing skill with `search_skills` first to avoid duplicates.
    \\
;

pub const add_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "add_skill",
        .description =
        \\Create a new skill file in the skills directory. Use this when the user wants to save a workflow, pattern, or reusable instructions as a skill for future use.
        \\
        \\`name` and `description` are SEPARATE ARGUMENTS; `content` is the markdown BODY only. The `---` YAML frontmatter is generated from `name` + `description` — never paste one into `content`. (If you do, it is stripped and its fields lifted, so nothing breaks, but you lose the chance to be explicit about either field.)
        \\
        \\`description` decides whether any future session finds the skill at all: `search_skills` returns that one sentence and nothing else. Prefer local (`.pabrik/skills/`); pass `is_global: true` only when the procedure holds outside this repo.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "The skill's directory name, sent as its own argument. Kebab-case letters, digits, dots, dashes, underscores; no slashes, spaces or leading dot (it is joined onto the skills directory, so a path would write outside it). Example: 'zig-move-code-static-contract-path-pins'.",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "One sentence: what the skill does AND when to use it — trigger conditions, not a title. Example: \"Use when MOVING Zig code between files in this repo and a static-contract test breaks on the path.\"",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "The markdown BODY: `## When to Use`, `## Procedure`, `## Pitfalls`. Skip sections that do not apply. No `---` frontmatter block — it is generated.",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "true writes the shared ~/.config/pabrik/skills/ (every project); false (default) writes this project's <cwd>/.pabrik/skills/.",
                },
            },
            .required = &.{ "name", "description", "content" },
        },
        .system_prompt = add_skill_tool_system_prompt,
    },
};

/// Actionable `add_skill` failures. Each names the argument that is wrong
/// AND what to send, because a message the model cannot act on just
/// produces the same call again — which is what `"Description cannot be
/// empty"` did. Exposed for tests.
pub const ADD_SKILL_MISSING_NAME =
    "add_skill: `name` is required. Send the skill's directory name as its own argument — kebab-case, letters/digits/dots/dashes/underscores, no slashes or spaces (e.g. \"zig-move-code-static-contract-path-pins\"). It becomes the folder name AND the frontmatter `name:`. (A `name:` inside `content`'s frontmatter is read from there instead.)";
pub const ADD_SKILL_MISSING_DESCRIPTION =
    "add_skill: `description` is required. Send it as its own argument: ONE sentence saying what the skill does AND when to use it — it is the only text `search_skills` returns, so a title or a restatement of `name` makes the skill undiscoverable. (A `description:` inside `content`'s frontmatter is read from there instead.)";
pub const ADD_SKILL_MISSING_CONTENT =
    "add_skill: `content` is empty. Send the markdown BODY — `## When to Use` (when it should load), `## Procedure` (atomic steps, exact commands, how to verify), `## Pitfalls` (failure modes you actually hit). A frontmatter block alone leaves nothing for the skill to teach; frontmatter is generated from `name` + `description`.";
pub const ADD_SKILL_BAD_NAME =
    "add_skill: `name` must be a single directory name — letters, digits, dots, dashes, underscores; no slashes, spaces, or leading/trailing dot. It is joined onto the skills directory, so a path would write outside it. Got: '";
pub const ADD_SKILL_CWD_UNRESOLVED =
    "add_skill: this session's working directory is relative and could not be absolutized, so the skills directory is unknown. Retry with is_global: true to write to the global skills folder instead.";

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

/// Execute the add_skill tool
/// Creates a new skill file at .pabrik/skills/<name>/SKILL.MD or global ~/.config/pabrik/skills/<name>/SKILL.MD
/// Returns a JSON string with the result or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeAddSkillToString(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, environment: ?*const std.process.Environ.Map, input: AddSkillInput) []const u8 {
    // `SkillWriteToolRule` shows the skill format as a `---` frontmatter
    // block, so models routinely paste one into `content`. Lift it out
    // instead of writing it twice: `buildSkillContent` ALWAYS prepends its
    // own frontmatter, so a frontmatter-carrying `content` used to produce
    // a file with two blocks — and `parseSkillFile` then read the second
    // as body text, which every later `edit_skill` preserved.
    const split = splitLeadingFrontmatter(input.content);
    const fm: ?[]const u8 = if (split.frontmatter.len != 0) split.frontmatter else null;

    const name = firstNonEmpty(&.{ input.name, if (fm) |f| frontmatterField(f, "name") else null });
    const description = firstNonEmpty(&.{ input.description, if (fm) |f| frontmatterField(f, "description") else null });
    // The body is what gets written; the lifted frontmatter is regenerated
    // from `name` + `description` by `buildSkillContent`.
    const content = split.body;

    // Every message names the argument AND what to send, because the old
    // ones ("Description cannot be empty") told the model nothing and it
    // retried the identical call.
    const resolved_name = name orelse {
        return addSkillJsonError(allocator, "", ADD_SKILL_MISSING_NAME);
    };
    if (description == null) {
        return addSkillJsonError(allocator, resolved_name, ADD_SKILL_MISSING_DESCRIPTION);
    }
    if (content.len == 0) {
        return addSkillJsonError(allocator, resolved_name, ADD_SKILL_MISSING_CONTENT);
    }
    if (!isValidSkillName(resolved_name)) {
        const msg = std.fmt.allocPrint(allocator, "{s}{s}", .{ ADD_SKILL_BAD_NAME, resolved_name }) catch {
            return addSkillJsonError(allocator, "", ADD_SKILL_BAD_NAME);
        };
        defer allocator.free(msg);
        return addSkillJsonError(allocator, "", msg);
    }
    const resolved: AddSkillInput = .{
        .name = resolved_name,
        .description = description.?,
        .content = content,
        .create_with_dir = input.create_with_dir,
        .is_global = input.is_global,
    };

    // A relative session `cwd` used to fail the whole call here. Resolve it
    // against the process cwd first — see `absolutizeCwd`.
    const abs_cwd = absolutizeCwd(allocator, cwd) catch {
        // Built inline rather than via a `const` + `defer free` dance: the
        // literal fallback below is static memory and must not be freed.
        const detail = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
            ADD_SKILL_CWD_UNRESOLVED,
            cwd,
            ". Give the session an absolute working directory, or set is_global: true to write to the global skills folder.",
        });
        return addSkillJsonError(allocator, resolved_name, detail catch ADD_SKILL_CWD_UNRESOLVED);
    };
    defer allocator.free(abs_cwd);

    // Determine skills directory based on is_global flag
    const skills_dir: []const u8 = if (resolved.is_global) blk: {
        if (environment) |env| {
            const path = skills.get_global_skills_path_from_env(allocator, env) orelse {
                return addSkillJsonError(allocator, resolved_name, "Failed to get global skills path");
            };
            break :blk path;
        } else {
            return addSkillJsonError(allocator, resolved_name, "Environment not available for global skills");
        }
    } else std.fs.path.join(allocator, &[_][]const u8{ abs_cwd, ".pabrik", "skills" }) catch {
        return addSkillJsonError(allocator, resolved_name, "Failed to build skills directory path");
    };
    // skills_dir is heap-allocated in both branches (global via get_global_skills_path_from_env,
    // local via path.join). Free it once at the end of the function via a single defer.
    defer allocator.free(skills_dir);

    // Duplicate resolved.name to ensure no aliasing with path.join's internal buffer allocation
    const name_copy = allocator.dupe(u8, resolved_name) catch {
        return addSkillJsonError(allocator, resolved_name, "Failed to allocate memory for skill name");
    };
    defer allocator.free(name_copy);

    const skill_dir = std.fs.path.join(allocator, &[_][]const u8{ skills_dir, name_copy }) catch {
        return addSkillJsonError(allocator, resolved_name, "Failed to build skill directory path");
    };
    defer allocator.free(skill_dir);

    const skill_file = std.fs.path.join(allocator, &[_][]const u8{ skill_dir, "SKILL.MD" }) catch {
        return addSkillJsonError(allocator, resolved_name, "Failed to build skill file path");
    };
    defer allocator.free(skill_file);

    // `createFileAbsolute` below asserts `skill_file` is absolute and ABORTS the
    // whole process (Debug/ReleaseSafe) when it is not. `absolutizeCwd`
    // handles the local branch; the global branch still trusts an unchecked
    // XDG_CONFIG_HOME/HOME, so enforce the contract here too.
    if (!std.fs.path.isAbsolute(skill_file)) {
        return addSkillJsonError(allocator, resolved_name, ADD_SKILL_CWD_UNRESOLVED);
    }

    // Create directories if needed using std.io.Dir
    if (resolved.create_with_dir) {
        const cwd_dir = std.Io.Dir.cwd();
        cwd_dir.createDirPath(io, skill_dir) catch {
            return addSkillJsonError(allocator, resolved_name, "Failed to create skill directory");
        };
    }

    // Build skill content with YAML frontmatter
    const file_content = buildSkillContent(allocator, resolved);
    defer allocator.free(file_content);
    if (file_content.len == 0) {
        return addSkillJsonError(allocator, resolved_name, "Failed to build skill content");
    }

    // Write the file using absolute path with Io.Dir
    const file = std.Io.Dir.createFileAbsolute(io, skill_file, .{}) catch {
        return addSkillJsonError(allocator, resolved_name, "Failed to create skill file");
    };
    defer std.Io.File.close(file, io);

    std.Io.File.writeStreamingAll(file, io, file_content) catch {
        return addSkillJsonError(allocator, input.name, "Failed to write skill file");
    };

    // Return success JSON
    return addSkillJsonSuccess(allocator, input.name, skill_file);
}

/// Build skill file content with YAML frontmatter
pub fn buildSkillContent(allocator: std.mem.Allocator, input: AddSkillInput) []const u8 {
    // Escape quotes in description for YAML string
    const escaped_desc = addSkillEscapeYamlString(allocator, input.description);
    defer allocator.free(escaped_desc);

    // Build the content: frontmatter + separator + content
    const total_len = 15 + input.name.len + 16 + escaped_desc.len + 5 + input.content.len + 1;
    var result = std.ArrayList(u8).initCapacity(allocator, total_len) catch return "";
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "---\n") catch return "";
    result.appendSlice(allocator, "name: ") catch return "";
    result.appendSlice(allocator, input.name) catch return "";
    result.appendSlice(allocator, "\n") catch return "";
    result.appendSlice(allocator, "description: \"") catch return "";
    result.appendSlice(allocator, escaped_desc) catch return "";
    result.appendSlice(allocator, "\"\n") catch return "";
    result.appendSlice(allocator, "---\n") catch return "";
    result.appendSlice(allocator, input.content) catch return "";
    result.append(allocator, '\n') catch return "";

    return result.toOwnedSlice(allocator) catch return "";
}

/// Escape special characters in a YAML string value
/// Handles: double quotes, backslashes
fn addSkillEscapeYamlString(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var needs_escape = false;

    // Check if escaping is needed
    for (s) |c| {
        if (c == '"' or c == '\\') {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) {
        return allocator.dupe(u8, s) catch return s;
    }

    // Build escaped string
    var result = std.ArrayList(u8).initCapacity(allocator, s.len + 16) catch return s;
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

/// Generate success XML response
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

/// Internal error-to-XML helper (doesn't return error)
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

/// Append XML-safe content to an ArrayList
/// Generate error XML response
/// Generate error XML response for parse failures (no name available)
/// Generate error JSON response for parse failures (no name available)
pub fn addSkillJsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return addSkillJsonError(allocator, "", error_msg);
}

// ─── edit_skill ───

/// Input structure for edit_skill tool. `skill_name` is defaulted so a
/// call that omits it parses and gets a message naming the field rather
/// than `error.MissingField`.
pub const EditSkillInput = struct {
    /// Skill identifier (required)
    skill_name: []const u8 = "",
    /// New description (optional - omit to keep existing). A `description:`
    /// line inside `content`'s frontmatter is used when this is null.
    description: ?[]const u8 = null,
    /// New skill content (optional - omit to keep existing). A leading
    /// `---` frontmatter block is stripped and its `description:` lifted.
    content: ?[]const u8 = null,
    /// If true, edit in global skills directory (~/.config/pabrik/skills/)
    /// If false, edit in local skills directory (.pabrik/skills/)
    is_global: bool = false,
};

/// Tool definition for edit_skill. See the note on `add_skill_tool` —
/// `function.description` and the parameter docs are the only per-tool
/// text that reaches the model.
pub const edit_skill_tool_system_prompt =
    \\## Edit Skill Tool — Behavior
    \\Use `edit_skill` to update an existing skill's description or body.
    \\- Provide `skill_name` and new `description`/`content`. Use to fix or improve a skill after learning a better approach.
    \\
;

pub const edit_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "edit_skill",
        .description =
        \\Edit an existing skill file. Updates the description and/or content of a skill. At least one of description or content must be provided; omit the other to keep it.
        \\
        \\`skill_name` is the directory name `search_skills` reported — not the SKILL.MD path, which is `use_skill`'s argument. `is_global` must match the tier it lives in; get that wrong and the error names the tier that actually holds it, so the fix is one flag away.
        \\
        \\`content` is the BODY only — the frontmatter is regenerated on every write. Rewriting the `description` is the highest-leverage edit available: it is the one line that decides whether this skill is ever loaded.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The skill's directory name, as `search_skills` reported it (e.g. 'my-workflow'). NOT the SKILL.MD path.",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "New one-sentence description: what the skill does AND when to use it. Omit to keep the existing one.",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "New markdown BODY — `## When to Use` / `## Procedure` / `## Pitfalls`. No `---` frontmatter block. Omit to keep the existing body.",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "Must match the tier the skill lives in. false (default) = this project's <cwd>/.pabrik/skills/<name>/SKILL.MD; true = the shared ~/.config/pabrik/skills/<name>/SKILL.MD.",
                },
            },
            .required = &.{"skill_name"},
        },
        .system_prompt = edit_skill_tool_system_prompt,
    },
};

/// Actionable `edit_skill` failures. Exposed for tests.
pub const EDIT_SKILL_MISSING_NAME =
    "edit_skill: `skill_name` is required. Send the skill's directory name as `search_skills` reported it (e.g. \"my-workflow\") — not the SKILL.MD path, which only `use_skill` takes. Run `search_skills` if you are unsure the skill exists.";
pub const EDIT_SKILL_BAD_NAME =
    "edit_skill: `skill_name` must be a single directory name — letters, digits, dots, dashes, underscores; no slashes, spaces, or leading/trailing dot. It is joined onto the skills directory, so a path would read or write outside it. Got: '";
pub const EDIT_SKILL_NOTHING_TO_CHANGE =
    "edit_skill: nothing to change — `description` and `content` were both omitted. Send a new `description` (the one line that decides whether this skill is ever found), a new `content` body, or both.";
pub const EDIT_SKILL_CWD_UNRESOLVED =
    "edit_skill: this session's working directory is relative and could not be absolutized, so the skills directory is unknown. Retry with is_global: true to edit the global skills folder instead.";

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

/// Execute the edit_skill tool
/// Updates an existing skill file at .pabrik/skills/<skill_name>/SKILL.MD or global ~/.config/pabrik/skills/<skill_name>/SKILL.MD
/// Returns a JSON string with the result or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeEditSkillToString(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, environment: ?*const std.process.Environ.Map, input: EditSkillInput) ![]const u8 {
    // Validate input
    if (input.skill_name.len == 0) {
        return editSkillJsonError(allocator, input.skill_name, EDIT_SKILL_MISSING_NAME);
    }
    // `skill_name` is joined onto the skills directory, so a path-like
    // value reads or writes outside it — same guard as `add_skill`.
    if (!isValidSkillName(input.skill_name)) {
        const msg = std.fmt.allocPrint(allocator, "{s}{s}'", .{ EDIT_SKILL_BAD_NAME, input.skill_name }) catch {
            return editSkillJsonError(allocator, input.skill_name, EDIT_SKILL_BAD_NAME);
        };
        defer allocator.free(msg);
        return editSkillJsonError(allocator, input.skill_name, msg);
    }

    // A `description:` carried in `content`'s frontmatter counts as a
    // supplied description, so the model is not told "nothing to change"
    // for sending one field in the place it was taught to.
    const split = splitLeadingFrontmatter(input.content orelse "");
    const fm: ?[]const u8 = if (split.frontmatter.len != 0) split.frontmatter else null;
    const lifted_description: ?[]const u8 = if (fm) |f| frontmatterField(f, "description") else null;

    // At least one of description or content must be provided
    if (input.description == null and input.content == null) {
        return editSkillJsonError(allocator, input.skill_name, EDIT_SKILL_NOTHING_TO_CHANGE);
    }

    // A relative session `cwd` used to fail the whole call here — see
    // `absolutizeCwd`.
    const abs_cwd = try absolutizeCwd(allocator, cwd);
    defer allocator.free(abs_cwd);

    // Determine skills directory based on is_global flag
    const skills_dir: []const u8 = if (input.is_global) blk: {
        if (environment) |env| {
            const path = skills.get_global_skills_path_from_env(allocator, env) orelse {
                return editSkillJsonError(allocator, input.skill_name, "Failed to get global skills path");
            };
            break :blk path;
        } else {
            return editSkillJsonError(allocator, input.skill_name, "Environment not available for global skills");
        }
    } else try std.fs.path.join(allocator, &[_][]const u8{ abs_cwd, ".pabrik", "skills" });
    // skills_dir is heap-allocated in both branches (global via get_global_skills_path_from_env,
    // local via path.join). Free it once at the end of the function via a single defer.
    defer allocator.free(skills_dir);

    // Build path to skill file
    // Duplicate skill_name to ensure no aliasing with path.join's internal buffer allocation
    const skill_name_copy = try allocator.dupe(u8, input.skill_name);
    defer allocator.free(skill_name_copy);

    const skill_file = try std.fs.path.join(allocator, &[_][]const u8{ skills_dir, skill_name_copy, "SKILL.MD" });
    defer allocator.free(skill_file);

    // `createFileAbsolute` at the bottom of this function asserts `skill_file` is
    // absolute and ABORTS the whole process (Debug/ReleaseSafe) when it is not.
    // `absolutizeCwd` handles the local branch; the global branch still
    // trusts XDG_CONFIG_HOME/HOME.
    if (!std.fs.path.isAbsolute(skill_file)) {
        return editSkillJsonError(allocator, input.skill_name, EDIT_SKILL_CWD_UNRESOLVED);
    }

    // Check if the skill file exists
    const file_exists = blk: {
        std.Io.Dir.cwd().access(io, skill_file, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!file_exists) {
        const hint = try editSkillNotFoundHint(allocator, io, input, abs_cwd, environment);
        defer allocator.free(hint);
        return editSkillJsonError(allocator, input.skill_name, hint);
    }

    // Read existing skill content
    const existing_content = std.Io.Dir.cwd().readFileAlloc(io, skill_file, allocator, std.Io.Limit.limited(1024 * 1024)) catch {
        return editSkillJsonError(allocator, input.skill_name, "Failed to read existing skill file");
    };
    defer allocator.free(existing_content);

    // Parse existing skill and extract current values
    const parsed = try parseSkillFile(allocator, existing_content);
    defer {
        allocator.free(parsed.description);
        allocator.free(parsed.content);
    }

    // Use new values or existing ones. A frontmatter block in `content` is
    // stripped so the write cannot re-introduce the doubled-frontmatter
    // that `add_skill` used to produce from such a body.
    const new_description = firstNonEmpty(&.{ input.description, lifted_description }) orelse parsed.description;
    const new_content = if (input.content != null) split.body else parsed.content;

    // Build updated skill content with YAML frontmatter
    const updated_content = try buildEditSkillContent(allocator, input.skill_name, new_description, new_content);
    defer allocator.free(updated_content);

    // Write the updated file
    const file = std.Io.Dir.createFileAbsolute(io, skill_file, .{}) catch {
        return editSkillJsonError(allocator, input.skill_name, "Failed to create skill file for writing");
    };
    defer std.Io.File.close(file, io);

    std.Io.File.writeStreamingAll(file, io, updated_content) catch {
        return editSkillJsonError(allocator, input.skill_name, "Failed to write skill file");
    };

    // Return success JSON
    return try editSkillJsonSuccess(allocator, input.skill_name, skill_file);
}

/// Build the "not found" message for `edit_skill`.
///
/// `"Skill file not found"` named neither the tier that was searched nor
/// the flag that selects it, so the one fix available to the model —
/// flipping `is_global` — was undiscoverable. When the skill IS in the
/// other tier, this says so and gives the exact retry. Caller frees.
fn editSkillNotFoundHint(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: EditSkillInput,
    abs_cwd: []const u8,
    environment: ?*const std.process.Environ.Map,
) ![]const u8 {
    const searched = if (input.is_global)
        "the global tier (you passed is_global: true)"
    else
        "this project's local tier (you passed is_global: false)";

    // The tier the model did NOT ask for.
    var other_dir: ?[]u8 = null;
    defer if (other_dir) |d| allocator.free(d);
    if (input.is_global) {
        other_dir = try std.fs.path.join(allocator, &[_][]const u8{ abs_cwd, ".pabrik", "skills" });
    } else if (environment) |env| {
        // `@constCast` is safe here: the callee allocated this buffer and
        // hands over ownership, and the defer above frees it.
        if (skills.get_global_skills_path_from_env(allocator, env)) |g| other_dir = @constCast(g);
    }

    if (other_dir) |dir| {
        const other_file = try std.fs.path.join(allocator, &[_][]const u8{ dir, input.skill_name, "SKILL.MD" });
        defer allocator.free(other_file);

        const found = blk: {
            std.Io.Dir.cwd().access(io, other_file, .{}) catch break :blk false;
            break :blk true;
        };
        if (found) {
            return std.fmt.allocPrint(
                allocator,
                "edit_skill: skill '{s}' was not found in {s}, but it EXISTS in the other tier at {s}. Retry the identical call with is_global: {}.",
                .{ input.skill_name, searched, other_file, !input.is_global },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "edit_skill: skill '{s}' was not found in {s}, nor in the other tier (looked in {s}). Run search_skills — it lists every installed skill with its scope and exact name.",
            .{ input.skill_name, searched, other_file },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "edit_skill: skill '{s}' was not found in {s}, and the other tier could not be resolved to compare against. Run search_skills to list the installed names.",
        .{ input.skill_name, searched },
    );
}

/// Parsed skill file structure
const ParsedSkill = struct {
    description: []const u8,
    content: []const u8,
};

fn parseSkillFile(allocator: std.mem.Allocator, file_content: []const u8) !ParsedSkill {
    // One parser, shared with the write path. The hand-rolled scanner this
    // replaces derived the key as `trim(frontmatter[i..i], ": ")` at each
    // `:`, which is always the EMPTY string — so `description` never matched
    // and every `edit_skill` that supplied only `content` silently rewrote
    // the frontmatter to `description: ""`. Nothing caught it: the existing
    // tests all supplied a new description, so the read path was never
    // exercised on its own.
    const split = splitLeadingFrontmatter(file_content);
    if (split.frontmatter.len == 0) {
        // No frontmatter — the whole file is the body.
        return .{
            .description = try allocator.dupe(u8, ""),
            .content = try allocator.dupe(u8, file_content),
        };
    }

    var description = frontmatterField(split.frontmatter, "description") orelse "";

    // Heal the doubled-frontmatter corruption on READ. `buildSkillContent`
    // always prepends its own block, so any file written by an `add_skill`
    // whose `content` arrived carrying one has the block twice — and the
    // second copy opens the body here. Without this, `edit_skill` copies the
    // duplicate forward forever and `use_skill` hands the model a body that
    // opens with frontmatter. Stripping on read repairs every already-written
    // skill the next time it is touched.
    var body = split.body;
    const inner = splitLeadingFrontmatter(std.mem.trim(u8, body, "\n"));
    if (inner.frontmatter.len != 0) {
        body = inner.body;
        if (description.len == 0) {
            description = frontmatterField(inner.frontmatter, "description") orelse "";
        }
    }

    return .{
        .description = try allocator.dupe(u8, description),
        .content = try allocator.dupe(u8, std.mem.trim(u8, body, "\n")),
    };
}

/// Build skill file content with YAML frontmatter
fn buildEditSkillContent(allocator: std.mem.Allocator, name: []const u8, description: []const u8, content: []const u8) ![]const u8 {
    // Escape quotes in description for YAML string
    const escaped_desc = try editSkillEscapeYamlString(allocator, description);
    defer allocator.free(escaped_desc);

    // Build the content: frontmatter + separator + content
    const total_len = 15 + name.len + 16 + escaped_desc.len + 5 + content.len + 1;
    var result = try std.ArrayList(u8).initCapacity(allocator, total_len);
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "---\n");
    try result.appendSlice(allocator, "name: ");
    try result.appendSlice(allocator, name);
    try result.appendSlice(allocator, "\n");
    try result.appendSlice(allocator, "description: \"");
    try result.appendSlice(allocator, escaped_desc);
    try result.appendSlice(allocator, "\"\n");
    try result.appendSlice(allocator, "---\n");
    try result.appendSlice(allocator, content);
    try result.append(allocator, '\n');

    return result.toOwnedSlice(allocator);
}

/// Escape special characters in a YAML string value
/// Handles: double quotes, backslashes
fn editSkillEscapeYamlString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var needs_escape = false;

    // Check if escaping is needed
    for (s) |c| {
        if (c == '"' or c == '\\') {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) {
        return allocator.dupe(u8, s);
    }

    // Build escaped string
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Generate success XML response
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

/// Internal error-to-XML helper (doesn't return error)
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

/// Generate error XML response
/// Generate error XML response for parse failures (no name available)
/// Generate error JSON response for parse failures (no name available)
pub fn editSkillJsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return editSkillJsonError(allocator, "", error_msg);
}

// ─── tests: toJson (the HTTP `/skills` wire shape) ───

test "toJson on empty lists parses to empty arrays and null cwd" {
    const alloc = std.testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(SkillsListDataJson, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.global_skills.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.local_skills.len);
    try std.testing.expect(parsed.value.cwd == null);
}

test "toJson carries raw skill fields, parsed" {
    const alloc = std.testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{
            .{
                .name = "test <skill>",
                .description = "desc & more",
                .path = "/path/with \"quotes\"",
            },
        },
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    // Raw text needs no escaping in JSON — parse and compare verbatim.
    const parsed = try std.json.parseFromSlice(SkillsListDataJson, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.global_skills.len);
    try std.testing.expectEqualStrings("test <skill>", parsed.value.global_skills[0].name);
    try std.testing.expectEqualStrings("desc & more", parsed.value.global_skills[0].description);
    try std.testing.expectEqualStrings("/path/with \"quotes\"", parsed.value.global_skills[0].path);
}

test "toJson includes cwd when present, parsed" {
    const alloc = std.testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = "/test/cwd",
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(SkillsListDataJson, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/test/cwd", parsed.value.cwd orelse "");
}

test "toJson generates valid JSON" {
    const alloc = std.testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    // Should be valid JSON structure
    try std.testing.expect(std.mem.startsWith(u8, json, "{"));
    try std.testing.expect(std.mem.endsWith(u8, json, "}"));
    const parsed = try std.json.parseFromSlice(SkillsListDataJson, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.global_skills.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.local_skills.len);
}

test "freeSkillsListData handles empty arrays" {
    const alloc = std.testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    // Should not panic
    freeSkillsListData(alloc, data);
}

test "use_skill_tool - has correct tool definition" {
    try std.testing.expectEqualStrings("use_skill", use_skill_tool.function.name);
    try std.testing.expect(use_skill_tool.function.parameters.properties.len == 2);
}

test "UseSkillInput - has correct defaults" {
    const input = UseSkillInput{};
    try std.testing.expect(input.path == null);
    try std.testing.expect(input.is_global == false);
}

test "UseSkillResult - has correct struct fields" {
    const result = UseSkillResult{
        .skill_name = "test",
        .content = "Test content",
        .loaded = true,
    };
    try std.testing.expectEqualStrings("test", result.skill_name);
    try std.testing.expectEqualStrings("Test content", result.content);
    try std.testing.expect(result.loaded == true);
    try std.testing.expect(result.path == null);
    try std.testing.expect(result.err_msg == null);
    try std.testing.expect(result.available_skills == null);
}

test "execute_use_skill_to_string - missing path returns InvalidInput" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = UseSkillInput{};
    const result = execute_use_skill_to_string(alloc, io, input, null);
    try std.testing.expectError(error.InvalidInput, result);
}

test "use_skill_tool - description is descriptive" {
    // The tool description should explain what the tool does
    try std.testing.expect(use_skill_tool.function.description.len > 10);
    try std.testing.expect(contains(use_skill_tool.function.description, "skill"));
    try std.testing.expect(contains(use_skill_tool.function.description, "content"));
}

test "execute_use_skill_to_string - loaded skill output preserves skill name" {
    // Sanity test: when the skill is found, the output contains the skill
    // name and content (not a use-after-free case, but worth verifying the
    // happy path still works after the refactor).
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const unique_skill_name = "_regression_uaf_use_skill_loaded_test";
    const unique_marker = "REGRESSION_MARKER_12345";
    const tmp_home = "/tmp/pabrik-uaf-test-home-loaded";
    const global_skills_dir = "/tmp/pabrik-uaf-test-home-loaded/.config/pabrik/skills";

    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ global_skills_dir, unique_skill_name });
    defer alloc.free(skill_dir_path);
    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_content =
        \\---
        \\name: _regression_uaf_use_skill_loaded_test
        \\description: "Loaded-path regression test"
        \\---
        \\
        \\# Test content with REGRESSION_MARKER_12345
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, skill_file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, skill_content);
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const output = try execute_use_skill_to_string(
        alloc,
        io,
        .{ .path = skill_file_path },
        &env,
    );
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.loaded);
    try std.testing.expectEqualStrings(unique_skill_name, parsed.value.skill_name);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.content, unique_marker) != null);
    try std.testing.expect(parsed.value.@"error" == null);
}

test "use_skill_tool - schema declares is_global property" {
    // Find the is_global property in the tool definition. This guards against
    // the field being accidentally removed from the schema.
    const props = use_skill_tool.function.parameters.properties;
    var found_is_global = false;
    for (props) |prop| {
        if (std.mem.eql(u8, prop.name, "is_global")) {
            found_is_global = true;
            try std.testing.expectEqualStrings("boolean", prop.type);
            break;
        }
    }
    try std.testing.expect(found_is_global);
}

test "execute_use_skill_to_string - absolute path loads skill file (loadSkillFromPath baseline)" {
    // Baseline: loadSkillFromPath with an absolute path must still work
    // after the openFileAbsolute → cwd().openFile swap. This guards against
    // a regression where the new code accidentally breaks the existing
    // absolute-path happy path.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/pabrik-get-skill-abs-path-test";
    const skill_file = "/tmp/pabrik-get-skill-abs-path-test/SKILL.MD";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    {
        const f = try std.Io.Dir.cwd().createFile(io, skill_file, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: absolute-path-test
            \\description: "Absolute path baseline test"
            \\---
            \\
            \\# Absolute path body
            \\
        );
    }

    const input = UseSkillInput{ .path = skill_file };
    const output = try execute_use_skill_to_string(alloc, io, input, null);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.loaded);
    try std.testing.expectEqualStrings("absolute-path-test", parsed.value.skill_name);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.content, "Absolute path body") != null);
}

test "execute_use_skill_to_string - relative path resolves against cwd (panic regression)" {
    // REGRESSION: previously, passing a relative path caused
    // std.Io.Dir.openFileAbsolute to `unreachable`-panic, killing the
    // entire worker process and bypassing every catch/try in the call
    // chain. See docs/plans/2025-01-15-get-skill-relative-path-panic.md
    //
    // We create a skill file at a relative path under cwd, then call
    // execute_use_skill_to_string with that relative path. Before the fix
    // this would SIGABRT; after the fix it loads successfully.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "tmp_use_skill_relative_test";
    const skill_file = "tmp_use_skill_relative_test/SKILL.MD";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    {
        const f = try std.Io.Dir.cwd().createFile(io, skill_file, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: relative-path-test
            \\description: "Relative path regression test"
            \\---
            \\
            \\# Relative path body
            \\
        );
    }

    const input = UseSkillInput{ .path = skill_file };
    const output = try execute_use_skill_to_string(alloc, io, input, null);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.loaded);
    try std.testing.expectEqualStrings("relative-path-test", parsed.value.skill_name);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.content, "Relative path body") != null);
}

test "execute_use_skill_to_string - non-existent path returns JSON error (no panic, includes path)" {
    // REGRESSION: previously, a non-existent relative path would return a
    // generic "Failed to open file" with no path or OS error info — and if
    // a future caller ever wrapped openFileAbsolute without the same
    // defensive logic, it would panic and kill the worker. The fix
    // surfaces the path and the underlying OS error so the LLM can
    // self-correct on the next turn.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const missing_path = "this/path/does/not/exist/SKILL.MD";
    const input = UseSkillInput{ .path = missing_path };
    const output = try execute_use_skill_to_string(alloc, io, input, null);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.loaded);
    // The path must appear in the error so the LLM knows what was tried.
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.@"error" orelse "", missing_path) != null);
    // Must NOT contain the word "unreachable" from the panic message.
    try std.testing.expect(std.mem.indexOf(u8, output, "unreachable") == null);
}
// ─── tests: remove_skill ───

test "remove_skill - empty skill_name returns error" {
    const alloc = std.testing.allocator;

    const input = RemoveSkillInput{
        .skill_name = "",
        .session_id = "test-session",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = try execute_remove_skill_to_string(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(RemoveSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.removed);
    try std.testing.expectEqualStrings("skill_name cannot be empty", parsed.value.@"error" orelse "");
}

test "remove_skill - tool definition includes is_global parameter" {
    const tool_def = remove_skill_tool;

    // Find is_global in the properties
    var found_is_global = false;
    inline for (tool_def.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "is_global")) {
            found_is_global = true;
            try std.testing.expect(std.mem.eql(u8, prop.type, "boolean"));
        }
    }
    try std.testing.expect(found_is_global);
}

test "remove_skill - tool definition has correct required fields" {
    const tool_def = remove_skill_tool;

    // Should have skill_name and session_id as required (not is_global)
    const required = tool_def.function.parameters.required;
    try std.testing.expect(required.len == 2);
    try std.testing.expect(std.mem.eql(u8, required[0], "skill_name"));
    try std.testing.expect(std.mem.eql(u8, required[1], "session_id"));
}

test "remove_skill - is_global defaults to false" {
    const input = RemoveSkillInput{
        .skill_name = "test-skill",
        .session_id = "test-session",
    };
    try std.testing.expect(input.is_global == false);
}
// ─── tests: add_skill ───

test "add_skill - empty name returns error" {
    const alloc = std.testing.allocator;

    const input = AddSkillInput{
        .name = "",
        .description = "Test description",
        .content = "Test content",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.created);
    try std.testing.expectEqualStrings(ADD_SKILL_MISSING_NAME, parsed.value.@"error" orelse "");
}

test "add_skill - empty description returns error" {
    const alloc = std.testing.allocator;

    const input = AddSkillInput{
        .name = "test-skill",
        .description = "",
        .content = "Test content",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.created);
    try std.testing.expectEqualStrings(ADD_SKILL_MISSING_DESCRIPTION, parsed.value.@"error" orelse "");
}

test "add_skill - empty content returns error" {
    const alloc = std.testing.allocator;

    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.created);
    try std.testing.expectEqualStrings(ADD_SKILL_MISSING_CONTENT, parsed.value.@"error" orelse "");
}

test "add_skill - tool definition includes is_global parameter" {
    const tool_def = add_skill_tool;

    // Find is_global in the properties
    var found_is_global = false;
    inline for (tool_def.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "is_global")) {
            found_is_global = true;
            try std.testing.expect(std.mem.eql(u8, prop.type, "boolean"));
        }
    }
    try std.testing.expect(found_is_global);
}

test "add_skill - tool definition has correct required fields" {
    const tool_def = add_skill_tool;

    // Should have name, description, content as required (not is_global)
    const required = tool_def.function.parameters.required;
    try std.testing.expect(required.len == 3);
    try std.testing.expect(std.mem.eql(u8, required[0], "name"));
    try std.testing.expect(std.mem.eql(u8, required[1], "description"));
    try std.testing.expect(std.mem.eql(u8, required[2], "content"));
}

test "add_skill - is_global defaults to false" {
    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "Test content",
    };
    try std.testing.expect(input.is_global == false);
}

test "add_skill - buildSkillContent with special characters" {
    const alloc = std.testing.allocator;

    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Test \"description\" with quotes",
        .content = "Test content with\\backslash",
        .is_global = false,
    };

    const content = buildSkillContent(alloc, input);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "name: test-skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "description: \"Test \\\"description\\\" with quotes\"") != null);
}

test "add_skill - executeAddSkillToString validates empty content" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "", // Empty content should fail
        .is_global = false,
    };

    const output = executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.created);
    try std.testing.expectEqualStrings(ADD_SKILL_MISSING_CONTENT, parsed.value.@"error" orelse "");
}

test "add_skill - buildSkillContent escapes special characters" {
    const alloc = std.testing.allocator;

    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Test \"description\" with quotes and\\backslash",
        .content = "Test content",
        .is_global = false,
    };

    const content = buildSkillContent(alloc, input);
    defer alloc.free(content);

    // Should contain escaped description
    try std.testing.expect(std.mem.indexOf(u8, content, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\\\\") != null);
}

// ---------------------------------------------------------------------------
// Overwrite-contract regression tests (added 2026-08-15)
//
// add_skill writes the skill file via `std.Io.Dir.createFileAbsolute(io,
// skill_file, .{})` (add_skill.zig:121) — that call relies on the default
// `truncate: bool = true` to OVERWRITE (not fail-with-FileAlreadyExists,
// not append-to) an existing skill with the same name. These tests pin
// that contract end-to-end: re-running add_skill with the same `name`
// must produce the new skill content, with no leftover bytes from the
// first call.
//
// Why this matters: when the LLM refines a skill (e.g. updates its
// description based on user feedback), it re-runs add_skill with the
// same name — a regression that left the old bytes appended would
// silently corrupt the skill file.
// ---------------------------------------------------------------------------

test "add_skill - re-running with same name OVERWRITES (truncates, no append)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-overwrite-skill";
    const tmp_path = "/tmp/pabrik-add-skill-overwrite-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{
        tmp_path, ".pabrik", "skills", skill_name, "SKILL.MD",
    });
    defer alloc.free(skill_file_path);

    // First add_skill: write a long skill body
    const first_input = AddSkillInput{
        .name = skill_name,
        .description = "First version description",
        .content = "# First version\n\nThis is the original long body that should be completely replaced on overwrite.",
        .create_with_dir = true,
        .is_global = false,
    };
    const first_output = executeAddSkillToString(alloc, io, tmp_path, null, first_input);
    defer alloc.free(first_output);
    const first_parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, first_output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer first_parsed.deinit();
    try std.testing.expect(first_parsed.value.created);

    // Sanity-check the first version landed on disk
    const first_read = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(first_read);
    try std.testing.expect(std.mem.indexOf(u8, first_read, "First version description") != null);

    // Second add_skill: write a SHORTER skill body with the SAME name.
    // If the createFile call is buggy and appends, the file would
    // contain BOTH versions concatenated.
    const second_input = AddSkillInput{
        .name = skill_name,
        .description = "Second desc",
        .content = "v2",
        .create_with_dir = true,
        .is_global = false,
    };
    const second_output = executeAddSkillToString(alloc, io, tmp_path, null, second_input);
    defer alloc.free(second_output);
    const second_parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, second_output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer second_parsed.deinit();
    try std.testing.expect(second_parsed.value.created);

    // Read back — must contain ONLY second-version markers, NO first-version
    const second_read = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(second_read);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "Second desc") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "v2") != null);
    // CRITICAL: no leftover from first call — would prove append-mode corruption
    try std.testing.expect(std.mem.indexOf(u8, second_read, "First version description") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "First version\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "should be completely replaced") == null);
}

test "add_skill - local creation (is_global=false) writes to .pabrik/skills/<name>/SKILL.MD" {
    // Regression test for use-after-free bug: when is_global=false, skills_dir
    // was being freed too early (defer was scoped to the else block), causing
    // path.join to use a dangling pointer. The file would either not be
    // created or be created in the wrong place.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-local-skill";
    const tmp_path = "/tmp/pabrik-add-skill-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const input = AddSkillInput{
        .name = skill_name,
        .description = "Test description for local skill",
        .content = "# Test skill content\n\nThis is a test.",
        .create_with_dir = true,
        .is_global = false,
    };

    const output = executeAddSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);

    // Verify the success response
    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.created);
    try std.testing.expectEqualStrings(skill_name, parsed.value.skill_name);

    // Verify the file was actually created at the correct path:
    // <tmp_path>/.pabrik/skills/<skill_name>/SKILL.MD
    // Check that the directory structure exists (this would fail with the old bug
    // because createDirPath was called with a freed-and-reused pointer)
    const dir_check = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".pabrik", "skills", skill_name });
    defer alloc.free(dir_check);
    const dir_exists = blk: {
        std.Io.Dir.cwd().access(io, dir_check, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(dir_exists);

    // Check that the SKILL.MD file exists
    const file_check = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".pabrik", "skills", skill_name, "SKILL.MD" });
    defer alloc.free(file_check);
    const file_exists = blk: {
        std.Io.Dir.cwd().access(io, file_check, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(file_exists);

    // Read the file and verify it has the expected content
    const file_content = try std.Io.Dir.cwd().readFileAlloc(io, file_check, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(file_content);

    try std.testing.expect(std.mem.indexOf(u8, file_content, "name: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, skill_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "Test description for local skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "Test skill content") != null);
}
// ─── tests: edit_skill ───

test "edit_skill - empty skill_name returns error" {
    const alloc = std.testing.allocator;

    const input = EditSkillInput{
        .skill_name = "",
        .description = try alloc.dupe(u8, "New description"),
        .content = null,
        .is_global = false,
    };
    defer alloc.free(input.description.?);

    const io = std.testing.io;
    const output = try executeEditSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.updated);
    try std.testing.expectEqualStrings(EDIT_SKILL_MISSING_NAME, parsed.value.@"error" orelse "");
}

test "edit_skill - neither description nor content provided returns error" {
    const alloc = std.testing.allocator;

    const input = EditSkillInput{
        .skill_name = "test-skill",
        .description = null,
        .content = null,
        .is_global = false,
    };

    const io = std.testing.io;
    const output = try executeEditSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.updated);
    try std.testing.expectEqualStrings(EDIT_SKILL_NOTHING_TO_CHANGE, parsed.value.@"error" orelse "");
}

test "edit_skill - tool definition includes is_global parameter" {
    const tool_def = edit_skill_tool;

    // Find is_global in the properties
    var found_is_global = false;
    inline for (tool_def.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "is_global")) {
            found_is_global = true;
            try std.testing.expect(std.mem.eql(u8, prop.type, "boolean"));
        }
    }
    try std.testing.expect(found_is_global);
}

test "edit_skill - tool definition has skill_name as required" {
    const tool_def = edit_skill_tool;

    // Should have skill_name as required (not description or content)
    const required = tool_def.function.parameters.required;
    try std.testing.expect(required.len == 1);
    try std.testing.expect(std.mem.eql(u8, required[0], "skill_name"));
}

test "edit_skill - is_global defaults to false" {
    const input = EditSkillInput{
        .skill_name = "test-skill",
        .description = null,
        .content = null,
    };
    try std.testing.expect(input.is_global == false);
}

test "edit_skill - local edit (is_global=false) updates .pabrik/skills/<name>/SKILL.MD" {
    // Regression test for use-after-free bug: when is_global=false, skills_dir
    // was being freed too early (defer was scoped to the else block), causing
    // path.join to use a dangling pointer. The file would either not be
    // updated or be updated in the wrong place.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-local-edit-skill";
    const tmp_path = "/tmp/pabrik-edit-skill-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    // Pre-create a local skill file in the expected format
    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".pabrik", "skills", skill_name });
    defer alloc.free(skill_dir_path);
    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    const original_content =
        \\---
        \\name: test-local-edit-skill
        \\description: "Original description"
        \\---
        \\
        \\# Original content
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, skill_file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, original_content);
    }

    // Now edit the local skill
    const new_description = "Updated description for local skill";
    const new_content = "# Updated content\n\nThis is the updated test.";

    const input = EditSkillInput{
        .skill_name = skill_name,
        .description = new_description,
        .content = new_content,
        .is_global = false,
    };

    const output = try executeEditSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);

    // Verify the success response
    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.updated);
    try std.testing.expectEqualStrings(skill_name, parsed.value.skill_name);

    // Read the file and verify it was actually updated with the new content
    const updated_file_content = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(updated_file_content);

    // New description and content should be present
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, new_description) != null);
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, "Updated content") != null);
    // Original description and content should be gone
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, "Original description") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, "Original content") == null);
}

// ---------------------------------------------------------------------------
// Overwrite-contract regression test (added 2026-08-15)
//
// edit_skill writes the updated skill back via `std.Io.Dir.createFileAbsolute
// (io, skill_file, .{})` (edit_skill.zig:132) — that call relies on the
// default `truncate: bool = true` to OVERWRITE (not append-to) the existing
// skill file. This test pins the contract by pre-seeding a skill with
// trailing junk AFTER the frontmatter, then editing with a SHORTER body,
// and asserting the trailing junk is GONE in the final file (would
// prove append-mode corruption if present).
// ---------------------------------------------------------------------------

test "edit_skill - edit truncates existing skill file (no append-mode corruption)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "edit-overwrite-skill";
    const tmp_path = "/tmp/pabrik-edit-skill-overwrite-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);
    const skill_dir_path = try std.fs.path.join(alloc, &.{ tmp_path, ".pabrik", "skills", skill_name });
    defer alloc.free(skill_dir_path);
    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{
        tmp_path, ".pabrik", "skills", skill_name, "SKILL.MD",
    });
    defer alloc.free(skill_file_path);

    // Pre-seed a skill file with a marker INSIDE the frontmatter description
    // plus trailing junk OUTSIDE the content block that the edit MUST wipe.
    // The format is: ---\nname: ...\ndescription: "..."\n---\n<content>\n
    const seed = "---\nname: edit-overwrite-skill\ndescription: \"OLD-DESC-MARKER\"\n---\nOLD-CONTENT-MARKER trailing junk that should be completely wiped on edit append-junk-trailing-bytes-12345\n";
    {
        const f = try std.Io.Dir.cwd().createFile(io, skill_file_path, .{});
        defer f.close(io);
        try std.Io.File.writeStreamingAll(f, io, seed);
    }

    // Edit the skill — replace BOTH description and content with shorter values.
    const input = EditSkillInput{
        .skill_name = skill_name,
        .description = "new",
        .content = "v2",
        .is_global = false,
    };
    const output = try executeEditSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);
    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.updated);

    // Read back — must contain ONLY the new description+content; ALL of the
    // OLD markers and trailing junk must be GONE.
    const updated = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(updated);

    // New values are present
    try std.testing.expect(std.mem.indexOf(u8, updated, "new") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "v2") != null);

    // CRITICAL: no leftover from old seed — would prove append-mode corruption
    try std.testing.expect(std.mem.indexOf(u8, updated, "OLD-DESC-MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "OLD-CONTENT-MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "trailing junk that should be completely wiped") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "append-junk-trailing-bytes") == null);
}

// ─── tests: argument resolution (the two failure modes that were live) ───

test "splitLeadingFrontmatter - splits a fenced block, leaves everything else alone" {
    const with_fm = "---\nname: foo\ndescription: \"bar\"\n---\n## Body\n";
    const s = splitLeadingFrontmatter(with_fm);
    try std.testing.expectEqualStrings("name: foo\ndescription: \"bar\"\n", s.frontmatter);
    try std.testing.expectEqualStrings("## Body\n", s.body);

    // No fence at the head → the whole input is the body.
    const bare = splitLeadingFrontmatter("## Body\n\n---\nnot a fence\n");
    try std.testing.expectEqualStrings("", bare.frontmatter);
    try std.testing.expectEqualStrings("## Body\n\n---\nnot a fence\n", bare.body);

    // Unterminated fence → not treated as frontmatter (never a guess).
    const open = splitLeadingFrontmatter("---\nname: foo\n");
    try std.testing.expectEqualStrings("", open.frontmatter);

    // Closing fence at EOF (no trailing newline) still splits.
    const eof = splitLeadingFrontmatter("---\nname: foo\n---");
    try std.testing.expectEqualStrings("name: foo\n", eof.frontmatter);
    try std.testing.expectEqualStrings("", eof.body);

    // `---x` is not a fence.
    const notfence = splitLeadingFrontmatter("---\nname: foo\n---x\nbody");
    try std.testing.expectEqualStrings("", notfence.frontmatter);
}

test "frontmatterField - reads values, strips quotes, rejects near-misses" {
    const fm = "name: foo-bar\ndescription: \"Use when X.\"\nnames: wrong-key\nempty:\n";
    try std.testing.expectEqualStrings("foo-bar", frontmatterField(fm, "name").?);
    try std.testing.expectEqualStrings("Use when X.", frontmatterField(fm, "description").?);
    // `name` must not match the `names:` line.
    try std.testing.expectEqualStrings("right", frontmatterField("names: wrong-key\nname: right\n", "name").?);
    // An empty value is no value.
    try std.testing.expect(frontmatterField("empty:\n", "empty") == null);
    try std.testing.expect(frontmatterField("name: foo\n", "description") == null);
}

test "isValidSkillName - rejects traversal and separator characters" {
    try std.testing.expect(isValidSkillName("my-skill"));
    try std.testing.expect(isValidSkillName("my_skill.v2"));

    // The traversal that `path.join(skills_dir, name)` would have honoured.
    try std.testing.expect(!isValidSkillName("../../etc/passwd"));
    try std.testing.expect(!isValidSkillName(".."));
    try std.testing.expect(!isValidSkillName("a/b"));
    try std.testing.expect(!isValidSkillName("a\\b"));
    try std.testing.expect(!isValidSkillName(".hidden"));
    try std.testing.expect(!isValidSkillName("trailing."));
    try std.testing.expect(!isValidSkillName("has space"));
    try std.testing.expect(!isValidSkillName(""));
}

test "add_skill - content carrying frontmatter does NOT double the block (the live corruption)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const tmp_path = "/tmp/pabrik-add-skill-fm-test";

    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    // Exactly the shape a model produces when it pastes the skill format:
    // frontmatter inside `content`, and NO `description` argument.
    const input = AddSkillInput{
        .name = "fm-lifted",
        .description = "",
        .content = "---\nname: fm-lifted\ndescription: \"Lifted from content.\"\n---\n## When to Use\n\nAlways.\n",
    };

    const output = executeAddSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.created);

    const file = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".pabrik", "skills", "fm-lifted", "SKILL.MD" });
    defer alloc.free(file);
    const body = try std.Io.Dir.cwd().readFileAlloc(io, file, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(body);

    // Exactly TWO fences (the generated block's open + close). Four is the bug
    // that shipped: the opening fence has no preceding newline, so this counts
    // both rather than matching only the closer.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "---\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "name: fm-lifted"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "Lifted from content."));

    // The frontmatter was lifted into the description, not left in the body.
    try std.testing.expect(std.mem.indexOf(u8, body, "## When to Use") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "description: \"Lifted from content.\"") != null);
}

test "add_skill - a RELATIVE cwd resolves instead of refusing (was: must be an absolute path)" {
    const alloc = std.testing.allocator;

    // `absolutizeCwd` is the fix; assert it directly so the guard is covered
    // by a test rather than only by the disk tests' absolute `/tmp` cwd.
    const abs = try absolutizeCwd(alloc, "/already/absolute");
    defer alloc.free(abs);
    try std.testing.expectEqualStrings("/already/absolute", abs);

    // Relative → joined onto the process cwd, so the result IS absolute.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = helpers.getcwd(&buf).?;
    const resolved = try absolutizeCwd(alloc, "sub/dir");
    defer alloc.free(resolved);
    try std.testing.expect(std.fs.path.isAbsolute(resolved));
    try std.testing.expect(std.mem.startsWith(u8, resolved, base));

    try std.testing.expectError(error.CwdUnavailable, absolutizeCwd(alloc, ""));
}

test "add_skill - a path-like name is refused with a message naming the rule" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const tmp_path = "/tmp/pabrik-add-skill-badname";

    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const input = AddSkillInput{
        .name = "../escaped",
        .description = "d",
        .content = "## Body\n",
    };
    const output = executeAddSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.created);
    const err = parsed.value.@"error" orelse "";
    try std.testing.expect(std.mem.startsWith(u8, err, ADD_SKILL_BAD_NAME));
    try std.testing.expect(std.mem.indexOf(u8, err, "../escaped") != null);

    // Nothing escaped the skills directory.
    try std.testing.expect(!helpers.fileExists("/tmp/pabrik-add-skill-badname/escaped/SKILL.MD"));
}

test "add_skill / edit_skill - every field defaults, so a missing one parses" {
    // The regression that produced `add_skill failed: MissingField`: with
    // non-defaulted fields, `std.json.parseFromSlice` rejects the payload
    // before any of the actionable messages can be produced.
    const alloc = std.testing.allocator;

    // Omitted `description` parses; it is validated downstream, where the
    // message can name the argument.
    const omitted_desc = try std.json.parseFromSlice(
        AddSkillInput,
        alloc,
        "{\"name\":\"x\",\"content\":\"## Body\\n\"}",
        .{ .allocate = .alloc_always },
    );
    defer omitted_desc.deinit();
    try std.testing.expectEqualStrings("x", omitted_desc.value.name);
    try std.testing.expectEqualStrings("", omitted_desc.value.description);

    // An extra key must not cost the call — that is what
    // `ignore_unknown_fields` buys, and what produced
    // `add_skill failed: UnknownField` before.
    const extra_key = try std.json.parseFromSlice(
        AddSkillInput,
        alloc,
        "{\"name\":\"x\",\"description\":\"d\",\"content\":\"c\",\"scope\":\"global\"}",
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer extra_key.deinit();
    try std.testing.expectEqualStrings("x", extra_key.value.name);

    const no_name = try std.json.parseFromSlice(
        EditSkillInput,
        alloc,
        "{\"description\":\"d\"}",
        .{},
    );
    defer no_name.deinit();
    try std.testing.expectEqualStrings("", no_name.value.skill_name);

    // remove_skill: `session_id` is unused, so omitting it must not fail.
    const no_session = try std.json.parseFromSlice(
        RemoveSkillInput,
        alloc,
        "{\"skill_name\":\"x\"}",
        .{ .allocate = .alloc_always },
    );
    defer no_session.deinit();
    try std.testing.expectEqualStrings("x", no_session.value.skill_name);
    try std.testing.expectEqualStrings("", no_session.value.session_id);
}

test "edit_skill - frontmatter in content lifts the description and is not re-duplicated" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const tmp_path = "/tmp/pabrik-edit-skill-fm";

    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const seed = AddSkillInput{
        .name = "edit-fm",
        .description = "Original description.",
        .content = "## When to Use\n\nOriginal body.\n",
    };
    const seeded = executeAddSkillToString(alloc, io, tmp_path, null, seed);
    defer alloc.free(seeded);

    // The model rewrites the body and, out of habit, re-pastes frontmatter
    // with the new description in it.
    const out = try executeEditSkillToString(alloc, io, tmp_path, null, .{
        .skill_name = "edit-fm",
        .content = "---\ndescription: \"Rewritten description.\"\n---\n## When to Use\n\nNew body.\n",
    });
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, out, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.updated);

    const file = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".pabrik", "skills", "edit-fm", "SKILL.MD" });
    defer alloc.free(file);
    const body = try std.Io.Dir.cwd().readFileAlloc(io, file, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(body);

    // Lifted, not duplicated, and the OLD description is gone.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "---\n"));
    try std.testing.expect(std.mem.indexOf(u8, body, "Rewritten description.") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Original description.") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "New body.") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Original body.") == null);
}

test "edit_skill - a path-like skill_name is refused before touching the disk" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const tmp_path = "/tmp/pabrik-edit-skill-badname";

    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const secret = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, "secret.txt" });
    defer alloc.free(secret);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = secret, .data = "do not clobber me" });

    const out = try executeEditSkillToString(alloc, io, tmp_path, null, .{
        .skill_name = "../secret",
        .content = "## Owned\n",
    });
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, out, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.updated);
    try std.testing.expect(std.mem.startsWith(u8, parsed.value.@"error" orelse "", EDIT_SKILL_BAD_NAME));

    const after = try std.Io.Dir.cwd().readFileAlloc(io, secret, alloc, std.Io.Limit.limited(1024));
    defer alloc.free(after);
    try std.testing.expectEqualStrings("do not clobber me", after);
}

test "edit_skill - not-found names the tier that actually holds the skill" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const tmp_path = "/tmp/pabrik-edit-skill-tierhint";

    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    // Skill exists ONLY in the global tier; the call asks for local.
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    const xdg = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".config-home" });
    defer alloc.free(xdg);
    try env.put("XDG_CONFIG_HOME", xdg);

    const seeded = executeAddSkillToString(alloc, io, tmp_path, &env, .{
        .name = "global-only",
        .description = "Lives in the global tier.",
        .content = "## When to Use\n\nOnly globally.\n",
        .is_global = true,
    });
    defer alloc.free(seeded);

    const out = try executeEditSkillToString(alloc, io, tmp_path, &env, .{
        .skill_name = "global-only",
        .description = "new",
        .is_global = false, // wrong tier on purpose
    });
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, out, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.updated);

    const err = parsed.value.@"error" orelse "";
    try std.testing.expect(std.mem.indexOf(u8, err, "EXISTS in the other tier") != null);
    try std.testing.expect(std.mem.indexOf(u8, err, "is_global: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, err, "local tier") != null);
}

test "remove_skill - a path-like skill_name is refused" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const tmp_path = "/tmp/pabrik-remove-skill-badname";

    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const out = try execute_remove_skill_to_string(alloc, io, tmp_path, null, .{
        .skill_name = "../../etc",
        .session_id = "s",
    });
    defer alloc.free(out);

    const parsed = try std.json.parseFromSlice(RemoveSkillOutput, alloc, out, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.removed);
    try std.testing.expect(std.mem.startsWith(u8, parsed.value.@"error" orelse "", REMOVE_SKILL_BAD_NAME));
}

test "skill tool descriptions carry the rules the failure modes needed" {
    // The per-tool `system_prompt` field is never rendered (see the note on
    // `add_skill_tool`), so `description` is the only per-tool surface the
    // model reads. Pin the rules it must state.
    for ([_][]const u8{ add_skill_tool.function.description, edit_skill_tool.function.description }) |desc| {
        try std.testing.expect(std.mem.indexOf(u8, desc, "frontmatter") != null);
        try std.testing.expect(std.mem.indexOf(u8, desc, "is_global") != null);
    }
    // The add_skill contract stated three ways: separate args, body only,
    // and why the description matters.
    try std.testing.expect(std.mem.indexOf(u8, add_skill_tool.function.description, "SEPARATE ARGUMENTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, add_skill_tool.function.description, "search_skills") != null);
}

test "parseSkillFile - heals the doubled frontmatter already on disk" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const tmp_path = "/tmp/pabrik-parse-heal";

    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const dir = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".pabrik", "skills", "legacy-doubled" });
    defer alloc.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    // Byte-for-byte the shape `add_skill` produced for every skill whose
    // `content` arrived with a frontmatter block — the corruption that
    // shipped. `---` at lines 1, 4, 5, 8.
    const file = try std.fs.path.join(alloc, &[_][]const u8{ dir, "SKILL.MD" });
    defer alloc.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "---\nname: legacy-doubled\ndescription: \"Written twice.\"\n---\n" ++
        "---\nname: legacy-doubled\ndescription: \"Written twice.\"\n---\n" ++
        "## When to Use\n\nThe real body.\n" });

    // Reading it back: the description parses, and the body is clean.
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, file, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(raw);
    const parsed = try parseSkillFile(alloc, raw);
    defer {
        alloc.free(parsed.description);
        alloc.free(parsed.content);
    }
    try std.testing.expectEqualStrings("Written twice.", parsed.description);
    try std.testing.expectEqualStrings("## When to Use\n\nThe real body.", parsed.content);

    // A description-only edit now carries the duplicate no further.
    const out = try executeEditSkillToString(alloc, io, tmp_path, null, .{
        .skill_name = "legacy-doubled",
        .description = "Rewritten once.",
    });
    defer alloc.free(out);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, file, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(after);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, after, "---\n"));
    try std.testing.expect(std.mem.indexOf(u8, after, "The real body.") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "Rewritten once.") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "Written twice.") == null);
}

test "edit_skill - a content-only edit KEEPS the description (it used to be wiped)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const tmp_path = "/tmp/pabrik-edit-skill-keep-desc";

    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const seeded = executeAddSkillToString(alloc, io, tmp_path, null, .{
        .name = "keep-desc",
        .description = "The sentence search_skills will return.",
        .content = "## When to Use\n\nFirst body.\n",
    });
    defer alloc.free(seeded);

    // `description` omitted — the tool must read the existing one off disk.
    const out = try executeEditSkillToString(alloc, io, tmp_path, null, .{
        .skill_name = "keep-desc",
        .content = "## When to Use\n\nSecond body.\n",
    });
    defer alloc.free(out);

    const file = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".pabrik", "skills", "keep-desc", "SKILL.MD" });
    defer alloc.free(file);
    const after = try std.Io.Dir.cwd().readFileAlloc(io, file, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(after);

    try std.testing.expect(std.mem.indexOf(u8, after, "The sentence search_skills will return.") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "Second body.") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "First body.") == null);
    // The empty frontmatter this used to write.
    try std.testing.expect(std.mem.indexOf(u8, after, "description: \"\"") == null);
}
