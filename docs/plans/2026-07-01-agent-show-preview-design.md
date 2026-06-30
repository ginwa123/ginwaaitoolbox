# `show_preview` Agent Tool — Design

> **Status:** Design proposed 2026-07-01. Awaiting user approval before
> implementation plan execution.

## Problem

The agent can already write files, run commands, list skills, browse the
web, and read images from the user — but it has **no direct way to push
visual content to the user's UI mid-turn**. If the agent produces a useful
artifact (a rendered chart, a generated image, a polished markdown
summary, a code snippet, a remote URL preview), the user has to:

1. Wait for the agent to finish its turn.
2. Open `read_file` / `bash` tool output rows.
3. Mentally scroll past several lines of XML envelopes.
4. Hope the relevant content is visible in the tool result row (often it
   isn't, because tool outputs are wrapped in `<tool><data>...</data></tool>`
   envelopes and truncated).

This breaks the "show, don't tell" workflow that the user has when
working with the agent on tasks that have visual outputs (image
generation, design mockups, code diffs, formatted tables).

## Goal

Add a single agent tool, `show_preview`, that lets the agent **push
visual content directly to the user's chat UI in real time**, supporting
images, markdown, code (syntax-highlighted), and plain text. The preview
is rendered inline in the chat history as a first-class component (not a
collapsed XML tool result), survives page reload, and can be called
multiple times per turn.

## Design

### Architecture (3 layers)

