# Fix OpenAI Responses Reasoning Leak + Persist Reasoning Metadata

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Goal

Fix `url_style="openai-response"` so that:

1. Responses API reasoning is represented as a separate top-level `type:"reasoning"` item.
2. Reasoning is never merged into the normal assistant `type:"message"` / `output_text` content.
3. `reasoning_content` is persisted to `llm_history`.
4. Responses reasoning metadata (`id`, `encrypted_content`) is persisted when returned.
5. Previous Responses reasoning can be replayed correctly when `store:false`.
6. Frontend continues to render reasoning separately from the final answer.
7. Legacy `url_style="openai"` / Chat Completions remains **100% untouched**.

---

## Architecture

There are two independent API stacks:

```text
url_style="openai"
        │
        └── buildJsonOpenAIRequest
                │
                └── Legacy Chat Completions
                    DO NOT MODIFY


url_style="openai-response"
        │
        └── buildJsonResponsesRequest
                │
                ├── reasoning item
                │     ├── type
                │     ├── id
                │     ├── summary
                │     └── encrypted_content
                │
                └── message item
                      └── output_text

                         ↓

                 Responses SSE parser
                         ↓
                 StreamingAggregator
                         ↓
                    CallResponse
                         ↓
                     workflow
                         ↓
                    LLMHistory
                         ↓
                       SQLite
                         ↓
                  history/replay
                         ↓
                 AgentMessage
                         ↓
              Responses input[]
```

The Responses implementation must not reuse the legacy Chat Completions request representation.

---

# Important Terminology

`reasoning_content` in Pabrik should be treated as:

> **Model-provided reasoning summary displayed by the application.**

It should not be treated as unrestricted hidden chain-of-thought.

The following fields have different purposes:

| Field                         | Purpose                                                                |
| ----------------------------- | ---------------------------------------------------------------------- |
| `reasoning_content`           | Human-readable reasoning summary used by the UI                        |
| `reasoning_id`                | Responses API reasoning item identifier                                |
| `reasoning_encrypted_content` | Opaque API-provided reasoning data required for replay when applicable |

Do not combine these fields.

---

# What Exists Today

## Responses Builder

`src/modules/agent/Agent.zig`

`buildJsonResponsesRequest` currently creates an assistant message like:

```json
{
  "type": "message",
  "role": "assistant",
  "content": [
    {
      "type": "output_text",
      "text": "thinking trace"
    },
    {
      "type": "output_text",
      "text": "final answer"
    }
  ]
}
```

This is incorrect for Responses reasoning.

The existing test in:

```text
src/modules/agent/openai_responses_test.zig
```

currently asserts this merged representation, meaning the test encodes the bug.

---

## Correct Responses Representation

Reasoning must be a separate top-level input item:

```json
{
  "type": "reasoning",
  "id": "rs_123",
  "summary": [
    {
      "type": "summary_text",
      "text": "The calculation requires..."
    }
  ],
  "encrypted_content": "ENCRYPTED_DATA..."
}
```

followed by:

```json
{
  "type": "message",
  "role": "assistant",
  "content": [
    {
      "type": "output_text",
      "text": "There are 9 remote engineers."
    }
  ]
}
```

Therefore:

```text
reasoning_content
        ↓
type:"reasoning"
        ↓
summary[]

NOT:

reasoning_content
        ↓
message.content[]
        ↓
output_text
```

---

# Responses Parser

`parse_responses_stream_chunk` already separates:

```text
response.output_text.delta
        ↓
StreamChunk.content

response.reasoning_text.delta
response.reasoning_summary_text.delta
response.reasoning.delta
        ↓
StreamChunk.reasoning_content
```

The aggregator therefore already keeps:

```zig
content
reasoning_content
```

separately.

However, the parser currently does not reliably capture the terminal reasoning item's:

```text
id
encrypted_content
summary[]
```

These need to be captured from the terminal response output.

---

# DB Design

The existing column:

```sql
reasoning_content TEXT
```

is retained.

Add two new nullable columns:

| Column                        | Type   | Purpose                          |
| ----------------------------- | ------ | -------------------------------- |
| `reasoning_content`           | `TEXT` | Human-readable reasoning summary |
| `reasoning_id`                | `TEXT` | Responses reasoning item ID      |
| `reasoning_encrypted_content` | `TEXT` | Opaque encrypted reasoning data  |

Migration:

```text
083
```

Schema:

```sql
ALTER TABLE llm_history ADD COLUMN reasoning_id TEXT;
ALTER TABLE llm_history ADD COLUMN reasoning_encrypted_content TEXT;
```

Both are nullable.

No index is required because replay reads history by `session_id`.

---

# Why Separate Columns?

Do not store the encrypted data inside `reasoning_content`.

`reasoning_content` is:

```text
human-readable
displayable
frontend-facing
```

while:

```text
reasoning_encrypted_content
```

is:

```text
opaque
API-specific
internal
potentially large
```

Keeping them separate avoids JSON parsing and prevents accidentally exposing encrypted data to the frontend.

---

# Frontend Boundary

The frontend should receive only:

```text
reasoning_content
```

It should **not** receive:

```text
reasoning_id
reasoning_encrypted_content
```

unless there is a specific frontend requirement.

The encrypted reasoning data is an internal persistence/replay artifact.

---

# Curl / API Shape

Example Responses request:

```bash
curl https://api.openai.com/v1/responses \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-5",
    "store": false,
    "reasoning": {
      "effort": "high"
    },
    "input": [
      {
        "type": "reasoning",
        "id": "rs_123",
        "summary": [
          {
            "type": "summary_text",
            "text": "The calculation requires..."
          }
        ],
        "encrypted_content": "ENCRYPTED_DATA..."
      },
      {
        "type": "message",
        "role": "assistant",
        "content": [
          {
            "type": "output_text",
            "text": "There are 9 remote engineers."
          }
        ]
      },
      {
        "role": "user",
        "content": "Now calculate..."
      }
    ]
  }'
```

The important architectural point is:

```text
type:"reasoning"
```

is a **top-level input/output item**, not a content block inside:

```text
type:"message"
```

---

# Global Constraints

* [ ] Keep `buildJsonOpenAIRequest` untouched.
* [ ] Keep `JsonRequest` / `JsonMessage` legacy representation untouched.
* [ ] Keep Chat Completions parser untouched.
* [ ] No platform-specific APIs.
* [ ] Use `ctx.allocator` for per-request arena allocations.
* [ ] Do not `free()` arena-backed slices.
* [ ] Functional tests must use the test harness (`8080..8199`).
* [ ] Do not use port `8081`.
* [ ] **Do not kill the existing port 8081 server.**
* [ ] Tests must be behavioural rather than source-code/static-contract tests.
* [ ] Do not expose `reasoning_encrypted_content` to the frontend.
* [ ] Do not merge reasoning into `output_text`.
* [ ] Do not modify legacy OpenAI behaviour.

---

# File Map

| File                                                                                  | Action     | Purpose                                      |
| ------------------------------------------------------------------------------------- | ---------- | -------------------------------------------- |
| `src/migrations/migration.zig`                                                        | EDIT       | Add Migration 083                            |
| `src/modules/agent/Agent.zig`                                                         | EDIT       | Responses builder/parser/data structures     |
| `src/modules/agent/openai_responses_test.zig`                                         | EDIT       | Responses regression tests                   |
| `src/ai_workflow/tui/agentic_loop/llm_history_row.zig`                                | EDIT       | Add reasoning metadata fields                |
| `src/ai_workflow/tui/agentic_loop/insert_llm_histories.zig`                           | EDIT       | Persist reasoning metadata                   |
| `src/ai_workflow/tui/agentic_loop/llm_history.zig`                                    | EDIT       | Read reasoning metadata                      |
| `src/ai_workflow/tui/agentic_loop/get_llm_histories.zig`                              | EDIT       | Map DB → AgentMessage                        |
| `src/ai_workflow/tui/agentic_loop/workflow.zig`                                       | AUDIT/EDIT | Ensure all assistant paths persist reasoning |
| `src/apps/desktop/src/components/views/ChatView.vue`                                  | AUDIT      | Verify reasoning remains separate            |
| `docs/superpowers/plans/2026-09-01-fix-openai-response-reasoning-leak-and-persist.md` | EDIT       | Implementation plan                          |
| `PABRIK.md`                                                                            | EDIT       | Changelog                                    |

