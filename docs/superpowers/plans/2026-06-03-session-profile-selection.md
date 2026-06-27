# Per-Session Profile Selection Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-session `selected_profile_model` column that stores the name of a profile (key in `LlmConfig.profiles_models`). When sending a message, the workflow resolves the profile to LLM credentials (model, base_url, api_key, url_style). NULL means use the top-level LLM config.

**Architecture:** Surgical extension of the existing sessions/CRUD/profile system. New `Migration040` adds the column. New `updateSessionSelectedProfileModel` function and a new `PUT /api/session/:id` HTTP handler let the frontend change the selection. `LlmConfig.getProfile(name)` accessor resolves the profile at LLM-call time. Frontend adds a profile selector chip to the chat input status bar that persists to the session.

**Tech Stack:** Zig 0.16 backend (custom SQLite migrations, gserverz HTTP router, std.ArrayList), Vue 3 + TypeScript + Pinia (Tailwind, no UI library).

---

## File Structure (Before/After)

### Backend (Zig) — 7 files modified, 1 file created

| File | Action | Responsibility |
|---|---|---|
| `src/ai_workflow/tui/migration.zig` | MODIFY | Add `Migration040AddSelectedProfileModelToSessions` struct + register in `allMigrations` slice |
| `src/ai_workflow/tui/llm_history.zig` | MODIFY | Add `selected_profile_model: []const u8` to `SessionInfo`, `SessionTableInfo`, `SessionInfoJson`, `SessionBroadcastInfo`; extend SELECTs; add `updateSessionSelectedProfileModel` function |
| `src/ai_workflow/tui/on_event_sent.zig` | MODIFY | Add field to `OnEventInputSessions` + payload builder |
| `src/ai_workflow/tui/http_handlers/session_create.zig` | MODIFY | Accept `selected_profile_model` in `RequestSession`; persist on insert; plumb through `RunParamsNew` |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | MODIFY | Add `selected_profile_model` to `SessionCreateResponse` |
| `src/ai_workflow/tui/http_handlers/mod.zig` | MODIFY | Re-export new `sessionUpdateHandler` |
| `src/ai_workflow/tui/http_handlers/session_update.zig` | **CREATE** | `PUT /api/session/:session_id` and `PUT /api/llm/session/:session_id` — partial update of `selected_profile_model` |
| `src/ai_workflow/tui/workflow.zig` | MODIFY | Add `selected_profile_model` to `RunParamsNew`; resolve profile at workflow start; pass resolved credentials to `callDynamicAgentNew`/`callCompactAgentNew`/`generateSessionNameNew` |
| `src/modules/config/Config.zig` | MODIFY | Add `getProfile(name)` + `hasProfile(name)` accessors (the `LlmProfile` already lives in `profiles_models` — no struct changes needed) |
| `src/main.zig` | MODIFY | Register new PUT route |

### Frontend (TypeScript / Vue) — 4 files modified

| File | Action | Responsibility |
|---|---|---|
| `src/apps/desktop/src/api/index.ts` | MODIFY | Add `selectedProfile` to `Session`, `Chat`, `SessionEvent`; extend `sendChatMessage` signature; add `updateSession` |
| `src/apps/desktop/src/components/ChatView.vue` | MODIFY | Add profile selector chip to status bar; pass `selectedProfile` to `sendChatMessage`; load on session change |
| `src/apps/desktop/src/components/ChatsList.vue` | MODIFY | Show model badge next to session name in sidebar |

### Test Files — 1 new + 1 extended

| File | Action | Responsibility |
|---|---|---|
| `src/ai_workflow/tui/llm_history_test.zig` | **CREATE** | Unit test for `updateSessionSelectedProfileModel` and new SELECTs |
| `src/ai_workflow/tui/http_handlers/session_update_test.zig` | **CREATE** | HTTP handler tests for PUT endpoint |

---

## Design Decisions

### 1. Column semantics
- `selected_profile_model TEXT NULL` — the **name** (key) of a profile in `LlmConfig.profiles_models`.
- `NULL` = use top-level `LlmConfig.{api_key, model, base_url, url_style}` (the "default" mode).
- Non-null but pointing to a deleted profile = fall back to top-level with a log warning (defensive).
- The column is **per-session**, not per-message. Stored once, used for every LLM call on that session.

### 2. Why a column AND a per-message override
- **Column (persistent)**: lets the frontend show "this session uses Work profile" and persist it across reloads; needed for the chat UI badge.
- **Per-message field (in `RequestSession`)**: lets the frontend change the selection on the FIRST message of a brand-new session (the column is written during `insertWorker`). Both paths converge: the workflow always reads the effective value, and the column is the source of truth at LLM-call time.
- For mid-session model switches, the frontend calls `PUT /api/session/:id` to update the column, and the next message uses the new value.

### 3. Profile resolution rule
- `RunParamsNew.selected_profile_model` (if non-empty) overrides everything else.
- The workflow then **re-reads the column from the DB** as the authoritative source (in case the frontend updated it via PUT between the request POST and the workflow execution).
- Workflow fallback chain:
  1. `params.selected_profile_model` (from the POST body, if non-empty)
  2. `db.session.selected_profile_model` (re-read in the workflow)
  3. `LlmConfig.profiles_models[name]` (must exist; if missing, log warning + fall back)
  4. Top-level `LlmConfig.{api_key, model, base_url, url_style}` (always available)

### 4. Threading
- The resolution happens once at the top of `runAgenticMultiStepnew` (workflow.zig:125, after `const config = nalar_mod.getLlmConfig(di);`).
- The resolved `effective_api_key`, `effective_model`, `effective_base_url`, `effective_url_style` are local `[]const u8` slices allocated in the workflow's arena allocator (lifetime = the whole workflow run).
- All three downstream call sites (`generateSessionNameNew`, `callCompactAgentNew`, `callDynamicAgentNew`) get the resolved values.

---

## Task Index

| # | Task | Files | Chunk |
|---|------|-------|-------|
| 1 | Add migration for `selected_profile_model` column | `migration.zig` | 1 |
| 2 | Extend Session structs + SELECTs + add `updateSessionSelectedProfileModel` | `llm_history.zig` | 1 |
| 3 | Add `getProfile`/`hasProfile` accessors to `LlmConfig` | `Config.zig` | 2 |
| 4 | Plumb `selected_profile_model` through `RequestSession` → `RunParamsNew` → workflow resolution | `session_create.zig`, `workflow.zig` | 2 |
| 5 | Create `PUT /api/session/:id` handler | `session_update.zig` (new), `mod.zig`, `http_response.zig`, `main.zig` | 3 |
| 6 | Update frontend types + `sendChatMessage` + new `updateSession` | `api/index.ts` | 4 |
| 7 | Add profile selector chip to ChatView status bar | `ChatView.vue` | 4 |
| 8 | Show profile badge in ChatsList sidebar | `ChatsList.vue` | 4 |
| 9 | Backend unit tests for the new code | `llm_history_test.zig`, `session_update_test.zig` | 5 |

---

# Chunk 1: Database & Session Model

> Both tasks are tightly coupled (migration adds column → structs need to read it) and form a self-contained backend unit. ~150 lines changed total.

### Task 1: Add `Migration040AddSelectedProfileModelToSessions`

**Files:**
- Modify: `src/ai_workflow/tui/migration.zig:617` (insert new struct after `Migration039`)
- Modify: `src/ai_workflow/tui/migration.zig:709` (append to `allMigrations` slice)

