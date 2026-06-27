# Worktree Path Collision — Recovery Plan

**Date:** 2026-06-20
**Scope:** The "worktree path already exists" failure mode when calling
`git worktree add` (directly, or via `set_git_worktree`, the
`using-git-worktrees` skill, or any wrapper).
**Applies to:** Any developer / agent trying to create a worktree at a
path that is already occupied by another worktree, branch, or stale
directory.

---

## TL;DR

The error `fatal: '<path>' already exists` from `git worktree add` means
**the target path is already registered in `git worktree list`** (or, less
commonly, is a stale directory that wasn't pruned). Git will never
overwrite an occupied path — you must first remove / reuse / rename.

**For the current case (`.worktrees/split-nalar-config-profile-delete`):**

1. The path is occupied by an **active worktree** bound to branch
   `refactor/split-nalar-config-profile-delete`, currently held by another
   agent session (`task_1781901060619`) with **uncommitted work**
   (3 modified files + 1 new untracked file).
2. **Recommended: just use the existing worktree** (Option A). It is
   already on a `refactor/` branch — the same intent as your new request.
3. **Do NOT blindly run `git worktree remove`** — it will silently throw
   away the other agent's uncommitted code (`nalar_config_profile_delete_usecase.zig`
   and the 3 modified files). If removal is required, save the work first
   (Option B).

---

## 1. Current State (verified 2026-06-20, `git` rev `a7dfd6fd`)

```
Path:    /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete
.git:    gitdir: /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.git/worktrees/split-nalar-config-profile-delete
Branch:  refactor/split-nalar-config-profile-delete   (checked out, active)
Commit:  a7dfd6fd "better code workflow"

Uncommitted work in the worktree (from `git status --short --branch`):
   M src/ai_workflow/tui/http_handlers/mod.zig
   M src/ai_workflow/tui/http_handlers/nalar_config_profile_delete.zig
   M src/ai_workflow/tui/http_handlers/nalar_config_profile_delete_test.zig
  ?? src/ai_workflow/tui/http_handlers/nalar_config_profile_delete_usecase.zig   ← NEW untracked
```

`git worktree list --porcelain` confirms the registration:

```
worktree /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete
HEAD a7dfd6fdd535b99a4a843cb3d7b2261b8ad73dd4
branch refs/heads/refactor/split-nalar-config-profile-delete
```

**Other branches in play (orphans, no worktree attached):**

```
worktree/split-nalar-config-profile-delete   (a7dfd6fd)   ← leftover from a failed earlier `add`
```

Both `refactor/...` and `worktree/...` branches point at the same commit
because `git worktree add -b worktree/<basename> <path>` defaults to HEAD.

**Side note (different bug, same family):**
`/home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature` is an
empty directory (size 0, no `.git` file, mtime `Jun 16 04:01`) — a stale
empty dir from a previous failed/mistaken creation. Not registered in
`git worktree list` and not blocking anything. Can be safely deleted
(`rmdir .worktrees/feature`) — see Option C cleanup.

---

## 2. Root Cause — Why The Error Happened

`git worktree add <path>` (without `-b`) auto-derives the branch name
from the path's basename:

```
Path:    .../split-nalar-config-profile-delete
Branch:  worktree/split-nalar-config-profile-delete     ← auto-derived
```

Two paths can never share a filesystem location — that's the rule git
enforces. The conflict happens when:

- **(Most common)** Another worktree was created earlier at the same
  path with an **explicit different branch name** (here: `refactor/...`,
  via `--branch=refactor/split-nalar-config-profile-delete`). Git tracks
  the path as belonging to that branch and refuses the new request.
- A stale/empty directory exists at the path (older failure mode, often
  a partially-completed `git worktree add` that left the dir behind).
- The path exists with non-git content (manually created, leftover from
  a deleted worktree whose `.git/worktrees/<name>` was removed but the
  directory was not pruned).

In this specific case: the previous run used
`git worktree add -b refactor/split-nalar-config-profile-delete
 /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete`,
claiming both the path and the `refactor/...` branch. The new run is
trying to claim the same path with the auto-derived branch name
`worktree/split-nalar-config-profile-delete`. Git refuses — and so it
should.

---

## 3. Decision Tree

