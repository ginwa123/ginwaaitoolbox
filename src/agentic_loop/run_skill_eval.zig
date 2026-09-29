//! The `run_skill_eval` agent tool: the one thing the agent has to do for
//! Skill Evals to happen.
//!
//! ## Why this is one tool and not an orchestration the model performs
//!
//! The prompt rule tells the agent to call this. Everything else is code:
//! which skills to evaluate (read from the ledger, so the agent cannot
//! cherry-pick around the skill it had to work around), what the intrinsic
//! verdict is (Tier 0, deterministic), where the result is stored, and what
//! the summary says. The agent contributes exactly one decision — WHEN — and
//! never the verdict, which is what keeps self-assessment bias out of a
//! feature whose whole job is judging the agent's own choices.
//!
//! ## Zero parameters, on purpose
//!
//! The tool takes no arguments. That is not laziness: an argument naming the
//! skills would be the cherry-picking hole, and a zero-parameter schema also
//! keeps the wire surface to `properties: {}` — nothing to validate, nothing
//! to get wrong.
//!
//! ## Tier 0 only, for now
//!
//! This runs the deterministic half (see `skill_evals_drift.zig`) and stores
//! the session-relative half as unknown. That is a complete, useful, zero-token
//! eval: it answers "is this skill still true?" for the cheapest and most
//! common failure. The LLM judge tier fans out sub-agents and fills the
//! session-relative scores; it is additive and lands on top of this.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const agent = nalarcore.agent;
const logger_mod = nalarcore.loggermod;
const AgentTool = @import("../modules/agent/tools/schemas.zig").AgentTool;

const tools = @import("tools.zig");
const skill_evals_db = @import("skill_evals_db.zig");
const drift = @import("skill_evals_drift.zig");
const migration = @import("../migrations/migration.zig");

const Verdict = skill_evals_db.Verdict;

pub const run_skill_eval_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "run_skill_eval",
        .description =
        \\Evaluate the skills this session actually used. Call it ONCE, after you have finished the user's task and before your final message, when you loaded at least one skill with `use_skill`.
        \\
        \\Takes no arguments: it reads the record of what this session was offered and what it read, so you cannot (and need not) name the skills. It checks whether the paths, commands and facts each skill names are still true against the code as it is now, and records a verdict for a human to review. You are not the judge.
        \\
        \\Cheap and idempotent: evals another session already ran for the same skill content are reused, and a second call in the same session is a no-op rather than a second eval. Skip it when you loaded no skill.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{},
            .required = &.{},
        },
        .system_prompt =
        \\## Skill Evals
        \\
        \\Call `run_skill_eval` once, before your final answer, if this session
        \\loaded a skill. Then report the outcome in one line.
        \\
    },
};

pub const RunOutcome = struct {
    /// The master switch is off. Nothing was read and nothing was written.
    disabled: bool = false,
    /// No skill was loaded or offered this session, so there is nothing to do.
    nothing_loaded: bool = false,
    /// A run already existed for this session. `run_id` names it; nothing was
    /// recomputed. This is the idempotency path, not an error.
    reused: bool = false,
    run_id: []u8 = &.{},
    evaluated: u32 = 0,
    keep: u32 = 0,
    update: u32 = 0,
    needs_human: u32 = 0,
    reused_facts: u32 = 0,
    skipped: u32 = 0,

    pub fn deinit(self: RunOutcome, allocator: std.mem.Allocator) void {
        if (self.run_id.len > 0) allocator.free(self.run_id);
    }
};

pub const RunArgs = struct {
    session_id: []const u8,
    cwd: []const u8,
    model: []const u8 = "",
    profile: []const u8 = "",
    environment: ?*const std.process.Environ.Map,
    enabled: bool,
    /// `skill_evals.max_skills_per_run`.
    max_skills: u32 = 8,
    /// `skill_evals.include_listed_without_loading`.
    include_listed_only: bool = true,
};