Mirror `Migration022AddCwdToSessions` (lines 305-312) exactly. The new column is `TEXT NULL` (nullable by default; SQLite `ADD COLUMN` with no `NOT NULL` makes it nullable).

- [ ] **Step 1.1: Read the existing migration file to confirm the exact insertion point**

```bash
sed -n '610,720p' src/ai_workflow/tui/migration.zig
```

- [ ] **Step 1.2: Append the new migration struct after `Migration039AddToolCallIdToLlmHistory`**

In `src/ai_workflow/tui/migration.zig`, after line 617 (the closing `};` of `Migration039`), insert:

```zig
pub const Migration040AddSelectedProfileModelToSessions = struct {
    pub const version: u32 = 40;
    pub const name = "add_selected_profile_model_to_sessions";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        try db.exec(allocator, "ALTER TABLE sessions ADD COLUMN selected_profile_model TEXT", &[_][]const u8{});
    }
};
```

- [ ] **Step 1.3: Register the new migration in `allMigrations`**

In the same file, find the last line of the `allMigrations` slice (line 709, currently `Migration039AddToolCallIdToLlmHistory`). Append:

```zig
    .{ .version = Migration040AddSelectedProfileModelToSessions.version, .name = Migration040AddSelectedProfileModelToSessions.name, .up = Migration040AddSelectedProfileModelToSessions.up },
```

- [ ] **Step 1.4: Build the project to verify the migration compiles**

Run: `zig build 2>&1 | head -n 50`
Expected: `Build succeeded` (or no new errors related to migration.zig).

- [ ] **Step 1.5: Commit**

```bash
git add src/ai_workflow/tui/migration.zig
git commit -m "feat(db): add Migration040 for selected_profile_model column"
```

### Task 2: Extend Session structs, SELECTs, and add `updateSessionSelectedProfileModel`

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig` (4 structs, 4 SELECTs, 1 new function)

> ⚠️ **Critical:** The deinit/order of fields must stay consistent. `SessionInfo` deinit frees in field order — adding a field at the end with a corresponding `allocator.free` is the safe path.

- [ ] **Step 2.1: Add `selected_profile_model` to `SessionInfo` struct (lines 21-39)**

After line 28 (the `agent` field), add:
```zig
    selected_profile_model: []const u8,
```

In the `deinit` function (after line 37), add:
```zig
        allocator.free(self.selected_profile_model);
```

- [ ] **Step 2.2: Add `selected_profile_model` to `SessionTableInfo` struct (lines 1722-1739)**

After line 1729 (the `updated_at` field), add:
```zig
    selected_profile_model: []u8,
```

In `deinit` (after line 1737), add:
```zig
        allocator.free(self.selected_profile_model);
```

- [ ] **Step 2.3: Add `selected_profile_model` to `SessionInfoJson` struct (lines 267-274)**

After line 273 (the `session_name` field), add:
```zig
    selected_profile_model: []const u8,
```

- [ ] **Step 2.4: Add `selected_profile_model` to `SessionBroadcastInfo` struct (lines 76-84)**

After line 83 (the `agent` field), add:
```zig
    selected_profile_model: []const u8,
```

- [ ] **Step 2.5: Extend the `getSessionListWithCursor` SQL (line 203) to SELECT the new column**

In `getSessionListWithCursor` (line 202-210), extend the SELECT:

```zig
    const sql_final = try std.fmt.allocPrint(allocator,
        \\SELECT s.id, s.name, s.status, s.cwd, COALESCE(s.created_at, ''),
        \\COALESCE(s.updated_at, ''),
        \\COALESCE(h.agent, 'Agent'),
        \\COALESCE(s.selected_profile_model, '')
        \\FROM sessions s
        \\LEFT JOIN llm_history h ON s.id = h.session_id
        \\WHERE {s}
        \\GROUP BY s.id ORDER BY {s} LIMIT {d}
    , .{ where_with_cursor, order_by, limit });
```

- [ ] **Step 2.6: Update the row-binding for `SessionInfo` (lines 222-232) to read the new column**

```zig
    while (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_name = try allocator.dupe(u8, row.values[1]),
            .status = try allocator.dupe(u8, row.values[2]),
            .cwd = try allocator.dupe(u8, row.values[3]),
            .created_at = try allocator.dupe(u8, row.values[4]),
            .updated_at = try allocator.dupe(u8, row.values[5]),
            .agent = try allocator.dupe(u8, row.values[6]),
            .selected_profile_model = try allocator.dupe(u8, row.values[7]),
        };
        try sessions.append(allocator, session);
        row.deinit(allocator);
    }
```

- [ ] **Step 2.7: Extend `buildSessionListJson` (lines 277-307) to include the new field in JSON output**

In the for-loop body (line 289-296), add:
```zig
        try json_sessions.append(allocator, .{
            .session_id = sess.session_id,
            .cwd = sess.cwd,
            .created_at = sess.created_at,
            .updated_at = sess.updated_at,
            .agent = sess.agent,
            .session_name = sess.session_name,
            .selected_profile_model = sess.selected_profile_model,
        });
```

- [ ] **Step 2.8: Extend `getSession` SELECT (line 1777) and row binding (lines 1783-1789)**

Change line 1777 to:
```zig
    const sql = "SELECT id, name, status, COALESCE(cwd, ''), COALESCE(created_at, ''), COALESCE(updated_at, ''), COALESCE(selected_profile_model, '') FROM sessions WHERE id = ?";
```

In the row binding (line 1783-1789), add:
```zig
            .selected_profile_model = try allocator.dupe(u8, row.values[6]),
