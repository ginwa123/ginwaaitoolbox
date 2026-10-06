// Functional wire tests for the `ask_user` agent tool (Migration 088).
//
// Zig port of `tests/functional/ask_user_test.py` (same test names,
// same order).
//
// Python docstring, preserved verbatim:
//
//   """Functional wire tests for the `ask_user` agent tool (Migration 088).
//
//   Plan: docs/superpowers/plans/2026-09-16-agent-tool-ask-user.md
//
//   The design makes this feature testable WITHOUT an LLM. `ask_user` does not
//   block: it records a question, returns immediately, and the agentic loop
//   BREAKS. The human's answer rewrites that tool call's `llm_history` row in
//   place and starts a new run. So a test only has to:
//
//     1. seed the two rows the backend would have written (assistant tool_calls
//        row + the tool-result row) plus the pending question row;
//     2. POST the exact body `AskUser.vue` sends;
//     3. assert the row rewrite AND the resume.
//
//   That last one is why this file exists: the row rewrite is the model's view of
//   the answer, and `resumed:true` proves a new run was started. Neither is
//   observable from Zig unit tests.
//
//   Covers:
//     * happy path — answer recorded, tool row rewritten in place, run resumed;
//     * idempotency — a second POST is a 200, not a 4xx, and resumes once;
//     * validation — empty answer 400, unknown question 404, wrong session 403;
//     * skip — settles as `skipped` and still resumes;
//     * abandoned — a message sent instead of an answer settles the question and
//       rewrites the row, so the model never reads `pending`;
//     * the route resolves to its own handler (the route-order trap).
//   """
//
// ── PORTING NOTES ───────────────────────────────────────────────────────
// * `_connect` (Python's `sqlite3.connect`) became the `sqlite3` COMMAND-LINE
//   tool plus its `-json` output — the idiom
//   `session_human_touched_at_test.zig` established. This package declares NO
//   dependency on `pabrikcore` and links no SQLite, so a test can never "pass"
//   without crossing the wire. `requireSqlite3Cli` SKIPS (never fails) when the
//   CLI is absent or predates `-json` (SQLite 3.33).
//
// * `-json` prints ZERO BYTES for an empty result set rather than `[]`.
//   `parseSqliteJson` shims that, which matters here because several tests
//   distinguish "no row" from "a NULL column".
//
// * Every value a test reads back out of the DB is DUPPED into `gpa` and
//   returned as an owned `[]u8`: `parseFromSlice`'s default
//   `.alloc_if_needed` leaves a string that needs no escaping pointing INTO the
//   CLI's stdout buffer, which the helper frees.
//
// * `_pending_envelope` / `_tool_envelope` were `json.dumps(..., separators=
//   (",", ":"))` of a dict literal. They are `std.json.Stringify` over structs
//   here, with the field ORDER preserved so the seeded bytes match the Python's
//   byte for byte — the assertions read the row as TEXT and compare exact
//   substrings like `"status":"pending"`.
//
// * `cwd_session: "/tmp"` (Python literal) became `harnessPath(gpa, h.temp_dir,
//   &.{})`: `std.fs.path.isAbsolute("/tmp")` is FALSE on windows-2022, so a
//   hardcoded literal that is correct on Linux fails at the HTTP door there.
//
// * `_wait_for_worker` polls a WRITE-BEHIND endpoint (the resume runs in a
//   concurrent task), so the worker row lands just after the HTTP response.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

// NOTE FOR `ask_user_multi_question_test.zig`: the seeding helpers here
// (`requireSqlite3Cli`, `sqliteRun`, `sqlLit`, `firstCellString`,
// `scalarCount`, `toolEnvelopeJson`, `ToolCall`, `seedQuestion`,
// `createSession`, `postAnswer`, `AnswerBody`, `waitForWorker`, …) are
// `pub` so that file can import them instead of copying them — the Python
// original did the same (`from ask_user_test import _connect,
// _create_session, _pending_envelope, _tool_envelope`) precisely so the
// two files cannot drift.

// ============================================================================
// Helpers — sqlite3 CLI
// ============================================================================

pub fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

/// The resolved `sqlite3` CLI for the CURRENT test. Borrowed by every
/// helper below; the OWNERSHIP is the caller's (`defer gpa.free(...)`),
/// because a file-scope allocation would leak once per test under the
/// DebugAllocator. Zig's test runner is single-threaded, so one slot is
/// enough.
var sqlite_cli: []const u8 = "";

/// True iff `bin` speaks `-json` AND can load the app's schema.
///
/// TWO probes, because one is not enough. `-json` landed in SQLite 3.33
/// (2020), and FTS5 is a COMPILE option: the `sqlite3` shipped with the
/// Android SDK is 3.50 but has no FTS5, so it fails the whole suite with
/// `Error: in prepare, no such module: fts5` the moment it parses a
/// schema the server created. Probing both means a PATH that happens to
/// shadow the system sqlite3 costs nothing — the scan simply moves on to
/// the next candidate.
fn sqliteCliWorks(bin: []const u8) bool {
    const res = std.process.run(gpa, io, .{
        .argv = &.{
            bin,                                                                   "-json", ":memory:",
            "CREATE VIRTUAL TABLE zz_fts_probe USING fts5(x); SELECT 1 AS probe;",
        },
    }) catch return false;
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    const code = exitCode(res.term);
    return code != null and code.? == 0 and
        std.mem.indexOf(u8, res.stdout, "\"probe\"") != null;
}

