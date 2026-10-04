# Unify `bash` + `pwsh` Into One `command` Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two LLM-facing shell tools (`bash`, `pwsh`) with one `command` tool that runs `pwsh` on Windows and `bash` on Linux/macOS, backend + frontend.

**Architecture:** Merge `bash.zig` + `pwsh.zig` into one `command.zig` (they are already thin wrappers over `shell.zig` — only argv prefix + description text differ) + one `tools_exec_command.zig` (merge of `tools_exec_bash/pwsh.zig`); OS dispatch is a single `argv-prefix` switch (`builtin.os.tag == .windows → pwsh -NoProfile -NonInteractive -Command`, else `bash -c`); old `bash.zig`/`pwsh.zig`/`tools_exec_bash.zig`/`tools_exec_pwsh.zig` become 5-line deprecated shims re-exporting the merged impl (removed next release); frontend `ShellTool.vue` + `toolOutputParser.ts` + both dispatchers gain a `command` case.

**Tech Stack:** Zig 0.16 (`std.process.spawn`, `builtin.os.tag`), `shell.zig` shared core, `UNIFIED_TOOL_REGISTRY` / `handle_tool.zig` dispatch, Vue 3 (`ShellTool.vue`, `ChatView.vue`, `SubAgentPeekPanel.vue`, `toolOutputParser.ts`), vitest + `zig build test` + python functional harness.

## Global Constraints

- No new input fields: `command` reuses the exact 8-field `ShellInput` wire (`command`, `cwd`, `mandatory_timeout` required; `max_output`, `stdin_data`, `background`, `max_lines`, `do_encoding` optional) — same lenient coercion in `tools_exec_bash_args.zig` (numeric-string + trailing `</field>` strip).
- No new envelope: inner 9-tag `result_to_xml` (`command/stdout/stderr/exit_code/truncated/timeout/stdout_lines/stderr_lines/is_self`) + outer `wrapToolOutput` (`<tool><name>command</name>...`) unchanged, only `tool_name` string changes.
- Windows binary must not require `bash` on PATH; Linux/macOS binary must not require `pwsh` on PATH (dispatch is compile-time per target, missing-binary error only fires for the active OS shell).
- Backward compat for one release: old `bash`/`pwsh` names still dispatch (deprecated prompt text points at `command`); frontend still renders old envelopes; removal is a separate follow-up task, not this plan.
- `DONT KILL PORT 8081` server; functional verification via isolated harness (`tests/functional/`), never live `curl` against 8081.
- Per-request arena: no `defer free` for `ctx.allocator` memory in new handler code.
- SSE contract untouched (no new event names).

## File Map (create / modify)

### Backend — new (2)

| File | Responsibility |
|---|---|
| `src/modules/agent/tools/command.zig` (NEW, merged) | `command_tool` (name `"command"`), `CommandInput/Output` aliases, both `COMMAND_BASH_PREFIX` + `COMMAND_PWSH_PREFIX` consts + OS switch, `execute_command`, `command_result_to_string`, merged `description` + `system_prompt`, inline tests (moved from bash/pwsh, not duplicated) |
| `src/ai_workflow/tui/agentic_loop/tools_exec_command.zig` (NEW, merged) | `execCommand` + `runWithContext` (merged body of `tools_exec_bash/pwsh.zig`, `tool_name="command"`) |

### Backend — modify (9)

| File | Change |
|---|---|
| `src/modules/agent/tools/shell.zig` | Add `defaultShellPrefix() / buildDefaultArgv()` helper (the one OS switch); keep `build_argv` as-is |
| `src/modules/agent/tools/schemas.zig` | Add `CommandInput/CommandOutput` aliases to `shell.*` |
| `src/modules/agent/tools/bash.zig` | Shrink to deprecated shim: `pub const bash_tool = command.command_tool with name override "bash"` + `execute_bash = command.execute_command` + deprecation banner; delete schema/prompt duplication (lives in `command.zig` now) |
| `src/modules/agent/tools/pwsh.zig` | Same shim pattern for `"pwsh"`; delete duplicated prefix/schema text |
| `src/ai_workflow/tui/agentic_loop/tools_exec_bash.zig` | Shrink to shim: `execBash` delegates to `execCommand` with `tool_name="bash"` for envelope compat |
| `src/ai_workflow/tui/agentic_loop/tools_exec_pwsh.zig` | Same shim for `"pwsh"` |
| `src/ai_workflow/tui/agentic_loop/tools.zig` | Add `pub const execCommand` re-export |
| `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` | Add `command_tool_mod` import + `equips()` entry + `UNIFIED_TOOL_REGISTRY()` entry `.{ .name = "command", .exec = tools.execCommand, ... }`; keep bash/pwsh entries (deprecated) |
| `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig` | `hasTool(filtered_tools, "bash")` GitPrompt gate → also fire on `"command"` (keep bash for compat): `if (hasTool(..., "bash") \|\| hasTool(..., "command"))` |
| `src/root.zig` | Add `pub const command_tool = @import("modules/agent/tools/command.zig")` |
| `src/modules/agent/tools/pwsh.zig` static-contract test (L248-325) | Add mirror contract for `command` (greps `tools_equipped.zig` for `.name = "command"`, `tools.execCommand`) |

