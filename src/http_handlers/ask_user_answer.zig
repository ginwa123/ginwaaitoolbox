//! `POST /api/llm/session/:session_id/answer` — resolve a pending
//! `ask_user` question and resume the conversation.
//!
//! ## The order is load-bearing
//!
//! 1. validate the request (see `AnswerError` for the status mapping);
//! 2. mark the `session_pending_question` row resolved;
//! 3. **rewrite the tool-result `llm_history` row in place** with the
//!    resolved JSON payload, and push its `llm_full` frame so an
//!    open `ChatView` flips the card without a reload;
//! 4. start a new run so the model continues with the answer in context.
//!
//! Steps 3 and 4 must not swap. Tool-result rows are written with
//! `is_feed_to_llm = 1`, so a run started first would hand the model
//! `"status":"pending"` — and it might guess. If step 3 fails we return
//! an error and leave the row `pending`, which keeps a Retry safe; the
//! reverse order would fail *silently* into a wrong answer.
//!
//! ## Idempotency
//!
//! A double-click, a browser retry or a late Retry after a 200-that-was-lost
//! must never 4xx — resolving an already-resolved question returns 200 with
//! the stored status. Only genuinely bad input is a 400/403/404.

const std = @import("std");
const nalarcore = @import("nalarcore");
const http_response = @import("http_response.zig");
const gserverz = nalarcore.gserverz;
const ask_user_mod = nalarcore.ask_user;
const ask_user_pending = nalarcore.ask_user_pending;
const wrapToolOutput = @import("../agentic_loop/tools_wrap_output.zig").wrapToolOutput;

pub const AnswerError = error{
    MissingSessionId,
    BodyRequired,
    InvalidJsonBody,
    MissingQuestionKey,
    QuestionNotFound,
    SessionMismatch,
    EmptyAnswer,
    MultiSelectRequiresArray,
    RewriteFailed,
    LookupFailed,
    ResumeFailed,
    GlobalContextNotInitialized,
    /// `resolveQuestion` dupes the outcome's strings; unreachable on the
    /// per-request arena, but the type system requires the variant.
    OutOfMemory,
};

/// Request body. `question_id` is preferred; `tool_call_id` is the fallback
/// for a client that only has the tool row in hand (the card always has it).
pub const AnswerBody = struct {
    question_id: []const u8 = "",
    tool_call_id: []const u8 = "",
    answer: []const u8 = "",
    skip: bool = false,
};

/// The outcome of resolving one question.
///
/// `status` / `answer` are OWNED by the outcome — `resolveQuestion` frees the
/// `PendingQuestion` row it read them from, so returning borrowed slices would
/// hand the caller freed memory (which JSON-serialises as 0xAA undefined
/// bytes in debug builds). Call `deinit` once done.
pub const AnswerOutcome = struct {
    /// The status stored on the question row: answered | skipped | abandoned.
    status: []u8,
    /// The stored answer ("" when skipped / already skipped).
    answer: []u8,
    /// False when the question was already resolved — the response is still
    /// 200; `resumed` is false because no new run was started.
    resumed: bool,

    pub fn deinit(self: *const AnswerOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.status);
        allocator.free(self.answer);
    }
};

/// Validate the wire shape of `answer` against the question's own
/// `multi_select` flag.
///
/// The option-membership rule (`allow_free_text = false` ⇒ the answer must be
/// one of `options`) is deliberately NOT enforced here: the options live in
/// the tool-call arguments, and recovering them would mean re-reading the
/// tool-call arguments — fragile machinery guarding a path the UI
/// cannot produce (radios and checkboxes can only emit valid values). What IS
/// enforced is the integrity-critical part: a non-empty value, and an array
/// for a multi-select question, because a scalar there would reach the model
/// in a shape it cannot read.
pub fn validateAnswerShape(answer: []const u8, multi_select: bool, skip: bool) AnswerError!void {
    if (skip) return;

    if (std.mem.trim(u8, answer, " \t\r\n").len == 0) return error.EmptyAnswer;

    if (!multi_select) return;

    // Multi-select answers are JSON arrays of strings.
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, answer, .{}) catch {
        return error.MultiSelectRequiresArray;
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.MultiSelectRequiresArray;
    if (parsed.value.array.items.len == 0) return error.MultiSelectRequiresArray;
    for (parsed.value.array.items) |item| {
        if (item != .string) return error.MultiSelectRequiresArray;
    }
}

pub const ResolveInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *nalarcore.sqlite.SqliteBackend,
    session_id: []const u8,
    question_id: []const u8,
    answer: []const u8,
    skip: bool,
    /// How many values the answer carries (for the payload's
    /// `"answers_count"`). 1 unless the caller parsed a multi-select array.
    answers_count: usize = 1,
};