/// Resolve a usable `sqlite3`, or SKIP.
///
/// Every `PATH` entry is tried in order (Python's `shutil.which` returned
/// only the first hit, which is the one that matters here: the FIRST
/// `sqlite3` on PATH is frequently the Android SDK's, and that build has
/// no FTS5).
pub fn requireSqlite3Cli() ![]u8 {
    const path_env = std.process.Environ.getAlloc(std.testing.environ, gpa, "PATH") catch {
        std.debug.print("PATH is unreadable; skipping DB assertions\n", .{});
        return error.SkipZigTest;
    };
    defer gpa.free(path_env);

    const exe = if (@import("builtin").os.tag == .windows) "sqlite3.exe" else "sqlite3";
    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const cand = std.fs.path.join(gpa, &.{ dir, exe }) catch continue;
        defer gpa.free(cand);
        std.Io.Dir.cwd().access(io, cand, .{ .execute = true }) catch continue;
        if (!sqliteCliWorks(cand)) continue;
        // `cand` is freed by the loop body's `defer` when this iteration
        // ends, so the global must point at the OWNED copy, not at
        // `cand` — a borrowed-into-the-global pointer reads freed memory
        // and the next `spawn` fails with FileNotFound.
        const owned = try gpa.dupe(u8, cand);
        sqlite_cli = owned;
        return owned;
    }
    std.debug.print(
        "no sqlite3 on PATH speaks -json AND has FTS5; skipping DB assertions\n",
        .{},
    );
    return error.SkipZigTest;
}

/// `sqlite3 -json` prints ZERO BYTES for an empty result set, not `[]`.
pub fn parseSqliteJson(out: []const u8) !std.json.Parsed(std.json.Value) {
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) {
        return std.json.parseFromSlice(std.json.Value, gpa, "[]", .{});
    }
    return std.json.parseFromSlice(std.json.Value, gpa, out, .{});
}

/// Single-quote `s` as an SQL literal, doubling embedded quotes. Owned.
pub fn sqlLit(s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    for (s) |c| {
        if (c == '\'') out.writer.writeByte('\'') catch return error.OutOfMemory;
        out.writer.writeByte(c) catch return error.OutOfMemory;
    }
    out.writer.writeByte('\'') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The agent DB inside the isolated tmpdir HOME (Linux/macOS layout).
pub fn dbPath(temp_dir: []const u8) ![]u8 {
    return harness.harnessPath(gpa, temp_dir, &.{ ".config", "pabrik", "agent.db" });
}

/// Run one statement against the harness's DB, return the CLI's stdout
/// (owned).
///
/// `.timeout 10000` is the `busy_timeout` the server's WAL connection
/// needs — the Python helper's `sqlite3.connect(..., timeout=10)`. A bare CLI
/// invocation without it fails with SQLITE_BUSY the moment the boot's
/// migration transaction is still closing.
pub fn sqliteRun(temp_dir: []const u8, sql: []const u8) ![]u8 {
    const db = try dbPath(temp_dir);
    defer gpa.free(db);
    const res = std.process.run(gpa, io, .{
        .argv = &.{ sqlite_cli, "-cmd", ".timeout 10000", "-json", db, sql },
    }) catch |err| {
        std.debug.print("sqlite3 did not spawn: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer gpa.free(res.stderr);

    const code = exitCode(res.term) orelse {
        gpa.free(res.stdout);
        std.debug.print("sqlite3 was killed by a signal: {any}\n", .{res.term});
        return error.TestUnexpectedResult;
    };
    if (code != 0) {
        defer gpa.free(res.stdout);
        std.debug.print("sqlite3 exited {d}: {s}\nsql: {s}\n", .{ code, res.stderr, sql });
        return error.TestUnexpectedResult;
    }
    return res.stdout;
}

/// Run a write statement and discard its (empty) stdout.
pub fn execSql(temp_dir: []const u8, sql: []const u8) !void {
    const out = try sqliteRun(temp_dir, sql);
    defer gpa.free(out);
}

/// The first row of a `-json` result set, or null when there is none.
pub fn firstRow(parsed: *const std.json.Parsed(std.json.Value)) !?std.json.ObjectMap {
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.TestUnexpectedResult,
    };
    if (arr.items.len == 0) return null;
    return switch (arr.items[0]) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
}

/// The first row's `col`, dupe'd into `gpa` so it outlives the parse.
///
/// A SQL NULL (Python's `row["answer"] or ""`) collapses to `""` here,
/// which is the same collapse the Python helper performed at its call
/// sites.
pub fn firstCellString(temp_dir: []const u8, sql: []const u8, col: []const u8) !?[]u8 {
    const out = try sqliteRun(temp_dir, sql);
    defer gpa.free(out);
    var parsed = try parseSqliteJson(out);
    defer parsed.deinit();
    const row = (try firstRow(&parsed)) orelse return null;
    const cell = row.get(col) orelse return null;
    return switch (cell) {
        .string => |s| try gpa.dupe(u8, s),
        .null => try gpa.dupe(u8, ""),
        else => return error.TestUnexpectedResult,
    };
}

/// `SELECT COUNT(*)` over the harness's DB.
pub fn scalarCount(temp_dir: []const u8, sql: []const u8) !i64 {
    const out = try sqliteRun(temp_dir, sql);
    defer gpa.free(out);
    var parsed = try parseSqliteJson(out);
    defer parsed.deinit();
    const row = (try firstRow(&parsed)) orelse return error.TestUnexpectedResult;
    var it = row.iterator();
    const kv = it.next() orelse return error.TestUnexpectedResult;
    return switch (kv.value_ptr.*) {
        .integer => |i| i,
        else => error.TestUnexpectedResult,
    };
}

// ============================================================================
// Helpers — envelopes
// ============================================================================

/// The inner `data` payload `execAskUser` produces while pending.
///
/// Field order matches the Python dict literal so the seeded bytes are
/// the same bytes Python wrote (the assertions compare exact substrings of
/// the stored text).
pub const PendingEnvelope = struct {
    status: []const u8 = "pending",
    question_id: []const u8,
    header: []const u8 = "Deploy target",
    question: []const u8,
    answer: ?[]const u8 = null,
    answers_count: ?i64 = null,
    allow_free_text: bool = true,
    multi_select: bool = false,
    recommended: []const u8 = "staging",
    options: []const []const u8 = &.{ "staging", "production" },
    instruction: []const u8 = "The human has been asked and this turn is ending.",
};

pub const AskParams = struct {
    header: []const u8 = "Deploy target",
    question: []const u8,
    options: []const []const u8 = &.{ "staging", "production" },
    recommended: []const u8 = "staging",
};

/// The `tool_calls_json` the provider returned for the assistant row.
pub const ToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: Function = .{},

    pub const Function = struct {
        name: []const u8 = "ask_user",
        arguments: []const u8 = "{}",
    };
};

/// The full tool-output envelope stored in `llm_history.response_content`.
const ToolEnvelope = struct {
    tool: []const u8 = "ask_user",
    parameters: AskParams,
    success: bool = true,
    data: PendingEnvelope,
    // `error` is a Zig keyword; the escaped identifier still serialises
    // under the wire key `error`.
    @"error": ?[]const u8 = null,
    v: i64 = 1,
};

pub fn pendingEnvelopeJson(question_id: []const u8, question: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, PendingEnvelope{
        .question_id = question_id,
        .question = question,
    }, .{});
}

