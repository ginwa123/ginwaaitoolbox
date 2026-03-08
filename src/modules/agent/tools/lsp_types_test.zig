const std = @import("std");
const lsp_types = @import("lsp_types.zig");

test "Position type can be instantiated" {
    const pos = lsp_types.Position{
        .line = 10,
        .character = 5,
    };
    try std.testing.expect(pos.line == 10);
    try std.testing.expect(pos.character == 5);
}

test "Range type can be instantiated" {
    const range = lsp_types.Range{
        .start = lsp_types.Position{ .line = 0, .character = 0 },
        .end = lsp_types.Position{ .line = 5, .character = 10 },
    };
    try std.testing.expect(range.start.line == 0);
    try std.testing.expect(range.end.line == 5);
}

test "Location type can be instantiated" {
    const loc = lsp_types.Location{
        .uri = "file:///test.zig",
        .range = lsp_types.Range{
            .start = lsp_types.Position{ .line = 1, .character = 2 },
            .end = lsp_types.Position{ .line = 1, .character = 8 },
        },
    };
    try std.testing.expect(std.mem.eql(u8, loc.uri, "file:///test.zig"));
    try std.testing.expect(loc.range.start.character == 2);
}

test "Diagnostic type can be instantiated" {
    const diag = lsp_types.Diagnostic{
        .severity = 1,
        .message = "test error",
        .range = lsp_types.Range{
            .start = lsp_types.Position{ .line = 0, .character = 0 },
            .end = lsp_types.Position{ .line = 0, .character = 5 },
        },
    };
    try std.testing.expect(diag.severity == 1);
    try std.testing.expect(std.mem.eql(u8, diag.message, "test error"));
}

test "ServerCapabilities default values" {
    const caps = lsp_types.ServerCapabilities{};
    try std.testing.expect(caps.text_document_sync == null);
    try std.testing.expect(caps.hover_provider == null);
    try std.testing.expect(caps.definition_provider == null);
    try std.testing.expect(caps.references_provider == null);
}

test "ServerCapabilities with values" {
    const caps = lsp_types.ServerCapabilities{
        .hover_provider = true,
        .definition_provider = true,
        .references_provider = true,
    };
    try std.testing.expect(caps.hover_provider == true);
    try std.testing.expect(caps.definition_provider == true);
    try std.testing.expect(caps.references_provider == true);
}

test "ClientInfo type can be instantiated" {
    const info = lsp_types.ClientInfo{
        .name = "test-client",
        .version = "1.0.0",
    };
    try std.testing.expect(std.mem.eql(u8, info.name, "test-client"));
    try std.testing.expect(std.mem.eql(u8, info.version.?, "1.0.0"));
}

test "ClientInfo without version" {
    const info = lsp_types.ClientInfo{
        .name = "test-client",
        .version = null,
    };
    try std.testing.expect(info.version == null);
}

test "WorkspaceFolder type can be instantiated" {
    const folder = lsp_types.WorkspaceFolder{
        .uri = "file:///workspace",
        .name = "workspace",
    };
    try std.testing.expect(std.mem.eql(u8, folder.uri, "file:///workspace"));
    try std.testing.expect(std.mem.eql(u8, folder.name, "workspace"));
}

test "InitializeParams type can be instantiated" {
    const params = lsp_types.InitializeParams{
        .process_id = 12345,
        .client_info = lsp_types.ClientInfo{
            .name = "test",
            .version = "1.0",
        },
        .workspace_folders = null,
    };
    try std.testing.expect(params.process_id == 12345);
}

test "InitializeResult type can be instantiated" {
    const result = lsp_types.InitializeResult{
        .capabilities = lsp_types.ServerCapabilities{
            .hover_provider = true,
        },
    };
    try std.testing.expect(result.capabilities.hover_provider == true);
}

test "common_binary_paths is not empty" {
    try std.testing.expect(lsp_types.common_binary_paths.len > 0);
}
