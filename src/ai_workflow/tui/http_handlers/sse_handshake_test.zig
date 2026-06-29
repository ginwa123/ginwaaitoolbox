//! Regression test for the SSE `connected` event handshake.
//!
//! Why this file exists
//! ────────────────────
//! The frontend `SseStatusBadge`
//! (src/apps/desktop/src/components/SseStatusBadge.vue) and the
//! `SseClient` state machine
//! (src/apps/desktop/src/helpers/sseClient.ts) only transition
//! from `'connecting'` to `'open'` when the server sends the SSE
//! `connected` named event:
//!
//!     event: connected\ndata: {"connected": true}\n\n
//!
//! Two of the four legacy backend SSE handlers used to skip this
//! handshake, leaving the badge stuck on "Connecting…" forever
//! (the stream was alive and streaming, but the badge had no
//! signal to hide). See docs/plans/2026-06-05-stuck-connecting-badge.md
//! for the full trace.
//!
//! After the 5→1 SSE endpoint unification (plan
//! docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md),
//! only ONE backend SSE handler is registered
//! (`unified_events_sse.zig`); this test pins its contract via a
//! STATIC check: the unified handler source file must contain the
//! handshake constant verbatim. Catches a future regression where
//! the 3-line send block is removed or the byte sequence changes
//! and the frontend SseStatusBadge gets stuck on "Connecting…"
//! again.
//!
//! The behavioral test (round-trip through a real SseManager +
//! socketpair) was considered and dropped: Zig 0.16 removed
//! `posix.socketpair` and the SseManager's own tests are
//! POSIX-only via the lower-level `posix.system` layer, which
//! would require a Linux-only gate. The static check is the
//! higher-value test anyway — it directly tests the bug.

const std = @import("std");
const nalarcore = @import("nalarcore");
const testing = std.testing;

/// The exact byte sequence the unified SSE handler MUST send as the
/// liveness handshake. Mirrors what the previous `worker_sse.zig`
/// / `sessions_sse.zig` emitted (those are now deleted; their
/// string is preserved here as the source of truth).
///
/// The trailing blank line (`\n\n`) is REQUIRED — it's the SSE
/// frame terminator. Without it, the browser's `EventSource`
/// will hold the bytes in its line buffer and never dispatch the
/// `connected` event to the SseClient.
///
/// The JSON in the `data:` line (`{"connected": true}`) is a
/// convention; the SseClient does NOT parse it. The empty JSON
/// object `{}` would also work.
///
/// IMPORTANT: this constant is the SOURCE-FORM of the handshake
/// as it appears in the .zig source files, NOT the in-memory
/// runtime form. Each `\n` in the file source is the two-byte
/// escape sequence (backslash + 'n'), and the literal `"` inside
/// the JSON is `\"` (backslash + quote). When Zig parses the
/// string literal at compile time, those escape sequences become
/// the real bytes that the SSE client sees. The test matches the
/// source form because the file is read as text.
const connected_handshake_in_source =
    "event: connected\\n" ++
    "data: {\\\"connected\\\": true}\\n" ++
    "\\n";

// ─── Static check on the single unified handler source file ───────────────

test "SSE handshake: unified stream handler sends the connected event" {
    // The single SSE route registered in src/main.zig. Must contain
    // the `connected` handshake string in its source, or the frontend
    // SseStatusBadge will be stuck on "Connecting…".
    //
    // This is a SOURCE-LEVEL test — it reads the .zig file from
    // disk at test time and asserts the handshake string appears
    // verbatim. The test is intentionally a substring match (not a
    // full AST walk) because:
    //   - The 3-line block is small and the byte sequence is the
    //     actual contract that reaches the client.
    //   - The constant string is also defined in this file as the
    //     source of truth, so any change must be made in lockstep.
    //
    // Path is relative to the project root, which is the cwd when
    // `zig build test:ai_workflow:tui` runs.
    const handlers = .{
        "src/ai_workflow/tui/http_handlers/unified_events_sse.zig",
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    inline for (handlers) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            allocator,
            .limited(64 * 1024),
        ) catch |err| {
            std.debug.print("\n!! SSE handshake: could not read {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        errdefer allocator.free(source);

        if (std.mem.indexOf(u8, source, connected_handshake_in_source) == null) {
            std.debug.print(
                "\n!! {s} does not contain the SSE connected handshake !!\n" ++
                    "   expected (verbatim, exactly as it must appear in the source):\n" ++
                    "     {s}\n" ++
                    "   Add the 3-line `event: connected` send right after\n" ++
                    "   `registerSessionClient`, mirroring worker_sse.zig.\n" ++
                    "   See docs/plans/2026-06-05-stuck-connecting-badge.md for why.\n",
                .{ path, connected_handshake_in_source },
            );
            return error.ConnectedHandshakeMissing;
        }
    }
}
