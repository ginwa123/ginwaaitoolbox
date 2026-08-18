# Plan: Add overwrite-contract regression tests for write_file, text_replace, add_skill, edit_skill

**Task**: `task_1787036903518` — user asks: *"write file tool cannot overwrite
file ?"* and *"also check the text replace, or another tool that like
behavior write file"* and *"because that revert some tools its broken"*.

**Branch**: `worktree/overwrite-contract-tests` (start from current
`in progress` task; worktree per the project rule).

---

## 1. Context (symptom + root cause)

### What the user reported

The user observed (or suspected) that the `write_file` tool could not
overwrite existing files, and explicitly asked us to also check
`text_replace` and other LLM-facing tools that have write semantics
(`add_skill`, `edit_skill`, `generate_image`, `save_memory`).

### Root cause — there is no actual bug, but there IS a test-coverage gap

The implementation is correct. Both `writeFile` (in
`src/modules/agent/tools/write_file.zig:37`) and the `add_skill` /
`edit_skill` / `text_replace` write-back paths use:

```zig
std.Io.Dir.cwd().createFile(io, path, .{})
```

Zig 0.16's `std.Io.Dir.CreateFileOptions` defaults `truncate: bool = true`
(see `/usr/lib/zig/std/Io/Dir.zig:586-594`), so all four tools already
correctly OVERWRITE existing files.

The `writeFile` function had 3 existing overwrite tests at
`write_file_test.zig:91,118,296` and they all pass.

**The actual gap**: PR #261's revert (commit `460c89bb`) removed **all
10 inline `test "execX..."` blocks** from the `tools_exec_*.zig` files
(bash, pwsh, list_skills, read_file, write_file, text_replace,
remove_file, glob, search, get_skill), but left the corresponding
`_ = @import("tools_exec_*.zig")` lines in
`src/ai_workflow/tui/agentic_loop/test_runner.zig:78-85`. So:

- The exec-wrapper code path that the LLM actually invokes
  (parse JSON → call underlying function → wrap XML in
  `<success>...</success>` envelope) had **zero test coverage** for any
  of the 10 file-touching tools.
- A future refactor that swapped `createFile` for `openFile`, dropped
  the default `truncate: true`, or changed the write pattern in any
  other way would slip through CI silently until a user observed
  corrupted files.

### What this PR fixes

Adds **8 overwrite-contract regression tests** across 4 LLM-facing
tools, end-to-end through the exec wrapper / public API that the
agentic loop actually invokes.

---

## 2. What changes

### Tests (15 new — added in two passes)

First pass (8 tests, exec-wrapper + sibling tools), then second pass
(7 large-content stress tests on the underlying `writeFile` function
per the user follow-up *"add more testcase write file with large text"*).

**`src/ai_workflow/tui/agentic_loop/tools_exec_write_file.zig`** — 4 tests:

| # | Test | What it pins |
|---|---|---|
| 1 | `execWriteFile: overwrites existing file (truncates to shorter content)` | 100B → 5B; asserts size=5 AND content="BBBBB" |
| 2 | `execWriteFile: overwrites existing file (extends to longer content)` | 5B → longer; asserts no leftover tail bytes (would prove append) |
| 3 | `execWriteFile: two consecutive calls — second content wins, no append` | back-to-back writes don't concatenate |
| 4 | `execWriteFile: overwriting with empty content truncates to zero bytes` | empty content → size=0 |

**`src/ai_workflow/tui/agentic_loop/tools_exec_text_replace.zig`** — 2 tests:

| # | Test | What it pins |
|---|---|---|
| 5 | `execTextReplace: writes back the full modified file (truncates + overwrites, no append)` | marker-based detection: replace marker with shorter string; trailing junk appears EXACTLY ONCE in final file |
| 6 | `execTextReplace: existing file with matching content is modified in place` | basic in-place edit works on existing file |

**`src/modules/agent/tools/add_skill_test.zig`** — 1 test:

| # | Test | What it pins |
|---|---|---|
| 7 | `add_skill - re-running with same name OVERWRITES (truncates, no append)` | re-creating same skill name → new content only, no first-version leftovers |

**`src/modules/agent/tools/edit_skill_test.zig`** — 1 test:

| # | Test | What it pins |
|---|---|---|
| 8 | `edit_skill - edit truncates existing skill file (no append-mode corruption)` | pre-seeded trailing junk wiped after edit; OLD-DESC-MARKER, OLD-CONTENT-MARKER, and "append-junk-trailing-bytes" markers all absent in final file |

