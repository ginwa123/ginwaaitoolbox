//! Pure helpers for parsing the per-profile / per-sub-agent `thinking`
//! and `reasoning_effort` string fields. Used by `Config.zig`'s
//! `buildResolvedFromConfig` (sub-agent path) and by the workflow's
//! main-agent resolver (Task 3 of
//! docs/superpowers/plans/2026-08-23-model-thinking.md).
//!
//! Both helpers are pure and side-effect-free — no allocations, no
//! global state — so they're trivially testable in isolation (see
//! `parse_thinking_test.zig`).
//!
//! ## Why a separate file?
//!
//! The previous inline parser at `Config.zig:1247-1253` only understood
//! `"auto" / "true" / "false"`. The new UI in `LlmConfigForm.vue:124-138`
//! sends `"on" / "off" / "auto"`. Extracting the parser to its own
//! module lets us:
//!   - add the `"on" / "off"` aliases without touching `Config.zig`,
//!   - validate `reasoning_effort` (a sibling field) in the same place,
//!   - inline-test in a single file (per the Agent Mode convention).

const std = @import("std");

/// Errors emitted by `parseThinkingString`.
pub const ThinkingModeError = error{InvalidThinkingMode};

/// Parses the per-profile / per-sub-agent `thinking` string field into
/// a typed `?bool`. Semantics:
///
///   - `"auto"`  → `null`  (inherit from parent — the model decides)
///   - `"on"`    → `true`  (extended reasoning enabled; budget via
///                          `thinking_budget_tokens` or Anthropic
///                          `type:"adaptive"` when that's also null)
///   - `"off"`   → `false` (extended reasoning disabled)
///   - `"true"`  → `true`  (legacy UI wrote boolean strings)
///   - `"false"` → `false` (legacy)
///   - `""`      → `null`  (same as `"auto"`)
///   - anything else → `error.InvalidThinkingMode`
///
/// Whitespace at either end is tolerated (single space) so a hand-
/// edited `~/.config/nalar/config.json` with a stray trailing newline
/// doesn't surface as a misconfig.
///
/// Returns a borrowed pointer into `raw` for the matched values — the
/// function does NOT allocate. The caller borrows for the duration of
/// the request (matches the lifetime of `LlmConfig` in the singleton).
pub fn parseThinkingString(raw: []const u8) ThinkingModeError!?bool {
    // Tolerate a single leading/trailing space — defensive against
    // hand-edited config.json files.
    const trimmed: []const u8 = blk: {
        if (raw.len >= 1 and raw[0] == ' ') break :blk raw[1..];
        break :blk raw;
    };
    const s: []const u8 = blk: {
        if (trimmed.len >= 1 and trimmed[trimmed.len - 1] == ' ') break :blk trimmed[0 .. trimmed.len - 1];
        break :blk trimmed;
    };

    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "auto")) return null;
    if (std.mem.eql(u8, s, "on")) return true;
    if (std.mem.eql(u8, s, "off")) return false;
    // Legacy aliases — pre-2026-08-23 UI wrote boolean strings.
    if (std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "false")) return false;
    return error.InvalidThinkingMode;
}

/// Errors emitted by `parseReasoningEffort`.
pub const ReasoningEffortError = error{InvalidReasoningEffort};

/// Parses the per-profile / per-sub-agent `reasoning_effort` string
/// field into the canonical 4-value set accepted by OpenAI-style
/// reasoning APIs (o1 / o3 / GPT-5 / DeepSeek-R1):
///
///   - `"low"`    → `"low"`
///   - `"medium"` → `"medium"`
///   - `"high"`   → `"high"`
///   - `"auto"`   → `"auto"`  (server picks — recommended for new models)
///   - `""`       → `"auto"`  (empty string from the form = default)
///   - anything else → `error.InvalidReasoningEffort`
///
/// The returned slice is one of the four literal strings above
/// (pointing into `.rodata`). Callers that need to store the value
/// long-term (e.g. inside `LlmProfile.reasoning_effort: ?[]const u8`)
/// must `dupe` it. The frontend `ApiNalarProfile` mirror uses the
/// same 4-value enum so this round-trips through JSON unchanged.
///
/// We are intentionally case-sensitive: the frontend always sends
/// lowercase, and accepting uppercase would silently lowercase a
/// user typo. Surface the error so the user notices.
pub fn parseReasoningEffort(raw: []const u8) ReasoningEffortError![]const u8 {
    if (raw.len == 0) return "auto";
    if (std.mem.eql(u8, raw, "low")) return "low";
    if (std.mem.eql(u8, raw, "medium")) return "medium";
    if (std.mem.eql(u8, raw, "high")) return "high";
    if (std.mem.eql(u8, raw, "auto")) return "auto";
    return error.InvalidReasoningEffort;
}
