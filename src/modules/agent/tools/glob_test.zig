const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

const glob = @import("glob.zig");
const GlobInput = glob.GlobInput;
const GlobTypeFilter = glob.GlobTypeFilter;
const GlobMatch = glob.GlobMatch;
const GlobResult = glob.GlobResult;
const executeGlob = glob.executeGlob;
const globResultToString = glob.globResultToString;

test "GlobTypeFilter toFdArg" {
    try expectEqualSlices(u8, "f", GlobTypeFilter.file.toFdArg());
    try expectEqualSlices(u8, "d", GlobTypeFilter.directory.toFdArg());
    try expectEqualSlices(u8, "l", GlobTypeFilter.symlink.toFdArg());
    try expectEqualSlices(u8, "s", GlobTypeFilter.socket.toFdArg());
    try expectEqualSlices(u8, "p", GlobTypeFilter.pipe.toFdArg());
    try expectEqualSlices(u8, "x", GlobTypeFilter.executable.toFdArg());
    try expectEqualSlices(u8, "e", GlobTypeFilter.empty.toFdArg());
}

test "GlobInput default values" {
    const input = GlobInput{
        .pattern = "*.zig",
        .path = "src",
    };
    try expect(!input.include_hidden);
    try expect(input.max_results == null);
    try expect(input.type_filter == null);
}

test "executeGlob finds zig files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .pattern = "*.zig",
        .path = "src",
        .max_results = 10,
    };

    var result = try executeGlob(allocator, input);
    defer result.deinit(allocator);

    try expect(result.matches.items.len > 0);
    // First match should end with .zig
    try expect(std.mem.endsWith(u8, result.matches.items[0].path, ".zig"));
}

test "executeGlob with hidden files disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .pattern = ".*",
        .path = "src",
        .include_hidden = false,
        .max_results = 10,
    };

    // Should complete without error even if no hidden files
    var result = try executeGlob(allocator, input);
    defer result.deinit(allocator);

    // Results should not include hidden files (files starting with .)
    for (result.matches.items) |m| {
        const basename = std.fs.path.basename(m.path);
        try expect(!std.mem.startsWith(u8, basename, "."));
    }
}

test "executeGlob with hidden files enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .pattern = ".*",
        .path = "src",
        .include_hidden = true,
        .max_results = 10,
    };

    var result = try executeGlob(allocator, input);
    defer result.deinit(allocator);

    // With hidden enabled, we might find .gitignore or similar
    _ = result.matches.items.len;
}

test "executeGlob with type filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .pattern = "*",
        .path = "src",
        .type_filter = .file,
        .max_results = 10,
    };

    var result = try executeGlob(allocator, input);
    defer result.deinit(allocator);

    // All results should be files (directories would have different suffixes)
    for (result.matches.items) |m| {
        try expect(!std.mem.endsWith(u8, m.path, "/"));
    }
}

test "executeGlob respects max_results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const max_results: usize = 3;
    const input = GlobInput{
        .pattern = "*.zig",
        .path = "src",
        .max_results = max_results,
    };

    var result = try executeGlob(allocator, input);
    defer result.deinit(allocator);

    try expect(result.matches.items.len <= max_results);
}

test "executeGlob with offset pagination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // First batch: get first 3 results
    const input1 = GlobInput{
        .pattern = "*.zig",
        .path = "src",
        .max_results = 3,
        .offset = 0,
    };

    var result1 = try executeGlob(allocator, input1);
    defer result1.deinit(allocator);

    // Second batch: skip first 3, get next 3
    const input2 = GlobInput{
        .pattern = "*.zig",
        .path = "src",
        .max_results = 3,
        .offset = 3,
    };

    var result2 = try executeGlob(allocator, input2);
    defer result2.deinit(allocator);

    // Results should not overlap
    for (result1.matches.items) |m1| {
        for (result2.matches.items) |m2| {
            try expect(!std.mem.eql(u8, m1.path, m2.path));
        }
    }
}

test "executeGlob handles non-existent path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = GlobInput{
        .pattern = "*.zig",
        .path = "/nonexistent/path/that/does/not/exist",
    };

    // Should return empty results, not an error
    var result = try executeGlob(allocator, input);
    defer result.deinit(allocator);

    try expect(result.matches.items.len == 0);
}

test "globResultToString formats correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = GlobResult{
        .matches = std.ArrayList(GlobMatch).empty,
    };
    defer result.deinit(allocator);

    try result.matches.append(allocator, .{ .path = "/path/to/file1.zig" });
    try result.matches.append(allocator, .{ .path = "/path/to/file2.zig" });

    const output = try globResultToString(allocator, result);

    try expect(std.mem.containsAtLeast(u8, output, 1, "<f>/path/to/file1.zig</f>"));
    try expect(std.mem.containsAtLeast(u8, output, 1, "<f>/path/to/file2.zig</f>"));
}

test "globResultToString handles empty result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = GlobResult{
        .matches = std.ArrayList(GlobMatch).empty,
    };
    defer result.deinit(allocator);

    const output = try globResultToString(allocator, result);

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

test "globTool definition is valid" {
    const tool = glob.globTool;

    try expectEqualSlices(u8, "function", tool.type);
    try expectEqualSlices(u8, "glob", tool.function.name);
    try expect(tool.function.description.len > 0);
    try expectEqualSlices(u8, "object", tool.function.parameters.type);
    try expect(tool.function.parameters.properties.len > 0);
}