/// The stored tool-output envelope.
///
/// The Python `_tool_envelope(question_id, question, tool_call_id=...)`
/// signature carried a `tool_call_id` it never put in the body — the
/// envelope identifies its question by `question_id`, and the call id
/// lives on the `session_pending_question` row. Dropped here rather than
/// kept as a dead parameter.
pub fn toolEnvelopeJson(question_id: []const u8, question: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, ToolEnvelope{
        .parameters = .{ .question = question },
        .data = .{ .question_id = question_id, .question = question },
    }, .{});
}

// ============================================================================
// Helpers — wire
// ============================================================================

/// Monotonic milliseconds (`.awake`, not the wall clock).
pub fn nowMs() i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// Unix nanoseconds — `int(time.time() * 1_000_000_000)`.
pub fn nowNs() i64 {
    const ts = std.Io.Timestamp.now(io, .real).toNanoseconds();
    return @intCast(@divTrunc(ts, 1));
}

/// Session-id sequence, so `_create_session` never collides within a run.
var session_seq = std.atomic.Value(u64).init(0);

/// Spin up a session ROW without starting a run.
///
/// Deliberately `PUT /api/llm/session/:id` (which auto-creates via
/// `ensureSessionExists`) and NOT `POST /api/llm/session`: the POST variant
/// starts an agent run, and the run's DB transaction then hides this test's
/// externally-seeded rows from the app (the row would look missing and the
/// endpoint would 404). Same reasoning as
/// `session_human_touched_at_test._create_session_via_update`.
///
/// Returns an OWNED session id — every caller formats it into a URL or
/// into SQL, both of which outlive this frame.
pub fn createSession(h: *Harness, name: []const u8) ![]u8 {
    const seq = session_seq.fetchAdd(1, .monotonic) + 1;
    const session_id = try std.fmt.allocPrint(
        gpa,
        "sess_askuser_{d}_{d}",
        .{ @divTrunc(std.Io.Timestamp.now(io, .real).toNanoseconds(), std.time.ns_per_s), seq },
    );
    errdefer gpa.free(session_id);

    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}", .{session_id});
    defer gpa.free(path);
    const body = try std.json.Stringify.valueAlloc(gpa, .{ .name = name }, .{});
    defer gpa.free(body);

    var r = try h.http(io, .PUT, path, .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
    return session_id;
}

/// `POST /api/llm/session/:sid/answer`.
///
/// `null` optionals are OMITTED, not serialised as null — which is what
/// makes `body_requires_a_question_key` send a body with no `question_id`
/// key at all, the way the Python dict literal did.
pub const AnswerBody = struct {
    question_id: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    answer: ?[]const u8 = null,
    skip: ?bool = null,
};

