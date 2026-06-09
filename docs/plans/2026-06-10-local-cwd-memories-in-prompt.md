# Local CWD Memories in Agent Prompt

**Status:** Draft (brainstorming done 2026-06-10)
**Owner:** Backend tools (`src/modules/agent/`)

## Goal

Extend the agent's system prompt to **auto-inject memories from
`<cwd>/.nalar/memories/*.md`** in addition to the existing global
`~/.config/nalar/memories/*.md`. Today, only the global folder is loaded
(`loadGlobalKnowledge` in `src/modules/agent/prompts.zig:207`). Project-specific
memories stored alongside the code (mirroring how `.nalar/skills/` works for
skills) are invisible to the agent unless the user manually `read_file`s them.

After this change, an agent in `/home/u/proj-x` sees **two** memory sections
in its system prompt:

```markdown
## Local Knowledge

The following markdown files are this project's local memory, auto-loaded
from `<cwd>/.nalar/memories/`. Use `read_file` to load a specific memory on
demand (the auto-injection includes the full content of every `.md` file
found).

### <title> (`<filename>`)

<full file content>
…

## Global Knowledge
… (existing, unchanged) …
```

## Decisions locked during brainstorming

1. **Local path convention:** `<cwd>/.nalar/memories/` (mirrors
   `LOCAL_SKILLS_DIR = ".nalar/skills"` in `tools/skills.zig:11`).
2. **Section header:** `## Local Knowledge` — pairs visually with the existing
   `## Global Knowledge` (`prompts.zig:412`). The two are **separate**
   sections, not sub-headings of a single `## Knowledge` block. Reason:
   minimal disruption to the existing `## Global Knowledge` test assertions
   (`prompts_test.zig:135, 202, 262, 505`).
3. **Position in prompt:** Inserted **before** `## Global Knowledge`, right
   after the project memory (`memoryMd` / `NALAR.md` / `CLAUDE.md`) block. The
   rationale: project-specific context first (NALAR.md → `.nalar/memories/`),
   then cross-project context (`~/.config/nalar/memories/`). This matches the
   "most specific first" ordering already in use.
4. **Sub-agent parity:** `build_sub_agent_prompt` also gets the new section.
   Sub-agents receive `cwd` already (`prompts.zig:257`), and the global
   knowledge section is also rendered for them (`prompts.zig:302`), so the
   parity is natural.
5. **No static `LocalMemorySystem` prompt section.** Mirroring how local
   skills are handled — there is no `## Local Skills System` static block;
   the dynamic `## Available Skills` section just lists local entries inline.
   The dynamic `## Local Knowledge` section's preamble paragraph will tell
   the model about the local folder (and how to read/write/refresh).
6. **`list_memory` tool is out of scope.** It is intentionally parameter-less
   today (`list_memory.zig:35`) and only lists global memories. A follow-up
   plan can add a `cwd` parameter and emit `<global_memories>` /
   `<local_memories>` tags. Keeping it out of this plan means no
   `tool_registry.zig` changes and no model-facing schema churn.
7. **No new cap on local memory size.** Pattern matches global: every `.md`
   file is read in full. The de facto limit is the LLM's context window.

## Open decisions (resolve during implementation)

- **Empty/missing local dir:** silent skip (no `## Local Knowledge` header
  emitted). Same as global behaviour (`prompts.zig:411`).
- **Local path resolution when `cwd` is empty:** skip the section. Mirrors
  the existing "no cwd → no available skills" behaviour
  (`prompts.zig:531-533`).
- **Local path resolution when `cwd` is relative:** trust the caller.
  `buildMessages` already runs `realPathFileAlloc` on the cwd before calling
  `build_agent_prompt` (`build_messages_for_agent_prompt.zig:524-528`).

## Data flow

