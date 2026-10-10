//! `pabrik headless run` — one agentic turn, no server.
//!
//! ## The rule this file exists to obey
//!
//! Headless mode must not contain a second implementation of the
//! backend. Every decision the HTTP path makes — cwd resolution, the
//! profile snapshot, the tool allowlist, the pending-ask_user
//! abandonment, slash-skill expansion, the session upsert, and which
//! function actually runs the loop — is made by the SAME function the
//! browser reaches.
//!
//! Concretely, `run` calls
//! `pabrikcore.http_handlers.sessionCreateUseCase`, which is the exact
//! `useCase` behind `POST /api/llm/session`. That function ends in
//! `App.emit_run_agent`, which schedules the turn on
//! `ctx.group_emit_session_create` and emits `RunParamsNew` on the event
//! bus; `boot` installs the `ai_worker_flow` subscriber that calls
//! `runAgenticMultiStepnew`. So a headless turn and a browser turn
//! execute the same code, and neither can drift from the other.
//!
//! An earlier draft of this file re-implemented the cwd resolution, the
//! profile snapshot and the session upsert by hand, and drove
//! `runAgenticMultiStepnew` directly. That was the bug: it would have
//! run TWO turns for one message, and the hand-rolled SQL would have
//! drifted from `App.insert_worker` on the next schema change. Both are
//! gone.
//!
//! ## What headless mode adds
//!
//! Exactly one thing the HTTP path does not need: a way to WAIT for the
//! turn and read its result. `emit_run_agent` is fire-and-forget — the
//! handler returns as soon as the work is scheduled. A CLI that printed
//! nothing would be useless, so `run` subscribes to the completion
//! signal the loop already emits and blocks on it, bounded by
//! `--timeout-ms`.
//!
//! ## How completion is detected
//!
//! The loop writes every assistant message through
//! `insertLLMHistories(..., .is_emit_sse = true)`, which emits an
//! `SseEvent` on the event bus under the session id and under `"llm"`.
//! `run` subscribes to both keys and watches for an assistant row whose
//! `finish_reason` is `stop`.
//!
//! This is the same signal the frontend renders from, so a headless run
//! and a browser run agree on when a turn is over.
//!
//! ## The one global
//!
//! `EventBus.subscribe` takes a bare `*const fn (T) void` with no closure
//! context, so the watch state has to live in a module-level `var`. That
//! is safe here because a headless process runs exactly one turn: there is
//! no second session to interleave with. The mutex is what makes the
//! handoff between the loop task and the polling task well-defined.

const std = @import("std");
const pabrikcore = @import("pabrikcore");

const args = @import("args.zig");
const boot_mod = @import("boot.zig");

const workflow = pabrikcore.agentic_loop_mod;
const SseEvent = workflow.SseEvent;

/// What one headless turn produced.
pub const TurnResult = struct {
    session_id: []const u8,
    /// The final assistant text. Empty when the turn produced none.
    assistant_text: []const u8,
    /// The `finish_reason` of the final assistant row: `stop`, `length`,
    /// `tool_calls`, or `cancelled`.
    finish_reason: []const u8,
    /// The `loop_index` of the final assistant row — how many LLM
    /// iterations the turn took, tool-call rounds included.
    iterations: u32,
    /// True when the turn hit `--timeout-ms` before finishing.
    timed_out: bool,
    /// The error name when the loop returned an error, else null.
    error_name: ?[]const u8 = null,
};

/// Shared state between the caller (which polls) and the SSE subscriber
/// (which runs on the loop's Io task). See the module header.
const Watch = struct {
    var mutex: std.Io.Mutex = .init;
    var io: ?std.Io = null;
    var session_id: []const u8 = "";
    var assistant_text: [8192]u8 = undefined;
    var assistant_len: usize = 0;
    var finish_reason: [32]u8 = undefined;
    var finish_len: usize = 0;
    var iterations: u32 = 0;
    var done: bool = false;

    fn reset(io_in: std.Io, sid: []const u8) void {
        Watch.io = io_in;
        Watch.session_id = sid;
        Watch.assistant_len = 0;
        Watch.finish_len = 0;
        Watch.iterations = 0;
        Watch.done = false;
    }

    fn lock() void {
        Watch.mutex.lockUncancelable(Watch.io orelse unreachable);
    }

    fn unlock() void {
        Watch.mutex.unlock(Watch.io orelse unreachable);
    }

    fn recordText(text: []const u8) void {
        const n = @min(text.len, Watch.assistant_text.len);
        @memcpy(Watch.assistant_text[0..n], text[0..n]);
        Watch.assistant_len = n;
    }

    fn recordFinish(reason: []const u8) void {
        const n = @min(reason.len, Watch.finish_reason.len);
        @memcpy(Watch.finish_reason[0..n], reason[0..n]);
        Watch.finish_len = n;
    }
};

