# Config.zig accepts only profile names `profile1`..`profile4` (drops user-defined profiles)

## Symptom (user report, task_1785963505875, 2026-08-06)

User says: *"when change profile via chatview i think the profile is not selected as effective on demand"*. The dropdown chip in the chatview shows the selected profile name, but the actual LLM call uses the top-level config (same model in this specific user's case, but a different `api_key`/`base_url` profile would not be picked up).

Screenshot shows the chatview profile picker with `900rlbu` selected (a typo for the user's actual profile name `900ribu` in `~/.config/nalar/config.json`).

## Root cause (live trace)

The user's actual server log (port 8081, `/tmp/agentic_coding.log`) shows the
smoking gun:

```
WORKFLOW: selected_profile_model '900ribu' not found in LlmConfig.profiles_models, using top-level config
[CHECKPOINT] loop iter start session_id=task_1785959915548 loop_counter=183 retry_count=0 effective_model=MiniMax-M3
```

The session row carries `selected_profile_model='900ribu'` (set by the PUT
endpoint), but `LlmConfig.getProfile('900ribu')` returns null, so the
workflow silently falls through to top-level.

Why? `Config.zig` hardcodes the profile schema:

```zig
// src/modules/config/Config.zig:288-293
const ProfilesModelsJson = struct {
    profile1: ?ProfileJson = null,
    profile2: ?ProfileJson = null,
    profile3: ?ProfileJson = null,
    profile4: ?ProfileJson = null,
};

// src/modules/config/Config.zig:487-490
try addProfile(&config.profiles_models, "profile1", profiles_data.profile1, allocator);
try addProfile(&config.profiles_models, "profile2", profiles_data.profile2, allocator);
try addProfile(&config.profiles_models, "profile3", profiles_data.profile3, allocator);
try addProfile(&config.profiles_models, "profile4", profiles_data.profile4, allocator);
```

`ProfilesModelsJson` declares exactly four named fields. `parseFromSlice`
with `ignore_unknown_fields = true` (line 479) silently DROPS every other
key. So the user's `profiles_models: { "900ribu": {...} }` becomes
`profiles_models: {}` after load, even though `mcp_servers` (which uses
the same `json.Value` reparse approach) handles arbitrary keys correctly.

The NalarSettings UI lets the user name their profiles anything (the
profile name is the key they pick), so ANY profile name other than
`profile1`..`profile4` is broken.

## Fix (surgical)

Replace the hardcoded `ProfilesModelsJson` schema with a `json.Value`
reparse that iterates over the object's keys. Same pattern as the
existing `mcp_servers` parser (Config.zig:441-469):

```zig
// New approach for profiles_models:
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

    const profiles_value = profiles_parsed.value;
    switch (profiles_value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                // entry.key_ptr is the profile name (e.g. "900ribu")
                // entry.value_ptr is a json.Value for the profile object
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

`ProfilesModelsJson` struct can be deleted (no remaining references after
this fix).

## Why JSON rep-parse (not a hand-rolled key walker)

The existing `mcp_servers` parser (Config.zig:441-469) uses the same
re-stringify-then-reparse pattern. Reusing the pattern keeps the code
consistent and avoids hand-rolling a JSON object walker in Zig 0.16
(the `std.json.Value` API surface is stable and well-tested).

The cost is one extra string allocation + one extra parse per
profile — negligible for the typical 1-5 profiles case.

## Verification (TDD sequence)

1. **RED**: Add behavioural tests in `config_test.zig` that load a
   config with user-named profiles (e.g. `alpha`, `beta`, `900ribu`)
   and assert they appear in `cfg.profiles_models`. The tests fail
   on the pre-fix code because the names aren't `profile1`..`profile4`.

2. **GREEN**: Apply the fix above. All tests pass.

3. **Live verification**: Restart the user's nalar instance on port 8080
   (don't kill 8081). Send a POST with `selected_profile_model: 900ribu`
   and verify the server log shows `[CHECKPOINT] ... effective_model=...`
   matches the profile's model (not the top-level fallback).

4. **Cross-platform**: `zig build-obj -fno-emit-bin -target x86_64-windows-gnu`
   and `-target aarch64-macos` both compile clean (the fix only changes
   parsing logic, no platform-specific code).

## Plan

### Chunk 1: Fix Config.zig

- Replace `ProfilesModelsJson` schema with a `json.Value` reparse + key
  iterator (same pattern as `mcp_servers`).
- Delete the now-unused `ProfilesModelsJson` struct.
- Update the four `addProfile` calls (one per schema field) with one
  loop over `obj.iterator()`.

### Chunk 2: Behavioural tests

Add 5 cases to `config_test.zig`:

1. `profiles_models: arbitrary name "alpha" → cfg.profiles_models.getEntry("alpha")` returns the profile
2. `profiles_models: arbitrary name "900ribu" (numeric prefix) → cfg.profiles_models.getEntry("900ribu")` returns the profile
3. `profiles_models: multiple arbitrary names → cfg.profiles_models.count()` equals the JSON object's entry count
4. `profiles_models: empty {} → cfg.profiles_models.count()` is 0
5. `profiles_models: missing key → cfg.profiles_models.count()` is 0 (back-compat with legacy configs)

Each test writes a real config to a tempdir via the existing
`writeAndRead` helper (already used by 100+ tests in this file) and
inspects `cfg.profiles_models.getEntry(name)`.

### Chunk 3: Live smoke

- Restart user's nalar on port 8080
- POST `/api/llm/session` with `selected_profile_model: 900ribu`
- Verify `agentic_coding.log` shows `effective_model=MiniMax-M3` AND
  `effective_api_key=<profile api key>` (not the top-level value)

## Out of scope (deferred)

- The "live config re-read per loop iteration" change (existing
  worktree `change-profile-bug`) was already merged on the workflow side;
  this fix only addresses the config-parsing piece. The two together
  mean: changes to `selected_profile_model` (PUT endpoint) take effect
  on the next LLM call without restarting the workflow.
- `parseMcpServersMap` already follows the same pattern; nothing to
  change there.
- `compaction_threshold_percent` and `max_capacity_token_model`
  per-profile overrides: no plan needed; the fix doesn't touch them.

## Pitfalls

- **Don't `defer` the parsed `json.Value`'s `deinit()` before the loop
  finishes iterating** — the `obj.iterator()` borrows from the parsed
  wrapper. Defer AFTER the loop completes (the existing pattern in
  `mcp_servers` is `config.mcpServers_parsed = reparsed;` — store the
  Parsed wrapper as a member for late deinit). For the profiles
  case, we re-stringify each entry BEFORE iterating the next, so the
  source `profiles_parsed` can be deinit'd immediately after the loop.

- **Skip malformed entries, don't fail the whole config load** — match
  the existing `sub_agents` parser's lenient behaviour (warn + skip
  rather than crash the boot).

- **The user's profile name `900ribu` has numeric chars** — `json.parseFromSlice`
  handles this fine because we iterate the parsed `.object`'s `.iterator()`
  which returns string keys. No special-casing needed.

## Files

- `src/modules/config/Config.zig` — fix the parser
- `src/modules/config/config_test.zig` — add 5 behavioural tests
- `AGENTS.md` — changelog entry
- No migration needed (DB unchanged)

## Branch / commit / PR

- Branch: `worktree/investigate-profile-bug` (already created)
- Commit: pending implementation
- PR: pending squash-merge candidate

## References

- `/tmp/agentic_coding.log` — live evidence of the bug (session `task_1785959915548`)
- `src/modules/config/Config.zig:288-293, 487-490` — the bug
- `src/modules/config/Config.zig:441-469` — the `mcp_servers` pattern to mirror
- `src/ai_workflow/tui/agentic_loop/workflow.zig:569-577` — the warning that surfaces the bug
- `src/apps/desktop/src/components/views/ChatView.vue:796-811` — the chatview picker (no bug; correct wire)
- Memory: `.nalar/memories/profile-not-effective-on-demand-2026-08-06.md` (to be created)