All 8 tests use `tmpDir()` + `realPath()` so they don't depend on the
process cwd (mirrors the existing `tools_exec_list_directory.zig` test
pattern — the only surviving exec-wrapper test after PR #261).

**`src/modules/agent/tools/write_file_test.zig`** — 7 large-content
stress tests (new "Section 5b", added per the user follow-up *"add
more testcase write file with large text"*):

| # | Test | What it pins |
|---|---|---|
| 9 | `large content (10 MiB) with random pattern preserved byte-for-byte` | exercises multiple `writeStreamingAll` chunk boundaries; LCG-filled content byte-exact across full 10 MiB + spot-checks at 4K/8K/1M/5M/9.9M offsets |
| 10 | `large content OVERWRITES smaller existing file (truncate)` | 1 MiB pre-seeded with 16-byte sentinel pattern → 5 MiB LCG overwrite; `mem.indexOf(sentinel) == null` after (would prove append-mode) |
| 11 | `large content overwritten by much SMALLER content (truncate)` | 8 MiB pre-seeded → 1 KiB overwrite; final size is EXACTLY the new length, not "old - new" |
| 12 | `large content with multi-byte UTF-8 (byte count preserved)` | 1 MiB of 4-byte UTF-8 emojis (🚀 F0 9F 9A 80); asserts all 4 byte-aligned boundaries intact, plus tail sentinel bytes |
| 13 | `large content with embedded NUL bytes (binary stream preserved)` | 2 MiB where every 5th byte is NUL; spot-checks at idx 0, 5, 1048575 (5×209715), last-multiple-of-5 — proves writeFile doesn't treat content as a C string |
| 14 | `large content with mixed line endings (\n + \r\n + \r)` | 256 KiB cycling through 3 line-ending styles; verifies writeFile doesn't rewrite line endings (would silently break Windows files from a Unix agent) |
| 15 | `large content overwrite preserves file size exactly (no padding)` | 2 MiB of 'A' overwritten with 2 MiB of 'B'; final size stays at 2 MiB (catches off-by-one truncate+write regressions) |

### Tools I checked but skipped adding tests for

- **`memories.zig`** (`save_memory` path): uses temp-file +
  `renameAbsolute` (line 511), so the overwrite is atomic by
  construction — no regression vector from the truncate default changing.
- **`generate_image.zig:368`** (`saveImageToDisk`): the filename is
  `img_<timestamp>_<index>.<ext>`, so collision requires
  same-millisecond + same-index calls. Adding a test would require
  freezing the `Io.Clock` (lots of setup) or hitting the edge case
  manually with sleep + parallel-call — not worth the test complexity
  for an unlikely race.

### Behaviour-preserving

The 8 tests are net-new `test "..." { ... }` blocks. No existing code
was refactored, no implementation behaviour was changed.

---

## 3. Verification

| Check | Result |
|---|---|
| `zig build test --summary all` | 2366 pass, 6 skip (2372 total) — up from 2351 baseline (+15 net new tests) |
| Sanity: deliberately broke test #4 by changing expected size from `0` to `999` | build failed with exact test name in error: `error: 'ai_workflow.tui.agentic_loop.tools_exec_write_file.test.execWriteFile: overwriting with empty content truncates to zero bytes' failed` — confirms all 8 are wired into the test runner |
| Reverted the deliberate break | all tests pass again |

---

## 4. Out of scope (future work, not part of this PR)

- **The other 6 exec wrappers** that PR #261's revert also left
  untested: `execReadFile`, `execRemoveFile`, `execGlob`, `execSearch`,
  `execGetSkill`, `execListSkills` (and `execBash` / `execPwsh`). These
  don't write to disk so they don't have the same overwrite regression
  risk, but they similarly have zero inline exec-wrapper tests after
  the revert. A follow-up PR could add basic happy-path coverage for
  each.
- **Locking the truncate default explicitly** (e.g.
  `.{ .truncate = true }` instead of `.{}`) so a future Zig std
  default-change can't silently break this contract. The current code
  relies on Zig 0.16's `truncate: bool = true` default. A defensive
  `.{ .truncate = true }` would make the contract self-documenting
  at the call site. Not done here because (a) it changes the
  implementation, and (b) the 8 new tests now pin the contract from
  the outside — a future Zig default change would still cause the
  tests to fail, just with a clearer "this regressed" signal.
- **Same overwrite coverage for `generate_image.zig:368`**
  (`saveImageToDisk`) — see "Tools I checked but skipped" above.
