# TASK 2 BRIEF — `secrets_substitution.zig` (pure substitute + redact)

WORK DIRECTLY IN THIS EXISTING WORKTREE — do NOT call `set_git_worktree`, do NOT create a
new worktree, do NOT touch `/home/ginwa/ginwaaitoolbox`:

    /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930

`cd` there for every command. All paths below are relative to that directory.

Repo: **nalar**, Zig 0.16 backend. We are implementing a workspace-scoped "Secrets" feature.
Plan: `docs/superpowers/plans/2026-10-02-workspace-secrets.md` (rev 2) — read `### Task 2`
and the Design Decisions 4 and 5 sections before you start.

**Your task is Task 2 only.** Another agent is concurrently adding Migration 101 and
`secrets_store.zig` (Task 1) in the same tree. Do NOT create migrations, do NOT create or edit
`secrets_store.zig`, do NOT touch `handle_tool.zig`, `workflow.zig`, tools, HTTP handlers, or
any frontend file.

**Your module must be PURE**: no DB, no filesystem, no crypto. It must not import
`handle_tool`, `workflow`, or any `http_handlers` file — no import cycles.

---

## What it does

The model writes `{{SECRETS:NAME}}` inside **any** tool-call argument. This module replaces it
with the real value, and can separately redact values back **out** of a tool's output. It never
logs and never persists anything.

---

## Public surface — create `src/agentic_loop/secrets_substitution.zig`

```zig
pub const ResolvedSecret = struct { name: []const u8, value: []const u8 };

pub const SubstitutionResult = struct {
    substituted_args: []const u8,     // allocator-owned
    resolved: []const ResolvedSecret, // allocator-owned; empty when nothing matched
};

/// Maps a name to its value, or null when unknown. Injected as a function
/// pointer so this file needs no DB.
pub const Resolver = *const fn (ctx: ?*const anyopaque, name: []const u8) ?[]const u8;

pub const SubstError = error{ UnknownSecretName, InvalidArguments, OutOfMemory };

pub fn substituteToolArguments(
    allocator: std.mem.Allocator,
    args_json: []const u8,
    resolver: Resolver,
    ctx: ?*const anyopaque,
    out: *SubstitutionResult,
) SubstError!void;

pub fn redactOutput(
    allocator: std.mem.Allocator,
    output: []const u8,
    resolved: []const ResolvedSecret,
) ![]u8;
```

---

## Algorithm — this exact approach is a reviewed decision, do not "improve" it

1. Parse `args_json` with `std.json.parseFromSlice(std.json.Value, ...)`.
   If it does NOT parse, return `error.InvalidArguments`. **Do not fall back to raw-byte
   replacement.**
2. Walk the tree. Substitute ONLY inside `.string` leaves, recursing through `.object` and
   `.array`. A placeholder inside a number / bool / null leaf is left alone.
3. In each string leaf, find `{{SECRETS:<name>}}` where `<name>` matches `[A-Za-z0-9_-]{1,64}`.
   Replace with the resolved value.
4. Re-serialize with `std.json.Stringify.valueAlloc`.
5. **Never re-scan the substituted text**, so a value that itself contains `{{SECRETS:X}}`
   cannot recurse.
6. An unresolvable name returns `error.UnknownSecretName` (the caller turns that into a named
   tool error). **Never substitute an empty string.**

`redactOutput` replaces each `resolved[i].value` occurrence in `output` with the literal
`{{SECRETS:<name>}}`. If a value does not occur, the output is returned unchanged.

---

## Why raw-byte replacement is forbidden — put this in the module docstring

Read `src/agentic_loop/tools_wrap_output.zig:94` and `src/agentic_loop/handle_tool.zig:1680`
first. A value containing a double-quote terminates the JSON string literal; a value containing
a backslash becomes an escape leader; and two consumers (`normalizeParamsJson`,
`repairToolCallArguments` at `src/modules/agent/Agent.zig:1785`) **FAIL SILENTLY** rather than
erroring — the model gets `{"_raw": "..."}` or `{}` instead of an error. `jsonEscapePath` at
`handle_tool.zig:1680` escapes only backslash and double-quote and is NOT sufficient; do not
reuse it.

For `redactOutput`, the docstring must state plainly that it is **best-effort substring
replacement** and that a value a tool transforms (base64-encoded, split, reversed) is **NOT**
caught. That is an accepted limitation, not a bug to fix here.

---

## Tests

This repo has **no `*_test.zig` files anywhere** — every Zig test is an inline `test "..."`
block inside the implementation file. **Write the failing test first, then implement.**

Required cases:
- `{"command":"curl -H 'Auth: {{SECRETS:GH}}'"}` with GH=abc → the string leaf becomes
  `curl -H 'Auth: abc'`, and the result RE-PARSES as valid JSON
- a value containing a double-quote, a newline, and a NUL byte still yields parseable JSON
- a value containing a backslash does not produce an invalid escape sequence
- `{{SECRETS:NOPE}}` unresolvable → `error.UnknownSecretName`, NOT an empty substitution
- a substituted value that itself contains `{{SECRETS:GH}}` is NOT re-scanned (no recursion)
- `redactOutput` replaces the value with the placeholder
- `redactOutput` returns the input unchanged when the value is absent
- `redactOutput` handles multiple distinct values
- a placeholder in a NON-string leaf (a JSON number) is untouched
- malformed `args_json` → `error.InvalidArguments`, and the bytes are not modified
- `args_json` with no placeholder returns a value semantically equal to the input

---

## Making your tests actually run

Nothing imports your module yet — Task 3 wires it in. The repo pattern for this is a
one-line `test_runner`-style shim that pulls the module into the test build. Read
`src/migrations/test_runner.zig` — it is exactly this pattern:

```zig
//! Test runner for the migrations module.
test {
    _ = @import("migration.zig");
}
```

Find the analogous shim/convention for `src/agentic_loop/` modules and add an equivalent
one-line `test { _ = @import("secrets_substitution.zig"); }` so your tests are compiled and
run. Look at how `workspace_scope.zig` and other agentic_loop modules get their tests executed.

**If you cannot find a clean existing convention, do NOT invent `build.zig` changes** — stop
and report that as a blocker instead, along with the evidence you gathered.

---

## GATE

```bash
cd /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930
zig build test
```

Must be green before you commit. A background warm build may be running; if you hit a cache
lock, wait and retry.

The other agent is concurrently adding Migration 101 + `secrets_store.zig`. If the build fails
in a file you did not create and the errors do NOT mention `secrets_substitution.zig`, it is
their in-progress work — retry after a pause; if still broken, report it rather than editing
their file.

If `zig build test` reveals **pre-existing** failures unrelated to this work, say so explicitly
and do not attempt to fix them.

Commit when green:

```
feat(secrets): JSON-safe placeholder substitution + output redaction
```

---

## HARD CONSTRAINTS

- **No `// NEW (plan: ...)` comments.** Explain WHY in one plain sentence, or not at all.
- No DB, no filesystem, no crypto in this module.
- Do not modify any file except your new module (+ a test shim if the repo convention genuinely
  requires one). If you conclude another file must change, **STOP and report** instead of editing.

## REPORT BACK

Files changed, exact commit sha, `zig build test` result, how you wired the tests into the
build, and any deviation from this brief with your reason.