/// Steps 1–3 for the DB side: find the row, validate, mark it resolved and
/// rewrite the tool-result row. Returns the outcome; the caller then resumes.
pub fn resolveQuestion(input: ResolveInput) AnswerError!AnswerOutcome {
    const allocator = input.allocator;

    const question = (ask_user_pending.getPendingQuestion(
        allocator,
        input.db,
        input.question_id,
    ) catch return error.LookupFailed) orelse return error.QuestionNotFound;
    defer question.deinit(allocator);

    // Never let session A answer session B's question.
    if (!std.mem.eql(u8, question.session_id, input.session_id)) return error.SessionMismatch;

    // Already resolved → idempotent 200, no second run.
    if (!std.mem.eql(u8, question.status, ask_user_mod.Status.pending.to_str())) {
        return .{
            .status = try allocator.dupe(u8, question.status),
            .answer = try allocator.dupe(u8, question.answer),
            .resumed = false,
        };
    }

    try validateAnswerShape(input.answer, question.multi_select, input.skip);

    const target: ask_user_mod.Status = if (input.skip) .skipped else .answered;
    const stored_answer: ?[]const u8 = if (input.skip) null else input.answer;

    ask_user_pending.markQuestionStatus(allocator, input.io, input.db, question.id, target, stored_answer) catch {
        return error.RewriteFailed;
    };

    // Rebuild the tool result the model will read on resume. The question
    // text travels with it so the transcript stays self-describing.
    const inner = ask_user_mod.buildAskUserJson(allocator, .{
        .status = target,
        .question_id = question.id,
        .question = question.question,
        .answer = input.answer,
        .answers_count = if (input.skip) 0 else input.answers_count,
    }) catch return error.RewriteFailed;
    defer allocator.free(inner);

    ask_user_pending.rewriteToolResultRow(.{
        .allocator = allocator,
        .io = input.io,
        .db = input.db,
        .session_id = input.session_id,
        .llm_history_id = question.llm_history_id,
        .inner = inner,
    }) catch return error.RewriteFailed;

    return .{
        .status = try allocator.dupe(u8, target.to_str()),
        .answer = try allocator.dupe(u8, stored_answer orelse ""),
        .resumed = true,
    };
}

// =====================================================================
// Handler
// =====================================================================

pub fn askUserAnswerHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id path parameter" }),
        });
    };

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const body = std.json.parseFromSliceLeaky(AnswerBody, allocator, req.body, .{ .ignore_unknown_fields = true }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // Resolve the question id, preferring the explicit one.
    var question_id: []const u8 = body.question_id;
    if (question_id.len == 0 and body.tool_call_id.len > 0) {
        const by_call = ask_user_pending.getPendingQuestionByToolCall(
            allocator,
            di.db,
            session_id,
            body.tool_call_id,
        ) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "DB error" }),
            });
        };
        if (by_call) |q| {
            defer q.deinit(allocator);
            question_id = try allocator.dupe(u8, q.id);
        }
    }
    if (question_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "question_id or tool_call_id is required" }),
        });
    }

    const outcome = resolveQuestion(.{
        .allocator = allocator,
        .io = di.io,
        .db = di.db,
        .session_id = session_id,
        .question_id = question_id,
        .answer = body.answer,
        .skip = body.skip,
        .answers_count = countAnswers(allocator, body.answer),
    }) catch |err| {
        const status: u16 = switch (err) {
            error.QuestionNotFound => 404,
            error.SessionMismatch => 403,
            error.EmptyAnswer => 400,
            error.MultiSelectRequiresArray => 400,
            error.MissingQuestionKey => 400,
            error.MissingSessionId => 400,
            error.BodyRequired => 400,
            error.InvalidJsonBody => 400,
            error.RewriteFailed => 500,
            error.LookupFailed => 500,
            error.ResumeFailed => 500,
            error.GlobalContextNotInitialized => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.QuestionNotFound => "no such pending question for this session",
            error.SessionMismatch => "that question belongs to a different session",
            error.EmptyAnswer => "answer must not be empty (use skip:true to decline)",
            error.MultiSelectRequiresArray => "this question is multi-select: answer must be a non-empty JSON array of strings",
            error.RewriteFailed => "failed to record the answer; the question is still pending, retry is safe",
            error.LookupFailed => "DB error",
            error.ResumeFailed => "the answer was recorded but the session could not be resumed",
            error.MissingQuestionKey => "question_id or tool_call_id is required",
            error.MissingSessionId => "Missing session_id path parameter",
            error.BodyRequired => "Request body required",
            error.InvalidJsonBody => "Invalid JSON body",
            error.GlobalContextNotInitialized => "Global context not initialized",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Step 4 — resume. Only after the row rewrite has definitely landed.
    // Best-effort by design: if the emit fails the ANSWER is still recorded,
    // so the user can recover by sending any message (which the
    // `session_create` guard turns into a normal run).
    var resumed = false;
    if (outcome.resumed) {
        resumed = ask_user_pending.resumeSession(di, allocator, session_id) catch |err| blk: {
            std.log.warn("ask_user: resume after answer failed for {s}: {s}", .{ session_id, @errorName(err) });
            break :blk false;
        };
    }

    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .success = true,
        .session_id = session_id,
        .status = outcome.status,
        .answer = outcome.answer,
        .resumed = resumed,
    }, .{});
    // `payload` copied the strings, so the outcome is done.
    outcome.deinit(allocator);

    return res.jsonResponse(.{
        .status_code = 200,
        .data = payload,
    });
}

