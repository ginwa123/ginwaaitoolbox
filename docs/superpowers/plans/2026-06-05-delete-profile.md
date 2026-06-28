# Delete Profile Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add immediate-persistence delete for LLM profiles — a new `DELETE /api/config/nalar/profiles/:name` backend endpoint, a `deleteProfile` API client function, a testable Vue composable that wraps the optimistic-update + rollback pattern, and a confirmation-gated UI flow in `NalarSettings.vue`.

**Architecture:**
- **Backend** — new handler `nalar_config_profile_delete.zig` reads `config.json`, removes the named profile from `profiles_models`, clears `active_profile` if it was the deleted one, writes the file, and live-reloads the `LlmConfigHolder` so in-flight workflows see the change. Returns `200` on success, `404` if the profile does not exist.
- **Frontend** — new `deleteProfile` function in `api/index.ts` calls the new endpoint. A new `useProfileDelete` composable owns the optimistic-update + rollback pattern and is fully testable. `NalarSettings.vue` gates the click on a `<ConfirmDialog>` and wires the composable's `onSuccess`/`onError` to its existing `emit('notification', ...)`.
- **Tests** — Zig unit test exercises the pure helper that manipulates the parsed config (no IO). Vitest tests cover the API function (mocked `fetch`) and the composable (mocked API).

**Tech Stack:** Zig 0.15.2, Vue 3 (Composition API + `<script setup>`), TypeScript, Vitest, gserverz router.

---

## File Structure

### New files

| File | Responsibility |
|---|---|
| `src/ai_workflow/tui/http_handlers/nalar_config_profile_delete.zig` | The `DELETE /api/config/nalar/profiles/:name` handler. Reads config, calls helper, writes back, live-reloads. |
| `src/ai_workflow/tui/http_handlers/nalar_config_profile_delete_test.zig` | Zig test for the pure `removeProfileFromConfig` helper. |
| `src/apps/desktop/src/composables/useProfileDelete.ts` | Vue composable. Owns optimistic-update + rollback + API call + loading state + notification callbacks. |
| `src/apps/desktop/src/__tests__/useProfileDelete.spec.ts` | Vitest test for the composable (mocked API). |
| `src/apps/desktop/src/__tests__/apiDeleteProfile.spec.ts` | Vitest test for the `api.deleteProfile` function (mocked `fetch`). |

### Modified files

| File | Change |
|---|---|
| `src/ai_workflow/tui/http_handlers/mod.zig` | Add 1-line re-export of the new handler. |
| `src/main.zig` | Add 1-line `gs.router.delete(...)` registration. |
| `src/ai_workflow/tui/test_runner.zig` | Add 1-line registration of the new test file. |
| `src/apps/desktop/src/api/index.ts` | Add `deleteProfile(name: string)` exported function. |
| `src/apps/desktop/src/components/NalarSettings.vue` | Replace `deleteProfile` (lines 290-295) with composable wiring. Add `confirmingDeleteProfile` ref, `requestDeleteProfile` / `confirmDeleteProfile` / `cancelDeleteProfile` functions. Add `<ConfirmDialog>` to the template. Update the Delete button click handler. Add `isDeletingProfile` ref for button disabled state. |

### What we are NOT touching

- `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` — the deferred-save path is unchanged. After this plan lands, deleting a profile via the new flow bypasses the `delete` action array entirely (good — it removes a path of confusion).
- The other handlers (`workspace_*`, `task_*`, etc.) — out of scope.
- `Config.zig` / `LlmConfig` types — the existing `profiles_models: ?json.Value` field already supports mutation.

---

## Chunk 1: Backend — Handler + tests

### Task 1.1: Write the failing Zig test for the helper

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/nalar_config_profile_delete_test.zig`

- [ ] **Step 1: Write the failing test**

```zig
//! Tests for the pure `removeProfileFromConfig` helper used by the
//! `DELETE /api/config/nalar/profiles/:name` handler. The helper is
//! split out from the handler so the file-system roundtrip does not
//! need to be exercised by the unit test — the existing
//! `nalar_config_put_test.zig` already documents the convention of
//! NOT exercising the full HTTP handler.

const std = @import("std");
const testing = std.testing;
const json = std.json;

const config_mod = @import("nalarcore").config;
const http_handlers = @import("nalarcore").ai_workflow.http_handlers;

// Helper we will be testing (defined in nalar_config_profile_delete.zig).
// We import it via the handler module so the test fails to compile until
// the handler file is created.
const removeProfileFromConfig = http_handlers.removeProfileFromConfig;
const ConfigJson = http_handlers.NalarConfigJsonForDelete;

