//! Sanity tests for the `src/models/` entity models.
//!
//! Verifies that every model file compiles, that `init` populates the
//! struct as expected, that `deinit` releases its strings, and that
//! external callers can read the struct's fields directly (matching
//! the file-level struct pattern requested by the user).

const std = @import("std");
const testing = std.testing;

const workspace = @import("workspace.zig");
const workspace_item = @import("workspace_item.zig");
const workspace_item_task = @import("workspace_item_task.zig");
const session = @import("session.zig");
const kanban_column = @import("kanban_column.zig");
const kanban_assignment = @import("kanban_assignment.zig");
const design_page = @import("design_page.zig");
const design_page_element = @import("design_page_element.zig");
const llm_history = @import("llm_history.zig");
const workspace_routine = @import("workspace_routine.zig");
const worker = @import("worker.zig");
const log = @import("log.zig");
const session_activity = @import("session_activity.zig");
const session_agent = @import("session_agent.zig");
const session_queue_message = @import("session_queue_message.zig");
const session_skill = @import("session_skill.zig");
const session_background_process = @import("session_background_process.zig");
const agent_memory = @import("agent_memory.zig");

test "workspace: init + deinit + field access" {
    var w = try workspace.init(testing.allocator, .{
        .id = "ws_1",
        .name = "My Workspace",
        .position = 5,
    });
    defer workspace.deinit(&w, testing.allocator);

    // External callers can read fields directly (file-level struct).
    try testing.expectEqualStrings("ws_1", w.id);
    try testing.expectEqualStrings("My Workspace", w.name);
    try testing.expectEqual(@as(i64, 5), w.position);
    try testing.expect(w.created_at == null);
    try testing.expect(w.updated_at == null);
}

test "workspace: clone produces independent copy" {
    var original = try workspace.init(testing.allocator, .{
        .id = "ws_1",
        .name = "Original",
    });
    defer workspace.deinit(&original, testing.allocator);

    var copy = try workspace.clone(&original, testing.allocator);
    defer workspace.deinit(&copy, testing.allocator);

    try testing.expectEqualStrings("ws_1", copy.id);
    try testing.expectEqualStrings("Original", copy.name);
    // Deep copy — different backing allocations.
    try testing.expect(original.id.ptr != copy.id.ptr);
    try testing.expect(original.name.ptr != copy.name.ptr);
}

test "workspace_item: init + deinit with all fields" {
    var w = try workspace_item.init(testing.allocator, .{
        .id = "item_1",
        .workspace_id = "ws_1",
        .item_type = "kanban",
        .name = "Sprint Board",
        .path = "/tmp/board",
        .position = 3,
    });
    defer workspace_item.deinit(&w, testing.allocator);

    try testing.expectEqualStrings("item_1", w.id);
    try testing.expectEqualStrings("kanban", w.item_type);
    try testing.expectEqualStrings("Sprint Board", w.name.?);
    try testing.expectEqualStrings("/tmp/board", w.path.?);
}

test "workspace_item_task: init + deinit with all fields" {
    var t = try workspace_item_task.init(testing.allocator, .{
        .id = "task_1",
        .name = "Build feature",
        .workspace_item_id = "item_1",
        .description = "A task description",
        .tags = "[\"bug\",\"urgent\"]",
        .image_urls = "data:image/png;base64,abc",
        .cwd = "/home/me",
        .is_pinned = true,
        .pinned_position = 2,
    });
    defer workspace_item_task.deinit(&t, testing.allocator);

    try testing.expectEqualStrings("task_1", t.id);
    try testing.expect(t.is_pinned);
    try testing.expectEqual(@as(i64, 2), t.pinned_position);
    try testing.expectEqualStrings("A task description", t.description);
    try testing.expectEqualStrings("[\"bug\",\"urgent\"]", t.tags);
}

test "session: init + deinit with nullable fields" {
    var s = try session.init(testing.allocator, .{
        .id = "session_1",
        .name = "Chat Session",
        .cwd = "/home/me",
        .workspace_id = "ws_1",
        .selected_profile_model = "openai-default",
        .git_worktree_cwd = "/tmp/worktree",
        .is_auto_retry_until_stop = true,
        .last_finish_reason = "stop",
    });
    defer session.deinit(&s, testing.allocator);

    try testing.expectEqualStrings("session_1", s.id);
    try testing.expectEqualStrings("active", s.status);
    try testing.expect(s.is_auto_retry_until_stop);
    try testing.expectEqualStrings("stop", s.last_finish_reason);
    try testing.expectEqualStrings("/home/me", s.cwd.?);
}

test "kanban_column: init + deinit" {
    var c = try kanban_column.init(testing.allocator, .{
        .id = "col_1",
        .workspace_item_id = "item_1",
        .name = "todo",
        .position = 0,
        .description = "Open work",
    });
    defer kanban_column.deinit(&c, testing.allocator);

    try testing.expectEqualStrings("col_1", c.id);
    try testing.expectEqualStrings("todo", c.name);
    try testing.expectEqualStrings("Open work", c.description);
}