/// How many values the answer holds, for the payload's `"answers_count"`.
/// A JSON array → its length; anything else → 1.
fn countAnswers(allocator: std.mem.Allocator, answer: []const u8) usize {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, answer, .{}) catch return 1;
    defer parsed.deinit();
    if (parsed.value == .array) return parsed.value.array.items.len;
    return 1;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "validateAnswerShape: single-select accepts any non-blank string" {
    try validateAnswerShape("staging", false, false);
    try validateAnswerShape("a free text answer", false, false);
    // Blank is the one rejection — it would bind as SQL NULL downstream.
    try testing.expectError(error.EmptyAnswer, validateAnswerShape("", false, false));
    try testing.expectError(error.EmptyAnswer, validateAnswerShape("  \n ", false, false));
    // skip bypasses the answer entirely.
    try validateAnswerShape("", false, true);
}

test "validateAnswerShape: multi-select requires a non-empty string array" {
    try validateAnswerShape("[\"a\"]", true, false);
    try validateAnswerShape("[\"zig unit\",\"pytest\"]", true, false);

    // A scalar is exactly the mistake a hand-crafted client would make.
    try testing.expectError(error.MultiSelectRequiresArray, validateAnswerShape("a", true, false));
    try testing.expectError(error.MultiSelectRequiresArray, validateAnswerShape("[]", true, false));
    try testing.expectError(error.MultiSelectRequiresArray, validateAnswerShape("[1,2]", true, false));
    try testing.expectError(error.MultiSelectRequiresArray, validateAnswerShape("not json", true, false));
    // skip is still allowed to carry nothing.
    try validateAnswerShape("", true, true);
}

test "countAnswers: array length vs single value" {
    const a = testing.allocator;
    try testing.expectEqual(@as(usize, 1), countAnswers(a, "staging"));
    try testing.expectEqual(@as(usize, 1), countAnswers(a, "not json"));
    try testing.expectEqual(@as(usize, 2), countAnswers(a, "[\"a\",\"b\"]"));
    try testing.expectEqual(@as(usize, 1), countAnswers(a, "[\"a\"]"));
}

test "ask_user_answer: the resolved envelope satisfies the frontend's contract" {
    const a = testing.allocator;
    const inner = try ask_user_mod.buildAskUserJson(a, .{
        .status = .answered,
        .question_id = "q_1",
        .question = "Which environment?",
        .answer = "staging",
        .answers_count = 1,
    });
    defer a.free(inner);

    const envelope = try wrapToolOutput(a, ask_user_mod.ASK_USER_TOOL_NAME, "{\"header\":\"Deploy target\"}", true, null, inner);
    defer a.free(envelope);

    // Shaped like every other tool result so `unwrapToolOutput` parses it…
    try testing.expect(std.mem.indexOf(u8, envelope, "\"tool\":\"ask_user\"") != null);
    try testing.expect(std.mem.indexOf(u8, envelope, "\"success\":true") != null);
    var env_parsed = try std.json.parseFromSlice(std.json.Value, a, envelope, .{});
    defer env_parsed.deinit();
    try testing.expect(env_parsed.value == .object);
    // …and the model reads the answer out of the JSON data payload.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, inner, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("answered", obj.get("status").?.string);
    try testing.expectEqualStrings("staging", obj.get("answer").?.string);
    try testing.expectEqual(@as(i64, 1), obj.get("answers_count").?.integer);
    // The data payload is JSON, not XML tags.
    try testing.expect(std.mem.indexOf(u8, inner, "<status>") == null);
}

test "ask_user_answer: parameters is mandatory in the envelope" {
    const a = testing.allocator;
    const inner = try ask_user_mod.buildAskUserJson(a, .{ .status = .skipped, .question_id = "q_2" });
    defer a.free(inner);

    const envelope = try wrapToolOutput(a, ask_user_mod.ASK_USER_TOOL_NAME, "{}", true, null, inner);
    defer a.free(envelope);

    // The frontend's `unwrapToolOutput` throws unless tool AND parameters AND
    // success are all present — a rewrite without parameters made the card
    // fall back to an empty pending render, so every resolved question looked
    // unanswered. An empty object still satisfies the parser.
    try testing.expect(std.mem.indexOf(u8, envelope, "\"parameters\":{}") != null);
}
