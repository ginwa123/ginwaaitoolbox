const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;

/// Audio container detection from the request's Content-Type header.
///
/// The frontend's MediaRecorder emits one of four MIME types
/// (depending on browser + OS): `audio/webm`, `audio/ogg`,
/// `audio/mp4`, or `audio/wav`. The container's file extension is
/// forwarded as the `filename` in the multipart/form-data body
/// because the upstream Whisper API uses the extension to pick the
/// decoder. Default to `webm` when the header is missing or
/// unrecognised — Chrome on Linux/Windows and most Chromium-based
/// browsers default to webm/opus.
const AudioFormat = struct {
    mime: []const u8,
    ext: []const u8,
};

const SUPPORTED_FORMATS = [_]AudioFormat{
    .{ .mime = "audio/webm", .ext = "webm" },
    .{ .mime = "audio/ogg", .ext = "ogg" },
    .{ .mime = "audio/mp4", .ext = "mp4" },
    .{ .mime = "audio/wav", .ext = "wav" },
};

/// Detect audio format from the request's Content-Type header.
/// Returns the default (webm) when the header is missing, empty,
/// or doesn't start with any known MIME prefix.
fn detectAudioFormat(content_type: ?[]const u8) AudioFormat {
    const header = content_type orelse return SUPPORTED_FORMATS[0];
    if (header.len == 0) return SUPPORTED_FORMATS[0];
    for (SUPPORTED_FORMATS) |fmt| {
        // Match `audio/webm;codecs=opus` style headers by prefix.
        if (std.ascii.startsWithIgnoreCase(header, fmt.mime)) {
            return fmt;
        }
    }
    return SUPPORTED_FORMATS[0];
}

/// POST /api/transcribe
///
/// Body: raw audio bytes (webm/ogg/mp4/wav). The Content-Type
/// header advertises the container. We forward the audio to the
/// user's configured OpenAI-compatible Whisper endpoint
/// (`<base_url>/audio/transcriptions`) using multipart/form-data
/// with two parts: `model=whisper-1` and `file=@<audio>.<ext>`.
///
/// On success: 200 with `{"text": "..."}` (the upstream Whisper
/// response is passed through verbatim — the OpenAI Whisper API
/// returns exactly this shape).
///
/// Errors:
///   - 400  empty body
///   - 500  nalarcore singleton not initialised
///   - 501  Whisper is not configured (no base_url or no api_key)
///   - 502  upstream call failed (spawn error, non-200, or
///          malformed response without a `.text` field)
pub fn transcribeHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // ─── 1. Validate the body ─────────────────────────────────────────
    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required (raw audio bytes)" }),
        });
    }

    // ─── 2. Resolve LlmConfig (the Whisper endpoint is the same
    //        base_url + api_key as the chat completion endpoint).
    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "nalarcore singleton not initialised" }),
        });
    };
    const cfg = nalarcore.getLlmConfig(di);

    // ─── 3. The frontend uses 501 to render a "configure Whisper in
    //        Nalar settings" hint. Distinct from 500 (server bug).
    if (cfg.base_url.len == 0 or cfg.api_key.len == 0) {
        return res.jsonResponse(.{
            .status_code = 501,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Whisper is not configured. Set base_url and api_key in Nalar settings." }),
        });
    }

    // ─── 4. Detect container from Content-Type header (default webm).
    const format = detectAudioFormat(req.headers.get("content-type"));

    // ─── 5. Persist the audio bytes to a temp file. curl's
    //        multipart encoder (`-F file=@<path>;type=<mime>`) reads
    //        from disk and streams the part with the correct
    //        Content-Type + Content-Disposition headers.
    const tmp_root: []const u8 = blk: {
        const env = di.environment orelse break :blk "/tmp";
        break :blk env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP") orelse "/tmp";
    };

    // Use a deterministic, recognisable filename so multiple
    // concurrent transcribes don't collide on /tmp/nalar-transcribe.bin
    // (the per-request arena will clean up after we return, but the
    // file may outlive the request if curl is slow).
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{std.c.getpid()}) catch "0";

    const tmp_path = try std.fs.path.join(allocator, &.{ tmp_root, "nalar-transcribe" });
    errdefer allocator.free(tmp_path);
    const tmp_filename = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ tmp_path, pid_str, format.ext });
    errdefer allocator.free(tmp_filename);

    {
        var file = try std.Io.Dir.createFileAbsolute(io, tmp_filename, .{ .truncate = true });
        defer file.close(io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        try writer.interface.writeAll(req.body);
        try writer.flush();
    }

    // Always delete the temp file before returning. Even on error
    // paths, we leave no audio in /tmp.
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_filename) catch {};

    // ─── 6. Spawn curl with multipart/form-data. We can't use the
    //        shared `HttpClient.post()` because it hardcodes
    //        `Content-Type: application/json` (see HttpClient.zig
    //        postWithCurl). curl's `-F` flag handles the multipart
    //        boundary + Content-Disposition per part automatically.
    //
    // The shell command uses single-quoted literals to avoid
    // interpretation of JSON braces (which would otherwise collide
    // with format-string interpolation).
    const escaped_url = try shellEscapeSingle(allocator, cfg.base_url);
    errdefer allocator.free(escaped_url);

    const shell_cmd = try std.fmt.allocPrint(
        allocator,
        "curl -sS -X POST '{s}/audio/transcriptions' -H 'Authorization: Bearer {s}' -F 'file=@{s};type={s}' -F 'model=whisper-1' -w '\n__HTTP_STATUS__:%{{http_code}}'",
        .{ escaped_url, cfg.api_key, tmp_filename, format.mime },
    );
    errdefer allocator.free(shell_cmd);

    const stdout_text = try runCurlCapture(io, allocator, shell_cmd);
    errdefer allocator.free(stdout_text);

    // ─── 7. Split the curl output into body + status. We appended
    //        `__HTTP_STATUS__:<code>` after the response body.
    const status_marker = "\n__HTTP_STATUS__:";
    const marker_idx = std.mem.lastIndexOf(u8, stdout_text, status_marker) orelse {
        return res.jsonResponse(.{
            .status_code = 502,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Upstream Whisper call did not return a status code" }),
        });
    };
    const body_slice = stdout_text[0..marker_idx];
    const status_slice = std.mem.trim(u8, stdout_text[marker_idx + status_marker.len ..], " \r\n\t");

    const status_code = std.fmt.parseInt(u16, status_slice, 10) catch {
        return res.jsonResponse(.{
            .status_code = 502,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Upstream Whisper returned a non-numeric status code" }),
        });
    };

    if (status_code != 200) {
        // Surface the upstream body (truncated) so the frontend can
        // show "OpenAI rejected the audio: <reason>".
        const truncated_len = @min(body_slice.len, 512);
        const preview = body_slice[0..truncated_len];
        const err_msg = try std.fmt.allocPrint(allocator, "Upstream Whisper returned {d}: {s}", .{ status_code, preview });
        return res.jsonResponse(.{
            .status_code = 502,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }),
        });
    }

    // ─── 8. Validate the upstream body is the expected shape. The
    //        OpenAI Whisper API returns exactly `{"text": "..."}` —
    //        we forward that verbatim. If the body doesn't contain
    //        a `.text` key, treat it as an upstream contract
    //        violation (502).
    if (std.mem.indexOf(u8, body_slice, "\"text\"") == null) {
        return res.jsonResponse(.{
            .status_code = 502,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Upstream Whisper response missing the .text field" }),
        });
    }

    // ─── 9. Forward the upstream body to the client. The browser
    //        sees `{"text": "..."}` and renders it. We intentionally
    //        don't re-serialise through valueAlloc because the
    //        Whisper response is already valid JSON; re-serialising
    //        risks changing field order or stripping unknown keys
    //        (forward-compat with new Whisper response fields).
    return res.jsonResponse(.{
        .status_code = 200,
        .data = body_slice,
    });
}

