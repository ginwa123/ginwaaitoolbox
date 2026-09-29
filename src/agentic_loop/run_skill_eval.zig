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
    /// The run could not even be claimed (a database error). Distinct from
    /// `nothing_loaded`, which would be a false statement about the ledger.
    failed: bool = false,
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
    /// `skill_evals.fact_lease_seconds` — how long a `computing` lease may sit
    /// before another session may take it over.
    fact_lease_seconds: u32 = 300,
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
) !void {
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
        // `sub_session_id` belongs to the LLM judge tier (it will name the
        // sub-agent that produced the session-relative half). The transcript
        // anchor for Tier 0 is the LEDGER's loop_index / llm_history_id, which
        // is where it belongs — so this stays empty rather than holding a
        // value the column does not mean.
        "",
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
        // `errdefer` does not fire on a normal return, so the id must be freed
        // here. Reporting this as `nothing_loaded` would also be a lie — the
        // ledger was already read and it was not empty.
        allocator.free(run_id);
        return .{ .failed = true };
    };
    if (!claimed) {
        // The agent emitted two calls in one turn, or already evaluated this
        // session. Return the existing run rather than doing the work twice.
        allocator.free(run_id);
        return .{ .reused = true };
    }

    // A run row now exists and holds the session's one-shot slot. If anything
    // below fails, the row must not be left `running` — that would both show a
    // permanently spinning run and, because the partial unique index still
    // holds it, block every later eval for this session forever.
    errdefer skill_evals_db.finishRun(allocator, db, run_id, "error", 0, "runEval failed mid-loop") catch {};

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
            try insertResult(allocator, db, result_id, run_id, skill_key, use.skill_name, args.session_id, "needs_human", .needs_human, "", "", "the skill body could not be read");
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
        // Set only on the reuse path, where the id is a fresh dupe that this
        // iteration owns. The `.won` path points at `result_id`, which is
        // already deferred by the loop body.
        var owned_fact_id: ?[]u8 = null;
        defer if (owned_fact_id) |id| allocator.free(id);
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
                    // Link the result to the fact it reused. Without this the
                    // result row carries a verdict with no evidence: the LEFT
                    // JOIN in `listResults` finds nothing, so the scores read 0
                    // and `shared_fact` reports false for exactly the rows that
                    // WERE shared. `fact.id` is freed by the `defer` above, so
                    // it must be duped, not aliased.
                    owned_fact_id = try allocator.dupe(u8, fact.id);
                    intrinsic_fact_id = owned_fact_id.?;
                }
            },
            .held => {
                // Someone else is computing the same question right now — or a
                // crashed owner left a lease behind. Try to take over an
                // EXPIRED lease; a live one is left alone so the work is not
                // duplicated. Without this a single crash poisons the fact for
                // that question forever, because the unique index blocks every
                // later claim and nothing ever reclaims the row.
                const stolen = skill_evals_db.stealFact(
                    allocator,
                    db,
                    skill_key,
                    fact_key_hash,
                    context_key,
                    args.fact_lease_seconds,
                ) catch false;
                if (stolen) {
                    _ = skill_evals_db.publishFact(allocator, db, result_id, .{
                        .verdict = analysis.verdict,
                        .freshness = if (analysis.missing_count > 0) 1 else 3,
                        .findings_json = analysis.findings_json,
                        .missing_paths_json = analysis.missing_paths_json,
                        .evidence_json = analysis.findings_json,
                    }) catch false;
                    intrinsic_fact_id = result_id;
                } else {
                    // A live owner exists. Record what Tier 0 already knows and
                    // let the owner's intrinsic verdict take over when it lands.
                    outcome.reused_facts += 1;
                }
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

        try insertResult(allocator, db, result_id, run_id, skill_key, use.skill_name, args.session_id, "done", verdict, intrinsic_fact_id, body_hash, rationale);

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
        .fact_lease_seconds = ctx.config.skill_evals.fact_lease_seconds,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "run_skill_eval failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(msg);
        const out = try tools.wrapToolOutput(ctx.allocator, "run_skill_eval", tc.function.arguments, false, msg, "");
        return tools.ToolExecResult{ .output = out, .output_allocated = true };
    };
    defer outcome.deinit(ctx.allocator);

    const inner = if (outcome.disabled)
        try ctx.allocator.dupe(u8, "{\"status\":\"disabled\",\"message\":\"Skill Evals are off. Ask the user to set skill_evals.enabled in config.json.\"}")
    else if (outcome.failed)
        try ctx.allocator.dupe(u8, "{\"status\":\"failed\",\"message\":\"The eval could not be started because of a database error. Nothing was evaluated.\"}")
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

