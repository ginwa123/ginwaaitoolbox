# TASK 3 BRIEF — wire substitution into the dispatch path

WORK DIRECTLY IN THIS EXISTING WORKTREE — do NOT call `set_git_worktree`, do NOT create a
new worktree, do NOT touch `/home/ginwa/ginwaaitoolbox`:

    /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930

`cd` there for every command. All paths below are relative to that directory.

Repo: **nalar**, Zig 0.16. Tasks 1 and 2 are already committed and merged:
- `src/agentic_loop/secrets_store.zig` — `loadSecretValues`, `listSecretNames`, …
- `src/agentic_loop/secrets_substitution.zig` — `substituteToolArguments`, `redactOutput`

Read BOTH modules' public surfaces before you start. They already exist — **do not modify
either module**, and do not touch migrations, HTTP handlers, tools registry, prompt
assembly, or any frontend file. Your job is `src/agentic_loop/handle_tool.zig` only
(plus its inline tests, which live in the same file).

Plan: `docs/superpowers/plans/2026-10-02-workspace-secrets.md` (rev 2) — `### Task 3` and
Design Decisions 3 and 5.

This is the most security-critical task in the plan. The promise being built is: **the model
never receives a secret value.** Two properties carry that promise and both must hold:

- **A** — the executor gets the real value, and
- **B** — the model gets `{{SECRETS:NAME}}` everywhere it can read: in the DB, in the tool
  result, over SSE.

---

## The APIs you already have

```zig
// secrets_substitution.zig
pub const ResolvedSecret = struct { name: []const u8, value: []const u8 };
pub const SubstitutionResult = struct {
    substituted_args: []const u8,
    resolved: []const ResolvedSecret,
};
pub const Resolver = *const fn (ctx: ?*const anyopaque, name: []const u8) ?[]const u8;
pub const SubstError = error{ UnknownSecretName, InvalidArguments, OutOfMemory };

pub fn substituteToolArguments(
    allocator, args_json, resolver: Resolver, ctx: ?*const anyopaque, out: *SubstitutionResult,
) SubstError!void;

pub fn redactOutput(allocator, output, resolved: []const ResolvedSecret) ![]u8;  // allocator-owned
```

```zig
// secrets_store.zig
pub const SecretValueRow = struct { name: []const u8, value: []const u8 };
pub fn loadSecretValues(
    allocator, db, workspace_id: []const u8, names: []const []const u8,
) SecretsError![]SecretValueRow;   // free with freeSecretValueRows
```

Workspace resolution is server-side from the session — the model can never choose it:

```zig
// workspace_scope.zig
pub fn resolveWorkspaceId(allocator, db, session_id) !?[]u8;   // null = fail closed
```

---

## STEP 1 — the resolver adapter

Write a private adapter in `handle_tool.zig` (or a tiny sibling module if you prefer —
say so in your report) that adapts the store to the `Resolver` function pointer.

It needs: `allocator`, `db`, `workspace_id`. It must be **fail-closed**:

- `resolveWorkspaceId` returns null (no workspace) → the resolver returns null for
  every name → every placeholder fails as `UnknownSecretName`. Do NOT treat "no
  workspace" as "no substitution needed and pass the placeholder through".
- Never log the value. Never include it in an error message.

**Cache it.** A placeholder name may repeat; query the store once per distinct name.
A `std.StringHashMap` keyed on name, with the resolved value stored in the store's own
allocation, is the expected shape. Do NOT pre-scan the args JSON for placeholder names
yourself — `substituteToolArguments` owns that detection, and a second detector that can
disagree with it is a correctness bug.

---

## STEP 2 — substitution in `dispatchTool` (built-in tools)

`dispatchTool` is at `handle_tool.zig:192`. Current shape:

```zig
fn dispatchTool(ctx: ToolContext, tool_call: agent.ToolCall) !ToolResult {
    var effective_call = tool_call;              // :193
    ...
    switch (runPreHookAction(ctx, effective_call.function.name, tool_call.function.arguments)) {  // :207
        .proceed => {},
        .proceed_modified => |a| { ...; effective_call.function.arguments = a; },   // :211
        .short_circuit => |out| return ToolResult{ .output = out },
    }
    // :217-221 the registry walk
    for (tools_equipped.UNIFIED_TOOL_REGISTRY()) |entry| { ... }
```

