//! Agent memory tools: `save_memory` + `load_memory` + `delete_memory`.
//!
//! Merged from `save_memory.zig` + `load_memory.zig` + `delete_memory.zig`
//! (2026-09-11 memory-merge refactor) — one file, three tools. The public
//! surface is unchanged: `SaveMemoryInput` / `save_memory_tool` /
//! `executeSaveMemory`, `LoadMemoryInput` / `load_memory_tool` /
//! `executeLoadMemory`, `DeleteMemoryInput` / `delete_memory_tool` /
//! `executeDeleteMemory`, plus the shared `splitTagsString` helper.
//!
//! Wire shapes (unchanged):
//!   save:   input { content, tags?, id? } →
//!           <save_memory><id/><created_at/><updated_at/></save_memory>
//!           or <save_memory><error/></save_memory>
//!   load:   input { query?, id?, tags?, limit?=10, offset?=0,
//!                   with_content?=false } →
//!           <load_memory ...><count/><total_count/><results/></load_memory>
//!           or <load_memory><error/></load_memory>
//!   delete: input { id } →
//!           <delete_memory><id/><deleted>true|false</deleted></delete_memory>
//!           or <delete_memory><error/></delete_memory>

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const agent_memories = nalarcore.agent_memories;

const helpers = @import("helpers");
const xmlEscape = helpers.xml_escape;

const testing = std.testing;
const migration = @import("../../../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

// ─── save_memory ───

// Agent-callable tool: `save_memory` — UPSERT a short, structured note
// that the agent can recall later via `load_memory`.
//
// Plan: docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md (Task 3)
// Task: task_1785958319567
//
// Wire shape:
//   input:  { content: string, tags?: string, id?: string }
//   output: <save_memory><id>...</id><created_at>...</created_at>
//            <updated_at>...</updated_at></save_memory>
//   or:     <save_memory><error>...</error></save_memory>
//
// The actual INSERT OR REPLACE lives in `agent_memories.saveMemory`.
// This file is a thin XML wrapper around it (mirrors the
// `kanban_list.zig` / `search_history.zig` pattern).
//
// Design choices:
//   - Caller-provided `id` is optional. Empty → auto-generated
//     `mem_<16-hex>` (collision-free for 10K rows, opaque token).
//   - Per-row size cap is 1 MiB (rejects overflow, doesn't truncate).
//   - Tags is a SINGLE STRING on the wire (matches the schema
//     `type: "string"`). Multiple tags are joined with `||`
//     (the project convention — matches Migration 067 / 069).
//     The parser ALSO accepts `|`, `,`, and space as separators
//     for robustness — the LLM has tried all of these.
//   - Empty string → empty `tags` array (canonical "no tags" sentinel).
//
// Why `tags` is a string, not an array:
//   The LLM tool schema declares `tags: { type: "string" }`. The
//   LLM faithfully sends a string. The previous struct shape
//   (`tags: []const []const u8`) parsed as a JSON array, so
//   every string-form failed with "UnexpectedToken" (user bug,
//   session-1785986173692, 2026-08-06). The string form is also
//   simpler to reason about and matches the documented contract
//   "Joined with `||` in storage".

/// Input for `save_memory`.
pub const SaveMemoryInput = struct {
    /// The note body. 1 KiB – 1 MiB (validated by `agent_memories.saveMemory`).
    content: []const u8 = "",
    /// Optional labels as a single string. Multiple tags separated
    /// by `||` (preferred), `|`, `,`, or space. Empty string = no tags.
    /// Split at the boundary into `[]const []const u8` before passing
    /// to `agent_memories.saveMemory` (which joins with `||` for storage).
    tags: []const u8 = "",
    /// Caller-provided id slug for UPSERT. Empty → auto-generate
    /// `mem_<16-hex>`.
    id: []const u8 = "",
};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to use this tool — it explicitly
/// tells the agent that memory entries are UPSERT, FTS5-indexed,
/// global (cross-session / cross-workspace), and capped at 1 MiB.
pub const save_memory_tool_system_prompt =
    \\## Save Memory Tool — Behavior
    \\Use `save_memory` to persist a fact across sessions (FTS5).
    \\- Content must be 1 KiB–1 MiB. UPSERT by `id` (auto-generates `mem_<hex>` if omitted).
    \\- Use for user preferences, project conventions, decisions, and corrections. Call immediately when you learn a preference.
    \\
;

pub const save_memory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "save_memory",
        .description =
        \\Save (or update) a structured note that you can recall later via the `load_memory` tool. Use this to remember facts, preferences, decisions, or any short, structured context that you want to persist across sessions.
        \\
        \\This is a UPSERT: if you provide an `id` that already exists, the existing row's content and tags are replaced (the `updated_at` timestamp bumps). Omit `id` (or pass an empty string) to auto-generate a fresh `mem_<16-hex>` id.
        \\
        \\Storage: the note is stored in a global SQLite table with a FTS5 index. Searches (`load_memory`) can find it via phrase matching on the content or tags.
        \\
        \\Constraints:
        \\- `content` must be 1 KiB – 1 MiB. Empty content is rejected; oversized is rejected (no silent truncation).
        \\- `tags` are joined with `||` in storage and split on `|` at read time.
        \\- To remove an entry entirely (e.g. it is genuinely obsolete or the user asked to forget it), use `delete_memory({ id })` — but default to UPSERT-with-superseding-content unless the user explicitly asks to delete.
        \\- Global scope: memories are visible across all workspaces and sessions. There is no per-workspace filter.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "content", .type = "string", .description = "The note body. 1 KiB – 1 MiB. Required." },
                .{ .name = "tags", .type = "string", .description = "Optional labels as a single string. Multiple tags separated by `||` (preferred), e.g. 'preferences||user'. Also accepts `|`, `,`, or space as separators for robustness. Empty string = no tags." },
                .{ .name = "id", .type = "string", .description = "Optional caller-provided id slug for UPSERT. Empty string → auto-generated 'mem_<16-hex>'." },
            },
            .required = &.{"content"},
        },
        .system_prompt = save_memory_tool_system_prompt,
    },
};

/// Execute save_memory. Returns an XML string for the LLM.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn executeSaveMemory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SaveMemoryInput,
) ![]const u8 {
    // Split the wire-string tags into an array for the storage layer.
    // Empty string → empty array (canonical "no tags" sentinel).
    const tags_array = try splitTagsString(allocator, input.tags);
    defer allocator.free(tags_array);

    const row = agent_memories.saveMemory(allocator, db, .{
        .content = input.content,
        .tags = tags_array,
        .id = input.id,
    }) catch |err| {
        const msg = switch (err) {
            error.InvalidContent => "content must be non-empty (1 KiB minimum)",
            error.ContentTooLarge => "content exceeds the 1 MiB per-memory cap",
            error.RowNotFoundAfterInsert => "row missing after insert (DB inconsistency)",
            else => @errorName(err),
        };
        return saveErrorXml(allocator, msg);
    };
    defer agent_memories.freeMemoryRow(allocator, row);

    return saveSuccessXml(allocator, row);
}