/// Insert one result row. Private because it is the only writer of this table
/// today and it is not a primitive anyone else should reach for; when the LLM
/// tier lands it should move next to the fact primitives in `skill_evals_db`.
fn insertResult(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    run_id: []const u8,
    skill_key: []const u8,
    skill_name: []const u8,
    session_id: []const u8,
    status: []const u8,
    verdict: Verdict,
    intrinsic_fact_id: []const u8,
    base_content_hash: []const u8,
    rationale: []const u8,
    reasoning_loop: ?u32,
) !void {
    const loop_str = if (reasoning_loop) |l|
        try std.fmt.allocPrint(allocator, "{d}", .{l})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(loop_str);

    // Every free-text column is COALESCE-wrapped: `exec` binds an empty slice
    // as SQL NULL, and these columns are NOT NULL (Migration 079's class).
    try db.exec(allocator,
        \\INSERT INTO skill_eval_results
        \\    (id, run_id, skill_key, skill_name, session_id, status, verdict,
        \\     intrinsic_fact_id, base_content_hash, rationale, sub_session_id)
        \\VALUES
        \\    (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\     COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\     COALESCE(NULLIF(?, ''), 'needs_human'),
        \\     COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''),
        \\     COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''))
    , &.{
        id,
        run_id,
        skill_key,
        skill_name,
        session_id,
        status,
        verdict.asString(),
        intrinsic_fact_id,
        base_content_hash,
        rationale,
        loop_str,
    });
}

