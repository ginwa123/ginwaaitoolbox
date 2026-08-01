
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

---

## 📜 Recent changes (changelog)

> Append-only. After finishing a non-trivial task, add a short note here
> documenting what landed and why. These breadcrumbs help the next session
> pick up context without re-reading the git log.

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
