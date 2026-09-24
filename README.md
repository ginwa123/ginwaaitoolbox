# ginwaaitoolbox — Nalar

[![CI](https://github.com/ginwa/ginwaaitoolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/ginwa/ginwaaitoolbox/actions/workflows/ci.yml)

**Nalar** is an AI agent workspace. Chat with LLMs that can actually *do things*
(read/write files, search code, browse the web, run routines, manage kanban boards,
draw on a design canvas), all persisted in a local SQLite database and presented
through a Vue web app, native desktop shell, or native Android client.

## What this project is about

Four pillars, one repo:

0. **Android client — native Jetpack Compose** (`android_mobile/`)
   - A standalone Kotlin client for Nalar.
   - The first milestone is a polished login screen; authentication and the
     rest of the mobile experience are intentionally staged for later iterations.
1. **Backend — Zig 0.16 agent runtime** (`src/`)
   - Orchestrates LLM calls (Anthropic, OpenAI-compatible, custom `base_url`)
     with streaming, auto-retry ("unattended mode"), and per-profile config.
   - **50+ agent tools**: file read/write/search/glob, bash, web fetch/search,
     LSP (definition/references/hover/symbols), kanban, design-canvas context,
     `save_memory` / `load_memory` (FTS5), vector semantic search, MCP
     (stdio + HTTP), sub-agents with inherited context, routines/scheduler.
   - Custom HTTP server (per-request arena, `Io.Threaded`) + libcurl-backed
     HTTP client (replaces `std.http`), SQLite via `SqliteBackend`
     (80+ sequential migrations), single global SSE stream
     (`/api/events?channels=...`), transaction support.
2. **Frontend — Vue 3 + TypeScript + Pinia SPA** (`src/apps/desktop/`)
   - Chat sessions, kanban boards (drag-drop, pinned tasks, pagination),
     design canvas (pages/elements, history), file tree, routine views,
     settings, notifications, tabs — all over a REST + SSE API.
   - Built with Vite, tested with Vitest.
3. **Desktop shell — `nalar-desktop`** (`src/apps/desktop_app/`)
   - Native webview wrapper (WebKitGTK 4.1 on Linux, WKWebView on macOS,
     WebView2 on Windows) that embeds the built web app. Pure GUI shell —
     it connects to a running `nalar` service, it doesn't own it.
   - Plus **`nalarcli`** (`src/apps/cli/`) — terminal wrapper around the
     REST API (`send` / `sessions` / `messages` / `events` SSE tail).

Key features at a glance:

- 💬 Chat sessions with tool-calling agent loop, compaction, FTS5 history search
- 📋 Kanban (columns, tasks, reorder, pins, routines per workspace item)
- 🎨 Design canvas (pages, elements, agent-visible via `get_design_context`)
- ⏰ Workspace routines + in-process scheduler (fire every 5 s)
- 🧠 Agent memories (append-only, FTS5) + vector store (semantic search)
- 🔌 MCP servers, LLM profiles, web-launch mode, TLS / HTTP/2 (h2c)
- 🖥️ Service mode (`nalar service start`) shared by desktop + browser + CLI

> Single source of truth for the feature set: [docs/SPEC.md](docs/SPEC.md).

## Tech stack

| Layer | Technology | Notes |
|---|---|---|
| Backend | **Zig 0.16.0** | `build.zig` + `build.zig.zon`; deps: `ruangsql` (sqlite3/openssl), `kabelweb` (HTTP), `helpers` |
| Database | **SQLite** | System lib on Linux; vendored amalgamation elsewhere; 80+ migrations in `src/migrations/` |
| Frontend | **Vue 3 + TS + Pinia** | Vite build, `vue-tsc`, Vitest, Tailwind 4, Monaco editor |
| Desktop | **Native webview** | WebKitGTK / WKWebView / WebView2 shims under `src/apps/desktop_app/platform/` |
| Tests | **Zig + Vitest + pytest** | `zig build test`, `npm run test`, `pytest tests/functional/` (isolated-`$HOME` harness) |

Repo layout:

```
src/
├── ai_workflow/tui/agentic_loop/  # LLM loop + tool dispatch (tools_exec_*.zig)
├── modules/agent/tools/           # 50+ agent tools
├── modules/databases/sqlite/      # SqliteBackend + transactions
├── http_handlers/                 # REST endpoints (thin wrappers)
├── migrations/                    # NNN_name.zig, sequential
├── apps/desktop/                  # Vue 3 SPA
├── apps/desktop_app/              # nalar-desktop webview wrapper
├── apps/cli/                      # nalarcli terminal client
├── service/                       # `nalar service` daemon (POSIX + Win32)
└── main.zig / root.zig / startup.zig
docs/      # SPEC.md, ci.md, tabs.md, hooks.md, http2*.md, plans/
tests/functional/    # API tests (Python harness, isolated HOME)
tests/functional_ui/ # Playwright UI tests
scripts/   # smoke tests, install helpers
packaging/ # linux / macos / windows
```

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| **Zig** | **0.16.0** (`minimum_zig_version`) | `zig version` must print `0.16.0`. Install via `mlugg/setup-zig@v2` in CI or [ziglang.org](https://ziglang.org/download/). |
| **Linux system libs** | — | `sudo apt-get install -y build-essential libssl-dev libsqlite3-dev pkg-config` (Arch: `base-devel openssl sqlite pkgconf`). Linux links system `libsqlite3`. |
| **macOS** | — | Xcode CLT (`xcode-select --install`) + `brew install pkg-config openssl@3` (sqlite via Homebrew keg-only or vendored fallback). |
| **Windows** | — | MSVC Build Tools 2022 + Windows 10 SDK (for `nalar-desktop` C++ shim) and/or vcpkg `sqlite3` — otherwise the vendored SQLite amalgamation is used. |
| **Node + npm** | **Node ^20.19.0 or >=22.12.0** (CI uses Node 24) | Only needed for the frontend / desktop build (`npm ci`, `npm run build`). `package-lock.json` is canonical — Bun is **not** used. |
| **Python** | **3.10+** + `pytest` | Only needed for functional tests (`pip install -r tests/functional/requirements.txt`). Playwright + Chromium only for `tests/functional_ui/`. |

Check yours:

```bash
zig version        # want 0.16.0
node --version     # want v20.19+ / v22.12+
npm --version
python3 --version
```

## Install

```bash
git clone https://github.com/ginwa/ginwaaitoolbox.git
cd ginwaaitoolbox

# 1. Backend binary (native for your OS)
zig build install:linux:system   # Linux  → zig-out/bin/nalar
# macOS / Windows: same command; SQLite comes from the pinned
# `databases` package (ruangsql) — no extra fetch on hosts with
# system SQLite. Without system libs, populate its vendored
# amalgamation first (idempotent, checksum-verified; see the
# ruangsql repo's scripts/fetch-vendor-sqlite3.sh).

# 2. Frontend web app (only if you hack on the UI)
cd src/apps/desktop
npm ci
npm run build          # vue-tsc + vite → dist/, embedded into nalar-desktop

# 3. Desktop shell (embeds the web build above)
cd ../../..
zig build nalar-desktop  # → zig-out/bin/nalar-desktop
```

Useful build commands:

```bash
zig build test            # all backend unit tests
zig build nalar-desktop   # backend + embedded webapp + desktop binary
zig build --help          # all steps (install:*, test:*, functional-test, …)
```

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
```

Examples:

```bash
# Serve the built UI from the same process
./zig-out/bin/nalar --port 8081 --static-dir src/apps/desktop/dist
# → open http://127.0.0.1:8081/app

# Random-port browser mode + self-signed TLS (HTTP/2 via ALPN)
./zig-out/bin/nalar --port 0 --tls-selfsigned

# Frontend dev loop (Vite HMR against a running backend on 8081)
cd src/apps/desktop && npm run dev
```

> ⚠️ Dev-server port convention: the real backend always sits on **8081**.
> Never kill it for experiments — point throwaway instances at **8080**.

### 2. Run as a background service (desktop + browser share one instance)

```bash
nalar service start    # daemonizes, writes ~/.local/state/nalar/state.json
nalar service status   # → status: running (pid 12345, http://127.0.0.1:8081/)
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
  Settings UI / API).

### 4. CLI + tests

```bash
nalarcli send --message "hello"          # chat from the terminal
nalarcli sessions | nalarcli messages    # inspect history
nalarcli events                          # tail the SSE stream

zig build test                           # backend unit tests
cd src/apps/desktop && npm run test      # frontend (vitest)
pytest tests/functional/                 # API functional tests (isolated tmp HOME)
pytest tests/functional_ui/              # Playwright UI tests (needs Chromium)
```

## See also

- [docs/SPEC.md](docs/SPEC.md) — full project specification (what exists, what's pending)
- [docs/ci.md](docs/ci.md) — CI pipeline layout, caching, troubleshooting
- [docs/agent-tools.md](docs/agent-tools.md) — agent tool catalogue
- [docs/hooks.md](docs/hooks.md) — hooks + `examples/hooks/`
- [docs/http2.md](docs/http2.md) / [docs/http2-tls.md](docs/http2-tls.md) — HTTP/2 modes
- [docs/tabs.md](docs/tabs.md), [docs/sse-tab-sharing.md](docs/sse-tab-sharing.md) — tabs + SSE
- [tests/functional/README.md](tests/functional/README.md) — functional-test harness
  (never deletes real `$HOME`; use ports 8080–8199, never kill 8081)
