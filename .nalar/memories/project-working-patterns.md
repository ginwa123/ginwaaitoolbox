# Project — cross-cutting working patterns

This file consolidates cross-cutting patterns that span multiple areas (research, code review, multi-agent work). For Zig-specific patterns, see the `zig-*.md` files. For nalar-specific patterns, see the `nalar-*.md` files.

---

## Cross-Check User-Provided Analysis Against Source Before Acting

When a user gives you an analysis from a third party (friend, colleague, LLM, online post) and asks you to "cross-check again" before applying the fix, the right move is to:

1. **Verify every claim with line-number + code-snippet checks** — don't trust the framing, trust the diff against the current source. Many claims in technical write-ups are directionally correct but over-state or under-state the effect ("skipped multiple times in a row" — actually impossible when `it.next()` returns each entry exactly once per iteration).

2. **Look for what the analysis MISSED** — the analysis often identifies the visible bug but misses adjacent issues in the same code path. In the SSE manager case:
   - The visible bug was POLL.NVAL subscription (correct).
   - The analysis missed: TOCTOU use-after-free in `sendHeartbeat`/`broadcast`/`broadcastTyped` (raw pointers dereferenced after `lock.unlock`).
   - The analysis missed: `last_heartbeat = timestamp()` was set BEFORE the write attempt, hiding staleness from any future periodic sweep.

3. **Verify the diagnosis, not just the proposed fix** — the diagnosis may be right but the proposed fix may be incomplete (e.g., the friend's "fix heartbeat sharding" is fine but the effect is small because every client is still in exactly one loop's slice per cycle, modulo covers all residue classes).

4. **Use static-contract tests when behavioural tests are impractical** — in this codebase, `startEventLoop` cannot be cleanly driven from a unit test (the Threaded-Io + spawned-thread pattern hangs on Zig 0.16). Static-contract tests that grep the source for the required pattern are an acceptable alternative, matching the convention already in the same file.

5. **Always do a stress test** — 20 concurrent SSE connections opened then abruptly closed via curl timeout confirmed zero leak (19 → 39 → 19 FDs). Static analysis alone would not catch a bug in the runtime path; the live test did.

### Why this matters

Without cross-check, the friend's "skipped multiple times in a row" claim would have been baked into the commit message, the PR description, and the architecture rationale — propagating a wrong claim into the project's permanent record. The PR is technically correct (the fix works), but the rationale is wrong, which is what new contributors read first.

### When this bites

- Any third-party diagnosis delivered as a markdown report or chat transcript.
- Any "trust me, the bug is X" message.
- Any task description that includes specific line numbers — verify them in the current source; the line numbers may have drifted.

### How to verify after the cross-check

For each claim, ask:
1. Is the line number still correct?
2. Is the code snippet exactly as shown?
3. Is the described effect actually what happens?
4. Does the proposed fix address the actual effect?
5. Are there adjacent issues the analysis missed?

If 1-3 are yes but 4 is no, the proposed fix is incomplete. If 1-3 are yes and 4 is yes but 5 surfaces a new bug, file the new bug separately.

---

## Multi-agent parallel execution: other workers can revert your changes

When multiple sub-agents work in parallel on the same worktree (e.g., chunks 2, 3, 4 of the same plan), other workers can `git checkout` or otherwise revert the file you just edited. The worktree is shared.

### Symptom

You finish a multi-step refactor, run the tests, see 376/379 pass, commit, then `git diff` shows only 30 lines changed instead of the 500+ you just edited. Your refactor is gone — only 1 function survived. Another worker needed the file in its pre-refactor state to test their own changes, did a `git checkout` / `git stash` / `git restore` to "temporarily revert", but then their test passed and they either (a) forgot to restore your changes, (b) only restored the parts they cared about, or (c) committed on top of the reversion.

### Why

The orchestrator prompt lists other workers running on the same worktree. They are NOT isolated from your changes — they share the same filesystem. If worker B needs to test against the pre-refactor state, they can and will revert your work.

### How to detect

- After your refactor, `git diff --stat <file>` should show hundreds of lines changed. If it shows ~30, your work was reverted.
- Compare `git log --oneline -5` before and after — new commits from other workers can be diagnostic.

