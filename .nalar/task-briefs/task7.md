# TASK 7 BRIEF — functional tests over the real wire

WORK DIRECTLY IN THIS EXISTING WORKTREE — do NOT call `set_git_worktree`, do NOT create a
new worktree, do NOT touch `/home/ginwa/ginwaaitoolbox`:

    /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930

`cd` there for every command. All paths below are relative to that directory.

Repo: **nalar**, Zig 0.16 backend + Vue frontend. Tasks 1–6 are committed and green: the
migration, the store, substitution + redaction, the dispatch wiring, `list_secrets`, the HTTP
surface, and the UI.

**Your job is tests only.** Create `tests/functional/workspace_secrets_test.py` and add it to
CI coverage. Do NOT modify any file under `src/` — if a test reveals a product bug, report it
and do not fix it.

Plan: `docs/superpowers/plans/2026-10-02-workspace-secrets.md` (rev 2) — `### Task 7`.

---

## Read first

`tests/functional/agent_knowledge_edit_test.py` is the worked template. Its module docstring
explains precisely why these tests exist: the first implementation of that feature passed unit
tests and still failed in real use, because `file_path: ""` hit `isAbsolute("") == false` and
`content: ""` hit the `SqliteBackend` empty-slice-binds-as-NULL trap. **Unit tests cannot see
either failure.** That is why this task exists.

Copy its shape: `_create_workspace`, `_create_agent` helpers, `harness.http(...)` with
`expect=` status codes, one test function per behaviour.

---

## HARNESS RULES — these are absolute

- **NEVER bind, kill, or touch port 8081.** It is the always-running dev server.
  `tests/functional/harness.py` declares `RESERVED_PORTS = (8081,)` and skips it.
- **NEVER verify by starting a live server and curling it.** No `nohup ./zig-out/bin/nalar … &`.
  Use `FunctionalHarness`, which boots a fresh binary against an isolated tmpdir `HOME` and
  tears both down (even on assert-fail). The anti-pattern leaks a process across tool calls
  and is exactly what missed the PR #291 bugs.
- The harness is session-scoped via the `harness` fixture in `tests/functional/conftest.py`.
  Use `from harness import FunctionalHarness` and type-annotate helpers with it, as
  `agent_knowledge_edit_test.py` does.

Run:
```bash
cd /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930
PYTHONPATH=tests/functional .venv-func/bin/python -m pytest tests/functional/workspace_secrets_test.py -q
```
If `.venv-func` does not exist, find the project's python env the way CI does and say so in
your report.

---

## The API under test

| Method | Path | Success |
|---|---|---|
| GET | `/api/workspaces/:workspace_id/secrets` | 200 `{secrets:[{id,name,created_at,updated_at}], count}` |
| POST | `/api/workspaces/:workspace_id/secrets` | 201 `{secret:{…}}` |
| PATCH | `/api/workspaces/:workspace_id/secrets/:secret_id` | 200 `{secret:{…}}` |
| DELETE | `/api/workspaces/:workspace_id/secrets/:secret_id` | 200 `{id, success}` |

Bodies: POST `{name, value}`; PATCH `{name?, value?}` — both optional, `name` not renameable.

---

## Required tests

**1. Full CRUD round-trip.** Create a secret → list it → assert `name` present and **`value`
absent from the response body entirely** (check the raw text, not just parsed keys — a stray
`"value":` anywhere is a failure) → PATCH the value → GET the single secret → DELETE →
GET returns `count: 0`.

**2. The write-only guarantee, end to end.** Assert across the whole cycle that the plaintext
value NEVER appears in ANY response body. This is the headline test.

**3. Cross-workspace isolation.** Workspace B's `GET` → `count: 0`. Workspace B's `GET` of
workspace A's secret id → **404, NOT 403**. Repeat for PATCH and DELETE. (A 403 would confirm
the id exists, which is itself a leak.)

**4. Empty value → 400, not 500.** POST `{"name":"X","value":""}` must be 400. If it is 500,
that is the `SqliteBackend` empty-slice-binds-as-NULL constraint violation reaching the wire.

**5. Duplicate name.** Same workspace → **409**. A different workspace, same name → **201**.

**6. Invalid name.** POST with a name outside `[A-Za-z0-9_-]{1,64}` → 400.

**7. Missing ids.** POST with no `name` → 400; no `value` → 400.

**8. Placeholder error, through the tool path.** This is the one that needs the agent surface.
Assert that a `{{SECRETS:UNKNOWN}}` reference produces a tool error envelope that **names
`UNKNOWN`** and dispatches nothing. If there is no practical harness path to drive a tool call,
do NOT fake it — say so in your report and mark that case as covered only by the Zig inline
test in `handle_tool.zig`. A fake test is worse than an acknowledged gap.

---

## CI shard coverage — verify, do not assume

Functional tests are sharded by `tests/func_shard.py`, and `select()` is **modulo over the
whole collected ITEM list**, not per-file. So adding a file silently changes which tests land
in which shard. Verify your module is actually collected:

```bash
PYTHONPATH=tests/functional:tests/functional_ui \
NALAR_FUNC_SHARD_INDEX=0 NALAR_FUNC_SHARD_TOTAL=3 \
  .venv-func/bin/python -m pytest tests/functional/ tests/functional_ui/ --collect-only -q
```
The output is a **tree** (`<Module …>` / `<Function …>`), not node IDs — count `<Function`
lines under your module, not occurrences of the filename. A correct partition sums to the
unsharded total with zero overlap. Paste the count in your report.

---

## Also re-run the backend gate

The Zig side changed a lot since the last full run:

```bash
zig build test --summary all
```
Expect `Build Summary: 8/8 steps succeeded`. Two known quirks: it prints a spurious
`failed command: .../test --listen=-` line immediately before the success summary (NOT a
failure), and the cold build takes 10+ minutes. Never run two `zig build test` concurrently —
they contend on `.zig-cache`.

---

## Commit

```
test(secrets): functional coverage for CRUD, isolation, and validation
```

---

## HARD CONSTRAINTS

- Tests only. No changes under `src/`. Report product bugs; do not fix them.
- Never port 8081. Never a live server + curl.
- Assert on the **raw response text** when checking that a value is absent — a parsed-JSON
  check can miss a stray field.
- If a test is not practically writable, say so explicitly rather than writing a test that
  passes for the wrong reason.

## REPORT BACK

Files changed, commit sha, the pytest summary line, the shard-coverage count, the `zig build
test` Build Summary line, which of the 8 required tests you wrote, and anything you could not
cover with the reason.