/// The SSE subscriber. Fires for every `llm_full` event on every session,
/// so the first thing it does is drop the ones that are not ours.
fn onLlmEvent(ev: SseEvent) void {
    if (Watch.done) return;
    if (!std.mem.eql(u8, ev.session_id, Watch.session_id)) return;

    // The payload is the `SseEventLLMHistory` JSON. Parse only the fields
    // that decide completion; a malformed payload is not worth failing a
    // turn over.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, std.heap.page_allocator, ev.data, .{
        .ignore_unknown_fields = true,
    }) catch return;
    if (parsed != .object) return;
    const obj = parsed.object;

    const role_v = obj.get("role") orelse return;
    if (role_v != .string) return;
    if (!std.mem.eql(u8, role_v.string, "assistant")) return;

    Watch.lock();
    defer Watch.unlock();

    if (obj.get("loop_index")) |v| {
        if (v == .integer and v.integer >= 0) Watch.iterations = @intCast(v.integer);
    }
    if (obj.get("content")) |v| {
        if (v == .string and v.string.len > 0) Watch.recordText(v.string);
    }
    if (obj.get("finish_reason")) |v| {
        if (v == .string) Watch.recordFinish(v.string);
    }

    // `stop` is the loop's normal exit. `length` means it bumped
    // max_tokens and kept going, so it is NOT terminal — a caller that
    // wants a bound on that sets `--timeout-ms`.
    if (Watch.finish_len > 0 and std.mem.eql(u8, Watch.finish_reason[0..Watch.finish_len], "stop")) {
        Watch.done = true;
    }
}

/// Run one turn and wait for it.
///
/// The returned `TurnResult` borrows `session_id` from `allocator`, which
/// the caller owns.
pub fn run(
    allocator: std.mem.Allocator,
    backend: *boot_mod.Backend,
    a: args.RunArgs,
) !TurnResult {
    const io = backend.io;
    const ctx = backend.ctx;

    // ─── Subscribe BEFORE the turn starts ───
    // Subscribing after would miss the first `llm_full` and hang until the
    // timeout. Both keys: the loop emits per-session and on the `"llm"`
    // broadcast, and either one carries the completion signal.
    //
    // The session id is not known until the usecase mints one, so the
    // per-session subscription is added after it returns — the `"llm"`
    // broadcast is subscribed here and already covers the window, because
    // `onLlmEvent` filters on `Watch.session_id`, which is set below.
    try backend.event_bus.subscribe(SseEvent, "llm", onLlmEvent);

    // ─── Drive the REAL session-create funnel ───
    // This is the same `useCase` the POST /api/llm/session handler calls.
    // It resolves the cwd (including the relative-path and DB-fallback
    // chains), snapshots the active profile, abandons a pending ask_user
    // question, expands slash-skills, upserts the session row and calls
    // `emit_run_agent` — which dupes its strings, upserts the row and
    // emits `RunParamsNew` on the bus.
    //
    // Headless mode deliberately does NOT re-implement any of that. A
    // second copy would drift from the browser on the next change to this
    // function, and the drift would only surface as "the CLI behaves
    // differently". See the doc comment on `useCase`.
    //
    // `owner` is empty: there is no request and no cookie, which is the
    // same identity the server uses with `--auth` off.
    const created = try pabrikcore.http_handlers.sessionCreateUseCase(
        allocator,
        io,
        ctx,
        .{
            .session_id = a.session_id orelse "",
            .queue_message = a.message,
            .cwd_session = a.cwd orelse "",
            .allowed_tools = a.allowed_tools,
            .selected_profile_model = a.profile orelse "",
        },
        "",
    );

    // The usecase dupes nothing for us — `ResponseSession` borrows from
    // the per-call arena — so take our own copy before it goes away.
    const session_id = try allocator.dupe(u8, created.id);

    // Now that the id is known, watch this session specifically too. The
    // broadcast subscription above already caught anything emitted before
    // this point, but `Watch.session_id` was empty then, so those events
    // were dropped — which is fine, because the turn has not started yet.
    Watch.reset(io, session_id);
    try backend.event_bus.subscribe(SseEvent, session_id, onLlmEvent);

    // ─── Wait for the loop ───
    // The turn is already running: `emit_run_agent` (inside the usecase
    // above) scheduled it on `ctx.group_emit_session_create` and emitted
    // `RunParamsNew`, and `boot` installed the `ai_worker_flow`
    // subscriber that calls `runAgenticMultiStepnew`. Headless mode does
    // NOT drive the loop itself — doing so would run two turns for one
    // message, and the second would be a parallel implementation of the
    // first.
    //
    // So all that is left is to watch for the completion signal the loop
    // already emits, bounded by `--timeout-ms`.
    const deadline_ms: ?i64 = if (a.timeout_ms == 0)
        null
    else
        std.Io.Timestamp.now(io, .awake).toMilliseconds() + @as(i64, @intCast(a.timeout_ms));

    var timed_out = false;
    while (true) {
        Watch.lock();
        const finished = Watch.done;
        Watch.unlock();
        if (finished) break;

        if (deadline_ms) |d| {
            if (std.Io.Timestamp.now(io, .awake).toMilliseconds() >= d) {
                timed_out = true;
                break;
            }
        }
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }

    Watch.lock();
    defer Watch.unlock();

    return .{
        .session_id = session_id,
        .assistant_text = Watch.assistant_text[0..Watch.assistant_len],
        .finish_reason = if (Watch.finish_len > 0) Watch.finish_reason[0..Watch.finish_len] else "",
        .iterations = Watch.iterations,
        .timed_out = timed_out,
        // The loop reports its own failures as an `is_error` llm_history
        // row rather than a returned error, so there is no error name to
        // forward here. A turn that produced no assistant text is the
        // signal, and the dispatcher already treats that as exit 1.
        .error_name = null,
    };
}
