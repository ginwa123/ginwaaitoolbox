# Add Memories Menu to Settings (Full CRUD)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third "Memories" tab to the Settings sidebar (under Skills) with a two-pane UI that lets the user **list, view, create, edit, and delete** global memory files (`~/.config/nalar/memories/*.md`). Backed by 4 new HTTP endpoints. Pure additive change to the existing Skills pattern. **Scope is HTTP handlers + frontend only — no new agent tools in this plan (deferred to a follow-up so the agent can also manage memories from chat).**

**Architecture:** Mirror the Skills HTTP + frontend pattern. Backend: 4 new HTTP handlers, all backed by helpers added to `memories.zig` (no new agent tool files). Frontend: new `MemoriesSettings.vue` orchestrator + `MemoryList.vue` + `MemoryDetail.vue` (the detail handles view/edit/create/delete modes), wired into the existing 240 px sidebar. The `SettingsView.vue` gains a third tab + a third menu item. Global memories only (matches existing `list_memory` tool scope; local cwd memories out of scope for v1).

**Tech Stack:** Vue 3 + TypeScript + Vite + Bun. Vitest + @vue/test-utils + jsdom. Zig 0.16 + `std.Io.Threaded`. Tailwind 4 (layout utilities only). No new dependencies.

---

## Design decisions locked during brainstorming

1. **Global memories only for v1** — same scope as the existing `list_memory` tool. The cwd-scoped `get_local_memories_path_for_dir` helper exists in `memories.zig` but is NOT exposed via HTTP in v1. A future plan can add a `cwd` query param.
2. **MemoryDetail handles view + edit + create modes** in one component (mode switch via `mode` ref). Avoids 3 separate components for a feature that fits in ~200 lines.
3. **Name validation: must end in `.md`, no `/` or `..`, non-empty after trim.** Rejected with the same toast style as `add_skill`'s "Skill name cannot be empty" error.
4. **Plain-text `<pre>` viewer** for content (no markdown rendering). Matches the `SkillDetail.vue` style and avoids pulling in a markdown library. A future plan can add `marked` or similar.
5. **No "are you sure" modal for create/cancel** — the edit/create modal already has a Cancel button. Only Delete needs a confirm dialog (mirrors `SkillDetail.vue`).
6. **No new agent tools in this plan** — the agent already has `list_memory`. Adding `read_memory` / `add_memory` / `edit_memory` / `remove_memory` for the agent is deferred to a follow-up plan (out of scope here). This keeps this plan's blast radius to HTTP + frontend only.

## File structure

### New files

```
src/ai_workflow/tui/http_handlers/
├── memories_detail.zig              (GET /api/memories/:name)
├── memories_create.zig              (POST /api/memories)
├── memories_update.zig              (PUT /api/memories/:name)
├── memories_delete.zig              (DELETE /api/memories/:name)
└── memories_crud_test.zig           (or one test file per handler — mirror skills)

src/apps/desktop/src/components/
├── MemoriesSettings.vue             (orchestrator: list + detail)
└── MemoryDetail.vue                 (view/edit/create/delete modes)

src/apps/desktop/src/components/tool_outputs/
└── MemoryList.vue                   (list, loading, error, empty)

src/apps/desktop/src/__tests__/
├── MemoryList.spec.ts
└── MemoryDetail.spec.ts

docs/plans/2026-06-17-add-memories-settings-menu.md  (this file)
```

### Modified files

```
src/modules/agent/tools/
└── memories.zig                     (add read/write/delete/exists helpers — used by HTTP handlers)

src/ai_workflow/tui/http_handlers/
└── mod.zig                          (export the 4 new handlers)

src/main.zig                         (register 4 new HTTP routes)

src/apps/desktop/src/api/index.ts    (add 4 API client methods + TS interfaces)

src/apps/desktop/src/components/
└── SettingsView.vue                 (add 'memories' tab + menu item + 3rd <MemoriesSettings> branch)
```

---

## Verification commands (run throughout)

```bash
# Backend (Zig)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 40

# Frontend type-check + bundle (per project NALAR.md memory — bun run build
# is the authoritative type check, NOT vitest)
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20

# Frontend unit tests
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 20

# Manual smoke test (after starting nalar in a separate terminal)
curl -sS http://127.0.0.1:8080/api/memories | python3 -m json.tool
curl -sS -X POST http://127.0.0.1:8080/api/memories \
  -H 'Content-Type: application/json' \
  -d '{"name":"test.md","content":"# test\n\nhello"}'
curl -sS http://127.0.0.1:8080/api/memories/test.md | python3 -m json.tool
curl -sS -X PUT http://127.0.0.1:8080/api/memories/test.md \
  -H 'Content-Type: application/json' \
  -d '{"content":"# test\n\nupdated"}'
curl -sS -X DELETE http://127.0.0.1:8080/api/memories/test.md
```

Per the project's `desktop-typescript-bun-build-as-typecheck` memory:
**Always run `bun run build` (NOT just `bunx vitest run`)** — vitest uses esbuild
which strips types, so TS2532 errors only surface during `vue-tsc --build`.

---

## Chunk 1: Backend helpers in `memories.zig`

Add to `src/modules/agent/tools/memories.zig` (do NOT rewrite the file —
surgical append):

- [ ] **Step 1.1: Add `readMemoryFile` helper**