/// Run the eval for one session. Pure with respect to the tool layer: it takes
/// a db and a session id, so it is testable without a live tool turn.
pub fn runEval(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    args: RunArgs,
) !RunOutcome {
    // Defence in depth. The tool is only injected into the tool list when the
    // switch is on, so reaching here disabled means something re-enabled it
    // behind our back — refuse rather than spend anything.
    if (!args.enabled) return .{ .disabled = true };
    if (args.session_id.len == 0) return .{ .nothing_loaded = true };

    const set = try skill_evals_db.sessionSkillSet(allocator, db, args.session_id);
    defer skill_evals_db.freeSessionSkillSet(allocator, set);
    if (set.len == 0) return .{ .nothing_loaded = true };

    const context_key = if (args.cwd.len > 0)
        try std.fmt.allocPrint(allocator, "{s}@", .{args.cwd})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(context_key);

    const run_id = try std.fmt.allocPrint(allocator, "skilleval_{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    errdefer allocator.free(run_id);
    // NOTE: ownership of `run_id` moves to `outcome` below. The `errdefer`
    // above covers an early return; once the outcome exists it is the owner and
    // the caller frees it via `deinit`. Duping it here as well leaked one
    // allocation per run (caught by the testing allocator).

    const claimed = skill_evals_db.claimRun(
        allocator,
        db,
        run_id,
        args.session_id,
        "self_prompt",
        "",
        "session",
        args.cwd,
        context_key,
        args.profile,
        args.model,
    ) catch |err| {
        if (logger) |l| l.warnFmt("skill eval: could not claim a run: {s}", .{@errorName(err)});
        return .{ .nothing_loaded = true };
    };
    if (!claimed) {
        // The agent emitted two calls in one turn, or already evaluated this
        // session. Return the existing run rather than doing the work twice.
        allocator.free(run_id);
        return .{ .reused = true };
    }

    var outcome = RunOutcome{ .run_id = run_id };
    var ordinal: u32 = 0;

    for (set) |use| {
        if (outcome.evaluated >= args.max_skills) {
            outcome.skipped += 1;
            continue;
        }
        // A skill that was only OFFERED is still worth judging: "the agent was
        // handed the right skill and ignored it" is a real finding. It is
        // configurable because it is also the noisier half.
        if (!use.loaded and !args.include_listed_only) {
            outcome.skipped += 1;
            continue;
        }

        ordinal += 1;
        const result_id = try std.fmt.allocPrint(allocator, "{s}_r{d}", .{ run_id, ordinal });
        defer allocator.free(result_id);

        const skill_key = try std.fmt.allocPrint(allocator, "global:{s}", .{use.skill_name});
        defer allocator.free(skill_key);

        // Current body: local scope first, then global — the same order
        // `use_skill` resolves with, so we judge the file the agent would get.
        const body_opt = nalarcore.skill_mod.parse_skill(allocator, io, use.skill_name, false, args.environment) orelse
            nalarcore.skill_mod.parse_skill(allocator, io, use.skill_name, true, args.environment);

        if (body_opt == null) {
            // The skill is gone from disk, or unreadable. That is a finding in
            // itself, and it is honest to say so rather than to invent a body.
            try insertResult(allocator, db, result_id, run_id, skill_key, use.skill_name, args.session_id, "needs_human", .needs_human, "", "", "the skill body could not be read", use.first_loop_index);
            outcome.needs_human += 1;
            outcome.evaluated += 1;
            continue;
        }
        const body = body_opt.?;
        defer allocator.free(body);

        var hash_buf: [64]u8 = undefined;
        skill_evals_db.sha256Hex(body, &hash_buf);
        const body_hash = hash_buf[0..];

        // The identity of the question: this body, in this repo. Reusing it is
        // what makes two sessions evaluating one skill cost one computation.
        const fact_key_hash = try allocator.dupe(u8, body_hash);
        defer allocator.free(fact_key_hash);

        const claim = skill_evals_db.claimFact(allocator, db, result_id, skill_key, fact_key_hash, context_key) catch |err| blk: {
            if (logger) |l| l.warnFmt("skill eval: claimFact failed for '{s}': {s}", .{ use.skill_name, @errorName(err) });
            break :blk skill_evals_db.FactClaim.held;
        };

        var analysis = try drift.analyse(allocator, io, args.cwd, body);
        defer analysis.deinit(allocator);

        var intrinsic_fact_id: []const u8 = "";
        var verdict = skill_evals_db.decideVerdict(analysis.verdict, analysis.has_high);

        switch (claim) {
            .won => {
                _ = skill_evals_db.publishFact(allocator, db, result_id, .{
                    .verdict = analysis.verdict,
                    .freshness = if (analysis.missing_count > 0) 1 else 3,
                    .findings_json = analysis.findings_json,
                    .missing_paths_json = analysis.missing_paths_json,
                    .evidence_json = analysis.findings_json,
                }) catch false;
                intrinsic_fact_id = result_id;
            },
            .reusable => {
                outcome.reused_facts += 1;
                if (skill_evals_db.readFact(allocator, db, skill_key, fact_key_hash, context_key) catch null) |fact| {
                    defer fact.deinit(allocator);
                    verdict = skill_evals_db.decideVerdict(fact.verdict, false);
                }
            },
            .held => {
                // Someone else is computing the same question right now. Do not
                // duplicate it; record what Tier 0 already knows and let the
                // owner's intrinsic verdict take over when it lands.
                outcome.reused_facts += 1;
            },
        }

        const changed = use.loaded and use.content_hash.len > 0 and !std.mem.eql(u8, use.content_hash, body_hash);
        const rationale = if (changed)
            try std.fmt.allocPrint(allocator, "the body changed since this session read it; {d} path check(s) failed", .{analysis.missing_count})
        else if (analysis.missing_count > 0)
            try std.fmt.allocPrint(allocator, "{d} referenced path(s) no longer exist", .{analysis.missing_count})
        else
            try allocator.dupe(u8, "Tier 0 found no problem; the session-relative half is not yet evaluated");
        defer allocator.free(rationale);

        try insertResult(allocator, db, result_id, run_id, skill_key, use.skill_name, args.session_id, "done", verdict, intrinsic_fact_id, body_hash, rationale, use.first_loop_index);

        outcome.evaluated += 1;
        switch (verdict) {
            .keep => outcome.keep += 1,
            .update => outcome.update += 1,
            else => outcome.needs_human += 1,
        }

        // Distinguish "offered and ignored" explicitly in the log, because it is
        // the one finding that is about the AGENT rather than about the skill.
        if (logger) |l| {
            if (!use.loaded and use.listed) {
                l.debugFmt("skill eval: '{s}' was offered and never loaded", .{use.skill_name});
            }
        }
    }

    skill_evals_db.finishRun(allocator, db, run_id, "done", 0, "") catch |err| {
        if (logger) |l| l.warnFmt("skill eval: could not finalize run {s}: {s}", .{ run_id, @errorName(err) });
    };
    return outcome;
}

pub fn execRunSkillEval(ctx: tools.ToolExecContext, tc: agent.ToolCall) !tools.ToolExecResult {
    const enabled = ctx.config.skill_evals.enabled;
    const outcome = runEval(ctx.allocator, ctx.io, ctx.db, ctx.logger, .{
        .session_id = ctx.session_id,
        .cwd = ctx.cwd,
        .model = ctx.model,
        .profile = ctx.selected_profile_model,
        .environment = ctx.environment,
        .enabled = enabled,
        .max_skills = ctx.config.skill_evals.max_skills_per_run,
        .include_listed_only = ctx.config.skill_evals.include_listed_without_loading,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "run_skill_eval failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(msg);
        const out = try tools.wrapToolOutput(ctx.allocator, "run_skill_eval", tc.function.arguments, false, msg, "");
        return tools.ToolExecResult{ .output = out, .output_allocated = true };
    };
    defer outcome.deinit(ctx.allocator);

    const inner = if (outcome.disabled)
        try ctx.allocator.dupe(u8, "{\"status\":\"disabled\",\"message\":\"Skill Evals are off. Ask the user to set skill_evals.enabled in config.json.\"}")
    else if (outcome.reused)
        try ctx.allocator.dupe(u8, "{\"status\":\"already_evaluated\",\"message\":\"This session's skills were already evaluated; nothing was recomputed.\"}")
    else if (outcome.nothing_loaded)
        try ctx.allocator.dupe(u8, "{\"status\":\"nothing_loaded\",\"message\":\"No skill was loaded or offered this session, so there is nothing to evaluate.\"}")
    else
        try std.fmt.allocPrint(ctx.allocator, "{{\"status\":\"done\",\"run_id\":{f},\"evaluated\":{d},\"keep\":{d},\"update\":{d},\"needs_human\":{d},\"reused_shared_facts\":{d},\"skipped\":{d}}}", .{
            std.json.fmt(outcome.run_id, .{}),
            outcome.evaluated,
            outcome.keep,
            outcome.update,
            outcome.needs_human,
            outcome.reused_facts,
            outcome.skipped,
        });
    defer ctx.allocator.free(inner);

    const out = try tools.wrapToolOutput(ctx.allocator, "run_skill_eval", tc.function.arguments, true, null, inner);
    return tools.ToolExecResult{ .output = out, .output_allocated = true };
}

// ─── tests ───────────────────────────────────────────────────────────────

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
    return .{ .db = db, .threaded = threaded };
}

fn seedLoaded(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, io: std.Io, session_id: []const u8, name: []const u8) !void {
    const result = try std.fmt.allocPrint(alloc,
        "{{\"tool\":\"use_skill\",\"success\":true,\"data\":{{\"skill_name\":{f},\"content\":\"body\",\"loaded\":true}},\"error\":null,\"v\":1}}",
        .{std.json.fmt(name, .{})});
    defer alloc.free(result);
    skill_evals_db.recordSkillToolEvents(alloc, db, null, .{
        .io = io,
        .session_id = session_id,
        .tool_name = "use_skill",
        .tool_result_json = result,
        .loop_index = 3,
        .llm_history_id = "h1",
    });
}

fn countResults(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend) !i64 {
    var q = try db.query(alloc, "SELECT COUNT(*) FROM skill_eval_results", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
}

test "runEval does nothing at all when the switch is off" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "whatever");
    const out = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = false,
    });
    defer out.deinit(alloc);

    try testing.expect(out.disabled);
    // Nothing read, nothing written: "off" must not mean "off, but it still
    // touched the database".
    try testing.expectEqual(@as(i64, 0), try countResults(alloc, &ctx.db));
}

