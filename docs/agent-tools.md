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
  "function": "pwsh",
  "arguments": "{\n  \"command\":\"Get-ChildItem | Select-Object -First 5\",\"cwd\":\"/tmp\",\"mandatory_timeout\":5\n}"
}
```
```