```zig
/// Read a single global memory file by name (e.g. "user-preferences.md").
/// Returns allocated content; caller frees. Returns null if the name is
/// invalid (contains "/" or "..", doesn't end in ".md") or the file is
/// missing. Mirrors the safety checks used by the Skills read tools.
pub fn readMemoryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    name: []const u8,
) ?[]u8 {
    if (!isValidMemoryName(name)) return null;
    const dir_path = get_global_memories_path(allocator, environment) orelse return null;
    defer allocator.free(dir_path);

    const full_path = std.fs.path.join(allocator, &.{ dir_path, name }) catch return null;
    defer allocator.free(full_path);

    return std.Io.Dir.cwd().readFileAlloc(
        io,
        full_path,
        allocator,
        std.Io.Limit.limited(std.math.maxInt(usize)),
    ) catch null;
}

/// Validate a memory filename. Rejects:
///   - empty / whitespace-only
///   - anything not ending in ".md"
///   - path separators ("/", "\")
///   - parent references ("..")
fn isValidMemoryName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (!std.mem.endsWith(u8, trimmed, ".md")) return false;
    if (std.mem.indexOfAny(u8, trimmed, "/\\") != null) return false;
    if (std.mem.indexOf(u8, trimmed, "..") != null) return false;
    return true;
}
```

- [ ] **Step 1.2: Add `writeMemoryFile` helper**

```zig
/// Write content to a global memory file. Creates parent dir if missing.
/// Returns true on success, false on validation error or IO failure.
/// Overwrites if the file already exists. Caller owns `content`.
pub fn writeMemoryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    name: []const u8,
    content: []const u8,
) bool {
    if (!isValidMemoryName(name)) return false;
    const dir_path = get_global_memories_path(allocator, environment) orelse return false;
    defer allocator.free(dir_path);

    // Ensure the global memories directory exists.
    std.Io.Dir.cwd().makePath(io, dir_path) catch return false;

    const full_path = std.fs.path.join(allocator, &.{ dir_path, name }) catch return false;
    defer allocator.free(full_path);

    // Atomic-ish: write to a temp file then rename. Avoids partial writes
    // corrupting an existing memory if the process is killed mid-write.
    const tmp_path = std.fs.path.join(allocator, &.{ full_path, ".tmp" }) catch return false;
    defer allocator.free(tmp_path);

    {
        const file = std.Io.Dir.cwd().createFile(io, tmp_path, .{}) catch return false;
        defer std.Io.File.close(file, io);
        file.writeStreaming(io, content) catch return false;
    }
    std.Io.Dir.cwd().rename(io, tmp_path, full_path) catch return false;
    return true;
}
```

- [ ] **Step 1.3: Add `deleteMemoryFile` helper**

```zig
/// Delete a global memory file by name. Returns true on success or if
/// the file did not exist (idempotent); false on validation error or
/// unexpected IO failure.
pub fn deleteMemoryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    name: []const u8,
) bool {
    if (!isValidMemoryName(name)) return false;
    const dir_path = get_global_memories_path(allocator, environment) orelse return false;
    defer allocator.free(dir_path);

    const full_path = std.fs.path.join(allocator, &.{ dir_path, name }) catch return false;
    defer allocator.free(full_path);

    std.Io.Dir.cwd().deleteFile(io, full_path) catch |err| {
        // ENOENT is "already gone" — treat as success.
        if (err == error.FileNotFound) return true;
        return false;
    };
    return true;
}
```

- [ ] **Step 1.4: Add `memoryExists` helper** (used by create handler to reject duplicates)

```zig
/// Returns true if a memory with the given name exists in the global folder.
pub fn memoryExists(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    name: []const u8,
) bool {
    if (!isValidMemoryName(name)) return false;
    const dir_path = get_global_memories_path(allocator, environment) orelse return false;
    defer allocator.free(dir_path);

    const full_path = std.fs.path.join(allocator, &.{ dir_path, name }) catch return false;
    defer allocator.free(full_path);

    // stat the file; success = exists.
    _ = std.Io.Dir.cwd().statFile(io, full_path, .{}) catch return false;
    return true;
}
```

- [ ] **Step 1.5: Add helper tests to `memories_test.zig`**

Append a new section for the CRUD helpers to the existing `src/modules/agent/tools/memories_test.zig`. Use the existing test setup pattern (use a temp `HOME` env so the test doesn't touch the user's real memories, or stub `get_global_memories_path` indirectly by creating a memory in a temp dir and reading it back). Cover:

- `isValidMemoryName` rejects: empty, whitespace-only, no `.md` suffix, contains `/`, contains `\`, contains `..`
- `isValidMemoryName` accepts: `foo.md`, `user-prefs.md`, `with.dots.in.name.md`
- `readMemoryFile` returns null for invalid name
- `readMemoryFile` returns null for missing file
- `writeMemoryFile` creates the parent dir if missing (test with a deep path that doesn't exist yet)
- `writeMemoryFile` overwrites existing file
- `memoryExists` returns false on missing, true after write
- `deleteMemoryFile` is idempotent (returns true on second call)
- `editMemoryFile` returns false when target doesn't exist

Pattern (add to memories_test.zig, end of file):

```zig
// -------------------------------------------------------------------------
// CRUD helpers (readMemoryFile / writeMemoryFile / deleteMemoryFile /
// memoryExists / editMemoryFile) — uses a temp dir for HOME so tests
// don't touch the user's real memories
// -------------------------------------------------------------------------