### Frontend — modify (6)

| File | Change |
|---|---|
| `src/apps/desktop/src/components/tool_outputs/_shared/toolOutputParser.ts` | Add `parseCommand = parseBash` alias; `parseShell` switch gains `'command' → parseBash` |
| `src/apps/desktop/src/components/preview/ShellTool.vue` | Accept `toolName === 'command'`; pill renders `command`; parsing via `parseShell('command', ...)` |
| `src/apps/desktop/src/components/preview/Bash.vue` | Keep as-is (legacy wrapper); optionally add `Command.vue` wrapper or reuse `ShellTool` directly — prefer reuse, no new file |
| `src/apps/desktop/src/components/views/ChatView.vue` (L3099-3104) | Dispatcher condition gains `\|\| msg.tool_name === 'command'`; `:tool-name` normalizes `command → 'command'`, `run_command → 'bash'`, `pwsh → 'pwsh'` (compat) |
| `src/apps/desktop/src/components/pabrik/SubAgentPeekPanel.vue` (L304-308) | Same dispatcher change as ChatView |
| `src/apps/desktop/src/components/views/KanbanToolsPanel.vue` + `parseSpawnSubAgentArgs` valid-names + `unwrapToolOutput` | `RECOMMENDED_TOOLS` swaps `'bash' → 'command'` (keep pwsh out); valid tool-name list accepts `'command'` (keep bash/pwsh accepted for compat) |

### Docs / tests (3)

| File | Change |
|---|---|
| `docs/superpowers/plans/2026-09-04-unify-bash-pwsh-into-command.md` (this file) | Plan under review |
| `tests/functional/command_tool_test.py` (NEW) | Harness: `command` runs `echo` on current OS; unknown-name compat (`bash` still works); envelope has `<name>command</name>` |
| `PABRIK.md` | Changelog entry |

## Key Design Decisions (locked before implementation)

1. **Dispatch point = argv prefix, not two code paths.** `command.zig` does `const prefix = if (builtin.os.tag == .windows) PWSH_ARGV_PREFIX else BASH_ARGV_PREFIX; return shell.execute_shell(allocator, io, prefix, input);` — all timeout/kill/reader/background logic stays shared in `shell.zig`. Rationale: bash + pwsh already share 100% of `shell.zig`; a second branch would fork the kill semantics (pgid-KILL vs NtWait) for no gain.
2. **Compile-time `builtin.os.tag`, not runtime sniffing.** Each shipped binary targets one OS, so comptime is correct and keeps tests deterministic. No `uname`/`$OS` probing.
3. **Background mode stays `nohup`-shaped on POSIX, known-gap on Windows carried over.** `spawn_background` hardcodes `nohup … & echo $!` (`shell.zig:716-720`); pwsh `background=true` is already a documented TODO (`pwsh.zig:25-29`). `command` on Windows inherits that TODO — do NOT fix background in this plan (separate task).
4. **Deprecate-then-remove, not flag-day.** Registry keeps all three names for one release; `bash`/`pwsh` descriptions say "deprecated, use `command`". Frontend accepts all four strings (`command`, `bash`, `pwsh`, `run_command`). Removal (registry entries, wrappers, parser aliases) is a follow-up after LLM prompt migration is observed.
5. **Prompt text: one behavior block.** `command_tool_system_prompt` merges both: timeout + `| head -n` bounding + explicit `cwd` + `background` + per-OS shell note ("On Windows this runs `pwsh -NoProfile -NonInteractive -Command`; on Linux/macOS `bash -c`. Write portable commands; use PowerShell idioms only when you know the target is Windows."). `bash`/`pwsh` system_prompts shrink to one-line deprecation pointers so `appendToolBehaviorSection` doesn't triple-teach the same rules.
6. **Frontend pill shows `command`, not the resolved shell.** The LLM and user both asked for "one tool named command" — resolving the pill to `bash`/`pwsh` per-OS would re-split the UX. `parseShell('command')` reuses the identical 9-tag envelope so no parser fork.

## Tasks (bite-sized: test → implement → verify → commit)

### Phase A — backend `command` tool def

- [ ] **A1. Failing test: `command_tool` schema shape.** In new `src/modules/agent/tools/command.zig` inline tests: assert `.function.name == "command"`, `.required` contains exactly `command/cwd/mandatory_timeout`, `execute_command` symbol exists. Run `zig build test` → fails (file missing).
- [ ] **A2. Implement `command.zig` (merge, not copy).** Move (not duplicate) the shared structure from `bash.zig:42-122` + `pwsh.zig:42-122` into `command.zig`; keep both prefix consts in the one file; `execute_command` dispatches on `builtin.os.tag`; merged `description` + `system_prompt` per Decision 5. Wire `schemas.zig` aliases + `root.zig` export. Then shrink `bash.zig`/`pwsh.zig` to shims (re-export + name override only).
- [ ] **A3. Verify A2.** `zig build test --summary all` passes; `command` tests green; commit.

