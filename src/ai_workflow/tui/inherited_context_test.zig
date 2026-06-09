const std = @import("std");
const ic = @import("inherited_context.zig");

test "parseMode - null/empty string returns Mode.none" {
    const m = try ic.parseMode("");
    try std.testing.expect(m == .none);
}

test "parseMode - 'none' returns Mode.none" {
    const m = try ic.parseMode("none");
    try std.testing.expect(m == .none);
}

test "parseMode - 'last:5' returns Mode.last{5}" {
    const m = try ic.parseMode("last:5");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 5);
}

test "parseMode - 'last:' (no number) defaults to 10" {
    const m = try ic.parseMode("last:");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 10);
}

test "parseMode - 'last:0' clamps to 1" {
    const m = try ic.parseMode("last:0");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 1);
}

test "parseMode - 'last:999' clamps to 50" {
    const m = try ic.parseMode("last:999");
    try std.testing.expect(m == .last);
    try std.testing.expect(m.last == 50);
}

test "parseMode - 'last:50' stays 50" {
    const m = try ic.parseMode("last:50");
    try std.testing.expect(m.last == 50);
}

test "parseMode - 'all' returns Mode.all" {
    const m = try ic.parseMode("all");
    try std.testing.expect(m == .all);
}

test "parseMode - 'since_last_user' returns Mode.since_last_user" {
    const m = try ic.parseMode("since_last_user");
    try std.testing.expect(m == .since_last_user);
}

test "parseMode - 'garbage' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, ic.parseMode("garbage"));
}

test "parseMode - 'last:abc' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, ic.parseMode("last:abc"));
}

test "parseMode - 'last:-3' returns InvalidInheritedContextMode" {
    try std.testing.expectError(error.InvalidInheritedContextMode, ic.parseMode("last:-3"));
}
