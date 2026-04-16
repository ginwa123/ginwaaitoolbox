//! Tests for activity info / worker table functionality

const std = @import("std");
const llm_history = @import("llm_history.zig");
const activity_registry = @import("nalarcore").session.activity_registry;
const build_prompt = @import("build_messages_for_agent_prompt.zig");

// =============================================================================
// WorkerInfo Tests
// =============================================================================

test "WorkerInfo struct exists with correct fields" {
    const info = llm_history.WorkerInfo{
        .session_id = "test-session-123",
        .working_directory = "/home/user/project",
        .last_activity = 1700000000,
        .last_activity_description = "reading file",
    };
    
    try std.testing.expect(std.mem.eql(u8, info.session_id, "test-session-123"));
    try std.testing.expect(std.mem.eql(u8, info.working_directory, "/home/user/project"));
    try std.testing.expect(info.last_activity == 1700000000);
    try std.testing.expect(std.mem.eql(u8, info.last_activity_description, "reading file"));
}

test "WorkerInfo deinit frees all fields" {
    var allocator = std.testing.allocator;
    
    var info = llm_history.WorkerInfo{
        .session_id = try allocator.dupe(u8, "my-session"),
        .working_directory = try allocator.dupe(u8, "/my/path"),
        .last_activity = 1700000000,
        .last_activity_description = try allocator.dupe(u8, "writing text"),
    };
    
    // Call deinit - should free all duplicated strings
    info.deinit(allocator);
    
    // If we get here without panic, deinit worked
    try std.testing.expect(true);
}

// =============================================================================
// Activity Registry Tests
// =============================================================================

test "activity_registry.get_global_registry is accessible" {
    const reg = activity_registry.get_global_registry();
    _ = reg;
    try std.testing.expect(true);
}

test "ActivityRegistry type exists" {
    const T = @TypeOf(activity_registry.ActivityRegistry);
    // Just verify the type exists and is accessible
    _ = T;
    try std.testing.expect(true);
}

// =============================================================================
// format_relative_time Tests - RED phase first (test the expected behavior)
// =============================================================================

test "format_relative_time: 0 seconds returns '< 1m'" {
    const result = build_prompt.format_relative_time(0);
    try std.testing.expect(std.mem.eql(u8, result, "< 1m"));
}

test "format_relative_time: 30 seconds returns '< 1m'" {
    const result = build_prompt.format_relative_time(30);
    try std.testing.expect(std.mem.eql(u8, result, "< 1m"));
}

test "format_relative_time: 59 seconds returns '< 1m'" {
    const result = build_prompt.format_relative_time(59);
    try std.testing.expect(std.mem.eql(u8, result, "< 1m"));
}

test "format_relative_time: 60 seconds (1 min) returns '1m'" {
    const result = build_prompt.format_relative_time(60);
    try std.testing.expect(std.mem.eql(u8, result, "1m"));
}

test "format_relative_time: 120 seconds (2 min) returns '2m'" {
    const result = build_prompt.format_relative_time(120);
    try std.testing.expect(std.mem.eql(u8, result, "2m"));
}

test "format_relative_time: 300 seconds (5 min) returns '2m'" {
    // Logic: 5 mins -> 5 < 10, so returns "2m" (bucketed)
    const result = build_prompt.format_relative_time(300);
    try std.testing.expect(std.mem.eql(u8, result, "2m"));
}

test "format_relative_time: 600 seconds (10 min) returns '5m'" {
    // Logic: 600s / 60 = 10 mins, 10 >= 10, so returns "5m" (bucketed)
    const result = build_prompt.format_relative_time(600);
    try std.testing.expect(std.mem.eql(u8, result, "5m"));
}

test "format_relative_time: 3600 seconds (1 hour) returns '1h'" {
    const result = build_prompt.format_relative_time(3600);
    try std.testing.expect(std.mem.eql(u8, result, "1h"));
}

test "format_relative_time: 21600 seconds (6 hours) returns '5h'" {
    const result = build_prompt.format_relative_time(21600);
    try std.testing.expect(std.mem.eql(u8, result, "5h"));
}

test "format_relative_time: 43200 seconds (12 hours) returns '12h+'" {
    const result = build_prompt.format_relative_time(43200);
    try std.testing.expect(std.mem.eql(u8, result, "12h+"));
}

test "format_relative_time: 86400 seconds (1 day) returns '> 24h'" {
    const result = build_prompt.format_relative_time(86400);
    try std.testing.expect(std.mem.eql(u8, result, "> 24h"));
}

test "format_relative_time: very large value (1 year) returns '> 24h'" {
    const result = build_prompt.format_relative_time(31536000);
    try std.testing.expect(std.mem.eql(u8, result, "> 24h"));
}

// =============================================================================
// Worker DB Functions Signature Tests
// =============================================================================

test "upsert_worker function exists" {
    const func = llm_history.upsert_worker;
    _ = func;
    try std.testing.expect(true);
}

test "update_worker_activity function exists" {
    const func = llm_history.update_worker_activity;
    _ = func;
    try std.testing.expect(true);
}

test "remove_worker function exists" {
    const func = llm_history.remove_worker;
    _ = func;
    try std.testing.expect(true);
}

test "get_active_workers function exists" {
    const func = llm_history.get_active_workers;
    _ = func;
    try std.testing.expect(true);
}

test "update_worker_activity_with_description function exists" {
    const func = llm_history.update_worker_activity_with_description;
    _ = func;
    try std.testing.expect(true);
}

test "update_worker_description function exists" {
    const func = llm_history.update_worker_description;
    _ = func;
    try std.testing.expect(true);
}

test "extract_activity_description handles empty content" {
    const result = llm_history.extract_activity_description("");
    try std.testing.expect(std.mem.eql(u8, result, "idle"));
}

test "extract_activity_description returns first line" {
    const content = "Let me analyze this...\nThen I'll do something";
    const result = llm_history.extract_activity_description(content);
    try std.testing.expect(std.mem.eql(u8, result, "Let me analyze this..."));
}

test "extract_activity_description truncates long lines" {
    const content = "This is a very long line that exceeds sixty characters and should be truncated";
    const result = llm_history.extract_activity_description(content);
    // Should be truncated to 60 chars or less
    try std.testing.expect(result.len <= 60);
}

test "extract_activity_description handles single word" {
    const content = "thinking";
    const result = llm_history.extract_activity_description(content);
    try std.testing.expect(std.mem.eql(u8, result, "thinking"));
}

test "extract_activity_description trims trailing whitespace" {
    const content = "My response   \n";
    const result = llm_history.extract_activity_description(content);
    try std.testing.expect(std.mem.eql(u8, result, "My response"));
}