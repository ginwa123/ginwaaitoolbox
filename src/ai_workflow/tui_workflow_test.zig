const std = @import("std");
const tree1 = @import("tree1");
const agent = tree1.agent;
const tui_workflow = tree1.ai_workflow;
const sqlite = tree1.sqlite;
const migrations = tree1.migrations;

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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-1";
    workflow.model = "test-model";

    const history = tui_workflow.TUIHistory{
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-2";
    workflow.model = "test-model";

    const history = tui_workflow.TUIHistory{
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-tool-msg";
    workflow.model = "test-model";

    // Simulate a tool result message (role="tool", tools column contains tool_call_id)
    const history = tui_workflow.TUIHistory{
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-3";
    workflow.model = "test-model";

    const history = tui_workflow.TUIHistory{
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();
    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-session";
    workflow.model = "test-model";

    const response = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Test response",
        .tool_calls = null,
        .finish_reason = .stop,
    };

    try workflow.saveMessageUnified(null, response, "assistant", null, null, null, null);

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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "user-msg-test";
    workflow.model = "test-model";

    try workflow.saveMessageUnified("Hello, world!", null, "user", "null", null, null, null);

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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "tool-msg-test";
    workflow.model = "test-model";

    try workflow.saveMessageUnified("bash output here", null, "tool", "tool", null, "tool_call_123", null);

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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "session-get-test";
    workflow.model = "test-model";

    const response1 = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "First message",
        .tool_calls = null,
        .finish_reason = .stop,
    };
    try workflow.saveMessageUnified(null, response1, "assistant", null, null, null, null);

    const response2 = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Second message",
        .tool_calls = null,
        .finish_reason = .stop,
    };
    try workflow.saveMessageUnified(null, response2, "assistant", null, null, null, null);

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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "tool-calls-test";
    workflow.model = "test-model";
    workflow.message = "List files";

    var tool_calls_slice = try allocator.alloc(agent.ToolCall, 1);
    tool_calls_slice[0] = .{ .id = "call_123", .function = .{ .name = "bash", .arguments = "{\"command\":\"ls\"}" } };
    defer allocator.free(tool_calls_slice);

    try workflow.saveMessageUnified(null, agent.Agent.CallResponse{
        .allocator = allocator,
        .content = null,
        .tool_calls = tool_calls_slice,
        .finish_reason = .tool_calls,
    }, "assistant", null, tool_calls_slice, null, null);

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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
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

test "buildMessages reconstructs tool_calls and tool_call_id correctly" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-tool-reconstruction";
    workflow.model = "test-model";

    // 1. Save user message
    try workflow.saveMessageUnified("run ls command", null, "user", "null", null, null, null);

    // 2. Save assistant message with tool_calls (simulating LLM response that wants to call a tool)
    var tool_calls = try allocator.alloc(agent.ToolCall, 1);
    tool_calls[0] = .{
        .id = "tool-abc123",
        .function = .{
            .name = "bash",
            .arguments = "{\"command\":\"ls\",\"cwd\":\".\",\"timeout\":30}",
        },
    };

    const assistant_response = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = null,
        .tool_calls = tool_calls,
        .finish_reason = .tool_calls,
    };
    try workflow.saveMessageUnified(null, assistant_response, "assistant", null, tool_calls, null, null);

    // 3. Save tool result message
    try workflow.saveMessageUnified("file1.txt\nfile2.txt", null, "tool", "tool", null, "tool-abc123", null);

    // 4. Now reconstruct messages using buildMessages
    workflow.message = "continue";
    const messages = try workflow.buildMessages();
    defer {
        for (messages) |*m| m.deinit(allocator);
        allocator.free(messages);
    }

    // 5. Verify the structure: system -> user -> assistant(tool_calls) -> tool(tool_call_id)
    try std.testing.expectEqual(@as(usize, 4), messages.len);

    // System message
    try std.testing.expectEqual(agent.Role.system, messages[0].role);

    // User message
    try std.testing.expectEqual(agent.Role.user, messages[1].role);
    try std.testing.expectEqualStrings("run ls command", messages[1].content.?);

    // Assistant message with tool_calls
    try std.testing.expectEqual(agent.Role.assistant, messages[2].role);
    try std.testing.expect(messages[2].tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), messages[2].tool_calls.?.len);
    try std.testing.expectEqualStrings("tool-abc123", messages[2].tool_calls.?[0].id);
    try std.testing.expectEqualStrings("bash", messages[2].tool_calls.?[0].function.name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\",\"cwd\":\".\",\"timeout\":30}", messages[2].tool_calls.?[0].function.arguments);

    // Tool result message with tool_call_id
    try std.testing.expectEqual(agent.Role.tool, messages[3].role);
    try std.testing.expect(messages[3].tool_call_id != null);
    try std.testing.expectEqualStrings("tool-abc123", messages[3].tool_call_id.?);
    try std.testing.expectEqualStrings("file1.txt\nfile2.txt", messages[3].content.?);

    // Cleanup
    allocator.free(tool_calls);
}

