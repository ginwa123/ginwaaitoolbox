//! Tests for the `parseConfigInput` helper used by
//! `PUT /api/config/nalar`.
//!
//! These tests exercise the PARSE step of the PUT handler — the
//! call into `std.json.parseFromSliceLeaky` that historically rejected
//! the on-disk object-map shape and returned 400 "Invalid JSON input"
//! to the user. Plan 2026-07-07 + PUT-400 bug fix: `ConfigInput.profiles`
//! was changed from `?[]const ProfileChange` (array of granular
//! changes) to `?json.Value` (accepts BOTH the array and the on-disk
//! object map). This test locks in the new behavior so a future
//! refactor can't regress it.
//!
//! Convention: handler internals stay scoped under
//! `nalarcore.http_handlers.*` (see `nalar_config_profile_delete_test.zig`'s
//! header comment for the rationale).

const std = @import("std");
const testing = std.testing;

const nalarcore = @import("nalarcore");
const parseConfigInput = nalarcore.http_handlers.parseConfigInput;

// ---------- Helpers ----------

/// The exact body shape the user's main settings panel sends on save.
/// Reproduces the real-world PUT body that triggered the 400 error:
///   - top-level `profiles` is a Record<name, NalarProfile> (on-disk shape)
///   - top-level `sub_agents` is an array of SubAgentJson (with non-ASCII
///     bytes in `system_prompt` from the agent spec text — em-dash + arrow)
///   - top-level `max_capacity_token_model` + `compaction_threshold_percent`
///     are present (new top-level defaults, plan 2026-07-07)
///   - per-profile `max_capacity_tokens` + `compaction_threshold_percent`
///     are present as `null` (cascading wildcards)
///   - per-profile `sub_agents` is `[]` (empty array, not omitted)
const USER_BODY =
    \\{"api_endpoint":"https://api.minimax.io/v1","api_key":"sk-test","model":"MiniMax-M3","url_style":"openai","temperature":0,"max_tokens":"","system_prompt":"","profiles":{"profile1":{"model":"MiniMax-M2.723223233","base_url":"https://api.minimax.io/v122","thinking":"on","temperature":"0","url_style":"anthropic","api_key":"sk-cp-0","sub_agents":[],"max_capacity_tokens":null,"compaction_threshold_percent":null},"profile2":{"model":"MiniMax-M2.7","base_url":"https://api.minimax.io/v1","thinking":"auto","temperature":"auto","url_style":"openai","api_key":"sk-cp-1","sub_agents":[],"max_capacity_tokens":null,"compaction_threshold_percent":null}},"active_profile":null,"mcp_servers":null,"sub_agents":[{"name":"CodeImplementationAgent","model":"MiniMax-M3","base_url":"https://api.minimax.io/v1","thinking":"false","temperature":"auto","url_style":"openai","api_key":"sk-cp-x","system_prompt":"em-dash here: \u2014, arrow here: \u2192, fully valid UTF-8."},{"name":"DebuggingAgent","model":"MiniMax-M3","base_url":"https://api.minimax.io/v1","thinking":"true","temperature":"auto","url_style":"openai","api_key":"sk-cp-x","system_prompt":"another agent with binary-search comment out halves \u2014 fully valid UTF-8."}],"notify_on_complete":true,"model_compaction_size_kb":100,"max_capacity_token_model":500000,"compaction_threshold_percent":95}
;

// ---------- Tests ----------

