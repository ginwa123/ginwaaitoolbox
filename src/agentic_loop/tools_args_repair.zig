//! Repair for tool-call `arguments` that a model emitted with RAW
//! backslashes inside a JSON string literal.
//!
//! Windows is where this bites: an absolute path is the one string a tool
//! call cannot avoid, and on Windows it is full of `\` separators. A model
//! that writes `{"path":"C:\Users\me\a.go"}` instead of the RFC 8259
//! `{"path":"C:\\Users\\me\\a.go"}` produces bytes that `std.json` rejects
//! with `error.SyntaxError` (`\U` is not one of `"\/bfnrtu`). On Linux and
//! macOS the same call carries `/` separators, there is nothing to escape,
//! and the bug is invisible — which is why it reads as "Windows only".
//!
//! Two layers used to turn that into the much more confusing
//! `error.MissingField`:
//!
//!   1. `parsing.zig` / `Agent.zig` dropped unparseable arguments and
//!      substituted `{}` when rebuilding history. The executor then parsed
//!      `{}` into `TextReplaceInput` and reported a missing `path`.
//!   2. The executor's own parse failure was reported as a bare Zig error
//!      name, so the model was told "MissingField" (send the field!) when
//!      the real problem was "your JSON is malformed".
//!
//! `escapeRawBackslashes` fixes the bytes; callers stop substituting `{}`.
//! Deliberately narrow: it only rewrites a backslash that JSON does not
//! accept as an escape introducer. It does not guess about raw control
//! characters, truncated arguments, markdown fences, or single quotes —
//! those get an actionable error message instead of a silent rewrite.
const std = @import("std");
const testing = std.testing;

