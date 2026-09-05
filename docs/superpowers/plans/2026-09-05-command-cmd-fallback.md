# command: cmd.exe fallback when pwsh missing (2026-09-05)

## Goal

Windows boxes without `pwsh` on PATH can still run the unified `command` tool via automatic `cmd.exe /c` fallback.

## Architecture

`execute_command` tries `pwsh` first; on `error.FileNotFound` it retries once with
`COMMAND_CMD_PREFIX` (`cmd.exe /c`) and appends `CMD_FALLBACK_NOTE` to stderr.
Foreground-only in Phase 1 — `background=true` on a pwsh-less box fails instead of detaching.

## Tech Stack

Zig 0.16 `std.process.spawn` for the `cmd_available` probe; `shell.zig` shared core
(`execute_shell` + `is_cmd_shell` gate) so bash/pwsh/cmd share one timeout/output path.

## File Map

- EDIT `src/modules/agent/tools/command.zig` — `COMMAND_CMD_PREFIX`, `CMD_FALLBACK_NOTE`,
  FileNotFound retry, `cmd_available` probe, prompt carve-outs, 3 tests.
- EDIT `src/modules/agent/tools/shell.zig` — `is_cmd_shell` gate (skips `do_encoding`
  single-to-double-quote rewrite under cmd).
- UNCHANGED `tools_exec_command.zig` — exec wrapper passes `CommandInput` straight through;
  shell selection lives in `execute_command`, nothing to rewire.
- No frontend, no migration, no config schema change.

## Design Decisions (review-approved)

1. **Try/catch over pre-probe** — attempt pwsh, catch `FileNotFound`, retry cmd. No TOCTOU
   race, no extra spawn on the happy path.
2. **`/c` prefix** — `cmd.exe /c <command>` mirrors `bash -c` / `pwsh -Command` shape.
3. **Foreground-only Phase 1** — background detach under cmd deferred; fails loudly instead.
4. **No new input field** — no `shell:` selector; dispatch stays automatic per OS.
5. **Stderr note** — `CMD_FALLBACK_NOTE` tells the LLM which shell ran so it adapts syntax.

## Tasks

- [x] T1 — RED tests: prefix-shape, `cmd_available` no-crash, FileNotFound-retry static-contract grep.
- [x] T2 — impl: retry + note + `is_cmd_shell` gate + prompt docs (commit `2ed0aba6`).
- [x] T3 — reviewer nits: Rules-block carve-out pointer; probe argv `echo` → `exit 0` (output-free).
- [x] T4 — verify: `zig build test` 0 failures, functional `command_tool_test.py` 5/5, desktop 21/21.

## Pitfalls

- **`timeout N` collision** — cmd has its own `timeout` builtin (waits N seconds); under the
  fallback the LLM must NOT prefix `timeout N`, `mandatory_timeout` is the enforcer.
- **Single-quote encoding** — `do_encoding` rewrites `"`→`'` for URLs; literal under cmd, so
  the `is_cmd_shell` gate skips it (double-quotes required).
- **Self-kill tuning** — the cancel/self-kill snippet is bash-tuned; cmd needs `taskkill`.
- **No `shell` field** — callers cannot force cmd; pwsh-less detection is automatic only.
- **Background gap** — `background=true` without pwsh errors; Phase 2 may add `start /b`.

## Verification

- `zig build test --summary all`: 3078/3084 pass (6 skip, 0 fail; pre-nit baseline 3076/3082).
- `zig build nalar-desktop --summary all`: 21/21 steps OK.
- Functional `tests/functional/command_tool_test.py`: 5/5 pass (POSIX path untouched).
- Independent review: APPROVED with 3 optional nits (2 code nits applied, 3rd was this plan doc).
