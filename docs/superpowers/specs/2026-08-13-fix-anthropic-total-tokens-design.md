# Fix Anthropic Agent Total Tokens — Design Spec

**Date:** 2026-08-13
**Branch:** `worktree/fix-anthropic-total-tokens`
**Task:** `task_1786640688092` ("fixing antropic agent total tokens")
**Bug report:** Anthropic profile (`url_style: anthropic`) reports `total_tokens`
in `llm_history` rows that is consistently lower than what an equivalent
OpenAI call would report. The discrepancy is the size of
`cache_read_input_tokens`, which the current parser silently drops from the
total. Compaction and the cost log are downstream consumers that compare
across providers.

## TL;DR

Right now, when an Anthropic response carries
`{input_tokens: 1_000, cache_creation_input_tokens: 500,
cache_read_input_tokens: 5_000, output_tokens: 1_000}`, the row stored in
`llm_history` says `total_tokens = 2_500`. The corresponding OpenAI call
on the same prompt would say `total_tokens = 7_500`. Both numbers should
be 7_500. The fix changes `prompt_tokens` so it includes cache reads
(which are real tokens the model processed, just billed at a discount),
keeps the cache breakdown available on the wire so future billing code can
charge them correctly, and writes a migration that adds the two new
columns to `llm_history`.

## What's wrong today

### Current parser (Agent.zig:1627-1650, sibling branch `anthropic-usage-fields`)

```zig
if (output_tokens > 0) {
    chunk.usage = .{
        .prompt_tokens = input_tokens + cache_creation_tokens,
        .completion_tokens = output_tokens,
        .total_tokens = input_tokens + cache_creation_tokens + output_tokens,
    };
}
```

The comment on Agent.zig:1610-1616 explains the existing choice:

> Billable total = input_tokens + cache_creation_input_tokens +
> output_tokens. Cache reads (`cache_read_input_tokens`) are FREE — they
> don't add to billing — so they're deliberately NOT included in
> `total_tokens`. This matches OpenAI's `prompt_tokens` semantic…

The first half is right (cache writes ARE billable at a higher rate than
fresh input), but the second half is the bug: OpenAI does include cached
input tokens in `prompt_tokens` (it just exposes them separately under
`prompt_tokens_details.cached_tokens`). Anthropic's `cache_read_input_tokens`
is the same field — the LLM still processed them; we just don't pay
the input rate for them. Dropping them from `total_tokens` makes Anthropic
totals wrong relative to OpenAI totals.

### Downstream impact

`llm_history` rows are consumed in three places that compare across
providers or expect token counts to mean "tokens the LLM actually saw":

1. **Compaction** (`agentic_loop/compaction.zig` and the
   `getMaxTotalTokensForSession` SQL on `llm_history.zig:788`) — uses
   `MAX(total_tokens)` to decide when to compact. If Anthropic undercounts,
   compaction fires later than it should on long cached-context sessions.
2. **The "tokens" pill in the chat header** — frontend renders
   `total_tokens` directly (via `llm_history` SSE payload). Anthropic
   sessions show a lower number than OpenAI sessions with identical
   prompts.
3. **Cost logging** (`Agent.zig:2014-2016`,
   `prompt_cost = prompt_tokens * 0.000003`) — the per-row cost log uses
   `prompt_tokens` as a proxy. After the fix, billing code that uses this
   formula will overcharge by ~90% on cached reads (since reads are
   roughly 1/10 the input price). We can't change the formula in this PR
   without scope creep, so we'll instead preserve the cache breakdown
   separately and document that `prompt_tokens` is no longer safe to
   use as a billable-input metric.

### Why the parser branch we have is half-right

