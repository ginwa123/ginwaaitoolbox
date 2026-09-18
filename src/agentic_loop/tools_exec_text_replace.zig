const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const text_replace_mod = nalarcore.text_replace_tool;
const wrapToolOutput = tools.wrapToolOutput;
const testing = std.testing;

/// Escape a string for inclusion as a JSON string literal value (between
/// the quotes — caller supplies the surrounding `"..."` template).
/// Escapes `\` → `\\` and `"` → `\"` (RFC 8259 §7). Other characters
/// (including control codes / non-ASCII) are passed through verbatim;
/// the test fixtures only contain ASCII so we don't bother with
/// `\u00XX` sequences here. Caller must `deinit` the returned slice.
fn jsonEscapeInto(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        if (c == '\\' or c == '"') {
            try out.append(allocator, '\\');
        }
        try out.append(allocator, c);
    }
    return out;
}

pub fn execTextReplace(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        text_replace_mod.TextReplaceInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "text_replace failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    var tr_result = text_replace_mod.executeTextReplace(
        ctx.allocator,
        ctx.io,
        parsed.value.path,
        parsed.value.old_str,
        parsed.value.new_str,
    ) catch |err| {
        const inner = try text_replace_mod.toJSONError(
            ctx.allocator,
            err,
            parsed.value.path,
            parsed.value.old_str,
        );
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "text_replace failed: {s}", .{@errorName(err)});
        const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    };

    defer tr_result.deinit(ctx.allocator);

    const inner = try text_replace_mod.toJSONSuccess(ctx.allocator, tr_result, parsed.value.path);
    const output = try wrapToolOutput(ctx.allocator, "text_replace", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ---------------------------------------------------------------------------
// Overwrite-contract regression tests (added 2026-08-15)
//
// text_replace internally writes the modified content back to disk via
// `std.Io.Dir.cwd().createFile(io, path, .{})` (text_replace.zig:468) —
// that call relies on the default `truncate: bool = true` to overwrite
// (not append-to) the existing file. These tests pin that contract
// end-to-end through the exec wrapper — the path the agentic loop
// actually invokes when the LLM calls text_replace.
//
// Like the execWriteFile tests (sister file), these close the gap left
// by PR #261's revert which removed the inline tests from the exec
// wrappers entirely.
// ---------------------------------------------------------------------------

fn minimalCtxTr(allocator: std.mem.Allocator) ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = testing.io,
        .db = undefined,
        .logger = undefined,
        .session_id = "test_session",
        .model = "test_model",
        .cwd = "/tmp",
        .api_key = "test_key",
        .base_url = "test_base",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .active_loops = undefined,
    };
}

/// Helper: assert the exec output is a success JSON envelope whose
/// `data.path` equals the expected path.
fn expectTextReplaceSuccess(output: []const u8, expected_path: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("success").?.bool);
    try testing.expectEqualStrings(expected_path, obj.get("data").?.object.get("path").?.string);
}

fn readAllTr(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .limited(4 << 20));
}

// CONTRACT: execTextReplace must overwrite the target file (truncate +
// write new content), not append. The simplest way to detect append-mode
// is: pre-seed with a long string containing a marker, replace the
// marker with a SHORTER replacement, then verify the file's bytes after
// the new content match what was originally after the marker — if it
// appended, the trailing content would be doubled.
test "execTextReplace: writes back the full modified file (truncates + overwrites, no append)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = path_buf[0..n];

    const target_name = "tr_overwrite.txt";
    const target_path = try std.fs.path.join(a, &.{ root_abs, target_name });

    // Pre-seed with a long string containing the marker we'll replace
    const original = "<<<REPLACE_ME>>> then keep this trailing junk after the marker to detect any append-mode corruption";
    {
        const f = try tmp.dir.createFile(testing.io, target_name, .{});
        defer f.close(testing.io);
        try std.Io.File.writeStreamingAll(f, testing.io, original);
    }

    // Build args: replace the marker with a SHORTER string. If createFile
    // appended instead of truncating, the trailing junk would still be
    // visible AFTER the new short content. Escape the path for JSON
    // (Windows JSON-parse fix — `\` in `realPath()` would otherwise
    // produce malformed `{"path":"C:\..."}` and reject by
    // `std.json.parseFromSlice`).
    {
        var escaped = try jsonEscapeInto(a, target_path);
        defer escaped.deinit(a);
        const args = try std.fmt.allocPrint(
            a,
            "{{\"path\":\"{s}\",\"old_str\":\"<<<REPLACE_ME>>>\",\"new_str\":\"[OK]\"}}",
            .{escaped.items},
        );
        const tc = agent.ToolCall{
            .id = "call_tr_ow1",
            .type = "function",
            .function = .{ .name = "text_replace", .arguments = args },
        };

        const result = try execTextReplace(minimalCtxTr(a), tc);
        defer if (result.output_allocated) a.free(result.output);

        try expectTextReplaceSuccess(result.output, target_path);

        // Read back — file must be EXACTLY "[OK] then keep this trailing junk
        // after the marker to detect any append-mode corruption"
        const expected = "[OK] then keep this trailing junk after the marker to detect any append-mode corruption";
        const read = try readAllTr(a, target_path);
        try testing.expectEqualStrings(expected, read);
        // File size must match the new length (not original.len) — proves
        // truncation happened, not append.
        try testing.expectEqual(@as(usize, expected.len), read.len);
        try testing.expect(read.len != original.len); // sanity: the two really differ
    }
}

// CONTRACT: execTextReplace must OVERWRITE, not fail or skip, when called
// on an existing file with content that exactly matches old_str.
test "execTextReplace: existing file with matching content is modified in place" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const root_abs = path_buf[0..n];

    const target_name = "tr_match.txt";
    const target_path = try std.fs.path.join(a, &.{ root_abs, target_name });

    {
        const f = try tmp.dir.createFile(testing.io, target_name, .{});
        defer f.close(testing.io);
        try std.Io.File.writeStreamingAll(f, testing.io, "Hello World\n");
    }

    // Escape `\` and `"` in the path (Windows JSON-parse fix).
    {
        var escaped = try jsonEscapeInto(a, target_path);
        defer escaped.deinit(a);
        const args2 = try std.fmt.allocPrint(
            a,
            "{{\"path\":\"{s}\",\"old_str\":\"Hello\",\"new_str\":\"Goodbye\"}}",
            .{escaped.items},
        );
        const tc = agent.ToolCall{
            .id = "call_tr_match",
            .type = "function",
            .function = .{ .name = "text_replace", .arguments = args2 },
        };

        const result = try execTextReplace(minimalCtxTr(a), tc);
        defer if (result.output_allocated) a.free(result.output);

        try expectTextReplaceSuccess(result.output, target_path);
        const read = try readAllTr(a, target_path);
        try testing.expectEqualStrings("Goodbye World\n", read);
    }
}
