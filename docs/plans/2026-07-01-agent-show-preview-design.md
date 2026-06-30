# `show_preview` Agent Tool — Design

> **Status:** Design revised 2026-07-01 per user feedback:
> 1. **No new SSE event** — use the standard `llm_full` SSE event (which
>    already carries tool results). No custom event type, no bus listener,
>    no Pinia banner store.
> 2. **Side panel** instead of inline tool-result row.

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
is rendered in a dedicated **side panel** adjacent to ChatView, survives
page reload (via the existing `llm_history` persistence), and can be
called multiple times per turn (each call adds a tab to the panel).

## Design

### Architecture (2 layers — simpler than v1)

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
│   │  • Returns <show_preview>...</show_preview> XML to LLM  │   │
│   └────────────────────────┬────────────────────────────────┘   │
│                            │                                    │
│   ┌────────────────────────▼────────────────────────────────┐   │
│   │ Persistence: existing llm_history path                  │   │
│   │  • wrapToolOutput → saveMessage → llm_history row       │   │
│   │  • tool_name="show_preview" identifies the row         │   │
│   │  • Response XML is the same <show_preview> envelope     │   │
│   │  • Standard SSE event (llm_full) carries the row data  │   │
│   └────────────────────────┬────────────────────────────────┘   │
│                            │                                    │
│   ┌────────────────────────▼────────────────────────────────┐   │
│   │ Existing onEventSendLLMHistory (no changes)            │   │
│   │  • Emits llm_full with tool_call_id + tool_name + data │   │
│   │  • Frontend already handles this for every other tool  │   │
│   └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                │  SSE wire format (standard):
                                │    event: llm_full
                                │    data: {"content":"<tool>...</tool>",
                                │           "tool_name":"show_preview",
                                │           "tool_call_id":"call_..."}
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Frontend (Vue/TS)                            │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │ ChatView.vue                                            │   │
│   │  • Already receives llm_full events → updates messages │   │
│   │  • Existing message filter: msg.tool_name === '...'    │   │
│   │  • Adds new computed: showPreviewMessages              │   │
│   │      = messages.filter(m => m.tool_name === 'show_preview')│
│   │  • Mounts <PreviewSidePanel> as a sibling              │   │
│   │      to the messages wrapper (right side of chat)      │   │
│   └────────────────────────┬────────────────────────────────┘   │
│                            │                                    │
│   ┌────────────────────────▼────────────────────────────────┐   │
│   │ Renderer: PreviewSidePanel.vue                          │   │
│   │  • Receives `previews` (array of tool-result messages) │   │
│   │  • Collapsible (chevron button)                        │   │
│   │  • Active preview rendered in main area                 │   │
│   │    - markdown → marked()                                │   │
│   │    - text     → <pre> whitespace preserved              │   │
│   │    - code     → <pre><code class="language-X">         │   │
│   │    - image    → <img src=data-url-or-http>              │   │
│   │  • Thumbnail strip / tabs for switching between        │   │
│   │    previews (when multiple exist)                       │   │
│   │  • Dismiss button (closes the panel)                   │   │
│   │  • Empty state when no previews                        │   │
│   └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Wire-format protocol contract — no new event

The `show_preview` tool reuses the **existing `llm_full` SSE event** that
every other tool already produces. No new event type is registered, no
new bus listener is wired up.

```jsonc
// Standard llm_full payload (same shape as every other tool's result)
{
  "session_id": "...",
  "tool_name": "show_preview",      // ← the discriminator the frontend uses
  "tool_call_id": "call_...",
  "content": "<tool><name>show_preview</name>...",
  ...
}
```

The frontend's existing `messages` array picks up the row via the same
`messages.value = [..., newToolMsg]` path that every other tool result
uses today. The new `<PreviewSidePanel>` component is a derived view of
those rows.

### Tool schema (LLM-facing)

```json
{
  "type": "function",
  "function": {
    "name": "show_preview",
    "description": "Show a visual preview to the user in the side panel of the chat. Use this whenever you produce something the user might want to see at a glance — a rendered chart, a generated image, a polished markdown summary, a code snippet, a URL preview, a formatted table. The preview is rendered as a first-class card in the side panel, survives page reload, and can be called multiple times per turn (each call adds a tab to the panel).",
    "parameters": {
      "type": "object",
      "properties": {
        "content_type": {
          "type": "string",
          "enum": ["markdown", "text", "code", "image"],
          "description": "How the side panel should render the content. 'markdown' renders via marked(). 'text' preserves whitespace. 'code' renders with syntax highlighting (requires 'language'). 'image' expects either a base64 data URL ('data:image/png;base64,...') or an http(s) URL."
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
LLM sees the failure and retries with smaller content.

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
                      <parameters>{"content_type":"markdown","content":"..."}</parameters>
                      <success>true</success>
                      <data><show_preview>
                        <status>shown</status>
                        <preview_id>pv_...</preview_id>
                        <content_type>markdown</content_type>
                        <content_length>1234</content_length>
                      </show_preview></data></tool>"
```

