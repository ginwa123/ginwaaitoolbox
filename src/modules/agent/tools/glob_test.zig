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

test "GlobInput default values" {
    const input = GlobInput{
        .any = "",
    };
    try expect(input.any.len == 0);
}

test "GlobInput with pattern-style any" {
    const input = GlobInput{
        .any = "-e zig src/",
    };
    try expect(input.any.len > 0);
}

test "execute_glob finds zig files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .any = "-e zig src/",
    };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    try expect(result.matches.items.len > 0);
    // First match should end with .zig
    try expect(std.mem.endsWith(u8, result.matches.items[0].path, ".zig"));
}

test "execute_glob with hidden files enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .any = ".* src/ -H",
    };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    // Should complete without error
    _ = result.matches.items.len;
}

test "execute_glob with extension filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .any = "-e zig src/",
    };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    // All results should be .zig files
    for (result.matches.items) |m| {
        try expect(std.mem.endsWith(u8, m.path, ".zig"));
    }
}

test "execute_glob with type filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .any = "-t f -e zig src/",
    };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    // All results should be files
    for (result.matches.items) |m| {
        try expect(std.mem.endsWith(u8, m.path, ".zig"));
    }
}

test "execute_glob handles non-existent path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .any = "-e zig /nonexistent/path/that/does/not/exist",
    };

    // Should return empty results, not an error
    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    try expect(result.matches.items.len == 0);
}

test "execute_glob with quoted args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .any = "\"-e zig\" src/",
    };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    // Results should be .zig files
    for (result.matches.items) |m| {
        try expect(std.mem.endsWith(u8, m.path, ".zig"));
    }
}

test "glob_result_to_string formats correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = GlobResult{
        .matches = std.ArrayList(GlobMatch).empty,
    };
    defer result.deinit(allocator);

    try result.matches.append(allocator, .{ .path = "/path/to/file1.zig" });
    try result.matches.append(allocator, .{ .path = "/path/to/file2.zig" });

    const output = try glob_result_to_string(allocator, result);

    try expect(std.mem.containsAtLeast(u8, output, 1, "<f>/path/to/file1.zig</f>"));
    try expect(std.mem.containsAtLeast(u8, output, 1, "<f>/path/to/file2.zig</f>"));
}

test "glob_result_to_string handles empty result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = GlobResult{
        .matches = std.ArrayList(GlobMatch).empty,
    };
    defer result.deinit(allocator);

    const output = try glob_result_to_string(allocator, result);

    try std.testing.expect(std.mem.indexOf(u8, output, "No files found") != null);
}

test "GlobResult deinit cleans up memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = GlobResult{
        .matches = std.ArrayList(GlobMatch).empty,
    };

    try result.matches.append(allocator, .{ .path = try allocator.dupe(u8, "/test/path.zig") });
    try result.matches.append(allocator, .{ .path = try allocator.dupe(u8, "/test/other.zig") });

    // deinit should not panic
    result.deinit(allocator);
}

test "glob_tool definition is valid" {
    const tool = glob.glob_tool;

    try expectEqualSlices(u8, "function", tool.type);
    try expectEqualSlices(u8, "glob", tool.function.name);
    try expect(tool.function.description.len > 0);
    try expectEqualSlices(u8, "object", tool.function.parameters.type);
    try expect(tool.function.parameters.properties.len > 0);
}

test "glob_tool has any property" {
    const tool = glob.glob_tool;

    // Find the "any" property
    var found_any = false;
    for (tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "any")) {
            found_any = true;
            try expectEqualSlices(u8, "string", prop.type);
            break;
        }
    }
    try expect(found_any);
}

test "glob_tool required is empty" {
    const tool = glob.glob_tool;

    try expectEqual(0, tool.function.parameters.required.len);
}

// ============================================================================
// BUG FIX: Glob patterns without --glob flag fail
// ============================================================================

test "execute_glob with glob pattern (e.g. *.zig) works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // This should work: fd should auto-detect glob patterns and add --glob
    const input = GlobInput{
        .any = "*.zig src/",
    };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    // Should find .zig files
    try expect(result.matches.items.len > 0);
    for (result.matches.items) |m| {
        try expect(std.mem.endsWith(u8, m.path, ".zig"));
    }
}

test "execute_glob with glob pattern and path (e.g. *.zig src/) works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .any = "*.zig src/",
    };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    // Should find .zig files in src/
    try expect(result.matches.items.len > 0);
    for (result.matches.items) |m| {
        try expect(std.mem.endsWith(u8, m.path, ".zig"));
    }
}

test "execute_glob with complex glob pattern (e.g. test_*.zig) works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .any = "test_*.zig src/",
    };

    var result = try execute_glob(allocator, input);
    defer result.deinit(allocator);

    // Should find test_*.zig files
    for (result.matches.items) |m| {
        const filename = std.fs.path.basename(m.path);
        try expect(std.mem.startsWith(u8, filename, "test_"));
        try expect(std.mem.endsWith(u8, m.path, ".zig"));
    }
}
