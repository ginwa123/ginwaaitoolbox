# nalar — `set_git_worktree clear=true` does NOT delete the branch

The `set_git_worktree` tool with `clear: true` removes the worktree
directory and the `git worktree list` registration, but it does NOT
delete the branch the worktree was on (the auto-derived
`worktree/<basename>` branch).

## Symptom

You create a worktree with `set_git_worktree(path="/abs/path/test-foo")`,
then call `set_git_worktree(clear=true)` to clean up. The worktree is
gone, the session is un-bound, but `git branch -a` still shows:

```
  worktree/test-foo
```

The branch is now orphaned (no worktree is attached to it). It usually
sits at the same commit as the base branch (e.g. `main`) since test
worktrees rarely add commits, so it's safe to delete with
`git branch -D worktree/test-foo`.

## Fix

After `clear: true`, follow up with:

```bash
git branch -D worktree/<basename>
```

The branch name is the same as the basename of the original `path`
arg, prefixed with `worktree/`.

## When This Bites

- Any test cycle of the tool (create → verify → clear) leaves a
  dangling branch per test.
- Test worktrees in `.worktrees/` accumulate over time if the agent
  only runs `clear: true` and not the follow-up `git branch -D`.
- A worktree was created on a real feature branch (overrode the
  default `worktree/<basename>` with a custom `branch` arg) — in that
  case the worktree's branch IS a real feature branch and should
  only be deleted if the user explicitly wants to discard the work.

## How to verify

```bash
git worktree list                     # worktree is gone
git branch -a | grep worktree/        # orphaned branch may still exist
ls .worktrees/<basename> 2>&1         # directory is gone
```

The first two checks should be empty for a fully clean state.
