const std = @import("std");
const testing = std.testing;
const LlmConfig = @import("Config.zig").LlmConfig;

test "LlmConfig.init populates user_identifier from existing config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.json",
        .data =
            \\{
            \\  "api_key": "test-key",
            \\  "model": "gpt-4o",
            \\  "base_url": "https://api.openai.com/v1",
            \\  "user_identifier": "preset-uuid-aaaa-bbbb"
            \\}
        ,
        .flags = .{ .truncate = true },
    });

    const config_path = try tmp.dir.realPathFileAlloc(testing.io, "config.json", testing.allocator);
    defer testing.allocator.free(config_path);

    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    var cfg = try LlmConfig.init(testing.allocator, testing.io, config_path, &env_map);
    defer cfg.deinit();

    try testing.expectEqualStrings("preset-uuid-aaaa-bbbb", cfg.user_identifier);
}

test "LlmConfig.init auto-generates user_identifier when missing and persists it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Existing config without user_identifier (legacy upgrade scenario).
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.json",
        .data =
            \\{
            \\  "api_key": "test-key",
            \\  "model": "gpt-4o",
            \\  "base_url": "https://api.openai.com/v1"
            \\}
        ,
        .flags = .{ .truncate = true },
    });

    const config_path = try tmp.dir.realPathFileAlloc(testing.io, "config.json", testing.allocator);
    defer testing.allocator.free(config_path);

    {
        var env_map = std.process.Environ.Map.init(testing.allocator);
        defer env_map.deinit();
        var cfg = try LlmConfig.init(testing.allocator, testing.io, config_path, &env_map);
        // user_identifier should be auto-generated and non-empty (UUID v4 length = 36).
        try testing.expect(cfg.user_identifier.len == 36);
        const first_uuid = try testing.allocator.dupe(u8, cfg.user_identifier);
        defer testing.allocator.free(first_uuid);
        cfg.deinit();

        // The file on disk should have been updated to include the new field.
        const on_disk = try std.Io.Dir.cwd().readFileAlloc(testing.io, config_path, testing.allocator, .limited(4096));
        defer testing.allocator.free(on_disk);
        try testing.expect(std.mem.indexOf(u8, on_disk, "\"user_identifier\":") != null);

        // Re-parsing should yield the SAME identifier (idempotent).
        var env_map2 = std.process.Environ.Map.init(testing.allocator);
        defer env_map2.deinit();
        var cfg2 = try LlmConfig.init(testing.allocator, testing.io, config_path, &env_map2);
        defer cfg2.deinit();
        try testing.expectEqualStrings(first_uuid, cfg2.user_identifier);
    }
}