/// Split a tags wire string by `||` (preferred), `|`, `,`, and space.
/// Returns an allocated array of `[]const u8` slices — caller owns the
/// array and the slices (free the array with `allocator.free()`; the
/// slices are views into the input string and don't need individual
/// frees unless they were trimmed).
///
/// The bounds are loose: `"foo, ,bar"` yields `["foo", "bar"]` (empty
/// segments skipped). Whitespace around tags is trimmed.
pub fn splitTagsString(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    // First pass: count tags (skip empty segments).
    var count: usize = 0;
    var in_segment = false;
    for (input) |c| {
        const is_sep = c == '|' or c == ',' or c == ' ';
        if (!is_sep and !in_segment) {
            count += 1;
            in_segment = true;
        } else if (is_sep) {
            in_segment = false;
        }
    }
    if (count == 0) return &.{};

    // Second pass: extract each tag (pointers into the input; bounds-check
    // ensures the input slice stays alive for the caller's use).
    var out = try allocator.alloc([]const u8, count);
    var idx: usize = 0;
    var start: ?usize = null;
    for (input, 0..) |c, i| {
        const is_sep = c == '|' or c == ',' or c == ' ';
        if (is_sep) {
            if (start) |s| {
                out[idx] = trimWhitespace(input[s..i]);
                idx += 1;
                start = null;
            }
        } else if (start == null) {
            start = i;
        }
    }
    if (start) |s| {
        out[idx] = trimWhitespace(input[s..]);
    }
    return out;
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '\r')) : (start += 1) {}
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[start..end];
}

fn saveSuccessXml(allocator: std.mem.Allocator, row: agent_memories.MemoryRow) ![]u8 {
    const id_e = try xmlEscape(allocator, row.id);
    defer allocator.free(id_e);
    const created_at_e = try xmlEscape(allocator, row.created_at);
    defer allocator.free(created_at_e);
    const updated_at_e = try xmlEscape(allocator, row.updated_at);
    defer allocator.free(updated_at_e);
    return std.fmt.allocPrint(allocator, "<save_memory>" ++
        "<id>{s}</id>" ++
        "<created_at>{s}</created_at>" ++
        "<updated_at>{s}</updated_at>" ++
        "</save_memory>", .{ id_e, created_at_e, updated_at_e });
}

fn saveErrorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "<save_memory><error>{s}</error></save_memory>", .{escaped});
}

// ─── load_memory ───

// Agent-callable tool: `load_memory` — FTS5 phrase search over the
// `agent_memories` store. Backs `save_memory` (the agent saves
// notes on demand, then recalls them via this tool).
//
// Plan: docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md (Task 4)
// Task: task_1785958319567
//
// Wire shape:
//   input:  { query?: string, id?: string, tags?: string[],
//             limit?: number=10, offset?: number=0,
//             with_content?: boolean=false }
//           Either `query` or `id` must be non-empty (validated at
//           runtime — the OpenAI schema DSL has no `oneOf` for primitive
//           strings, so the validation lives in `executeLoadMemory`).
//   output: <load_memory query="..." id="..." by_id="0|1" limit="..."
//                    offset="..." with_content="0|1">
//            <count>N</count>
//            <total_count>M</total_count>
//            <results>
//              <memory id="..." tags="..." created_at="..." updated_at="...">
//                <snippet>...[match]...</snippet>
//                <content truncated="0|1">...</content> (when with_content=true,
//                                                     OR when by-id is used —
//                                                     full body, no 2 KiB cap)
//              </memory>
//              ...
//            </results>
//          </load_memory>
//   or:     <load_memory><error>...</error></load_memory>
//           Errors: "must supply either query or id" (both empty),
//                   "not found: <id>" (id given but row missing),
//                   FTS5 / DB errors.
//
// Context anti-bloat guarantees:
//   - **Snippets by default** (10-token window with [match] markers).
//     Never raw content unless with_content=true.
//   - **`with_content=true` truncates at MAX_FULL_CONTENT_BYTES (2 KiB)**.
//     Worst case: 50 rows × 2 KiB = 100 KiB. Comfortably fits the
//     LLM context budget.
//   - **limit default 10, max 50** (MAX_LIMIT). Caller's `limit`
//     higher than MAX_LIMIT is capped silently.
//
// Why `tags` is a string, not an array:
//   The LLM tool schema declares `tags: { type: "string" }`. The
//   LLM faithfully sends a string. The previous struct shape
//   (`tags: []const []const u8`) parsed as a JSON array, so
//   every string-form failed with "UnexpectedToken" (user bug,
//   session-1785986173692, 2026-08-06). Split on `||` (preferred),
//   `|`, `,`, or space at the boundary before passing to the
//   storage layer (which uses the array as individual LIKE patterns).

/// Input for `load_memory`.
pub const LoadMemoryInput = struct {
    /// FTS5 phrase search. Required when `id` is empty. Sanitized
    /// via `agent_memories.loadMemoriesByFts` (which calls
    /// `escapeFtsQuery` to strip FTS5 operators like `.`, `-`, `:`, `*`).
    query: []const u8 = "",
    /// Look up a single memory by exact id. When non-empty, FTS5 is
    /// skipped and `agent_memories.getMemoryById` does a single-row
    /// SELECT that returns the FULL content (no MAX_FULL_CONTENT_BYTES
    /// 2 KiB cap — only the storage layer's 1 MiB MAX_CONTENT_BYTES).
    /// `tags` is ignored when `id` is set (only 1 row can match).
    /// Either `query` or `id` must be non-empty — supplying both is OK
    /// (the by-id path wins).
    id: []const u8 = "",
    /// Optional AND filter as a single string. Multiple tags separated
    /// by `||` (preferred), `|`, `,`, or space. Empty string = no
    /// filter. Split at the boundary into `[]const []const u8` before
    /// passing to `agent_memories.loadMemoriesByFts`. Ignored when `id`
    /// is set.
    tags: []const u8 = "",
    /// Max rows to return. Default 10, hard cap MAX_LIMIT (50).
    limit: u32 = 10,
    /// Skip the first N rows. Default 0.
    offset: u32 = 0,
    /// When true, include the full content of each FTS hit (truncated
    /// to MAX_FULL_CONTENT_BYTES per row). When false (default),
    /// only the snippet is included — protects the LLM context
    /// budget. Ignored in the by-id path (content is always full).
    with_content: bool = false,
};

/// Hard cap on the per-row content when `with_content=true`. 2 KiB
/// matches the snippet length used by `search_history` (16 KiB is too
/// large for a memory-note preview; 2 KiB is enough to see context
/// around the matched phrase).
pub const MAX_FULL_CONTENT_BYTES: u32 = 2 * 1024;

/// Hard cap on the result set size. Caller's `limit` is silently
/// capped to this value. 50 rows × 120-char snippets = ~6 KiB
/// (snippet-only) or 50 × 2 KiB = 100 KiB worst case (with_content).
pub const MAX_LIMIT: u32 = 50;