test "readMemoryFile returns null on invalid name" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const env_ptr = blk: {
        // Build a minimal env map with just HOME -> temp dir.
        // (For brevity, just test the pure validation branch: no env
        // needed because isValidMemoryName returns false first.)
        _ = alloc; _ = io;
        break :blk @as(?*const std.process.Environ.Map, null);
    };
    try std.testing.expect(memories.readMemoryFile(alloc, io, env_ptr, "") == null);
    try std.testing.expect(memories.readMemoryFile(alloc, io, env_ptr, "foo.txt") == null);
    try std.testing.expect(memories.readMemoryFile(alloc, io, env_ptr, "../etc/passwd") == null);
    try std.testing.expect(memories.readMemoryFile(alloc, io, env_ptr, "sub/dir.md") == null);
}
```

(For tests that need a real `HOME`, set it to a temp dir at the top of the test. The pattern is the same one used by `listMemoriesInDir` tests above — point at a `/tmp/nalar-memories-*` directory.)

- [ ] **Step 1.6: Verify with `zig build test`**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 20
```

Expected: existing 431/431 pass + ~9 new tests pass (Step 1.5). No behavior change to anything else.

---

## Chunk 2: Deferred — new agent tools for the agent

This plan deliberately **omits** the 4 new agent tools (`read_memory`, `add_memory`, `edit_memory`, `remove_memory`) that would let the agent manage memories from chat. The scope here is HTTP handlers + frontend only.

**Why deferred:** the agent already has `list_memory` and can use `read_file` to read any memory by path. Adding the 3 missing tools is a separate, self-contained piece of work — the user explicitly asked to keep this plan to HTTP + frontend.

**Follow-up plan will:**
- Add `src/modules/agent/tools/{read,add,edit,remove}_memory.zig` (each ~80 lines, mirroring `add_skill.zig` / `remove_skill.zig` shape)
- Add matching `*_memory_test.zig` files
- Register the 4 tools in `src/ai_workflow/tui/tool_registry.zig` next to the existing `list_memory` (line ~1427)
- Update the `list_memory` description to mention the new tools exist

**Reuse the helpers added in Chunk 1** (`readMemoryFile`, `writeMemoryFile`, `editMemoryFile`, `deleteMemoryFile`, `memoryExists`). They are already the right shape — each tool just needs an `execute*ToString` wrapper that calls the helper and emits an XML result.

---

## Chunk 3: New HTTP endpoints (4 handlers)

Each handler is a thin wrapper over the new helpers in `memories.zig`. They
return JSON in the same shape as the existing `skill_*` handlers. All four
read `ctx.environment` from the singleton (matches `memoriesListHandler`).

### Task 3.1: `GET /api/memories/:name` — `memories_detail.zig`

- [ ] **Step 1: Create `src/ai_workflow/tui/http_handlers/memories_detail.zig`**

```zig
const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const memories_mod = nalarcore.memories;

/// GET /api/memories/:name
/// Returns {"memory":{"name":"...","title":"...","path":"...","size":N,"content":"..."}}
/// on success; 404 {"error":"Memory not found"} on miss.
pub fn memoryDetailHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const environment = di.environment orelse {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = "{\"error\":\"Missing environment\"}",
        });
    };

    const name = req.path_params.get("name") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"Missing :name\"}" });
    };

    const content = memories_mod.readMemoryFile(allocator, ctx.io, environment, name) orelse {
        return res.jsonResponse(.{ .status_code = 404, .data = "{\"error\":\"Memory not found\"}" });
    };
    defer allocator.free(content);

    // Re-list to get title + path + size (cheaper than re-parsing the file).
    const list = memories_mod.listAllMemories(allocator, ctx.io, environment);
    defer memories_mod.freeMemoriesList(allocator, list);
    var info: ?memories_mod.MemoryInfo = null;
    for (list) |m| {
        if (std.mem.eql(u8, m.name, name)) {
            info = m;
            break;
        }
    }
    const m = info orelse {
        return res.jsonResponse(.{ .status_code = 404, .data = "{\"error\":\"Memory not found\"}" });
    };

    const json = try std.fmt.allocPrint(allocator,
        "{{\"memory\":{{\"name\":\"{s}\",\"title\":\"{s}\",\"path\":\"{s}\",\"size\":{d},\"content\":\"{s}\"}}}}",
        .{ m.name, m.title, m.path, m.size, content },
    );
    // Note: hand-rolled JSON; content may contain quotes/backslashes.
    // For safety, replace with std.json.Stringify once a MemoryDetail
    // struct is defined. See skill_detail.zig for the typed pattern.
    return res.jsonResponse(.{ .status_code = 200, .data = json });
}
```

> **Pitfall:** the hand-rolled `std.fmt.allocPrint` does NOT escape quotes
> in `content`. A memory containing a `"` will produce invalid JSON. The
> project memory `zig-no-default-function-parameters.md` mentions
> `jsonEscape` is the safer pattern. Use the existing `jsonEscape` helper
> in `llm_history.zig:491` to escape `content`, `name`, `title`, `path`
> before formatting. **Do NOT copy the hand-rolled pattern above as-is**
> — replace with the jsonEscape-on-each-field pattern from `llm_history.zig`.

- [ ] **Step 2: Add a `MemoryDetail` struct to a shared header** (or define it locally) and use `std.json.Stringify.valueAlloc(allocator, detail, .{})` for the response. This is the safer, idiomatic pattern.

### Task 3.2: `POST /api/memories` — `memories_create.zig`

