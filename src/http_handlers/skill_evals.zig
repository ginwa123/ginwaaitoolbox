//! `GET /api/skill-evals/runs` and `GET /api/skill-evals/summary` — the READ
//! surface for Skill Evals.
//!
//! Why a sibling prefix rather than routes under `/api/skills/`: `matchRoute`
//! walks the route table in registration order and returns on first hit, so a
//! literal like `/api/skills/evals` registered after `/api/skills/:name`
//! (main.zig:602) would be captured with `name = "evals"`. A sibling prefix has
//! no such interaction at all, which is cheaper than remembering the ordering
//! rule forever. See docs/plans/2026-09-27-skill-evals.md §4.10.
//!
//! Query parameters only, no path parameters, for the same reason: `/runs` and
//! `/summary` are literals, so the wire surface cannot be shadowed by a later
//! route addition. `run_id` selects one run and additionally returns its
//! results; `session_id` filters; `limit` caps the list.
//!
//! Layered like the other read handlers: a `useCase` that resolves the
//! singleton and does the DB work, and a thin handler that maps a closed error
//! set to status codes.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const skill_evals_db = pabrikcore.skill_evals_db;
const skill_eval_events = pabrikcore.skill_eval_events;

pub const SkillEvalsError = error{
    Internal,
    InvalidLimit,
    MissingResultId,
    ResultNotFound,
    AlreadyApplied,
    Stale,
    NotApplicable,
};

pub const MAX_LIMIT: u32 = 100;
pub const DEFAULT_LIMIT: u32 = 25;

const RunJson = struct {
    id: []const u8,
    session_id: []const u8,
    status: []const u8,
    trigger: []const u8,
    scope: []const u8,
    skill_name: []const u8,
    @"error": []const u8,
    total_tokens: i64,
    created_at: []const u8,
};

const ResultJson = struct {
    id: []const u8,
    skill_name: []const u8,
    skill_key: []const u8,
    status: []const u8,
    verdict: []const u8,
    freshness: u8,
    accuracy: u8,
    duplication: u8,
    rationale: []const u8,
    /// A JSON *string* here (the stored array), because the column holds JSON
    /// text. The reader parses it; emitting it raw would need a custom
    /// serializer for one field.
    missing_paths: []const u8,
    /// Whether the intrinsic half came from the shared fact cache rather than
    /// being computed for this session.
    shared_fact: bool,
    /// The skill body the verdict was computed against, verbatim, and the text
    /// the verdict would write over it. Together they are the before/after a
    /// human needs to judge a proposal. Both empty on a Tier-0-only run, which
    /// is why they are nullable-in-spirit rather than required.
    content_at_use: []const u8,
    proposed_diff: []const u8,
    applied: bool,
    apply_action: []const u8,
};

const CountJson = struct {
    verdict: []const u8,
    n: i64,
};

fn parseLimit(raw: ?[]const u8) SkillEvalsError!u32 {
    const s = raw orelse return DEFAULT_LIMIT;
    if (s.len == 0) return DEFAULT_LIMIT;
    const n = std.fmt.parseInt(u32, s, 10) catch return error.InvalidLimit;
    if (n == 0) return error.InvalidLimit;
    return if (n > MAX_LIMIT) MAX_LIMIT else n;
}

// =====================================================================
// Use cases
// =====================================================================

fn runsUseCase(
    allocator: std.mem.Allocator,
    run_id: []const u8,
    session_id: []const u8,
    limit: u32,
) SkillEvalsError![]const u8 {
    const di = pabrikcore.getSingleton() catch return error.Internal;

    const runs = skill_evals_db.listRuns(allocator, di.db, .{
        .run_id = run_id,
        .session_id = session_id,
        .limit = limit,
    }) catch return error.Internal;
    defer skill_evals_db.freeRunRows(allocator, runs);

    var run_json: std.ArrayList(RunJson) = .empty;
    defer run_json.deinit(allocator);
    for (runs) |r| {
        run_json.append(allocator, .{
            .id = r.id,
            .session_id = r.session_id,
            .status = r.status,
            .trigger = r.trigger,
            .scope = r.scope,
            .skill_name = r.skill_name,
            .@"error" = r.err,
            .total_tokens = r.total_tokens,
            .created_at = r.created_at,
        }) catch return error.Internal;
    }

    // Results only when one run was asked for. Listing every result of every
    // run would be a much bigger response for no extra information.
    var result_rows: []skill_evals_db.ResultRow = &.{};
    var owns_results = false;
    if (run_id.len > 0) {
        result_rows = skill_evals_db.listResults(allocator, di.db, run_id) catch return error.Internal;
        owns_results = true;
    }
    defer if (owns_results) skill_evals_db.freeResultRows(allocator, result_rows);

    var result_json: std.ArrayList(ResultJson) = .empty;
    defer result_json.deinit(allocator);
    for (result_rows) |r| {
        result_json.append(allocator, .{
            .id = r.id,
            .skill_name = r.skill_name,
            .skill_key = r.skill_key,
            .status = r.status,
            .verdict = r.verdict,
            .freshness = r.freshness,
            .accuracy = r.accuracy,
            .duplication = r.duplication,
            .rationale = r.rationale,
            .missing_paths = r.missing_paths_json,
            .shared_fact = r.intrinsic_fact_id.len > 0,
            .content_at_use = r.content_at_use,
            .proposed_diff = r.proposed_diff,
            .applied = r.applied,
            .apply_action = r.apply_action,
        }) catch return error.Internal;
    }

    return std.json.Stringify.valueAlloc(allocator, .{
        .runs = run_json.items,
        .results = result_json.items,
    }, .{}) catch return error.Internal;
}

