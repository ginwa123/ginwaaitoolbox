# Cross-Check User-Provided Analysis Against Source Before Acting

When a user gives you an analysis from a third party (friend, colleague,
LLM, online post) and asks you to "cross-check again" before applying
the fix, the right move is to:

1. **Verify every claim with line-number + code-snippet checks** —
   don't trust the framing, trust the diff against the current source.
   Many claims in technical write-ups are directionally correct but
   over-state or under-state the effect ("skipped multiple times in a
   row" — actually impossible when `it.next()` returns each entry
   exactly once per iteration).

2. **Look for what the analysis MISSED** — the analysis often
   identifies the visible bug but misses adjacent issues in the same
   code path. In the SSE manager case:
   - The visible bug was POLL.NVAL subscription (correct).
   - The analysis missed: TOCTOU use-after-free in
     `sendHeartbeat`/`broadcast`/`broadcastTyped` (raw pointers
     dereferenced after `lock.unlock`).
   - The analysis missed: `last_heartbeat = timestamp()` was set
     BEFORE the write attempt, hiding staleness from any future
     periodic sweep.

3. **Verify the diagnosis, not just the proposed fix** — the
   diagnosis may be right but the proposed fix may be incomplete
   (e.g., the friend's "fix heartbeat sharding" is fine but the
   effect is small because every client is still in exactly one
   loop's slice per cycle, modulo covers all residue classes).

4. **Use static-contract tests when behavioural tests are
   impractical** — in this codebase, `startEventLoop` cannot be
   cleanly driven from a unit test (the Threaded-Io + spawned-thread
   pattern hangs on Zig 0.16). Static-contract tests that grep the
   source for the required pattern are an acceptable alternative,
   matching the convention already in the same file.

5. **Always do a stress test** — 20 concurrent SSE connections
   opened then abruptly closed via curl timeout confirmed zero leak
   (19 → 39 → 19 FDs). Static analysis alone would not catch a bug
   in the runtime path; the live test did.

## Why this matters

Without cross-check, the friend's "skipped multiple times in a row"
claim would have been baked into the commit message, the PR
description, and the architecture rationale — propagating a wrong
claim into the project's permanent record. The PR is technically
correct (the fix works), but the rationale is wrong, which is what
new contributors read first.

## When this bites

- Any third-party diagnosis delivered as a markdown report or chat
  transcript.
- Any "trust me, the bug is X" message.
- Any task description that includes specific line numbers — verify
  them in the current source; the line numbers may have drifted.

## How to verify after the cross-check

For each claim, ask:
1. Is the line number still correct?
2. Is the code snippet exactly as shown?
3. Is the described effect actually what happens? (Trace
   `it.next()`, count loop iterations, etc.)
4. Does the proposed fix address the actual effect?
5. Are there adjacent issues the analysis missed?

If 1-3 are yes but 4 is no, the proposed fix is incomplete. If
1-3 are yes and 4 is yes but 5 surfaces a new bug, file the new
bug separately.