test "max_skills = 0 evaluates nothing and does not crash" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "fake-one");
    try seedLoaded(alloc, &ctx.db, ctx.threaded.io(), "sess_1", "fake-two");

    const out = try runEval(alloc, ctx.threaded.io(), &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
        .max_skills = 0,
    });
    defer out.deinit(alloc);

    try testing.expectEqual(@as(u32, 0), out.evaluated);
    try testing.expectEqual(@as(u32, 2), out.skipped);
    try testing.expectEqual(@as(i64, 0), try countResults(alloc, &ctx.db));
}

// ─── the publish / reuse paths ───────────────────────────────────────────
//
// These need a skill that actually EXISTS on disk, because every test above
// names a skill that does not and therefore exits at the "body could not be
// read" branch. That branch is ~15% of runEval; the publish, reuse and
// changed-body paths below are the rest, and they are where the fact cache
// lives.

/// Write `<xdg>/nalar/skills/<name>/SKILL.MD` and return the xdg root. The
/// caller owns the tmpdir and must remove it.
///
/// The GLOBAL path is used rather than the local one because
/// `get_local_skills_path` resolves against the PROCESS cwd, which a test
/// cannot change; the global path is resolved from the environment map the
/// caller passes in, which a test fully controls.
fn seedSkillOnDisk(alloc: std.mem.Allocator, io: std.Io, xdg_root: []const u8, name: []const u8, body: []const u8) !void {
    const dir = try std.fs.path.join(alloc, &.{ xdg_root, "nalar", "skills", name });
    defer alloc.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const file = try std.fs.path.join(alloc, &.{ dir, "SKILL.MD" });
    defer alloc.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = body });
}

fn makeTmpRoot(alloc: std.mem.Allocator, io: std.Io, tag: []const u8) ![]u8 {
    var buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "skilleval-test-{s}-{d}", .{
        tag,
        std.Io.Timestamp.now(io, .real).nanoseconds,
    });
    const root = try std.fs.path.join(alloc, &.{ "/tmp", name });
    try std.Io.Dir.cwd().createDirPath(io, root);
    return root;
}

/// An environment map whose XDG_CONFIG_HOME points at `xdg_root`, so
/// `parse_skill(..., is_global=true, env)` finds the seeded skill.
fn makeEnv(alloc: std.mem.Allocator, xdg_root: []const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(alloc);
    try env.put("XDG_CONFIG_HOME", xdg_root);
    return env;
}

test "a real skill is published as a fact and linked from the result" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    const root = try makeTmpRoot(alloc, io, "publish");
    defer {
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        alloc.free(root);
    }
    var env = try makeEnv(alloc, root);
    defer env.deinit();

    // A body whose only reference resolves, so Tier 0 says `keep`.
    const body =
        \\---
        \\name: real-skill
        \\description: a skill that exists
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    try seedSkillOnDisk(alloc, io, root, "real-skill", body);
    try seedLoaded(alloc, &ctx.db, io, "sess_1", "real-skill");

    const out = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = ".",
        .environment = &env,
        .enabled = true,
    });
    defer out.deinit(alloc);

    try testing.expectEqual(@as(u32, 1), out.evaluated);
    try testing.expectEqual(@as(u32, 1), out.keep);
    try testing.expectEqual(@as(u32, 0), out.reused_facts);

    // The FACT must exist and be published (not left as a `computing` lease).
    var fq = try ctx.db.query(alloc,
        "SELECT verdict_intrinsic, freshness FROM skill_eval_facts", &.{});
    defer fq.deinit();
    const frow = (try fq.next()) orelse return error.RowMissing;
    defer frow.deinit(alloc);
    try testing.expectEqualStrings("keep", frow.values[0]);
    try testing.expectEqualStrings("3", frow.values[1]);

    // And the RESULT must point at it, or the LEFT JOIN loses the evidence.
    var rq = try ctx.db.query(alloc,
        "SELECT intrinsic_fact_id, base_content_hash, status FROM skill_eval_results", &.{});
    defer rq.deinit();
    const rrow = (try rq.next()) orelse return error.RowMissing;
    defer rrow.deinit(alloc);
    try testing.expect(rrow.values[0].len > 0);
    try testing.expectEqualStrings("done", rrow.values[2]);
    // The base hash must be the hash of the body that was read.
    var expected: [64]u8 = undefined;
    skill_evals_db.sha256Hex(body, &expected);
    try testing.expectEqualStrings(expected[0..], rrow.values[1]);
}