On page reload, the existing `loadChatHistory` REST endpoint returns
these rows; the frontend's existing message pipeline populates
`messages`; `<PreviewSidePanel>` filters `messages` by
`tool_name === 'show_preview'` and renders them in the side panel.

The `parameters` field carries the full `content` + `title` + `language`
+ `caption` (the inner `<data>` envelope only carries the length for
storage compactness, but the parameters are needed at render time to
display the actual content). This matches the existing pattern for
tool output components (e.g. `<NalarBrowser>` reads `parameters` for
the action-specific args).

### Multi-preview per turn

The LLM may call `show_preview` multiple times in a single turn
(showing 3 images, then a summary markdown). Each call is a **separate
tool result row** with a distinct `preview_id`. The side panel:

- Shows the **most recent** preview in the main area.
- Shows a **thumbnail strip** (or tabs) at the top with one entry per
  preview (oldest left, newest right).
- Clicking a thumbnail switches the main area to that preview.
- Thumbnails show: content_type icon + title (or first 30 chars of content
  if no title) + the preview_id suffix for traceability.

The thumbnail list is **scoped to the current chat** and resets when the
user switches chats (since each chat has its own `llm_history`).

### Content size cap

Hard cap at **1 MB** for `content` (per call). Reasoning:
- Base64 image at 1 MB ≈ 750 KB binary (fits a typical screenshot)
- Markdown at 1 MB ≈ 250-500 KB of formatted text (a long doc)
- Anything larger should be split or summarized by the agent

If exceeded, the tool returns an error to the LLM (LLM can retry with
smaller content). The 1 MB cap is **not** configurable in v1 (YAGNI).

### Side panel layout

The side panel mounts **inside ChatView**, to the right of the messages
wrapper. Default width **480px**, collapsible to a 32px chevron strip.

```
┌────────────────────────────────────┬─────────────────────────────┐
│ ChatView                          │ ◀ PreviewSidePanel          │
│ ┌──────────────────────────────┐  │ ┌─ [md] [code] [img] ──────┐│
│ │ messages                      │  │ │ Tabs (one per preview)   ││
│ │  [user message]               │  │ └──────────────────────────┘│
│ │  [assistant tool call row]    │  │ ┌──────────────────────────┐│
│ │  [show_preview tool row]      │  │ │ Title: Summary           ││
│ │  [assistant text continues]  │  │ │                          ││
│ │  ...                          │  │ │ [rendered content]       ││
│ │                               │  │ │                          ││
│ │                               │  │ │ Caption (if set)        ││
│ └──────────────────────────────┘  │ └──────────────────────────┘│
│                                   │ preview_id: pv_1782...      │
└────────────────────────────────────┴─────────────────────────────┘
```

**Collapsed state** (chevron only):
```
┌─────────────────────────────┐
│ ChatView │ ▶ │ 3 previews  │
└─────────────────────────────┘
```

**Empty state** (no previews in this chat yet): panel is fully hidden
(does not occupy space).

**Auto-open behavior**: when a new `show_preview` tool result arrives in
the messages, the side panel auto-opens if it was collapsed or hidden.

### Why this design (vs. alternatives considered)

**Alternative A: Inline tool-result row (the original v1 plan).**
- Each preview appears as a row in the chat tool sequence.
- Pros: lowest implementation complexity, no layout changes.
- Cons: doesn't scale (multiple previews = lots of scrolling);
  doesn't match the user's mental model of "preview pane" from IDEs.
- **Rejected** by user feedback (2026-07-01).

**Alternative B: Custom SSE event (`show_preview`) for transient banner.**
- Would emit a new `show_preview` SSE event alongside the standard
  `llm_full`; the frontend listens via the bus and shows a toast.
- Pros: gives instant feedback during a live turn.
- Cons: **two signals for one tool call** (the event + the row) — the
  user feedback was clear: "should emit event like other tool".
- **Rejected** by user feedback (2026-07-01).

**Alternative C: Floating overlay (popover near the assistant message).**
- Each preview floats above the chat, near the assistant message that
  triggered it.
- Pros: contextual to the message.
- Cons: overlaps content, hard to read multi-preview stacks.
- **Rejected**: side panel is cleaner.

### What is OUT of scope for v1 (YAGNI)

- Editable previews (markdown editor, image cropping).
- Copy-to-clipboard buttons (markdown `marked` output already supports
  selection + Ctrl+C).
- Configurable size cap.
- Preview export to file.
- Resizable panel width (fixed at 480px; user resize is a future UX).
- Cross-chat preview persistence (panel resets when switching chats).

## Open questions (decided by user 2026-07-01)

1. **Inline vs. side panel?** → **Side panel** (decided by user).
2. **Custom SSE event vs. standard flow?** → **Standard flow** (decided
   by user). The tool reuses the existing `llm_full` event; no new SSE
   type, no bus listener, no Pinia banner store.
3. **Should previews have an "open in new window/tab" action?** → No for v1.
4. **Max content size — 1 MB?** → Yes.
5. **Other content types (HTML, JSON, PDF)?** → No for v1. Adding enum
   variants later is non-breaking.