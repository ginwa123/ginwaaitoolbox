//! Agent-callable tool: `load_memory` — FTS5 phrase search over the
//! `agent_memories` store. Backs `save_memory` (the agent saves
//! notes on demand, then recalls them via this tool).
//!
//! Plan: docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md (Task 4)
//! Task: task_1785958319567
//!
//! Wire shape:
//!   input:  { query?: string, id?: string, tags?: string[],
//!             limit?: number=10, offset?: number=0,
//!             with_content?: boolean=false }
//!           Either `query` or `id` must be non-empty (validated at
//!           runtime — the OpenAI schema DSL has no `oneOf` for primitive
//!           strings, so the validation lives in `executeLoadMemory`).
//!   output: <load_memory query="..." id="..." by_id="0|1" limit="..."
//!                    offset="..." with_content="0|1">
//!            <count>N</count>
//!            <total_count>M</total_count>
//!            <results>
//!              <memory id="..." tags="..." created_at="..." updated_at="...">
//!                <snippet>...[match]...</snippet>
//!                <content truncated="0|1">...</content> (when with_content=true,
//!                                                     OR when by-id is used —
//!                                                     full body, no 2 KiB cap)
//!              </memory>
//!              ...
//!            </results>
//!          </load_memory>
//!   or:     <load_memory><error>...</error></load_memory>
//!           Errors: "must supply either query or id" (both empty),
//!                   "not found: <id>" (id given but row missing),
//!                   FTS5 / DB errors.
//!
//! Context anti-bloat guarantees:
//!   - **Snippets by default** (10-token window with [match] markers).
//!     Never raw content unless with_content=true.
//!   - **`with_content=true` truncates at MAX_FULL_CONTENT_BYTES (2 KiB)**.
//!     Worst case: 50 rows × 2 KiB = 100 KiB. Comfortably fits the
//!     LLM context budget.
//!   - **limit default 10, max 50** (MAX_LIMIT). Caller's `limit`
//!     higher than MAX_LIMIT is capped silently.
//!
//! Why `tags` is a string, not an array:
//!   The LLM tool schema declares `tags: { type: "string" }`. The
//!   LLM faithfully sends a string. The previous struct shape
//!   (`tags: []const []const u8`) parsed as a JSON array, so
//!   every string-form failed with "UnexpectedToken" (user bug,
//!   session-1785986173692, 2026-08-06). Split on `||` (preferred),
//!   `|`, `,`, or space at the boundary before passing to the
//!   storage layer (which uses the array as individual LIKE patterns).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const agent_memories = nalarcore.agent_memories;
const save_memory_mod = nalarcore.save_memory;

const helpers = @import("helpers");
const xmlEscape = helpers.xml_escape;

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
        return errorXml(allocator, "must supply either query or id");
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
    const tags_array = try save_memory_mod.splitTagsString(allocator, input.tags);
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
        return errorXml(allocator, msg);
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
                return errorXml(allocator, msg);
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

    return successXml(allocator, hits, contents, input, effective_limit);
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
        return errorXml(allocator, msg);
    };

    const r = row orelse {
        const msg = std.fmt.allocPrint(allocator, "not found: {s}", .{input.id}) catch "?";
        defer allocator.free(msg);
        return errorXml(allocator, msg);
    };
    defer agent_memories.freeMemoryRow(allocator, r);

    return successByIdXml(allocator, r, input);
}

fn successXml(
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

    try xml.print(allocator,
        "<load_memory query=\"{s}\" limit=\"{d}\" offset=\"{d}\" with_content=\"{s}\">\n",
        .{ query_e, effective_limit, input.offset, with_content_str });

    const total_count: u32 = if (hits.len > 0) hits[0].total_count else 0;
    try xml.print(allocator,
        "  <count>{d}</count>\n" ++
        "  <total_count>{d}</total_count>\n" ++
        "  <results>\n",
        .{ hits.len, total_count });

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
                try xml.print(allocator,
                    "      <content truncated=\"{c}\">{s}</content>\n",
                    .{ @as(u8, if (was_truncated) '1' else '0'), content_e });
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
fn successByIdXml(
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
    try xml.print(allocator,
        "<load_memory query=\"\" id=\"{s}\" by_id=\"1\" limit=\"{d}\" offset=\"{d}\" with_content=\"1\">\n",
        .{ id_e, input.limit, input.offset });

    try xml.appendSlice(allocator,
        "  <count>1</count>\n" ++
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
    try xml.print(allocator,
        "      <content truncated=\"0\">{s}</content>\n",
        .{content_e});

    try xml.appendSlice(allocator,
        "    </memory>\n" ++
        "  </results>\n</load_memory>\n");
    return try xml.toOwnedSlice(allocator);
}

fn errorXml(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    const escaped = try xmlEscape(allocator, msg);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        "<load_memory><error>{s}</error></load_memory>",
        .{escaped});
}