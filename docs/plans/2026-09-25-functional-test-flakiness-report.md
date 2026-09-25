# Are `zig build functional-test` / `functional-test-ui` flaky?

**Task:** `task_1790361290183_5` · **Date:** 2026-09-25 · **Binary:** `zig-out/bin/nalar` @ `main`
**Method:** CI job history (31 runs) + 3× local full runs of both suites (junit-xml) + targeted repro probes.

---

## TL;DR

**No — not in the sense "sometimes red, sometimes green". Both suites are *permanently red*, and
only 4 tests out of 650 are genuinely flaky *on top of* that.**

This is measured over **3 consecutive full local runs of both suites** (junit-xml, 650 tests × 3 =
1950 test executions):

| | tests | consistent failures | genuinely flaky |
|---|---|---|---|
| `functional-test` (API) | 575 | **8** | **3** |
| `functional-test-ui` (Playwright) | 75 | **30** | **1** |

### The 3-run outcome matrix

```
API  tests/functional       ...  564 tests  always pass
                            FFF     8 tests  always fail
                            E..     1 test   llm_stream_get_test  (port race)      → FIXED
                            .F.     1 test   mcp_test_test        (error-string race) → FIXED
                            F.F     1 test   session_pr_url_test  (sqlite read race)

UI   tests/functional_ui    ...  44 tests  always pass
                            FFF    30 tests  always fail   ← all of them the dead route
                            F..     1 test   chatview_tail_gap_probe_test
```

So: **644 of 650 tests are perfectly deterministic.** 38 fail every single time, 4 flip, and the
other 608 pass every single time.

CI has **never** gone green on either job in the last 31 runs:

```
functional-test     (Linux X64)  n=31  success=0  failure=14  (rest cancelled/skipped)
functional-test-ui  (Linux X64)  n=31  success=0  failure=15  (rest cancelled/skipped)
```

The CI retry wrapper (`ci.yml:1821-1844`) only re-runs on **network-fetch** errors during
`zig build`'s dependency resolution. A genuine test flake is never retried, so these numbers are
the raw flake rate, not a retry-masked one.

So the useful question is *not* "is it flaky" but **"what is broken, and what is a true race?"**.
Answered below, with the evidence for each.

---

## Part 1 — `tests/functional/` (API suite)

Local run 1 reproduced CI **exactly**: `9 failed, 565 passed, 1 error in 592.66s`
(CI run `36120290245`: `9 failed, 548 passed, 6 skipped in 700.76s`).

### 1a. Four failures = ONE real product bug: **TLS is broken**

`http2_tls_test.py` — all 4 TLS tests fail identically:

```
Failed: nalar did not become ready in 45.0s in TLS mode
        (last probe: curl rc=35 code='000' err='curl: (35) Send failure: Broken pipe')
```

This is **not** a bad cert and **not** a broken probe. Direct repro
(`/tmp/probe_tls2.py`, boot `--tls-selfsigned`, then probe):

```
$ openssl s_client -connect 127.0.0.1:54201
depth=0 CN=localhost
CONNECTION ESTABLISHED
Protocol version: TLSv1.3
Ciphersuite: TLS_AES_256_GCM_SHA384
Peer certificate: CN=localhost
...
40B73A3A:error:0A000126:SSL routines::unexpected eof while reading
40B73A3A:error:80000020:system library:tls_retry_write_records:Broken pipe

$ curl -k https://127.0.0.1:54201/health
curl: (35) Send failure: Broken pipe        # rc=35
```

The certificate is valid and correct:

```
subject=CN=localhost
notBefore=Sep 25 18:57:30 2026 GMT   notAfter=Sep 25 18:57:30 2027 GMT
X509v3 Subject Alternative Name: DNS:localhost, IP Address:127.0.0.1
```

nalar logs `TLS enabled (ALPN: h2, http/1.1) cert=...` then `Agent is ready to serve!` and stays
alive — but **the TLS handshake completes and the server drops the socket without ever emitting an
HTTP response.** That is a bug in the TLS request path, and it makes the whole `--tls` /
`--tls-selfsigned` surface unusable. Contract lives in `docs/http2-tls.md`; the 4 tests are doing
their job.

### 1b. Four failures = stale tests, removed on purpose by the "media-flags" change

| test | error |
|---|---|
| `kanban_task_get_test::test_get_task_by_id_returns_full_task` | `assert 'image_urls' in {...}` |
| `agent_video_upload_test::test_create_task_with_mp4_echoes_video_urls` | `KeyError: 'video_urls'` |
| `agent_video_upload_test::test_create_task_with_multiple_video_mimes` | `KeyError: 'video_urls'` |
| `agent_video_upload_test::test_update_task_sets_and_clears_video_urls` | `KeyError: 'video_urls'` |