Insert the substitution **between the pre-hook and the registry walk**, operating on
`effective_call`:

```zig
var sub_result: secrets_substitution.SubstitutionResult = .{ .substituted_args = "", .resolved = &.{} };
defer /* free sub_result per its ownership rules — see the module docstring */;
sub_result = secrets_substitution.substituteToolArguments(
    allocator, effective_call.function.arguments, resolver, resolver_ctx, &sub_result,
) catch |err| { /* build a wrapToolOutput error envelope naming the MISSING KEY; return without dispatching */ };
effective_call.function.arguments = sub_result.substituted_args;
```

**Why after the pre-hook and not before** — this is Design Decision 3, do not invert it: a
user-authored Lua hook receives `arguments` and may log or rewrite them. Substituting
before would hand plaintext to arbitrary user Lua with nothing downstream to redact it.
After, the hook sees `{{SECRETS:NAME}}` and only the executor sees the value.

Note `.proceed_modified` REPLACES the arguments at `:211`, so you must substitute whatever
the hook produced, not the original string. Substituting after the switch handles this
correctly.

**On error, never dispatch.** For `error.UnknownSecretName`, build the standard
`wrapToolOutput` failure envelope whose message names the key that was missing — the agent
can only act on a specific, immediate error. An empty substitution would surface much later
as an opaque third-party 401. `error.InvalidArguments` means the args were not valid JSON,
which is also a hard failure; say so in the message.

---

## STEP 3 — substitution in the MCP branch (MANDATORY, second call site)

Phase 3 of `handle_tool` intercepts MCP tools at `handle_tool.zig:747` and `continue`s —
**MCP tools never reach `dispatchTool`**. It already builds a mutable copy:

```zig
var mcp_call = tool_call;              // :748
switch (runPreHookAction(ctx, tool_call.function.name, tool_call.function.arguments)) { ... }  // :751
tool_result = handle_mcp_tool.handle_mcp_tool_run(allocator, logger, mcp_call, config) catch ...
```

Apply the identical substitution to `mcp_call` after that pre-hook and before
`handle_mcp_tool_run`. An authenticated MCP call is the single most likely place a user
wants a secret, so a hook placed only in `dispatchTool` would fail exactly where it matters.

---

## STEP 4 — redaction at all six persist sites

`redactOutput` must run on `tool_result` **before** every `updateAndSendToolResult` call.
There are exactly six, all in the Phase-3 loop — verify this list yourself with
`grep -n 'try updateAndSendToolResult' src/agentic_loop/handle_tool.zig`:

| line | branch |
|---|---|
| `:739` | unknown tool |
| `:760` | MCP pre-hook short-circuit |
| `:778` | MCP dispatch error |
| `:785` | MCP result |
| `:798` | built-in dispatch error |
| `:850` | built-in result |

Each becomes: redact → free the original → persist the redacted copy. **There are exactly
six; do not miss one.** For the branches where substitution never ran (`resolved` is
empty), `redactOutput` returns an unchanged dupe — that is fine and cheap.

**Why redaction is the feature, not hardening (Design Decision 5):**
`src/modules/agent/tools/shell.zig:874-881` puts `result.command` — the fully substituted
command — into the tool result `data`. So `curl -H "Auth: {{SECRETS:gh}}"` returns the real
token to the model, and from there into the next provider request and into `llm_history`.
Without redaction the value is still never *stored* in the clear, but it is handed to the
model on the very first call. Redaction is what makes the promise true.

---

## STEP 5 — keep the DB holding the placeholder (property B)

**Do NOT mutate `tool_call`.** Substitute into the copy only (`effective_call` /
`mcp_call`). This is load-bearing and already true by construction:

- Phase 2 persists the assistant row with the RAW arguments at `handle_tool.zig:533`,
  textually BEFORE dispatch at `:790`.
- Both persistence paths — the Phase-1 placeholder (`:601`, `:610`) and the error envelope
  (`:796`) — pass `tool_call.function.arguments`, NOT the substituted copy.

