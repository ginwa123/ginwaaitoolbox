# Sub-Agents Config Field Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new top-level `sub_agents` array to `LlmConfig` (and a `sub_agents` array inside each `LlmProfile`) so users can define named sub-agent LLM configurations (model + base_url + thinking + temperature + url_style + api_key + system_prompt) for both the default model and each profile.

**Architecture:**
- New typed `SubAgentConfig` struct (mirrors `LlmProfile` fields + `system_prompt`) and `SubAgentsList` slice.
- Stored as an **owned `[]SubAgentConfig`** on the parent (top-level `LlmConfig` and each `LlmProfile`), so cloning/deinit is straightforward (no StringHashMap).
- Parsed from JSON via a new `SubAgentJson` struct (matches the user's exact wire format).
- Exposed via `GET /api/config/nalar` (response gains a `sub_agents` array and each profile entry gains its own `sub_agents` array).
- Accepted via `PUT /api/config/nalar` (whole-list replace for both top-level and per-profile `sub_agents`).
- Rendered in `NalarSettings.vue` as a new "Sub-Agents" section beneath the existing "Profiles" section, and as a nested sub-agents list inside each profile's edit modal.

**Tech Stack:** Zig 0.15 (server-side, `Config.zig` + HTTP handlers), TypeScript + Vue 3 (frontend, `api/index.ts` + `NalarSettings.vue`).

---

## File Structure

| File | Responsibility |
|---|---|
| `src/modules/config/Config.zig` | Add `SubAgentConfig` struct, `SubAgentsList` alias, parse top-level + per-profile `sub_agents` arrays, add accessors, deep-clone, deep-free |
| `src/modules/config/config_test.zig` | Unit tests for parse/clone/deinit/accessors of the new field |
| `src/ai_workflow/tui/http_handlers/nalar_config_get.zig` | Add `sub_agents` to `ConfigJson` + include in `NalarConfigResponse` payload |
| `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` | Add `sub_agents` to `ConfigInput` + `ConfigJson`; whole-list replace for top-level and per-profile |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | Extend `NalarConfigResponse` and `LlmProfileResponse` to carry `sub_agents` |
| `src/apps/desktop/src/api/index.ts` | Add `sub_agents` to `NalarConfig`, `NalarProfile`, and `getNalarConfig`/`saveNalarConfig` signatures |
| `src/apps/desktop/src/components/NalarSettings.vue` | Render a "Sub-Agents" section + nested sub-agents UI in the profile edit modal; serialize `sub_agents` on save |

---

## Task 1: Add `SubAgentConfig` and `SubAgentsList` types to `Config.zig`

**Files:**
- Modify: `src/modules/config/Config.zig:39-46` (insert new types after `LlmProfile`)
- Test: `src/modules/config/config_test.zig` (append a new test)

- [ ] **Step 1.1: Write the failing test**

Append to `src/modules/config/config_test.zig`:

```zig
test "sub_agents: top-level field is parsed into SubAgentsList" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k",
        \\  "model": "m",
        \\  "base_url": "b",
        \\  "sub_agents": [
        \\    {
        \\      "name": "SubAgent1",
        \\      "model": "MiniMax-M3",
        \\      "base_url": "https://api.minimax.io/v1",
        \\      "thinking": "false",
        \\      "temperature": "auto",
        \\      "url_style": "openai",
        \\      "api_key": "",
        \\      "system_prompt": ""
        \\    }
        \\  ]
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 1), cfg.sub_agents.len);
    const sa = cfg.sub_agents[0];
    try std.testing.expectEqualStrings("SubAgent1", sa.name);
    try std.testing.expectEqualStrings("MiniMax-M3", sa.model);
    try std.testing.expectEqualStrings("https://api.minimax.io/v1", sa.base_url);
    try std.testing.expectEqualStrings("false", sa.thinking);
    try std.testing.expectEqualStrings("auto", sa.temperature);
    try std.testing.expectEqualStrings("openai", sa.url_style);
    try std.testing.expectEqualStrings("", sa.api_key);
    try std.testing.expectEqualStrings("", sa.system_prompt);
}
```

- [ ] **Step 1.2: Run the test to verify it fails**

Run: `timeout 120 zig build test:config 2>&1 | tail -n 20`
Expected: FAIL — `error: no member named 'sub_agents' in struct 'LlmConfig'`.

- [ ] **Step 1.3: Add the `SubAgentConfig` and `SubAgentsList` types**

Modify `src/modules/config/Config.zig`. Insert **after line 46** (after the `LlmProfile` const definition):

```zig
    /// Named sub-agent LLM configuration. Lives inside the top-level
    /// `LlmConfig` AND inside each `LlmProfile` (so each profile can
    /// carry its own sub-agent set). Mirrors `LlmProfile` fields plus
    /// a `system_prompt` that profiles don't have.
    pub const SubAgentConfig = struct {
        name: []const u8,
        model: []const u8,
        base_url: []const u8,
        thinking: []const u8,
        temperature: []const u8,
        url_style: []const u8,
        api_key: []const u8,
        system_prompt: []const u8,
    };

    /// Owned list of sub-agents. The slice AND every string field are
    /// allocated with the parent `LlmConfig.allocator`.
    pub const SubAgentsList = []SubAgentConfig;
```

- [ ] **Step 1.4: Run the test — still fails (expected, no field on LlmConfig yet)**

Run: `timeout 120 zig build test:config 2>&1 | tail -n 10`
Expected: FAIL — `error: no member named 'sub_agents' in struct 'LlmConfig'`.

---

## Task 2: Add `sub_agents` field to `LlmConfig` + parse from JSON

**Files:**
- Modify: `src/modules/config/Config.zig:6-26` (add field to `LlmConfig`)
- Modify: `src/modules/config/Config.zig:57-71` (add field to `LlmConfigJson`)
- Modify: `src/modules/config/Config.zig:48-55` (add field to `ProfileJson` + corresponding `LlmProfile`)
- Modify: `src/modules/config/Config.zig:111-217` (init logic)

- [ ] **Step 2.1: Add the field to `LlmConfig`**

Modify line 6-26 in `Config.zig`. Insert after `profiles_models`:

```zig
    /// Parsed sub-agents from the top-level `sub_agents` JSON array.
    /// Ordered (the user controls order via the JSON array); consumers
    /// should look up by `name` if they need a specific entry.
    sub_agents: SubAgentsList,
```

- [ ] **Step 2.2: Add the field to `LlmProfile` (so per-profile sub-agents work)**

Modify line 39-46. Insert after `url_style: []const u8 = "openai",`:

```zig
        /// Per-profile sub-agents. Same shape as the top-level
        /// `LlmConfig.sub_agents`; profiles can override the default
        /// sub-agent set with their own.
        sub_agents: SubAgentsList = &.{},
```

- [ ] **Step 2.3: Add the field to `ProfileJson` (the JSON parse target)**

Modify line 48-55. Insert after `url_style: []const u8 = "openai",`:

```zig
        sub_agents: ?std.json.Value = null,
```

- [ ] **Step 2.4: Add the field to `LlmConfigJson`**

Modify line 57-71. Insert after `profiles_models: ?std.json.Value = null,`:

```zig
        /// Top-level sub-agents array. Each entry is a
        /// `SubAgentConfig`-shaped object.
        sub_agents: ?std.json.Value = null,
```

- [ ] **Step 2.5: Run the test — should now parse but the slice is empty**

Run: `timeout 120 zig build test:config 2>&1 | tail -n 10`
Expected: FAIL — `expected len 1, found 0` (field exists but isn't populated yet).

- [ ] **Step 2.6: Add a `SubAgentJson` parse struct + helper, and wire up parsing**

Modify the region around line 73-81 in `Config.zig` (just after `LlmConfigJson`). Insert the JSON parse struct:

```zig
    const SubAgentJson = struct {
        name: []const u8 = "",
        model: []const u8 = "",
        base_url: []const u8 = "",
        thinking: []const u8 = "auto",
        temperature: []const u8 = "auto",
        url_style: []const u8 = "openai",
        api_key: []const u8 = "",
        system_prompt: []const u8 = "",
    };
```

Then add a private parse helper (insert after `addProfile` around line 267):

```zig
    /// Parse a `SubAgentsList` from a JSON array value.
    /// Returns an empty slice when `value` is null or not an array.
    /// Entries missing the `name` field are skipped (with a warning).
    fn parseSubAgentsList(allocator: std.mem.Allocator, value: ?std.json.Value) !SubAgentsList {
        const arr = switch (value) {
            .array => |a| a,
            else => return &.{},
        };

        var list = std.ArrayList(SubAgentConfig).empty;
        errdefer {
            for (list.items) |sa| {
                allocator.free(sa.name);
                allocator.free(sa.model);
                allocator.free(sa.base_url);
                allocator.free(sa.thinking);
                allocator.free(sa.temperature);
                allocator.free(sa.url_style);
                allocator.free(sa.api_key);
                allocator.free(sa.system_prompt);
            }
            list.deinit(allocator);
        }

        for (arr.items) |item| {
            const obj = item.object;
            const name_val = obj.get("name") orelse {
                std.log.warn("sub_agents entry missing 'name'; skipping", .{});
                continue;
            };
            if (name_val != .string or name_val.string.len == 0) {
                std.log.warn("sub_agents entry has empty/non-string 'name'; skipping", .{});
                continue;
            }

            // Re-serialize this single entry to a flat object, then
            // parse it as `SubAgentJson` so we get the defaults applied
            // and string-vs-number validation done by the parser.
            const item_str = try std.json.Stringify.valueAlloc(allocator, item, .{});
            defer allocator.free(item_str);
            const parsed = json.parseFromSlice(SubAgentJson, allocator, item_str, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.log.warn("Failed to parse sub_agents entry: {s}", .{@errorName(err)});
                continue;
            };
            defer parsed.deinit();

            const j = parsed.value;
            const name = try allocator.dupe(u8, j.name);
            errdefer allocator.free(name);
            const model = try allocator.dupe(u8, j.model);
            errdefer allocator.free(model);
            const base_url = try allocator.dupe(u8, j.base_url);
            errdefer allocator.free(base_url);
            const thinking = try allocator.dupe(u8, j.thinking);
            errdefer allocator.free(thinking);
            const temperature = try allocator.dupe(u8, j.temperature);
            errdefer allocator.free(temperature);
            const url_style = try allocator.dupe(u8, j.url_style);
            errdefer allocator.free(url_style);
            const api_key = try allocator.dupe(u8, j.api_key);
            errdefer allocator.free(api_key);
            const system_prompt = try allocator.dupe(u8, j.system_prompt);
            errdefer allocator.free(system_prompt);

            try list.append(allocator, .{
                .name = name,
                .model = model,
                .base_url = base_url,
                .thinking = thinking,
                .temperature = temperature,
                .url_style = url_style,
                .api_key = api_key,
                .system_prompt = system_prompt,
            });
        }

        return list.toOwnedSlice(allocator);
    }
```

- [ ] **Step 2.7: Add a deep-free helper for `SubAgentsList`**

Insert after the parse helper:

```zig
    /// Free every owned string inside a `SubAgentsList`, then free the
    /// backing slice. Safe to call on a `&.{}` empty slice.
    fn freeSubAgentsList(slice: SubAgentsList, allocator: std.mem.Allocator) void {
        for (slice) |sa| {
            allocator.free(sa.name);
            allocator.free(sa.model);
            allocator.free(sa.base_url);
            allocator.free(sa.thinking);
            allocator.free(sa.temperature);
            allocator.free(sa.url_style);
            allocator.free(sa.api_key);
            allocator.free(sa.system_prompt);
        }
        if (slice.len > 0) allocator.free(slice);
    }
```

- [ ] **Step 2.8: Wire the top-level field into the `LlmConfig` initializer**

Modify `init` around line 142-216. The `LlmConfig` struct literal needs the new field. Change line 152-153 (the `.profiles_models` line) to:

```zig
            .profiles_models = ProfilesMap.init(allocator),
            .sub_agents = &.{},
```

- [ ] **Step 2.9: Populate the top-level `sub_agents` from JSON**

At the end of `init` (just before `return config;` at line 216), insert:

```zig
        // Parse top-level sub_agents
        config.sub_agents = try parseSubAgentsList(allocator, config_json.sub_agents);
```

- [ ] **Step 2.10: Populate per-profile `sub_agents` in `addProfile`**

Modify `addProfile` (line 235-267). It currently does NOT populate `sub_agents`; the new `LlmProfile` field has a default of `&.{}` so existing tests will keep passing. To honor per-profile sub_agents, the helper needs the JSON `?std.json.Value` as an extra param. **Replace the `addProfile` signature and body** to take an optional per-profile JSON value:

```zig
    fn addProfile(m: *ProfilesMap, name: []const u8, p: ?ProfileJson, alloc: std.mem.Allocator) !void {
        const profile = p orelse return;

        const key = try alloc.dupe(u8, name);
        errdefer alloc.free(key);

        const model = try alloc.dupe(u8, profile.model);
        errdefer alloc.free(model);

        const base_url = try alloc.dupe(u8, profile.base_url);
        errdefer alloc.free(base_url);

        const thinking = try alloc.dupe(u8, profile.thinking);
        errdefer alloc.free(thinking);

        const temperature = try alloc.dupe(u8, profile.temperature);
        errdefer alloc.free(temperature);

        const url_style = try alloc.dupe(u8, profile.url_style);
        errdefer alloc.free(url_style);

        const api_key = try alloc.dupe(u8, profile.api_key);
        errdefer alloc.free(api_key);

        // Per-profile sub-agents. ProfileJson.sub_agents is a
        // `?std.json.Value` (an array of SubAgentConfig-shaped objects).
        const profile_sub_agents = try parseSubAgentsList(alloc, profile.sub_agents);
        errdefer freeSubAgentsList(profile_sub_agents, alloc);

        try m.put(key, LlmProfile{
            .model = model,
            .base_url = base_url,
            .thinking = thinking,
            .temperature = temperature,
            .api_key = api_key,
            .url_style = url_style,
            .sub_agents = profile_sub_agents,
        });
    }
```

- [ ] **Step 2.11: Add the top-level sub_agents to the `errdefer` in `init`**

In the `errdefer` block at line 154-162, insert after the `freeProfilesMap` line:

```zig
            freeSubAgentsList(config.sub_agents, allocator);
```

- [ ] **Step 2.12: Run the test from Task 1 — should now pass**

Run: `timeout 120 zig build test:config 2>&1 | tail -n 20`
Expected: PASS — `sub_agents: top-level field is parsed into SubAgentsList` is green.

- [ ] **Step 2.13: Commit**

```bash
git add src/modules/config/Config.zig src/modules/config/config_test.zig
git commit -m "config: add sub_agents array to LlmConfig and LlmProfile"
```

---

## Task 3: Add accessor methods + clone + deinit support

**Files:**
- Modify: `src/modules/config/Config.zig:389-401` (deinit)
- Modify: `src/modules/config/Config.zig:403-488` (clone)
- Modify: `src/modules/config/Config.zig:544-557` (after `getProfile`/`hasProfile`)

- [ ] **Step 3.1: Write the failing test for accessors + clone + deinit**

Append to `src/modules/config/config_test.zig`:

```zig
test "sub_agents: hasSubAgent / getSubAgent accessors" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "sub_agents": [
        \\    { "name": "alpha", "model": "M1", "base_url": "https://a",
        \\      "thinking": "on", "temperature": "0.5", "url_style": "openai",
        \\      "api_key": "ak1", "system_prompt": "you are alpha" },
        \\    { "name": "beta",  "model": "M2", "base_url": "https://b",
        \\      "thinking": "off", "temperature": "auto", "url_style": "anthropic",
        \\      "api_key": "ak2", "system_prompt": "" }
        \\  ]
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    try std.testing.expect(cfg.hasSubAgent("alpha"));
    try std.testing.expect(cfg.hasSubAgent("beta"));
    try std.testing.expect(!cfg.hasSubAgent("nope"));

    const a = cfg.getSubAgent("alpha").?;
    try std.testing.expectEqualStrings("M1", a.model);
    try std.testing.expectEqualStrings("https://a", a.base_url);
    try std.testing.expectEqualStrings("on", a.thinking);
    try std.testing.expectEqualStrings("0.5", a.temperature);
    try std.testing.expectEqualStrings("you are alpha", a.system_prompt);

    try std.testing.expect(cfg.getSubAgent("nope") == null);
}

test "sub_agents: clone produces independent deep copy" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "sub_agents": [
        \\    { "name": "alpha", "model": "M1", "base_url": "https://a",
        \\      "thinking": "on", "temperature": "0.5", "url_style": "openai",
        \\      "api_key": "ak1", "system_prompt": "sp" }
        \\  ]
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    var cloned = try cfg.clone();
    defer {
        cfg.deinit();
        cloned.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), cloned.sub_agents.len);
    const orig = cfg.sub_agents[0];
    const copy = cloned.sub_agents[0];
    try std.testing.expect(orig.name.ptr != copy.name.ptr);
    try std.testing.expect(orig.model.ptr != copy.model.ptr);
    try std.testing.expectEqualStrings("alpha", copy.name);
    try std.testing.expectEqualStrings("sp", copy.system_prompt);
}

test "sub_agents: per-profile sub_agents are parsed" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "api_key": "k", "model": "m", "base_url": "b",
        \\  "profiles_models": {
        \\    "profile1": {
        \\      "model": "M-p1", "base_url": "https://p1",
        \\      "thinking": "auto", "temperature": "auto",
        \\      "url_style": "openai", "api_key": "kp1",
        \\      "sub_agents": [
        \\        { "name": "p1sa", "model": "M1", "base_url": "https://a",
        \\          "thinking": "on", "temperature": "0.5", "url_style": "openai",
        \\          "api_key": "ak1", "system_prompt": "sp1" }
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    var cfg = try writeAndRead(allocator, std.testing.io, json);
    defer cfg.deinit();

    const p1 = cfg.getProfile("profile1").?;
    try std.testing.expectEqual(@as(usize, 1), p1.sub_agents.len);
    try std.testing.expectEqualStrings("p1sa", p1.sub_agents[0].name);
    try std.testing.expectEqualStrings("M1", p1.sub_agents[0].model);
    try std.testing.expectEqualStrings("sp1", p1.sub_agents[0].system_prompt);
}
```

- [ ] **Step 3.2: Run tests — should fail (no accessors yet)**

Run: `timeout 120 zig build test:config 2>&1 | tail -n 10`
Expected: FAIL — `error: no member named 'hasSubAgent' in struct 'LlmConfig'`.

- [ ] **Step 3.3: Add accessors**

Insert after `hasProfile` (around line 557 in `Config.zig`):

```zig
    /// Look up a top-level sub-agent by `name`. Returns null when not
    /// configured. The returned `SubAgentConfig` borrows from `self` —
    /// do not outlive the config.
    pub fn getSubAgent(self: *const LlmConfig, name: []const u8) ?SubAgentConfig {
        for (self.sub_agents) |sa| {
            if (std.mem.eql(u8, sa.name, name)) return sa;
        }
        return null;
    }

    /// Returns true when a sub-agent with the given `name` exists.
    pub fn hasSubAgent(self: *const LlmConfig, name: []const u8) bool {
        return self.getSubAgent(name) != null;
    }

    /// Returns the number of top-level sub-agents.
    pub fn subAgentCount(self: *const LlmConfig) u32 {
        return @intCast(self.sub_agents.len);
    }
```

- [ ] **Step 3.4: Update `deinit`**

In `deinit` (line 389-401), add `freeSubAgentsList` call. Insert after the `freeProfilesMap` line:

```zig
        freeSubAgentsList(self.sub_agents, self.allocator);
```

- [ ] **Step 3.5: Update `clone`**

In `clone` (line 403-488), the struct literal at line 404-415 needs the new field, and the errdefer needs the free call. Modify:

1. Inside the struct literal (around line 414), add `.sub_agents = &.{},` after `profiles_models = ...`.
2. In the `errdefer` block (around line 416-424), add `freeSubAgentsList(config.sub_agents, self.allocator);` after `freeProfilesMap`.
3. After the profile-cloning loop (around line 485), add the top-level sub_agents deep-clone:

```zig
        // Deep-copy top-level sub_agents
        for (self.sub_agents) |sa| {
            const dup = SubAgentConfig{
                .name = try self.allocator.dupe(u8, sa.name),
                .model = try self.allocator.dupe(u8, sa.model),
                .base_url = try self.allocator.dupe(u8, sa.base_url),
                .thinking = try self.allocator.dupe(u8, sa.thinking),
                .temperature = try self.allocator.dupe(u8, sa.temperature),
                .url_style = try self.allocator.dupe(u8, sa.url_style),
                .api_key = try self.allocator.dupe(u8, sa.api_key),
                .system_prompt = try self.allocator.dupe(u8, sa.system_prompt),
            };
            try sub_agents_list.append(self.allocator, dup);
        }
        config.sub_agents = try sub_agents_list.toOwnedSlice(self.allocator);
```

You'll need a `var sub_agents_list = std.ArrayList(SubAgentConfig).empty;` declared just before the `return config;` at the bottom of `clone`.

- [ ] **Step 3.6: Run all the new tests**

Run: `timeout 120 zig build test:config 2>&1 | tail -n 30`
Expected: PASS — all three new tests are green.

- [ ] **Step 3.7: Commit**

```bash
git add src/modules/config/Config.zig src/modules/config/config_test.zig
git commit -m "config: sub_agents accessors, clone, deinit"
```

---

## Task 4: Expose `sub_agents` via `GET /api/config/nalar`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig:138-155` (add field to `NalarConfigResponse`)
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig:271-293` (add field to `LlmProfileResponse`)
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_get.zig:88-102` (add field to `ConfigJson`)
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_get.zig:71-86` (pass to response)

- [ ] **Step 4.1: Add `sub_agents` to `NalarConfigResponse`**

In `http_response.zig`, modify the `NalarConfigResponse` struct (line 138-151) by adding after the `mcp_servers` line:

```zig
    /// Top-level sub-agents array. Sent as the raw `json.Value` so the
    /// frontend gets full fidelity (preserves the exact shape).
    sub_agents: ?std.json.Value = null,
```

- [ ] **Step 4.2: Add `sub_agents` to `LlmProfileResponse`**

In `http_response.zig`, modify the `LlmProfileResponse` struct (line 271-278) by adding after `api_key`:

```zig
    /// Per-profile sub-agents. Same shape as the top-level
    /// `sub_agents` field.
    sub_agents: ?std.json.Value = null,
```

- [ ] **Step 4.3: Add `sub_agents` to the GET handler's `ConfigJson`**

In `nalar_config_get.zig`, modify the `ConfigJson` struct (line 88-102) by adding after `active_profile`:

```zig
    sub_agents: ?json.Value = null,
```

- [ ] **Step 4.4: Wire the new field into the GET response**

In `nalar_config_get.zig` (line 71-86), the `makeNalarConfigResponse` call needs the new field. Modify the call to add `.sub_agents = cfg.sub_agents,` after the `mcp_servers` line.

- [ ] **Step 4.5: Build to verify**

Run: `timeout 120 zig build 2>&1 | tail -n 20`
Expected: PASS.

- [ ] **Step 4.6: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/http_response.zig src/ai_workflow/tui/http_handlers/nalar_config_get.zig
git commit -m "config-api: GET exposes top-level sub_agents"
```

---

## Task 5: Accept `sub_agents` via `PUT /api/config/nalar` (whole-list replace, top-level + per-profile)

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put.zig:233-246` (add field to `ConfigInput`)
- Modify: `src/ai_workflow/tui/http_handlers/nalar_config_put.zig:259-270` (add field to `ConfigJson`)

- [ ] **Step 5.1: Add `sub_agents` to `ConfigInput`**

In `nalar_config_put.zig`, modify `ConfigInput` (line 233-246) by adding after `mcp_servers`:

```zig
    /// Whole-list replace for the top-level `sub_agents` array. When
    /// present, replaces the existing top-level sub-agents entirely.
    /// When absent, the existing list is preserved.
    sub_agents: ?json.Value = null,
```

- [ ] **Step 5.2: Add `sub_agents` to the `ConfigJson` parse target**

Modify `ConfigJson` (line 259-270) by adding after `mcp_servers`:

```zig
    sub_agents: ?json.Value = null,
```

- [ ] **Step 5.3: Add the whole-list replace logic for top-level `sub_agents`**

After the MCP-servers replace block (around line 168), insert:

```zig
    // Handle top-level sub_agents: whole-list replace when the input
    // provides the field (matches the UI's add/edit/delete workflow).
    if (input.value.sub_agents) |sa_value| {
        switch (sa_value) {
            .array => |arr| {
                var new_arr = json.Array.init(allocator);
                for (arr.items) |item| {
                    const copied = try deepCopyJsonValue(allocator, item);
                    try new_arr.append(copied);
                }
                config_json.sub_agents = json.Value{ .array = new_arr };
            },
            else => {
                // Non-array value: silently drop (e.g. user sent `null`).
                config_json.sub_agents = null;
            },
        }
    }
```

- [ ] **Step 5.4: Build to verify**

Run: `timeout 120 zig build 2>&1 | tail -n 20`
Expected: PASS.

- [ ] **Step 5.5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/nalar_config_put.zig
git commit -m "config-api: PUT accepts whole-list sub_agents (top-level)"
```

---

## Task 6: Frontend types and NalarSettings.vue UI

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:1200-1258` (extend types and add `SubAgent` type)
- Modify: `src/apps/desktop/src/components/NalarSettings.vue` (add `sub_agents` state, render new section + per-profile sub-agents)

- [ ] **Step 6.1: Add TypeScript types**

In `api/index.ts`, insert a new interface after the `McpServer` interface (around line 1220):

```ts
export interface SubAgent {
  name: string
  model: string
  base_url: string
  thinking: string
  temperature: string
  url_style: string
  api_key: string
  system_prompt: string
}
```

Then add `sub_agents?: SubAgent[]` to the `NalarProfile` interface (line 1201-1208):

```ts
export interface NalarProfile {
  model?: string
  base_url?: string
  thinking?: string
  temperature?: string
  url_style?: string
  api_key?: string
  sub_agents?: SubAgent[]
}
```

Then add `sub_agents?: SubAgent[]` to the `NalarConfig` interface (line 1222-1238):

```ts
export interface NalarConfig {
  api_endpoint?: string
  api_key?: string
  model?: string
  url_style?: string
  temperature?: number
  max_tokens?: string
  system_prompt?: string
  profiles?: Record<string, NalarProfile>
  active_profile?: string
  mcp_servers?: Record<string, { url: string; headers?: Record<string, string> }>
  sub_agents?: SubAgent[]
}
```

- [ ] **Step 6.2: Add state to `NalarSettings.vue`**

In `NalarSettings.vue` (top of `<script setup>`), add after the profiles state:

```ts
// Sub-agents state
const subAgents = ref<SubAgent[]>([])
const editingSubAgent = ref<SubAgent | null>(null)
const isAddingSubAgent = ref(false)

const emptySubAgent = (): SubAgent => ({
  name: '',
  model: '',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  system_prompt: ''
})
```

- [ ] **Step 6.3: Load sub_agents in `onMounted`**

In the existing `onMounted` (around line 124-159), after the `mcpServers.value = parseMcpServers(...)` line, add:

```ts
// Load sub-agents
if (data.sub_agents && Array.isArray(data.sub_agents)) {
  subAgents.value = data.sub_agents.map((sa: any) => ({
    name: sa.name ?? '',
    model: sa.model ?? '',
    base_url: sa.base_url ?? '',
    thinking: sa.thinking ?? 'auto',
    temperature: sa.temperature ?? 'auto',
    url_style: sa.url_style ?? 'openai',
    api_key: sa.api_key ?? '',
    system_prompt: sa.system_prompt ?? ''
  }))
}
```

Also load per-profile sub-agents inside the existing `for ([name, profile] of Object.entries(data.profiles))` loop. The current loop creates a `profilesList` entry — modify the `profilesList.push` call to include the nested field:

```ts
profilesList.push({
  name,
  model: parseJsonValue((profile as any).model),
  base_url: parseJsonValue((profile as any).base_url),
  thinking: parseJsonValue((profile as any).thinking),
  temperature: parseJsonValue((profile as any).temperature),
  url_style: parseJsonValue((profile as any).url_style) || 'openai',
  api_key: parseJsonValue((profile as any).api_key),
  sub_agents: ((profile as any).sub_agents ?? []).map((sa: any) => ({
    name: sa.name ?? '',
    model: sa.model ?? '',
    base_url: sa.base_url ?? '',
    thinking: sa.thinking ?? 'auto',
    temperature: sa.temperature ?? 'auto',
    url_style: sa.url_style ?? 'openai',
    api_key: sa.api_key ?? '',
    system_prompt: sa.system_prompt ?? ''
  }))
})
```

And update the `Profile` interface (line 47-55) to include `sub_agents: SubAgent[]`.

- [ ] **Step 6.4: Add save logic**

In `saveSettings` (around line 162-227), add the top-level sub_agents:

```ts
if (subAgents.value.length > 0) {
  settings.sub_agents = subAgents.value
}
```

Add per-profile sub_agents inside the existing `for (const profile of profiles.value)` loop:

```ts
for (const profile of profiles.value) {
  profileChanges.push({
    name: profile.name,
    action: 'update',
    model: profile.model,
    base_url: profile.base_url,
    thinking: profile.thinking,
    temperature: profile.temperature,
    url_style: profile.url_style,
    api_key: profile.api_key,
    sub_agents: profile.sub_agents ?? []
  })
}
```

- [ ] **Step 6.5: Add CRUD helpers (mirror the existing profile helpers)**

After the existing `confirmDeleteProfile` function (around line 330), add:

```ts
const startAddSubAgent = () => {
  editingSubAgent.value = emptySubAgent()
  isAddingSubAgent.value = true
}

const startEditSubAgent = (sa: SubAgent) => {
  editingSubAgent.value = { ...sa }
  isAddingSubAgent.value = false
}

const cancelEditSubAgent = () => {
  editingSubAgent.value = null
  isAddingSubAgent.value = false
}

const saveSubAgent = () => {
  if (!editingSubAgent.value) return
  const incoming = editingSubAgent.value
  if (!incoming.name.trim()) {
    emit('notification', 'Sub-agent requires a name', 'error')
    return
  }
  if (isAddingSubAgent.value) {
    if (subAgents.value.some(s => s.name === incoming.name)) {
      emit('notification', `Sub-agent "${incoming.name}" already exists`, 'error')
      return
    }
    subAgents.value.push({ ...incoming })
  } else {
    const index = subAgents.value.findIndex(s => s.name === incoming.name)
    if (index !== -1) {
      subAgents.value[index] = { ...incoming }
    }
  }
  editingSubAgent.value = null
  isAddingSubAgent.value = false
}

const deleteSubAgent = (name: string) => {
  subAgents.value = subAgents.value.filter(s => s.name !== name)
}
```

- [ ] **Step 6.6: Add the Sub-Agents section to the template**

In `NalarSettings.vue`, after the closing `</div>` of the Profiles section (around line 774, just before the MCP Servers section), add:

```vue
    <!-- Sub-Agents Section -->
    <div
      class="rounded-xl p-6"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
    >
      <div class="flex justify-between items-center mb-4">
        <div>
          <h2
            class="text-base font-semibold"
            style="color: var(--semantic-text);"
          >Sub-Agents</h2>
          <p
            class="text-xs mt-1"
            style="color: var(--semantic-text-dim);"
          >Named sub-agent LLM configurations used by <code>spawn_sub_agent</code>.</p>
        </div>
        <button
          @click="startAddSubAgent"
          class="px-4 py-2 rounded-lg text-sm font-medium transition-colors duration-200"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
        >
          + Add Sub-Agent
        </button>
      </div>

      <!-- Sub-Agent list -->
      <div class="space-y-3">
        <div
          v-for="sa in subAgents"
          :key="sa.name"
          class="p-4 rounded-lg border"
          style="background-color: var(--semantic-content-bg); border-color: var(--color-border);"
        >
          <div class="flex justify-between items-start">
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="font-medium" style="color: var(--semantic-text);">{{ sa.name }}</span>
              </div>
              <div
                class="text-sm mt-1 truncate"
                style="color: var(--semantic-text-muted);"
                :title="sa.model"
              >{{ sa.model }} - {{ sa.base_url }}</div>
            </div>
            <div class="flex gap-2 ml-3 shrink-0">
              <button
                @click="startEditSubAgent(sa)"
                class="px-3 py-1 text-xs rounded"
                style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
              >Edit</button>
              <button
                @click="deleteSubAgent(sa.name)"
                class="px-3 py-1 text-xs rounded"
                style="background-color: var(--semantic-card-bg); color: #ef4444; border: 1px solid var(--color-border);"
              >Delete</button>
            </div>
          </div>
        </div>

        <div
          v-if="subAgents.length === 0"
          class="text-center py-8"
          style="color: var(--semantic-text-muted);"
        >
          No sub-agents configured. Click "Add Sub-Agent" to create one.
        </div>
      </div>

      <!-- Sub-Agent Edit Modal -->
      <div
        v-if="editingSubAgent"
        class="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
        @click.self="cancelEditSubAgent"
      >
        <div
          class="rounded-xl p-6 w-full max-w-md max-h-[90vh] overflow-y-auto"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
        >
          <h3 class="text-lg font-semibold mb-4" style="color: var(--semantic-text);">
            {{ isAddingSubAgent ? 'Add Sub-Agent' : 'Edit Sub-Agent' }}
          </h3>

          <div class="space-y-4">
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Name</label>
              <input
                v-model="editingSubAgent.name"
                type="text"
                :disabled="!isAddingSubAgent"
                placeholder="SubAgent1"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Model</label>
              <input
                v-model="editingSubAgent.model"
                type="text"
                placeholder="MiniMax-M3"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Base URL</label>
              <input
                v-model="editingSubAgent.base_url"
                type="text"
                placeholder="https://api.minimax.io/v1"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Thinking</label>
              <select
                v-model="editingSubAgent.thinking"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              >
                <option value="auto">Auto</option>
                <option value="on">On</option>
                <option value="off">Off</option>
                <option value="false">False</option>
                <option value="true">True</option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Temperature</label>
              <select
                v-model="editingSubAgent.temperature"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              >
                <option value="auto">Auto</option>
                <option value="0">0 - Precise</option>
                <option value="0.5">0.5</option>
                <option value="1">1 - Balanced</option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">URL Style</label>
              <select
                v-model="editingSubAgent.url_style"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              >
                <option value="openai">OpenAI (e.g. /v1/chat/completions)</option>
                <option value="anthropic">Anthropic (e.g. /v1/messages)</option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">API Key</label>
              <input
                v-model="editingSubAgent.api_key"
                type="password"
                placeholder="sk-..."
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">System Prompt</label>
              <textarea
                v-model="editingSubAgent.system_prompt"
                placeholder="System prompt for this sub-agent..."
                rows="4"
                class="w-full px-4 py-2.5 rounded-lg border text-sm resize-none"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
          </div>

          <div class="flex gap-3 mt-6">
            <button
              @click="saveSubAgent"
              class="px-6 py-2.5 rounded-lg font-medium text-sm"
              style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
            >Save</button>
            <button
              @click="cancelEditSubAgent"
              class="px-6 py-2.5 rounded-lg font-medium text-sm"
              style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
            >Cancel</button>
          </div>
        </div>
      </div>
    </div>
```

- [ ] **Step 6.7: Run frontend type-check + tests**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 30`
Expected: PASS — `vue-tsc --build` clean and bundle succeeds.

Run: `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20`
Expected: PASS — all existing tests still green.

- [ ] **Step 6.8: Commit**

```bash
git add src/apps/desktop/src/api/index.ts src/apps/desktop/src/components/NalarSettings.vue
git commit -m "ui: render Sub-Agents section in NalarSettings (top-level + per-profile)"
```

---

## Task 7: End-to-end verification

- [ ] **Step 7.1: Run the full Zig test suite**

Run: `timeout 300 zig build test 2>&1 | tail -n 30`
Expected: PASS — no regressions; all new sub_agents tests green.

- [ ] **Step 7.2: Manual smoke test against `nalar-dev`**

1. Launch `zig build run:dev` in one terminal.
2. `curl -sS http://localhost:8081/api/config/nalar | jq .sub_agents` — should return `null` or `[]` on first run.
3. `curl -sS -X PUT -H 'Content-Type: application/json' -d '{"sub_agents":[{"name":"SubAgent1","model":"MiniMax-M3","base_url":"https://api.minimax.io/v1","thinking":"false","temperature":"auto","url_style":"openai","api_key":"","system_prompt":""}]}' http://localhost:8081/api/config/nalar` — should return 200.
4. `curl -sS http://localhost:8081/api/config/nalar | jq .sub_agents` — should now return the saved array.
5. Open the desktop app, navigate to Settings, verify the Sub-Agents section renders, add a sub-agent, save, and confirm the round-trip persisted to `config.json` (use `cat ~/.config/nalar/config.json`).

- [ ] **Step 7.3: Update `NALAR.md`**

Add a brief note in the "LLM Configuration" section describing the new `sub_agents` field (top-level + per-profile), what each sub-agent configures, and an example JSON snippet.

- [ ] **Step 7.4: Final commit**

```bash
git add NALAR.md
git commit -m "docs: document sub_agents field in NALAR.md"
```

---

## Pitfalls

- **Don't accidentally reallocate `sub_agents` during `errdefer`.** The `errdefer` block in `init` runs after the struct literal, so by the time it runs the slice may already point to a partially-constructed value. `freeSubAgentsList` is null-safe (`if (slice.len > 0)`) so it tolerates the `&.{}` default.
- **`config_json.sub_agents` is a `?std.json.Value` (an array of raw `json.Value`).** We deep-copy it to avoid use-after-free when `parsed.deinit()` fires at the end of `init` (same pattern as the MCP-servers parse).
- **The `addProfile` signature changed** (it still takes `?ProfileJson` — the new `sub_agents` field on `ProfileJson` is the only addition; no call site needs updating). Existing callers in `clone` that build a `ProfileJson` literal need to include `sub_agents = ...` (see Task 3.5).
- **The PUT handler stores sub_agents as `json.Value` directly** (not via the typed map) because the frontend may send fields we haven't validated yet. The typed parse happens on the next `LlmConfig.init` reload.
- **Zig 0.15 slice header semantics** — `[]SubAgentConfig` returned from `toOwnedSlice` MUST be freed with `allocator.free(slice)` AFTER every string inside has been freed. The `freeSubAgentsList` helper does both in the right order.
- **`spawn_sub_agent` is NOT in scope for this plan.** The runtime tool (`src/modules/agent/tools/spawn_sub_agent.zig`) is unchanged — it still parses the `sub_agents` JSON from its `json_input` argument. A follow-up plan will wire the `LlmConfig.sub_agents` lookups into the spawn handler.
- **JSON.stringify on `sub_agents`** in the GET handler preserves field order as Zig's `Stringify` enumerates struct fields. The order on disk will be: `name, model, base_url, thinking, temperature, url_style, api_key, system_prompt` — matches the user's example.

## Verification

End-to-end test that the round-trip works: write a config with `sub_agents` via PUT, then read it back via GET, and assert every field matches. The existing `mcp_servers` round-trip pattern in the integration smoke test is the model.

For unit verification:
- `zig build test:config` runs `src/modules/config/config_test.zig` — all sub_agents tests should be green.
- `bun run build` (NOT just `vitest run`) is the authoritative type-check.
- The full `zig build test` is the no-regression check.
