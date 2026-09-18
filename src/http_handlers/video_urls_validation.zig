//! Validation + joining helpers for `workspace_item_tasks.video_urls`
//! (Migration 090 — kanban video urls column).
//!
//! Storage format
//! ──────────────
//! The `video_urls` column is a `||`-delimited string of base64 data
//! URLs. The column is NOT NULL DEFAULT '' (the canonical "no videos"
//! sentinel). Mirrors the `image_urls` convention (Migration 069) and
//! `llm_history.image_url` — same split-scalar join.
//!
//! Why `||` and not JSON: same reasons as image_urls — single string
//! end-to-end, trivial round-trip debugging, no JSON wrap.
//!
//! Why validate at all: the frontend reads each file via
//! `FileReader.readAsDataURL` which produces
//! `data:video/<mime>;base64,<payload>`. We validate the prefix on the
//! server so a malicious client can't inject non-data URLs (e.g.
//! `http://internal/...`) that would render as `<video>` sources
//! pointing at private network resources.
//!
//! Allowlist (locked 2026-09-18): mp4, webm, quicktime (mov), x-msvideo
//! (avi), x-matroska (mkv). Phase 0 found providers document mp4/webm/mov
//! natively; avi/mkv are accepted at the validation layer and rejected
//! with a hard error at the Agent wire layer for unsupported models.

const std = @import("std");

/// Cap on the total joined `video_urls` payload (25 MB). Base64 inflates
/// ~33%, so this fits roughly one 18 MB raw video or several smaller
/// clips. Enforced client-side too (FileInput + Kanban editor reject
/// files > 25 MB before readAsDataURL).
pub const MAX_VIDEO_URLS_BYTES: usize = 25 * 1024 * 1024;

/// Validate each URL in `joined` is a `data:video/<mime>;base64,...`
/// URL with an allowlisted mime, and the total byte length is within
/// `MAX_VIDEO_URLS_BYTES`. Returns the validated joined string on
/// success (borrowed slice). Returns `error.InvalidVideoUrl` on the
/// first malformed URL, `error.VideoUrlsTooLarge` when over cap.
pub fn validateVideoUrls(joined: []const u8) ![]const u8 {
    if (joined.len > MAX_VIDEO_URLS_BYTES) return error.VideoUrlsTooLarge;
    if (joined.len == 0) return joined; // empty = no videos

    var iter = std.mem.splitScalar(u8, joined, '|');
    while (iter.next()) |segment| {
        if (segment.len == 0) continue; // tolerate empty segments (consecutive `||`)
        if (!isValidVideoDataUrl(segment)) return error.InvalidVideoUrl;
    }
    return joined;
}

fn isAllowedVideoMime(mime: []const u8) bool {
    // Allowlist: video/mp4, video/webm, video/quicktime (mov),
    // video/x-msvideo (avi), video/x-matroska (mkv).
    if (std.mem.eql(u8, mime, "video/mp4")) return true;
    if (std.mem.eql(u8, mime, "video/webm")) return true;
    if (std.mem.eql(u8, mime, "video/quicktime")) return true;
    if (std.mem.eql(u8, mime, "video/x-msvideo")) return true;
    if (std.mem.eql(u8, mime, "video/x-matroska")) return true;
    return false;
}

/// `data:video/<mime>;base64,<payload>` — the only shape the frontend's
/// `FileReader.readAsDataURL` produces for video files. Empty payloads
/// are rejected.
fn isValidVideoDataUrl(segment: []const u8) bool {
    const prefix = "data:video/";
    if (!std.mem.startsWith(u8, segment, prefix)) return false;
    const after_scheme = segment[prefix.len..];
    const sep = std.mem.indexOf(u8, after_scheme, ";base64,") orelse return false;
    if (sep == 0) return false; // empty MIME
    const mime_suffix = after_scheme[0..sep];
    var mime_buf: [32]u8 = undefined;
    const full_mime = std.fmt.bufPrint(&mime_buf, "video/{s}", .{mime_suffix}) catch return false;
    if (!isAllowedVideoMime(full_mime)) return false;
    const payload = after_scheme[sep + ";base64,".len ..];
    if (payload.len == 0) return false; // empty payload
    return true;
}

test "validateVideoUrls accepts empty (no videos sentinel)" {
    const result = try validateVideoUrls("");
    try std.testing.expectEqualStrings("", result);
}

test "validateVideoUrls accepts a single mp4 data URL" {
    const url = "data:video/mp4;base64,AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDE=";
    const result = try validateVideoUrls(url);
    try std.testing.expectEqualStrings(url, result);
}

test "validateVideoUrls accepts webm and mov" {
    const joined = "data:video/webm;base64,GkXfo59ChoEBQveBAULygQRC84E||data:video/quicktime;base64,AAAAIGZ0eXBxdCA=";
    const result = try validateVideoUrls(joined);
    try std.testing.expectEqualStrings(joined, result);
}

test "validateVideoUrls accepts avi and mkv (allowlisted, provider may hard-error)" {
    const joined = "data:video/x-msvideo;base64,UklGRg==||data:video/x-matroska;base64,GkXfo59ChoE=";
    const result = try validateVideoUrls(joined);
    try std.testing.expectEqualStrings(joined, result);
}

test "validateVideoUrls rejects non-data URLs" {
    const result = validateVideoUrls("http://example.com/foo.mp4");
    try std.testing.expectError(error.InvalidVideoUrl, result);
}

test "validateVideoUrls rejects image URLs (use image_urls column)" {
    const result = validateVideoUrls("data:image/png;base64,iVBORw0KGgo=");
    try std.testing.expectError(error.InvalidVideoUrl, result);
}

test "validateVideoUrls rejects disallowed mime" {
    const result = validateVideoUrls("data:video/ogg;base64,T2dnUw==");
    try std.testing.expectError(error.InvalidVideoUrl, result);
}

test "validateVideoUrls rejects missing ;base64," {
    const result = validateVideoUrls("data:video/mp4,abc123");
    try std.testing.expectError(error.InvalidVideoUrl, result);
}

test "validateVideoUrls rejects empty payload" {
    const result = validateVideoUrls("data:video/mp4;base64,");
    try std.testing.expectError(error.InvalidVideoUrl, result);
}

test "validateVideoUrls rejects empty MIME" {
    const result = validateVideoUrls("data:video/;base64,abc");
    try std.testing.expectError(error.InvalidVideoUrl, result);
}

test "validateVideoUrls tolerates trailing ||" {
    const joined = "data:video/mp4;base64,abc||";
    const result = try validateVideoUrls(joined);
    try std.testing.expectEqualStrings(joined, result);
}

test "validateVideoUrls cap is 25 MB" {
    try std.testing.expectEqual(@as(usize, 25 * 1024 * 1024), MAX_VIDEO_URLS_BYTES);
    const ok = "data:video/mp4;base64,abc";
    const result = try validateVideoUrls(ok);
    try std.testing.expectEqualStrings(ok, result);
}