/// Top-level tool definition for the LLM.
pub const load_memory_tool_system_prompt =
    \\## Memory Tools — save_memory / load_memory / delete_memory
    \\SQLite FTS5, cross-session. **Mandatory, not optional.** Skipping `load_memory`
    \\when prior context exists, or skipping `save_memory` when a fact should
    \\persist, counts as a task failure.
    \\
    \\These are AGENT-managed notes — distinct from the curated `.md` files in
    \\`~/.config/nalar/memories/` (auto-injected as `## Global Knowledge`).
    \\- `save_memory` → short structured facts you'd otherwise re-ask or re-derive.
    \\- `.md` files → hand-curated insights (architecture notes, conventions). Not
    \\  written by these tools; edit directly if that's the surface you need.
    \\
    \\### Reference
    \\
    \\| Tool | Signature | Behavior |
    \\|---|---|---|
    \\| `save_memory` | `{ content, tags?, id? }` | UPSERT by `id`. No `id` (or `""`) → auto-generates `mem_<16-hex>`. Stable slug `id` → updates that row. `content`: 1 KiB–1 MiB (empty/oversized = rejected, never silently truncated). |
    \\| `load_memory` | `{ query, tags?, limit?, offset?, with_content? }` | FTS5 phrase search over `content` + `tags`. Returns ranked hits with `<snippet>`. `with_content=true` → full body, capped 2 KiB/row. `limit` default 10, max 50. Paginate with `<total_count>` + `offset`. |
    \\| `delete_memory` | `{ id }` | Permanent, no undo. Unknown `id` → `<deleted>false</deleted>` (idempotent, not an error). Empty `id` → `<error>`. |
    \\
    \\**Deletion policy:** prefer `save_memory` overwrite to `delete_memory`. Never
    \\delete a user-preference memory unless the user explicitly asks for it.
    \\
    \\### Wire format
    \\- `tags`: **one string**, not an array. Separator preference order: `||` >
    \\  `|` > `,` > space. Example: `tags: "dark-mode||preferences"`.
    \\- `id`: opaque. Either `mem_<16-hex>` (auto) or a caller-chosen slug (e.g.
    \\  `"user-pref-theme"`). Never parse or construct it manually beyond passing a
    \\  slug through.
    \\- FTS query: pass plain text. `.`, `-`, `:` etc. are auto-sanitized/stripped;
    \\  multi-word queries are OR-joined automatically. Do not pre-escape.
    \\
    \\### When to call `load_memory` (before proceeding)
    \\1. First user message of a session — before anything else.
    \\2. User says "do you remember…" / "last time we…" — never guess or fabricate
    \\   an answer to this; the tool call is the only acceptable source.
    \\3. Before re-deriving any fact you could plausibly have already verified
    \\   (a build command, a config value, a prior decision).
    \\4. On entry to any long-running or recurring project.
    \\
    \\### When to call `save_memory` (immediately, not batched for later)
    \\- A user preference is stated (theme, model, language, working hours, profile).
    \\- A project convention is established (build/test/deploy commands, code style).
    \\- A decision is made worth surviving the session.
    \\- A lookup key is defined (model aliases, session_id conventions, board/column
    \\  mappings).
    \\- The user corrects you — **even a single correction, save it immediately.**
    \\- You just re-derived a fact that `load_memory` should have returned — save it
    \\  so the next session doesn't redo the work.
    \\
    \\### Blocking gate (apply before every response)
    \\- About to ask the user something they may have already told you? → `load_memory` first, not a question.
    \\- About to re-derive a fact that could be stored? → `load_memory` first.
    \\- Just learned a preference/convention/correction? → `save_memory` now.
    \\- Is this the first turn of the session? → confirm `load_memory` already ran.
    \\
    \\These four checks are blocking preconditions, not suggestions — do not send a
    \\response that skips a check it should have passed.
    \\
    \\### Examples
    \\- ✅ User: "use pnpm not npm" → immediately `save_memory({ content: "Project uses pnpm, not npm, for all installs/scripts.", tags: "convention||tooling" })`.
    \\- ✅ Session start → `load_memory({ query: "project setup conventions" })` before reading any files.
    \\- ❌ Agent re-asks "which package manager do you use?" after the user already stated it in an earlier session → gate violation; should have called `load_memory` first.
    \\- ❌ Agent discovers the deploy command by trial-and-error but never calls `save_memory` → next session repeats the discovery; gate violation.
;

pub const load_memory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "load_memory",
        .description =
        \\Search your saved notes (from `save_memory`) using SQLite FTS5 search. Returns ranked hits with a short `<snippet>` (10-token window with `[match]` markers) per row.
        \\
        \\BY-ID LOOKUP: pass `id="mem_xxx"` to fetch a single memory by its exact id (no FTS5, no 2 KiB snippet cap, returns the full body up to 1 MiB). When `id` is set, `tags` is ignored. Either `query` or `id` must be non-empty — supplying both is allowed (by-id wins).
        \\
        \\Context anti-bloat: by default, only `<snippet>` is returned — NOT the raw content. Pass `with_content=true` when you need the full body of a hit (capped at 2 KiB per row). The default `limit` is 10 (hard cap 50), so the worst-case response is ~6 KiB snippets-only or ~100 KiB with content. The by-id path always returns full content.
        \\
        \\MULTI-WORD QUERIES ARE JOINED WITH OR. `query="preferred model"` matches memories that mention EITHER "preferred" OR "model" (not just memories with the literal substring "preferred model"). This is the natural recall semantics — for a more precise search, use a single keyword. The query matches against both the content AND the tags column.
        \\
        \\FTS5 QUERY SANITIZATION: queries with `.`, `-`, `:`, `*`, `^`, `(`, `)`, `"`, `+` are auto-sanitized — so you can write "handle_tool.zig" or "2026-08-06" without crashes. FTS5's default tokenizer splits on those characters like the indexer did.
        \\
        \\Tags filter: AND semantics. Every tag in the `tags` array must be present in the row's tags (substring match). Empty `tags` = no filter. Ignored when `id` is set.
        \\
        \\Pagination: use `offset` to walk through more results. The `<total_count>` field tells you how many total matches exist.
        \\
        \\Example: {"query": "preferred model", "tags": "user"} — finds memories about either preference OR model.
        \\Example: {"query": "AGENTS.md", "limit": 3}
        \\Example: {"query": "dark mode", "with_content": true}
        \\Example: {"id": "user-dark-mode"} — fetch a specific memory's full body, no FTS.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "query", .type = "string", .description = "FTS5 search keywords. Required when `id` is empty. Auto-sanitized (FTS5 operators stripped); multi-word queries are joined with OR for natural recall." },
                .{ .name = "id", .type = "string", .description = "Look up a single memory by exact id (e.g. 'mem_aabbcc...' or a user-supplied slug). When non-empty, FTS5 is skipped and the full body is included (no 2 KiB cap). When set, `tags` is ignored." },
                .{ .name = "tags", .type = "string", .description = "Optional AND filter as a single string. Multiple tags separated by `||` (preferred), e.g. 'preferences||user'. Also accepts `|`, `,`, or space as separators. Empty string = no filter. Ignored when `id` is set." },
                .{ .name = "limit", .type = "number", .description = "Max rows to return. Default 10, hard cap 50." },
                .{ .name = "offset", .type = "number", .description = "Skip the first N results. Default 0. Use <total_count> to know when to stop." },
                .{ .name = "with_content", .type = "boolean", .description = "Include truncated full content (max 2 KiB per row) for FTS hits. Default false (snippet-only — anti-bloat). Ignored when `id` is set (by-id always returns full content)." },
            },
            // `query` was previously the only required field. With the
            // 2026-08-19 by-id addition, EITHER `query` OR `id` must be
            // supplied — but the OpenAI tool-schema DSL has no `oneOf`
            // for primitive strings, so the validation moves to
            // `executeLoadMemory` (returns <error> when both are empty).
            .required = &.{},
        },
        .system_prompt = load_memory_tool_system_prompt,
    },
};

