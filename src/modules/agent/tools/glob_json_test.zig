const std = @import("std");
const glob = @import("glob.zig");
const GlobInput = glob.GlobInput;

test "JSON parsing of max_results=0" {
    const allocator = std.heap.page_allocator;
    
    // Test parsing JSON with max_results=0
    const json_str = "{\"pattern\": \"*\", \"path\": \"src/\", \"max_results\": 0}";
    const parsed = try std.json.parseFromSlice(GlobInput, allocator, json_str, .{.allocate = .alloc_always});
    defer parsed.deinit();
    
    std.debug.print("max_results parsed as: {any}\n", .{parsed.value.max_results});
    
    // Verify max_results is 0 (not null)
    try std.testing.expect(parsed.value.max_results != null);
    try std.testing.expect(parsed.value.max_results.? == 0);
    
    // Now test execute_glob with this input
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_allocator = arena.allocator();
    
    var result = try glob.execute_glob(test_allocator, parsed.value);
    defer result.deinit(test_allocator);
    
    std.debug.print("execute_glob result: {} matches (total={})\n", .{result.matches.items.len, result.total_found});
    
    // Should return all results (same as null or DEFAULT_MAX_RESULTS)
    try std.testing.expect(result.matches.items.len > 0);
}
