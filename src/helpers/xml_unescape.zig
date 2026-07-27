const std = @import("std");


/// Decode XML entities produced by the backend's `xmlEscape` (its inverse).
/// Mirrors the same entity set: `&lt;` → `<`, `&gt;` → `>`, `&quot;` → `"`,
/// `&apos;` → `'`, `&amp;` → `&`. The order of replacements matters —
/// `&amp;` MUST be replaced LAST, otherwise the other replacements would
/// double-decode `&amp;`-prefixed entities (e.g. `&amp;quot;` would incorrectly
/// become `"` instead of `&quot;`).
pub fn xmlUnescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    // Fast path: if there are no `&` at all, no entity can be present — return
    // a dupe so the caller's allocator invariant (always-allocated when
    // diff_view_found is true) still holds. This avoids the 5 string scans
    // for the common case (diff_view content rarely contains entities).
    if (std.mem.indexOfScalar(u8, s, '&') == null) {
        return try allocator.dupe(u8, s);
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            // Try each entity in turn; order doesn't matter except for `&amp;`
            // which must be tried LAST (so we don't prematurely decode it).
            // Bounds check: `i + N <= s.len` ensures the slice has N chars.
            if (i + 4 <= s.len and std.mem.eql(u8, s[i..][0..4], "&lt;")) {
                try out.append(allocator, '<');
                i += 4;
            } else if (i + 4 <= s.len and std.mem.eql(u8, s[i..][0..4], "&gt;")) {
                try out.append(allocator, '>');
                i += 4;
            } else if (i + 6 <= s.len and std.mem.eql(u8, s[i..][0..6], "&quot;")) {
                try out.append(allocator, '"');
                i += 6;
            } else if (i + 6 <= s.len and std.mem.eql(u8, s[i..][0..6], "&apos;")) {
                try out.append(allocator, '\'');
                i += 6;
            } else if (i + 5 <= s.len and std.mem.eql(u8, s[i..][0..5], "&amp;")) {
                try out.append(allocator, '&');
                i += 5;
            } else {
                // Unknown entity (or partial match at end of string) — emit
                // the literal `&` and advance one byte. The downstream
                // consumer will see it as-is.
                try out.append(allocator, '&');
                i += 1;
            }
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}