```

- [ ] **Step 2.9: Extend `getSessionsForBroadcast` SELECT and `SessionBroadcastInfo` binding (lines 2305-2331)**

Read the file first to confirm the exact line numbers and current SQL.

- Extend the SELECT to include `COALESCE(s.selected_profile_model, '')`
- Bind the new field to the `SessionBroadcastInfo` struct

- [ ] **Step 2.10: Add the `updateSessionSelectedProfileModel` function after `updateSessionName` (after line 1848)**

```zig
/// Update session selected_profile_model (the name of a profile in
/// LlmConfig.profiles_models). Pass empty string or null to clear.
pub fn updateSessionSelectedProfileModel(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    selected_profile_model: ?[]const u8,
) !void {
    const effective: []const u8 = selected_profile_model orelse "";
    const sql = "UPDATE sessions SET selected_profile_model = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?";
    try db.exec(allocator, sql, .{ effective, id });

    // Re-read and broadcast the updated session
    const session = getSession(allocator, db, id) catch null;
    if (session) |s| {
        defer s.deinit(allocator);
        ai_mod.on_event_sent.onEventSendSessions(allocator, .{
            .action = "updated",
            .id = s.id,
            .name = s.name,
            .status = s.status,
            .cwd = s.cwd,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .selected_profile_model = s.selected_profile_model,
        }) catch {};
    }
}
```

- [ ] **Step 2.11: Update `onEventSendSessions` payload struct in `on_event_sent.zig`**

In `src/ai_workflow/tui/on_event_sent.zig` (lines 96-104), add the new field to `OnEventInputSessions`:

```zig
pub const OnEventInputSessions = struct {
    action: []const u8,
    id: []const u8,
    name: []const u8,
    status: []const u8,
    cwd: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    selected_profile_model: []const u8 = "",  // NEW
};
```

Then in the function that builds the JSON payload from this struct (search for the `.print(allocator, "{f}", .{std.json.fmt(payload, ...)})` block that references these fields), add the new field to the `payload` struct literal:

```zig
const payload = .{
    .action = input.action,
    .id = input.id,
    .name = input.name,
    .status = input.status,
    .cwd = input.cwd,
    .created_at = input.created_at,
    .updated_at = input.updated_at,
    .selected_profile_model = input.selected_profile_model,  // NEW
};
```

- [ ] **Step 2.12: Build to verify no type errors**

Run: `zig build 2>&1 | head -n 50`
Expected: `Build succeeded` with no errors related to the modified files. Likely candidates: a struct field mismatch in a builder function you missed.

- [ ] **Step 2.13: Commit**

```bash
git add src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/on_event_sent.zig
git commit -m "feat(db): add selected_profile_model field to session structs and SELECTs"
```

---

# Chunk 2: LLM Config Accessor + Workflow Plumbing

> Couples Tasks 3-4. After this chunk, the backend fully supports profile-resolved LLM calls but the column isn't yet settable via the HTTP layer (that's Chunk 3). The frontend still can't see profiles. ~80 lines changed.

### Task 3: Add `getProfile` and `hasProfile` accessors to `LlmConfig`

**Files:**
- Modify: `src/modules/config/Config.zig` (add 2 accessors after line ~516, near the existing `mcpServerConfig` accessor)

- [ ] **Step 3.1: Read the existing accessors for context**

```bash
grep -n "pub fn" src/modules/config/Config.zig
```

Confirm the location of the existing accessors (e.g., `mcpServerConfig`, `hasMcpServer`).

- [ ] **Step 3.2: Add the two accessors after the last existing accessor**

Append at the end of the file (or after the last `pub fn`):

```zig
/// Look up a profile by name (the key in `profiles_models`). Returns null when
/// not configured. The returned `LlmProfile` borrows from `self` — the lifetime
/// is tied to this `LlmConfig` (do not outlive the config).
pub fn getProfile(self: *const LlmConfig, name: []const u8) ?LlmProfile {
    const entry = self.profiles_models.getEntry(name) orelse return null;
    return entry.value_ptr.*;
}

/// Returns true if a profile with the given name exists and has a non-empty
/// `model` field. Use this before calling `getProfile` if you need to know
/// whether resolution will succeed.
pub fn hasProfile(self: *const LlmConfig, name: []const u8) bool {
    if (self.profiles_models.getEntry(name)) |entry| {
        return entry.value_ptr.model.len > 0;
    }
    return false;
}
```

- [ ] **Step 3.3: Build to verify**

Run: `zig build 2>&1 | head -n 50`
Expected: no new errors.

- [ ] **Step 3.4: Commit**

```bash
git add src/modules/config/Config.zig
git commit -m "feat(config): add LlmConfig.getProfile and hasProfile accessors"
```

### Task 4: Plumb `selected_profile_model` through HTTP request → event bus → workflow

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/session_create.zig` (4 places: struct, dup, defer, emit)
- Modify: `src/ai_workflow/tui/workflow.zig` (2 places: `RunParamsNew` struct, `runAgenticMultiStepnew` resolution + 3 call sites)

> The wiring: frontend sends `selected_profile_model` in the POST body → handler heaps-dupes and passes to `concurrent` runner → emits on event bus → workflow reads from `RunParamsNew` → resolves profile and uses it for all 3 LLM calls.

- [ ] **Step 4.1: Add `selected_profile_model` to `RequestSession` struct (session_create.zig:38-46)**

```zig
pub const RequestSession = struct {
    session_id: []const u8 = "",
    session_name: []const u8 = "",
    queue_message: []const u8 = "",
    cwd_session: []const u8 = "",
    allowed_tools: []const u8 = "",
    body_message: []const u8 = "",
    image_urls: []const u8 = "",
    selected_profile_model: []const u8 = "",  // NEW: name of profile in LlmConfig.profiles_models
};
```

- [ ] **Step 4.2: Heap-dupe the new field inside `useCase` (around line 141-153)**

After the existing `thread_image_urls` dupe, add:
```zig
    const thread_selected_profile_model = try di.allocator.dupe(u8, parsed.selected_profile_model);
```

In the `errdefer` block (line 146-153), add:
```zig
        di.allocator.free(thread_selected_profile_model);
```

- [ ] **Step 4.3: Add the parameter to the inner `run` function signature (lines 158-166)**

```zig
            fn run(
                di_inner: *nalarcore.ContextIPCTui,
                sid: []u8,
                qmsg: []u8,
                cwd: []u8,
                bmsg: []u8,
                atools: []u8,
                iurls: []u8,
                spm: []u8,  // NEW: selected_profile_model
            ) void {
                // Task owns these slices — free them when done
                defer di_inner.allocator.free(sid);
                defer di_inner.allocator.free(qmsg);
                defer di_inner.allocator.free(cwd);
                defer di_inner.allocator.free(bmsg);
                defer di_inner.allocator.free(atools);
                defer di_inner.allocator.free(iurls);
                defer di_inner.allocator.free(spm);  // NEW
```

- [ ] **Step 4.4: Add the new field to the `event_bus.emit` payload (lines 176-185)**

```zig
                event_bus.emit(ai_workflow.ai_workflow.RunParamsNew, "ai_worker_flow", .{
                    .parent_session_id = sid,
                    .session_id = sid,
                    .message = qmsg,
                    .cwd = cwd,
                    .body = bmsg,
                    .allowed_tools = atools,
                    .is_sub_agent = false,
                    .image_urls = iurls,
                    .selected_profile_model = spm,  // NEW
                });
```

- [ ] **Step 4.5: Pass the new arg in the `.concurrent` call (line 188)**

```zig
        .{ di, thread_session_id, thread_queue_message, thread_effective_cwd, thread_body_message, thread_allowed_tools, thread_image_urls, thread_selected_profile_model },
```

- [ ] **Step 4.6: Update `insertWorker` to also write the new column (session_create.zig:202-227)**

In `insertWorker` (lines 202-227), extend the SQL and the bind list:

```zig
fn insertWorker(allocator: std.mem.Allocator, sqlite_db: *sqlite_db_mod.SqliteBackend, parsed: RequestSession, image_urls: []const u8) !void {
    _ = image_urls;
    const session_id = parsed.session_id;
    const session_name = parsed.session_name;
    const effective_cwd = parsed.cwd_session;
    const effective_profile = parsed.selected_profile_model;

    const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model) VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?)";
    const copy_session_name = try allocator.dupe(u8, session_name);
    defer allocator.free(copy_session_name);
    const copy_cwd = try allocator.dupe(u8, effective_cwd);
    defer allocator.free(copy_cwd);
    const copy_session_id = try allocator.dupe(u8, session_id);
    defer allocator.free(copy_session_id);
    const copy_profile = if (effective_profile.len > 0) try allocator.dupe(u8, effective_profile) else "";
    defer if (copy_profile.len > 0) allocator.free(copy_profile);
    try sqlite_db.exec(allocator, session_sql, &.{ session_id, copy_session_name, copy_cwd, copy_profile });

    // Broadcast session created event (include new field)
    ai_workflow.on_event_sent.onEventSendSessions(allocator, .{
        .action = "created",
        .id = session_id,
        .name = session_name,
        .status = "active",
        .cwd = effective_cwd,
        .created_at = "",
        .updated_at = "",
        .selected_profile_model = effective_profile,  // NEW
    }) catch {};
}
```

