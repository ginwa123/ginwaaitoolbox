# `pabrik-tui` — a Claude-Code-style TUI for pabrik (design)

**Status:** design (pre-implementation)
**Branch:** `worktree/cli-tui`
**Author:** agent (ginwaaitoolbox)

## 1. Motivation

The existing `pabrikcli` (`src/apps/cli`) is a one-shot JSON-over-HTTP client
suitable for scripting but not for an interactive LLM session:

- `send` blocks once and prints the response (or nothing if you don't poll
  `messages` afterwards).
- There is no streaming UX (the SSE `/api/events` channel exists but the
  CLI just prints raw SSE frames).
- No persistent input box, no scrollback, no spinner, no session affinity.

`pabrik-tui` is the interactive counterpart:

- A full-screen terminal chat with **streaming** model output.
- A reusable `tui` module (Bubble Tea-shaped: `Model.update(msg) ->
  Model`, `Model.view() -> Frame`) that other future CLIs can compose.

It talks to the existing backend over the same `/api/llm/session`,
`/api/llm/session/:id/messages`, and `/api/events` endpoints — no server
changes are required.

## 2. Scope

### 2.1 In scope (this PR)

- A new `tui` module at `src/apps/cli/src/tui/` that any caller can
  `@import("tui")` against.
- A new executable `pabrik-tui` (wired into the root `build.zig` next to
  the existing `pabrikcli`).
- Interactive mode: streaming chat with a persistent input box,
  scrollback, spinner, status bar, Ctrl-C to quit.
- Two transport modes:
  1. **Live SSE** — uses the existing `/api/events?channels=llm,queue`
     stream to pull streaming assistant deltas as they arrive.
  2. **Poll fallback** — when SSE is unavailable (proxy, etc.), poll
     `/api/llm/session/:id/messages` every 500 ms and diff against the
     last seen `created_at`.

### 2.2 Out of scope (follow-ups)

- Persistent multi-session UI (a session picker). v1 is single-session
  per invocation; the session id is auto-created and printed on exit.
- Slash-commands (e.g. `/profile`, `/clear`). v1 ships with Ctrl-C to
  quit and Enter to send.
- Mouse input, syntax highlighting, code-block rendering. v1 renders
  text as plain monospace with word-wrap.
- A reusable `tui` widget library on top of the framework; v1 ships
  only the four widgets it needs (viewport, input, spinner, status).

## 3. Architecture

### 3.1 The `tui` module

Lives at `src/apps/cli/src/tui/`. Public surface:

```
tui
├── Program          — top-level event loop driver
├── Model            — user-defined state (per app)
├── Msg              — discriminated union of input / output messages
├── Viewport         — scrollable buffer of styled rows
├── Input            — single-line input with cursor + history
├── Spinner          — animated spinner using a TickMsg
├── StatusBar        — fixed-height status line
├── Style            — ANSI SGR helpers (bold, fg color, reset)
├── Key              — input event (Rune, Backspace, Enter, Ctrl-C, ...)
├── Resize           — terminal size change event
├── TickMsg          — periodic "wake up" message
├── Frame            — view() output: a 2-D cell grid
└── terminal         — raw-mode + alt-screen + ioctl winsize + key reader
```

