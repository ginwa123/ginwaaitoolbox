# FileInput Microphone (Voice-to-Text) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a microphone button to `FileInput.vue` that captures the user's speech via `navigator.mediaDevices.getUserMedia` + `MediaRecorder`, uploads the audio to a new `POST /api/transcribe` endpoint, and inserts the transcribed text into the input textarea at the cursor position. Support both **toggle mode** (click to start, click again to stop) and **hold mode** (press-and-hold to record, release to stop) on the same button.

**Architecture:**
- **Frontend**: New `MicButton.vue` component encapsulates the MediaRecorder state machine, talk/hold gesture detection, and visual states (idle / recording / processing / error). Calls a new `api.transcribe(blob)` helper that POSTs the audio to the backend. `FileInput.vue` renders the button next to the paperclip button and inserts the returned text into `inputText` at the cursor position via a new `insertTextAtCursor()` helper.
- **Backend**: New Zig HTTP handler `POST /api/transcribe` in `src/ai_workflow/tui/http_handlers/transcribe.zig`. Accepts the audio as `application/octet-stream` raw bytes (simpler than multipart parsing in Zig — frontend already uses `FileReader.readAsArrayBuffer` patterns elsewhere). Reads `LlmConfig.base_url` + `api_key` via `nalarcore.getLlmConfig(di)`, constructs a `multipart/form-data` request body in Zig (~30 lines using `@import("std").fmt`), POSTs to `<base_url>/audio/transcriptions` with `model=whisper-1` via the existing `HttpClient` module. Returns `{ text: "..." }` JSON.

**Tech Stack:** Vue 3.5 + TypeScript + Vite + Bun (Vitest + @vue/test-utils + jsdom). Zig 0.16 + `std.Io.Threaded` + `src/modules/http/HttpClient.zig` (curl-backed). No new dependencies.

---

## File Structure

| File | Responsibility |
|------|----------------|
| **Create** `src/ai_workflow/tui/http_handlers/transcribe.zig` | New `transcribeHandler` — reads raw audio body, calls upstream Whisper API, returns `{ text: "..." }`. |
| **Create** `src/ai_workflow/tui/http_handlers/transcribe_test.zig` | Static-contract tests: route path, raw-bytes body handling, multipart construction, JSON response shape. |
| **Modify** `src/ai_workflow/tui/http_handlers/mod.zig` | Re-export `transcribeHandler`. |
| **Modify** `src/main.zig` (around line 258) | Register `try gs.router.post("/api/transcribe", ai_mod.http_handlers.transcribeHandler);` |
| **Modify** `src/apps/desktop/src/api/index.ts` | Add `transcribe(audioBlob: Blob): Promise<{ text: string }>` helper. |
| **Create** `src/apps/desktop/src/components/MicButton.vue` | New mic button component (toggle + hold gesture, MediaRecorder state machine, idle/recording/processing/error visual states). |
| **Create** `src/apps/desktop/src/__tests__/FileInput.mic.spec.ts` | End-to-end tests: toggle mode, hold mode, error states, text insertion. |
| **Create** `src/apps/desktop/src/__tests__/stubs/mediaRecorder.ts` | Inert `MediaRecorder` stub for jsdom tests (constructor + event emitters + state methods). |
| **Create** `src/apps/desktop/src/__tests__/stubs/mediaDevices.ts` | Inert `navigator.mediaDevices.getUserMedia` stub. |
| **Modify** `src/apps/desktop/src/__tests__/setup.ts` | Install `MediaRecorder` + `mediaDevices` polyfills. |
| **Modify** `src/apps/desktop/src/components/FileInput.vue` | Render `<MicButton>` between paperclip and Send buttons. Add `insertTextAtCursor()` helper. Expose `inputText` via `defineExpose` for parent test access. |

---

## Chunk 1: Backend transcription endpoint (Zig)

### Task 1.1: Static contract tests for `transcribe.zig`

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/transcribe_test.zig`

The project convention (per `git_pr_create_test.zig` and `git_worktree_info_test.zig`) is **static source-check tests** that read the handler source as text and grep for required substrings. We don't have a real `GinwaServer` test infrastructure. Follow this pattern.

- [ ] **Step 1: Create the static-test file with route-registration contract test**

```zig
const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/transcribe.zig";
const MAIN_PATH = "src/main.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1 << 20);
}

test "transcribe.zig exists and declares transcribeHandler" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn transcribeHandler") == null) {
        std.debug.print("!! transcribe.zig does not declare transcribeHandler !!\n", .{});
        return error.TranscribeHandlerMissing;
    }
}

test "transcribe.zig accepts raw body (does not require JSON parse)" {
    // We POST audio/webm raw bytes, NOT JSON — so the handler must
    // read req.body directly (NOT std.json.parseFromSlice).
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "parseFromSlice") != null) {
        std.debug.print("!! transcribe.zig must not call parseFromSlice on the request body !!\n", .{});
        return error.ParseFromSliceMustNotBeUsed;
    }
    if (std.mem.indexOf(u8, source, "req.body") == null) {
        std.debug.print("!! transcribe.zig does not read req.body !!\n", .{});
        return error.ReqBodyNotRead;
    }
}

test "transcribe.zig reads LlmConfig via nalarcore.getLlmConfig" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "nalarcore.getLlmConfig") == null) {
        std.debug.print("!! transcribe.zig does not call nalarcore.getLlmConfig !!\n", .{});
        return error.GetLlmConfigMissing;
    }
    if (std.mem.indexOf(u8, source, "getSingleton") == null) {
        std.debug.print("!! transcribe.zig does not call nalarcore.getSingleton !!\n", .{});
        return error.GetSingletonMissing;
    }
}

test "transcribe.zig POSTs to upstream /audio/transcriptions" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "audio/transcriptions") == null) {
        std.debug.print("!! transcribe.zig does not target /audio/transcriptions !!\n", .{});
        return error.UpstreamPathMissing;
    }
    if (std.mem.indexOf(u8, source, "whisper-1") == null) {
        std.debug.print("!! transcribe.zig does not use whisper-1 model !!\n", .{});
        return error.WhisperModelMissing;
    }
}

test "transcribe.zig returns JSON with .text field" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, ".text") == null) {
        std.debug.print("!! transcribe.zig response struct does not have a .text field !!\n", .{});
        return error.ResponseTextFieldMissing;
    }
}

test "transcribe.zig returns 501 when Whisper not configured" {
    const source = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(source);
    // If the user has not configured api_key / base_url, we return 501
    // (not 500 — 501 is "Not Implemented" and tells the frontend to
    // show "Configure transcription in nalar settings" rather than
    // a generic server error).
    if (std.mem.indexOf(u8, source, "501") == null) {
        std.debug.print("!! transcribe.zig does not return 501 when Whisper is unconfigured !!\n", .{});
        return error.UnconfiguredStatusCodeMissing;
    }
}