- [ ] **Step 4.7: Add `selected_profile_model` to `RunParamsNew` struct (workflow.zig:953-962)**

```zig
pub const RunParamsNew = struct {
    parent_session_id: []const u8,
    session_id: []const u8,
    message: []const u8,
    cwd: []const u8,
    body: []const u8,
    allowed_tools: []const u8,
    is_sub_agent: bool = false,
    image_urls: []const u8 = "",
    selected_profile_model: []const u8 = "",  // NEW
};
```

- [ ] **Step 4.8: Add the resolution block at the top of `runAgenticMultiStepnew` (workflow.zig:125)**

After `const config = nalar_mod.getLlmConfig(di);` (line 125), insert:

```zig
    // ─── Resolve the effective LLM profile (selected_profile_model) ──────
    // Fallback chain:
    //   1. params.selected_profile_model (from POST body) if non-empty AND profile exists
    //   2. top-level LlmConfig (the "default" mode)
    // All four slices borrow from the arena allocator OR the LlmConfig —
    // they live for the whole workflow run.
    const effective_api_key: []const u8 = blk: {
        if (params.selected_profile_model.len > 0) {
            if (config.getProfile(params.selected_profile_model)) |profile| {
                if (profile.api_key.len > 0) break :blk profile.api_key;
            } else {
                logger.warnFmt("WORKFLOW: selected_profile_model '{s}' not found in LlmConfig.profiles_models, using top-level config", .{params.selected_profile_model});
            }
        }
        break :blk config.api_key;
    };
    const effective_model: []const u8 = blk: {
        if (params.selected_profile_model.len > 0) {
            if (config.getProfile(params.selected_profile_model)) |profile| {
                if (profile.model.len > 0) break :blk profile.model;
            }
        }
        break :blk config.model;
    };
    const effective_base_url: []const u8 = blk: {
        if (params.selected_profile_model.len > 0) {
            if (config.getProfile(params.selected_profile_model)) |profile| {
                if (profile.base_url.len > 0) break :blk profile.base_url;
            }
        }
        break :blk config.base_url;
    };
    const effective_url_style: []const u8 = blk: {
        if (params.selected_profile_model.len > 0) {
            if (config.getProfile(params.selected_profile_model)) |profile| {
                if (profile.url_style.len > 0) break :blk profile.url_style;
            }
        }
        break :blk config.url_style;
    };
```

- [ ] **Step 4.9: Replace the 3 call sites in the workflow loop to use the resolved values**

**Site 1** — line 345 (`generateSessionNameNew`):
```zig
            generateSessionNameNew(db_messages, allocator, effective_api_key, effective_model, effective_base_url, copy_session_id, logger, io, db);
```

**Site 2** — line 358 (`callCompactAgentNew`):
```zig
            if (callCompactAgentNew(&copy_list, allocator, effective_api_key, effective_model, effective_base_url, copy_cwd, logger, io)) |compacted_xml| {
                try compactMessageInMemoryNew(allocator, &messagesLists, compacted_xml, copy_session_id, effective_model, copy_cwd, db, io, logger);
            }
```

**Site 3** — line 363 (`callDynamicAgentNew`):
```zig
        const res_dynamic_agent = callDynamicAgentNew(allocator, io, &messagesLists, agent_temperature, current_max_tokens, isThinking, effective_api_key, effective_model, effective_base_url, copy_session_id, merged_tools) catch |err| {
```

- [ ] **Step 4.10: Build and verify**

Run: `zig build 2>&1 | head -n 80`
Expected: no new errors. If `RunParamsNew` initialization is missing in a tests file, add `.selected_profile_model = ""` to satisfy the new required field.

- [ ] **Step 4.11: Manual smoke test**