test "parseConfigInput: accepts the on-disk object-map shape (user's main settings panel body)" {
    // `parseFromSliceLeaky` does allocate (slice headers for the
    // `[]SubAgentJson`, internal ObjectMap storage for `?json.Value`),
    // so we back it with an arena. Production handlers don't need
    // this because the per-request arena in GinwaServer reaps all
    // request allocations (see project memory
    // `custom-http-server-per-request-arena`).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // `parseConfigInput` uses `std.json.parseFromSliceLeaky` — the
    // returned struct's string slices borrow from the input body
    // (no copies made). The user must keep `USER_BODY` alive for
    // the lifetime of the parsed struct. USER_BODY is at module
    // scope, so it's alive for the whole test function.
    const input = try parseConfigInput(arena.allocator(), USER_BODY);

    // Sanity: the top-level scalars parsed.
    try testing.expectEqualStrings("MiniMax-M3", input.model);
    try testing.expectEqualStrings("openai", input.url_style);
    try testing.expectEqualStrings("https://api.minimax.io/v1", input.api_endpoint);
    try testing.expectEqualStrings("", input.max_tokens.?);
    try testing.expectEqual(@as(?u32, 500000), input.max_capacity_token_model);
    try testing.expectEqual(@as(?u8, 95), input.compaction_threshold_percent);
    try testing.expect(input.notify_on_complete == true);
    try testing.expectEqual(@as(usize, 100), input.model_compaction_size_kb);

    // The fix: `profiles` is a json.Value object map (NOT an array).
    // Pre-fix the type was `?[]const ProfileChange` and this test would
    // fail with `error.InvalidCharacter` because the object map doesn't
    // match the array shape.
    const profiles_value = input.profiles orelse return error.ProfilesFieldMissing;
    try testing.expect(profiles_value == .object);
    try testing.expectEqual(@as(usize, 2), profiles_value.object.count());

    // The keys are the profile names from the user's body.
    var iter = profiles_value.object.iterator();
    var seen_profile1 = false;
    var seen_profile2 = false;
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "profile1")) {
            seen_profile1 = true;
            // profile1 carries the per-profile compaction overrides as
            // null (cascading wildcards) — verify they round-trip.
            const p1 = entry.value_ptr.*;
            try testing.expect(p1 == .object);
            try testing.expect(p1.object.get("max_capacity_tokens").? == .null);
            try testing.expect(p1.object.get("compaction_threshold_percent").? == .null);
        } else if (std.mem.eql(u8, entry.key_ptr.*, "profile2")) {
            seen_profile2 = true;
        } else {
            return error.UnexpectedProfileKey;
        }
    }
    try testing.expect(seen_profile1);
    try testing.expect(seen_profile2);

    // The `sub_agents` array is also present and parsed (with non-ASCII
    // bytes in the system_prompts — would have failed the parse before
    // any change if the field were missing or wrongly typed).
    const sub_agents = input.sub_agents orelse return error.SubAgentsFieldMissing;
    try testing.expectEqual(@as(usize, 2), sub_agents.len);
    try testing.expectEqualStrings("CodeImplementationAgent", sub_agents[0].name);
    try testing.expectEqualStrings("DebuggingAgent", sub_agents[1].name);
    // The em-dash and arrow survive the parse round-trip (the
    // pre-fix parse error was triggered by this exact byte sequence).
    // Em-dash is U+2014 = 0xE2 0x80 0x94 in UTF-8.
    const em_dash = "\xe2\x80\x94";
    try testing.expect(std.mem.indexOf(u8, sub_agents[0].system_prompt, em_dash) != null);
    try testing.expect(std.mem.indexOf(u8, sub_agents[1].system_prompt, em_dash) != null);
}

test "parseConfigInput: accepts the granular array-of-changes shape (regression)" {
    // Pre-fix this was the ONLY shape that worked. The fix must keep
    // it working — the sub-agent add/edit/delete UIs send this shape.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // `body` stays alive for the test (constant slice — parsed slices borrow).
    const body =
        \\{"api_key":"k","model":"m","api_endpoint":"https://api.test/v1","profiles":[{"name":"alpha","action":"add","model":"m","base_url":"https://api.test/v1","thinking":"auto","temperature":"auto","url_style":"openai","api_key":"k","sub_agents":[]}]}
    ;

    const input = try parseConfigInput(arena.allocator(), body);

    const profiles_value = input.profiles orelse return error.ProfilesFieldMissing;
    try testing.expect(profiles_value == .array);
    try testing.expectEqual(@as(usize, 1), profiles_value.array.items.len);
    // The single entry is a full profile object map (the array form is
    // a "replace" semantic, not granular per-field changes).
    const entry = profiles_value.array.items[0];
    try testing.expect(entry == .object);
    try testing.expectEqualStrings("m", entry.object.get("model").?.string);
}

test "parseConfigInput: accepts a body with NO profiles field (regression)" {
    // Pre-existing on-disk files may omit `profiles` entirely. The
    // handler should treat that as "no change to profiles" — the parse
    // step must NOT require the field.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const body =
        \\{"api_key":"k","model":"m","api_endpoint":"https://api.test/v1"}
    ;

    const input = try parseConfigInput(arena.allocator(), body);

    try testing.expect(input.profiles == null);
    try testing.expect(input.sub_agents == null);
    try testing.expect(input.mcp_servers == null);
    try testing.expect(input.max_capacity_token_model == null);
    try testing.expect(input.compaction_threshold_percent == null);
}

test "parseConfigInput: rejects malformed JSON with SyntaxError (not InvalidCharacter)" {
    const body =
        \\{"api_key":"k","model":"m",broken}
    ;

    const result = parseConfigInput(testing.allocator, body);
    try testing.expectError(error.SyntaxError, result);
}