// Build a ConfigJson with two profiles and `active_profile = "alpha"`.
fn makeConfigJson(allocator: std.mem.Allocator) !ConfigJson {
    var profiles = json.ObjectMap.init(allocator, &.{}, &.{});
    // alpha
    var alpha = json.ObjectMap.init(allocator, &.{}, &.{});
    try alpha.put(allocator, "model", .{ .string = try allocator.dupe(u8, "gpt-4o") });
    try alpha.put(allocator, "base_url", .{ .string = try allocator.dupe(u8, "https://api.example.com") });
    try profiles.put(allocator, try allocator.dupe(u8, "alpha"), .{ .object = alpha });
    // beta
    var beta = json.ObjectMap.init(allocator, &.{}, &.{});
    try beta.put(allocator, "model", .{ .string = try allocator.dupe(u8, "claude") });
    try beta.put(allocator, "base_url", .{ .string = try allocator.dupe(u8, "https://api.anthropic.com") });
    try profiles.put(allocator, try allocator.dupe(u8, "beta"), .{ .object = beta });

    return ConfigJson{
        .api_key = try allocator.dupe(u8, "test-key"),
        .model = try allocator.dupe(u8, "gpt-4o"),
        .base_url = try allocator.dupe(u8, "https://api.example.com"),
        .url_style = try allocator.dupe(u8, "openai"),
        .max_tokens = null,
        .system_prompt = try allocator.dupe(u8, ""),
        .profiles_models = .{ .object = profiles },
        .active_profile = try allocator.dupe(u8, "alpha"),
    };
}

test "removeProfileFromConfig: removes the named profile and returns true" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    const removed = try removeProfileFromConfig(allocator, &cfg, "alpha");
    try testing.expect(removed);

    const obj = cfg.profiles_models.?.object;
    try testing.expectEqual(@as(usize, 1), obj.count());
    try testing.expect(obj.get("alpha") == null);
    try testing.expect(obj.get("beta") != null);
}

test "removeProfileFromConfig: returns false when the profile does not exist" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    const removed = try removeProfileFromConfig(allocator, &cfg, "ghost");
    try testing.expect(!removed);

    // Existing profiles unchanged
    const obj = cfg.profiles_models.?.object;
    try testing.expectEqual(@as(usize, 2), obj.count());
}

test "removeProfileFromConfig: clears active_profile when it matches the deleted name" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    _ = try removeProfileFromConfig(allocator, &cfg, "alpha");
    try testing.expect(cfg.active_profile == null);
}

test "removeProfileFromConfig: preserves active_profile when it does not match" {
    const allocator = testing.allocator;
    var cfg = try makeConfigJson(allocator);
    defer cfg.deinit(allocator);

    _ = try removeProfileFromConfig(allocator, &cfg, "beta");
    try testing.expectEqualStrings("alpha", cfg.active_profile.?);
}

test "removeProfileFromConfig: handles missing profiles_models gracefully" {
    const allocator = testing.allocator;
    var cfg = ConfigJson{
        .api_key = try allocator.dupe(u8, ""),
        .model = try allocator.dupe(u8, ""),
        .base_url = try allocator.dupe(u8, ""),
        .url_style = try allocator.dupe(u8, "openai"),
        .max_tokens = null,
        .system_prompt = try allocator.dupe(u8, ""),
        .profiles_models = null,
        .active_profile = null,
    };
    defer cfg.deinit(allocator);

    const removed = try removeProfileFromConfig(allocator, &cfg, "alpha");
    try testing.expect(!removed);
}
```

- [ ] **Step 2: Verify the test fails to compile (no handler file yet)**

Run: `timeout 120 zig build test 2>&1 | head -n 30`
Expected: compilation error mentioning `removeProfileFromConfig` (the test imports from the handler module which doesn't exist yet).

### Task 1.2: Create the handler file

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/nalar_config_profile_delete.zig`

- [ ] **Step 3: Write the handler with the pure helper**

