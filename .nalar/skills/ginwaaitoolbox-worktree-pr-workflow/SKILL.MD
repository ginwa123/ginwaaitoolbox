---
name: ginwaaitoolbox-worktree-pr-workflow
description: "How to make changes in the ginwaaitoolbox repo — the main path is a BARE repo, so every change happens in a git worktree under .worktree/worktrees_agent_<name>, then commit, push, and open a PR with gh."
---
---
name: ginwaaitoolbox-worktree-pr-workflow
description: How to make changes in the ginwaaitoolbox repo — the main path is a BARE repo, so every change happens in a git worktree under .worktree/worktrees_agent_<name>, then commit, push, and open a PR with gh.
tags: [workflow, environment, git, ginwaaitoolbox]
---

## When to Use

Any task in `ginwaaitoolbox` that produces a file change (code, docs, plans) and will be reviewed by a human — i.e. basically every implementation/planning task on the kanban board. Trigger phrases: "use git worktree", "open a PR", "move to in_review_*".

## Context

- `/home/ginwa/ginwaaitoolbox` is a **bare** repo (`git rev-parse --is-bare-repository` → `true`, HEAD → `refs/heads/main`). Source files exist there and `zig build`/tests run there (the dev server on 8081 runs from there), but `git status` fails with `fatal: this operation must be run in a work tree` — you **cannot commit** from that path.
- Remote: `origin https://github.com/ginwa123/ginwaaitoolbox.git`, `gh` authenticated as `ginwa123`.
- Local `main` may be ahead of `origin/main` (2026-09-11: `2822263b` vs `d6c57e15`). A worktree created from local main carries those commits into the PR diff.
- Agent worktrees live at `/home/ginwa/ginwaaitoolbox/.worktree/worktrees_agent_<name>` (singular `.worktree`); older human worktrees live at `.worktrees/<name>` (plural).
- Port **8081 is a never-kill dev server**; functional tests must use another port (the harness randomises 40000–60000 and explicitly reserves 8081).

## Procedure

1. Call `set_git_worktree` with `path=/home/ginwa/ginwaaitoolbox/.worktree/worktrees_agent_<shortname>` (parent must exist). It creates the worktree and binds the session cwd; the branch becomes `worktree/worktrees_agent_<shortname>`. All later `bash`/`read_file`/`write_file` calls operate inside it.
2. Do the work. Run the repo's own gates from inside the worktree (`zig build test --summary all`, plus functional tests — see Pitfalls for the binary rebuild).
3. Stage + commit **per task** with a conventional message (`feat(...)`, `fix(...)`, `docs(...)`).
4. Push: `git push --no-verify -u origin <branch>`. Use `--no-verify` **only** for docs-only commits (see Pitfalls). For code commits, either run the gates the hook runs, or accept the hook running them.
5. Open the PR: `gh pr create --base main --head <branch> --title "..." --body-file /tmp/pr_body.md` (write the body to a file first — avoids shell quoting hell with backticks/markdown).
6. Report the PR URL in the final reply and move the kanban card to the review column (`in_review_planning` for a plan, `in_review_task` for delivered work).

## Pitfalls

- **`git status`/`git commit` at `/home/ginwa/ginwaaitoolbox` fails** ("must be run in a work tree"). Never try to fix it; just work in the worktree. `git -C <worktree> …` always works.
- **`.husky/pre-push` mirrors CI**: it runs `zig build test nalar-desktop`, the Python functional suite, the UI suite, and `pnpm run build` in `src/apps/desktop`. In a *fresh* worktree this is a cold full compile (10–30+ min) and cannot exercise a markdown-only change → use `git push --no-verify` for docs commits and disclose it in the PR body. A pre-commit hook can be skipped with `git -c core.hooksPath=/dev/null commit …`.
- **Functional tests do NOT use a fresh binary unless you rebuild it**: `zig build nalar-desktop` rebuilds the desktop app, *not* `zig-out/bin/nalarcore-linux-x86_64`. Run `zig build install:linux` first, then `NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 python3 -m pytest tests/functional/<file>_test.py -v`.
- **Never touch the process on port 8081** and never bind it in tests.
- **New worktree = empty `zig-out`/`.venv-func`**: the first build is slow; the functional venv is bootstrapped by `zig build functional-test` (or reuse `/home/ginwa/ginwaaitoolbox/.venv-func` via `NALAR_FUNC_VENV_DIR`).
- **Local main ahead of origin/main** → the PR shows extra commits. Disclose in the PR body, or rebase the plan/feature commit onto `origin/main` if the reviewer wants a clean diff.

## Verification

- `git -C <worktree> log --oneline -2` shows your commit on `worktree/worktrees_agent_<name>`.
- `git -C <worktree> status --short` is clean.
- `gh pr view <url>` resolves and the base is `main`.
- The gates you claim in the PR body were actually run in the worktree (paste the summary lines: `N/N tests passed`).