test "a second session reuses the shared fact AND links the result to it" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    const root = try makeTmpRoot(alloc, io, "reuse");
    defer {
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        alloc.free(root);
    }
    var env = try makeEnv(alloc, root);
    defer env.deinit();

    const body =
        \\---
        \\name: shared-skill
        \\description: shared
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    try seedSkillOnDisk(alloc, io, root, "shared-skill", body);

    // Session A computes and publishes the fact.
    try seedLoaded(alloc, &ctx.db, io, "sess_a", "shared-skill");
    const a = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_a",
        .cwd = ".",
        .environment = &env,
        .enabled = true,
    });
    defer a.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), a.reused_facts);

    // Session B evaluates the SAME body in the same repo: the fact is reused.
    try seedLoaded(alloc, &ctx.db, io, "sess_b", "shared-skill");
    const b = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_b",
        .cwd = ".",
        .environment = &env,
        .enabled = true,
    });
    defer b.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), b.reused_facts);
    try testing.expectEqual(@as(u32, 1), b.keep);

    // Exactly one fact for the question — the cache did its job.
    var fq = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_eval_facts", &.{});
    defer fq.deinit();
    const frow = (try fq.next()) orelse return error.RowMissing;
    defer frow.deinit(alloc);
    try testing.expectEqualStrings("1", frow.values[0]);

    // BOTH results must carry the fact id. This is the assertion that catches
    // the `.reusable` branch dropping it: without the link the LEFT JOIN finds
    // nothing, the scores read 0, and `shared_fact` reports false for exactly
    // the row that WAS shared.
    var rq = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM skill_eval_results WHERE intrinsic_fact_id != ''", &.{});
    defer rq.deinit();
    const rrow = (try rq.next()) orelse return error.RowMissing;
    defer rrow.deinit(alloc);
    try testing.expectEqualStrings("2", rrow.values[0]);
}

test "a body edited between the read and the eval is reported as changed" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    const root = try makeTmpRoot(alloc, io, "changed");
    defer {
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        alloc.free(root);
    }
    var env = try makeEnv(alloc, root);
    defer env.deinit();

    // The ledger records a hash of the body the session READ...
    try seedLoaded(alloc, &ctx.db, io, "sess_1", "edited-skill");
    // ...but the file on disk is now different.
    const new_body =
        \\---
        \\name: edited-skill
        \\description: edited after the read
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    try seedSkillOnDisk(alloc, io, root, "edited-skill", new_body);

    const out = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = ".",
        .environment = &env,
        .enabled = true,
    });
    defer out.deinit(alloc);

    var q = try ctx.db.query(alloc, "SELECT rationale FROM skill_eval_results", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    // The `changed` branch has its own rationale; nothing else produces it.
    try testing.expect(std.mem.indexOf(u8, row.values[0], "the body changed since this session read it") != null);
}

test "a skill that was only LISTED is still evaluated when configured" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    const root = try makeTmpRoot(alloc, io, "listed");
    defer {
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        alloc.free(root);
    }
    var env = try makeEnv(alloc, root);
    defer env.deinit();

    const body =
        \\---
        \\name: offered-only
        \\description: offered and ignored
        \\---
        \\## Procedure
        \\Read src/agentic_loop/skill_evals_drift.zig
    ;
    try seedSkillOnDisk(alloc, io, root, "offered-only", body);

    // Only a `listed` event — the agent was offered the skill and never read it.
    const listed =
        \\{"tool":"list_skills","success":true,"data":{"global_skills":[{"name":"offered-only","description":"d","path":"/p"}],"local_skills":[],"cwd":"/cwd"},"error":null,"v":1}
    ;
    skill_evals_db.recordSkillToolEvents(alloc, &ctx.db, null, .{
        .io = io,
        .session_id = "sess_1",
        .tool_name = "list_skills",
        .tool_result_json = listed,
        .loop_index = 1,
        .llm_history_id = "h1",
    });

    // With include_listed_only = true (the default) it IS evaluated: "the agent
    // was handed the right skill and ignored it" is a real finding.
    const with_listed = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = ".",
        .environment = &env,
        .enabled = true,
        .include_listed_only = true,
    });
    defer with_listed.deinit(alloc);
    try testing.expectEqual(@as(u32, 1), with_listed.evaluated);

    // With it off, the same session skips it.
    const without = try runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_2",
        .cwd = ".",
        .environment = &env,
        .enabled = true,
        .include_listed_only = false,
    });
    defer without.deinit(alloc);
    try testing.expectEqual(@as(u32, 0), without.evaluated);
}

test "a run that fails mid-loop is finalized as error, not left running" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const io = ctx.threaded.io();

    // A session with a ledger row, so the run is claimed...
    try seedLoaded(alloc, &ctx.db, io, "sess_1", "whatever");
    // ...then drop the results table so the first insertResult fails. This is
    // the shape of any transient DB error mid-loop.
    try ctx.db.exec(alloc, "DROP TABLE skill_eval_results", &.{});

    const result = runEval(alloc, io, &ctx.db, null, .{
        .session_id = "sess_1",
        .cwd = "/tmp",
        .environment = null,
        .enabled = true,
    });
    // It must propagate an error...
    try testing.expectError(error.PrepareFailed, result);

    // ...and the run must NOT be left `running`. A stuck run both shows a
    // permanently spinning UI and, because the partial unique index still holds
    // the row, blocks every later eval for this session forever.
    var q = try ctx.db.query(alloc, "SELECT status FROM skill_eval_runs", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("error", row.values[0]);
}