test "main.zig registers POST /api/transcribe" {
    const source = try readSource(testing.allocator, MAIN_PATH);
    defer testing.allocator.free(source);
    if (std.mem.indexOf(u8, source, "/api/transcribe") == null) {
        std.debug.print("!! main.zig does not register /api/transcribe !!\n", .{});
        return error.RouteRegistrationMissing;
    }
    if (std.mem.indexOf(u8, source, "transcribeHandler") == null) {
        std.debug.print("!! main.zig does not reference transcribeHandler !!\n", .{});
        return error.HandlerReferenceMissing;
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (red phase)**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: FAIL — all 7 tests fail with `TranscribeHandlerMissing`, `ParseFromSliceMustNotBeUsed`, etc. (the file does not exist yet).

- [ ] **Step 3: Register the new test in `src/ai_workflow/tui/test_runner.zig`**

Open `src/ai_workflow/tui/test_runner.zig` and add (next to the other `*_test.zig` imports):

```zig
_ = @import("http_handlers/transcribe_test.zig");
```

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/transcribe_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "test: add static contract tests for transcribe endpoint (red)"
```

---

### Task 1.2: Implement `transcribe.zig` skeleton + route registration

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/transcribe.zig`
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig`
- Modify: `src/main.zig` (around line 258)

- [ ] **Step 1: Implement the handler with stub upstream call**

```zig
// src/ai_workflow/tui/http_handlers/transcribe.zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const config = nalarcore.config;
const LlmConfig = config.LlmConfig;
const HttpClient = @import("../../http/HttpClient.zig").HttpClient;

/// Response shape for POST /api/transcribe
pub const TranscribeResponse = struct {
    text: []const u8 = "",
    @"error": ?[]const u8 = null,
};

/// POST /api/transcribe
///
/// Accepts raw audio bytes (audio/webm or audio/ogg) as the request body
/// and forwards them to the configured OpenAI-compatible Whisper endpoint
/// (`<base_url>/audio/transcriptions`, model `whisper-1`). The user's
/// existing `api_endpoint` and `api_key` config are reused.
///
/// Returns 501 if the user has not configured an LLM endpoint (no
/// `base_url` set in the config). Returns 502 if the upstream call
/// fails. Returns 200 with `{ "text": "..." }` on success.
pub fn transcribeHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // 1. Load config from singleton
    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "Global context not initialized",
            }),
        });
    };
    const cfg = nalarcore.getLlmConfig(di);

    // 2. Validate Whisper is configured
    if (cfg.base_url.len == 0 or cfg.api_key.len == 0) {
        return res.jsonResponse(.{
            .status_code = 501,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "Transcription not configured. Set api_endpoint and api_key in Nalar settings.",
            }),
        });
    }

    // 3. Validate we have audio bytes
    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "Empty audio body",
            }),
        });
    }

    // 4. Determine MIME type from Content-Type header (default: audio/webm)
    var mime_type: []const u8 = "audio/webm";
    if (req.headers.get("Content-Type")) |ct| {
        if (std.mem.indexOf(u8, ct, "audio/ogg") != null) mime_type = "audio/ogg";
        if (std.mem.indexOf(u8, ct, "audio/mp4") != null) mime_type = "audio/mp4";
        if (std.mem.indexOf(u8, ct, "audio/wav") != null) mime_type = "audio/wav";
    }

    // 5. Build multipart/form-data body for upstream Whisper API.
    //    Boundary is a 16-byte random hex string. We assemble the
    //    boundary here so we can also stamp it into the Content-Type
    //    header that goes to the upstream.
    var boundary_buf: [33]u8 = undefined;
    const boundary = try generateBoundary(&boundary_buf);

    const multipart_body = try buildMultipartBody(
        allocator,
        boundary,
        req.body,
        mime_type,
        "whisper-1",
    );

    // 6. POST to upstream Whisper endpoint
    const upstream_url = try std.fmt.allocPrint(
        allocator,
        "{s}/audio/transcriptions",
        .{cfg.base_url},
    );

    const content_type_header = try std.fmt.allocPrint(
        allocator,
        "multipart/form-data; boundary={s}",
        .{boundary},
    );

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try headers.put("Content-Type", content_type_header);
    try headers.put("Authorization", try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.api_key}));

    var client = HttpClient.init(allocator, io);
    defer client.deinit();

    const upstream_result = client.post(upstream_url, multipart_body, headers) catch {
        return res.jsonResponse(.{
            .status_code = 502,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "Upstream transcription service unavailable",
            }),
        });
    };

    if (upstream_result.status_code != 200) {
        return res.jsonResponse(.{
            .status_code = 502,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = try std.fmt.allocPrint(
                    allocator,
                    "Upstream returned {d}: {s}",
                    .{ upstream_result.status_code, upstream_result.body },
                ),
            }),
        });
    }

    // 7. Parse upstream JSON `{ "text": "..." }` and return.
    const parsed = std.json.parseFromSliceLeaky(
        struct { text: []const u8 },
        allocator,
        upstream_result.body,
        .{},
    ) catch {
        return res.jsonResponse(.{
            .status_code = 502,
            .data = try http_response.makeErrorResponse(allocator, .{
                .@"error" = "Upstream returned unparseable response",
            }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(
            allocator,
            "{{\"text\":\"{s}\"}}",
            .{parsed.text},
        ),
    });
}

/// Generate a 32-hex-char multipart boundary. Returns a slice into buf.
fn generateBoundary(buf: *[33]u8) ![]u8 {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        buf[i] = hex[i % 16]; // Deterministic — not security-sensitive
    }
    buf[32] = 0;
    return buf[0..32];
}

