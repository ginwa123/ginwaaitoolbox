# `nalarcli` — native Zig CLI for the nalar HTTP API

Wraps the backend's REST API from the terminal. Built with the same
libcurl-backed `custom_http_client` module the rest of the project
uses, so libcurl paths are reused (no duplicate `-Dcurl-prefix` /
`-Dcurl-vcpkg-root` wiring).

## Build wiring

The CLI is integrated into the **parent** `build.zig` (not a
standalone `build.zig` here). Three entries:

| Step | Command |
|---|---|
| Build & install | `zig build install:cli` → `zig-out/bin/nalarcli` |
| Run | `zig build run:cli -- [args]` |
| Test | `zig build test:cli --summary all` |

The parent `build:all` step also builds the CLI (alongside the
service binary + nalar-desktop), so a plain `zig build` produces
all three binaries.

## Subcommands

| Verb | Endpoint | Behaviour |
|---|---|---|
| `send <msg>` | POST `/api/llm/session` | Queue a message; creates a fresh `session-<unix-ms>` if none is given. |
| `sessions` | GET `/api/llm/session?limit=N` | List recent sessions. |
| `messages <id>` | GET `/api/llm/session/<id>/messages` | List messages in a session. |
| `events` | GET `/api/events?channels=…` | Long-lived SSE tail (uses `custom_http_client.openStream`). |
| `help` | — | Print usage. |

Run `nalarcli help` for the full flag list.

## Config

| Source | Server | Session | Profile |
|---|---|---|---|
| Flag | `--server <url>` | `--session <id>` | `--profile <name>` |
| Env | `NALARCLI_SERVER` | `NALARCLI_SESSION_ID` | `NALARCLI_PROFILE` |
| Default | `http://localhost:8081` | (auto-create per `send`) | (server's default) |

Resolution order: flags → env → defaults.

## Cross-platform

| Platform | libcurl | Verified |
|---|---|---|
| Linux   | system libcurl via `/usr/include` | ✅ `zig build install:cli` succeeds |
| macOS   | Homebrew keg at `$(brew --prefix curl)/{include,lib}` | ✅ Zig compiles; linker fails because this host has no Homebrew (pre-existing project-wide) |
| Windows | vcpkg at `C:/vcpkg/installed/x86-windows/{include,lib}` | ✅ Zig compiles; linker fails because this host has no vcpkg (pre-existing project-wide) |

The Zig code itself compiles cleanly for all three targets — the
linker is the only step that needs the system libcurl.

## Layout

```
src/apps/cli/
├── README.md                   # this file
├── src/
│   ├── main.zig                # entry point: argv → config → dispatch
│   ├── root.zig                # package re-exports (config, client, format, commands, custom_http_client)
│   ├── config.zig              # server/session/profile resolution (flags → env → defaults)
│   ├── client.zig              # HTTP helpers over custom_http_client
│   ├── format.zig              # JSON formatter (placeholder for future use)
│   ├── *_test.zig              # unit tests
│   └── commands/
│       ├── root.zig            # parseCommand + dispatch + parseXxxArgs
│       ├── send.zig            # POST /api/llm/session
│       ├── sessions.zig        # GET /api/llm/session
│       ├── messages.zig        # GET /api/llm/session/<id>/messages
│       ├── events.zig          # GET /api/events (SSE tail)
│       └── *_test.zig          # placeholder tests; real tests land when the live endpoint is wired
```
