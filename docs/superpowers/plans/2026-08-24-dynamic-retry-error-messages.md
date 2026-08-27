# Dynamic Retry Error Messages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every user-visible retry/bail diagnostic show the actual server reason (HTTP status + response body, scanner error, raw SSE sample) instead of the static `StreamInterrupted (source: callDynamicAgentNew)`.

**Architecture:** The transport layer (`Agent.callStreaming`) already captures rich detail into `last_error_message`, and `callDynamicAgentNew` already copies it out via `out_last_error_message`. The workflow's retry-catch block logs it but drops it from the three user-visible surfaces: the per-retry chat message (`saveRetryAttemptMessage`), the unattended soft-bail snapshot, and the hard-bail TooManyRetries diagnostic. This plan threads a `server_detail` string through those three sites — no changes to Agent.zig, no schema changes, no frontend changes.

**Tech Stack:** Zig 0.16 (std.fmt.allocPrint multiline literals), existing `insertLLMHistories` plumbing, existing static-contract test pattern (`pub const` grep-based tests).

## Global Constraints

- **No changes to `src/modules/agent/Agent.zig`** — the capture side is already correct and tested.
- **No DB migration** — diagnostics are written with `.is_skip_db = true`; they live only in the SSE stream / chat view.
- **No frontend changes** — messages arrive as ordinary assistant/user-role SSE content.
- **Truncate server detail to 500 chars** in user-visible messages (the raw detail can be up to 2 KiB; 10 retries × 2 KiB would flood the chat).
- **Never leak the API key** — `last_error_message` never contains it today; keep it that way by only passing through the pre-built detail string.
- **Preserve exact behavior when detail is null** — fall back to `(no server detail)` so old error shapes still read naturally.
- Do NOT touch port 8081 for any verification run.
- Every task ends with a commit on branch `worktree/dynamic-retry-error-messages`.

---

## Background: where the message comes from and where it dies

```
Agent.callStreaming (src/modules/agent/Agent.zig)
  ├─ HTTP status != 200        → last_error_message = "HTTP {d}: {body}..."   (:1962)
  ├─ scanner.next() fails      → last_error_message = "scanner.next failed after {d} chunk(s): {err}" (:2044)
  └─ stream ends w/o finish    → last_error_message = "stream ended without finish_reason after {d} chunk(s); first server lines: ..." (:2128)
        │
        ▼
callDynamicAgentNew (workflow.zig:1637)
  └─ catch → out_last_error_message.* = dupe(last_error_message)   (:1716-1718)
        │
        ▼
workflow retry-catch (workflow.zig:1197-1239)
  ├─ logger.errFmt(... server_detail ...)          ✅ logged to file
  ├─ saveRetryAttemptMessage(...)                  ❌ DROPS server_detail — prints only @errorName
  │
  ▼ (after 10 retries)
TooManyRetries bail
  ├─ soft-bail diagnostic  (workflow.zig:1040-1043) ❌ DROPS — prints only @errorName + source
  └─ hard-bail diagnostic  (workflow.zig:1082-1085) ❌ DROPS — prints only @errorName + source
```

The fix: hoist `server_detail` into a loop-scoped variable, thread it into all three formatters.

---

## Task 1 — Thread `server_detail` into `saveRetryAttemptMessage`

**Files:** `src/ai_workflow/tui/agentic_loop/workflow.zig` (only file in this task)

### Step 1.1 — Write failing static-contract test

Create `src/ai_workflow/tui/agentic_loop/workflow_retry_detail_test.zig` following the repo's static-contract pattern (grep the function body between `fn saveRetryAttemptMessage` and the next `pub fn`/`fn`, assert the new parameter + format specifier exist). Test asserts:

- signature contains `server_detail: []const u8`
- format literal contains `{s}` count matching arg count (i.e. the body now interpolates `server_detail`)
- both call sites pass a non-literal variable named `server_detail`

