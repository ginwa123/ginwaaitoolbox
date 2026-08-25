// Static-contract tests for the config-simplify change in
// nalar_config_put.zig (plan 2026-08-24-config-simplify-remove-defaults).
//
// Per the user preference (2026-08-17 cleanup commit 91c0ee63): no
// HTTP handler `_test.zig` files. Same source-grep pattern as
// `nalar_config_put_thinking_test.zig` — lock in that the PUT handler
// no longer persists top-level LLM defaults to config.json.

const std = @import("std");
const testing = std.testing;

const PUT_HANDLER_PATH = "src/ai_workflow/tui/http_handlers/nalar_config_put.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &buf);
    return reader.interface.allocRemaining(allocator, .limited(128 * 1024));
}

test "PUT handler ConfigJson write struct has NO top-level LLM default fields" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);

    // The handler-local `ConfigJson` is the on-disk serializer — any
    // field on it gets re-emitted by Stringify.valueAlloc on save.
    // After config-simplify these fields must be gone so a PUT never
    // writes api_key/model/base_url/url_style/max_tokens/system_prompt
    // back to disk. (ProfileChange's per-profile fields of the same
    // names are FINE — scope the check to the ConfigJson block.)
    const start = std.mem.indexOf(u8, source, "const ConfigJson = struct {") orelse
        return error.ConfigJsonStructMissing;
    const end = std.mem.indexOfPos(u8, source, start, "};") orelse
        return error.ConfigJsonStructUnterminated;
    const block = source[start..end];

    const forbidden = [_][]const u8{
        "api_key:",
        "\n    model:",
        "base_url:",
        "url_style:",
        "max_tokens:",
        "system_prompt:",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, block, needle) != null) {
            std.debug.print("!! PUT handler ConfigJson still declares '{s}' !!\n", .{needle});
            return error.PutWriteStructStillHasDefaults;
        }
    }
}

test "PUT handler apply block no longer reads input.api_endpoint/api_key/model/url_style" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);

    // The old apply block wrote `config_json.base_url = ...input.api_endpoint`
    // etc. All six must be gone.
    const forbidden = [_][]const u8{
        "config_json.api_key = try allocator.dupe(u8, input.api_key)",
        "config_json.model = try allocator.dupe(u8, input.model)",
        "config_json.base_url = try allocator.dupe(u8, input.api_endpoint)",
        "config_json.url_style = try allocator.dupe(u8, input.url_style)",
        "config_json.max_tokens = try allocator.dupe(u8, mt)",
        "config_json.system_prompt = try allocator.dupe(u8, input.system_prompt)",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, source, needle) != null) {
            std.debug.print("!! PUT handler still applies '{s}' !!\n", .{needle});
            return error.PutApplyBlockStillWritesDefaults;
        }
    }
}

test "PUT handler still persists profiles + operational settings" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, PUT_HANDLER_PATH);
    defer allocator.free(source);

    // Guard against over-deletion: the fields we KEEP must still be
    // present in the write struct.
    const required = [_][]const u8{
        "profiles_models: ?json.Value = null",
        "active_profile: ?[]const u8 = null",
        "mcp_servers: ?json.Value = null",
        "notify_on_complete: bool = false",
        "model_compaction_size_kb: usize = 100",
        "max_capacity_token_model: ?u32 = null",
        "compaction_threshold_percent: ?u8 = null",
        "retry_delay_ms: u32 = 0",
        "sub_agents: ?[]LlmConfig.SubAgentJson = null",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print("!! PUT handler write struct lost required field '{s}' !!\n", .{needle});
            return error.PutWriteStructMissingRequiredField;
        }
    }
}
