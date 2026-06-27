# Git Worktree CWD Display + Clickable Dropdown (Create PR etc.)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the chat status bar's git branch indicator (currently a read-only `<div>` showing `🌿 main ✓` at `src/apps/desktop/src/components/ChatView.vue:2286-2301`) worktree-aware and clickable. When a session has a bound worktree (`sessions.git_worktree_cwd IS NOT NULL`), show the worktree's branch (not the session's original `cwd` branch), display the worktree's path basename beside the branch name with a tooltip showing the full path, and open a dropdown menu when the user clicks the indicator. The dropdown contains actions: **Create a PR**, **View in folder**, **Clear worktree**.

**Architecture:**
- **Backend (Zig):** Two new HTTP endpoints — `GET /api/git/worktree/info?path=<worktree_path>` (returns branch, last commit, base-branch detection, commits-ahead count, draft PR title/body) and `POST /api/git/pr` (runs `gh pr create --base <base> --title <title> --body <body>` in the worktree path and returns the PR URL). One small extension to `getSessionMessagesSorted`/`SessionMessageResponse` so the chat-history response carries `git_worktree_cwd` for the frontend.
- **Frontend (Vue 3):** Add a `git_worktree_cwd` ref to `ChatView.vue`, compute `effectiveCwd = git_worktree_cwd || cwd`, route the git-status call through `effectiveCwd` so the branch display reflects the worktree. Replace the status-bar `<div>` with a clickable `<button>` that opens a dropdown (mirroring the `showProfilePicker` pattern at `ChatView.vue:2187-2251`). Add a `CreatePrDialog.vue` component that pre-fills title/body from the worktree-info endpoint and submits to `POST /api/git/pr`.

**Tech Stack:** Vue 3 + TypeScript + Vite + Bun. Vitest + @vue/test-utils + jsdom. Zig 0.16 + `std.Io.Threaded`. Git CLI + `gh` CLI (for PR creation). No new dependencies.

---

## Current state (verified by exploration)

| Component | Status | Reference |
|---|---|---|
| `set_git_worktree` tool | ✅ Exists | `src/modules/agent/tools/set_git_worktree.zig` |
| `sessions.git_worktree_cwd` column | ✅ Migration 046 | `src/ai_workflow/tui/migration.zig` |
| `ChatsList.vue` 🌳 badge | ✅ Exists | `src/apps/desktop/src/components/ChatsList.vue:508-514` |
| `ChatView.vue` branch status bar | ❌ Shows session's original `cwd` branch (not worktree's) | `src/apps/desktop/src/components/ChatView.vue:2286-2301` |
| Clickable branch / dropdown | ❌ Not clickable | — |
| Worktree path display | ❌ Not shown | — |
| "Create PR" feature | ❌ Does not exist | — |
| `cwd_override` runtime override | ❌ Dead-letter (separate plan) | `docs/plans/2026-06-18-set-git-worktree-cwd-override.md` |
| `getChatHistory` returns `git_worktree_cwd` | ❌ Missing | `src/apps/desktop/src/api/index.ts:428-498` |

## Design decisions locked during brainstorming

