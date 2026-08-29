# `nalar-tui` streaming rendering — design

## Goal

Make `nalar-tui`'s chat stream render the way the Vue frontend renders
chat: tool outputs as compact styled cards (tool name + primary field +
status badge) instead of raw `<tool>...</tool>` envelopes, and assistant
thinking hidden instead of dumped as `<think>...</think>` text.

**Scope also includes:** replacing the input cursor's yellow background
block with a foreground-only caret, so the prompt row matches the rest
of the TUI palette.

This is **rendering only** — no new HTTP endpoints, no new backend
behaviour. The backend already returns everything we need on the
existing `/api/llm/session/:id/messages` endpoint; the TUI just throws
it on screen as raw `content` and the user sees XML soup.

## Current behaviour (problem statement)

Screenshot from a live session:

```
> hai
hai
<think>The user said "hai" — this is a simple greeting. I should respond in a friendly way, matching their language (...
<tool><name>load_memory</name><parameters><query>user preferences language</query><limit>5</limit></parameters><succes
<tool><name>update_activity</name><parameters><thought>[2026-04-15 10:30] session-1787827396630 @ /home/ginwa/.local/s
<think>The user prefers Indonesian language based on the memory. Let me load the full content of that memory to confir...
> mau tanya
mau tanya
<think>The user said "mau tanya" which means "want to ask" in Indonesian. They're indicating they have a question. I s
```

Two problems, both from `App.onMessages` blindly appending
`msg.content` to the viewport as a single unstyled line (see
`src/apps/cli/src/tui/app.zig:175-178`):

1. **Raw `<tool>` envelopes.** Tool result rows arrive with
   `role === "tool"` and `content` wrapped in the `<tool>` envelope
   produced by `tools_wrap_output.zig`. The TUI dumps the envelope
   verbatim — the user sees the XML, not "load_memory ✓".
2. **Raw `<think>...</think>` blocks.** Assistant text frequently
   starts with a thinking block from reasoning models (Anthropic,
   DeepSeek-R1, o1, etc.). The TUI dumps it verbatim — the user sees
   the model's internal monologue instead of just the answer.

## Vue reference: how the desktop app renders this

From `src/apps/desktop/src/components/views/ChatView.vue` + the
`tool_outputs/_shared/ToolCardHeader.vue` + `helpers/stripTags.ts`
family:

- **Assistant text** is run through `stripThinkingTags(content)` which
  drops `<think>...</think>` before rendering. If the only content is
  the thinking block, the message is hidden entirely (or shown as a
  compact "thinking..." chip — see `isThinkingTags`).
- **Tool rows** are parsed by `tryUnwrapToolOutput(content)` into a
  `{name, parameters, data, success, error}` struct, then handed to a
  per-tool component (ReadFile, Bash, Glob, …). Each renders a card
  with:
  - a violet pill containing the tool name (`read_file`)
  - the primary field truncated (`/path/to/file.txt`)
  - a right-meta string (`12L` for read_file, `3 matches` for search)
  - a green ✓ / red ✗ status badge
  - an expandable body (collapsed by default)
- **User messages** are wrapped in a bubble with green-tinted prompt
  affordance.

For the TUI we mirror that contract at the textual level — no mouse
expansion, but the same three rendering tiers (user / assistant /
tool) with the same compact representation.

## Target behaviour

After this change, the same conversation renders as:

```
> hai
 hai
 ▶ load_memory  user preferences language  ✓
 ▶ update_activity  [activity thought...]  ✓
The user prefers Indonesian language based on the memory...
> mau tanya
 mau tanya
The user said "mau tanya" which means "want to ask" in Indonesian...
```

Visible elements per role:

| Role      | Rendered as                                                         |
|-----------|---------------------------------------------------------------------|
| `user`    | `> {content}` in bold green (existing — unchanged)                  |
| `assistant` | Plain text with `<think>...</think>` stripped. Thinking-only turns collapse to a single dim `… thinking …` chip. |
| `tool`    | One header line: `▶ {tool_name}  {primary}  ✓/✗` in dim style; the body is folded away (out of scope for v1 — see below). |

## Wire shape we read

The `SessionMessage` struct in `src/ai_workflow/tui/http_handlers/http_response.zig:245-269` already carries everything:

```zig
pub const SessionMessage = struct {
    id: []const u8,
    role: []const u8,             // "user" | "assistant" | "tool"
    content: []const u8,          // raw, may contain <tool> envelope or <think> block
    tool_name: []const u8,        // e.g. "read_file" for tool rows
    reasoning_content: []const u8,// thinking models' reasoning (separate from content)
    tool_calls_json: []const u8,  // assistant's tool-call args (out of scope v1)
    finish_reason: []const u8,
    // ...
};
```

For the tool primary-field extraction we read `tool_name` and pull
`<data>` from the envelope via a minimal XML walk. We do **not** depend
on `tool_calls_json` (which is on the assistant row, not the tool row)
in v1 — a follow-up PR can join assistant→tool by `tool_call_id` to
render "▶ read_file /foo.txt" when `tool_name` is missing.

## Approach (recommended)

Three pure helpers + one wiring change in `App.onMessages`. No new
dependencies. No new transports. No new files outside
`src/apps/cli/src/tui/` (plus this plan/spec pair).

```
tui/think.zig       stripThinkingTags(text) -> text       (pure, testable)
                    isThinkingOnly(text)     -> bool
tui/tool_envelope.zig tryParseToolEnvelope(content) -> ?ToolEnvelope
                    toolEnvelopePrimary(env) -> ?[]const u8
tui/render_msg.zig  renderMessage(msg, alloc) -> []Line   (pure dispatcher)
App.onMessages      use renderMessage + dedupe by msg.id
```

### Helper 1 — `tui/think.zig`

Mirrors `src/apps/desktop/src/helpers/stripTags.ts:5-80`. Pure
functions, no allocations unless needed.

- `stripThinkingTags(content) -> []const u8` — returns a slice into
  the input with every `<think>...</think>` block removed (including
  the tags themselves) and surrounding whitespace trimmed. When no
  tags are present, returns `content` unchanged.
- `isThinkingOnly(content) -> bool` — true when stripping leaves
  nothing. Used by the assistant branch to decide between rendering
  text vs. a "… thinking …" chip.

Both live alongside their tests in `tui/think.zig` and
`tui/think_test.zig` (split per project convention
`impl and test code should inline one file no need split` — see
`AGENTS.md` rule and plan
`2026-08-24-delete-memory-agent-tool` §Files for the precedent).
Implementation follows a tight inline-test pattern; one file per
helper family.

### Helper 2 — `tui/tool_envelope.zig`

Mirrors `tryUnwrapToolOutput(content)` on the Vue side. Pure
functions, no allocations unless needed for the inner data slice
(the data slice aliases into `content`).

```zig
pub const ToolEnvelope = struct {
    name: []const u8,        // <name>...</name>
    parameters: []const u8,  // raw <parameters>...</parameters> body
    data: []const u8,        // <data>...</data> body ("" when <error>)
    success: bool,           // <success>...</success> == "true"
    error: []const u8,       // <error>...</error> body ("" on success)
};

pub fn tryParseToolEnvelope(content: []const u8) ?ToolEnvelope;
pub fn toolEnvelopePrimary(env: ToolEnvelope) []const u8;
```

`tryParseToolEnvelope` returns `null` when any of `<tool>`,
`<name>`, or `<success>` is missing — that's the "not a tool
envelope" signal, and the caller falls back to plain text render.

`toolEnvelopePrimary` returns the first reasonable primary field per
the table below. When unknown, returns the tool name itself (so the
header is always non-empty).