test "kanban_assignment: init + deinit" {
    var a = try kanban_assignment.init(testing.allocator, .{
        .workspace_item_task_id = "task_1",
        .kanban_column_id = "col_1",
        .kanban_position = 3,
    });
    defer kanban_assignment.deinit(&a, testing.allocator);

    try testing.expectEqualStrings("task_1", a.workspace_item_task_id);
    try testing.expectEqualStrings("col_1", a.kanban_column_id);
    try testing.expectEqual(@as(i64, 3), a.kanban_position);
}

test "design_page: init + deinit with dimensions" {
    var p = try design_page.init(testing.allocator, .{
        .id = "page_1",
        .workspace_item_id = "item_1",
        .name = "Login",
        .width = 1920,
        .height = 1080,
        .x = 100,
        .y = 50,
        .workspace_item_task_id = "task_1",
    });
    defer design_page.deinit(&p, testing.allocator);

    try testing.expectEqualStrings("Login", p.name);
    try testing.expectEqual(@as(i64, 1920), p.width);
    try testing.expectEqual(@as(i64, 1080), p.height);
    try testing.expectEqualStrings("task_1", p.workspace_item_task_id);
}

test "design_page_element: init + deinit with rotation" {
    var e = try design_page_element.init(testing.allocator, .{
        .id = "elem_1",
        .page_id = "page_1",
        .name = "Hero Card",
        .elem_type = "rectangle",
        .fill = "#181616",
        .stroke = "#ffffff",
        .corner_radius = 12,
        .opacity = 0.85,
        .rotation = 45.0,
    });
    defer design_page_element.deinit(&e, testing.allocator);

    try testing.expectEqualStrings("elem_1", e.id);
    try testing.expectEqualStrings("rectangle", e.elem_type);
    try testing.expectEqualStrings("#181616", e.fill);
    try testing.expectEqualStrings("#ffffff", e.stroke);
    try testing.expectEqual(@as(i64, 12), e.corner_radius);
    try testing.expectApproxEqAbs(@as(f64, 0.85), e.opacity, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 45.0), e.rotation, 0.0001);
}

test "llm_history: init + deinit with cache tokens" {
    var h = try llm_history.init(testing.allocator, .{
        .id = "msg_1",
        .session_id = "session_1",
        .model = "claude-sonnet-4-5",
        .role = "assistant",
        .prompt_tokens = 100,
        .completion_tokens = 50,
        .total_tokens = 150,
        .cache_creation_input_tokens = 200,
        .cache_read_input_tokens = 1000,
        .is_thinking = true,
        .temperature = 0.7,
    });
    defer llm_history.deinit(&h, testing.allocator);

    try testing.expectEqualStrings("claude-sonnet-4-5", h.model);
    try testing.expectEqualStrings("assistant", h.role);
    try testing.expect(h.is_thinking);
    try testing.expectEqual(@as(i64, 100), h.prompt_tokens);
    try testing.expectEqual(@as(i64, 200), h.cache_creation_input_tokens);
    try testing.expectEqual(@as(i64, 1000), h.cache_read_input_tokens);
    try testing.expectApproxEqAbs(@as(f64, 0.7), h.temperature, 0.0001);
}

test "workspace_routine: init + deinit" {
    var r = try workspace_routine.init(testing.allocator, .{
        .id = "wr_1",
        .workspace_item_id = "item_1",
        .instruction = "Check the build status",
        .schedule = "*/5 * * * *",
        .next_run_at = "2026-08-15 12:00:00",
        .enabled = true,
    });
    defer workspace_routine.deinit(&r, testing.allocator);

    try testing.expectEqualStrings("wr_1", r.id);
    try testing.expectEqualStrings("item_1", r.workspace_item_id);
    try testing.expectEqualStrings("*/5 * * * *", r.schedule);
    try testing.expect(r.enabled);
    try testing.expectEqualStrings("idle", r.last_status);
    try testing.expect(r.next_run_at != null);
}

test "worker: init + deinit" {
    var w = try worker.init(testing.allocator, .{
        .id = "worker_1",
        .session_id = "session_1",
        .working_directory = "/tmp/work",
        .last_activity = 1786000000,
        .last_activity_description = "Tool call: bash",
    });
    defer worker.deinit(&w, testing.allocator);

    try testing.expectEqualStrings("worker_1", w.id);
    try testing.expectEqualStrings("session_1", w.session_id);
    try testing.expectEqualStrings("/tmp/work", w.working_directory.?);
    try testing.expectEqualStrings("Tool call: bash", w.last_activity_description.?);
    try testing.expectEqual(@as(i64, 1786000000), w.last_activity);
    try testing.expect(!w.cancelled);
}