1. **Worktree-aware git status.** When `git_worktree_cwd` is set, the status bar displays the **worktree's** branch and the worktree's `git status` output (not the session's original `cwd`). The frontend computes `effectiveCwd = git_worktree_cwd || cwd` and passes it to `getGitStatus`. The session's original `cwd` is preserved as the fallback when no worktree is bound.

2. **Clickable indicator, dropdown layout.** The status indicator becomes a `<button>` (mirroring the profile-selector pattern at `ChatView.vue:2188-2211`) with a `<div class="absolute bottom-full mb-2 left-0">` dropdown panel (mirroring `ChatView.vue:2212-2250`). The dropdown items are: **Create a PR**, **View in folder**, **Clear worktree**. Each item is its own `<button>` with `hover:opacity-80` styling.

3. **Worktree path display.** When a worktree is bound, show `🌿 main  ·  🌳 auth-fix` in the status bar. The `🌳 auth-fix` text is the basename of `git_worktree_cwd`. A `:title` attribute exposes the full path as a native tooltip (matches the ChatsList badge pattern at line 511).

4. **Dropdown actions — direct API vs. LLM-mediated.** Mixed approach:
   - **Create a PR** → direct API call to `POST /api/git/pr` (no LLM round-trip; the user's intent is clear from the dialog form).
   - **View in folder** → direct UI action that calls the existing `/api/system/folder?path=<worktree_path>&action=list` endpoint to confirm the directory is accessible, then opens a folder-explorer modal (or invokes the system file manager via a new endpoint — implementation detail deferred to the chunk).
   - **Clear worktree** → POSTs a system-style message to the LLM via `POST /api/llm/session` asking it to call `set_git_worktree(clear=true)`. The LLM does the cleanup; the SSE event updates the UI. This re-uses the existing tool path and avoids duplicating the worktree-removal logic.

5. **Why LLM-mediated for "Clear worktree" instead of a direct endpoint?** The `set_git_worktree` tool already implements the worktree removal + DB update + (post-`cwd-override` plan) in-memory override clearing. A direct endpoint would duplicate that logic and risk drift. LLM-mediated is one extra round-trip but stays in the tool's audit trail.

6. **PR creation requires `gh` CLI.** The backend runs `gh pr create --base <base> --title <title> --body <body>` inside the worktree path. If `gh` is not installed, the endpoint returns a structured 500 with a clear error. We do NOT implement a `git push` + GitHub API call from scratch — `gh` is the right tool and is already required for the user's typical workflow.

7. **PR base branch detection.** Auto-detect by listing `git -C <worktree_path> branch -r` and preferring `origin/main` → `origin/master` → the first remote branch. The user can override in the dialog.

8. **YAGNI: out of scope for v1.** "Switch worktree" (re-bind to a different path via direct API), "Open worktree in a new tab", "Compare with base branch visually" (a diff viewer), and "Manage worktree list" (list all worktrees in the dropdown) are out of scope. Add them later if needed. The 3 actions above cover the user's stated need.

9. **Static-test pattern follows `set_git_worktree_test.zig`.** The project's established convention (per the NALAR.md memory `nalar-http-handler-thin-wrapper-pattern`) is static source-check tests that grep the handler source for required substrings. New endpoints follow the same pattern — no behavioral handler tests.

10. **Frontend tests use vitest + jsdom.** The pattern from `chatsListGitWorktree.spec.ts` (vue-test-utils mount + vi.mock for vue-router + vi.spyOn for API mocks) is reused for the new components.

11. **Auto-fill button in the PR dialog header.** The dialog has a small `↻ Auto-fill` button (icon + text) in the modal header, between the dialog title and the close button. Clicking it re-fetches `getGitWorktreeInfo` and overwrites BOTH `title` (from the latest commit subject) and `body` (from the diff shortstat against the **current base branch value** — not the original default). This is useful when:
    - (a) The user changed the base branch and wants the body regenerated against the new base
    - (b) The worktree has new commits since the dialog was opened (e.g. the LLM kept working while the dialog was open)
    - (c) The user manually edited the title/body and wants to revert to the auto-generated version

    No confirmation dialog — the user explicitly clicked the button, so overwriting is expected. A small spinner appears on the button while the request is in flight (mirrors the submit button's loading pattern). The button is disabled while `isSubmitting` is true (don't fight with the submit). Initial pre-fill on mount is unchanged — the button is the explicit way to refresh later.

12. **`getGitWorktreeInfo` re-fetches against the current base branch.** When the user changes the base branch input from `main` to `feature-y` and clicks Auto-fill, the backend needs to return a diff against `feature-y`, not `origin/main`. Implementation: add an optional `?base=<branch>` query parameter to `GET /api/git/worktree/info`. If `base` is missing, the endpoint uses the auto-detected default (today's behavior). If present, all `commits_ahead` / `diff_summary` / `draft_body` calculations use `origin/<base>` instead of `origin/<default>`. The frontend passes `base=<current_base_input.value>` on the regenerate click.

---

## File structure

### New files

```
src/ai_workflow/tui/http_handlers/
├── git_worktree_info.zig                GET /api/git/worktree/info
├── git_worktree_info_test.zig           static + behavioral tests
├── git_pr_create.zig                    POST /api/git/pr
└── git_pr_create_test.zig               static + behavioral tests

src/apps/desktop/src/
├── components/
│   ├── WorktreeMenu.vue                 dropdown component (extracted for testability)
│   └── CreatePrDialog.vue               "Create a PR" dialog
└── __tests__/
    ├── chatViewWorktree.spec.ts         component tests for the worktree-aware status bar
    ├── worktreeMenu.spec.ts             dropdown open/close/menu-click tests
    └── createPrDialog.spec.ts           dialog open/submit/error tests
```

### Modified files

```
src/ai_workflow/tui/
├── http_handlers/
│   ├── mod.zig                          export new handlers
│   └── http_response.zig                add GitWorktreeInfoResponse + GitPrCreateResponse + extend SessionMessageResponse with git_worktree_cwd
├── llm_history.zig                      return git_worktree_cwd from getSession/getSessionMessagesSorted
├── test_runner.zig                      register git_worktree_info_test.zig + git_pr_create_test.zig
└── migration.zig                        (no change — column already exists from Migration 046)

src/main.zig                             register 2 new routes: GET /api/git/worktree/info, POST /api/git/pr

src/apps/desktop/src/
├── api/index.ts                         add getGitWorktreeInfo + createGitPr; extend getChatHistory with git_worktree_cwd
└── components/
    └── ChatView.vue                     add git_worktree_cwd ref, effectiveCwd computed, make branch button clickable, integrate WorktreeMenu + CreatePrDialog
```

---

## Verification commands (run throughout)

```bash
# Backend
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 20
# Expected: test success; count grows by 4-8 from the new tests (2 backend × 2-4 each, frontend component tests counted separately).

# Frontend type-check + build (NOT just vitest — see memory desktop-typescript-bun-build-as-typecheck.md)
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
# Expected: clean. No TS errors, no vue-tsc errors.

# Frontend unit tests
timeout 120 bunx vitest run 2>&1 | tail -n 20
# Expected: all pass; new specs for worktree menu, PR dialog, ChatView worktree display.

# Manual smoke test
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build install:linux:system 2>&1 | tail -n 5
nohup ./zig-out/bin/nalar --port 8080 > /tmp/nalar-smoke.log 2>&1 &
# 1) Open a session whose cwd is inside a git repo (any local repo).
# 2) Verify the status bar shows 🌿 <branch> ✓ (unchanged behavior — no worktree bound).
# 3) Send the message: "use set_git_worktree to bind a worktree at /tmp/worktrees/feature-x"
# 4) Wait for the LLM to complete the tool call. Verify the status bar now shows 🌿 <worktree-branch> · 🌳 feature-x with a hover tooltip.
# 5) Click the status bar. The dropdown opens with 3 items: "Create a PR", "View in folder", "Clear worktree".
# 6) Click "Create a PR". The dialog opens with title and body pre-filled.
# 7) Edit the title if desired, click "Create". Verify a PR is created (the dialog shows the PR URL).
# 8) Click "View in folder". Verify a folder browser modal opens at the worktree path.
# 9) Click "Clear worktree" (in a new session — don't clear the worktree you just used for PR creation). The LLM processes the request, the status bar reverts to 🌿 <original-branch> (no 🌳 suffix).
```

---

## Chunk 1: Extend `getChatHistory` to return `git_worktree_cwd`

The chat-history response carries the session's `git_worktree_cwd` so the frontend can show the worktree in the status bar from the moment the chat loads. Mirrors how `cwd` is already returned (see `llm_history.zig` SELECT at line 1802 / `session_messages_get.zig:91`).

- [ ] **Step 1.1: Read `llm_history.zig` lines 1790-1820 to understand the current `getSession`/`getSessionMessagesSorted` SELECT**

Run: `rg -n "getSessionMessagesSorted|getSession\b" /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/ai_workflow/tui/llm_history.zig | head -n 20`
Expected: find the function that returns `SessionMessageResponse`. Note that it already includes `cwd` (line 1802 SELECT).

- [ ] **Step 1.2: Add `git_worktree_cwd: []const u8 = ""` field to the response struct in `llm_history.zig`**

Find the response struct (search for `cwd: []const u8` near line 1802). Add the new field right after `cwd`:

```zig
pub const SessionMessageResponse = struct {
    // ... existing fields ...
    cwd: []const u8 = "",
    git_worktree_cwd: []const u8 = "",  // NEW
    // ...
};
```

Use `[]const u8 = ""` (default empty string) so existing call sites that construct a `SessionMessageResponse` literal don't break.

- [ ] **Step 1.3: Extend the SELECT in `getSession` to include `git_worktree_cwd`**

The current SELECT (line 1802) returns the session's `cwd` and other fields. Add `COALESCE(s.git_worktree_cwd, '')` to the column list. Update the row→struct mapping to populate the new field. Pattern (do not copy verbatim — adjust to the local variable names):

```zig
// In the row-decode loop:
.git_worktree_cwd = try allocator.dupe(u8, row.values[N]),  // N = the index of the new column
```

Use `try allocator.dupe(u8, ...)` so the response owns its memory and the deinit path can free it.

- [ ] **Step 1.4: Extend the same SELECT in `getSessionMessagesSorted`**

`getSessionMessagesSorted` is the function actually called by `sessionMessagesHandler` (see `session_messages_get.zig:49`). It must also populate `git_worktree_cwd` on the response. Follow the same pattern as Step 1.3.

- [ ] **Step 1.5: Extend `http_response.zig`'s `SessionMessageResponse` (or `SessionMessagesResponse`) with `git_worktree_cwd`**

Find the response type in `http_response.zig` (search for `cwd_session` or `SessionMessagesResponse`). The chain is:
- `llm_history.SessionMessageResponse.git_worktree_cwd` → copied in `session_messages_get.zig:87-96` (the handler builds an `http_resp`) → JSON-serialized by `makeSessionMessagesResponse`.

The `http_resp` is currently built as:
```zig
const http_resp = http_response.SessionMessagesResponse{
    .messages = messages,
    .has_more = msg_response.has_more,
    .next_cursor = msg_response.next_cursor,
    .cwd = msg_response.cwd,
    .skills = msg_response.skills,
    // ...
};
```

Add `.git_worktree_cwd = msg_response.git_worktree_cwd,` to this struct literal.

Add the matching field to `http_response.SessionMessagesResponse`:
```zig
pub const SessionMessagesResponse = struct {
    // ... existing fields ...
    cwd: []const u8 = "",
    git_worktree_cwd: []const u8 = "",  // NEW
    // ...
};
```

- [ ] **Step 1.6: Update `makeSessionMessagesResponse` in `http_response.zig` to emit the new field**

Find the function (search for `makeSessionMessagesResponse`). It uses `std.json.Stringify.valueAlloc` to serialize. The struct-literal `SessionMessagesResponse` is the type; once the new field is on the struct, the serializer emits it automatically. **No code change needed inside the function body** — just verify the new field appears in the JSON output.

- [ ] **Step 1.7: Verify the test suite still passes**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success` with the same test count as before. The change is additive (a new optional field with default `""`).

- [ ] **Step 1.8: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/llm_history.zig src/ai_workflow/tui/http_handlers/http_response.zig src/ai_workflow/tui/http_handlers/session_messages_get.zig
git commit -m "feat(api): return git_worktree_cwd from getChatHistory"
```

---

## Chunk 2: Backend — `GET /api/git/worktree/info` endpoint

Returns worktree metadata that the frontend "Create PR" dialog uses to pre-fill the form.

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/git_worktree_info.zig`
- Create: `src/ai_workflow/tui/http_handlers/git_worktree_info_test.zig`
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig`
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig`
- Modify: `src/main.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 2.1: Read the existing `git_status.zig` handler to understand the pattern**

The new handler follows the same pattern: parse query, run `git` command, parse output, return JSON response. See `src/ai_workflow/tui/http_handlers/git_status.zig` lines 1-68.

- [ ] **Step 2.2: Write the failing test for `gitWorktreeInfoHandler`**

Create `src/ai_workflow/tui/http_handlers/git_worktree_info_test.zig`. Pattern from `set_git_worktree_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/git_worktree_info.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
const HTTP_RESP_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

test "git_worktree_info handler is exported from mod.zig" {
    const source = try readSource(testing.allocator, MOD_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const gitWorktreeInfoHandler") == null) {
        std.debug.print("!! mod.zig does not export gitWorktreeInfoHandler !!\n", .{});
        return error.GitWorktreeInfoExportMissing;
    }
}

test "git_worktree_info route is registered in main.zig" {
    const source = try readSource(testing.allocator, MAIN_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "/api/git/worktree/info") == null) {
        std.debug.print("!! main.zig does not register /api/git/worktree/info !!\n", .{});
        return error.GitWorktreeInfoRouteMissing;
    }
}

test "http_response.zig defines GitWorktreeInfoResponse struct" {
    const source = try readSource(testing.allocator, HTTP_RESP_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "GitWorktreeInfoResponse") == null) {
        std.debug.print("!! http_response.zig does not define GitWorktreeInfoResponse !!\n", .{});
        return error.GitWorktreeInfoResponseTypeMissing;
    }
}
```

- [ ] **Step 2.3: Run test to verify it fails**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: failures on `error.GitWorktreeInfoExportMissing`, `error.GitWorktreeInfoRouteMissing`, `error.GitWorktreeInfoResponseTypeMissing` (the test file imports correctly but the source it greps for doesn't exist yet).

- [ ] **Step 2.4: Create the handler file `git_worktree_info.zig`**

```zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

/// Git worktree info endpoint — returns branch, last commit, base-branch
/// auto-detection, and a draft PR title/body for the worktree at `path`.
///
/// Query: ?path=<absolute_worktree_path>
///
/// Returns:
///   {
///     "is_git_repo": true,
///     "branch": "worktree/feature-x",
///     "last_commit_sha": "abc1234",
///     "last_commit_msg": "Add feature x",
///     "default_base": "main",        // first of origin/main, origin/master, origin/develop
///     "commits_ahead": 3,
///     "diff_summary": " 3 files changed, 42 insertions(+), 7 deletions(-)",
///     "draft_title": "Add feature x",
///     "draft_body": "## Summary\n\n- Change 1\n- Change 2\n"
///   }
pub fn gitWorktreeInfoHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const path_param = req.query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing path parameter" }) });
    };

    // Optional ?base=<branch> override. When present, the diff + commit
    // count are calculated against `origin/<base>` instead of the
    // auto-detected default. The frontend passes this on the
    // regenerate button click in CreatePrDialog.
    const explicit_base_param = req.query.get("base");

    // 1) Confirm it's a git repo
    const git_dir_check = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "rev-parse", "--git-dir" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, @errorName(err)) });
    };
    if (git_dir_check.term.exited != 0) {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "not a git repository" }) });
    }

    // 2) Current branch
    const branch_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "branch", "--show-current" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, @errorName(err)) });
    };
    const branch = std.mem.trim(u8, branch_result.stdout, " \n\r");

    // 3) Last commit (short SHA + subject)
    const log_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "log", "-1", "--format=%h %s" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, @errorName(err)) });
    };
    const log_line = std.mem.trim(u8, log_result.stdout, " \n\r");
    var last_sha: []const u8 = "";
    var last_msg: []const u8 = "";
    if (std.mem.indexOf(u8, log_line, " ")) |space_idx| {
        last_sha = log_line[0..space_idx];
        last_msg = log_line[space_idx + 1 ..];
    }

    // 4) Default base branch — try origin/main, origin/master, origin/develop in order.
    // If the `?base=` query param was supplied, use it directly and skip
    // auto-detection (the user has already chosen the base).
    var default_base: []const u8 = "main";
    if (explicit_base_param) |eb| {
        default_base = eb;
    } else {
        const bases = [_][]const u8{ "main", "master", "develop" };
        for (bases) |b| {
            const probe = std.process.run(allocator, io, .{
                .argv = &.{ "git", "-C", path_param, "rev-parse", "--verify", "origin/" ++ b },
            }) catch continue;
            if (probe.term.exited == 0) {
                default_base = b;
                break;
            }
        }
    }

    // 5) Commits ahead (against `default_base`, which may have been overridden by ?base=)
    var commits_ahead: i64 = 0;
    const ahead_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "rev-list", "--count", "origin/" ++ default_base ++ "..HEAD" },
    }) catch null;
    if (ahead_result) |ar| {
        if (ar.term.exited == 0) {
            commits_ahead = std.fmt.parseInt(i64, std.mem.trim(u8, ar.stdout, " \n\r"), 10) catch 0;
        }
    }

    // 6) Diff summary against `default_base`
    var diff_summary: []const u8 = "";
    const diff_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "diff", "--shortstat", "origin/" ++ default_base ++ "..HEAD" },
    }) catch null;
    if (diff_result) |dr| {
        if (dr.term.exited == 0) {
            diff_summary = std.mem.trim(u8, dr.stdout, " \n\r");
        }
    }

    // 7) Draft title = last commit subject. Draft body = "## Summary\n\n<diff shortstat>\n\nCommits ahead: N\n"
    const draft_title = last_msg;
    const draft_body = try std.fmt.allocPrint(allocator, "## Summary\n\n{s}\n\nCommits ahead: {d}\n", .{ diff_summary, commits_ahead });

    const response = http_response.GitWorktreeInfoResponse{
        .is_git_repo = true,
        .branch = branch,
        .last_commit_sha = last_sha,
        .last_commit_msg = last_msg,
        .default_base = default_base,
        .commits_ahead = commits_ahead,
        .diff_summary = diff_summary,
        .draft_title = draft_title,
        .draft_body = draft_body,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitWorktreeInfoResponse(allocator, response) });
}
```

- [ ] **Step 2.5: Add `GitWorktreeInfoResponse` struct + `makeGitWorktreeInfoResponse` helper in `http_response.zig`**

```zig
pub const GitWorktreeInfoResponse = struct {
    is_git_repo: bool = false,
    branch: []const u8 = "",
    last_commit_sha: []const u8 = "",
    last_commit_msg: []const u8 = "",
    default_base: []const u8 = "",
    commits_ahead: i64 = 0,
    diff_summary: []const u8 = "",
    draft_title: []const u8 = "",
    draft_body: []const u8 = "",
};

pub fn makeGitWorktreeInfoResponse(allocator: std.mem.Allocator, resp: GitWorktreeInfoResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, resp, .{});
}
```

- [ ] **Step 2.6: Export from `mod.zig`**

Add (alphabetically near the other `git*` exports):
```zig
pub const gitWorktreeInfoHandler = @import("git_worktree_info.zig").gitWorktreeInfoHandler;
```

- [ ] **Step 2.7: Register the route in `main.zig`**

Add right after the existing `/api/git/status` route registration (line 294):
```zig
try gs.router.get("/api/git/worktree/info", ai_mod.http_handlers.gitWorktreeInfoHandler);
```

- [ ] **Step 2.8: Register the test file in `test_runner.zig`**

Find `src/ai_workflow/tui/test_runner.zig` and add (alphabetically):
```zig
_ = @import("http_handlers/git_worktree_info_test.zig");
```

- [ ] **Step 2.9: Run tests to verify they pass**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success`. The 3 new tests pass; test count increased by 3.

- [ ] **Step 2.10: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/git_worktree_info.zig src/ai_workflow/tui/http_handlers/git_worktree_info_test.zig src/ai_workflow/tui/http_handlers/mod.zig src/ai_workflow/tui/http_handlers/http_response.zig src/ai_workflow/tui/test_runner.zig src/main.zig
git commit -m "feat(api): add GET /api/git/worktree/info endpoint"
```

---

## Chunk 3: Backend — `POST /api/git/pr` endpoint

Runs `gh pr create` in the worktree path and returns the PR URL. Surfaces structured errors for the 3 most common failure modes (no `gh`, no remote, branch not pushed).

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/git_pr_create.zig`
- Create: `src/ai_workflow/tui/http_handlers/git_pr_create_test.zig`
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig`
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig`
- Modify: `src/main.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 3.1: Write the failing test for `gitPrCreateHandler`**

Create `src/ai_workflow/tui/http_handlers/git_pr_create_test.zig`. Pattern:

```zig
test "git_pr_create handler is exported from mod.zig" { /* ... */ }
test "git_pr_create route is registered in main.zig" {
    // greps for "/api/git/pr"
}
test "http_response.zig defines GitPrCreateResponse" { /* ... */ }
test "git_pr_create body has worktree_path, base, title, body fields" {
    // greps the handler source for those field names
}
```

- [ ] **Step 3.2: Run test to verify it fails**

Expected: failures on the new error names (export missing, route missing, etc.).

- [ ] **Step 3.3: Create the handler file `git_pr_create.zig`**

```zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

/// Create a pull request on the worktree at `worktree_path`.
/// Body: { "worktree_path": "...", "base": "main", "title": "...", "body": "..." }
///
/// Runs `gh pr create --base <base> --title <title> --body <body>` in the
/// worktree path. Returns the PR URL on success, or a structured error.
pub fn gitPrCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Parse JSON body using the Leaky variant — see memory
    // nalar-http-handler-thin-wrapper-pattern.md.
    const Body = struct {
        worktree_path: []const u8 = "",
        base: []const u8 = "main",
        title: []const u8 = "",
        body: []const u8 = "",
    };
    const parsed = std.json.parseFromSliceLeaky(Body, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }) });
    };

    if (parsed.worktree_path.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "worktree_path is required" }) });
    }
    if (parsed.title.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "title is required" }) });
    }

    // Run `gh pr create --base <base> --title <title> --body <body>`.
    // Capture stdout (the PR URL) and stderr (error details).
    const argv = &[_][]const u8{
        "gh", "pr", "create",
        "--base",      parsed.base,
        "--title",     parsed.title,
        "--body",      parsed.body,
    };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = parsed.worktree_path },  // see memory zig-0.16-spawn-cwd-is-not-nullable.md
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        // `gh` not found → return a clear 500
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err), .hint = "is the gh CLI installed and on PATH?" }) });
    };

    // Read stdout + stderr in parallel (bounded to 64KB each, like
    // set_git_worktree.zig:160-190).
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    if (child.stdout) |pipe| {
        while (true) {
            const n = std.Io.File.readStreaming(pipe, io, &.{&read_buf}) catch break;
            if (n == 0) break;
            if (stdout_buf.items.len < 64 * 1024) {
                const take = @min(n, 64 * 1024 - stdout_buf.items.len);
                stdout_buf.appendSlice(allocator, read_buf[0..take]) catch break;
            }
        }
    }
    if (child.stderr) |pipe| {
        while (true) {
            const n = std.Io.File.readStreaming(pipe, io, &.{&read_buf}) catch break;
            if (n == 0) break;
            if (stderr_buf.items.len < 64 * 1024) {
                const take = @min(n, 64 * 1024 - stderr_buf.items.len);
                stderr_buf.appendSlice(allocator, read_buf[0..take]) catch break;
            }
        }
    }

    const term = child.wait(io) catch return error.GhWaitFailed;
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                // Surface the gh CLI error verbatim so the user can debug
                const response = http_response.GitPrCreateResponse{
                    .success = false,
                    .pr_url = "",
                    .error_message = try allocator.dupe(u8, std.mem.trim(u8, stderr_buf.items, " \n\r")),
                };
                return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitPrCreateResponse(allocator, response) });
            }
        },
        else => {
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "gh killed by signal" }) });
        },
    }

    // gh pr create prints the PR URL on stdout
    const pr_url = std.mem.trim(u8, stdout_buf.items, " \n\r");
    const response = http_response.GitPrCreateResponse{
        .success = true,
        .pr_url = pr_url,
        .error_message = "",
    };
    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitPrCreateResponse(allocator, response) });
}
```

- [ ] **Step 3.4: Add `GitPrCreateResponse` + `makeGitPrCreateResponse` in `http_response.zig`**

```zig
pub const GitPrCreateResponse = struct {
    success: bool = false,
    pr_url: []const u8 = "",
    error_message: []const u8 = "",
};

pub fn makeGitPrCreateResponse(allocator: std.mem.Allocator, resp: GitPrCreateResponse) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, resp, .{});
}
```

- [ ] **Step 3.5: Export from `mod.zig`**

```zig
pub const gitPrCreateHandler = @import("git_pr_create.zig").gitPrCreateHandler;
```

- [ ] **Step 3.6: Register the route in `main.zig`**

```zig
try gs.router.post("/api/git/pr", ai_mod.http_handlers.gitPrCreateHandler);
```

- [ ] **Step 3.7: Register the test file in `test_runner.zig`**

```zig
_ = @import("http_handlers/git_pr_create_test.zig");
```

- [ ] **Step 3.8: Run tests to verify they pass**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success`. Test count increased by 4 (2 from Chunk 2 + 2 from Chunk 3, plus the 2 from Chunk 1's source-check tests = 8 total, but Chunk 1 didn't add new tests — it only extended existing data flow).

- [ ] **Step 3.9: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/git_pr_create.zig src/ai_workflow/tui/http_handlers/git_pr_create_test.zig src/ai_workflow/tui/http_handlers/mod.zig src/ai_workflow/tui/http_handlers/http_response.zig src/ai_workflow/tui/test_runner.zig src/main.zig
git commit -m "feat(api): add POST /api/git/pr endpoint (gh pr create wrapper)"
```

---

## Chunk 4: Frontend — TypeScript API surface for the new endpoints

Add the TypeScript types and functions for `getGitWorktreeInfo` and `createGitPr`, and extend `getChatHistory` to expose `git_worktree_cwd`.

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 4.1: Extend the `getChatHistory` return type with `git_worktree_cwd`**

In `src/apps/desktop/src/api/index.ts` around line 432-441, the return-type object literal gets a new field:

```ts
export async function getChatHistory(
  sessionId: string,
  limit = 50,
  cursor?: string,
): Promise<{
  messages: Message[]
  has_more: boolean
  next_cursor: string | null
  cwd?: string
  git_worktree_cwd?: string  // NEW — empty string when no worktree is bound
  max_total_tokens?: number
  max_capacity_total_tokens?: number
  total_count?: number
  skills?: SkillInfo[]
}>
```

The function body's return object also gets the field:
```ts
return {
  // ... existing fields ...
  cwd: data.cwd,
  git_worktree_cwd: data.git_worktree_cwd,  // NEW
  // ...
}
```

The catch-block return gets the same new field (set to `undefined`).

- [ ] **Step 4.2: Add the `GitWorktreeInfo` interface**

Add after the existing `GitStatus` interface (around line 1067):

```ts
export interface GitWorktreeInfo {
  is_git_repo: boolean
  branch: string
  last_commit_sha: string
  last_commit_msg: string
  default_base: string
  commits_ahead: number
  diff_summary: string
  draft_title: string
  draft_body: string
}
```

- [ ] **Step 4.3: Add the `getGitWorktreeInfo` function**

Add right after `getGitStatus` (around line 1108):

```ts
export async function getGitWorktreeInfo(
  worktreePath: string,
  base?: string,
): Promise<GitWorktreeInfo> {
  try {
    const params = new URLSearchParams({ path: worktreePath })
    if (base && base.trim() !== '') {
      params.set('base', base)
    }
    const response = await fetch(`${API_BASE}/git/worktree/info?${params}`)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return response.json()
  } catch (error) {
    console.error('Failed to get git worktree info:', error)
    return {
      is_git_repo: false,
      branch: '',
      last_commit_sha: '',
      last_commit_msg: '',
      default_base: base || 'main',
      commits_ahead: 0,
      diff_summary: '',
      draft_title: '',
      draft_body: '',
    }
  }
}
```

The optional `base` parameter is forwarded as `?base=<branch>` to the backend (see design decision #12). When `base` is undefined or empty, the URL omits the param and the backend falls back to its own auto-detection.

- [ ] **Step 4.4: Add the `GitPrCreateResponse` interface + `createGitPr` function**

Add right after `getGitWorktreeInfo`:

```ts
export interface GitPrCreateResponse {
  success: boolean
  pr_url: string
  error_message: string
}

export async function createGitPr(
  worktreePath: string,
  base: string,
  title: string,
  body: string,
): Promise<GitPrCreateResponse> {
  const response = await fetch(`${API_BASE}/git/pr`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      worktree_path: worktreePath,
      base,
      title,
      body,
    }),
  })
  if (!response.ok) {
    const text = await response.text()
    throw new Error(`HTTP ${response.status}: ${text}`)
  }
  return response.json()
}
```

- [ ] **Step 4.5: Verify the type-check passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean. No TS errors. The new fields are optional, so existing call sites don't break.

- [ ] **Step 4.6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(api): add getGitWorktreeInfo + createGitPr; extend getChatHistory with git_worktree_cwd"
```

---

## Chunk 5: Frontend — `WorktreeMenu.vue` dropdown component

A standalone Vue component that renders the 3 dropdown items. Extracted from `ChatView.vue` for testability (vue-test-utils can mount this in isolation; the `ChatView.vue` mount path is much heavier).

**Files:**
- Create: `src/apps/desktop/src/components/WorktreeMenu.vue`

- [ ] **Step 5.1: Create the `WorktreeMenu.vue` component**

```vue
<script setup lang="ts">
/**
 * Dropdown menu for the worktree indicator in the chat status bar.
 * Three actions:
 *   - "Create a PR" — emits 'create-pr' so the parent opens CreatePrDialog
 *   - "View in folder" — emits 'view-folder' so the parent opens a folder browser
 *   - "Clear worktree" — emits 'clear' so the parent sends the LLM a system message
 *
 * The menu closes itself after any action via the parent's v-if binding.
 */
import { ref, onMounted, onUnmounted } from 'vue'

const emit = defineEmits<{
  (e: 'create-pr'): void
  (e: 'view-folder'): void
  (e: 'clear'): void
  (e: 'close'): void
}>()

const menuRef = ref<HTMLElement | null>(null)

const handleClickOutside = (e: MouseEvent) => {
  if (menuRef.value && !menuRef.value.contains(e.target as Node)) {
    emit('close')
  }
}

onMounted(() => {
  // Add a tick delay so the click that opened the menu doesn't immediately close it
  setTimeout(() => document.addEventListener('click', handleClickOutside), 0)
})
onUnmounted(() => {
  document.removeEventListener('click', handleClickOutside)
})

const onCreatePr = () => {
  emit('create-pr')
  emit('close')
}
const onViewFolder = () => {
  emit('view-folder')
  emit('close')
}
const onClear = () => {
  if (confirm('Clear the worktree binding? This removes the worktree directory and unbinds the session.')) {
    emit('clear')
    emit('close')
  }
}
</script>

<template>
  <div
    ref="menuRef"
    class="absolute bottom-full mb-2 left-0 min-w-[200px] rounded-lg shadow-lg z-20 overflow-hidden"
    style="
      background-color: var(--semantic-card-bg);
      border: 1px solid var(--color-border);
    "
  >
    <button
      data-testid="worktree-menu-create-pr"
      @click="onCreatePr"
      class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
      style="color: var(--semantic-text)"
    >
      <span>🔀</span>
      <span>Create a PR</span>
    </button>
    <button
      data-testid="worktree-menu-view-folder"
      @click="onViewFolder"
      class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
      style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
    >
      <span>📁</span>
      <span>View in folder</span>
    </button>
    <button
      data-testid="worktree-menu-clear"
      @click="onClear"
      class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
      style="color: var(--color-red); border-top: 1px solid var(--color-border)"
    >
      <span>🗑️</span>
      <span>Clear worktree</span>
    </button>
  </div>
</template>
```

- [ ] **Step 5.2: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/WorktreeMenu.vue
git commit -m "feat(ui): add WorktreeMenu dropdown component"
```

---

## Chunk 6: Frontend — `CreatePrDialog.vue` component

A modal dialog that pre-fills from the worktree info endpoint and submits to `POST /api/git/pr`.

**Files:**
- Create: `src/apps/desktop/src/components/CreatePrDialog.vue`

- [ ] **Step 6.1: Create the `CreatePrDialog.vue` component**

```vue
<script setup lang="ts">
/**
 * "Create a PR" dialog. Mounted by ChatView.vue when the user clicks
 * "Create a PR" in the WorktreeMenu.
 *
 * On mount, calls api.getGitWorktreeInfo(worktreePath) to pre-fill the
 * title and body. User can edit before clicking "Create". The submit
 * calls api.createGitPr(...) and emits 'pr-created' with the URL on
 * success or 'error' with the message on failure.
 */
import { ref, onMounted, computed } from 'vue'
import * as api from '../api'

const props = defineProps<{
  worktreePath: string
}>()

const emit = defineEmits<{
  (e: 'pr-created', url: string): void
  (e: 'error', message: string): void
  (e: 'close'): void
}>()

const base = ref('main')
const title = ref('')
const body = ref('')
const isSubmitting = ref(false)
const isLoading = ref(true)
const isRegenerating = ref(false)

onMounted(async () => {
  try {
    const info = await api.getGitWorktreeInfo(props.worktreePath)
    base.value = info.default_base || 'main'
    title.value = info.draft_title
    body.value = info.draft_body
  } catch (err) {
    emit('error', `Failed to load worktree info: ${err}`)
  } finally {
    isLoading.value = false
  }
})

// Re-fetch the worktree info against the CURRENT base branch value and
// overwrite title + body. See design decision #11 for why this is
// useful. Pass the current base explicitly so the diff is computed
// against whatever the user has typed (not the auto-detected default).
const onRegenerate = async () => {
  if (isRegenerating.value || isSubmitting.value) return
  isRegenerating.value = true
  try {
    const info = await api.getGitWorktreeInfo(props.worktreePath, base.value)
    title.value = info.draft_title
    body.value = info.draft_body
  } catch (err) {
    emit('error', `Failed to regenerate: ${err}`)
  } finally {
    isRegenerating.value = false
  }
}

const onSubmit = async () => {
  if (isSubmitting.value || title.value.trim() === '') return
  isSubmitting.value = true
  try {
    const resp = await api.createGitPr(props.worktreePath, base.value, title.value, body.value)
    if (resp.success) {
      emit('pr-created', resp.pr_url)
    } else {
      emit('error', resp.error_message || 'Unknown error from gh pr create')
    }
  } catch (err) {
    emit('error', `Failed to create PR: ${err}`)
  } finally {
    isSubmitting.value = false
  }
}

const onClose = () => {
  if (!isSubmitting.value) emit('close')
}
</script>

<template>
  <div
    class="fixed inset-0 z-50 flex items-center justify-center p-4"
    style="background-color: rgba(0, 0, 0, 0.5)"
    @click.self="onClose"
  >
    <div
      class="w-full max-w-2xl rounded-lg shadow-xl overflow-hidden"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      data-testid="create-pr-dialog"
    >
      <div
        class="px-4 py-3 flex items-center justify-between"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <h2 class="text-sm font-semibold" style="color: var(--semantic-text)">
          🔀 Create a pull request
        </h2>
        <div class="flex items-center gap-2">
          <!-- Auto-fill button: re-fetches worktree info against the
               CURRENT base branch value, overwrites title + body.
               Disabled while submitting (avoid race) or while a
               regenerate is already in flight (avoid double-fire). -->
          <button
            @click="onRegenerate"
            :disabled="isRegenerating || isSubmitting || isLoading"
            data-testid="create-pr-regenerate"
            title="Re-fill title and body from the latest commit and diff against the current base branch"
            class="px-2 py-1 text-xs rounded flex items-center gap-1.5"
            :class="
              isRegenerating || isSubmitting || isLoading
                ? 'opacity-50 cursor-not-allowed'
                : 'hover:opacity-80'
            "
            style="
              background-color: var(--semantic-card-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text-dim);
            "
          >
            <span
              v-if="isRegenerating"
              class="w-3 h-3 border-2 rounded-full animate-spin"
              style="border-color: var(--semantic-text-dim); border-top-color: transparent"
            ></span>
            <span v-else>↻</span>
            <span>Auto-fill</span>
          </button>
          <button
            @click="onClose"
            :disabled="isSubmitting"
            class="opacity-60 hover:opacity-100"
            style="color: var(--semantic-text)"
          >
            ✕
          </button>
        </div>
      </div>

      <div v-if="isLoading" class="px-4 py-8 text-center text-xs" style="color: var(--semantic-text-dim)">
        Loading worktree info...
      </div>

      <div v-else class="px-4 py-4 space-y-3">
        <div>
          <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text-dim)">
            Base branch
          </label>
          <input
            v-model="base"
            data-testid="create-pr-base"
            type="text"
            class="w-full px-2 py-1.5 text-xs rounded font-mono"
            style="
              background-color: var(--semantic-input-bg, var(--semantic-card-bg));
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            placeholder="main"
          />
        </div>
        <div>
          <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text-dim)">
            Title
          </label>
          <input
            v-model="title"
            data-testid="create-pr-title"
            type="text"
            class="w-full px-2 py-1.5 text-xs rounded"
            style="
              background-color: var(--semantic-input-bg, var(--semantic-card-bg));
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            placeholder="PR title"
          />
        </div>
        <div>
          <label class="block text-xs font-medium mb-1" style="color: var(--semantic-text-dim)">
            Body
          </label>
          <textarea
            v-model="body"
            data-testid="create-pr-body"
            rows="8"
            class="w-full px-2 py-1.5 text-xs rounded font-mono"
            style="
              background-color: var(--semantic-input-bg, var(--semantic-card-bg));
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            placeholder="Describe the changes..."
          ></textarea>
        </div>
      </div>

      <div
        class="px-4 py-3 flex items-center justify-end gap-2"
        style="border-top: 1px solid var(--color-border)"
      >
        <button
          @click="onClose"
          :disabled="isSubmitting"
          class="px-3 py-1.5 text-xs rounded"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
        >
          Cancel
        </button>
        <button
          @click="onSubmit"
          :disabled="isSubmitting || isLoading || title.trim() === ''"
          data-testid="create-pr-submit"
          class="px-3 py-1.5 text-xs font-medium rounded flex items-center gap-1.5"
          :class="
            isSubmitting || isLoading || title.trim() === ''
              ? 'opacity-50 cursor-not-allowed'
              : 'hover:opacity-80'
          "
          style="
            background-color: var(--color-violet);
            color: white;
          "
        >
          <span
            v-if="isSubmitting"
            class="w-3 h-3 border-2 rounded-full animate-spin"
            style="border-color: white; border-top-color: transparent"
          ></span>
          <span>{{ isSubmitting ? 'Creating...' : 'Create PR' }}</span>
        </button>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 6.2: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/CreatePrDialog.vue
git commit -m "feat(ui): add CreatePrDialog component"
```

---

## Chunk 7: Frontend — Wire it all into `ChatView.vue`

This is the integration chunk. Add the `git_worktree_cwd` ref, compute `effectiveCwd`, make the branch indicator clickable, integrate `WorktreeMenu` and `CreatePrDialog`.

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 7.1: Add the `git_worktree_cwd` ref and `effectiveCwd` computed**

In the `<script setup>` block of `ChatView.vue`, near line 501 where `cwd` is declared, add:

```ts
// Bound git worktree path (empty string when no worktree is bound).
// Updated by loadChatHistory() from the API response and by the
// sessions SSE stream when the LLM calls set_git_worktree.
const gitWorktreeCwd = ref('')

// The cwd we run git status against. Prefers the worktree when set
// (so the branch display reflects the worktree's branch, not the
// session's original cwd). Falls back to the session's original cwd.
const effectiveCwd = computed(() => gitWorktreeCwd.value || cwd.value)
```

- [ ] **Step 7.2: Populate `gitWorktreeCwd` in `loadChatHistory`**

Find the block in `loadChatHistory` that sets `cwd.value` (around line 818):

```ts
if (!loadMore && data.cwd) {
  cwd.value = data.cwd
}
```

Add a parallel line right after:

```ts
if (!loadMore && data.git_worktree_cwd !== undefined) {
  gitWorktreeCwd.value = data.git_worktree_cwd
}
```

- [ ] **Step 7.3: Subscribe to the sessions SSE event for live worktree changes**

Find the SSE event handler that updates session state in the global stream (search for `createSessionsSseConnection` or `session.updated` in `ChatView.vue`). Add a handler for the `git_worktree_cwd` field. The pattern is the same as the existing `selected_profile_model` handler.

If ChatView doesn't already subscribe to the sessions SSE, just add a watcher on `data.git_worktree_cwd` from `loadChatHistory` (Step 7.2 is sufficient — the next page load picks it up).

For real-time updates during an active chat, the more robust pattern is: when the LLM calls `set_git_worktree`, the SSE event fires; the `onSessionUpdated` callback in ChatsList.vue updates `navItems[i].git_worktree_cwd`. To propagate this to the active ChatView, the parent component (App.vue / AppLayout.vue) should re-fetch the session info on `session.updated` events and pass it down. **For v1, do not wire this up** — the user can refresh the chat (or just observe the change on the next `loadChatHistory` call). Document this as a follow-up.

- [ ] **Step 7.4: Replace the git-status watcher to use `effectiveCwd`**

Find the watcher at line 1641-1650:

```ts
watch(
  () => cwd.value,
  (newCwd) => {
    if (newCwd) {
      checkGitStatus()
    } else {
      gitStatus.value = null
    }
  },
)
```

Change `() => cwd.value` to `() => effectiveCwd.value`:

```ts
watch(
  () => effectiveCwd.value,
  (newCwd) => {
    if (newCwd) {
      checkGitStatus()
    } else {
      gitStatus.value = null
    }
  },
)
```

And update `checkGitStatus` (line 602) to use `effectiveCwd.value` instead of `cwd.value`:

```ts
const checkGitStatus = async () => {
  if (!effectiveCwd.value) {
    gitStatus.value = null
    return
  }
  try {
    const status = await api.getGitStatus(effectiveCwd.value)
    gitStatus.value = status
  } catch (err) {
    console.error('Failed to check git status:', err)
    gitStatus.value = null
  }
}
```

- [ ] **Step 7.5: Add refs for the dropdown and dialog state**

Near the existing profile-picker refs (line 511-514), add:

```ts
const showWorktreeMenu = ref(false)
const worktreeMenuRef = ref<HTMLElement | null>(null)
const showCreatePrDialog = ref(false)
```

- [ ] **Step 7.6: Add the dropdown handlers**

After the existing `selectProfile` function (line 534-549), add the worktree-menu handlers:

```ts
const onWorktreeMenuCreatePr = () => {
  showCreatePrDialog.value = true
}

const onWorktreeMenuViewFolder = () => {
  // Open the worktree path in the system file manager.
  // Implementation: use the existing /api/system/folder?path=<worktree>
  // to confirm the directory is accessible, then emit a window event
  // that the right-sidebar file explorer subscribes to. For v1, the
  // simplest implementation is to copy the path to the clipboard and
  // show a toast — see ChatsList.vue for the clipboard pattern.
  navigator.clipboard.writeText(gitWorktreeCwd.value)
  // TODO: open a folder-explorer modal in a follow-up
}

const onWorktreeMenuClear = async () => {
  // Send a system message to the LLM asking it to clear the worktree.
  // The LLM calls set_git_worktree(clear=true), which removes the
  // directory and clears the binding. The SSE event updates the UI.
  if (!sessionId.value) return
  try {
    await api.sendChatMessage(
      sessionId.value,
      'Please call set_git_worktree with clear=true to remove the current worktree binding.',
      cwd.value,
      [],
      selectedProfile.value ?? undefined,
    )
  } catch (err) {
    console.error('Failed to send clear-worktree message:', err)
  }
}
```

- [ ] **Step 7.7: Add the PR-created handler**

After the onWorktreeMenuClear handler, add:

```ts
const onPrCreated = (url: string) => {
  showCreatePrDialog.value = false
  // Show a brief toast (use the existing notification pattern)
  // For v1, just open the PR URL in a new tab
  window.open(url, '_blank')
}

const onPrError = (message: string) => {
  console.error('PR creation failed:', message)
  // Show a toast with the error
  // For v1, just log — the dialog stays open with the form intact
}
```

- [ ] **Step 7.8: Replace the read-only `<div>` at line 2286-2301 with a clickable button + dropdown**

Find the current block:

```vue
<!-- Git status display -->
<div
  v-if="gitStatus && gitStatus.is_git_repo"
  class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs"
  style="
    background-color: var(--semantic-card-bg);
    border: 1px solid var(--color-border);
  "
  :title="
    gitStatus.status === 'clean' ? 'Working tree clean' : 'Working tree has changes'
  "
>
  <span>🌿</span>
  <span style="color: var(--semantic-text)">{{ gitStatus.branch || 'main' }}</span>
  <span v-if="!gitStatus.is_clean" style="color: var(--color-orange)">●</span>
  <span v-else style="color: var(--color-green)">✓</span>
</div>
```

Replace with:

```vue
<!-- Git status indicator — clickable when a worktree is bound -->
<div ref="worktreeMenuRef" class="relative">
  <button
    v-if="gitStatus && gitStatus.is_git_repo"
    @click.stop="gitWorktreeCwd ? (showWorktreeMenu = !showWorktreeMenu) : null"
    :disabled="!gitWorktreeCwd"
    data-testid="worktree-status-button"
    class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs transition-all duration-200"
    :class="gitWorktreeCwd ? 'hover:scale-105 cursor-pointer' : 'cursor-default'"
    style="
      background-color: var(--semantic-card-bg);
      border: 1px solid var(--color-border);
    "
    :title="
      gitWorktreeCwd
        ? `Worktree: ${gitWorktreeCwd}\n${gitStatus.status === 'clean' ? 'Working tree clean' : 'Working tree has changes'}`
        : (gitStatus.status === 'clean' ? 'Working tree clean' : 'Working tree has changes')
    "
  >
    <span>🌿</span>
    <span style="color: var(--semantic-text)">{{ gitStatus.branch || 'main' }}</span>
    <template v-if="gitWorktreeCwd">
      <span style="color: var(--semantic-text-dim)">·</span>
      <span style="color: var(--color-emerald); font-family: monospace;">
        🌳 {{ gitWorktreeCwd.split('/').pop() }}
      </span>
    </template>
    <span v-if="!gitStatus.is_clean" style="color: var(--color-orange)">●</span>
    <span v-else style="color: var(--color-green)">✓</span>
    <span v-if="gitWorktreeCwd" class="text-[10px]">▾</span>
  </button>
  <WorktreeMenu
    v-if="showWorktreeMenu"
    @create-pr="onWorktreeMenuCreatePr"
    @view-folder="onWorktreeMenuViewFolder"
    @clear="onWorktreeMenuClear"
    @close="showWorktreeMenu = false"
  />
</div>
```

- [ ] **Step 7.9: Add the `CreatePrDialog` mount at the end of the template**

Find a good place near the other modals (around line 2336 where `SkillsPopup` is mounted). Add:

```vue
<CreatePrDialog
  v-if="showCreatePrDialog"
  :worktree-path="gitWorktreeCwd"
  @pr-created="onPrCreated"
  @error="onPrError"
  @close="showCreatePrDialog = false"
/>
```

- [ ] **Step 7.10: Import the new components**

At the top of `ChatView.vue`'s `<script setup>` block, add:

```ts
import WorktreeMenu from './WorktreeMenu.vue'
import CreatePrDialog from './CreatePrDialog.vue'
```

- [ ] **Step 7.11: Verify the type-check passes**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean. No TS errors, no vue-tsc errors.

- [ ] **Step 7.12: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/ChatView.vue
git commit -m "feat(ui): worktree-aware branch status + clickable dropdown with Create PR"
```

---

## Chunk 8: Frontend — Component tests

The 3 new components and the modified `ChatView.vue` get unit tests following the project's `chatsListGitWorktree.spec.ts` pattern.

**Files:**
- Create: `src/apps/desktop/src/__tests__/worktreeMenu.spec.ts`
- Create: `src/apps/desktop/src/__tests__/createPrDialog.spec.ts`
- Create: `src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts`

- [ ] **Step 8.1: Write `worktreeMenu.spec.ts`**

Tests:
1. Renders 3 menu items with the correct test-ids
2. Clicking "Create a PR" emits `create-pr` and `close`
3. Clicking "View in folder" emits `view-folder` and `close`
4. Clicking "Clear worktree" shows confirm dialog; on accept, emits `clear` and `close`
5. Clicking outside the menu emits `close`

Pattern (see `chatsListGitWorktree.spec.ts` for the full setup):
```ts
import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import WorktreeMenu from '../components/WorktreeMenu.vue'

describe('WorktreeMenu', () => {
  it('emits create-pr when Create a PR is clicked', async () => {
    const wrapper = mount(WorktreeMenu)
    await wrapper.find('[data-testid="worktree-menu-create-pr"]').trigger('click')
    expect(wrapper.emitted('create-pr')).toBeTruthy()
    expect(wrapper.emitted('close')).toBeTruthy()
  })
  // ... 4 more tests
})
```

- [ ] **Step 8.2: Write `createPrDialog.spec.ts`**

Tests:
1. On mount, calls `api.getGitWorktreeInfo` (with no `base`) and pre-fills the form
2. Clicking the Auto-fill button calls `api.getGitWorktreeInfo` with the **current base branch value** as the second arg, and overwrites title + body
3. The Auto-fill button is disabled while submitting
4. The Auto-fill button is disabled while a regenerate is in flight
5. Clicking "Create PR" calls `api.createGitPr` and emits `pr-created` on success
6. On `createGitPr` failure, emits `error` and keeps the dialog open
7. The submit button is disabled when title is empty
8. The close button is disabled while submitting

Pattern: `vi.spyOn(api, 'getGitWorktreeInfo').mockResolvedValue({...})` and `vi.spyOn(api, 'createGitPr').mockResolvedValue({...})`. For test #2 specifically:

```ts
it('auto-fill button re-fetches with the current base branch', async () => {
  const spy = vi.spyOn(api, 'getGitWorktreeInfo')
    .mockResolvedValueOnce({  // first call (onMounted)
      is_git_repo: true, branch: 'worktree/feature-x',
      last_commit_sha: 'abc1234', last_commit_msg: 'old title',
      default_base: 'main', commits_ahead: 1,
      diff_summary: 'old diff', draft_title: 'old title',
      draft_body: 'old body',
    } as any)
    .mockResolvedValueOnce({  // second call (auto-fill click)
      is_git_repo: true, branch: 'worktree/feature-x',
      last_commit_sha: 'def5678', last_commit_msg: 'new title',
      default_base: 'develop', commits_ahead: 5,
      diff_summary: 'new diff', draft_title: 'new title',
      draft_body: 'new body',
    } as any)

  const wrapper = mount(CreatePrDialog, { props: { worktreePath: '/tmp/wt' } })
  await flushPromises()

  // Simulate the user changing the base branch
  const baseInput = wrapper.find('[data-testid="create-pr-base"]')
  await baseInput.setValue('develop')

  // Click auto-fill
  await wrapper.find('[data-testid="create-pr-regenerate"]').trigger('click')
  await flushPromises()

  // The second call must have been made with base='develop'
  expect(spy).toHaveBeenCalledTimes(2)
  expect(spy.mock.calls[1][1]).toBe('develop')

  // Title + body should reflect the second response
  expect((wrapper.find('[data-testid="create-pr-title"]').element as HTMLInputElement).value).toBe('new title')
  expect((wrapper.find('[data-testid="create-pr-body"]').element as HTMLTextAreaElement).value).toBe('new body')
})
```

- [ ] **Step 8.3: Write `chatViewWorktree.spec.ts`**

Tests:
1. When `git_worktree_cwd` is empty, the status button is disabled (not clickable)
2. When `git_worktree_cwd` is set, the status button shows the worktree basename with `🌳 <basename>` text
3. When `git_worktree_cwd` is set, clicking the status button opens the dropdown
4. The status button's `title` attribute shows the full worktree path

For mounting ChatView, follow the pattern from `chatsListGitWorktree.spec.ts` — spy on `getChats`, `createSessionsSseConnection`, etc.

- [ ] **Step 8.4: Run all frontend tests**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 30`
Expected: all pass. New test count includes the 5 + 5 + 4 = 14 new component tests.

- [ ] **Step 8.5: Run the build**

Run: `timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean. (Per the project's `bun run build` vs `vitest run` rule — `vue-tsc` is the authoritative type-check.)

- [ ] **Step 8.6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/__tests__/worktreeMenu.spec.ts src/apps/desktop/src/__tests__/createPrDialog.spec.ts src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts
git commit -m "test(ui): worktree menu, create PR dialog, and ChatView worktree display"
```

---

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `gh` CLI not installed on the user's system | High | The `POST /api/git/pr` endpoint returns a structured 500 with a clear `hint` field. The dialog displays the error inline. Users without `gh` cannot use "Create PR" but everything else works. |
| `gh` is installed but the user is not authenticated | Medium | `gh pr create` exits with a non-zero code and writes a "not authenticated" error to stderr. The handler surfaces this verbatim. |
| The worktree branch is not pushed to origin | High | `gh pr create` fails with "no commits between origin/main and worktree/feature-x" or similar. The handler surfaces this verbatim. The user can run `git push -u origin worktree/feature-x` in the worktree directory. |
| The worktree path doesn't exist on disk (user `rm -rf`'d it) | Low | The git status check at line 18 of `git_worktree_info.zig` returns 404. The frontend's `effectiveCwd` falls back to `cwd.value` and the status bar still works. The "Create PR" action would show a clear error. |
| `set_git_worktree` is called mid-LLM-processing, changing the worktree | Low | The LLM would re-call the tool with the new path; the `cwd_override` (post-`cwd-override` plan) is updated; subsequent tool calls operate on the new worktree. The frontend updates on the next `loadChatHistory` or via SSE. |
| The 4096-char limit on `set_git_worktree` path is too short for deeply-nested worktrees | Low | Users with deeply-nested paths can shorten the project dir. The 4096 limit is consistent with `set_git_worktree`'s existing constraint. |
| The "View in folder" action opens the OS file manager, which the LLM can't control | Medium | For v1, the action copies the path to the clipboard and shows a toast. A future plan can add a "browse files" modal that uses the existing `/api/system/folder?path=<worktree>&action=list` endpoint. |
| The `git_worktree_cwd` field on the `Session` interface is optional — TypeScript will complain when accessed as a string | Low | Use `gitWorktreeCwd.value || ''` pattern in computed, and `data.git_worktree_cwd ?? ''` in the API caller. The `getChatHistory` return type marks it as `string` (always present) even though it can be empty. |

---

## Out of scope (follow-up plans)

1. **"Switch worktree" dropdown action.** Re-bind the session to a different worktree path via a direct API call (no LLM round-trip). Would need a new `PUT /api/session/:id/worktree` endpoint that mirrors `set_git_worktree`'s logic. The follow-up plan can include this and the parallel `cwd_override` runtime work.

2. **"Open in new tab" / "Pin worktree" actions.** Open a new chat in a separate window, pre-bound to the worktree. This is a UI feature with a small backend touch (the new chat's `cwd` is the worktree path). Out of scope for v1.

3. **Real-time worktree updates in the active chat.** When the LLM calls `set_git_worktree` mid-chat, the SSE event fires on the global `sessions/stream` topic. The active ChatView doesn't currently subscribe to that stream — only ChatsList does. A follow-up plan should wire `App.vue` (or AppLayout.vue) to forward `session.updated` events to the active ChatView so the status bar updates in real time without a page refresh.

4. **Diff viewer for the worktree vs base.** Show a side-by-side diff between the worktree's branch and the base branch in a modal. Useful for reviewing the PR before creating it. Out of scope for v1.

5. **Worktree manager page.** List all worktrees in the repo with their status, allow bulk cleanup. Out of scope for v1.

---

## Definition of done

- [ ] All 8 chunks complete.
- [ ] `timeout 180 zig build test --summary all 2>&1 | tail -n 5` shows `test success` with the test count increased by ~10 (3 from Chunk 2 + 4 from Chunk 3 + 14 from Chunk 8, but the 14 frontend tests are counted by vitest, not zig).
- [ ] `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` is clean.
- [ ] `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20` is clean.
- [ ] Manual smoke test (see "Verification commands" at the top) passes all 9 steps: load chat, no worktree → unchanged; bind worktree via LLM → 🌳 suffix appears; click → dropdown opens; create PR → dialog opens with pre-filled form; submit → PR created, URL displayed; view in folder → path copied; clear worktree → LLM clears it, status reverts.
- [ ] No new test regressions in either backend or frontend test suite.
- [ ] No changes to the `cwd_override` field on `ToolExecContext` (that's a separate plan's territory — see NALAR.md dead-letter note).

---

## Estimated LoC

| File | Change | LoC estimate |
|---|---|---|
| `src/ai_workflow/tui/llm_history.zig` | Add `git_worktree_cwd` field to 2 response structs + 2 SELECT updates | +30 |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | Add `SessionMessageResponse.git_worktree_cwd` + 2 new response types + 2 helpers | +40 |
| `src/ai_workflow/tui/http_handlers/session_messages_get.zig` | Pass new field through | +2 |
| `src/ai_workflow/tui/http_handlers/git_worktree_info.zig` | New endpoint | +130 |
| `src/ai_workflow/tui/http_handlers/git_worktree_info_test.zig` | Static tests | +40 |
| `src/ai_workflow/tui/http_handlers/git_pr_create.zig` | New endpoint | +110 |
| `src/ai_workflow/tui/http_handlers/git_pr_create_test.zig` | Static tests | +50 |
| `src/ai_workflow/tui/http_handlers/mod.zig` | Export 2 handlers | +2 |
| `src/main.zig` | Register 2 routes | +2 |
| `src/ai_workflow/tui/test_runner.zig` | Register 2 test files | +2 |
| `src/apps/desktop/src/api/index.ts` | Extend `getChatHistory` + 2 new types + 2 new functions (one with optional `base`) | +85 |
| `src/apps/desktop/src/components/WorktreeMenu.vue` | New component | +90 |
| `src/apps/desktop/src/components/CreatePrDialog.vue` | New component (incl. Auto-fill button + handler) | +210 |
| `src/apps/desktop/src/components/ChatView.vue` | Add worktree ref + 4 handlers + replace status div + mount 2 new components + import | +90 |
| `src/apps/desktop/src/__tests__/worktreeMenu.spec.ts` | 5 tests | +90 |
| `src/apps/desktop/src/__tests__/createPrDialog.spec.ts` | 8 tests (incl. 1 verbose auto-fill re-fetch test) | +200 |
| `src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts` | 4 tests | +120 |
| **Total** | **9 files modified, 7 files created** | **~1260 LoC** |
