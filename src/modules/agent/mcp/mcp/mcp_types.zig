const std = @import("std");

// MCP uses JSON-RPC 2.0

/// JSON-RPC 2.0 request message
pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?[]const u8 = null,
    method: []const u8,
    params: ?[]const u8 = null, // Raw JSON params
};

/// JSON-RPC 2.0 response message  
pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?[]const u8,
    result: ?[]const u8 = null,
    error: ?JsonRpcError = null,
};

/// JSON-RPC 2.0 error
pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?[]const u8 = null,
};

/// MCP Initialize params (parsed from JSON)
pub const InitializeParams = struct {
    protocolVersion: ?[]const u8 = null,
    capabilities: ?InitializeCapabilities = null,
    clientInfo: ?ClientInfo = null,
};

pub const InitializeCapabilities = struct {};

pub const ClientInfo = struct {
    name: []const u8,
    version: []const u8,
};

/// MCP Server capabilities
pub const ServerCapabilities = struct {
    tools: ?ToolsCapability = null,
    resources: ?ResourcesCapability = null,
    prompts: ?PromptsCapability = null,
    completions: ?CompletionsCapability = null,
    logging: ?LoggingCapability = null,
};

pub const PromptsCapability = struct {
    listChanged: bool = false,
};

pub const CompletionsCapability = struct {};

pub const LoggingCapability = struct {};

/// MCP Prompt definition
pub const Prompt = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
};

pub const PromptArgument = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    required: ?bool = null,
};

/// MCP Prompts list result
pub const ListPromptsResult = struct {
    prompts: []const Prompt,
};

/// MCP Get prompt params
pub const GetPromptParams = struct {
    name: []const u8,
    arguments: ?std.json.Value = null,
};

/// MCP Get prompt result
pub const GetPromptResult = struct {
    description: ?[]const u8 = null,
    messages: []const PromptMessage,
};

pub const PromptMessage = struct {
    role: []const u8,
    content: PromptContent,
};

pub const PromptContent = union(enum) {
    text: []const u8,
    image: ImageContent,
    resource: ResourceContent,
};

pub const ImageContent = struct {
    data: []const u8,
    mimeType: []const u8,
};

pub const ResourceContent = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

/// MCP Completion params
pub const CompleteParams = struct {
    ref: CompletionReference,
    argument: CompletionArgument,
};

pub const CompletionReference = union(enum) {
    type: []const u8,
    name: []const u8,
};

pub const CompletionArgument = struct {
    name: []const u8,
    value: []const u8,
};

/// MCP Completion result
pub const CompleteResult = struct {
    completion: Completion,
};

pub const Completion = struct {
    values: []const []const u8,
    total: ?i32 = null,
    hasMore: ?bool = null,
};

/// MCP Set level params
pub const SetLevelParams = struct {
    level: []const u8,
};

pub const ToolsCapability = struct {
    listChanged: bool = false,
};

pub const ResourcesCapability = struct {
    subscribe: bool = false,
    listChanged: bool = false,
};

/// MCP Tool definition (MCP schema)
pub const McpTool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: InputSchema,
};

pub const InputSchema = struct {
    @"type": []const u8 = "object",
    properties: std.json.Value,
    required: ?[]const []const u8 = null,
};

/// MCP Tools list response
pub const ListToolsResult = struct {
    tools: []const McpTool,
};

/// MCP Tool call params
pub const CallToolParams = struct {
    name: []const u8,
    arguments: ?std.json.Value = null,
};

/// MCP Tool call result
pub const CallToolResult = struct {
    content: []const ContentBlock,
    isError: bool = false,
};

pub const ContentBlock = struct {
    @"type": []const u8,
    text: ?[]const u8 = null,
    resource: ?ResourceContents = null,
};

pub const ResourceContents = struct {
    uri: []const u8,
    mimeType: ?[]const u8 = null,
    text: ?[]const u8 = null,
    blob: ?[]const u8 = null,
};

/// MCP Resource definition
pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

/// MCP Resources list result
pub const ListResourcesResult = struct {
    resources: []const Resource,
};

/// MCP Resource read params
pub const ReadResourceParams = struct {
    uri: []const u8,
};

/// MCP Resource read result
pub const ReadResourceResult = struct {
    contents: []const ResourceContents,
};

// Error codes
pub const ErrorCode = enum(i32) {
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,
    ServerError = -32000,
};