```
buildMessages(cwd, …) in build_messages_for_agent_prompt.zig
        │  (cwd is already absolute here)
        ▼
prompt.build_agent_prompt(allocator, io, cwd, …, environment)
        │
        ├─► appendSection loop  (static PROMPT_SECTIONS — unchanged)
        │
        ├─► usedSkills                  (existing)
        ├─► memoryMd (NALAR.md)         (existing)
        │
        ├─► loadLocalKnowledge(allocator, io, cwd)         ◄── NEW
        │       │
        │       ├─ memories.get_local_memories_path_for_dir(allocator, cwd)
        │       │       → "<cwd>/.nalar/memories"
        │       │
        │       ├─ memories.listMemoriesInDir(allocator, io, dir)   ◄── NEW
        │       │       → []MemoryInfo  (same struct as global)
        │       │
        │       └─ readFileAlloc each → format as
        │          "### <title> (<filename>)\n\n<content>\n\n"
        │
        ├─► appendSkillsListing  (existing)
        ├─► loadGlobalKnowledge  (existing — no change)
        ├─► appendToolListing    (existing)
        └─► (rest of dynamic blocks — unchanged)
```

Same shape flows into `build_sub_agent_prompt` with the same new helper
call inserted at the right point.

## File-by-file changes

### 1. `src/modules/agent/tools/memories.zig` — add local helpers

Add two new free functions and one new directory-scoped list helper. **Do NOT
touch the existing `listAllMemories` or its signature** — that function is
called by `list_memory` and `http_handlers/memories_list.zig:28`, both of
which want *global-only* output. New functions are additive.

```zig
/// Subdirectory name under the per-project local config folder.
/// Mirrors LOCAL_SKILLS_DIR = ".nalar/skills" in tools/skills.zig:11.
pub const LOCAL_MEMORIES_DIR = ".nalar/memories";

/// Get the local memories directory path for a specific cwd.
/// Returns allocated `<cwd>/.nalar/memories` (no realpath resolution —
/// caller is responsible for passing an absolute cwd).
/// Returns null only on alloc failure.
pub fn get_local_memories_path_for_dir(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) ?[]const u8 {
    if (cwd.len == 0) return null;
    return std.fs.path.join(allocator, &[_][]const u8{
        cwd,
        LOCAL_MEMORIES_DIR,
    }) catch null;
}

/// List all .md memory files in a specific directory (no XDG resolution).
///
/// Returns a slice of `MemoryInfo` with all string fields allocator-owned
/// (same contract as `listAllMemories`). Returns an empty slice when the
/// directory does not exist (no error) — this is the expected first-run
/// behaviour, identical to the global listAllMemories path.
///
/// Reuses the same title extraction (extractTitle, TITLE_SCAN_LIMIT).
/// Internal to this module; not part of the public tool surface.
pub fn listMemoriesInDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) []MemoryInfo {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return &.{};
    };
    defer std.Io.Dir.close(dir, io);

    var list: std.ArrayList(MemoryInfo) = .empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.name);
            allocator.free(item.title);
            allocator.free(item.path);
        }
        list.deinit(allocator);
    }

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        const full_path = std.fs.path.join(allocator, &[_][]const u8{
            dir_path,
            entry.name,
        }) catch continue;

        const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };
        defer std.Io.File.close(file, io);

        const stat = std.Io.File.stat(file, io) catch {
            allocator.free(full_path);
            continue;
        };

        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            full_path,
            allocator,
            std.Io.Limit.limited(std.math.maxInt(usize)),
        ) catch {
            allocator.free(full_path);
            continue;
        };
        defer allocator.free(content);

        const title = extractTitle(allocator, entry.name, content) catch {
            allocator.free(full_path);
            continue;
        };

        const name_copy = allocator.dupe(u8, entry.name) catch {
            allocator.free(title);
            allocator.free(full_path);
            continue;
        };

        list.append(allocator, .{
            .name = name_copy,
            .title = title,
            .path = full_path,
            .size = stat.size,
        }) catch {
            allocator.free(name_copy);
            allocator.free(title);
            allocator.free(full_path);
            continue;
        };
    }

    return list.toOwnedSlice(allocator) catch &.{};
}
```

The body of `listMemoriesInDir` is intentionally a copy of the inner loop
from `listAllMemories` (lines 100-170). Refactor is out of scope (the
existing function's `get_global_memories_path` call would have to be lifted
to a `?[]const u8` parameter and threaded through the call sites; that's a
bigger surgery than this plan warrants). The duplication is acceptable
because both call sites use `extractTitle` and the same struct fields.

**Memory ownership contract** is identical to `listAllMemories`: every
`MemoryInfo` returned by `listMemoriesInDir` must be freed via
`freeMemoriesList` (reused, not a new function).

### 2. `src/modules/agent/prompts.zig` — add `loadLocalKnowledge`

