# LLM end-user identifier — Design

**Status:** Draft for review
**Date:** 2026-07-25
**Author:** brainstorming session
**Task:** task_1784406079692

## Problem

Both Anthropic and OpenAI support an optional end-user identifier in their chat/messages API for abuse detection. Neither field is currently sent by nalar. Without it:

- OpenAI cannot tie problematic request patterns to a specific nalar install (only to the API key / account).
- Anthropic's `metadata.user_id` field is recommended in their docs but always absent in our payloads.

**OpenAI request body** (current spec — https://platform.openai.com/docs/api-reference/chat/create):

```json
{
  "model": "gpt-4o",
  "messages": [{"role": "user", "content": "Hello"}],
  "user": "user-1234abcd"
}
```

**Anthropic request body** (current spec — https://docs.claude.com/en/api/messages):

```json
{
  "model": "claude-sonnet-4-6",
  "max_tokens": 1024,
  "messages": [{"role": "user", "content": "Hello"}],
  "metadata": {
    "user_id": "user-1234abcd"
  }
}
```

## Goals

- Send a stable opaque user identifier on every LLM call (both Anthropic + OpenAI).
- Identifier is per-nalar-install (one user = one identifier), generated once on first run and persisted.
- Zero user setup. Zero new config edits. Auto-generated.
- Survives restarts, upgrades, and config migrations.

## Non-goals

- Per-session granularity (the user_id stays constant across sessions — this matches Anthropic's documented recommendation of a stable identifier, not per-request).
- Identifying the actual human user (no real-name / email / phone — opaque UUID only).
- Per-profile identifier (we don't expose this in config — one identifier per install).
- Configurable identifier (no CLI flag, no env var override).

## Approach

### Identifier format

**UUID v4 string (canonical form): `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`** (36 chars, e.g. `550e8400-e29b-41d4-a716-446655440000`).

Rationale:
- Universally recognized as "anonymous opaque ID".
- Anthropic's docs explicitly recommend UUIDs.
- Easy to format / parse with stdlib (no external crate).
- Generated via `libc.getrandom` (Linux) / `libc.getentropy` (macOS) — already the codebase's CSPRNG pattern (see `src/modules/logger/RequestId.zig:79-138`).

### Identifier storage

**`~/.config/nalar/config.json`** — top-level field `user_identifier`. Read on startup. Auto-generated and persisted on first run when the config file is auto-created.

Rationale:
- The config file is already the source of truth for install-level state (`api_key`, `model`, `base_url`).
- One read per startup, zero per-call overhead.
- Reuses the existing `LlmConfig` struct and `writeDefaultConfig` flow.

### Identifier lifecycle

1. **First run (no config file exists):**
   - `LlmConfig.init` detects missing file, calls `writeDefaultConfig`.
   - `writeDefaultConfig` generates a fresh UUID v4 via `generateInstallId()` and embeds it in the default JSON template (`"user_identifier": "550e..."`).
   - The config file is written with the UUID embedded.

2. **Subsequent runs (config file exists):**
   - `LlmConfig.init` parses the existing file. The `user_identifier` field is loaded into `LlmConfig.user_identifier`.
   - If the field is missing (older config from before this feature), a new UUID is generated, persisted via a one-shot write back to the config file (atomic rename), and then loaded.

3. **In-process:** the identifier is held in `LlmConfig.user_identifier` for the whole server lifetime and passed to the `Agent` at call sites.

### Where it's plumbed

The identifier is set on the `Agent` struct (NOT on `AgentCall`) because:
- `apiKey`, `model`, `baseUrl`, `UrlStyle` already live on `Agent` as install-level fields.
- `AgentCall` carries per-call fields (`messages`, `tools`, `temperature`, `max_tokens`).
- Three `Agent.init` call sites in the codebase currently set these fields manually after `init()`:
  - `src/ai_workflow/tui/workflow.zig:756` (session-name agent)
  - `src/ai_workflow/tui/workflow.zig:982` (dynamic_agent — main loop)
  - `src/ai_workflow/tui/agentic_loop/compaction.zig:164` (compaction_agent)

  All three will also set `dynamic_agent.userIdentifier = config.user_identifier` (or whatever naming we choose — see API below).

### API surface

**New field on `Agent`:**

```zig
pub const Agent = struct {
    // ... existing fields ...
    userIdentifier: []const u8 = "",  // empty = don't include in request body
};
```

Empty default means existing callers that don't set this field continue to produce request bodies without the identifier — fully backward compatible.

**New field on `LlmConfig`:**

```zig
pub const LlmConfig = struct {
    // ... existing fields ...
    /// Stable per-install UUID used as the LLM-API end-user identifier.
    /// Auto-generated on first run, persisted in config.json as
    /// `user_identifier`. Empty only if generation failed (logged warning);
    /// empty Agent.userIdentifier omits the field from the request.
    user_identifier: []const u8 = "",
};
```

**Two new request-body fields:**

```zig
// OpenAI (JsonRequest at Agent.zig:219)
const JsonRequest = struct {
    // ... existing fields ...
    user: ?[]const u8 = null,  // empty string = omit
};

// Anthropic (AnthropicRequest at Agent.zig:388)
const AnthropicMetadata = struct {
    user_id: ?[]const u8 = null,
};

const AnthropicRequest = struct {
    // ... existing fields ...
    metadata: ?AnthropicMetadata = null,
};
```

### Wire format examples

**OpenAI request body when `agent.userIdentifier = "550e8400-..."`:**

```json
{
  "model": "gpt-4o",
  "messages": [...],
  "temperature": 0.4,
  "max_tokens": 4096,
  "stream": true,
  "tools": [...],
  "user": "550e8400-e29b-41d4-a716-446655440000"
}
```

**Anthropic request body when `agent.userIdentifier = "550e8400-..."`:**

```json
{
  "model": "claude-sonnet-4-6",
  "messages": [...],
  "max_tokens": 4096,
  "stream": true,
  "tools": [...],
  "metadata": {
    "user_id": "550e8400-e29b-41d4-a716-446655440000"
  }
}
```

### Helper: `generateInstallId`

Lives in `src/helpers/install_id.zig` (new file). Pattern after `RequestId.zig::SessionId.init`:

```zig
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn getentropy(buffer: [*]u8, size: usize) c_int;  // macOS only

/// Format UUID v4 into a fixed 36-byte buffer.
/// "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
/// Returns the slice [0..36].
pub fn generateInstallId(buf: *[36]u8) void {
    var bytes: [16]u8 = undefined;
    fillRandom(&bytes);              // libc getrandom / getentropy / Windows fallback
    bytes[6] = (bytes[6] & 0x0F) | 0x40;  // version = 4 (random)
    bytes[8] = (bytes[8] & 0x3F) | 0x80;  // variant = 10 (RFC 4122)

    const hex = "0123456789abcdef";
    var j: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[j] = '-';
            j += 1;
        }
        buf[j] = hex[b >> 4];
        buf[j + 1] = hex[b & 0x0F];
        j += 2;
    }
}
```

The `fillRandom` helper mirrors `RequestId.zig`'s pattern: libc `getrandom` on Linux, locally-declared `getentropy` on macOS, Windows fallback to timestamp + pointer entropy (test-only — production paths always run on Linux/macOS).

### Migration of existing config files

A user who upgrades nalar will have an existing `config.json` WITHOUT the `user_identifier` field. The plan handles this in two layers:

1. **`LlmConfig.init` missing-field detection:** If `config_json.user_identifier` is absent, generate a fresh UUID, persist via `writeBackUserIdentifier`, and use the new value.
2. **`writeBackUserIdentifier`** (new helper): atomically rewrites `~/.config/nalar/config.json` with the new field added. Same atomic `*.tmp` → rename pattern as `state_file.zig:119-196`.

This keeps the upgrade path clean — no separate "migration" code; the parse layer handles it.

### Test strategy

Three layers:

1. **Static-contract tests for `Agent.zig`:**
   - `buildJsonOpenAIRequest` with `userIdentifier="uuid"` → emitted JSON contains `"user":"uuid"`.
   - `buildJsonOpenAIRequest` with `userIdentifier=""` → emitted JSON does NOT contain `"user"`.
   - `buildJsonAnthropicRequest` with `userIdentifier="uuid"` → emitted JSON contains `"metadata":{"user_id":"uuid"}`.
   - `buildJsonAnthropicRequest` with `userIdentifier=""` → emitted JSON does NOT contain `"metadata"`.

2. **`install_id.zig` tests:**
   - `generateInstallId` produces a 36-char string matching the UUID v4 format regex.
   - Version nibble is `4`.
   - Variant nibble is `8`/`9`/`a`/`b`.
   - Two calls produce different UUIDs.

3. **`Config.zig` upgrade-path test:**
   - Parse an existing `config.json` without `user_identifier` → field is populated with a non-empty UUID.
   - Re-parse the same file after the auto-write → `user_identifier` is preserved (idempotent — no new UUID each time).

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| `getrandom`/`getentropy` unavailable on some platforms | Falls back to `RequestId.zig`'s Windows / unknown-POSIX pattern (timestamp + pointer entropy, marked explicitly as weaker). For nalar's supported platforms (Linux/macOS) the CSPRNG path always works. |
| User edits `config.json` and removes `user_identifier` | Re-running `LlmConfig.init` will detect the missing field and regenerate + re-persist. Safe. |
| User accidentally commits `config.json` containing the UUID | The UUID is opaque and not PII. Low risk. (Same posture as Anthropic's docs.) |
| Atomic write of `config.json` corrupts an in-progress user edit | Same `<path>.tmp` + rename pattern as `state_file.zig`. POSIX `rename(2)` is atomic. A user editing the file with `vim` may lose unsaved changes during the upgrade-window write — acceptable trade-off for a one-time auto-migration. |
| `writeDefaultConfig` with embedded UUID — re-write each call | The default config is only written when the file does NOT exist (`LlmConfig.init` `error.FileNotFound` arm). After first run, `writeDefaultConfig` is not re-invoked, so the UUID stays stable. The auto-migration path is a separate, one-shot code path triggered only on the missing-field case. |

## Out of scope

- Identifying individual humans (no auth system, no per-user config).
- Per-API-key identifier (single identifier per install, sent to all providers).
- Identifier rotation (no manual reset, no API to regenerate).
- Identifier in analytics / dashboards (no internal tracking of `user_identifier`; we just send it to the LLM provider).
- Identifier on requests other than chat/messages (only the two chat endpoints are affected).