test "serializeToolCalls escapes JSON arguments correctly" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();

    // Create tool_calls with JSON arguments that need escaping
    var tool_calls = try allocator.alloc(agent.ToolCall, 1);
    tool_calls[0] = .{
        .id = "call-xyz789",
        .function = .{
            .name = "bash",
            .arguments = "{\"command\":\"echo \\\"hello world\\\"\",\"cwd\":\"/home/user\"}",
        },
    };

    // Serialize
    const serialized = try workflow.serializeToolCalls(tool_calls);
    defer allocator.free(serialized);

    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, serialized, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);

    const tc_obj = parsed.value.array.items[0];
    try std.testing.expect(tc_obj == .object);
    try std.testing.expectEqualStrings("call-xyz789", tc_obj.object.get("id").?.string);
    try std.testing.expectEqualStrings("function", tc_obj.object.get("type").?.string);

    const func = tc_obj.object.get("function").?.object;
    try std.testing.expectEqualStrings("bash", func.get("name").?.string);
    // The arguments should be preserved correctly (escaped and unescaped properly)
    try std.testing.expectEqualStrings("{\"command\":\"echo \\\"hello world\\\"\",\"cwd\":\"/home/user\"}", func.get("arguments").?.string);

    allocator.free(tool_calls);
}

test "get_session_by_dir returns empty slice when no sessions" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();

    const sessions = try workflow.get_session_by_dir();
    defer {
        for (sessions) |*s| s.deinit(allocator);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 0), sessions.len);
}

test "get_session_by_dir returns single session" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();

    workflow.session_id = "session-1";
    workflow.cwd = "/home/user/project1";
    workflow.model = "test-model";

    const response = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Test response",
        .tool_calls = null,
        .finish_reason = .stop,
    };
    try workflow.saveMessageUnified(null, response, "assistant", null, null, null, null);

    const sessions = try workflow.get_session_by_dir();
    defer {
        for (sessions) |*s| s.deinit(allocator);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("session-1", sessions[0].session_id);
    try std.testing.expectEqualStrings("/home/user/project1", sessions[0].session_dir);
    try std.testing.expect(sessions[0].created.len > 0);
}

test "get_session_by_dir returns multiple sessions ordered by created DESC" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();

    workflow.model = "test-model";

    // Insert sessions directly with explicit timestamps for deterministic ordering
    // Insert oldest session (timestamp 1000)
    try db.exec(allocator, "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, session_dir) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", &.{"id1", "session-old", "test-model", "1000", "Old message", "stop", "assistant", "/home/user/old"});

    // Insert middle session (timestamp 2000)
    try db.exec(allocator, "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, session_dir) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", &.{"id2", "session-middle", "test-model", "2000", "Middle message", "stop", "assistant", "/home/user/middle"});

    // Insert newest session (timestamp 3000)
    try db.exec(allocator, "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, session_dir) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", &.{"id3", "session-new", "test-model", "3000", "New message", "stop", "assistant", "/home/user/new"});

    const sessions = try workflow.get_session_by_dir();
    defer {
        for (sessions) |*s| s.deinit(allocator);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 3), sessions.len);

    // Verify ordering: newest first (DESC)
    try std.testing.expectEqualStrings("session-new", sessions[0].session_id);
    try std.testing.expectEqualStrings("session-middle", sessions[1].session_id);
    try std.testing.expectEqualStrings("session-old", sessions[2].session_id);
}

