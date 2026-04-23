const std = @import("std");
const expect = std.testing.expect;

const glob = @import("glob.zig");
const GlobInput = glob.GlobInput;
const execute_glob = glob.execute_glob;

test "max_results=0 should return all results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // First get all results with no limit
    const input_all = GlobInput{ .pattern = "*", .path = "src/", .max_results = null };
    var result_all = try execute_glob(allocator, input_all);
    defer result_all.deinit(allocator);
    const all_count = result_all.matches.items.len;

    // Then get with max_results=0
    const input_zero = GlobInput{ .pattern = "*", .path = "src/", .max_results = 0 };
    var result_zero = try execute_glob(allocator, input_zero);
    defer result_zero.deinit(allocator);
    const zero_count = result_zero.matches.items.len;

    std.debug.print("max_results=null: {} matches\n", .{all_count});
    std.debug.print("max_results=0: {} matches\n", .{zero_count});
    
    // max_results=0 should return all matches (same as null)
    try expect(zero_count == all_count);
}
