const std = @import("std");
const list_skills = @import("list_skills.zig");
const skills = list_skills.skills;

// Helper to check if string contains substring
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "toXml generates valid XML structure" {
    const alloc = std.testing.allocator;

    const data = list_skills.SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const xml = try list_skills.toXml(alloc, data);
    defer alloc.free(xml);

    try std.testing.expect(std.mem.startsWith(u8, xml, "<skills>"));
    try std.testing.expect(std.mem.endsWith(u8, xml, "</skills>"));
    try std.testing.expect(contains(xml, "<global_skills>"));
    try std.testing.expect(contains(xml, "<local_skills>"));
}

test "toXml escapes special characters in skill data" {
    const alloc = std.testing.allocator;

    const data = list_skills.SkillsListData{
        .global_skills = &[_]skills.SkillInfo{
            .{
                .name = "test <skill>",
                .description = "desc & more",
                .path = "/path/with \"quotes\"",
            },
        },
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const xml = try list_skills.toXml(alloc, data);
    defer alloc.free(xml);

    // Should contain escaped versions
    try std.testing.expect(contains(xml, "&lt;skill&gt;"));
    try std.testing.expect(contains(xml, "&amp;"));
    try std.testing.expect(contains(xml, "&quot;"));
    // Should NOT contain unescaped < or > outside of XML tags
    // (we allow <global_skills>, <local_skills>, <skill>, etc. which are valid XML tags)
}

test "toXml includes cwd when present" {
    const alloc = std.testing.allocator;

    const data = list_skills.SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = "/test/cwd",
    };

    const xml = try list_skills.toXml(alloc, data);
    defer alloc.free(xml);

    try std.testing.expect(contains(xml, "<cwd>"));
    try std.testing.expect(contains(xml, "/test/cwd"));
}

test "toJson generates valid JSON" {
    const alloc = std.testing.allocator;

    const data = list_skills.SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const json = try list_skills.toJson(alloc, data);
    defer alloc.free(json);

    // Should be valid JSON structure
    try std.testing.expect(std.mem.startsWith(u8, json, "{"));
    try std.testing.expect(std.mem.endsWith(u8, json, "}"));
    try std.testing.expect(contains(json, "global_skills"));
    try std.testing.expect(contains(json, "local_skills"));
}

test "freeSkillsListData handles empty arrays" {
    const alloc = std.testing.allocator;

    const data = list_skills.SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    // Should not panic
    list_skills.freeSkillsListData(alloc, data);
}