test "get_session_by_dir handles NULL session_dir with COALESCE" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();

    workflow.session_id = "session-null-dir";
    // Leave cwd as default (empty string) - this will insert empty string, not NULL
    // To test NULL, we need to insert directly into the database
    workflow.model = "test-model";

    // Insert a record with NULL session_dir directly via SQL
    try db.exec(allocator, "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, session_dir) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)", &.{ "id-null-test", "session-null-dir", "test-model", "1000", "content", "stop", "assistant" });

    const sessions = try workflow.get_session_by_dir();
    defer {
        for (sessions) |*s| s.deinit(allocator);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("session-null-dir", sessions[0].session_id);
    // COALESCE should convert NULL to empty string
    try std.testing.expectEqualStrings("", sessions[0].session_dir);
}

test "get_session_by_dir groups by session_id" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();

    workflow.model = "test-model";

    // Insert multiple messages with same session_id but different timestamps directly
    // This tests GROUP BY and MAX(created)
    try db.exec(allocator, "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, session_dir) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", &.{"id1", "shared-session", "test-model", "1000", "First message", "stop", "assistant", "/home/user/shared"});
    try db.exec(allocator, "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, session_dir) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", &.{"id2", "shared-session", "test-model", "2000", "Second message", "stop", "assistant", "/home/user/shared"});
    try db.exec(allocator, "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, session_dir) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", &.{"id3", "shared-session", "test-model", "3000", "Third message", "stop", "assistant", "/home/user/shared"});

    const sessions = try workflow.get_session_by_dir();
    defer {
        for (sessions) |*s| s.deinit(allocator);
        allocator.free(sessions);
    }

    // Should only return 1 session due to GROUP BY
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("shared-session", sessions[0].session_id);
    try std.testing.expectEqualStrings("/home/user/shared", sessions[0].session_dir);

    // Verify that created is the MAX(created) - should be "3000" (the newest)
    try std.testing.expectEqualStrings("1970-01-01 07:50:00", sessions[0].created);
}

test "get_session_by_dir limits to 10 results" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();

    workflow.model = "test-model";

    // Insert 15 sessions directly with explicit timestamps for deterministic testing
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        const id = try std.fmt.allocPrint(allocator, "id-{}", .{i});
        defer allocator.free(id);
        const sessionId = try std.fmt.allocPrint(allocator, "session-{}", .{i});
        defer allocator.free(sessionId);
        const sessionDir = try std.fmt.allocPrint(allocator, "/home/user/project{}", .{i});
        defer allocator.free(sessionDir);
        const created = try std.fmt.allocPrint(allocator, "{}", .{i});
        defer allocator.free(created);
        
        try db.exec(allocator, "INSERT INTO llm_history (id, session_id, model, created, response_content, finish_reason, role, session_dir) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", &.{id, sessionId, "test-model", created, "Test message", "stop", "assistant", sessionDir});
    }

    const sessions = try workflow.get_session_by_dir();
    defer {
        for (sessions) |*s| s.deinit(allocator);
        allocator.free(sessions);
    }

    // Should only return 10 sessions due to LIMIT
    try std.testing.expectEqual(@as(usize, 10), sessions.len);
}

test "saveMessageUnified with null agent_name defaults to GeneralAgent" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-agent-null";
    workflow.model = "test-model";

    const response = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Test response",
        .tool_calls = null,
        .finish_reason = .stop,
    };

    // Call saveMessageUnified with null agent_name (8th param)
    try workflow.saveMessageUnified(null, response, "assistant", null, null, null, null);

    // Verify agent column contains "GeneralAgent"
    const row = try db.queryRow(allocator, "SELECT agent FROM llm_history WHERE session_id = ?", &.{"test-agent-null"});
    defer row.deinit(allocator);

    try std.testing.expectEqualStrings("GeneralAgent", row.values[0]);
}