Add a new helper next to `loadGlobalKnowledge` (line 207). Same shape, same
return semantics (allocated string, "" when nothing to inject), same
all-errors-swallowed style. Reuses the `### <title> (\`<name>\`)` heading
format used by `loadGlobalKnowledge` so visual consistency is automatic.

```zig
/// Load the contents of all memory files in `<cwd>/.nalar/memories/`
/// and concatenate them as a single markdown blob. Mirrors
/// `loadGlobalKnowledge` exactly in shape and error handling.
///
/// Returns an empty string (allocated) when:
///   - `cwd` is empty
///   - `.nalar/memories/` does not exist
///   - no `.md` files exist
///
/// Per-file errors (open, read, title extraction) skip the file and
/// continue — never break the prompt.
fn loadLocalKnowledge(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) ![]u8 {
    if (cwd.len == 0) return allocator.dupe(u8, "");

    const dir_path = memories_mod.get_local_memories_path_for_dir(allocator, cwd)
        orelse return allocator.dupe(u8, "");
    defer allocator.free(dir_path);

    const list = memories_mod.listMemoriesInDir(allocator, io, dir_path);
    defer memories_mod.freeMemoriesList(allocator, list);

    if (list.len == 0) return allocator.dupe(u8, "");

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (list) |mem| {
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            mem.path,
            allocator,
            std.Io.Limit.limited(std.math.maxInt(usize)),
        ) catch continue;
        defer allocator.free(content);

        try result.appendSlice(allocator, "### ");
        try result.appendSlice(allocator, mem.title);
        try result.appendSlice(allocator, " (`");
        try result.appendSlice(allocator, mem.name);
        try result.appendSlice(allocator, "`)\n\n");
        try result.appendSlice(allocator, content);
        try result.appendSlice(allocator, "\n\n");
    }

    return result.toOwnedSlice(allocator);
}
```

### 3. `src/modules/agent/prompts.zig` — wire the new section into both builders

**In `build_agent_prompt` (line 360-473):** insert a new block immediately
after the existing `memoryMd` rendering (line 393) and **before**
`appendSkillsListing` (line 403):

```zig
    // Project memory (NALAR.md / CLAUDE.md from cwd).
    if (memoryMd.len > 0) {
        try appendSection(allocator, &result, memoryMd);
    }

    // Local Knowledge — auto-loaded from <cwd>/.nalar/memories/*.md.
    // Project-specific memories that ship with the codebase. Renders
    // before the global knowledge block so project context precedes
    // cross-project context.
    const local_knowledge = try loadLocalKnowledge(allocator, io, cwd);
    defer allocator.free(local_knowledge);
    if (local_knowledge.len > 0) {
        try result.appendSlice(allocator, "\n\n## Local Knowledge\n\n");
        try result.appendSlice(allocator,
            \\The following markdown files are this project's local memory,
            \\auto-loaded from `<cwd>/.nalar/memories/`. Use `read_file` to
            \\load a specific memory on demand. To update, use `write_file`
            \\or `text_replace`; to delete, use `remove_file`.
            \\
        );
        try result.appendSlice(allocator, local_knowledge);
    }

    // need to listing list skills globals and locals
    // … (unchanged: appendSkillsListing, loadGlobalKnowledge, …)
```

**In `build_sub_agent_prompt` (line 254-334):** insert a parallel block
right after the existing `## Global Knowledge` rendering (after line 317).
The sub-agent prompt keeps its simpler "Global Knowledge" position because
it doesn't have the multi-tier dynamic structure that the main agent has —
adding Local Knowledge at the end (after OS info / cwd) is fine for parity
but a placement after Global Knowledge is more semantically correct.
**Decision: place immediately after the global block** so the two
knowledge sections sit together (easier to compare, easier to test).

