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
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const skill_evals_db = nalarcore.skill_evals_db;

pub const SkillEvalsError = error{
    Internal,
    InvalidLimit,
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
    const di = nalarcore.getSingleton() catch return error.Internal;

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
    const di = nalarcore.getSingleton() catch return error.Internal;

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
    };
    const message: []const u8 = switch (err) {
        error.Internal => "Internal server error",
        error.InvalidLimit => "limit must be a positive integer",
    };
    return res.jsonResponse(.{
        .status_code = status,
        .data = try nalarcore.http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
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
