const std = @import("std");
const lsp_client_core = @import("lsp_client_core.zig");
const AgentTool = @import("models.zig").AgentTool;

pub const LspStartInput = struct {
    session_id: []const u8,
    binary_name: []const u8,
    workspace_uri: []const u8,
};

pub const LspStartOutput = struct {
    session_id: []u8,
    binary_path: []u8,
    status: []u8,
};

pub fn executeLspStart(allocator: std.mem.Allocator, input: LspStartInput) !LspStartOutput {
    const client = try lsp_client_core.spawnLsp(allocator, input.session_id, input.binary_name, input.workspace_uri);

    // Try to initialize immediately - zls expects the initialize request right after spawn
    _ = lsp_client_core.initialize(allocator, client) catch |e| {
        std.debug.print("Warning: LSP initialize failed: {}\n", .{e});
        // Cleanup the client since initialization failed
        const sessions_ptr = lsp_client_core.getSessions();
        if (sessions_ptr.fetchRemove(input.session_id)) |kv| {
            allocator.free(kv.key);
        }
        client.deinit();
        allocator.destroy(client);
        return lsp_client_core.LspError.HandshakeFailed;
    };

    // Find binary path for output
    const binary_path = lsp_client_core.findBinary(allocator, input.binary_name) catch {
        return lsp_client_core.LspError.BinaryNotFound;
    };

    return .{
        .session_id = try allocator.dupe(u8, input.session_id),
        .binary_path = binary_path,
        .status = try allocator.dupe(u8, "started"),
    };
}

pub fn lspStartToString(allocator: std.mem.Allocator, result: LspStartOutput) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<session_id>{s}</session_id>
        \\<binary_path>{s}</binary_path>
        \\<status>{s}</status>
    , .{
        result.session_id,
        result.binary_path,
        result.status,
    });
}

pub const lspStartTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "lsp_start",
        .description = "Start an LSP server for a session. Searches for the binary in PATH and common locations.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "session_id",
                    .type = "string",
                    .description = "Unique session identifier",
                },
                .{
                    .name = "binary_name",
                    .type = "string",
                    .description = "LSP binary name (e.g., zls, clangd, pylsp)",
                },
                .{
                    .name = "workspace_uri",
                    .type = "string",
                    .description = "Workspace URI (e.g., file:///path/to/project)",
                },
            },
            .required = &.{ "session_id", "binary_name", "workspace_uri" },
        },
    },
};


test {
    _ = @import("lsp_start_test.zig");
}
