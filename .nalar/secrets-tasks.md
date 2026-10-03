# Secrets implementation — task ledger

Plan: `docs/superpowers/plans/2026-10-02-workspace-secrets.md` (rev 2)
Worktree: `~/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930`
Branch: `worktree/implement-new-features-name-secrets-1790968240930`

Pre-flight (2026-10-03):
- `main` merged (5 commits: PR #781 workspace_members, PR #780 web_search).
- Every `path:line` in the plan re-audited post-merge; 16 pointers corrected.
- Migration **101** re-verified free in the merged tree (max is 100).

| # | Task | State | Commit |
|---|---|---|---|
| 1 | Migration 101 + `secrets_store.zig` | **done** | `71a99e08` (+`f6a6b1ca`) |
| 2 | `secrets_substitution.zig` (substitute + redact) | **done** | `d44ae03f` |
| 3 | Wire dispatchTool + MCP branch; assert DB keeps placeholder | **done** | `afe9b807` |
| 4 | `list_secrets` tool + registry + allowlist bypass + prompt rule | **done** | `6a51add6` |
| 5 | HTTP handlers + routes | **done** | `6fb86c65` |
| 6 | Frontend: client, store, section, route | **done** | `b8024879` |
| 7 | Functional tests over the real wire | **done** | `d63a97ee` |
| 8 | Docs + PR | in progress | pending |

Gate for every task: `zig build test` green (plus `vue-tsc` + vitest from Task 6 on).

## Progress log

- Tasks 1 + 2 dispatched in parallel (independent leaf modules). Both landed in
  the same worktree.
- Gate after both, plus two fixes found in review: `8/8 steps succeeded;
  4352/4362 tests passed (10 skipped)`, exit 0. Note: the run emits a spurious
  `failed command: .../test --listen=-` line immediately BEFORE the success
  summary — it is not a failure signal. Trust the Build Summary + exit code.
- 11 tests in `secrets_store.zig`, 15 in `secrets_substitution.zig`.
- Task 2's module verified pure: imports only `std`; the `handle_tool` /
  `File` grep hits are all `//!` doc comments.
- REVIEW FIXES applied to Task 1:
  1. Dropped `idx_workspace_secrets_workspace` — byte-identical column pair to
     `uq_workspace_secrets_name`; a unique index already serves the lookup.
  2. Added the `workspace_secrets` child-delete to `workspace_delete.zig`, which
     the Task 1 brief had omitted.

## Non-negotiables (from the plan's Global Constraints)

- NEVER bind or kill port 8081. Never verify HTTP with a live `nalar` + `curl`;
  use `tests/functional/harness.py`.
- `SqliteBackend.exec` binds `""` as SQL NULL → every `NOT NULL` TEXT column is
  written `COALESCE(NULLIF(?, ''), '')`.
- No `user_id` on `workspace_secrets`. Access = workspace membership via
  `workspace_members`, enforced by `auth_common.workspaceVisibilityClause` +
  `canSeeWorkspace`. Do NOT add an owner column (DD11).
- Plaintext `value` column — no master key, no encryption (DD2).
- No `key_hint` column; the UI renders "configured" (DD9).
- No `// NEW (plan: ...)` tags in new code.
- Tasks 5 and 6 dispatched in parallel (Zig handlers vs frontend, disjoint trees).
- Task 8's agent was cut off before committing; the final gates, plan-doc rev 3 and
  PR update were completed in-session.

## FINAL GATES (all run, all green)

- `zig build test --summary all` -> `Build Summary: 8/8 steps succeeded; 4407/4417
  tests passed (10 skipped)`, exit 0
- `npx vue-tsc --noEmit` -> exit 0
- `npx vitest --run src/__tests__/SecretsSection.spec.ts` -> 16 passed
- `pytest tests/functional/workspace_secrets_test.py` -> 9 passed

## Deviations from the plan (recorded in plan rev 3)

1. No `GET .../secrets/:secret_id` route - write-only is structural, not a per-struct property.
2. Dropped `idx_workspace_secrets_workspace` (duplicate of the UNIQUE index).
3. `root.zig` test-discovery imports were required; without them none of the new inline
   tests compile into the test binary and the build reports green vacuously.
4. The Lua POST-hook still sees substituted args + unredacted output. Design Decision 3
   pins only the pre-hook. Left alone deliberately; flagged for a future decision.