/// Build a multipart/form-data body for the upstream Whisper API.
///
/// Shape:
///   --<boundary>\r\n
///   Content-Disposition: form-data; name="model"\r\n\r\n
///   whisper-1\r\n
///   --<boundary>\r\n
///   Content-Disposition: form-data; name="file"; filename="audio.webm"\r\n
///   Content-Type: audio/webm\r\n\r\n
///   <audio bytes>\r\n
///   --<boundary>--\r\n
fn buildMultipartBody(
    allocator: std.mem.Allocator,
    boundary: []const u8,
    audio_bytes: []const u8,
    mime_type: []const u8,
    model: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const filename = switch (std.mem.indexOf(u8, mime_type, "/") orelse 0) {
        0 => "audio.bin",
        else => blk: {
            const ext_start = (std.mem.indexOf(u8, mime_type, "/") orelse 0) + 1;
            break :blk try std.fmt.allocPrint(allocator, "audio.{s}", .{mime_type[ext_start..]});
        },
    };

    try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "--{s}\r\n", .{boundary}));
    try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "Content-Disposition: form-data; name=\"model\"\r\n\r\n{s}\r\n", .{model}));
    try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "--{s}\r\n", .{boundary}));
    try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "Content-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\n", .{filename}));
    try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "Content-Type: {s}\r\n\r\n", .{mime_type}));
    try buf.appendSlice(allocator, audio_bytes);
    try buf.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\r\n--{s}--\r\n", .{boundary}));

    return try buf.toOwnedSlice(allocator);
}
```

- [ ] **Step 2: Add the re-export to `mod.zig`**

Open `src/ai_workflow/tui/http_handlers/mod.zig` and add at the bottom (matching the alphabetical ordering if any):

```zig
pub const transcribe = @import("transcribe.zig");
```

- [ ] **Step 3: Register the route in `main.zig`**

Open `src/main.zig`, find the line `try gs.router.post("/api/llm/session", ...)` (around line 258), and add right after it:

```zig
try gs.router.post("/api/transcribe", ai_mod.http_handlers.transcribeHandler);
```

- [ ] **Step 4: Run tests to verify they pass (green phase)**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: all 7 transcribe_test.zig tests pass. Total test count increases by 7.

If `HttpClient` import path is wrong, see `src/modules/http/HttpClient.zig` line 1 and adjust the `const HttpClient = ...` line in `transcribe.zig` accordingly. The pattern `../../http/HttpClient.zig` is relative to `src/ai_workflow/tui/http_handlers/transcribe.zig`, going up two levels then into `http/`.

- [ ] **Step 5: Run the full build to verify it compiles end-to-end**

Run: `timeout 180 zig build install:linux:system 2>&1 | tail -n 15`
Expected: 4/6 steps succeed (the 5th is `cp /usr/local/bin/nalar` which fails harmlessly with permission denied). **MUST** see no compile errors in `transcribe.zig`.

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/transcribe.zig \
        src/ai_workflow/tui/http_handlers/transcribe_test.zig \
        src/ai_workflow/tui/http_handlers/mod.zig \
        src/main.zig
git commit -m "feat(transcribe): add POST /api/transcribe endpoint (Whisper)"
```

---

## Chunk 2: Frontend API client (`api.transcribe`)

### Task 2.1: Failing test for `api.transcribe()`

**Files:**
- Create: `src/apps/desktop/src/__tests__/apiTranscribe.spec.ts`
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 1: Write failing test**

```typescript
// src/apps/desktop/src/__tests__/apiTranscribe.spec.ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { apiTranscribe } from '../api/transcribe'

describe('apiTranscribe', () => {
  let fetchMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('POSTs the audio Blob to /api/transcribe and returns { text }', async () => {
    const blob = new Blob(['fake-audio-bytes'], { type: 'audio/webm' })
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ text: 'hello world' }),
      text: () => Promise.resolve('{"text":"hello world"}'),
    })

    const result = await apiTranscribe(blob)

    expect(result).toEqual({ text: 'hello world' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe('/api/transcribe')
    expect(init.method).toBe('POST')
    expect(init.body).toBe(blob) // raw Blob, NOT JSON
    // Content-Type is NOT 'application/json' — we send raw audio
    const headers = init.headers as Record<string, string>
    expect(headers['Content-Type']).toBe('audio/webm')
  })

  it('uses the Blob mime type for the Content-Type header', async () => {
    const blob = new Blob(['ogg'], { type: 'audio/ogg' })
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ text: 'hi' }),
      text: () => Promise.resolve('{"text":"hi"}'),
    })

    await apiTranscribe(blob)

    const headers = (fetchMock.mock.calls[0][1] as RequestInit).headers as Record<string, string>
    expect(headers['Content-Type']).toBe('audio/ogg')
  })

  it('throws ApiError on 4xx response', async () => {
    const blob = new Blob(['x'], { type: 'audio/webm' })
    fetchMock.mockResolvedValueOnce({
      ok: false,
      status: 501,
      statusText: 'Not Implemented',
      json: () => Promise.resolve({ error: 'Transcription not configured' }),
      text: () => Promise.resolve('{"error":"Transcription not configured"}'),
    })

    await expect(apiTranscribe(blob)).rejects.toThrow(/Transcription not configured/)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run apiTranscribe 2>&1 | tail -n 20`