`src/main.zig:787-790` documents the intent:

> Lazy media fetch (media-flags change) — full `image_urls` / `video_urls` only when
> `is_have_image` / `is_have_video` is true. Longer path (extra `/media` segment) so no shadowing
> vs the `:task_id` route.

The handler exists and works (`src/http_handlers/tasks_media.zig` →
`getWorkspaceItemTaskMedia`, registered at `main.zig:790`). The GET-task response now correctly
carries only the flags:

```
{'id': …, 'is_have_image': False, 'is_have_video': False, 'tags': '', …}
```

**Verdict: the tests are asserting a contract that was intentionally deleted. They must move to
`GET …/tasks/:task_id/media`.** Not a flake, not a product bug.

### 1c. One genuine FLAKE: `session_pr_url_test::test_direct_update_reflected_in_messages_response`

* Alone: **5/5 pass**.
* As the 2nd test in its own file (right after `test_messages_response_carries_pr_defaults`):
  **fails, 2/2**.
* Full-suite run: **fails**.

Instrumented probe (`/tmp/probe_prurl2.py`) shows the UPDATE *does* land and a fresh connection
*does* read it back, but the server still answers `null`:

```
[TEST-2] port=46833 sid=sess_1790362354_f2c2b66ada1c261d2200 db=/tmp/nalar-func-f1o9iltl/...
[TEST-2] UPDATE rows_changed=1
[TEST-2] fresh-conn readback:   [('https://github.com/acme/app/pull/42', 'github')]
[TEST-2] HTTP pr_url=None pr_provider=None        <-- server disagrees with the file
[TEST-2] post-GET fresh-conn readback: [('https://github.com/acme/app/pull/42', 'github')]
```

A second probe (`/tmp/probe_prurl3.py`, same shape, 5 boots) got it right **5/5** — so it is a
race, not a constant. The handler path is
`src/http_handlers/session_messages_get.zig:97-99` → `llm_history.getSessionPrFields`
(`src/agentic_loop/llm_history.zig:1093`) which does a *fresh* `SELECT … FROM sessions`. It also
has a `catch |_| => .{ .pr_url = "" }` at line 97 that silently degrades to "no PR".

**Verdict: a genuine, load-dependent read-visibility flake in the server's SQLite path** (plus a
swallowed-error fallback that turns a DB error into a silently-wrong `null`). Worth a follow-up
investigation of connection/transaction handling — but it is 1 test out of 575, and it is *not*
what is making CI red.

### 1d. One intermittent ERROR = port race + a second real product bug

`llm_stream_get_test::test_stream_route_does_not_shadow_sibling_routes` errored **only** in the
full-suite run; alone it passes **5/5**. The harness log:

```
error: BindFailed
  kabelweb/src/server/http_server.zig:292:25: in bindPort
  kabelweb/src/server/http_server.zig:220:9:  in init
  src/main.zig:367:21: in main
→ harness.FunctionalHarnessError: nalar exited rc=-11 during boot
```

`rc = -11` is **SIGSEGV**. Reproduced 1/1 deterministically by pointing nalar at an occupied port:

```python
s.bind(('127.0.0.1', 45999)); s.listen(1)
subprocess.run(['zig-out/bin/nalar', '--port', '45999'], …)
# returncode: -11
# error: BindFailed
```

**Bug A (product, 1 line class):** a port that is already in use makes nalar **segfault** instead
of exiting with a clean `1` and a readable message. That is why a routine port collision shows up
in CI as an apparent crash.

**Bug B (test harness, `tests/functional/harness.py`):** `find_free_port_random()` (line ~915)
binds a probe socket with `SO_REUSEADDR`, **closes it**, and returns the number; the child binds
the real listener tens of ms later. Classic probe-then-bind TOCTOU. Worse, the range:

```python
RANDOM_PORT_START = 40000
RANDOM_PORT_END   = 60000
```

sits **entirely inside this host's kernel ephemeral range**:

```
$ cat /proc/sys/net/ipv4/ip_local_port_range
32768 60999
```

Every outbound connection on the box (pnpm, vite, zig, git, the CI runner, nalar's own libcurl
probes) draws its *source* port from the same pool the harness picks listeners from. Under load
the window is stealable — which is exactly what happened.