```
┌─────────────────────────────────────────────────────────────────┐
│                       Backend (Zig)                             │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │ Tool execution: show_preview.zig                        │   │
│   │  • Parses LLM-provided {content_type, content, ...}    │   │
│   │  • Validates content size (≤ 1 MB)                      │   │
│   │  • Sanitizes UTF-8 (same pattern as on_event_sent.zig) │   │
│   │  • Generates preview_id (pv_<ts>_<rand>)                │   │
│   │  • Calls onEventSendShowPreview (live SSE)             │   │
│   │  • Returns <show_preview>...</show_preview> to LLM     │   │
│   └────────────────────────┬────────────────────────────────┘   │
│                            │                                    │
│   ┌────────────────────────▼────────────────────────────────┐   │
│   │ SSE event: on_event_sent_show_preview.zig               │   │
│   │  • New named event: "show_preview"                       │   │
│   │  • Payload: {preview_id, content_type, content, ...}    │   │
│   │  • Routed via existing event_bus.emit (same as kanban)  │   │
│   └────────────────────────┬────────────────────────────────┘   │
│                            │                                    │
│   ┌────────────────────────▼────────────────────────────────┐   │
│   │ Persistence: existing llm_history path                  │   │
│   │  • wrapToolOutput → saveMessage → llm_history row       │   │
│   │  • tool_name="show_preview" identifies the row         │   │
│   │  • Response XML is the same <show_preview> envelope     │   │
│   │  • On reload: existing /api/sessions/:id/messages GET   │   │
│   │    returns the row → frontend renders it again          │   │
│   └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                │  SSE wire format:
                                │    event: show_preview
                                │    data: {"preview_id":"pv_...",
                                │           "content_type":"markdown",
                                │           "content":"...",
                                │           "session_id":"..."}
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Frontend (Vue/TS)                            │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │ SSE wiring: api/index.ts                                │   │
│   │  • createUnifiedSseConnection's additionalEventTypes:   │   │
│   │    add 'show_preview' to the list                       │   │
│   │  • ShowPreviewEvent interface mirrors Zig payload       │   │
│   └────────────────────────┬────────────────────────────────┘   │
│                            │                                    │
│   ┌────────────────────────▼────────────────────────────────┐   │
│   │ Bus listener: ChatView.vue (or composable)              │   │
│   │  • bus.on('show_preview', (event) => {                 │   │
│   │      previewStore.pushPreview(event)                   │   │
│   │    })                                                   │   │
│   │  • previewStore (small Pinia store, scoped to chat)    │   │
│   │    holds transient "currently previewing" banner        │   │
│   └────────────────────────┬────────────────────────────────┘   │
│                            │                                    │
│   ┌────────────────────────▼────────────────────────────────┐   │
│   │ Renderer: tool_outputs/ShowPreview.vue                  │   │
│   │  • Renders the persistent preview row in tool sequence │   │
│   │  • Receives `content` (inner <data> XML), `parameters` │   │
│   │  • Switch on content_type:                              │   │
│   │     - "markdown" → render via `marked`                  │   │
│   │     - "text"     → <pre> with whitespace preserved      │   │
│   │     - "code"     → <pre><code> with hljs class          │   │
│   │     - "image"    → <img src=data-url-or-http>           │   │
│   │  • Header shows title + content_type + size             │   │
│   │  • Collapsible (like other tool_outputs components)    │   │
│   └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Wire-format protocol contract

Two signals are emitted per `show_preview` call, both carrying the same
payload:

1. **Live SSE event** — `event: show_preview\ndata: {...}\n\n`. Emitted
   *before* the assistant message is finalized so the user's UI can show
   a transient banner immediately. This is the "the agent is showing
   you something now" signal.

2. **Persistent tool result row** — saved to `llm_history` with
   `tool_name='show_preview'` and the standard `<tool><data>...</data></tool>`
   envelope (via the existing `wrapToolOutput`). Re-fetched on page
   reload by the existing `GET /api/sessions/:id/messages` endpoint.

The live event is **transient** (cleared on session change or after N
seconds); the persistent row is **the source of truth** for what was
shown in the chat.

### Tool schema (LLM-facing)

```json
{
  "type": "function",
  "function": {
    "name": "show_preview",
    "description": "Show a visual preview to the user inline in the chat. Use this whenever you produce something the user might want to see at a glance — a rendered chart, a generated image, a polished markdown summary, a code snippet, a URL preview, a formatted table. The preview is rendered as a first-class card in the chat history (not a collapsed XML tool result), survives page reload, and can be called multiple times per turn.",
    "parameters": {
      "type": "object",
      "properties": {
        "content_type": {
          "type": "string",
          "enum": ["markdown", "text", "code", "image"],
          "description": "How the frontend should render the content. 'markdown' renders via marked(). 'text' preserves whitespace. 'code' renders with syntax highlighting (requires 'language'). 'image' expects either a base64 data URL (data:image/png;base64,...) or an http(s) URL."
        },
        "content": {
          "type": "string",
          "description": "The content to display. For markdown: markdown text. For text: plain text. For code: source code. For image: data URL or http(s) URL."
        },
        "title": {
          "type": "string",
          "description": "Optional human-readable title shown above the preview (e.g. 'Generated chart.png', 'Summary of changes')."
        },
        "language": {
          "type": "string",
          "description": "For content_type='code' only: the programming language for syntax highlighting (e.g. 'python', 'zig', 'javascript'). Ignored otherwise."
        },
        "caption": {
          "type": "string",
          "description": "Optional caption shown below the preview (e.g. 'Generated by matplotlib')."
        }
      },
      "required": ["content_type", "content"]
    }
  }
}
```

### Tool execution (LLM-facing output)

After successful execution, the tool returns to the LLM:

```xml
<show_preview>
  <status>shown</status>
  <preview_id>pv_1782850000000_a8b3c</preview_id>
  <content_type>markdown</content_type>
  <content_length>1234</content_length>
</show_preview>
```

On error (e.g., content > 1 MB, invalid content_type, missing required
fields), returns:

```xml
<show_preview>
  <error>content exceeds 1 MB limit (got 5.2 MB); consider summarizing or splitting</error>
</show_preview>
```

The error path sets `success=false` in the outer tool envelope so the
LLM can see the failure and retry with smaller content.

### SSE event payload

```json
{
  "preview_id": "pv_1782850000000_a8b3c",
  "session_id": "session_xyz",
  "content_type": "markdown",
  "content": "# Hello\n\nThis is the content.",
  "title": "Summary",
  "language": null,
  "caption": null,
  "tool_call_id": "call_019f..."
}
```

### Persistence model

**No new DB schema.** The existing `llm_history` table already stores
tool result rows with `tool_name` and `response_content` (XML envelope).
The `show_preview` tool reuses this path:

```
llm_history row:
  role           = "tool"
  tool_name      = "show_preview"
  tool_call_id   = "call_019f..."  (links to the assistant message)
  response_content = "<tool><name>show_preview</name>
                      <parameters>{...}</parameters>
                      <success>true</success>
                      <data><show_preview>
                        <status>shown</status>
                        <preview_id>pv_...</preview_id>
                        <content_type>markdown</content_type>
                        <content_length>1234</content_length>
                      </show_preview></data></tool>"