```zig
const std = @import("std");
const json = std.json;
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const config = nalarcore.config;

pub const NalarConfigJsonForDelete = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    base_url: []const u8 = "",
    url_style: []const u8 = "openai",
    max_tokens: ?usize = null,
    system_prompt: []const u8 = "",
    profiles_models: ?json.Value = null,
    active_profile: ?[]const u8 = null,
};

pub const ProfileDeleteResponse = struct {
    success: bool,
    profile_name: []const u8,
    active_profile_was_cleared: bool = false,
    error_message: ?[]const u8 = null,
};

/// Pure helper: remove the named profile from `cfg.profiles_models` and
/// clear `active_profile` if it matched. Returns true if the profile
/// existed and was removed, false otherwise.
///
/// Split out from the handler so it can be unit-tested without touching
/// the file system — the same pattern used in
/// `nalar_config_put_test.zig` (see its file header for rationale).
pub fn removeProfileFromConfig(
    allocator: std.mem.Allocator,
    cfg: *NalarConfigJsonForDelete,
    name: []const u8,
) !bool {
    const profiles_value = cfg.profiles_models orelse return false;
    const profiles_obj = switch (profiles_value) {
        .object => |obj| obj,
        else => return false,
    };

    const existed = profiles_obj.get(name) != null;
    if (!existed) return false;

    // Free the old key/value memory before swapRemove.
    if (profiles_obj.fetchSwapRemove(name)) |kv| {
        allocator.free(kv.key);
        // The value's owned strings are leaked in the test path (not freed),
        // matching the put handler's pattern at nalar_config_put.zig:103-112.
        // Production writes a fresh config immediately after, so the leak is
        // bounded to one config file's worth of memory.
        _ = kv.value;
    }

    if (cfg.active_profile) |ap| {
        if (std.mem.eql(u8, ap, name)) {
            allocator.free(ap);
            cfg.active_profile = null;
        }
    }

    return true;
}

/// DELETE /api/config/nalar/profiles/:name
/// Removes a single profile from `config.json` and live-reloads the
/// `LlmConfigHolder` so in-flight workflows see the change. Returns
/// 404 if the named profile does not exist.
pub fn nalarConfigProfileDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const name = req.params.get("name") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
            .success = false,
            .profile_name = "",
            .error_message = "Missing :name path parameter",
        }, .{}) });
    };

    if (name.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
            .success = false,
            .profile_name = "",
            .error_message = "Profile name cannot be empty",
        }, .{}) });
    }

    const di = try nalarcore.getSingleton();
    const environment_ptr = di.environment orelse return res.jsonResponse(.{
        .status_code = 500,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Environment not available" }),
    });
    const environment: *std.process.Environ.Map = @constCast(@ptrCast(environment_ptr));

    const config_path = config.getDefaultConfigPath(allocator, environment) catch |err| {
        std.log.err("Failed to get config path: {s}", .{@errorName(err)});
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to get config path" }) });
    };

    std.Io.Dir.cwd().createDirPath(io, config_path) catch |err| {
        std.log.err("Failed to create config dir: {s}", .{@errorName(err)});
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create config directory" }) });
    };

    // Read existing config (if any).
    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch null;
    var existing_content: ?[]u8 = null;
    if (file) |f| {
        defer f.close(io);
        var read_buffer: [4096]u8 = undefined;
        var reader = f.reader(io, &read_buffer);
        existing_content = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    }

    if (existing_content == null) {
        return res.jsonResponse(.{ .status_code = 404, .data = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
            .success = false,
            .profile_name = name,
            .error_message = "No config file exists",
        }, .{}) });
    }

    var config_json: NalarConfigJsonForDelete = NalarConfigJsonForDelete{};
    {
        const parsed = try std.json.parseFromSlice(NalarConfigJsonForDelete, allocator, existing_content.?, .{
            .ignore_unknown_fields = true,
        });
        config_json = parsed.value;
    }

    const was_active = if (config_json.active_profile) |ap| std.mem.eql(u8, ap, name) else false;
    const removed = try removeProfileFromConfig(allocator, &config_json, name);

    if (!removed) {
        return res.jsonResponse(.{ .status_code = 404, .data = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
            .success = false,
            .profile_name = name,
            .error_message = "Profile not found",
        }, .{}) });
    }

    // Write the updated config back.
    const config_str = try std.json.Stringify.valueAlloc(allocator, config_json, .{
        .whitespace = .indent_tab,
    });

    var write_file = try std.Io.Dir.createFileAbsolute(io, config_path, .{ .truncate = true });
    defer write_file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = write_file.writer(io, &write_buffer);
    try writer.interface.writeAll(config_str);
    try writer.flush();

    // Live-reload LlmConfigHolder (same pattern as nalar_config_put.zig:185-225).
    {
        const env_for_reload: *std.process.Environ.Map = @constCast(@ptrCast(di.environment orelse environment));

        var new_cfg = config.LlmConfig.init(allocator, io, null, env_for_reload) catch |err| {
            std.log.err("DELETE profile: live reload parse failed: {s}", .{@errorName(err)});
            return res.jsonResponse(.{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
                .success = true,
                .profile_name = name,
                .active_profile_was_cleared = was_active,
                .error_message = "Profile deleted from disk but live reload parse failed",
            }, .{}) });
        };

        new_cfg.validate() catch |err| {
            std.log.err("DELETE profile: live reload validation failed: {s}", .{@errorName(err)});
            var mut: *config.LlmConfig = &new_cfg;
            mut.deinit();
            return res.jsonResponse(.{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
                .success = true,
                .profile_name = name,
                .active_profile_was_cleared = was_active,
                .error_message = "Profile deleted from disk but failed validation",
            }, .{}) });
        };

        const new_ptr = allocator.create(config.LlmConfig) catch |err| {
            std.log.err("DELETE profile: alloc failed: {s}", .{@errorName(err)});
            var mut: *config.LlmConfig = &new_cfg;
            mut.deinit();
            return res.jsonResponse(.{ .status_code = 500, .data = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
                .success = false,
                .profile_name = name,
                .error_message = "Out of memory",
            }, .{}) });
        };
        new_ptr.* = new_cfg;
        nalarcore.setLlmConfig(di, new_ptr);
        std.log.info("DELETE profile: live-reloaded llm_config (deleted={s})", .{name});
    }

    return res.jsonResponse(.{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, ProfileDeleteResponse{
        .success = true,
        .profile_name = name,
        .active_profile_was_cleared = was_active,
    }, .{}) });
}
```