The `anthropic-usage-fields` worktree (already in main as part of
PR #227's follow-ups) gets these right:

- Anthropic's `message_delta.usage.input_tokens` overrides the
  `message_start.usage.input_tokens` cache (relay-quirk robustness).
- `cache_creation_input_tokens` IS added to `prompt_tokens` (cache writes
  are billable).
- `output_tokens` populates `completion_tokens`.

What's wrong is purely the cache-read handling: it gets silently dropped.

## Goal

After the fix, an Anthropic response of
`{input_tokens: 1_000, cache_creation_input_tokens: 500,
cache_read_input_tokens: 5_000, output_tokens: 1_000}` produces:

```text
prompt_tokens      = 6_500    # 1_000 + 500 + 5_000
completion_tokens  = 1_000    # output_tokens
total_tokens       = 7_500    # prompt + completion
```

…identical to what OpenAI would produce on the same prompt (modulo the
`prompt_tokens_details` sub-shape that OpenAI exposes — we don't need
that). Cache counts stay separately available on the `Usage` struct so
billing code can multiply them by their discounted rates.

## Architecture

### `Usage` struct — extend, don't replace

```zig
pub const Usage = struct {
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
    /// Anthropic-only: tokens used to write a cache entry (billed at
    /// ~1.25× input rate). 0 for non-Anthropic profiles. Preserved
    /// separately from `prompt_tokens` for billing.
    cache_creation_input_tokens: usize = 0,
    /// Anthropic-only: tokens read from a cache entry (billed at
    /// ~0.1× input rate, but STILL COUNT as tokens processed — and
    /// therefore included in `prompt_tokens` and `total_tokens` for
    /// parity with OpenAI's semantic). 0 for non-Anthropic profiles.
    cache_read_input_tokens: usize = 0,
};
```

Two new optional fields. Both default to 0 (no breakage for OpenAI
profiles). The OpenAI parser keeps emitting zeros for them — we already
test that the OpenAI wire path is unaffected.

### `parse_anthropic_stream_chunk` (Agent.zig:1489) — switch the formula

```zig
// In the message_delta branch, after parsing the four fields:
const cache_creation_tokens: u32 = ...;
const cache_read_tokens: u32 = ...;
const input_tokens_eff: u32 = ...;
const output_tokens: u32 = ...;

if (output_tokens > 0) {
    chunk.usage = .{
        .prompt_tokens = input_tokens_eff + cache_creation_tokens + cache_read_tokens,
        .completion_tokens = output_tokens,
        .total_tokens = input_tokens_eff + cache_creation_tokens + cache_read_tokens + output_tokens,
        .cache_creation_input_tokens = cache_creation_tokens,
        .cache_read_input_tokens = cache_read_tokens,
    };
}
```

`message_start` must also cache `cache_read_input_tokens` so the first-delta
usage chunk (which is just `prompt_tokens = input_tokens`) can be extended
with cache reads if the strict API sends them in `message_start` but not
`message_delta` (mirrors the existing `input_tokens` cache pattern).

### Streaming aggregator (Agent.zig:683-727)

No structural change. The existing "last seen usage chunk wins" rule
already replaces the first-delta stub with the full `message_delta`
chunk on `finalize()`. Just confirm with a test that the final
`CallResponse.usage` carries cache counts when `message_delta` emits them.

### `llm_history` schema — add 2 columns (Migration 074)

```sql
ALTER TABLE llm_history ADD COLUMN cache_creation_input_tokens INTEGER DEFAULT 0;
ALTER TABLE llm_history ADD COLUMN cache_read_input_tokens INTEGER DEFAULT 0;
```

Both columns nullable-or-default-to-0 so existing rows backfill cleanly.
The columns are stored on the same row as `prompt_tokens` /
`completion_tokens` / `total_tokens` — they're denormalized cache
breakdown for the Anthropic-specific subset of rows. OpenAI rows always
have 0 in both columns (the parser never sets them).

The `saveMessage` path (`llm_history.zig:1078-1258`) and
`insertLLMHistories` (`agentic_loop/insert_llm_histories.zig`) need 2
new `input` fields + SQL placeholders. `LLMHistory` (the row struct at
`agentic_loop/llm_history.zig:5-57`) needs 2 new fields too.

### Cost log (Agent.zig:2014-2016)

Leave unchanged. The fix explicitly does NOT use `prompt_tokens` as a
billable-input metric any more; the comment block above the formula gets
updated to point at `cache_creation_input_tokens + input_tokens -
cache_creation_input_tokens - cache_read_input_tokens` style derivations
for any future billing code. Out of scope for this PR; we just don't
make things worse.

## Files touched

| File | Change |
|------|--------|
| `src/modules/agent/Agent.zig` | Add 2 fields to `Usage`. Update `parse_anthropic_stream_chunk`'s `message_delta` branch to include cache_read in `prompt_tokens`/`total_tokens` and emit the cache breakdown. Update `message_start` branch to also cache `cache_read_input_tokens`. Reset the 2 new per-call fields at the top of `callStreaming`. Update the cost-log comment. |
| `src/modules/agent/parse_anthropic_sse_test.zig` | New tests: cache_read included in prompt+total; cache_read+cache_creation combined; cache_read at message_start preserved; structural contract assertion for the 2 new fields on `Usage`. |
| `src/migrations/migration.zig` | Add `Migration074AddLlmHistoryCacheTokenColumns`. Register in `allMigrations`. |
| `src/migrations/migration_074_test.zig` (NEW) | 4 tests: columns added, defaults to 0, idempotent on re-run, INSERT+SELECT round-trip with cache counts populated. |
| `src/migrations/test_runner.zig` | Add `_ = @import("migration_074_test.zig");`. |
| `src/ai_workflow/tui/llm_history.zig` | Add 2 fields to `SaveMessageInput`. Add the 2 columns to INSERT SQL + `sqlArgs`. |
| `src/ai_workflow/tui/agentic_loop/llm_history.zig` | Add 2 fields to `LLMHistory` struct (u32, default 0). Update the "default fields are safe to read" test. |
| `src/ai_workflow/tui/agentic_loop/insert_llm_histories.zig` | Add the 2 columns to INSERT SQL + `sqlArgs`. |
| `src/ai_workflow/tui/agentic_loop/handle_tool.zig` | Populate the 2 new fields on the `saveMessage` call (pass through from `res_dynamic_agent.usage`). |
| `src/ai_workflow/tui/agentic_loop/workflow.zig` | Populate the 2 new fields on the `LLMHistory` for `finish_reason == .stop` insert + on the local `usage_for_agent` copy returned to the caller. |

## Files NOT touched

- Frontend (Vue/TS) — the existing `total_tokens` rendering just shows the
  higher (correct) number automatically. No UI work needed.
- `buildJsonAnthropicRequest` / `buildJsonOpenAIRequest` — request shape
  unchanged. Caching is server-side; the client doesn't request or
  surface cache_control markers.
- `compaction.zig`, `compaction_context.zig` — they don't read cache
  fields. The fact that `total_tokens` is now higher (more accurate) is
  the desired downstream effect; no compaction-logic change.
- Cost / pricing code — explicitly out of scope. Documented in the
  comment but no formula change.
- Other migrations.

## Behavioural matrix

| Profile `url_style` | Server response | Before | After |
|---|---|---|---|
| `openai` (default) | OpenAI 200 + `usage: {prompt_tokens, completion_tokens, total_tokens}` | `prompt_tokens = N, total_tokens = N+M` | **Same** (parser ignores the 2 new fields) |
| `openai` | OpenAI 200 + `prompt_tokens_details.cached_tokens` | `prompt_tokens = N` (cached count dropped) | **Same** — we don't read OpenAI's `prompt_tokens_details` |
| `anthropic` | Anthropic 200 + `{input:1000, cache_creation:500, output:1000}` | `prompt = 1500, total = 2500` | **`prompt = 1500, total = 2500`** (no change) |
| `anthropic` | Anthropic 200 + `{input:1000, cache_read:5000, output:1000}` | `prompt = 1000, total = 2000` ❌ | **`prompt = 6000, total = 7000`** ✅ |
| `anthropic` | Anthropic 200 + `{input:1000, cache_creation:500, cache_read:5000, output:1000}` | `prompt = 1500, total = 2500` ❌ | **`prompt = 6500, total = 7500`** ✅ |

## Global Constraints

- **Backward compatible.** OpenAI profiles are byte-for-byte unchanged at
  the DB level (the new columns are 0). Anthropic profiles gain correct
  totals. No breaking change to the `Usage` struct's existing fields.
- **No wire-shape change.** The Anthropic HTTP request body is
  unchanged. The SSE parser is the only thing that grows (3 more integer
  reads).
- **No new error variants.**
- **Pure Zig change** — Linux/macOS/Windows compile + test must all pass.
- **Migration 074 is idempotent.** Re-running on a DB that already has
  the columns must be a no-op (per project-wide
  `migration-is-idempotent` invariant — see `migration.zig` history).
- **The cost log formula** (`Agent.zig:2014-2016`) is **NOT** updated in
  this PR. The comment above it gets updated to warn future readers
  that `prompt_tokens` is now "tokens processed" (not "tokens billed
  at full input rate").

## Verification

Before claiming done:
1. `zig build test --summary all` — all green, including the 4 new
   migration tests and the new Anthropic parser tests.
2. New parser tests cover:
   - strict API shape, no cache → unchanged
   - cache_creation only → unchanged from current behaviour
   - cache_read only → new behaviour (was: 1500+1000, now: 6000+1000)
   - cache_creation + cache_read combined → matches the example in TL;DR
   - cache_read at `message_start` (not at `message_delta`) — preserved
   - structural contract: `Usage` struct has the 2 new fields and the
     Anthropic parser populates them
3. Migration tests:
   - column added with default 0
   - existing rows still insert successfully (default applies)
   - re-running the migration is idempotent
   - explicit-value INSERT + SELECT round-trip
4. Manual smoke: hit the Anthropic API (or `api.minimax.io/anthropic`)
   with a cached prompt; confirm `llm_history.total_tokens` matches
   `input + cache_creation + cache_read + output`.

## Out of scope (confirmed by user — ship as follow-up)

- **Update the cost log formula** to use the cache breakdown properly
  (cache_read at ~10% rate, cache_creation at ~125% rate). A follow-up
  PR should derive `billable_input_tokens` = `input_tokens` (already
  includes cache writes, which Anthropic sends separately as
  `cache_creation_input_tokens` — note the Anthropic `input_tokens` does
  NOT include cache reads, so we have `billable_input =
  input_tokens + cache_creation_input_tokens - cache_read_input_tokens
  × 0.9` or similar).
- Surface the cache breakdown in the frontend UI (separate "cached" pill
  on the chat header). Defer until the cost-log update ships so the
  numbers mean something to the user.
- Add `prompt_tokens_details` parsing for OpenAI's `cached_tokens` so
  the two providers report the same shape. Defer; the row-level totals
  are correct without it.

## Risks

- **llm_history.max_total_tokens drift.** The MAX(total_tokens) SQL
  might pick up new (correctly-higher) totals that retroactively look
  like a regression to anyone reading the row's number. Mitigation: the
  release note for this PR explicitly states that Anthropic totals are
  expected to rise by the size of cache reads.
- **Compaction timing drift.** Sessions with heavy cache reads might
  trigger compaction earlier (because `MAX(total_tokens)` now sees the
  full number, not a truncated one). This is the correct behaviour —
  compaction should trigger when the LLM is actually processing a lot of
  tokens, regardless of how they're billed.
- **Test runtime.** The Anthropic parser unit tests use the same pattern
  as `parse_anthropic_sse_test.zig` — pure JSON-string parsing, no
  network. New tests add <1s to `zig build test --summary all`.