```

On page reload, the existing `loadChatHistory` REST endpoint returns
this row, the frontend's `Message` interface picks up `tool_name='show_preview'`,
and the `<ShowPreview>` component renders the same preview again.

### Multi-preview per turn

The LLM may call `show_preview` multiple times in a single turn
(showing 3 images, then a summary markdown). Each call is a **separate
tool result row** in the tool sequence, rendered inline in the chat.
No special multi-preview UI is needed — each row stands alone.

### Content size cap

Hard cap at **1 MB** for `content` (per call). Reasoning:
- Base64 image at 1 MB ≈ 750 KB binary (fits a typical screenshot)
- Markdown at 1 MB ≈ 250-500 KB of formatted text (a long doc)
- Anything larger should be split or summarized by the agent

If exceeded, the tool returns an error to the LLM (LLM can retry with
smaller content). The 1 MB cap is **not** configurable in v1 (YAGNI).

### Frontend layout

The preview renders as a tool sequence row, **identical in shape** to
`<KanbanList>` and `<NalarBrowser>`:

```
┌─────────────────────────────────────────────────────────┐
│ show_preview  ✓  markdown · 1.2 KB                  [+] │
├─────────────────────────────────────────────────────────┤
│ Title (if set)                                          │
│                                                         │
│ [rendered markdown / text / code / image]               │
│                                                         │
│ Caption (if set)                                        │
└─────────────────────────────────────────────────────────┘
```

The transient banner (driven by live SSE) appears briefly at the top
of the chat: *"Previewing: Summary"* — auto-dismisses after 5 seconds
or when the next preview is shown.

### Why this design (vs. alternatives considered)

**Alternative A: Inline in the assistant message text (not a tool
result).**
- Would require injecting preview tokens into the LLM's content stream.
- Breaks the streaming protocol (the assistant is still mid-generation).
- Frontend would need to parse preview tokens from partial content.
- **Rejected** because: too much protocol churn, breaks streaming.

**Alternative B: Separate side panel / floating overlay.**
- Familiar UX (VSCode's preview pane) but adds a new layout region.
- Hidden state when the user isn't looking at it.
- More complex layout coordination with the kanban panel.
- **Rejected for v1**: inline rendering is simpler and matches existing
  tool result UX. Side panel can be added as a future evolution.

**Alternative C: New `previews` table with FK to `llm_history`.**
- Allows rich queries (list all previews for a session, paginate).
- Adds DB migration complexity for a feature that fits existing schema.
- **Rejected**: the existing tool-result envelope is sufficient. The
  `tool_name='show_preview'` predicate on `llm_history` already gives
  us the "all previews for a session" query if needed later.

### What is OUT of scope for v1 (YAGNI)

- Dismiss button on the preview (user can collapse the row instead).
- Side panel / floating preview window.
- Carousel / multi-preview UI in a single row.
- Editable previews (Markdown editor, image cropping).
- Copy-to-clipboard buttons (the markdown `marked` output already supports
  selection + Ctrl+C).
- Persistent previews table (reusing `llm_history` is sufficient).
- Configurable size cap.
- New SSE event types for `clear_preview` / `update_preview`.
- Preview acceptance feedback (e.g. "user accepted the change").

## Open questions (for user confirmation)

1. **Inline (recommended) vs. side panel vs. both?**
   Recommendation: inline. Lower risk, matches existing UX.

2. **Should the transient banner be shown, or just the persistent
   row?**
   Recommendation: both — banner gives immediate feedback during a live
   turn, persistent row is the canonical record.

3. **Should previews have an "open in new window/tab" action?**
   Recommendation: not for v1 (matches YAGNI). Future evolution.

4. **Max content size — 1 MB?**
   Recommendation: 1 MB hard cap, returns error to LLM if exceeded.

5. **Any other content types to support (HTML, JSON, PDF)?**
   Recommendation: not for v1. Adding `content_type` enum variants later
   is non-breaking.