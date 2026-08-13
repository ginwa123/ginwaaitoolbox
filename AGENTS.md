
#Mandatory
DONT KILL THE PORT 8081 SERVER,
for testing use another port like 8080

## SSE Wire-Format Contract — Always Add Event Names in Pairs

The browser's `EventSource` drops named events whose listener isn't pre-registered. There is **no error, no warning** — the event just vanishes at the wire. User-visible symptom: "feature X never updates live, only after I refresh the page".

When you add (or rename) any SSE event_type name, change **all three** sites together — they're one contract, not three independent changes:

1. **Backend emitter** (`src/ai_workflow/tui/**/on_event_sent*.zig` or `agentic_loop/sse_on_event_send_*.zig`): add the action → `event_type` mapping to the `event_type_name` if/else.
2. **Frontend pre-registration** (`src/apps/desktop/src/api/index.ts` → `additionalEventTypes`): add the name to the list passed to `createSseClient`.
3. **Frontend dispatch check** (same file → named-event `if (eventType === ...)` chain): add the name to the branch that routes to `opts.channels.<channel>`.

If only one side changes, the bug is silent. Skip a step, and users see "doesn't update until refresh" — no error in the console, no failed test, no broken type check.

**Verification (before claiming done):** grep for the new event_type name across the codebase. It must appear in:

- All backend `onEventSend*` functions that emit it
- `additionalEventTypes` in `api/index.ts`
- The named-event dispatch chain in `api/index.ts`

If any of those is missing, the wire contract is broken.