/// Wrap `s` in single quotes for safe shell usage. Embedded single
/// quotes are escaped with `'\''` (close, escape, reopen) — the
/// POSIX-portable form. Mirrors `escapeShellArg` in HttpClient.zig
/// but kept local so the handler is self-contained.
fn shellEscapeSingle(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try result.appendSlice(allocator, "'\\''");
        } else {
            try result.append(allocator, c);
        }
    }
    try result.append(allocator, '\'');
    return try result.toOwnedSlice(allocator);
}

/// Spawn `bash -c <shell_cmd>` and capture stdout. Stderr is
/// discarded. Returns the captured text or an error if the spawn
/// itself fails. The returned slice is owned by the caller.
fn runCurlCapture(io: std.Io, allocator: std.mem.Allocator, shell_cmd: []const u8) ![]u8 {
    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{ "bash", "-c", shell_cmd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.UpstreamSpawnFailed;

    var stdout_buf: std.ArrayList(u8) = .empty;
    errdefer stdout_buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    if (child.stdout) |pipe| {
        while (true) {
            const n = std.Io.File.readStreaming(pipe, io, &.{&read_buf}) catch break;
            if (n == 0) break;
            try stdout_buf.appendSlice(allocator, read_buf[0..n]);
        }
    }
    // Drain stderr so curl doesn't block on a full pipe; we don't
    // surface it (curl -sS already writes errors to stdout on
    // failure, and our status-code path catches non-200).
    if (child.stderr) |pipe| {
        var drain_buf: [1024]u8 = undefined;
        while (true) {
            const n = std.Io.File.readStreaming(pipe, io, &.{&drain_buf}) catch break;
            if (n == 0) break;
        }
    }

    _ = child.wait(io) catch return error.UpstreamWaitFailed;
    return try stdout_buf.toOwnedSlice(allocator);
}
