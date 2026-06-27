# `set_git_worktree` Tool — Handling "path already exists"

**Date:** 2026-06-20
**Tool:** `src/modules/agent/tools/set_git_worktree.zig` (LLM-callable)
**Dispatch:** `src/ai_workflow/tui/tool_registry.zig::execSetGitWorktree`
**Symptom:** LLM calls `set_git_worktree(path=X)`; tool fails with the
raw git stderr `"fatal: '<X>' already exists"` returned via XML.

---

## TL;DR

The tool today **passes through git's stderr verbatim** — which is
correct but unhelpful. The LLM gets back `<error>fatal: '/abs/.worktrees/x' already exists</error>`
and has no machine-readable hint about *why* it failed, *which branch*
owns the conflicting path, or *what to do next*.

**Three-layer fix (all surgical, no breaking changes):**

1. **Layer 1 — Tool-side precheck (cheap, always-on):** before
   spawning `git worktree add`, classify the path:
   - registered worktree on a compatible branch → auto-bind (success)
   - registered worktree on a different branch → XML error with the
     existing branch + 3 actionable options
   - plain directory / stale worktree metadata → XML error with the
     `git worktree prune + rm` remediation
2. **Layer 2 — Smarter error messages:** detect specific git stderr
   patterns (`already exists`, `is already checked out`, `not a git
   repository`, `invalid reference`) and rewrite them with project-
   specific guidance.
3. **Layer 3 — LLM guidance:** add 2 sentences to the tool description
   telling the LLM what to do on `<error>` — pick a different path,
   or check `git worktree list` via `bash`, or ask the user.

**For the current case** (path occupied by an active worktree on
branch `refactor/split-nalar-config-profile-delete`): Layer 1 will
auto-bind to the existing worktree on the SAME intent (`refactor/...`)
and return success. No data loss, no user friction.

---

## 1. Current State (verified 2026-06-20)

### 1.1 What the tool does today

`src/modules/agent/tools/set_git_worktree.zig::executeSetGitWorktreeToString`
(lines 292–352):

```zig
// (excerpt)
const git_detail = runGitWorktreeAdd(allocator, io, cwd, worktree_path, branch)
    catch |err| { ... return xmlError(allocator, session_id, @errorName(err)); };
defer allocator.free(git_detail);
if (git_detail.len > 0) {
    return xmlError(allocator, session_id, git_detail);   // ← raw git stderr
}
return successSetToXml(allocator, session_id, worktree_path, branch);
```

`runGitWorktreeAdd` (lines 134–228) spawns `git worktree add -b <branch>
<path>`, captures stderr into a bounded `ArrayList(u8)` (64 KB cap),
and returns the captured text on non-zero exit.

`execSetGitWorktree` (tool_registry.zig:472–531) unwraps the inner XML,
extracts `<error>...</error>`, and wraps it for the LLM. On success it
calls `llm_history.updateSessionGitWorktreeCwd` to persist the binding.

### 1.2 What the LLM sees today

When git fails with "already exists", the LLM gets back the raw message:

```xml
<worktree>
  <session_id>...</session_id>
  <created>false</created>
  <error>fatal: '/abs/.worktrees/split-nalar-config-profile-delete' already exists</error>
</worktree>
```

Wrapped by `wrapToolOutput` (tool_registry.zig:480) into the standard
tool envelope. The LLM can SEE the error but has to **guess** that
the path is occupied by another worktree, that another session owns
it, that it has uncommitted work, etc.

### 1.3 What the user reported

> `Preparing worktree (new branch 'worktree/split-nalar-config-profile-delete')`
> `fatal: '/abs/.worktrees/split-nalar-config-profile-delete' already exists`

The "Preparing worktree" line is **not in the current tool output** —
git's full stderr is captured but only the `fatal: ...` line is
meaningful in our context. We can keep that line (it's not wrong, just
verbose) or strip it.