| Tool name       | Primary field (extracted from `<data>`) |
|-----------------|------------------------------------------|
| `read_file`     | `<path>...</path>`                      |
| `write_file`    | `<path>...</path>`                      |
| `text_replace`  | `<path>...</path>`                      |
| `search`        | `<query>...</query>`                    |
| `glob`          | `<pattern>...</pattern>`                |
| `bash` / `pwsh` | first 60 chars of `<output>` (or first 60 of `<command>` when errored) |
| `*` (fallback)  | tool name                               |

This is intentionally a small whitelist. Per-tool primary extraction
for the remaining ~20 tools is a follow-up — the fallback ("tool
name") is always non-empty, so the header line never breaks.

### Helper 3 — `tui/render_msg.zig`

```zig
pub fn renderMessage(
    allocator: std.mem.Allocator,
    msg: SessionMessageView, // trimmed slice type — see below
) ![]Line;
```

`SessionMessageView` is a small struct defined next to the function so
the renderer doesn't have to depend on `http_response.zig` (which is
backend code, not TUI code). `App.onMessages` populates it from the
parsed JSON.

The dispatcher:
- `role == "user"` → one `Line` of `{ .text = "> " + content, .style = { .fg = green, .bold = true } }`
- `role == "assistant"` →
  - if `isThinkingOnly(content)` → one dim `{ .text = "… thinking …", .style = { .fg = brightBlack } }`
  - else → one or more `Line`s of `{ .text = stripped, .style = {} }` (word-wrap handled by viewport)
- `role == "tool"` →
  - if envelope parses → one header `Line` of
    `{ .text = "▶ " + env.name + "  " + primary + "  ✓/✗", .style = { .fg = magenta, .bold = false } }`
  - else (legacy) → one line of the raw content, dim style

### Wiring change — `App.onMessages`

`src/apps/cli/src/tui/app.zig:152-193` currently appends `content`
verbatim. New behaviour:

- Track `seen_ids: std.StringHashMapUnmanaged(void)` (alloc'd on the
  App, freed in `App.deinit`) instead of `seen_count: usize`. This
  fixes a latent bug: the current code re-appends the entire backlog
  on every poll when `arr.items.len > self.seen_count`, which causes
  the user to see the same tool card three times during a streaming
  burst (matches the screenshot — `<tool><name>load_memory…` shows up
  three times in the user's transcript).
- For each new message id, call `renderMessage(...)` and append the
  resulting `[]Line`s in order.

### Input cursor — background-less caret

`src/apps/cli/src/tui/widgets.zig:215-217` renders the cursor as a
background-fill block:

```zig
if (cx < width) {
    f.set(cx, 0, .{ .char = ' ', .bg = .white });
}
```

On several terminal palettes (iTerm2, macOS Terminal with the "Solarized"
or "Pro" schemes, default GNOME Terminal on Ubuntu 22.04) the white
background renders as a yellow block — the cell SGR `[47m` overlays the
terminal's selection / cursor color and produces a colour the user
explicitly does not want.

Fix: paint the cursor as a foreground-only **bold `|`** character with
no background fill. The caret sits between the typed text and the right
edge; reading the text and the prompt is unaffected. The visible
geometry (one cell wide, never more, never less) stays identical; only
the styling changes.

```zig
if (cx < width) {
    f.set(cx, 0, .{ .char = '|', .fg = .white, .bold = true });
}
```

`Frame.cursor` (the cursor POSITION for the terminal driver) is still
set to `cx` so the OS-level caret blinks at the right cell — that part
of the implementation is orthogonal to the visual styling and stays as
is.

## Non-goals (explicit YAGNI)

- **Expand/collapse for tool bodies.** No TUI key binding exists yet
  for per-message expansion, and a sensible UX needs a focused-pane
  mode (`Tab` → focused card; `Enter` → expand; `Esc` → unfocus) that
  is its own design exercise. v1 folds the body away — the user can
  scroll the desktop app for full content. Header + status badge is
  enough to verify the agent did the work.
- **Per-tool primary extraction beyond the whitelist above.** A
  follow-up PR adds the rest once we have user feedback on which
  primary fields people actually want at a glance.
- **`reasoning_content` rendering.** The backend already returns it
  separately from `content`, and the desktop shows it as a collapsible
  panel. The TUI's equivalent is a separate `… reasoning …` line —
  deferred to a follow-up; v1 still hides `<think>` inline content
  via the stripper.
- **`tool_calls_json` join via `tool_call_id`.** Lets the assistant
  row show the primary field even when `tool_name` is empty. Useful
  but not load-bearing for v1.
- **SSE-driven streaming.** Still poll-based. The existing `sse.zig`
  skeleton is wired but unused; bringing live chunk updates in is its
  own plan (the existing poll already gives near-realtime UX at 500ms
  cadence).

## Tests

Every helper gets behavioural tests **inline** with the implementation
(per project convention `impl and test code should inline one file no
need split` — see `AGENTS.md`). Tests are pure (no HTTP), run under
`zig build test:tui --summary all`. Each test asserts one observable
behaviour and fails closed (the test name spells out the contract, so
a future reader sees the spec without opening a separate file).

Approximate coverage per file:

- `tui/think.zig` — ~6 tests (no-tag passthrough, simple strip, multi
  block, leading/trailing whitespace, thinking-only flag for 3 shapes)
- `tui/tool_envelope.zig` — ~10 tests (valid envelope, missing name,
  missing success, success=false with error, success=true with empty
  data, malformed XML, primary extraction per whitelist entry)
- `tui/render_msg.zig` — ~6 tests (user role renders as `> ...`,
  assistant with thinking stripped, assistant thinking-only renders
  as `… thinking …`, tool card renders as `▶ name primary ✓`,
  tool card with error renders as `▶ name primary ✗`, legacy tool
  falls back to raw content)
- `tui/app.zig` `onMessages` — replace the existing 3 `onMessages`
  tests with 5 that cover dedupe-by-id and the role dispatch.
- `tui/widgets.zig` `Input.render` — add 2 tests asserting the cursor
  cell uses a foreground-only caret (no `bg`, char is `|`, fg is white
  + bold). Existing 5 `Input.*` tests stay green.

## Verification

- `zig build test:tui --summary all` — all green, 0 leak.
- `zig build install:tui` — `zig-out/bin/nalar-tui` builds.
- Manual smoke (with the dev server running on 8081):
  - `nalar-tui --server http://localhost:8081` — chat renders, Enter
    sends a message, Ctrl-C exits cleanly.
  - Type `hai` — observe `▶ load_memory  ...  ✓` then `▶ update_activity  ...  ✓` then the assistant's plain-text reply (no raw `<think>` block visible).
  - Confirm the same `<tool>` envelope does NOT appear three times
    during the streaming burst (regression on the dedupe-by-id fix).

## Risks

1. **Whitespace in assistant content.** Some models emit leading/trailing
   whitespace inside `<think>` blocks that survive stripping. The
   `stripThinkingTags` helper trims the final result; if that's too
   aggressive we lose legitimate leading whitespace in user-quoted
   responses. Mitigation: only trim the OUTER result, not the inner.
2. **Tool envelope malformed mid-stream.** If the LLM streams the tool
   result mid-write and we poll before the envelope is complete,
   `tryParseToolEnvelope` returns `null` and we fall through to the
   legacy raw-content path. Next poll will parse correctly. Visually
   one extra raw-XML line for ~500ms; acceptable.
3. **StringHashMap allocations.** `seen_ids` is `std.StringHashMapUnmanaged`
   with backing allocator = `App.allocator`. Adds one alloc on first
   use, one free on `deinit`. Zero per-message cost beyond the hash
   lookup (~80ns). Negligible.