So `llm_history.tool_calls_json` keeps `{{SECRETS:NAME}}`. **Your job is to not break
that.** Passing the original `tool_call` to `updateAndSendToolResult` and to `wrapToolOutput`
is what preserves it.

---

## STEP 6 — threading `resolved` out of `dispatchTool`

`redactOutput` needs the `resolved` list at the persist sites, which are OUTSIDE
`dispatchTool`. Add a field to the private `ToolResult` struct in `handle_tool.zig`:

```zig
secrets: []const secrets_substitution.ResolvedSecret = &.{},
```

Populate it from `sub_result.resolved` on the success path, and return the (usually empty)
list on every early return. The caller then redacts. Document the ownership rule on the
field: who frees it, and when — follow whatever convention the struct's other fields use.

---

## STEP 7 — tests (inline, in `handle_tool.zig`)

This repo has NO `*_test.zig` files; all Zig tests are inline `test "..."` blocks.

**The worked template already exists:** `hookDispatchSetup()` at `handle_tool.zig:1631`
builds a real in-memory SQLite and a real `ToolContext`, and the tests at `:1693-1806` call
`dispatchTool` directly. Read those and follow them.

Required:

1. **A — the executor receives the real value.** Seed a secret in the in-memory DB, run a
   dispatch whose arguments carry `{{SECRETS:NAME}}`, and assert the executor saw the
   value. Use a real registry tool whose effect you can observe (the existing tests use
   `read_file`).
2. **B — the DB keeps the placeholder.** After the same dispatch, read back the
   `llm_history` `tool_calls_json` and assert it contains `{{SECRETS:NAME}}` and does NOT
   contain the value. **This is the single most important test in the plan** — it is what
   pins property B. Do not skip it.
3. **Redaction.** A tool whose output contains the substituted value has that value
   scrubbed before persistence — assert the persisted result contains the placeholder and
   not the value. Give the `shell.zig` echo case its own explicit test; it is the leak that
   survives if redaction is applied at the wrong layer.
4. **Static contract test.** A source-grep test (copy the shape of the existing static
   contract tests in this file, e.g. around `:1402` and `:3781`-style tests in
   `workflow.zig`) asserting the MCP branch at `:747` contains the substitution call. This
   exists so a future edit cannot silently delete the second call site.
5. **Unknown placeholder.** `{{SECRETS:NOPE}}` produces a `wrapToolOutput` failure
   envelope naming `NOPE` and the tool is **not** dispatched.
6. **Fail-closed.** A session that resolves to no workspace → placeholder fails as unknown,
   never passed through.

**TDD: write the failing test first, watch it fail, then implement.**

---

## GATE

```bash
cd /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930
zig build test --summary all
```

Must report `Build Summary: 8/8 steps succeeded` and exit 0.

**Read this before you panic:** the run prints a spurious
`failed command: .../test --listen=-` line immediately BEFORE the success summary. It is
**not** a failure signal — trust the Build Summary and the exit code. Also, the cold build
takes roughly 10+ minutes; that is normal. Do not run two `zig build test` invocations
concurrently in this tree — they contend on `.zig-cache` and produce a genuine spurious
failure.

If failures appear in files you did not touch, report them rather than fixing them.

Commit when green:

```
feat(secrets): substitute at dispatch, redact before persist
```

---

## HARD CONSTRAINTS

- **No `// NEW (plan: ...)` comments.** Explain WHY in one plain sentence, or not at all.
- Do NOT modify `secrets_store.zig` or `secrets_substitution.zig`. If you believe one of them
  must change, STOP and report it.
- Do NOT add a `user_id` to anything. Access is workspace membership via `workspace_members`
  (`auth_common.canSeeWorkspace`), resolved server-side from `ctx.session_id`.
- Never log a resolved value, never put one in an error message, never write one to the DB.
- If you conclude any file other than `handle_tool.zig` must change, STOP and report.

## REPORT BACK

Files changed, exact commit sha, the `Build Summary` line, how you shaped the resolver
adapter, which of the six redaction sites you changed, and any deviation with its reason.