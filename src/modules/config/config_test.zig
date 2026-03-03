const std = @import("std");
const config = @import("tree1").config;

// Helper to create unique temp file paths
fn getTempPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/config_test_" ++ suffix ++ ".json";
}

test "LlmConfig - parse valid JSON" {
    const allocator = std.testing.allocator;
    
    const config_path = getTempPath("valid");
    const config_content = 
        \\{
        \\  "api_key": "test-api-key-123",
        \\  "model": "test-model",
        \\  "base_url": "https://api.test.com/v1",
        \\  "model_compaction_size_kb": 50
        \\}
    ;
    
    const file = std.fs.createFileAbsolute(config_path, .{ .truncate = true }) catch return;
    defer file.close();
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    
    try file.writeAll(config_content);
    
    var cfg = try config.LlmConfig.init(allocator, config_path);
    defer cfg.deinit();
    
    try std.testing.expectEqualStrings("test-api-key-123", cfg.api_key);
    try std.testing.expectEqualStrings("test-model", cfg.model);
    try std.testing.expectEqualStrings("https://api.test.com/v1", cfg.base_url);
    try std.testing.expectEqual(@as(usize, 50), cfg.model_compaction_size_kb);
}

test "LlmConfig - validate missing api_key" {
    const allocator = std.testing.allocator;
    
    const config_path = getTempPath("no_api");
    const config_content = 
        \\{
        \\  "api_key": "",
        \\  "model": "test-model",
        \\  "base_url": "https://api.test.com/v1"
        \\}
    ;
    
    const file = std.fs.createFileAbsolute(config_path, .{ .truncate = true }) catch return;
    defer file.close();
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    
    try file.writeAll(config_content);
    
    var cfg = try config.LlmConfig.init(allocator, config_path);
    defer cfg.deinit();
    
    const result = cfg.validate();
    try std.testing.expectError(error.MissingRequiredField, result);
}

test "LlmConfig - validate missing model" {
    const allocator = std.testing.allocator;
    
    const config_path = getTempPath("no_model");
    const config_content = 
        \\{
        \\  "api_key": "test-key",
        \\  "model": "",
        \\  "base_url": "https://api.test.com/v1"
        \\}
    ;
    
    const file = std.fs.createFileAbsolute(config_path, .{ .truncate = true }) catch return;
    defer file.close();
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    
    try file.writeAll(config_content);
    
    var cfg = try config.LlmConfig.init(allocator, config_path);
    defer cfg.deinit();
    
    const result = cfg.validate();
    try std.testing.expectError(error.MissingRequiredField, result);
}

test "LlmConfig - validate missing base_url" {
    const allocator = std.testing.allocator;
    
    const config_path = getTempPath("no_url");
    const config_content = 
        \\{
        \\  "api_key": "test-key",
        \\  "model": "test-model",
        \\  "base_url": ""
        \\}
    ;
    
    const file = std.fs.createFileAbsolute(config_path, .{ .truncate = true }) catch return;
    defer file.close();
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    
    try file.writeAll(config_content);
    
    var cfg = try config.LlmConfig.init(allocator, config_path);
    defer cfg.deinit();
    
    const result = cfg.validate();
    try std.testing.expectError(error.MissingRequiredField, result);
}

test "LlmConfig - default model_compaction_size_kb" {
    const allocator = std.testing.allocator;
    
    const config_path = getTempPath("default");
    const config_content = 
        \\{
        \\  "api_key": "test-key",
        \\  "model": "test-model",
        \\  "base_url": "https://api.test.com/v1"
        \\}
    ;
    
    const file = std.fs.createFileAbsolute(config_path, .{ .truncate = true }) catch return;
    defer file.close();
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    
    try file.writeAll(config_content);
    
    var cfg = try config.LlmConfig.init(allocator, config_path);
    defer cfg.deinit();
    
    try std.testing.expectEqual(@as(usize, 100), cfg.model_compaction_size_kb);
}

test "LlmConfig - file not found" {
    const allocator = std.testing.allocator;
    
    const result = config.LlmConfig.init(allocator, "/nonexistent/path/config.json");
    try std.testing.expectError(error.ConfigFileNotFound, result);
}

test "LlmConfig - invalid JSON" {
    const allocator = std.testing.allocator;
    
    const config_path = getTempPath("bad_json");
    const config_content = "{ invalid json }";
    
    const file = std.fs.createFileAbsolute(config_path, .{ .truncate = true }) catch return;
    defer file.close();
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    
    try file.writeAll(config_content);
    
    const result = config.LlmConfig.init(allocator, config_path);
    try std.testing.expectError(error.InvalidJson, result);
}

test "getDefaultConfigDir - returns valid path" {
    const allocator = std.testing.allocator;
    
    const config_dir = config.getDefaultConfigDir(allocator) catch |err| {
        if (err == error.HomeNotFound or err == error.ConfigDirNotFound) return;
        return err;
    };
    defer allocator.free(config_dir);
    
    try std.testing.expect(config_dir.len > 0);
}

test "getDefaultConfigPath - returns valid path ending with config.json" {
    const allocator = std.testing.allocator;
    
    const config_path = config.getDefaultConfigPath(allocator) catch |err| {
        if (err == error.HomeNotFound or err == error.ConfigDirNotFound) return;
        return err;
    };
    defer allocator.free(config_path);
    
    try std.testing.expect(std.mem.endsWith(u8, config_path, "config.json"));
}

test "LlmConfig - ignore unknown fields" {
    const allocator = std.testing.allocator;
    
    const config_path = getTempPath("unknown");
    const config_content = 
        \\{
        \\  "api_key": "test-key",
        \\  "model": "test-model",
        \\  "base_url": "https://api.test.com/v1",
        \\  "unknown_field": "should be ignored",
        \\  "another_unknown": 123
        \\}
    ;
    
    const file = std.fs.createFileAbsolute(config_path, .{ .truncate = true }) catch return;
    defer file.close();
    defer std.fs.deleteFileAbsolute(config_path) catch {};
    
    try file.writeAll(config_content);
    
    var cfg = try config.LlmConfig.init(allocator, config_path);
    defer cfg.deinit();
    
    try std.testing.expectEqualStrings("test-key", cfg.api_key);
}