/// Execute load_memory. Returns an XML string for the LLM.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
///
/// Branches on `input.id`:
///   - When `id` is non-empty: bypass FTS5, call
///     `agent_memories.getMemoryById`, return a single-row
///     `<results>` response with the FULL content (no
///     MAX_FULL_CONTENT_BYTES 2 KiB cap). Not-found → `<error>`.
///   - When `id` is empty: run the existing FTS5 path.
pub fn executeLoadMemory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: LoadMemoryInput,
) ![]const u8 {
    // Either id OR query must be non-empty. The OpenAI tool-schema DSL
    // can't express "oneOf: query OR id" for primitive strings, so the
    // validation lives here.
    if (input.id.len == 0 and input.query.len == 0) {
        return loadErrorXml(allocator, "must supply either query or id");
    }

    // By-id path: skip FTS5 entirely. Storage layer's `getMemoryById`
    // returns the FULL content (up to 1 MiB) — no MAX_FULL_CONTENT_BYTES
    // 2 KiB cap. `tags` is ignored (only 1 row can match).
    if (input.id.len > 0) {
        return executeById(allocator, db, input);
    }

    // FTS5 path (unchanged from the 2026-08-06 implementation).
    const effective_limit = @min(input.limit, MAX_LIMIT);

    // Split the wire-string tags into an array for the storage layer.
    // Empty string → empty array (canonical "no filter" sentinel).
    const tags_array = try splitTagsString(allocator, input.tags);
    defer allocator.free(tags_array);

    // Build hits from the FTS5 query.
    const hits = agent_memories.loadMemoriesByFts(allocator, db, .{
        .query = input.query,
        .tags = tags_array,
        .limit = effective_limit,
        .offset = input.offset,
    }) catch |err| {
        const msg = switch (err) {
            error.OutOfMemory => "out of memory",
            else => @errorName(err),
        };
        return loadErrorXml(allocator, msg);
    };
    defer agent_memories.freeMemoryHits(allocator, hits);

    // Optional: fetch full content for each hit (truncated to
    // MAX_FULL_CONTENT_BYTES). Stored in a separate parallel array so
    // we can free it independently if the XML build fails mid-way.
    var contents: ?[]?[]u8 = null;
    defer if (contents) |cs| {
        for (cs) |maybe_c| if (maybe_c) |c| allocator.free(c);
        allocator.free(cs);
    };

    if (input.with_content and hits.len > 0) {
        const cs = try allocator.alloc(?[]u8, hits.len);
        contents = cs;
        for (hits, 0..) |hit, i| {
            const row = agent_memories.getMemoryById(allocator, db, hit.id) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "getMemoryById failed: {s}", .{@errorName(err)}) catch "?";
                defer allocator.free(msg);
                return loadErrorXml(allocator, msg);
            };
            if (row) |r| {
                defer agent_memories.freeMemoryRow(allocator, r);
                const was_truncated = r.content.len > MAX_FULL_CONTENT_BYTES;
                const src: []const u8 = if (was_truncated) r.content[0..MAX_FULL_CONTENT_BYTES] else r.content;
                cs[i] = try allocator.dupe(u8, src);
            } else {
                cs[i] = null;
            }
        }
    }

    return loadSuccessXml(allocator, hits, contents, input, effective_limit);
}

/// By-id branch of `executeLoadMemory`. Single-row SELECT against
/// `agent_memories`, returns the same `<results>` shape as the FTS5
/// path (one `<memory>` entry) so the LLM only learns one XML
/// structure regardless of which branch ran.
///
/// The content is the FULL body — no MAX_FULL_CONTENT_BYTES 2 KiB cap.
/// `saveMemory` rejects content > 1 MiB at write time (storage's
/// MAX_CONTENT_BYTES), so the by-id response is bounded at 1 MiB.
fn executeById(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: LoadMemoryInput,
) ![]u8 {
    const row = agent_memories.getMemoryById(allocator, db, input.id) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "getMemoryById failed: {s}", .{@errorName(err)}) catch "?";
        defer allocator.free(msg);
        return loadErrorXml(allocator, msg);
    };

    const r = row orelse {
        const msg = std.fmt.allocPrint(allocator, "not found: {s}", .{input.id}) catch "?";
        defer allocator.free(msg);
        return loadErrorXml(allocator, msg);
    };
    defer agent_memories.freeMemoryRow(allocator, r);

    return loadSuccessByIdXml(allocator, r, input);
}

fn loadSuccessXml(
    allocator: std.mem.Allocator,
    hits: []agent_memories.MemoryHit,
    contents: ?[]?[]u8,
    input: LoadMemoryInput,
    effective_limit: u32,
) ![]u8 {
    const query_e = try xmlEscape(allocator, input.query);
    defer allocator.free(query_e);
    const with_content_str = if (input.with_content) "1" else "0";

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.print(allocator, "<load_memory query=\"{s}\" limit=\"{d}\" offset=\"{d}\" with_content=\"{s}\">\n", .{ query_e, effective_limit, input.offset, with_content_str });

    const total_count: u32 = if (hits.len > 0) hits[0].total_count else 0;
    try xml.print(allocator, "  <count>{d}</count>\n" ++
        "  <total_count>{d}</total_count>\n" ++
        "  <results>\n", .{ hits.len, total_count });

    for (hits, 0..) |hit, i| {
        const id_e = try xmlEscape(allocator, hit.id);
        defer allocator.free(id_e);
        const tags_e = try xmlEscape(allocator, hit.tags);
        defer allocator.free(tags_e);
        const snippet_e = try xmlEscape(allocator, hit.snippet);
        defer allocator.free(snippet_e);
        const created_at_e = try xmlEscape(allocator, hit.created_at);
        defer allocator.free(created_at_e);
        const updated_at_e = try xmlEscape(allocator, hit.updated_at);
        defer allocator.free(updated_at_e);

        try xml.appendSlice(allocator, "    <memory>\n");
        try xml.print(allocator, "      <id>{s}</id>\n", .{id_e});
        try xml.print(allocator, "      <tags>{s}</tags>\n", .{tags_e});
        if (hit.created_at.len > 0) {
            try xml.print(allocator, "      <created_at>{s}</created_at>\n", .{created_at_e});
        }
        if (hit.updated_at.len > 0) {
            try xml.print(allocator, "      <updated_at>{s}</updated_at>\n", .{updated_at_e});
        }
        try xml.print(allocator, "      <snippet>{s}</snippet>\n", .{snippet_e});

        // Optional <content> when with_content=true.
        if (contents) |cs| {
            if (cs[i]) |c| {
                const content_e = try xmlEscape(allocator, c);
                defer allocator.free(content_e);
                const was_truncated = c.len == MAX_FULL_CONTENT_BYTES;
                try xml.print(allocator, "      <content truncated=\"{c}\">{s}</content>\n", .{ @as(u8, if (was_truncated) '1' else '0'), content_e });
            }
        }
        try xml.appendSlice(allocator, "    </memory>\n");
    }

    try xml.appendSlice(allocator, "  </results>\n</load_memory>\n");
    return try xml.toOwnedSlice(allocator);
}