fn summaryUseCase(
    allocator: std.mem.Allocator,
    session_id: []const u8,
) SkillEvalsError![]const u8 {
    const di = pabrikcore.getSingleton() catch return error.Internal;

    const counts = skill_evals_db.verdictCounts(allocator, di.db, session_id) catch return error.Internal;
    defer skill_evals_db.freeVerdictCounts(allocator, counts);

    var out: std.ArrayList(CountJson) = .empty;
    defer out.deinit(allocator);
    var total: i64 = 0;
    for (counts) |c| {
        total += c.n;
        out.append(allocator, .{ .verdict = c.verdict, .n = c.n }) catch return error.Internal;
    }

    return std.json.Stringify.valueAlloc(allocator, .{
        .counts = out.items,
        .total = total,
    }, .{}) catch return error.Internal;
}

// =====================================================================
// Increment 7 — the apply endpoint
// =====================================================================

/// What the apply endpoint did, for the response body.
const ApplyJson = struct {
    result_id: []const u8,
    skill_name: []const u8,
    action: []const u8,
    applied: bool,
    message: []const u8,
};

/// Apply one verdict.
///
/// The order matters and is the whole design:
///
///   1. Read the result. A missing row is a 404, not a 500.
///   2. `claimApply` takes the exclusive right to apply it. Two clicks, two
///      clients or two humans cannot both write the skill — the loser is told
///      `already_applied` rather than silently overwriting.
///   3. Re-check the body hash. Between the eval and the click a human may have
///      edited the skill, and applying a verdict computed against the OLD body
///      would write a stale proposal over fresh work. On a mismatch we
///      `releaseApply` (or the verdict becomes unapplicable forever) and
///      `markResultStale` (so the UI can offer a re-evaluate), then 409.
///   4. Only then is the action recorded.
///
/// `apply_mode` is deliberately NOT consulted here: this endpoint is the human
/// clicking Apply, which is the `propose` flow's terminal step. The automatic
/// modes are a separate, later decision.
fn applyUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    result_id: []const u8,
    action: []const u8,
) SkillEvalsError![]const u8 {
    if (result_id.len == 0) return error.MissingResultId;

    const di = pabrikcore.getSingleton() catch return error.Internal;
    const db = di.db;

    const row = (skill_evals_db.readResultById(allocator, db, result_id) catch return error.Internal) orelse
        return error.ResultNotFound;
    defer row.deinit(allocator);

    // A verdict that is already stale is not applicable — the body moved on and
    // the proposal no longer describes it.
    if (std.mem.eql(u8, row.status, "stale")) return error.Stale;

    const claim = skill_evals_db.claimApply(allocator, db, result_id, action) catch return error.Internal;
    switch (claim) {
        .missing => return error.ResultNotFound,
        .already_applied => return error.AlreadyApplied,
        .won => {},
    }

    // The hash re-check. `base_content_hash` is the body the eval judged; if the
    // file on disk no longer hashes to it, the verdict is about a body that is
    // gone.
    const current = readCurrentSkillHash(allocator, io, di, row.skill_name, row.session_id) catch null;
    if (current) |hash| {
        defer allocator.free(hash);
        if (row.base_content_hash.len > 0 and !std.mem.eql(u8, hash, row.base_content_hash)) {
            // Give the claim back FIRST, or the verdict can never be applied
            // again even after a re-evaluate.
            skill_evals_db.releaseApply(allocator, db, result_id) catch {};
            skill_evals_db.markResultStale(allocator, db, result_id) catch {};
            return error.Stale;
        }
    }

    emitApplied(allocator, di, result_id);

    return std.json.Stringify.valueAlloc(allocator, ApplyJson{
        .result_id = result_id,
        .skill_name = row.skill_name,
        .action = action,
        .applied = true,
        .message = "the verdict was recorded as applied",
    }, .{}) catch return error.Internal;
}

