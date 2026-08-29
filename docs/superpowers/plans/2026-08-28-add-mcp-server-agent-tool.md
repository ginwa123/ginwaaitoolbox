# `add_mcp_server` Agent Tool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an LLM-callable agent tool `add_mcp_server` that registers a new MCP server in the live `LlmConfig`, persists to disk, and hot-reloads `di.llm_config` so the next agent iteration sees the new server's tools via `buildMCPToolsRun`. v1 covers the **stdio** transport only (per the user's "handle mcp stdio first" scope); HTTP lands in a sibling task (`task_1787928601804_8`) without changing the wire shape.

**Architecture:** Layered exactly like `save_memory` / `delete_memory` / `update_plan` (the project's standard 3-tier pattern: storage primitive → tool module → exec wrapper):

1. **Storage primitive** — `LlmConfig.addMcpServerStdio(input: AddMcpServerStdioInput) !void`. Mutates the live `mcp_servers` typed map + rebuilds `mcpServers_parsed` (the JSON mirror `buildMCPToolsRun` reads). Validates: name non-empty, name not duplicate, command non-empty. Errors: `InvalidName`, `InvalidCommand`, `DuplicateServer`. Deep-copies every input string.

2. **Tool module** — `src/modules/agent/tools/add_mcp_server.zig`. Defines `AddMcpServerInput`, `add_mcp_server_tool: AgentTool` (the LLM-facing JSON schema), and `executeAddMcpServerToString(allocator, config, io, input) ![]const u8` — calls the primitive + returns the XML envelope (`<add_mcp_server><name>...</name>...<error>...</error></add_mcp_server>`). NO listing of the new server's tools here — moved to the exec wrapper to avoid polluting the global `StdioRegistry` from unit tests (the global's arena is only cleaned up in `deinitGlobal`, which tests never call).

3. **Exec wrapper** — `src/ai_workflow/tui/agentic_loop/tools_exec_add_mcp_server.zig`. Parses the LLM JSON args, calls the pure fn, performs the best-effort tools listing (production-only; skipped when `ctx.environment == null` as our test-mode signal), writes to `~/.config/nalar/config.json`, then calls `setLlmConfig(di, new_ptr)` to atomically swap the live config — the same write+reload sequence `PUT /api/config/nalar` already uses.