### Phase B — exec wrapper + registry + prompt gate

- [ ] **B1. Failing test: registry contains `command`.** Extend static-contract style test (mirror `pwsh.zig:248-325`): grep `tools_equipped.zig` for `.name = "command"` + `tools.execCommand` + `command_tool_mod.command_tool`. Run → fails.
- [ ] **B2. Implement `tools_exec_command.zig` (merge, not copy).** Move (not duplicate) the shared body from `tools_exec_bash/pwsh.zig:26-93` into `tools_exec_command.zig` (`tool_name="command"`); then shrink both old files to shims delegating to `execCommand`; re-export in `tools.zig`; add import + 2 lines in `tools_equipped.zig` (keep bash/pwsh); update `prompts_build_messages_for_agent_prompt.zig:111` gate to `bash || command`.
- [ ] **B3. Shrink bash/pwsh to shims.** `bash.zig`/`pwsh.zig` keep only name override + `execute_* = command.execute_command` + one-line deprecation pointer; `tools_exec_bash/pwsh.zig` keep only delegation. No duplicated schema/prompt text.
- [ ] **B4. Verify B.** `zig build test --summary all` green; `zig build pabrik-desktop` links; commit.

### Phase C — frontend `command` rendering

- [ ] **C1. Failing tests: parser + dispatcher.** `toolOutputParser.spec.ts`: `parseShell('command', envelope)` equals `parseBash`; new spec for `ShellTool` pill `command` (or extend existing parser spec if no component spec exists — there is currently no `ShellTool.spec.ts`). Run `pnpm test:unit` → fails.
- [ ] **C2. Implement parser + dispatchers.** `toolOutputParser.ts`: add `parseCommand` alias + `'command'` switch arm; `ShellTool.vue`: accept `'command'`; `ChatView.vue` + `SubAgentPeekPanel.vue`: add `msg.tool_name === 'command'` to `v-else-if`, pass `:tool-name="msg.tool_name"` through (or normalized triple); `KanbanToolsPanel.vue` RECOMMENDED_TOOLS + `parseSpawnSubAgentArgs` valid-names accept `command`.
- [ ] **C3. Verify C.** `pnpm test:unit` green; `vue-tsc --noEmit` clean; commit.

### Phase D — wire verification + docs

- [ ] **D1. Functional test (harness, isolated HOME, non-8081 port).** New `tests/functional/command_tool_test.py`: boot fresh binary, run `command` with `echo hello` (portable across shells), assert `<name>command</name>` + `exit_code 0` + stdout contains hello; second case: old `bash` name still dispatches (compat) on Linux. Run `PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 python3 -m pytest tests/functional/command_tool_test.py -v`.
- [ ] **D2. Full suites + changelog.** `zig build test --summary all` + `pnpm test:unit` green; add `PABRIK.md` entry; commit.
- [ ] **D3. Human review gate.** Present this plan; stay in `in_review_planning`; do NOT implement until approved. Follow-up (out of scope): remove `bash`/`pwsh` registry entries + wrappers + parser aliases after one release.

## Pitfalls

- **Don't fork `shell.zig` kill semantics.** The POSIX pgid-KILL (`kill(-pgid)`) vs Windows `NtWaitForSingleObject` paths are subtle (`shell.zig:148-263,623-641`); the OS switch belongs ONLY in the argv prefix. Any edit to timeout/kill/readers must stay shared.
- **Don't break the `hasTool("bash")` GitPrompt gate.** `prompts_build_messages_for_agent_prompt.zig:111` fires only on `"bash"` today; a pure rename without the `|| "command"` edit silently drops the Git prompt section for `command`-only sessions.
- **Don't forget the three `wrapToolOutput` call sites per shell.** `tool_name` string feeds the frontend `ToolCard` path (`tools_exec_pwsh.zig:88-90` comment); a copy-paste leaving `"bash"` in `tools_exec_command.zig` renders the wrong pill.
- **Don't assume `pwsh` exists on Linux CI or `bash` on Windows.** Missing binary = `FileNotFound` → `command failed: FileNotFound` envelope, not a crash. Functional test must use `echo` (both shells) not `ls`/`Get-ChildItem`.
- **Don't add a `Command.vue` file.** Reuse `ShellTool` directly like the current dispatcher does; `Bash.vue` is already a dead-import legacy wrapper (`ChatView.vue:36` eslint-disabled). A fourth component triples the dispatcher matrix.
- **macOS `bash` is 3.2** (`bash.zig:143-144`) — keep `command` examples to POSIX-basics (`timeout`, `head -n`) so the same LLM output works on macOS + Linux.

## Verification

- [ ] Plan saved to `docs/superpowers/plans/2026-09-04-unify-bash-pwsh-into-command.md`
- [ ] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [ ] Each task has bite-sized steps (test → implement → verify → commit)
- [ ] User has reviewed the plan before execution begins