### 1.4 What the underlying git state looks like (this case)

```
Path:    /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete
Branch:  refactor/split-nalar-config-profile-delete   ← already on a refactor branch
Status:  3 modified files + 1 new untracked file (active agent's WIP)

Orphan:  worktree/split-nalar-config-profile-delete   ← leftover branch
```

(Verified via `git worktree list --porcelain` and
`git -C <worktree> status --short --branch`.)

---

## 2. Why This Case Is Especially Painful

The `set_git_worktree` tool's contract is:

> "Create a git worktree at an absolute path you provide and bind it as
> the session's working directory."

When the path is already occupied, **the intent is usually already
satisfied** — there's a worktree at the path, and binding to it would
be the right outcome. The current tool treats this as a hard failure
and forces the LLM into a retry loop:

```
LLM: set_git_worktree(path=A)         → "fatal: A already exists"
LLM: set_git_worktree(path=A, branch=B) → "fatal: A already exists"
LLM: bash(rm -rf A)                   → works, but blows away other agent's WIP
LLM: set_git_worktree(path=A)         → succeeds, but now lost the WIP
LLM: reports to user "I had to nuke some files to proceed"
```

The right behavior is:

```
LLM: set_git_worktree(path=A, branch=B)
TOOL: detects path is already a worktree on branch C
TOOL: C and B are both refactor-ish, intent matches
TOOL: auto-binds session to path A (success, returns "bound to existing")
LLM: continues work, no friction
```

---

## 3. Decision Tree (what the tool SHOULD do)

```
set_git_worktree(path=X, branch=Y, clear=false) called
│
├─ X does not exist on disk
│   → run git worktree add (current behavior) ✓
│
├─ X exists, is a registered worktree
│   │
│   ├─ Registered branch == Y (or auto-derived == Y) → auto-bind, success
│   │   (the existing worktree IS the requested one; just update session DB)
│   │
│   ├─ Registered branch is "compatible" (same prefix family) →
│   │   auto-bind with a warning; suggest the user can rename later
│   │
│   └─ Registered branch is unrelated (e.g. user is requesting branch B
│      but path is on branch C) → return XML error with:
│       - existing branch name
│       - "use the existing worktree by calling set_git_worktree without args"
│         (but this isn't a thing in the current API — see §6 Future)
│       - "pick a different path"
│       - "ask the user to merge/abandon the conflicting branch"
│
├─ X exists, has a .git file but not registered
│   (orphaned worktree directory)
│   → return XML error with: "git worktree prune && rm -rf X" remediation
│
├─ X exists, no .git file (plain directory)
│   → return XML error: "path exists but is not a worktree"
│     (offer: "remove it manually, or pick a different path")
│
└─ X exists but unreadable (permission denied)
    → return XML error: "cannot read X (permission denied)"
```

---

## 4. Implementation Plan

### Chunk 1 — Add path-classification helpers (LOW RISK, always-on)

**Files:** `src/modules/agent/tools/set_git_worktree.zig`
**Tests:** `src/modules/agent/tools/set_git_worktree_test.zig`

Add three new pure / IO-light helpers:

```zig
/// Classify the state of `path` relative to the git worktree system.
/// Returns a tagged union describing what we found. Pure (no allocation
/// beyond the returned slices).
pub const PathState = union(enum) {
    not_found,                                          // doesn't exist
    plain_directory: []const u8,                        // exists, no .git file
    orphaned_worktree: []const u8,                      // has .git file, not in `worktree list`
    registered_worktree: struct {                       // in `git worktree list`
        branch: []const u8,                             // branch name (e.g. "refactor/x")
        commit: []const u8,                             // HEAD commit SHA
        porcelain_entry: []const u8,                    // raw `worktree list --porcelain` block
    },
};

pub fn classifyPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    target: []const u8,
) !PathState { ... }

/// Run `git -C <repo_root> worktree list --porcelain` and return the raw
/// output. Empty string on success, descriptive error on failure.
fn runGitWorktreeList(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) ![]u8 { ... }

/// Parse a single block from `git worktree list --porcelain` output.
/// One block = 3 lines: "worktree <path>", "HEAD <sha>", "branch <ref>".
fn parseWorktreeBlock(allocator: std.mem.Allocator, block: []const u8) !?PathState.registered_worktree { ... }
```