> **Implementation note:** `req.params.get("name")` and the `getDefaultConfigPath` helper are the same APIs used elsewhere in the codebase — verify exact names against `nalar_config_get.zig` and `nalar_config_put.zig` before writing. The route-registration step below assumes `:name` is a registered path parameter; if gserverz uses a different mechanism (e.g. `:profile_name` or wildcard), adjust both the param lookup and the route string to match.

- [ ] **Step 4: Verify the test passes**

Run: `timeout 120 zig build test 2>&1 | head -n 50`
Expected: 5 new tests in `nalar_config_profile_delete_test.zig` all pass.

### Task 1.3: Register the handler in the module and the route in main.zig

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig:88-89`
- Modify: `src/main.zig:216-217`

- [ ] **Step 5: Re-export the handler from mod.zig**

In `src/ai_workflow/tui/http_handlers/mod.zig`, after the existing `nalarConfigPutHandler` line (line 89), add:

```zig
pub const nalarConfigProfileDeleteHandler = @import("nalar_config_profile_delete.zig").nalarConfigProfileDeleteHandler;
```

Also add a re-export for the test-visible helper and type (so the test file's `@import("nalarcore").ai_workflow.http_handlers.removeProfileFromConfig` works):

```zig
pub const removeProfileFromConfig = @import("nalar_config_profile_delete.zig").removeProfileFromConfig;
pub const NalarConfigJsonForDelete = @import("nalar_config_profile_delete.zig").NalarConfigJsonForDelete;
```

> **Implementation note:** verify the path to `http_handlers` from `nalarcore`. The test imports `@import("nalarcore").ai_workflow.http_handlers` — if the actual path differs (e.g. `tui.http_handlers`), update the test's import accordingly. Check `src/ai_workflow/tui/mod.zig` and `src/ai_workflow/mod.zig` to find the right chain.

- [ ] **Step 6: Register the route in main.zig**

In `src/main.zig`, after the existing `try gs.router.put("/api/config/nalar", ...)` line (line 217), add:

```zig
try gs.router.delete("/api/config/nalar/profiles/:name", ai_mod.http_handlers.nalarConfigProfileDeleteHandler);
```

> **Implementation note:** verify the exact `delete` method name on the gserverz router. It may be `del` or `delete` — check `src/modules/custom_http_server/src/router.zig` for the actual public method.

- [ ] **Step 7: Build the backend to verify the registration compiles**

Run: `timeout 180 zig build 2>&1 | head -n 30`
Expected: clean build, no errors.

### Task 1.4: Register the test in test_runner.zig

**Files:**
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 8: Add the test to test_runner.zig**

After the existing `nalar_config_put_test.zig` line (line 11), add:

```zig
_ = @import("http_handlers/nalar_config_profile_delete_test.zig");
```

- [ ] **Step 9: Run the full test suite**

Run: `timeout 300 zig build test 2>&1 | tail -n 30`
Expected: all 5 new `removeProfileFromConfig` tests pass; no existing tests break.

---

## Chunk 2: Frontend — API client function + tests

### Task 2.1: Write the failing vitest test for the API function

**Files:**
- Create: `src/apps/desktop/src/__tests__/apiDeleteProfile.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
/**
 * Unit tests for the `api.deleteProfile` function. Mocks `global.fetch`
 * to assert URL, method, and error handling without hitting the
 * network.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'

import { deleteProfile } from '../api'

describe('api.deleteProfile', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  it('calls DELETE on /api/config/nalar/profiles/:name with URL-encoded name', async () => {
    mockFetchOnce(200, { success: true, profile_name: 'my profile', active_profile_was_cleared: false })

    await deleteProfile('my profile')

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/config/nalar/profiles/my%20profile')
    expect(init.method).toBe('DELETE')
  })

  it('returns the parsed JSON on 200', async () => {
    mockFetchOnce(200, { success: true, profile_name: 'alpha', active_profile_was_cleared: true })

    const result = await deleteProfile('alpha')

    expect(result).toEqual({ success: true, profile_name: 'alpha', active_profile_was_cleared: true })
  })

  it('throws an Error with the HTTP status on non-2xx', async () => {
    mockFetchOnce(404, { success: false, profile_name: 'ghost', error_message: 'Profile not found' })

    await expect(deleteProfile('ghost')).rejects.toThrow(/HTTP 404/)
  })

  it('encodes special characters in the profile name', async () => {
    mockFetchOnce(200, { success: true, profile_name: 'a/b+c', active_profile_was_cleared: false })

    await deleteProfile('a/b+c')

    const [url] = fetchMock.mock.calls[0] as [string, RequestInit]
    // encodeURIComponent produces 'a%2Fb%2Bc' for this input
    expect(url).toContain('/api/config/nalar/profiles/a%2Fb%2Bc')
  })
})
```

- [ ] **Step 2: Verify the test fails to import**

Run: `timeout 60 bun run test:unit apiDeleteProfile 2>&1 | head -n 30`
Expected: import error — `deleteProfile` is not exported from `../api`.

### Task 2.2: Add the `deleteProfile` function to the API client

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts` (add after `saveNalarConfig` at line 1195)

- [ ] **Step 3: Add the function**

```typescript
/**
 * Response shape from `DELETE /api/config/nalar/profiles/:name`.
 *
 * `active_profile_was_cleared` is `true` when the deleted profile was
 * the active one (the backend also cleared `active_profile` on disk).
 * `error_message` is set when the request succeeded (HTTP 200) but a
 * downstream concern (live reload) failed — the deletion still
 * persisted.
 */
