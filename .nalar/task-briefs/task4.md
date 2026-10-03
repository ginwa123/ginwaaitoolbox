# TASK 4 BRIEF — `list_secrets` tool, registry wiring, prompt rule

WORK DIRECTLY IN THIS EXISTING WORKTREE — do NOT call `set_git_worktree`, do NOT create a
new worktree, do NOT touch `/home/ginwa/ginwaaitoolbox`:

    /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930

`cd` there for every command. All paths below are relative to that directory.

Repo: **nalar**, Zig 0.16. Tasks 1–3 are committed and green:
- `secrets_store.zig` — `listSecretNames` (names only), `loadSecretValues`
- `secrets_substitution.zig` — pure substitute/redact
- `handle_tool.zig` — substitution wired at both dispatch paths, redaction before persist

Read those three before you start. Do NOT modify them. Do NOT touch migrations,
`http_handlers/`, the frontend, or the existing tools in `src/modules/agent/tools/`.

Plan: `docs/superpowers/plans/2026-10-02-workspace-secrets.md` (rev 2) — `### Task 4`,
Design Decisions 6 and 7.

---

## What you are building

An agent tool `list_secrets` (no arguments) that returns the **names** of the secrets in the
calling session's workspace — and **never a value**. Plus the registry wiring and the prompt
rule that teaches the model the `{{SECRETS:NAME}}` syntax.

---

## STEP 1 — the tool schema

Create `src/modules/agent/tools/list_secrets.zig`, following the shape of the sibling
single-file tool modules in that directory (read `list_sub_agent.zig` and
`read_workspace_session.zig` for the convention: module docstring, the `AgentTool` const,
schema JSON).

**No parameters at all.** And explicitly: the schema must carry **no `workspace_id` field**.
That is a security property, not an omission — see STEP 3.

---

## STEP 2 — the exec adapter

Create `src/agentic_loop/tools_exec_list_secrets.zig`, following the sibling
`tools_exec_*.zig` convention (read `tools_exec_skills.zig` for the shape).

Signature: `pub fn execListSecrets(ctx: ToolExecContext, tc: agent.ToolCall) !tools.ToolExecResult`

Body:
1. Resolve the workspace **server-side** from `ctx.session_id`:
   `workspace_scope.resolveWorkspaceId(allocator, ctx.db, ctx.session_id)`.
   - `null` → return an **empty** list (fail closed; never fall back to "all workspaces").
2. `secrets_store.listSecretNames(allocator, ctx.db, workspace_id)` — this SELECTs `name`
   only, so you cannot leak a value even by accident.
3. Build the result via `wrapToolOutput(ctx.allocator, "list_secrets", tc.function.arguments,
   true, null, <payload>)`, returning `ToolExecResult{ .output = ..., .output_allocated = true }`.

**Shape the payload so the model can act on it.** For each entry give the name plus
`updated_at` — enough to pick a key and to tell two rotations of one key apart, and nothing
else. The stored value is never in this payload, and `listSecretNames` never returns it.

---

## STEP 3 — registry + `ToolExecContext` re-export

1. Re-export in `src/agentic_loop/tools.zig` alongside the other `execXxx` aliases —
   add `pub const execListSecrets = @import("tools_exec_list_secrets.zig").execListSecrets;`
   near the others (that file is a barrel of exactly these).
2. Register in `src/agentic_loop/tools_equipped.zig` inside `UNIFIED_TOOL_REGISTRY()`.
   Follow the surrounding entries exactly:
   ```zig
   .{ .name = "list_secrets", .exec = tools.execListSecrets, .tool_def = list_secrets_mod.list_secrets_tool },
   ```
   Add the import alias in the same style as its siblings (`list_secrets_mod = nalarcore.…` —
   read how `list_sub_agent_mod` is declared and match it).
3. Add `list_secrets_tool.function.name` to `DEFAULT_AGENT_TOOLS` (that list is at
   `tools_equipped.zig:343`).

---

## STEP 4 — the allowlist bypass (do not skip this)

`DEFAULT_AGENT_TOOLS` only seeds **agents created from now on**. Existing agents have
persisted `agent_tools` / `agent_kanban_tools` rows that predate this tool, so without the
next step the tool would be invisible to every agent already in the database.

In `filterAndMergeTools` (`src/agentic_loop/workflow.zig`, `pub fn filterAndMergeTools` —
read the whole function and its comment block first), append `list_secrets` as a
**server-side injection that bypasses the `allowed_tools` allowlist**, exactly as the
existing MCP / progressive-tool and `skill_evals` injections do. Read the comment at the
`skill_evals` parameter in that same function — it states the precedent and the reasoning;
follow it.

