# `pabrikcli` — native Zig CLI for the pabrik HTTP API

Wraps the backend's REST API from the terminal. Built with the same
libcurl-backed `kabelweb.client` module the rest of the project
uses, so libcurl paths are reused (no duplicate `-Dcurl-prefix` /
`-Dcurl-vcpkg-root` wiring).

## `pabrik-tui` — interactive chat TUI

Alongside `pabrikcli`, this package ships **`pabrik-tui`**: a
Claude-Code-style interactive chat client powered by a from-scratch
Bubble-Tea-inspired `tui` module (`src/apps/cli/src/tui/`).

| Step | Command |
|---|---|
| Build & install | `zig build install:tui` → `zig-out/bin/pabrik-tui` |
| Run | `zig build run:tui -- [flags]` |
| Test | `zig build test:tui --summary all` |

```bash
pabrik-tui --server http://localhost:8081            # new session
pabrik-tui --session session-1724580000000           # resume a session
```

Keys: **Enter** sends, **Ctrl-C / Ctrl-D** quits, **↑/↓** input
history. The status bar shows the active session id; on exit the
session id is printed so it can be resumed with `--session`.

### Architecture (the `tui` module)

```
src/apps/cli/src/tui/
├── root.zig        # public re-exports
├── program.zig     # Program(Model) event loop: raw mode + alt-screen + frame diffing
├── terminal.zig    # termios raw mode, TIOCGWINSZ size, tty detection
├── key.zig         # key decoder (runes, arrows, Ctrl-*, escape seqs)
├── frame.zig       # Frame/Cell grid + minimal-diff renderer
├── style.zig       # ANSI SGR helpers (bold/dim/fg/bg)
├── color.zig       # 16-color palette
├── msg.zig         # Msg union + Cmd side-effects
├── widgets.zig     # Viewport, Input (history), Spinner, StatusBar
├── app.zig         # chat Model: send/poll state machine
├── transport.zig   # HTTP glue over kabelweb.client
└── sse.zig         # SSE frame parser (for the streaming follow-up)
```

The pattern is Bubble Tea's: your model implements
`update(Msg) -> Cmd` and `view(alloc, w, h) -> Frame`; `Program.run()`
drives raw mode, key decoding, ticks, and paints only changed cells.

## Build wiring

The CLI is integrated into the **parent** `build.zig` (not a
standalone `build.zig` here). Three entries:

| Step | Command |
|---|---|
| Build & install | `zig build install:cli` → `zig-out/bin/pabrikcli` |
| Run | `zig build run:cli -- [args]` |
| Test | `zig build test:cli --summary all` |

The parent `build:all` step also builds the CLI (alongside the
service binary + pabrik-desktop), so a plain `zig build` produces
all three binaries.

## Subcommands

| Verb | Endpoint | Behaviour |
|---|---|---|
| `send <msg>` | POST `/api/llm/session` | Queue a message; creates a fresh `session-<unix-ms>` if none is given. |
| `sessions` | GET `/api/llm/session?limit=N` | List recent sessions. |
| `messages <id>` | GET `/api/llm/session/<id>/messages` | List messages in a session. |
| `events` | GET `/api/events?channels=…` | Long-lived SSE tail (uses `kabelweb.client.openStream`). |
| `pr-status [<pr>]` | GET `/api/git/pr/status` | Show PR open/merged/closed status (`gh pr view` wrapper). Alias: `pr`. |
| `help` | — | Print usage. |

Run `pabrikcli help` for the full flag list.

## Config

| Source | Server | Session | Profile |
|---|---|---|---|
| Flag | `--server <url>` | `--session <id>` | `--profile <name>` |
| Env | `PABRIKCLI_SERVER` | `PABRIKCLI_SESSION_ID` | `PABRIKCLI_PROFILE` |
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
│   ├── root.zig                # package re-exports (config, client, format, commands, kabelweb.client)
│   ├── config.zig              # server/session/profile resolution (flags → env → defaults)
│   ├── client.zig              # HTTP helpers over kabelweb.client
│   ├── format.zig              # JSON formatter (placeholder for future use)
│   ├── *_test.zig              # unit tests
│   └── commands/
│       ├── root.zig            # parseCommand + dispatch + parseXxxArgs
│       ├── send.zig            # POST /api/llm/session
│       ├── sessions.zig        # GET /api/llm/session
│       ├── messages.zig        # GET /api/llm/session/<id>/messages
│       ├── events.zig          # GET /api/events (SSE tail)
│       ├── pr_status.zig       # GET /api/git/pr/status (open/merged/closed)
│       └── *_test.zig          # placeholder tests; real tests land when the live endpoint is wired
```