/// True when `c` is one of the escape introducers RFC 8259 §7 accepts as a
/// single-character escape. `u` is handled separately because it is a
/// four-hex-digit escape, not a single-character one.
fn isSimpleEscape(c: u8) bool {
    return switch (c) {
        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => true,
        else => false,
    };
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Rewrite every backslash inside a JSON string literal that does not
/// introduce a legal escape into `\\`.
///
/// Returns a newly allocated copy whenever anything changed, `null` when
/// `raw` contains no stray backslash (so the caller can keep its own
/// pointer and skip the allocation). The result is NOT guaranteed to parse
/// — the caller must re-parse and fall back to a real error message when it
/// still does not.
///
/// This is a byte-level pass, not a parser: it tracks only "am I inside a
/// string literal", which is all that is needed to decide whether a
/// backslash is an escape or a literal separator.
pub fn escapeRawBackslashes(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    var changed = false;
    // First pass: decide whether a rewrite is needed at all, so the common
    // (already-valid) case costs no allocation.
    {
        var in_string = false;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (!in_string) {
                if (c == '"') in_string = true;
                i += 1;
                continue;
            }
            if (c == '"') {
                in_string = false;
                i += 1;
                continue;
            }
            if (c == '\\') {
                const next = if (i + 1 < raw.len) raw[i + 1] else 0;
                if (next == 'u' and i + 5 < raw.len and isHexDigit(raw[i + 2]) and isHexDigit(raw[i + 3]) and isHexDigit(raw[i + 4]) and isHexDigit(raw[i + 5])) {
                    i += 6;
                    continue;
                }
                if (isSimpleEscape(next)) {
                    i += 2;
                    continue;
                }
                changed = true;
                break;
            }
            i += 1;
        }
    }
    if (!changed) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_string = false;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (!in_string) {
            if (c == '"') in_string = true;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = false;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '\\') {
            const next = if (i + 1 < raw.len) raw[i + 1] else 0;
            const legal_u = next == 'u' and i + 5 < raw.len and isHexDigit(raw[i + 2]) and isHexDigit(raw[i + 3]) and isHexDigit(raw[i + 4]) and isHexDigit(raw[i + 5]);
            if (legal_u) {
                try out.appendSlice(allocator, raw[i .. i + 6]);
                i += 6;
                continue;
            }
            if (isSimpleEscape(next)) {
                try out.appendSlice(allocator, raw[i .. i + 2]);
                i += 2;
                continue;
            }
            // Stray backslash: the next byte is a literal character (the
            // first letter of a directory name, usually), so emit `\\` and
            // let the loop handle that byte as ordinary content.
            try out.append(allocator, '\\');
            try out.append(allocator, '\\');
            i += 1;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// Result of `repairToolCallArguments`. The borrow is spelled out rather
/// than left to the caller to infer from pointer identity, because getting
/// that wrong is a use-after-free on a 100 KB arguments string.
pub const RepairedArgs = union(enum) {
    /// The caller's own slice, unchanged. Do not free.
    borrowed: []const u8,
    /// A fresh allocation. Free with `deinit`.
    owned: []u8,

    pub fn slice(self: RepairedArgs) []const u8 {
        return switch (self) {
            .borrowed => |b| b,
            .owned => |o| o,
        };
    }

    pub fn deinit(self: RepairedArgs, allocator: std.mem.Allocator) void {
        switch (self) {
            .borrowed => {},
            .owned => |o| allocator.free(o),
        }
    }
};

/// `raw` if it already parses as JSON, otherwise the backslash-repaired
/// form if that parses, otherwise `null` (nothing to repair — report the
/// real error rather than substituting a fake empty object).
pub fn repairToolCallArguments(allocator: std.mem.Allocator, raw: []const u8) !?RepairedArgs {
    if (parsesAsJson(raw)) return RepairedArgs{ .borrowed = raw };

    const repaired = (try escapeRawBackslashes(allocator, raw)) orelse return null;
    if (parsesAsJson(repaired)) return RepairedArgs{ .owned = repaired };
    allocator.free(repaired);
    return null;
}

/// The letter RFC 8259 pairs with each control-character escape, so a
/// decoded control byte can be read back as the two characters the model
/// actually wrote.
fn escapeLetterForControl(c: u8) ?u8 {
    return switch (c) {
        0x08 => 'b',
        0x09 => 't',
        0x0A => 'n',
        0x0C => 'f',
        0x0D => 'r',
        else => null,
    };
}

/// Re-expand control characters in a decoded file path back into the
/// literal backslash + letter the model wrote.
///
/// `escapeRawBackslashes` only rewrites backslashes JSON rejects. It
/// deliberately leaves `\n`, `\t`, `\r` and `\f` alone, because a
/// multi-line `new_str` genuinely needs them. That leaves one hole: the
/// reported path contains `.config\pabrik`, where `\n` is a legal escape
/// but the model meant a separator. The arguments then parse, and the
/// path silently becomes `…\.config<LF>alar` — a different file, with no
/// error anywhere to explain it.
///
/// The reading is unambiguous in the other direction: a raw control byte
/// is illegal inside a JSON string, so a control byte in a DECODED value
/// can only have come from an escape sequence. And no real path contains
/// one. So re-expanding recovers the path the model meant. Returns `null`
/// when there is nothing to re-expand.
pub fn reexpandPathControlChars(allocator: std.mem.Allocator, value: []const u8) !?[]u8 {
    const has_control = for (value) |c| {
        if (escapeLetterForControl(c) != null) break true;
    } else false;
    if (!has_control) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |c| {
        if (escapeLetterForControl(c)) |letter| {
            try out.append(allocator, '\\');
            try out.append(allocator, letter);
        } else {
            try out.append(allocator, c);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn parsesAsJson(raw: []const u8) bool {
    var probe = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch return false;
    defer probe.deinit();
    return true;
}

// ---------------------------------------------------------------------------
// The reported failure: a real Windows path, unescaped by the model.
// ---------------------------------------------------------------------------

test "reported Windows path round-trips: raw backslashes in, real path out" {
    // The segment letters are load-bearing: `\n` and `\t` are LEGAL JSON
    // escapes (so the repaired value decodes to an embedded newline + tab that
    // step 2 must re-expand) while `\p`, `\o`, `\s` and `\c` are illegal. A path
    // with no legal escape in it would make step 2 vacuous.
    const raw =
        \\{"path":"C:\Users\gilang.trisetya\.config\pabrik\notes\src\test.go","old_str":"a","new_str":"b"}
    ;
    const want = "C:\\Users\\gilang.trisetya\\.config\\pabrik\\notes\\src\\test.go";

    // Precondition: this is exactly what the model emitted, and it does NOT
    // parse. This is the byte sequence behind the "works on Linux, breaks on
    // Windows" report.
    try testing.expect(!parsesAsJson(raw));

    // Step 1 — the illegal escapes (`\U`, `\.`, `\w`, `\s`, `\i`, `\d`)
    // become legal ones, so the arguments parse at all.
    const repaired = (try escapeRawBackslashes(testing.allocator, raw)).?;
    defer testing.allocator.free(repaired);
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, repaired, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings("a", parsed.value.object.get("old_str").?.string);
        try testing.expectEqualStrings("b", parsed.value.object.get("new_str").?.string);
    }

    // Step 2 — `.config\pabrik\notes` decoded to a real newline + tab, because
    // `\n` and `\t` are legal escapes the repair must not touch (a multi-line
    // `new_str` needs them). Re-expanding them is what turns the parsed-but-
    // corrupt path back into the path the model meant. Without this step the
    // tool would look for a file whose name contains control characters and
    // report "not found".
    // legal escape the repair must not touch (a multi-line `new_str` needs
    // it). Re-expanding it is what turns the parsed-but-corrupt path back
    // into the path the model meant. Without this step the tool would look
    // for a file whose name contains a newline and report "not found".
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, repaired, .{});
        defer parsed.deinit();
        const decoded = parsed.value.object.get("path").?.string;
        try testing.expect(std.mem.indexOfScalar(u8, decoded, '\n') != null);
        const path = (try reexpandPathControlChars(testing.allocator, decoded)).?;
        defer testing.allocator.free(path);
        try testing.expectEqualStrings(want, path);
    }
}

test "reexpandPathControlChars: a clean path is returned as null (no allocation)" {
    try testing.expect((try reexpandPathControlChars(testing.allocator, "C:\\Users\\me\\a.go")) == null);
    try testing.expect((try reexpandPathControlChars(testing.allocator, "/tmp/a.go")) == null);
    try testing.expect((try reexpandPathControlChars(testing.allocator, "")) == null);
}

test "reexpandPathControlChars: a genuine multi-line value is left to its caller" {
    // Re-expansion is for PATHS only. A `new_str` that really is two lines
    // must stay two lines, which is why exec applies this to `path` and
    // never to the replacement text.
    const decoded = "line1\nline2";
    const out = (try reexpandPathControlChars(testing.allocator, decoded)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("line1\\nline2", out);
}

test "escapeRawBackslashes: already-valid arguments are left byte-identical (no allocation)" {
    const raw =
        \\{"path":"C:\\Users\\me\\a.go","old_str":"x","new_str":"y"}
    ;
    try testing.expect((try escapeRawBackslashes(testing.allocator, raw)) == null);
    try testing.expect(parsesAsJson(raw));
}

test "escapeRawBackslashes: legal escapes inside strings survive untouched" {
    // \n and \t here are REAL escapes the model meant (a multi-line
    // new_str). Rewriting them to \\n would corrupt the replacement text.
    const raw =
        \\{"path":"/tmp/a.go","old_str":"x","new_str":"line1\nline2\ttabbed \"quoted\" c:\\slash"}
    ;
    try testing.expect(parsesAsJson(raw));
    try testing.expect((try escapeRawBackslashes(testing.allocator, raw)) == null);
}

test "escapeRawBackslashes: \\uXXXX is left alone (four hex digits, not a separator)" {
    const raw =
        \\{"path":"C:\\Users\\ሴ\\a.go","old_str":"x","new_str":"y"}
    ;
    try testing.expect(parsesAsJson(raw));
    try testing.expect((try escapeRawBackslashes(testing.allocator, raw)) == null);
}

test "escapeRawBackslashes: lowercase \\users is repaired, not mistaken for a \\u escape" {
    // `C:\users\...` looks like the start of a `\uXXXX` escape to a naive
    // scanner, but `sers` is not four hex digits — so the backslash is a
    // literal separator and must be escaped.
    const raw =
        \\{"path":"C:\users\me\a.go","old_str":"x","new_str":"y"}
    ;
    try testing.expect(!parsesAsJson(raw));
    const repaired = (try escapeRawBackslashes(testing.allocator, raw)).?;
    defer testing.allocator.free(repaired);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, repaired, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("C:\\users\\me\\a.go", parsed.value.object.get("path").?.string);
}

test "escapeRawBackslashes: a Windows UNC path is repaired" {
    // `\server\share\a.go` written fully raw. Documented limit: the UNC
    // PREFIX is not recoverable here, because a leading `\\` is a LEGAL
    // escape that decodes to a single backslash and the byte pass must not
    // second-guess a legal escape. The illegal separators (`\s`, `\a`) are
    // repaired, so the call parses and the model gets a real "file not
    // found" naming the path it sent, instead of a SyntaxError.
    const raw =
        \\{"path":"\\server\share\a.go","old_str":"x","new_str":"y"}
    ;
    try testing.expect(!parsesAsJson(raw));
    const repaired = (try escapeRawBackslashes(testing.allocator, raw)).?;
    defer testing.allocator.free(repaired);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, repaired, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("\\server\\share\\a.go", parsed.value.object.get("path").?.string);
}

test "escapeRawBackslashes: backslashes OUTSIDE a string literal are not touched" {
    // `\d` between two top-level tokens is not inside a string; repairing
    // it would corrupt the structure rather than fix it.
    const raw =
        \\{"a":"C:\x","b":1}
    ;
    const repaired = (try escapeRawBackslashes(testing.allocator, raw)).?;
    defer testing.allocator.free(repaired);
    try testing.expectEqualStrings("{\"a\":\"C:\\\\x\",\"b\":1}", repaired);
}

test "repairToolCallArguments: valid JSON is returned borrowed, not copied" {
    const raw =
        \\{"path":"/tmp/a.go","old_str":"x","new_str":"y"}
    ;
    const out = (try repairToolCallArguments(testing.allocator, raw)).?;
    try testing.expect(out == .borrowed);
    try testing.expectEqual(@intFromPtr(raw.ptr), @intFromPtr(out.slice().ptr));
    out.deinit(testing.allocator); // borrowed: must not free `raw`
}

test "repairToolCallArguments: repairable Windows arguments come back fixed" {
    const raw =
        \\{"path":"C:\Users\me\a.go","old_str":"x","new_str":"y"}
    ;
    const out = (try repairToolCallArguments(testing.allocator, raw)).?;
    defer out.deinit(testing.allocator);
    try testing.expect(out == .owned);
    try testing.expect(parsesAsJson(out.slice()));
}

test "repairToolCallArguments: unrepairable arguments return null instead of a fake {}" {
    // A truncated object (max_tokens cut mid-call) and a markdown fence are
    // not backslash problems. Returning null is what lets the caller report
    // the real error instead of silently substituting `{}` and blaming a
    // missing field.
    try testing.expect((try repairToolCallArguments(testing.allocator, "{\"path\":\"/tmp/a.go\",\"old_str\":")) == null);
    try testing.expect((try repairToolCallArguments(testing.allocator, "```json\n{\"path\":\"/tmp/a.go\"}\n```")) == null);
}

test "repairToolCallArguments: empty arguments stay a valid empty object" {
    const out = (try repairToolCallArguments(testing.allocator, "{}")).?;
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("{}", out.slice());
}
