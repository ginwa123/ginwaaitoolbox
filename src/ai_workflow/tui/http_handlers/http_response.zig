const std = @import("std");
const llm_history = @import("../llm_history.zig");

pub const WorkspaceResponse = struct {
    id: []const u8,
    name: []const u8,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null
};

pub const WorkspaceItemResponse = struct {
    id: []const u8,
    success: bool = true
};

pub const WorkspaceItemFullResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null
};

pub const LlmRunResponse = struct {
    status: []const u8,
    session_id: []const u8
};

pub const WorkspaceItemUpdateResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    success: bool = true
};

pub const WorkspaceItemGetResponse = struct {
    id: []const u8,
    workspace_id: []const u8,
    item_type: []const u8,
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null
};

pub const SystemFolderErrorResponse = struct {
    @"error": []const u8,
    details: ?[]const u8 = null
};

pub const SessionCreateResponse = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8
};

pub const SessionUpdateResponse = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    selected_profile_model: []const u8,
};

pub const WorkerResponse = struct {
    id: []const u8,
    status: []const u8
};

pub const HealthResponse = struct {
    status: []const u8,
    timestamp: i64
};

pub const TaskDeleteResponse = struct {
    id: []const u8,
    success: bool = true
};

pub const TaskCreateResponse = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8,
    completed: bool
};

// Request types
pub const TaskCreateRequest = struct {
    name: []const u8,
    session_id: ?[]const u8 = null,
};

pub const TaskUpdateRequest = struct {
    name: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

pub const GitStageResponse = struct {
    success: bool,
    message: []const u8,
    staged_files: []const []const u8,
    failed_files: []const []const u8 = &.{},
};

pub const WorkerInfo = struct {
    id: []const u8,
    session_id: []const u8,
    working_directory: ?[]const u8,
    last_activity: ?[]const u8,
    last_activity_description: ?[]const u8,
    created_at: ?[]const u8,
    status: []const u8,
    is_running: bool,
    queue_count: u32
};

pub const WorkerListResponse = struct {
    workers: []const WorkerInfo,
    count: u32
};

pub const SessionMessage = struct {
    id: []const u8,
    session_id: []const u8,
    role: []const u8,
    content: []const u8,
    created_at: []const u8,
    is_input: []const u8,
    is_output: []const u8,
    tool_name: []const u8,
    finish_reason: []const u8,
    reasoning_content: []const u8,
    diffview_before: []const u8 = "",
    diffview_after: []const u8 = "",
    image_url: []const u8 = "",
    tool_call_id: []const u8 = "",
    tool_calls_json: []const u8 = "",
};

pub const SessionMessagesResponse = struct {
    messages: []const SessionMessage,
    has_more: bool,
    next_cursor: ?[]const u8,
    cwd: ?[]const u8 = null,
    max_total_tokens: u32 = 0,
    max_capacity_total_tokens: u32 = 0,
    total: ?u32 = null,  // Total count of messages for VirtualScroller
    skills: ?[]const llm_history.SkillInfo = null, // Skills loaded for this session
};

pub fn makeSessionMessagesResponse(allocator: std.mem.Allocator, response: SessionMessagesResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{
        .emit_strings_as_arrays = false,
    });
}

