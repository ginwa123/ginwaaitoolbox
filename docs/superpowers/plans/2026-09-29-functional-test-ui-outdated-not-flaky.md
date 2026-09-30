# functional-test-ui: outdated, not flaky

**Run:** <https://github.com/ginwa123/ginwaaitoolbox/actions/runs/36610133932/job/109560826036>
**Job:** `functional-test-ui (ubuntu-24.04)` — 29 failed / 58 passed in 15m45s
**Verdict:** both failure classes are **outdated tests**, reproducible 100% of the
time on a laptop. Nothing here is a flake.

The job has been red for at least five consecutive runs
(36595467134, 36595902957, 36601800648, 36602679747, 36610133932), which is the
tell: a flaky suite goes green sometimes.

---

## A. `harness_safety_test` asserts a port range the picker stopped using

```
FAILED tests/functional_ui/harness_safety_test.py::test_find_free_vite_port_returns_port_in_range
AssertionError: vite port 20810 fell outside the configured range [40000, 60000]
```

`f131e6c4` ("exit cleanly on an occupied port; move harness ports out of the
ephemeral range") moved the shared random range:

```python
# tests/functional/harness.py
RANDOM_PORT_START = 20000   # was 40000
RANDOM_PORT_END   = 32000   # was 60000
```

40k-60k sat entirely inside Linux's default `net.ipv4.ip_local_port_range`
(32768-60999), so a probe `bind()` could be stolen by an outgoing connection
before the child bound its real listener. The move was deliberate and correct.

`_find_free_vite_port` delegates to `find_free_port_random(reserved=…)`, which
picks from the new range. But `ui_harness.py` kept a private copy of the old
numbers "retained for the harness_safety_test contract" — and the test asserted
against that copy. Since the whole new range is below 40000, the assertion can
never hold: **0 passes in 20 local runs**, no browser, no server, no timing.

**Fix:** `VITE_PORT_START` / `VITE_PORT_END` now re-export `harness.RANDOM_PORT_*`
instead of carrying their own literals, so the contract test and the picker
cannot drift apart again. The stale 40k-60k references in both `README.md` files
and two docstrings were corrected at the same time.

```
tests/functional_ui/harness_safety_test.py .................  17 passed
```

---

## B. 22 Playwright timeouts: the chat deep-link contract changed under the tests

Every failing browser test is a `TimeoutError` on a chatview selector. The cause
is a product change the tests were never updated for, not a slow runner.

### The change

`6b0d2b36` (2026-09-23, plan `2026-09-22-revamp-ui-chats`) moved the app from
query URLs to path URLs and made the legacy chat URL **fail closed**:

```ts
// src/apps/desktop/src/components/AppLayout.vue — bootLegacyChat()
const wsId = await api.getSessionWorkspaceId(sessionId)   // GET /api/llm/session/:id
navigationStore.setActiveChat(sessionId, navigationStore.activeChatName)
if (!wsId) {
  router.replace({ path: '/app', query: keep })   // ← fail closed
  workspacesStore.initializeFromSystemFolder()
  return
}
router.replace(buildAppUrl({ workspaceId: wsId, chatSessionId: sessionId, ... }))
```

The module header says it outright: *"Unresolvable sessions/tasks fail closed to
`/app` (never render a chat under the wrong workspace path)."*

### Why the tests fall into it

`DbSeed.seed_session` inserts `(id, name, status, cwd)` and never
`sessions.workspace_id`. So every seeded session is unresolvable, and every
legacy URL lands on `/app`.

### Proof (in-page probe, no guessing)

Driving the same URL the tests use and logging every network event:

```
### url=http://127.0.0.1:25738/app?view=chat&session=sess_probe_001
### REQUESTS WITH /api ###
  REQ GET http://127.0.0.1:25738/api/auth/me        ← the ONLY api call
### URL AFTER LOAD ### http://127.0.0.1:25738/app     ← query string dropped
### BODY TEXT ###
  Select workspace / Settings / New Chat / RECENT / Probe Chat / now
  PROJECTS / No workspace selected.
  ✦ nalar — AI AGENT WORKSPACE — Create a workspace …
```

347 responses, one API call, and the rendered body is `Chats.vue`'s landing
page — not `<ChatView>`. The boot rewrite did exactly what it was told.

Ruled out along the way: the Vite proxy is fine (`curl` through it returns
`/api/auth/me` in 0.02s), the backend is fine (200 in 0.01s), Chromium reports
no console or page errors. Nothing is timing out at the transport layer.

### The tell in the repo

Three newer test files already do the migrated thing, and they pass:

| file | URL | in the failing set? |
|---|---|---|
| `chatview_slow_server_empty_state_ui_test.py` | `/app/{ws}/chat/{sid}` | no |
| `chatview_send_scrolls_to_bottom_ui_test.py` | `/app/{ws}/chat/{sid}` | no |
| `chatview_floating_composer_test.py` | `/app/{ws}/chat/{sid}` | no |
| `chatview_ui_test.py` (8/22 old) | `?view=chat&session=` | **yes** |
| `terminal_sidebar_ui_test.py` | `?view=chat&session=` | **yes** |

All 58 passing tests are the migrated ones; all 29 failures are the ones still
on the pre-2026-09-23 contract.

### Fix

New shared helper `tests/functional_ui/chatview_boot.py`:

- `create_workspace(h)` — mint a workspace through the backend API. Workspaces
  are filesystem entries, not rows, so a SQLite INSERT is not enough.
- `bind_session_workspace(conn, ws, sid)` — point `sessions.workspace_id` at it
  so the session-detail endpoint agrees with the deep link.
- `open_chatview(page, h, ws, sid)` — navigate `/app/{ws}/chat/{sid}`, the shape
  `parseAppPath` classifies as `kind: 'chat'` and `handleBootUrl` adopts
  synchronously.

Ten legacy files migrated to it (their private `_open_chatview` copies deleted,
so the next routing change is a one-file fix). `chatview_slow_server…` and
`chatview_send_scrolls_to_bottom…` still carry their own copies; folding them in
is a follow-up, not a blocker.

Before/after on the biggest file:

```
chatview_ui_test.py  9 failed → 9 passed
```

Full suite:

```
29 failed, 58 passed   →   5 failed, 82 passed
```

---

## C. The 5 that remain are a DIFFERENT bug — and it is in the product

After the migration the chatview mounts, so three `terminal_sidebar` tests get
past `How can I help you?` and fail one layer deeper, on
`terminal-session-chip`. That is a genuine backend defect, not a stale test.

The chatview resolves the right-sidebar terminal's cwd from the **history**
response — `api/index.ts:1956`: *"Use the same endpoint as getChatHistory - it
returns session info including cwd."* That endpoint derives `cwd` from the
joined row of the **first message**:

```zig
// src/agentic_loop/llm_history.zig:867
// Get cwd from first row (same for all rows since we filter by session_id)
var cwd: ?[]u8 = null;
...
while (try rows.next()) |row| {
    if (cwd == null) {
        const cwd_val = row.values[9];
        if (cwd_val.len > 0) { cwd = try allocator.dupe(u8, cwd_val); }
    }
```

A brand-new chat has **zero `llm_history` rows**, so the loop never runs and
`cwd` stays `null` — even though `sessions.cwd` is populated. Measured on a
freshly created session with `cwd_session` set:

```
POST /api/llm/session                        -> id sess_1790710671_…
GET  /api/llm/session/{id}                   -> "cwd": "/tmp/nalar-func-…/term-cwd"   ✅
GET  /api/llm/session/{id}/messages?limit=1  -> "cwd": null                              ❌
```

In the browser that surfaces as `data-testid="terminal-cwd"` reading
**`📂 (no cwd)`**, no `POST /api/terminal/sessions` is ever issued, and the chip
never appears.

So the user-visible defect is: *open a fresh chat, open the right sidebar,
switch to Terminal — there is no terminal, because the chat has no messages
yet.* The fix belongs in the read path (select the session's cwd independently
of the message rows, as the detail endpoint already does), which is a backend
behaviour change and deliberately **not** folded into this test-fix PR.

The other two survivors are unrelated to routing and were failing before this
change too:

- `chatview_lazy_prefetch::test_prefetch_request_is_issued_before_the_scroll_reaches_the_top`
  — *"the prefetch never armed"*, identical in the CI log.
- `chatview_scroll_popin_probe::test_small_scrolls_neither_hole_nor_jump`
  — one measured pop-in, `step 10: JUMP (d_scroll=60 d_spacer=322 win 360->362)`.

---

## Not a flake — how to tell again

| symptom | what it meant here |
|---|---|
| 0/20 local passes, no browser needed | stale constant, not timing |
| 5 consecutive red runs | deterministic, not flaky |
| a page that never issues the API call the test waits on | wrong view mounted |
| `Timeout 10000ms` on a selector that needs 200ms when correct | assertion on absent DOM |

The in-repo tell is `git log --date=short -- <test file>` next to
`git log -S '<the helper the test uses>' -- src/`. A test file older than the
source change it exercises is the whole story in both cases.

---

## Follow-ups (not done here)

1. **`cwd: null` on an empty session** (finding C) — a real product bug; needs
   its own PR against the read path.
2. **CI hides 6 of 29 failures.** `.github/workflows/ci.yml` runs
   `zig build … | tee /tmp/x.log | tail -n 80`; `tail -n 80` cut the first six
   `FAILED` lines. Raise it, or `tail -n 200` on the failure path only.
3. **Fold the two remaining private copies** of the create-workspace/bind/goto
   trio into `chatview_boot.py`.
4. **Guard the drift at the source.** `DbSeed.seed_session` could take an
   optional `workspace_id`, or a `conftest` fixture could own the workspace, so
   a new chatview test cannot silently pick up the unresolvable-session shape
   again.
5. **The last two failures** (prefetch never arms; one pop-in jump) are
   independent of routing and need their own look.
