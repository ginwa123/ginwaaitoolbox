const std = @import("std");
const json = std.json;
const testing = std.testing;
const mcp_types = @import("mcp_types.zig");

// Note: McpServer cannot be directly instantiated in tests because it contains
// a function pointer field (toolExecutor) which requires comptime.
// The server is tested via integration tests. This file tests the types.

// ============ Error Code Tests ============

test "McpError error codes match spec" {
    // Verify error codes match JSON-RPC 2.0 and MCP spec
    try testing.expectEqual(@as(i32, -32700), @intFromEnum(mcp_types.ErrorCode.ParseError));
    try testing.expectEqual(@as(i32, -32600), @intFromEnum(mcp_types.ErrorCode.InvalidRequest));
    try testing.expectEqual(@as(i32, -32601), @intFromEnum(mcp_types.ErrorCode.MethodNotFound));
    try testing.expectEqual(@as(i32, -32602), @intFromEnum(mcp_types.ErrorCode.InvalidParams));
    try testing.expectEqual(@as(i32, -32603), @intFromEnum(mcp_types.ErrorCode.InternalError));
    try testing.expectEqual(@as(i32, -32000), @intFromEnum(mcp_types.ErrorCode.ServerError));
}

// ============ Tool Definition Tests ============

test "McpTool structure is valid" {
    const tool = mcp_types.McpTool{
        .name = "test_tool",
        .description = "A test tool description",
        .inputSchema = .{
            .@"type" = "object",
            .properties = .{ .null = {} },
            .required = &.{ "param1", "param2" },
        },
    };

    try testing.expectEqualStrings("test_tool", tool.name);
    try testing.expectEqualStrings("A test tool description", tool.description);
    try testing.expectEqualStrings("object", tool.inputSchema.@"type");
    try testing.expect(tool.inputSchema.required != null);
    try testing.expectEqual(@as(usize, 2), tool.inputSchema.required.?.len);
}

test "McpTool with null required fields" {
    const tool = mcp_types.McpTool{
        .name = "simple_tool",
        .description = "Simple tool",
        .inputSchema = .{
            .@"type" = "object",
            .properties = .{ .null = {} },
            .required = null,
        },
    };

    try testing.expectEqualStrings("simple_tool", tool.name);
    try testing.expect(tool.inputSchema.required == null);
}

// ============ Server Capabilities Tests ============

test "ServerCapabilities default values" {
    const caps = mcp_types.ServerCapabilities{
        .tools = .{ .listChanged = false },
        .resources = null,
    };

    try testing.expect(caps.tools != null);
    try testing.expect(caps.tools.?.listChanged == false);
    try testing.expect(caps.resources == null);
}

test "ServerCapabilities with resources" {
    const caps = mcp_types.ServerCapabilities{
        .tools = .{ .listChanged = true },
        .resources = .{ .subscribe = true, .listChanged = true },
    };

    try testing.expect(caps.tools.?.listChanged == true);
    try testing.expect(caps.resources != null);
    try testing.expect(caps.resources.?.subscribe == true);
    try testing.expect(caps.resources.?.listChanged == true);
}

// ============ Resource Tests ============

test "Resource structure" {
    const resource = mcp_types.Resource{
        .uri = "file:///test.txt",
        .name = "test.txt",
        .description = "A test file",
        .mimeType = "text/plain",
    };

    try testing.expectEqualStrings("file:///test.txt", resource.uri);
    try testing.expectEqualStrings("test.txt", resource.name);
    try testing.expectEqualStrings("A test file", resource.description.?);
    try testing.expectEqualStrings("text/plain", resource.mimeType.?);
}

test "Resource with optional fields null" {
    const resource = mcp_types.Resource{
        .uri = "file:///test.txt",
        .name = "test.txt",
        .description = null,
        .mimeType = null,
    };

    try testing.expect(resource.description == null);
    try testing.expect(resource.mimeType == null);
}

// ============ Prompt Tests ============

test "Prompt structure" {
    const prompt = mcp_types.Prompt{
        .name = "test_prompt",
        .description = "A test prompt",
        .arguments = &.{.{
            .name = "arg1",
            .description = "First argument",
            .required = true,
        }},
    };

    try testing.expectEqualStrings("test_prompt", prompt.name);
    try testing.expectEqualStrings("A test prompt", prompt.description.?);
    try testing.expect(prompt.arguments != null);
    try testing.expectEqual(@as(usize, 1), prompt.arguments.?.len);
}

// ============ Content Block Tests ============

test "ContentBlock text type" {
    const block = mcp_types.ContentBlock{
        .@"type" = "text",
        .text = "Hello world",
        .resource = null,
    };

    try testing.expectEqualStrings("text", block.@"type");
    try testing.expectEqualStrings("Hello world", block.text.?);
    try testing.expect(block.resource == null);
}