Inspired by [Bubble Tea](https://github.com/charmbracelet/bubbletea) but
written from scratch in Zig, no Go dependencies, no curses dependency.

### 3.2 The Bubble Tea pattern, in Zig

```zig
const Model = struct {
    chat: ChatModel, // user's app-specific state

    pub fn init(allocator: std.mem.Allocator) !Model { ... }
    pub fn update(self: *Model, msg: Msg) !void { ... }
    pub fn view(self: *const Model, w: u16, h: u16) Frame { ... }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    var model = try Model.init(allocator);
    var program: tui.Program(Model) = .init(&model, allocator, io);
    try program.run(); // blocks until Ctrl-C / quit
}
```

- `Program.run()` owns the event loop:
  1. Switch stdin to raw mode.
  2. Enter alt-screen (`\x1b[?1049h`), hide cursor
     (`\x1b[?25l`).
  3. Loop:
     - Pull the next `Msg` from a non-blocking poll of (a) stdin keys,
       (b) a `TickMsg` timer driven by `io.futexWaitTimeout`, (c) any
       user-emitted messages via `program.send(Msg)`.
     - Call `model.update(msg)`.
     - If `model.view(...)` produced a new `Frame`, diff it against the
       previously rendered frame and emit only the changed cells
       (double-buffered).
  4. On exit: show cursor, leave alt-screen (`\x1b[?1049l`), restore
     cooked terminal mode.

### 3.3 Frame diffing

The terminal is the bottleneck. Naive full-screen redraws at 60 Hz are
acceptable for short chats but wasteful. v1 does a simple per-cell
diff:

```
Frame = struct {
    width: u16,
    height: u16,
    cells: []Cell,           // row-major, len == width * height
    cursor: ?Cursor = null,  // optional cursor position
};

Cell = struct {
    char: u21,              // Unicode scalar
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
};
```

`Program.run()` keeps two frames (`prev`, `next`). For each cell at
`(x, y)` it compares `prev.cells[y*w + x]` against `next.cells[y*w + x]`
and emits:

- `\x1b[<row>;<col>H` (move cursor) only when needed.
- `\x1b[<n>m` (SGR) only when the style changed since the last cell.
- The UTF-8 encoding of `next.cells[i].char`.

The first draw is always a full repaint (`\x1b[2J\x1b[H`).

### 3.4 The `tui.terminal` module

Owns the raw-mode state machine. Pseudocode:

```zig
const terminal = struct {
    pub fn enterRawMode() !RawMode { ... }     // saves + sets termios
    pub fn leaveRawMode(rm: RawMode) void { ... }
    pub fn size() !Size { ... }                // ioctl TIOCGWINSZ
    pub fn readKey(allocator) !?Key { ... }    // blocking stdin read, parses escape seqs
    pub fn writeAll(io, bytes) !void { ... }   // stdout write + flush
};
```

- Raw-mode setup mirrors the conventions of `stty raw -echo` but uses
  `std.posix.tcgetattr` / `std.posix.tcsetattr` directly so the
  restoration is exact.
- Key parsing supports: ASCII runes, `\x1b` escape sequences (Arrow
  keys, Home/End, Delete, Page Up/Down, F1–F12), Backspace (0x7F and
  0x08), Ctrl-C (0x03), Ctrl-D (0x04), Ctrl-U (0x15), Ctrl-W (0x17),
  Ctrl-L (0x0C), Enter (0x0D / 0x0A), Tab (0x09), Shift-Tab.
- `size()` uses `std.c.ioctl(STDIN_FILENO, T.IOCGWINSZ, ...)` with
  `T = if (native_os == .linux) std.os.linux.T else std.c.T`.

### 3.5 The `tui.Style` module

ANSI SGR helpers:

```
Style.bold("hello")       -> "\x1b[1mhello\x1b[0m"
Style.fg(.red, "alert")   -> "\x1b[31malert\x1b[0m"
Style.bg(.blue, "hi")     -> "\x1b[44mhi\x1b[0m"
Style.dim("...")          -> "\x1b[2m...\x1b[0m"
Style.reset()             -> "\x1b[0m"
```

Color palette:

- 16 standard ANSI colors (`Color.black`, `.red`, `.green`, …,
  `.brightWhite`).
- 256-color / truecolor deferred (escape sequences supported in the
  helper, but no widgets consume them yet).

### 3.6 The widgets

| Widget       | Responsibility                                    | State                                   |
|--------------|---------------------------------------------------|-----------------------------------------|
| `Viewport`   | Scrollable buffer of styled `Line`s               | `lines: ArrayList(Line)`, `offset: usize` |
| `Input`      | Single-line input with cursor + history (↑/↓)     | `buf: ArrayList(u8)`, `cursor: usize`, `history`, `hist_idx` |
| `Spinner`    | Animated "thinking…" indicator driven by TickMsg  | `frame: usize`, `label: []const u8`     |
| `StatusBar`  | Fixed-height footer (mode, tokens, session)       | `text: []const u8`                      |

Each widget exposes:

```
fn render(self: *const Self, w: u16) Frame
fn update(self: *Self, msg: Msg) !bool   // returns true if redraw needed
fn handleKey(self: *Self, k: Key) !bool // returns true if consumed
```

### 3.7 The chat model (`pabrik_tui.App`)

```
App = struct {
    allocator: Allocator,
    io: Io,
    cfg: Config,

    viewport: Viewport,
    input: Input,
    spinner: Spinner,
    status: StatusBar,

    session_id: ?[]u8,
    is_streaming: bool,
    last_seen_msg_count: usize,
    stream: ?ResponseStream, // open SSE stream while streaming

    // HTTP
    http_client: custom_http_client.Client,

    pub fn init(...) !App
    pub fn update(self: *App, msg: Msg) !?Cmd
    pub fn view(self: *const App, w: u16, h: u16) Frame
};
```

Layout:

```
┌─ viewport (h-3 rows, scrollable) ────────────┐
│  > hi                                        │
│  Hello! How can I help?                      │
│  > write a fib fn                            │
│  Thinking... ⠋                              │
├─ input (1 row, wraps) ───────────────────────┤
│ █                                            │
├─ status (1 row) ─────────────────────────────┤
│ session-12345 | streaming | 0/8k tokens      │
└──────────────────────────────────────────────┘
```

Commands (`Cmd` = `union(enum) { send_msg: []const u8, poll_messages:
void, tick: u64 }`) are returned by `update` and executed by the
program via:

- `send_msg` → POST `/api/llm/session`, sets `is_streaming = true`,
  opens an SSE stream on `/api/events?channels=llm,queue`.
- `poll_messages` → GET `/api/llm/session/:id/messages`, diffs against
  the cached copy, appends new assistant chunks to the viewport.
- `tick` → reschedule a `TickMsg` after N ms (drives the spinner).

### 3.8 SSE wire shape

The backend already emits SSE on `/api/events?channels=llm,queue` (see
`src/ai_workflow/tui/http_handlers/unified_events_sse.zig`). The TUI
filters for `event: llm_history` and `event: queue` actions and applies
them to the viewport:

- `llm_history` with `action: "updated"` / `action: "created"` →
  fetch the full message row, append to viewport if it belongs to the
  current session and was created after `last_seen_msg_count`.
- `queue` with `action: "drained"` → set `is_streaming = false`, close
  the SSE stream, schedule a final GET to grab any final messages.

If the user opts out of SSE via `--no-sse`, the program polls
`/api/llm/session/:id/messages` every 500 ms instead (driven by a
`TickMsg`).

### 3.9 Config

Same flag surface as `pabrikcli`:

| Flag             | Env                  | Default                       |
|------------------|----------------------|-------------------------------|
| `--server`       | `PABRIKCLI_SERVER`    | `http://localhost:8081`       |
| `--session`      | `PABRIKCLI_SESSION_ID`| (auto-create)                 |
| `--profile`      | `PABRIKCLI_PROFILE`   | (server default)              |
| `--no-sse`       | —                    | SSE on                        |
| `--cwd`          | `PABRIKCLI_CWD`       | `$HOME`                       |

(Same env names as `pabrikcli` for parity; one config struct in the
`cli` module is shared between both binaries.)

## 4. Build wiring

Three additions to the root `build.zig` (mirroring the existing
`pabrikcli` block):

1. **Module.** A new `b.addModule("tui", ...)` rooted at
   `src/apps/cli/src/tui/root.zig`. The `tui` module re-exports its
   submodules; the `cli` module adds an import for `tui`.
2. **Executable.** A new `b.addExecutable` named `pabrik-tui`, root
   `src/apps/cli/src/tui_main.zig`, imports: `tui`, `cli`,
   `custom_http_client`, `helpers`. Same libc / system libcurl
   treatment as `pabrikcli`.
3. **Steps.** `run:tui`, `install:tui`, `test:tui` — each mirrors the
   `run:cli` / `install:cli` / `test:cli` pattern.

The `cli` module (existing `b.addModule("cli")`) gains
`cli.addImport("tui", tui_mod)` so `tui_main.zig` can do
`@import("cli").tui` (or `@import("tui")` directly via the executable
imports list — both paths work; we pick the direct path for clarity).

## 5. Tests

| Test                                                      | Where                          | Coverage                                      |
|-----------------------------------------------------------|--------------------------------|-----------------------------------------------|
| `terminal.parseKey: ascii runes`                         | `tui/terminal_test.zig`        | "a", "Z", "5" → `Key{ .rune = ... }`           |
| `terminal.parseKey: backspace + ctrl-c`                  | `tui/terminal_test.zig`        | 0x7F, 0x08, 0x03                                |
| `terminal.parseKey: arrow keys`                           | `tui/terminal_test.zig`        | `"\x1b[A"` → `Key{ .arrow = .up }`            |
| `Style.bold / fg / bg`                                   | `tui/style_test.zig`           | round-trip the SGR strings                     |
| `Frame.diff: identical frames → no writes`               | `tui/frame_diff_test.zig`      | empty byte stream                              |
| `Frame.diff: single cell change → 1 move + 1 rune`       | `tui/frame_diff_test.zig`      | minimal write                                  |
| `Input.update: backspace deletes char before cursor`     | `tui/input_test.zig`           | state machine                                  |
| `Input.update: arrow-up recalls last history entry`      | `tui/input_test.zig`           | state machine                                  |
| `Viewport.render: scrolls when content > height`         | `tui/viewport_test.zig`        | offset behaviour                               |
| `App.update: Enter in input → SendMsg cmd`               | `tui/app_test.zig`             | dispatches correctly                           |
| `App.update: LlmHistoryEvent appends to viewport`        | `tui/app_test.zig`             | wire-shape mock                                |

All tests are inline (`*_test.zig`) per project convention; no static
fixtures needed.

## 6. Risks and mitigations

| Risk                                                                 | Mitigation                                                                 |
|----------------------------------------------------------------------|----------------------------------------------------------------------------|
| Terminal state corrupted if process crashes mid-render               | `Program.run()` is wrapped in a `defer leaveRawMode()`; Ctrl-C handler returns a synthetic `Quit` msg that always runs cleanup |
| Raw-mode setup fails (no tty, e.g. CI logs)                          | Detect non-tty stdin and print a friendly error + non-zero exit; never crash |
| SSE connection drops mid-stream                                      | App catches `Error.ConnectionClosed` and falls back to polling for the rest of the session |
| Frame diffing O(n²) for very long chats                              | Cap viewport to last 10_000 lines; full history scrolls out of memory only on demand (not in v1; v1 keeps everything) |
| Backwards-incompatible SGR codes break older terminals               | Use only `[1m` (bold), `[2m` (dim), `[0m` (reset), and the 8-color codes — all in the VT100 spec |
| `std.c.ioctl` has C varargs — Zig wrapper might fight us             | Use `std.os.linux.ioctl` on Linux (raw syscall) and `std.c.ioctl` via varargs on macOS; both paths have precedent in the project (`std.os.linux.ioctl` returns `usize`) |

## 7. Open questions

- Should the `tui` module live at `src/apps/cli/src/tui/` (per user
  request) or eventually graduate to `src/modules/tui/`? For v1 we keep
  it under `cli` and decide in a follow-up based on whether other
  consumers (e.g. a Rust-side CLI) emerge.
- Should the TUI use line-buffered mode (one key per read) or
  raw-mode? Raw mode is the right answer for snappy input but is more
  code. v1 ships raw mode.

## 8. Out-of-band follow-ups

- A `pabrik-tui --resume` flag that loads a previous session by id and
  scrolls back through its message history. Requires a `--limit` flag
  passed to `GET /api/llm/session/:id/messages`.
- Slash-commands (`/profile alpha`, `/clear`, `/help`).
- Truecolor SGR escapes once we've surveyed the target terminals.
- A reusable `tui/widgets/` split if the widget set grows.