- [ ] **Step 1: Create the file**. Body: `{"name":"foo.md","content":"..."}`. Returns 201 with `{"memory":{name, title, path, size}}` on success; 400 on validation error (with `{"error":"..."}`); 409 if already exists.

```zig
const CreateMemoryBody = struct {
    name: []const u8,
    content: []const u8,
};

pub fn memoryCreateHandler(...) !... {
    // 1. Parse body as CreateMemoryBody
    // 2. memoryExists check → 409
    // 3. writeMemoryFile → 400 on failure
    // 4. Re-list to get title/path/size
    // 5. Return 201 with the same shape as detail
}
```

### Task 3.3: `PUT /api/memories/:name` — `memories_update.zig`

- [ ] **Step 1: Create the file**. Body: `{"content":"..."}`. Returns 200 on success; 404 if missing; 400 on validation error.

### Task 3.4: `DELETE /api/memories/:name` — `memories_delete.zig`

- [ ] **Step 1: Create the file**. No body. Returns 200 `{"success":true,"name":"..."}` on success (idempotent — 200 even if already missing). Matches the `skill_delete.zig` response shape.

### Task 3.5: Re-export + register routes

- [ ] **Step 1: Add to `src/ai_workflow/tui/http_handlers/mod.zig`** right under the existing `memoriesListHandler` line (line 71):

```zig
pub const memoryDetailHandler = @import("memories_detail.zig").memoryDetailHandler;
pub const memoryCreateHandler = @import("memories_create.zig").memoryCreateHandler;
pub const memoryUpdateHandler = @import("memories_update.zig").memoryUpdateHandler;
pub const memoryDeleteHandler = @import("memories_delete.zig").memoryDeleteHandler;
```

- [ ] **Step 2: Add routes in `src/main.zig`** right after line 279 (`/api/memories` GET):

```zig
try gs.router.get("/api/memories/:name", ai_mod.http_handlers.memoryDetailHandler);
try gs.router.post("/api/memories", ai_mod.http_handlers.memoryCreateHandler);
try gs.router.put("/api/memories/:name", ai_mod.http_handlers.memoryUpdateHandler);
try gs.router.delete("/api/memories/:name", ai_mod.http_handlers.memoryDeleteHandler);
```

- [ ] **Step 3: Verify with `zig build test` and a manual `curl` smoke test** (see verification commands at top).

---

## Chunk 4: Frontend API client (`api/index.ts`)

- [ ] **Step 1: Add the TS interfaces** near the existing `Skill` interface (around line 921). Pattern:

```ts
// Memories API
export interface Memory {
  name: string
  title: string
  path: string
  size: number
}

export interface MemoryDetail extends Memory {
  content: string
}

export interface MemoryDetailResponse {
  memory: MemoryDetail | null
  error_message: string | null
}

export interface MemoryDeleteResponse {
  success: boolean
  name: string
  error_message: string | null
}
```

- [ ] **Step 2: Add 5 client functions** (list + 4 CRUD). Use the existing
`fetch(${API_BASE}/...)` pattern, throwing `new Error('HTTP ${response.status}')` on non-2xx.

```ts
export async function getMemories(): Promise<{ memories: Memory[] }> {
  const response = await fetch(`${API_BASE}/memories`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function getMemoryDetail(name: string): Promise<MemoryDetailResponse> {
  const response = await fetch(`${API_BASE}/memories/${encodeURIComponent(name)}`)
  if (!response.ok) {
    if (response.status === 404) return { memory: null, error_message: 'Memory not found' }
    throw new Error(`HTTP ${response.status}`)
  }
  return response.json()
}

export async function createMemory(name: string, content: string): Promise<{ memory: Memory }> {
  const response = await fetch(`${API_BASE}/memories`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, content }),
  })
  if (!response.ok) {
    const text = await response.text().catch(() => '')
    throw new Error(text || `HTTP ${response.status}`)
  }
  return response.json()
}

export async function updateMemory(name: string, content: string): Promise<{ memory: Memory }> {
  const response = await fetch(`${API_BASE}/memories/${encodeURIComponent(name)}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content }),
  })
  if (!response.ok) {
    const text = await response.text().catch(() => '')
    throw new Error(text || `HTTP ${response.status}`)
  }
  return response.json()
}