It must still respect `is_sub_agent`.

**Why bypass rather than honour the allowlist:** the `Migration099` lesson — a tool only new
agents have is a tool no existing agent ever sees, and the discovery step would be dead on
arrival for the users this feature is for.

---

## STEP 5 — the prompt rule

Add `pub const SecretsToolRule` to `src/modules/agent/prompts/core.zig`, following
`ReadWorkspaceSessionToolRule` / `SkillsToolRule` there (same multi-line `\\` style, same
tone: direct, second person, no hedging).

It must convey:

1. The syntax `{{SECRETS:NAME}}` and that it works in **any** tool parameter.
2. Names are discovered by calling `list_secrets` — nothing is pre-listed in the prompt.
   (This matches a convention the repo states twice: catalogues are discovered by tool call,
   never inlined.)
3. An unknown name is a hard error naming the key, so call `list_secrets` rather than
   guessing.
4. **Explicitly: never echo, print, log, or write a secret's value** into a file, a commit
   message, a command that captures output, or your own message back to the user. A model
   told it can use a credential will happily `echo` it.

Then append it in `src/agentic_loop/prompts_build_messages_for_agent_prompt.zig`, next to
the other unconditional tool rules (`ProgressiveToolRule`, `SkillsToolRule`, … — around
line 121).

**Gate it on `hasTool(filtered_tools, "list_secrets")`** so an agent without the tool is
never told about a capability it lacks. The rules at 121+ are currently unconditional;
explain in a comment why this one differs, and make sure `hasTool` is in scope there (it is
used for `command` and `update_plan` earlier in the same function).

---

## STEP 6 — tests (inline, in the same files)

This repo has NO `*_test.zig` files; all Zig tests are inline `test "..."` blocks.

1. `execListSecrets` with a context whose session resolves to workspace A returns only
   workspace A's names.
2. The result string contains **no value substring** — seed a secret with a recognisable
   value and assert the payload does not contain it.
3. The tool's **schema JSON contains no `value` key** and no `workspace_id` key.
4. A session that resolves to **no** workspace returns an empty list (fail closed, never
   every workspace).
5. `filterAndMergeTools` appends `list_secrets` even when `allowed_tools` is a restrictive
   CSV that omits it.
6. The appended schema has **no `workspace_id` field** — so `ignore_unknown_fields` parsing
   cannot smuggle a foreign workspace id past the guard. Assert on the schema string.
7. Static contract: the prompt rule text is actually appended — a source-grep test in the
   spirit of the ones already in `workflow.zig` (which read their own source via
   `std.Io.Dir.cwd().readFileAlloc`).

**TDD: failing test first, watch it fail, then implement.**

Note for test 1/4: `ToolExecContext` is at `src/agentic_loop/tools.zig:92-143` and has **no
`workspace_id`** — workspace comes from `ctx.session_id`, which is why you must seed a
session row that `resolveWorkspaceId` can follow. Look at how
`src/agentic_loop/workspace_scope.zig`'s own inline tests build their in-memory fixture;
mirror that.

---

## GATE

```bash
cd /home/ginwa/.config/nalar/.worktrees/implement-new-features-name-secrets-1790968240930
zig build test --summary all
```

Must report `Build Summary: 8/8 steps succeeded` and exit 0.

**Two gotchas that cost time last time:**
- The run prints a spurious `failed command: .../test --listen=-` line immediately BEFORE the
  success summary. **Not a failure.** Trust the Build Summary and the exit code.
- Cold build ≈ 10+ minutes. Do not run two `zig build test` invocations concurrently in this
  tree — they contend on `.zig-cache` and produce a genuine spurious failure.

Commit when green:

```
feat(secrets): list_secrets tool + prompt rule
```

---

## HARD CONSTRAINTS

- **No `// NEW (plan: ...)` comments.** Explain WHY in one plain sentence, or not at all.
- **No `user_id`** anywhere. Access is workspace membership via `workspace_members`,
  enforced by `auth_common.canSeeWorkspace`, resolved server-side from `ctx.session_id`.
- **`list_secrets` must never return, log, or embed a secret value.** Not masked, not
  hinted, not last-4. Names only.
- Do NOT modify `secrets_store.zig`, `secrets_substitution.zig`, or `handle_tool.zig`. If you
  believe one must change, STOP and report.
- If you conclude any other file must change beyond the ones listed in Steps 3–5, STOP and
  report before editing it.

## REPORT BACK

Files changed, exact commit sha, the `Build Summary` line, how you wired the allowlist
bypass, how the prompt rule is gated, and any deviation with its reason.