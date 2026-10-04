//! GET /test/system-prompt/:session_id
//!
//! Returns ONLY the system prompt that would be sent to the LLM for the
//! given session, rendered through the same `buildMessages` pipeline the
//! production workflow uses (`workflow.zig:509`). This is a debug/inspection
//! endpoint — it does NOT make any LLM call; it just runs the prompt-build
//! path and extracts the `role: .system` message.
//!
//! Why a separate endpoint (instead of reading `llm_history.response_content`):
//! `response_content` only stores the assistant's reply per turn. The actual
//! system prompt is rendered per-request from many sources (skills,
//! memories, background processes, agent content, activity, sub-agents,
//! workspace context, inherited parent history). Inspecting it requires
//! running the full `buildMessages` stack — exactly what this endpoint does.
//!
//! Response shape: `{"session_id":"...","system_prompt":"...","size_bytes":N}`.
//!
//! Errors:
//!   - 400 missing `:session_id` path param
//!   - 404 session not found in DB
//!   - 500 DB failure, buildMessages failure, JSON serialization failure
//!
//! See `src/http_handlers/session_compact.zig` for the
//! closest sibling (same singleton + buildMessages pattern, but the compact
//! handler proceeds to run compaction afterwards — this one stops after
//! reading the system message).

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const llm_history = pabrikcore.llm_history;
const agent = pabrikcore.agent;
const tool_models = pabrikcore.tool_models;

const buildMessages = @import("../agentic_loop/prompts_build_messages_for_agent_prompt.zig").buildMessages;

const agentic_loop = @import("../agentic_loop/workflow.zig");
const SqliteBackend = pabrikcore.sqlite.SqliteBackend;

/// JSON response struct. `size_bytes` is the byte length of the rendered
/// `system_prompt` so callers can sanity-check they got a non-empty prompt
/// without re-counting bytes on the client.
const SystemPromptResponse = struct {
    session_id: []const u8,
    system_prompt: []const u8,
    size_bytes: u32,
};

pub fn systemPromptGetHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse "";
    if (session_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    }

    const di = try pabrikcore.getSingleton();
    const sqlite_db = di.db;
    const io = di.io;

    // Recover the working directory from the session row. A missing row
    // is a 404 — we cannot build a meaningful system prompt without a cwd
    // (the memory loader + workspace context both depend on it).
    const cwd = blk: {
        const session_row_opt = llm_history.get_session(allocator, sqlite_db, session_id) catch null;
        if (session_row_opt) |session| {
            if (session.cwd.len > 0) {
                break :blk try allocator.dupe(u8, session.cwd);
            }
        }
        break :blk null;
    };
    if (cwd == null) {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Session not found" }),
        });
    }
    const cwd_str: []const u8 = cwd.?;

    // Load the DB-stored message history (same shape `workflow.zig` uses
    // before calling buildMessages). An empty history is fine — buildMessages
    // still emits the system message alone.
    // const db_messages = llm_history.getMessages(allocator, sqlite_db, session_id) catch {
    const db_messages = agentic_loop.getLLMHistories(*SqliteBackend, .{
        .allocator = allocator,
        .db = sqlite_db,
        .session_id = session_id,
    }) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "getMessages failed" }),
        });
    };

    // Mirrors workflow.zig:509's call shape: empty parent_session_id,
    // empty inherited_context, empty activeAgentContent (which falls back
    // to BuildDynamicAgentContent — the main-agent flow's source of truth
    // via the session_agents table). This is the "what does the main
    // agent see" view.
    //
    // buildMessages' 10-arg signature (prompts_build_messages_for_agent_prompt.zig:23):
    //   1. allocator, 2. io, 3. db, 4. cwd, 5. session_id,
    //   6. parent_session_id, 7. historyMessages, 8. tools,
    //   9. inherited_context_mode, 10. activeAgentContent
    const merged_tools: []tool_models.AgentTool = &.{};
    const messages = buildMessages(
        allocator,
        io,
        sqlite_db,
        cwd_str,
        session_id,
        "",
        db_messages,
        merged_tools,
        "",
        "",
    ) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "buildMessages failed" }),
        });
    };
    defer {
        for (messages) |*msg| msg.deinit(allocator);
        allocator.free(messages);
    }

    // buildMessages always emits messages[0] as the system message (see
    // prompts_build_messages_for_agent_prompt.zig:131). Defensive: also check
    // the role so we never silently leak a different role's content.
    if (messages.len == 0 or messages[0].role != .system) {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "buildMessages returned no system message" }),
        });
    }

    const system_prompt = messages[0].content orelse "";

    const response = SystemPromptResponse{
        .session_id = session_id,
        .system_prompt = system_prompt,
        .size_bytes = @intCast(system_prompt.len),
    };
    const json_str = try std.json.Stringify.valueAlloc(allocator, response, .{});

    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}

// ===== Tests merged from system_prompt_get_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `/test/system-prompt/:session_id` handler.
// 
// Why this file exists
// ────────────────────
// This endpoint runs the full `buildMessages` pipeline (skills, memory,
// activity, sub-agents, workspace context, inherited parent history) and
// returns the resulting `role: .system` content as JSON. It is a thin
// wrapper, so the contracts worth enforcing are:
// 
//   1. The handler is registered in `mod.zig` and `main.zig`.
//   2. The handler pulls the singleton for `db`/`io`.
//   3. The handler calls `buildMessages` (the canonical prompt-builder),
//      NOT a bespoke rebuild — otherwise it drifts from production.
//   4. The handler validates `session_id` (400), checks session existence
//      (404), and returns 200 with a `system_prompt` field on success.
//   5. `getMessages` and `buildMessages` failures map to 500.
//   6. The route path is `/test/system-prompt/:session_id`.
// 
// Standing up a sqlite DB + migrations + `ContextIPCTui` singleton to
// behavioural-test the handler is out of scope (matches
// `routines_run_test.zig`, `memories_crud_test.zig`, etc.). The static
// checks below cover the same ground for less code.

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/system_prompt_get.zig";
const MOD_PATH = "src/http_handlers/mod.zig";
const MAIN_PATH = "src/http_routes.zig";

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
            "\n!! {s} does not call pabrikcore.getSingleton() !!\n" ++
                "   The handler has no other source for the SQLite DB or Io\n" ++
                "   runtime. Add `const di = try pabrikcore.getSingleton();`\n" ++
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
                "   production workflow uses (`prompts_build_messages_for_agent_prompt.zig`)\n" ++
                "   — otherwise it drifts from `workflow.zig:509` and returns\n" ++
                "   a prompt the LLM never sees. Add a `buildMessages(...)` call.\n",
            .{HANDLER_PATH},
        );
        return error.BuildMessagesCallMissing;
    }

    if (std.mem.indexOf(u8, source, "../agentic_loop/prompts_build_messages_for_agent_prompt.zig") == null) {
        std.debug.print(
            "\n!! {s} does not import from `../agentic_loop/prompts_build_messages_for_agent_prompt.zig` !!\n" ++
                "   The handler must reach the canonical builder through its\n" ++
                "   file-relative import. Add:\n" ++
                "     const buildMessages = @import(\"../agentic_loop/prompts_build_messages_for_agent_prompt.zig\").buildMessages;\n",
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