---

# Root Cause

| # | Symptom                                       | Root Cause                                                                                |
| - | --------------------------------------------- | ----------------------------------------------------------------------------------------- |
| 1 | Reasoning appears inside assistant answer     | Responses builder serializes `reasoning_content` as `output_text` inside `type:"message"` |
| 2 | `reasoning_content` is NULL                   | Reasoning persistence path has not been proven across all response/tool-call paths        |
| 3 | Reasoning replay is incomplete                | No DB storage for reasoning item metadata                                                 |
| 4 | Stateless replay loses reasoning metadata     | `reasoning_id` / `encrypted_content` are not persisted                                    |
| 5 | Frontend may display reasoning as answer text | Builder/replay collapses reasoning into normal assistant content                          |

---

# Task 1 — Regression Tests (RED)

## Responses Builder

* [ ] Modify the existing assistant reasoning test to assert the **desired** representation.

Input:

```text
assistantMsg(
    "final answer",
    "thinking trace"
)
```

Expected:

```text
input[]
    ├── type:"reasoning"
    │      ├── summary contains "thinking trace"
    │      └── id when available
    │
    └── type:"message"
           └── output_text contains "final answer"
```

* [ ] Assert the assistant `content[]` does **not** contain `"thinking trace"`.
* [ ] Assert reasoning is not represented as `output_text`.
* [ ] Run the test against the current implementation.
* [ ] Confirm it fails.

The test should fail because the existing implementation still merges reasoning into the assistant message.

---

## DB Round Trip

Add a behavioural test:

```text
saveMessage
    reasoning_content = "trace"
    reasoning_id = "rs_123"
    reasoning_encrypted_content = "ENC..."

        ↓

getMessages

        ↓

assert all three values survive
```

* [ ] Run the test before implementation.
* [ ] Confirm it fails because the new DB fields do not exist.

---

# Task 2 — Migration 083

In:

```text
src/migrations/migration.zig
```

add:

```zig
pub const Migration083AddReasoningIdAndEncryptedContent = struct {
    pub const version: u32 = 83;

    pub fn up(
        db: *SqliteBackend,
        allocator: std.mem.Allocator,
    ) !void {
        try addColumnIfMissing(
            db,
            allocator,
            "llm_history",
            "reasoning_id",
            "reasoning_id TEXT",
        );

        try addColumnIfMissing(
            db,
            allocator,
            "llm_history",
            "reasoning_encrypted_content",
            "reasoning_encrypted_content TEXT",
        );
    }
};
```

* [ ] Register Migration 083 in `allMigrations`.
* [ ] Add migration test verifying both columns exist.
* [ ] Add DB INSERT/SELECT round-trip test.
* [ ] Run:

```bash
zig build test --summary all
```

* [ ] Confirm migration tests pass.

---

# Task 3 — Fix Responses Builder

Modify:

```text
buildJsonResponsesRequest
```

Only.

Do not touch:

```text
buildJsonOpenAIRequest
```

## Desired behaviour

### Reasoning + content

```text
AgentMessage
    reasoning_content = "thinking"
    content = "answer"
```

becomes:

```json
[
  {
    "type": "reasoning",
    "id": "rs_123",
    "summary": [
      {
        "type": "summary_text",
        "text": "thinking"
      }
    ],
    "encrypted_content": "ENC..."
  },
  {
    "type": "message",
    "role": "assistant",
    "content": [
      {
        "type": "output_text",
        "text": "answer"
      }
    ]
  }
]
```

### Reasoning only