/// Build the success XML for the by-id branch. Mirrors `successXml`'s
/// shape (one `<memory>` wrapped in `<results>`) so the LLM sees the
/// same XML structure regardless of which branch ran.
///
/// Differences from `successXml`:
///   - `<load_memory>` includes `id="..." by_id="1"` attribute pair.
///   - `<memory>` includes `<content>` with the FULL body
///     (no MAX_FULL_CONTENT_BYTES cap; `truncated="0"` is hardcoded
///     because `saveMemory` rejects content > 1 MiB at write time).
///   - No `<snippet>` — the by-id path is targeted, not a search hit.
fn loadSuccessByIdXml(
    allocator: std.mem.Allocator,
    row: agent_memories.MemoryRow,
    input: LoadMemoryInput,
) ![]u8 {
    const id_e = try xmlEscape(allocator, row.id);
    defer allocator.free(id_e);
    const tags_e = try xmlEscape(allocator, row.tags);
    defer allocator.free(tags_e);
    const created_at_e = try xmlEscape(allocator, row.created_at);
    defer allocator.free(created_at_e);
    const updated_at_e = try xmlEscape(allocator, row.updated_at);
    defer allocator.free(updated_at_e);
    const content_e = try xmlEscape(allocator, row.content);
    defer allocator.free(content_e);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    // <load_memory id="..." by_id="1" with_content="1"> — by-id always
    // carries full content, so the with_content attribute is "1".
    // query="", limit/offset echo the caller's input for symmetry.
    try xml.print(allocator, "<load_memory query=\"\" id=\"{s}\" by_id=\"1\" limit=\"{d}\" offset=\"{d}\" with_content=\"1\">\n", .{ id_e, input.limit, input.offset });

    try xml.appendSlice(allocator, "  <count>1</count>\n" ++
        "  <total_count>1</total_count>\n" ++
        "  <results>\n");

    try xml.appendSlice(allocator, "    <memory>\n");
    try xml.print(allocator, "      <id>{s}</id>\n", .{id_e});
    try xml.print(allocator, "      <tags>{s}</tags>\n", .{tags_e});
    if (row.created_at.len > 0) {
        try xml.print(allocator, "      <created_at>{s}</created_at>\n", .{created_at_e});
    }
    if (row.updated_at.len > 0) {
        try xml.print(allocator, "      <updated_at>{s}</updated_at>\n", .{updated_at_e});
    }
    // Full body — `saveMemory` enforces MAX_CONTENT_BYTES (1 MiB) at
    // write time, so the truncation flag is always "0" for by-id.
    try xml.print(allocator, "      <content truncated=\"0\">{s}</content>\n", .{content_e});

    try xml.appendSlice(allocator, "    </memory>\n" ++
        "  </results>\n</load_memory>\n");
    return try xml.toOwnedSlice(allocator);
}

fn loadErrorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "<load_memory><error>{s}</error></load_memory>", .{escaped});
}

// ─── delete_memory ───

// Agent-callable tool: `delete_memory` — PERMANENTLY remove one row
// from the agent_memories store by id.
//
// Plan: docs/superpowers/plans/2026-08-24-delete-memory-agent-tool.md (Task 2)
// Task: task_1787546484030_8
//
// Wire shape:
//   input:  { id: string }            (id is REQUIRED)
//   output: <delete_memory><id>...</id><deleted>true|false</deleted></delete_memory>
//   or:     <delete_memory><error>...</error></delete_memory>
//
// The actual DELETE lives in `agent_memories.deleteMemory`.
// This section is a thin XML wrapper (mirrors the `save_memory`
// section pattern).

/// Input for `delete_memory`.
pub const DeleteMemoryInput = struct {
    /// Exact memory id (mem_<16-hex> or caller-provided slug).
    /// Required. Empty string → error.
    id: []const u8 = "",
};

/// Top-level tool definition for the LLM.
pub const delete_memory_tool_system_prompt =
    \\## Delete Memory Tool — Behavior
    \\Use `delete_memory` to permanently delete a memory row by `id`.
    \\- Never delete user-preference memories unless the user explicitly asks. Prefer UPSERT with superseding content.
    \\- Unknown `id` returns `deleted=false` (idempotent).
    \\
;

pub const delete_memory_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "delete_memory",
        .description =
        \\Permanently delete ONE saved memory by its exact `id`. Use this when a note is genuinely obsolete (e.g. the user asks to forget it, or a correction invalidates the old entry entirely).
        \\
        \\**WARNING: deletion is permanent. There is no undo, no soft-delete, no recycle bin.** When in doubt, prefer overwriting the existing note via `save_memory` (UPSERT) over deleting.
        \\
        \\Wire: pass the exact `id` from a prior `save_memory`/`load_memory` call. If unsure which row to target, call `load_memory` first to find the id.
        \\
        \\Behavior:
        \\- id matches a row → row is removed (FTS5 index updates automatically), `<deleted>true</deleted>`.
        \\- id is unknown → no error, returns `<deleted>false</deleted>` (idempotent — safe to retry).
        \\- id is empty → `<error>id is required</error>`.
        \\
        \\Scope: deleting a user-preference memory is generally the WRONG action unless the user explicitly asks — the load-first rule applies. Deleting your own scratch notes (e.g. things tagged `scratch` or `temp`) is fine when no longer needed.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{ .name = "id", .type = "string", .description = "Exact memory id (mem_<16-hex> or caller-provided slug). Required." },
            },
            .required = &.{"id"},
        },
        .system_prompt = delete_memory_tool_system_prompt,
    },
};

/// Execute delete_memory. Returns an XML string for the LLM.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn executeDeleteMemory(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: DeleteMemoryInput,
) ![]const u8 {
    if (input.id.len == 0) {
        return deleteErrorXml(allocator, "id is required");
    }

    const deleted = agent_memories.deleteMemory(allocator, db, input.id) catch |err| {
        const msg = switch (err) {
            error.InvalidId => "id is required",
            else => @errorName(err),
        };
        return deleteErrorXml(allocator, msg);
    };

    return deleteSuccessXml(allocator, input.id, deleted);
}

fn deleteSuccessXml(allocator: std.mem.Allocator, id: []const u8, deleted: bool) ![]u8 {
    const id_e = try xmlEscape(allocator, id);
    defer allocator.free(id_e);
    return std.fmt.allocPrint(allocator, "<delete_memory>" ++
        "<id>{s}</id>" ++
        "<deleted>{}</deleted>" ++
        "</delete_memory>", .{ id_e, deleted });
}

fn deleteErrorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "<delete_memory><error>{s}</error></delete_memory>", .{escaped});
}

// ─── tests: save_memory ───

test "save_memory_tool: tool name is 'save_memory'" {
    const tool = save_memory_tool;
    try testing.expectEqualStrings("save_memory", tool.function.name);
}

test "save_memory_tool: parameters include content, tags, id" {
    const tool = save_memory_tool;
    var found_content = false;
    var found_tags = false;
    var found_id = false;
    for (tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "content")) found_content = true;
        if (std.mem.eql(u8, prop.name, "tags")) found_tags = true;
        if (std.mem.eql(u8, prop.name, "id")) found_id = true;
    }
    try testing.expect(found_content);
    try testing.expect(found_tags);
    try testing.expect(found_id);
}

test "save_memory_tool: returns success XML envelope on insert" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "user prefers dark mode",
        .tags = "preferences",
        .id = "user-dark-mode",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // Returns <save_memory> envelope on success.
    try testing.expect(std.mem.indexOf(u8, out, "<save_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "</save_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>user-dark-mode</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<created_at>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<updated_at>") != null);
    // No error envelope.
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
}

test "save_memory_tool: returns error XML on empty content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "",
        .tags = "",
        .id = "should-not-save",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "empty") != null or
        std.mem.indexOf(u8, out, "InvalidContent") != null);
}

test "save_memory_tool: returns error XML on content > 1 MiB" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Allocate 1 MiB + 1 byte of garbage.
    const oversize = alloc.alloc(u8, (1 << 20) + 1) catch unreachable;
    defer alloc.free(oversize);
    @memset(oversize, 'x');

    const input = SaveMemoryInput{
        .content = oversize,
        .tags = "",
        .id = "oversize-memory",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") != null);
}