**Reuse:** `runGitWorktreeAdd` and `runGitWorktreeRemove` are the
templates — same spawn + bounded stderr read pattern, different argv.

**Tests (new):**
- `classifyPath(not_found)` for `/tmp/does-not-exist-<random>`
- `classifyPath(plain_directory)` for `mktemp -d && classify`
- `classifyPath(orphaned_worktree)` — manually mkdir + write `.git` file pointing to nonexistent dir
- `classifyPath(registered_worktree)` — `git worktree add` a real worktree, classify it
- `runGitWorktreeList` returns 3+ blocks for a repo with 3 worktrees
- `parseWorktreeBlock` extracts branch + HEAD correctly

These are integration tests (need real git + filesystem) — follow the
pattern in `src/modules/agent/tools/bash.zig` for shell-out tests.

### Chunk 2 — Wire precheck into `executeSetGitWorktreeToString`

**File:** `src/modules/agent/tools/set_git_worktree.zig`
**Tests:** `set_git_worktree_test.zig` (extend)

In the SET branch (after `validatePath`, before `runGitWorktreeAdd`):

```zig
// ── Precheck: classify the path before invoking git ──────────────────
const state = try classifyPath(allocator, io, cwd, worktree_path);
switch (state) {
    .not_found => {
        // Normal path: git worktree add will create the dir.
        // Fall through to existing runGitWorktreeAdd.
    },
    .registered_worktree => |rwt| {
        // Path is already a worktree. Is it on the branch we want?
        const requested_branch = input.branch;  // already computed
        if (std.mem.eql(u8, rwt.branch, requested_branch) or
            isCompatibleBranchFamily(rwt.branch, requested_branch)) {
            // AUTO-BIND: existing worktree IS the requested one.
            // Persist the binding, return success.
            return successSetToXml(allocator, session_id, worktree_path, rwt.branch);
        }
        // Different branch — return XML error with actionable advice.
        return xmlError(allocator, session_id,
            try std.fmt.allocPrint(allocator,
                "path '{s}' is already a worktree on branch '{s}'. " ++
                "Pick a different path, or pass branch='{s}' to bind to it, " ++
                "or ask the user how to resolve the conflict.",
                .{ worktree_path, rwt.branch, rwt.branch }));
    },
    .orphaned_worktree => {
        return xmlError(allocator, session_id,
            try std.fmt.allocPrint(allocator,
                "path '{s}' is an orphaned worktree directory (has .git file " ++
                "but is not registered with git). Run " ++
                "`git worktree prune && rm -rf {s}` to clean up, " ++
                "then retry set_git_worktree.",
                .{ worktree_path, worktree_path }));
    },
    .plain_directory => {
        return xmlError(allocator, session_id,
            try std.fmt.allocPrint(allocator,
                "path '{s}' already exists but is not a worktree directory. " ++
                "Remove it manually (after backing up any important content) " ++
                "or pick a different path.",
                .{ worktree_path }));
    },
}
```

Add the `isCompatibleBranchFamily` helper (pure function):

```zig
/// "Are these two branches the same logical work?" Returns true if
/// the prefixes match (e.g. "refactor/x" and "refactor/y" are both
/// in the refactor family). Conservative: only matches the
/// project-known prefixes.
pub fn isCompatibleBranchFamily(a: []const u8, b: []const u8) bool {
    const families = [_][]const u8{ "refactor/", "feature/", "fix/", "feat/" };
    for (families) |prefix| {
        if (std.mem.startsWith(u8, a, prefix) and
            std.mem.startsWith(u8, b, prefix)) return true;
    }
    return false;
}
```