export async function deleteMemory(name: string): Promise<MemoryDeleteResponse> {
  const response = await fetch(`${API_BASE}/memories/${encodeURIComponent(name)}`, {
    method: 'DELETE',
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}
```

- [ ] **Step 3: Verify with `bun run build`**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: clean.

---

## Chunk 5: Frontend `MemoriesSettings.vue` orchestrator

Mirrors `SkillsSettings.vue` (73 lines) exactly. Two-panel: list left, detail right.

- [ ] **Step 1: Create `src/apps/desktop/src/components/MemoriesSettings.vue`**

```vue
<script setup lang="ts">
import { ref } from 'vue'
import MemoryList from './tool_outputs/MemoryList.vue'
import MemoryDetail from './MemoryDetail.vue'

const emit = defineEmits<{
  notification: [message: string, type: 'success' | 'error']
}>()

const selectedMemoryName = ref<string | null>(null)
const memoryListRef = ref<InstanceType<typeof MemoryList> | null>(null)

const handleSelectMemory = (name: string) => {
  selectedMemoryName.value = name
}

const handleMemoryDeleted = (_name: string) => {
  selectedMemoryName.value = null
  memoryListRef.value?.refresh()
  emit('notification', 'Memory deleted successfully', 'success')
}

const handleMemorySaved = () => {
  memoryListRef.value?.refresh()
  emit('notification', 'Memory saved', 'success')
}

const handleError = (message: string) => {
  emit('notification', message, 'error')
}
</script>

<template>
  <div class="flex h-full gap-6">
    <!-- Memory List Panel -->
    <div class="w-80 shrink-0 flex flex-col overflow-hidden">
      <div class="rounded-xl p-6 flex-1 flex flex-col overflow-hidden"
           style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);">
        <h2 class="text-base font-semibold mb-4 shrink-0" style="color: var(--semantic-text);">Memories</h2>
        <p class="text-sm mb-4 shrink-0" style="color: var(--semantic-text-muted);">
          Global markdown notes the agent can reference. Files live in <code>~/.config/nalar/memories/</code>.
        </p>
        <div class="flex-1 overflow-y-auto min-h-0">
          <MemoryList
            ref="memoryListRef"
            :selected-memory-name="selectedMemoryName"
            @select-memory="handleSelectMemory"
          />
        </div>
      </div>
    </div>

    <!-- Memory Detail Panel -->
    <div class="flex-1 flex flex-col overflow-hidden">
      <div class="rounded-xl flex-1 flex flex-col overflow-hidden"
           style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);">
        <h2 class="text-base font-semibold p-4 shrink-0"
            style="color: var(--semantic-text); border-bottom: 1px solid var(--color-border);">
          Memory
        </h2>
        <div class="flex-1 overflow-hidden">
          <MemoryDetail
            :memory-name="selectedMemoryName"
            @memory-deleted="handleMemoryDeleted"
            @memory-saved="handleMemorySaved"
            @error="handleError"
          />
        </div>
      </div>
    </div>
  </div>
</template>
```

---

## Chunk 6: `MemoryList.vue` (left panel)

Mirrors `SkillList.vue` (145 lines) but simpler — only one section (Global)
because design decision #1 is global-only.

- [ ] **Step 1: Create `src/apps/desktop/src/components/tool_outputs/MemoryList.vue`**

Pattern is essentially `SkillList.vue` minus the Local Skills section:
- `memories = ref<Memory[]>([])`, `isLoading`, `error` refs
- `loadMemories()` calls `getMemories()` and sets `memories.value = result.memories || []`
- `openMemory(memory)` emits `selectMemory` with the name
- Empty state: "No memories yet. Click + New Memory in the detail panel to create one."
- Each row shows: 🧠 icon + name + title + size (human-readable, e.g. `1.2 KB`)

```vue
<template>
  <div class="memory-list">
    <div v-if="isLoading" class="flex items-center justify-center py-8">
      <div class="flex items-center gap-3">
        <div class="w-5 h-5 border-2 rounded-full animate-spin"
             style="border-color: var(--color-violet); border-top-color: transparent;"></div>
        <span style="color: var(--semantic-text-muted);">Loading memories...</span>
      </div>
    </div>

    <div v-else-if="error" class="text-center py-8">
      <p class="text-sm" style="color: var(--color-red);">{{ error }}</p>
      <button @click="loadMemories" class="mt-3 px-4 py-2 rounded-lg text-sm"
              style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);">
        Retry
      </button>
    </div>

    <div v-else-if="memories.length === 0" class="text-center py-8">
      <p class="text-sm" style="color: var(--semantic-text-muted);">No memories yet</p>
    </div>

    <div v-else class="space-y-2">
      <div v-for="mem in memories" :key="mem.name"
           class="p-4 rounded-lg transition-all duration-200 cursor-pointer hover:opacity-90"
           :class="{ 'ring-2': props.selectedMemoryName === mem.name }"
           :style="props.selectedMemoryName === mem.name
             ? 'background-color: var(--semantic-active-bg); border-color: var(--color-violet);'
             : 'background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);'"
           @click="openMemory(mem)">
        <div class="flex items-start gap-3">
          <span class="text-lg mt-0.5">🧠</span>
          <div class="flex-1 min-w-0">
            <h3 class="text-sm font-medium truncate" style="color: var(--semantic-text);">{{ mem.title }}</h3>
            <p class="text-xs mt-1 truncate" style="color: var(--semantic-text-muted);">{{ mem.name }}</p>
            <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">{{ formatSize(mem.size) }}</p>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 2: Add the `formatSize` helper** (1 KB = 1024 bytes, show KB/MB).

```ts
function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}
```

---

## Chunk 7: `MemoryDetail.vue` (right panel — view/edit/create/delete)

Single component with 4 modes driven by refs:
- `view` — selectedMemoryName set, not editing, not creating
- `edit` — user clicked Edit on a selected memory
- `create` — user clicked "+ New Memory" and selectedMemoryName is null
- `empty` — selectedMemoryName is null and not creating (show "Select a memory or create a new one")

- [ ] **Step 1: Create `src/apps/desktop/src/components/MemoryDetail.vue`**

Top of script:

```ts
import { ref, watch, computed } from 'vue'
import { getMemoryDetail, createMemory, updateMemory, deleteMemory, type MemoryDetail as MemoryDetailData } from '../api'

const props = defineProps<{
  memoryName: string | null
}>()

const emit = defineEmits<{
  memoryDeleted: [name: string]
  memorySaved: []
  error: [message: string]
}>()

const detail = ref<MemoryDetailData | null>(null)
const isLoading = ref(false)
const isSaving = ref(false)
const isDeleting = ref(false)
const error = ref<string | null>(null)
const mode = ref<'view' | 'edit' | 'create' | 'empty'>('empty')

// Editable copies
const editName = ref('')
const editContent = ref('')

// Show delete confirm
const showDeleteConfirm = ref(false)

// Watch prop changes to drive mode
watch(() => props.memoryName, async (newName) => {
  if (!newName) {
    detail.value = null
    error.value = null
    mode.value = 'empty'
    return
  }
  isLoading.value = true
  error.value = null
  try {
    const result = await getMemoryDetail(newName)
    if (result.error_message) {
      error.value = result.error_message
      detail.value = null
      mode.value = 'empty'
    } else if (result.memory) {
      detail.value = result.memory
      editName.value = result.memory.name
      editContent.value = result.memory.content
      mode.value = 'view'
    }
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load memory'
    mode.value = 'empty'
  } finally {
    isLoading.value = false
  }
}, { immediate: true })
```

- [ ] **Step 2: Add action handlers** (in `<script setup>`)

```ts
const startEdit = () => {
  if (!detail.value) return
  editName.value = detail.value.name  // disabled in edit mode (name is the id)
  editContent.value = detail.value.content
  mode.value = 'edit'
}

const cancelEdit = () => {
  mode.value = 'view'
  if (detail.value) editContent.value = detail.value.content
}

const saveEdit = async () => {
  if (!detail.value) return
  isSaving.value = true
  try {
    await updateMemory(detail.value.name, editContent.value)
    mode.value = 'view'
    // Refresh the detail so title/size update if content changed
    const result = await getMemoryDetail(detail.value.name)
    if (result.memory) detail.value = result.memory
    emit('memorySaved')
  } catch (err) {
    emit('error', err instanceof Error ? err.message : 'Failed to save memory')
  } finally {
    isSaving.value = false
  }
}

const startCreate = () => {
  detail.value = null
  editName.value = ''
  editContent.value = '# New Memory\n\nWrite your notes here.\n'
  mode.value = 'create'
}

const cancelCreate = () => {
  mode.value = 'empty'
  editName.value = ''
  editContent.value = ''
}

const saveCreate = async () => {
  const trimmedName = editName.value.trim()
  if (!trimmedName) {
    emit('error', 'Name cannot be empty')
    return
  }
  if (!trimmedName.endsWith('.md')) {
    emit('error', 'Name must end in .md')
    return
  }
  if (trimmedName.includes('/') || trimmedName.includes('\\') || trimmedName.includes('..')) {
    emit('error', 'Name cannot contain path separators')
    return
  }
  isSaving.value = true
  try {
    const result = await createMemory(trimmedName, editContent.value)
    mode.value = 'view'
    detail.value = result.memory
    editName.value = result.memory.name
    editContent.value = result.memory.content
    emit('memorySaved')
  } catch (err) {
    emit('error', err instanceof Error ? err.message : 'Failed to create memory')
  } finally {
    isSaving.value = false
  }
}

const confirmDelete = () => { showDeleteConfirm.value = true }
const cancelDelete = () => { showDeleteConfirm.value = false }
const handleDelete = async () => {
  if (!detail.value) return
  isDeleting.value = true
  try {
    const result = await deleteMemory(detail.value.name)
    if (result.success) {
      showDeleteConfirm.value = false
      emit('memoryDeleted', detail.value.name)
    } else {
      emit('error', result.error_message || 'Failed to delete memory')
    }
  } catch (err) {
    emit('error', err instanceof Error ? err.message : 'Failed to delete memory')
  } finally {
    isDeleting.value = false
  }
}
```

- [ ] **Step 3: Build the template** — 4 branches based on `mode.value`. Use the
`SkillsSettings.vue` + `SkillDetail.vue` visual style (rounded-xl cards,
violet active ring, dark surface, `:style="..."` for theme tokens).

Template sketch (full version in implementation; this is the structure):