```json
[
  {
    "type": "reasoning",
    "summary": [
      {
        "type": "summary_text",
        "text": "thinking"
      }
    ]
  }
]
```

### Content only

```json
[
  {
    "type": "message",
    "role": "assistant",
    "content": [
      {
        "type": "output_text",
        "text": "answer"
      }
    ]
  }
]
```

* [ ] Extend `ResponsesInputItem` to support `type:"reasoning"`.
* [ ] Add reasoning-specific fields:

  * [ ] `id`
  * [ ] `summary`
  * [ ] `encrypted_content`
* [ ] Serialize optional fields conditionally.
* [ ] Do not automatically emit `id: ""` unless the API contract requires it.
* [ ] Preserve the real reasoning ID when replaying historical reasoning.
* [ ] Update `ResponsesInputContent` as necessary.
* [ ] Update builder tests.
* [ ] Confirm reasoning is never emitted as `output_text`.
* [ ] Run:

```bash
zig build test --summary all
```

---

# Task 4 — Capture Responses Reasoning Metadata

Modify:

```text
parse_responses_stream_chunk
```

and the associated aggregation structures.

The parser should handle terminal response events such as:

```text
response.completed
response.incomplete
response.failed
```

When inspecting:

```text
response.output[]
```

find:

```json
{
  "type": "reasoning"
}
```

and capture:

```text
id
summary[]
encrypted_content
```

---

## Summary Handling

Do not assume only:

```text
summary[0]
```

exists.

Process the complete summary array.

Conceptually:

```text
summary[0].text
summary[1].text
summary[2].text
...
```

should be combined into the application's:

```text
reasoning_content
```

using the existing expected formatting.

Delta events remain the primary streaming source for reasoning content.

Terminal `summary[]` should provide fallback/completion data when necessary.

---

## CallResponse

Extend:

```zig
CallResponse
```

with:

```zig
reasoning_id: ?[]const u8
reasoning_encrypted_content: ?[]const u8
```

---

## StreamingAggregator

Extend it with:

```zig
reasoning_id: ?[]const u8
reasoning_encrypted_content: ?[]const u8
```

Reasoning deltas:

```text
reasoning delta
    ↓
reasoning_content
```

Terminal output:

```text
reasoning item
    ↓
reasoning_id
reasoning_encrypted_content
summary fallback
```

* [ ] Add parser test with `response.completed`.
* [ ] Assert `reasoning_content`.
* [ ] Assert `reasoning_id`.
* [ ] Assert `reasoning_encrypted_content`.
* [ ] Add test with multiple summary entries.
* [ ] Add test for a response containing no reasoning item.
* [ ] Run:

```bash
zig build test --summary all
```

---

# Task 5 — Persist Reasoning on Every Agent Path

Update:

```text
LLMHistory
```

with:

```text
reasoning_id
reasoning_encrypted_content
```

Update:

```text
insert_llm_histories.zig
```

to persist:

```text
reasoning_content
reasoning_id
reasoning_encrypted_content
```

Update:

```text
llm_history.zig
```

SELECT statements.

Update:

```text
get_llm_histories.zig
```

to map:

```text
SQLite
    ↓
LLMHistory
    ↓
AgentMessage
```

---

# Task 5.1 — Normal Stop Path

Audit:

```text
finish_reason == .stop
```

Ensure:

```text
res_dynamic_agent.reasoning_content
res_dynamic_agent.reasoning_id
res_dynamic_agent.reasoning_encrypted_content
```

all reach:

```text
insertLLMHistories
```

---

# Task 5.2 — Tool Call Path

Explicitly test:

```text
finish_reason == .tool_calls
```

Do not assume this path behaves like `.stop`.

Verify that the assistant turn preceding the tool call persists:

```text
reasoning_content
reasoning_id
reasoning_encrypted_content
```

---

# Task 5.3 — Other Completion Paths

Audit:

```text
finish_reason == .length
finish_reason == null
finish_reason == .incomplete
finish_reason == .failed
```

Reasoning metadata must not silently disappear.

