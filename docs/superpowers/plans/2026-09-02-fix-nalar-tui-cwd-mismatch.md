# Fix nalar-tui cwd mismatch — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `nalar-tui` sends the shell's actual working directory as `cwd_session` so the agent operates in the user's project folder instead of the empty sandbox `~/.local/share/nalar/data/apps/session-...`.

**Architecture:** Capture the OS cwd once at TUI startup (via `std.Io.Dir.cwd().realPathAlloc`), store it in `App.Config`/`App`, thread it through `transport.buildSendBody` → `POST /api/llm/session` as `cwd_session`. Backend already honors `cwd_session` when non-empty (see `session_create.zig:160-167`); no backend change needed. Add an optional `--cwd` flag to override the auto-detected value.

**Tech Stack:** Zig 0.16 (`std.Io`, `std.fs.path`, `custom_http_client`), `nalar-tui` TUI module (`src/apps/cli/src/tui/`), existing `session_create` fallback chain.

## Global Constraints

- Zig 0.16 APIs only (`std.Io.Threaded`, `std.Io.Dir.cwd().realPathAlloc`, `std.fs.path.isAbsolute`). No `std.posix.getenv` (removed) — use `std.process.Environ.Map` where needed.
- Do NOT kill the port 8081 server. Functional tests must use an isolated port (8080) via `tests/functional/harness.py`.
- `cwd_session` must be an absolute path when sent; empty string means "let server fall back to sandbox" (preserves backward compat for callers that intentionally want sandbox).
- Follow per-request arena rule: `ctx.allocator` is arena-backed — no `defer free` for arena slices inside handlers (not relevant here, but keep in mind if touching backend).

---

## Context — Root Cause

**User report (2026-09-02):** Launching `nalar-tui` from `~/D/Archive.tar` (or any project dir) then asking "project apa iniii?" makes the agent answer "masih kosong total" and `list_directory` shows it inspected `/home/ginwa/.local/share/nalar/data/apps/session-1788360596665` (0 entries) instead of the shell's cwd.

**Why:**

1. `src/apps/cli/src/tui/transport.zig:99-117` — `buildSendBody` hardcodes `"cwd_session":""` for every message:
   ```zig
   try w.writeAll(",\"allowed_tools\":\"all\",\"cwd_session\":\"\"," ++ ...
   ```
2. `src/apps/cli/src/tui_main.zig:110-133` — `sendAndTrack` calls `transport.postSend(allocator, &http_client, server, session_id, msg_text)` with no cwd argument; `App` has no cwd field at all.
3. Backend `src/ai_workflow/tui/http_handlers/session_create.zig:159-201` — when `cwd_session == ""` and `session_id` has no `workspace_item_tasks` row (true for every TUI session — `session-1788360596665` is not a kanban task id), `resolveCwdFromTaskOrItem` returns `""` and the handler falls back to `createSandbox(...)` → `~/.local/share/nalar/data/apps/<session_id>`. That sandbox is empty by design.
4. The agent's system prompt then renders `cwd = sandbox` and every `list_directory`/`read_file`/`glob` tool call is scoped there — the user's real project is invisible.

**Desktop is not affected:** `src/apps/desktop/src/api/index.ts:1311` and `AppLayout.vue:2646` thread `workspace_item.path` as `cwd_session` for kanban chats. TUI has no equivalent.