```vue
<template>
  <div class="memory-detail h-full flex flex-col overflow-hidden">
    <!-- Empty state -->
    <div v-if="mode === 'empty'" class="flex-1 flex flex-col items-center justify-center gap-4 p-6">
      <p class="text-sm" style="color: var(--semantic-text-muted);">
        Select a memory to view, or create a new one.
      </p>
      <button @click="startCreate" class="px-4 py-2 rounded-lg text-sm font-medium"
              style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;">
        + New Memory
      </button>
    </div>

    <!-- Loading state -->
    <div v-else-if="isLoading" class="flex-1 flex items-center justify-center">
      <div class="flex items-center gap-3">
        <div class="w-5 h-5 border-2 rounded-full animate-spin"
             style="border-color: var(--color-violet); border-top-color: transparent;"></div>
        <span style="color: var(--semantic-text-muted);">Loading...</span>
      </div>
    </div>

    <!-- Error state -->
    <div v-else-if="error" class="flex-1 flex items-center justify-center">
      <p class="text-sm" style="color: var(--color-red);">{{ error }}</p>
    </div>

    <!-- Create mode -->
    <div v-else-if="mode === 'create'" class="flex-1 flex flex-col overflow-hidden">
      <div class="p-4 shrink-0" style="border-bottom: 1px solid var(--color-border);">
        <input v-model="editName" placeholder="my-memory.md" ... />
      </div>
      <div class="flex-1 overflow-y-auto p-4">
        <textarea v-model="editContent" rows="20" class="w-full ... resize-none" ... />
      </div>
      <div class="p-4 flex gap-2 justify-end shrink-0" style="border-top: 1px solid var(--color-border);">
        <button @click="cancelCreate" :disabled="isSaving" class="px-4 py-2 ...">Cancel</button>
        <button @click="saveCreate" :disabled="isSaving" class="px-4 py-2 ...">
          {{ isSaving ? 'Creating...' : 'Create' }}
        </button>
      </div>
    </div>

    <!-- View / Edit mode (shared shell, different buttons) -->
    <div v-else-if="detail" class="flex-1 flex flex-col overflow-hidden">
      <div class="p-4 shrink-0" style="border-bottom: 1px solid var(--color-border);">
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-3">
            <span class="text-lg">🧠</span>
            <h3 class="text-base font-semibold" style="color: var(--semantic-text);">{{ detail.title }}</h3>
          </div>
          <div v-if="mode === 'view'" class="flex gap-2">
            <button @click="startEdit" class="px-3 py-1 text-xs rounded" ...>Edit</button>
            <button @click="confirmDelete" class="w-8 h-8 rounded-lg ..." title="Delete memory">
              <svg ...><!-- trash icon --></svg>
            </button>
          </div>
        </div>
        <p class="text-xs" style="color: var(--semantic-text-dim);">
          <span class="font-medium">Path:</span> {{ detail.path }} · {{ formatSize(detail.size) }}
        </p>
      </div>

      <div class="flex-1 overflow-y-auto p-4">
        <pre v-if="mode === 'view'" class="text-xs p-4 rounded whitespace-pre-wrap"
             style="background-color: var(--semantic-content-bg); color: var(--semantic-text-muted);">{{ detail.content }}</pre>
        <textarea v-else v-model="editContent" rows="20" class="w-full ... resize-none" />
      </div>

      <div v-if="mode === 'edit'" class="p-4 flex gap-2 justify-end shrink-0" style="border-top: 1px solid var(--color-border);">
        <button @click="cancelEdit" :disabled="isSaving" class="...">Cancel</button>
        <button @click="saveEdit" :disabled="isSaving" class="...">
          {{ isSaving ? 'Saving...' : 'Save' }}
        </button>
      </div>
    </div>

    <!-- Delete Confirmation Modal (overlay, mirrors SkillDetail) -->
    <div v-if="showDeleteConfirm" class="absolute inset-0 flex items-center justify-center z-10"
         style="background-color: rgba(0,0,0,0.5);">
      <div class="rounded-xl p-6 max-w-sm mx-4"
           style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);">
        <h3 class="text-base font-semibold mb-2" style="color: var(--semantic-text);">Delete Memory?</h3>
        <p class="text-sm mb-4" style="color: var(--semantic-text-muted);">
          Are you sure you want to delete "<strong>{{ detail?.name }}</strong>"? This action cannot be undone.
        </p>
        <div class="flex gap-3 justify-end">
          <button @click="cancelDelete" :disabled="isDeleting" class="...">Cancel</button>
          <button @click="handleDelete" :disabled="isDeleting" class="..." style="background-color: var(--color-red); color: white;">
            {{ isDeleting ? 'Deleting...' : 'Delete' }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
```

- [ ] **Step 4: Add the `formatSize` helper** (duplicate from MemoryList or
move to a shared util — implementer decides; for v1, duplicate is fine).

---

## Chunk 8: Wire it into `SettingsView.vue`

- [ ] **Step 1: Add the import** at the top:

```ts
import MemoriesSettings from './MemoriesSettings.vue'
```

- [ ] **Step 2: Add the menu item** right under the Skills button (around line 90):

```vue
<button
  @click="setSettingsTab('memories')"
  class="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200"
  :style="activeSettingsTab === 'memories'
    ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text);`
    : `color: var(--semantic-text-muted);`"
>
  <span class="text-lg">🧠</span>
  <span>Memories</span>
</button>
```

- [ ] **Step 3: Add the content branch** after the Skills branch (around line 104):

```vue
<div v-else-if="activeSettingsTab === 'memories'" class="flex-1 overflow-y-auto p-6">
  <MemoriesSettings @notification="handleNotification" />
</div>
```

> **Pitfall (per `nalar-frontend-task-literal-typing-rule`):** the three
> branches MUST be independent `v-if` / `v-else-if` siblings, not chained
> `v-else-if` everywhere. The existing pattern is already `v-if` / `v-else-if`
> for two branches; adding a third becomes `v-if` / `v-else-if` / `v-else-if`.
> Do NOT introduce a new `v-else` at the end.

- [ ] **Step 4: Verify with `bun run build`** (must pass — this is the type check).

---

## Chunk 9: Tests

### Task 9.1: Backend Zig tests (Chunks 1-3)

Already specified inline in each step. Run:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 20
```

Expected: all prior tests pass + ~9 new tests pass from Chunk 1.5 + ~8 new tests pass from HTTP handler tests (2 per handler × 4 handlers, or whatever the skill handlers use). Total backend delta: ~+17 tests.

### Task 9.2: Frontend Vitest tests (Chunks 4-8)

- [ ] **Step 1: `src/apps/desktop/src/__tests__/MemoryList.spec.ts`** — minimal coverage:
  - Renders loading state on mount
  - Renders empty state when `getMemories` returns `{memories: []}`
  - Renders a row for each memory (uses `getMemories` mocked)
  - Emits `selectMemory` with the correct name on row click
  - Calls `refresh()` on `defineExpose` to refetch

