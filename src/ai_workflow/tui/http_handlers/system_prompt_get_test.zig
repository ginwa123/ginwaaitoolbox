//! Static regression checks for the `/test/system-prompt/:session_id` handler.
//!
//! Why this file exists
//! ────────────────────
//! This endpoint runs the full `buildMessages` pipeline (skills, memory,
//! activity, sub-agents, workspace context, inherited parent history) and
//! returns the resulting `role: .system` content as JSON. It is a thin
//! wrapper, so the contracts worth enforcing are:
//!
//!   1. The handler is registered in `mod.zig` and `main.zig`.
//!   2. The handler pulls the singleton for `db`/`io`.
//!   3. The handler calls `buildMessages` (the canonical prompt-builder),
//!      NOT a bespoke rebuild — otherwise it drifts from production.
//!   4. The handler validates `session_id` (400), checks session existence
//!      (404), and returns 200 with a `system_prompt` field on success.
//!   5. `getMessages` and `buildMessages` failures map to 500.
//!   6. The route path is `/test/system-prompt/:session_id`.
//!
//! Standing up a sqlite DB + migrations + `ContextIPCTui` singleton to
//! behavioural-test the handler is out of scope (matches
//! `routines_run_test.zig`, `memories_crud_test.zig`, etc.). The static
//! checks below cover the same ground for less code.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/system_prompt_get.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Contract 1: handler is exported from mod.zig ─────────────────────────

test "system_prompt_get handler is re-exported in mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "systemPromptGetHandler") == null) {
        std.debug.print(
            "\n!! {s} does not re-export `systemPromptGetHandler` !!\n" ++
                "   The handler exists but is not reachable as\n" ++
                "   `ai_mod.http_handlers.systemPromptGetHandler`. Add a\n" ++
                "   `pub const systemPromptGetHandler = @import(\"system_prompt_get.zig\").systemPromptGetHandler;`\n" ++
                "   line to mod.zig.\n",
            .{MOD_PATH},
        );
        return error.HandlerNotExported;
    }
}

// ─── Contract 2: route is registered in main.zig ──────────────────────────

test "system_prompt_get route is registered in main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "/test/system-prompt/:session_id") == null) {
        std.debug.print(
            "\n!! {s} does not register the route `/test/system-prompt/:session_id` !!\n" ++
                "   Without this line the endpoint is unreachable. Add:\n" ++
                "     try gs.router.get(\"/test/system-prompt/:session_id\", ai_mod.http_handlers.systemPromptGetHandler);\n" ++
                "   in the // testing debug section of main.zig.\n",
            .{MAIN_PATH},
        );
        return error.RouteNotRegistered;
    }

    if (std.mem.indexOf(u8, source, "ai_mod.http_handlers.systemPromptGetHandler") == null) {
        std.debug.print(
            "\n!! {s} route registration does not reference the handler !!\n",
            .{MAIN_PATH},
        );
        return error.RouteHandlerMissing;
    }
}

// ─── Contract 3: handler uses the singleton for db/io ─────────────────────

test "system_prompt_get handler gets the singleton for db and io" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "getSingleton") == null) {
        std.debug.print(
            "\n!! {s} does not call nalarcore.getSingleton() !!\n" ++
                "   The handler has no other source for the SQLite DB or Io\n" ++
                "   runtime. Add `const di = try nalarcore.getSingleton();`\n" ++
                "   and read sqlite_db/io from it.\n",
            .{HANDLER_PATH},
        );
        return error.SingletonMissing;
    }
}

// ─── Contract 4: handler delegates to buildMessages ──────────────────────

test "system_prompt_get handler delegates to buildMessages" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "buildMessages") == null) {
        std.debug.print(
            "\n!! {s} does not call buildMessages !!\n" ++
                "   The endpoint must use the same prompt-builder the\n" ++
                "   production workflow uses (`build_messages_for_agent_prompt.zig`)\n" ++
                "   — otherwise it drifts from `workflow.zig:509` and returns\n" ++
                "   a prompt the LLM never sees. Add a `buildMessages(...)` call.\n",
            .{HANDLER_PATH},
        );
        return error.BuildMessagesCallMissing;
    }

    if (std.mem.indexOf(u8, source, "../build_messages_for_agent_prompt.zig") == null) {
        std.debug.print(
            "\n!! {s} does not import from `../build_messages_for_agent_prompt.zig` !!\n" ++
                "   The handler must reach the canonical builder through its\n" ++
                "   file-relative import. Add:\n" ++
                "     const buildMessages = @import(\"../build_messages_for_agent_prompt.zig\").buildMessages;\n",
            .{HANDLER_PATH},
        );
        return error.BuildMessagesImportMissing;
    }
}

// ─── Contract 5: 400 when session_id path param is missing ───────────────

test "system_prompt_get handler returns 400 on missing session_id" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"session_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the `session_id` path param !!\n" ++
                "   Add `const session_id = req.params.get(\"session_id\") orelse \"\";`\n" ++
                "   and the `if (session_id.len == 0)` 400 branch.\n",
            .{HANDLER_PATH},
        );
        return error.SessionIdParamMissing;
    }

    if (std.mem.indexOf(u8, source, "Missing session_id") == null) {
        std.debug.print(
            "\n!! {s} does not produce a \"Missing session_id\" 400 response !!\n",
            .{HANDLER_PATH},
        );
        return error.SessionIdErrorMessageMissing;
    }
}