test "log: init + deinit with unix-ms timestamp" {
    var l = try log.init(testing.allocator, .{
        .id = "log_1",
        .created_at = 1786000000000,
        .level = "error",
        .kind = "console_error",
        .message = "Something broke",
        .stack = "Error: foo\n  at bar.js:1:1",
        .line = 42,
        .route_path = "/workspaces",
        .session_id = "session_1",
        .count = 3,
    });
    defer log.deinit(&l, testing.allocator);

    try testing.expectEqual(@as(i64, 1786000000000), l.created_at);
    try testing.expectEqualStrings("error", l.level);
    try testing.expectEqualStrings("console_error", l.kind);
    try testing.expectEqualStrings("Something broke", l.message);
    try testing.expectEqualStrings("Error: foo\n  at bar.js:1:1", l.stack.?);
    try testing.expectEqual(@as(i64, 42), l.line.?);
    try testing.expectEqual(@as(i64, 3), l.count);
}

test "session_activity: init + deinit" {
    var a = try session_activity.init(testing.allocator, .{
        .id = "act_1",
        .session_id = "session_1",
        .description = "Implementing | Adding feature X",
        .created_at = "2026-08-15 12:00:00",
    });
    defer session_activity.deinit(&a, testing.allocator);

    try testing.expectEqualStrings("act_1", a.id);
    try testing.expectEqualStrings("Implementing | Adding feature X", a.description);
}

test "session_agent: init + deinit" {
    var a = try session_agent.init(testing.allocator, .{
        .session_id = "session_1",
        .agent_name = "code-reviewer",
        .updated_at = 1786000000,
    });
    defer session_agent.deinit(&a, testing.allocator);

    try testing.expectEqualStrings("session_1", a.session_id);
    try testing.expectEqualStrings("code-reviewer", a.agent_name);
    try testing.expectEqual(@as(i64, 1786000000), a.updated_at);
}

test "session_queue_message: init + deinit with image-only" {
    var m = try session_queue_message.init(testing.allocator, .{
        .id = "q_1",
        .session_id = "session_1",
        .image_url = "data:image/png;base64,abc",
    });
    defer session_queue_message.deinit(&m, testing.allocator);

    try testing.expectEqualStrings("q_1", m.id);
    try testing.expect(m.message == null);
    try testing.expectEqualStrings("data:image/png;base64,abc", m.image_url.?);
}

test "session_skill: init + deinit" {
    var s = try session_skill.init(testing.allocator, .{
        .session_id = "session_1",
        .skill_name = "test-driven-development",
        .content = "# TDD\n\nWrite tests first.",
        .loaded_at = 1786000000,
    });
    defer session_skill.deinit(&s, testing.allocator);

    try testing.expectEqualStrings("session_1", s.session_id);
    try testing.expectEqualStrings("test-driven-development", s.skill_name);
    try testing.expectEqualStrings("# TDD\n\nWrite tests first.", s.content);
    try testing.expectEqual(@as(i64, 1786000000), s.loaded_at);
}

test "session_background_process: init + deinit" {
    var p = try session_background_process.init(testing.allocator, .{
        .session_id = "session_1",
        .pid = 12345,
        .command = "npm run dev",
        .log_path = "/tmp/dev.log",
        .started_at = 1786000000,
        .status = "running",
    });
    defer session_background_process.deinit(&p, testing.allocator);

    try testing.expectEqual(@as(i64, 12345), p.pid);
    try testing.expectEqualStrings("npm run dev", p.command);
    try testing.expectEqualStrings("/tmp/dev.log", p.log_path);
    try testing.expectEqualStrings("running", p.status);
}

test "agent_memory: init + deinit" {
    var m = try agent_memory.init(testing.allocator, .{
        .id = "mem_1",
        .content = "User prefers Anthropic Sonnet for code review.",
        .tags = "preferences||models",
        .created_at = "2026-08-15 12:00:00",
        .updated_at = "2026-08-15 12:00:00",
    });
    defer agent_memory.deinit(&m, testing.allocator);

    try testing.expectEqualStrings("mem_1", m.id);
    try testing.expectEqualStrings("User prefers Anthropic Sonnet for code review.", m.content);
    try testing.expectEqualStrings("preferences||models", m.tags);
}

test "every model: clone is deep copy with distinct pointers" {
    var w = try workspace.init(testing.allocator, .{
        .id = "ws_1",
        .name = "Original",
        .position = 1,
    });
    defer workspace.deinit(&w, testing.allocator);

    var copy = try workspace.clone(&w, testing.allocator);
    defer workspace.deinit(&copy, testing.allocator);

    // Strings point to different heap allocations.
    try testing.expect(w.id.ptr != copy.id.ptr);
    try testing.expect(w.name.ptr != copy.name.ptr);
    // But have equal contents.
    try testing.expectEqualStrings(w.id, copy.id);
    try testing.expectEqualStrings(w.name, copy.name);
}