**Tests (extend):**
- `executeSetGitWorktreeToString on existing worktree on same branch → success`
- `executeSetGitWorktreeToString on existing worktree on compatible branch → success`
- `executeSetGitWorktreeToString on existing worktree on unrelated branch → error mentions existing branch name`
- `executeSetGitWorktreeToString on orphaned worktree dir → error mentions git worktree prune`
- `executeSetGitWorktreeToString on plain directory → error mentions manual removal`

These need a helper to set up a real git repo + worktree in a temp
dir. Reuse the pattern from `bash_test.zig` for temp dir setup.

### Chunk 3 — Smarter error rewriting for git stderr

**File:** `src/modules/agent/tools/set_git_worktree.zig`
**Tests:** `set_git_worktree_test.zig` (new unit tests)

Even with the precheck, git may still fail with messages we can improve
(networking issues, race conditions where the path appeared between
precheck and add, etc.). Detect the common stderr patterns and rewrite:

```zig
/// Rewrite a raw git stderr into a tool-friendly message.
pub fn rewriteGitStderr(
    allocator: std.mem.Allocator,
    raw_stderr: []const u8,
    worktree_path: []const u8,
    branch: []const u8,
) ![]u8 {
    if (std.mem.indexOf(u8, raw_stderr, "already exists") != null) {
        return try std.fmt.allocPrint(allocator,
            "the directory '{s}' already exists on disk. " ++
            "Either pick a different path, or run " ++
            "`git -C <repo> worktree list` to see which branch occupies it.",
            .{worktree_path});
    }
    if (std.mem.indexOf(u8, raw_stderr, "is already checked out") != null) {
        return try std.fmt.allocPrint(allocator,
            "branch '{s}' is already checked out by another worktree. " ++
            "Pass branch='' (empty) to use the auto-derived branch name " ++
            "worktree/<basename(path)>, or pick a different branch name.",
            .{branch});
    }
    if (std.mem.indexOf(u8, raw_stderr, "not a git repository") != null) {
        return try allocator.dupe(u8,
            "the current directory is not a git repository. " ++
            "set_git_worktree requires being run from inside a git repo.");
    }
    if (std.mem.indexOf(u8, raw_stderr, "invalid reference") != null) {
        return try std.fmt.allocPrint(allocator,
            "the branch name '{s}' is invalid (git refused it). " ++
            "Branch names must not contain spaces, '/..', '~', '^', ':', " ++
            "'?', '*', '[', '\\', or end with '.lock' or '/'.",
            .{branch});
    }
    // Default: surface raw stderr (preserves any context we don't recognize).
    return try allocator.dupe(u8, raw_stderr);
}
```

Use it in `executeSetGitWorktreeToString` instead of passing raw
`git_detail` to `xmlError`.

**Tests (new):**
- Unit tests for `rewriteGitStderr` with each known pattern
- Edge cases: empty stderr, very long stderr (truncate), stderr with no recognized pattern (pass-through)

### Chunk 4 — LLM guidance in tool description

**File:** `src/modules/agent/tools/set_git_worktree.zig` (description field only)
**Tests:** existing static tests in `set_git_worktree_test.zig` (extend with "description mentions recovery options")

Extend the description with the recovery pattern. Current:

> "Create a git worktree at an absolute path you provide and bind it as the session's working directory..."

New:

> "...On <error>, recover by: (1) checking `git -C <repo> worktree list --porcelain` to see what branch occupies the path; (2) either re-calling set_git_worktree with `branch=<existing-branch>` to bind to it, or picking a different path; (3) if the existing branch is abandoned, ask the user to delete it then retry. Never `rm -rf` the conflicting path — there may be uncommitted work."

**Tests (extend existing static checks):**
- `description mentions git worktree list recovery`
- `description mentions uncommitted work warning`