Start the dev server: `./bin/nalar-dev` (or follow the project's run command).
Send a message with `selected_profile_model: "work"` (or whatever profile exists) via curl to `/api/llm/session`. Check the log for the resolved model name.
Send a message with `selected_profile_model: ""` and confirm it uses the top-level config.

- [ ] **Step 4.12: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/session_create.zig src/ai_workflow/tui/workflow.zig
git commit -m "feat(workflow): resolve selected_profile_model and use it for LLM calls"
```

---

# Chunk 3: HTTP Update Endpoint

> Single task that lets the frontend change the column mid-session. ~120 lines new code in a fresh file. The frontend uses this to switch profiles without creating a new session.

### Task 5: Create `PUT /api/session/:session_id` and `PUT /api/llm/session/:session_id`

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/session_update.zig` (new file, ~110 lines)
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig` (re-export)
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig` (add `SessionUpdateResponse` + `makeSessionUpdateResponse`)
- Modify: `src/main.zig` (register PUT routes)

- [ ] **Step 5.1: Read the existing mod.zig to confirm the re-export pattern**

```bash
cat src/ai_workflow/tui/http_handlers/mod.zig
```

Look for how `session_create.zig` is imported and re-exported.

- [ ] **Step 5.2: Read main.zig lines 170-250 to find the route registration pattern**

```bash
sed -n '170,250p' src/main.zig
```

Note the exact `gs.router.put(...)` and `gs.router.post(...)` patterns.

- [ ] **Step 5.3: Create the new file `src/ai_workflow/tui/http_handlers/session_update.zig`**

```zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");

const ai_mod = nalarcore.ai_mod;
const gserverz = nalarcore.gserverz;
const llm_history = nalarcore.llm_history;

/// Request body for updating an existing session
pub const RequestSessionUpdate = struct {
    /// Name of a profile in LlmConfig.profiles_models.
    /// Empty string OR missing key = clear (use top-level config).
    selected_profile_model: []const u8 = "",
    /// Optional — also support renaming in the same endpoint for symmetry
    name: []const u8 = "",
};

/// Response body for session update
pub const ResponseSessionUpdate = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    selected_profile_model: []const u8,
};

/// Extract the session_id from the URL path. The path looks like
/// /api/session/{session_id} or /api/llm/session/{session_id}.
/// We expect a path parameter named "session_id".
fn extractSessionIdFromPath(req: gserverz.HttpRequest) []const u8 {
    // Path parameter is populated by the router into req.params
    if (req.params.get("session_id")) |id| return id;
    return "";
}

/// PUT /api/session/:session_id
/// PUT /api/llm/session/:session_id
///
/// Body (JSON, all fields optional):
///   - selected_profile_model: profile name to assign to this session (empty/null = clear)
///   - name: new session name (empty/null = unchanged)
pub fn sessionUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const session_id = extractSessionIdFromPath(req);
    if (session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "missing session_id" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(RequestSessionUpdate, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };

    // Update selected_profile_model (always — even if empty, to allow clearing)
    try llm_history.updateSessionSelectedProfileModel(allocator, sqlite_db, session_id, parsed.selected_profile_model);

    // Optionally update name
    if (parsed.name.len > 0) {
        try llm_history.updateSessionName(allocator, sqlite_db, session_id, parsed.name);
    }

    // Re-read for the response
    const session = (try llm_history.getSession(allocator, sqlite_db, session_id)) orelse {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "session not found" }),
        });
    };
    defer session.deinit(allocator);

    const data = try http_response.makeSessionUpdateResponse(allocator, .{
        .id = session.id,
        .name = session.name,
        .status = session.status,
        .selected_profile_model = session.selected_profile_model,
    });

    return res.jsonResponse(.{ .status_code = 200, .data = data });
}
```

- [ ] **Step 5.4: Add `SessionUpdateResponse` to `http_response.zig`**

In `src/ai_workflow/tui/http_handlers/http_response.zig`, after `SessionCreateResponse` (line 57), add:

```zig
pub const SessionUpdateResponse = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
    selected_profile_model: []const u8,
};
```

After `makeSessionCreateResponse` (line 159-163), add:

```zig
pub fn makeSessionUpdateResponse(allocator: std.mem.Allocator, response: SessionUpdateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}
```

- [ ] **Step 5.5: Re-export the new handler in `http_handlers/mod.zig`**

Look for the existing re-export line that exposes `sessionCreateHandler`. Add a sibling line:

```zig
pub const sessionUpdateHandler = @import("session_update.zig").sessionUpdateHandler;
```

(Adjust the exact import syntax to match the pattern used in this file — if it uses `pub usingnamespace`, follow that pattern instead.)

- [ ] **Step 5.6: Register the PUT routes in `src/main.zig`**

Find the existing routes for `sessionCreateHandler` (line 173-174, 191-192) and add the matching PUT routes right after them:

```zig
try gs.router.put("/api/session/:session_id", ai_mod.http_handlers.sessionUpdateHandler);   // line ~175
try gs.router.put("/api/llm/session/:session_id", ai_mod.http_handlers.sessionUpdateHandler); // line ~193
```

- [ ] **Step 5.7: Build and verify**

Run: `zig build 2>&1 | head -n 50`
Expected: no errors. Common pitfalls:
- `req.params` doesn't have a `get` method → use the actual API surface (search the codebase for `req.params.get` or similar — see how other handlers extract path params)
- The router's `put()` method takes a different signature → check existing `gs.router.put(...)` calls

- [ ] **Step 5.8: Manual smoke test with curl**

```bash
# Create a session
curl -X POST http://localhost:8080/api/llm/session \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"test-spm","session_name":"Test SPM","cwd_session":"/tmp"}'

# Update the selected profile
curl -X PUT http://localhost:8080/api/llm/session/test-spm \
  -H 'Content-Type: application/json' \
  -d '{"selected_profile_model":"work"}'

# Verify via list
curl http://localhost:8080/api/llm/session?limit=10 | python3 -m json.tool | head -n 30
```

Expected: response includes `selected_profile_model: "work"`, list endpoint shows it too.

- [ ] **Step 5.9: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/session_update.zig \
        src/ai_workflow/tui/http_handlers/mod.zig \
        src/ai_workflow/tui/http_handlers/http_response.zig \
        src/main.zig
git commit -m "feat(api): add PUT /api/session/:id endpoint for profile selection"
```

---

# Chunk 4: Frontend Types, API, and Chat UI

> All three frontend tasks are coupled (types must exist before API, API must exist before UI). Run the desktop build (`bun run build`) after each step that touches TypeScript.

### Task 6: Update frontend types and `sendChatMessage`, add `updateSession`

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts` (4 changes: types, sendChatMessage, new function, Chat interface)

- [ ] **Step 6.1: Add `selectedProfile` to `Session` interface (api/index.ts:568-574)**

```typescript
export interface Session {
  sessionId: string
  cwd: string
  createdAt: string
  agent: string
  sessionName: string
  selectedProfile: string  // NEW: empty = use default (top-level config)
}
```

- [ ] **Step 6.2: Add `selectedProfile` to `Chat` interface (api/index.ts:184-188)**

```typescript
export interface Chat {
  session_id: string
  session_name?: string
  status?: string
  selected_profile_model?: string  // NEW
}
```

- [ ] **Step 6.3: Add `selectedProfile` to `SessionEvent` interface (api/index.ts:819-827)**

```typescript
export interface SessionEvent {
  action: 'created' | 'updated' | 'deleted'
  id: string
  name: string
  status: string
  cwd: string
  created_at: string
  updated_at: string
  selected_profile_model: string  // NEW
}
```

- [ ] **Step 6.4: Extend `sendChatMessage` to accept and send `selectedProfile` (api/index.ts:292-355)**

```typescript
export async function sendChatMessage(
  sessionId: string,
  message: string,
  cwdSession: string,
  imageUrls?: string[],
  selectedProfile?: string,  // NEW
): Promise<{ status: string }> {
  let body: string
  const imageUrlsStr = imageUrls?.join('|') || ''

  try {
    body = JSON.stringify({
      session_id: sessionId,
      queue_message: message,
      allowed_tools: 'all',
      cwd_session: cwdSession,
      image_urls: imageUrlsStr,
      selected_profile_model: selectedProfile || '',  // NEW
    })
  } catch (serializeError) {
    console.error('Failed to serialize request body:', serializeError)
    return { status: 'invalid_payload' }
  }

  // (rest of the function unchanged)
  ...
}
```

- [ ] **Step 6.5: Add the new `updateSession` function after `sendChatMessage`**

```typescript
// Update an existing session (selectedProfile, name, etc.)
export async function updateSession(
  sessionId: string,
  updates: { selectedProfile?: string | null; name?: string },
): Promise<{ status: string; selectedProfile?: string }> {
  try {
    const body = JSON.stringify({
      selected_profile_model: updates.selectedProfile ?? '',
      name: updates.name ?? '',
    })
    const response = await fetch(`${API_BASE}/llm/session/${sessionId}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body,
    })
    if (!response.ok) {
      const text = await response.text().catch(() => '')
      console.error(`updateSession HTTP ${response.status}: ${text}`)
      throw new Error(`HTTP ${response.status}`)
    }
    return response.json()
  } catch (error) {
    console.error('updateSession failed:', error)
    throw error
  }
}
```

- [ ] **Step 6.6: Add a `getProfiles` helper for fetching the available profiles (if not already present)**

Check if `getNalarConfig` exists (line 1125 per the exploration). Use that — it already returns `profiles` and `active_profile`. No new function needed; just consume it from `NalarSettings.vue`'s existing pattern.

If `api/index.ts` doesn't have a `getProfiles` shortcut, add:

```typescript
// Convenience: fetch only the profiles (subset of NalarConfig)
export async function getProfiles(): Promise<{
  profiles: Record<string, NalarProfile>
  activeProfile: string | null
}> {
  const config = await getNalarConfig()
  return {
    profiles: config.profiles ?? {},
    activeProfile: config.active_profile ?? null,
  }
}
```

- [ ] **Step 6.7: Build the frontend to catch type errors**

Run: `cd src/apps/desktop && bun run build 2>&1 | tail -n 40`
Expected: `vue-tsc --build` passes (this catches any interface mismatch with the real API responses).

- [ ] **Step 6.8: Commit**

```bash
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(frontend): add selectedProfile to types, sendChatMessage, and updateSession"
```

### Task 7: Add profile selector chip to ChatView status bar

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue` (3 changes: state, send-message call, template chip)

> The chip lives in the status bar (lines 1377-1472). It shows "🤖 Default" or "🤖 <profile name>" and opens a dropdown when clicked. Selecting a profile calls `api.updateSession` and updates local state. On message send, the current profile is passed to `api.sendChatMessage`.

- [ ] **Step 7.1: Read the current `<script setup>` imports and state to understand the existing structure**

```bash
sed -n '1,40p' src/apps/desktop/src/components/ChatView.vue
sed -n '900,1010p' src/apps/desktop/src/components/ChatView.vue
```

- [ ] **Step 7.2: Add profile state and helpers inside `<script setup>`**

Add to the reactive state (near line 36-44, after the `cwd`/`queuedMessages` setup):