pub fn postAnswer(h: *Harness, session_id: []const u8, body_spec: AnswerBody, expect: []const u16) !harness.Response {
    const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/answer", .{session_id});
    defer gpa.free(path);
    const body = try std.json.Stringify.valueAlloc(gpa, body_spec, .{ .emit_null_optional_fields = false });
    defer gpa.free(body);
    return h.http(io, .POST, path, .{ .json_body = body, .expect = expect });
}

/// A required string field — Python's `body["status"]`, which RAISED on a
/// missing key rather than degrading to `""`.
pub fn wantStr(doc: *const harness.Json, key: []const u8) ![]const u8 {
    return doc.str(key) orelse {
        std.debug.print("expected string key `{s}` in the answer response\n", .{key});
        return error.TestUnexpectedResult;
    };
}

/// A required bool field — Python's `body["resumed"] is True`.
pub fn wantBool(doc: *const harness.Json, key: []const u8) !bool {
    return doc.boolean(key) orelse {
        std.debug.print("expected boolean key `{s}` in the answer response\n", .{key});
        return error.TestUnexpectedResult;
    };
}

/// A required integer field — Python's `body["questions_remaining"] == 0`.
pub fn wantInt(doc: *const harness.Json, key: []const u8) !i64 {
    return doc.int(key) orelse {
        std.debug.print("expected integer key `{s}` in the answer response\n", .{key});
        return error.TestUnexpectedResult;
    };
}

/// Assert `content` contains `needle` — Python's `assert needle in content`.
pub fn wantContains(content: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, content, needle) == null) {
        std.debug.print("expected {s} in the stored row, got:\n{s}\n", .{ needle, content });
        return error.TestUnexpectedResult;
    }
}

/// Assert `content` does NOT contain `needle` — Python's
/// `assert needle not in content`.
pub fn wantAbsent(content: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, content, needle) != null) {
        std.debug.print("did not expect {s} in the stored row, got:\n{s}\n", .{ needle, content });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Helpers — seeded DB state
// ============================================================================

/// What `_seed_question` hands back: `(question_id, tool_result_row_id)`.
/// Both fields are OWNED.
pub const Seeded = struct {
    question_id: []u8,
    tool_row_id: []u8,

    pub fn deinit(self: *Seeded) void {
        gpa.free(self.question_id);
        gpa.free(self.tool_row_id);
        self.* = undefined;
    }
};

/// Insert what handle_tool Phase 1/3 + execAskUser would have written.
pub fn seedQuestion(
    h: *Harness,
    session_id: []const u8,
    question_id: []const u8,
    tool_call_id: []const u8,
    question: []const u8,
) !Seeded {
    const tool_row_id = try std.fmt.allocPrint(gpa, "row_{s}", .{question_id});
    errdefer gpa.free(tool_row_id);
    const assistant_row_id = try std.fmt.allocPrint(gpa, "asst_{s}", .{question_id});
    defer gpa.free(assistant_row_id);

    const now_ns = nowNs();

    // The assistant row that made the call (tool_calls_json is what makes
    // the chain a valid assistant(tool_calls) + tool(result) pair).
    {
        const calls_json = try std.json.Stringify.valueAlloc(
            gpa,
            &.{ToolCall{ .id = tool_call_id }},
            .{},
        );
        defer gpa.free(calls_json);
        const calls_lit = try sqlLit(calls_json);
        defer gpa.free(calls_lit);
        const asst_lit = try sqlLit(assistant_row_id);
        defer gpa.free(asst_lit);
        const sid_lit = try sqlLit(session_id);
        defer gpa.free(sid_lit);
        const sql = try std.fmt.allocPrint(gpa,
            \\INSERT INTO llm_history (id, session_id, model, response_content, role,
            \\    finish_reason, tool_calls_json, tool_call_id, created_at_nano,
            \\    is_feed_to_llm, agent, loop_index, temperature, is_thinking,
            \\    is_input, is_output)
            \\VALUES ({s}, {s}, 'test-model', '', 'assistant', 'tool_calls', {s}, NULL, {d},
            \\    1, 'Agent', 0, 0.2, 0, 0, 1)
        , .{ asst_lit, sid_lit, calls_lit, now_ns });
        defer gpa.free(sql);
        try execSql(h.temp_dir, sql);
    }

    // The tool-result placeholder, rewritten in place by the endpoint.
    {
        const env_json = try toolEnvelopeJson(question_id, question);
        defer gpa.free(env_json);
        const env_lit = try sqlLit(env_json);
        defer gpa.free(env_lit);
        const row_lit = try sqlLit(tool_row_id);
        defer gpa.free(row_lit);
        const sid_lit = try sqlLit(session_id);
        defer gpa.free(sid_lit);
        const call_lit = try sqlLit(tool_call_id);
        defer gpa.free(call_lit);
        const sql = try std.fmt.allocPrint(gpa,
            \\INSERT INTO llm_history (id, session_id, model, response_content, role,
            \\    finish_reason, tool_calls_json, tool_call_id, tool_name,
            \\    created_at_nano, is_feed_to_llm, agent, loop_index, temperature,
            \\    is_thinking, is_input, is_output)
            \\VALUES ({s}, {s}, 'test-model', {s}, 'tool', 'tool', '', {s}, 'ask_user', {d},
            \\    1, 'Agent', 0, 0.2, 0, 0, 1)
        , .{ row_lit, sid_lit, env_lit, call_lit, now_ns + 1 });
        defer gpa.free(sql);
        try execSql(h.temp_dir, sql);
    }

    // The pending question (Migration 088).
    {
        const qid_lit = try sqlLit(question_id);
        defer gpa.free(qid_lit);
        const sid_lit = try sqlLit(session_id);
        defer gpa.free(sid_lit);
        const call_lit = try sqlLit(tool_call_id);
        defer gpa.free(call_lit);
        const row_lit = try sqlLit(tool_row_id);
        defer gpa.free(row_lit);
        const q_lit = try sqlLit(question);
        defer gpa.free(q_lit);
        const sql = try std.fmt.allocPrint(gpa,
            \\INSERT INTO session_pending_question
            \\    (id, session_id, tool_call_id, llm_history_id, question,
            \\     multi_select, status, answer, created_at, resolved_at)
            \\VALUES ({s}, {s}, {s}, {s}, {s}, 0, 'pending', NULL, {d}, NULL)
        , .{ qid_lit, sid_lit, call_lit, row_lit, q_lit, now_ns });
        defer gpa.free(sql);
        try execSql(h.temp_dir, sql);
    }

    return .{
        .question_id = try gpa.dupe(u8, question_id),
        .tool_row_id = tool_row_id,
    };
}

/// `_question(...)` — the `session_pending_question` row, or null.
pub const QuestionRow = struct {
    status: []u8,
    answer: []u8,

    pub fn deinit(self: *QuestionRow) void {
        gpa.free(self.status);
        gpa.free(self.answer);
        self.* = undefined;
    }
};

pub fn fetchQuestion(temp_dir: []const u8, question_id: []const u8) !?QuestionRow {
    const lit = try sqlLit(question_id);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT status, answer FROM session_pending_question WHERE id = {s}",
        .{lit},
    );
    defer gpa.free(sql);
    const status = try firstCellString(temp_dir, sql, "status");
    if (status == null) return null;
    const answer = (try firstCellString(temp_dir, sql, "answer")) orelse try gpa.dupe(u8, "");
    return .{ .status = status.?, .answer = answer };
}