test "ContentBlock with resource" {
    const resource_content = mcp_types.ResourceContents{
        .uri = "file:///test.txt",
        .mimeType = "text/plain",
        .text = "File content",
        .blob = null,
    };

    const block = mcp_types.ContentBlock{
        .@"type" = "resource",
        .text = null,
        .resource = resource_content,
    };

    try testing.expectEqualStrings("resource", block.@"type");
    try testing.expect(block.text == null);
    try testing.expect(block.resource != null);
    try testing.expectEqualStrings("file:///test.txt", block.resource.?.uri);
}

// ============ Completion Tests ============

test "CompleteParams structure" {
    const params = mcp_types.CompleteParams{
        .ref = .{ .type = "resource" },
        .argument = .{
            .name = "uri",
            .value = "file:///",
        },
    };

    try testing.expectEqualStrings("resource", params.ref.type);
    try testing.expectEqualStrings("uri", params.argument.name);
    try testing.expectEqualStrings("file:///", params.argument.value);
}

test "Completion result structure" {
    const completion = mcp_types.Completion{
        .values = &.{ "option1", "option2", "option3" },
        .total = 3,
        .hasMore = false,
    };

    try testing.expectEqual(@as(usize, 3), completion.values.len);
    try testing.expectEqual(@as(i32, 3), completion.total.?);
    try testing.expect(completion.hasMore.? == false);
}

// ============ Initialize Params Tests ============

test "InitializeParams with client info" {
    const params = mcp_types.InitializeParams{
        .protocolVersion = "2024-11-05",
        .capabilities = .{},
        .clientInfo = .{
            .name = "test-client",
            .version = "1.0.0",
        },
    };

    try testing.expectEqualStrings("2024-11-05", params.protocolVersion.?);
    try testing.expectEqualStrings("test-client", params.clientInfo.?.name);
    try testing.expectEqualStrings("1.0.0", params.clientInfo.?.version);
}

// ============ CallToolParams Tests ============

test "CallToolParams structure" {
    const params = mcp_types.CallToolParams{
        .name = "test_tool",
        .arguments = null,
    };

    try testing.expectEqualStrings("test_tool", params.name);
    try testing.expect(params.arguments == null);
}

// ============ ReadResourceParams Tests ============

test "ReadResourceParams structure" {
    const params = mcp_types.ReadResourceParams{
        .uri = "file:///test.txt",
    };

    try testing.expectEqualStrings("file:///test.txt", params.uri);
}

// ============ SetLevelParams Tests ============

test "SetLevelParams structure" {
    const params = mcp_types.SetLevelParams{
        .level = "info",
    };

    try testing.expectEqualStrings("info", params.level);
}

// ============ ResourceContents Tests ============

test "ResourceContents with text" {
    const contents = mcp_types.ResourceContents{
        .uri = "file:///test.txt",
        .mimeType = "text/plain",
        .text = "File content here",
        .blob = null,
    };

    try testing.expectEqualStrings("file:///test.txt", contents.uri);
    try testing.expectEqualStrings("text/plain", contents.mimeType.?);
    try testing.expectEqualStrings("File content here", contents.text.?);
    try testing.expect(contents.blob == null);
}

test "ResourceContents with blob" {
    const blob_data = "binary data";
    const contents = mcp_types.ResourceContents{
        .uri = "file:///test.bin",
        .mimeType = "application/octet-stream",
        .text = null,
        .blob = blob_data,
    };

    try testing.expectEqualStrings("file:///test.bin", contents.uri);
    try testing.expect(contents.text == null);
    try testing.expect(contents.blob != null);
}

// ============ PromptMessage Tests ============

test "PromptMessage text content" {
    const message = mcp_types.PromptMessage{
        .role = "user",
        .content = .{ .text = "Hello" },
    };

    try testing.expectEqualStrings("user", message.role);
}

test "PromptMessage image content" {
    const image = mcp_types.ImageContent{
        .data = "base64data",
        .mimeType = "image/png",
    };
    const message = mcp_types.PromptMessage{
        .role = "assistant",
        .content = .{ .image = image },
    };

    try testing.expectEqualStrings("assistant", message.role);
}

// ============ GetPromptParams Tests ============

test "GetPromptParams structure" {
    const params = mcp_types.GetPromptParams{
        .name = "test_prompt",
        .arguments = null,
    };

    try testing.expectEqualStrings("test_prompt", params.name);
    try testing.expect(params.arguments == null);
}

// ============ PromptArgument Tests ============

