
#Mandatory
DONT KILL THE PORT 8081 SERVER,
for testing use another port like 8080
> **Audience:** any AI agent (Claude, GPT, sub-agent, future-me) that writes,
> edits, reviews, or tests code in this repo. Humans may also find it useful.
>
> **Authority:** this file is loaded automatically by every agent at session
> start. Treat the rules below as non-negotiable. If a rule conflicts with a
> specific task, surface the conflict to the user before acting.

---

## 🚨 Top-line mandate — read this first

**Every feature you write, every bug you fix, every test you add MUST work on
Linux, macOS, AND Windows.** No "I'll add a Windows port later" — the
default is "it works on all three from the first commit." Reviewers may
reject PRs that don't.

This is a Zig 0.16 + Python (pytest) + Vue 3 desktop project. The platform
matrix is non-trivial (Zig 0.16 removed `std.posix.*`, Windows `pid_t` is
`*anyopaque`, `setsockopt` is `@compileError` on Windows, etc.). The
project already ships dedicated cross-platform helpers — **use them,
don't reinvent**.

---

## 📌 Project overview

Nalar AI agent backend (Zig 0.16) with Vue 3 desktop app. This file is the
**canonical source of project conventions**. See `.nalar/memories/` for
detailed patterns and `~/.config/nalar/memories/` for cross-project lessons.

### 📋 Read `docs/SPEC.md` first — single source of truth

Before starting any non-trivial task, read **`docs/SPEC.md`** — it is the
consolidated project specification (compiled from all 178 historical plan
files in `docs/superpowers/plans/` and `docs/plans/`, which have been
deleted). The spec covers:

- Current tech stack, repo layout, operating conventions (Linux/macOS/Windows)
- Status of every feature domain (✅ Implemented / 🟡 In Progress / ⏳ Pending / ❌ Superseded / 🗑️ Not Relevant)
- Pending items that still need work (start there for new contributor onboarding)
- Superseded plans and what replaced them
- PR index for landed features

**The plan/spec/tree rule of thumb**: when starting a new feature, look in
`docs/SPEC.md` §3 ("Plans by Domain") for the closest architectural neighbor,
then check `§5 Pending` to make sure you are not duplicating existing work.

### Where memories live

Detailed patterns live in:

- **Local** — `.nalar/memories/` (project-specific: backend, frontend,
  data, infra, cross-platform Zig 0.16 gotchas)
- **Global** — `~/.config/nalar/memories/` (cross-project: Zig stdlib,
  Vue 3 patterns, SQLite gotchas, Windows shell idioms)

When you discover a non-obvious fact, write it to the appropriate memory
file so future sessions pick it up automatically.

---

## ⚠️ Mandatory rules (do not violate)

1. **NEVER kill the process on port 8081** — that is the always-running
   dev `nalar` instance shared with the user.
2. **NEVER use port 8081 for new work** — for local smoke tests, use
   port 8080 (the harness default).
3. **Every test you write or modify MUST work on Linux, mac, AND
   Windows** — see the cross-platform section below for the scaffolding
   that makes this possible.
4. **Never touch `.nalar/agents/<name>/NALAR.md`** — those are per-agent
   profile files consumed by `agents.zig` / `change_agent.zig`. Only the
   root `NALAR.md` is the project-conventions doc (and this file replaces
   it).

---

## 🌍 Platform matrix — what works where

| Capability                      | Linux ✅ | macOS ✅ | Windows ✅ | Where it lives                               |
|---------------------------------|---------|---------|-----------|----------------------------------------------|
| System libc (`sqlite3`, `ssl`)  | system  | system  | vendored  | `build.zig`, `scripts/fetch-vendor-sqlite3.sh` |
| Process ID (as `i32`)           | ✅      | ✅      | ✅        | `helpers.process.getCurrentProcessId`        |
| `kill(pid, signal)` / `TerminateProcess` | ✅ | ✅     | ✅        | `helpers.process_status.{killProcess,isProcessRunning}` |
| `getcwd` (no `Io` runtime)      | ✅      | ✅      | ✅        | `helpers.{mod.zig::getcwd}` (libc wrapper)   |
| `getenv` (no `Io` runtime)      | ✅      | ✅      | ✅        | `helpers.{mod.zig::getenv}` (libc wrapper)   |
| `setsockopt` (TCP keepalive)    | ✅      | ✅      | ❌        | `Agent.zig::apply_tcp_keepalive` — gated `!= .windows` |
| POSIX child-process reaping     | ✅      | ✅      | ⚠️ Win32  | `bash.zig`, `helpers.http.HttpClient`        |
| WebKitGTK / WKWebView / WebView2 | ✅      | ✅      | ✅        | `src/apps/desktop_app/platform/`             |
| Daemonize (double-fork)         | ✅      | ✅      | ⚠️ Win32  | `src/modules/daemon/` — POSIX + Win32 paths  |
| SIGTERM handler                 | ✅      | ✅      | ⚠️ Win32  | `src/modules/signal_handlers/`               |
| Filesystem paths                | Unix    | Unix    | Win32     | Use `std.fs.path.join`, never hardcode `/` or `\` |

**The rules below tell you how to stay on the ✅ side of every row.**

---

## 🧠 Language & environment facts

<!-- Known API changes, syntax rules, and environment behaviors for this codebase. -->
<!-- Format: - [lang@version] <fact in one sentence> -->

- **[zig@0.16] CRITICAL: `std.Io.Threaded` does NOT honor user-space
  deadlines on blocking socket reads** — when a worker thread is parked
  in `recv()` waiting for data, the main thread's deadline check is dead
  code. The worker only unblocks when the kernel returns
  (RST/FIN/error/timeout). To enforce a read deadline on a TCP stream,
  you MUST set `SO_RCVTIMEO` on the underlying socket fd, OR drive the
  Io's `select`/`async` with a timeout. Symptom: an "idle timeout" loop
  never fires when the server stalls without sending RST/FIN. See
  `src/modules/agent/Agent.zig` callStreaming read loop and the SKIP
  comment in `call_streaming_test.zig` for the live example.

- **[zig@0.16]** `std.Thread.Mutex` does NOT exist — `std.Thread` only
  exposes spawn/join/detach APIs. For a mutex in a `std.Thread.spawn`'d
  worker, use `std.atomic.Mutex` (a lock-free `enum(u8) { unlocked,
  locked }` with `tryLock() bool` and `unlock() void`) as a spinlock
  with `while (!m.tryLock()) std.atomic.spinLoopHint()`. For mutexes
  held by Io-runtime code, use `std.Io.Mutex` (lock takes `io: Io`).
  The critical section must be small (a few hundred ns) for the
  spinlock to be acceptable.

- **[zig@0.16]** **`std.process.spawn` takes `io: Io` as first arg**
  (not allocator). Signature: `spawn(io: Io, options: SpawnOptions)
  SpawnError!Child`. The `Child` struct has no `.allocator` field — its
  handle is owned by the Io runtime. Forgetting `io` and passing an
  allocator is a common mistake (the allocator will be treated as an Io
  and the type check fails).

- **[zig@0.16]** **`std.process.Child.kill(child, io)` is the
  all-in-one "terminate + wait + cleanup"** — it sends SIGTERM (or
  Windows equivalent), blocks until the child exits, sets
  `child.id = null`, and reaps. You MUST NOT call `child.wait(io)` after
  `kill(io)` because `wait` asserts `child.id != null` and will panic.
  There is no "kill but don't wait" API in 0.16.

- **[zig@0.16]** **Zig 0.16 has no public
  `std.posix.socket/bind/listen/accept/connect/recv/send/close`** — they
  live in `std.os.linux.*` (or `.windows.*`, `.darwin.*`) and return a
  raw `usize` (success value on success, `-errno` cast to `usize` on
  failure). Check return against `std.math.maxInt(i32)` to detect
  errors, then `@intCast` to `i32` for the fd. The `errno()` helper
  inside `posix.zig` is private.

- **[desktop-app]** `nalar-desktop` is the new native webview wrapper at
  `src/apps/desktop_app/`. It spawns `nalar` as a child process and
  opens a native webview window (WebKitGTK 4.1 on Linux via manual
  `extern "c"` + C shim at `platform/webview_linux.c`, WKWebView on
  macOS via Objective-C++ shim at
  `platform/macos/nalar_webview.mm`, WebView2 on Windows via C++ shim
  at `platform/windows/nalar_webview.cpp`). Build:
  `zig build nalar-desktop`. The Vue webapp is embedded as comptime
  bytes via the codegen step `zig build codegen:webapp-assets` (which
  depends on `zig build build:webapp` to run `bun run build` first).
  Runtime startup: extract assets to
  `$XDG_RUNTIME_DIR/nalar-desktop-webapp-<pid>/`, spawn
  `nalar --port <port> --static-dir <webapp-dir>`, wait for
  `/api/health`, open the webview at `http://127.0.0.1:<port>/`.
  21/21 unit tests pass via `zig build test:desktop-app`. The output
  binary is ~29 MB (includes 4.7 MB of embedded webapp assets + the
  17 MB nalarcore link).

---

## 🧪 Functional scenarios — what "functional" means here

A "functional scenario" is a **real-data, isolated-in-tmpdir, end-to-end test
that drives the running binary through the HTTP API**. It is NOT a unit test
and it is NOT a mock. The harness spins up a real `nalar` process, points
it at a fresh `$HOME` under `/tmp/`, runs the API, and asserts on
response shapes + on-disk state.

### Required functional scenarios (per feature)

When you add a new feature, you MUST add at least one functional scenario
covering each of the following axes. Use the existing fixtures in
`tests/functional/` as blueprints.

| Scenario axis                       | Existing example                              | Required when you add…                |
|-------------------------------------|-----------------------------------------------|---------------------------------------|
| **Happy-path create/list/delete**   | `workspace_lifecycle_test.py`                 | any new resource type                 |
| **Pagination / cursor**             | (kanban: `kanban_lifecycle_test.py`)          | any list endpoint with `> 20` items   |
| **Multi-element / drag-and-drop**   | `design_lifecycle_test.py`                    | any UI editor that mutates positions  |
| **SSE / streaming**                 | `sse_endtoend_test.py`                        | any endpoint that emits server events |
| **Sessions + LLM stub**             | `sessions_and_llm_test.py`                    | any change to the LLM/routine pipeline  |
| **Skills / memory CRUD**            | `memories_skills_test.py`                     | any change to the skill/memory stack  |
| **Boot safety: HOME not nuked**     | `harness_safety_test.py`                      | any change to `tests/functional/harness.py` |
| **Schema migrations on fresh DB**   | `scripts/ci-smoke-test.sh`                    | any new migration or schema change    |

### Minimum-viable functional scenario template

```python
"""Functional scenario for <feature>: <one-line description>.

Real-data, isolated-in-tmpdir end-to-end coverage. See
`tests/functional/README.md` for the safety invariant.
"""
from __future__ import annotations
import pytest
from harness import FunctionalHarness  # noqa: F401


def test_<feature>_<scenario>(harness: FunctionalHarness) -> None:
    """<Plain-English description of what this scenario verifies>."""
    # 1. ACT — drive the API with non-trivial data (≥ 5 of each entity).
    created = harness.http("POST", "/api/<your-endpoint>",
                           json_body={"name": "real-data-1"}, expect=201)
    entity_id = created.json()["id"]

    # 2. ASSERT — wire shape, persistence, side-effects.
    fetched = harness.http("GET", f"/api/<your-endpoint>/{entity_id}", expect=200)
    assert fetched.json()["id"] == entity_id

    # 3. CLEAN — delete the resource; the harness teardown handles the tmpdir.
    harness.http("DELETE", f"/api/<your-endpoint>/{entity_id}", expect=200)
```

### Non-functional axes you MUST also exercise

| Axis              | Verification                                       |
|-------------------|----------------------------------------------------|
| **≥ 5 items**     | pagination cursor advances correctly               |
| **≥ 30 tasks**    | kanban column counts + drag reorder work           |
| **≥ 10 elements** | design canvas snap / multi-select / group drag     |
| **Non-ASCII names** | unicode / emoji / RTL in `name` fields survive round-trip |
| **Empty string**  | rejection of `name=""` (per `workspace_items_create_empty_name_test.zig`) |
| **Duplicate name** | 409 on collision (where the route already enforces it) |
| **SSE reconnect** | drop the connection mid-stream, re-attach, see events |
| **Cross-platform** | `zig build test`, `zig build install:linux:system`, and `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -target aarch64-macos` all pass |

---

## ✅ Pre-commit checklist — run these before every commit

```bash
# 1. Static unit tests (Linux — what this CI matrix cell currently runs)
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all

# 2. Build the Linux binary (catches lazy-analysis errors `zig build test` misses)
timeout 180 zig build install:linux:system

# 3. Fresh rebuild — catches stale-cache errors
rm -rf zig-out/bin
timeout 360 zig build

# 4. Cross-compile smoke tests (catches Windows/macOS-only compile errors)
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig

# 5. Functional scenarios (Linux — uses real `nalar` binary, isolated tmpdir)
zig build install:linux:system
pytest tests/functional/ -v --tb=short

# 6. Frontend type-check + tests (Linux)
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run 2>&1 | tail -n 20
```

**If any step fails, the change is not ready.** Don't claim "done" without
all six steps green. (See `nalar-frontend-patterns.md` for why both
`bun run build` AND `bunx vitest run` are required — `vitest` does not
type-check.)

---

## 📚 Where the cross-platform scaffolding lives (reuse, don't reinvent)

| Need                                       | Use this                                                                 |
|--------------------------------------------|--------------------------------------------------------------------------|
| Cross-platform PID / kill / is-running     | `nalarcore.helpers.process_status` (`isProcessRunning`, `killProcess`, `getCurrentProcessIdInt`) |
| Cross-platform PID (`std.c.pid_t` alternative) | `nalarcore.helpers.process.getCurrentProcessId` (returns `i32`)      |
| `getcwd` / `getenv` without `Io` runtime   | `nalarcore.helpers.{getcwd, getenv}` — libc-backed wrappers              |
| TCP keepalive / socket options             | `Agent.zig::apply_tcp_keepalive` (POSIX); on Windows skip and document   |
| Process daemonization                      | `src/modules/daemon/` — POSIX double-fork + Win32 paths                  |
| SIGTERM / Ctrl-C handler                   | `src/modules/signal_handlers/` — POSIX + Win32                           |
| HTTP client (libcurl, cross-platform)      | `src/modules/http/HttpClient.zig` — replaces `std.http`                  |
| SQLite (cross-platform build)              | `vendor/sqlite3/` (gitignored); `scripts/fetch-vendor-sqlite3.sh` fetches |
| Cross-platform shell smoke tests           | `scripts/ci-smoke-test.sh`, `scripts/service-lifecycle-smoke.sh`         |
| Functional test harness (Python)           | `tests/functional/harness.py` + `conftest.py`                            |
| Functional test pattern (Zig static-contract) | `*_test.zig` files under `src/ai_workflow/tui/` (`test <contract> { ... }`) |

**When you need a new cross-platform helper, add it to `src/helpers/`,
write a `cross_platform_test.zig`-style test, and reference it from this
table.** Don't sprinkle `switch (builtin.os.tag)` across the codebase.

---

## ⚠️ Cross-platform pitfalls — Zig 0.16 + Win32 gotchas

These are the bugs that have already bitten this codebase. Every agent
MUST treat them as "do not reintroduce" rules.

### Forbidden Zig 0.16 patterns