/// `assert row is not None and row["status"] == want`.
///
/// Fused into one helper because Python's two-step assert leaves the Zig
/// call site holding a `const` payload it cannot `defer row.deinit()`
/// on — `orelse` yields a const value, and `deinit` needs `*T`.
pub fn expectQuestionStatus(temp_dir: []const u8, question_id: []const u8, want: []const u8) !void {
    var row_opt = try fetchQuestion(temp_dir, question_id);
    defer if (row_opt) |*r| r.deinit();
    const row = row_opt orelse {
        std.debug.print("no session_pending_question row for {s}\n", .{question_id});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, row.status, want)) {
        std.debug.print("expected question status={s}, got {s}\n", .{ want, row.status });
        return error.TestUnexpectedResult;
    }
}

/// `assert row["answer"] == want` — the RAW value, not the envelope.
pub fn expectQuestionAnswer(temp_dir: []const u8, question_id: []const u8, want: []const u8) !void {
    var row_opt = try fetchQuestion(temp_dir, question_id);
    defer if (row_opt) |*r| r.deinit();
    const row = row_opt orelse {
        std.debug.print("no session_pending_question row for {s}\n", .{question_id});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, row.answer, want)) {
        std.debug.print("expected question answer={s}, got {s}\n", .{ want, row.answer });
        return error.TestUnexpectedResult;
    }
}

/// `_tool_row_content` — the `response_content` of one `llm_history` row.
///
/// OWNED: Python returned a `str` copied out of the driver, and the Zig
/// caller compares it after this frame's buffers are gone.
pub fn toolRowContent(temp_dir: []const u8, row_id: []const u8) ![]u8 {
    const lit = try sqlLit(row_id);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(
        gpa,
        "SELECT response_content FROM llm_history WHERE id = {s}",
        .{lit},
    );
    defer gpa.free(sql);
    return (try firstCellString(temp_dir, sql, "response_content")) orelse try gpa.dupe(u8, "");
}

pub fn workerExists(temp_dir: []const u8, session_id: []const u8) !bool {
    const lit = try sqlLit(session_id);
    defer gpa.free(lit);
    const sql = try std.fmt.allocPrint(gpa, "SELECT 1 AS present FROM worker WHERE id = {s}", .{lit});
    defer gpa.free(sql);
    const out = try sqliteRun(temp_dir, sql);
    defer gpa.free(out);
    var parsed = try parseSqliteJson(out);
    defer parsed.deinit();
    return (try firstRow(&parsed)) != null;
}

/// `_wait_for_worker` — the resume runs in a concurrent task, so the worker
/// row lands just after the HTTP response. Poll briefly instead of
/// asserting immediately.
pub fn waitForWorker(temp_dir: []const u8, session_id: []const u8, timeout_ms: i64) !bool {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        if (try workerExists(temp_dir, session_id)) return true;
        sleepMs(50);
    }
    return false;
}

/// A cancellable sleep in whole milliseconds. `Io.sleep` reports
/// cancellation, which a test cannot act on.
pub fn sleepMs(ms: i64) void {
    std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}

