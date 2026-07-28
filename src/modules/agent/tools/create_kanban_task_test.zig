//! Static-contract tests for the `create_kanban_task` agent tool.
//!
//! Lock the wire shape of the tool definition BEFORE any code lands
//! (TDD red). Each test reads `src/modules/agent/tools/create_kanban_task.zig`
//! from disk and asserts on required substrings. If a future refactor
//! drops a required substring, the corresponding test fails.
//!
//! Plan: docs/superpowers/plans/2026-07-29-create-kanban-task-tool.md (Task 1)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const TOOL_PATH = "src/modules/agent/tools/create_kanban_task.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
/// The returned buffer is owned by the caller (freed with `allocator.free`).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── Static source-check tests (RED — file does not exist yet) ────────────

test "create_kanban_task tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"create_kanban_task\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig does not define the tool with .name = \"create_kanban_task\" !!\n" ++
                "   The LLM dispatch will fail to find the tool by its schema name.\n",
            .{},
        );
        return error.ToolNameMissing;
    }
}

test "create_kanban_task description mentions kanban + task/card" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Both substrings are required — "kanban" so the LLM scopes the
    // tool to kanban operations (matches the kanban_* prefix), and
    // "task" so the LLM recognizes the tool creates a card.
    if (!contains(source, "kanban")) {
        std.debug.print(
            "\n!! create_kanban_task description does not contain 'kanban' !!\n" ++
                "   LLM can't scope the tool to kanban contexts.\n",
            .{},
        );
        return error.KanbanKeywordMissing;
    }
    if (!contains(source, "task")) {
        std.debug.print(
            "\n!! create_kanban_task description does not contain 'task' !!\n" ++
                "   LLM can't recognize this as a card-creation tool.\n",
            .{},
        );
        return error.TaskKeywordMissing;
    }
}

test "create_kanban_task required fields are workspace_id + item_id + name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The .required field MUST contain all three. Order matters
    // only for the LLM's UX hint — we match the substring regardless.
    if (!contains(source, ".required = &.{ \"workspace_id\", \"item_id\", \"name\" }")) {
        std.debug.print(
            "\n!! create_kanban_task .required field is missing one of workspace_id / item_id / name !!\n" ++
                "   The tool must require all three; missing any one returns an undefined slice.\n",
            .{},
        );
        return error.RequiredFieldsMissing;
    }
}

test "create_kanban_task input struct has workspace_id + item_id + name fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The Zig struct must declare each field with the documented type.
    if (!contains(source, "workspace_id: []const u8")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'workspace_id' field !!\n",
            .{},
        );
        return error.WorkspaceIdFieldMissing;
    }
    if (!contains(source, "item_id: []const u8")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'item_id' field !!\n",
            .{},
        );
        return error.ItemIdFieldMissing;
    }
    if (!contains(source, "name: []const u8")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'name' field !!\n",
            .{},
        );
        return error.NameFieldMissing;
    }
}

test "create_kanban_task description marks column_id as optional" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must explicitly tell the LLM that column_id
    // is optional (so it knows to omit the field for auto-assign).
    if (!contains(source, "column_id")) {
        std.debug.print(
            "\n!! create_kanban_task description does not mention 'column_id' !!\n" ++
                "   LLM won't know it can omit the field for auto-assign.\n",
            .{},
        );
        return error.ColumnIdMentionMissing;
    }
}

test "create_kanban_task description tells LLM ids come from Workspace Context" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Without this hint, the LLM will hallucinate ids. Matches the
    // convention in kanban_list / kanban_move_task / set_design_page.
    if (!contains(source, "## Workspace Context") and
        !contains(source, "Workspace Context") and
        !contains(source, "workspace context"))
    {
        std.debug.print(
            "\n!! create_kanban_task description does not mention Workspace Context !!\n" ++
                "   LLM will hallucinate workspace_id / item_id without this hint.\n",
            .{},
        );
        return error.WorkspaceContextHintMissing;
    }
}