If the API does not return reasoning metadata for a particular path, nullable fields should remain `NULL`.

---

# Task 6 — Multi-Turn Replay Test

Add an integration test for:

```text
user
  ↓
assistant reasoning + answer
  ↓
user
  ↓
assistant reasoning + answer
```

Expected reconstructed Responses input:

```text
[
    user,
    reasoning,
    assistant,
    user,
    reasoning,
    assistant
]
```

* [ ] Verify chronological ordering.
* [ ] Verify each reasoning item stays associated with the correct assistant response.
* [ ] Verify each reasoning item preserves its own ID.
* [ ] Verify encrypted content is replayed verbatim.
* [ ] Verify reasoning is not inserted into assistant `output_text`.

---

# Task 7 — Tool-Call Replay Test

Add a behavioural test representing the agentic flow:

```text
user
    ↓
assistant reasoning
    ↓
assistant tool call
    ↓
tool result
    ↓
assistant reasoning
    ↓
assistant final answer
```

Verify:

* [ ] reasoning is persisted for the tool-call turn.
* [ ] reasoning metadata survives DB round-trip.
* [ ] tool call remains separate from reasoning.
* [ ] final answer remains separate from reasoning.
* [ ] next Responses request reconstructs the correct sequence.
* [ ] encrypted reasoning content is preserved exactly.

---

# Task 8 — End-to-End Persistence Test

Mock a Responses SSE stream containing:

```text
response.reasoning_text.delta
response.output_text.delta
response.completed
```

where `response.completed.output[]` contains:

```json
[
  {
    "type": "reasoning",
    "id": "rs_123",
    "summary": [
      {
        "type": "summary_text",
        "text": "thinking"
      }
    ],
    "encrypted_content": "ENC..."
  },
  {
    "type": "message",
    "role": "assistant"
  }
]
```

Run:

```text
SSE
 ↓
parse
 ↓
StreamingAggregator
 ↓
CallResponse
 ↓
workflow
 ↓
insertLLMHistories
 ↓
SQLite
 ↓
getMessages
```

Assert:

```text
reasoning_content == "thinking"
reasoning_id == "rs_123"
reasoning_encrypted_content == "ENC..."
```

---

# Task 9 — Frontend Verification

Audit:

```text
ChatView.vue
```

Verify:

```text
reasoning_content
    ↓
reasoning/collapsible UI

content
    ↓
normal markdown answer
```

They must never be concatenated.

* [ ] Verify `filteredMessages` keeps reasoning-only messages.
* [ ] Verify reasoning is rendered separately.
* [ ] Verify `content` contains only normal assistant output.
* [ ] Verify `transformLLMHistoryToAgentMessage` preserves `reasoning_content`.
* [ ] Verify `reasoning_id` and `reasoning_encrypted_content` are not unnecessarily exposed to the frontend.
* [ ] Run:

```bash
pnpm test:unit
```

---

# Task 10 — Legacy API Regression

Legacy implementation must remain untouched.

Verify:

```text
buildJsonOpenAIRequest
JsonRequest
JsonMessage
Chat Completions parser
```

remain functional.

Run:

```bash
zig build test --summary all
```

Specifically confirm:

```text
openai_reasoning_test.zig
parse_anthropic_sse_test.zig
```

and existing OpenAI/legacy tests pass.

Do not refactor legacy code as part of this fix.

---

# Task 11 — Full Verification

Run:

```bash
zig build test --summary all
```

Expected:

```text
0 failures
```

Run:

```bash
zig build pabrik-desktop --summary all
```

Expected:

```text
0 failures
```

Run:

```bash
pnpm test:unit
```

Expected:

```text
0 failures
```

---

# Task 12 — Manual Smoke Test

Configure:

```text
url_style = "openai-response"
reasoning_effort = "medium"
store = false
```

Send a message.

Check:

```sql
SELECT
    id,
    reasoning_content,
    reasoning_id,
    reasoning_encrypted_content
FROM llm_history
WHERE session_id = ?
  AND role = 'assistant'
ORDER BY created_at;
```

