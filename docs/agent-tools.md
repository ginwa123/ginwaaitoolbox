# Agent Tools

This document lists the agent tools that the nalar LLM can call.

## `present_files`

Present workspace files as inline-preview cards in the chat transcript.
Each file renders an inline preview plus a download action — images
full-width (click → fullscreen), HTML in a sandboxed iframe with an
"Open in new tab" action, text/markdown/code as fetched source,
PDF embedded, video/audio with native players; anything else falls back
to a file row with a download button. To show generated content inline,
first save it with `write_file`, then present the saved file.

**Input** (JSON object):
- `files` (required): array of 1–10 objects, each with `path` (required,
  ABSOLUTE path to an existing file), `label` (optional display name),
  `caption` (optional note below the row)

**Output to LLM** (XML envelope):
- Success: `<present_files><status>presented</status><count>N</count><files><file path="..." bytes="..." mime="..." label="..."/>...</files></present_files>`
- Error: `<present_files><error>...</error></present_files>`

**SSE event:** none — uses the standard `llm_full` event with `tool_name='present_files'`. The frontend's `<PresentFiles>` card renders the message inline.

**Persistence:** `llm_history` row with `tool_name='present_files'`. The inner `<data>` envelope carries only metadata (status, count, per-file path/bytes/mime/label) — file bytes are served on demand via `GET /api/files/download` (`disposition=inline` for previews, `attachment` for downloads), so the SSE payload stays tiny. On reload, `loadChatHistory` returns the row and the inline card re-renders from `messages`.

**Error cases** (return `success=false` to the LLM):
- Empty `files` list, or more than 10 files
- Empty or relative `path`
- File not found (or is a directory)
- File exceeds 50 MiB

**Frontend rendering** (`PresentFiles.vue`; text source via the shared
`PreviewContentRenderer.vue`):
- `image/*` → thumbnail in the row + full-width inline preview (`<img src="...disposition=inline">`, click → fullscreen modal)
- `text/html` → sandboxed `<iframe src="...disposition=inline" sandbox="allow-scripts">` (fixed 480px height) + "Open in new tab". The iframe gets a null origin, so its JS cannot read the parent app's cookies, localStorage, or window. Forms render but cannot submit; `window.open()` from the iframe is blocked. The sandbox is the security boundary.
- `application/pdf` → embedded `<iframe src="...disposition=inline">` (480px)
- `video/*` → native `<video controls>`; `audio/*` → native `<audio controls>`
- text-like (`text/*`, `application/json`, `application/javascript`) → source fetched over same-origin `fetch` (≤ 512 KB, sliced to 200k chars) and rendered via `PreviewContentRenderer`: markdown for `.md`, code + language for known code extensions, plain `<pre>` text otherwise
- anything else (zip, etc.) → generic 📄 row (icon + name + size + mime + ⬇ download)

**Example usage:**

```json
{
  "files": [
    { "path": "/home/user/report.md", "label": "Weekly report" },
    { "path": "/home/user/chart.png" }
  ]
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

After `generate_image` returns the success envelope, the agent MUST call `present_files` with `files=[{path=<path from the envelope>}]` to display the image inline in the chat. The agent also sees the `<revised_prompt>` and can echo it back to the user (so the user knows what the model actually generated). Example two-call sequence:

```
→ generate_image({"prompt": "a cute cat wearing a top hat"})
← <generate_image>...<image index="0" path="/.../img_xxx_0.png" .../>...<revised_prompt>A cute cat wearing a black top hat in watercolor style</revised_prompt></generate_image>
→ present_files({"files": [{"path": "/.../img_xxx_0.png", "label": "A cute cat wearing a black top hat in watercolor style"}]})
← <present_files><status>presented</status>...</present_files>
```

The image is durable on disk at `<cwd>/generated_images/img_xxx_0.png` — the user can re-view it later via the chat history (which embeds the same `present_files` envelope, and the card re-fetches the bytes via `GET /api/files/download?disposition=inline` on reload). The image is also available for use as a kanban task attachment (`create_kanban_task`'s `image_urls` field) or for embedding in a design-mode element (`update_design_element`'s `image_url` field).

**Auth:**

Uses the active profile's `api_key` and `base_url`. For OpenAI's hosted API this is `https://api.openai.com/v1` + your OpenAI API key. Self-hosted DALL-E-compatible endpoints (e.g. a local DALL-E proxy) work the same way — just point `base_url` at the proxy.