### Chunk 5 — Register new tests in test_runner.zig

**File:** `src/ai_workflow/tui/test_runner.zig`

If new test files were added (likely), register them:

```zig
_ = @import("../../../modules/agent/tools/set_git_worktree_test.zig");
// (existing entry — extend if we add new files)
```

---

## 5. Test Plan (cumulative)

After each chunk:

| Chunk | New tests | Expected pass delta |
|-------|-----------|---------------------|
| 1 (classifyPath helpers) | 6 | 6/6 → 12/12 |
| 2 (wire precheck into execute) | 5 | 12/12 → 17/17 |
| 3 (rewriteGitStderr) | 5 | 17/17 → 22/22 |
| 4 (description text) | 2 | 22/22 → 24/24 |
| 5 (registration) | 0 (just wiring) | unchanged |

Baseline before chunks: `zig build test --summary all` reports current
test count (verify before starting; `set_git_worktree_test.zig`
currently has 14 tests). After all chunks: 14 + 18 = 32 tests in
`set_git_worktree_test.zig`.

---

## 6. Future Work (out of scope for this plan)

These came up during investigation but are not blockers:

### 6.1 New `bind_to_existing` parameter

Instead of auto-binding silently, let the LLM opt in:

```zig
pub const SetGitWorktreeInput = struct {
    ...
    /// If true, and the path is already a worktree, bind to it instead
    /// of failing. Default: true (silent auto-bind is the friendly default).
    reuse_existing: bool = true,
    ...
};
```

When `reuse_existing=false`, the tool fails on existing worktrees even
on compatible branches. Useful for the LLM to "fail loud" when it
suspects the path was supposed to be empty.

### 6.2 `force` parameter for branch conflicts

```zig
/// If true, replace an existing branch of the same name. Does NOT
/// override path collisions (git refuses those regardless). Default: false.
force: bool = false,
```

Translates to `git worktree add -f -b <branch> <path>`. Combined with
`reuse_existing=true` this gives the LLM full control over recovery.

### 6.3 `cwd_override` wire-up (from `set-git-worktree-cwd-override.md`)

The `ToolExecContext.cwd_override` field is currently dead-letter
(see project memory). Wire it up so that `set_git_worktree` actually
changes the session's effective cwd for subsequent tool calls.

### 6.4 Clear-then-set helper

A common pattern: "abandon the current worktree and create a new one
at path X with branch Y." Add a helper parameter:

```zig
/// If true AND this session already has a worktree binding, remove the
/// old worktree first, then create the new one. Saves the LLM from
/// coordinating set_git_worktree(clear=true) + set_git_worktree(path=X).
replace_existing: bool = false,
```

