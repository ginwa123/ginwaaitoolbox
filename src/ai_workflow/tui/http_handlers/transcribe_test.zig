// Static source-check tests for the transcribe handler.
//
// The project does not have a behavioral handler-test infrastructure for
// spinning up GinwaServer + nalarcore singleton + Io runtime + SQLite
// + Environment, so we use the established static-grep pattern
// (mirrors git_pr_create_test.zig and git_worktree_info_test.zig): read
// the source file as text, assert the required substrings are present.
//
// Each test returns a named error like `error.TranscribeHandlerMissing`
// so a failure points at WHICH contract broke.

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/transcribe.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── 1. Handler declaration ────────────────────────────────────────────────

test "transcribe.zig exists and declares transcribeHandler" {
    const allocator = testing.allocator;
    const source = readSource(allocator, HANDLER_PATH) catch |err| {
        std.debug.print("!! transcribe.zig could not be read: {s} !!\n", .{@errorName(err)});
        return error.TranscribeHandlerMissing;
    };
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn transcribeHandler") == null) {
        std.debug.print("!! transcribe.zig does not declare pub fn transcribeHandler !!\n", .{});
        return error.TranscribeHandlerMissing;
    }
}

// ─── 2. Body handling — raw audio, NOT JSON ────────────────────────────────

test "transcribe.zig accepts raw body (does not require JSON parse)" {
    const allocator = testing.allocator;
    const source = readSource(allocator, HANDLER_PATH) catch {
        return error.TranscribeHandlerMissing;
    };
    defer allocator.free(source);
    // The handler must NOT call `parseFromSlice` on `req.body` — the
    // body is raw audio bytes (webm/ogg/mp4/wav) and the upstream
    // Whisper call expects a multipart body, not a JSON one.
    if (std.mem.indexOf(u8, source, "parseFromSlice") != null) {
        std.debug.print("!! transcribe.zig must NOT parseFromSlice (body is raw audio) !!\n", .{});
        return error.TranscribeBodyMustBeRaw;
    }
    // The handler must read the raw body from `req.body`.
    if (std.mem.indexOf(u8, source, "req.body") == null) {
        std.debug.print("!! transcribe.zig does not read req.body !!\n", .{});
        return error.TranscribeBodyNotRead;
    }
}

// ─── 3. LlmConfig access via nalarcore singleton ───────────────────────────

test "transcribe.zig reads LlmConfig via nalarcore.getLlmConfig" {
    const allocator = testing.allocator;
    const source = readSource(allocator, HANDLER_PATH) catch {
        return error.TranscribeHandlerMissing;
    };
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "nalarcore.getLlmConfig") == null) {
        std.debug.print("!! transcribe.zig does not call nalarcore.getLlmConfig !!\n", .{});
        return error.TranscribeLlmConfigMissing;
    }
    if (std.mem.indexOf(u8, source, "getSingleton") == null) {
        std.debug.print("!! transcribe.zig does not call nalarcore.getSingleton !!\n", .{});
        return error.TranscribeSingletonMissing;
    }
}

// ─── 4. Upstream Whisper URL + model ───────────────────────────────────────

test "transcribe.zig POSTs to upstream /audio/transcriptions with whisper-1" {
    const allocator = testing.allocator;
    const source = readSource(allocator, HANDLER_PATH) catch {
        return error.TranscribeHandlerMissing;
    };
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "audio/transcriptions") == null) {
        std.debug.print("!! transcribe.zig does not POST to /audio/transcriptions !!\n", .{});
        return error.TranscribeUpstreamUrlMissing;
    }
    if (std.mem.indexOf(u8, source, "whisper-1") == null) {
        std.debug.print("!! transcribe.zig does not reference model whisper-1 !!\n", .{});
        return error.TranscribeWhisperModelMissing;
    }
}

// ─── 5. Response shape ────────────────────────────────────────────────────

test "transcribe.zig returns JSON with .text field" {
    const allocator = testing.allocator;
    const source = readSource(allocator, HANDLER_PATH) catch {
        return error.TranscribeHandlerMissing;
    };
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, ".text") == null) {
        std.debug.print("!! transcribe.zig does not return a JSON .text field !!\n", .{});
        return error.TranscribeTextFieldMissing;
    }
}

// ─── 6. Error path: 501 when Whisper not configured ───────────────────────

test "transcribe.zig returns 501 when Whisper not configured" {
    const allocator = testing.allocator;
    const source = readSource(allocator, HANDLER_PATH) catch {
        return error.TranscribeHandlerMissing;
    };
    defer allocator.free(source);
    // The frontend uses 501 to render a "Configure in Nalar settings" hint.
    if (std.mem.indexOf(u8, source, "501") == null) {
        std.debug.print("!! transcribe.zig does not return 501 when not configured !!\n", .{});
        return error.TranscribeNotConfiguredStatusMissing;
    }
}

// ─── 7. Route registration in main.zig ─────────────────────────────────────

test "main.zig registers POST /api/transcribe" {
    const allocator = testing.allocator;
    const source = readSource(allocator, MAIN_PATH) catch {
        return error.MainSourceMissing;
    };
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "/api/transcribe") == null) {
        std.debug.print("!! main.zig does not register /api/transcribe route !!\n", .{});
        return error.TranscribeRouteMissing;
    }
    if (std.mem.indexOf(u8, source, "transcribeHandler") == null) {
        std.debug.print("!! main.zig does not reference transcribeHandler !!\n", .{});
        return error.TranscribeHandlerRefMissing;
    }
}