**Fix, cheapest first:** (1) `main.zig` catch `BindFailed` → `std.process.exit(1)` with a message;
(2) harness retries boot on `BindFailed` (or holds the probe socket until `Popen` returns);
(3) move `RANDOM_PORT_*` below 32768, e.g. `[20000, 32000]`.

---

## Part 2 — `tests/functional_ui/` (Playwright)

**31 of 75 tests fail on the local run** (`31 failed, 44 passed in 790.04s`).

> Correction to an earlier reading of the CI logs: CI runs reported 28 and 29 failures, but
> `ci.yml:1828` pipes the pytest output through `tail -n 50`, so the `FAILED` lines visible in the
> GitHub log are a **truncated prefix**, not the full list. The local junit run is the complete
> picture. Treat 31 as the real number.

The split is unusually clean, and that is the most useful fact in this report:

| route the test navigates to | result |
|---|---|
| `?view=chat&session=<id>` (dead) | **30 of 30 fail** |
| `/app/<wsId>/chat/<sessionId>` (current) | **pass** — with exactly 1 flaky exception |

### 2a. One root cause for 30 of the 31: **the URL contract changed and the tests didn't**

The revamp moved the app to **path-based** URLs. `src/apps/desktop/src/helpers/appUrl.ts:58-63`:

```ts
export type ParsedAppPath =
  | { kind: 'landing' }
  | { kind: 'workspace'; workspaceId: string }
  | { kind: 'chat';  workspaceId: string; sessionId: string }
  | { kind: 'project'; workspaceId: string; projectId: string }
  | { kind: 'projectChat'; workspaceId: string; projectId: string; chatTaskId: string }
  | { kind: 'other'; path: string }
```

`AppLayout.vue:389-429` builds `pendingUrlRestore` from **only** `parseAppPath(route.path)` kinds
and `?view=workspace&workspaceId=`. There is **no branch for `?view=chat&session=`**, so it returns
`null`, no workspace is restored, and the app falls through to the home landing.

Proved with a DOM probe (`/tmp/probe_chatview.py`) against a live `ui_harness`:

```
=== goto http://127.0.0.1:51997/app?view=chat&session=sess_probe_empty_001
=== data-testid present in DOM
['sidebar-collapse-toggle', …, 'projects-no-workspace', 'home-landing',
 'home-wordmark', 'home-tagline', 'home-blurb', 'home-create-workspace', …]
=== skeleton visible?   {'skeleton': False, 'error': None}
=== h3 texts            []
```

`home-landing`, no `chat-initializing-skeleton`, no ChatView empty state. And the failing test's
own error says exactly that:

```
FAILED tests/functional_ui/chatview_ui_test.py::test_chatview_renders_empty_state
  playwright._impl._errors.TimeoutError: Locator.wait_for: Timeout 10000ms exceeded.
  Call log: - waiting for locator("text=How can I help you?").first
```

The empty state is still in the template — `ChatView.vue:4289-4306` has it verbatim, gated on
`v-if="!isInitializing && !isLoading && !error && messageGroups.length === 0"`. It is simply never
reached, because `<ChatView v-else-if="activeChatId.startsWith('chat-')">` (`AppLayout.vue:3254`)
is downstream of a workspace branch that never matches.

**10 test files still navigate the dead `?view=chat&session=` shape — 30 tests, 30 failures:**

| file | fail / total |
|---|---|
| `chatview_ui_test.py` | **9 / 9** |
| `chatview_html_tag_ui_test.py` | **5 / 5** |
| `chatview_html_frame_layout_test.py` | **4 / 4** |
| `chatview_agent_error_card_ui_test.py` | **3 / 3** |
| `terminal_sidebar_ui_test.py` | **3 / 3** |
| `chatview_lazy_prefetch_ui_test.py` | 2 / 3 |
| `chatview_command_output_live_ui_test.py` | 1 / 1 |
| `chatview_present_files_ui_test.py` | 1 / 1 |
| `chatview_tool_calls_json_wire_test.py` | 1 / 2 |
| `kanban_profile_select_ui_test.py` | 1 / 3 (`…chip` only) |

Fully green, for contrast: `agent_system_prompt_ui_test` (5), `auth_login_sse_ui_test` (1),
`harness_safety_test` (17), `kanban_lifecycle_ui_test` (4), `kanban_sidebar_open_ui_test` (4),
`smoke_boot_test` (5), and `chatview_scroll_popin_probe_test` (3) — the last of which navigates
the current path-based route.