```
git worktree add fails with "'<path>' already exists"
│
├─ Run `git worktree list --porcelain | grep -A2 <basename>`
│  │
│  ├─ Path appears in output  ───────────►  Scenario A (active worktree)
│  │                                       → Section 4 Option A or D
│  │
│  └─ Path NOT in output  ───────────────►  Scenario B/C/D/E (stale)
│                                          → Section 4 Option C
│
├─ Check `ls -la <path>/.git`
│  │
│  ├─ File: "gitdir: .../worktrees/<name>"  → Scenario B (orphaned worktree)
│  │                                          → Section 4 Option C.1
│  │
│  └─ No `.git` file                        → Scenario C (plain empty dir)
│                                             → Section 4 Option C.2
│
└─ Check `git -C <repo> branch -a | grep '<branch-name>'`
   │
   └─ Branch exists → Scenario D (branch but no worktree) — use `-f` flag
                     → Section 4 Option C.3
```

---

## 4. Resolution Options

### Option A — Use the existing worktree (RECOMMENDED)

The other agent already created the worktree at the same path with the
same intent (split `nalar_config_profile_delete.zig`). Just bind to the
existing one instead of creating a new one.

```bash
# 1. Verify it's the same refactor work you intended:
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete
git status --short --branch
git log --oneline -3

# 2. Either:
#    a) Continue the work in this session (the worktree is shared — see Note below)
#    b) Wait for the other worker (task_1781901060619) to finish, then review
#       their work and continue from there.
```

**When to pick:** Any time the existing worktree's branch matches your
intent. Avoids the data-loss risk of Option B and the cost of Option C.

**Trade-off:** Multiple agents sharing one worktree can step on each
other's uncommitted changes (see
[`multi-agent-file-reverts.md`](../../zig-slice-headers-across-defer-lifetimes/SKILL.MD)
for the parallel-work revert problem). Coordinate via the
`Active Workers` section of the orchestrator prompt and the worktree's
branch name.

**If the existing branch is `worktree/<basename>`** (the auto-derived
name), and you'd prefer a different branch name, see Option A.1 below.

#### Option A.1 — Rename the existing branch to your preferred name

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete
git branch -m refactor/split-nalar-config-profile-delete refactor/split-nalar-config-profile-delete
# (or: git branch -m worktree/split-nalar-config-profile-delete <your-preferred-name>)
git push origin :refactor/split-nalar-config-profile-delete 2>/dev/null || true   # clean up remote if any
```

---

### Option B — Remove the existing worktree and recreate (DESTRUCTIVE)

**⚠️ DATA LOSS WARNING ⚠️**

Removing the existing worktree at this path will **silently discard**
the other agent's uncommitted changes:

```
Lost on `git worktree remove`:
  • src/ai_workflow/tui/http_handlers/mod.zig                              (modified)
  • src/ai_workflow/tui/http_handlers/nalar_config_profile_delete.zig      (modified)
  • src/ai_workflow/tui/http_handlers/nalar_config_profile_delete_test.zig (modified)
  • src/ai_workflow/tui/http_handlers/nalar_config_profile_delete_usecase.zig (NEW untracked)
```

These changes are NOT recoverable via git (untracked files never were;
modifications never committed). Only do this if:

1. You have confirmed with the user that the other agent's work is
   disposable / abandonable, **OR**
2. The other worker has actually finished and committed everything
   (then the work IS preserved on the branch — see Option B.1).

#### Option B.1 — Preserve the work first (REQUIRED if not committed)

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete

# 1. Stash uncommitted changes (preserves M + ?? files)
git stash push -u -m "split-nalar-config-profile-delete: pre-removal snapshot"

# 2. Check status — should show clean working tree
git status

# 3. (Optional) Verify the stash contains everything
git stash show -u stash@{0}

# 4. Move out of the worktree before removing (git refuses if you're cd'd in)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox

# 5. Remove the worktree
git worktree remove /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete

# 6. Delete the branch (only if you don't want it anymore)
git branch -D refactor/split-nalar-config-profile-delete

# 7. Now create the new worktree (with your preferred branch name)
git worktree add -b refactor/split-nalar-config-profile-delete \
    /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete

# 8. Pop the stash in the new worktree to restore the previous agent's work
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete
git stash pop   # may conflict — resolve manually if so
```

**When to pick:** The other worker is genuinely stuck, the user has
confirmed abandonment, and you have stashed the work for safety.

---

### Option C — Use a different path / branch name (FALLBACK)

