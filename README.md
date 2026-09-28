# ginwaaitoolbox — Nalar

[![CI](https://github.com/ginwa123/ginwaaitoolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/ginwa123/ginwaaitoolbox/actions/workflows/ci.yml)

**Nalar** is an AI agent workspace. Chat with LLMs that can actually *do things*
(read/write files, search code, run shell commands, manage kanban boards, draw on
a design canvas), all persisted in a local SQLite database and presented through
a Vue web app, a native desktop shell, a native Android client, or the terminal.

## What this project is about

One backend, five clients, one repo:

1. **Backend — Zig 0.16 agent runtime** (`src/`)
   - Orchestrates LLM calls (Anthropic, OpenAI-compatible, custom `base_url`)
     with streaming, auto-retry ("unattended mode"), and per-profile config.
   - **42 built-in agent tools** — see [Agent tools](#agent-tools) below for the
     full list and the registry they dispatch from.
   - Custom HTTP server (per-request arena, `Io.Threaded`) + libcurl-backed
     HTTP client (replaces `std.http`), SQLite via `SqliteBackend`
     (**92 migrations**), single global SSE stream
     (`/api/events?channels=...`), transaction support.
2. **Frontend — Vue 3 + TypeScript + Pinia SPA** (`src/apps/desktop/`)
   - Chat sessions, kanban boards (drag-drop, pins, pagination), design canvas
     (pages/elements, history), file tree, routine views, settings,
     notifications, tabs — all over a REST + SSE API.
   - 163 `.vue` components and 476 `*.spec.ts` tests; the main screens live in
     `src/apps/desktop/src/components/views/` (`src/apps/desktop/src/views/`
     only holds `LoginView.vue`).
   - Built with Vite + pnpm, tested with Vitest. `src/apps/desktop/src/sync/`
     is the Effect-TS offline-sync slice (see
     [docs/effect-migration.md](docs/effect-migration.md)).
3. **Desktop shell — `nalar-desktop`** (`src/apps/desktop_app/`)
   - Native webview wrapper (WebKitGTK 4.1 on Linux, WKWebView on macOS,
     WebView2 on Windows) that embeds the built web app. Pure GUI shell —
     it connects to a running `nalar` service, it doesn't own it.
4. **Terminal clients** (`src/apps/cli/`)
   - **`nalarcli`** — terminal wrapper around the REST API
     (`send` / `sessions` / `messages` / `events` SSE tail / `pr-status`).
   - **`nalar-tui`** — a full-screen, Claude-Code-style streaming chat client
     over the same endpoints, built on a from-scratch Bubble-Tea-style
     `tui` module at `src/apps/cli/src/tui/`. No extra dependencies.
5. **Android client — native Jetpack Compose** (`src/apps/android_mobile/`)
   - A standalone Kotlin client (`com.nalar.mobile`, minSdk 26). It is a real
     client, not a stub: HTTPS sign-in, Keystore-encrypted session restore,
     SSE chat with markdown/reasoning/tool cards, projects + task creation,
     a recents drawer, three Room offline caches, an in-app network inspector
     with request replay, `nalar://chat/…` deep links, and session resume.
   - It does **not** embed the web app and does **not** start or manage a
     Nalar server. See [its README](src/apps/android_mobile/README.md).

Plus two standalone side services:

- **`src/modules/nalar_browser/`** — a Bun + TypeScript anti-bot scraping
  microservice (CloakBrowser / stealth Chromium) with its own
  `http_handlers/` bridge. This is the one place Bun is still used; the webapp
  build path is pnpm-only (see [Prerequisites](#prerequisites)).
- **`src/apps/mcp_hello_world/`** and **`src/apps/mcp_http_hello_world/`** —
  tiny MCP fixtures (stdio and Streamable-HTTP) that the MCP functional tests
  boot as self-test targets. `zig build mcp-hello-world` /
  `zig build mcp-http-hello-world`.

Key features at a glance:

- 💬 Chat sessions with tool-calling agent loop, compaction, FTS5 history search
- 📋 Kanban (columns, tasks, reorder, pins, routines per workspace item)
- 🎨 Design canvas (pages, elements, agent-visible via `get_design_context`)
- ⏰ Workspace routines + in-process scheduler
- 🧠 Agent memories (append-only, FTS5), skills, sub-agents, git worktrees
- 🔌 MCP servers (stdio + HTTP), LLM profiles, web-launch mode, TLS / HTTP/2 (h2c)
- 🖥️ Service mode (`nalar service start`) shared by desktop + browser + CLI
- 🔐 Optional `--auth` multi-user mode with per-user DB + SSE scoping

> Full feature list: [docs/SPEC.md](docs/SPEC.md) — note it is a
> **2026-08-06 snapshot** and has itself drifted (it still cites 54 migrations
> and a Bun frontend). Treat it as a design document, not a live inventory.

## Agent tools

42 tools are registered in `UNIFIED_TOOL_REGISTRY()`
(`src/agentic_loop/tools_equipped.zig`), grouped as:

| Group | Tools |
|---|---|
| Agent control | `spawn_sub_agent` · `ask_user` |
| Plans & introspection | `update_plan` · `get_plan` · `list_sub_agent` · `used_tools` |
| Skills | `list_skills` · `use_skill` · `add_skill` · `edit_skill` · `remove_skill` |
| Memory | `save_memory` · `load_memory` · `read_workspace_session` |
| Files & shell | `command` · `read_file` · `write_file` · `text_replace` · `remove_file` · `glob` · `search` · `list_directory` |
| Git | `set_git_worktree` · `set_pull_request` |
| Kanban | `kanban_list` · `kanban_move_task` · `create_kanban_task` |
| Design canvas | `set_design_page` · `add_element` · `update_element` · `group_elements` · `set_element_parent` · `move_design_element` · `move_element_to_page` · `get_design_context` · `preview_design_page` |
| MCP & progressive discovery | `add_mcp_server` · `search_tool` · `view_tool` · `use_tool` |
| Media & presentation | `generate_image` · `present_files` |

Notes on what is **not** wired up yet — the registry sections exist but every
entry is commented out, so these are not callable today: LSP
(definition/references/hover/symbols), `web_search`, `semantic_search`,
`index_codebase`, and `list_memory`. `command` is the single unified shell tool
(`bash`/`pwsh` are removed — `tools_exec_bash.zig` is a deprecation shim).

Per-tool input/output envelopes: [docs/agent-tools.md](docs/agent-tools.md).

## Tech stack

| Layer | Technology | Notes |
|---|---|---|
| Backend | **Zig 0.16.0** | `build.zig` + `build.zig.zon`; deps: `databases` (ruangsql — sqlite3/openssl), `kabelweb` (HTTP), `helpers` (in-tree) |
| Database | **SQLite** | System lib on Linux; vendored amalgamation elsewhere; 92 migrations in `src/migrations/migration.zig` |
| Frontend | **Vue 3.5 + TS 6 + Pinia 3** | Vue Router 5, Vite 8, Tailwind 4, Monaco editor, `@xterm/xterm` 6, `idb` 8, `marked` 18 |
| Frontend state | **Effect-TS 3.22** | Pinned; owns the `src/apps/desktop/src/sync/` offline-sync layer |
| Lint / format | **oxlint + ESLint 10** + Prettier | `pnpm run lint`, `pnpm run format` |
| Android | **Kotlin 2.0 + Compose M3** | AGP 8.7.3, Room 2.6.1, minSdk 26, JDK 17 |
| Desktop | **Native webview** | WebKitGTK / WKWebView / WebView2 shims under `src/apps/desktop_app/platform/` |
| Tests | **Zig + Vitest + pytest** | `zig build test`, `pnpm run test`, `pytest tests/functional/` (isolated-`$HOME` harness) |

Repo layout:

```
src/
├── agentic_loop/                # LLM loop + tool dispatch (tools_exec_*.zig)
├── modules/agent/tools/         # tool implementations (58 files)
├── modules/nalar_browser/       # Bun anti-bot scraping service (TS)
├── modules/databases/sqlite/    # SqliteBackend + transactions
├── http_handlers/               # REST endpoints (thin wrappers)
├── migrations/migration.zig     # all 92 migrations, registered in allMigrations
├── schedulers/ · models/        # routines scheduler, shared data types
├── ai_workflow/tui/routines/    # routines TUI
├── apps/desktop/                # Vue 3 SPA (screens under src/components/views/)
├── apps/desktop_app/            # nalar-desktop webview wrapper
├── apps/cli/                    # nalarcli + nalar-tui (src/apps/cli/src/tui/)
├── apps/android_mobile/         # native Kotlin/Compose client
├── apps/mcp_hello_world/        # MCP stdio fixture
├── apps/mcp_http_hello_world/   # MCP Streamable-HTTP fixture
├── service/                     # `nalar service` daemon (POSIX + Win32)
└── main.zig / root.zig / startup.zig
docs/
  SPEC.md, ci.md, agent-tools.md, hooks.md, http2*.md, tabs.md,
  sse-tab-sharing.md, effect-migration.md, sse-reconnect-plan.md,
  kanban-row-mode-plan.md, plans/, superpowers/, wireframes/
tests/functional/    # 110 API tests (Python harness, isolated HOME)
tests/functional_ui/ # 20 Playwright UI tests
scripts/   # smoke tests, install helpers, vendoring
packaging/ # linux / macos / windows
examples/  # hooks
```

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| **Zig** | **0.16.0** (`minimum_zig_version`) | `zig version` must print `0.16.0`. Install via `mlugg/setup-zig@v2` in CI or [ziglang.org](https://ziglang.org/download/). |
| **Linux system libs** | — | `sudo apt-get install -y build-essential libssl-dev libsqlite3-dev pkg-config` (Arch: `base-devel openssl sqlite pkgconf`). Linux links system `libsqlite3`. |
| **macOS** | — | Xcode CLT (`xcode-select --install`) + `brew install pkg-config openssl@3` (sqlite via Homebrew keg-only or vendored fallback). |
| **Windows** | — | MSVC Build Tools 2022 + Windows 10 SDK (for the `nalar-desktop` C++ shim) and/or vcpkg `sqlite3` — otherwise the vendored SQLite amalgamation is used. |
| **Node + pnpm** | **Node ^20.19.0 or >=22.12.0** (CI uses Node 24) + **pnpm 11** | Only needed for the frontend / desktop build. **`pnpm-lock.yaml` is canonical** — there is no `package-lock.json`; npm and Bun were dropped from the webapp build in CI and `build.zig` on 2026-08-28. |
| **Bun** | optional | Only for the standalone `src/modules/nalar_browser/` service. |
| **JDK + Android SDK** | JDK 17, SDK platform 35 | Only for `src/apps/android_mobile/`. |
| **Python** | **3.10+** + `pytest` | Only needed for functional tests (`pip install -r tests/functional/requirements.txt`). Playwright + Chromium only for `tests/functional_ui/`. |

Check yours:

```bash
zig version        # want 0.16.0
node --version     # want v20.19+ / v22.12+
pnpm --version     # want 11.x
python3 --version
```

## Install

```bash
git clone https://github.com/ginwa123/ginwaaitoolbox.git
cd ginwaaitoolbox

# 1. Backend binary (native for your OS)
zig build install:linux:system   # Linux → zig-out/bin/nalar, cp /usr/local/bin/nalar
zig build install:macos          # → zig-out/bin/nalarcore-macos-x86_64
zig build install:macos-arm      # → zig-out/bin/nalarcore-macos-aarch64
zig build install:windows        # → zig-out/bin/nalarcore-windows-x86_64.exe
# SQLite comes from the pinned `databases` package (ruangsql) — no extra
# fetch on hosts with system SQLite. Without system libs, populate its
# vendored amalgamation first (idempotent, checksum-verified; see the
# ruangsql repo's scripts/fetch-vendor-sqlite3.sh, or run
# ./scripts/bootstrap-vendor.sh from this repo).

# 2. Frontend web app (only if you hack on the UI)
cd src/apps/desktop
pnpm install
pnpm run build     # vue-tsc + vite → dist/, embedded into nalar-desktop
```

Desktop shell, the `.app`-style installers, and the terminal clients:

```bash
zig build nalar-desktop          # → zig-out/bin/nalar-desktop (backend + embedded webapp)
zig build install:cli            # → nalarcli
zig build install:tui            # → nalar-tui
zig build install-tui            # nalar-tui → ~/.local/bin (or %LOCALAPPDATA%\nalar\bin)

# One-click launcher entries (need sudo on Linux, ~/Applications on macOS)
sudo zig build install:linux:app
zig build install:macos:app
zig build install:windows:app

# Build everything (service + desktop) with a summary
zig build build:all
```

Useful build & test commands:

```bash
zig build test                    # nalarcore module unit tests
zig build test:cli                # nalarcli unit tests
zig build test:tui                # nalar-tui unit tests
zig build test:desktop-app        # nalar-desktop unit tests
zig build functional-test         # Python API tests via zig
zig build functional-test-ui      # Playwright UI tests via zig
zig build --help                  # every step (install:*, test:*, build:*, run:*)
```

> `zig build test` covers the `nalarcore` module only. The CLI, TUI, and
> desktop-app test suites are separate steps and are **not** pulled in by it —
> run them explicitly (CI runs all of them).

## How to run

### 1. Start the server (simplest)

```bash
./zig-out/bin/nalar --port 8081
# → http://127.0.0.1:8081/  (API at /api/*, SSE at /api/events?channels=...)
```

Flags (`nalar --help`):

```
--port PORT            Port to listen on (0 = random free port; default 8081,
                       or random when web-launch mode is on)
--static-dir DIR       Serve a webapp build at / (e.g. src/apps/desktop/dist)
--http2 h2c|off        Also accept HTTP/2 cleartext (default: off)
--tls CERT KEY | --tls-selfsigned
--auth                 Require login (session cookie + middleware)
```

(`--tls`/`--tls-selfsigned` are accepted and documented here, but the binary's
own `--help` lists them only in the usage line. Subcommands `service` and
`create-admin` are likewise not in `--help`.)

Examples:

```bash
# Serve the built UI from the same process
./zig-out/bin/nalar --port 8081 --static-dir src/apps/desktop/dist
# → open http://127.0.0.1:8081/app

# Random-port browser mode + self-signed TLS (HTTP/2 via ALPN)
./zig-out/bin/nalar --port 0 --tls-selfsigned

# Frontend dev loop (Vite HMR against a running backend on 8081)
cd src/apps/desktop && pnpm dev
```

> ⚠️ Dev-server port convention: the real backend always sits on **8081**.
> Never kill it for experiments — point throwaway instances at **8080**.

### 2. Run as a background service (desktop + browser share one instance)

```bash
nalar service start    # daemonizes, writes ~/.local/state/nalar/state.json
nalar service status   # → status: running (pid 12345, http://127.0.0.1:8081/)
nalar service restart  # stop + start, optionally with --port/--auth
nalar service stop     # the ONLY way to stop it — closing the desktop won't
```

`nalar-desktop` is a pure GUI shell: on launch it probes `state.json` for a
running `nalar`; if none is found it shows:

```
error: nalar is not running.
Run `nalar service start` in a terminal first, then re-open the desktop.
```

Smoke tests:

```bash
./scripts/service-lifecycle-smoke.sh   # service start/status/stop cycle
./scripts/desktop-autospawn-smoke.sh   # desktop lifecycle wires to service
./scripts/ci-smoke-test.sh             # boot → /health → clean shutdown
./scripts/crash_handler_smoke.sh       # crash handler / restart path
./scripts/design-mode-smoke.sh         # design-canvas mode against a live server
```

### 3. Configure your LLM provider

On first run an empty config is auto-created — the server still starts
(non-LLM endpoints work), but chat calls fail until you fill it in:

- File: `~/.config/nalar/config.json`
- Or via UI: Settings → Profiles (strict validation — empty `api_key` is
  rejected on save with an error body so you can correct it).
- Fields per profile: `base_url` / `model` / `api_key`, plus `url_style`,
  `notify_on_complete`, `sub_agents`, `retry_delay_ms`, `web_launch_enabled`.
- With `--auth`: `config.json` is ignored — each user's config lives in
  the `users.config_json` DB column (per-user, managed via the same
  Settings UI / API). Seed the first account from the CLI:

```bash
nalar create-admin --email you@example.com --password '…' --name 'You' [--force]
#   --email    required, must contain '@'
#   --password required, min 8 chars
#   --name     optional display name
#   --force    overwrite an existing account with the same email
```

### Per-user isolation — what is scoped, and what is not

With `--auth` on, every user-owned **DB row** and **push channel** belongs
to exactly one user: workspaces (and every child resource via a middleware
choke point on `:workspace_id`), sessions (by id, in the list, and
owner-stamped on create), workers, terminals, and the SSE fan-out. A
foreign id returns **404**, never 403, so one user cannot probe for the
existence of another's ids. `admin` grants **no** cross-user visibility.
Rows created before `--auth` existed carry the `user_system` sentinel and
stay visible to everyone (a local-first upgrade must not make data vanish);
the shared bucket only shrinks. With `--auth` off there is no identity, so
the system user sees everything — the pre-isolation behaviour.

**Not scoped — the filesystem boundary (deferred).** `command`,
`terminal/ws`, `read_file`, `list_directory`, `/api/git/*`,
`/api/files/download`, `/api/skills*` and `/api/memories*` all run as the
**OS user** against caller-supplied paths. Global skills/memories live in
one `~/.config/nalar/skills|memories/` directory per OS account, and local
ones in `{cwd}/.nalar/…` where `cwd` comes from the request — so a second
browser user on the same machine can still read those files by path. This
is a known boundary, not a regression: closing it needs a per-user OS
uid/chroot or a workspace-root allowlist, which is a separate decision.
`tests/functional/skills_memories_boundary_test.py` pins the boundary so a
future change that closes it must update the test and this section. Never
describe the system as "sandboxed" or "multi-tenant".

### 4. CLI + tests

```bash
nalarcli send "hello"                # message is POSITIONAL — no --message flag
nalarcli sessions                   # list sessions
nalarcli messages <session-id>       # read history for one session
nalarcli events                     # tail the SSE stream
nalarcli pr-status [pr] [--path .]   # PR/MR status (alias: `pr`); --json for machine output

zig build test                       # nalarcore unit tests
zig build test:cli && zig build test:tui
cd src/apps/desktop && pnpm run test # frontend (vitest)
pytest tests/functional/             # API functional tests (isolated tmp HOME)
pytest tests/functional_ui/          # Playwright UI tests (needs Chromium)
cd src/apps/android_mobile && ./gradlew test   # Android unit + Robolectric
```

Global `nalarcli` flags: `--server <url>` (default `http://localhost:8081`),
`--session <id>`, `--profile <name>` — also readable from `NALARCLI_SERVER`,
`NALARCLI_SESSION_ID`, `NALARCLI_PROFILE`.

> Android is not in the CI workflow matrix; build and test it locally with the
> checked-in Gradle wrapper.

## See also

- [docs/SPEC.md](docs/SPEC.md) — full project specification (2026-08-06 snapshot; superseded in places by this README)
- [docs/ci.md](docs/ci.md) — CI pipeline layout, caching, troubleshooting
- [docs/agent-tools.md](docs/agent-tools.md) — agent tool catalogue with I/O envelopes
- [docs/hooks.md](docs/hooks.md) — hooks + `examples/hooks/`
- [docs/effect-migration.md](docs/effect-migration.md) — Effect-TS adoption in the Vue app
- [docs/http2.md](docs/http2.md) / [docs/http2-tls.md](docs/http2-tls.md) — HTTP/2 modes
- [docs/tabs.md](docs/tabs.md), [docs/sse-tab-sharing.md](docs/sse-tab-sharing.md) — tabs + SSE
- [src/apps/android_mobile/README.md](src/apps/android_mobile/README.md) — Android client
- [src/modules/nalar_browser/README.md](src/modules/nalar_browser/README.md) — Bun scraping service
- [tests/functional/README.md](tests/functional/README.md) — functional-test harness
  (never deletes real `$HOME`; use ports 8080–8199, never kill 8081)
- [tests/functional_ui/README.md](tests/functional_ui/README.md) — Playwright UI-test harness
- [AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md) — repo conventions for coding agents