test "save_memory_tool: UPSERTs on second call with same id (updated_at bumps)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input1 = SaveMemoryInput{
        .content = "original content",
        .tags = "preferences",
        .id = "user-preference",
    };
    const out1 = try executeSaveMemory(alloc, &ctx.db, input1);
    defer alloc.free(out1);

    // Extract updated_at from the first response.
    const updated_at_open = std.mem.indexOf(u8, out1, "<updated_at>") orelse return error.MissingUpdatedAt;
    const updated_at_close = std.mem.indexOf(u8, out1, "</updated_at>") orelse return error.MissingUpdatedAtClose;
    const first_updated_at = out1[updated_at_open + "<updated_at>".len .. updated_at_close];
    try testing.expect(first_updated_at.len > 0);

    // Sleep 1 second so the UPDATE bumps the timestamp (DATETIME resolution).
    // Use a portable helper because std.c.timespec is broken on Windows
    // (Zig 0.16 — see ../../../agentic_loop/test_sleep.zig).
    const test_sleep = @import("../../../agentic_loop/test_sleep.zig");
    test_sleep.sleep(1, 0);

    const input2 = SaveMemoryInput{
        .content = "updated content",
        .tags = "preferences||updated",
        .id = "user-preference",
    };
    const out2 = try executeSaveMemory(alloc, &ctx.db, input2);
    defer alloc.free(out2);

    // Same id.
    try testing.expect(std.mem.indexOf(u8, out2, "<id>user-preference</id>") != null);
    // Content replaced.
    try testing.expect(std.mem.indexOf(u8, out2, "<error>") == null);

    // Only ONE row in the DB (UPSERT, not INSERT-OR-APPEND).
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_memories WHERE id = ?", &.{"user-preference"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "save_memory_tool: auto-generates mem_<16-hex> id when none provided" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "auto-generated memory",
        .tags = "",
        .id = "",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // Extract the auto-generated id.
    const id_open = std.mem.indexOf(u8, out, "<id>") orelse return error.MissingId;
    const id_close = std.mem.indexOf(u8, out, "</id>") orelse return error.MissingIdClose;
    const generated_id = out[id_open + "<id>".len .. id_close];

    // Format: mem_<16 hex chars>.
    try testing.expectEqual(@as(usize, 4 + 16), generated_id.len);
    try testing.expect(std.mem.startsWith(u8, generated_id, "mem_"));
    for (generated_id[4..]) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(is_hex);
    }
}

test "save_memory_tool: round-trips tag list through storage" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "memory with multiple tags",
        .tags = "alpha||beta||gamma",
        .id = "tagged-memory",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // Verify tags are stored as ||-joined string.
    var q = try ctx.db.query(alloc, "SELECT tags FROM agent_memories WHERE id = ?", &.{"tagged-memory"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("alpha||beta||gamma", row.values[0]);
}

// -----------------------------------------------------------------------
// REGRESSION: tags as a single STRING (the new wire format, 2026-08-06)
//
// The LLM tool schema declares `tags` as a string. The LLM faithfully
// sends it as a string (e.g. "demo|tool-test|nalar"). The parser
// previously expected tags as `[]const []const u8` (JSON array), so
// every string-form failed with "UnexpectedToken". The fix accepts
// the string form: split on `||` at the boundary, pass array to
// `agent_memories.saveMemory`.
// -----------------------------------------------------------------------
test "save_memory_tool: tags wire format is a string (parses without UnexpectedToken)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // EXACT shape the LLM produced in session-1785986173692 (the bug).
    // tags is a STRING with `|` separator.
    const llm_arguments =
        \\{"content":"Demo note","tags":"demo|tool-test|nalar","id":"test-bug-string"}
    ;

    const parsed = std.json.parseFromSlice(
        SaveMemoryInput,
        alloc,
        llm_arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        std.debug.print("UNEXPECTED parse failure: {s}\n", .{@errorName(err)});
        return err;
    };
    defer parsed.deinit();

    // The parser must succeed without "UnexpectedToken".
    try testing.expect(parsed.value.content.len > 0);
    try testing.expectEqualStrings("test-bug-string", parsed.value.id);
    try testing.expectEqualStrings("demo|tool-test|nalar", parsed.value.tags);

    // The string form must be passed through to storage correctly
    // (split on || at the wire boundary, joined back to || in DB).
    const out = try executeSaveMemory(alloc, &ctx.db, parsed.value);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);

    var q = try ctx.db.query(alloc, "SELECT tags FROM agent_memories WHERE id = ?", &.{"test-bug-string"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    // After splitTagsString + joinTags, the `|` separator is normalized
    // to `||` (the documented storage convention).
    try testing.expectEqualStrings("demo||tool-test||nalar", row.values[0]);
}

test "save_memory_tool: single tag (no separator) round-trips" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "single tag",
        .tags = "demo",
        .id = "single-tag-memory",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);

    var q = try ctx.db.query(alloc, "SELECT tags FROM agent_memories WHERE id = ?", &.{"single-tag-memory"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("demo", row.values[0]);
}

test "save_memory_tool: empty tags string saves empty tags" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = SaveMemoryInput{
        .content = "no tags",
        .tags = "",
        .id = "no-tags-memory",
    };
    const out = try executeSaveMemory(alloc, &ctx.db, input);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);

    var q = try ctx.db.query(alloc, "SELECT tags FROM agent_memories WHERE id = ?", &.{"no-tags-memory"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "save_memory_tool: splitTagsString accepts ||, |, comma, and space separators" {
    const alloc = testing.allocator;

    // || separator (the documented "join" form).
    {
        const out = try splitTagsString(alloc, "foo||bar||baz");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
        try testing.expectEqualStrings("foo", out[0]);
        try testing.expectEqualStrings("bar", out[1]);
        try testing.expectEqualStrings("baz", out[2]);
    }

    // | separator (the LLM tried this in the bug session).
    {
        const out = try splitTagsString(alloc, "demo|tool-test|nalar");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
        try testing.expectEqualStrings("demo", out[0]);
    }

    // comma separator (intuitive fallback).
    {
        const out = try splitTagsString(alloc, "foo,bar,baz");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
    }

    // space separator (also tried by the LLM).
    {
        const out = try splitTagsString(alloc, "demo tool-test nalar");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 3), out.len);
    }

    // Empty string → empty array.
    {
        const out = try splitTagsString(alloc, "");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }

    // Only separators → empty array.
    {
        const out = try splitTagsString(alloc, "||,, ,|");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }

    // Mixed separators (the LLM might mix).
    {
        const out = try splitTagsString(alloc, "foo||bar,baz qux");
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 4), out.len);
        try testing.expectEqualStrings("foo", out[0]);
        try testing.expectEqualStrings("bar", out[1]);
        try testing.expectEqualStrings("baz", out[2]);
        try testing.expectEqualStrings("qux", out[3]);
    }
}

// ─── tests: load_memory ───

test "load_memory_tool: tool name is 'load_memory'" {
    try testing.expectEqualStrings("load_memory", load_memory_tool.function.name);
}

test "load_memory_tool: parameters include query, id, tags, limit, offset, with_content" {
    var found_query = false;
    var found_id = false;
    var found_tags = false;
    var found_limit = false;
    var found_offset = false;
    var found_with_content = false;
    for (load_memory_tool.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "query")) found_query = true;
        if (std.mem.eql(u8, prop.name, "id")) found_id = true;
        if (std.mem.eql(u8, prop.name, "tags")) found_tags = true;
        if (std.mem.eql(u8, prop.name, "limit")) found_limit = true;
        if (std.mem.eql(u8, prop.name, "offset")) found_offset = true;
        if (std.mem.eql(u8, prop.name, "with_content")) found_with_content = true;
    }
    try testing.expect(found_query);
    try testing.expect(found_id);
    try testing.expect(found_tags);
    try testing.expect(found_limit);
    try testing.expect(found_offset);
    try testing.expect(found_with_content);
}

