//! Agent-callable tool: `save_memory` — UPSERT a short, structured note
//! that the agent can recall later via `load_memory`.
//!
//! Plan: docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md (Task 3)
//! Task: task_1785958319567
//!
//! Wire shape:
//!   input:  { content: string, tags?: string[], id?: string }
//!   output: <save_memory><id>...</id><created_at>...</created_at>
//!            <updated_at>...</updated_at></save_memory>
//!   or:     <save_memory><error>...</error></save_memory>
//!
//! The actual INSERT OR REPLACE lives in `agent_memories.saveMemory`.
//! This file is a thin XML wrapper around it (mirrors the
//! `kanban_list.zig` / `search_history.zig` pattern).
//!
//! Design choices:
//!   - Caller-provided `id` is optional. Empty → auto-generated
//!     `mem_<16-hex>` (collision-free for 10K rows, opaque token).
//!   - Per-row size cap is 1 MiB (rejects overflow, doesn't truncate).
//!   - Tags stored as `||`-joined string (matches the project's
//!     `tags` / `image_urls` convention — Migration 067 / 069).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const agent_memories = nalarcore.agent_memories;

const helpers = nalarcore.helpers;
const xmlEscape = helpers.xml_escape;

/// Input for `save_memory`.
pub const SaveMemoryInput = struct {
    /// The note body. 1 KiB – 1 MiB (validated by `agent_memories.saveMemory`).
    content: []const u8 = "",
    /// Optional labels. Stored as `||`-joined (matches the project's
    /// `tags` / `image_urls` convention).
    tags: []const []const u8 = &.{},
    /// Caller-provided id slug for UPSERT. Empty → auto-generate
    /// `mem_<16-hex>`.
    id: []const u8 = "",
};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to use this tool — it explicitly
/// tells the agent that memory entries are UPSERT, FTS5-indexed,
/// global (cross-session / cross-workspace), and capped at 1 MiB.
pub const save_memory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "save_memory",
        .description =
            \\Save (or update) a structured note that you can recall later via the `load_memory` tool. Use this to remember facts, preferences, decisions, or any short, structured context that you want to persist across sessions.
            \\
            \\This is a UPSERT: if you provide an `id` that already exists, the existing row's content and tags are replaced (the `updated_at` timestamp bumps). Omit `id` (or pass an empty string) to auto-generate a fresh `mem_<16-hex>` id.
            \\
            \\Storage: the note is stored in a global SQLite table with a FTS5 index. Searches (`load_memory`) can find it via phrase matching on the content or tags.
            \\
            \\Constraints:
            \\- `content` must be 1 KiB – 1 MiB. Empty content is rejected; oversized is rejected (no silent truncation).
            \\- `tags` are joined with `||` in storage and split on `|` at read time.
            \\- There is NO delete_memory tool — memory is permanent (by your design). To "forget" something, save a new memory that supersedes it.
            \\- Global scope: memories are visible across all workspaces and sessions. There is no per-workspace filter.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "content", .type = "string", .description = "The note body. 1 KiB – 1 MiB. Required." },
                .{ .name = "tags", .type = "string", .description = "Optional labels (e.g. 'preferences', 'user'). Joined with '||' in storage. Each tag is a short, distinct string." },
                .{ .name = "id", .type = "string", .description = "Optional caller-provided id slug for UPSERT. Empty string → auto-generated 'mem_<16-hex>'." },
            },
            .required = &.{"content"},
        },
    },
};

/// Execute save_memory. Returns an XML string for the LLM.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn executeSaveMemory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SaveMemoryInput,
) ![]const u8 {
    const row = agent_memories.saveMemory(allocator, db, .{
        .content = input.content,
        .tags = input.tags,
        .id = input.id,
    }) catch |err| {
        const msg = switch (err) {
            error.InvalidContent => "content must be non-empty (1 KiB minimum)",
            error.ContentTooLarge => "content exceeds the 1 MiB per-memory cap",
            error.RowNotFoundAfterInsert => "row missing after insert (DB inconsistency)",
            else => @errorName(err),
        };
        return errorXml(allocator, msg);
    };
    defer agent_memories.freeMemoryRow(allocator, row);

    return successXml(allocator, row);
}

fn successXml(allocator: std.mem.Allocator, row: agent_memories.MemoryRow) ![]u8 {
    const id_e = try xmlEscape(allocator, row.id);
    defer allocator.free(id_e);
    const created_at_e = try xmlEscape(allocator, row.created_at);
    defer allocator.free(created_at_e);
    const updated_at_e = try xmlEscape(allocator, row.updated_at);
    defer allocator.free(updated_at_e);
    return std.fmt.allocPrint(allocator,
        "<save_memory>" ++
        "<id>{s}</id>" ++
        "<created_at>{s}</created_at>" ++
        "<updated_at>{s}</updated_at>" ++
        "</save_memory>",
        .{ id_e, created_at_e, updated_at_e });
}

fn errorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<save_memory><error>{s}</error></save_memory>",
        .{escaped});
}