This is what the user's situation actually wants — they have an existing
worktree (theirs, not another agent's) and want to swap it for a new one.

---

## 7. Verification Checklist

After all chunks land:

```bash
# 1. All set_git_worktree tests pass
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | rg "set_git_worktree_test|set_git_worktree"
# Expect: ~32 tests pass (14 existing + 18 new)

# 2. Install target compiles (catches the lazy-analysis trap)
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
# Expect: 4/6 steps succeed (cp /usr/local/bin/nalar fails harmlessly on permission)

# 3. Manual smoke test: simulate the original error case
#    a. Start nalar on port 8080
./zig-out/bin/nalar --port 8080 &
#    b. Send a set_git_worktree call to a pre-occupied path
curl -sX POST http://127.0.0.1:8080/api/chat/stream/<session_id> -d '... set_git_worktree path=/abs/.worktrees/split-nalar-config-profile-delete ...'
#    c. Verify the response XML mentions the existing branch and offers options
#       (NOT the raw "fatal: ... already exists")

# 4. LLM recovery test (manual or scripted)
#    Trigger the original error path; verify the LLM picks the auto-bind
#    branch and continues without manual intervention.
```

---

## 8. Risk Analysis

### 8.1 Auto-bind regression risk

The biggest risk: **auto-bind makes the tool silently change behavior.**
If a user explicitly wanted to create a NEW worktree (because the old
one is stale or wrong-branch), auto-binding would silently mask the
problem.

Mitigation:
- Default to **auto-bind only on exact branch match** (`refactor/x` ==
`refactor/x`). `isCompatibleBranchFamily` is a conservative second
  case, not a silent one.
- Log the auto-bind to the session log so it shows up in audit:
  `ctx.logger.infoFmt("set_git_worktree: auto-bound session {s} to existing worktree on branch {s}", .{...})`
- Surface `<bound_to_existing>true</bound_to_existing>` in the success
  XML so the LLM can detect the auto-bind happened.

### 8.2 Race conditions

Two concurrent LLM sessions calling `set_git_worktree` on the same path
race between precheck and `git worktree add`. Mitigations:
- Precheck + add are still atomic from the filesystem's perspective
  (`git worktree add` will fail if the path appeared between precheck
  and add, with the same error message — Layer 1 didn't make this worse)
- Long-term: add a per-path file lock around the operation. Out of
  scope for this plan.

### 8.3 Test flakiness

Integration tests that spawn `git worktree add` depend on the host
having git, having enough disk space, and not hitting per-process
worktree limits. Mitigations:
- Use `mktemp -d` for temp dirs (per-test isolation)
- `git worktree remove --force` in `defer` cleanup
- Mark flaky tests with `@Tag("integration")` if the test runner supports it

---

## 9. Migration: Fixing the Current Case

While the chunks are being implemented, the existing conflicted state
needs manual resolution. The user / agent should:

```bash
# 1. Verify the existing worktree is recoverable
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete
git status   # 3 modified + 1 untracked (active agent's WIP)

# 2. If the WIP belongs to another agent, wait for them to commit.
#    If it's your own WIP, commit it:
git add src/ai_workflow/tui/http_handlers/nalar_config_profile_delete_usecase.zig
git add src/ai_workflow/tui/http_handlers/mod.zig \
        src/ai_workflow/tui/http_handlers/nalar_config_profile_delete.zig \
        src/ai_workflow/tui/http_handlers/nalar_config_profile_delete_test.zig
git commit -m "wip: split-nalar-config-profile-delete (snapshot before merge)"

# 3. Clean up the orphan branch
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git branch -D worktree/split-nalar-config-profile-delete
# (verify: git branch -a | grep split-nalar-config-profile-delete)

# 4. (Optional) Clean up the empty .worktrees/feature dir
rmdir /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature
```

After the chunks land, the LLM calling `set_git_worktree(path=A)`
on an already-occupied path will succeed (auto-bind), making the
manual cleanup less urgent.

---

## 10. See Also

- Previous (broader) plan: `docs/plans/2026-06-20-worktree-path-collision-recovery.md`
  — covers the underlying `git worktree add` CLI semantics, all 5
  scenarios, helper script. Kept as background; not the actionable plan.
- Plan: `docs/plans/2026-06-18-set-git-worktree-cwd-override.md` —
  the parallel `cwd_override` wire-up (Chunk 6.3 of this plan).
- Memory: `~/.config/nalar/memories/set-git-worktree-clear-keeps-branch.md`
  — `clear=true` keeps the branch. Confirms why Layer 1's auto-bind is
  the friendlier default.
- Memory: `~/.config/nalar/memories/multi-agent-file-reverts.md` —
  why sharing a worktree across agents is risky (Layer 1's auto-bind
  makes this more common, so the warning in §4 Chunk 4 is important).
- Tool code: `src/modules/agent/tools/set_git_worktree.zig`
- Dispatch: `src/ai_workflow/tui/tool_registry.zig:472` (`execSetGitWorktree`)
- Persistence: `src/ai_workflow/tui/llm_history.zig::updateSessionGitWorktreeCwd`