test "runEval reports nothing_loaded for a session with no ledger rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const out = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_empty",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
    });
    defer out.deinit(alloc);

    try testing.expect(out.nothing_loaded);
    // No run should be left behind for a session that had nothing to evaluate.
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_eval_runs", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "a skill whose body cannot be read is an honest needs_human, not a guess" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // In the ledger, but there is no such skill on disk anywhere.
    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "definitely-not-a-real-skill-xyz");
    const out = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
    });
    defer out.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), out.evaluated);
    try testing.expectEqual(@as(u32, 1), out.needs_human);
    try testing.expectEqual(@as(u32, 0), out.keep);
    try testing.expectEqual(@as(i64, 1), try countResults(alloc, &ctx.db));

    var q = try ctx.db.query(alloc, "SELECT status, verdict, rationale FROM skill_eval_results", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("needs_human", row.values[0]);
    try testing.expectEqualStrings("needs_human", row.values[1]);
    try testing.expectEqualStrings("the skill body could not be read", row.values[2]);
}

test "a second call in the same session reuses the run instead of redoing it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "definitely-not-a-real-skill-xyz");
    const first = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
    });
    defer first.deinit(alloc);
    try testing.expect(!first.reused);

    // The agent can emit this twice in one turn. The partial unique index is
    // the arbiter, and the loser must not evaluate again.
    const second = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
    });
    defer second.deinit(alloc);
    try testing.expect(second.reused);
    try testing.expectEqual(@as(i64, 1), try countResults(alloc, &ctx.db));
}

test "max_skills bounds the work and records the remainder as skipped" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "fake-one");
    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "fake-two");
    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "fake-three");

    const out = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
        .max_skills = 2,
    });
    defer out.deinit(alloc);

    try testing.expectEqual(@as(u32, 2), out.evaluated);
    try testing.expectEqual(@as(u32, 1), out.skipped);
    try testing.expectEqual(@as(i64, 2), try countResults(alloc, &ctx.db));
}