// ============================================================================
// Tests
// ============================================================================

// Happy path: the model's view of the answer + a new run.
test "answer_rewrites_the_tool_row_and_resumes_the_run" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedQuestion(
        &h,
        session_id,
        "q_test_1",
        "call_abc",
        "Which environment should I deploy to?",
    );
    defer seeded.deinit();

    var r = try postAnswer(&h, session_id, .{
        .question_id = seeded.question_id,
        .answer = "staging",
    }, &.{200});
    defer r.deinit();
    var body = try r.json();
    defer body.deinit();
    if (!std.mem.eql(u8, try wantStr(&body, "status"), "answered")) {
        std.debug.print("expected status=answered, got {s}\n", .{try wantStr(&body, "status")});
        return error.TestUnexpectedResult;
    }
    if (!try wantBool(&body, "resumed")) {
        std.debug.print("expected resumed=true\n", .{});
        return error.TestUnexpectedResult;
    }

    // 1. the question row resolved
    try expectQuestionStatus(h.temp_dir, seeded.question_id, "answered");
    try expectQuestionAnswer(h.temp_dir, seeded.question_id, "staging");

    // 2. the tool-result ROW was rewritten in place — same row id, which is
    //    what the model reads on the next run.
    {
        const content = try toolRowContent(h.temp_dir, seeded.tool_row_id);
        defer gpa.free(content);
        try wantContains(content, "\"status\":\"answered\"");
        try wantContains(content, "\"answer\":\"staging\"");
        try wantAbsent(content, "\"status\":\"pending\"");
    }

    // 3. a run was started.
    if (!try waitForWorker(h.temp_dir, session_id, 8_000)) {
        std.debug.print("no worker row after answering\n", .{});
        return error.TestUnexpectedResult;
    }
}

// The card parses the row with `unwrapToolOutput`, which THROWS unless the
// envelope has `tool`, `parameters`, `success` and `v`.
//
// An earlier version of the rewrite emitted an envelope with only
// `success` — no `parameters` — so every resolved question fell back to an
// empty "pending" card: it looked unanswered and its inputs stayed live.
test "rewritten_row_satisfies_the_frontend_envelope_contract" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedQuestion(
        &h,
        session_id,
        "q_test_1",
        "call_abc",
        "Which environment should I deploy to?",
    );
    defer seeded.deinit();

    {
        var r = try postAnswer(&h, session_id, .{
            .question_id = seeded.question_id,
            .answer = "staging",
        }, &.{200});
        defer r.deinit();
    }

    const content = try toolRowContent(h.temp_dir, seeded.tool_row_id);
    defer gpa.free(content);
    for ([_][]const u8{
        "\"tool\":\"ask_user\"",
        "\"parameters\"",
        "\"success\":true",
        "\"v\":1",
    }) |required| try wantContains(content, required);
    // The parameters block is preserved from the placeholder, not dropped.
    try wantContains(content, "Deploy target");
    // And the payload the card renders is inside <data>.
    try wantContains(content, "\"data\":{\"status\":\"answered\"");
    // Python: `content.rstrip().endswith("}")`.
    const trimmed = std.mem.trimEnd(u8, content, " \t\r\n");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '}') {
        std.debug.print("rewritten row does not end with `}}`: {s}\n", .{content});
        return error.TestUnexpectedResult;
    }
}

// Same contract on the Skip path — the card must be able to show `skipped`
// and disable its inputs.
test "skipped_question_rewrites_the_row_too" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedQuestion(
        &h,
        session_id,
        "q_test_1",
        "call_abc",
        "Which environment should I deploy to?",
    );
    defer seeded.deinit();

    {
        var r = try postAnswer(&h, session_id, .{
            .question_id = seeded.question_id,
            .skip = true,
        }, &.{200});
        defer r.deinit();
    }

    const content = try toolRowContent(h.temp_dir, seeded.tool_row_id);
    defer gpa.free(content);
    try wantContains(content, "\"status\":\"skipped\"");
    try wantContains(content, "\"parameters\"");
    try wantContains(content, "\"success\":true");
}

// A double-click (or a retry after a lost 200) must never 4xx.
test "double_answer_is_idempotent_and_resumes_once" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedQuestion(
        &h,
        session_id,
        "q_test_1",
        "call_abc",
        "Which environment should I deploy to?",
    );
    defer seeded.deinit();

    {
        var first = try postAnswer(&h, session_id, .{
            .question_id = seeded.question_id,
            .answer = "production",
        }, &.{200});
        defer first.deinit();
        var doc = try first.json();
        defer doc.deinit();
        if (!std.mem.eql(u8, try wantStr(&doc, "status"), "answered")) {
            std.debug.print("first POST: expected status=answered\n", .{});
            return error.TestUnexpectedResult;
        }
    }

    {
        var second = try postAnswer(&h, session_id, .{
            .question_id = seeded.question_id,
            .answer = "production",
        }, &.{200});
        defer second.deinit();
        var doc = try second.json();
        defer doc.deinit();
        if (!std.mem.eql(u8, try wantStr(&doc, "status"), "answered")) {
            std.debug.print("replayed POST: expected status=answered\n", .{});
            return error.TestUnexpectedResult;
        }
        // No second run was started for an already-resolved question.
        if (try wantBool(&doc, "resumed")) {
            std.debug.print("the replayed answer started a SECOND run\n", .{});
            return error.TestUnexpectedResult;
        }
    }

    // The stored answer is unchanged by the replay.
    {
        const content = try toolRowContent(h.temp_dir, seeded.tool_row_id);
        defer gpa.free(content);
        try wantContains(content, "\"answer\":\"production\"");
    }
    // The question row stores the RAW value, not the envelope.
    try expectQuestionAnswer(h.temp_dir, seeded.question_id, "production");
}