pub fn makeSystemFolderErrorResponse(allocator: std.mem.Allocator, message: []const u8, err: anytype) ![]u8 {
    const response = SystemFolderErrorResponse{
        .@"error" = message,
        .details = @errorName(err),
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeSessionCreateResponse(allocator: std.mem.Allocator, response: SessionCreateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{

    });
}

pub fn makeSessionUpdateResponse(allocator: std.mem.Allocator, response: SessionUpdateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkerResponse(allocator: std.mem.Allocator, response: WorkerResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeHealthResponse(allocator: std.mem.Allocator, response: HealthResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeTaskDeleteResponse(allocator: std.mem.Allocator, response: TaskDeleteResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeTaskCreateResponse(allocator: std.mem.Allocator, response: TaskCreateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkerListResponse(allocator: std.mem.Allocator, workers: []const WorkerInfo, count: u32) ![]u8 {
    const response = WorkerListResponse{
        .workers = workers,
        .count = count,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub const ErrorResponse = struct {
    @"error": []const u8
};

pub fn makeErrorResponse(allocator: std.mem.Allocator, response: ErrorResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub const NalarConfigResponse = struct {
    api_endpoint: []const u8,
    api_key: []const u8,
    model: []const u8,
    url_style: []const u8,
    temperature: f64,
    max_tokens: ?usize,
    system_prompt: []const u8,
    profiles: ?std.json.Value = null,
    active_profile: ?[]const u8 = null,
    /// Map of MCP server name to its raw JSON config (`{"url": "...", "headers": {...}}`).
    /// Sent as-is so the frontend gets full fidelity (header values, etc.).
    mcp_servers: ?std.json.Value = null,
};

pub fn makeNalarConfigResponse(allocator: std.mem.Allocator, response: NalarConfigResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceResponse(allocator: std.mem.Allocator, response: WorkspaceResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemResponse(allocator: std.mem.Allocator, response: WorkspaceItemResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeLlmRunResponse(allocator: std.mem.Allocator, response: LlmRunResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemUpdateResponse(allocator: std.mem.Allocator, response: WorkspaceItemUpdateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemGetResponse(allocator: std.mem.Allocator, response: WorkspaceItemGetResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemFullResponse(allocator: std.mem.Allocator, response: WorkspaceItemFullResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemListResponse(allocator: std.mem.Allocator, items: anytype) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "[");
    for (items, 0..) |item, i| {
        if (i > 0) try list.appendSlice(allocator, ",");
        const json_str = try std.json.Stringify.valueAlloc(allocator, WorkspaceItemFullResponse{
            .id = item.id,
            .workspace_id = item.workspace_id,
            .item_type = item.item_type,
            .name = item.name,
            .path = item.path,
            .created_at = item.created_at,
            .updated_at = item.updated_at,
        }, .{});
        defer allocator.free(json_str);
        try list.appendSlice(allocator, json_str);
    }
    try list.appendSlice(allocator, "]");
    return try list.toOwnedSlice(allocator);
}

/// Object-wrapped variant of `makeWorkspaceItemListResponse`.
/// Returns `{"items":[...],"count":N}` to match the shape the desktop store's
/// `getWorkspacesItems` frontend wrapper expects. Delegates the inner array
/// build to the bare-array helper to avoid duplicating the item-shape logic.
pub fn makeWorkspaceItemListObjectResponse(allocator: std.mem.Allocator, items: anytype) ![]u8 {
    const array_json = try makeWorkspaceItemListResponse(allocator, items);
    defer allocator.free(array_json);

    return std.fmt.allocPrint(allocator, "{{\"items\":{s},\"count\":{d}}}", .{ array_json, items.len });
}

// Workspace Item Task types
pub const WorkspaceItemTaskResponse = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    session_id: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null
};

pub const WorkspaceItemTaskListResponse = struct {
    tasks: []const WorkspaceItemTaskResponse,
    count: u32
};

pub fn makeWorkspaceItemTaskResponse(allocator: std.mem.Allocator, response: WorkspaceItemTaskResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeWorkspaceItemTaskListResponse(allocator: std.mem.Allocator, tasks: []const WorkspaceItemTaskResponse) ![]u8 {
    const response = WorkspaceItemTaskListResponse{
        .tasks = tasks,
        .count = @intCast(tasks.len),
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// Git status types
pub const GitStatusResponse = struct {
    is_git_repo: bool,
    branch: ?[]const u8 = null,
    has_changes: bool = false,
    is_clean: bool = true,
    status: ?[]const u8 = null
};

pub const GitStatusErrorResponse = struct {
    @"error": []const u8
};

pub fn makeGitStatusResponse(allocator: std.mem.Allocator, response: GitStatusResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeGitStatusErrorResponse(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const response = GitStatusErrorResponse{
        .@"error" = message,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeGitStageResponse(allocator: std.mem.Allocator, response: GitStageResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

// Profile types
pub const LlmProfileResponse = struct {
    name: []const u8,
    model: []const u8,
    base_url: []const u8,
    thinking: []const u8,
    temperature: []const u8,
    api_key: []const u8,
};

pub const ProfilesListResponse = struct {
    profiles: []const LlmProfileResponse,
    count: u32,
    active_profile: ?[]const u8 = null,
};

pub fn makeProfilesListResponse(allocator: std.mem.Allocator, profiles: []const LlmProfileResponse, active_profile: ?[]const u8) ![]u8 {
    const response = ProfilesListResponse{
        .profiles = profiles,
        .count = @intCast(profiles.len),
        .active_profile = active_profile,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}