```zig
    // 6. Global Knowledge — auto-loaded from ~/.config/nalar/memories/*.md.
    //    (existing — unchanged)
    const knowledge = try loadGlobalKnowledge(allocator, io, environment);
    defer allocator.free(knowledge);
    if (knowledge.len > 0) { … }

    // 6.5. Local Knowledge — auto-loaded from <cwd>/.nalar/memories/*.md.
    //      Project-specific memories that ship with the codebase.
    const local_knowledge = try loadLocalKnowledge(allocator, io, cwd);
    defer allocator.free(local_knowledge);
    if (local_knowledge.len > 0) {
        try result.appendSlice(allocator, "\n\n## Local Knowledge\n\n");
        try result.appendSlice(allocator,
            \\The following markdown files are this project's local memory,
            \\auto-loaded from `<cwd>/.nalar/memories/`. Use `read_file` to
            \\load a specific memory on demand. To update, use `write_file`
            \\or `text_replace`; to delete, use `remove_file`.
            \\
        );
        try result.appendSlice(allocator, local_knowledge);
    }

    // 7. Working directory context
    //    (existing — unchanged)
```

### 4. `src/modules/agent/tools/memories.zig` — no public API change

The new functions are additions. The `MemoryInfo` struct, `listAllMemories`,
`freeMemoriesList`, `get_global_memories_path`, and `extractTitle` are
**unchanged**. This is important for the `list_memory` tool, the HTTP
handler at `src/ai_workflow/tui/http_handlers/memories_list.zig:28`, and
any external consumers that bind to those symbols.

## Test plan