// An empty answer would bind as SQL NULL downstream — it must 400.
test "empty_answer_is_rejected_on_the_wire" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedQuestion(
        &h,
        session_id,
        "q_test_1",
        "call_abc",
        "Which environment should I deploy to?",
    );
    defer seeded.deinit();

    for ([_][]const u8{ "", "   " }) |bad| {
        var r = try postAnswer(&h, session_id, .{
            .question_id = seeded.question_id,
            .answer = bad,
        }, &.{400});
        defer r.deinit();
        // The STATUS ITSELF is the assertion, so read it rather than
        // trusting `.expect` alone.
        try testing.expectEqual(@as(u16, 400), r.status);
    }

    // The question is untouched, so a retry is safe.
    try expectQuestionStatus(h.temp_dir, seeded.question_id, "pending");
    {
        const content = try toolRowContent(h.temp_dir, seeded.tool_row_id);
        defer gpa.free(content);
        try wantContains(content, "\"status\":\"pending\"");
    }
}

// Never let session A answer session B's question.
test "unknown_question_is_404_and_other_session_is_403" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const owner = try createSession(&h, "ask-user-owner");
    defer gpa.free(owner);
    const other = try createSession(&h, "ask-user-other");
    defer gpa.free(other);
    var seeded = try seedQuestion(
        &h,
        owner,
        "q_test_1",
        "call_abc",
        "Which environment should I deploy to?",
    );
    defer seeded.deinit();

    {
        var missing = try postAnswer(&h, owner, .{
            .question_id = "q_does_not_exist",
            .answer = "staging",
        }, &.{404});
        defer missing.deinit();
        try testing.expectEqual(@as(u16, 404), missing.status);
    }
    {
        var stolen = try postAnswer(&h, other, .{
            .question_id = seeded.question_id,
            .answer = "staging",
        }, &.{403});
        defer stolen.deinit();
        try testing.expectEqual(@as(u16, 403), stolen.status);
    }

    // Still pending for its rightful owner.
    try expectQuestionStatus(h.temp_dir, seeded.question_id, "pending");
}

// A body with no key at all cannot identify a question.
test "body_requires_a_question_key" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedQuestion(
        &h,
        session_id,
        "q_test_1",
        "call_abc",
        "Which environment should I deploy to?",
    );
    defer seeded.deinit();

    // `question_id` and `tool_call_id` both left null → OMITTED, so the
    // body is literally `{"answer":"staging"}`.
    var r = try postAnswer(&h, session_id, .{ .answer = "staging" }, &.{400});
    defer r.deinit();
    try testing.expectEqual(@as(u16, 400), r.status);
}

// The card always has the tool_call_id, so it must work as a key.
test "tool_call_id_is_accepted_as_the_fallback_key" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedQuestion(
        &h,
        session_id,
        "q_test_1",
        "call_fallback",
        "Which environment should I deploy to?",
    );
    defer seeded.deinit();

    var r = try postAnswer(&h, session_id, .{
        .tool_call_id = "call_fallback",
        .answer = "staging",
    }, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    if (!std.mem.eql(u8, try wantStr(&doc, "status"), "answered")) {
        std.debug.print("tool_call_id key was not honoured\n", .{});
        return error.TestUnexpectedResult;
    }

    const content = try toolRowContent(h.temp_dir, seeded.tool_row_id);
    defer gpa.free(content);
    try wantContains(content, "\"answer\":\"staging\"");
}

// Skip is not Stop: the run must continue, and the model is told not to
// guess instead of being handed an answer.
test "skip_settles_the_question_and_still_resumes" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedQuestion(
        &h,
        session_id,
        "q_test_1",
        "call_abc",
        "Which environment should I deploy to?",
    );
    defer seeded.deinit();

    {
        var r = try postAnswer(&h, session_id, .{
            .question_id = seeded.question_id,
            .skip = true,
        }, &.{200});
        defer r.deinit();
        var doc = try r.json();
        defer doc.deinit();
        if (!std.mem.eql(u8, try wantStr(&doc, "status"), "skipped")) {
            std.debug.print("expected status=skipped\n", .{});
            return error.TestUnexpectedResult;
        }
    }

    {
        const content = try toolRowContent(h.temp_dir, seeded.tool_row_id);
        defer gpa.free(content);
        try wantContains(content, "\"status\":\"skipped\"");
        try wantContains(content, "Do not guess");
    }
    if (!try waitForWorker(h.temp_dir, session_id, 8_000)) {
        std.debug.print("skip did not resume the run\n", .{});
        return error.TestUnexpectedResult;
    }
}

