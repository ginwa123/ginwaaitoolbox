# Plan — Expose `notify_on_error` + `retry_delay_ms` in Nalar Settings

**Task:** task_1787671269086_0
**Branch:** worktree/notify-on-error-retry-ms-settings
**Date:** 2026-08-25

## User request

> settings like on notifi when error not showup in frontend also retry ms in config.json is exist that

The Settings page (`/app/settings` → Nalar) currently shows three tabs — Profiles / Sub-agents / MCP Servers — and hides two operational settings that already exist in `config.json`:

1. `notify_on_complete` (bool) — fires an OS notification on a successful `finish_reason == "stop"`. Already wired in `workflow.zig:1188`.
2. `retry_delay_ms` (u32) — workflow sleep between failed LLM retries. Range 0–60 000, clamped at the HTTP layer.

The user wants both exposed in the UI. They also want a companion toggle: **"Notify when agent fails"** — fire an OS notification when the LLM call errors out (transport failure, rate limit, auth, etc.). Currently the workflow is silent on errors — the user only sees the diagnostic card in the chatview when they're actively looking at it.

## Design

### 1. New tab "General" inside Nalar settings

The three operational settings belong together (notification on completion, notification on error, retry delay). Add a **General** tab as the FIRST tab in the Nalar tab strip (operational settings are the broadest, most-frequently-touched — same UX instinct as "Preferences" before "Profiles" in a typical desktop app).

Tab order: **General / Profiles / Sub-agents / MCP Servers**.

### 2. Backend plumbing — add `notify_on_error: bool`

Mirrors the existing `notify_on_complete: bool` field. Default `false`. Field plumbing touches 5 files:

- `src/modules/config/Config.zig` — `LlmConfig.notify_on_error` (runtime) + `LlmConfigJson.notify_on_error` (on-disk parse struct) + the `LlmConfig.clone()` copy.
- `src/ai_workflow/tui/http_handlers/http_response.zig` — `NalarConfigResponse.notify_on_error` so the GET handler emits it.
- `src/ai_workflow/tui/http_handlers/nalar_config_get.zig` — `ConfigJson.notify_on_error` + pipe `cfg.notify_on_error` into the response.
- `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` — `ConfigInput.notify_on_error` (parse-side) + `ConfigJson.notify_on_error` (write-side) + apply block.
- `src/ai_workflow/tui/agentic_loop/workflow.zig` — fire `notifications.notify(io, allocator, "Agent Nalar", errBody)` at the three error sites: (a) `callDynamicAgentNew` catch (~:1040), (b) TooManyRetries hard bail (~:954), (c) the outer runAgenticMultiStepNew catch (~:142). Gated on `config.notify_on_error and copy_is_sub_agent == false` (same sub-agent suppression as `notify_on_complete`).

Error notification body: `"{reason_error} (source: {reason_source}) — server: {server_detail}"` — matches the pattern the diagnostic uses. Truncated to 200 chars so the toast isn't a wall of text.

### 3. Frontend wiring

- `src/apps/desktop/src/api/index.ts` — add `notify_on_error?: boolean` to the `NalarConfig` interface.
- `src/apps/desktop/src/components/nalar/NalarTabStrip.vue` — add `'general'` as the first tab id; label "General".
- `src/apps/desktop/src/components/nalar/NalarGeneralSection.vue` — **NEW**. Two toggle switches (`notify_on_complete`, `notify_on_error`) + one number input (`retry_delay_ms`, clamped 0–60 000). Uses `defineModel<{ notify_on_complete, notify_on_error, retry_delay_ms }>()` so the parent can `v-model` a single config object — no event plumbing.
- `src/apps/desktop/src/components/NalarSettings.vue` — render `<NalarGeneralSection v-model="generalSettings" />` when `activeTab === 'general'`. Add `generalSettings` ref + hydrate from `syncFromConfig` / write back via `syncToConfig`.

### 4. Tests

Zig:
- `src/ai_workflow/tui/http_handlers/nalar_config_get_test.zig` — add static-contract test that `notify_on_error: bool = false` appears in both `NalarConfigResponse` and `ConfigJson`, and that the GET handler pipes `cfg.notify_on_error`.
- `src/modules/config/config_test.zig` — add three tests: (a) `notify_on_error` defaults to `false` when missing, (b) reads `true` from JSON, (c) reads `false` from JSON explicitly. Mirror the existing `notify_on_complete` test block (config_test.zig:334-381).
- `src/ai_workflow/tui/http_handlers/nalar_config_put_parse_test.zig` — extend coverage: the input parse struct accepts `notify_on_error: true`.
- `src/ai_workflow/tui/http_handlers/nalar_config_put.zig` — inline static-contract tests at the bottom: parse-input accepts `notify_on_error`, apply block writes it through.

Frontend:
- `src/apps/desktop/src/__tests__/NalarSettings.spec.ts` — add test that the General tab is the first tab, that toggling `notify_on_error` flips `dirty=true`, that saving sends `notify_on_error: true` in the PUT body.
- `src/apps/desktop/src/__tests__/NalarTabStrip.spec.ts` — extend the "renders 3 tab labels" tests to expect 4 (General / Profiles / Sub-agents / MCP).
- `src/apps/desktop/src/__tests__/NalarGeneralSection.spec.ts` — **NEW**. Render the section with an initial config, click the error-notification toggle, assert `update:modelValue` payload carries the flip. Click the retry-ms number input, set value, assert the payload.

### 5. Worktree + plan branch

- Branch `worktree/notify-on-error-retry-ms-settings` from `main`.
- `zig build test --summary all` passes (no regressions; new tests added).
- `bun run test:unit` passes.
- `bunx vue-tsc --build` clean.
- Commit at the end, push as PR (do NOT merge — kanban policy says human moves the merged column).

## Verification

1. `zig build test --summary all` — all tests pass, including new ones.
2. `bun run test:unit` — Vue/Vitest unit tests pass, including new GeneralSection spec.
3. `bunx vue-tsc --build` — no TS errors.
4. Manual review of the PUT round-trip: load config → toggle notify_on_error on → save → reload → confirm `notify_on_error: true` on disk in `~/.config/nalar/config.json`.

## Pitfalls

- **Per-request arena cleanup.** `notify_on_error` is a `bool` — no allocation, no `defer free`.
- **Wire-format static contract.** `notify_on_error` MUST appear in BOTH the `NalarConfigResponse` and the GET-side `ConfigJson`, and the GET handler MUST pipe it. Three greppable sites — locked by static tests.
- **Config-simplify precedent.** The `NalarConfig` interface comment at `api/index.ts:3480-3484` says "the top-level LLM defaults were REMOVED from config.json". This change does NOT touch the simplification — it only adds a new optional field that the existing PUT handler's `ignore_unknown_fields` already tolerates.
- **Sub-agent suppression.** `notify_on_complete` is gated on `copy_is_sub_agent == false` so the user isn't spammed by every sub-agent step. Mirror that gate for `notify_on_error`.