**Implementation:**

- Tool impl: `src/modules/agent/tools/generate_image.zig`
- Tests: `src/modules/agent/tools/generate_image_test.zig` (34 tests: 6 static source-check + 28 behavioural)
- Exec wrapper: `src/ai_workflow/tui/agentic_loop/tools_exec_generate_image.zig`
- Wire-up: `src/root.zig`, `src/ai_workflow/tui/mod.zig`, `src/ai_workflow/tui/agentic_loop/tools.zig`, `src/ai_workflow/tui/agentic_loop/tools_equipped.zig`
- Test runner: `src/modules/agent/test_runner.zig`
- Plan: `docs/superpowers/plans/2026-08-14-generate-image-tool.md`
## `pwsh`

Same wire contract as [`bash`](#bash) — switching between them is a one-token change in the function-call name. The 8 input fields (`command`, `cwd`, `mandatory_timeout`, `max_output`, `stdin_data`, `background`, `max_lines`, `do_encoding`), the 3 required ones (`command`, `cwd`, `mandatory_timeout`), and the 9-tag XML output envelope (`<command>…</command> <stdout>…</stdout> <stderr>…</stderr> <exit_code>…</exit_code> <truncated>…</truncated> <timeout>…</timeout> <stdout_lines>…</stdout_lines> <stderr_lines>…</stderr_lines> <is_self>…</is_self>`) are identical to bash. Only the shell executable differs — `pwsh` runs PowerShell Core 7+ (or `powershell.exe` 5.1 on Windows).

**Use this when:** the user is on a Windows host (or has PowerShell Core installed on Linux/macOS), the requested operation is .NET-specific, the user wrote PowerShell in their prompt, or the target script is in a `.ps1` file.

**Command Rules (PowerShell-idiom):**
- end with `| Select-Object -First <N>` (alias `Select -First N`) instead of `head -n N`, to bound the BYTE count
- use `[Console]::OutputEncoding` or `Out-File` if you need UTF-8
- prefer `Get-ChildItem` (alias `ls`, `dir`) over recursive search
- prefer `Set-Location` (alias `cd`) over inline path navigation
- avoid `Get-ChildItem -Recurse` / `Select-String -Recurse` on large directories — bound with `| Select-Object -First <N>`
- use `rg` or `fd` for cross-shell code search (they're available cross-platform)

**Platform availability:**
- **Windows**: ships preinstalled as `powershell.exe` (5.1). PowerShell 7+ via `winget install Microsoft.PowerShell`.
- **macOS**: install with `brew install --cask powershell`.
- **Linux**: install via the Microsoft repo (`/etc/yum.repos.d/microsoft.repo` + `dnf install powershell`), `snap install powershell --classic`, or the tarball at <https://github.com/PowerShell/PowerShell/releases>.

If `pwsh` is not on `$PATH`, the spawn fails with `FileNotFound` — same shape of error as bash on Windows today. Probe with `which pwsh` (POSIX) or `(Get-Command pwsh -ErrorAction SilentlyContinue)` (PowerShell) before invoking.

**Example usage:**

```json
{
  "prompt": "A cute baby sea otter wearing a small knit hat, watercolor style, soft pastel colors, gentle lighting",
  "model": "dall-e-3",
  "size": "1024x1024",
  "quality": "hd",
  "style": "natural"
}
  "function": "pwsh",
  "arguments": "{\n  \"command\":\"Get-ChildItem | Select-Object -First 5\",\"cwd\":\"/tmp\",\"mandatory_timeout\":5\n}"
}
```
```
## `ask_user`

Stops the turn to ask the human a question, with 2–6 selectable options
and/or a free-text answer. Use it only when a decision is genuinely blocked
on the human and guessing wrong would waste real work — not to confirm
something you can verify yourself.

The call **ends the turn**. `ask_user` returns immediately, the agentic loop
breaks, and the question waits in the transcript for as long as it takes the
human to answer (there is **no timeout**: nothing is parked in memory, so a
question can wait a week at no cost). Answering rewrites this tool call's
result row in place and starts a **new run** that continues with the answer
in context.

**Input** (JSON object):
- `question` (required): the question. Ask exactly one; put context in the text
- `header` (optional): card title, ≤ 40 characters
- `options` (optional): 2–6 short strings. Each option **is** the answer value. Omit for a free-text-only question
- `allow_free_text` (optional, default `true`): also offer an "Other — type your own answer" box
- `multi_select` (optional, default `false`): let the human pick several options
- `recommended` (optional): must exactly match one of `options`; rendered as a chip

**Output to LLM** (XML envelope inside `<data>`):
- Pending (returned immediately, and what the card renders): `<ask_user><status>pending</status><question_id>q_…</question_id><header>…</header><question>…</question><allow_free_text>true</allow_free_text><multi_select>false</multi_select><recommended>…</recommended><options><option>…</option></options><instruction>…</instruction></ask_user>`
- Answered (written in place by the answer endpoint): `…<status>answered</status><answer>staging</answer><answers_count>1</answers_count>`
- Skipped: `…<status>skipped</status><instruction>The human declined to answer. Do not guess…</instruction>`
- Abandoned: `…<status>abandoned</status><instruction>The human moved on without answering. Do not guess…</instruction>`
- No human (unattended run / sub-agent, returned immediately, **no row written**): `…<status>unavailable</status><reason>no_human</reason><instruction>Choose the most reasonable option yourself…</instruction>`
- Error (malformed input only, e.g. `recommended` not in `options`): `<tool><name>ask_user</name>…<success>false</success><error>…</error></tool>`

`skipped` / `abandoned` / `unavailable` are **successful** calls with a
degraded outcome, never `<error>`.

**SSE event:** none — the card renders from the standard `llm_full`
tool-result row (`tool_name='ask_user'`). The answer rewrites that same row in
place (and emits its `llm_full`), so an open chat flips the card without a
reload; a page reload re-renders it from history.

**Persistence:** Migration 087 `session_pending_question` — one row per
question (`session_id`, `tool_call_id`, `llm_history_id`, `question`,
`multi_select`, `status`, `answer`). `status` is one of
`pending | answered | skipped | abandoned`; `unavailable` writes no row at all.

**HTTP:** `POST /api/llm/session/:session_id/answer` with
`{question_id | tool_call_id, answer, skip}`. The order inside the handler is
load-bearing: mark the row resolved → rewrite the tool-result row → *then*
`emit_run_agent(skip_initial_queue_message=true)`. A run started first would
hand the model `<status>pending</status>` and it might guess. Idempotent —
answering an already-resolved question returns 200 with the stored status.
Errors: 400 (no key / empty answer / scalar answer to a multi-select), 403
(another session's question), 404 (unknown question).

**Never ask:** a sub-agent (stripped at equip time, rejected outright by
`spawn_sub_agent`, and `unavailable` at runtime) or an unattended run
(`sessions.is_auto_retry_until_stop=1`).

**If the human sends a message instead of answering:** the `session_create`
guard settles the question as `abandoned` and rewrites its row first, so the
session is never dead-ended and the model is told not to guess.

**Frontend rendering:** `AskUser.vue` — radio list (or checkboxes for
multi-select) with digit shortcuts, an "Other" textarea, Send / Skip, a
"waiting for you" badge while pending, and resolved states for
answered / skipped / abandoned / unavailable. The pending card carries the
whole question in its envelope, so it renders identically live and after a
reload.