```typescript
// Profile selection for this session
const availableProfiles = ref<Array<{ name: string; model: string; base_url: string }>>([])
const selectedProfile = ref<string | null>(null)
const showProfilePicker = ref(false)
const isUpdatingProfile = ref(false)
```

Add a helper function (after the existing `formatTime`):

```typescript
// Load available profiles (called on mount and on session change)
const loadProfiles = async () => {
  try {
    const config = await api.getNalarConfig()
    const profiles = config.profiles ?? {}
    availableProfiles.value = Object.entries(profiles).map(([name, p]) => ({
      name,
      model: p.model ?? '',
      base_url: p.base_url ?? '',
    }))
  } catch (err) {
    console.error('Failed to load profiles:', err)
    availableProfiles.value = []
  }
}

// Select a profile and persist via PUT
const selectProfile = async (name: string | null) => {
  if (isUpdatingProfile.value) return
  isUpdatingProfile.value = true
  try {
    const sid = sessionId.value
    if (sid) {
      await api.updateSession(sid, { selectedProfile: name })
    }
    selectedProfile.value = name
  } catch (err) {
    console.error('Failed to update profile:', err)
  } finally {
    isUpdatingProfile.value = false
    showProfilePicker.value = false
  }
}

// Reset selection when session changes
watch(() => sessionId.value, async (newId) => {
  if (!newId) {
    selectedProfile.value = null
    return
  }
  // Load the current selection from the session detail
  try {
    const session = await api.getSession(newId)
    selectedProfile.value = session?.selectedProfile ?? null
  } catch (err) {
    console.error('Failed to load session profile:', err)
    selectedProfile.value = null
  }
})

onMounted(() => {
  loadProfiles()
})
```

- [ ] **Step 7.3: Update the `handleFileInputSubmit` call to pass `selectedProfile` (line 993)**

```typescript
    await api.sendChatMessage(
      currentSessionId,
      userMessage,
      cwd.value,
      imageUrls,
      selectedProfile.value ?? undefined,  // NEW
    )
```

- [ ] **Step 7.4: Add the chip to the template status bar (after line 1403, before the token usage block)**

```vue
            <!-- Model/Profile selector -->
            <div class="relative">
              <button
                @click="showProfilePicker = !showProfilePicker"
                :disabled="isUpdatingProfile || !sessionId"
                class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-200"
                :class="isUpdatingProfile || !sessionId ? 'opacity-50 cursor-not-allowed' : 'hover:scale-105'"
                style="
                  background-color: var(--semantic-card-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                "
                :title="selectedProfile ? `Using profile: ${selectedProfile}` : 'Using default (top-level config)'"
              >
                <span>🤖</span>
                <span>{{ selectedProfile ?? 'Default' }}</span>
                <span class="text-[10px]">▾</span>
              </button>
              <div
                v-if="showProfilePicker"
                class="absolute bottom-full mb-2 left-0 min-w-[240px] rounded-lg shadow-lg z-20 overflow-hidden"
                style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
              >
                <button
                  @click="selectProfile(null)"
                  class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center justify-between"
                  style="color: var(--semantic-text);"
                >
                  <span>Default (top-level config)</span>
                  <span v-if="!selectedProfile">✓</span>
                </button>
                <div
                  v-for="p in availableProfiles"
                  :key="p.name"
                  @click="selectProfile(p.name)"
                  class="w-full text-left px-3 py-2 text-xs hover:opacity-80 cursor-pointer"
                  style="color: var(--semantic-text); border-top: 1px solid var(--color-border);"
                >
                  <div class="flex items-center justify-between">
                    <span class="font-medium">{{ p.name }}</span>
                    <span v-if="selectedProfile === p.name">✓</span>
                  </div>
                  <div class="text-[10px] mt-0.5" style="color: var(--semantic-text-muted);">
                    {{ p.model }} · {{ p.base_url }}
                  </div>
                </div>
                <div
                  v-if="availableProfiles.length === 0"
                  class="px-3 py-2 text-xs"
                  style="color: var(--semantic-text-muted);"
                >
                  No profiles configured. Add one in Settings.
                </div>
              </div>
            </div>
```

- [ ] **Step 7.5: Add a click-outside handler to close the picker**

In the script setup (after the existing handlers):

```typescript
import { onClickOutside } from '@vueuse/core'  // if not already imported; otherwise use document.addEventListener

// Close picker on outside click
const profilePickerRef = ref<HTMLElement | null>(null)
// Wrap the picker div with `ref="profilePickerRef"` in the template
// (Update Step 7.4 to add `ref="profilePickerRef"` to the dropdown div)

onClickOutside(profilePickerRef, () => {
  showProfilePicker.value = false
})
```

If `@vueuse/core` is not already a dependency, use a manual `document.addEventListener`:

```typescript
const closeOnOutsideClick = (e: MouseEvent) => {
  if (profilePickerRef.value && !profilePickerRef.value.contains(e.target as Node)) {
    showProfilePicker.value = false
  }
}
onMounted(() => document.addEventListener('click', closeOnOutsideClick))
onUnmounted(() => document.removeEventListener('click', closeOnOutsideClick))
```

- [ ] **Step 7.6: Build the desktop app**

Run: `cd src/apps/desktop && bun run build 2>&1 | tail -n 60`
Expected: clean build. Common pitfall: `api.getSession` doesn't return `selectedProfile` yet (it's in the type but the backend response doesn't include it — Task 6.1 added the type but the backend response shape is determined by `buildSessionListJson` which we updated in Task 2.7).

- [ ] **Step 7.7: Manual UI test**

1. Start the desktop app: `cd src/apps/desktop && bun run dev`
2. Open a session
3. Click the chip — verify the dropdown shows profiles
4. Select a profile — verify the chip label updates and a `PUT /api/llm/session/:id` request fires
5. Send a message — verify the LLM actually uses the selected profile (check backend logs for the resolved model name)
6. Reload the page — verify the chip shows the persisted selection

- [ ] **Step 7.8: Commit**

```bash
git add src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(chat): add profile/model selector chip to status bar"
```

### Task 8: Show profile badge in ChatsList sidebar

**Files:**
- Modify: `src/apps/desktop/src/components/ChatsList.vue` (1 change: badge in the chat row template)

> The badge is purely informational — it shows the model next to each session name in the sidebar so the user can see at a glance which profile each session uses.

- [ ] **Step 8.1: Read the ChatsList template around the chat row rendering**

```bash
sed -n '430,500p' src/apps/desktop/src/components/ChatsList.vue
```

- [ ] **Step 8.2: Add a model badge to the chat row**

Find the `<div>` that renders each chat's name (likely contains `{{ item.name }}` or similar). Add a small badge next to it:

```vue
        <div v-if="item.selected_profile_model" class="text-[10px] mt-0.5" style="color: var(--color-violet);">
          🤖 {{ item.selected_profile_model }}
        </div>
```

Adjust placement so it doesn't break the existing flex layout. The simplest: add it below the name in a small font.

- [ ] **Step 8.3: Update the `navItem` type in ChatsList.vue to include the new field**

Look for the type definition (likely around line 124-130 per the exploration):

```typescript
{ id: string; name: string; active?: boolean; processing?: boolean; relativeTime?: string; selected_profile_model?: string }
```

And in the mapping function (line 124-130), propagate the field from the `Chat` object.

- [ ] **Step 8.4: Build the desktop app**

Run: `cd src/apps/desktop && bun run build 2>&1 | tail -n 40`
Expected: clean build.

