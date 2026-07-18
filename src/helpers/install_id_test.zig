const std = @import("std");
const testing = std.testing;
const install_id = @import("install_id.zig");

test "generateInstallId produces a 36-char UUID v4 string" {
    var buf: [36]u8 = undefined;
    install_id.generateInstallId(&buf);
    const out = buf[0..];

    // Length must be exactly 36 characters
    try testing.expectEqual(@as(usize, 36), out.len);

    // Hyphen positions: 8, 13, 18, 23
    try testing.expectEqual(@as(u8, '-'), out[8]);
    try testing.expectEqual(@as(u8, '-'), out[13]);
    try testing.expectEqual(@as(u8, '-'), out[18]);
    try testing.expectEqual(@as(u8, '-'), out[23]);

    // All other positions must be lowercase hex
    for (out, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(is_hex);
    }

    // Version nibble (position 14, the FIRST hex char of group 3) must be '4'
    try testing.expectEqual(@as(u8, '4'), out[14]);

    // Variant nibble (position 19, the FIRST hex char of group 4) must be 8/9/a/b
    try testing.expect(std.mem.indexOfScalar(u8, "89ab", out[19]) != null);
}

test "generateInstallId produces unique values across calls" {
    var buf1: [36]u8 = undefined;
    var buf2: [36]u8 = undefined;
    var buf3: [36]u8 = undefined;
    install_id.generateInstallId(&buf1);
    install_id.generateInstallId(&buf2);
    install_id.generateInstallId(&buf3);

    // Each pair must differ (vanishingly unlikely to collide across 122-bit random space)
    try testing.expect(!std.mem.eql(u8, &buf1, &buf2));
    try testing.expect(!std.mem.eql(u8, &buf2, &buf3));
    try testing.expect(!std.mem.eql(u8, &buf1, &buf3));
}