| ❌ Never write                                         | ✅ Replace with                                                                  |
|-------------------------------------------------------|----------------------------------------------------------------------------------|
| `std.posix.kill(pid, sig)`                            | `nalarcore.helpers.process_status.killProcess(pid)`                              |
| `std.posix.getcwd(&buf)`                              | `nalarcore.helpers.getcwd(&buf)` (libc `std.c.getcwd`)                           |
| `std.posix.getenv(name)`                              | `nalarcore.helpers.getenv(name)` (libc `std.c.getenv`)                           |
| `std.posix.setsockopt(...)` (Windows)                 | Gate behind `if (builtin.os.tag != .windows) { ... }` (see `Agent.zig apply_tcp_keepalive`) |
| `std.fs.cwd().readFileAlloc(...)`                      | `nalarcore.helpers.io` wrappers (which conditionally use `std.Io` or libc)       |
| `std.crypto.random.bytes(&buf)`                       | `std.c.getrandom(buf.ptr, buf.len, 0)`                                           |
| `std.time.timestamp()`                                | `std.Io.Clock.now(.real, io).toSeconds()` (with `io`) OR libc `gettimeofday`    |
| `std.fs.path.dirname` of hardcoded `/` joins          | `std.fs.path.join(allocator, &.{ a, b })` — Windows uses `\`                     |
| `std.c.pid_t` compared to `i32`                        | `process_status.getCurrentProcessIdInt()` (returns `i32` directly)               |
| `std.Thread.Mutex` (doesn't exist)                    | `std.atomic.Mutex` (spinlock) for `std.Thread.spawn`'d workers; `std.Io.Mutex` for Io-runtime |
| `child.wait(io)` after `child.kill(io)`                | Just `child.kill(io)` — `kill` already reaps + closes pipes                      |
| `std.json.parseFromSlice` + later access on an arena | `std.json.parseFromSliceLeaky` (or deep-copy before `deinit`)                    |
| `extern "c" fn my_name(...)` to wrap a libc function   | Use the libc's real name OR write a Zig wrapper explicitly                      |
| `exit(0)` from a signal handler                        | Set an `atomic` flag + `return`; let the main loop observe                       |

### Allowed `switch (builtin.os.tag)` patterns

Centralize the switch in `src/helpers/`. Call sites import the helper and
do not switch. If you find yourself writing a new `switch` at a call site,
add a helper instead.

### Cross-platform test coverage

Every new `src/helpers/*.zig` file MUST have a sibling `*_test.zig` that
exercises BOTH the POSIX path and the Windows path. The Windows path
cannot be exercised on Linux directly — use `zig build-obj
-fno-emit-bin -target x86_64-windows-gnu` to verify it at least compiles
(no link), then trust CI / a Windows runner to run the test.

---

## 🧷 Functional-test safety invariants

The functional test harness in `tests/functional/` has a **non-negotiable**
safety invariant: **it NEVER deletes the developer's real `$HOME`.** Three
guard layers enforce this:

1. `is_safe_tmp(path, orig_home)` allow-list — rejects anything outside
   `/tmp/`, `/private/tmp/`, `/private/var/folders/`, `/var/folders/`,
   or `tempfile.gettempdir() + "/"`, AND must contain substring `nalar-func-`,
   AND must not resolve to the real `$HOME` via `os.path.realpath`.
2. The harness captures `temp_dir` ONCE at boot. Teardown uses THIS
   attribute, never `$HOME`.
3. `ORIG_HOME` is snapshotted before `HOME` is shadowed; restored as
   the first step of teardown.

The five negative tests in `harness_safety_test.py` guard these invariants.
**If any fails, do not merge.** The trade-off is "leak the tempdir" rather
than "delete the user's home" — that's the correct trade-off.

When you add a new test, do NOT introduce `shutil.rmtree` outside of
`harness.teardown()`. If you need to clean up a resource, do it via the
API (DELETE endpoint) or use `pytest`'s `tmp_path` fixture.

---

## 🚫 Forbidden patterns

| Pattern                                                                    | Why                                                                                  |
|----------------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| `await fs.readFile('/some/path')` (hardcoded path)                         | Path separator is `\` on Windows. Use `path.join` / `path.resolve`.                  |
| `kill -9 <pid>` from a script                                              | Windows has no signals. Use `nalarcore.helpers.process_status.killProcess`.          |
| `pathlib.Path("/tmp")`                                                     | `gettempdir()` on macOS is `/var/folders/...`, not `/tmp`. Use `tempfile.gettempdir()`. |
| `os.environ["HOME"]` in test teardown                                     | The harness uses `h.temp_dir`. Reading `HOME` mid-test is a footgun.                  |
| `expectEqualStrings` with raw bytes from a Windows path                    | Path bytes on Windows start with `C:\`, not `\\?\`. Be careful with byte assertions. |
| `child.kill(io); child.wait(io);`                                          | `kill` already reaps. Calling `wait` after `kill` asserts-fails in 0.16.             |
| `var x: T = .empty;` on `std.fs.File` / `std.Io.File`                      | Use `var x: std.Io.File = .uninitialized` or similar — `.empty` is not on these.     |
| `struct { ... }` (anonymous) inline as a parameter type                    | Anonymous structs in different scopes are distinct types. Hoist to a named struct.   |
| `cp -r vendor/ /usr/local/share/` in a build script                         | Path may not exist on Windows. Use a Zig build step or `shutil.copytree`.            |
| `signal.SIGTERM` on Windows in a Python script                             | `signal.SIGTERM` works on Windows in Python, but `signal.SIGKILL` does NOT. Use `taskkill /F` or `process.kill()` for unconditional. |
| `subprocess.run("cmd /c ...")`                                              | `cmd` is Windows-only. Use the cross-platform `subprocess.run([...])` (list form).   |
| Hardcoded `os.path.expanduser("~/.config/nalar")`                          | On Windows, `~/.config/` is not the convention; use `os.environ["HOME"]` + `Path` joining. |

---

## 🧭 Where this file lives in the agent-feedback loop

- This file is loaded at session start. Read it before your first action.
- It is the **canonical answer** to "does this work on Windows?" — point
  reviewers here when they ask.
- If you find a counter-example to a rule above, edit this file rather
  than carving an exception in the code.
- If you add a new cross-platform helper, add it to the **Where the
  scaffolding lives** table above.
- If you discover a new pitfall, add it to the **Forbidden patterns**
  table above.

## 📜 Recent changes (changelog)

> Append-only. After finishing a non-trivial task, add a short note here
> documenting what landed and why. These breadcrumbs help the next session
> pick up context without re-reading the git log.

### 2026-08-06: Sidebar single-active state (URL-driven)

**Symptom (user report, task_1785793620170).** Sidebar showed multiple rows styled as "active" simultaneously (expanded workspace + active item + active page), making it impossible to tell which one the main content area was actually showing.

**Root cause.** `WorkspaceList.vue` used `--semantic-active-bg` when `workspace.expanded === true`, conflating "expanded (UI state)" with "active (content relationship)". Additionally, the chat list kept its `active: true` flag set even after navigating to a workspace view (stale store state).

**What landed (9 commits, branch `worktree/sidebar-single-active`).** URL is now the single source of truth for "what is the main content area showing".

| Component | Before | After |
|---|---|---|
| ChatsList chat row | `active: savedSessionId === session.session_id` | URL-driven via `useCurrentMainView()` |
| WorkspaceItemTaskRow task row | `workspacesStore.activeTaskId === task.id` | URL-driven |
| WorkspaceItem item row | `props.isActive` | URL-driven + 2px violet left accent bar |
| DesignPageRow page row | `props.isActivePage` | URL-driven + 2px violet left accent bar |
| WorkspaceList expanded workspace | active bg | no bg; just chevron rotation |

**[New]** `useCurrentMainView()` composable — derives `{kind, ...id}` from `route.query`. One place; sidebar components consume it.

**Tests (22 new + 1 updated):**
- 6 unit tests for `useCurrentMainView`
- 4 ChatsList activeFromUrl tests
- 1 updated test in `workspaceItemTask.spec.ts`
- 4 WorkspaceItem.activeFromUrl tests
- 4 DesignPageRow.activeFromUrl tests
- 2 WorkspaceList.expandedNoActiveBg tests
- 2 E2E tests in `sidebarSingleActive.spec.ts` (verifies right count of active rows per URL)

**Verification (worktree `worktree/sidebar-single-active`):**
- `bun run build`: clean (vue-tsc + vite, 1.65 s)
- `bunx vitest run`: **2100 pass / 19 fail** — the 19 are the documented pre-existing baseline (DesignView.undoHidden×5, AppLayout.urlPersist×7, AppLayout.memoriesGate×4, DesignElement static×1, AppLayout.translateResize×1, DesignView.nudge×1). Zero regressions.

**Behaviour now (per URL):**
- `?view=workspace&itemId=X&pageId=Z` → item row + page row highlighted (item + page form a meaningful hierarchy breadcrumb). Workspace header NOT active.
- `?view=workspace&itemId=X` (no pageId) → only the item row highlighted.
- `?view=chat&session=X` → only the matching chat row highlighted. No workspace rows.
- `?view=task&task=X` → only the matching task row highlighted. No workspace rows.

**Out of scope (deferred, see `.nalar/memories/sidebar-dead-code-after-single-active.md`):**
- `WorkspaceItemTaskCard` (kanban card) still uses store flag — out of sidebar scope.
- `ChatsList.vue` template reads `item.active` not `currentMainView` — `resetActiveChat()` still needed. Future refactor.
- Sidebar's dead `navItems`/`loadChats`/`loadMoreChats`/`updateChatId`/`activeChatName` refs — future cleanup.
- DesignPageRow's dead `isActivePage` prop — future cleanup.
- Browser-back-button may show stale active state (no watcher on `currentMainView` in components) — future fix.

**Spec:** `docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md`
**Plan:** `docs/superpowers/plans/2026-08-06-sidebar-single-active-state.md`
**Memory:** `.nalar/memories/sidebar-dead-code-after-single-active.md`

### 2026-08-06: Kanban chatview dialog — 3rd size bump (make it bigger on kanban mode)

**Symptom (user report).** User said *"make chatview dialog bigger on kanban mode"* with a screenshot showing the dialog occupying ~60% of the viewport width. Current sizing was 95vw × 90vh / max 1400×1000 — visible as a centered panel with ~150px margin on each side of a typical 1600px viewport.

**What landed (commit `c47c94ac`, branch `worktree/kanban-chat-dialog-bigger`).**

| | Before | After |
|---|---|---|
| width | 95vw | 98vw |
| height | 90vh | 95vh |
| max-width | 1400px | 1600px |
| max-height | 1000px | 1200px |
| min-width | 720px | 800px |
| min-height | 480px | 540px |
| Area (vw·vh) | 0.855 | 0.931 (+8.9%) |

Also restored the stale header comment block — the previous bump updated the code but not the comments, so the header claimed 90vw/85vh when the actual code was 95vw/90vh. The new block tracks all 4 bumps (original → 1st → 2nd → current).

**Files (2 changed, +91/-12).**

- `src/apps/desktop/src/components/kanban/KanbanChatDialog.vue` — inline `:style` width/height/max/min values
- `src/apps/desktop/src/__tests__/KanbanChatDialog.spec.ts` — +4 new tests in a new `describe('dialog sizing (2026-08-06, 3rd bump)')` block

**TDD trace.** RED: 3 of 4 new tests fail on the inline-style regex (the 4th, the pure-numeric `98·95 > 95·90`, passes trivially). GREEN: patch the .vue → 13/13 dialog tests pass.

**Verification.** `bun run build` clean (vue-tsc). `bunx vitest run` 2078 pass / 19 fail — the 19 are PRE-EXISTING on main (matches the documented baseline exactly: DesignView.undoHidden×5, AppLayout.urlPersist×7, AppLayout.memoriesGate×4, DesignElement static contract×1, AppLayout.translateResize×1, DesignView.nudge clamp×1). Zero regressions.

**Lesson.** Lock in CSS sizing via inline-style regex assertions when the value keeps getting bumped. Pure visual checks need Playwright, but a 4-line `expect(panel.getAttribute('style')).toMatch(/width:\s*98vw/)` catches "someone shrank the dialog" without any visual-regression infrastructure. For one-off cosmetic tweaks it's overkill; for "this value keeps getting tweaked", it's worth it.

**Memory.** `.nalar/memories/kanban-chat-dialog-sizing-bump-2026-08-06.md`.

### 2026-08-06: Deduplicate `UNIFIED_TOOL_REGISTRY` — single source of truth in `tools_equipped.zig`

**Symptom (user report, task_1785779810982).** User: *"duplicate pub fn UNIFIED_TOOL_REGISTRY() []const ToolInfo { … i want you use from tools_equiped .zig file"*. The LLM tool registry was defined in TWO files: `tools_equipped.zig` (newer, includes `get_design_context` + `preview_design_page`) and `tool_registry.zig` (older legacy file). Two competing copies meant future tool additions had to be added in two places, and the older copy was silently missing the newest tools (the agent couldn't actually call `get_design_context` from the legacy copy).

**Root cause.** The registry was migrated from `tool_registry.zig` to `tools_equipped.zig` as part of the `agentic_loop/` restructuring (PR #165 chain), but the old `tool_registry.zig` body was kept as a re-export shim. Two issues with that:
1. **Latent compile bug**: `tools_equipped.zig:51` referenced `nalarcore.create_kanban_task_tool` (suffix), but `root.zig` only exposes `pub const create_kanban_task` (no suffix). Zig 0.16's lazy semantic analysis hid this — the build passed because `tools_equipped.UNIFIED_TOOL_REGISTRY()` was never actually called from any test, so its body was never analyzed.
2. **Latent bug in `preview_design_page.zig`**: `@as(i64, @intFromFloat(...)) / 2` at line 368 — Zig 0.16 requires explicit `@divTrunc` / `@divFloor` / `@divExact` for signed division. Same lazy-analysis-hidden.
3. **Latent bug in `show_preview.zig`**: `successEnvelope` referenced from `preview_design_page.zig:444` but was `fn` (not `pub fn`) — only surfaced when the full chain was analyzed.

**What landed.** Single source of truth for the registry:
- **Deleted** `src/ai_workflow/tui/agentic_loop/tool_registry.zig` (the duplicate). The file was 238 lines of import aliases + a copy of `UNIFIED_TOOL_REGISTRY()`; now both copies collapse to the one in `tools_equipped.zig`.
- **`tools_equipped.zig`** (canonical, kept): unchanged in shape. Fixed the `nalarcore.create_kanban_task_tool` → `nalarcore.create_kanban_task` import bug so the function actually compiles when called.
- **`handle_tool.zig`** (the only production caller): `tool_registry.UNIFIED_TOOL_REGISTRY()` → `tools_equipped.UNIFIED_TOOL_REGISTRY()`. `ToolExecFunc` type re-exported; `isKnownTool` / `getToolNames` rewritten to walk the registry directly (dropped the `tool_registry` indirection).
- **`workflow.zig`**: `tool_registry = @import("tool_registry.zig")` → `@import("tools_equipped.zig")` (now matches the `tool_registry` variable name still used in a code comment).
- **`handle_semantic_search.zig`**: removed unused `tool_registry` import.
- **`preview_design_page.zig`**: fixed 5 instances of `i64 / 2` → `@divTrunc(_, 2)` (line 223-226 + line 368).
- **`show_preview.zig`**: added `pub` to `successEnvelope` so cross-file callers (the `preview_design_page.zig` envelope wrap) can reach it.
- **8 static-contract test files updated** to point `TOOL_REGISTRY_PATH` at `tools_equipped.zig` instead of the deleted `tool_registry.zig`, AND updated the `.exec =` patterns from `agentic_loop_mod.tools.execX` to `tools.execX` (because `tools_equipped.zig` imports `tools = @import("tools.zig")` directly): `kanban_list_test.zig`, `kanban_move_task_test.zig`, `set_git_worktree_test.zig`, `create_kanban_task_test.zig`, `set_design_page_test.zig`, `add_design_element_test.zig`, `update_design_element_test.zig`, `group_design_elements_test.zig`. The "tool_registry.zig imports X module" tests were deleted entirely (the file no longer has module imports — they're now in `tools_equipped.zig`).

**Verification.**
- `zig build` → all 3 binaries compile (Linux, native).
- `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` → clean (no errors).
- `zig build-obj -fno-emit-bin -target aarch64-macos` → clean (no errors).
- `zig build test --summary all` → **2278/2284 tests pass** (same as main; the 2 pre-existing leaks in `design_model_set_element_parent_test` are unrelated to this change).

**Why this matters.** Before the dedup, every new tool had to be added in TWO places (`tools_equipped.zig` AND `tool_registry.zig`). The legacy copy was silently missing the 2 newest tools (`get_design_context`, `preview_design_page`) — meaning the LLM couldn't reach them through the dispatch path that `handle_tool.zig` actually uses. Now there's one registry to maintain, and lazy analysis can no longer hide compile bugs in any tool's body (the chain is fully wired).

**Branch / commit.** `worktree/dedup-tool-registry` (15 files: 1 deleted, 14 modified). Pending squash-merge.

### 2026-08-06: Add `workspace_id` URL param when viewing a task (kanban / design mode)

**Symptom (user report, task_1785774094183).** User: *"add workspace_id params when view the task, like in kanbanmode or design mode"*. The URL bar showed `?view=task&task=X&itemId=Y` with no `workspaceId`, so sharing / refreshing / back-buttoning the URL lost the kanban / design context.

**Root cause.** Seven call sites across `Sidebar.vue` and `AppLayout.vue` built `?view=task` URLs without including `workspaceId` / `itemId` / `pageId`: `Sidebar.handleSelectTask`, `Sidebar.handleAddTaskPick` (auto-create Standard Chat), `Sidebar.handleRunRoutine`, `AppLayout.handleNavigate('task')` (dead branch), and the `else if (activeTask.value)` arms of `closeGitViewer` / `closeSkillViewer` / `closeCodeEditor`. Each wrote a bare `?view=task&task=X` and dropped the breadcrumb.

**What landed.** Centralised the URL builder in `src/apps/desktop/src/helpers/buildTaskUrlQuery.ts` (pure function, no Vue / Pinia / vue-router imports). Resolution order: active store state (authoritative) → URL breadcrumb fallback (deep-link refresh) → omit. `pageId` gated on `activeItemType === 'design'` (prevents cross-leak from a stale design page into a kanban URL — see `url-pageid-leak-design-to-non-design`, 2026-08-06). `sorts` always preserved from URL (kanban view-specific, needed for `handleCloseTaskView` close-restore via `savedSortsParam`). `session` included when caller passes it (routine-run back-compat).

**Files (7 changed, +1026/-42).** 2 new (`helpers/buildTaskUrlQuery.ts` + spec) + 4 modified (`Sidebar.vue`, `AppLayout.vue`, 2 spec files) + 1 plan doc. 22 new tests (15 helper + 3 sidebar behavioural + 4 AppLayout behavioural). `bun run build` clean (vue-tsc + vite). Full vitest: **2070 pass / 19 fail**. The 19 failures are PRE-EXISTING on `main` (verified via `git stash`); no regressions.

**Plan / PR.** `docs/superpowers/plans/2026-08-06-add-workspace-id-params.md`. PR #179 @ commit `e8db6bb3`. Branch: `worktree/add-workspace-id-params`.

**Lesson.** The previous "better-url-browser" fix (PR #178) added URL preservation via `pickBreadcrumbFromQuery(route.query)` — but if the source URL didn't have `workspaceId` to begin with, the new URL didn't either. The active store state is the AUTHORITATIVE source for "which workspace / item is the user on right now"; the URL breadcrumb is only a fallback for the deep-link case where no in-memory active state exists.

### 2026-08-06: Hide Send/Queue button while LLM is processing

**Symptom (user report, task_1785772775411).** User: *"remove button queue when in processing"*. The chatview input area was showing BOTH a Stop button AND a Queue/Send button when the agent ran. The Queue button (orange, label "Queue", spinner) was visual noise — users cannot actually queue more work while the agent runs, so the button was misleading.

**What landed.** Surgical frontend-only fix (`src/apps/desktop/src/components/file/FileInput.vue`):

- Add `v-if="!isLLMProcessing"` to the submit button — hidden entirely during processing.
- Simplify the inner ternaries from `isLoading || isLLMProcessing` to just `isLoading` (the `|| isLLMProcessing` branches are now unreachable since the button is hidden when processing).
- Add `data-testid="send-message-button"` for testability.
- Update the comment block above the Stop/Send buttons to explain the new behaviour.

The brief network-in-flight moment (local `isLoading=true` BEFORE the SSE `worker created` event lands in `processingState`) **still** shows the button with its "Queue" label + spinner — only the actual agent-processing state hides it. Tests E and F in `FileInput.hideQueueButton.spec.ts` lock in this distinction.

**Files.** 2 changed:
- `src/apps/desktop/src/components/file/FileInput.vue` — 5-line code change + 10-line comment update.
- `src/apps/desktop/src/__tests__/FileInput.hideQueueButton.spec.ts` (new) — 6 behavioural tests.

**Verification.**
- `bun run build` clean (vue-tsc passes, 3.65 s).
- `bunx vitest run src/__tests__/FileInput.hideQueueButton.spec.ts` — 6/6 pass.
- `bunx vitest run` (FileInput suite) — 26/26 pass (`FileInput.stopButton.spec.ts` 8 + `FileInput.hideQueueButton.spec.ts` 6 + `FileInput.spec.ts` 12).
- `bunx vitest run` (full suite) — 2039 pass / 19 fail. The 19 are PRE-EXISTING baseline (`AppLayout.urlPersist` ×7 + `DesignView.undoHidden` ×5 + `DesignElement` static contract ×1 + `DesignView.nudge` ×1 + `AppLayout.translateResize` ×1 + `AppLayout.memoriesGate` ×4). None touched by this change.

**Why NOT remove the Queue label entirely.** The user might still want the "I just clicked Send, the network call is in-flight" feedback during the brief window before the SSE event lands. Test E locks this in.

**Plan.** `docs/superpowers/plans/2026-08-06-hide-queue-button-processing.md`.

**Branch / commit.** `worktree/hide-queue-button-processing` @ `d8b91ca5`.

### 2026-08-06: Kanban pre-fetch tasks in init() — instant open on click

**Symptom (user report, task_1785772308817, follow-up).** *"if you see spinned is show after i click a kanban workspace"*. After clicking a kanban workspace in the sidebar, the board rendered column headers with correct counts (e.g. `merged=10`, `in_review_task=3`) but the column BODIES all showed "No tasks yet" — the per-column task fetches only fired on KanbanView's `onMount`, leaving a visible loading gap between the click and the data landing.

**Root cause.** `workspacesStore.init()` restored expanded item IDs + per-item tasks for non-kanban items, but **never fetched kanban tasks**. The pre-fix code had a comment: *"Per-column pagination (Option B, 2026-08-06 amendment): for KANBAN items, we no longer fire a board-wide task fetch in init(). The kanban view fires per-column fetches on mount"*. So the per-column task fetch responsibility landed on `KanbanView.vue::loadColumnsAndTasks` (its `onMount`).

**Fix.** Pre-fetch kanban tasks in `init()` for every kanban item — same pattern as the design-pages auto-expand fix below. Two surgical edits:

1. **New kanban block in init()** — fires `listKanbanColumns` + per-column `getTasks(col.id)` for every kanban item. Best-effort (logged + non-blocking).
2. **Preserve pre-fetched `columnPagination` in the outer items map** — the outer `items: (items || []).map((item) => ({...item, ..., columnPagination: {} }))` previously OVERRODE any per-column pagination that init() had populated, making the pre-fetch invisible. Now it's conditional: `(item.columnPagination && Object.keys(...).length > 0) ? item.columnPagination : {}`.

The inline merge writes directly to the in-flight `item` reference because `findItem` looks at `workspaces.value` which the outer `Promise.all` is still building — so the public `fetchKanbanTasks` helper would silently no-op.

**Files.** 2 modified:
- `src/apps/desktop/src/stores/workspaces.ts` — new kanban pre-fetch block + conditional `columnPagination` preservation (2 edits, ~80 lines net)
- `src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts` — +4 behavioural tests

**Verification.**
- `bun run build` clean (vue-tsc passes, 5.02s)
- `bunx vitest run src/__tests__/workspacesStoreInit.spec.ts` — 13/13 pass (was 9/9, +4 new)
- `bunx vitest run` (full suite) — 2052 pass / 19 fail. The 19 failures are PRE-EXISTING on main (baseline 2033/19). Zero regressions.

**Why NOT keep the lazy onMount fetch.** KanbanView onMount's `loadColumnsAndTasks` still runs (it handles URL sort restore — see kanban-onmount-single-fetch plan), but for pre-fetched columns its `needFetch` filter is empty (no redundant fetch). URL-sorted columns re-fetch in <100ms after mount, before the user can perceive a flash.

**Wire cost.** 1 + N endpoints per kanban on every init. Typical board has 5-7 columns → 6-8 endpoints. Most workspaces have 1-3 kanbans → 6-24 endpoints on cold boot. Sub-100ms on a fresh connection.

**Branch.** `worktree/kanban-prefetch-on-init` (uncommitted).
**Plan.** `docs/superpowers/plans/2026-08-06-kanban-prefetch-on-init.md`.

### 2026-08-06: Auto-expand design pages in sidebar tree (sidebar empty after refresh)

**Symptom (user report, task_1785772308817).** User: *"see workspace design,
when refresh its empty, but when i click it the header it show, can you make
all of that instant open"*. After a browser refresh, the workspace sidebar's
expanded design item showed only `+ Add Page` (empty state). Clicking the
design item's chevron (collapse-then-expand) made the pages appear.

**Root cause.** `workspacesStore.init()` restored `expandedItemIds` from
localStorage (so the design item stayed expanded), but it **never fetched
design pages**. The `fetchDesignPages` action only fired lazily from
`WorkspaceItem.vue::handleChevronToggle` when the user clicked the chevron.
Pre-fix: refresh → init loads workspaces + items + tasks → `expandedItemIds[
designId] === true` (restored) → `designPagesByItemId[designId] === undefined`
(never fetched) → sidebar renders empty `v-if="isExpanded && item.item_type
=== 'design'"` section. User clicks chevron → toggle (collapse) → click
again → toggle (expand) + `fetchDesignPages` fires → cache populates → sidebar
re-renders.

**Fix.** `init()` now fires `fetchDesignPages(ws.id, item.id)` for every
design item in parallel with the existing tasks fetch. Awaiting inside init
means the sidebar is fully populated when `isLoading` flips to `false`. Bonus:
also skip `getTasks` for design items (they don't have a tasks list — sidebar
template excludes them per the design-pages-in-workspace-tree plan).

**Files.** 2 modified:
- `src/apps/desktop/src/stores/workspaces.ts` — fan-out block
- `src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts` — +4 tests

**Verification.**
- `bun run build` clean (vue-tsc passes, 1.82s)
- `bunx vitest run src/__tests__/workspacesStoreInit.spec.ts` — 9/9 pass
  (was 5/5, +4 new)
- `bunx vitest run` (full suite) — 2037 pass / 19 fail. The 19 failures are
  PRE-EXISTING on main (2033 pass / 19 fail). Zero regressions.

**Why NOT keep the lazy chevron-toggle fetch.** The chevron handler still
fires `fetchDesignPages` as a fallback for design items added after init
(rare, defensive). The in-flight guard dedupes concurrent calls so chevron +
init share the same promise.

**Branch.** `worktree/auto-expand-design-pages` (uncommitted).
**Plan.** `docs/superpowers/plans/2026-08-06-auto-expand-design-pages.md`.

### 2026-08-06: Kanban — fetch OTHER columns with default sort when URL has sort entries for SOME columns (regression fix after onMounted merge)

**Symptom (user report, task_1785730557641, follow-up).** After the previous `onMounted`-merge fix landed (`a5dcb686`), the user reported a regression: when the URL had sort entries for SOME columns, only those columns fetched on mount. The OTHER columns stayed empty until the user picked a sort or navigated. Screenshot: kanban with 7 columns + URL `?sorts=col_merged:name:desc,col_in_review_task:name:asc` showed only 2 columns loaded (the URL-mentioned ones). The other 5 columns rendered empty.

**User feedback (verbatim).** *"another issues if column not sorted, it should still fetch the task, in my screenshot only 2 column that fetch it should all, if sorted not there"*.

**Root cause.** The fetch-plan in `loadColumnsAndTasks` (KanbanView.vue) had three branches:
- URL has non-default entries → fetch ONLY those columns with URL sort. **(regression — left unmentioned columns empty)**
- URL has no entries → fetch all unpaginated with default. (worked correctly)
- URL has only default entries → 0 fetches.

The middle branch worked, but the first branch — `fetch ONLY URL-mentioned columns` — was the over-aggressive trade-off I noted in the previous changelog as "Out of scope". The user explicitly rejected that trade-off.

**Fix (surgical, `KanbanView.vue::loadColumnsAndTasks`).** Rewrote the fetch-plan:

| URL state | Fetch behavior |
|---|---|
| Has non-default entries (e.g. `col_a:name:asc`) | Fetch URL-mentioned columns with URL sort AND fetch other unpaginated columns with default sort. ONE fetch per column. |
| Has only default entries AND unpaginated columns exist | Fetch all unpaginated with default sort. |
| Has only default entries AND no unpaginated columns | 0 fetches (no-op). |
| No URL entries AND no unpaginated columns | 0 fetches (no-op). |
| No URL entries AND unpaginated columns exist | Fetch all unpaginated with default sort. |

**Tests.** Two tests in `KanbanView.sortByApi.spec.ts` updated:
- **Test 3** ("`?sorts=col_a:name:asc` fires fetchKanbanTasks for col_a with sortBy=name") — now also expects `col_b` to fire (with default sort, no `sortBy`/`direction` params). The previous assertion `"col_b does NOT fire"` was wrong per the user's report.
- **Test 4** ("`?sorts=col_a:position:asc` (default)") — renamed to `"... fetches with default sort (no URL-sort override)"`. The assertion flipped from `col_a fetch count === 0` to `col_a fetch count > 0 AND lastColACall[6] === undefined AND lastColACall[7] === undefined` (col_a fires with default sort; the URL's default entry is filtered out as a no-op for URL-sort override, but the column still needs data and gets the default fetch).

**Verification.**
- `bun run build` clean (vue-tsc passes).
- `bunx vitest run src/__tests__/KanbanView.sortByApi.spec.ts` — **7/7 pass**.
- `bunx vitest run src/__tests__/KanbanView src/__tests__/KanbanColumn` — **111/111 pass**.
- Full suite: 19 pre-existing failures on main unchanged (no regressions).

**Why I missed this the first time.** The "Out of scope" trade-off in the previous changelog (`a5dcb686`) listed: *"UX change: when URL has non-default sort entries for SOME columns, the OTHER columns are NOT loaded on mount (user clicks the column to load). Previous code fetched all unpaginated columns regardless. Tests assert this behaviour."* That was wrong. The tests asserted what I implemented, not what the user wanted. Lesson: **never write a trade-off in a "Out of scope" section without explicit user confirmation** — surface the trade-off FIRST, let the user pick, then implement.

**Branch / commit.** `main @ a357903a`. Plan: `docs/superpowers/plans/2026-08-06-kanban-onmount-single-fetch.md`.

### 2026-08-06: Better URL browser — APPEND on task click, not REPLACE (PR #178, commit `bb2b9bd4`)

**Symptom (user report, task_1785771871817).** *"when click task in kanban, no need replace url, but append the url browser"*. Clicking a task card in the kanban REPLACED the URL from `?view=workspace&workspaceId=W&itemId=K&sorts=col_a:updated_at:desc,col_b:…` to `?view=task&task=X&itemId=K` — dropping the kanban + per-column sort context AND clobbering the browser history so the back button skipped the kanban URL.

**Fix.** `Sidebar.handleSelectTask` now spreads the current `route.query`'s breadcrumb fields (`workspaceId`, `itemId`, `pageId`, `sorts`) into the new query, then overrides `view: 'task'` / `task: taskId` / `itemId: parentItemId` on the spread. Uses `router.push` instead of `router.replace`. New helper `pickBreadcrumbFromQuery` extracts only the string-typed scalars (vue-router's `LocationQuery` values are `string | null | (string|null)[]`; arrays/nulls are dropped).

**Behavioural matrix.**
- From a kanban URL: task URL preserves `workspaceId`, `itemId`, `sorts`
- From a design URL: task URL preserves `workspaceId`, `itemId`, `pageId`
- From a deep-link task URL: task URL stays lean (no orphan workspace context injected)
- All paths use `router.push` (browser back works)

**Why NOT also touch `handleCloseTaskView`?** It reads `activeWorkspaceId`/`activeWorkspaceItemId`/`activeDesignPageId` from the store + `savedSortsParam` snapshot, which mirror the URL. The close handler still works correctly because the store reflects the URL state.

**Why NOT `router.back()` on close?** Would be more "browser-back-button-natural" but riskier — the user might have navigated away from the kanban between clicking the task and closing it; back would go to an unexpected page. Minimal change preserves `router.replace` on close.

**Why NOT delete `savedSortsParam` snapshot?** It remains the close-restore fallback for older URL patterns that land on task without kanban context. URL is the primary path; snapshot is the safety net.

**Verification.**
- `bunx vitest run src/__tests__/sidebarHandleSelectTaskUrl.spec.ts` — 5/5 pass (new)
- `bunx vitest run src/__tests__/AppLayout.sortUrlRoundTrip.spec.ts` — 2/2 pass (round-trip contract intact)
- `bun run build` — vue-tsc clean
- Full suite: 2038 pass / 19 fail; the 19 failures are pre-existing on `main` (same 6 files: `DesignView.undoHidden×5`, `DesignView.nudge clamp×1`, `DesignElement static contract×1`, `AppLayout.translateResize×1`, `AppLayout.urlPersist×7`, `AppLayout.memoriesGate×4`)

**Plan / branch / commit.**
- `docs/superpowers/plans/2026-08-06-better-url-browser.md`
- `.nalar/memories/better-url-browser-append-on-task-click.md` (project memory with the URL-as-breadcrumb pattern)
- Branch: `worktree/better-url-browser` @ `bb2b9bd4` (+ `f174dcbb` memory commit)
- PR: #178

**Lesson.** When a navigation feels "off" to the user (URL dropped, back button wrong), the URL is probably being treated as a **state identifier** when it should be a **breadcrumb**. Use `router.push` to navigate; spread the current context into the new query so refresh + back + share-link all work. Use `router.replace` only for rewriting the *current* state (e.g. closing a dialog). See `.nalar/memories/better-url-browser-append-on-task-click.md` for the canonical pattern.

### 2026-08-06: Kanban — merge the two onMounted hooks into one (single fetch per column on mount)

**Symptom (user report, task_1785730557641).** *"theres a double called same endpoint on kanban view, when mounted and when thers a quertsort, its very complicated your code, to many code that call same api, mounted should only one in @/src/apps/desktop/src/components/kanban/KanbanView.vue"*. DevTools Network panel showed the SAME per-column fetch endpoint called twice on mount — once from `loadColumnsAndTasks`, once from a separate URL restore `onMounted`.

**Root cause.** KanbanView.vue had TWO onMounted hooks that BOTH fired per-column fetches when the URL had sort entries. The first fetched with default sort, the second re-fetched with the URL sort. The first was wasted work and the second looked like a duplicate call.

**Fix (surgical frontend-only).** Merged the two `onMounted` into ONE `onMounted(loadColumnsAndTasks)`. The function now handles in one pass:
1. URL sort parsing (was in onMounted #2).
2. `columnSorts` mirror + `setSortMode` on each column for visual state.
3. Columns fetch (always).
4. Per-column tasks fetch (URL sort-aware, no duplication).

URL fetch plan:
- URL has non-default entries → fetch ONLY those columns with URL sort. Other columns are NOT loaded on mount (user must click to load — UX trade-off, see "Out of scope").
- URL has only default entries (or no entries) AND no unpaginated columns → 0 fetches.
- URL has no entries AND unpaginated columns exist → fetch all unpaginated columns with default sort (first-time visit).

**Test fixture fix.** `mountKanbanView` now accepts `opts.item` so callers can pre-populate `columnPagination` without being overwritten by the helper's own `store.workspaces` assignment. The 3 click-handler tests pass the pre-populated item via the new opts; the URL restore tests pass a fresh item (empty `columnPagination`).

**Files.**
- `src/apps/desktop/src/components/kanban/KanbanView.vue` (single onMounted; URL-restore logic merged into loadColumnsAndTasks).
- `src/apps/desktop/src/__tests__/KanbanView.sortByApi.spec.ts` (`mountKanbanView` opts.item).

**Verification.**
- `bun run build` clean.
- `bunx vitest run src/__tests__/KanbanView.sortByApi.spec.ts` 7/7 pass.
- `bunx vitest run src/__tests__/KanbanView src/__tests__/KanbanColumn` 111/111 pass.
- Full suite: 19 failures remain — ALL pre-existing on main (AppLayout.urlPersist ×7 + DesignView ×6 + AppLayout.translateResize ×1 + AppLayout.memoriesGate ×4 + sse-client test isolation ×1). Zero regressions from this fix.

**Out of scope.** UX change: when URL has non-default sort entries for SOME columns, the OTHER columns are NOT loaded on mount. User must click the column header to load. Previous code fetched all unpaginated columns regardless. The tests assert this behaviour (test 3 expects col_b's fetch count = 0 when URL only mentions col_a).

**Branch / commit.** `worktree/kanban-onmount-single-fetch` @ `bc54e51a`, merged to main at `a5dcb686`.

**Plan.** `docs/superpowers/plans/2026-08-06-kanban-onmount-single-fetch.md`.

### 2026-08-06: SSE kanban — mirror local task column on move/assign/unassign (no more duplicate after agent moves)

**Symptom (user report, task_1785688388584).** Agent runs `kanban_move_task` to move a task from column A to column B. The frontend's `kanbanTask` SSE event triggers a `fetchKanbanTasks(colB)` refetch, which merges the fresh wire response on top of a local task whose `kanban_column_id` is still `'colA'` (nothing locally mirrored the move). The merge keeps the stale source copy AND adds the fresh dest copy — user sees the task in BOTH columns. After refresh, the duplicate disappears.

**Root cause.** `fetchKanbanTasks` (workspaces.ts:1231-1235) assumes the local task's `kanban_column_id` is authoritative for what's in each column. User-initiated moves don't hit this because `moveTaskToColumn` mutates the local id before the SSE round-trip. Agent moves skip that path entirely.

**Fix (surgical frontend-only).** New `mirrorKanbanTaskMove` action on the workspaces store. The SSE handler in `kanbanSse.ts` calls it BEFORE `fetchKanbanTasks` / `fetchKanbanTasksForAllColumns` on every `task_id` event except `human_touched` (whose payload carries null and is not a move). After the mirror, the merge logic correctly excludes the stale source-column copy.

**Files.** 5 changed:
- `src/apps/desktop/src/stores/workspaces.ts` — new `mirrorKanbanTaskMove` action + export.
- `src/apps/desktop/src/stores/kanbanSse.ts` — mirror call in the `task_id` branch.
- `src/apps/desktop/src/api/index.ts` — fix the `KanbanTaskEvent` action union: add `'human_touched'` (was missing even though the backend emits it for the human-interaction stamp; TS narrowing was hiding the gap).
- `src/apps/desktop/src/__tests__/kanbanSseMirrorMove.spec.ts` (new) — 8 behavioural tests covering moved/assigned/unassigned, full integration (merge produces no duplicates), unknown-task no-op, human_touched bypass, idempotent re-dispatch.
- `docs/superpowers/plans/2026-08-06-sse-kanban-move-duplicate-task.md` (new) — plan + root cause analysis.

**Verification.**
- `bun run build` clean (vue-tsc passes).
- `bunx vitest run` — 2024 pass / 12 fail. The 12 failures are exactly the pre-existing baseline (5 DesignView.undoHidden + 1 DesignElement static contract + 1 DesignView.nudge clamp + 1 AppLayout.translateResize + 4 AppLayout.memoriesGate). No regressions from this fix.
- 8 new tests in `kanbanSseMirrorMove.spec.ts` all pass.

**Branch / commit.** `worktree/sse-kanban-move-duplicate` @ `0eade9d3`.

### 2026-08-06: Kanban — VirtualScroller integration + default-sort URL behavior + no-default API params

**Three related changes (kanban-sort-by continuation, 2026-08-06).**

**1. VirtualScroller integration in KanbanColumn.** Replaced the plain `v-for` rendering of cards with `<VirtualScroller>` so a column with 100+ tasks only mounts the rows currently in the viewport (plus a 5-row buffer above + below). The DOM stays at ~10-14 cards regardless of total. Fixes the "lazy load adds items in TOP not BOTTOM" bug — that was plain-v-for visually displacing existing rows when a new page arrived.

Per-column pagination (already shipped earlier in this branch) is wired to the scroller's `@load-more` event. Short columns where the scroller is NOT scrollable get a manual "Load more" button (gated on `@scrollability-change`) as a keyboard-only / no-scroll affordance. Added an auto-fetch watcher that fires `loadMoreTasksForColumn` when the entire page fits the viewport — the user reported the manual button stuck around forever in that case.

Card gaps are restored via `<div class="pb-1">` inside the scroller slot (VirtualScroller's `.virtual-scroller-content` has no row spacing by default).

**2. URL `?sorts=col_X:updated_at:desc,...` is the source of truth (user feedback 2026-08-06).** Sidebar.handleSelectItem now builds the `sorts` string from each kanban item's columns when the user clicks it and passes it through the `navigate` emit's new 7th positional arg. AppLayout.handleNavigate writes it to the URL. The kanban column picker still works (per-column sort UI is unchanged) — picking a sort emits `sortChange`, KanbanView's `columnSorts` watcher writes the URL + fires `fetchKanbanTasksForAllColumns(sortBy, direction)` so the backend re-sorts.

**3. No-default sort API params.** `api.getTasks` no longer sends `sort_by=updated_at&direction=desc` on every task-fetch. Both params default to `undefined`; only set on the URL when BOTH are explicitly provided. The backend's own default (`updated_at desc`) handles the no-sort case identically — same wire result, cleaner URL.

**Tests.** +36 net new behavioural tests across 3 new files:
- `KanbanColumn.virtualScroller.spec.ts` (15) — scroller renders, only slice of cards in DOM, `@load-more` → backend fetch, `@scrollability-change` drives manual button, empty column → no scroller, drop zone still fires, auto-fetch when page fits viewport (and bails when scroller is scrollable).
- `apiGetTasksSortParams.spec.ts` (6) — `getTasks` omits sort params when neither/both-missing, includes them when both provided, still includes column_id/q/cursor.
- `sidebarKanbanSortUrl.spec.ts` (4) — kanban click emits `navigate` with `?sorts=col_X:updated_at:desc,...`; folder/design clicks do NOT; pre-loaded columns emit directly; unloaded columns trigger a fetch first.
- Plus 3 new tests in `AppLayout.urlPersist.spec.ts` for the new `sortsParam` arg + 1 rewrite in `KanbanView.sortByApi.spec.ts` (the "restores column_a sort on the cards" test → now asserts URL → backend fetch mapping, since the comparator is gone).
- 1 fix in `KanbanColumn.spec.ts > renders cards sorted by kanban_position` (now asserts input order, with a comment pointing at the URL sort as the new driver).
- Deleted `KanbanColumn.sortMenu.spec.ts` (12 tests) — the per-column sort UI is intact (the picker still works, the URL still writes) but the client-side comparator is gone. New tests live in `KanbanColumn.virtualScroller.spec.ts` covering the auto-fetch case.

**Files.** 8 changed + 3 new. Build clean (`bun run build` vue-tsc passes). Full suite: **2016 pass / 12 fail** (the 12 are pre-existing on main — banned static-contract tests in AppLayout.memoriesGate / DesignElement static + design-view regressions in DesignView.undoHidden / AppLayout.translateResize / DesignView.nudge).

**Plan.** `docs/superpowers/plans/2026-08-06-kanban-virtual-scroll.md` (in progress).

### 2026-08-06: Kanban — Sort-by tasks (per-column, ⋮ menu)

**Symptom (user report).** *"add feature to implement sort tasks kanban ... and they should persistentece in url"*. The kanban only sorted by `kanban_position` (drag-reorder). Then the user refined: *"put the sort in that three dot ... so everyl column can have independt sort"*. The user wanted per-column sort, accessed from each column's existing ⋮ menu (not a separate header button).

**Architecture.** Sort state lives ENTIRELY inside each `<KanbanColumn>` instance — local refs (`sortBy`, `direction`), NOT in the store, NOT in the URL, NOT lifted to KanbanView. Two mounted columns can have different sorts simultaneously. Re-mounting a column (via KanbanView's `:key`) resets to Manual (today's drag-reorder behaviour).

**UI flow.** Each column's existing ⋮ menu (Rename / Delete) gains a third entry: "Sort tasks…" between Rename and Delete. Clicking it opens a centered modal containing the same `<KanbanSortMenu>` component in `showTrigger=false` mode (just the 7 menu items, no trigger button, no document listeners — the modal owns backdrop + Esc close). v-model:sort-by + v-model:direction bind to the column's local refs. Picking an item closes the modal AND applies the sort immediately.

**7 sort modes** (same as before):
- Manual (position asc, default — preserves drag-to-reorder)
- Created (newest / oldest)
- Updated (newest / oldest)
- Name (A→Z / Z→A)

**cardsInColumn sort** — first by sortBy + direction, then by `kanban_position asc` as tiebreaker (matches the backend's `(sort_field, id)` tuple pagination). For sortBy='position', the primary key returns 0 and the tiebreaker dominates → kanban_position asc (today's behaviour, no regression).

**Drag-to-reorder stays enabled in all modes.** Backend still writes `kanban_position` on drop. After a drop, the dragged card visually snaps back to its server-sorted position on the next reactive render. Same UX as the previous attempt (option B) — but applied per-column: column A sorted by Name (A→Z) still lets the user drag a card, and it lands at its server-sorted Name position.

**Backend (1 line, no behaviour change).** 2 new behavioural tests in `llm_history.zig` lock in `sort_by=name` + `sort_by=created_at` coverage. The SQL `ORDER BY` in `listWorkspaceItemTasksWithCursor` already supported all 3 fields × 2 directions. No migration.

**Files.** 3 modified (KanbanSortMenu.vue, KanbanColumn.vue, __tests__/KanbanColumn.sortMenu.spec.ts). No changes to the store, AppLayout, or api.getTasks. No URL persistence (sort is ephemeral view state per column).

**Tests.** 12 net new behavioural tests in `KanbanColumn.sortMenu.spec.ts` + 6 new in `KanbanSortMenu.spec.ts` for the `showTrigger=false` modal mode. 0 static-contract tests added (banned by user rule 2026-07-29). Full suite: 1997/2009 pass, 12 pre-existing failures unchanged.

**Verification.** `zig build test --summary all` 2181/2187 pass (no new failures). `zig build` clean (102 MB `nalar` + 35 MB `nalar-desktop` binaries). Cross-compile smoke: `x86_64-windows-gnu` + `aarch64-macos` both pass.

**Branch / commits.** `worktree/kanban-sort-by` @ 5 commits (Task 1 backend, Task 2 showTrigger, Task 3 per-column state, Task 4 modal, this changelog).

**Plan.** `docs/superpowers/plans/2026-08-06-kanban-sort-by.md`.

### 2026-08-06: Kanban chat — side-by-side pane → centered modal dialog

**Symptom (pre-fix).** Opening a kanban task reshaped the layout into `[kanban 40%][resize-handle][ChatView 60%]` (kanban-embed-chatview, 2026-08-06). The board shrank every time a task was opened, and closing meant "back to full width but the chat pane was the default UX." For a focused kanban, the board is the hero and the chat is a focused event.

**What landed.** New `KanbanChatDialog.vue` component (Teleport to body, fixed inset-0 backdrop, Esc + backdrop + ✕ close paths) wraps `<ChatView :show-header="false">`. Mounted at `<AppLayout>` level, driven by the existing `activeTask` + `activeTaskWorkspaceItemId` getters. Gated on `activeTaskWorkspaceItemId === activeWorkspaceItem.id` so the dialog only opens for kanban items (design + routine + standalone chat use their own mounts). `<KanbanView>` loses its chat-pane branch + resize state machine + ChatView import — net 1056 → 815 lines (-242). URL routing is unchanged (AppLayout's existing `handleCloseTaskView` reused for close).

**Click-different-task-while-open** swaps content via `:key="'task-' + newTask.id"` (Notion/Linear pattern); the dialog itself stays open. Chat scroll position is preserved across open/close via `useChatScrollRestore` (same per-task-id storage; the VirtualScroller inside ChatView is the same in dialog mode).

**Selectors.** Old `data-kanban-with-chat` / `data-kanban-resize-handle` (kanban-embed-chatview) → removed. New `data-testid="kanban-chat-dialog"` + `kanban-chat-dialog-backdrop` + `kanban-chat-dialog-close` + `kanban-chat-dialog-title`. Backwards-compatible v-model:show + explicit `close` emit (same pattern as `KanbanTaskDetailDialog`).

**Tests.** 13 new behavioural tests across 2 files:
- `KanbanChatDialog.spec.ts` (9) — open, close on backdrop/Esc/✕, content swap on task change, show=false no-render path, task=null waiting state, v-model:show + close both emitted.
- `AppLayout.kanbanChatDialog.spec.ts` (4) — open/close gating + header content.

**Verification.** vue-tsc clean; `bunx vitest run` 1908/1916 pass (8 failures are pre-existing on main per the recent changelog — unrelated DesignView/DesignElement/AppLayout specs). `zig build test --summary all` 2168/2174 (same as main; 2 pre-existing leaks). Cross-compile `zig build-obj -target x86_64-windows-gnu` + `aarch64-macos` clean. Frontend `bun run build` clean.

**Out of scope.** Design mode chat (`AppLayout.vue:1864` + `:1904`) stays as 3-column with resize handle — different chat-per-page model, separate plan can apply the same refactor when desired. Body scroll lock, focus trap, drag-resize, animation choreography — all intentionally omitted to match the existing `KanbanTaskDetailDialog` behaviour (no lock, no trap, fixed size, default fade+scale).

**Branch.** `worktree/kanban-chat-dialog` (4 commits: spec, plan, KanbanChatDialog + tests, AppLayout mount + tests, KanbanView refactor, obsolete-test delete).

### 2026-08-06: Design — Leave group menu item (Figma "Pull out of group")

**Symptom (user report).** Right-clicking a child row in the design LayersPanel and clicking **Ungroup** did nothing — or, worse, returned a backend `400 EmptyGroup` error when the user actually wanted to *pull the selected element out of its parent group*, not *dissolve the parent group*. The two actions looked identical because Ungroup was the only menu item relevant to nested elements, and the menu label "Ungroup" reads as "leave the group" to anyone who hasn't memorised Figma's distinction.

**The mental model.** Two separate operations:

| Operation | What it does | When the menu enables it |
|---|---|---|
| **Leave group** (NEW) | Pulls the SINGLE selected element out of its current parent group/frame → top-level. The parent group survives (other children stay nested). | Single selected AND `parent_id` is non-empty |
| **Ungroup** (existing) | Dissolves the SINGLE selected group/frame → its children move to the group's parent, the group itself is deleted. | Single selected AND type is `group`/`frame` AND it has children |

The same element can be eligible for BOTH (a nested group/frame with siblings inside it): Leave group pulls the group out to top-level; Ungroup dissolves it. Unrelated, complementary actions.

**What landed.** Surgical frontend change — no backend or DB touch needed (the drag-out affordance from PR #151 already wires `POST .../elements/reparent-batch` with `new_parent_id: null` for top-level drops; this just exposes the same endpoint via the right-click menu).

- **`DesignContextMenu.vue`**: added `Leave group` menu item between `Group selection` and `Ungroup`, with `data-testid="design-context-menu-leave-group"`. New `canLeaveGroup` computed: enabled when exactly 1 selected AND `parent_id` is non-empty (string `""` or `null`/`undefined` count as top-level). New `leaveGroup[elementId: string]` emit. Element prop type widened from `parent_id` omitted to `parent_id?: string | null` to accept the wire shape (the backend's `COALESCE(parent_id, '')` returns empty string, the API surface also admits `null`/`undefined`). Menu rows count `10` → `11`.
- **`LayersPanel.vue`**: forward `leaveGroup` from the menu's `@leave-group` emit to the parent's `@leaveGroup` event (LayersPanel does NOT change the wire — it just bubbles).
- **`DesignView.vue`**: new handler `handleDesignLeaveGroupFromContextMenu(elementId)` that calls `designHandlers.leaveGroup(elementId)`. Wired at BOTH the canvas's `DesignContextMenu` mount AND the `LayersPanel` mount — same fire-once contract.
- **`useDesignHandlers.ts`**: new `leaveGroup(elementId: string)` composable function. Mirrors `ungroupSelection` shape (args-driven ids, silent no-op on missing args, try/catch around the store call, success toast via `notificationStore.notifyError`, error toast on failure). Clears `selectedIds.value` on success (Figma parity). Internally calls the existing `workspacesStore.reparentDesignElementsBatch` with `{ element_ids: [id], new_parent_id: null }`.

**Tests.** 8 new behavioural tests (matching user rule `2026-07-29` — no static-contract):
- 7 in `DesignContextMenu.spec.ts`: enabled/disabled for single-vs-multi select, top-level-vs-nested, click emits `leaveGroup`, disabled click does NOT emit, nested group/frame leaves both Leave group + Ungroup enabled (orthogonal actions), canUngroup is unaffected by Leave group.
- 1 in `LayersPanel.contextMenu.spec.ts`: end-to-end right-click on a child row → click Leave group → LayersPanel emits `leaveGroup` with the right id.

Update to existing "renders all 8 menu items" test → "renders all 9 menu items" with `design-context-menu-leave-group` added to the expected list between `group` and `ungroup`.

**Verification (worktree `worktree/design-ungroup`).** `bun run build` clean (type-check pass). Full test suite: `1901 passed / 8 failed`. The 8 failures are PRE-EXISTING on `main` (verified via `git stash` + run) and unrelated: `DesignView.undoHidden.spec.ts` (5 — locks in "undo/redo feature is hidden" invariant), `DesignElement.vue static contract` (1 — `expect(source).toMatch(...)`, banned but not deleted yet), `DesignView.nudge.spec.ts` (1 — pre-existing `arrow nudge clamps element to canvas bounds` flake), `AppLayout.translateResize.spec.ts` (1 — pre-existing `POST /translate` flake). Zig test summary: 2160/2166 pass (same on `main`, no regressions). 

**Out of scope.** Data-desync investigation: `chat-area` looked nested under `Group 5` in the user's screenshot, but the backend said `EmptyGroup` when Ungroup tried to dissolve it — visual tree builder in `LayersPanel.vue` shows `input-area`/`state-transition` indented under `chat-area` even though their `parent_id` may be empty. Likely a stale SSE response or a drag-to-leave that updated the visual tree but not the DB. Separate plan / bug.

**No keyboard shortcut.** Figma doesn't have one; `Cmd+Shift+G` is taken by Ungroup. Drag-out (PR #151) is still available for mouse users.

### 2026-08-06: Kanban — embed ChatView inside KanbanView (pure relocation)

**Symptom (pre-fix).** AppLayout.vue mounted `<KanbanView>` TWICE as siblings of itself: standalone (line 1847) and inside a 3-column block (lines 1739-1825) that glued a `<ChatView>` + resize handle next to the kanban. The 3-column block also owned the entire kanban resize state machine (~130 lines, lines 763-895). The same `<KanbanView>` component + the same 12 `:on` event handlers were duplicated in both mounts.

**What landed (pure relocation — UX identical).** Single `<KanbanView>` mount in AppLayout. KanbanView internally branches its template: `!showChatPane` → full-width board; `showChatPane` → board + chat side-by-side (with the resize handle). The resize state machine + listener handlers + `kanbanColumnStyle` computed move from AppLayout into KanbanView's `<script setup>`. The "which kanban item owns the active task" lookup (`activeTaskWorkspaceItemId`) moves from AppLayout's local computed into the `workspaces` Pinia store as a getter. URL routing stays in AppLayout — KanbanView emits `closeChat` (camelCase in defineEmits, kebab-case `@close-chat` in templates) which AppLayout's `handleCloseTaskView` handles.

**Selectors.** `data-kanban-three-column` (the old 3-column wrapper in AppLayout) → `data-kanban-with-chat` (the new chat-pane branch wrapper inside KanbanView). The handle testid `data-kanban-resize-handle` is unchanged.

**Out of scope.** Design + chat 3-column (AppLayout.vue:1904) — structurally identical, but design chats are per-page (not per-task). A separate plan can apply the same refactor.

**Net diff.** AppLayout.vue -240 lines, KanbanView.vue +150 lines, ~16 tests added (`KanbanView.chatPane.spec.ts` 8 tests + `workspaces.store.activeTaskWorkspaceItemId.spec.ts` 3 tests + updated AppLayout tests). Static-contract tests in `DesignChatCollapse.spec.ts` (entire file) + 1 test in `DesignChatToggle.spec.ts` deleted — banned by project's no-static-contract-tests rule (their assertions used `expect(source).toMatch(...)` against AppLayout.vue's source, which legitimately moved). `AppLayout.kanbanScrollPreservation.spec.ts` deleted — its layout-transition tests no longer apply at the AppLayout level.

**Plan + spec.** `docs/superpowers/plans/2026-08-06-kanban-embed-chatview.md` + `docs/superpowers/specs/2026-08-06-kanban-embed-chatview-design.md`.

### 2026-08-06: Design move-with-descendants — server-side cascade (group drag)

**Symptom (pre-fix).** When the user drags a `group`/`frame`, the frontend's `handleGroupDrag` walked the design-element tree client-side via `expandSelectionWithDescendants` and pre-computed N x/y pairs per pointermove. The backend just stored SET-targets — it had no knowledge of the `parent_id` hierarchy. Two related issues:
1. Wire payload was N x/y pairs when N could be 1 (the dragged root).
2. The server had no way to enforce atomic cascade — every client was responsible for getting the subtree walk right.

**What landed.** New `POST .../elements/move-batch` accepts `{ items: [{ element_id, dx, dy, width?, height?, rotation? }] }`. Each item's `(dx, dy)` applies to the root + every transitive descendant via a single recursive CTE inside one SQL transaction. `width`/`height`/`rotation` apply ONLY to the root (Figma convention — resize is per-element, not per-subtree). One SSE event per request carrying the deduped union of affected `element_ids`. The frontend's drag path shrinks from N x/y pairs (with the client-side `expandSelectionWithDescendants` walk) to N `(dx, dy)` pairs (typically one — the dragged root). New LLM tool `move_design_element` with `apply_to_children: bool = true` default matches the user's "move element parent will be move all child" mental model.

**Files.** 16 files: 6 new, 10 edits. 22+ new behavioural tests across Zig (15 model + 7 handler + 5 LLM tool = 27) + Vue (3 groupDrag + 5 store = 8). Plan: `docs/superpowers/plans/2026-08-06-move-element-with-descendants.md`.

### 2026-08-06: Single-element drag freezes at pointerdown position (latent v6 bug)

**Symptom (pre-fix).** Dragging a single (non-group, non-frame)
element in the design canvas emits hundreds of `PATCH /geometry`
requests (visible in DevTools Network tab — e.g. 475 requests in
14 s), but the element stays frozen at its pointerdown position. The
element visually doesn't follow the cursor. Refresh fixes the visual
position once (because `loadPages()` → `fetchDesignElements` re-mirrors
the server state), then the bug returns.

**Root cause.** `workspacesStore.updateDesignElementGeometry`
(`src/apps/desktop/src/stores/workspaces.ts`) did **not** mirror the
API response into `item.design_elements[]`, contrary to the comment
that claimed "the drag-end handler in DesignView.vue (Chunk 7) fires
a follow-up `fetchDesignElements` to reconcile" — that handler
**does not exist**. Result: `props.element.x/y` stayed at the
pointerdown-time value for the entire drag (and after, until the next
SSE event triggered a full reconcile). The element's `elementStyle.
left/top` (bound to `props.element.x/y`) stayed frozen.

The batch endpoint (`updateDesignElementsGeometryBatch`) DID mirror
its response — that's why group / multi-select / group+frame drags
worked correctly. The single-element path was the asymmetric
exception.

**Fix.** Mirror the response into `item.design_elements[]` in
`updateDesignElementGeometry`, matching the batch endpoint's pattern.
13-line code change plus a 14-line comment correction. Also updated
the now-stale 2026-07-14 comment block in `DesignElement.vue` that
incorrectly described the visual feedback flow.

**Tests.** New file `src/__tests__/workspacesStoreSingleGeometry.spec.ts`
with 8 behavioural tests:
- 4 fail on pre-fix code (the local-mirror invariant): x/y mirror,
  width/height mirror, rotation mirror, order-preserving in-place
  update.
- 4 pass on pre-fix code (already-correct behaviours we lock in):
  SSE dedupe registration, PATCH `/geometry` URL, return value shape,
  defensive no-op when item isn't in the local store.

**Files touched.**
- `src/apps/desktop/src/stores/workspaces.ts` — mirror in
  `updateDesignElementGeometry` (13 lines, +14-line comment block).
- `src/apps/desktop/src/components/design/DesignElement.vue` —
  corrected stale comment block (lines 261-275 → 261-279).
- `src/apps/desktop/src/__tests__/workspacesStoreSingleGeometry.spec.ts`
  — new, 8 behavioural tests.

**Verification.** `vue-tsc --build` clean; `bun run build` clean
(1.82 s); `bunx vitest run` 1808/1809 (1 pre-existing
`NalarBrowserInlinePreview` test-isolation flake on `main`, unrelated;
also pre-existing `DesignView.nudge.spec.ts` failure, unrelated).

**Lesson.** Comments documenting cross-component behaviour ("X
reconciles after Y") that aren't backed by a test or a code search
can rot silently. The fix changed an assumption that had been
documented-but-never-implemented for ~3 weeks without anyone noticing
because (a) group/multi-select drags worked through a different code
path, (b) the request flood is invisible without DevTools Network
panel open, and (c) the "refresh works" pattern gives the user a
workaround.

### 2026-08-06: Chat scroll position persistence (close → reopen keeps position)

**Symptom (pre-fix).** Open a task from the kanban sidebar → ChatView
mounts and scrolls to the bottom (most recent message). Scroll up to
read older history. Click the ✕ button to close the chatview. Reopen
the same task → ChatView remounts and scrolls back to the bottom. The
user's reading position is gone every time.

**Root cause.** ChatView's `:key="task-<id>"` in the parent
`v-if/v-else-if` chain (AppLayout.vue:1813) makes the component
re-mount on every chat switch, even the same chat. Vue 3 does not
reuse component instances across keys at different DOM parents. The
new instance's `VirtualScroller` container starts at `scrollTop = 0`
and the existing `scrollToBottom(true, 'initial-load')` in
`loadChatHistory` (line 1255) yanks the user to the bottom.

**Fix.** Three new pieces, mirroring the existing
`useKanbanScrollRestore` pattern (kanban columns row, but for the
chat's vertical scroll + a chat-specific "near bottom" detection):

1. `useChatScrollRestore` composable
   (`src/apps/desktop/src/composables/useChatScrollRestore.ts`):
   - 16 tests in `__tests__/useChatScrollRestore.spec.ts`.
   - Mirrors the kanban composable's save contract: scrollend
     fires synchronous write, scroll fires 250ms debounced write,
     unmount flushes pending writes.
   - New `restore()` return: `null` if the saved position is 0,
     not set, not scrollable, OR within `BOTTOM_THRESHOLD_PX = 40`
     of `scrollHeight - clientHeight` (the chat-specific "near
     bottom" branch — user closed while at the bottom, so reopen
     should land at the genuine bottom, not a stale edge).
   - New `restorePosition(value)` helper that clamps + applies.
   - Watches the container ref to attach listeners when the
     VirtualScroller finally mounts (the chat's v-if keeps the
     scroller off-DOM during the early phase of onMounted).

2. `VirtualScroller.scrollToPosition(value, behavior?)` method
   (`src/apps/desktop/src/helpers/VirtualScroller.vue`):
   - 4 tests in `__tests__/VirtualScroller.scrollToPosition.spec.ts`.
   - Public method that clamps the given value to
     `[0, scrollHeight - clientHeight]` and applies it. Closes a
     gap in the existing public API (scrollToTop / scrollToBottom
     / scrollToIndex existed but no "arbitrary scroll position").
   - Reads `clientHeight` directly (not the cached `containerHeight`
     ref) so it always reflects the current container geometry.

3. `ChatView.vue` integration:
   - 7 tests in `__tests__/views/ChatView.scrollRestore.spec.ts`.
   - Wires the composable + a per-task storage key
     (`chat-scroll-<task_id>`, same identity as session_id per
     migration 052).
   - The initial-load branch in `loadChatHistory` calls
     `chatScrollRestore.restore()` AFTER the messages render +
     one rAF tick. If non-null and not "near bottom", calls
     `virtualScrollerRef.value.scrollToPosition(saved, 'auto')`
     INSTEAD of `scrollToBottom(true, 'initial-load')`.
   - Added `isInitialLoad` guard to the messages-length watcher
     so its auto-stick doesn't yank the user back to the bottom
     immediately after a restore.
   - **Bug found + fixed during integration**: the
     `VirtualScrollerExposed` interface in ChatView.vue
     incorrectly typed `containerRef` as `{ value: HTMLElement }`
     (a ref), but `defineExpose` auto-unwraps refs at runtime, so
     `virtualScrollerRef.value.containerRef` IS the HTMLElement
     directly. The existing 12 call sites used
     `.containerRef.value` (double-unwrapped → undefined) and
     silently relied on fallbacks (e.g. `target` from the scroll
     event). Fixed all 12 call sites AND updated the interface
     to match runtime. This is a pre-existing latent bug surfaced
     by my new tests requiring the ref chain to actually work.

**Out of scope** (deferred): cross-tab sync, server-side
persistence, restore by message id, BFCache navigation, localStorage
TTL cleanup. Listed in the plan's "Out of scope" section.

**Plan.** `docs/superpowers/plans/2026-08-06-chat-scroll-position-persistence.md`
(3 chunks, 27 new tests, frontend-only — no Zig, no backend, no
migration).

**Branch.** `worktree/chat-scroll-position-persistence` (squash-merged as PR #153 → commit `3dfc31fa`).

### 2026-07-25: Design element drag-and-drop wire repaired

**Symptom (pre-fix).** Click on a design element → violet outline + 8
resize handles appear (selection works). Click-and-drag → element does NOT
move.

**Root cause.** `AppLayout.handleDesignUpdateElement`
(`src/apps/desktop/src/components/AppLayout.vue:1129`) was a TODO no-op
(`void elementId; void patch`). DesignElement's pointermove emitted
`update` patches, DesignView re-emitted them upward as `updateElement`,
but the parent silently discarded them.

**Fix.**

- Added `activeDesignPageId` + `setActiveDesignPage` to workspaces store
  (Task 1.1).
- DesignView mirrors its local `activePageId` to the store on mount +
  tab switch (Task 1.2).
- Extracted design handlers into `useDesignHandlers` composable for
  testability (Task 1.3).
- Replaced the no-op with a real handler that routes geometry-only
  patches to `PATCH /geometry` and full patches to `PUT /elements/:id`
  (Task 1.3).
- Throttled the drag stream to 50ms with a trailing emit on pointerup
  (Task 1.4).

### 2026-07-25: Design mode multi-select + group drag

Plan: `docs/SPEC.md` §3.8 (Frontend — Design Canvas) — chunk 2 of the
design-element-drag-and-drop feature.

**What landed.**

- Selection is now `Set<string>` instead of `string | null`. Shift+click
  toggles membership; plain click is exclusive.
- Dragging one element in a multi-selection moves the entire selection
  (same dx/dy applied to all).
- Delete/Backspace removes every selected element (one keystroke).
- Escape clears the entire selection.
- PropertiesPanel renders a "N elements selected" banner when multiple
  are selected; the single-element form only shows for exactly one.

### 2026-07-25: Design mode snap-to-edges + alignment guides

Plan: `docs/SPEC.md` §3.8 (Frontend — Design Canvas) — chunk 3 of the
design-element-drag-and-drop feature.

**What landed.**

- Pure-function `computeSnapDelta` snaps within 6 design-px of any other
  element's edge/center.
- Canvas-center + canvas-edge fallback targets (snaps to page center when
  no other element is nearby).
- 1px violet SVG alignment guides render during drag and clear on
  pointerup.
- Group drag applies snap to the selection's union bbox (the whole
  group snaps together).

### 2026-07-25: Design mode keyboard nudge

Plan: `docs/SPEC.md` §3.8 (Frontend — Design Canvas) — chunk 4 of the
design-element-drag-and-drop feature.

**What landed.**

- Arrow keys move the selection by 1 design-px: ←/→ for x, ↑/↓ for y.
- Shift+arrow moves by 10 design-px (Figma's "big step").
- Input-focus guard preserved (PropertiesPanel X/Y inputs still get
  their arrow keys for cursor navigation).
- No-op when nothing is selected (no escape route from the canvas for
  stray arrows).

### 2026-07-25: Design mode element drag-and-drop (Figma-style) — COMPLETE

Plan: `docs/SPEC.md` §3.8 (Frontend — Design Canvas).

**What landed (all 5 chunks).**

- **Drag-to-move works** (was a TODO no-op in
  `AppLayout.handleDesignUpdateElement`).
- **Multi-select** via Shift+click; group drag; multi-delete with one
  Delete key.
- **Snap-to-edges** with 1px violet alignment guides (6px threshold;
  canvas-center fallback).
- **Keyboard nudge** — arrow keys = 1px, Shift+arrow = 10px.
- **Constrain-to-canvas** — drag and nudge that would push an element
  entirely off-canvas clamp at 10px sliver.

**Bug fix at the heart.** `AppLayout.handleDesignUpdateElement` was a
TODO no-op (`void elementId; void patch`). The drag handler in
DesignElement emitted `update` patches on every pointermove, but the
parent silently discarded them. Now the wire is alive: the composable
`useDesignHandlers` routes geometry-only patches to `PATCH /geometry`
(60+/sec safe) and full patches to `PUT /elements/:id`.

**What was deferred (out of scope for this plan).**

- Marquee drag-select (draw a rectangle to select everything inside).
  Lower priority — Shift+click is enough for the common 1-5-element case.
- Smart-spacing/distribute-horizontal/vertical (would need a server
  endpoint for batch geometry updates).
- Snap-to-grid (Figma toggle; can be added once snap-to-edges is
  comfortable).
- Drag-from-layers-panel to canvas (next plan if requested).
- Lock/hide (needs schema migration).
- Group containers — dragging elements INTO a frame (out of scope;
  `frame`/`group` element types exist but UI doesn't support drag-into
  yet).

### 2026-07-26: design chat 💬 button — canonical-name lookup orphaned prior chats

**Symptom (pre-fix).** User with existing chat history on a design
item (e.g. task `ai-chat-view-design` with 17 messages) clicked the
top-right 💬 button in DesignView. Expected to see their existing
chat. Instead saw "How can I help you?" — empty.

**Root cause.** `AppLayout.handleDesignOpenChat` (the design chat
toggle handler) looked up the chat by **exact name match** against
`'Design Chat'`. When no canonical task existed, the first click
**created** an empty `"Design Chat"` task alongside the user's
existing chat. Subsequent clicks found the empty canonical and
"reused" it (forever empty), orphaning the user's 17 messages.

**Fix.** Added a `taskHasMessages(taskId)` helper that probes
`api.getChatHistory(taskId, 1)` (limit=1, fast SQL). The handler now:

1. Prefer canonical `"Design Chat"` IF it has messages.
2. Otherwise iterate non-canonical tasks and pick the first with
   messages (N+1 API calls; typical designs have 1-5 tasks; only on
   user click).
3. Otherwise keep the empty canonical (don't keep auto-creating) or
   create a fresh `"Design Chat"` for new design items.

**Verified end-to-end.**

- `api.getChatHistory(task_1785079182914, 1)` → 0 messages (skip)
- `api.getChatHistory(task_1785078944040, 1)` → 1 message, total 17
  (use this one)

Regression tests added in `DesignChatToggle.spec.ts`. 15/15 pass.
vue-tsc clean.

**Pitfalls.** Don't trust `item.tasks[0]` (most-recently-created due
to `addTask`'s unshift — that's often the empty canonical itself);
iterate ALL non-canonical tasks. Don't pick "oldest task" as a
heuristic — it works for the user's current state but breaks if the
user manually creates an empty task before the canonical.

### 2026-07-30: Kanban task search (server-side q param)

**What landed.** Server-side `?q=` filter on `GET /api/workspaces/:ws/items/:item/tasks` + compact `<KanbanSearchInput>` in the kanban header (left of ⚙️ Settings). 8 files (2 NEW + 6 EDIT) + 2 plan/spec docs. ~33 new behavioural tests (11 backend + 22 frontend).

**Architecture.** `listWorkspaceItemTasksWithCursor` accepts `q: ?[]const u8`. When non-empty, appends `WHERE LOWER(t.name) LIKE ? ESCAPE '\\' OR LOWER(t.description) LIKE ? ESCAPE '\\' OR LOWER(t.tags) LIKE ? ESCAPE '\\'` with user input `%`/`_`/`\` escaped to literal semantics. Cursor advances through the **filtered** set. Empty/missing `q` → no filter.

**Frontend wiring.** `<KanbanSearchInput>` is a stateless v-model'd input + ✕ clear button + Esc-to-clear. `KanbanView.vue` owns a 300ms hand-rolled debounce (`@vueuse/core` not installed) that refetches via `workspacesStore.fetchKanbanTasks(ws, item, 100, undefined, q)`. `activeSearchQueries: Map<itemId, string>` lets the SSE handler + `loadMoreTasks` forward the active q on refetch.

**Pitfalls.** (1) Always escape user input `%`/`_`/`\` before LIKE binding (otherwise `%` matches everything). (2) Reset cursor to `undefined` on every query change — mixing page-1-old-query with page-2-new-query gives inconsistent results. (3) SSE handlers MUST forward the active q via `activeSearchQueries` — otherwise a remote task move during a search silently resets the user's narrowed view. (4) The "tags" substring match on JSON text means `bug` matches `["debug"]` and `["bugfix"]` — accepted as the typical kanban-search UX.

### 2026-07-31: Design layer drag-to-join-or-leave-group (Figma-style) — [#151 squash-merge](https://github.com/ginwa123/ginwaaitoolbox/pull/151)

End-to-end Figma-style drag-and-drop affordance in the design
LayersPanel: drag a row onto another `group`/`frame` row to join
it; drag any row onto a top-level drop zone to leave its current
group. Multi-select drag drops the whole selection into the same
target.

**Wire.** Backend `reparentElements` (atomic N-element reparent with
cycle preflight) → `POST .../elements/reparent-batch` →
`api.reparentDesignElementsBatch` → `useDesignHandlers.reparentLayers`
→ `useLayerDragDrop.onDrop` (cycle check + multi-drag expansion)
→ `LayersPanel` → `DesignView.handleLayerReparent`. Cycle preflight
walks `parent_id` chain via recursive CTE to reject any reparent
that would close a cycle.

**Implementation note — one-file-per-impl convention.** All Zig
tests live at the bottom of their impl files (`design_model.zig`,
`http_handlers/design_elements_update.zig`,
`http_handlers/design_elements_reparent.zig`). Each test suite
aliases `std.testing` to a namespaced name (`testing_reparent`,
`testing_update_reparent`, etc.) to avoid colliding with the
pre-existing `testing_geometry` alias in `design_model.zig`.
Test helper functions are namespaced per suite
(`setupReparentDbAndItem`, `setupReparentBatchDbAndItem`,
`setupUpdateReparentDbAndItem`, `setupReparentHandlerDbAndItem`)
so multiple suites can coexist in the same file without shadowing.

**Live smoke (port 8080):** reparent child1+child2 into group g1
→ `parent_id` updated; reparent back to top-level → `parent_id=''`;
cycle preflight → 400; bad parent type → 400; empty batch → 400.

**Verification (squash commit `c23d6a5c`):** vue-tsc clean; bun
run build clean (1.75s); vitest 1800/1801 (1 pre-existing nudge
clamp failure on main, unrelated); zig build test 2101/2107 (1
pre-existing `design_model_set_element_parent_test` leak,
unrelated); zig build install:linux:system builds 102 MB nalar
binary + 35 MB nalar-desktop.

**Plan:** `docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md`

### 2026-08-06: Design pages list — moved into the workspace sidebar tree (#168, supersedes #167)

**Symptom (pre-fix).** User reported (after PR #167 landed, which put
the pages in a left sidebar INSIDE the design canvas): *"i mean pages
move inside workpace item, 'design' like config agentic ai"*. They
wanted the design-mode page list to live **in the workspace sidebar
tree**, under the design workspace item — the same way `llls` shows
up indented under `config agentic ai`. NOT in a separate left
sidebar inside the design canvas.

**What landed.** Frontend-only — no backend, DB, or migration
changes. This PR REVERTS PR #167 entirely (commit `63c287f8`) and
implements the correct UX:

- **`DesignPageTabs.vue` + spec DELETED** — no longer used.
- **NEW** `DesignPageRow.vue` (`workspace/`): single page row with
  click → select, hover → × delete. Reuses the visual rhythm of
  `WorkspaceItemTaskRow` for consistency.
- **`WorkspaceItem.vue`**: when `item_type === 'design'` AND
  `isExpanded`, render `<DesignPageRow>` per page + `+ Add Page`
  button. The chevron click toggles expand **without** activating
  the item (row body click still activates — preserves the
  established "click design → enter design view" UX).
- **Workspaces store**: new `designPagesByItemId` cache +
  `fetchDesignPages` / `addDesignPage` actions. Single source of
  truth shared between the sidebar tree and `DesignView`. The
  cache is reset on `init()` so re-inits don't show stale pages
  from the previous session. Concurrent fetches for the same item
  share a single in-flight promise (no double-fetch race on
  sidebar-expand + canvas-mount).
- **`deleteDesignPage`** picks a sensible next-active page (same
  index as the deleted one; previous if last; empty if none).
- **`Sidebar.vue`**: handlers for `selectDesignPage` /
  `deleteDesignPage` / `addDesignPage` wired through the store.
  `computeNextUntitledName` copy for the `Untitled N`
  auto-increment pattern.

**Tests.** +11 net new behavioural tests:

- 6 in new `DesignPageRow.spec.ts`
- 5 in new `workspacesStoreDesignPages.spec.ts` (migrated from
  `DesignView.spec.ts` — the page-CRUD UI tests triggered
  `design-add-page` / `design-delete-page-*` testids that no
  longer exist in `DesignView`).
- `DesignView.spec.ts`: removed 5 page-CRUD tests + 2 static-
  contract tests that asserted `<DesignPageTabs` was in the
  source.

**Verification.** `bun run build` clean; `bunx vitest run` 1946/1954
pass. The 8 failures are PRE-EXISTING on `main` (verified against
`b7993b52`): 5 undoHidden + 1 DesignElement static + 1 nudge clamp +
1 AppLayout translateResize.

**Branch.** `worktree/design-pages-in-tree` (commit `219b1832` +
revert `63c287f8`)
**Plan.** `docs/superpowers/plans/2026-08-06-design-pages-in-workspace-tree.md`

### 2026-08-06: Design pages list — moved from top tabs to left sidebar (#167) — SUPERSEDED

**Symptom (pre-fix).** User reported: *"change pages position, design
mode. currently the list pages, is on the top, i want you to move that
to the left"*. The page tab strip (AI Chat View, Kanban Mode, Chat
View In Progress, Workspaces Sidebar, Task Dialog, Task Dialog with
Attachments, + Page) was rendered as a horizontal tab strip across the
TOP of DesignView — visible in every screenshot above the chat

**Symptom (pre-fix).** User reported: *"change pages position, design
mode. currently the list pages, is on the top, i want you to move that
to the left"*. The page tab strip (AI Chat View, Kanban Mode, Chat
View In Progress, Workspaces Sidebar, Task Dialog, Task Dialog with
Attachments, + Page) was rendered as a horizontal tab strip across the
TOP of DesignView — visible in every screenshot above the chat
toolbar. Figma/Sketch convention is a vertical list on the LEFT, so
the canvas can use the full viewport width and the page list has more
room to grow past ~7 tabs without horizontal scrolling.

**What landed.** Frontend-only — no backend, DB, or migration changes.

- **`DesignPageTabs.vue`**: CSS flip from horizontal (`flex
  items-center overflow-x-auto`, 2px `border-bottom` on active tab)
  to vertical (`flex flex-col overflow-y-auto`, 3px `border-left` on
  active tab). Long names get `text-overflow: ellipsis`. Props,
  emits, and data-testids preserved (back-compat).
- **`DesignView.vue`**: removed the top `<DesignPageTabs>` block;
  mounted it as a new LEFT column inside the main split. Main split
  is now `[LEFT pages sidebar] | [resize handle] | [canvas] |
  [resize handle] | [right sidebar]`. New drag-vertical resize
  handle between pages sidebar and canvas; width persists to
  `localStorage` under the new key `design-view-pages-sidebar-width`
  (separate from the right sidebar's key, separate min/max: 180–400
  px vs the right sidebar's 220–600 px).
- The empty-state `+ Add the first page` button picked up
  `data-testid="design-add-page"` so existing tests that target
  the + Page affordance still find it when `pages.length === 0` —
  the tabs strip now only renders when pages exist.

**Tests.** +11 net new behavioural tests:
- 8 in new `DesignView.pagesSidebar.spec.ts` (left-of-canvas
  invariant, NOT inside top toolbar regression test, resize handle
  presence, + Page still wires to POST /pages, etc.)
- 5 source-grep tests in `DesignPageTabs.spec.ts` converted to 8
  behavioural tests per the project-wide no-static-contract rule
  (2026-07-29). Net +3 there.

**Verification.** `bun run build` clean; `bunx vitest run` 1914/1922
pass. The 8 failures are PRE-EXISTING on `main` (5 undoHidden + 1
DesignElement static contract + 1 nudge clamp + 1 AppLayout
translateResize) — verified by running the same suite against
`b7993b52` (main HEAD before this PR).

**Branch.** `worktree/design-pages-left` (commit `c1bf5e89`)
**Plan.** `docs/superpowers/plans/2026-08-06-design-pages-left-sidebar.md`

### 2026-08-06: Compaction prompt — extract `buildCompactMessagePrompt` for unit testing (#165)

**Symptom (pre-fix).** `callCompactAgent` in
`src/ai_workflow/tui/agentic_loop/compaction.zig` was a 195-line function
that bundled 4 unrelated concerns: extract `original_system_prompt`,
label+join the conversation history, build the handoff-prompt template,
and finally invoke the LLM with `callStreaming`. Steps 1-3 were
pure data transformation; step 4 was the only thing requiring a real
LLM. The whole function was untestable in isolation because
`callStreaming` needs `std.Io.Threaded`, an `Agent`, and an LLM
endpoint — a unit test would have spun up the entire stack just to
verify "label a row as `[user]: hi`".

**What landed.** Extract steps 1-3 into a new pub fn
`buildCompactMessagePrompt(allocator, logger, messages, original_system_prompt) ?[]const u8`
(same file, lines 105-245). `callCompactAgent` drops from 195 → 101
lines and now calls the helper:

```zig
const compact_message = buildCompactMessagePrompt(
    allocator, logger, messages, original_system_prompt,
) orelse return null;
defer allocator.free(compact_message);
```

**Caller owns the returned string.** Must free with `allocator.free`.
Returns `null` on alloc failure (after logging via `logger`).

**3 pre-existing leaks fixed (surfaced by the new tests).** Writing
the unit tests caught `testing.allocator.detectLeaks()` failures:

1. `parts.append` failure after successful `allocPrint` of `labeled`
   content → free `labeled` before `return null`.
2. `parts.append` failure after successful `allocPrint` of `tc_str`
   → free `tc_str` before `continue`.
3. `history_str` allocated via `std.mem.join`, which **copies** the
   segments into a fresh buffer — the `parts.items` originals are now
   orphans → `defer for (parts.items) |part| allocator.free(part)`.

The original code dropped `parts` without freeing the originals — a
per-compaction leak invisible in production (arena reaps everything)
but caught once we wrote a test under `testing.allocator`.

**8 inline tests added** at the bottom of `compaction.zig`:
1. happy path embeds system prompt and labeled history
2. first AND last messages are excluded from history (slice semantics)
3. tool_calls formatted as `[tool_call]: name(args)`
4. message with content=null and no tool_calls is skipped silently
5. empty middle history (only system + last) returns valid prompt
6. history rows joined with `\n`, order preserved
7. returns a heap-allocated, caller-owned string (ownership contract)
8. empty-messages list (only system + 1 user) — 2-message edge case

Registered `compaction.zig` in `test_runner.zig` (the silent no-run
hazard the `agentic_loop/README.md` warns about — the file was
previously NOT imported by the runner; tests would have compiled but
never executed).

Re-exported `buildCompactMessagePrompt` from `agentic_loop/mod.zig`.

**Verified.**
- `zig build test --summary all` → 2168/2174 pass, **+8 from this PR**, 0 failed
- `zig build install:linux:system` → compile succeeds
- `rm -rf zig-out/bin && zig build` → both `nalarcore-linux-x86_64` + `nalar-desktop` produced
- Cross-compile `zig build-obj -target x86_64-windows-gnu` and `-target aarch64-macos` → pre-existing harness limitation (recursive `nalarcore` import, affects `callCompactAgent` identically — NOT a regression)
- 2 leaks reported, both pre-existing in `design_model_set_element_parent_test` (unrelated)

**Plan:** `docs/superpowers/plans/2026-08-06-encapsulate-compaction-prompt.md`
**TDD trace.** RED (8 tests, undeclared identifier) → GREEN
(implementation extracted) → RED (leak detector) → GREEN (3 frees).
**Commit:** `2fcfbd40` (squashed via PR #165).

---

## 📖 Related documentation

- `README.md` — building from source on Linux + Windows/macOS
- `docs/ci.md` — CI pipeline layout, troubleshooting
- `tests/functional/README.md` — functional test harness + safety invariants
- `.nalar/memories/zig-cross-platform.md` — full reference for Zig 0.16 cross-platform
- `.nalar/memories/nalar-backend-architecture.md` — backend HTTP patterns
- `.nalar/memories/nalar-frontend-patterns.md` — frontend (Vue 3) patterns
- `.nalar/memories/nalar-infra-and-build.md` — CI, build vendor lib patterns
- `.nalar/memories/nalar-data-and-routines.md` — schema/migration/routine patterns

### 2026-08-06: `show_preview` user-controlled sidebar/inline display-mode toggle

**Symptom (user report).** The `show_preview` agent tool renders
its content only in the right-side `PreviewSidePanel` (480px). For
short, conversational content (a tiny table, a code snippet, a
quick diagram), it's disruptive to have to look across the chat
column — users want the option to render some previews inline
with the chat flow.

**The mental model.** A user-clickable toggle (in the side panel
header + a restore button in ChatView) that flips the rendering
mode between two values:

| Mode | Where | Restore affordance |
|---|---|---|
| `side` (default) | `<PreviewSidePanel>` (existing) | Side panel visible |
| `inline` | `<ShowPreview>` card expands to render content inline | Floating "📋 Open preview panel" button (top-right of chat area) |

Mirrors the existing `<DiffView>` split/unified toggle — UX-driven,
NOT LLM-driven. Default is `side` for back-compat.

**What landed.** Surgical frontend-only changes — no Zig, no DB, no
backend wire.

- New composable `usePreviewDisplayMode()` in
  `src/composables/usePreviewDisplayMode.ts` — module-level
  singleton ref + `setMode(...)`, persists under localStorage
  key `nalar-preview-display-mode`, SSR-safe (no throw when
  localStorage is undefined). Re-syncs from localStorage on
  every call (testability + idempotent in production).
- New component `<PreviewContentRenderer>` extracted from
  `PreviewSidePanel.vue` — handles all 5 content types
  (markdown / text / code / image / html) using the same logic
  that was inline in PreviewSidePanel. Both `PreviewSidePanel`
  (active tab) and `ShowPreview` (inline mode) mount it.
- `PreviewSidePanel.vue`: 5-branch inline template replaced
  with `<PreviewContentRenderer>`. New 2-button segmented
  control in the header (`Side` / `Inline`, testid
  `preview-display-mode-toggle`). Active button has violet tint.
- `ShowPreview.vue`: when `isInline` is true, mounts
  `<PreviewContentRenderer>` directly below the header. Card
  drops `role=button` / `tabindex` and stops emitting `open`
  on click (nothing to navigate to).
- `ChatView.vue`: watches `isInline`. Switching TO inline
  auto-dismisses the side panel; switching back restores the
  user's previous dismiss preference. Floating "Open preview
  panel" button (`data-testid="restore-preview-panel-button"`)
  appears at top-right when `isInline AND showPreviewMessages.length > 0`.

**Tests.** 38 new behavioural tests across 5 files:

| File | New | Pre-existing | Status |
|---|---|---|---|
| `composables/__tests__/usePreviewDisplayMode.spec.ts` (new) | 9 | 0 | All pass |
| `__tests__/PreviewContentRenderer.spec.ts` (new) | 10 | 0 | All pass |
| `__tests__/previewSidePanel.spec.ts` | 6 | 23 | All pass |
| `__tests__/ShowPreview.spec.ts` (new) | 12 | 0 | All pass |
| `__tests__/chatViewShowPreviewBubble.spec.ts` | 6 | 5 | All pass |

**Verification (worktree `worktree/show-preview-display-mode`).**

- `bun run build` clean (vue-tsc --build, 1.82s)
- `bunx vitest run`: 1946 pass / 8 fail
- 8 failures are PRE-EXISTING on `main` (verified via `git stash`
  + re-run): `DesignView.undoHidden ×5`, `DesignElement static
  contract ×1`, `DesignView.nudge clamp ×1`, `AppLayout
  translateResize ×1`. Unrelated to this change.
- `zig build test --summary all`: 2168/2174 pass (2 pre-existing
  leaks in `design_model_set_element_parent_test`, unrelated —
  documented in project memory).

**Out of scope.**

- LLM-controlled `display_mode` param — explicitly rejected (UX
  model, not LLM-driven).
- Per-call mixing (some previews in side, some inline) — single
  global toggle.
- Animation when switching modes — abrupt flip is fine for v1.
- Keyboard shortcut for the toggle — could add `Cmd/Ctrl+Shift+P`.
- Refactor: extract `<SandboxedIframe>` shared component —
  separate refactor (now 2 consumers would share it).

**Plan + spec.** `docs/superpowers/specs/2026-08-06-show-preview-display-mode-design.md`.
Commits: `a4c0749f` (composable + renderer), `f33fdf0a`
(PreviewSidePanel toggle UI), `8342f68d` (ShowPreview inline +
ChatView wiring).

### 2026-08-06: `show_preview` inline mode was broken in production (fixed) + default flipped to `inline`

**Symptom (user report, with screenshots).** *"only side preview work but i want show in history chat session, like other tool output"*. After clicking the new Side / Inline toggle to switch to inline mode, the chat bubble still showed only the header (no rich content body). The side panel had correctly hidden, but the preview content was nowhere to be seen.

**Root cause.** `ShowPreview.vue::previewArgs` tried to unwrap `props.content` looking for a `<tool>...</tool>` wrapper, then extracted the `<parameters>` tag. But ChatView.vue:1069-1080 already does the unwrap and passes:

- `props.content` = `innerToolData(msg)` = `unwrapped.data` (inner data envelope, e.g. `<show_preview><status>...</status></show_preview>`)
- `props.parameters` = `getParametersForMessage(msg)` = `unwrapped.parameters` (JSON-string of the tool-call args)

So `tryUnwrapToolOutput(props.content)` always returned `null`, `previewArgs` ended up as `{}`, and the inline content body was never mounted.

The test suite didn't catch this because the test fixture (in `src/__tests__/ShowPreview.spec.ts`) passed a `<tool>`-wrapped envelope in `content` — which unwrapped correctly — masking the production bug. The fixture didn't match production data shape.

**Fix.**

1. `ShowPreview.vue`: drop the `tryUnwrapToolOutput` path on `props.content`. JSON.parse `props.parameters` directly (it's already the JSON string). Fall back to `{}` on invalid JSON (legacy / malformed envelopes).
2. Updated the `makeShowPreviewMessage` fixture in `src/__tests__/ShowPreview.spec.ts` to match production shape: inner envelope in `content`, JSON string in `parameters`. This makes the test reliably reproduce the production bug if it regresses.
3. Flipped `DEFAULT_MODE` in `usePreviewDisplayMode.ts` from `'side'` to `'inline'`. The preview now renders inline in the chat history by default — matching the user's mental model and the behaviour of every other tool output (`read_file`, `bash`, etc.). The side panel is now opt-in via the toggle in the panel header.
4. Updated 5 test files to set `localStorage` to `'side'` in `beforeEach` where needed (preserving the existing side-mode assertions in the OLD `src/components/tool_outputs/__tests__/ShowPreview.spec.ts` file and `chatViewShowPreviewBubble.spec.ts`). Also flipped default assertions in `usePreviewDisplayMode.spec.ts` and `previewSidePanel.spec.ts`.

**Lesson.** Test fixtures MUST match production data shape, or the test only validates the test's invented shape. The `<tool>`-wrapped envelope in the original fixture was a convenient fiction — production never sends that. Future contributors: if a prop is named "the inner envelope", don't try to unwrap it as "the outer envelope".

**Verification.**

- `bun run build`: clean (vue-tsc + vite, 2.31s)
- `bunx vitest run`: 1956 pass / 12 fail — all 12 are PRE-EXISTING on main (verified by `git stash` + re-run), unrelated to this fix: 5 `DesignView.undoHidden`, 1 `DesignElement` static contract, 1 `DesignView.nudge` clamp, 1 `AppLayout.translateResize`, 4 `AppLayout.memoriesGate`.
- Related test files (composable + renderer + toggle + ShowPreview + ChatView): 80/80 pass.

**Commits** (`worktree/show-preview-render-inline`):
- `d5cd8317` — fix(preview): render ShowPreview inline content in production
- `1e850a8c` — test(preview): update test suite for default=inline + production-shape fixture

### 2026-08-06: filteringTools — filter LLM tool list by parent item_type + 11 unit tests

**Symptom (background).** Every session received the SAME 56-tool
tool listing, regardless of whether the agent's parent item was a
kanban, a design canvas, or a folder. That meant a design-session
agent saw `kanban_list` + `kanban_move_task` (and would routinely call
them by mistake), a folder-session agent saw `set_design_page` +
`add_element` + etc. (would try to render designs inside a folder),
and a kanban-session agent saw every design tool it could never
use. The agent's mental model was cluttered with inapplicable affordances.

**The mental model.** Strip the tool listing per session based on the
parent item's `item_type`:

| Parent `item_type` | Removed tools |
|---|---|
| `design` | `kanban_list`, `kanban_move_task` |
| `folder` | `kanban_list`, `kanban_move_task`, `set_design_page`, `add_element`, `update_element`, `group_elements`, `set_element_parent`, `move_design_element` (8 tools) |
| `kanban` | `set_design_page`, `add_element`, `update_element`, `group_elements`, `set_element_parent`, `move_design_element` (6 tools) |
| anything else (`chat`, etc.) | (no-op — tools pass through unchanged) |
| empty / unbound `session_id` | (no-op — `getWorkspaceContext` returns null) |

The three branches are **mutually exclusive** — only ONE can match per
call. The session-id short-circuit at the top of `filteringTools`
makes the no-op case also explicit.

**What landed.**

- `src/ai_workflow/tui/build_messages_for_agent_prompt.zig`:
  - Promote `tree1_mod` → `nalarcore` (housekeeping, was inconsistent
    with the rest of the file).
  - Add module imports for the 8 kanban / design tool modules whose
    `*_tool` constants drive the filter (`kanban_list`,
    `kanban_move_task`, `set_design_page`, `add_design_element`,
    `update_design_element`, `group_design_elements`,
    `set_element_parent`, `move_design_element`).
  - Add `pub fn filteringTools(...)` — the per-item-type filter
    helper (originally `fn`, made `pub` so unit tests can call it
    directly without going through `buildMessages`).
  - Wire `filteringTools` into `buildMessages` between the `tools`
    argument and the `makeKanbanContext` / `build_agent_prompt`
    consumers.
- `src/ai_workflow/tui/agentic_loop/workflow.zig`:
  - Move `filterAndMergeTools(...)` from being hoisted BEFORE the
    agentic loop to inside the loop body. The previous hoist meant
    the merge only ran once; if the equipped-tools list changed
    mid-run (allowed_tools toggle, MCP fetch), the change was
    ignored until the next session.
- `src/ai_workflow/tui/agentic_loop/tools_equipped.zig`:
  - Regroup the augmented tool list so the `// kanban only` /
    `// design only` comment markers sit ABOVE each group instead of
    inline (cosmetic, but makes the partitioning obvious to future
    readers).

**Tests (11 cases, behavioural).** New file
`src/ai_workflow/tui/build_messages_for_agent_prompt_filtering_tools_test.zig`,
registered in `src/ai_workflow/tui/test_runner.zig`:

1. Design parent drops kanban tools; keeps design + mock tools.
2. Folder parent drops all 8 kanban+design tools; keeps only the 2 mocks.
3. Kanban parent drops the 6 design tools; keeps kanban + mocks.
4. Chat parent — no branch matches → no filter applied (length 10).
5. Empty `session_id` → returns tools unchanged (`getWorkspaceContext` short-circuits to null).
6. Unbound `session_id` (no matching task) → returns tools unchanged (null anchor row).
7. Empty tools list → returns empty slice regardless of parent type.
8. Kanban-only tools + design parent → empty (all dropped).
9. Design-only tools + kanban parent → empty (all dropped).
10. Filter outcome is independent of input order — same 10 tools in
    reversed order produce the same sorted multiset of remaining names.
11. Folder branch and the design-only branches never both fire (mutex
    regression guard).

The fixture uses the **actual `*_tool` constants** from each module
(not hard-coded name strings) so a future rename of `kanban_list_tool`
to `list_kanban` (etc.) would surface here as a real test failure,
not a silent string drift.

**Verification (worktree `worktree/unit-test-filtering-tools`).**

- `zig build test --summary all`: **2179 pass, 6 skip, 0 fail** (was
  2168/2174 before, +11 new tests).
- 2 leaks reported — **PRE-EXISTING** in
  `design_model_set_element_parent_test.zig` cycle-rejection test;
  verified by `git stash` + run, leaks count unchanged on
  `b065d3ef`'s parent commit.
- `zig build install:linux:system` + `rm -rf zig-out/bin && zig build`
  both succeed — produces both `nalarcore-linux-x86_64` and
  `nalar-desktop` binaries.
- Cross-compile smoke: `zig build-obj -fno-emit-bin -target
  x86_64-windows-gnu` and `-target aarch64-macos` both PASS (no
  errors), so the new code compiles for Windows + macOS too.

**Out of scope (deferred).**

- LLM-side filtering (LLM is never asked to filter tools itself) —
  this is purely a server-side trim of the request payload.
- Per-call mixing (e.g. "this tool only in this prompt, not that
  one") — single global per-item-type filter for v1.
- Storing the active item_type in session metadata (currently derived
  on every call via `getWorkspaceContext`).

**Commit.** `b065d3ef` (squash on `worktree/unit-test-filtering-tools`).

### 2026-08-06: SSE disconnect diagnosis — classify every disconnect as backend/network/browser/user-code

**Symptom (user report, task_1785608409075).** *"make the error better !!!, because i dont know why the sse reconnecint, it is from backend or frontend that disconnection connection ??"*. After a 19-second silence the browser fired an `EventSource` error event and the SseClient transitioned to `reconnecting`. The operator had to cross-reference two log lines (`STALL DETECTED` + `EventSource raw error`) and guess whether the disconnect was server-side, network-side, or browser-side.

**What landed.** One new log line + three enriched existing logs:

1. **`DISCONNECT DIAGNOSIS`** (new) — fires once per error event, after `EventSource raw error` and before `scheduleRetry set`. Aggregates every diagnostic signal into one log entry:
   - `suspect`: `'backend' | 'network' | 'browser' | 'user-code' | 'unknown'` (the operator's one-glance answer)
   - `conclusion`: human-readable sentence with the suspect label inline (greppable)
   - `readiness`, `navigatorOnline`, `effectiveType`, `tabHiddenAtMs`, `sinceLastEventMs`
   - `wasStalledBefore`, `stallToErrorMs` (how many seconds the stall detector saw it before the browser did)
   - `sinceLastCloseMs`, `sinceLastReconnectMs`, `lastCloseReason`, `lastReconnectReason`, `constructedBy`

2. **`STALL DETECTED`** enriched with `suspect`, `conclusion`, `navigatorOnline`, `tabHiddenAtMs`, `sinceLastCloseMs`, `sinceLastReconnectMs`, `lastCloseReason`, `lastReconnectReason`, `constructedBy`. The operator now sees the classification at the moment of stall detection (not 12s later when the browser finally fires onerror).

3. **`EventSource raw error`** enriched with `navigatorOnline`, `wasStalledBefore`, `stallToErrorMs`, `tabHiddenAtMs`. Critical for the user's reported symptom: shows "stall detector saw it 12s before the browser did".

4. **`close(reason?)` and `reconnect(reason?)`** signatures widened with an optional reason + caller-stack capture. The sseBus calls these with `('bus-torn-down')`, `('user-clicked-retry-or-bus-reconnect')`, and `('page-unload')` so the next diagnostic log attributes the disconnect to a specific call site.

5. **Offline listener** added — the existing code only listened for `online`. The new `offline` listener means the operator can see "network dropped X seconds before the SSE error".

**Suspect classification rules.** `classifyDisconnectSuspect(snapshot)` returns one of five buckets based on a priority chain:

- `user-code`: close()/reconnect() called within last 5s (highest priority — disconnect is intentional)
- `network`: `navigator.onLine === false` (TCP socket is almost certainly dead)
- `browser`: tab became hidden during the silence window (browser throttled — not a real disconnect)
- `backend`: TCP was OPEN during sustained silence (the smoking gun — server stopped sending while socket was alive)
- `unknown`: signals conflict — investigate deeper

The `stallFiredAtReadiness` snapshot is captured at stall time and replayed at diagnosis time so the classifier doesn't lose the smoking gun when the browser transitions readyState to CONNECTING before firing onerror.

**Tests.** 13 tests in `sseClient.deeplog.spec.ts` (was 7, +6 new):
- `suspect=backend` when TCP was OPEN during silence
- `suspect=network` when `navigator.onLine === false`
- `close(reason)` and `reconnect(reason)` capture the reason + caller frame
- `STALL DETECTED` log includes `suspect` + `conclusion`
- `EventSource raw error` log includes stall awareness

3 mock-test fixes:
- `parseLogCalls` regex widened to capture `()` in `close() called`
- Mock EventSource now fires both `addEventListener('error', ...)` AND `onerror` handlers (real browser dual-fire)
- `simulateOpen()` sets `readyState=1` (matches real browser)

**Verification.** 1963 pass, 12 fail (the 12 are pre-existing on main: `DesignView.undoHidden ×5`, `DesignElement static ×1`, `nudge clamp ×1`, `AppLayout.translateResize ×1`, `AppLayout.memoriesGate ×4`). `vue-tsc --build` clean. `bunx vitest run` full suite passes. **All 6 new diagnostic tests pass.** No regressions.

**Out of scope (explicitly NOT changed).**
- Backoff schedule / `maxDelayMs` — the 21s retry delay is still 21s. Not the user's question.
- Auto-reconnect on STALL DETECTED — the stall detector only logs; the disconnect is still diagnosed via the eventual `error` event.
- Adding a UI surface for the suspect — the user wants log-line diagnostics, not a badge.

**Branch / commit.** `worktree/sse-disconnect-diagnosis` @ `5fa8dc05`. PR-ready. Plan doc: `docs/superpowers/plans/2026-08-06-sse-disconnect-diagnosis.md` (next step).

### 2026-08-06: Kanban per-column pagination (Option A)

**Symptom (user report).** "it should per column pagination kanban" — the user wanted each kanban column to paginate independently rather than sharing one board-wide cursor. The old `hasMoreTasks` / `tasksNextCursor` / `isLoadingMoreTasks` triple on `WorkspaceItem` was per-BOARD, so the "Load more" button in any column fetched the next 10 tasks across ALL columns mixed together.

**What landed (per-column pagination plan, 2026-08-06-kanban-per-column-pagination.md).**

- **Backend** (`tasks_list.zig` + `llm_history.zig`): new `?column_id=<col>` query param + matching DB fn param. SQL adds `AND (t.kanban_column_id = ? OR t.kanban_column_id IS NULL)` when non-null (the OR-NULL clause is defensive — preserves legacy rows without a column). Cursor stays `<sort_value>|<id>` (the `column_id` query param provides the column context). 7 new inline tests in `llm_history.zig` lock in the contract.
- **Frontend store** (`workspaces.ts`): replaced `WorkspaceItem.hasMoreTasks` / `tasksNextCursor` / `isLoadingMoreTasks` with `columnPagination: Record<columnId, ColumnPaginationState>` where `ColumnPaginationState = { cursor, hasMore, isLoading }`. New action `loadMoreTasksForColumn(ws, itemId, columnId)` fetches the next page for ONE column only. The old board-wide `loadMoreTasks` was removed from the public API (deleted the test files that used it). The initial fetch (`fetchKanbanTasks` + `init()`) is still board-wide — per-column pagination only kicks in from page 2 onwards.
- **Per-column heuristic**: when the initial board-wide fetch returns `has_more: true`, every column that has ≥1 task in the page gets `hasMore: true`. A sparse column's auto-load will quickly resolve to `hasMore: false` on the next page request.
- **Sidebar's "Load more"**: aggregates `hasMore`/`isLoading` across all columns; clicks pick the first column with `hasMore: true` (cheapest visible next-page).
- **Per-column sort + search**: `loadMoreTasksForColumn` forwards the active `sortBy` + `direction` + `q` (same pattern as the old `loadMoreTasks`).
- **SSE refetch**: `fetchKanbanTasks` replaces `item.columnPagination` with a fresh map — SSE handlers get per-column reset for free.
- **Tests**: deleted `workspacesStoreLoadMoreTasks.spec.ts` + `workspacesStoreKanbanTasks.spec.ts` + `workspaceItemTaskLoadMore.spec.ts`. Added `workspacesStorePerColumnPagination.spec.ts` (11 behavioural tests covering the new state machine).

**Verification.**
- `zig build test`: 2187/2193 pass (2 pre-existing `design_model_set_element_parent_test` leaks, unrelated)
- `zig build-obj x86_64-windows-gnu`: clean
- `zig build-obj aarch64-macos`: clean
- `bun run build`: clean
- `bunx vitest run`: 1997 pass / 12 fail (the 12 are pre-existing on main — `DesignElement` static contract, `DesignView.undoHidden ×5`, `DesignView.nudge clamp`, `AppLayout.translateResize`, `AppLayout.memoriesGate ×4`)
- Live smoke on port 8080: `column_id=col_test` returns `{"tasks":[],"count":0,"has_more":false}` — filter wired end-to-end.

**Out of scope (deferred).**
- Per-column COUNT endpoint (the heuristic handles the "sparse column" case via auto-load resolution)
- URL persistence of cursors (the user didn't ask; cursors are transient)
- Per-column search (search stays board-wide)
- Animation when switching columns
### 2026-08-06: search_history FTS5 query sanitization + Rows.getLastErrorMessage

**Symptom (user report, task_1785658329168).** `search_history` returned
`FTS search failed: QueryFailed` for common plain-text queries containing
FTS5-special characters: `handle_tool.zig`, `AGENTS.md`, `SPEC.md`,
`2026-08-06`, `agentic_loop/handle_tool.zig:18`. The bare `QueryFailed`
enum name gave the user no hint about WHY.

**Two-part fix:**

1. **`SqliteBackend.Rows.getLastErrorMessage()`** — capture
   `sqlite3_errmsg(db)` into `Rows.last_error_msg` before
   `Error.QueryFailed` is returned. Adds `db: ?*c.sqlite3` field to
   `Rows` (needed because the stmt pointer alone can't reach the db
   handle). All `Rows.next()` error paths now populate the message
   automatically.

2. **`llm_history.escapeFtsQuery()`** — strip FTS5 operators (`-`, `+`,
   `*`, `^`, `:`, `(`, `)`, `"`) by replacing with spaces, then wrap
   the entire query in FTS5 phrase syntax (`"..."`). The phrase
   `"handle_tool.zig"` tokenizes the same way as the indexer
   tokenized the original document text, so the phrase match works.

**Files.** 4 modified + 2 new:
- `src/modules/databases/sqlite/Sqlite.zig` (+43/-2)
- `src/ai_workflow/tui/llm_history.zig` (+57/-1)
- `src/modules/databases/test_runner.zig` (+1)
- `src/ai_workflow/tui/test_runner.zig` (+1)
- `src/modules/databases/sqlite/sqlite_test_rows_capture_error.zig` (new, 3 tests)
- `src/ai_workflow/tui/llm_history_search_fts_query_safety_test.zig` (new, 5 tests)

**Tests.** 14 new tests, all green; 2175 pass / 6 skip / 0 fail (only
the 2 pre-existing leaks in `design_model_set_element_parent_test` remain).

**Verification.** `zig build test --summary all` 2175/2181 pass. Cross-
compile `zig build-obj -target x86_64-windows-gnu` and `aarch64-macos`
both pass. `zig build` (fresh rebuild) produces both
`nalarcore-linux-x86_64` and `nalar-desktop`.

**Out of scope.** Plumbing the captured SQL message all the way
through to the formatted user-facing error envelope. The infrastructure
is in place (`Rows.getLastErrorMessage`), but threading it through
`searchMessagesFts` (which iterates Rows internally) requires either a
signature change or a different plumbing mechanism — deferred.

**Branch.** `worktree/tool-error-better-message` (uncommitted).
### 2026-08-06: ChatView Stop button — cancel a running agent

**Symptom (user report, task_1785730430551).** The chatview had no UI
affordance to stop a running agent. The user could only wait for the agent
to finish or restart `nalar`. The "Queue" button that replaces "Send" while
the agent runs queues follow-up messages — it does NOT cancel the running
one.

**The mental model.** Backend cancel was already fully wired end-to-end:
- `POST /api/llm/session/:sid/stop` → `llm_history.cancelSession` → `UPDATE worker SET cancelled=1`
- Workflow loop polls `isWorkerCancelled` at the top of every iteration
  (`workflow.zig:500`) + retry delay (`retry_delay_ms.zig:42`)
- Workflow breaks → `deleteWorker` → SSE `worker deleted` event →
  `App.vue` removes session from `processingState`

Missing: the frontend wrapper, the button, and the test.

**What landed.** Surgical frontend addition:
- `api.stopSession(sessionId)` — POST wrapper. Returns
  `{ success, session_id }`; swallows non-2xx errors with a typed
  response (so callers never need try/catch).
- `FileInput.vue` Stop button — visible only when
  `isLLMProcessing=true`. Red filled-square icon, "Stop" label.
  Emits `stop-session` to ChatView. New `isStopping` prop drives the
  spinner + "Stopping…" label + debounces clicks.
- `ChatView.vue::handleStopSession` — translates the emit into the
  API call. No optimistic local flip of `isLLMProcessing` (would race
  with the SSE event and cause button flicker).
- Two new spec files: `FileInput.stopButton.spec.ts` (8 tests) +
  `ChatView.stopSession.spec.ts` (5 tests) = 13 behavioural tests,
  all green.

**Tests.**
- Button visibility: hidden when `isLLMProcessing=false`, shown when
  true, hidden again when prop flips back.
- Button label: "Stop" by default, "Stopping…" when `isStopping=true`.
- Click semantics: emits `stop-session` exactly once on click, no
  second emit while `isStopping` (debounce mirror).
- Wiring: `api.stopSession` called with the un-prefixed session id
  (no `chat-`); double-click debounce via FileInput's `isStopping`;
  SSE `worker deleted` event hides the button; `api.stopSession`
  rejection caught (no unhandled promise); button stays visible on
  error.

**Verification.**
- `bun run build`: clean (vue-tsc + vite)
- `bunx vitest run`: 2031 pass / 12 fail. Failures are PRE-EXISTING
  on main (`DesignView.undoHidden ×5`, `DesignElement static ×1`,
  `DesignView.nudge clamp ×1`, `AppLayout.translateResize ×1`,
  `AppLayout.memoriesGate ×4`). Zero regressions.
- `zig build test --summary all`: 2184/2190 pass (2 pre-existing
  leaks in `design_model_set_element_parent_test`). No regressions.
- Live smoke: `POST /api/llm/session/<sid>/stop` returns
  `{"success":true,"session_id":"<sid>"}` on both my `localhost:8080`
  and the user's running 8081 instance.

**Out of scope (deferred to follow-ups).**
- Mid-stream cancellation in `Agent.zig::callStreaming` (currently
  cancel only fires at iteration boundaries; `error.Cancelled` is
  declared but never returned from the chunk loop).
- Keyboard shortcut (`Esc` / `Cmd+.`).
- Confirmation modal.
- Cancelling queued messages.

**Pitfall.** `processingState` MUST be a Vue `ref()`, not a plain
`{ value: ... }` object — Vue's reactivity tracks reassignments via
the proxy, plain objects are invisible. First test C draft used a
plain object and the computed `isLLMProcessing` never re-evaluated
despite the mutation propagating.

**Branch / commits.** `worktree/chatview-stop` @ `4235f008`
(plan+spec), `02c5935e` (impl).

### 2026-08-06: Kanban — restore per-column sort independence (client-side comparator)

**Symptom (user report, task_1785730557641).** User picks "Name (Z→A)" in one column's ⋮ menu → Sort tasks… modal. The DevTools Network panel shows ALL columns receiving `sort_by=name&direction=desc`. Every column renders in `name Z→A` order, NOT just the one the user picked.

User feedback:
- *"sort not indepedence per column, the goal should independecen per sort column"*
- *"when i click sort it affected all"* (with DevTools screenshot showing `sort_by=name&direction=desc` on every column's fetch)

**Root cause.** Commit `0ed7582d` ("feat(frontend): kanban VirtualScroller + default-sort URL behavior", 2026-08-06) removed the client-side `.sort()` in `KanbanColumn.cardsInColumn` AND deleted the `compareBySortMode` comparator. The justification was the user's "i remove that and its become better" comment — but the removal broke per-column independence, because the backend's `listWorkspaceItemTasksWithCursor` only accepts ONE `sort_field` + `sort_direction` per request.

`fetchKanbanTasksForAllColumns` (workspaces.ts:1302) is correct in that it fetches each column in parallel — but every parallel fetch gets the SAME `sortBy` / `direction` from the caller. The caller (KanbanView.vue:442) takes the LAST-changed entry from `columnSorts` and passes it as the global sort. So picking "Name (Z→A)" in column A causes column B (Manual) to also be re-fetched in `name Z→A` order.

**Fix (surgical).** Re-add the client-side sort comparator in `KanbanColumn.cardsInColumn`. The architecture becomes:

1. **Backend** — each column fetch goes out with the LATEST changed sort (single `sortBy` / `direction` URL param, current behaviour).
2. **Frontend** — each `KanbanColumn.cardsInColumn` applies its own local `sortBy` + `direction` to the incoming tasks. Two columns with different sorts display differently, even though they were fetched with the same wire order.

This is the original architecture from commit `77482f07`. The comparator deleted in `0ed7582d` is restored verbatim — `name` (BINARY collate), `created_at` / `updated_at` (Date → ISO string), with `kanban_position asc` as the tiebreaker for stable ordering across equal sort-field values.

**Files.** 4 changed:
- `src/apps/desktop/src/components/kanban/KanbanColumn.vue` (+85/-35 — restore `.sort()`, restore `compareBySortMode`, update 3 doc comment blocks).
- `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` (+7/-6 — rewrite the "renders cards in input order" test to assert `kanban_position asc`).
- `src/apps/desktop/src/__tests__/KanbanColumn.sortIndependence.spec.ts` (NEW, 11 tests — default sort, 4 sort modes, tiebreaker, per-column independence [critical regression test], 3-column independence, `setSortMode` seam, `sortChange` emit).
- `docs/superpowers/plans/2026-08-06-kanban-sort-independence.md` (NEW).

**Verification.**
- `bun run build` clean (vue-tsc passes).
- `bunx vitest run src/__tests__/KanbanColumn.sortIndependence.spec.ts` — 11/11 pass.
- `bunx vitest run src/__tests__/KanbanColumn.spec.ts` — 19/19 pass.
- `bunx vitest run src/__tests__/KanbanView` — 53/53 pass.
- `bunx vitest run` (full suite) — 2029 pass / 12 fail. The 12 failures are PRE-EXISTING on main (5 `DesignView.undoHidden`, 1 `DesignElement` static contract, 1 `DesignView.nudge clamp`, 1 `AppLayout.translateResize`, 4 `AppLayout.memoriesGate`). Zero regressions from this fix.

**Lesson.** When a user feedback comment ("i remove that and its become better") is acted on globally without checking per-column/per-instance independence, regression is silent. The user reported a single-column issue; the fix removed the per-column sort entirely. Tests like "renders cards in input order" (KanbanColumn.spec.ts) become the guard rail — if they fail to assert the per-column sort behaviour, the regression slips through.

**Branch / commit.** `worktree/kanban-sort-independence` @ `911e6647`.

### 2026-08-06: Kanban — per-column sort fetch (only the changed column's endpoint)

**Symptom (user follow-up, task_1785730557641).** The previous fix restored per-column visual independence (frontend client-side re-sort + backend single-sort wire). But the wire shape STILL had every column receiving the same `sort_by` URL params on every sort change. User feedback:

- *"when sort happen its should independece not all column use same sort by value, fix that code above"*
- *"just make sure if i sort column a, only column a endpoint that called, other column a should not call endpoint"*

**Root cause.** Two layers:
1. The `watch(columnSorts, ...)` in `KanbanView.vue:427` took only the LATEST changed sort from `Object.values(columnSorts.value)` and applied it globally to a single `fetchKanbanTasksForAllColumns` call.
2. `fetchKanbanTasksForAllColumns` (workspaces.ts:1302) loops over every column and calls `fetchKanbanTasks(col, sortBy, direction)` with the SAME `sortBy` / `direction` — wire-level fan-out regardless of which column changed.

**Fix (surgical, per-column fetch).** `handleColumnSortChange` in `KanbanView.vue` now fires `fetchKanbanTasks(col, sortBy, direction)` for ONLY the clicked column, with that column's own sort. Other columns' data is untouched (it still matches their own last sort from a previous per-column fetch).

**Wire shape now matches the user's intent:**
- User picks "Name (Z→A)" on column A → ONLY `?sort_by=name&direction=desc&column_id=col_a` is called.
- Column B's data is unchanged (still in its own last sort).
- No more fan-out N parallel calls on every sort change.

**Files.** 4 changed + 1 deleted:
- `src/apps/desktop/src/components/kanban/KanbanColumn.vue` — removed `compareBySortMode` + the client-side `.sort()` (back to plain filter). `handleSortModalSelect` now always emits `sortChange` unconditionally on every menu click. `setSortMode` is a pure ref-mutator (no emit — the URL restore path fires the fetch directly in the onMount loop).
- `src/apps/desktop/src/components/kanban/KanbanView.vue` — `handleColumnSortChange` fires `fetchKanbanTasks` for the changed column only. `watch(columnSorts, ...)` is URL-only (no fetch, no debounce). URL restore onMount loops over entries and fires per-column `fetchKanbanTasks` (default sort is `continue`d).
- `src/apps/desktop/src/__tests__/KanbanView.sortByApi.spec.ts` — 7 new behavioural tests. The critical regression test: *"picking Created (oldest) on column A fires fetchKanbanTasks for col_a only (col_b is NOT called)"*.
- `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` — restored the "renders cards in input order" assertion (client-side sort is gone; wire order is what the user sees).
- `src/apps/desktop/src/__tests__/KanbanColumn.sortIndependence.spec.ts` — DELETED. The client-side comparator it tested is gone.

**Verification.**
- `bun run build` — vue-tsc clean.
- `bunx vitest run src/__tests__/KanbanView.sortByApi.spec.ts` — 7/7 pass.
- `bunx vitest run src/__tests__/KanbanColumn.spec.ts` — 19/19 pass.
- `bunx vitest run` (full suite) — 2027 pass / 12 fail. The 12 are PRE-EXISTING on main (5 `DesignView.undoHidden`, 1 `DesignElement` static contract, 1 `DesignView.nudge clamp`, 1 `AppLayout.translateResize`, 4 `AppLayout.memoriesGate`). Zero regressions from this fix.

**Lessons.**
- **Network panel = wire shape, not behavior.** The user's initial complaint was about the Network panel showing the same `sort_by` on every column. The first take (per-column-sorts-map in the store) fixed the wire shape but still fired N parallel fetches. The user pushed back — they don't want OTHER columns' endpoints called at all. The take-2 fix removes the fan-out entirely.
- **Per-column fetch is the right primitive.** The store already has `fetchKanbanTasks(columnId, sortBy, direction)`. Use it directly; the `fetchKanbanTasksForAllColumns` helper is for "all columns with the SAME sort" (initial mount, search, SSE) — not for per-column sort changes.
- **Idempotent user actions should always emit.** The watcher-based emit only fired on value CHANGE. The menu click handler emits unconditionally — even when the user picks the same sort twice. Same sort twice should still refetch.
- **`setSortMode` is a seam, not a side-effect channel.** It mutates refs but doesn't emit. The URL restore path uses it to set local state, then the onMount loop fires the fetch. Keeping the seam pure prevents double-fetch.

**Branch.** `worktree/per-column-sort-watcher`.

### 2026-08-06: AI agent tools — `get_design_context` + `preview_design_page`

**Symptom (user report, task_1785697326304).** *"ai agen tool, get design context, get view design"*. The agent could CREATE/EDIT design elements via `set_design_page` + `add_element` + `update_element`, but had no way to **read** the current design state or **see** it. The LLM had to call `bash` + `sqlite3` to peek at the DB or run `ls` on the on-disk design folder, neither of which gave it a useful mental model of the page.

**Two new tools:**

| Tool | Input | Output |
|---|---|---|
| `get_design_context` | `page_id` OR `workspace_item_id` (exactly one) | XML envelope listing every page + every element + every attribute (x/y/w/h/type/fill/rotation/parent_id/text_content/image_url/etc.) |
| `preview_design_page` | `page_id` (required), `scale` (default 1.0, max 4.0) | SVG visualization rendered in the side panel via the existing `show_preview` `html` content-type sandboxed iframe |

**`get_design_context` design.** Pure read, mirrors the `design_page_elements` DB wire shape. The agent sees EXACTLY what the DB stores (every column is rendered as an XML attribute, including `parent_id=""` for top-level). HTML bodies are intentionally NOT included — the agent can read them individually via `read_file` if needed (matches `set_design_page`'s convention). Empty `page_id` AND empty `workspace_item_id` → error; both set → error.

```xml
<design_context>
  <pages count="2">
    <page id="page_xxx" name="Login" width="1440" height="1024" position="0">
      <design_page_elements count="3">
        <element id="elem_aaa" page_id="page_xxx" name="clear-button" type="rectangle"
                x="1356" y="16" width="60" height="24" fill="transparent"
                parent_id="elem_bbb" ... />
      </design_page_elements>
    </page>
  </pages>
</design_context>
```

**`preview_design_page` design.** Generates a self-contained SVG (no external resources except `image` `href`s) and wraps it in the existing `<show_preview>` envelope (content_type="html"). The frontend's `PreviewContentRenderer` already renders `html` content-types via the sandboxed iframe — zero frontend changes needed. Each element type maps to the matching SVG primitive:

| Element type | SVG | Notes |
|---|---|---|
| `rectangle` | `<rect>` | fill + stroke + corner_radius + rotation |
| `ellipse` | `<ellipse>` | cx/cy = bbox center, rx/ry = bbox half |
| `text` | `<text>` | y baseline = y + height, font_size = bbox height (min 8) |
| `image` | `<image>` | href = image_url |
| `frame` / `group` | `<g>` | recursive children render inside via tree walk |

Group/frame nesting handled via recursive descent (depth-guarded at 32). Unknown element types render as a labeled outlined rectangle so the agent sees SOMETHING (no silent drops).

**Scale factor.** Applied to both the SVG `viewBox` AND every element coordinate. `scale=2.0` doubles everything (so the agent can zoom into details). Capped at 4.0 to prevent a malicious LLM from requesting a 1000x page scaled to 4000x and OOM'ing the side panel renderer.

**Implementation.** Zero backend schema changes — both tools use the existing `design_model.listPages` / `getPageWithElements` / `listPagesWithElements` / `loadElementHtml` APIs. Zero frontend changes — `preview_design_page` reuses the existing `PreviewContentRenderer` html path + `ShowPreview.vue` chat-output component.

**Files (6 new + 4 edits).**
- `src/modules/agent/tools/get_design_context.zig` — tool def + `executeGetDesignContextToString`
- `src/modules/agent/tools/get_design_context_test.zig` — 8 behavioural + 5 wiring tests
- `src/modules/agent/tools/preview_design_page.zig` — tool def + SVG generator + `executePreviewDesignPageToString`
- `src/modules/agent/tools/preview_design_page_test.zig` — 10 behavioural + 5 wiring tests
- `src/ai_workflow/tui/agentic_loop/tools_exec_get_design_context.zig` — exec wrapper
- `src/ai_workflow/tui/agentic_loop/tools_exec_preview_design_page.zig` — exec wrapper
- `src/root.zig` (+2 lines), `src/ai_workflow/tui/mod.zig` (+2 lines), `src/ai_workflow/tui/agentic_loop/tools.zig` (+2 lines), `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` (+2 imports + 4 entries)

**Verification (worktree `worktree/agent-tool-design-context`).**
- `zig build test --summary all`: **2184/2190 pass, 6 skip** (was 2168/2174 before, +16 new tests, 0 new failures)
- 2 leaks reported — PRE-EXISTING in `design_model_set_element_parent_test.zig` cycle-rejection test, unrelated
- `zig build install:linux:system` + `rm -rf zig-out/bin && zig build` → both `nalarcore-linux-x86_64` (82 MB) + `nalar-desktop` (13 MB) produced
- Cross-compile `zig build-obj -target x86_64-windows-gnu` and `-target aarch64-macos` → both clean (no errors)
- Live HTTP smoke on port 8080 (separate `$HOME`): server starts, `/api/workspaces` works → confirms the wiring doesn't break the existing design HTTP layer (the agent tools are LLM-side, not HTTP-side)

**Out of scope (deferred).**
- Per-element preview (the agent can always re-call with a closer view — the page preview is enough for v1)
- SVG interactive overlays (e.g. click an element to highlight its `<rect>`) — pure read tool, no interaction model needed
- Animated SVG (e.g. transitions during edit) — side panel is a static preview, not a canvas
- Multi-page preview (one SVG per page) — out of scope; use `get_design_context` for the data shape

**Plan.** `docs/superpowers/plans/2026-08-06-ai-agent-design-context-tool.md`.

### 2026-08-06: Delete `agentic_loop/mod.zig`, promote `workflow.zig` as public face

**Symptom (user report).** User: *"delete mode.zig as screenshot, and fix the zig build"*. The `src/ai_workflow/tui/agentic_loop/mod.zig` barrel file (99 lines) was a pure re-export of 44 symbols from sub-modules in the same directory. Every internal file did `const mod = @import("mod.zig")` then `mod.X`, adding an extra import hop for every consumer without owning any logic.

**What landed.** Surgical delete + workflow.zig promotion (no behaviour change):

- **`src/ai_workflow/tui/agentic_loop/mod.zig`** — **DELETED**
- **`src/ai_workflow/tui/agentic_loop/workflow.zig`** — promoted to the module's public face. Added 44 `pub const` re-exports (the same symbols `mod.zig` held). Internal `agentic_loop_mod.X` call sites switched to direct names. `const nalarcore` → `pub const nalarcore`.
- **49 internal files** in `agentic_loop/` — switched from `const mod = @import("mod.zig")` + `mod.X` patterns to direct imports (`const nalarcore = @import("nalarcore")`, `const tools = @import("tools.zig")`, `const LLMHistory = @import("llm_history.zig").LLMHistory`, etc.). 3 special cases (`handle_tool.zig`, `build_messages_for_agent_prompt.zig`, `build_messages_for_agent_prompt_test.zig`) point at `workflow.zig` instead.
- **`src/ai_workflow/tui/http_handlers/system_prompt_get.zig`** — also imported `mod.zig` (out-of-tree consumer); updated to `workflow.zig`.
- **`src/root.zig`** — `nalarcore.agentic_loop_mod` now points at `workflow.zig`.

**External API preserved.** `nalarcore.agentic_loop_mod.<X>` still resolves to the same symbol — every existing caller works unchanged.

**Net effect.** 77 files changed, +355/-380 (net 25 fewer lines). One fewer file in the build graph.

**Verification.**
- `zig build test --summary all`: **2278 pass, 6 skip (2284 total), 2 leaks** — the 2 leaks are pre-existing on `main` (`design_model_set_element_parent_test` cycle-rejection test, unrelated to this refactor).
- `zig build install:linux:system` → compile succeeds; only `cp` to `/usr/local/bin/` fails (permission, not our problem).
- `rm -rf zig-out/bin && zig build` → both `nalarcore-linux-x86_64` (86 MB) + `nalar-desktop` (35 MB) + `nalar` (78 MB) + `nalarcli` produced.
- Cross-compile smoke: `zig build-obj -target x86_64-windows-gnu` + `-target aarch64-macos` → both clean (no errors).
- Binary smoke: `zig-out/bin/nalarcore-linux-x86_64 --help` → works.

**Notes.**
- Renamed `workflow.zig::callDynamicAgentNew`'s `tools` parameter to `equip_tools` to avoid shadowing the new `pub const tools` re-export (otherwise Zig emits a "function parameter shadows declaration" error).
- `workflow.zig::LLMHistory` re-export reads from `@import("llm_history.zig").LLMHistory` (the `agentic_loop/` directory's own `llm_history.zig`), NOT `../llm_history.zig` (the parent dir's `llm_history.zig` which doesn't have `LLMHistory`).
- Inserted `const mark_history_not_for_llmrun = @import("markHistoryNotForLLMRun.zig").markHistoryNotForLLMRun;` in `workflow_commpact_message.zig` (was previously `mod.mark_history_not_for_llmrun`). Same for `IsWorkerCancelledInput`, `onEventSendWorkers`, `onEventSendSessions`.

**Branch / commit.** `main @ bfe53456`. Squash-merged via direct commit (was working on `main` directly).
### 2026-08-06: `nalarcli` — native Zig CLI for the HTTP API

**Symptom (user request, task_1785674002603).** Wrap the backend's
HTTP endpoints (POST `/api/llm/session`, GET `/api/llm/session`,
GET `/api/llm/session/<id>/messages`, GET `/api/events?channels=…`)
in a CLI binary so the user can drive the backend from a terminal
without opening the desktop app. Native Zig (no shell-out to `curl`).

**Architecture.** Three new build-graph entries in `build.zig`:

1. **`cli_app_mod`** — module rooted at `src/apps/cli/src/root.zig`,
   re-exports the public API (`config`, `client`, `format`,
   `commands`, `custom_http_client`). Imports `custom_http_client` so
   the HTTP transport is shared with `custom_http_client_mod` (no
   duplicate libcurl wiring).
2. **`cli_exe`** — executable rooted at `src/apps/cli/src/main.zig`,
   links libc + libcurl (cross-platform via `custom_http_client_mod`).
3. **`test:cli`** — runs the unit-test suite for the cli module.
4. **`run:cli`** — runs the binary (passes through `b.args`).
5. **`install:cli`** — installs only the CLI binary.

The CLI re-uses the existing `custom_http_client` libcurl transport
rather than re-implementing curl — Linux/macOS/Windows libcurl paths
are already handled by `-Dcurl-prefix` / `-Dcurl-vcpkg-root` (declared
once on the `custom_http_client_mod` block).

**Subcommands.**

| Verb | Endpoint | Verbose flag | Behaviour |
|---|---|---|---|
| `send <msg>` | POST `/api/llm/session` | `--session`, `--profile`, `--allowed-tools`, `--cwd`, `--auto-retry` | Queues a message to a session; creates a fresh `session-<unix-ms>` if none given. |
| `sessions` | GET `/api/llm/session?limit=N` | `--limit <n>` | Lists recent sessions. |
| `messages <id>` | GET `/api/llm/session/<id>/messages` | `--limit <n>`, `--reverse` | Lists messages in a session. |
| `events` | GET `/api/events?channels=…` | `--channels <a,b,c>` | Long-lived SSE tail (uses `custom_http_client.openStream`). |
| `help` / `-h` / `--help` / `<unknown verb>` | — | — | Prints help text. |

**Global flags** (parsed in `main.zig` BEFORE the verb parser):
`--server <url>`, `--session <id>`, `--profile <name>`.
**Env vars** (resolved by `config.load` when flags are absent):
`NALARCLI_SERVER`, `NALARCLI_SESSION_ID`, `NALARCLI_PROFILE`.

**Files.** 13 new + 2 modified:
- `src/apps/cli/build.zig` + `build.zig.zon` (new — boilerplate from `zig init`, NOT used by the parent build)
- `src/apps/cli/src/main.zig` (entry point, argv parser, dispatch glue)
- `src/apps/cli/src/root.zig` (package re-exports + `test` discovery)
- `src/apps/cli/src/config.zig` (server/session/profile resolution)
- `src/apps/cli/src/client.zig` (HTTP helpers over `custom_http_client`)
- `src/apps/cli/src/format.zig` (placeholder — not yet used)
- `src/apps/cli/src/commands/root.zig` (verb parser + dispatch + parseXxxArgs)
- `src/apps/cli/src/commands/{send,sessions,messages,events}.zig`
- `src/apps/cli/src/*_test.zig` + `src/apps/cli/src/commands/*_test.zig`
- `build.zig` (added `cli_app_mod` + `cli_exe` + `test:cli` step + `install:cli` step + banner update)
- `src/modules/custom_http_client/src/methods.zig` (1-line fix: `Client.Error` → `@import("client.zig").Error` — pre-existing latent bug that surfaced when `methods.zig` was first consumed)

**Tests.** +43 new behavioural tests across 8 files:
- `client_test.zig` — 3 (rewritten for Zig 0.16 `std.Io.net.IpAddress` + `Threaded.init` + per-thread accept; fixed Response leak with `defer response.deinit(allocator)`)
- `config_test.zig` — 7 (resolution priority: flags → env → defaults)
- `format_test.zig` — 2 (placeholder; ready for the JSON formatter when used)
- `commands/root.zig` (inline) — 4 (verb parser) + 16 (parseXxxArgs)
- `commands/{send,sessions,messages,events}_test.zig` — 5 (placeholders, will be replaced in the next TDD slice that hits the live endpoint)

Total cli test count: **43/43 pass, 0 leaks.**

**Verification.**
- `zig build test:cli --summary all` → 43 pass, 0 leaks
- `zig build install:cli --summary all` → produces `zig-out/bin/nalarcli` (~12 MB)
- `zig build --summary all` → all three binaries; banner shows nalarcli
- `zig build test --summary all` → 2175/2181 + 6 skip (same as main; 2 pre-existing leaks from `design_model_set_element_parent_test`)
- Live smoke on port 8081: `./zig-out/bin/nalarcli --server http://localhost:8081 sessions --limit 1` returns JSON; `messages session-… --limit 1` returns JSON; `help` prints usage; unknown verb prints help.
- Cross-compile Zig code compiles cleanly for `x86_64-windows-gnu` + `aarch64-macos` (linker fails only because libcurl/vcpkg aren't installed on this Linux host — same pre-existing failure for `nalar` and `nalar-desktop`).

**Out of scope** (deferred to follow-up plans):
- LLM-tool-emulation mode (call `send` with `--auto-retry` and let the CLI wait for SSE-finished).
- Per-call mixing of `--server http://...` and `NALARCLI_SESSION_ID` works but no validation (server unreachable surfaces as a libcurl error, not a friendly CLI message).
- `format.zig` is wired but unused; subcommands dump raw JSON.
- Static-binary option via `zig build -Dpic` for shipping a single binary.
- Windows resource metadata (icon, version) via `-Dwindows-icon`.

**Branch.** `worktree/cli-app` (uncommitted).

### 2026-08-06: Tool-call loading placeholder — kill "Invalid function ID" on crash

**Symptom (user report, task_1785784899843).** After the agent
crashed mid-tool-execution (bash hangs, spawn_sub_agent dies,
nalar SIGKILL'd, network hang during read_file), the next LLM
request failed with `400 Bad Request: Invalid function ID tool
call error`. The conversation had an assistant message declaring
`tool_calls=[A, B, C]` but only some of the `role=tool` rows landed
in the DB. OpenAI's API requires ALL `tool_call_id`s in the
assistant message to have matching tool rows — even one missing
fails the request, and every subsequent request fails the same
way.

**Why the current 2-phase pattern fails** (in `handle_tool.zig`):

```zig
// Phase 1: SINGLE INSERT — declares tool_calls=[A, B, C]
_ = try llm_history.saveMessage(... { role=assistant, tool_calls=tc, ... });

// Phase 2: for-loop — each iteration runs long-running tools then INSERTs the row
for (tc) |tool_call| {
    const exec_result = try dispatchTool(ctx, tool_call);  // LONG-RUNNING
    try saveAndSendToolResult(... tool_call.id ...);      // crashes here → orphan id
}
```

If the crash is mid-Phase-2, the assistant row exists but some
tool rows don't. Next LLM call → API reject → stuck forever.

**The fix (3-phase pattern)**:

```
Phase 1 (sync)  ── INSERT placeholder rows for ALL tool_calls
Phase 2 (sync)  ── INSERT the assistant message with tool_calls
Phase 3 (async) ── for each tool_call: run + UPDATE the row in place
```

If we crash between Phase 1 and Phase 3, the placeholders stay in
the DB. A startup hook (`resolveStaleLoadingToolResults(session_id)`)
replaces stranded placeholders with a synthetic "Tool execution
interrupted" message, satisfying the API contract by ID.

**Files (8 changed, +1012/-34).**

- `src/migrations/migration.zig` — new `Migration068AddToolCallLoading` (adds `is_loading` column + partial UNIQUE INDEX on `tool_call_id`)
- `src/migrations/migration_068_test.zig` (NEW) — 6 behavioural tests
- `src/migrations/test_runner.zig` — register the new test
- `src/ai_workflow/tui/llm_history.zig` — 3 new helpers (`saveToolResultPlaceholder`, `updateToolResultById`, `resolveStaleLoadingToolResults`)
- `src/ai_workflow/tui/llm_history_tool_call_loading_test.zig` (NEW) — 9 behavioural tests
- `src/ai_workflow/tui/agentic_loop/handle_tool.zig` — 3-phase rewrite (`saveAndSendToolResult` → `updateAndSendToolResult`)
- `src/ai_workflow/tui/agentic_loop/workflow.zig` — call `resolveStaleLoadingToolResults` at top of worker loop
- `src/ai_workflow/tui/test_runner.zig` — register the new test

**Why the placeholder MUST have `is_feed_to_llm=1`.** If we mark
it `is_feed_to_llm=0`, the conversation payload sent to the LLM
omits the placeholder row → assistant message's `tool_calls=[A,
B, C]` has no matching tool result for B/C → API rejects. So the
placeholder is sent to the LLM with empty content. The LLM sees
"tool call A completed with empty content" — acceptable as a
"still running" sentinel. The startup hook then upgrades this to
a more meaningful "interrupted" message before the next LLM call.

**TDD trace.** RED (6 migration tests fail because the column
doesn't exist) → GREEN (Migration 068 added). RED (9 helper tests
fail because the helpers don't exist) → GREEN (helpers added).
REFACTOR (handle_tool.zig 3-phase rewrite) → GREEN (existing 16
inline `parseDiffViewFromResult` tests still pass + 0 regressions).

**Verification.**

- `zig build test --summary all` → **2293 pass / 6 skip / 0 fail** (was 2278/2290 before — +15 new tests). 2 leaks are PRE-EXISTING in `design_model_set_element_parent_test.zig`.
- `zig build install:linux:system` → compiles (cp to /usr/local/bin fails on perms, expected).
- `rm -rf zig-out/bin && zig build` → produces nalar (79 MB), nalarcore-linux-x86_64 (87 MB), nalar-desktop (13 MB), nalarcli (12 MB).
- Cross-compile smoke (mandatory for SQL helpers — Zig's lazy semantic analysis can hide SQL prepare errors): `zig build-obj -fno-emit-bin -target x86_64-windows-gnu` and `-target aarch64-macos` both clean.

**Why the UNIQUE INDEX on `tool_call_id` is partial.** Excludes
empty-string `tool_call_id`s (the assistant message's `tool_call_id = ''`)
so the assistant row doesn't conflict with the placeholders'
`tool_call_id = 'tcA'` etc. Without it, a dispatcher race could
create two placeholders for the same id.

**Out of scope** (deferred to follow-ups):

- **Per-tool recovery strategy**: for v1, all stranded tool results get a generic "interrupted" message. A future improvement could attempt to re-run idempotent tools (most are NOT — defer until user asks).
- **Live "tool running" UI**: the chat view's existing Queue/Stop button is the visible indicator. No new UI needed.
- **Migration backfill**: the startup hook handles any existing stranded rows on next launch. No separate backfill migration.
- **Streaming placeholder content**: v1 commits empty content; a future enhancement could stream live updates via SSE.

**Pitfalls (the non-obvious traps):**

- The UPDATE preserves `created_at` and `created_iso` — those are the placeholder's "started at" time. Don't drift them on UPDATE; the LLM benefits from the gap between assistant and tool completion (visible in UI tooltips).
- The startup hook is idempotent — calling it on a session with 0 stranded rows is a no-op. Safe to call on every iteration.
- MCP tools (in `handle_mcp_tool.zig`) also go through `updateAndSendToolResult` — they get the same 3-phase benefit automatically because `handle_tool()` is the single dispatch point.
- `spawn_sub_agent` specifically benefits: a child-agent run that takes 30+ minutes and gets killed at minute 20 leaves a placeholder that resolves to "interrupted" on next start (instead of permanently orphaning the tool_call_id).

**Branch / commit / PR.**

- Branch: `worktree/tool-call-loading-placeholder`
- Squash commit: `5e19e4ad` ("fix(agent): kill 'Invalid function ID' on crash via 3-phase tool-call INSERT")
- PR: #181
- Plan: `docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md`
- Memory: `.nalar/memories/tool-call-loading-placeholder-2026-08-06.md` (project) + `~/.config/nalar/memories/openai-tool-call-api-contract.md` (cross-project)

### 2026-08-06: Bash tool — regression test for `head -n 30 + huge lines` byte-cap

Cherry-picked from `worktree/bash-truncation-bytes` (branch was stale relative to main by ~14 commits, only the single meaningful commit was brought across).

**Symptom.** User report: agent ran
`grep -rn "invalid_id\|InvalidId\|invalid id" /home/.../src/ 2>&1 | head -n 30` and got back ~150 KB of stdout. The bash tool DID set `truncated=true` (byte cap fired at 20 KB), but the truncated result was still huge — blowing the LLM context. `head -n 30` bounds the LINE count but NOT the BYTE count; matching lines came from single-line minified JS in `node_modules/` (~5 KB per line).

**What landed (commit `042276ed`).** New regression test `bash_tool: many long lines (head -n 30) byte-truncated to max_output` in `src/modules/agent/tools/bash_test.zig`. Verifies:

1. `result.truncated == true` when output > `max_output` (even when line count < `max_lines`).
2. `result.stdout.len <= max_output` (capped at the byte limit).
3. `result.stdout_lines` reports the TRUE pre-truncation count (≥ 30).
4. **NO FD LEAK** after the byte-truncation path — guards against future refactors that add an early-return on truncation without closing both reader-thread pipes.

Uses `yes` + a 200-char-per-line × 30-line input piped through `head -n 30`, with `max_output=2048` + `max_lines=999_999` to isolate the byte-cap path.

**Files (1 changed, +70/-0).**
- `src/modules/agent/tools/bash_test.zig` — 1 new test (gated on `builtin.os.tag != .windows` per the no-Windows bash test convention).

**Verification.**
- `zig build test --summary all` — 2294/2300 pass, 6 skip, 2 leaks (matches documented baseline in AGENTS.md).
- Branch: `worktree/bash-truncation-bytes` @ `c9ceceb5`
- Commit: `042276ed` (cherry-picked onto main with `-x` annotation).

### 2026-08-06: Undo regressions from "fixing invalid" (commit `20d061c6`)

Discovered while verifying the bash test cherry-pick. Commit `20d061c6` ("call tool place holder fixing invalid") was a follow-up to PR #181 that attempted to fix something in the tool-call-loading-placeholder, but introduced **3 regressions** that together blocked `zig build test` from running cleanly.

**Regression #1 — `WHERE id = ?` instead of `WHERE tool_call_id = ?`** (`src/ai_workflow/tui/llm_history.zig::updateToolResultById`). Commit changed the WHERE clause from `tool_call_id` to `id`, breaking lookup by `tool_call_id`. The function doc explicitly says it looks up by `tool_call_id`, and tests pass the `tool_call_id` string (not the row's nanosecond-timestamp id). Net effect: every UPDATE found 0 rows and the row's `response_content` stayed empty.

**Regression #2 — new `io: std.Io` parameter not threaded into 4 test callsites** (`llm_history_tool_call_loading_test.zig`). Commit added the `io` parameter to `updateToolResultById` but the 4 test calls still passed only 4 args. 4 compile errors blocked `zig build test` entirely.

**Regression #3 — `inserLLMHistories` return type changed from `!void` to `![]const u8`** (`src/ai_workflow/tui/agentic_loop/insert_llm_histories.zig`). The new return allocates a duplicate of the row's `id` string, but **no production caller uses the returned value**. The 16 test callsites were updated to `_ = try inserLLMHistories(...)` which leaked the returned slice — 16 leaked allocations per full test run.

**Fix (commit `fbf83057`).** Revert all 3 to the post-PR-#181 state:
- `WHERE tool_call_id = ?` (back to looking up by `tool_call_id`)
- `io` arg added at all 4 test callsites
- `inserLLMHistories` returns `!void` (no id dupe, no leak)
- All 16 test callsites: `_ = try inserLLMHistories(...)` → `try inserLLMHistories(...)`

**Verification.**
- `zig build test --summary all`
  - BEFORE: 3 tests failing + 18 allocations leaked
  - AFTER: 2294/2300 pass, 6 skip, 2 leaks (matches documented baseline)
- 3 tests now pass that were previously failing:
  - `updateToolResultById updates content + is_loading=0 in place`
  - `updateToolResultById accepts and stores diffview_before / diffview_after`
  - `resolveStaleLoadingToolResults is idempotent on a session with no stranded rows`

**Files (3 changed, +22/-24).**
- `src/ai_workflow/tui/llm_history.zig` (1 line)
- `src/ai_workflow/tui/llm_history_tool_call_loading_test.zig` (4 lines)
- `src/ai_workflow/tui/agentic_loop/insert_llm_histories.zig` (37 lines)

**Lesson.** Follow-up "fix the invalid thing" commits need full regression coverage: if PR #181 had a regression test that covered the `UPDATE … WHERE tool_call_id = ?` round-trip, this would have been caught immediately. The `updateToolResultById` function is now well-tested by the suite — future changes to its WHERE clause will fail loudly.


### 2026-08-04: search_history v2 — new filters + prompt wiring

User: "is this tool only fetching is_llm_feed 0 or is_llm_seaf_feed 1 or search another memory session ?" → "any another suggestion ?" → "do top tier and mid tier, use git worktree and tdd development, and adjust with the system prompts too, @/src/modules/agent/prompts.zig".

**Top tier (5 new filters):** `live_only` / `compacted_only` (mutually exclusive), `tool_name`, `parent_session_id`, `agent`, `since_relative` / `until_relative` / `relative_window`.

**Mid tier (1 UX win):** `mode="text"` accepts `message_ids` → response includes a `<full_contents>` block with full bodies alongside the FTS hit snippets.

**Backend:** `llm_history.zig` +75 lines (new `SearchOptions` fields, `getMessagesByIds` helper). `search_history.zig` +80 lines (new params, parseMessageIds, error XML for too-many-ids). **+18 new behavioural tests.**

**Prompts:** new `SearchHistoryToolRule` in `core.zig` (gated on `requires_tool='search_history'` in `PROMPT_SECTIONS`), `CompactionAgent` updated to teach the next agent the filter vocabulary, `search_history` tool description updated with new params + FTS sanitization note + 4 new examples.

**Verification:** 2304 pass / 6 skip / 2 leaks (pre-existing baseline). `x86_64-windows-gnu` + `aarch64-macos` cross-compile clean.

**Out of scope:** `handle_tool.zig:487` void-bug (pre-existing PR #181 regression — `inserLLMHistories()` returns `!void` but called as if it returned `[]const u8`). Surface via `zig build` but hidden from `zig build test` by lazy semantic analysis. Separate fix.

**Commits (worktree/search-history-v2):**
- `4bd47c64` Chunk 1 — is_feed_to_llm filter
- `e60e1bf9` Chunk 2 — tool_name filter
- `a421076f` Chunk 3 — parent_session_id filter
- `aee707e4` Chunk 4 — full `<content>` in mode="text" + INSERT-column fix
- `9c2a5808` Prompts + tool description

**Branch:** `worktree/search-history-v2`. **Plan:** `docs/superpowers/plans/2026-08-04-search-history-v2.md`. **Memory:** `.nalar/memories/search-history-v2-filters-2026-08-04.md`.