// ─── Contract 6: 404 when session row is missing ─────────────────────────

test "system_prompt_get handler returns 404 when session is missing" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "Session not found") == null) {
        std.debug.print(
            "\n!! {s} does not produce a \"Session not found\" 404 response !!\n" ++
                "   When `get_session` returns null, the handler must return 404.\n" ++
                "   A missing cwd cannot be guessed without losing prompt fidelity\n" ++
                "   (memory loader + workspace context both depend on it).\n",
            .{HANDLER_PATH},
        );
        return error.NotFoundMessageMissing;
    }

    if (std.mem.indexOf(u8, source, ".status_code = 404") == null) {
        std.debug.print(
            "\n!! {s} does not return `status_code = 404` !!\n",
            .{HANDLER_PATH},
        );
        return error.NotFoundStatusMissing;
    }
}

// ─── Contract 7: 200 response carries session_id + system_prompt ─────────

test "system_prompt_get handler returns system_prompt JSON on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "system_prompt") == null) {
        std.debug.print(
            "\n!! {s} does not emit a `system_prompt` field !!\n" ++
                "   The success-response struct must include\n" ++
                "   `system_prompt: []const u8` so the client can render the\n" ++
                "   rendered prompt verbatim.\n",
            .{HANDLER_PATH},
        );
        return error.SystemPromptFieldMissing;
    }

    if (std.mem.indexOf(u8, source, "valueAlloc") == null) {
        std.debug.print(
            "\n!! {s} does not use std.json.Stringify.valueAlloc for the response !!\n" ++
                "   Hand-rolled allocPrint would not JSON-escape the rendered\n" ++
                "   prompt (which contains backticks, newlines, quotes). Use\n" ++
                "   std.json.Stringify.valueAlloc with the response struct.\n",
            .{HANDLER_PATH},
        );
        return error.ValueAllocMissing;
    }
}

// ─── Contract 8: getMessages failure maps to 500 ─────────────────────────

test "system_prompt_get handler maps getMessages failure to 500" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "getMessages failed") == null) {
        std.debug.print(
            "\n!! {s} does not handle `getMessages` failure with 500 !!\n" ++
                "   `llm_history.getMessages` can fail with DB errors. The\n" ++
                "   handler must catch and return 500 rather than crash.\n",
            .{HANDLER_PATH},
        );
        return error.GetMessagesErrorMissing;
    }
}

// ─── Contract 9: buildMessages failure maps to 500 ──────────────────────

test "system_prompt_get handler maps buildMessages failure to 500" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "buildMessages failed") == null) {
        std.debug.print(
            "\n!! {s} does not handle `buildMessages` failure with 500 !!\n" ++
                "   `buildMessages` can fail on DB / IO / inherited-context\n" ++
                "   errors. The handler must catch and return 500.\n",
            .{HANDLER_PATH},
        );
        return error.BuildMessagesErrorMissing;
    }
}

// ─── Contract 10: handler frees the messages slice ───────────────────────

test "system_prompt_get handler frees the AgentMessage slice" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // `buildMessages` returns `[]agent.AgentMessage` whose elements
    // each own strings/arrays (content, tool_calls, content_parts, ...).
    // The handler must deinit each message AND free the slice itself.
    if (std.mem.indexOf(u8, source, "msg.deinit") == null) {
        std.debug.print(
            "\n!! {s} does not call `.deinit` on AgentMessages !!\n" ++
                "   `buildMessages` returns `[]agent.AgentMessage`. Each message\n" ++
                "   owns allocated fields (content, tool_calls, ...). The handler\n" ++
                "   must call `msg.deinit(allocator)` per element to avoid leaks.\n",
            .{HANDLER_PATH},
        );
        return error.MessageDeinitMissing;
    }

    if (std.mem.indexOf(u8, source, "allocator.free(messages)") == null) {
        std.debug.print(
            "\n!! {s} does not `allocator.free(messages)` after deinit !!\n" ++
                "   The slice itself was allocated by `buildMessages.toOwnedSlice`.\n" ++
                "   Free the backing memory after per-element deinit.\n",
            .{HANDLER_PATH},
        );
        return error.MessagesSliceFreeMissing;
    }
}

// ─── Contract 11: response struct has the right shape ────────────────────

test "system_prompt_get handler response struct has session_id + system_prompt + size_bytes" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    const fields = [_][]const u8{
        "session_id: []const u8",
        "system_prompt: []const u8",
        "size_bytes: u32",
    };
    for (fields) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print(
                "\n!! {s} response struct is missing field `{s}` !!\n" ++
                    "   The JSON shape must stay with exactly these three fields\n" ++
                    "   (session_id, system_prompt, size_bytes) so the client\n" ++
                    "   can rely on it.\n",
                .{ HANDLER_PATH, needle },
            );
            return error.ResponseShapeMissing;
        }
    }
}