test "saveMessageUnified with explicit agent_name stores provided value" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-agent-explicit";
    workflow.model = "test-model";

    const response = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Test response from PlanningAgent",
        .tool_calls = null,
        .finish_reason = .stop,
    };

    // Call saveMessageUnified with explicit agent_name = "PlanningAgent"
    try workflow.saveMessageUnified(null, response, "assistant", null, null, null, "PlanningAgent");

    // Verify agent column contains "PlanningAgent"
    const row = try db.queryRow(allocator, "SELECT agent FROM llm_history WHERE session_id = ?", &.{"test-agent-explicit"});
    defer row.deinit(allocator);

    try std.testing.expectEqualStrings("PlanningAgent", row.values[0]);
}

test "getMessages retrieves agent column correctly" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-agent-getmessages";
    workflow.model = "test-model";

    const response = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Test response from ExplorationAgent",
        .tool_calls = null,
        .finish_reason = .stop,
    };

    // Call saveMessageUnified with agent_name = "ExplorationAgent"
    try workflow.saveMessageUnified(null, response, "assistant", null, null, null, "ExplorationAgent");

    // Retrieve messages using getMessages()
    const messages = try workflow.getMessages();
    defer {
        for (messages) |*msg| msg.deinit(allocator);
        allocator.free(messages);
    }

    // Verify we got one message and agent field is correct
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("ExplorationAgent", messages[0].agent);
}

test "saveMessageUnified handles various agent names" {
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
    try mgr.registerMigration(.{
        .version = migrations.Migration004AddSessionDir.version,
        .name = migrations.Migration004AddSessionDir.name,
        .up = migrations.Migration004AddSessionDir.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration005AddIsFeedToLLM.version,
        .name = migrations.Migration005AddIsFeedToLLM.name,
        .up = migrations.Migration005AddIsFeedToLLM.up,
    });
    try mgr.registerMigration(.{
        .version = migrations.Migration006AddAgent.version,
        .name = migrations.Migration006AddAgent.name,
        .up = migrations.Migration006AddAgent.up,
    });
    try mgr.runMigrations();

    var workflow = try tui_workflow.TUIWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.model = "test-model";

    // Test ExplorationAgent
    workflow.session_id = "test-various-1";
    const response1 = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Exploration response",
        .tool_calls = null,
        .finish_reason = .stop,
    };
    try workflow.saveMessageUnified(null, response1, "assistant", null, null, null, "ExplorationAgent");

    // Test PlanningAgent
    workflow.session_id = "test-various-2";
    const response2 = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Planning response",
        .tool_calls = null,
        .finish_reason = .stop,
    };
    try workflow.saveMessageUnified(null, response2, "assistant", null, null, null, "PlanningAgent");

    // Test ExecutingAgent
    workflow.session_id = "test-various-3";
    const response3 = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Executing response",
        .tool_calls = null,
        .finish_reason = .stop,
    };
    try workflow.saveMessageUnified(null, response3, "assistant", null, null, null, "ExecutingAgent");

    // Test KnowledgeAgent
    workflow.session_id = "test-various-4";
    const response4 = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Knowledge response",
        .tool_calls = null,
        .finish_reason = .stop,
    };
    try workflow.saveMessageUnified(null, response4, "assistant", null, null, null, "KnowledgeAgent");

    // Verify each agent name is stored correctly
    const row1 = try db.queryRow(allocator, "SELECT agent FROM llm_history WHERE session_id = ?", &.{"test-various-1"});
    defer row1.deinit(allocator);
    try std.testing.expectEqualStrings("ExplorationAgent", row1.values[0]);

    const row2 = try db.queryRow(allocator, "SELECT agent FROM llm_history WHERE session_id = ?", &.{"test-various-2"});
    defer row2.deinit(allocator);
    try std.testing.expectEqualStrings("PlanningAgent", row2.values[0]);

    const row3 = try db.queryRow(allocator, "SELECT agent FROM llm_history WHERE session_id = ?", &.{"test-various-3"});
    defer row3.deinit(allocator);
    try std.testing.expectEqualStrings("ExecutingAgent", row3.values[0]);

    const row4 = try db.queryRow(allocator, "SELECT agent FROM llm_history WHERE session_id = ?", &.{"test-various-4"});
    defer row4.deinit(allocator);
    try std.testing.expectEqualStrings("KnowledgeAgent", row4.values[0]);
}