If you don't need to share the path or don't want to disturb the other
agent, pick a new path. Two sub-options:

#### Option C.1 — Just pick a different basename

```bash
git worktree add -b refactor/split-nalar-config-profile-delete \
    /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete-v2
```

Pros: Trivial. Both worktrees coexist.
Cons: Two parallel worktrees on the same logical refactor. They will
eventually conflict at merge time.

#### Option C.2 — Reuse the path on a different branch (only if old branch is committed + not in use)

If the existing worktree's branch (`refactor/split-nalar-config-profile-delete`)
already has all commits and is merged / abandoned:

```bash
# Remove the worktree (the branch keeps its commits, only the working tree is gone)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git worktree remove --force /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete

# Delete the old branch if abandoned
git branch -D refactor/split-nalar-config-profile-delete

# Now create new worktree at the same path with your preferred branch
git worktree add -b your-preferred-branch-name \
    /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete
```

#### Option C.3 — Use `--force` to replace a stale branch entry

If `git worktree list` does NOT show the path, but the branch with your
intended name exists and is checked out elsewhere (Scenario D), force the
checkout with `-f`:

```bash
git worktree add -f -b <your-branch> <path>
# `-f` re-creates the worktree even if a stale branch ref points at it
```

---

### Option D — Wait for the other worker (COOPERATIVE)

