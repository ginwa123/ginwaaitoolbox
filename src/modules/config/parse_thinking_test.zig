// Tests for parse_thinking.zig — pure helpers `parseThinkingString` and
// `parseReasoningEffort`. Cover the new UI semantics (Auto / On / Off)
// plus the legacy string->bool mapping (true / false / auto).
//
// Like the rest of the config module, this file is reached via a
// `_ = @import("parse_thinking_test.zig");` line in Config.zig.

const std = @import("std");
const pt = @import("parse_thinking.zig");
const testing = std.testing;

test "parseThinkingString auto -> null (inherit)" {
    try testing.expectEqual(@as(?bool, null), try pt.parseThinkingString("auto"));
}

test "parseThinkingString on -> true (extended reasoning enabled)" {
    try testing.expectEqual(@as(?bool, true), try pt.parseThinkingString("on"));
}

test "parseThinkingString off -> false (extended reasoning disabled)" {
    try testing.expectEqual(@as(?bool, false), try pt.parseThinkingString("off"));
}

test "parseThinkingString true -> true (legacy UI wrote boolean strings)" {
    try testing.expectEqual(@as(?bool, true), try pt.parseThinkingString("true"));
}

test "parseThinkingString false -> false (legacy)" {
    try testing.expectEqual(@as(?bool, false), try pt.parseThinkingString("false"));
}

test "parseThinkingString empty -> null (auto)" {
    try testing.expectEqual(@as(?bool, null), try pt.parseThinkingString(""));
}

test "parseThinkingString garbage -> error.InvalidThinkingMode" {
    try testing.expectError(error.InvalidThinkingMode, pt.parseThinkingString("maybe"));
}

test "parseThinkingString leading whitespace stripped" {
    // Defensive: tolerate one accidental leading space (frontend types
    // shouldn't carry whitespace, but a hand-edited config.json might).
    try testing.expectEqual(@as(?bool, true), try pt.parseThinkingString(" on"));
    try testing.expectEqual(@as(?bool, false), try pt.parseThinkingString("off "));
}

test "parseReasoningEffort low" {
    try testing.expectEqualStrings("low", try pt.parseReasoningEffort("low"));
}

test "parseReasoningEffort medium" {
    try testing.expectEqualStrings("medium", try pt.parseReasoningEffort("medium"));
}

test "parseReasoningEffort high" {
    try testing.expectEqualStrings("high", try pt.parseReasoningEffort("high"));
}

test "parseReasoningEffort auto" {
    try testing.expectEqualStrings("auto", try pt.parseReasoningEffort("auto"));
}

test "parseReasoningEffort empty -> auto" {
    try testing.expectEqualStrings("auto", try pt.parseReasoningEffort(""));
}

test "parseReasoningEffort garbage -> error.InvalidReasoningEffort" {
    try testing.expectError(error.InvalidReasoningEffort, pt.parseReasoningEffort("super"));
}

test "parseReasoningEffort is case-sensitive (Anthropic / OpenAI treat LOW/low the same but we do NOT silently lowercase)" {
    // The frontend always sends lowercase; we accept only lowercase.
    // Uppercase would surface as an error so the user notices a misconfig.
    try testing.expectError(error.InvalidReasoningEffort, pt.parseReasoningEffort("LOW"));
}