`terminal_sidebar_ui_test.py` fails for the same reason — it gates on the same empty-state copy
(`page.locator("text=…").first.wait_for(timeout=20000)`).

**Fix:** seed a workspace + project item alongside the session, and navigate to
`/app/<wsId>/chat/<sessionId>`. `chatview_scroll_popin_probe_test.py` (3/3 green) and
`chatview_tail_gap_probe_test.py` (1/2 green) already do this and are the template to copy.

### 2b. The genuinely flaky remainder (UI)

**Exactly one**, and the split above is what isolates it:

```
chatview_tail_gap_probe_test.py::test_small_scrolls_at_the_tail_do_not_teleport
  AssertionError: tail-region scroll signatures:
    step 7: JUMP (d_scroll=40 d_spacer=361 win 317->318 …)
```

It is one of only two tests that already navigate the **current** path-based route, so it is the
only flaky test in the suite that is not merely collateral damage. Shape: a fixed
`wait_for_timeout` guarding a measurement with a tight tolerance. ~8.4 s of sleeps across 6
sites; the tail-gap cap is `MAX_TAIL_GAP_PX + SLACK_PX = 124 px`. The test re-samples at
`:189`→`:195` "to let it settle" and then asserts — the settle is unbounded.

Its sibling `chatview_html_frame_layout_test::test_srcdoc_shell_carries_theme_and_resize_script`
also flipped between CI runs, but locally it fails 4/4 like the rest of its file, so that is
contract drift plus a weak budget rather than an independent flake. It has the same smell though:
`chatview_html_frame_layout_test.py:322-333` is an 8 s auto-resize settle loop that **falls
through without setting a flag** on timeout and then asserts anyway on a half-resized frame.

Both are "the budget is a guess, the tolerance is tight" rather than "the code is wrong".

### 2c. Latent landmines in the UI harness (not currently firing — CI is sequential)

* `UIHarness._wait_vite_ready` (`ui_harness.py:120-124, 512-545`) treats **HTTP 200 on `/`** as
  "Vite is ready". Vite serves the `index.html` shell before dep pre-bundling, so the 60 s budget
  is spent on ~0.3 s of work and the real compile lands in each test's 30 s `page.goto`. The
  docstring claims the opposite of what Vite does.
* Vite's dep cache (`node_modules/.vite/deps`) is **shared across all 75 boots** (no `cacheDir`
  override). Harmless while CI is sequential; the moment anyone adds `-n auto` (which
  `tests/functional_ui/README.md` recommends) the `deps_temp_*` → `deps` swap can 504 an
  in-flight browser.
* `ui_harness.py:320-327` — the Vite boot-failure path calls `vite_proc.kill()` (PID only), not
  `os.killpg`, and there is **no Vite pidfile**, so a leaked Vite is permanently unreclaimable by
  `_reap_orphan_test_pids`. The leak fires exactly when a boot is slow.
* `conftest.py:111-124` — `UIHarness.boot(...)` sits **outside** the fixture's `try/finally`, so
  one 60 s Vite timeout becomes N simultaneous ERRORs for the whole file.
* 7 tests in `kanban_lifecycle_ui_test.py` + `kanban_profile_select_ui_test.py` gate
  **write-then-read** assertions on a bare `page.wait_for_timeout(1000)` / `(800)` with no
  `expect(...).to_be_visible()` and no retry.

---

## Part 3 — Summary: flaky vs broken

### Actually flaky (4 of 650 = 0.6%)

| test | 3-run pattern | root cause | status |
|---|---|---|---|
| `llm_stream_get_test::test_stream_route_does_not_shadow_sibling_routes` | `E..` | harness port TOCTOU inside the kernel ephemeral range, masked as a "segfault" by a product bug | **fixed in this PR** |
| `mcp_test_test::test_mcp_test_stdio_diagnostic_on_child_death` | `.F.` | over-specified assertion — `mcp_test.zig:856-857` has two legitimate errors and a dying child loses the send/recv race. Run 2 produced `failed to send request to MCP server` where the test demanded `failed to receive response from MCP server` | **fixed in this PR** |
| `session_pr_url_test::test_direct_update_reflected_in_messages_response` | `F.F` | server-side SQLite read-visibility race + `catch \|_\| => ""` fallback that masks a DB error as `null` | open |
| `chatview_tail_gap_probe_test::test_small_scrolls_at_the_tail_do_not_teleport` | `F..` | unbounded "settle" vs a 124 px tolerance | open |

### Broken, not flaky (38 tests, 3 causes)