test "load_memory_tool: returns success XML envelope" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed one memory.
    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user prefers dark mode",
        .tags = "preferences",
        .id = "user-dark-mode",
    });
    defer alloc.free(_out);

    const input = LoadMemoryInput{
        .query = "dark mode",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<load_memory") != null);
    try testing.expect(std.mem.indexOf(u8, out, "</load_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>user-dark-mode</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<snippet>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[") != null); // [match] marker
    try testing.expect(std.mem.indexOf(u8, out, "<count>1</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<total_count>1</total_count>") != null);
}

test "load_memory_tool: returns error XML on empty query" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = LoadMemoryInput{
        .query = "",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") != null);
}

test "load_memory_tool: limits result count to MAX_LIMIT (50) when caller requests more" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed 60 memories that all match the query.
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        const id = std.fmt.allocPrint(alloc, "mem-cap-{d}", .{i}) catch unreachable;
        defer alloc.free(id);
        const _out = try executeSaveMemory(alloc, &ctx.db, .{
            .content = "shared memory content for cap test",
            .tags = "",
            .id = id,
        });
        defer alloc.free(_out);
    }

    // Request limit=999 — should be capped to 50.
    const input = LoadMemoryInput{
        .query = "shared",
        .tags = "",
        .limit = 999,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // Verify <count>50</count> appears (the cap).
    try testing.expect(std.mem.indexOf(u8, out, "<count>50</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<total_count>60</total_count>") != null);
}

test "load_memory_tool: snippets contain [match] markers (FTS5 convention)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user prefers dark mode for the editor",
        .tags = "",
        .id = "mem-snippet",
    });
    defer alloc.free(_out);

    const input = LoadMemoryInput{
        .query = "dark",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // Every snippet must have [match] markers (the FTS5 convention).
    try testing.expect(std.mem.indexOf(u8, out, "<snippet>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[dark]") != null or
        std.mem.indexOf(u8, out, "[dark mode]") != null);
}

test "load_memory_tool: AND-filters by tags" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out1 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory one with model preference",
        .tags = "preferences||user",
        .id = "mem-one",
    });
    defer alloc.free(_out1);
    const _out2 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory two with project context",
        .tags = "preferences||project",
        .id = "mem-two",
    });
    defer alloc.free(_out2);
    const _out3 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory three with project context",
        .tags = "project",
        .id = "mem-three",
    });
    defer alloc.free(_out3);

    const input = LoadMemoryInput{
        .query = "context",
        .tags = "project",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // mem-two + mem-three match (both have "context" + "project" tag).
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-two</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-three</id>") != null);
    // mem-one does NOT match (no "context" in content).
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-one</id>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<count>2</count>") != null);
}

test "load_memory_tool: without with_content, snippets only (no raw <content>)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "short content for anti-bloat test",
        .tags = "",
        .id = "mem-no-content",
    });
    defer alloc.free(_out);

    const input = LoadMemoryInput{
        .query = "content",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false, // ← snippets only
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // <snippet> present, <content> NOT present.
    try testing.expect(std.mem.indexOf(u8, out, "<snippet>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<content") == null);
}

test "load_memory_tool: paginates via limit + offset" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed 5 memories that all match "pageword".
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const id = std.fmt.allocPrint(alloc, "mem-page-{d}", .{i}) catch unreachable;
        defer alloc.free(id);
        const _out = try executeSaveMemory(alloc, &ctx.db, .{
            .content = "pageword row",
            .tags = "",
            .id = id,
        });
        defer alloc.free(_out);
    }

    // Page 1: limit=3 → 3 hits.
    const out1 = try executeLoadMemory(alloc, &ctx.db, .{
        .query = "pageword",
        .tags = "",
        .limit = 3,
        .offset = 0,
        .with_content = false,
    });
    defer alloc.free(out1);
    try testing.expect(std.mem.indexOf(u8, out1, "<count>3</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out1, "<total_count>5</total_count>") != null);

    // Page 2: limit=3 offset=3 → 2 hits.
    const out2 = try executeLoadMemory(alloc, &ctx.db, .{
        .query = "pageword",
        .tags = "",
        .limit = 3,
        .offset = 3,
        .with_content = false,
    });
    defer alloc.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, "<count>2</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out2, "<total_count>5</total_count>") != null);
}

test "load_memory_tool: FTS5 query sanitization (dots, dashes, colons don't crash)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "this row contains handle_tool.zig and AGENTS.md",
        .tags = "",
        .id = "mem-special-chars",
    });
    defer alloc.free(_out);

    // Queries with FTS5-special chars must NOT crash (escapeFtsQuery
    // strips the operators and joins tokens with OR, so the FTS5 query
    // parser doesn't see `.`, `:`, `-`, etc.).
    const input = LoadMemoryInput{
        .query = "handle_tool.zig",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // No <error> — the query didn't crash. The row should be found
    // because FTS5's tokenizer splits `handle_tool.zig` (in the
    // indexed content) on the dot, and the OR-joined query asks for
    // either `handle_tool` OR `zig` — both present in the row.
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<load_memory") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-special-chars</id>") != null);
}

// --- Regression tests for the strict-search bug (task_1787050039216_3) ---
//
// Symptom: load_memory({query: "preferred model"}) returned 0 hits because
// the query was wrapped in FTS5 phrase syntax, requiring "preferred" to be
// ADJACENT to "model" in the indexed text. After the fix, multi-word queries
// are joined with OR — natural recall semantics.

test "load_memory_tool: multi-token query joins with OR (regression for strict-search bug)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed 3 memories that mention "preferred" or "model" separately,
    // but NOT the literal substring "preferred model" as adjacent text.
    const _o1 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred model is claude-sonnet",
        .tags = "",
        .id = "mem-coding-pref",
    });
    defer alloc.free(_o1);
    const _o2 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "user prefers claude-sonnet for writing tasks",
        .tags = "",
        .id = "mem-writing-pref",
    });
    defer alloc.free(_o2);
    const _o3 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the project's database model is documented in spec",
        .tags = "",
        .id = "mem-db-model",
    });
    defer alloc.free(_o3);

    // With the old phrase-wrap behavior, this query would return 0 hits
    // because no memory contains the literal substring "preferred model".
    // With the new OR-join behavior, this query should find all 3.
    const input = LoadMemoryInput{
        .query = "preferred model",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    // No error, no crash.
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);

    // All 3 memories should be found (each contains at least one of the
    // two tokens).
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-coding-pref</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-writing-pref</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-db-model</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<count>3</count>") != null);
}

test "load_memory_tool: single-token query still works (regression guard)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _o1 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user prefers dark mode for the editor",
        .tags = "",
        .id = "mem-dark-mode",
    });
    defer alloc.free(_o1);

    const input = LoadMemoryInput{
        .query = "dark",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-dark-mode</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<count>1</count>") != null);
}

test "load_memory_tool: hyphenated date query returns sanitized recall (no crash)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Memory contains a date that the user might search for verbatim.
    const _o1 = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "log entry on 2026-08-06 says the build is green",
        .tags = "",
        .id = "mem-date-row",
    });
    defer alloc.free(_o1);

    // The old phrase-wrap behavior turned this into "2026 08 06" (phrase).
    // The new OR-join behavior turns it into "2026 OR 08 OR 06". Both
    // find the row — but we just want to verify no crash and at least
    // 1 hit.
    const input = LoadMemoryInput{
        .query = "2026-08-06",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-date-row</id>") != null);
}