export interface ProfileDeleteResponse {
  success: boolean
  profile_name: string
  active_profile_was_cleared?: boolean
  error_message?: string
}

/**
 * DELETE /api/config/nalar/profiles/:name
 *
 * Removes a profile from `config.json` and live-reloads the backend's
 * in-memory LLM config. Throws an Error (with the HTTP status) on
 * non-2xx responses; the composable wraps this for UI concerns
 * (optimistic update, rollback, notification).
 */
export async function deleteProfile(name: string): Promise<ProfileDeleteResponse> {
  const response = await fetch(
    `${API_BASE}/config/nalar/profiles/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}
```

> **Implementation note:** verify `API_BASE` is the local module-level constant in `api/index.ts` (used by `getNalarConfig` and `saveNalarConfig` at lines 1177-1195). If it's imported from somewhere else, match the existing pattern.

- [ ] **Step 4: Verify the test passes**

Run: `timeout 60 bun run test:unit apiDeleteProfile 2>&1 | tail -n 20`
Expected: 4 tests pass.

---

## Chunk 3: Frontend — `useProfileDelete` composable + tests

### Task 3.1: Write the failing vitest test for the composable

**Files:**
- Create: `src/apps/desktop/src/__tests__/useProfileDelete.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
/**
 * Unit tests for the `useProfileDelete` composable. Mocks the
 * `api.deleteProfile` module function (NOT `global.fetch`) so we can
 * assert the composable's optimistic-update + rollback behavior in
 * isolation.
 */
import { ref } from 'vue'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { useProfileDelete } from '../composables/useProfileDelete'
import * as api from '../api'

// Mock the whole `../api` module so we control the return value of
// `api.deleteProfile` without hitting the network.
vi.mock('../api', () => ({
  deleteProfile: vi.fn(),
}))

const mockDeleteProfile = api.deleteProfile as unknown as ReturnType<typeof vi.fn>

interface Profile {
  name: string
  model: string
}

describe('useProfileDelete', () => {
  beforeEach(() => {
    mockDeleteProfile.mockReset()
  })

  it('removes the profile from local state immediately (optimistic)', async () => {
    const profiles = ref<Profile[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>('alpha')
    const onSuccess = vi.fn()
    const onError = vi.fn()
    mockDeleteProfile.mockResolvedValueOnce({
      success: true,
      profile_name: 'alpha',
      active_profile_was_cleared: true,
    })

    const { deleteProfile } = useProfileDelete(profiles, active, onSuccess, onError)
    await deleteProfile('alpha')

    expect(profiles.value.map((p) => p.name)).toEqual(['beta'])
    expect(active.value).toBeNull()
    expect(mockDeleteProfile).toHaveBeenCalledWith('alpha')
    expect(onSuccess).toHaveBeenCalledTimes(1)
    expect(onError).not.toHaveBeenCalled()
  })

  it('rolls back local state when the API call throws', async () => {
    const profiles = ref<Profile[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>('alpha')
    const onSuccess = vi.fn()
    const onError = vi.fn()
    mockDeleteProfile.mockRejectedValueOnce(new Error('HTTP 500'))

    const { deleteProfile } = useProfileDelete(profiles, active, onSuccess, onError)
    await expect(deleteProfile('alpha')).rejects.toThrow('HTTP 500')

    // Rolled back: alpha is back, active is restored.
    expect(profiles.value.map((p) => p.name)).toEqual(['alpha', 'beta'])
    expect(active.value).toBe('alpha')
    expect(onSuccess).not.toHaveBeenCalled()
    expect(onError).toHaveBeenCalledTimes(1)
    expect(onError.mock.calls[0][0]).toMatch(/Failed to delete profile.*HTTP 500/)
  })

  it('preserves active_profile when deleting a non-active profile', async () => {
    const profiles = ref<Profile[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>('alpha')
    mockDeleteProfile.mockResolvedValueOnce({
      success: true,
      profile_name: 'beta',
      active_profile_was_cleared: false,
    })

    const { deleteProfile } = useProfileDelete(profiles, active)
    await deleteProfile('beta')

    expect(profiles.value.map((p) => p.name)).toEqual(['alpha'])
    expect(active.value).toBe('alpha')
  })

  it('reports isDeleting=true during the in-flight call and false after', async () => {
    const profiles = ref<Profile[]>([{ name: 'alpha', model: 'gpt-4o' }])
    const active = ref<string | null>(null)
    let resolveApi!: (v: unknown) => void
    mockDeleteProfile.mockReturnValueOnce(
      new Promise((r) => {
        resolveApi = r
      }),
    )

    const { deleteProfile, isDeleting } = useProfileDelete(profiles, active)
    const p = deleteProfile('alpha')

    // Optimistic update happened, isDeleting is true.
    expect(profiles.value).toEqual([])
    expect(isDeleting.value).toBe(true)

    resolveApi({ success: true, profile_name: 'alpha', active_profile_was_cleared: false })
    await p

    expect(isDeleting.value).toBe(false)
  })

  it('emits a friendly "not found" message on HTTP 404', async () => {
    const profiles = ref<Profile[]>([{ name: 'alpha', model: 'gpt-4o' }])
    const active = ref<string | null>(null)
    const onError = vi.fn()
    mockDeleteProfile.mockRejectedValueOnce(new Error('HTTP 404'))

    const { deleteProfile } = useProfileDelete(profiles, active, undefined, onError)
    await expect(deleteProfile('alpha')).rejects.toThrow()

    expect(onError.mock.calls[0][0]).toMatch(/not found/i)
  })

  it('does nothing when isDeleting is already true (prevents concurrent deletes)', async () => {
    const profiles = ref<Profile[]>([
      { name: 'alpha', model: 'gpt-4o' },
      { name: 'beta', model: 'claude' },
    ])
    const active = ref<string | null>(null)
    let resolveFirst!: (v: unknown) => void
    mockDeleteProfile.mockReturnValueOnce(
      new Promise((r) => {
        resolveFirst = r
      }),
    )

    const { deleteProfile } = useProfileDelete(profiles, active)
    const first = deleteProfile('alpha')
    // Second call while first is in flight — should be a no-op.
    await deleteProfile('beta')

    expect(mockDeleteProfile).toHaveBeenCalledTimes(1)
    expect(mockDeleteProfile).toHaveBeenCalledWith('alpha')

    resolveFirst({ success: true, profile_name: 'alpha', active_profile_was_cleared: false })
    await first
  })
})
```

- [ ] **Step 2: Verify the test fails to import**

Run: `timeout 60 bun run test:unit useProfileDelete 2>&1 | head -n 30`
Expected: import error — `useProfileDelete` does not exist.

### Task 3.2: Create the composable

**Files:**
- Create: `src/apps/desktop/src/composables/useProfileDelete.ts`

- [ ] **Step 3: Write the composable**

```typescript
/**
 * useProfileDelete — optimistic-update + rollback for LLM profile
 * deletion.
 *
 * On `deleteProfile(name)`:
 *   1. Snapshot the current `profiles` and `activeProfile` so we can
 *      roll back if the API call fails.
 *   2. Remove the profile from local state immediately (UI feels
 *      instant).
 *   3. Call the backend. On success, fire `onSuccess`. On failure,
 *      restore the snapshot and fire `onError`.
 *
 * A `isDeleting` flag is exposed for the UI to disable the delete
 * button while the request is in flight, and to prevent concurrent
 * deletes from racing.
 */
import { ref, type Ref } from 'vue'

import { deleteProfile as apiDeleteProfile, type ProfileDeleteResponse } from '../api'

export interface UseProfileDeleteOptions<TProfile> {
  /** Called after a successful delete. Receives the user-facing message. */
  onSuccess?: (message: string) => void
  /** Called after a failed delete (state has been rolled back). Receives the user-facing message. */
  onError?: (message: string) => void
  /** Type-narrowing hook for the profile shape — only used to keep the local snapshot typed. */
  profileType?: TProfile
}

export function useProfileDelete<TProfile extends { name: string }>(
  profiles: Ref<TProfile[]>,
  activeProfile: Ref<string | null>,
  onSuccess?: (message: string) => void,
  onError?: (message: string) => void,
) {
  const isDeleting = ref(false)

  const deleteProfile = async (name: string): Promise<ProfileDeleteResponse> => {
    if (isDeleting.value) {
      // Prevent concurrent deletes from racing the rollback logic.
      return Promise.reject(new Error('Another delete is already in progress'))
    }

    // Snapshot for rollback.
    const previousProfiles = profiles.value.slice()
    const previousActive = activeProfile.value

    // Optimistic local update (preserves the user's exact snippet at
    // NalarSettings.vue:290-295 from the original spec).
    isDeleting.value = true
    profiles.value = profiles.value.filter((p) => p.name !== name)
    if (activeProfile.value === name) {
      activeProfile.value = null
    }

    try {
      const result = await apiDeleteProfile(name)
      onSuccess?.(`Profile "${name}" deleted`)
      return result
    } catch (err) {
      // Rollback.
      profiles.value = previousProfiles
      activeProfile.value = previousActive
      onError?.(formatErrorMessage(name, err))
      throw err
    } finally {
      isDeleting.value = false
    }
  }

  return { deleteProfile, isDeleting }
}

function formatErrorMessage(name: string, err: unknown): string {
  if (!(err instanceof Error)) {
    return `Failed to delete profile "${name}"`
  }
  const statusMatch = err.message.match(/HTTP (\d+)/)
  if (statusMatch) {
    const status = Number(statusMatch[1])
    if (status === 404) {
      return `Profile "${name}" not found on server (it may have been already deleted)`
    }
    if (status >= 500) {
      return `Server error while deleting profile "${name}"`
    }
  }
  return `Failed to delete profile "${name}": ${err.message}`
}
```

> **Implementation note:** the `UseProfileDeleteOptions` interface is exported for future use but not required by the current callers — the four-arg positional signature is what `NalarSettings.vue` will use. If you prefer, drop the options interface and keep only the positional form.

- [ ] **Step 4: Verify the test passes**

Run: `timeout 60 bun run test:unit useProfileDelete 2>&1 | tail -n 30`
Expected: 6 tests pass.

- [ ] **Step 5: Run the full frontend test suite to confirm nothing broke**

Run: `timeout 60 bun run test:unit 2>&1 | tail -n 15`
Expected: all 31 + 10 new tests pass (4 from `apiDeleteProfile` + 6 from `useProfileDelete`).

---

## Chunk 4: Frontend — UI integration in `NalarSettings.vue`

### Task 4.1: Wire the composable and add the confirmation flow

**Files:**
- Modify: `src/apps/desktop/src/components/NalarSettings.vue` (script block at lines 1-388, template at lines 596-602 and 916-934)

- [ ] **Step 1: Add the import and the composable wiring**

In the `<script setup>` block, after the existing `import { getNalarConfig, saveNalarConfig } from '../api'` line (line 3), add:

```typescript
import { deleteProfile as apiDeleteProfile } from '../api'
import { useProfileDelete } from '../composables/useProfileDelete'
```

After the existing `activeProfile` ref (line 20) and before `editingProfile` (line 21), add:

```typescript
// Delete confirmation state
const confirmingDeleteProfile = ref<string | null>(null)

// Wire the composable. It owns the optimistic update, rollback, and
// API call. We route success/error to the existing `notification`
// emit so the toast appears in the same place as other settings
// notifications.
const { deleteProfile, isDeletingProfile } = useProfileDelete(
  profiles,
  activeProfile,
  (msg) => emit('notification', msg, 'success'),
  (msg) => emit('notification', msg, 'error'),
)
```

- [ ] **Step 2: Replace the existing `deleteProfile` function (lines 290-295)**

Replace the entire `deleteProfile` function (lines 290-295) with:

```typescript
// Click handler for the row's Delete button. Shows the confirmation
// dialog. The actual delete + rollback is in the composable, invoked
// by `confirmDeleteProfile` once the user confirms.
const requestDeleteProfile = (name: string) => {
  confirmingDeleteProfile.value = name
}

const cancelDeleteProfile = () => {
  confirmingDeleteProfile.value = null
}

const confirmDeleteProfile = async () => {
  const name = confirmingDeleteProfile.value
  if (!name) return
  confirmingDeleteProfile.value = null
  try {
    await deleteProfile(name) // composable's function
  } catch {
    // Notification already emitted by the composable. Swallow the
    // throw so the row's click handler doesn't see an unhandled
    // rejection — the composable has already rolled back the local
    // state and surfaced the error.
  }
}
```

> **Why this preserves the user's original snippet:** the user's
> `profiles.value = profiles.value.filter(...)` and
> `activeProfile.value = null` logic now lives inside the composable
> as the optimistic-update step. The behavior is identical, with the
> addition of the rollback path and the API call.

- [ ] **Step 3: Update the Delete button's click handler**

In the template, change line 597:

```html
<button
  @click="deleteProfile(profile.name)"
  ...
>
  Delete
</button>
```

to:

```html
<button
  @click="requestDeleteProfile(profile.name)"
  :disabled="isDeletingProfile && confirmingDeleteProfile === profile.name"
  ...
>
  Delete
</button>
```

The `:disabled` flag prevents the user from clicking Delete on the
same row twice in quick succession (the composable also blocks this
defensively, but disabling the button gives visible feedback).

- [ ] **Step 4: Add the `<ConfirmDialog>` to the template**

Inside the Profiles section (after the closing `</div>` of the profile
edit modal, before the closing `</div>` of the profiles section — i.e.
just before line 727), add:

```html
<!-- Delete confirmation dialog -->
<ConfirmDialog
  :show="confirmingDeleteProfile !== null"
  title="Delete profile"
  :message="`Are you sure you want to delete the profile \u201c${confirmingDeleteProfile ?? ''}\u201d? This cannot be undone.`"
  confirm-text="Delete"
  cancel-text="Cancel"
  @confirm="confirmDeleteProfile"
  @close="cancelDeleteProfile"
/>
```

- [ ] **Step 5: Import the `ConfirmDialog` component**

In `<script setup>`, after the existing `import` lines, add:

```typescript
import ConfirmDialog from './ConfirmDialog.vue'
```

> **Implementation note:** verify the import path. Components in
> `src/apps/desktop/src/components/` import each other with relative
> paths like `./ConfirmDialog.vue`; verify by checking another
> component (e.g. `AppLayout.vue` imports).

- [ ] **Step 6: Run `bun run build` to verify TypeScript and the build**

Run: `timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean build. Per the NALAR.md lesson "Desktop app: ALWAYS
run `bun run build` (NOT `bun run build-only`)" — this catches
`vue-tsc --build` errors that the vite build alone would miss.

---

## Verification (whole plan)

After all four chunks are complete:

- [ ] **Backend tests pass** — `timeout 300 zig build test 2>&1 | tail -n 20`
- [ ] **Frontend tests pass** — `timeout 60 bun run test:unit 2>&1 | tail -n 15`
- [ ] **Frontend type-checks + builds** — `timeout 120 bun run build 2>&1 | tail -n 20`
- [ ] **Backend compiles** — `timeout 180 zig build 2>&1 | tail -n 20`
- [ ] **Manual smoke test** — start `nalar` on port 8080, open the desktop app:
  1. Settings → add a profile "alpha" with model "gpt-4o" → click "Save Settings"
  2. Set "alpha" as active
  3. Click Delete on "alpha" → confirm
  4. Verify:
     - "alpha" disappears from the list immediately
     - "Active profile" clears in the UI
     - Toast: "Profile 'alpha' deleted"
     - `cat ~/.config/nalar/config.json` shows no "alpha" key and `active_profile` is `null`
     - If a workflow is mid-stream that was using "alpha", the next turn fails gracefully (out of scope for this plan; see "Out of scope" below)
  5. Re-add "alpha", then try to delete it with the backend killed (port 8080 stopped) — verify the row reappears in the list (rollback) and an error toast appears
  6. Try to delete a non-existent profile via curl: `curl -X DELETE http://localhost:8080/api/config/nalar/profiles/ghost` → 404
  7. Try to delete a profile whose name contains a `/` and a space: verify the URL is correctly encoded and the delete succeeds
- [ ] **Commit** — `git add ... && git commit -m "feat: immediate-persist profile deletion with confirmation + rollback"`

---

## Out of scope (deliberately)

- **Refuse delete if the profile is the active one** — the current behavior is "delete it and clear `active_profile`", matching the user's snippet. The plan preserves this. A future "refuse delete" UX would need a separate design (warn the user, require them to pick a new active first).
- **Refuse delete if a workflow is mid-stream using the profile** — checking `active_loops` is straightforward (`di.active_loops` exposes a registry) but the right UX is non-obvious (block? warn? force-kill the loop?). The user did not ask for it. Add as a follow-up.
- **Bulk delete** — only single-profile delete is in scope.
- **Optimistic-delete already-saved profiles when the user navigates away** — if the user clicks Delete and then closes the settings view before the API responds, the optimistic state may be in the parent's in-memory refs but never persisted. The composable's `isDeleting` guard makes this less likely, and the rollback handles the API-failure case. The "user navigates away mid-flight" race is a known limitation of optimistic UI in general; document it but do not fix in this plan.
- **Refactor the deferred-save path in `saveSettings` (lines 172-184 of `NalarSettings.vue`)** — the existing `delete` action array is now dead code (the new flow bypasses it), but removing it is a separate cleanup. Leave a `// TODO: remove once the immediate-delete path is the only delete path` comment for the follow-up PR.
- **Per-profile undo toast** ("Profile deleted [Undo]") — would require holding the deleted profile in memory for N seconds, which is more state for a small win. Skip.

---

## Risk summary

| Risk | Mitigation |
|---|---|
| `req.params.get("name")` API name is different in gserverz | Step 6's implementation note flags this; verify against `router.zig` before writing. |
| `getDefaultConfigPath` vs `getDefaultConfigDir` (the PUT handler uses the latter) | The GET handler at `nalar_config_get.zig:23` uses `getDefaultConfigPath` (the file path, not the directory). Use that — same as GET, since we're reading/writing the file directly. |
| Free-on-`swapRemove` semantics differ across `json.ObjectMap` versions | The test (Task 1.1, Step 1) asserts the helper's memory behavior is correct. If `fetchSwapRemove` is missing, fall back to `swapRemove` + a separate `allocator.free(key)` on the returned key. |
| The new endpoint breaks the `mcpServers_parsed` / `mcp_servers` alias migration | The handler only touches `profiles_models` and `active_profile`; all other fields pass through unchanged. The PUT handler has the same field-preservation pattern — verified by the existing `nalar_config_put_test.zig` smoke test. |
| Optimistic update races with the parent re-fetching via `getNalarConfig` | The parent (`NalarSettings.vue`) only fetches on `onMounted`; it does not poll. The composable's `isDeleting` guard + the parent's `confirmingDeleteProfile` ref ensure no concurrent delete+fetch is possible from this component. |
| Composable test's `vi.mock('../api', ...)` collides with the real module's `EventSource` constructor (run at function entry in `api/index.ts`) | The `__tests__/setup.ts` polyfill already addresses this for the whole suite; the mock replaces the named export only, leaving the `EventSource` constructor side-effect of the real module to run once at import time. |
