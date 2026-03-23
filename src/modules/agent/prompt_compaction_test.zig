const std = @import("std");
const prompt = @import("prompt.zig");

test "CompactionAgent: prompt contains core principles" {
    // Verify the improved prompt contains key structural elements
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Core Principles") != null);
}

test "CompactionAgent: prompt contains what to preserve" {
    // Verify the prompt has clear guidance on what to preserve
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "What to Preserve") != null);
}

test "CompactionAgent: prompt contains what to compress" {
    // Verify the prompt has clear guidance on what to compress
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "What to Compress") != null);
}

test "CompactionAgent: prompt contains output format" {
    // Verify the prompt has a structured output format
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Output Format") != null);
}

test "CompactionAgent: prompt contains project context section" {
    // Verify the output format includes Project Context section
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "## Project Context") != null);
}

test "CompactionAgent: prompt contains session summary section" {
    // Verify the output format includes Session Summary section
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "## Session Summary") != null);
}

test "CompactionAgent: prompt contains current state section" {
    // Verify the output format includes Current State section
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Current State") != null);
}

test "CompactionAgent: prompt contains compression examples" {
    // Verify the prompt has compression examples
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Compression Examples") != null);
}

test "CompactionAgent: prompt contains important rules" {
    // Verify the prompt has important rules section
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Important Rules") != null);
}

test "CompactionAgent: prompt is longer than original (~40 lines)" {
    // The improved prompt should be significantly longer
    // Original was ~40 lines, improved should be ~100+ lines
    const min_length = 3000; // ~100 lines of content
    try std.testing.expect(prompt.CompactionAgent.len > min_length);
}

test "CompactionAgent: prompt contains code decisions guidance" {
    // Verify the prompt mentions code decisions
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Code decisions") != null);
}

test "CompactionAgent: prompt contains file operations guidance" {
    // Verify the prompt mentions file operations
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "File operations") != null);
}

test "CompactionAgent: prompt contains errors and solutions guidance" {
    // Verify the prompt mentions errors and solutions
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Errors & solutions") != null);
}

test "CompactionAgent: prompt contains skills usage guidance" {
    // Verify the prompt mentions skills
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Skills loaded") != null);
}

test "CompactionAgent: prompt contains agent workflows guidance" {
    // Verify the prompt mentions agent workflows
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Agent workflows") != null);
}

test "CompactionAgent: prompt warns against inventing" {
    // Verify the prompt warns about not inventing information
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Never invent") != null);
}

test "CompactionAgent: prompt emphasizes structure" {
    // Verify the prompt emphasizes the importance of structure
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Structure is key") != null);
}

test "CompactionAgent: prompt specifies output only the summary" {
    // Verify the prompt says to output ONLY the compressed summary
    try std.testing.expect(std.mem.indexOf(u8, prompt.CompactionAgent, "Output ONLY the compressed summary") != null);
}