New file: `src/modules/agent/tools/memories_test.zig`. Register in
`src/modules/agent/test_runner.zig` (if it doesn't exist as a separate file,
register in the main test runner per the project's "always register new
tests" rule).

### `listMemoriesInDir` unit tests (filesystem, isolated `tmp_home`-style dirs)

Pattern: mirror `list_memory_test.zig:99-226` exactly — create a temp dir,
drop `.md` files in it, call `listMemoriesInDir`, assert on the returned
slice. Clean up with `defer deleteTree`.

- Returns empty slice when dir does not exist
- Returns empty slice when dir exists but has no `.md` files
- Skips `.txt`, `.json`, subdirectories
- Lists two `.md` files in alphabetical order (or whatever order `dir.iterate`
  yields — assert *presence* of each filename + title, not order)
- Filename stem used as title when no H1
- First H1 used as title when present
- H1 in second line (after blank line) is found
- Free contract: `freeMemoriesList(allocator, slice)` does not leak/double-free

### `get_local_memories_path_for_dir` unit tests (pure)

- `get_local_memories_path_for_dir(alloc, "/tmp/proj")` → `"/tmp/proj/.nalar/memories"`
- `get_local_memories_path_for_dir(alloc, "")` → `null`
- Returned slice is allocator-owned; freeing it does not crash
- Allocator failure surfaces as `null` (not an error)

### `loadLocalKnowledge` + `build_agent_prompt` integration tests (extend `prompts_test.zig`)

Pattern: mirror the existing `build_agent_prompt loads memory files into
Global Knowledge section` test (`prompts_test.zig:88-140`). Each new test
sets up a temp cwd with `.nalar/memories/`, calls `build_agent_prompt` with
that cwd, and asserts on the rendered prompt.

- `## Local Knowledge` section appears when `<cwd>/.nalar/memories/*.md` is
  populated; both global and local sections can coexist in one prompt
- Section is **absent** when `cwd` is empty (i.e. caller passed `""`)
- Section is **absent** when `<cwd>/.nalar/memories/` does not exist
- Section is **absent** when the dir exists but has no `.md` files
- The full content of a single local `.md` is rendered (no truncation)
- Filename + H1 title appear in the section (e.g. `### My Project Rule`
  and the filename in backticks)
- The framing paragraph tells the model where the files came from
  (assert substring like `"auto-loaded from"` and `"<cwd>/.nalar/memories/"`)

### `build_sub_agent_prompt` integration test (extend `prompts_test.zig`)

- `## Local Knowledge` section appears for sub-agents when cwd is populated
- Section is absent when cwd is empty

### Regression guard

- The existing tests at `prompts_test.zig:88-140, 142-175, 177-203, 209-278`
  must still pass unchanged. They use a HOME-based global memories fixture
  and assert the global section is rendered; the new local code is additive
  and must not perturb them.

## Files touched

- `src/modules/agent/tools/memories.zig` — add `LOCAL_MEMORIES_DIR`,
  `get_local_memories_path_for_dir`, `listMemoriesInDir`
- `src/modules/agent/prompts.zig` — add `loadLocalKnowledge`; insert two new
  sections in `build_agent_prompt` and `build_sub_agent_prompt`
- `src/modules/agent/tools/memories_test.zig` — NEW (filesystem tests for
  the new helpers)
- `src/modules/agent/prompts_test.zig` — extend with local-knowledge cases
- `src/modules/agent/test_runner.zig` — register `memories_test.zig` (or
  whichever file owns the test imports in this project)

## Out of scope (deferred to a follow-up if needed)

- **`list_memory` tool update.** It still only lists global memories. To
  support local: add a `cwd` parameter to the schema, thread it through
  `tool_registry.zig` → `execute_list_memory`, and emit a new
  `<local_memories>` block in the XML output. Trivial extension of the
  pattern in this plan but a model-facing schema change, so left for a
  separate plan.
- **`read_memory` / `write_memory` / `delete_memory` tools.** The dynamic
  prompt tells the model to use `read_file` / `write_file` / `text_replace`
  / `remove_file` directly, which works today. Dedicated tools would be
  nicer UX but are not required.
- **Per-file or aggregate size caps.** Pattern matches global — full content
  injected. If a user dumps a 10MB markdown into `.nalar/memories/`, the
  context window will overflow. We trust the user to keep memories small,
  same as for global.
- **Walking parent directories for `.nalar/memories/`.** If the agent is
  started from `/home/u/proj-x/src/foo`, do we look in
  `/home/u/proj-x/src/foo/.nalar/memories/` only, or also walk up to find
  `/home/u/proj-x/.nalar/memories/`? v1 looks only at the literal cwd. The
  parent-walk is a follow-up.
- **Static `LocalMemorySystem` prompt section.** Decision: not added in v1.
  The dynamic `## Local Knowledge` section's preamble is sufficient to tell
  the model about the local folder.
- **A `Local Knowledge` section in the tool list (like `list_memory`).**
  Deferred to the `list_memory` follow-up.

## Verification

1. `zig build` clean — no new warnings
2. New tests in `memories_test.zig` pass (filesystem unit tests)
3. Extended tests in `prompts_test.zig` pass (integration tests for both
   `build_agent_prompt` and `build_sub_agent_prompt`)
4. **Red-green check** for at least one new test:
   - Without the fix: test fails (no `## Local Knowledge` in prompt)
   - With the fix: test passes
5. All existing prompts tests still pass (regression guard)
6. Manual smoke: in a real project, create `.nalar/memories/test-rule.md`
   with a `# Test Rule\n\nBody` content, start a session in that directory,
   ask the agent "what rules are you aware of?", and confirm the response
   includes "Test Rule" / "Body". Should be a single token, not a manual
   `read_file` call.
7. Confirm the `## Global Knowledge` section still appears when only
   `~/.config/nalar/memories/` is populated (not cwd-local).

## Pitfalls / things that have bitten similar work

- **Sliced memory ownership in the dynamic prompt.** The new `loadLocalKnowledge`
  returns an owned slice; the `defer allocator.free` must be set on it
  **before** the `if (local_knowledge.len > 0)` check, or the buffer
  leaks when the section is rendered. Pattern matches `loadGlobalKnowledge`
  (`prompts.zig:409-410`).
- **Use `std.Io.Dir.cwd().readFileAlloc` for content, not for paths.** The
  existing `loadGlobalKnowledge` reads by absolute path with the cwd `Dir`
  handle (`prompts.zig:225`). Use the same idiom for local — never go via
  `std.fs.openFileAbsolute`, which doesn't go through the Io abstraction
  consistently.
- **Don't silently mask a real bug as "file unreadable".** If a `.md` file
  is unreadable (permissions, encoding), skip it (don't break the prompt),
  but consider a `std.log.debug` so the failure is visible in logs. Match
  the existing `listAllMemories` style, which uses `continue` and emits no
  warning.
- **Re-iterate on directory only once.** If a memory file is added or
  modified mid-session, the agent won't see it until the next prompt build.
  This matches the global behaviour and the existing test expectations; no
  inotify / watching is required.
- **Don't add a 50KB cap.** The static `SkillsUsage` reference at the top
  of `prompts.zig` mentions a 50KB cap, but `loadGlobalKnowledge` does not
  actually cap (`prompts.zig:201-206`). Mirror that. If a cap is wanted
  later, add it symmetrically to both `loadGlobalKnowledge` and
  `loadLocalKnowledge`.