// The user is never dead-ended: sending a message settles the question and
// the model is told the human moved on (it must not read `pending`).
test "a_new_message_instead_of_an_answer_settles_it_as_abandoned" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);
    var seeded = try seedQuestion(
        &h,
        session_id,
        "q_test_1",
        "call_abc",
        "Which environment should I deploy to?",
    );
    defer seeded.deinit();

    // `POST /api/llm/session` creates-or-sends, so it answers 201 here.
    //
    // `cwd_session` is `h.temp_dir` rather than the Python's "/tmp"
    // literal: `std.fs.path.isAbsolute("/tmp")` is FALSE on windows-2022,
    // and `harnessPath` is absolute on every platform.
    {
        const cwd = try harness.harnessPath(gpa, h.temp_dir, &.{});
        defer gpa.free(cwd);
        const body = try std.json.Stringify.valueAlloc(gpa, .{
            .session_id = session_id,
            .queue_message = "never mind, use production",
            .cwd_session = cwd,
        }, .{});
        defer gpa.free(body);
        var r = try h.http(io, .POST, "/api/llm/session", .{
            .json_body = body,
            .expect = &.{ 200, 201 },
        });
        defer r.deinit();
    }

    try expectQuestionStatus(h.temp_dir, seeded.question_id, "abandoned");

    {
        const content = try toolRowContent(h.temp_dir, seeded.tool_row_id);
        defer gpa.free(content);
        try wantContains(content, "\"status\":\"abandoned\"");
        // The whole point: the model never sees the pending envelope.
        try wantAbsent(content, "\"status\":\"pending\"");
        // …and the card can still read it (see the envelope-contract test).
        try wantContains(content, "\"parameters\"");
        try wantContains(content, "\"success\":true");
    }

    // And any later answer for it is refused rather than re-resumed.
    {
        var late = try postAnswer(&h, session_id, .{
            .question_id = seeded.question_id,
            .answer = "staging",
        }, &.{200});
        defer late.deinit();
        var doc = try late.json();
        defer doc.deinit();
        if (!std.mem.eql(u8, try wantStr(&doc, "status"), "abandoned")) {
            std.debug.print("a late answer must report status=abandoned\n", .{});
            return error.TestUnexpectedResult;
        }
        if (try wantBool(&doc, "resumed")) {
            std.debug.print("a late answer must not resume the run\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

// Route-order regression guard: `/answer` must resolve to its OWN handler.
//
// `matchRoute` walks routes in registration order, so a sibling `:param`
// route registered earlier could capture this path (the /knowledge/reorder
// class of bug). The distinctive JSON keys prove which handler ran.
test "answer_route_is_not_shadowed_by_sibling_routes" {
    try harness.requirePabrikBin(io, gpa);
    const sqlite = try requireSqlite3Cli();
    defer gpa.free(sqlite);
    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}", .{@errorName(err)});
    };

    const session_id = try createSession(&h, "ask-user-probe");
    defer gpa.free(session_id);

    // Wrong method on the right path → 404/405, never a sibling handler's 200
    // with sibling keys.
    {
        const path = try std.fmt.allocPrint(gpa, "/api/llm/session/{s}/answer", .{session_id});
        defer gpa.free(path);
        var r = try h.http(io, .GET, path, .{ .expect = &.{ 404, 405 } });
        defer r.deinit();
        if (r.status < 400) {
            std.debug.print("GET on the answer route answered {d}: {s}\n", .{ r.status, r.body });
            return error.TestUnexpectedResult;
        }
    }

    // The real handler answers with its own keys.
    var seeded = try seedQuestion(
        &h,
        session_id,
        "q_test_1",
        "call_abc",
        "Which environment should I deploy to?",
    );
    defer seeded.deinit();

    var ok = try postAnswer(&h, session_id, .{
        .question_id = seeded.question_id,
        .answer = "staging",
    }, &.{200});
    defer ok.deinit();
    var body = try ok.json();
    defer body.deinit();

    if (body.get("resumed") == null or body.get("status") == null) {
        std.debug.print("the answer handler's own keys are missing: {s}\n", .{ok.body});
        return error.TestUnexpectedResult;
    }
    // A session-scoped sibling (e.g. /stop) returns `success`, not these.
    if (!try wantBool(&body, "success")) {
        std.debug.print("expected success=true alongside resumed/status\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Body-analysis barrier: an unreferenced helper is never type-checked, so a
// stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = requireSqlite3Cli;
    _ = sqliteCliWorks;
    _ = parseSqliteJson;
    _ = sqliteRun;
    _ = execSql;
    _ = firstRow;
    _ = firstCellString;
    _ = scalarCount;
    _ = sqlLit;
    _ = dbPath;
    _ = pendingEnvelopeJson;
    _ = toolEnvelopeJson;
    _ = createSession;
    _ = postAnswer;
    _ = wantStr;
    _ = wantBool;
    _ = wantInt;
    _ = wantContains;
    _ = wantAbsent;
    _ = seedQuestion;
    _ = fetchQuestion;
    _ = expectQuestionStatus;
    _ = expectQuestionAnswer;
    _ = toolRowContent;
    _ = workerExists;
    _ = waitForWorker;
    _ = sleepMs;
    _ = nowNs;
    _ = nowMs;
    _ = Harness.boot;
}
