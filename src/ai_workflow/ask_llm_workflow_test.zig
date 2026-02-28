const std = @import("std");
const agent = @import("../modules/agent/agent.zig");
const ask_llm_workflow = @import("ask_llm_workflow.zig");
const sqlite = @import("../modules/databases/sqlite/sqlite.zig");
const migrations = @import("../modules/databases/sqlite/migrations.zig");

test "transformMessageToAgentMessages with user message" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-1";
    workflow.model = "test-model";

    const history = ask_llm_workflow.AskLLMHistory{
        .id = "1",
        .session_id = "test-1",
        .model = "model",
        .created = "123",
        .response_content = "Hello",
        .finish_reason = "stop",
        .role = "user",
        .tools = "",
    };

    const messages = try workflow.transformMessageToAgentMessages(history);
    defer {
        for (messages) |*msg| msg.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent.Role.user, messages[0].role);
}

test "transformMessageToAgentMessages with assistant message" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-2";
    workflow.model = "test-model";

    const history = ask_llm_workflow.AskLLMHistory{
        .id = "2",
        .session_id = "test-2",
        .model = "model",
        .created = "123",
        .response_content = "Hi there",
        .finish_reason = "stop",
        .role = "assistant",
        .tools = "",
    };

    const messages = try workflow.transformMessageToAgentMessages(history);
    defer {
        for (messages) |*msg| msg.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent.Role.assistant, messages[0].role);
}

test "transformMessageToAgentMessages with tool message" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-tool-msg";
    workflow.model = "test-model";

    // Simulate a tool result message (role="tool", tools column contains tool_call_id)
    const history = ask_llm_workflow.AskLLMHistory{
        .id = "4",
        .session_id = "test-tool-msg",
        .model = "model",
        .created = "123",
        .response_content = "bash output here",
        .finish_reason = "tool",
        .role = "tool",
        .tools = "call_abc123", // This is the tool_call_id, not JSON
    };

    const messages = try workflow.transformMessageToAgentMessages(history);
    defer {
        for (messages) |*msg| msg.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent.Role.tool, messages[0].role);
    try std.testing.expect(messages[0].tool_call_id != null);
    try std.testing.expectEqualStrings("call_abc123", messages[0].tool_call_id.?);
    try std.testing.expectEqualStrings("bash output here", messages[0].content.?);
}

test "transformMessageToAgentMessages with tool_calls message" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-3";
    workflow.model = "test-model";

    const history = ask_llm_workflow.AskLLMHistory{
        .id = "3",
        .session_id = "test-3",
        .model = "model",
        .created = "123",
        .response_content = "[tool_calls]",
        .finish_reason = "tool_calls",
        .role = "assistant",
        .tools = "[{\"id\":\"call_123\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]",
    };

    const messages = try workflow.transformMessageToAgentMessages(history);
    defer {
        for (messages) |*msg| msg.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent.Role.assistant, messages[0].role);
    try std.testing.expect(messages[0].tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), messages[0].tool_calls.?.len);
}

test "saveMessage saves response to llm_history" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-session";
    workflow.model = "test-model";

    const response = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Test response",
        .tool_calls = null,
        .finish_reason = .stop,
    };

    try workflow.saveMessage(response, "assistant", null);

    const row = try db.queryRow(allocator, "SELECT response_content, finish_reason FROM llm_history WHERE session_id = ?", &.{"test-session"});
    defer row.deinit(allocator);

    try std.testing.expectEqualStrings("Test response", row.values[0]);
    try std.testing.expectEqualStrings("stop", row.values[1]);
}

test "saveMessageAsUser saves user message to llm_history" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "user-msg-test";
    workflow.model = "test-model";

    try workflow.saveMessageAsUser("Hello, world!");

    const row = try db.queryRow(allocator, "SELECT response_content, role FROM llm_history WHERE session_id = ?", &.{"user-msg-test"});
    defer row.deinit(allocator);

    try std.testing.expectEqualStrings("Hello, world!", row.values[0]);
    try std.testing.expectEqualStrings("user", row.values[1]);
}

test "saveMessageAsTool saves tool result to llm_history" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "tool-msg-test";
    workflow.model = "test-model";

    try workflow.saveMessageAsTool("bash output here", "tool_call_123");

    const row = try db.queryRow(allocator, "SELECT response_content, role, tool_calls_json FROM llm_history WHERE session_id = ?", &.{"tool-msg-test"});
    defer row.deinit(allocator);

    try std.testing.expectEqualStrings("bash output here", row.values[0]);
    try std.testing.expectEqualStrings("tool", row.values[1]);
    try std.testing.expectEqualStrings("tool_call_123", row.values[2]);
}