test "PromptArgument structure" {
    const arg = mcp_types.PromptArgument{
        .name = "input",
        .description = "User input",
        .required = true,
    };

    try testing.expectEqualStrings("input", arg.name);
    try testing.expectEqualStrings("User input", arg.description.?);
    try testing.expect(arg.required.? == true);
}

// ============ ImageContent Tests ============

test "ImageContent structure" {
    const image = mcp_types.ImageContent{
        .data = "base64encodeddata",
        .mimeType = "image/jpeg",
    };

    try testing.expectEqualStrings("base64encodeddata", image.data);
    try testing.expectEqualStrings("image/jpeg", image.mimeType);
}

// ============ CompletionReference Tests ============

test "CompletionReference type variant" {
    const ref = mcp_types.CompletionReference{ .type = "resource" };
    try testing.expectEqualStrings("resource", ref.type);
}

test "CompletionReference name variant" {
    const ref = mcp_types.CompletionReference{ .name = "my_resource" };
    try testing.expectEqualStrings("my_resource", ref.name);
}

// ============ CompletionArgument Tests ============

test "CompletionArgument structure" {
    const arg = mcp_types.CompletionArgument{
        .name = "prefix",
        .value = "test",
    };

    try testing.expectEqualStrings("prefix", arg.name);
    try testing.expectEqualStrings("test", arg.value);
}

// ============ ListPromptsResult Tests ============

test "ListPromptsResult empty" {
    const result = mcp_types.ListPromptsResult{
        .prompts = &.{},
    };

    try testing.expectEqual(@as(usize, 0), result.prompts.len);
}

test "ListPromptsResult with prompts" {
    const prompts = [_]mcp_types.Prompt{
        .{ .name = "prompt1", .description = "First", .arguments = null },
        .{ .name = "prompt2", .description = "Second", .arguments = null },
    };
    const result = mcp_types.ListPromptsResult{
        .prompts = &prompts,
    };

    try testing.expectEqual(@as(usize, 2), result.prompts.len);
}

// ============ ListToolsResult Tests ============

test "ListToolsResult empty" {
    const result = mcp_types.ListToolsResult{
        .tools = &.{},
    };

    try testing.expectEqual(@as(usize, 0), result.tools.len);
}

test "ListToolsResult with tools" {
    const tools = [_]mcp_types.McpTool{
        .{
            .name = "tool1",
            .description = "First tool",
            .inputSchema = .{ .@"type" = "object", .properties = .{ .null = {} }, .required = null },
        },
        .{
            .name = "tool2",
            .description = "Second tool",
            .inputSchema = .{ .@"type" = "object", .properties = .{ .null = {} }, .required = null },
        },
    };
    const result = mcp_types.ListToolsResult{
        .tools = &tools,
    };

    try testing.expectEqual(@as(usize, 2), result.tools.len);
}

// ============ CallToolResult Tests ============

test "CallToolResult success" {
    const content = [_]mcp_types.ContentBlock{
        .{ .@"type" = "text", .text = "Result", .resource = null },
    };
    const result = mcp_types.CallToolResult{
        .content = &content,
        .isError = false,
    };

    try testing.expect(result.isError == false);
    try testing.expectEqual(@as(usize, 1), result.content.len);
}

test "CallToolResult error" {
    const content = [_]mcp_types.ContentBlock{
        .{ .@"type" = "text", .text = "Error occurred", .resource = null },
    };
    const result = mcp_types.CallToolResult{
        .content = &content,
        .isError = true,
    };

    try testing.expect(result.isError == true);
}

// ============ ListResourcesResult Tests ============

test "ListResourcesResult empty" {
    const result = mcp_types.ListResourcesResult{
        .resources = &.{},
    };

    try testing.expectEqual(@as(usize, 0), result.resources.len);
}

test "ListResourcesResult with resources" {
    const resources = [_]mcp_types.Resource{
        .{ .uri = "file:///a.txt", .name = "a.txt", .description = null, .mimeType = null },
        .{ .uri = "file:///b.txt", .name = "b.txt", .description = null, .mimeType = null },
    };
    const result = mcp_types.ListResourcesResult{
        .resources = &resources,
    };

    try testing.expectEqual(@as(usize, 2), result.resources.len);
}

// ============ ReadResourceResult Tests ============

test "ReadResourceResult empty" {
    const result = mcp_types.ReadResourceResult{
        .contents = &.{},
    };

    try testing.expectEqual(@as(usize, 0), result.contents.len);
}

test "ReadResourceResult with contents" {
    const contents = [_]mcp_types.ResourceContents{
        .{ .uri = "file:///test.txt", .mimeType = "text/plain", .text = "Content", .blob = null },
    };
    const result = mcp_types.ReadResourceResult{
        .contents = &contents,
    };

    try testing.expectEqual(@as(usize, 1), result.contents.len);
}