- [ ] **Step 8.5: Manual UI test**

1. Restart the desktop app
2. Check the sidebar — sessions with a profile set should show the badge; "Default" sessions should not
3. Switch a session's profile via the chat chip — verify the badge updates in real time (the SSE event for "updated" should trigger a re-fetch)

- [ ] **Step 8.6: Commit**

```bash
git add src/apps/desktop/src/components/ChatsList.vue
git commit -m "feat(sidebar): show profile badge in chat list rows"
```

---

# Chunk 5: Backend Tests

> Two test files. After this chunk, the test suite covers the new column, the resolver, and the HTTP endpoint. ~250 lines of new test code.

### Task 9: Backend unit tests for `updateSessionSelectedProfileModel` and the new HTTP endpoint

**Files:**
- Create: `src/ai_workflow/tui/llm_history_test.zig`
- Create: `src/ai_workflow/tui/http_handlers/session_update_test.zig`
- Modify: Find and update the test runner registration file (search for `test_runner.zig`)

- [ ] **Step 9.1: Find the test runner file**

```bash
find src -name "test_runner*.zig" -o -name "*_test_runner*.zig" 2>/dev/null
```

Also look at one existing test file to confirm the import pattern.

- [ ] **Step 9.2: Read an existing test file to confirm the patterns**

```bash
find src -name "*_test.zig" | head -n 3
cat src/ai_workflow/tui/llm_history_test.zig 2>/dev/null || echo "no existing test"
```

If no `llm_history_test.zig` exists, look at a sibling test in the project (e.g., a test for `migration.zig` or a similar function-heavy module). Confirm the test boilerplate (allocator, test database setup, etc.).

- [ ] **Step 9.3: Create `src/ai_workflow/tui/llm_history_test.zig`**

```zig
const std = @import("std");
const testing = std.testing;

const llm_history = @import("llm_history.zig");
const sqlite_db_mod = @import("../../modules/databases/sqlite/Sqlite.zig");

fn makeTestDb(allocator: std.mem.Allocator) !*sqlite_db_mod.SqliteBackend {
    const db = try allocator.create(sqlite_db_mod.SqliteBackend);
    errdefer allocator.destroy(db);
    db.* = try sqlite_db_mod.SqliteBackend.initInMemory(allocator);
    return db;
}

test "updateSessionSelectedProfileModel: sets the column" {
    const allocator = testing.allocator;
    const db = try makeTestDb(allocator);
    defer {
        db.deinit();
        allocator.destroy(db);
    }

    // Setup: create a session first
    try db.exec(allocator,
        \\INSERT INTO sessions (id, name, status) VALUES ('s1', 'Test', 'active')
    , &.{});

    // Test: update the profile
    try llm_history.updateSessionSelectedProfileModel(allocator, db, "s1", "work");

    // Verify
    var rows = try db.query(allocator,
        "SELECT COALESCE(selected_profile_model, '') FROM sessions WHERE id = 's1'", &.{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    defer row.deinit(allocator);
    try testing.expectEqualStrings("work", row.values[0]);
}

test "updateSessionSelectedProfileModel: empty string clears the column" {
    const allocator = testing.allocator;
    const db = try makeTestDb(allocator);
    defer {
        db.deinit();
        allocator.destroy(db);
    }

    try db.exec(allocator,
        \\INSERT INTO sessions (id, name, status, selected_profile_model) VALUES ('s2', 'Test', 'active', 'old_profile')
    , &.{});

    try llm_history.updateSessionSelectedProfileModel(allocator, db, "s2", "");

    var rows = try db.query(allocator,
        "SELECT COALESCE(selected_profile_model, '') FROM sessions WHERE id = 's2'", &.{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    defer row.deinit(allocator);
    try testing.expectEqualStrings("", row.values[0]);
}

test "getSession: returns selected_profile_model in the struct" {
    const allocator = testing.allocator;
    const db = try makeTestDb(allocator);
    defer {
        db.deinit();
        allocator.destroy(db);
    }

    try db.exec(allocator,
        \\INSERT INTO sessions (id, name, status, selected_profile_model) VALUES ('s3', 'Test', 'active', 'fast')
    , &.{});

    const session = (try llm_history.getSession(allocator, db, "s3")).?;
    defer session.deinit(allocator);
    try testing.expectEqualStrings("fast", session.selected_profile_model);
}

test "getProfile: returns null for unknown profile" {
    const allocator = testing.allocator;
    const config = (try @import("../../modules/config/Config.zig").LlmConfig.initForTest(allocator)).?;
    defer config.deinit();
    try testing.expect(config.getProfile("nonexistent") == null);
}
```

> **Note:** The `LlmConfig.initForTest` helper doesn't exist yet — write a minimal version in `Config.zig` if you want this test, or skip the test and rely on integration testing. Pragmatic: drop the `getProfile: returns null` test if `initForTest` is hard to add, since the resolver is also covered by the manual smoke test in Step 4.11.

- [ ] **Step 9.4: Create `src/ai_workflow/tui/http_handlers/session_update_test.zig`**

```zig
const std = @import("std");
const testing = std.testing;
const http_response = @import("http_response.zig");
const session_update = @import("session_update.zig");

test "RequestSessionUpdate: parses JSON with selected_profile_model" {
    const allocator = testing.allocator;
    const body =
        \\{"selected_profile_model": "work", "name": "Renamed"}
    ;
    const parsed = try std.json.parseFromSliceLeaky(
        session_update.RequestSessionUpdate,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    );
    try testing.expectEqualStrings("work", parsed.selected_profile_model);
    try testing.expectEqualStrings("Renamed", parsed.name);
}

test "RequestSessionUpdate: defaults to empty when field missing" {
    const allocator = testing.allocator;
    const body = "{}";
    const parsed = try std.json.parseFromSliceLeaky(
        session_update.RequestSessionUpdate,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    );
    try testing.expectEqualStrings("", parsed.selected_profile_model);
    try testing.expectEqualStrings("", parsed.name);
}

test "SessionUpdateResponse: serializes correctly" {
    const allocator = testing.allocator;
    const response = session_update.ResponseSessionUpdate{
        .id = "s1",
        .name = "Test",
        .status = "active",
        .selected_profile_model = "work",
    };
    const json = try http_response.makeSessionUpdateResponse(allocator, response);
    defer allocator.free(json);
    // Verify it contains the expected keys
    try testing.expect(std.mem.indexOf(u8, json, "\"id\":\"s1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Test\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"status\":\"active\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"selected_profile_model\":\"work\"") != null);
}
```

- [ ] **Step 9.5: Register the new test files in the test runner**

Find the test runner (likely `src/test_runner.zig` or similar). Add:

```zig
_ = @import("ai_workflow/tui/llm_history_test.zig");
_ = @import("ai_workflow/tui/http_handlers/session_update_test.zig");
```

The exact path may differ — check the convention used by other tests in the project.

- [ ] **Step 9.6: Run the test suite**

