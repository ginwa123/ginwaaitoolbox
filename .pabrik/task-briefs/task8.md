# TASK 8 BRIEF — final gates, docs, PR

WORK DIRECTLY IN THIS EXISTING WORKTREE — do NOT call `set_git_worktree`, do NOT create a
new worktree, do NOT touch `/home/ginwa/ginwaaitoolbox`:

    /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930

`cd` there for every command.

Tasks 1–7 are committed. Your job is **verification, documentation, and the PR**. Do NOT
change product code. If a gate fails because of a product bug, report it — do not fix it.

---

## STEP 1 — run every gate and capture real output

Run all four. Paste the actual output into your report; do not paraphrase.

```bash
cd /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930

zig build test --summary all

cd src/apps/desktop
npx vue-tsc --noEmit
npx vitest --run src/__tests__/SecretsSection.spec.ts
cd ../..

PYTHONPATH=tests/functional .venv-func/bin/python -m pytest \
  tests/functional/workspace_secrets_test.py -q
```

Known quirks so you do not chase phantoms:
- `zig build test` prints a spurious `failed command: .../test --listen=-` line immediately
  BEFORE the success summary. **Not a failure.** Trust `Build Summary:` and the exit code.
- Cold Zig build ≈ 10+ min. Never run two concurrently.

---

## STEP 2 — correct the plan doc to match what shipped

Read `docs/superpowers/plans/2026-10-02-workspace-secrets.md` (rev 2) against the actual
implementation and fix what the implementation superseded. Known drifts:

1. **The plan's Wire Contract lists a `GET .../secrets/:secret_id` route that was never
   built, and the task-7 brief wrongly assumed it existed.** There is deliberately **no
   read-by-id route** — write-only is then structural (absent from the route table) rather
   than a property of one response struct. Record that as an explicit design decision; it is
   strictly stronger than what the plan described, and the functional suite covers it as a
   404.
2. **`idx_workspace_secrets_workspace` was dropped.** The plan asked for two indexes on the
   same column pair; the unique index already serves the lookup.
3. **The plan's Task list has 8 tasks, all now complete.** Mark them and add a short
   "What actually shipped" section summarising the real commit list.

Do NOT rewrite the design decisions — record outcomes and add new ones where reality differs.
Keep the plan's original reasoning visible; it is what makes the deviations legible.

---

## STEP 3 — check the docs index

Plan: `docs/superpowers/plans/2026-10-02-workspace-secrets.md`. Check whether
`docs/SPEC.md` indexes plans and needs an entry. (A prior investigation found `docs/SPEC.md`
is a *historical* inventory of documents that no longer exist, not a live index — verify
rather than assume, and if no edit is needed, say so.)

---

## STEP 4 — push and open the PR

Branch is `worktree/implement-new-features-name-secrets-1790968240930`. **PR #783 already
exists for this branch** (it was the plan-only PR). Update it rather than opening a new one:
push the commits and edit the existing PR body with `gh pr edit`.

PR body must contain:

- **Goal** — per-workspace secrets; the model references `{{SECRETS:NAME}}` and never
  receives the value.
- **What shipped** — the 8 commits, one line each.
- **The guarantee and exactly how it is enforced** — this is the part a reviewer must be
  able to check. Name the mechanism and the test that pins it:
  substitution at two dispatch points, parse-and-re-serialize (never raw bytes), redaction
  at every persist site, `llm_history` retaining the placeholder, and the test that proves
  the plaintext never appears in any response body across a full lifecycle.
- **Traps closed** — with `path:line`:
  - MCP tools bypass `dispatchTool`, so a single hook silently skips them
  - `shell.zig` echoes the substituted command into the tool result
  - raw-byte substitution breaks JSON and two consumers fail *silently*
  - route-order shadowing on both the backend and the Vue router
  - empty-slice binds as SQL NULL
- **Honest limitations** — restate, do not bury:
  - values are stored **plaintext** (reviewer decision); the substitution-path guarantee is
    unchanged, but anything that can read `agent.db` reads every secret, and the agent itself
    can (`command` → `bash -c`, no allowlist; `read_file` has no sandbox)
  - redaction is best-effort substring replacement — a value a tool base64s or splits is
    not caught
  - membership-only access: a `viewer`-role member can rotate any secret (roles deferred)
  - no read-by-id route
- **Gates** — the real output from Step 1, not a claim.
- **Not claimed:** pre-push hooks do not run in worktrees (`.husky/_` is uncommitted), so no
  local hook result is asserted.

---

## STEP 5 — update the task ledger

`.nalar/secrets-tasks.md` — mark all tasks done with their commit shas. Commit the briefs in
`.nalar/task-briefs/` too (they are currently untracked) — they are the record of what each
agent was told, and two of them contain corrections the agents found.

---

## HARD CONSTRAINTS

- No product-code changes. Report bugs; do not fix them.
- Do not claim a gate passed without having run it and pasted its output.
- Never touch port 8081.

## REPORT BACK

Every gate's real output, what you corrected in the plan doc, whether `docs/SPEC.md` needed
an entry, the PR URL, and the commit sha of the ledger/brief commits.