- [ ] **Step 2: `src/apps/desktop/src/__tests__/MemoryDetail.spec.ts`** — minimal coverage:
  - Renders empty state when `memoryName` is null
  - Loads and renders content when `memoryName` is set (mocks `getMemoryDetail`)
  - Edit button switches to edit mode; textarea is populated; Save calls `updateMemory` and emits `memorySaved`
  - Create button switches to create mode; Create button calls `createMemory` and emits `memorySaved`
  - Delete button shows confirm modal; confirm calls `deleteMemory` and emits `memoryDeleted`
  - Validation: empty name shows error; name without `.md` shows error; name with `/` shows error

- [ ] **Step 3: Run the full suite**

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
timeout 120 bunx vitest run 2>&1 | tail -n 20
```

Both must be clean.

---

## Chunk 10: Manual end-to-end smoke test

Start `nalar` (port 8080 per the MANDATORY rule) and walk through:

- [ ] Open the app, click Settings
- [ ] Verify the Memories menu item appears under Skills
- [ ] Click Memories — should show empty list (or existing memories if you have any)
- [ ] Click "+ New Memory", enter `smoke-test.md`, enter some markdown, click Create
- [ ] Verify the new memory appears in the list
- [ ] Click on it — should show the content in view mode
- [ ] Click Edit, modify, click Save
- [ ] Verify the list re-renders with the new title (extracted from the H1)
- [ ] Click Delete, confirm
- [ ] Verify the memory is gone from the list AND from `~/.config/nalar/memories/`

```bash
ls -la ~/.config/nalar/memories/   # should NOT contain smoke-test.md
```

---

## General pitfalls to watch for

1. **`std.fmt.allocPrint` with `{s}` format specifier does NOT escape JSON special characters** (per `zig-no-default-function-parameters.md` and the `jsonEscape` memory). For HTTP responses that embed user content, use `std.json.Stringify.valueAlloc(allocator, response_struct, .{})` with a typed struct, or use the existing `jsonEscape` helper.
2. **The frontend must use `bun run build` (NOT just `bunx vitest run`)** per the project memory `desktop-typescript-bun-build-as-typecheck`. Vue 3 + strict TS will catch type errors in the new components that vitest's esbuild will silently miss.
3. **The `MemoriesSettings.vue` panel uses the OLD Skills visual style** (rounded-xl cards, gradient buttons, violet active ring). The newer `NalarSettings.vue` revamp plan (`docs/plans/2026-06-17-nalar-settings-revamp-design.md`) uses a Kanagawa Dragon refined-industrial style — this plan does NOT adopt that style. If the user wants the new style, file a follow-up plan to revamp Memories + Skills.
4. **Do not refactor `SettingsView.vue`'s existing patterns** — the project rule is surgical patches. Just add the third tab; do not "improve" the two existing tabs.
5. **Empty cwd for tests** — when testing the new HTTP handlers, pass a non-empty `environment` to the singleton (or set `HOME` in the test env). The handlers all deref `di.environment` non-null.
6. **The CRUD helpers in Chunk 1 leak no memory on error paths** — every helper uses `defer allocator.free(...)` for the joined `dir_path` and `full_path` strings, plus a `defer allocator.free(content)` inside the read helper. Verify by running the new helper tests under the leak detector (default in `zig build test`).

---

## How to verify the whole feature is done

```bash
# 1. Backend compiles + tests pass
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 20
# Expect: all tests pass (was 431, now ~448 with the ~9 new helper tests + ~8 new handler tests)

# 2. Frontend type-checks clean
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
# Expect: clean

# 3. Frontend tests pass
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 20
# Expect: 31 → 33+ tests pass (was 31, +2 new spec files)

# 4. Manual smoke (start nalar, then walk Chunk 10)
# 5. git diff --stat shows:
#    - 1 modified memories.zig (5 new helpers + 1 validator)
#    - 1 new memories_crud_test.zig (or per-handler tests)
#    - 4 new HTTP handler files
#    - 1 modified http_handlers/mod.zig (4 re-exports)
#    - 1 modified main.zig (4 route registrations)
#    - 3 new Vue components (MemoriesSettings, MemoryList, MemoryDetail)
#    - 1 modified SettingsView.vue
#    - 1 modified api/index.ts
#    - 2 new spec files
#    - 1 new plan file
#    NO new files in src/modules/agent/tools/ (deferred to a follow-up plan)
```

---

## Out of scope (for follow-up plans)

- **New agent tools (`read_memory` / `add_memory` / `edit_memory` / `remove_memory`)** — see Chunk 2 for the deferred design. The agent currently has `list_memory` only; it can read any memory via `read_file` with the path from `list_memory`. Adding the 3 missing CRUD tools is a self-contained ~400-line follow-up plan.
- **Local (cwd-scoped) memories** — the `get_local_memories_path_for_dir` helper exists; would need a `?cwd=...` query param on all 5 endpoints, plus UI to show a "Local" section in `MemoryList.vue`.
- **Markdown rendering** — currently shows content in a `<pre>`. Adding `marked` or a similar library is a separate UX decision.
- **Multi-file bulk operations** — e.g. import/export all memories as a zip.
- **Search across memory content** — would need a new backend tool + UI.
- **Apply the Kanagawa Dragon revamp style** — see design doc `2026-06-17-nalar-settings-revamp-design.md`.
