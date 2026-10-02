---
name: ginwaaitoolbox-zig-change-gate-and-push
description: "How to make a Zig change in the ginwaaitoolbox repo, prove it green, and commit+push it without tripping zig fmt, the GIT_DIR pre-push trap, or the noisy zig build test summary. Use for any src/**/*.zig edit here."
---
---
name: ginwaaitoolbox-zig-change-gate-and-push
description: How to make a Zig change in the ginwaaitoolbox repo, prove it green, and commit+push it without tripping zig fmt, the GIT_DIR pre-push trap, or the noisy zig build test summary. Use for any src/**/*.zig edit here.
is_global: false
---
# Zig change → gate → commit → push in ginwaaitoolbox

## When to Use
Any edit under `src/**/*.zig` in `/home/ginwa/ginwaaitoolbox` (or its worktrees),
when the task ends in "commit + push". Pairs with the general
`verification-before-completion` skill; this one is the repo's mechanics.

## Procedure
1. **Reproduce the failure first.** `zig build 2>&1 | tail -30` — read the error's
   *referenced by* trail, then `git blame -L <line>,<line> <file>` to find which
   commit introduced the bad line. The introducing commit is usually where the
   real bug is, not the line in front of you.
2. **Fix in the file's existing hand style. NEVER run `zig fmt`.** Zig 0.16's fmt
   rewrote 233 lines of a file where I had touched ~40. See Pitfalls.
3. **Cover it with a test in the same file**, asserting every value the code path
   moves — index-mapped SQL reads silently mis-map, so one assertion per column
   with values no other column holds.
4. **Compile gate:** `zig build` — must be silent of `error:`.
5. **Test gate:** `zig build test --summary all 2>&1 | tail -40` and read
   `Build Summary: N/N steps succeeded; X/Y tests passed (Z skipped)` plus
   `echo $?` → 0. Do not judge by the last lines — see Pitfalls.
6. **Frontend gate** (only if you touched `src/apps/desktop` or CI triggers it):
   `cd src/apps/desktop && pnpm run lint:check` and `pnpm run build`.
7. **Commit.** The pre-commit hook runs `lint:check`; let it run (it is ~10 s).
8. **Push with `--no-verify`**, then ALWAYS `git log --oneline -4` and check for
   empty `init` commits before reporting done.
9. Report the gate numbers, not adjectives.

## Pitfalls (all hit for real on 2026-10-02, fix `d181ffd2`)
- **`zig fmt` is not a gate and is destructive here.** `.github/workflows/ci.yml:210`
  states the tree is deliberately not fmt-clean. `zig fmt --check <file>` failing
  on a file you edited is expected and says nothing about your edit. Recovery:
  `git checkout -- <file>` and re-apply via a python exact-string patch — NOT by
  hand, and NOT through a bash heredoc (it mangles long multi-line literals).
- **`zig build test`'s trailing `failed command: ./.zig-cache/o/<hash>/test …`**
  is captured stderr from a test that asserts on a failing child command. A green
  run prints it. Trust `Build Summary` + exit code only.
- **Never run the test binary by hand with `--listen=-`** — no build server on the
  other end → `panic: internal test runner failure: ReadFailed`, which reads like
  a test failure. Without `--listen=-` it runs fine and prints `N passed; N skipped; 0 failed.`
- **`git push` exports `GIT_DIR` for hooks**, and the hook's `zig build test`
  makes `set_git_worktree` tests commit `init` into your live branch. Gate by hand,
  push with `--no-verify`, then check the log.
- **A stray `worktree/wt` branch blocks `zig build test`.** It comes from a test
  fixture left inside `.zig-cache/tmp`. If `git worktree list | grep -F worktree/wt`
  shows no live registration: `git worktree prune` then `git branch -D worktree/wt`.
- **No test subset exists on `main`** — no `-Dtest-filter` option (that lives on
  the `worktree/fix-skipped-tests` branch). Run the whole suite.
- A stray `zig test --listen=-` compiler holds the build-cache lock and makes every
  later build look hung: `pgrep -af "listen=-"`.


## The project hook formats .zig for you (added 2026-10-03)

`.nalar/hooks/register_hook.lua` formats edited files on `post_tool_use`:
prettier for `.vue/.ts/.mts/.tsx`, `zig fmt` for `.zig`. **You do not need
to run `zig fmt` yourself on a file the agent just edited** — it is done
automatically. (That is separate from the rule above about never using
`zig fmt` as a manual tidy-up step on a file you did not mean to reformat.)

`zig fmt` rewrites the WHOLE file. A file that was not already fmt-clean is
swept canonical across its whole contents on the agent's first edit to it.
The owner confirmed that churn is acceptable — it is the point of formatting
— so the hook is ungated: no `git show HEAD:` probe, no history check.

**Vendored-Lua gotcha that shapes any hook written here:** `io.popen` is NOT
available. `vendor/lua/liolib.c` compiles it only under `LUA_USE_POSIX` /
`LUA_USE_WINDOWS`, and `build.zig` defines neither, so it resolves to the
ISO-C stub that raises `'popen' not supported` at runtime. Use `os.execute`
(`true` on success, `nil, "exit", code` on non-zero) with shell redirection,
plus `os.tmpname()` / `os.remove()` for temp files.

Test the hook file directly — fast, and no nalar binary needed. The vendored
Lua is 5.4.9, identical to system `lua5.4`, so the real file runs under the
system interpreter:

    uv run --with pytest python -m pytest tests/functional/hook_zig_fmt_test.py -v

Plain `python3 -m pytest` fails here — the system python has no pytest; use
`uv run --with pytest`.