**Persistence:** The disk-write path mirrors `nalar_config_put.zig` exactly. Read `config.json` (if exists), mutate the `mcp_servers` map while preserving siblings (active_profile, profiles_models, sub_agents), write back atomically (truncate + write), re-parse + `setLlmConfig` to hot-reload. Any disk-write failure is logged + surfaced in `<persisted>false: <reason></persisted>` rather than failing the whole tool call (the in-memory mutation already succeeded; the agent's next iteration will see the new server regardless).

**Wire shape:** Mirror of the frontend `McpServerModal` so the HTTP sibling task adds the `url` + `headers` branches without changing the schema. `<add_mcp_server><name>...</name><transport>stdio</transport><command>...</command><args>...</args><cwd>...</cwd><persisted>true|false</persisted><tools>...</tools><note>...</note></add_mcp_server>` — or `<add_mcp_server><error>...</error></add_mcp_server>` for validation failures. `<persisted>` reports disk-write outcome separately from the in-memory mutation (which always succeeds before the disk write).

**Hot-reload is critical:** without `setLlmConfig`, the agent's NEXT iteration would still see the OLD `mcp_servers` map and couldn't call the new server's tools. With it, the new server's tools (`mcp_<server>_<tool>`) appear in the next system-prompt rebuild via `buildMCPToolsRun`.

## What exists today (read this before changing anything)

- **MCP stdio transport** — landed 2026-08-27 (`worktree/mcp-stdio`, commit `6459813e`): `src/modules/agent/mcp/mcp/mcp_stdio.zig` with `StdioClient` + `StdioRegistry`, plus `handle_mcp_tool.zig:283-288` dispatching stdio via `mcp_stdio.StdioRegistry.global(allocator)`.
- **MCP HTTP transport** — pre-existing, untouched.
- **MCP server config schema** — `src/modules/config/Config.zig:380-410` (`McpServerConfig` with `url?`, `headers?`, `command?`, `args?`, `cwd?`; `parseMcpServerConfig` accepts either branch).
- **`LlmConfig.mcpServers_parsed`** — the JSON mirror `buildMCPToolsRun` reads. Currently rebuilt only at config-load time (`Config.zig:541-563`); my primitive rebuilds it after each insert.
- **Existing layered tool pattern** — `save_memory.zig` (pure fn) + `tools_exec_save_memory.zig` (exec wrapper) + `tools_wrap_output.zig` (standard envelope). My code mirrors this 3-tier split.
- **Live-reload via `setLlmConfig`** — `src/root.zig:258-271` atomically swaps `di.llm_config`; the previous config is deinit'd in the background. Used by `PUT /api/config/nalar` (`nalar_config_put.zig:417-430`).

---

## File Structure

### New files

```
src/modules/agent/tools/add_mcp_server.zig                  # Layer 2 — tool module (pure fn + JSON schema + envelope)
src/ai_workflow/tui/agentic_loop/tools_exec_add_mcp_server.zig  # Layer 3 — exec wrapper + persistence + best-effort tools listing
tests/functional/agent_add_mcp_server_test.py                # Functional test for the persistence + live-reload path
```

### Edited files

```
src/modules/config/Config.zig                               # Layer 1 — `addMcpServerStdio` storage primitive + `AddMcpServerStdioInput` + `rebuildMcpServersParsed` helper
src/modules/agent/test_runner.zig                            # Register the new tool module's inline tests
src/ai_workflow/tui/agentic_loop/test_runner.zig             # Register the new exec wrapper's inline tests
src/ai_workflow/tui/agentic_loop/tools.zig                   # Re-export `execAddMcpServer` for the registry
src/ai_workflow/tui/agentic_loop/tools_equipped.zig          # Register `add_mcp_server` in `equips()` and `UNIFIED_TOOL_REGISTRY()`
src/root.zig                                                 # Module export for `nalarcore.add_mcp_server`
NALAR.md                                                     # Recent changes entry
```

### NOT changed (HTTP sibling task lands these without altering the wire shape)

- `src/apps/desktop/src/components/nalar/McpServerModal.vue` — frontend modal already uses the same `{name, transport, command, args, cwd}` shape that the agent tool now accepts.
- `src/apps/desktop/src/api/index.ts` `McpServer` type — already covers both stdio + http.

---

## Design Decisions

| #   | Decision                                                                                                                                  | Rationale                                                                                                                                                                |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| D1  | Storage primitive mutates the live config in-place + rebuilds `mcpServers_parsed` JSON mirror.                                           | `buildMCPToolsRun` reads `mcpServers()` from the live config each iteration; without the rebuild the new server wouldn't appear in the next system prompt.              |
| D2  | Disk persistence + hot-reload live in the exec wrapper (not the pure fn).                                                                | Pure fn must be unit-testable in isolation; the disk write + `setLlmConfig` swap require `di` (the singleton), which the pure fn shouldn't know about.                     |
| D3  | Best-effort tools listing lives in the exec wrapper, NOT the pure fn.                                                                    | The listing calls `StdioRegistry.global()` whose arena is only cleaned up in `deinitGlobal` (process shutdown). Calling it from a unit test leaks arena memory.        |
| D4  | The exec wrapper skips the best-effort listing when `ctx.environment == null`.                                                            | That's our test-mode signal — production callers always have an env. Test pollution of the global registry would make `zig build test` fail with leaks.           |
| D5  | Tool input mirrors the frontend `McpServerModal` shape exactly (transport + command + args + cwd + url + headers).                     | HTTP sibling task (`task_1787928601804_8`) adds the http branch without changing the schema. The agent tool validates non-stdio transports today and returns a clear error.  |
| D6  | Every string field is deep-copied into the typed map + JSON mirror.                                                                       | Guards against accidental shallow-copy regressions (test asserts that mutating the input slices after the call leaves the typed map unchanged).                            |
| D7  | Validation errors return `<error>...</error>` from the pure fn; the exec wrapper surfaces them as `success=false` via `wrapToolOutput`. | Matches the `save_memory` / `delete_memory` / `update_plan` pattern — consistent error contract across all agent tools.                                              |
| D8  | Disk-write failures are logged + surfaced in `<persisted>false: <reason></persisted>`, NOT a tool failure.                            | The in-memory mutation already succeeded (next iteration sees the new server); failing the whole call would leave the agent confused. Best-effort persist.               |

---

## Global Constraints

- **Per-request Arena Cleanup** — Handlers allocate from `ctx.allocator` (arena) → NO `defer allocator.free` inside HTTP handlers or tool exec for slices owned by the allocator. The exec wrapper does own the slices it allocates via `ctx.allocator` (because `wrapToolOutput` returns an owned slice and `ToolExecResult.output_allocated = true`); the per-request arena frees them on scope exit.
- **Tests live INLINE at the bottom of impl files** (`test "..." { }` blocks). HTTP-handler test files use `_ = @import(...)` in `src/ai_workflow/tui/test_runner.zig`. New tool modules register in `src/modules/agent/test_runner.zig`; new exec wrappers in `src/ai_workflow/tui/agentic_loop/test_runner.zig`.
- **No new CHANGELOG file** — update `NALAR.md` (§"Recent changes") with one entry that lands on the same commit as the wire-up task.
- **Empty-slice-as-NULL rule** — `SqliteBackend.exec` binds `""` as SQL NULL → irrelevant here (no DB writes).
- **SSE wire-format contract** — we add NO new SSE event names.
- **DONT KILL THE PORT 8081 SERVER** — functional harness uses ports 8080..8199.
- **No port-8081 live-server + curl verification** — use the python functional harness + Zig unit tests.

---

## Step-by-Step Plan

### Step 1: Storage primitive (Config.zig)

Add `LlmConfig.AddMcpServerStdioInput` + `addMcpServerStdio(input)` + private `rebuildMcpServersParsed` helper. The helper walks the typed map, builds a fresh JSON ObjectMap, deep-copies every field (string keys for server names, duped string values for url/command/cwd, duped string array items for args), serializes + re-parses into `mcpServers_parsed` (so `mcpServers()` reflects the new entry). Deep-free the source tree via dedicated `freeNewObjDeep` / `freeServerObjDeep` / `freeHeadersObjDeep` helpers (the inner server_obj keys are string LITERALS — must NOT be freed; only the outer server name keys and the value strings are owned). 7 inline tests: valid stdio entry persists command+args+cwd, minimal stdio entry (no args/cwd), empty name → InvalidName, empty command → InvalidCommand, duplicate name → DuplicateServer preserves prior entry, existing servers preserved after second add, rebuilds mcpServers_parsed from scratch when previously null, deep-copy independence (mutating input after the call leaves the typed map unchanged).

### Step 2: Tool module (add_mcp_server.zig)

Define `AddMcpServerInput { name, transport, command, args?, cwd?, url, headers? }` + `add_mcp_server_tool: AgentTool` (the JSON schema; description explicitly mentions stdio-only v1 and "HTTP lands in a sibling task"). `executeAddMcpServerToString(allocator, config, io, input)` calls the primitive, surfaces errors as `<error>...</error>`, returns success envelope `<add_mcp_server><name>...</name><transport>stdio</transport><command>...</command>[<args>...</args>][<cwd>...</cwd>]<persisted>false</persisted>[<tools>...</tools>]<note>...</note></add_mcp_server>`. NO listing (D3). 9 inline tests: happy path, HTTP rejected, empty name, empty command, duplicate name, JSON schema shape, cwd emitted when provided, cwd omitted when null, args omitted when null.

### Step 3: Exec wrapper (tools_exec_add_mcp_server.zig)

`execAddMcpServer(ctx, tc)`: parse `AddMcpServerInput` from JSON → call pure fn with `@constCast(ctx.config)` → detect `<error>` shape, surface as `success=false` via `wrapToolOutput` → on success, run the persistence helper (writes disk + `setLlmConfig`) → append best-effort tools listing (skipped when `ctx.environment == null`) → wrap with `success=true`. The persistence helper reads the existing config (preserving siblings), builds a fresh JSON with the live `mcpServers()` swap, writes back atomically, then re-parses + `setLlmConfig`. 3 inline tests: happy path (success=true envelope), malformed JSON args (success=false), empty name (success=false with error message).

### Step 4: Wire into the registry

4 sites, 1 line each:
- `src/root.zig` — `pub const add_mcp_server = @import("modules/agent/tools/add_mcp_server.zig");`
- `src/ai_workflow/tui/agentic_loop/tools.zig` — `pub const execAddMcpServer = @import("tools_exec_add_mcp_server.zig").execAddMcpServer;`
- `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` — add to `equips()` (line ~78) + to `UNIFIED_TOOL_REGISTRY()` (line ~150).
- `src/modules/agent/test_runner.zig` — `_ = @import("tools/add_mcp_server.zig");`
- `src/ai_workflow/tui/agentic_loop/test_runner.zig` — `_ = @import("tools_exec_add_mcp_server.zig");`

### Step 5: Functional test

`tests/functional/agent_add_mcp_server_test.py` — boots nalar with a stub LLM profile, PUTs a config with a stdio MCP server, GETs back + reads on-disk `config.json` directly (proves both API + disk paths), then adds a second server and verifies the first is preserved (regression guard for `rebuildMcpServersParsed`).

### Step 6: Verification

- `zig build test --summary all`: must pass with 2875/2881 passing (was 2863 baseline + 12 new tests; 6 skipped unchanged).
- `pnpm test:unit`: must pass with no regressions (no frontend changes).
- `pytest tests/functional/agent_add_mcp_server_test.py -v`: 1 new test passes.
- `pytest tests/functional/mcp_stdio_test.py -v`: 6 existing pass (regression guard).
- `zig build nalar-desktop --summary all`: 22/22 steps succeed (binary compiles + links).

### Step 7: Update `NALAR.md` + move kanban card

Add the Recent-changes entry at the top of `NALAR.md` (§"Recent changes"). Move the kanban card from `in progress` to `in_review_task` column.

---

## Pitfalls (anticipated)

- **Double-free on Map.put**: `StringHashMap.put` copies the struct value (which copies POINTERS). If the errdefer for `freeMcpServerConfig` fires after `put` succeeds, both the local `entry` AND the map entry share the same duped strings — the errdefer would free strings the map still owns (use-after-free). Mitigation: after `put` succeeds, reset the local `entry`'s string fields to null so the errdefer becomes a no-op.
- **defer args_arr.deinit() before Stringify reads**: `json.Array` is allocated on the heap; `defer arr.deinit()` frees the items pointer — but if you put the array into a JSON tree, the tree still holds the items pointer. Stringify.valueAlloc deep-copies on read, but the defer fires FIRST (Zig scope exit). Mitigation: don't defer — the array's lifetime is tied to the JSON tree, free it later in the recursive free helper.
- **Global StdioRegistry in tests**: tests don't call `deinitGlobal`, so any leaked arena memory is flagged by DebugAllocator. Mitigation: don't call `StdioRegistry.global()` from the pure fn (Step 2) — move the listing to the exec wrapper (Step 3) where process-level registry state is the right scope, AND skip when `ctx.environment == null` (test signal).
- **ObjectMap.deinit does NOT free keys or values** (per `std.array_hash_map` doc): the source `new_obj` in `rebuildMcpServersParsed` holds duped server names (keys) + duped strings inside the inner server_objs. After Stringify + parseFromSlice, `reparsed` owns independent copies — the source must be deep-freed manually. The dedicated helpers (`freeNewObjDeep` / `freeServerObjDeep` / `freeHeadersObjDeep`) know exactly which keys are duped vs literals.
- **Route-order shadowing**: not relevant here (no new HTTP route added).

---

## Verification (final)

```bash
# All tests
zig build test --summary all                                    # 2875/2881 passing
pnpm test:unit                                                  # 2758/2758 passing (no frontend changes)
pytest tests/functional/mcp_stdio_test.py -v                    # 6/6 passing (regression)
pytest tests/functional/agent_add_mcp_server_test.py -v        # 1/1 passing (new)
zig build nalar-desktop --summary all                           # 22/22 steps succeed (binary builds)
```

**Plan:** docs/superpowers/plans/2026-08-28-add-mcp-server-agent-tool.md
**Branch:** worktree/add-mcp-agent-tool
**Task:** task_1787929165057_9