**Concrete example** (task_1786507100896, PR #215): backend's `onEventSendSessions` had an `event_type_name` if/else that knew about `created` and `deleted` and fell through to `session_unknown` for everything else. `action="updated"` (the most common case — fired by the auto-rename-on-first-message cascade in `workflow.zig` and the unattended toggle in `llm_history.zig`) reached the wire as `event: session_unknown`, which the frontend's `additionalEventTypes` didn't pre-register. The browser silently dropped it. Sidebar task rows kept showing "New Chat" until a manual page refresh.

## Code Exploration with Graphify

Before exploring or making changes in an unfamiliar or large codebase, use the `graphify` CLI to build a knowledge graph of the repo instead of manually grepping through files.

**Setup (once per environment):**


> **Audience:** any AI agent (Claude, GPT, sub-agent, future-me) that writes,
> edits, reviews, or tests code in this repo. Humans may also find it useful.
>
> **Authority:** this file is loaded automatically by every agent at session
> start. Treat the rules below as non-negotiable. If a rule conflicts with a
> specific task, surface the conflict to the user before acting.


**Usage:**
- `graphify ./path` — build the knowledge graph for a project or folder
- `graphify query "<question>"` — ask a question against the graph
- `graphify path <A> <B>` — trace the relationship/path between two nodes (e.g., functions, files)
- `graphify explain <node>` — get an explanation of what a specific node does and why

**When to use it:**
- Onboarding to an unfamiliar repo or module
- Before refactoring, to see what depends on what
- Tracing how a function, class, or file is used across the codebase
- Investigating "god nodes" (highly-connected core components) or unexpected cross-file connections

**Why:** Graphify combines Tree-sitter static analysis with LLM-driven semantic extraction to produce an interactive `graph.html`, a queryable `graph.json`, and a `GRAPH_REPORT.md` audit report in `graphify-out/`. It only sends semantic descriptions to the AI model — never raw source code.


## Recent changes

- **Fix CI Linux — build.zig vendor race + build-vendor-curl.sh bugs** (2026-08-13): `zig build test` raced the `fetch-vendor-curl` step on a fresh checkout (`test_step`'s children ran in parallel — the test compile started before `libcurl.a` was written). CI run 31706196476 reproduced the race ("error: .../vendor/curl/linux_x86_64/lib/libcurl.a: file not found"). Fix: attach the fetch deps to the COMPILE step directly (`mod_tests.step.dependOn(...)`, `linux_exe.step.dependOn(...)`, etc., NOT `run_mod_tests.step` — `addRunArtifact` wraps the Compile in a Run step, and adding deps to the Run step makes the fetch a sibling of the compile, not a prerequisite; the Compile step needs to be the dependent) — 8 sites in `build.zig` patched. Same patch surfaced 4 latent bugs in `build-vendor-curl.sh` that were masked by the race: (1) `ar t missing_file` exits 9 and `set -euo pipefail` propagates that out of a `$(...)` substitution — append `|| true`; (2) `cp -r include/openssl` copies from the build dir, which only has 28 generated `.h` files — copy from `${OPENSSL_SRC_DIR}/include/openssl/` (113 plain `.h` files like `pem.h`, `ssl.h`, `evp.h`) first, then overlay; (3) `nm libcurl.a | grep 'T sym'` is a false-negative because `nm` on an archive reports only UNDEFINED references — extract the archive and `nm` each member; (4) the script unconditionally cross-compiled all 3 targets (linux + 2 macOS), wasting 30+ min on a Linux CI runner that only needs Linux — add a `TARGETS` env var defaulting to the host OS targets. Branch: `worktree/fix-ci-linux-vendor-race`. Plan: `docs/superpowers/plans/2026-08-13-fix-ci-linux-vendor-race.md`. `zig build test --summary all`: 2201 pass, 6 skip, 0 fail.
- **Anthropic profile SSE parsing + raw-error surfacing** (2026-08-13): `src/modules/agent/Agent.zig` now parses Anthropic's `/v1/messages` SSE events (`message_start` / `content_block_delta` / `content_block_start` / `message_delta` / `message_stop`) and surfaces raw server output in the retry-log error message when parsing fails. 3 commits on `worktree/anthropic-sse-parsing`: `4a783794` (raw SSE sample), `c137ebc9` (Anthropic SSE parser + UrlStyle dispatch), `c4d6853e` (also capture non-SSE lines). Plan: `docs/superpowers/plans/2026-08-13-anthropic-profile-sse-parsing.md`.
- **Fix Anthropic profile SEGV in iter 2** (2026-08-13): `buildJsonAnthropicRequest` was constructing `AnthropicContentBlock` structs via `.{ .text = rc }` / `.{ .tool_use = ... }` — Zig 0.16's anonymous struct literal only initializes named fields, leaving `.tool_use` / `.tool_result` as the arena's uninitialized bytes (0xAA debug poison). `AnthropicContentBlock.jsonStringify`'s `if (self.text)` then misread the poisoned bytes as a slice pointer → SEGV in `utf8ValidateSlice` on the second iteration (after arena memory had been reused+re-poisoned). Fix: initialize ALL three optional fields explicitly. Also dropped a premature `defer arena_alloc.free(content_blocks)` that was rewinding the arena bump pointer mid-function. New regression test: `buildJsonAnthropicRequest: assistant message with tool_calls + null reasoning_content survives` in `src/modules/agent/parse_anthropic_sse_test.zig`. 4th commit on `worktree/anthropic-sse-parsing`.
- **Fix Anthropic image upload (content_parts dropped on Anthropic wire)** (2026-08-13): `buildJsonAnthropicRequest` previously ignored `msg.content_parts` entirely — it only emitted `content` as a single text string OR as `tool_use` blocks for assistant messages. So user-attached images (stored correctly in `llm_history.image_urls` and rendered correctly in the frontend) were silently dropped before reaching Anthropic, and the model replied "I don't see any image". OpenAI-style `buildJsonOpenAIRequest` was already handling `content_parts`. Fix: add an `image` variant to `AnthropicContentBlock` (serializes as `{type:"image", source:{type:"url", url:"data:image/..."}}` — Anthropic accepts the `data:` URL shorthand via `source.url`); make the user/system branch of `buildJsonAnthropicRequest` build content_blocks from `msg.content_parts` when present, falling back to the legacy `single.text` path when not. 4 new regression tests in `parse_anthropic_sse_test.zig`: with-image, only-image, plain-text-regression, and explicit-wire-shape (asserts the Anthropic-native `source.url` wrapper is used, not the OpenAI-flat `image_url:` key). Branch: `worktree/anthropic-image-content-parts`. `zig build test --summary all`: 2198 pass, 6 skip, 0 fail.