Expected: FAIL — `Failed to resolve import "../api/transcribe"` (the file doesn't exist yet).

- [ ] **Step 3: Implement `transcribe.ts`**

Create `src/apps/desktop/src/api/transcribe.ts`:

```typescript
// src/apps/desktop/src/api/transcribe.ts

/**
 * Send a recorded audio Blob to the backend for transcription.
 *
 * The backend (POST /api/transcribe) accepts raw audio bytes (NOT
 * JSON, NOT multipart) — it forwards them to the user's configured
 * OpenAI-compatible Whisper endpoint and returns the transcribed text.
 *
 * @param audioBlob - Audio recorded via MediaRecorder (audio/webm
 *   by default in Chromium-based browsers; audio/ogg in Firefox).
 * @returns The transcribed text on success.
 * @throws {ApiError} On non-2xx response (e.g. 501 if Whisper is
 *   not configured in nalar settings).
 */
export async function apiTranscribe(
  audioBlob: Blob,
): Promise<{ text: string }> {
  const response = await fetch('/api/transcribe', {
    method: 'POST',
    headers: {
      'Content-Type': audioBlob.type || 'audio/webm',
    },
    body: audioBlob,
  })

  if (!response.ok) {
    const body = await response.text().catch(() => '')
    throw new Error(
      `Transcription failed (${response.status}): ${body || response.statusText}`,
    )
  }

  const data = (await response.json()) as { text: string }
  return data
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run apiTranscribe 2>&1 | tail -n 20`
Expected: PASS — all 3 tests green.

- [ ] **Step 5: Type-check (mandatory before commit)**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean (no TS errors). This is the project's authoritative type-check; `vitest run` alone does NOT run `vue-tsc`. See project memory `desktop-typescript-bun-build-as-typecheck.md`.

- [ ] **Step 6: Commit**

```bash
git add src/apps/desktop/src/api/transcribe.ts \
        src/apps/desktop/src/__tests__/apiTranscribe.spec.ts
git commit -m "feat(transcribe): add apiTranscribe() helper for /api/transcribe"
```

---

## Chunk 3: Test stubs for `MediaRecorder` + `navigator.mediaDevices.getUserMedia`

### Task 3.1: Inert jsdom polyfills

**Files:**
- Create: `src/apps/desktop/src/__tests__/stubs/mediaRecorder.ts`
- Create: `src/apps/desktop/src/__tests__/stubs/mediaDevices.ts`
- Modify: `src/apps/desktop/src/__tests__/setup.ts`
- Modify: `vitest.config.ts`

The existing `monaco-editor` stub (in `vitest.config.ts` `resolve.alias`) is a precedent — we use the same approach for `MediaRecorder` and `mediaDevices` because vite's import-analysis runs before `vi.mock`. Tests then use `vi.stubGlobal` to override the stub with a programmable mock per test.

- [ ] **Step 1: Create `mediaRecorder.ts` stub**

```typescript
// src/apps/desktop/src/__tests__/stubs/mediaRecorder.ts
//
// Inert MediaRecorder stub for jsdom. The real MediaRecorder emits
// 'dataavailable' and 'stop' events; tests replace this class with a
// programmable version via `vi.stubGlobal('MediaRecorder', MockMediaRecorder)`.
//
// This stub satisfies vite's import-analysis so any component file
// that references `MediaRecorder` (e.g. `new MediaRecorder(stream)`)
// can be module-loaded without crashing. It is NOT used at runtime
// in tests — see `createMockMediaRecorder()` in FileInput.mic.spec.ts.

export type MediaRecorderEvent = 'dataavailable' | 'stop' | 'error' | 'start' | 'pause' | 'resume'

export class MediaRecorder {
  static readonly inactive = 'inactive'
  static readonly recording = 'recording'
  static readonly paused = 'paused'

  readonly stream: MediaStream
  state: string = MediaRecorder.inactive
  ondataavailable: ((ev: BlobEvent) => void) | null = null
  onstop: ((ev: Event) => void) | null = null
  onerror: ((ev: Event) => void) | null = null
  onstart: ((ev: Event) => void) | null = null

  constructor(stream: MediaStream) {
    this.stream = stream
  }

  start(_timeslice?: number): void {
    this.state = MediaRecorder.recording
  }
  stop(): void {
    this.state = MediaRecorder.inactive
  }
  pause(): void {
    this.state = MediaRecorder.paused
  }
  resume(): void {
    this.state = MediaRecorder.recording
  }
  addEventListener(_type: string, _listener: EventListenerOrEventListenerObject): void {}
  removeEventListener(_type: string, _listener: EventListenerOrEventListenerObject): void {}
  requestData(): void {}
}

export default MediaRecorder
```

- [ ] **Step 2: Create `mediaDevices.ts` stub**

```typescript
// src/apps/desktop/src/__tests__/stubs/mediaDevices.ts
//
// Inert navigator.mediaDevices stub for jsdom. The real
// `navigator.mediaDevices.getUserMedia(constraints)` returns a
// Promise<MediaStream>. Tests replace this with a programmable
// version via `vi.stubGlobal('navigator', { mediaDevices: { getUserMedia: mock } })`.
//
// This stub satisfies vite's import-analysis so any component file
// that references `navigator.mediaDevices.getUserMedia` can be
// module-loaded without crashing.

export interface MediaStream {
  getTracks(): MediaStreamTrack[]
  getAudioTracks(): MediaStreamTrack[]
}

export interface MediaStreamTrack {
  kind: string
  stop(): void
}

export const mediaDevices = {
  getUserMedia: async (_constraints: MediaStreamConstraints): Promise<MediaStream> => {
    return {
      getTracks: () => [],
      getAudioTracks: () => [],
    }
  },
  enumerateDevices: async (): Promise<MediaDeviceInfo[]> => [],
}

export default { mediaDevices }
```

- [ ] **Step 3: Register stubs in `vitest.config.ts`**

Open `vitest.config.ts` and extend the `resolve.alias` block:

```typescript
resolve: {
  alias: {
    'monaco-editor': fileURLToPath(
      new URL('./src/__tests__/stubs/monaco-editor.ts', import.meta.url),
    ),
    'media-recorder-stub': fileURLToPath(
      new URL('./src/__tests__/stubs/mediaRecorder.ts', import.meta.url),
    ),
  },
},
```

(We use a sub-path import `media-recorder-stub` so component code that wants the real `MediaRecorder` at runtime does NOT have to change — vite's alias only resolves the bare-specifier when explicitly imported.)

- [ ] **Step 4: Verify stubs are correctly installed**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run --reporter=verbose 2>&1 | tail -n 20`
Expected: existing 31 tests still pass. No new tests yet.

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/__tests__/stubs/mediaRecorder.ts \
        src/apps/desktop/src/__tests__/stubs/mediaDevices.ts \
        vitest.config.ts
git commit -m "test: add inert MediaRecorder + mediaDevices stubs for jsdom"
```

---

## Chunk 4: `MicButton.vue` component

### Task 4.1: Failing tests for the MicButton (toggle + hold modes)

**Files:**
- Create: `src/apps/desktop/src/__tests__/FileInput.mic.spec.ts`

- [ ] **Step 1: Write the test file**

```typescript
// src/apps/desktop/src/__tests__/FileInput.mic.spec.ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { nextTick } from 'vue'
import MicButton from '../components/MicButton.vue'

// ── Programmable MediaRecorder mock ───────────────────────────────────────

interface MockMediaRecorder {
  start: ReturnType<typeof vi.fn>
  stop: ReturnType<typeof vi.fn>
  pause: ReturnType<typeof vi.fn>
  resume: ReturnType<typeof vi.fn>
  state: 'inactive' | 'recording' | 'paused'
  // Programmable event emitters (tests call these to simulate the
  // browser firing events).
  emitDataAvailable: (blob: Blob) => void
  emitStop: () => void
  emitError: (message: string) => void
  // Capture the listeners so tests can simulate events directly.
  dataavailableHandler: ((ev: { data: Blob }) => void) | null
  stopHandler: ((ev: Event) => void) | null
  errorHandler: ((ev: { error?: Error }) => void) | null
}

function createMockMediaRecorder(): MockMediaRecorder {
  const mr: MockMediaRecorder = {
    start: vi.fn(),
    stop: vi.fn(),
    pause: vi.fn(),
    resume: vi.fn(),
    state: 'inactive',
    dataavailableHandler: null,
    stopHandler: null,
    errorHandler: null,
    emitDataAvailable(blob: Blob) {
      mr.dataavailableHandler?.({ data: blob })
    },
    emitStop() {
      mr.stopHandler?.(new Event('stop'))
    },
    emitError(message: string) {
      mr.errorHandler?.({ error: new Error(message) })
    },
  }
  // start() switches state to 'recording'. Tests verify the call.
  mr.start.mockImplementation(() => {
    mr.state = 'recording'
  })
  mr.stop.mockImplementation(() => {
    mr.state = 'inactive'
  })
  return mr
}

// Capture the MediaRecorder instance the component creates, so tests
// can drive its event handlers.
let lastRecorder: MockMediaRecorder | null = null

vi.stubGlobal(
  'MediaRecorder',
  class {
    constructor(_stream: MediaStream) {
      lastRecorder = createMockMediaRecorder()
      // Mirror the real MediaRecorder API surface used by MicButton
      return lastRecorder as unknown as MediaRecorder
    }
    static readonly inactive = 'inactive'
    static readonly recording = 'recording'
    static readonly paused = 'paused'
  },
)

// Stub getUserMedia to return a fake MediaStream synchronously.
vi.stubGlobal('navigator', {
  mediaDevices: {
    getUserMedia: vi.fn(async () => ({
      getTracks: () => [{ kind: 'audio', stop: vi.fn() }],
      getAudioTracks: () => [{ kind: 'audio', stop: vi.fn() }],
    })),
  },
})

// Stub apiTranscribe so we can control transcription responses.
vi.mock('../api/transcribe', () => ({
  apiTranscribe: vi.fn(),
}))
import { apiTranscribe } from '../api/transcribe'
const apiTranscribeMock = apiTranscribe as ReturnType<typeof vi.fn>

// ── Tests ──────────────────────────────────────────────────────────────────

describe('MicButton — toggle mode', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    lastRecorder = null
    apiTranscribeMock.mockReset()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.clearAllMocks()
  })

  it('renders an idle mic button by default', () => {
    wrapper = mount(MicButton)
    expect(wrapper.find('[data-testid="mic-button"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('idle')
  })

  it('click toggles into recording state and starts MediaRecorder', async () => {
    wrapper = mount(MicButton)
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    expect(lastRecorder).not.toBeNull()
    expect(lastRecorder!.start).toHaveBeenCalledTimes(1)
    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('recording')
  })

  it('clicking again stops recording, transcribes, and emits the text', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'hello world' })

    wrapper = mount(MicButton)
    const btn = wrapper.find('[data-testid="mic-button"]')

    // First click → start recording
    await btn.trigger('click')
    await flushPromises()
    expect(lastRecorder).not.toBeNull()
    expect(lastRecorder!.start).toHaveBeenCalledTimes(1)

    // Second click → stop recording (toggle off)
    await btn.trigger('click')
    expect(lastRecorder!.stop).toHaveBeenCalledTimes(1)

    // Simulate browser firing dataavailable + stop on the MediaRecorder
    const audioBlob = new Blob(['fake-audio'], { type: 'audio/webm' })
    lastRecorder!.emitDataAvailable(audioBlob)
    lastRecorder!.emitStop()
    await flushPromises()

    // apiTranscribe was called with the blob
    expect(apiTranscribeMock).toHaveBeenCalledTimes(1)
    expect(apiTranscribeMock.mock.calls[0][0]).toBe(audioBlob)

    // emitted with the transcribed text
    const emitted = wrapper.emitted('transcribed')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['hello world'])

    // returns to idle
    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('idle')
  })

  it('shows processing state while transcription is in flight', async () => {
    let resolveTranscribe: (v: { text: string }) => void
    apiTranscribeMock.mockImplementationOnce(
      () => new Promise((resolve) => { resolveTranscribe = resolve }),
    )

    wrapper = mount(MicButton)
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    // Now in 'processing' state
    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('processing')

    // Resolve transcription
    resolveTranscribe!({ text: 'done' })
    await flushPromises()
    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('idle')
  })
})

describe('MicButton — hold mode', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    lastRecorder = null
    apiTranscribeMock.mockReset()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.clearAllMocks()
  })

  it('mousedown starts recording, mouseup stops and transcribes', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'hold text' })

    wrapper = mount(MicButton)
    const btn = wrapper.find('[data-testid="mic-button"]')

    await btn.trigger('mousedown')
    await flushPromises()
    expect(lastRecorder!.start).toHaveBeenCalledTimes(1)
    expect(btn.attributes('data-state')).toBe('recording')

    await btn.trigger('mouseup')
    expect(lastRecorder!.stop).toHaveBeenCalledTimes(1)

    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    expect(apiTranscribeMock).toHaveBeenCalledTimes(1)
    const emitted = wrapper.emitted('transcribed')
    expect(emitted![0]).toEqual(['hold text'])
  })

  it('touchstart starts recording, touchend stops it', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'touch text' })

    wrapper = mount(MicButton)
    const btn = wrapper.find('[data-testid="mic-button"]')

    await btn.trigger('touchstart')
    await flushPromises()
    expect(lastRecorder!.start).toHaveBeenCalledTimes(1)

    await btn.trigger('touchend')
    expect(lastRecorder!.stop).toHaveBeenCalledTimes(1)
  })
})

describe('MicButton — error states', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    lastRecorder = null
    apiTranscribeMock.mockReset()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.clearAllMocks()
  })

  it('shows error state and emits error when getUserMedia is denied', async () => {
    // Override getUserMedia for this test
    ;(navigator.mediaDevices.getUserMedia as ReturnType<typeof vi.fn>).mockRejectedValueOnce(
      new Error('Permission denied'),
    )

    wrapper = mount(MicButton)
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('error')
    const errEmitted = wrapper.emitted('error')
    expect(errEmitted).toBeTruthy()
    expect(String(errEmitted![0][0])).toMatch(/Permission denied/)
  })

  it('shows error state when transcription API fails', async () => {
    apiTranscribeMock.mockRejectedValueOnce(new Error('Upstream 502'))

    wrapper = mount(MicButton)
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    expect(wrapper.find('[data-testid="mic-button"]').attributes('data-state')).toBe('error')
  })
})
```

- [ ] **Step 2: Run tests to verify they fail (red)**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run FileInput.mic 2>&1 | tail -n 25`
Expected: FAIL — `Failed to resolve import "../components/MicButton.vue"` (file doesn't exist).

- [ ] **Step 3: Commit (the failing test)**

```bash
git add src/apps/desktop/src/__tests__/FileInput.mic.spec.ts
git commit -m "test: add MicButton toggle + hold + error tests (red)"
```

---

### Task 4.2: Implement `MicButton.vue`

**Files:**
- Create: `src/apps/desktop/src/components/MicButton.vue`

- [ ] **Step 1: Write the component**

```vue
<!-- src/apps/desktop/src/components/MicButton.vue -->
<script setup lang="ts">
import { ref } from 'vue'
import { apiTranscribe } from '../api/transcribe'

type MicState = 'idle' | 'recording' | 'processing' | 'error'

const emit = defineEmits<{
  transcribed: [text: string]
  error: [message: string]
}>()

const props = defineProps<{
  disabled?: boolean
}>()

const state = ref<MicState>('idle')
const errorMessage = ref<string>('')
let mediaRecorder: MediaRecorder | null = null
let mediaStream: MediaStream | null = null
let recordedChunks: Blob[] = []

// Hold-mode gesture detection
const HOLD_THRESHOLD_MS = 250
let pressTimer: ReturnType<typeof setTimeout> | null = null
let mode: 'toggle' | 'hold' = 'idle' // current gesture in progress

function resetState() {
  state.value = 'idle'
  errorMessage.value = ''
  mode = 'idle'
  if (pressTimer) {
    clearTimeout(pressTimer)
    pressTimer = null
  }
}

async function ensurePermissions(): Promise<MediaStream> {
  if (!navigator.mediaDevices?.getUserMedia) {
    throw new Error('Microphone API not available in this browser')
  }
  return await navigator.mediaDevices.getUserMedia({ audio: true })
}

async function startRecording() {
  try {
    recordedChunks = []
    errorMessage.value = ''
    mediaStream = await ensurePermissions()
    mediaRecorder = new MediaRecorder(mediaStream)

    mediaRecorder.addEventListener('dataavailable', (ev: Event) => {
      const blob = (ev as BlobEvent).data
      if (blob && blob.size > 0) recordedChunks.push(blob)
    })
    mediaRecorder.addEventListener('stop', () => {
      void finalizeRecording()
    })
    mediaRecorder.addEventListener('error', (ev: Event) => {
      const errEvent = ev as { error?: Error }
      state.value = 'error'
      errorMessage.value = errEvent.error?.message ?? 'Recording error'
      emit('error', errorMessage.value)
    })

    mediaRecorder.start()
    state.value = 'recording'
  } catch (err) {
    state.value = 'error'
    errorMessage.value = err instanceof Error ? err.message : String(err)
    emit('error', errorMessage.value)
    cleanupStream()
  }
}

function stopRecording() {
  if (mediaRecorder && mediaRecorder.state !== 'inactive') {
    mediaRecorder.stop()
  }
}

async function finalizeRecording() {
  // 'stop' fired → transcribe
  state.value = 'processing'
  try {
    const mimeType = mediaRecorder?.mimeType || 'audio/webm'
    const blob = new Blob(recordedChunks, { type: mimeType })
    if (blob.size === 0) {
      throw new Error('No audio recorded')
    }
    const result = await apiTranscribe(blob)
    emit('transcribed', result.text)
    state.value = 'idle'
  } catch (err) {
    state.value = 'error'
    errorMessage.value = err instanceof Error ? err.message : String(err)
    emit('error', errorMessage.value)
  } finally {
    cleanupStream()
  }
}

function cleanupStream() {
  if (mediaStream) {
    mediaStream.getTracks().forEach((t) => t.stop())
    mediaStream = null
  }
  mediaRecorder = null
  recordedChunks = []
}

// ── Gesture handlers (toggle vs hold) ────────────────────────────────────

function onMouseDown(e: MouseEvent) {
  if (props.disabled) return
  e.preventDefault()
  if (state.value === 'processing') return

  // Start a hold-mode timer; if we release before it fires, we treat
  // it as a toggle click.
  mode = 'toggle' // tentative
  pressTimer = setTimeout(() => {
    // Held past threshold → upgrade to hold mode
    if (state.value === 'idle') {
      mode = 'hold'
      void startRecording()
    }
  }, HOLD_THRESHOLD_MS)

  // If we're already recording (toggle mode), mousedown does NOT
  // start a second recording — wait for click to toggle off.
}

function onMouseUp(e: MouseEvent) {
  if (props.disabled) return
  e.preventDefault()

  if (pressTimer) {
    clearTimeout(pressTimer)
    pressTimer = null
  }

  if (mode === 'hold') {
    // Stop the recording on release
    if (state.value === 'recording') {
      stopRecording()
    }
    mode = 'idle'
  } else if (mode === 'toggle') {
    // Released before threshold — toggle click
    if (state.value === 'idle') {
      void startRecording()
    } else if (state.value === 'recording') {
      stopRecording()
    }
    mode = 'idle'
  }
}

function onMouseLeave(_e: MouseEvent) {
  // If the user drags out of the button while holding, treat as
  // mouseup so we don't leave the recorder stuck on.
  if (mode === 'hold' && state.value === 'recording') {
    if (pressTimer) clearTimeout(pressTimer)
    pressTimer = null
    stopRecording()
    mode = 'idle'
  }
}

function onTouchStart(e: TouchEvent) {
  if (props.disabled) return
  e.preventDefault()
  onMouseDown(e as unknown as MouseEvent)
}

function onTouchEnd(e: TouchEvent) {
  if (props.disabled) return
  e.preventDefault()
  onMouseUp(e as unknown as MouseEvent)
}

function onClick(e: MouseEvent) {
  // The click event also fires after mousedown+mouseup on the same
  // element. Since onMouseUp already handles toggle/hold transitions,
  // we just prevent the default click to avoid double-triggering.
  e.preventDefault()
}
</script>

<template>
  <button
    type="button"
    data-testid="mic-button"
    :data-state="state"
    :disabled="disabled"
    :title="state === 'error' ? errorMessage
      : state === 'recording' ? 'Recording... (release to stop, click again to cancel)'
      : state === 'processing' ? 'Transcribing...'
      : 'Click to talk or hold to record'"
    class="px-3 py-3 rounded-xl text-sm transition-all duration-200 border flex items-center gap-1 relative"
    :style="state === 'recording'
      ? 'background-color: var(--color-orange); border-color: var(--color-orange); color: var(--color-bg); animation: mic-pulse 1.2s ease-in-out infinite;'
      : state === 'processing'
      ? 'background-color: var(--color-violet); border-color: var(--color-violet); color: var(--color-bg);'
      : state === 'error'
      ? 'background-color: var(--semantic-card-bg); border-color: var(--color-orange); color: var(--color-orange);'
      : 'background-color: var(--semantic-card-bg); border-color: var(--color-border); color: var(--semantic-text);'"
    :class="disabled ? 'cursor-not-allowed opacity-50' : 'hover:opacity-90 active:scale-95'"
    @mousedown="onMouseDown"
    @mouseup="onMouseUp"
    @mouseleave="onMouseLeave"
    @touchstart="onTouchStart"
    @touchend="onTouchEnd"
    @click="onClick"
  >
    <!-- Recording: pulsing filled mic -->
    <svg
      v-if="state === 'recording'"
      class="w-5 h-5"
      fill="currentColor"
      viewBox="0 0 24 24"
    >
      <path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.91-3c0 3.24-2.72 5.83-6 5.91V19h2c.55 0 1 .45 1 1s-.45 1-1 1h-4c-.55 0-1-.45-1-1s.45-1 1-1h2v-2.09c-3.28-.08-6-2.67-6-5.91 0-.55.45-1 1-1s1 .45 1 1c0 2.21 1.79 4 4 4s4-1.79 4-4c0-.55.45-1 1-1s.99.45.99 1z" />
    </svg>

    <!-- Processing: spinner -->
    <div
      v-else-if="state === 'processing'"
      class="w-5 h-5 border-2 rounded-full animate-spin"
      style="border-color: var(--color-bg); border-top-color: transparent;"
    ></div>

    <!-- Error: warning triangle -->
    <svg
      v-else-if="state === 'error'"
      class="w-5 h-5"
      fill="currentColor"
      viewBox="0 0 24 24"
    >
      <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z" />
    </svg>

    <!-- Idle: outline mic -->
    <svg
      v-else
      class="w-5 h-5"
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M19 10v2a7 7 0 01-14 0v-2M12 18.5v3.5m-4 0h8M12 1a3 3 0 00-3 3v8a3 3 0 006 0V4a3 3 0 00-3-3z"
      />
    </svg>

    <span v-if="state === 'error'" class="text-xs ml-1 max-w-[120px] truncate">
      {{ errorMessage }}
    </span>
  </button>
</template>

<style scoped>
@keyframes mic-pulse {
  0%, 100% { transform: scale(1); opacity: 1; }
  50% { transform: scale(1.08); opacity: 0.85; }
}
</style>
```

- [ ] **Step 2: Run tests to verify they pass (green)**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run FileInput.mic 2>&1 | tail -n 25`
Expected: PASS — all 8 tests green.

- [ ] **Step 3: Type-check**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean. If `vue-tsc` complains about missing types, ensure the import `import { apiTranscribe } from '../api/transcribe'` resolves and the return type is `{ text: string }`.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/components/MicButton.vue
git commit -m "feat(mic): add MicButton component with toggle + hold gestures"
```

---

## Chunk 5: Wire MicButton into FileInput

### Task 5.1: Wire up and add `insertTextAtCursor()` helper

**Files:**
- Modify: `src/apps/desktop/src/components/FileInput.vue`

- [ ] **Step 1: Add MicButton import and render it**

Open `src/apps/desktop/src/components/FileInput.vue`. Add the import after the existing `FilePreview` import (line 4):

```typescript
import MicButton from './MicButton.vue'
```

Add the `defineExpose` after the existing function declarations (near line 372) so tests/parents can drive the component programmatically:

```typescript
// Expose for parent tests (ChatView integration tests use these)
defineExpose({
  inputText,
})
```

Add an `insertTextAtCursor` helper function near line 372 (above the `defineExpose`):

```typescript
/**
 * Insert text at the current cursor position in the textarea.
 * If text is already selected, the selection is replaced.
 * Adds a trailing space if existing content is non-empty.
 */
const insertTextAtCursor = (text: string) => {
  const textarea = document.querySelector(
    '.file-input-wrapper textarea',
  ) as HTMLTextAreaElement | null

  if (!textarea) {
    // Fallback: just append
    inputText.value = inputText.value
      ? `${inputText.value} ${text}`
      : text
    return
  }

  const start = textarea.selectionStart ?? inputText.value.length
  const end = textarea.selectionEnd ?? start
  const before = inputText.value.slice(0, start)
  const after = inputText.value.slice(end)
  const needsLeadingSpace = before.length > 0 && !before.endsWith(' ') && !before.endsWith('\n')
  const needsTrailingSpace = after.length > 0 && !after.startsWith(' ')

  const insertion = `${needsLeadingSpace ? ' ' : ''}${text}${needsTrailingSpace ? ' ' : ''}`
  inputText.value = before + insertion + after

  // Restore cursor position after the inserted text
  nextTick(() => {
    const newPos = start + insertion.length
    textarea.setSelectionRange(newPos, newPos)
    textarea.focus()
  })
}
```

Add a `handleTranscribed` handler (just above `sendMessage`, near line 369):

```typescript
const handleTranscribed = (text: string) => {
  insertTextAtCursor(text)
}
```

In the `<template>`, find the native file-picker button block (around line 492-500, the `<button @click="triggerFilePicker">` with the paperclip SVG) and add the `<MicButton>` right after it, before the Send button:

```vue
<!-- Microphone button -->
<MicButton
  :disabled="isLoading || isLLMProcessing"
  @transcribed="handleTranscribed"
  @error="(msg: string) => console.warn('Mic error:', msg)"
/>
```

The `disabled` prop mirrors the existing Send button's disable logic — we don't want to start a recording while an LLM is mid-stream (the user can't see/use the result anyway).

- [ ] **Step 2: Run type-check (mandatory)**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean. The `:disabled` prop on MicButton must match what the component declares.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/components/FileInput.vue
git commit -m "feat(mic): wire MicButton into FileInput with text-insertion helper"
```

---

## Chunk 6: End-to-end integration tests + parent-context test

### Task 6.1: Add integration tests for FileInput + MicButton + cursor insertion

**Files:**
- Modify: `src/apps/desktop/src/__tests__/FileInput.mic.spec.ts`

- [ ] **Step 1: Append integration tests to the existing spec file**

Add a new `describe` block at the bottom of the file:

```typescript
import FileInput from '../components/FileInput.vue'

describe('FileInput — MicButton integration', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    lastRecorder = null
    apiTranscribeMock.mockReset()
    ;(navigator.mediaDevices.getUserMedia as ReturnType<typeof vi.fn>).mockResolvedValue({
      getTracks: () => [{ kind: 'audio', stop: vi.fn() }],
      getAudioTracks: () => [{ kind: 'audio', stop: vi.fn() }],
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.clearAllMocks()
  })

  it('renders the MicButton in the input form', () => {
    wrapper = mount(FileInput, { props: { cwd: '/tmp' } })
    expect(wrapper.find('[data-testid="mic-button"]').exists()).toBe(true)
  })

  it('inserts transcribed text at the cursor (cursor at end of existing text)', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'added by mic' })

    wrapper = mount(FileInput, { props: { cwd: '/tmp' } })

    // Type something into the textarea first
    const textarea = wrapper.find('textarea')
    await textarea.setValue('Hello')
    // Place cursor at end (after "Hello")
    const ta = textarea.element as HTMLTextAreaElement
    ta.selectionStart = ta.selectionEnd = 5

    // Trigger full toggle cycle
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    // Text was inserted with a leading space because "Hello" is non-empty
    expect((wrapper.vm as { inputText: string }).inputText).toBe('Hello added by mic ')
  })

  it('inserts transcribed text without leading space when textarea is empty', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'first words' })

    wrapper = mount(FileInput, { props: { cwd: '/tmp' } })
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    expect((wrapper.vm as { inputText: string }).inputText).toBe('first words')
  })

  it('disables the MicButton while LLM is processing', () => {
    wrapper = mount(FileInput, {
      props: { cwd: '/tmp', isLLMProcessing: true },
    })
    const btn = wrapper.find('[data-testid="mic-button"]')
    expect(btn.attributes('disabled')).toBeDefined()
  })

  it('disables the MicButton while isLoading is true', () => {
    wrapper = mount(FileInput, {
      props: { cwd: '/tmp', isLoading: true },
    })
    const btn = wrapper.find('[data-testid="mic-button"]')
    expect(btn.attributes('disabled')).toBeDefined()
  })

  it('works in review mode', async () => {
    apiTranscribeMock.mockResolvedValueOnce({ text: 'review note' })

    wrapper = mount(FileInput, {
      props: { cwd: '/tmp', reviewMode: true },
    })

    // MicButton should still be present in review mode
    expect(wrapper.find('[data-testid="mic-button"]').exists()).toBe(true)

    // Toggle + transcribe cycle still works
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="mic-button"]').trigger('click')
    lastRecorder!.emitDataAvailable(new Blob(['x'], { type: 'audio/webm' }))
    lastRecorder!.emitStop()
    await flushPromises()

    expect((wrapper.vm as { inputText: string }).inputText).toBe('review note')
  })
})
```

- [ ] **Step 2: Run tests**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run FileInput.mic 2>&1 | tail -n 25`
Expected: PASS — all 13 tests green (8 from Chunk 4 + 5 new).

- [ ] **Step 3: Type-check**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20`
Expected: clean. The cast `(wrapper.vm as { inputText: string }).inputText` must compile — `defineExpose({ inputText })` makes the ref unwrappable through `vm`.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/__tests__/FileInput.mic.spec.ts
git commit -m "test: add FileInput + MicButton integration tests"
```

---

## Chunk 7: Manual smoke test on a live backend

This is NOT a vitest step — it requires a running nalar backend with a configured Whisper-compatible endpoint.

- [ ] **Step 1: Build and launch the backend on port 8080**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
# Binary is at zig-out/bin/nalar. The cp step fails with permission
# denied (it tries to install to /usr/local/bin) — this is harmless.
./zig-out/bin/nalar --port 8080 &
echo "PID: $!"
```

- [ ] **Step 2: Configure an LLM endpoint with Whisper support**

Open the desktop app → Settings → Defaults. Set `api_endpoint` to `https://api.openai.com/v1` (or any OpenAI-compatible endpoint that supports `/v1/audio/transcriptions`) and `api_key` to a valid key. Save.

- [ ] **Step 3: Run the desktop dev server and verify the mic button appears**

```bash
cd src/apps/desktop
timeout 60 bun run dev &
# Visit http://localhost:5173 (or whatever Vite reports)
```

In the chat input, verify:
- ✅ A microphone button is visible between the paperclip and Send buttons
- ✅ Click the button → browser asks for mic permission (or silently permits)
- ✅ Button turns orange with pulsing animation while recording
- ✅ Click again → button shows spinner during transcription
- ✅ Transcribed text appears in the textarea at the cursor

- [ ] **Step 4: Test hold mode**

- Press and hold the mic button for > 250ms → recording starts
- Release → recording stops, transcription fires

- [ ] **Step 5: Test error states**

- Open a new private/incognito window (no mic permission grant) → click mic → expect "Permission denied" error state with orange text
- Set api_endpoint to an invalid URL → click mic, record, stop → expect "Upstream 502" error

- [ ] **Step 6: Kill the test backend**

```bash
kill <PID from step 1>
```

(NEVER `pkill -f 'zig build'` — the project's mandatory rule is to leave the nalar on port 8081 running. Only kill the test process on port 8080.)

---

## Summary of test counts

| After chunk | New tests | Total tests (frontend + backend) |
|---|---|---|
| Pre-feature | — | 31 frontend + ~500 Zig (last known: 504) |
| Chunk 1 (Zig endpoint) | +7 | 31 + 511 |
| Chunk 2 (api.transcribe) | +3 | 34 + 511 |
| Chunk 3 (jsdom stubs) | 0 (no tests yet) | 34 + 511 |
| Chunk 4 (MicButton unit) | +8 | 42 + 511 |
| Chunk 5 (FileInput wire) | 0 | 42 + 511 |
| Chunk 6 (integration) | +5 | 47 + 511 |

## Verification checklist (run BEFORE marking the plan complete)

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox

# Backend tests pass
timeout 180 zig build test --summary all 2>&1 | tail -n 5
# Expected: test success (count 511 or higher)

# Frontend build is clean (NOT just vitest — must include vue-tsc)
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 10
# Expected: no TS errors

# Frontend tests pass
timeout 120 bunx vitest run --reporter=verbose 2>&1 | tail -n 30
# Expected: 47+ tests passing

# Backend compiles to a binary
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
# Expected: 4/6 steps (cp to /usr/local/bin/nalar fails harmlessly)

# Manual smoke test on port 8080 with a configured Whisper endpoint
# (see Chunk 7) — toggle works, hold works, error states surface correctly
```

## Known limitations / follow-ups (NOT in scope for this plan)

1. **Live audio waveform** — the recording state currently shows a pulsing icon; a real-time amplitude waveform would require an `AudioContext` + `AnalyserNode` setup. Defer to a future plan.
2. **Voice activity detection (VAD)** — recording continues until the user clicks again or releases; an automatic silence-detection stop would shorten recordings and reduce Whisper API costs. Defer.
3. **Multi-language STT** — the upstream Whisper API supports `language` and `translate` parameters. Not currently forwarded. Easy follow-up if the user wants it.
4. **Pre-recording buffer** — currently the user has to click first; we don't keep a rolling 5-second buffer that gets committed on click. Defer.
5. **Transcription in review mode toolbar** — review mode currently re-uses the same MicButton. A dedicated "voice note" tool for code review might be useful. Defer.

These are deliberately left out to keep the plan focused on the user's actual ask (toggle/hold mic → printed text).
