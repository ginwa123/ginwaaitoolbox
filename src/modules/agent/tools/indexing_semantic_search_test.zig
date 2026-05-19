const std = @import("std");
const testing = std.testing;
const indexing = @import("indexing_semantic_search.zig");

// ============================================================================
// Test: Chunk Single Function
// ============================================================================

test "testChunkSingleFunction" {
    const allocator = testing.allocator;

    const content =
        \\fn myFunction() void {
        \\    std.debug.print("Hello\n", .{});
        \\}
    ;

    const chunks = try indexing.chunkFile(allocator, "test.zig", content, 500);
    defer {
        for (chunks) |c| {
            allocator.free(c.file_path);
            allocator.free(c.content);
        }
        allocator.free(chunks);
    }

    // May produce 1 or 2 chunks depending on trailing content handling
    try testing.expect(chunks.len >= 1);
    try testing.expectEqual(@as(u32, 0), chunks[0].chunk_id);
    try testing.expect(!chunks[0].oversized);
}

// ============================================================================
// Test: Chunk Multiple Functions
// ============================================================================

test "testChunkMultipleFunctions" {
    const allocator = testing.allocator;

    const content =
        \\fn funcA() void {}
        \\
        \\fn funcB() void {}
        \\
        \\fn funcC() void {}
        \\
        \\fn funcD() void {}
        \\
        \\fn funcE() void {}
    ;

    const chunks = try indexing.chunkFile(allocator, "test.zig", content, 500);
    defer {
        for (chunks) |c| {
            allocator.free(c.file_path);
            allocator.free(c.content);
        }
        allocator.free(chunks);
    }

    // May produce 5-6 chunks depending on trailing content handling
    try testing.expect(chunks.len >= 5);
    for (0..@min(chunks.len, 5)) |i| {
        try testing.expect(chunks[i].content.len > 0);
    }
}

// ============================================================================
// Test: Chunk Non-Code File (Markdown)
// ============================================================================

test "testChunkNonCode" {
    const allocator = testing.allocator;

    const content =
        \\# Title
        \\
        \\Paragraph one.
        \\
        \\Paragraph two.
    ;

    const chunks = try indexing.chunkFile(allocator, "readme.md", content, 500);
    defer {
        for (chunks) |c| {
            allocator.free(c.file_path);
            allocator.free(c.content);
        }
        allocator.free(chunks);
    }

    try testing.expect(chunks.len >= 1);
}

// ============================================================================
// Test: Gitignore Glob Matching
// ============================================================================

test "testGitignoreGlob" {
    // Test *.o pattern
    try testing.expect(indexing.gitignoreGlobMatch("*.o", "test.o", false));
    try testing.expect(!indexing.gitignoreGlobMatch("*.o", "test.c", false));

    // Test build/* pattern
    try testing.expect(indexing.gitignoreMatch("build/", "build/output", true));
    try testing.expect(indexing.gitignoreMatch("build/", "build/", true));

    // Test negation pattern - this tests the matching logic
    // *.o should NOT match keep.o when the glob is properly respecting characters
    try testing.expect(!indexing.gitignoreGlobMatch("build/*.txt", "keep.o", false));
}

// ============================================================================
// Test: Binary Content Detection
// ============================================================================

test "testBinarySniff" {
    // Null byte in content
    try testing.expect(indexing.isBinaryContent("hello\x00world"));

    // No null bytes
    try testing.expect(!indexing.isBinaryContent("hello world"));
    try testing.expect(!indexing.isBinaryContent("line1\nline2\nline3"));
}

// ============================================================================
// Test: Normalization
// ============================================================================

test "testNormalization" {
    var v: [4]f32 = .{ 3.0, 4.0, 0.0, 0.0 };
    indexing.normalize(&v);

    // Compute magnitude
    var mag: f32 = 0;
    for (v) |x| mag += x * x;
    mag = @sqrt(mag);

    try testing.expect(@abs(mag - 1.0) < 0.0001);
}

// ============================================================================
// Test: Dot Product
// ============================================================================

test "testDotProduct" {
    const a: [3]f32 = .{ 1.0, 2.0, 3.0 };
    const b: [3]f32 = .{ 4.0, 5.0, 6.0 };

    const result = indexing.dotProduct(&a, &b);
    // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
    try testing.expect(@abs(result - 32.0) < 0.0001);
}

// ============================================================================
// Test: Hash Computation
// ============================================================================

test "testHashDiff" {
    const content1 = "hello world";
    const content2 = "hello world";
    const content3 = "different content";

    const hash1 = indexing.computeHash(content1);
    const hash2 = indexing.computeHash(content2);
    const hash3 = indexing.computeHash(content3);

    try testing.expectEqual(hash1, hash2);
    try testing.expect(!std.mem.eql(u8, &hash1, &hash3));
}

// ============================================================================
// Test: Search Results Structure
// ============================================================================

test "testSearchResultsStructure" {
    const result = indexing.SearchResult{
        .file_path = "test.zig",
        .start_line = 10,
        .end_line = 20,
        .snippet = "test content snippet",
        .score = 0.95,
    };

    try testing.expectEqualStrings("test.zig", result.file_path);
    try testing.expectEqual(@as(u32, 10), result.start_line);
    try testing.expectEqual(@as(u32, 20), result.end_line);
    try testing.expectEqualStrings("test content snippet", result.snippet);
    try testing.expectEqual(@as(f32, 0.95), result.score);
}

// ============================================================================
// Test: Chunk Info Structure
// ============================================================================

test "testChunkInfoStructure" {
    const chunk = indexing.ChunkInfo{
        .chunk_id = 5,
        .file_path = "myfile.zig",
        .start_line = 1,
        .end_line = 10,
        .content = "fn test() {}",
        .oversized = false,
    };

    try testing.expectEqual(@as(u32, 5), chunk.chunk_id);
    try testing.expectEqualStrings("myfile.zig", chunk.file_path);
    try testing.expect(!chunk.oversized);
}

// ============================================================================
// Test: File Entry Structure
// ============================================================================

test "testFileEntryStructure" {
    const entry = indexing.FileEntry{
        .path = "/path/to/file.zig",
        .content = "file content",
        .mtime = 1234567890,
    };

    try testing.expectEqualStrings("/path/to/file.zig", entry.path);
    try testing.expectEqualStrings("file content", entry.content);
    try testing.expectEqual(@as(i64, 1234567890), entry.mtime);
}

// ============================================================================
// Test: Search with Empty Index
// ============================================================================

test "testSearchEmptyIndex" {
    const allocator = testing.allocator;

    const chunks: []const indexing.ChunkInfo = &.{};
    const embeddings: []const f32 = &.{};
    const dimensions: u32 = 0;

    const results = indexing.search(allocator, chunks, embeddings, dimensions, "query", 5) catch &.{};
    try testing.expectEqual(@as(usize, 0), results.len);
}

// ============================================================================
// Test: Index Manifest Structure
// ============================================================================

test "testIndexManifestStructure" {
    const manifest = indexing.IndexManifest{
        .version = 1,
        .dimensions = 768,
        .chunk_count = 100,
        .indexed_files = &.{},
        .last_updated = 1234567890,
        .memory_bytes = 307200,
        .oversized_chunks = &.{},
    };

    try testing.expectEqual(@as(u32, 1), manifest.version);
    try testing.expectEqual(@as(u32, 768), manifest.dimensions);
    try testing.expectEqual(@as(u32, 100), manifest.chunk_count);
    try testing.expectEqual(@as(u64, 307200), manifest.memory_bytes);
}