// ============ CompleteResult Tests ============

test "CompleteResult structure" {
    const completion = mcp_types.Completion{
        .values = &.{ "opt1", "opt2" },
        .total = 2,
        .hasMore = false,
    };
    const result = mcp_types.CompleteResult{
        .completion = completion,
    };

    try testing.expectEqual(@as(usize, 2), result.completion.values.len);
}

// ============ GetPromptResult Tests ============

test "GetPromptResult structure" {
    const messages = [_]mcp_types.PromptMessage{};
    const result = mcp_types.GetPromptResult{
        .description = "Test description",
        .messages = &messages,
    };

    try testing.expectEqualStrings("Test description", result.description.?);
    try testing.expectEqual(@as(usize, 0), result.messages.len);
}

// ============ ToolsCapability Tests ============

test "ToolsCapability default" {
    const cap = mcp_types.ToolsCapability{ .listChanged = false };
    try testing.expect(cap.listChanged == false);
}

test "ToolsCapability with listChanged true" {
    const cap = mcp_types.ToolsCapability{ .listChanged = true };
    try testing.expect(cap.listChanged == true);
}

// ============ ResourcesCapability Tests ============

test "ResourcesCapability default" {
    const cap = mcp_types.ResourcesCapability{ .subscribe = false, .listChanged = false };
    try testing.expect(cap.subscribe == false);
    try testing.expect(cap.listChanged == false);
}

test "ResourcesCapability with all features" {
    const cap = mcp_types.ResourcesCapability{ .subscribe = true, .listChanged = true };
    try testing.expect(cap.subscribe == true);
    try testing.expect(cap.listChanged == true);
}

// ============ PromptsCapability Tests ============

test "PromptsCapability default" {
    const cap = mcp_types.PromptsCapability{ .listChanged = false };
    try testing.expect(cap.listChanged == false);
}

test "PromptsCapability with listChanged" {
    const cap = mcp_types.PromptsCapability{ .listChanged = true };
    try testing.expect(cap.listChanged == true);
}

// ============ CompletionsCapability Tests ============

test "CompletionsCapability exists" {
    const cap = mcp_types.CompletionsCapability{};
    _ = cap; // Just verify it compiles
}

// ============ LoggingCapability Tests ============

test "LoggingCapability exists" {
    const cap = mcp_types.LoggingCapability{};
    _ = cap; // Just verify it compiles
}

// ============ InitializeCapabilities Tests ============

test "InitializeCapabilities exists" {
    const caps = mcp_types.InitializeCapabilities{};
    _ = caps; // Just verify it compiles
}

// ============ ClientInfo Tests ============

test "ClientInfo structure" {
    const info = mcp_types.ClientInfo{
        .name = "test-client",
        .version = "1.0.0",
    };

    try testing.expectEqualStrings("test-client", info.name);
    try testing.expectEqualStrings("1.0.0", info.version);
}

// ============ JsonRpcRequest Tests ============

test "JsonRpcRequest default values" {
    const req = mcp_types.JsonRpcRequest{
        .method = "test",
    };

    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expect(req.id == null);
    try testing.expect(req.params == null);
}

test "JsonRpcRequest with all fields" {
    const req = mcp_types.JsonRpcRequest{
        .jsonrpc = "2.0",
        .id = "123",
        .method = "tools/list",
        .params = "{}",
    };

    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expectEqualStrings("123", req.id.?);
    try testing.expectEqualStrings("tools/list", req.method);
    try testing.expectEqualStrings("{}", req.params.?);
}

// ============ JsonRpcResponse Tests ============

test "JsonRpcResponse default values" {
    const resp = mcp_types.JsonRpcResponse{
        .id = null,
    };

    try testing.expectEqualStrings("2.0", resp.jsonrpc);
    try testing.expect(resp.id == null);
    try testing.expect(resp.result == null);
    try testing.expect(resp.@"error" == null);
}

// ============ JsonRpcError Tests ============

test "JsonRpcError structure" {
    const err = mcp_types.JsonRpcError{
        .code = -32600,
        .message = "Invalid Request",
        .data = null,
    };

    try testing.expectEqual(@as(i32, -32600), err.code);
    try testing.expectEqualStrings("Invalid Request", err.message);
    try testing.expect(err.data == null);
}

test "JsonRpcError with data" {
    const err = mcp_types.JsonRpcError{
        .code = -32602,
        .message = "Invalid params",
        .data = "Additional info",
    };

    try testing.expectEqualStrings("Additional info", err.data.?);
}
