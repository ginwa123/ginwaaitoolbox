# Plan: New agent tool — `generate_image` (OpenAI Images API)

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **⛔ DO ALL WORK IN A GIT WORKTREE — never on `main`.** See **Task 0 — Worktree setup** below. Project convention: every feature/refactor ships via a PR from `worktree/<topic>`. The kanban card moves to `merged` only after the user merges the PR.

## Goal

Add a new agent tool **`generate_image`** that calls the OpenAI Images API (`POST /v1/images/generations`) — the canonical DALL-E endpoint per <https://developers.openai.com/api/reference/resources/images/methods/generate> — so the agent can synthesise images from a natural-language prompt directly inside a chat. The tool saves the generated image to disk and returns its path so the agent can immediately call the existing `show_preview` tool with `content_type="image"` and `path=<path>` to display it in the chat's side panel.

## User-facing description

> Generate an image from a text prompt using the OpenAI Images API (DALL-E 2 / DALL-E 3 / gpt-image-1).
>
> **Input** (JSON object):
> - `prompt` (required, string): description of the image to generate
> - `model` (optional, string, default `"dall-e-3"`): one of `"dall-e-2"`, `"dall-e-3"`, `"gpt-image-1"`
> - `n` (optional, integer, default `1`, range 1-10): number of images. Note: DALL-E 3 and gpt-image-1 only support `n=1`.
> - `size` (optional, string, default `"1024x1024"`): one of `"256x256"`, `"512x512"`, `"1024x1024"`, `"1792x1024"`, `"1024x1792"`. Allowed values depend on `model`.
> - `quality` (optional, string): `"standard"` or `"hd"`. DALL-E 3 only. Ignored for other models.
> - `style` (optional, string): `"vivid"` or `"natural"`. DALL-E 3 only. Ignored for other models.
> - `response_format` (optional, string, default `"b64_json"`): `"url"` or `"b64_json"`. URL is returned by OpenAI, expires after ~60 min — only useful for the immediate next step.
> - `user` (optional, string): end-user identifier forwarded to OpenAI for abuse detection
>
> **Behaviour:** Calls the OpenAI `/v1/images/generations` endpoint using the active profile's `api_key` and `base_url` (no new config needed — same key as the chat completion calls). Decodes each returned image (base64) and saves it to `<cwd>/generated_images/img_<unix_ms>_<index>.<ext>` (PNG for DALL-E 3, PNG for DALL-E 2, PNG for gpt-image-1). Creates the directory if missing.
>
> **Output to LLM** (XML envelope, success):
> ```xml
> <generate_image>
>   <status>generated</status>
>   <count>1</count>
>   <model>dall-e-3</model>
>   <size>1024x1024</size>
>   <images>
>     <image index="0" path="/cwd/generated_images/img_1723123456789_0.png" bytes="12345" mime="image/png" />
>   </images>
>   <revised_prompt>...</revised_prompt>   <!-- present only for dall-e-3 / gpt-image-1 -->
> </generate_image>
> ```
>
> **Output to LLM** (XML envelope, error):
> ```xml
> <generate_image><error>HTTP 400: ...OpenAI error message...</error></generate_image>
> ```
>
> **Next step for the agent:** Call `show_preview` with `content_type="image"`, `path=<path>`, `title=<prompt>` (or a truncated version) to display the image in the side panel. The image is durable on disk, so the user can re-view it later via `read_file` + `show_preview` or attach it to a kanban task.
>
> **Auth:** Uses the active profile's `api_key` and `base_url` (e.g. `https://api.openai.com/v1` for the real OpenAI endpoint, or any OpenAI-style-compatible URL for self-hosted DALL-E). The tool description mentions this so the agent knows it does NOT need to ask the user for a separate API key.

## Background — why we're doing this

The agent can already write files, run bash, and embed images via `show_preview` (it accepts a `path` to a local file or a base64 data URI as `content`). But it has NO way to **create** a new image — the only options today are "the user attaches one manually" or "the agent builds an SVG and `show_preview`s it". The user wants DALL-E generation as a first-class tool so the agent can:

- Generate illustrations for documentation/README drafts
- Create mockups for design-mode work without leaving the chat
- Generate image assets to attach to kanban tasks (via `create_kanban_task`'s `image_urls` field, or to upload via `update_design_element`)

The OpenAI Images API endpoint is documented at <https://platform.openai.com/docs/api-reference/images/create> (the `developers.openai.com` link in the task is the same endpoint under the newer docs site).

## Architecture

The tool follows the existing 5-file pattern (same as `set_design_page`, `show_preview`, `preview_design_page`):

| File | Role |
|---|---|
| `src/modules/agent/tools/generate_image.zig` | Tool definition (`generate_image_tool` constant), `GenerateImageInput` struct, `execute_generate_image` impl, `saveImageToDisk` helper, `toXMLSuccess` / `toXMLError` |
| `src/modules/agent/tools/generate_image_test.zig` | Behavioural tests (JSON body shape, base64 decode, save-to-disk round-trip, error envelope) + static source-check wiring tests |
| `src/ai_workflow/tui/agentic_loop/tools_exec_generate_image.zig` | Thin `execGenerateImage(ctx, tc) -> ToolExecResult` wrapper that parses JSON input → calls impl → wraps the XML envelope via `wrapToolOutput` |
| (existing) `src/ai_workflow/tui/agentic_loop/tools_exec_save_image_to_disk.zig` | NOT NEEDED — saving is internal to `execute_generate_image` |
| (existing) `custom_http_client` | Used to POST the JSON body and receive the JSON response (libcurl-backed, already imported by `pabrikcore`) |

### Wire integration (5 edits)

1. `src/root.zig` — add `pub const generate_image = @import("modules/agent/tools/generate_image.zig");`
2. `src/ai_workflow/tui/mod.zig` — add `pub const generate_image = @import("../../modules/agent/tools/generate_image.zig");` (matches the existing `show_preview` re-export at line 11)
3. `src/ai_workflow/tui/agentic_loop/tools.zig` — add `pub const execGenerateImage = @import("tools_exec_generate_image.zig").execGenerateImage;`
4. `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` — add the `generate_image_mod` import + add `generate_image_tool` to BOTH `tools_list` (in `equips()`) AND `UNIFIED_TOOL_REGISTRY()`
5. `src/modules/agent/test_runner.zig` — register `generate_image_test.zig`

### Backend: zero changes beyond the wire-up

No DB migration. No new HTTP endpoints. No new tables. The `cwd/generated_images/` directory is created on demand by the tool itself.

### Frontend: zero changes

The agent receives `<generate_image>...<image path="..." />...</generate_image>` and then calls the existing `show_preview` tool with `content_type="image"` + `path=<path>`. `PreviewContentRenderer.vue` already handles the `path` parameter (MIME-sniffs the magic bytes, base64-encodes, emits a data URI — same code path as a hand-written data URL). No new Vue components, no SSE event additions.

The chat-history tool-output component renders the `<generate_image>` envelope as plain text inside the tool call (same as the existing `<bash>` / `<show_preview>` tool envelopes — there's no dedicated rich renderer for `<generate_image>` and we don't need one because the **next tool call** is `show_preview`, which renders the actual image in the side panel).

## Design Decisions (review before execution)

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| D1  | **Save the image to disk** at `<cwd>/generated_images/img_<unix_ms>_<index>.<ext>` and return the path in the envelope. | (1) Base64 PNGs from DALL-E 3 are 1-5 MB — blowing past the existing 1 MiB cap in `show_preview`'s `content` field. (2) URLs from `response_format=url` expire after ~60 min — not durable for the "I want to revisit this image later" case. (3) Saves are durable across reloads (the `cwd` is part of the session). (4) The existing `show_preview` tool already accepts `path` → reads + MIME-sniffs + base64-encodes on demand. | Return base64 inline only — fails on large images. Return URL only — fails on the "user wants to keep this" case. Save to a global `~/.cache/pabrik/` dir — out of the user's workspace, the LLM can't see it via `read_file` without an absolute path the user didn't expect. |
| D2  | **Default `model="dall-e-3"`** (best quality). Also accept `dall-e-2` (cheaper, allows n>1) and `gpt-image-1` (the newer model). | OpenAI recommends DALL-E 3 for new use cases. The user can downgrade for cost or n>1 needs. | Hard-code DALL-E 3 — limits the user. Default DALL-E 2 — worse out-of-the-box. |
| D3  | **Default `response_format="b64_json"`** so we can decode + save to disk in one step. The LLM can opt into `"url"` if they want (and we just write the URL to disk as text — practical joke). | b64_json is the only way to get raw bytes we can persist. | Default `"url"` — useless for the tool's purpose. |
| D4  | **Use the active profile's `base_url` and `api_key`** (passed via `ToolExecContext`). Same flow as `Agent.zig` uses for chat completion. Endpoint: `<base_url>/images/generations` (where `base_url` already includes `/v1`). | No new config. If the user has OpenAI configured for chat, they have it for image gen. Self-hosted DALL-E-compatible servers (e.g. local dall-e-3-style proxies) work out of the box. | Add `image_api_key` + `image_base_url` to `LlmConfig` — over-engineered; the same key works. Hard-code `https://api.openai.com/v1` — breaks self-hosted setups. |
| D5  | **Endpoint is always `<base_url>/images/generations`** regardless of model. No `/v1` prefix in the endpoint — `base_url` already includes `/v1` per the existing chat-completion convention (`Agent.zig:1791-1792`). | Matches the `Agent.zig` convention for `/chat/completions`. | Endpoint is `<base_url>/v1/images/generations` — duplicates `/v1` for users who already include it. |
| D6  | **Self-imposed size limit:** reject the request if the agent passes `size` that's not valid for the chosen `model`. Forward OpenAI's validation errors verbatim for everything else. | We don't want to round-trip every size:model matrix to OpenAI just to discover the user passed `1792x1024` with DALL-E 2. The allowed-set table is small (3 sizes × 3 models). | Always forward — wastes a round trip on a known-bad request. |
| D7  | **Output envelope is XML** (not JSON), per project convention (`<show_preview>`, `<kanban_list>`, etc.). `<error>` tags surface a wrapped `success=false` to the LLM via `wrapToolOutput` — same pattern as every other tool. | Every other tool returns XML. Consistency. | JSON envelope — inconsistent with the rest of the tool surface. |
| D8  | **Auth header is `Authorization: Bearer <api_key>`** (matches `Agent.zig:1824-1828`). | OpenAI's standard. | `api-key` header — that's Azure OpenAI, not OpenAI. |
| D9  | **Image is saved with `O_CREAT | O_WRONLY | O_TRUNC` + `writeStreamingAll` + `close`.** The directory is created with `createDirPath` (recursive) if missing. If save fails (read-only fs, disk full), the tool returns an error envelope — the LLM knows the image wasn't saved and can retry. | Don't save — defeats the durability point. Save to a Memory Pool — over-engineered. |
| D10 | **The `revised_prompt` field is included in the output envelope** when OpenAI returns one (DALL-E 3 + gpt-image-1 do; DALL-E 2 doesn't). This lets the agent see what prompt the model actually used (after OpenAI's safety / clarity rewrite) and surface it to the user. | Transparency — the agent shouldn't silently lie about what the model saw. | Strip revised_prompt — the agent (and user) can't see the rewrite. |
| D11 | **One image per file** (`img_<unix_ms>_<index>.png`). When `n>1` we still get a single response with `count` images, each saved to its own file. The output envelope has a `<images>` list with one `<image>` per file. | Same shape for n=1 and n>10. Easy for the LLM to iterate. | Single file with multiple images — doesn't match OpenAI's response. |
| D12 | **No new tests for the HTTP layer** — `custom_http_client` has 3973 lines of tests already. We test the request-body builder + the JSON-response parser + the save-to-disk round-trip; the HTTP call itself is left to manual smoke tests (an actual OpenAI key is needed; CI can't pay for that). | Tests that depend on a paid API are an anti-pattern. | Record/replay fixture — adds a dep, drift risk. |
| D13 | **Test strategy: behavioural + a small set of static source-check tests** (schema fields, required array, function signatures, exec-fn name). The static checks catch "I renamed a function and forgot to update the registry". | Mirrors `show_preview_test.zig` exactly. The project grandfathered the existing static tests in `tools_exec_*_test.zig`. | Pure behavioural — fails at runtime with cryptic Zig compile errors when the registry signature drifts. |
| D14 | **TDD discipline**: every implementation step starts with a failing test, then minimal code to make it pass, then a commit. | Project norm from AGENTS.md "Verification Workflow". | Write the impl first — risky; hard to know what to test. |
| D15 | **Worktree: `.worktrees/generate-image-tool` on branch `worktree/generate-image-tool`**. | Project convention. | Direct on main — forbidden. |
| D16 | **No DB migration**, **no new SSE event type**, **no Vue component changes**, **no `LlmConfig` schema changes**. | Pure backend feature. The wire format (`llm_full` event with `tool_name='generate_image'`) is already supported. | Migration / event — over-engineered. |
| D17 | **Naming**: tool name = `generate_image`. Constants: `GenerateImageInput`, `generate_image_tool`, `execute_generate_image`, `execGenerateImage`. File names: `generate_image.zig`, `generate_image_test.zig`, `tools_exec_generate_image.zig`. | snake_case + PascalCase matches every other tool in the repo. | CamelCase names — drifts from convention. |
| D18 | **One PR, 3-4 commits**: (1) tests + impl + wire-up (atomic), (2) docs. | Each commit is reviewable. | One mega-commit — unreviewable. |
| D19 | **Cross-platform**: works on Linux, macOS, AND Windows. libcurl handles TLS so HTTPS to `api.openai.com` works everywhere. File saves use `std.Io.File.writeStreamingAll` (cross-platform). | Matches every other tool that hits the network. | Windows-only or POSIX-only file paths — breaks the cross-platform rule. |
| D20 | **Verify zig build test** at the end of each task — `zig build test --summary all 2>&1 | tail -n 5` showing "all tests passed". | Project norm from AGENTS.md "Verification Workflow". | Skip — will break later. |

---

## Global Constraints

- **TDD discipline**: every implementation step starts with a failing test, then minimal code to make it pass, then a commit.
- **Cross-platform**: every change must work on Linux, macOS, AND Windows. The tool calls OpenAI's HTTPS endpoint via libcurl and writes files via `std.Io.File`.
- **No static-contract tests for behavioural behaviour** — user rule (2026-07-29). The static checks here are ONLY for "did this name land in the source code" wiring tests, matching the existing `show_preview_test.zig` grandfathered static tests.
- **No new dependencies** — `custom_http_client` is already wired in via `pabrikcore`, the existing `wrapToolOutput` helper exists, the existing `AgentTool` schema struct exists.
- **Surgical patches** — don't refactor anything outside the new files + the 5 wire-up edits.
- **No DB migration** — pure backend feature.
- **No port 8081** — smoke tests use port 8080.
- **Zig 0.16 anonymous-struct-literal gotcha**: when constructing optional-field structs (`GenerateImageInput`, `GenerateImageOutput`), initialize ALL fields explicitly. Same gotcha that bit `buildJsonAnthropicRequest` (`Agent.zig:1100`). Mirror that pattern verbatim.
- **Naming**: `generate_image` / `GenerateImageInput` / `generate_image_tool` / `execute_generate_image` / `execGenerateImage`.
- **No `unused` lint regressions** — `pub fn`s in `generate_image.zig` may be used only by the test file or only by the exec wrapper; silence unused-when-reachable-via-module.

---

## File Structure

```
src/modules/agent/tools/
├── generate_image.zig                 # NEW — tool def, input struct, execute_generate_image, saveImageToDisk, envelope helpers
├── generate_image_test.zig            # NEW — ~25 behavioural + ~6 static wiring tests

src/ai_workflow/tui/
├── mod.zig                            # EDIT — add `pub const generate_image = @import(...);` (matches line 11 show_preview)
└── agentic_loop/
    ├── tools.zig                      # EDIT — `pub const execGenerateImage = @import("tools_exec_generate_image.zig").execGenerateImage;`
    ├── tools_equipped.zig             # EDIT — add `generate_image_mod` import + register in `tools_list` and `UNIFIED_TOOL_REGISTRY()`
    └── tools_exec_generate_image.zig  # NEW — execGenerateImage(ctx, tc) -> ToolExecResult

src/root.zig                           # EDIT — `pub const generate_image = @import("modules/agent/tools/generate_image.zig");`
src/modules/agent/test_runner.zig      # EDIT — `_ = @import("tools/generate_image_test.zig");`

docs/agent-tools.md                    # EDIT — add `## generate_image` section (mirrors `## show_preview` layout)
docs/superpowers/plans/2026-08-14-generate-image-tool.md  # NEW — this file
```

### File budget (concrete)

| File | New lines | Touched |
|---|---:|---:|
| `src/modules/agent/tools/generate_image.zig` | ~400 | NEW |
| `src/modules/agent/tools/generate_image_test.zig` | ~400 | NEW |
| `src/ai_workflow/tui/agentic_loop/tools_exec_generate_image.zig` | ~50 | NEW |
| `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` | +5 | EDIT |
| `src/ai_workflow/tui/agentic_loop/tools.zig` | +1 | EDIT |
| `src/ai_workflow/tui/mod.zig` | +1 | EDIT |
| `src/root.zig` | +1 | EDIT |
| `src/modules/agent/test_runner.zig` | +1 | EDIT |
| `docs/agent-tools.md` | ~80 | EDIT |

Total: ~940 lines, of which ~850 are new code/tests and ~90 are wiring + docs.

---

## Task 0 — Worktree setup (5 minutes)

- [ ] `git worktree add .worktrees/generate-image-tool -b worktree/generate-image-tool`
- [ ] `cd .worktrees/generate-image-tool`
- [ ] Verify clean: `git status` shows `On branch worktree/generate-image-tool, nothing to commit`.

## Task 1 — Write the test file (red) — ~30 minutes

Goal: write all behavioural + static tests in `generate_image_test.zig`. They must FAIL because `generate_image.zig` does not exist yet.

### Task 1.1 — Static source-check tests (6 tests)

Grep `src/modules/agent/tools/generate_image.zig` for required substrings. If the file doesn't exist, every test fails with `error.FileNotFound`.

| Test | Needle |
|---|---|
| `tool definition has name "generate_image"` | `.name = "generate_image"` |
| `schema has all 6 properties` | `prompt`, `model`, `n`, `size`, `quality`, `style`, `response_format`, `user` (8 total — but `prompt` is required; required array must include `prompt`) |
| `required array contains prompt` | `required = &.{ "prompt"` (or with additional fields after) |
| `defines pub fn execute_generate_image` | `pub fn execute_generate_image(` |
| `defines 1 MiB response cap constant` | `MAX_RESPONSE_BYTES` + `1024 * 1024` (mirror of show_preview's cap) |
| `references custom_http_client` | `custom_http_client` (proves the impl actually wires up the HTTP layer — guards against an accidental std-lib-only stub) |

### Task 1.2 — Behavioural tests (validation, JSON shape, error paths)

These exercise the pure-data helpers (`buildJsonRequestBody`, `parseImageResponse`, `validateModelSize`) and the save-to-disk round-trip. They do NOT need a real OpenAI key.

- [ ] `validateModelSize accepts dall-e-2 + 256x256 / 512x512 / 1024x1024`
- [ ] `validateModelSize accepts dall-e-3 + 1024x1024 / 1792x1024 / 1024x1792`
- [ ] `validateModelSize accepts gpt-image-1 + 1024x1024 / 1536x1024 / 1024x1536` (or whatever OpenAI returns; keep it permissive if uncertain)
- [ ] `validateModelSize rejects dall-e-3 + 512x512`
- [ ] `validateModelSize rejects dall-e-2 + 1792x1024`
- [ ] `validateModelSize rejects unknown model`
- [ ] `validateModelSize rejects unknown size`
- [ ] `buildJsonRequestBody produces correct shape for minimal input (prompt only)`
- [ ] `buildJsonRequestBody omits optional fields when null (no nulls in JSON)`
- [ ] `buildJsonRequestBody includes all fields when provided (model, n, size, quality, style, response_format, user)`
- [ ] `buildJsonRequestBody defaults model to "dall-e-3" and n to 1`
- [ ] `buildJsonRequestBody defaults response_format to "b64_json"`
- [ ] `parseImageResponse accepts a single-image response with b64_json`
- [ ] `parseImageResponse accepts a multi-image response with n=2 (DALL-E 2)`
- [ ] `parseImageResponse extracts revised_prompt when present`
- [ ] `parseImageResponse handles URL response_format (URL only, no b64_json)`
- [ ] `parseImageResponse surfaces OpenAI error envelope (HTTP 400 + {"error": {"message": "..."}})`
- [ ] `parseImageResponse rejects empty data array`
- [ ] `saveImageToDisk writes base64 bytes to <cwd>/generated_images/img_<ts>_<idx>.png and returns absolute path`
- [ ] `saveImageToDisk creates the generated_images subdirectory if missing`
- [ ] `saveImageToDisk rejects when the base64 payload is not valid base64`
- [ ] `saveImageToDisk returns an error when the cwd path is read-only` (skip test on Windows + skip test if running as root in CI)
- [ ] `toXMLSuccess produces the expected envelope shape (status, count, model, size, images list, revised_prompt)`
- [ ] `toXMLSuccess omits revised_prompt for DALL-E 2 responses`
- [ ] `toXMLSuccess escapes XML special chars in the prompt / revised_prompt`
- [ ] `toXMLError produces <generate_image><error>...</error></generate_image>`

### Task 1.3 — Verify all tests FAIL

```sh
zig build test --summary all 2>&1 | tail -n 30
```

Expect: file-not-found errors for `generate_image.zig` references in `tools_equipped.zig` (because `tools_equipped.zig` imports `pabrikcore.generate_image` which doesn't exist yet — we'll add the import in Task 2). To make this cleaner, **the wire-up edits in Task 2 are part of "the implementation lands"**; for now, write the test file in isolation and confirm it fails because `src/modules/agent/tools/generate_image.zig` doesn't exist (the test runner will refuse to compile if the file is `@import`ed but missing).

Commit: `test: add generate_image tool tests (red)`.

## Task 2 — Write the impl file (green) — ~90 minutes

Goal: implement `generate_image.zig` so every Task 1 test passes.

### Task 2.1 — Constants + struct + tool definition

```zig
const std = @import("std");
const custom_http_client = @import("custom_http_client");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;

/// Maximum response body size — 4 MiB covers a single DALL-E 3 b64_json
/// payload (1-3 MiB PNG → 1.3-4 MiB base64). 4 MiB also covers a 10-image
/// DALL-E 2 multi-image response comfortably.
pub const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

pub const GenerateImageInput = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    n: ?u8 = null,
    size: ?[]const u8 = null,
    quality: ?[]const u8 = null,
    style: ?[]const u8 = null,
    response_format: ?[]const u8 = null,
    user: ?[]const u8 = null,
};

pub const generate_image_tool: AgentTool = .{
    .type = "function",
    .function = .{
        .name = "generate_image",
        .description = "...",
        .parameters = .{
            .type = "object",
            .properties = &[_]schemas.ToolProperty{ ... },
            .required = &.{"prompt"},
        },
    },
};
```

### Task 2.2 — `validateModelSize` helper

Returns `null` on success, an `owned []u8` error message on failure. Mirrors `validateContentType` in `show_preview.zig`.

```zig
pub fn validateModelSize(allocator: std.mem.Allocator, model: []const u8, size: []const u8) !?[]u8 {
    // Allowed sizes per model (mirror OpenAI docs as of 2026-08):
    //   dall-e-2       → 256x256, 512x512, 1024x1024
    //   dall-e-3       → 1024x1024, 1792x1024, 1024x1792
    //   gpt-image-1    → 1024x1024, 1536x1024, 1024x1536
    ...
}
```

### Task 2.3 — `buildJsonRequestBody` helper

Pure-data — given a `GenerateImageInput`, returns the JSON body bytes. No allocations beyond the JSON string itself. Uses `std.json.fmt` with an intermediate `std.json.Value` tree, OR hand-builds the JSON via `std.ArrayList(u8)` for full control over field omission. **Recommended: hand-build** (avoids the `std.json.Value` tree allocation and makes "no nulls in JSON" trivially correct).

```zig
pub fn buildJsonRequestBody(allocator: std.mem.Allocator, input: GenerateImageInput) ![]u8 {
    // Hand-build JSON. Append each non-null field.
    // Field order: prompt, model, n, size, quality, style, response_format, user
    ...
}
```

### Task 2.4 — `parseImageResponse` helper

Given the raw JSON response body, returns an array of `ImageRecord { b64_json, url, revised_prompt }`. Throws on parse error, OpenAI error envelope, or empty data array.

```zig
pub const ImageRecord = struct {
    b64_json: ?[]const u8,
    url: ?[]const u8,
    revised_prompt: ?[]const u8,
    mime_type: []const u8,  // "image/png" for now
};

pub fn parseImageResponse(allocator: std.mem.Allocator, body: []const u8) ![]ImageRecord {
    ...
}
```

### Task 2.5 — `saveImageToDisk` helper

Writes the base64-decoded bytes to `<cwd>/generated_images/img_<unix_ms>_<idx>.<ext>` and returns the absolute path.

```zig
pub fn saveImageToDisk(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, b64_payload: []const u8, index: usize, mime: []const u8) ![]u8 {
    // Decode base64 → bytes
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64_payload) catch return error.InvalidBase64;
    var decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, b64_payload);

    // Resolve path
    const ts = std.Io.Clock.now(.real, io).toMilliseconds();
    const filename = try std.fmt.allocPrint(allocator, "img_{d}_{d}.{s}", .{ ts, index, extForMime(mime) });
    defer allocator.free(filename);
    const rel_path = try std.fs.path.join(allocator, &.{ "generated_images", filename });
    defer allocator.free(rel_path);

    // mkdir -p generated_images
    try std.Io.Dir.cwd().createDirPath(io, "generated_images");

    // Write
    const file = try std.Io.Dir.cwd().createFile(io, rel_path, .{});
    defer std.Io.File.close(file, io);
    try std.Io.File.writeStreamingAll(file, io, decoded);

    // Return absolute path
    return try std.fs.path.join(allocator, &.{ cwd, "generated_images", filename });
}
```

### Task 2.6 — `execute_generate_image` public entry point

Top-level orchestration:
1. Validate `prompt` (non-empty, length cap)
2. Resolve defaults (model="dall-e-3", n=1, size="1024x1024", response_format="b64_json")
3. Validate model+size compatibility
4. Build JSON body via `buildJsonRequestBody`
5. Compose URL `<base_url>/images/generations`
6. POST via `custom_http_client.Client` with `Authorization: Bearer <api_key>` + `Content-Type: application/json`
7. Check status code (4xx/5xx → parse OpenAI error envelope, return `<generate_image><error>...</error></generate_image>`)
8. Parse response via `parseImageResponse`
9. For each image: `saveImageToDisk` → collect (path, bytes, mime)
10. Build XML success envelope via `toXMLSuccess`

```zig
pub fn execute_generate_image(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: GenerateImageInput,
    base_url: []const u8,
    api_key: []const u8,
    cwd: []const u8,
) ![]u8 {
    // ... orchestrate
}
```

### Task 2.7 — XML envelope helpers

`toXMLSuccess(allocator, model, size, images[], revised_prompt)` → `<generate_image>...</generate_image>`
`toXMLError(allocator, msg)` → `<generate_image><error>...</error></generate_image>`

Both use the local `xmlEscape` helper (same as `show_preview.zig:149-165`).

### Task 2.8 — Verify all tests PASS

```sh
zig build test --summary all 2>&1 | tail -n 10
```

Expect: 0 failures. Fix any test that fails; do NOT delete tests to make them pass.

Commit: `feat(tools): add generate_image agent tool (green)`.

## Task 3 — Wire up the tool into the registry — ~15 minutes

5 edits so the tool is visible to the agent loop:

### Task 3.1 — `src/root.zig`

Add one line in the `pub const` block near line 520:

```zig
pub const generate_image = @import("modules/agent/tools/generate_image.zig");
```

### Task 3.2 — `src/ai_workflow/tui/mod.zig`

Add one line near line 11 (the show_preview re-export):

```zig
pub const generate_image = @import("../../modules/agent/tools/generate_image.zig");
```

### Task 3.3 — `src/ai_workflow/tui/agentic_loop/tools.zig`

Add one line after the other `exec*` aliases (around line 42):

```zig
pub const execGenerateImage = @import("tools_exec_generate_image.zig").execGenerateImage;
```

### Task 3.4 — `src/ai_workflow/tui/agentic_loop/tools_equipped.zig`

Add the module import near line 53:

```zig
const generate_image_mod = pabrikcore.generate_image;
```

Add the tool to the `tools_list` slice in `equips()` (somewhere alphabetical, between `glob_tool` and `load_memory_mod`):

```zig
generate_image_mod.generate_image_tool,
```

Add the registry entry in `UNIFIED_TOOL_REGISTRY()`:

```zig
.{ .name = "generate_image", .exec = tools.execGenerateImage, .tool_def = generate_image_mod.generate_image_tool },
```

### Task 3.5 — `src/modules/agent/test_runner.zig`

Add one line:

```zig
_ = @import("tools/generate_image_test.zig");
```

Commit: `feat(tools): register generate_image in agent tool registry`.

## Task 4 — Write the exec wrapper — ~15 minutes

`src/ai_workflow/tui/agentic_loop/tools_exec_generate_image.zig`:

```zig
const std = @import("std");
const pabrikcore = @import("pabrikcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = pabrikcore.agent;
const generate_image_mod = pabrikcore.generate_image;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execGenerateImage(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        generate_image_mod.GenerateImageInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "generate_image failed to parse input: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "generate_image", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = generate_image_mod.execute_generate_image(
        ctx.allocator,
        ctx.io,
        parsed.value,
        ctx.base_url,
        ctx.api_key,
        ctx.cwd,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "generate_image failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "generate_image", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // <generate_image><error> → success=false
    if (std.mem.indexOf(u8, inner, "<error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse inner.len - err_start;
        const err_msg = inner[err_start .. err_start + err_end];
        const output = try wrapToolOutput(ctx.allocator, "generate_image", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "generate_image", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}
```

Commit: `feat(tools): add execGenerateImage wrapper`.

## Task 5 — Docs — ~15 minutes

Add a `## generate_image` section to `docs/agent-tools.md` that mirrors the layout of `## show_preview`:

```md
## `generate_image`

Generate an image from a text prompt using the OpenAI Images API (DALL-E 2 / DALL-E 3 / gpt-image-1).

**Input** (JSON object):
- `prompt` (required, string): description of the image to generate
- `model` (optional, string, default `"dall-e-3"`): one of `"dall-e-2"`, `"dall-e-3"`, `"gpt-image-1"`
- `n` (optional, integer, default `1`, range 1-10): number of images
- `size` (optional, string, default `"1024x1024"`): depends on model
- `quality` (optional, string, dall-e-3 only): `"standard"` or `"hd"`
- `style` (optional, string, dall-e-3 only): `"vivid"` or `"natural"`
- `response_format` (optional, string, default `"b64_json"`): `"url"` or `"b64_json"`
- `user` (optional, string): end-user identifier

**Behaviour:** Calls `POST <base_url>/images/generations` using the active profile's `api_key` and `base_url`. Saves the image to `<cwd>/generated_images/img_<ts>_<idx>.png`. Returns an XML envelope with the saved paths.

**Output to LLM** (success envelope): `<generate_image><status>generated</status>...<images><image path="..." bytes="..." mime="..."/></images>...</generate_image>`

**Output to LLM** (error envelope): `<generate_image><error>HTTP 400: ...</error></generate_image>`

**Next step:** Call `show_preview` with `content_type="image"`, `path=<path>` to display the image.

**Auth:** Uses the active profile's `api_key` + `base_url` (same as the chat completion calls).
```

Commit: `docs: add generate_image section to agent-tools.md`.

## Task 6 — Final verification — ~10 minutes

```sh
zig build test --summary all 2>&1 | tail -n 20
```

Expect: baseline test count + ~31 new generate_image tests, all passing.

Manual smoke test (requires a real OpenAI key in `~/.config/pabrik/config.json`):

```sh
# In the desktop app: open a chat and ask the agent
"Generate an image of a cute cat wearing a hat"
```

Expected: agent calls `generate_image`, gets back an envelope with `<image path="/cwd/generated_images/img_xxx.png" .../>`, then calls `show_preview` with `content_type="image"` + `path=<path>`. The image renders in the side panel.

Commit: `test: verify all generate_image tests pass` (only if any fix-ups were needed; otherwise amend the prior commit).

## Task 7 — Open PR + move kanban card

- [ ] `git push -u origin worktree/generate-image-tool`
- [ ] Open PR: `feat(tools): add generate_image agent tool (OpenAI Images API)`
- [ ] Move the kanban card `new agent tool generate_image` from `in progress` → `in_review_task` via `kanban_move_task`.
- [ ] Wait for the user to review + merge.

## Why this design

- **Save to disk + return path**: durable (URLs expire), works with any image size (no 1 MiB cap issue), lets the existing `show_preview` tool handle rendering without any new frontend code.
- **Use the active profile's `base_url` + `api_key`**: zero new config; same OpenAI key works for both chat and image gen.
- **XML envelope**: matches every other tool in the project (`<show_preview>`, `<kanban_list>`, etc.).
- **Hand-built JSON**: avoids the `std.json.Value` allocation + guarantees "no nulls in JSON" (OpenAI rejects null fields with confusing 400s for some params).
- **`b64_json` by default**: the only way to get raw bytes we can save.
- **No new SSE event type**: tool flows through `llm_full` event with `tool_name='generate_image'` — same as `bash`, `show_preview`, etc.
- **No new Vue component**: the agent renders the image by calling `show_preview`, which is already a first-class tool.
- **One-shot tool**: no async / streaming / background-mode needed. A DALL-E 3 call takes 5-30s, well within the standard `execute_*` synchronous budget. If we ever need to support long-running image jobs (gpt-image-1 background mode), that's a future plan.

## Open questions for the user

1. **Default `model`** — `dall-e-3` (good quality, $0.04/image) is the recommendation. Alternative: `dall-e-2` ($0.02/image, allows n>1) or `gpt-image-1` ($0.04-$0.25 depending on size/quality). Plan defaults to dall-e-3; change if you'd rather.
2. **Save location** — plan saves to `<cwd>/generated_images/`. Alternative: a global dir like `~/.cache/pabrik/generated_images/<session_id>/` (avoids polluting the user's workspace but makes the image "invisible" to other agents). Plan: per-cwd, because the cwd is the session's working dir and the user explicitly opted into image gen there.
3. **`revised_prompt` visibility** — DALL-E 3 silently rewrites prompts. Plan includes the revised_prompt in the output so the agent can see what was actually used. Alternative: hide it (less verbose but lies about what the model saw).
4. **Cleanup** — generated images stay on disk forever (user can manually `bash rm`). Alternative: auto-clean after N days (over-engineered for v1).

If any of these decisions feel wrong, surface them before execution and we'll amend.