### How to recover

1. **DO NOT panic-commit and re-push.** First verify with `git diff <file>` that your work is actually gone.
2. Re-apply your refactor via `text_replace` (you have the patterns memorized from your first pass).
3. **Watch for "pointless discard" errors** at this stage: when you reuse an `_ = tc;` / `_ = ctx;` line in a function whose body now actually uses the parameter, Zig 0.16 will reject it. Remove the discard.
4. Run tests, confirm the same pass/fail count, commit.

### How to prevent

- When working in a worktree shared with other workers, **commit early and often** between tasks so your work is durable.
- Prefer tasks-per-chunk that touch distinct files (chunk 2 = `tool_registry.zig`, chunk 3 = `handle_tool.zig`, chunk 4 = frontend Vue files) so cross-chunk file conflicts are minimized.
- The orchestrator should serialize chunks that share files. With parallel chunks, the later chunk's worker may revert the earlier chunk's file to get a known-good baseline.

### How to verify

- `git diff --stat <file>` shows the expected number of lines changed.
- `git log --oneline -3` shows your commit at the top of the branch.
- `timeout 180 zig build test --summary all` reports the same test count as before (e.g., 376/379 pass).

---

## Naming conventions for new tools / handlers / migrations

When adding new code in this codebase, follow the existing conventions so future contributors (and yourself) can find things:

### File names

- `*_test.zig` — companion test file. Always register in `test_runner.zig` immediately: `_ = @import("path/to/test.zig");`.
- `*_db.zig` or `model.zig` — DB layer for an entity.
- `http_handlers/<verb>_<noun>.zig` — HTTP CRUD handler (thin wrapper, see `nalar-backend-architecture.md`).

### Symbol names

- PascalCase types (`MyStruct`, `MyError`).
- snake_case functions and variables.
- `pub const Error = error{...};` defined per file/struct.

### Migration naming

`<NNN>_<short_description>.zig` with sequential NNN. Each migration exports `up(db, alloc) !void` and `down(db, alloc) !void`. Use `addColumnIfMissing` / `dropColumnIfExists` for `NOT NULL DEFAULT ''` / idempotent column adds. See `nalar-data-and-routines.md` for full migration patterns.

### Static contract tests

The project doesn't have a full handler test infrastructure. The convention is **static-contract tests** that read source files as text and grep for required substrings:

```zig
test "my handler uses parseFromSliceLeaky" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print("!! my_handler.zig does not use parseFromSliceLeaky !!\n", .{});
        return error.ParseFromSliceLeakyMissing;
    }
}
```

Test name describes the contract. Error name is the contract violation (`error.XMissing`). Register in `test_runner.zig` immediately.

---

## Smoke testing on port 8080 (NEVER 8081)

Another `nalar` process is always running on port 8081. NEVER kill it, NEVER use it for new work. Use port 8080 for any local smoke testing.

See `nalar-backend-architecture.md` for the full smoke test workflow (including the `zig build install:linux:system` workaround for getting a runnable binary).

---

## Verification before completion (the project's mandatory rule)

**No completion claims without fresh verification evidence.** Always run the necessary commands and confirm output before making any success claims. Evidence before assertions always.

For Zig changes, the canonical verification is (see `zig-build-and-test.md` for full reasoning):

```bash
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
rm -rf zig-out/bin
timeout 360 zig build
```

For Vue/TS changes (see `nalar-frontend-patterns.md` for full reasoning):

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20      # type-check + bundle
timeout 120 bunx vitest run 2>&1 | tail -n 20    # unit tests
```

---

## Related / cross-references

- `zig-0.16-stdlib-changes.md` — Zig 0.16 stdlib API changes
- `zig-language-quirks.md` — Zig language gotchas
- `zig-build-and-test.md` — build/test patterns
- `zig-cross-platform.md` — cross-platform Zig 0.16
- `zig-sqlite-patterns.md` — SQLite patterns
- `nalar-backend-architecture.md` — backend patterns
- `nalar-frontend-patterns.md` — frontend patterns
- `nalar-data-and-routines.md` — data, migrations, routines
- `nalar-infra-and-build.md` — CI, build infrastructure