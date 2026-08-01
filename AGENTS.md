
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