1. **URL contract drift** — 30 UI tests. Fix the 10 files' navigation + seeding.
2. **TLS listener drops the connection after the handshake** — 4 API tests. Real product bug.
3. **media-flags contract drift** — 4 API tests. Point them at `…/tasks/:task_id/media`.

### Also real, and a bad look in CI

4. **Occupied port ⇒ SIGSEGV** instead of a clean exit. One `catch` in `main.zig` — **fixed in
   this PR**.
### Environment-coupled test (will fail on any dev box, not CI)

`tests/functional/sessions_and_llm_test.py::test_no_state_leaked_to_real_home` asserts
`time.time() - mtime("$HOME/.config/nalar/agent.db") > 60` on the **developer's real** DB. This
box permanently runs a dev nalar on **8081** (PID 2027624) writing exactly that file, so the test
is racing an unrelated long-lived process. It should be skipped when a real nalar is detected, or
rewritten to assert on the harness's own `temp_dir`.

---

## Recommended order of work

| # | change | size | unblocks |
|---|---|---|---|
| 1 | `main.zig`: clean exit on `BindFailed` | S | ✅ **done (this PR)** — `rc=1` + operator message instead of `rc=-11` |
| 2 | `harness.py`: move `RANDOM_PORT_*` to `[20000, 32000]` | S | ✅ **done (this PR)**. A boot retry on `BindFailed` would be belt-and-braces; not needed once the range is outside the ephemeral pool |
| 3 | 4 media tests → `…/tasks/:task_id/media` | S | 4 API failures |
| 4 | 10 UI files → path-based URL + workspace seeding | **L** | 30 UI failures |
| 5 | TLS: handshake-then-drop | M (product) | 4 API failures + the whole `--tls` surface |
| 6 | `session_pr_url` read-visibility | M (product) | flake #1 |
| 7 | Replace fixed sleeps with `expect(...).to_be_visible()` in kanban UI tests | M | removes the next flake tier |
| 8 | Vite readiness gate + `cacheDir` + pidfile + group-kill in `ui_harness.py` | M | hardens the UI suite for `-n auto` |
| 9 | `mcp_test_test`: accept both MCP child-death error messages | S | ✅ **done (this PR)** — flake `.F.` |

Items 1–2 and 9 are small, safe, and independently reviewable — all landed here. Items 3–4 are the
next two, and item 4 is really its own task.

---

## Reproduction

Three consecutive runs of both suites is what turns "this looks flaky" into a per-test outcome
matrix. The junit XML is the source of truth — the console log is not:

```bash
# API suite (575 tests, ~10 min)
NALAR_BIN=$PWD/zig-out/bin/nalar .venv-func/bin/python -m pytest tests/functional/ \
    -q --tb=no -rf --junit-xml=/tmp/junit_func_$i.xml

# UI suite (75 tests, ~13 min) — MUST use .venv-func (it has playwright);
# /tmp/nalar-func-venv silently SKIPS every test with `could not import 'playwright'`
NALAR_BIN=$PWD/zig-out/bin/nalar .venv-func/bin/python -m pytest tests/functional_ui/ \
    -q --tb=no -rf --junit-xml=/tmp/junit_ui_$i.xml
```

Then join the runs per test id to get the pattern matrix:

```python
import xml.etree.ElementTree as ET
def load(p):
    d = {}
    for tc in ET.parse(p).iter('testcase'):
        bad = [c for c in tc if c.tag in ('failure', 'error')]
        d[f"{tc.get('classname')}::{tc.get('name')}"] = (bad[0].get('type') or bad[0].tag) if bad else 'PASS'
    return d
runs = [load(f'/tmp/junit_func_{i}.xml') for i in (1, 2, 3)]
for k in sorted(set().union(*[set(r) for r in runs])):
    seq = [r.get(k) for r in runs]
    if len(set(seq)) > 1:
        print(k, seq)          # <- the flaky set
```

**Do not read flake counts off the CI log.** `ci.yml:1828` pipes the pytest output through
`tail -n 50`, so the `FAILED` lines in the GitHub UI are a truncated prefix — that is how a 31-failure
run was first mis-read as 28.

CI job history:

```bash
gh run list --workflow=ci --limit 40 --json databaseId,conclusion
gh run view <id> --log | rg -o 'FAILED tests/\S+' | sort -u   # truncated, see above
```

Probes used in this investigation live in `/tmp/probe_chatview.py`, `/tmp/probe_prurl{,2,3}.py`,
`/tmp/probe_tls{,2}.py` and `/tmp/instr_run.py` (a harness-instrumenting pytest driver).
