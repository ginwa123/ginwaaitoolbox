const std = @import("std");
const SqliteBackend = @import("sqlite.zig").SqliteBackend;

test "sqlite open db" {
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();
}

test "sqlite insert and query" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    try db.exec(allocator, "INSERT INTO users (name) VALUES (?)", &.{"Alice"});
    try db.exec(allocator, "INSERT INTO users (name) VALUES (?)", &.{"Bob"});

    const row = try db.queryRow(allocator, "SELECT name FROM users WHERE id = ?", &.{"1"});
    try std.testing.expectEqualStrings("Alice", row.values[0]);
    row.deinit(allocator);
}

test "sqlite query multiple rows" {
    const allocator = std.testing.allocator;
    var db: SqliteBackend = .{};
    try db.init(":memory:");
    defer db.deinit();

    try db.exec(allocator, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    try db.exec(allocator, "INSERT INTO users (name) VALUES (?)", &.{"Alice"});
    try db.exec(allocator, "INSERT INTO users (name) VALUES (?)", &.{"Bob"});
    try db.exec(allocator, "INSERT INTO users (name) VALUES (?)", &.{"Charlie"});

    var rows = try db.query(allocator, "SELECT name FROM users", &.{});
    defer rows.deinit();

    var count: usize = 0;

    var sliceOfStrings: std.ArrayList([]u8) = .empty;
    defer {
        for (sliceOfStrings.items) |s| allocator.free(s);
        sliceOfStrings.deinit(allocator);
    }
    while (try rows.next()) |row| {
        count += 1;

        const copy = try allocator.dupe(u8, row.values[0]);
        _ = try sliceOfStrings.append(allocator, copy);
        row.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 3), count);

    const item1 = sliceOfStrings.items[0];
    try std.testing.expectEqualStrings("Alice", item1);

    const item2 = sliceOfStrings.items[1];
    try std.testing.expectEqualStrings("Bob", item2);

    const item3 = sliceOfStrings.items[2];
    try std.testing.expectEqualStrings("Charlie", item3);
}