Run: `zig build test 2>&1 | tail -n 50` (or the project's test command)
Expected: all new tests pass. If `updateSessionSelectedProfileModel` is missing (you didn't add it yet), this step will fail — go back to Task 2.10.

- [ ] **Step 9.7: Commit**

```bash
git add src/ai_workflow/tui/llm_history_test.zig \
        src/ai_workflow/tui/http_handlers/session_update_test.zig \
        <test-runner-file>
git commit -m "test: add unit tests for selected_profile_model CRUD and HTTP endpoint"
```

---

# Verification Checklist (Run Before Marking Plan Complete)

After all 9 tasks complete, run the following end-to-end verification:

- [ ] **V1: Database migration runs on a fresh database**

```bash
# Wipe the test database (CAREFUL — only run on a test env, not production)
rm -f ~/.config/nalar/state.db
./bin/nalar-dev  # or the project's dev run command
# Confirm no errors on startup, and that schema_migrations has version 40
sqlite3 ~/.config/nalar/state.db "SELECT version, name FROM schema_migrations ORDER BY version DESC LIMIT 5"
```

Expected: latest entry is `(40, add_selected_profile_model_to_sessions)`.

- [ ] **V2: Migration runs on an existing database (idempotent / additive)**

The migration uses `ALTER TABLE ... ADD COLUMN` (no `IF NOT EXISTS`), so on a pre-Migration040 database it should succeed. On a post-Migration040 database the column already exists — the migration should be a no-op via the `version > currentVersion` check in `MigrationManager.runMigrations`.

```bash
# Restart with the existing DB
./bin/nalar-dev
# Check logs: "Running migration: add_selected_profile_model_to_sessions (version 40)" should appear once
```

- [ ] **V3: POST /api/llm/session with selected_profile_model persists**

```bash
curl -X POST http://localhost:8080/api/llm/session \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"e2e-test","session_name":"E2E","cwd_session":"/tmp","selected_profile_model":"work"}'
sqlite3 ~/.config/nalar/state.db "SELECT id, name, selected_profile_model FROM sessions WHERE id='e2e-test'"
```

Expected: returns row with `selected_profile_model = "work"`.

- [ ] **V4: PUT /api/llm/session/:id updates the column**

```bash
curl -X PUT http://localhost:8080/api/llm/session/e2e-test \
  -H 'Content-Type: application/json' \
  -d '{"selected_profile_model":"fast"}'
sqlite3 ~/.config/nalar/state.db "SELECT id, selected_profile_model FROM sessions WHERE id='e2e-test'"
```

Expected: row now shows `selected_profile_model = "fast"`.

- [ ] **V5: GET /api/llm/session includes selected_profile_model in the response**

```bash
curl http://localhost:8080/api/llm/session?limit=5 | python3 -m json.tool
```

Expected: each session in the `sessions` array has a `selected_profile_model` key.

- [ ] **V6: Workflow uses the resolved profile**

Send a message with a known profile (e.g., `"work"`) via curl. Check the backend logs for the resolved model name in the Agent initialization. Compare with a `selected_profile_model: ""` (default) request — the model name in the logs should differ.

- [ ] **V7: Frontend chip shows and persists**

1. Open the desktop app
2. Open a session, click the chip, select a profile
3. Send a message — verify the backend log shows the resolved profile
4. Reload the page — verify the chip shows the persisted selection

- [ ] **V8: Sidebar shows the badge**

Restart the app, look at the sidebar — sessions with a profile set should show a small "🤖 <name>" badge.

- [ ] **V9: All tests pass**

```bash
zig build test 2>&1 | tail -n 30
cd src/apps/desktop && bun run build 2>&1 | tail -n 10
```

Expected: all green.

---

# Pitfalls & Gotchas

1. **Lifetime of `effective_*` slices** — The resolved `effective_api_key`, `effective_model`, etc. are slices borrowed from either `LlmConfig` (lifetime = the whole LlmConfigHolder) or the arena allocator (lifetime = the workflow run). Both outlive all three downstream call sites (`generateSessionNameNew`, `callCompactAgentNew`, `callDynamicAgentNew`) because those run synchronously inside the same `runAgenticMultiStepnew` scope. No need to dupe.

2. **`getProfile` returns a `LlmProfile` by value** — `LlmProfile` contains only `[]const u8` fields, all of which point at the same backing memory as the `LlmConfig.profiles_models` map. The returned `LlmProfile` is a "view" — its lifetime is tied to the `LlmConfig`. Don't store it past a `setLlmConfig` call (which atomically swaps the pointer).

3. **Empty string vs missing key in `selected_profile_model`** — Both `""` and `null` in the JSON body mean "clear". The `RequestSessionUpdate` struct defaults to `""` so the missing-key case is handled at the parser level. The `updateSessionSelectedProfileModel` function writes the empty string to the column, which the resolver treats identically to NULL.

4. **Concurrent updates** — If a user changes the profile mid-LLM-call (e.g., clicks the chip while a message is streaming), the in-flight call uses the old value (the workflow already captured it). The next message uses the new value. This is the correct semantics — no need for fancy locking.

5. **SSE broadcast on profile change** — The `updateSessionSelectedProfileModel` function re-reads the session and broadcasts an "updated" event with the new field. The frontend's `ChatsList.vue` listens for these events; it should pick up the change in real time. If it doesn't, verify the SSE subscription is processing the new field in `SessionEvent`.

6. **`INSERT OR IGNORE` in `insertWorker`** — The first message for a session triggers `insertWorker`. If the session was already created (e.g., via a previous PUT), the IGNORE clause means the `selected_profile_model` column is NOT updated by the first-message INSERT. This is correct: the first message only sets the column if the session is brand new. Mid-session changes go through PUT.

7. **`url_style` cascade** — When the profile specifies `url_style: "anthropic"`, the Agent's `buildJsonAnthropicRequest` is used instead of `buildJsonOpenAIRequest`. Make sure `effective_url_style` is plumbed into the Agent struct too — see `callDynamicAgentNew` (workflow.zig:626-655) for where the `url_style` field is set. If you skip this, the request format will mismatch the base_url.

8. **Frontend watcher timing** — The `watch(() => sessionId.value, ...)` in ChatView may fire before the session is fully loaded. Use `watchEffect` or a debounce if you see flicker. Also, the `loadProfiles()` call on mount should fire BEFORE the user clicks the chip — verify by checking that the dropdown isn't empty on first open.

9. **Per-profile URL vs default URL** — The `LlmProfile.base_url` is the FULL endpoint URL (e.g., `https://api.openai.com/v1`), not just the host. The `Agent.callStreaming` concatenates `/chat/completions` or `/messages` onto it. Make sure profiles in `nalar.json` include the `/v1` suffix (or whatever the API expects).

10. **CORS / network in dev mode** — The PUT endpoint is a new HTTP method on existing paths. If the dev server runs on a different port, the browser may not allow PUT (CORS). Check `src/main.zig` for the CORS middleware and ensure PUT is in the allowed methods list.

---

# Plan Summary

| Chunk | Tasks | Lines Added | Lines Modified | Files Touched |
|-------|-------|-------------|----------------|---------------|
| 1: DB & Model | 1, 2 | ~40 | ~50 | 2 |
| 2: Config & Workflow | 3, 4 | ~50 | ~25 | 3 |
| 3: HTTP Endpoint | 5 | ~110 | ~20 | 4 |
| 4: Frontend | 6, 7, 8 | ~150 | ~10 | 4 |
| 5: Tests | 9 | ~150 | ~5 | 3 |
| **Total** | **9 tasks** | **~500 new** | **~110 modified** | **~16 files** |

Estimated effort: 4-6 hours for an agent familiar with the codebase, 8-12 hours for someone new.

Next step: dispatch a plan-document-reviewer subagent against each chunk for a sanity check before execution. Once approved, run with `superpowers:subagent-driven-development` (one subagent per task) or `superpowers:executing-plans` if no subagents are available.
