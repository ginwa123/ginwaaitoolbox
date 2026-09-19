//! Phase 0 RED contract for the XML → JSON tool-output migration
//! (plan `2026-09-18-agent-tool-output-xml-to-json.md`, schema in
//! `2026-09-18-agent-tool-output-json-schema.md`).
//!
//! These tests assert the JSON envelope `wrapToolOutput` must produce after
//! Phase 1. They FAIL while the writer still emits `<tool>…</tool>` XML
//! (RED) and go green with the Phase 1 rewrite — no test changes needed.
//! Fixtures live in `tests/fixtures/tool_output/json/`.

const std = @import("std");
const testing = std.testing;
const wrapToolOutput = @import("tools_wrap_output.zig").wrapToolOutput;

fn parseEnvelope(allocator: std.mem.Allocator, out: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
}

test "json contract - success envelope has the six keys with data object and null error" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "read_file",
        "{\"path\":\"/x.txt\"}",
        true,
        null,
        "{\"path\":\"/x.txt\",\"content\":\"hi\",\"total_lines\":10,\"start_line\":0,\"end_line\":10}",
    );
    defer allocator.free(out);

    var parsed = try parseEnvelope(allocator, out);
    defer parsed.deinit();
    const env = parsed.value.object;

    try testing.expectEqualStrings("read_file", env.get("tool").?.string);
    try testing.expectEqualStrings("/x.txt", env.get("parameters").?.object.get("path").?.string);
    try testing.expect(env.get("success").?.bool);
    const data = env.get("data").?.object;
    try testing.expectEqualStrings("hi", data.get("content").?.string);
    try testing.expect(env.get("error").? == .null);
    try testing.expectEqual(@as(i64, 1), env.get("v").?.integer);
}

test "json contract - error envelope carries null data and string error" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(
        allocator,
        "read_file",
        "{\"path\":\"/missing\"}",
        false,
        "File not found",
        "",
    );
    defer allocator.free(out);

    var parsed = try parseEnvelope(allocator, out);
    defer parsed.deinit();
    const env = parsed.value.object;

    try testing.expect(!env.get("success").?.bool);
    try testing.expect(env.get("data").? == .null);
    try testing.expectEqualStrings("File not found", env.get("error").?.string);
    try testing.expectEqual(@as(i64, 1), env.get("v").?.integer);
}

test "json contract - malformed args fall back to _raw object" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(allocator, "bash", "{not valid json", true, null, "{}");
    defer allocator.free(out);

    var parsed = try parseEnvelope(allocator, out);
    defer parsed.deinit();
    const params = parsed.value.object.get("parameters").?.object;
    try testing.expectEqualStrings("{not valid json", params.get("_raw").?.string);
}

test "json contract - output is JSON, never the <tool> envelope" {
    const allocator = testing.allocator;
    const out = try wrapToolOutput(allocator, "bash", "{}", true, null, "{}");
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<tool>") == null);
    // Must parse as a JSON object at all.
    var parsed = try parseEnvelope(allocator, out);
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "json contract - binary stdout is sanitized, envelope stays valid JSON" {
    const allocator = testing.allocator;
    // ELF header bytes: 0x7F 'E' 'L' 'F' + NUL + C0 control. NUL truncates
    // SQLite TEXT and breaks both XML and JSON strings, so the writer must
    // replace such bytes with U+FFFD before serialization.
    const raw_stdout = [_]u8{ 0x7F, 'E', 'L', 'F', 0x00, 0x01 };
    const data = try std.fmt.allocPrint(allocator, "{{\"stdout\":\"{s}\"}}", .{raw_stdout});
    defer allocator.free(data);
    const out = try wrapToolOutput(allocator, "bash", "{}", true, null, data);
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\x00") == null);
    var parsed = try parseEnvelope(allocator, out);
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}