The active worker `task_1781901060619` is bound to this worktree and is
working on the same refactor plan ("split nalar_config_profile_delete.zig
into use-case file + slim handler with extracted sub-helpers"). Wait for
their session to finish, then review their PR / branch and either:

- Continue from their committed work, or
- Tear down the worktree (Option B) and restart from scratch.

**When to pick:** Two agents are about to do duplicate work. The
orchestrator should detect this via the `Active Workers` section and
choose a winner before either starts writing code.

---

## 5. Cleanup of Orphans

Regardless of which option you pick, these are safe to clean up:

```bash
# Orphan branch (leftover from a failed earlier worktree add)
git branch -D worktree/split-nalar-config-profile-delete
# Verify with: git branch -a | grep split-nalar-config-profile-delete

# Empty stale directory (different bug, but in the same area)
rmdir /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/feature
# (rmdir fails if non-empty; if so, investigate with `ls -la .worktrees/feature`)

# After full removal in Option B, also:
git worktree prune    # removes stale entries from .git/worktrees/
```

---

## 6. Preventive Measures (for future work)

### A. Detect the conflict BEFORE calling `git worktree add`

Add a 4-line precheck to any wrapper (the
[`using-git-worktrees`](../../../../home/ginwa/.config/nalar/skills/using-git-worktrees/SKILL.MD)
skill, `set_git_worktree`, your own scripts):

```bash
target="/abs/path/to/worktree"
basename="$(basename "$target")"

if git worktree list --porcelain | grep -q "^worktree $target$"; then
    echo "ERROR: $target is already a registered worktree." >&2
    git worktree list --porcelain | grep -A2 "^worktree $target$" >&2
    exit 1
fi

if [ -e "$target" ]; then
    echo "ERROR: $target exists but is not a registered worktree." >&2
    ls -la "$target" | head -n 5 >&2
    exit 1
fi
```

This makes the failure mode loud and diagnostic, instead of the
terse git fatal error.

### B. Always use explicit `-b <branch>` to make branch ownership obvious

Auto-derived branches (`worktree/<basename>`) collide silently across
runs that pick different basenames. Explicit names
(`refactor/...`, `fix/...`, `feat/...`) make ownership visible in
`git worktree list`.

### C. Never blindly `rm -rf .worktrees/<name>`

Always use `git worktree remove <path>` (or `git worktree remove --force`
for a dirty tree). Manual `rm -rf` leaves `.git/worktrees/<name>/`
behind, which `git worktree prune` cleans up but which may confuse
later agents.

### D. Have the orchestrator serialize workers on the same path

The orchestrator prompt has an `Active Workers` section. Two workers
picking the same `set_git_worktree path=...` will collide. Add a
precheck:

> "If another worker is already bound to this path, do not call
> `set_git_worktree` — bind to their worktree or wait."

### E. Commit early and often in worktrees

The other agent's 3 modified + 1 untracked files would have been safe
to abandon if they had committed after each milestone. The plan format
in this project (`docs/plans/<date>-<feature>.md` with Chunk 1, Chunk 2,
...) is well-suited to "commit after each chunk" — promote it from
"recommended" to "required" for any agent working in a worktree.

---

## 7. Verification Checklist

After applying any option, run these to confirm the fix:

```bash
# 1. The path resolves to a single worktree entry
git worktree list --porcelain | grep -c "^worktree /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete$"
# Expect: 1

# 2. The branch is checked out exactly once across all worktrees
git worktree list --porcelain | grep -c "branch refs/heads/refactor/split-nalar-config-profile-delete"
# Expect: 1

# 3. No orphan branches
git branch -a | grep "split-nalar-config-profile-delete"
# Expect: only the branch you intended to keep (and possibly its origin/* mirror)

# 4. Working tree status (if you kept the existing worktree)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete
git status
# Expect: clean, OR the same 3 modified + 1 untracked files you stashed in Option B.1

# 5. Build still works
timeout 180 zig build test --summary all 2>&1 | tail -n 5
# Expect: same pass/fail count as before
```

---

## 8. Helper Script (optional)

Save as `scripts/resolve-worktree-collision.sh` for one-shot diagnosis +
fix:

```bash
#!/usr/bin/env bash
# Resolve a "worktree path already exists" collision.
# Usage: ./scripts/resolve-worktree-collision.sh <path>
set -euo pipefail

target="$(realpath "$1")"
basename="$(basename "$target")"
repo="$(git rev-parse --show-toplevel)"

echo "Target:    $target"
echo "Basename:  $basename"
echo "Repo:      $repo"
echo

# State 1: registered worktree at this path
if git worktree list --porcelain | grep -q "^worktree $target$"; then
    echo "STATE: registered worktree exists"
    git worktree list --porcelain | grep -A2 "^worktree $target$"
    echo
    echo "OPTIONS:"
    echo "  A. Use the existing worktree (RECOMMENDED if intent matches)."
    echo "  B. git worktree remove  (DATA LOSS — see plan §4 Option B)"
    echo "  C. Pick a different path / branch name."
    echo "  D. Wait for the active worker to finish."
    exit 0
fi

# State 2: directory exists with a .git file (orphaned worktree metadata)
if [ -f "$target/.git" ]; then
    echo "STATE: orphaned worktree directory (has .git file)"
    cat "$target/.git"
    echo
    echo "FIX: git worktree prune && rm -rf '$target'"
    exit 0
fi

# State 3: directory exists but no .git file (plain leftover)
if [ -e "$target" ]; then
    echo "STATE: plain leftover directory (no .git file)"
    ls -la "$target" | head -n 5
    echo
    echo "FIX: rm -rf '$target'   (verify contents first with: ls -la '$target')"
    exit 0
fi

# State 4: nothing at the path — safe to create
echo "STATE: path is clear. Safe to run:"
echo "  git worktree add -b <branch> '$target'"
```

**Usage:**

```bash
chmod +x scripts/resolve-worktree-collision.sh
./scripts/resolve-worktree-collision.sh \
    /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/split-nalar-config-profile-delete
```

---

## 9. Decision Matrix (quick reference)

| Scenario | Path registered? | Has `.git` file? | Branch exists? | Uncommitted work? | Pick |
|----------|-------------------|------------------|----------------|-------------------|------|
| A (this case) | yes | yes | yes (`refactor/...`) | yes | **A** or **D** |
| B (orphaned) | no | yes | maybe | maybe | **C.1** (prune + rm) |
| C (plain) | no | no | maybe | n/a | **C.2** (rm -rf) |
| D (branch only) | no | n/a | yes | n/a | **C.3** (`-f` flag) |
| E (clean) | no | no | no | n/a | Just `git worktree add` |

---

## 10. See Also

- Global memory: `~/.config/nalar/memories/set-git-worktree-clear-keeps-branch.md`
  — the `set_git_worktree clear=true` gotcha (orphaned branch even after
  clean removal)
- Global memory: `~/.config/nalar/memories/multi-agent-file-reverts.md`
  — when sharing a worktree across agents, expect race conditions
- Skill: `using-git-worktrees` — the canonical wrapper that should
  grow the §6.A precheck
- Local skill: `zig-slice-headers-across-defer-lifetimes/SKILL.MD` —
  unrelated but commonly referenced from worktree flows
- Plan: `docs/plans/2026-06-18-set-git-worktree-cwd-override.md` —
  parallel set_git_worktree feature work
