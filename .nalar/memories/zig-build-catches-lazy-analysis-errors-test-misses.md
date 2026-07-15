# zig build catches lazy-analysis errors zig build test misses

In Zig 0.16, `zig build test` and `zig build install:linux:system` (or any
`addExecutable` step) compile **separate module graphs** rooted at different
files. The test target's graph is rooted at the test runner and may not reach
production code paths via lazy analysis. The install target's graph is rooted
at `main.zig` and DOES reach them.

## Symptom

You fix a handler bug, run `zig build test` — **1008/1011 pass** — commit,
push, and the CI / user reports the binary crashes on startup with a cryptic
type error. The error was always there in the production code path; the test
target's lazy analysis just never reached the offending line.

## Real example (this project, 2026-07-08)

`src/ai_workflow/tui/http_handlers/nalar_config_put.zig:121` was:

```zig
if (std.fmt.parseInt(usize, mt, 10)) |parsed| {
    config_json.max_tokens = parsed;   // ← BUG: parsed is usize, field is ?[]const u8
}
```

The test file `nalar_config_put_parse_test.zig` only exercises
`parseConfigInput` (the parse step) — it never reaches the apply block at
line 121. So `zig build test` reported green (1008/1011) and
`zig build install:linux:system` also reported "4/6 steps succeed" (the cp
fails harmlessly on `/usr/local/bin/nalar` permission, masking the missing
`compile exe nalar` check). **Only `zig build`** caught the type error:

```
src/ai_workflow/tui/http_handlers/nalar_config_put.zig:121:42: error:
  expected type '?[]const u8', found 'usize'
```

## Fix (project pattern)

After any change to a production handler / module that flows into the
`addExecutable` binary, **always run all three** (and force a fresh
`zig build` by wiping the output — see "Cache caveat" below):

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
rm -rf zig-out/bin                                  # ← MANDATORY
timeout 360 zig build                                # fresh build step
```

The fourth one is what catches the bug. Per the project memory
`verification-before-completion` ("NO COMPLETION CLAIMS WITHOUT FRESH
VERIFICATION EVIDENCE"), claim success only after all four pass.

## Why the three checks are not equivalent

| Check | Module graph | Reaches private helpers in production? | Catches `addExecutable`-only errors? |
|---|---|---|---|
| `zig build test` | Rooted at test runner | Lazy — only the public API used by tests | **No** |
| `zig build install:linux:system` | Rooted at `main.zig` → `nalarcore` | Yes, but the cp-to-`/usr/local/bin/nalar` step fails harmlessly and **masks** the build result | Partial (the `compile exe nalar` step may also be cached/skipped) |
| `zig build` (without `rm -rf zig-out/bin`) | Rooted at `main.zig` → `nalarcore` + nalar-desktop | Yes, BUT the output is cached — a stale `zig-out/bin/nalar` from a prior partial build is reported as "success" even if the current source would fail | **Partially** (the print at the end says "zig build success" but it can be lying) |
| `rm -rf zig-out/bin && zig build` | Rooted at `main.zig` → `nalarcore` + nalar-desktop | Yes, AND the output is rebuilt from scratch, so a real error will surface as a non-zero exit | **Yes** |

`zig build install:linux:system` is the closest to a real production build,
but on a non-root machine the cp step fails and the wrapper exits 1 even
when the compile succeeded. `zig build` skips the cp step and gives a
clean success/failure based purely on the compile result — BUT the result
may be a stale cached binary from a prior partial build. The `rm -rf
zig-out/bin` step is what forces a clean re-link.

## Cache caveat (this is the bite I had)

`zig build` uses `.zig-cache/` and the binaries in `zig-out/bin/` as its
build artifact cache. If a prior `zig build` left a partial state (e.g. a
successful `compile exe nalarcore` but a failed `install nalar` step — which
is exactly what happens on the lazy-analysis bug above), subsequent `zig
build` runs may see the `nalar` binary as "up to date" and skip the
compile, even if the current source has type errors.

The build summary helpfully prints this warning:

```
nalar service binary  →  zig-out/bin/nalarcore-linux-x86_64
nalar desktop binary  →  zig-out/bin/nalar-desktop

(If a binary is missing, run `rm -rf zig-out/bin && zig build`
 to force a fresh install — the cache sometimes hides
 manual deletions.)
```

When the lazy-analysis bug bites, the `nalar` binary IS missing (because
the `install nalar` step failed), but a stale `nalarcore-linux-x86_64` from
a prior run may already be in `zig-out/bin/`. Running `zig build` again
sees the stale `nalarcore` as up-to-date, skips the compile, and reports
`[zig build success]` even though the current source would fail.

**The fix is always to start the verification with `rm -rf zig-out/bin`**
to clear the partial-state cache. This forces every step to re-run, so
the actual compile errors surface.

## The deeper pattern (Zig 0.16 lazy analysis)

A test target's module graph is rooted at the test runner. The runner
imports test files. Test files import production code's public API. Private
helpers that aren't transitively reachable from a tested function are
**not type-checked** in the test build.

This is documented in:
- `zig-0.16-t-to-t-param-becomes-const` (different manifestation, same cause)
- `nalar-build-cross-compile-blocked` (cross-compile lazy analysis trap)
- `zig-migration-tests-three-pitfalls` (lazy analysis + SQL migrations)
- `zig-0.16-spawn-cwd-is-not-nullable` (`spawn` in private helper misses test target)
- `nalar-website-auth-zig-error-set-lazy-analysis-bug` (error set hidden until lib_tests references it)
- `nalar-config-put-per-profile-compaction-options` (production-side `catch` arm narrows inferred set; install target catches it)

All seven follow the same pattern: **the test target's lazy analysis hides
errors that only the full `addExecutable` graph reveals**.

## When this bites

- Any new HTTP handler (the test file imports only the public parse helper;
  the apply block is invisible to the test target).
- Any new private helper called from a tested function with `catch` arms
  that change the inferred error set.
- Any new code path guarded by `if (cond) { production_code() }` that the
  test target never exercises.
- Any new `std.json.parseFromSliceLeaky` + apply block — the parser test
  is decoupled from the apply test.
- Any cross-platform code change where the test target runs on a single
  platform and the `addExecutable` target crosses to a different one.

## How to verify after a fix

After amending the production code, run all three in order:

```bash
timeout 180 zig build test --summary all      # 1. test target
timeout 180 zig build install:linux:system    # 2. install target
timeout 300 zig build                          # 3. full build target
```

If all three succeed, the change is correct. If `zig build` fails, the test
target's lazy analysis missed a real production-code error — fix the
production code, re-run all three.

## Concrete precedent in this repo

`src/ai_workflow/tui/http_handlers/nalar_config_put.zig:121` (PUT-400 fix,
commit `b39ea449`, branch `worktree/config-compact`, PR #81). The lesson is
baked into the commit message so future contributors see it from
`git log --grep='PUT 400'`. The PR body also includes the lesson so
reviewers see it during code review.