test "buildMessages returns correct message structure" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "build-msg-test";
    workflow.model = "test-model";
    workflow.message = "test message";

    const messages = try workflow.buildMessages();
    defer {
        for (messages) |*m| m.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expect(messages.len >= 1);
    try std.testing.expectEqual(agent.Role.system, messages[0].role);
}

test "getMessages retrieves messages by session_id" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "session-get-test";
    workflow.model = "test-model";

    const response1 = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "First message",
        .tool_calls = null,
        .finish_reason = .stop,
    };
    try workflow.saveMessage(response1, "assistant", null);

    const response2 = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Second message",
        .tool_calls = null,
        .finish_reason = .stop,
    };
    try workflow.saveMessage(response2, "assistant", null);

    const messages = try workflow.getMessages();
    defer {
        for (messages) |*m| m.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("assistant", messages[0].role);
    try std.testing.expectEqualStrings("assistant", messages[1].role);
}

test "buildMessages handles tool_calls response correctly" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "tool-calls-test";
    workflow.model = "test-model";
    workflow.message = "List files";

    var tool_calls_slice = try allocator.alloc(agent.ToolCall, 1);
    tool_calls_slice[0] = .{ .id = "call_123", .function = .{ .name = "bash", .arguments = "{\"command\":\"ls\"}" } };
    defer allocator.free(tool_calls_slice);

    try workflow.saveMessage(agent.Agent.CallResponse{
        .allocator = allocator,
        .content = null,
        .tool_calls = tool_calls_slice,
        .finish_reason = .tool_calls,
    }, "assistant", tool_calls_slice);

    const messages = try workflow.buildMessages();
    defer {
        for (messages) |*msg| {
            if (msg.content) |c| allocator.free(c);
            if (msg.tool_call_id) |tid| allocator.free(tid);
            if (msg.tool_calls) |tc| {
                for (tc) |*call| {
                    allocator.free(call.id);
                    allocator.free(call.function.name);
                    allocator.free(call.function.arguments);
                }
                allocator.free(tc);
            }
        }
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(agent.Role.system, messages[0].role);
    try std.testing.expectEqual(agent.Role.assistant, messages[1].role);
}

test "sendResponse generates valid XML with content" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-session-xml";
    workflow.model = "test-model";
    workflow.conn_fd = -1;

    const response = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Hello <world>",
        .tool_calls = null,
        .finish_reason = .stop,
    };

    workflow.sendResponse(response, null);
}

test "sendResponse generates valid XML with markdown content" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-session-md";
    workflow.model = "test-model";
    workflow.conn_fd = -1;

    const response = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "<markdown>\nHello world\n</markdown>",
        .tool_calls = null,
        .finish_reason = .stop,
    };

    workflow.sendResponse(response, null);
}

test "sendError with content_filter finish reason" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-content-filter";
    workflow.model = "test-model";
    workflow.conn_fd = -1; // No connection, just test it doesn't crash

    // Test sendError with content_filter finish reason
    workflow.sendError("Content was filtered due to safety policies.", "content_filter");
}

test "sendError with null finish reason defaults to stop" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-error-stop";
    workflow.model = "test-model";
    workflow.conn_fd = -1;

    // Test sendError with null finish reason (should default to "stop")
    workflow.sendError("Some error occurred.", null);
}

test "sendResponse with content_filter override" {
    const allocator = std.testing.allocator;

    var db: sqlite.SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    var mgr = migrations.MigrationManager.init(allocator, &db);
    defer mgr.deinit();
    try mgr.registerMigration(.{
        .version = migrations.Migration001CreateLLMHistory.version,
        .name = migrations.Migration001CreateLLMHistory.name,
        .up = migrations.Migration001CreateLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration002AddRoleToLLMHistory.version,
        .name = migrations.Migration002AddRoleToLLMHistory.name,
        .up = migrations.Migration002AddRoleToLLMHistory.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration003AddReasoningContent.version,
        .name = migrations.Migration003AddReasoningContent.name,
        .up = migrations.Migration003AddReasoningContent.up,
    });
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-response-filter";
    workflow.model = "test-model";
    workflow.conn_fd = -1;

    // Test sendResponse with content_filter override
    const response = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Partial content before filter",
        .tool_calls = null,
        .finish_reason = .content_filter,
    };

    workflow.sendResponse(response, "content_filter");
}
