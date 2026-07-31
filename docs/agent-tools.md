# Agent Tools

This document lists the agent tools that the nalar LLM can call.

## `show_preview`

Show a visual preview to the user in the side panel of the chat.

**Input** (JSON object):
- `content_type` (required): one of `"markdown"`, `"text"`, `"code"`, `"image"`, `"html"`
- `content` (required): the content to display (string, up to 1 MB)
- `title` (optional): human-readable title shown above the preview
- `language` (required when `content_type='code'`): programming language for syntax highlighting
- `caption` (optional): caption shown below the preview

**Output to LLM** (XML envelope):
- Success: `<show_preview><status>shown</status><preview_id>pv_...</preview_id><content_type>markdown</content_type><content_length>NN</content_length></show_preview>`
- Error: `<show_preview><error>...</error></show_preview>`

**SSE event:** none — uses the standard `llm_full` event with `tool_name='show_preview'`. The frontend's `<PreviewSidePanel>` filters the `messages` array.

**Persistence:** `llm_history` row with `tool_name='show_preview'` and `parameters` containing the full content. The inner `<data>` envelope carries only metadata (status, preview_id, content_type, content_length) — the actual content is delivered via `parameters` to keep storage compact. On reload, `loadChatHistory` returns the row and the side panel re-renders from `messages`.

**Error cases** (return `success=false` to the LLM):
- Empty or missing `content_type` / `content`
- `content_type` not one of the five supported values
- `content` exceeds 1 MB
- `content_type='code'` with no `language` (or empty `language`)

**Frontend rendering** (`PreviewSidePanel.vue`):
- The side panel mounts on the right side of ChatView (480px wide, collapses to 32px)
- Auto-opens when a new preview arrives
- Multi-preview per turn: each call adds a tab; click a tab to switch
- `markdown` → rendered via `marked()`
- `text` → preserved whitespace in a `<pre>` block
- `code` → syntax-highlighted via `<pre><code class="language-X">`
- `image` → `<img>` with `data:` or `http(s):` URL only (XSS protection)
- `html` → rendered inside an `<iframe sandbox="allow-scripts" srcdoc="...">`. The iframe gets a null origin, so its JS cannot read the parent app's cookies, localStorage, or window. Forms render but cannot submit; `window.open()` from the iframe is blocked. The HTML is attribute-escaped into the `srcdoc` (no HTML sanitization — the iframe sandbox is the security boundary).

**Example usage:**

```json
{
  "content_type": "markdown",
  "content": "# Project Summary\n\nThis project has 3 main components...",
  "title": "Project structure overview"
}
```

```json
{
  "content_type": "code",
  "content": "fn main() void {\n    std.debug.print(\"Hello\\n\", .{});\n}",
  "language": "zig",
  "title": "Sample Zig program"
}
```

```json
{
  "content_type": "image",
  "content": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "title": "Generated chart"
}
```

```json
{
  "content_type": "html",
  "content": "<!DOCTYPE html>\n<html>\n  <body style=\"font-family: sans-serif; padding: 2rem;\">\n    <h1>Welcome</h1>\n    <p>Landing pages are a common preview target.</p>\n    <button onclick=\"alert('clicked')\">Click me</button>\n  </body>\n</html>",
  "title": "Landing page preview"
}
```
```