# Migrate OpenAI Legacy Features to OpenAI Response — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Achieve full feature parity between `url_style="openai"` (legacy Chat Completions `POST /v1/chat/completions`) and `url_style="openai-response"` (new Responses `POST /v1/responses`) so users can switch to Responses without losing any capability, while **keeping the legacy API fully intact** (no deletion, no deprecation, no breaking change). Frontend adapts per `url_style` so each style only shows its relevant controls (reasoning/thinking/budget).

**Architecture:** Dual-stack already exists in `src/modules/agent/Agent.zig`: `buildJsonOpenAIRequest` + OpenAI SSE parser for legacy, and `buildJsonResponsesRequest` + `parse_responses_stream_chunk` for Responses (commit `6a6501e9`). Backend: audit every field/behavior legacy supports, port missing pieces to Responses, lock with behavioural tests — legacy code is **read-only**. Frontend: `LlmConfigForm.vue` becomes `url_style`-aware — conditional rendering of `thinking_budget_tokens` (Anthropic only), `reasoning_effort` (OpenAI + OpenAI-Response), and `thinking` toggle semantics per style. Config (`Config.zig`) keeps all three `url_style` values; no migration of stored configs.

**Tech Stack:** Zig 0.16 (`Agent.zig`, `Config.zig`), `custom_http_client`, Vue 3 + TypeScript (`LlmConfigForm.vue`), Vitest, `zig build test`, `pytest` harness.

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/migrate-openai-legacy-to-response` on branch `worktree/migrate-openai-legacy-to-response` (base `6a6501e9`).

---

## What exists today (read before changing anything)

- **Legacy stack (`url_style="openai"`):** `Agent.buildJsonOpenAIRequest` builds `JsonRequest` with `model`, `enable_thinking`, `thinking: {type:"disabled"}` (when off), `messages[]` (role/content/content_parts/tool_calls/tool_call_id/reasoning_content), `temperature`, `max_tokens`, `stream` + `stream_options: {include_usage:true}`, `tools[]` + `tool_choice:"auto"`, `user`, `reasoning_effort` (low/medium/high/auto). Parser is the OpenAI chat-completions SSE path in `parse_stream_chunk` → `choices[0].delta.{content, reasoning_content, tool_calls}` + `finish_reason` + `usage`.
- **Responses stack (`url_style="openai-response"`):** `Agent.buildJsonResponsesRequest` builds `ResponsesRequest` with `model`, `instructions` (joined system messages), `input[]` (heterogeneous: message/function_call/function_call_output), `max_output_tokens`, `stream`, `temperature`, `reasoning: {effort}`, `tools[]` + `tool_choice:"auto"`, `store:false`, `user`. Handles `content_parts` (input_text/input_image), `reasoning_content` → `output_text`, tool calls. Parser is `parse_responses_stream_chunk` handling `response.output_text.delta`, `response.reasoning_text.delta`, `response.output_item.added` (function_call), `response.function_call_arguments.delta/done`, `response.completed/failed/incomplete` (finish_reason + usage).
- **Config:** `Config.zig` defaults `url_style="openai"`; `LlmConfigForm.vue` offers `openai` + `openai-response` + `anthropic`. No auto-migration of stored configs.
- **Dispatch:** `Agent.callStreaming` branches on `UrlStyle` to pick builder + parser. Both stacks share `StreamingAggregator` and `CallResponse` shape.
- **Frontend today:** `LlmConfigForm.vue` shows `thinking` (auto/on/off) + `temperature` + `url_style` always. Below that, when `thinking !== "off"`, it shows **both** `thinking_budget_tokens` (helper "Anthropic only") and `reasoning_effort` (helper "OpenAI only") side-by-side regardless of `url_style`. So an `openai` user sees an Anthropic field and vice versa — noisy, and no distinction between `openai` vs `openai-response`.

---

## Global Constraints

- **Keep legacy intact:** Do NOT delete or modify `buildJsonOpenAIRequest`, its `JsonRequest`/`JsonMessage` structs, or the OpenAI chat-completions parser. Legacy stays as-is for backward compat.
- **Cross-platform:** No platform-specific APIs.
- **Per-request arena:** Handlers use `ctx.allocator` (arena) — no `defer allocator.free` for arena slices.
- **No port 8081:** Functional tests use harness (8080..8199).
- **Behavioural tests only:** No `expect(source).toContain(...)` static-contract tests.
- **No new migration:** Config JSON keeps `url_style` as-is; no DB migration.
- **DONT KILL PORT 8081 SERVER.**

---

## File map

| File | Action | Why |
|---|---|---|
| `src/modules/agent/Agent.zig` | EDIT | Add any missing parity fields to `ResponsesRequest`/`buildJsonResponsesRequest` and `parse_responses_stream_chunk` |
| `src/modules/agent/openai_responses_test.zig` | NEW | Behavioural tests for Responses builder + parser parity (mirrors `openai_reasoning_test.zig` + `parse_anthropic_sse_test.zig` shape) |
| `src/modules/agent/test_runner.zig` | EDIT | Register new test file |
| `src/modules/config/Config.zig` | EDIT (if needed) | Only if a new config field is required for parity (unlikely — keep minimal) |
| `src/apps/desktop/src/components/nalar/LlmConfigForm.vue` | EDIT | Make reasoning/thinking UI `url_style`-aware (see Task 5) |
| `src/apps/desktop/src/__tests__/nalarConfigFormThinking.spec.ts` | EDIT | Add per-style visibility tests |
| `src/apps/desktop/src/__tests__/LlmConfigForm.spec.ts` | EDIT | Update select-count / visibility asserts for per-style rendering |
| `docs/superpowers/plans/2026-09-01-migrate-openai-legacy-to-response.md` | NEW | This plan |
| `NALAR.md` | EDIT | Changelog entry on final commit |

---

## Parity audit (legacy → Responses)

| # | Legacy feature | Legacy wire | Responses today | Gap? | Action |
|---|---|---|---|---|---|
| 1 | `model` | `model` | `model` | ✅ | None |
| 2 | `messages[]` with system/user/assistant/tool | `messages` | `instructions` + `input[]` | ✅ | Verify join + heterogeneous mapping |
| 3 | `content_parts` (vision) | `content_parts[]` | `input_text`/`input_image` | ✅ | Verify `detail` + `image_url` |
| 4 | `reasoning_content` | `reasoning_content` | `output_text` (assistant) | ✅ | Verify both `content` + `reasoning_content` emitted |
| 5 | `tool_calls` / `tool_call_id` | `tool_calls` | `function_call` / `function_call_output` | ✅ | Verify `call_id` + `arguments` |
| 6 | `temperature` | `temperature` | `temperature` | ✅ | None |
| 7 | `max_tokens` | `max_tokens` | `max_output_tokens` | ✅ | None |
| 8 | `stream` + `stream_options.include_usage` | `stream_options` | `stream` (usage via `response.completed`) | ✅ | Ensure usage parsed from `response.completed.usage` |
| 9 | `tools` + `tool_choice:"auto"` | `tools` | `tools` + `tool_choice` | ✅ | None |
| 10 | `user` | `user` | `user` | ✅ | None |
| 11 | `reasoning_effort` | `reasoning_effort` | `reasoning.effort` | ✅ | Verify low/medium/high/auto |
| 12 | `enable_thinking` + `thinking:{type:"disabled"}` | `enable_thinking` | — | ⚠️ Intentional gap | Responses has no `enable_thinking`; reasoning is via `reasoning.effort` only. Document as intentional, do NOT port. |
| 13 | `finish_reason` (`stop`/`tool_calls`/`length`) | `choices[0].finish_reason` | `response.completed.status` + `output[]` scan for `function_call` | ✅ | Verify `tool_calls` override |
| 14 | `usage` (`prompt_tokens`/`completion_tokens`/`total_tokens`) | `usage` | `usage.{input_tokens,output_tokens,total_tokens}` | ✅ | Verify mapping + `cached_tokens` |
| 15 | Streaming deltas (`content`, `reasoning_content`, `tool_calls`) | `choices[0].delta` | `response.output_text.delta`, `response.reasoning_text.delta`, `response.function_call_arguments.delta` | ✅ | Verify all three |

**Result:** No functional gap except `enable_thinking` which is intentionally not ported (Responses uses `reasoning.effort`). The plan is therefore **verification + hardening**, not new fields.

---

## Frontend per-style matrix (Task 5)

Current `LlmConfigForm.vue` shows both `thinking_budget_tokens` and `reasoning_effort` whenever `thinking !== "off"`, regardless of `url_style`. New behavior — gate by `url_style`:

| `url_style` | `thinking` select | `thinking_budget_tokens` input | `reasoning_effort` select | Notes |
|---|---|---|---|---|
| `openai` (legacy) | ✅ visible | ❌ hidden | ✅ visible (when `thinking !== "off"`) | Legacy OpenAI uses `reasoning_effort`; budget is Anthropic-only |
| `openai-response` | ✅ visible (or hidden if Responses has no `enable_thinking` — keep visible but helper says "Responses: reasoning via effort") | ❌ hidden | ✅ visible (when `thinking !== "off"`) | Same `reasoning_effort` field, but wire is `reasoning.effort` not `reasoning_effort`; UI reuses same model field |
| `anthropic` | ✅ visible | ✅ visible (when `thinking !== "off"`) | ❌ hidden | Anthropic uses `thinking_budget_tokens` + adaptive; no `reasoning_effort` |

Implementation: computed `isAnthropic = url_style === "anthropic"`, `isOpenAI = url_style === "openai" || url_style === "openai-response"`. Template `v-if` on each field. When hidden, the field's value is **preserved** in model (not nulled) so switching styles doesn't lose data — only visibility changes. Helper text updated per style.

Alternative considered: null the hidden field on style switch — rejected, would be destructive.

---

## Tasks

### Task 1 — Parity audit test (RED)

- [ ] Create `src/modules/agent/openai_responses_test.zig` with failing tests that assert Responses builder parity:
  - `buildJsonResponsesRequest` emits `instructions` from system messages, `input[]` with `input_text`/`input_image`, `output_text` for assistant, `function_call` + `function_call_output` for tools, `temperature`, `max_output_tokens`, `reasoning.effort`, `tools` + `tool_choice`, `user`, `store:false`, `stream:true`.
  - `parse_responses_stream_chunk` handles `response.output_text.delta` → `content`, `response.reasoning_text.delta` → `reasoning_content`, `response.output_item.added` + `response.function_call_arguments.delta` → `tool_calls_delta`, `response.completed` → `finish_reason` + `usage` (including `tool_calls` override).
- [ ] Register in `src/modules/agent/test_runner.zig`.
- [ ] Run `zig build test --summary all` → expect RED (missing file or failing asserts).

### Task 2 — Harden Responses builder (GREEN)

- [ ] In `src/modules/agent/Agent.zig`, verify `buildJsonResponsesRequest` covers every row in the audit table. Fix any missing mapping (e.g., ensure `detail` defaults to `"auto"`, ensure empty assistant without tools still emits `output_text:""`, ensure `tool_choice` only when tools present).
- [ ] Run `zig build test --summary all` → GREEN for builder tests.

### Task 3 — Harden Responses parser (GREEN)

- [ ] In `src/modules/agent/Agent.zig`, verify `parse_responses_stream_chunk` covers all event types in the audit table. Ensure `response.completed` correctly sets `finish_reason=.tool_calls` when `output[]` contains `function_call`, and that `usage` maps `input_tokens`→`prompt_tokens`, `output_tokens`→`completion_tokens`, `total_tokens` preserved, `cached_tokens` → `cache_read_input_tokens`.
- [ ] Run `zig build test --summary all` → GREEN for parser tests.

### Task 4 — Keep legacy untouched (verify)

- [ ] Run `zig build test --summary all` and confirm legacy OpenAI tests (`openai_reasoning_test.zig`, `parse_anthropic_sse_test.zig` openai cases) still pass.
- [ ] Grep `rg -n "buildJsonOpenAIRequest|JsonRequest" src/modules/agent/Agent.zig` → confirm legacy structs/functions still present and unmodified (except maybe comments).

### Task 5 — Frontend per-style reasoning UI

- [ ] In `src/apps/desktop/src/components/nalar/LlmConfigForm.vue`:
  - Add computed `isAnthropic` / `isOpenAIStyle` based on `modelValue.url_style`.
  - Gate `thinking_budget_tokens` block with `v-if="isAnthropic && modelValue.thinking !== 'off'"`.
  - Gate `reasoning_effort` block with `v-if="isOpenAIStyle && modelValue.thinking !== 'off'"` (covers both `openai` and `openai-response`).
  - Keep `thinking` select always visible (all three styles use it, even if Responses ignores `enable_thinking` — preserves UX consistency; or hide for `openai-response` if product decides — default keep visible).
  - Update helper texts: budget → "Anthropic only", effort → "OpenAI / Responses only (o1/o3/GPT-5/DeepSeek-R1)".
  - Do NOT null hidden fields on style switch — preserve values.
- [ ] Update `src/apps/desktop/src/__tests__/nalarConfigFormThinking.spec.ts`: add tests for per-style visibility (anthropic shows budget hides effort, openai shows effort hides budget, openai-response shows effort hides budget).
- [ ] Update `src/apps/desktop/src/__tests__/LlmConfigForm.spec.ts`: adjust select-count asserts to be per-style (or assert conditional rendering).
- [ ] Run `pnpm test:unit` → GREEN.

### Task 6 — Verification + docs

- [ ] `zig build test --summary all` → 0 fail.
- [ ] `zig build nalar-desktop --summary all` → 0 fail.
- [ ] `pnpm test:unit` → 0 fail.
- [ ] Append `NALAR.md` changelog: "### 2026-09-01: Migrate OpenAI legacy features to OpenAI Response (keep legacy) — frontend per-style reasoning UI".
- [ ] Commit.

---

## Verification

- [ ] Plan saved to `docs/superpowers/plans/2026-09-01-migrate-openai-legacy-to-response.md`
- [ ] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] Frontend per-style matrix covered (openai / openai-response / anthropic)
- [ ] User has reviewed the plan before execution begins
- [ ] Worktree created at `.worktrees/migrate-openai-legacy-to-response` on branch `worktree/migrate-openai-legacy-to-response`

---

## Pitfalls

- Don't delete legacy code — the user explicitly said "keep the old api open ai legacy okeyy".
- Don't add `enable_thinking` to Responses — it's not part of the Responses spec; use `reasoning.effort`.
- Don't auto-migrate stored configs from `openai` to `openai-response` — let users opt-in via the dropdown.
- Don't forget `store:false` — Responses defaults to `store:true` server-side; we keep stateless like chat/completions.
- Don't null hidden frontend fields on style switch — preserve values so switching back doesn't lose data.
- Don't hide `thinking` select for `openai-response` without product sign-off — even if Responses doesn't use `enable_thinking`, the toggle still controls `reasoning_effort` visibility.
