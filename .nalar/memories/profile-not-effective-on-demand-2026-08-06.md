# Config.zig drops user-named profiles (only accepts profile1..profile4)

## Symptom (user report, task_1785963505875, 2026-08-06)

User: *"when change profile via chatview i think the profile is not
selected as effective on demand"*. Chatview dropdown shows the selected
profile name with a checkmark, but the actual LLM call uses the
top-level config (same model in the user's case, but a different
`api_key`/`base_url` profile would be silently ignored).

## Root cause

`src/modules/config/Config.zig` hardcodes the profile schema:

```zig
// Line 288-293
const ProfilesModelsJson = struct {
    profile1: ?ProfileJson = null,
    profile2: ?ProfileJson = null,
    profile3: ?ProfileJson = null,
    profile4: ?ProfileJson = null,
};

// Line 487-490
try addProfile(&config.profiles_models, "profile1", profiles_data.profile1, allocator);
try addProfile(&config.profiles_models, "profile2", profiles_data.profile2, allocator);
try addProfile(&config.profiles_models, "profile3", profiles_data.profile3, allocator);
try addProfile(&config.profiles_models, "profile4", profiles_data.profile4, allocator);
```

`parseFromSlice` with `ignore_unknown_fields = true` (line 479)
silently DROPS every key other than `profile1`..`profile4`. So
`profiles_models: { "900ribu": {...} }` becomes `profiles_models: {}`
after load.

The NalarSettings UI lets the user name their profiles anything, so
ANY profile name other than `profile1`..`profile4` is broken.

## Diagnostic

Live evidence from the user's `/tmp/agentic_coding.log`:

```
WORKFLOW: selected_profile_model '900ribu' not found in LlmConfig.profiles_models, using top-level config
[CHECKPOINT] loop iter start session_id=task_1785959915548 loop_counter=183 retry_count=0 effective_model=MiniMax-M3
```

The session row carries `selected_profile_model='900ribu'` (set by
PUT `/api/llm/session/:id` → `updateSessionSelectedProfileModel`), but
`LlmConfig.getProfile('900ribu')` returns null. The warning + silent
fallback to top-level is the bug signature.

## Fix (the canonical pattern)

Replace the hardcoded `ProfilesModelsJson` schema with a `json.Value`
reparse + key iterator. Same pattern as the existing `mcp_servers`
parser (Config.zig:441-469):

```zig
if (config_json.profiles_models) |profiles| {
    const profiles_str = std.json.Stringify.valueAlloc(allocator, profiles, .{}) catch {
        return error.InvalidJson;
    };
    defer allocator.free(profiles_str);

    const profiles_parsed = json.parseFromSlice(json.Value, allocator, profiles_str, .{
        .ignore_unknown_fields = true,
    }) catch {
        return error.InvalidJson;
    };
    defer profiles_parsed.deinit();

    switch (profiles_parsed.value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const profile_json_str = std.json.Stringify.valueAlloc(
                    allocator, entry.value_ptr, .{},
                ) catch continue;
                defer allocator.free(profile_json_str);

                const profile_parsed = json.parseFromSlice(
                    ProfileJson, allocator, profile_json_str,
                    .{ .ignore_unknown_fields = true },
                ) catch continue;
                defer profile_parsed.deinit();

                try addProfile(
                    &config.profiles_models,
                    entry.key_ptr.*,
                    profile_parsed.value,
                    allocator,
                );
            }
        },
        else => {},
    }
}
```

`ProfilesModelsJson` struct can be deleted (no remaining references).

## Why JSON rep-parse

Same pattern as `mcp_servers`. Reuses the stable `std.json.Value` API
instead of hand-rolling a JSON walker. Cost: 1 extra alloc + 1 extra
parse per profile. Negligible for typical 1-5 profiles.

## Verification (TDD sequence)

1. RED: add 5 tests in `config_test.zig` that load configs with
   user-named profiles (`alpha`, `beta`, `900ribu`, empty `{}`,
   missing key) and assert they appear in `cfg.profiles_models`.
   All 5 fail on pre-fix code.
2. GREEN: apply the fix. All 5 pass.
3. Cross-compile `zig build-obj -fno-emit-bin -target X` for Windows
   + macOS — clean.
4. Live smoke: restart user's nalar on port 8080, POST a session with
   `selected_profile_model: 900ribu`, verify `agentic_coding.log`
   shows the warning is GONE (the profile name resolves successfully).

## Pitfalls

- **`defer profiles_parsed.deinit()` AFTER the loop** — the
  `obj.iterator()` borrows from the parsed wrapper. (For the
  profiles case we re-stringify each entry into a local buffer
  before consuming, so the source `profiles_parsed` can be deinit'd
  immediately after the loop completes.)

- **Skip malformed entries, don't fail the whole load** — match the
  existing `sub_agents` parser's lenient behaviour (warn + skip
  rather than crash the boot).

- **Numeric profile names work fine** — `entry.key_ptr.*` returns
  the JSON string key as-is, no special-casing for numeric prefixes.

## Related files

- `src/modules/config/Config.zig:288-293, 487-490` — the bug
- `src/modules/config/Config.zig:441-469` — the `mcp_servers` pattern to mirror
- `src/ai_workflow/tui/agentic_loop/workflow.zig:569-577` — the warning that surfaces the bug
- `src/modules/config/config_test.zig` — where the regression test goes
- `src/apps/desktop/src/components/views/ChatView.vue:796-811` —
  the chatview picker (no bug; correct wire to backend)

## Related (no bug, but relevant context)

- `src/ai_workflow/tui/http_handlers/session_update.zig:69` —
  `updateSessionSelectedProfileModel` persists the session's
  `selected_profile_model` correctly. Verified via
  `session_update_test.zig` (already covered).
- `src/apps/desktop/src/api/index.ts:1089-1118` — frontend's
  `updateSession` sends the PUT correctly. No bug here.
- `src/apps/desktop/src/components/views/ChatView.vue:796-811` —
  `selectProfile` writes the new value to the local `selectedProfile`
  ref before the next send. No bug here.
- `src/ai_workflow/tui/agentic_loop/workflow.zig:574-577` —
  `resolveProfileField` correctly resolves the cascade
  (selected_profile_model → active_profile → top-level). The cascade
  works; the problem is the lookup table is empty.

## Branch / PR

- Branch: `worktree/investigate-profile-bug`
- Plan: `docs/superpowers/plans/2026-08-06-config-profiles-arbitrary-keys.md`
- Files: 2 (Config.zig + config_test.zig), +AGENTS.md changelog entry
- No DB / migration change
- Worktree: `/home/ginwa/ginwaaitoolbox/.worktrees/investigate-profile-bug`