**Fix is frontend-only (TUI):** Backend fallback chain is correct — it already prefers an explicit `cwd_session` when provided. We just need to provide it.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/apps/cli/src/tui/transport.zig` | EDIT | Add `cwd` param to `buildSendBody` + `postSend`; JSON-escape it like `session_id`/`queue_message` |
| `src/apps/cli/src/tui/app.zig` | EDIT | Add `cwd: []const u8` to `Config` and `App`; dupe/free lifecycle |
| `src/apps/cli/src/tui_main.zig` | EDIT | Capture OS cwd at startup, populate `Config.cwd`, pass to `postSend`; add `--cwd` flag + env fallback |
| `src/apps/cli/src/tui/tdd_round2_test.zig` | EDIT | Update `buildSendBody` call sites (new arg) + add cwd-specific tests |
| `src/apps/cli/src/tui/transport_test.zig` (if exists) or inline tests in `transport.zig` | EDIT | Add `cwd_session` round-trip tests |
| `docs/superpowers/plans/2026-09-02-fix-nalar-tui-cwd-mismatch.md` | NEW | This plan |

No backend, migration, or desktop changes.

---

## Task 1 — Add `cwd` to `transport.buildSendBody` + `postSend`

**Why:** This is the wire-format bottleneck. Every TUI message flows through `buildSendBody`; fixing it first lets later tasks be tested in isolation.

### Steps

- [ ] Read `src/apps/cli/src/tui/transport.zig:99-117` and `src/apps/cli/src/tui/tdd_round2_test.zig:32-39` to confirm current signature.
- [ ] Write failing test in `src/apps/cli/src/tui/transport.zig` (or `tdd_round2_test.zig`):
  ```zig
  test "buildSendBody: cwd_session is JSON-escaped and round-trips" {
      const body = try transport.buildSendBody(testing.allocator, "s1", "hi", "/home/ginwa/my project");
      defer testing.allocator.free(body);
      const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
      defer parsed.deinit();
      try testing.expectEqualStrings("/home/ginwa/my project", parsed.value.object.get("cwd_session").?.string);
  }
  test "buildSendBody: cwd with quote and backslash is escaped" {
      const body = try transport.buildSendBody(testing.allocator, "s1", "hi", "/tmp/a\"b\\c");
      defer testing.allocator.free(body);
      const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
      defer parsed.deinit();
      try testing.expectEqualStrings("/tmp/a\"b\\c", parsed.value.object.get("cwd_session").?.string);
  }
  test "buildSendBody: empty cwd still produces valid JSON with empty cwd_session" {
      const body = try transport.buildSendBody(testing.allocator, "s1", "hi", "");
      defer testing.allocator.free(body);
      const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
      defer parsed.deinit();
      try testing.expectEqualStrings("", parsed.value.object.get("cwd_session").?.string);
  }
  ```
- [ ] Run `zig build test:tui --summary all` — expect 3 failures (function still takes 2 args).
- [ ] Edit `transport.zig`:
  - Change `pub fn buildSendBody(allocator, session_id, message) ![]u8` → `pub fn buildSendBody(allocator, session_id, message, cwd: []const u8) ![]u8`
  - Replace the hardcoded `",\"cwd_session\":\"\","` fragment with proper JSON escaping:
    ```zig
    try w.writeAll(",\"cwd_session\":");
    try std.json.Stringify.encodeJsonString(cwd, .{}, w);
    try w.writeAll(",\"image_urls\":\"\",\"selected_profile_model\":\"\",\"is_auto_retry_until_stop\":\"\"}");
    ```
  - Change `pub fn postSend(allocator, client, server, session_id, message)` → `pub fn postSend(allocator, client, server, session_id, message, cwd: []const u8)` and forward `cwd` to `buildSendBody`.
- [ ] Run `zig build test:tui --summary all` — new tests pass; old tests in `tdd_round2_test.zig` now fail (they call `buildSendBody` with 3 args).
- [ ] Update `tdd_round2_test.zig:33` call site to pass `""` as 4th arg (preserves existing expectation that default cwd is empty).
- [ ] Run `zig build test:tui --summary all` — all pass.
- [ ] Commit: `fix(tui): transport sends cwd_session from caller instead of hardcoding ""`

---

## Task 2 — Add `cwd` to `App.Config` and `App`

**Why:** `App` is the long-lived model that owns the session id and HTTP client. Storing cwd there makes it available to `sendAndTrack` without re-reading the OS on every keystroke.

### Steps

- [ ] Read `src/apps/cli/src/tui/app.zig:31-34` (`Config` struct) and `36-91` (`App` struct + `init`/`deinit`).
- [ ] Write failing test in `src/apps/cli/src/tui/app.zig`:
  ```zig
  test "App: Config cwd defaults to empty" {
      const cfg = app_mod.Config{};
      try testing.expectEqualStrings("", cfg.cwd);
  }
  test "App: init dupes cwd from Config" {
      var app = try App.init(testing.allocator, undefined, .{ .server = "http://test", .cwd = "/tmp/proj" });
      defer app.deinit();
      try testing.expectEqualStrings("/tmp/proj", app.cwd);
  }
  ```
- [ ] Run `zig build test:tui --summary all` — expect failures (no `cwd` field).
- [ ] Edit `app.zig`:
  - Add `cwd: []const u8 = ""` to `Config` (line 31-34).
  - Add `cwd: []u8 = &[_]u8{}` or `?[]u8` to `App` (choose `[]u8` owned slice; empty means "no cwd / sandbox fallback"). Prefer `cwd: ?[]u8 = null` to distinguish "not set" from "explicitly empty" — but `""` already means sandbox fallback, so `[]u8` with `""` sentinel is fine. Use `cwd: []u8 = &[_]u8{}` and dupe on init.
  - In `App.init`, if `cfg.cwd.len > 0` then `app.cwd = try allocator.dupe(u8, cfg.cwd)` else leave empty.
  - In `App.deinit`, if `app.cwd.len > 0` then `allocator.free(app.cwd)`.
  - Update `status.setRight` or add a debug line if useful (optional — not required for fix).
- [ ] Run `zig build test:tui --summary all` — new tests pass.
- [ ] Commit: `fix(tui): App.Config/App carry cwd from startup`

---

## Task 3 — Capture OS cwd at startup and wire through `tui_main`

**Why:** This is the user-visible fix. The TUI process's cwd at launch IS the project directory the user expects the agent to see.

### Steps

- [ ] Read `src/apps/cli/src/tui_main.zig:37-95` (arg parsing + `App.init` + `execCmd`).
- [ ] Write a helper test (or manual check) for cwd capture:
  - The helper should call `std.Io.Dir.cwd().realPathAlloc` and verify it returns an absolute path.
  - No need for a full integration test — the unit test for `transport` already covers the wire format.
- [ ] Edit `tui_main.zig`:
  - Add `--cwd <path>` flag parsing alongside `--server`/`--session`/`--profile` (lines 48-69). Store in `var flag_cwd: ?[]const u8 = null`.
  - After env fallbacks (line 71-77), resolve `effective_cwd`:
    ```zig
    // Priority: --cwd flag > NALARCLI_CWD env > OS cwd > "" (sandbox fallback)
    var effective_cwd: []const u8 = "";
    if (flag_cwd) |v| {
        effective_cwd = v;
    } else if (env.get("NALARCLI_CWD")) |v| {
        if (v.len > 0) effective_cwd = v;
    } else {
        // Capture OS cwd. Use realPathAlloc to get absolute path.
        // On failure (e.g., cwd deleted), fall back to "" → sandbox.
        effective_cwd = std.Io.Dir.cwd().realPathAlloc(io, ".", allocator) catch "";
        // Note: if realPathAlloc allocates, we need to keep it alive for App's lifetime.
        // Since allocator is the process arena (lives for whole process), no free needed.
        // Alternatively, dupe into arena explicitly.
    }
    // Validate: must be absolute when non-empty; if not absolute, fall back to "".
    if (effective_cwd.len > 0 and !std.fs.path.isAbsolute(effective_cwd)) {
        effective_cwd = "";
    }
    cfg.cwd = effective_cwd;
    ```
  - Update `sendAndTrack` (line 110-133) to pass `model.cwd` (or `model.cfg.cwd` / `model.cwd` depending on Task 2's field name) to `transport.postSend`:
    ```zig
    const resp = transport.postSend(model.allocator, &model.http_client, model.cfg.server, session_id, msg_text, model.cwd) catch {
    ```
  - Update `usage()` text to document `--cwd` (optional but helpful).
- [ ] Handle the `realPathAlloc` allocation lifetime: `init.arena.allocator()` lives for the whole process, so the slice is valid for `App`'s lifetime without extra dupe. If `App.init` dupes it again (Task 2), that's fine — double ownership is safe (arena will free on exit, App will free its dupe on deinit). Document this.
- [ ] Run `zig build test:tui --summary all` — all pass.
- [ ] Manual smoke test (no live server needed for wire check):
  ```bash
  zig build install:tui
  ./zig-out/bin/nalar-tui --help | grep -q "\-\-cwd" && echo "help ok"
  # Verify buildSendBody with cwd produces correct JSON (already unit-tested)
  ```
- [ ] Commit: `fix(tui): capture OS cwd at startup and send as cwd_session`

---

## Task 4 — Update existing tests and add regression coverage

**Why:** The `tdd_round2_test.zig` expectation for `buildSendBody` hardcodes `cwd_session:""` — it must be updated to pass the new arg. Add a regression test that would have caught the original bug.

### Steps

- [ ] Read `src/apps/cli/src/tui/tdd_round2_test.zig:32-39` — the "plain message round-trips" test expects `cwd_session:""` in the JSON literal.
- [ ] Update that test to call `buildSendBody(allocator, "session-1", "hi", "")` (4 args) — expectation stays `cwd_session:""` so it still passes.
- [ ] Add regression test that documents the bug:
  ```zig
  test "buildSendBody: non-empty cwd is sent as cwd_session (regression: tui always sent empty)" {
      // Before the fix, nalar-tui always sent cwd_session="" even when
      // launched from a project directory. The agent then fell back to
      // createSandbox → ~/.local/share/nalar/data/apps/session-... (empty).
      // This test locks in that a non-empty cwd reaches the wire.
      const body = try transport.buildSendBody(testing.allocator, "session-1", "hi", "/home/ginwa/my-project");
      defer testing.allocator.free(body);
      const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
      defer parsed.deinit();
      try testing.expectEqualStrings("/home/ginwa/my-project", parsed.value.object.get("cwd_session").?.string);
  }
  ```
- [ ] Run `zig build test:tui --summary all` — all pass.
- [ ] Run `zig build test --summary all` — full suite passes (no regressions).
- [ ] Commit: `test(tui): update buildSendBody expectations for cwd param + regression test`

---

## Task 5 — Functional verification (isolated harness)

**Why:** Unit tests prove the JSON wire format; a functional test proves the end-to-end `POST /api/llm/session` → `sessions.cwd` → agent prompt chain.

### Steps

- [ ] Write `tests/functional/tui_cwd_test.py` using `tests/functional/harness.py` (isolated tmp HOME, free port, no 8081):
  ```python
  def test_tui_cwd_reaches_backend(harness):
      # Simulate what nalar-tui now does: POST with cwd_session="/tmp/my-proj"
      # Verify the session row's cwd is "/tmp/my-proj" (not sandbox)
      # and that GET /api/llm/session/:id/messages shows the cwd in the system prompt
      # (or at least that the session's cwd column is correct).
  def test_tui_empty_cwd_falls_back_to_sandbox(harness):
      # POST with cwd_session="" → session cwd should be sandbox path
      # (contains ".local/share/nalar/data/apps")
  ```
  - Use `harness.post("/api/llm/session", json={"session_id": "session-test-123", "queue_message": "hi", "cwd_session": "/tmp/proj", ...})`
  - Query `GET /api/llm/session/test-123` or check DB via `harness.db_query` if available; otherwise verify via the session list endpoint.
  - Keep the test minimal — the harness already isolates HOME and port.
- [ ] Run `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/tui_cwd_test.py -v` — expect 2 pass.
- [ ] Run `zig build test --summary all` + `zig build nalar-desktop --summary all` — no regressions.
- [ ] Commit: `test(functional): tui cwd reaches backend as cwd_session`

---

## Task 6 — Docs and cleanup

### Steps

- [ ] Update `src/apps/cli/README.md` (if it has a nalar-tui section) to mention `--cwd` and the auto-detected cwd behavior.
- [ ] Verify `NALAR.md` or `AGENTS.md` doesn't need a changelog entry (optional — the plan's commit history is the changelog).
- [ ] Run `zig build nalar-desktop --summary all` and `pnpm test:unit` (if frontend touched — it isn't) to confirm no cross-cutting break.
- [ ] Final `git log --oneline -10` review — 5-6 commits, each with a clear message.

---

## Pitfalls

- **Zig 0.16 `realPathAlloc` signature:** It takes `(io: std.Io, path: []const u8, allocator: Allocator) ![]u8` — not the old `std.fs.cwd().realpathAlloc`. Check `src/ai_workflow/tui/agentic_loop/prompts_make_working_directory_context.zig:29` for the correct call shape: `std.Io.Dir.cwd().realPathFileAlloc(io, effective_cwd, allocator)`. For TUI startup, `std.Io.Dir.cwd().realPathAlloc(io, ".", allocator)` is the right form — verify against `std.Io.Dir` docs.
- **Arena lifetime:** `init.arena.allocator()` lives for the whole process, so a slice allocated there is valid for `App`'s lifetime. But `App.deinit` will `free` its duped copy — don't double-free the arena slice. Either (a) let `App.init` dupe and keep the arena slice alive (harmless leak, arena dies on exit) or (b) have `tui_main` dupe into a separate allocation. Option (a) is simpler.
- **Empty cwd vs sandbox:** `""` is a valid sentinel meaning "use sandbox". Don't normalize `""` to `"."` or `"/"` — the backend's `if (cwd_session.len > 0)` check depends on empty meaning "no override".
- **Absolute path check:** `std.fs.path.isAbsolute("")` is false, so the `if (effective_cwd.len > 0 and !isAbsolute(...))` guard correctly leaves `""` as sandbox fallback. Don't add a separate `effective_cwd.len == 0` branch that tries to make it absolute.
- **Resuming sessions:** If the user runs `nalar-tui --session session-old` from a different directory, the new cwd will be sent for the next message. This changes the session's effective cwd for that run. That's intentional — the user's current shell location is the best signal. If we want to preserve the original session's cwd on resume, we'd need to `GET /api/llm/session/:id` first and only send cwd when the session is new. V1 keeps it simple: always send current cwd. A follow-up can add "only send cwd on session creation" if users report surprise.

---

## Verification

- [ ] `zig build test:tui --summary all` — all TUI unit tests pass (including new cwd tests)
- [ ] `zig build test --summary all` — full backend suite passes (no regressions)
- [ ] `zig build nalar-desktop --summary all` — desktop build still succeeds
- [ ] `NALAR_BIN=... python3 -m pytest tests/functional/tui_cwd_test.py -v` — 2/2 pass (cwd reaches backend, empty falls back to sandbox)
- [ ] Manual: `zig build install:tui && ./zig-out/bin/nalar-tui --help` shows `--cwd` flag
- [ ] Manual: launch `nalar-tui` from a temp dir with a real backend, send "list files in cwd", verify agent lists the temp dir's contents (not the sandbox)

