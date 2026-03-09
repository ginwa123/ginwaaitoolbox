const std = @import("std");

pub const LspError = error{
    ProcessSpawnFailed,
    BinaryNotFound,
    HandshakeFailed,
    RequestTimeout,
    InvalidResponse,
    NotInitialized,
    AlreadyInitialized,
    SessionNotFound,
    JsonParseError,
    ProcessNotRunning,
};

pub const InitializeParams = struct {
    process_id: ?i32,
    client_info: ClientInfo,
    workspace_folders: ?[]const WorkspaceFolder,
};

pub const ClientInfo = struct {
    name: []const u8,
    version: ?[]const u8,
};

pub const WorkspaceFolder = struct {
    uri: []const u8,
    name: []const u8,
};

pub const ServerCapabilities = struct {
    text_document_sync: ?i32 = null,
    hover_provider: ?bool = null,
    definition_provider: ?bool = null,
    references_provider: ?bool = null,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Diagnostic = struct {
    severity: i32,
    message: []const u8,
    range: Range,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const InitializeResult = struct {
    capabilities: ServerCapabilities,
};

// Binary search paths
pub const common_binary_paths = [_][]const u8{
    "/usr/bin",
    "/usr/local/bin",
    "/home/.local/bin",
    "/home/.local/share/nvim/mason/bin",
    "/opt/homebrew/bin",
    "/home/ginwa/.local/bin",
    "/home/ginwa/.local/share/nvim/mason/bin",
};

test {
    _ = @import("lsp_types_test.zig");
}
