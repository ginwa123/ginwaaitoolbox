const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const glob = @import("glob.zig");
const GlobInput = glob.GlobInput;
const GlobMatch = glob.GlobMatch;
const GlobResult = glob.GlobResult;
const execute_glob = glob.execute_glob;
const glob_result_to_string = glob.glob_result_to_string;

// ============================================================================
// Basic Input Tests
// ============================================================================

test "GlobInput default values" {
    const input = GlobInput{};
    try expect(std.mem.eql(u8, input.pattern, "*"));
    try expect(std.mem.eql(u8, input.path, "."));
}

test "GlobInput with pattern" {
    const input = GlobInput{ .pattern = "*.zig" };
    try expect(std.mem.eql(u8, input.pattern, "*.zig"));
}

// ============================================================================
// execute_glob Tests
// ============================================================================

test "execute_glob finds zig files in src" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{ .pattern = "*.zig", .path = "src/" };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    // Just check it doesn't crash and returns results
    _ = result.matches.items.len;
}

test "execute_glob with max_results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{ .pattern = "*.zig", .path = "src/", .max_results = 5 };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    try expect(result.matches.items.len <= 5);
}

test "execute_glob with offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // First get all results
    const input_all = GlobInput{ .pattern = "*.zig", .path = "src/" };
    var result_all = try execute_glob(allocator, input_all);
    defer result_all.deinit(allocator);

    if (result_all.matches.items.len > 5) {
        // Now get with offset
        const input_offset = GlobInput{ .pattern = "*.zig", .path = "src/", .offset = 5, .max_results = 5 };
        var result_offset = try execute_glob(allocator, input_offset);
        defer result_offset.deinit(allocator);

        // Should have offset_applied
        try expect(result_offset.offset_applied == 5);
    }
}

test "execute_glob with hidden files option" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{ .pattern = ".*", .path = "src/", .hidden = true };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    _ = result.matches.items.len;
}

test "execute_glob handles non-existent path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{ .pattern = "*.zig", .path = "/nonexistent/path" };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    try expect(result.matches.items.len == 0);
}

test "execute_glob with file_type filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{ .pattern = "*", .path = "src/", .file_type = "f" };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    // Just check it doesn't crash
    _ = result.matches.items;
}

// ============================================================================
// Output Formatting Tests
// ============================================================================

test "glob_result_to_string formats correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = GlobResult{ .matches = std.ArrayList(GlobMatch).empty };
    defer result.deinit(allocator);

    try result.matches.append(allocator, .{ .path = "/path/to/file1.zig" });
    try result.matches.append(allocator, .{ .path = "/path/to/file2.zig" });

    const output = try glob_result_to_string(allocator, result);
    defer allocator.free(output);

    try expect(std.mem.containsAtLeast(u8, output, 1, "<f>/path/to/file1.zig</f>"));
    try expect(std.mem.containsAtLeast(u8, output, 1, "<f>/path/to/file2.zig</f>"));
}

test "glob_result_to_string handles empty result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = GlobResult{ .matches = std.ArrayList(GlobMatch).empty };
    defer result.deinit(allocator);

    const output = try glob_result_to_string(allocator, result);
    defer allocator.free(output);

    try expect(std.mem.indexOf(u8, output, "No files found") != null);
}

test "glob_result_to_string shows truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = GlobResult{ 
        .matches = std.ArrayList(GlobMatch).empty, 
        .truncated_count = 10,
        .total_found = 15,
    };
    defer result.deinit(allocator);

    try result.matches.append(allocator, .{ .path = "/path/to/file.zig" });

    const output = try glob_result_to_string(allocator, result);
    defer allocator.free(output);

    // Check for glob_summary with truncation info
    try expect(std.mem.containsAtLeast(u8, output, 1, "glob_summary"));
    try expect(std.mem.containsAtLeast(u8, output, 1, "total="));
}

// ============================================================================
// Memory Management Tests
// ============================================================================

test "GlobResult deinit cleans up memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = GlobResult{ .matches = std.ArrayList(GlobMatch).empty };

    try result.matches.append(allocator, .{ .path = try allocator.dupe(u8, "/test/path.zig") });
    try result.matches.append(allocator, .{ .path = try allocator.dupe(u8, "/test/other.zig") });

    result.deinit(allocator);
}

// ============================================================================
// Tool Definition Tests
// ============================================================================

test "glob_tool definition is valid" {
    const tool = glob.glob_tool;

    try expectEqualSlices(u8, "function", tool.type);
    try expectEqualSlices(u8, "glob", tool.function.name);
    try expect(tool.function.description.len > 0);
    try expectEqualSlices(u8, "object", tool.function.parameters.type);
    try expect(tool.function.parameters.properties.len > 0);
}

test "glob_tool has pattern property" {
    const tool = glob.glob_tool;

    var found_pattern = false;
    for (tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "pattern")) {
            found_pattern = true;
            try expectEqualSlices(u8, "string", prop.type);
            break;
        }
    }
    try expect(found_pattern);
}

test "glob_tool has path property" {
    const tool = glob.glob_tool;

    var found_path = false;
    for (tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "path")) {
            found_path = true;
            try expectEqualSlices(u8, "string", prop.type);
            break;
        }
    }
    try expect(found_path);
}

test "glob_tool has max_results property" {
    const tool = glob.glob_tool;

    var found_max_results = false;
    for (tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "max_results")) {
            found_max_results = true;
            try expectEqualSlices(u8, "number", prop.type);
            break;
        }
    }
    try expect(found_max_results);
}

test "glob_tool has hidden property" {
    const tool = glob.glob_tool;

    var found_hidden = false;
    for (tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "hidden")) {
            found_hidden = true;
            try expectEqualSlices(u8, "boolean", prop.type);
            break;
        }
    }
    try expect(found_hidden);
}

test "glob_tool required is empty" {
    const tool = glob.glob_tool;
    try expectEqual(0, tool.function.parameters.required.len);
}

// ============================================================================
// Pattern Matching Tests
// ============================================================================

test "pattern with glob characters matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{ .pattern = "test_*.zig", .path = "src/" };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    // Just check it doesn't crash
    _ = result.matches.items;
}

test "question mark pattern matches single char" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{ .pattern = "?.txt", .path = "." };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    // Just check it doesn't crash
    _ = result.matches.items;
}