test "load_memory_tool: empty-after-sanitize query returns empty results (no crash)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // A query of only FTS5 operators sanitizes to empty string. The
    // load_memories helper now guards against FTS5's "empty query"
    // error and returns 0 hits instead of crashing.
    const input = LoadMemoryInput{
        .query = "+++--",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<count>0</count>") != null);
}

// ─── by-id lookup (Task 1 of 2026-08-19-load-memory-by-id) ──────────────
//
// Adds an `id` parameter to `load_memory` so the LLM can fetch a
// specific memory's FULL body (no 2 KiB cap) without running an FTS5
// query. Wire contract:
//   - When `id` is non-empty, FTS5 is skipped — `agent_memories.getMemoryById`
//     does a single-row SELECT and returns the full content (up to 1 MiB).
//   - When `id` is empty, the FTS5 path runs as before (no behaviour change).
//   - When both `id` and `query` are empty → `<error>must supply either
//     query or id</error>`.
//   - When `id` is non-empty but no row exists → `<error>not found: <id></error>`.
//   - `tags` is ignored when `id` is set (only 1 row can match anyway).

test "load_memory_tool: by-id lookup returns single row with full content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "the user's preferred model is claude-sonnet",
        .tags = "preferences||user",
        .id = "mem-coding-pref",
    });
    defer alloc.free(_out);

    // id-only, with_content defaults to false — content still comes back
    // because the by-id path is targeted (not an FTS snippet).
    const input = LoadMemoryInput{
        .query = "",
        .id = "mem-coding-pref",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<load_memory") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-coding-pref</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<tags>preferences||user</tags>") != null);
    // Full body, not just a 10-token snippet.
    try testing.expect(std.mem.indexOf(u8, out, "preferred model is claude-sonnet") != null);
    // Wrapped in <results> for shape consistency with the FTS path.
    try testing.expect(std.mem.indexOf(u8, out, "<count>1</count>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<total_count>1</total_count>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<results>") != null);
}

test "load_memory_tool: by-id lookup returns content beyond 2 KiB (no MAX_FULL_CONTENT_BYTES cap)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed a memory with content > 2 KiB so the FTS5 + with_content=true
    // path would truncate at MAX_FULL_CONTENT_BYTES (2 KiB). The by-id
    // path must return the FULL body.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(alloc);
    const filler = "lorem ipsum dolor sit amet consectetur adipiscing elit ";
    var i: u32 = 0;
    while (big.items.len < 4096) : (i += 1) {
        try big.print(alloc, "{s}", .{filler});
    }
    try big.appendSlice(alloc, "DISTINCT_TAIL_TOKEN_AFTER_2KIB_MARK");

    const _out = try executeSaveMemory(alloc, &ctx.db, .{
        .content = big.items,
        .tags = "",
        .id = "mem-big-content",
    });
    defer alloc.free(_out);

    const input = LoadMemoryInput{
        .query = "",
        .id = "mem-big-content",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") == null);
    // Tail marker is well past the 2 KiB cutoff — only reachable if the
    // by-id path bypasses MAX_FULL_CONTENT_BYTES.
    try testing.expect(std.mem.indexOf(u8, out, "DISTINCT_TAIL_TOKEN_AFTER_2KIB_MARK") != null);
    // No <content truncated="1"> flag — content is not truncated.
    try testing.expect(std.mem.indexOf(u8, out, "<content truncated=\"1\">") == null);
}

test "load_memory_tool: by-id lookup returns error when id not found" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = LoadMemoryInput{
        .query = "",
        .id = "mem-does-not-exist",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "not found") != null);
    // No empty <results> — error shape only.
    try testing.expect(std.mem.indexOf(u8, out, "<results>") == null);
}

test "load_memory_tool: empty id + empty query returns error" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const input = LoadMemoryInput{
        .query = "",
        .id = "",
        .tags = "",
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "must supply either query or id") != null);
}

test "load_memory_tool: by-id ignores tags (only one row can match anyway)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed two memories — the by-id lookup must return only the one
    // with the matching id, regardless of the tags filter.
    const _a = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory alpha",
        .tags = "alpha",
        .id = "mem-alpha",
    });
    defer alloc.free(_a);
    const _b = try executeSaveMemory(alloc, &ctx.db, .{
        .content = "memory beta",
        .tags = "beta",
        .id = "mem-beta",
    });
    defer alloc.free(_b);

    const input = LoadMemoryInput{
        .query = "",
        .id = "mem-alpha",
        .tags = "beta", // intentionally wrong tag — must be ignored
        .limit = 10,
        .offset = 0,
        .with_content = false,
    };
    const out = try executeLoadMemory(alloc, &ctx.db, input);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-alpha</id>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<id>mem-beta</id>") == null);
}

// ─── tests: delete_memory ───

test "delete_memory_tool: tool name is 'delete_memory'" {
    const tool = delete_memory_tool;
    try testing.expectEqualStrings("function", tool.type);
    try testing.expectEqualStrings("delete_memory", tool.function.name);
}

test "delete_memory_tool: parameters include only id, which is required" {
    const tool = delete_memory_tool;
    const params = tool.function.parameters;
    try testing.expectEqualStrings("object", params.type);
    try testing.expectEqual(@as(usize, 1), params.properties.len);
    try testing.expectEqualStrings("id", params.properties[0].name);
    try testing.expectEqualStrings("string", params.properties[0].type);
    try testing.expectEqual(@as(usize, 1), params.required.len);
    try testing.expectEqualStrings("id", params.required[0]);
}

test "delete_memory_tool: returns success envelope with deleted=true on existing row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "row to be deleted",
        .tags = &.{},
        .id = "to-delete",
    });
    defer agent_memories.freeMemoryRow(alloc, row);

    const xml = try executeDeleteMemory(alloc, &ctx.db, .{ .id = "to-delete" });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<delete_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>to-delete</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<deleted>true</deleted>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);
}

test "delete_memory_tool: returns success envelope with deleted=false on unknown id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const xml = try executeDeleteMemory(alloc, &ctx.db, .{ .id = "ghost" });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<delete_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<id>ghost</id>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<deleted>false</deleted>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") == null);
}

test "delete_memory_tool: returns error envelope on empty id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const xml = try executeDeleteMemory(alloc, &ctx.db, .{ .id = "" });
    defer alloc.free(xml);

    try testing.expect(std.mem.indexOf(u8, xml, "<delete_memory>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<deleted>") == null);
}

test "delete_memory_tool: round-trip — deleted row is gone from getMemoryById" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const row = try agent_memories.saveMemory(alloc, &ctx.db, .{
        .content = "round-trip target",
        .tags = &.{"test"},
        .id = "rt-target",
    });
    defer agent_memories.freeMemoryRow(alloc, row);

    const before = (try agent_memories.getMemoryById(alloc, &ctx.db, "rt-target")) orelse return error.RowMissingBeforeDelete;
    defer agent_memories.freeMemoryRow(alloc, before);

    const xml = try executeDeleteMemory(alloc, &ctx.db, .{ .id = "rt-target" });
    defer alloc.free(xml);
    try testing.expect(std.mem.indexOf(u8, xml, "<deleted>true</deleted>") != null);

    const after = try agent_memories.getMemoryById(alloc, &ctx.db, "rt-target");
    try testing.expect(after == null);
}
