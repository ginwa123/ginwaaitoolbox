const std = @import("std");

pub const WorkspaceResponse = struct {
    id: []const u8,
    name: []const u8
};

pub const WorkspaceItemResponse = struct {
    id: []const u8,
    success: bool = true
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
    item_type: []const u8
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

pub fn makeSystemFolderErrorResponse(allocator: std.mem.Allocator, message: []const u8, err: anytype) ![]u8 {
    const response = SystemFolderErrorResponse{
        .@"error" = message,
        .details = @errorName(err),
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn makeSessionCreateResponse(allocator: std.mem.Allocator, response: SessionCreateResponse) ![]u8 {
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

pub const ErrorResponse = struct {
    @"error": []const u8
};

pub fn makeErrorResponse(allocator: std.mem.Allocator, response: ErrorResponse) ![]u8 {
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

pub fn makeWorkspaceItemListResponse(allocator: std.mem.Allocator, items: anytype) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, "[");
    for (items, 0..) |item, i| {
        if (i > 0) try list.appendSlice(allocator, ",");
        const json_str = try std.json.Stringify.valueAlloc(allocator, WorkspaceItemGetResponse{
            .id = item.id,
            .workspace_id = item.workspace_id,
            .item_type = item.item_type,
        }, .{});
        defer allocator.free(json_str);
        try list.appendSlice(allocator, json_str);
    }
    try list.appendSlice(allocator, "]");
    return try list.toOwnedSlice(allocator);
}