Run: `zig build test --summary all 2>&1 | tail -n 20` → expect FAIL (parameter doesn't exist yet).

### Step 1.2 — Extend the function

In `saveRetryAttemptMessage` (workflow.zig:1566):

- Add param `server_detail: []const u8` after `error_name`.
- Change the format literal:

```zig
\\[Retry {d}/{d}] {s} ({s}). Retrying in {d}ms.
\\Server said: {s}
```

with args `.{ attempt, max_attempts, error_name, source, delay_ms, server_detail }`.

- Keep the OOM fallback path (`catch |err| blk:` → `"[Retry error: formatting failed]"`) unchanged.

### Step 1.3 — Update call site 1 (retry-catch, workflow.zig:1222)

Hoist above the `callDynamicAgentNew` call (next to `var last_dynamic_agent_error_message`):

```zig
var server_detail_buf: ?[]const u8 = null;
```

In the catch block, before `saveRetryAttemptMessage`:

```zig
const server_detail = server_detail_buf orelse "(no server detail)";
```

and pass `server_detail` as the new final argument.

Note: `out_last_error_message` (`last_dynamic_agent_error_message`) is already populated by `callDynamicAgentNew` before the catch fires — reuse it directly instead of adding a second variable if cleaner:

```zig
const server_detail = last_dynamic_agent_error_message orelse "(no server detail)";
```

(Preferred — one variable, no duplication.)

### Step 1.4 — Update call site 2 (finish_reason else, workflow.zig:1418)

Pass `"unexpected finish_reason (no HTTP exchange failed)"` — this path has no transport error; the LLM responded but with an unusable finish_reason. Literal is fine here.

### Step 1.5 — Run tests

`zig build test --summary all 2>&1 | tail -n 20` → PASS. Confirm no leaks reported.

### Step 1.6 — Commit

```
git add -A && git commit -m "workflow: include server detail in per-retry chat diagnostics"
```

---

## Task 2 — Thread `server_detail` into the TooManyRetries bail diagnostics

**Files:** `src/ai_workflow/tui/agentic_loop/workflow.zig`

### Step 2.1 — Add loop-scoped capture variable

Next to `var last_retry_error` / `var last_retry_source` (workflow.zig:648-649):

```zig
/// Most recent server-side reason string (HTTP status+body, scanner error,
/// raw SSE sample) captured from `last_dynamic_agent_error_message` at each
/// retry. Reset alongside `last_retry_error` everywhere that resets those.
var last_retry_server_detail: ?[]const u8 = null;
```

Lifetime note: the string is duped into the per-iteration arena by `callDynamicAgentNew`; the arena lives until end-of-iteration, which fully covers both bail sites (they fire inside the same iteration as the failure). No extra ownership work needed — but DO NOT free it manually (arena-owned).

### Step 2.2 — Capture in the retry-catch (workflow.zig:1208-1209)

After `last_retry_source = "callDynamicAgentNew";` add:

```zig
last_retry_server_detail = last_dynamic_agent_error_message;
```

### Step 2.3 — Capture in the finish_reason-else path (workflow.zig:1413-1414)

```zig
last_retry_server_detail = null; // no transport error on this path
```

### Step 2.4 — Reset at all existing reset points

Three reset sites set `last_retry_error = error.Unknown; last_retry_source = "unknown";` — add `last_retry_server_detail = null;` next to each:

- soft-bail reset (workflow.zig:1076-1077)
- success-path reset (workflow.zig:1277-1278)
- post-finish_reason-block reset (workflow.zig:1443-1444)

### Step 2.5 — Soft-bail diagnostic (workflow.zig:1040-1043)

Change to:

```zig
const soft_diagnostic = std.fmt.allocPrint(allocator,
    \\[Agent Nalar System info] unattended-mode soft-bail after {} consecutive retries.
    \\Reason for last retry: {s} (source: {s}).
    \\Server said: {s}
    \\The session keeps running.
, .{ retry_count, reason_error, reason_source, last_retry_server_detail orelse "(no server detail)" }) catch "unattended soft-bail snapshot";
```

### Step 2.6 — Hard-bail diagnostic (workflow.zig:1082-1085)

Change to:

```zig
const diagnostic = std.fmt.allocPrint(allocator,
    \\[Agent Nalar System error] workflow halted after {} consecutive retries.
    \\Reason for last retry: {s} (source: {s}).
    \\Server said: {s}
, .{ retry_count, reason_error, reason_source, last_retry_server_detail orelse "(no server detail)" }) catch "workflow halted after too many retries";
```

Also extend the adjacent `logger.errFmt` (workflow.zig:1087) with `— server: {s}` + the detail, so the log file carries it too.

### Step 2.7 — Truncation guard

Add a tiny helper near `saveRetryAttemptMessage`:

```zig
fn clampDetail(detail: []const u8, max_len: usize) []const u8 {
    if (detail.len <= max_len) return detail;
    return detail[0..max_len];
}
```

Use `clampDetail(detail, 500)` at all three interpolation sites (soft-bail, hard-bail, and pass-through into Task 1's `saveRetryAttemptMessage` call — clamp once at the catch site so every downstream consumer gets the clamped version).

### Step 2.8 — Extend the static-contract test

In `workflow_retry_detail_test.zig`: assert `last_retry_server_detail` appears ≥ 6 times (decl + capture + 3 resets + 2 reads), and both bail literals contain `Server said: {s}`.

### Step 2.9 — Run tests

`zig build test --summary all 2>&1 | tail -n 20` → PASS.

### Step 2.10 — Commit

```
git add -A && git commit -m "workflow: surface server detail in TooManyRetries soft/hard bail diagnostics"
```

---

## Task 3 — End-to-end verification + docs

**Files:** none (verification only), plus plan checkbox updates.

### Step 3.1 — Full test suite

```
zig build test --summary all 2>&1 | tail -n 20
```

Expect: 0 fail, 0 leaks (baseline ~2400 pass).

### Step 3.2 — Manual smoke (optional, only if a mock provider is handy)

Point a profile's `base_url` at a local server returning `HTTP 429 {"error":"quota exceeded"}` and confirm the chat shows `[Retry 1/10] ApiError (callDynamicAgentNew). Retrying in 0ms.` followed by `Server said: HTTP 429: {"error":"quota exceeded"}`. Skip if wiring a mock takes >15 min — the static-contract tests lock the wire shape.

### Step 3.3 — Update kanban + report

Move card `task_1787540075329_3` to `in_review_task` (col_1826ecca367f0000) with a summary of before/after messages.

### Step 3.4 — Final commit (if any doc edits)

```
git add -A && git commit -m "docs: dynamic retry error messages plan executed"
```

---

## Pitfalls

- **Arena lifetime:** `last_dynamic_agent_error_message` is duped into the per-iteration arena inside `callDynamicAgentNew`. Both bail sites fire within the SAME iteration as the failure, so the pointer is valid — do not cache it across iterations (the reset sites prevent exactly that).
- **Multiline literal escaping:** Zig `\\`-literals don't process `\n`; each line is its own `\\` row. Don't try to embed newlines inside a single row.
- **Don't reformat the whole file** — surgical patches only; the file has heavy comment density that reviewers rely on.
- **`is_skip_db = true` stays** on all three diagnostics — they must not pollute persistent history or the AI's next-turn context beyond what exists today.

## Verification

- [ ] `zig build test --summary all` passes with the new static-contract test
- [ ] New test FAILS when the `server_detail` param/format is reverted (mutation check)
- [ ] Both bail messages + per-retry message contain `Server said: <actual HTTP status/body>` when the provider returns an error body
- [ ] No changes under `src/modules/agent/`, no migration files, no frontend files
