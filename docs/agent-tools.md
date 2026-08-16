# Agent Tools

This document lists the agent tools that the nalar LLM can call.

## `show_preview`

Show a visual preview to the user in the side panel of the chat, OR
inline within the chat message bubble (user choice — see "Display
mode" below).

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

**Display mode** (user-controlled toggle, 2026-08-06):
The user chooses where previews render via a 2-button segmented
control in the side panel header (`Side` / `Inline`). The choice
persists across reloads via `localStorage['nalar-preview-display-mode']`.
Default: `inline` — matches the behaviour of every other tool
output (`read_file`, `bash`, etc.), so previews are visible in
the chat history without an extra click.

| Mode | Where it renders |
|---|---|
| `inline` (default) | Rich content renders directly inside the chat message bubble (in `<ShowPreview>`). |
| `side` (opt-in) | The right-side `<PreviewSidePanel>` — for users who prefer a dedicated sidebar over inline rendering. |

In inline mode, the side panel auto-hides. A floating "📋 Open
preview panel" button appears at top-right of the chat area when
the user wants to switch to side mode. Click → flips mode back
to `side`.

The LLM does NOT pick the display mode per-call — only the user
decides. Same UX model as `<DiffView>`'s split/unified toggle.

**Frontend rendering** (`PreviewContentRenderer.vue`, used by both
`<PreviewSidePanel>` and `<ShowPreview>`):
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

## `generate_image`

Generate an image from a text prompt using the OpenAI Images API
(`POST /v1/images/generations` — the canonical DALL-E 2 / DALL-E 3 /
gpt-image-1 endpoint, per
<https://developers.openai.com/api/reference/resources/images/methods/generate>).

**Input** (JSON object):

- `prompt` (required, string): A text description of the desired image. Be specific — subject, style, lighting, composition. Max 1000 characters for `dall-e-2`, 4000 for `dall-e-3` / `gpt-image-1`.
- `model` (optional, string, default `"dall-e-3"`): One of `"dall-e-2"`, `"dall-e-3"`, `"gpt-image-1"`. DALL-E 2 is cheaper and allows `n > 1`; DALL-E 3 has the best quality; gpt-image-1 is the newest model.
- `n` (optional, integer, default `1`, range `1-10`): Number of images to generate. Note: DALL-E 3 and gpt-image-1 only accept `n=1` (OpenAI returns 400 if violated).
- `size` (optional, string, default `"1024x1024"`): Output size. Allowed values depend on model:
  - `dall-e-2`: `"256x256"`, `"512x512"`, `"1024x1024"`
  - `dall-e-3`: `"1024x1024"`, `"1792x1024"`, `"1024x1792"`
  - `gpt-image-1`: `"1024x1024"`, `"1536x1024"`, `"1024x1536"`

    The tool validates model+size compatibility locally before calling OpenAI so a known-bad request fails fast (the LLM sees the allowed-size list in the error message).
- `quality` (optional, string, DALL-E 3 only): `"standard"` (default) or `"hd"` (more detail, ~2× cost). Ignored for `dall-e-2` / `gpt-image-1`.
- `style` (optional, string, DALL-E 3 only): `"vivid"` (default, hyper-real / dramatic) or `"natural"` (more subdued). Ignored for `dall-e-2` / `gpt-image-1`.
- `response_format` (optional, string, default `"b64_json"`): `"url"` or `"b64_json"`. We always save to disk regardless of format. The `"b64_json"` default is the only useful choice for saving; `"url"` is only useful if the caller wants the OpenAI URL too (which we don't currently return in the envelope, and which expires after ~60 min anyway).
- `user` (optional, string): A unique identifier for the end-user. Helps OpenAI detect abuse. Optional.

**Behaviour:**

1. Validates `prompt` is non-empty.
2. Applies defaults for `model`, `n`, `size`, `response_format`.
3. Validates `(model, size)` compatibility locally (allowed-set table — fails fast on bad combinations without a round-trip to OpenAI).
4. Builds the JSON request body (no null fields — OpenAI returns 400 on some nulls in some SDKs).
5. POSTs `<base_url>/images/generations` with `Authorization: Bearer <api_key>` and the JSON body. Uses the active profile's `api_key` and `base_url` — same auth as chat completion. **No new config needed.**
6. Parses the response. Surface OpenAI's `error.message` verbatim on 4xx/5xx.
7. Saves each image (base64-decoded) to `<cwd>/generated_images/img_<unix_ms>_<index>.png`. Creates the directory if missing.
8. Returns the success envelope with the absolute paths.

**Output to LLM** (XML envelope, success):

```xml
<generate_image>
  <status>generated</status>
  <count>1</count>
  <model>dall-e-3</model>
  <size>1024x1024</size>
  <images>
    <image index="0" path="/cwd/generated_images/img_1723123456789_0.png" bytes="12345" mime="image/png" />
  </images>
  <revised_prompt>A vibrant watercolor painting of a hat-wearing cat</revised_prompt>
</generate_image>
```

Notes:

- `<revised_prompt>` is included ONLY when DALL-E 3 / gpt-image-1 returns one (they silently rewrite the prompt for clarity/safety; DALL-E 2 doesn't).
- `bytes` is the on-disk file size in bytes (read with `std.Io.File.stat` after writing).
- One `<image>` per file even when `n > 1` (DALL-E 2 can do n=2..10; the others only do n=1).

**Output to LLM** (XML envelope, error):

```xml
<generate_image><error>HTTP 400: size '512x512' is not valid for model 'dall-e-3'. Allowed sizes: 1024x1024, 1792x1024, 1024x1792.</error></generate_image>
```

Or:

```xml
<generate_image><error>HTTP 401: Incorrect API key provided: sk-XXXXX...</error></generate_image>
```

The error envelope surfaces as `success=false` to the LLM via the standard `wrapToolOutput` envelope.

**Next step for the agent:**

After `generate_image` returns the success envelope, the agent MUST call `show_preview` with `content_type="image"` and `path=<path from the envelope>` to display the image in the side panel. The agent also sees the `<revised_prompt>` and can echo it back to the user (so the user knows what the model actually generated). Example two-call sequence:

```
→ generate_image({"prompt": "a cute cat wearing a top hat"})
← <generate_image>...<image index="0" path="/.../img_xxx_0.png" .../>...<revised_prompt>A cute cat wearing a black top hat in watercolor style</revised_prompt></generate_image>
→ show_preview({"content_type": "image", "path": "/.../img_xxx_0.png", "title": "A cute cat wearing a black top hat in watercolor style"})
← <show_preview><status>shown</status>...</show_preview>
```

The image is durable on disk at `<cwd>/generated_images/img_xxx_0.png` — the user can re-view it later via the chat history (which embeds the same `show_preview` envelope, and `PreviewContentRenderer` reads the local file again on reload). The image is also available for use as a kanban task attachment (`create_kanban_task`'s `image_urls` field) or for embedding in a design-mode element (`update_design_element`'s `image_url` field).

**Auth:**

Uses the active profile's `api_key` and `base_url`. For OpenAI's hosted API this is `https://api.openai.com/v1` + your OpenAI API key. Self-hosted DALL-E-compatible endpoints (e.g. a local DALL-E proxy) work the same way — just point `base_url` at the proxy.

**Implementation:**

- Tool impl: `src/modules/agent/tools/generate_image.zig`
- Tests: `src/modules/agent/tools/generate_image_test.zig` (34 tests: 6 static source-check + 28 behavioural)
- Exec wrapper: `src/ai_workflow/tui/agentic_loop/tools_exec_generate_image.zig`
- Wire-up: `src/root.zig`, `src/ai_workflow/tui/mod.zig`, `src/ai_workflow/tui/agentic_loop/tools.zig`, `src/ai_workflow/tui/agentic_loop/tools_equipped.zig`
- Test runner: `src/modules/agent/test_runner.zig`
- Plan: `docs/superpowers/plans/2026-08-14-generate-image-tool.md`

**Example usage:**

```json
{
  "prompt": "A cute baby sea otter wearing a small knit hat, watercolor style, soft pastel colors, gentle lighting",
  "model": "dall-e-3",
  "size": "1024x1024",
  "quality": "hd",
  "style": "natural"
}
```