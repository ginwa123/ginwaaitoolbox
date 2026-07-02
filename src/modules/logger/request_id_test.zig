const std = @import("std");
const request_id = @import("RequestId.zig");
const RequestId = request_id.RequestId;
const SessionId = request_id.SessionId;
const generateRequestId = request_id.generateRequestId;
const generateSessionId = request_id.generateSessionId;

test "RequestId has correct format" {
    const id = generateRequestId();
    const str = id.toString();
    
    // Check length
    try std.testing.expectEqual(@as(usize, 24), str.len);
    
    // Check prefix
    try std.testing.expectEqualStrings("REQ-", str[0..4]);
    
    // Check dash at position 12 (after YYYYMMDD)
    try std.testing.expectEqual('-', str[12]);
    
    // Check dash at position 19 (before random suffix)
    try std.testing.expectEqual('-', str[19]);
    
    // Check that random suffix is hex
    for (str[20..24]) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_hex);
    }
}

test "RequestIds are unique" {
    const id1 = generateRequestId();
    const id2 = generateRequestId();
    
    // IDs should differ (either time or random component)
    try std.testing.expect(!std.mem.eql(u8, id1.toString(), id2.toString()));
}

test "SessionId has correct format" {
    const id = generateSessionId();
    const str = id.toString();
    
    // Check length (SES- + 8 hex chars = 12)
    try std.testing.expectEqual(@as(usize, 12), str.len);
    
    // Check prefix
    try std.testing.expectEqualStrings("SES-", str[0..4]);
    
    // Check that suffix is hex
    for (str[4..12]) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_hex);
    }
}

test "SessionIds are unique" {
    const id1 = generateSessionId();
    const id2 = generateSessionId();

    // IDs should differ due to random component
    try std.testing.expect(!std.mem.eql(u8, id1.toString(), id2.toString()));
}

test "SessionIds are unique across 1000 back-to-back calls" {
    // Regression for the macOS CI failure where two back-to-back calls
    // in the same nanosecond produced identical SessionIds (CI run
    // 28568881975). Now uses libc `getrandom` for guaranteed entropy.
    //
    // IMPORTANT: store OWNED COPIES of the 12-byte value, not slices.
    // `id.toString()` returns `&id.value` — a pointer into the stack
    // slot of the local `id` variable. Each loop iteration reuses the
    // same stack address, so all `seen[i]` slice aliases point at the
    // same memory and appear "identical" even when the IDs differ.
    // Using `[N][12]u8` (fixed arrays) makes each entry an independent
    // copy of the bytes at the moment of insertion.
    const N: usize = 1000;
    var seen: [N][12]u8 = undefined;
    var unique_count: usize = 0;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const id = generateSessionId();
        var dup = false;
        for (seen[0..unique_count]) |existing| {
            if (std.mem.eql(u8, &existing, &id.value)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        seen[unique_count] = id.value;
        unique_count += 1;
    }
    try std.testing.expectEqual(@as(usize, N), unique_count);
}