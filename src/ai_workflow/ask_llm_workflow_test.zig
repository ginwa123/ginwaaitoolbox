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
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();

    var history = ask_llm_workflow.AskLLMHistory{
        .id = try allocator.dupe(u8, "test-id"),
        .session_id = try allocator.dupe(u8, "test-session"),
        .model = try allocator.dupe(u8, "test-model"),
        .created = try allocator.dupe(u8, "1234567890"),
        .response_content = try allocator.dupe(u8, "Hi there"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "assistant"),
        .tools = try allocator.dupe(u8, ""),
    };
    defer history.deinit(allocator);

    const messages = try workflow.transformMessageToAgentMessages(history);
    defer {
        for (messages) |*m| {
            if (m.content) |c| allocator.free(c);
            if (m.tool_call_id) |tid| allocator.free(tid);
            if (m.tool_calls) |tc| {
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

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent.Role.assistant, messages[0].role);
    try std.testing.expectEqualStrings("Hi there", messages[0].content.?);
}

test "transformMessageToAgentMessages with assistant and tool" {
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
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();

    var history = ask_llm_workflow.AskLLMHistory{
        .id = try allocator.dupe(u8, "test-id-2"),
        .session_id = try allocator.dupe(u8, "test-session-2"),
        .model = try allocator.dupe(u8, "test-model"),
        .created = try allocator.dupe(u8, "1234567890"),
        .response_content = try allocator.dupe(u8, "Here are the files"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "assistant"),
        .tools = try allocator.dupe(u8, ""),
    };
    defer history.deinit(allocator);

    const messages = try workflow.transformMessageToAgentMessages(history);
    defer {
        for (messages) |*m| {
            if (m.content) |c| allocator.free(c);
            if (m.tool_call_id) |tid| allocator.free(tid);
            if (m.tool_calls) |tc| {
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

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent.Role.assistant, messages[0].role);
    try std.testing.expectEqualStrings("Here are the files", messages[0].content.?);
}

test "transformMessageToAgentMessages with tool_calls finish_reason" {
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
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();

    var history = ask_llm_workflow.AskLLMHistory{
        .id = try allocator.dupe(u8, "test-id-3"),
        .session_id = try allocator.dupe(u8, "test-session-3"),
        .model = try allocator.dupe(u8, "test-model"),
        .created = try allocator.dupe(u8, "1234567890"),
        .response_content = try allocator.dupe(u8, "[{\"id\":\"call_abc\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}]"),
        .finish_reason = try allocator.dupe(u8, "tool_calls"),
        .role = try allocator.dupe(u8, "assistant"),
        .tools = try allocator.dupe(u8, ""),
    };
    defer history.deinit(allocator);

    const messages = try workflow.transformMessageToAgentMessages(history);
    defer {
        for (messages) |*m| {
            if (m.content) |c| allocator.free(c);
            if (m.tool_call_id) |tid| allocator.free(tid);
            if (m.tool_calls) |tc| {
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

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent.Role.assistant, messages[0].role);
    try std.testing.expect(messages[0].tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), messages[0].tool_calls.?.len);
    try std.testing.expectEqualStrings("call_abc", messages[0].tool_calls.?[0].id);
    try std.testing.expectEqualStrings("bash", messages[0].tool_calls.?[0].function.name);
}

test "transformMessageToAgentMessages with stop finish_reason" {
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
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();

    var history = ask_llm_workflow.AskLLMHistory{
        .id = try allocator.dupe(u8, "test-id-4"),
        .session_id = try allocator.dupe(u8, "test-session-4"),
        .model = try allocator.dupe(u8, "test-model"),
        .created = try allocator.dupe(u8, "1234567890"),
        .response_content = try allocator.dupe(u8, "Just a response"),
        .finish_reason = try allocator.dupe(u8, "stop"),
        .role = try allocator.dupe(u8, "assistant"),
        .tools = try allocator.dupe(u8, ""),
    };
    defer history.deinit(allocator);

    const messages = try workflow.transformMessageToAgentMessages(history);
    defer {
        for (messages) |*m| {
            if (m.content) |c| allocator.free(c);
            if (m.tool_call_id) |tid| allocator.free(tid);
            if (m.tool_calls) |tc| {
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

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(agent.Role.assistant, messages[0].role);
    try std.testing.expectEqualStrings("Just a response", messages[0].content.?);
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
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "test-session";
    workflow.model = "test-model";

    const response = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Hello from LLM",
        .tool_calls = null,
        .finish_reason = .stop,
    };

    try workflow.saveMessage(response, "assistant", "");

    const row = try db.queryRow(allocator, "SELECT response_content, finish_reason FROM llm_history WHERE session_id = ?", &.{"test-session"});
    defer row.deinit(allocator);

    try std.testing.expectEqualStrings("Hello from LLM", row.values[0]);
    try std.testing.expectEqualStrings("stop", row.values[1]);
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
    try workflow.saveMessage(response1, "assistant", "");

    const response2 = agent.Agent.CallResponse{
        .allocator = allocator,
        .content = "Second message",
        .tool_calls = null,
        .finish_reason = .stop,
    };
    try workflow.saveMessage(response2, "assistant", "");

    const messages = try workflow.getMessages();
    defer {
        for (messages) |*m| m.deinit(allocator);
        allocator.free(messages);
    }

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("First message", messages[0].response_content);
    try std.testing.expectEqualStrings("Second message", messages[1].response_content);
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
    try mgr.runMigrations();

    var workflow = ask_llm_workflow.AskLLMWorkflow.init(allocator, &db);
    defer workflow.deinit();
    workflow.session_id = "build-messages-test";
    workflow.model = "test-model";
    workflow.message = "What is 2+2?";

    const responseContent = try allocator.dupe(u8, "2 + 2 equals 4");
    try workflow.saveMessage(agent.Agent.CallResponse{
        .allocator = allocator,
        .content = responseContent,
        .tool_calls = null,
        .finish_reason = .stop,
    }, "assistant", "");
    allocator.free(responseContent);

    const messages = try workflow.buildMessages();
    defer {
        for (messages) |*msg| {
            if (msg.role == .assistant or msg.role == .tool) {
                if (msg.content) |c| allocator.free(c);
            }
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
    }, "assistant", "[tool_calls]");

    const messages = try workflow.buildMessages();
    defer {
        for (messages) |*msg| {
            if (msg.role == .assistant or msg.role == .tool) {
                if (msg.content) |c| allocator.free(c);
            }
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