Do **not** require every assistant row to contain reasoning.

For responses where the API returned reasoning, verify:

```text
reasoning_content != NULL
reasoning_id != NULL when returned
reasoning_encrypted_content != NULL when returned
```

For responses without reasoning:

```text
reasoning_* may remain NULL
```

---

## Next-Turn Verification

Send another message and inspect the generated Responses request.

Verify the previous reasoning is reconstructed as:

```json
{
  "type": "reasoning",
  "id": "rs_123",
  "summary": [...],
  "encrypted_content": "ENC..."
}
```

and **not**:

```json
{
  "type": "message",
  "role": "assistant",
  "content": [
    {
      "type": "output_text",
      "text": "thinking..."
    }
  ]
}
```

---

# Task 13 — Documentation

Update:

```text
PABRIK.md
```

with:

```markdown
### 2026-09-01: Fix OpenAI Responses reasoning leak + persistence

- Fixed Responses reasoning being serialized as assistant `output_text`.
- Added separate Responses `type:"reasoning"` input items.
- Persisted Responses reasoning metadata.
- Added Migration 083.
- Preserved legacy OpenAI Chat Completions behaviour.
```

---

# Task 14 — Commit

After all tests pass:

* [ ] Review the diff.
* [ ] Confirm no legacy OpenAI code was modified unnecessarily.
* [ ] Confirm no encrypted reasoning data is sent to the frontend.
* [ ] Confirm Migration 083 is registered.
* [ ] Confirm all tests pass.
* [ ] Commit the changes.

---

# Verification Checklist

* [ ] Responses reasoning is a top-level `type:"reasoning"` item.
* [ ] Reasoning is not serialized as `output_text`.
* [ ] Assistant final answer remains a normal `type:"message"`.
* [ ] `reasoning_content` is persisted.
* [ ] `reasoning_id` is persisted when returned.
* [ ] `reasoning_encrypted_content` is persisted when returned.
* [ ] Multiple summary entries are handled.
* [ ] Reasoning metadata survives DB round-trip.
* [ ] Multi-turn replay preserves ordering.
* [ ] Tool-call turns preserve reasoning.
* [ ] `store:false` replay works.
* [ ] Encrypted reasoning data stays out of the frontend.
* [ ] Frontend renders reasoning separately.
* [ ] Legacy Chat Completions remains unchanged.
* [ ] `zig build test --summary all` passes.
* [ ] `zig build pabrik-desktop --summary all` passes.
* [ ] `pnpm test:unit` passes.
* [ ] Manual smoke test passes.
* [ ] PABRIK.md updated.
* [ ] Changes committed.

---

# Pitfalls

* **Do not modify legacy Chat Completions.**
* **Do not merge reasoning into `output_text`.**
* **Do not treat `reasoning_content` as unrestricted hidden chain-of-thought.**
* **Do not assume `summary[0]` is the only summary entry.**
* **Do not automatically emit `id: ""`.**
* **Do not expose `reasoning_encrypted_content` to the frontend.**
* **Do not drop reasoning on `tool_calls`.**
* **Do not assume every assistant response has reasoning.**
* **Do not assume terminal responses always contain the same reasoning fields; handle nullable fields.**
* **Do not forget the complete data flow:**

```text
Responses SSE
    ↓
parser
    ↓
StreamingAggregator
    ↓
CallResponse
    ↓
workflow
    ↓
LLMHistory
    ↓
SQLite
    ↓
get_llm_histories
    ↓
AgentMessage
    ↓
buildJsonResponsesRequest
```

* **Do not kill the existing port 8081 server.**
* **Do not use static source-code tests such as `expect(source).toContain(...)`.**
* **Do not remove or rewrite the legacy implementation just to share code.**

---

# Worktree

```text
/home/ginwa/ginwaaitoolbox/.worktrees/fix-openai-response-reasoning
```

Branch:

```text
worktree/fix-openai-response-reasoning
```

Base:

```text
250ae757
```