/// Tell the UI a verdict was applied, so the Evals tab can refresh. Emitted
/// after the claim is recorded; a failure here must not fail the apply.
fn emitApplied(
    allocator: std.mem.Allocator,
    di: *pabrikcore.ContextIPCTui,
    result_id: []const u8,
) void {
    skill_eval_events.emitSkillEvalEvent(allocator, di.event_bus, .{
        .action = "result_applied",
        .result_id = result_id,
    });
}

/// Hash the skill body as it is on disk right now, or null when it cannot be
/// read. Local scope first, then global — the same order `use_skill` resolves
/// with, so we compare against the file the agent would actually get.
///
/// `session_id` supplies the repo root. The server process's cwd is NOT the
/// session's repo (it is usually a worktree), so hashing the local tier
/// against it re-hashes the wrong file — or nothing at all — and a live verdict
/// gets refused as stale.
fn readCurrentSkillHash(
    allocator: std.mem.Allocator,
    io: std.Io,
    di: *pabrikcore.ContextIPCTui,
    skill_name: []const u8,
    session_id: []const u8,
) !?[]u8 {
    const session_repo = try pabrikcore.workspace_scope.sessionCwd(allocator, di.db, session_id);
    defer if (session_repo) |p| allocator.free(p);

    const body = pabrikcore.skill_mod.parse_skill(allocator, io, skill_name, session_repo, false, di.environment) orelse
        pabrikcore.skill_mod.parse_skill(allocator, io, skill_name, session_repo, true, di.environment) orelse
        return null;
    defer allocator.free(body);
    var buf: [64]u8 = undefined;
    skill_evals_db.sha256Hex(body, &buf);
    return try allocator.dupe(u8, buf[0..]);
}

// =====================================================================
// Handlers
// =====================================================================

/// Map the closed error set to a status code and message. Two exhaustive
/// switches, so adding an error variant fails to compile rather than falling
/// through to a 500.
fn errorResponse(
    allocator: std.mem.Allocator,
    res: gserverz.HttpResponse,
    err: SkillEvalsError,
) !gserverz.HttpResponse {
    const status: u16 = switch (err) {
        error.Internal => 500,
        error.InvalidLimit => 400,
        error.MissingResultId => 400,
        error.ResultNotFound => 404,
        error.AlreadyApplied => 409,
        error.Stale => 409,
        error.NotApplicable => 409,
    };
    const message: []const u8 = switch (err) {
        error.Internal => "Internal server error",
        error.InvalidLimit => "limit must be a positive integer",
        error.MissingResultId => "result_id is required",
        error.ResultNotFound => "no such result",
        error.AlreadyApplied => "this verdict has already been applied",
        error.Stale => "the skill body changed since this verdict was computed; re-evaluate it",
        error.NotApplicable => "this verdict cannot be applied",
    };
    return res.jsonResponse(.{
        .status_code = status,
        .data = try pabrikcore.http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
    });
}

pub fn skillEvalsRunsHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const run_id = req.query.get("run_id") orelse "";
    const session_id = req.query.get("session_id") orelse "";

    const limit = parseLimit(req.query.get("limit")) catch |err| return errorResponse(allocator, res, err);
    const body = runsUseCase(allocator, run_id, session_id, limit) catch |err| return errorResponse(allocator, res, err);

    return res.jsonResponse(.{ .status_code = 200, .data = body });
}

pub fn skillEvalsSummaryHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.query.get("session_id") orelse "";

    const body = summaryUseCase(allocator, session_id) catch |err| return errorResponse(allocator, res, err);

    return res.jsonResponse(.{ .status_code = 200, .data = body });
}

/// `POST /api/skill-evals/results/apply?result_id=...&action=...`
///
/// A POST because it mutates: it records that a human accepted a verdict. The
/// `result_id` is a QUERY parameter rather than a path segment on purpose — a
/// `/results/:result_id/apply` route would put a `:param` under this prefix,
/// and `matchRoute` walks the table in registration order, so any literal
/// registered after it would be shadowed. Keeping every route here a literal
/// removes the ordering rule from the design entirely.
pub fn skillEvalsApplyHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const result_id = req.query.get("result_id") orelse "";
    const action = req.query.get("action") orelse "apply";

    const body = applyUseCase(allocator, ctx.io, result_id, action) catch |err| return errorResponse(allocator, res, err);

    return res.jsonResponse(.{ .status_code = 200, .data = body });
}
