//! Static regression checks for the `POST /workspaces/:wsId/items/agent`
//! handler (`workspace_items_create_agent.zig`).
//!
//! Why this file exists
//! ────────────────────
//! Agent Mode (plan `2026-08-15-agent-mode.md`) introduces a new
//! `item_type='agent'` workspace item with a 1-1 sibling row in the
//! `agents` table. The create handler is a thin wrapper that:
//!   1. Parses `{name, path}` from the JSON body via `parseFromSliceLeaky`.
//!   2. Generates a unique `item_<unix_nanoseconds>` id.
//!   3. BEGIN TRANSACTION
//!   4. INSERTs into `workspace_items` with `item_type='agent'` and a fresh position.
//!   5. INSERTs into `agents` with the SAME id (per spec D3 — 1-1 share).
//!   6. COMMIT TRANSACTION
//!   7. Returns 201 with `{item: {...}, agent: {...}}` — the wrapped
//!      envelope the frontend's `api.createAgent` destructures.
//!
//! These contracts are enforced by static substring checks (matching
//! the project's `workspace_items_create_kanban_test.zig` /
//! `routines_run_test.zig` pattern), not by spinning up an in-memory DB.
//! The static checks below directly test the bug — they fail if and
//! only if the create plumbing is removed or routed back to the generic
//! `item_type='folder'` path.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/workspace_items_create_agent.zig";

/// Read a source file from disk, relative to the project root.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "create_agent handler parses name + path from JSON body via parseFromSliceLeaky" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must use `parseFromSliceLeaky` (per-request arena
    // owns the memory; no explicit deinit needed). Both `name` and
    // `path` must be extracted from the parsed struct.
    if (std.mem.indexOf(u8, source, "parseFromSliceLeaky") == null) {
        std.debug.print(
            "\n!! {s} does not use parseFromSliceLeaky !!\n" ++
                "   The create-body contract is broken.\n" ++
                "   See docs/superpowers/plans/2026-08-15-agent-mode.md.\n",
            .{HANDLER_PATH},
        );
        return error.ParseFromSliceLeakyMissing;
    }

    if (std.mem.indexOf(u8, source, ".name") == null) {
        std.debug.print("\n!! {s} does not reference .name (must extract name field) !!\n", .{HANDLER_PATH});
        return error.NameFieldMissing;
    }

    if (std.mem.indexOf(u8, source, ".path") == null) {
        std.debug.print("\n!! {s} does not reference .path (must extract path field) !!\n", .{HANDLER_PATH});
        return error.PathFieldMissing;
    }
}

test "create_agent handler uses item_type='agent' literal (NOT 'folder' / 'kanban' / 'design')" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The INSERT statement must contain the literal 'agent' for
    // item_type. Other item_type literals (folder/kanban/design) must
    // NOT appear — that's how we catch a copy-paste from another
    // create handler.
    if (std.mem.indexOf(u8, source, "'agent'") == null) {
        std.debug.print(
            "\n!! {s} does not contain item_type='agent' literal !!\n" ++
                "   The handler must INSERT into workspace_items with item_type='agent'.\n",
            .{HANDLER_PATH},
        );
        return error.AgentItemTypeMissing;
    }
    for ([_][]const u8{ "'folder'", "'kanban'", "'design'" }) |bad| {
        if (std.mem.indexOf(u8, source, bad) != null) {
            std.debug.print(
                "\n!! {s} contains the wrong item_type literal '{s}' !!\n" ++
                    "   Likely a copy-paste from another create handler.\n",
                .{HANDLER_PATH, bad},
            );
            return error.WrongItemTypeLiteral;
        }
    }
}

test "create_agent handler INSERTs into both workspace_items AND agents tables (1-1 invariant)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must INSERT into `workspace_items` AND `agents`.
    // The agents row uses the SAME id as the workspace_item (per spec
    // D3 — the agent id is the workspace_item id).
    if (std.mem.indexOf(u8, source, "INSERT INTO workspace_items") == null) {
        std.debug.print("\n!! {s} does not INSERT INTO workspace_items !!\n", .{HANDLER_PATH});
        return error.WorkspaceItemsInsertMissing;
    }
    if (std.mem.indexOf(u8, source, "INSERT INTO agents") == null) {
        std.debug.print(
            "\n!! {s} does not INSERT INTO agents !!\n" ++
                "   The handler must INSERT into the agents sibling table (1-1 invariant per spec D3).\n",
            .{HANDLER_PATH},
        );
        return error.AgentsInsertMissing;
    }
}

test "create_agent handler uses unixTimestampNanos for id generation (matches project convention)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "unixTimestampNanos") == null) {
        std.debug.print(
            "\n!! {s} does not use unixTimestampNanos for id generation !!\n" ++
                "   Project convention (workspace_items_create_kanban.zig uses the same helper).\n",
            .{HANDLER_PATH},
        );
        return error.UnixTimestampNanosMissing;
    }
}

test "create_agent handler wraps response in {item, agent} envelope (NOT flat {id, name, ...})" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The response must contain a wrapped `{item, agent}` shape (the
    // frontend's `api.createAgent` destructures both). A flat shape
    // would break the sidebar (regression pattern from
    // workspace_items_create_kanban.zig::CreateKanbanResponseFull).
    // We look for the literal "agent" inside the JSON response
    // construction. We also assert the handler does NOT use the
    // generic `CreateKanbanResponseFull` (or similar) — Agent is its
    // own shape.
    if (std.mem.indexOf(u8, source, "\"agent\"") == null and std.mem.indexOf(u8, source, "'agent'") == null) {
        std.debug.print(
            "\n!! {s} does not include 'agent' in its JSON response construction !!\n" ++
                "   The response must include the agent row alongside the item.\n",
            .{HANDLER_PATH},
        );
        return error.AgentFieldMissingInResponse;
    }
    if (std.mem.indexOf(u8, source, "CreateKanbanResponseFull") != null) {
        std.debug.print(
            "\n!! {s} uses the kanban response envelope by mistake !!\n" ++
                "   Agent has its own shape (no kanban columns, no seeded defaults).\n",
            .{HANDLER_PATH},
        );
        return error.WrongResponseEnvelope;
    }
}

test "create_agent handler does NOT call kanban_model.seedDefaultColumns (no seed data)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must NOT call kanban_model.seedDefaultColumns —
    // agents start with empty knowledge + empty tool allowlist.
    // Adding seed columns would break the runtime filter (the agent
    // would have rows in kanban_columns, but no agent row).
    if (std.mem.indexOf(u8, source, "seedDefaultColumns") != null) {
        std.debug.print(
            "\n!! {s} calls seedDefaultColumns !!\n" ++
                "   Agents do NOT seed kanban columns — they start with\n" ++
                "   empty knowledge + empty tool allowlist (secure-by-default per D1).\n",
            .{HANDLER_PATH},
        );
        return error.SeedDefaultColumnsShouldNotBeCalled;
    }
}