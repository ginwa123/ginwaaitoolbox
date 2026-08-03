# Merge pattern: cli-app branch into main (2026-08-06)

## What landed

Merge commit `f2a3d2f3 Merge branch 'worktree/cli-app' into main`. Adds
`nalarcli` — a native Zig CLI wrapper for the backend HTTP API (43 unit
tests pass, 5 subcommands: `send`, `sessions`, `messages`, `events`, `help`).

## What was tricky (worth recording)

### 1. Main already had partial cli wiring

When I started the merge, I expected cli-app to be entirely additive.
But main had ALREADY wired `cli_module` + `cli_exe` + `cli_install` +
`cli_step` (via Postgres PR #173 `ea58b0b4`, which incidentally
included the cli scaffolding). So build.zig had conflicts on EVERY
section of cli wiring, not just the new additions.

Detection: `git diff <base> main -- build.zig | head` shows main had
~111 lines of changes; `git diff <base> worktree/cli-app -- build.zig`
shows cli-app had ~131 lines. Most of those lines were OVERLAPPING
additions.

**Resolution**: take HEAD (most complete version of the cli_module +
cli_exe + cli_install + cli_step + run_cli_cmd), then surgically ADD
the cli-app's `cli_tests` + `test_cli` step + `install_cli_step`. The
`test:cli` and `install:cli` steps were missing from main.

### 2. Main had `src/apps/cli/` template files from `zig init`

Commit `77d7505b push` (a vague "push" commit on 2026-08-03) had
included the boilerplate that `zig init` generates:
- `src/apps/cli/README.md`
- `src/apps/cli/src/main.zig` (a "hello world" with a "All your X are
  belong to us" string)
- `src/apps/cli/src/root.zig` (a stub `add(a, b)` function)

These collided with cli-app's REAL CLI files at the same paths. The
merge produced `add/add` conflicts on both `main.zig` and `root.zig`.

**Resolution**: `git checkout --theirs src/apps/cli/src/main.zig
src/apps/cli/src/root.zig` — cli-app's versions are the real CLI; the
templates are garbage that should never have been committed.

### 3. AGENTS.md changelog conflict — append-only pattern

Both sides added entries to the append-only changelog. Taking just one
side drops entries from the other side.

**Resolution**: `git checkout --ours AGENTS.md` (keep main's most
recent entries), then APPEND cli-app's `### 2026-08-06: \`nalarcli\``
section to the end. This loses the chronological ordering of cli-app's
section (it happened Aug 2, but now lives at the bottom next to the
Aug 4 entries). For a personal changelog, this is acceptable; for
strict chronological order, the section should be inserted in the
right spot manually.

### 4. Other active worker in the same worktree

The main worktree had a SECOND worker (`task_1785776552601 refactor
code,`) making 77 file modifications when I started. Their changes
were uncommitted, but they were working in `src/ai_workflow/tui/agentic_loop/`
files — DIFFERENT files than the cli-app merge touches.

Key learning: I checked the intersection FIRST (`comm -12 cli_files
wt_files`) before doing anything. Empty intersection → safe to merge
without disturbing their work. Their refactor commit landed while I
was reading data (HEAD moved from `794a36c9` → `bfe53456`) — the
conflict on `build.zig` between their refactor and the cli-app's
build wiring turned out to be benign (both versions of cli_app_mod /
cli_module coexist cleanly because the variable names don't collide).

### 5. Stale AUTO_MERGE state

The `.git/AUTO_MERGE` file existed when I started (tree hash from a
previous interrupted merge). It cleared itself once HEAD advanced (the
refactor commit triggered an index refresh). No manual cleanup needed
— but if I had tried to do anything git-related while it was stale, it
could have confused the merge result.

## Verification checklist (for similar merges)

1. ✅ Check `comm -12 cli_files wt_files` — empty = safe to proceed
2. ✅ Run `git merge worktree/cli-app --no-ff -m "..."` — see what auto-merges
3. ✅ Resolve conflicts surgically:
   - `git checkout --theirs` for add/add conflicts where theirs is real
   - `git checkout --ours` then manually patch for content conflicts
   - Append for changelog files (AGENTS.md, docs/SPEC.md)
4. ✅ Verify build: `zig build --summary all` — expect all 4 binaries
5. ✅ Verify tests: `zig build test:cli --summary all` — expect 43/43
6. ✅ Cross-compile smoke: `zig build-obj -fno-emit-bin -target X` for
   Windows + macOS — expect clean (no errors)
7. ✅ Commit with descriptive message documenting the conflict resolution

## What to NOT do

- Don't blindly `git checkout --theirs` for content conflicts (loses
  main's recent entries).
- Don't blindly `git checkout --ours` for add/add conflicts (might
  pick up template garbage from `zig init`).
- Don't skip the cross-compile smoke — Zig's lazy analysis can hide
  Windows-only or macOS-only errors.

## Branch / commit

- Branch merged: `worktree/cli-app`
- Merge commit: `f2a3d2f3`
- HEAD after: `f2a3d2f3` on `main`
- Files changed: 20 (+1407/-70)
