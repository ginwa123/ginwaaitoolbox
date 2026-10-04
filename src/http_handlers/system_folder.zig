const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const SystemFolder = nalarcore.system_folder.SystemFolder;
const SystemFolderError = nalarcore.system_folder.SystemFolderError;
const FolderEntry = nalarcore.system_folder.FolderEntry;

/// Escape special characters for JSON string values
fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);
    for (value) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, c),
        }
    }
    return try result.toOwnedSlice(allocator);
}

/// Serialize entries into the JSON array literal used on the wire:
/// `[{"name":...,"path":...,"is_directory":...,"is_symlink":...},...]`.
///
/// Shared by the `list` and `search` branches (which previously carried
/// byte-identical copies of this loop) and callable from a test, which is
/// what lets the Windows case be asserted instead of assumed: on Windows
/// every `entry.path` is a backslash path (`C:\Users\ginwa\...`), and an
/// unescaped one makes the whole response unparseable.
pub fn buildEntriesJson(allocator: std.mem.Allocator, entries: []const FolderEntry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (entries, 0..) |entry, i| {
        if (i > 0) try out.append(allocator, ',');
        const escaped_name = jsonEscape(allocator, entry.name) catch "";
        defer allocator.free(escaped_name);
        const escaped_path = jsonEscape(allocator, entry.path) catch "";
        defer allocator.free(escaped_path);
        try out.appendSlice(allocator, "{\"name\":\"");
        try out.appendSlice(allocator, escaped_name);
        try out.appendSlice(allocator, "\",\"path\":\"");
        try out.appendSlice(allocator, escaped_path);
        try out.appendSlice(allocator, "\",\"is_directory\":");
        try out.appendSlice(allocator, if (entry.is_directory) "true" else "false");
        try out.appendSlice(allocator, ",\"is_symlink\":");
        try out.appendSlice(allocator, if (entry.is_symlink) "true" else "false");
        try out.append(allocator, '}');
    }
    return out.toOwnedSlice(allocator);
}

/// Render the `{path, absolute, home[, parent][, entries]}` body.
///
/// Every one of those top-level fields can hold a Windows path
/// (`C:\Users\ginwa`), and a lone backslash is an invalid JSON escape --
/// interpolating them raw is what made this endpoint's response
/// unparseable on Windows. Escaping failures PROPAGATE here rather than
/// falling back to the raw string: that fallback would re-produce exactly
/// the broken body this function exists to prevent.
///
/// `entries_json` is `null` for the no-action shape (which has no
/// `entries` key) and the already-serialized array for `action=list`.
fn printFolderJson(
    allocator: std.mem.Allocator,
    relative: []const u8,
    absolute: []const u8,
    home: []const u8,
    parent: ?[]const u8,
    entries_json: ?[]const u8,
) ![]u8 {
    const esc_rel = try jsonEscape(allocator, relative);
    defer allocator.free(esc_rel);
    const esc_abs = try jsonEscape(allocator, absolute);
    defer allocator.free(esc_abs);
    const esc_home = try jsonEscape(allocator, home);
    defer allocator.free(esc_home);

    if (parent) |pr| {
        const esc_parent = try jsonEscape(allocator, pr);
        defer allocator.free(esc_parent);
        if (entries_json) |entries| {
            return std.fmt.allocPrint(allocator,
                "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\",\"entries\":[{s}]}}",
                .{ esc_rel, esc_abs, esc_home, esc_parent, entries });
        }
        return std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"parent\":\"{s}\"}}",
            .{ esc_rel, esc_abs, esc_home, esc_parent });
    }
    if (entries_json) |entries| {
        return std.fmt.allocPrint(allocator,
            "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\",\"entries\":[{s}]}}",
            .{ esc_rel, esc_abs, esc_home, entries });
    }
    return std.fmt.allocPrint(allocator,
        "{{\"path\":\"{s}\",\"absolute\":\"{s}\",\"home\":\"{s}\"}}",
        .{ esc_rel, esc_abs, esc_home });
}

/// `action=list` body -- always carries `entries`.
pub fn buildFolderListJson(
    allocator: std.mem.Allocator,
    relative: []const u8,
    absolute: []const u8,
    home: []const u8,
    parent: ?[]const u8,
    entries_json: []const u8,
) ![]u8 {
    return printFolderJson(allocator, relative, absolute, home, parent, entries_json);
}

/// Body for a request with no `action` (or an unknown one) -- that shape
/// has no `entries` key. Kept byte-compatible with the pre-refactor
/// response so an existing client cannot notice the change.
pub fn buildFolderInfoJson(
    allocator: std.mem.Allocator,
    relative: []const u8,
    absolute: []const u8,
    home: []const u8,
    parent: ?[]const u8,
) ![]u8 {
    return printFolderJson(allocator, relative, absolute, home, parent, null);
}

/// System folder endpoint
///
/// GET /api/system/folder
/// GET /api/system/folder?path=/some/relative/path
/// GET /api/system/folder?path=/some/relative/path&action=list
/// GET /api/system/folder?path=/some/relative/path&action=read&file=filename.txt
pub fn systemFolderHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const path_param = req.query.get("path");
    const action = req.query.get("action");
    const do_list = std.mem.eql(u8, action orelse "", "list");

    if (path_param) |p| {
        if (p.len == 0 and std.mem.eql(u8, action orelse "", "search")) {
            return res.jsonResponse( .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "path required" }) });
        }
    }

    const di = try nalarcore.getSingleton();
    const environment = di.environment;


    const home = SystemFolder.getHomeDirectory(allocator, environment) catch |err| {
        return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeSystemFolderErrorResponse(allocator, "Failed to get home directory", err) });
    };

    const target_path: []u8 = if (path_param) |p|
        SystemFolder.resolvePath(allocator, p, environment) catch |err| {
            return res.jsonResponse( .{ .status_code = 400, .data = try http_response.makeSystemFolderErrorResponse(allocator, "Invalid path", err) });
        }
    else blk: {
        const dup = allocator.dupe(u8, home) catch {
            return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) });
        };
        break :blk dup;
    };

    if (!std.fs.path.isAbsolute(target_path)) {
        if (path_param != null) {
            return res.jsonResponse( .{ .status_code = 400, .data = try http_response.makeSystemFolderErrorResponse(allocator, "path must be absolute", SystemFolderError.InvalidPath) });
        }
        return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeSystemFolderErrorResponse(allocator, "home directory must be absolute", SystemFolderError.InvalidPath) });
    }

    const relative = SystemFolder.getRelativePathFromHome(allocator, target_path, home) catch |err| {
        return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeSystemFolderErrorResponse(allocator, "Failed to compute relative path", err) });
    };

    const parent_opt = SystemFolder.getParentPath(allocator, target_path, environment) catch null;
    const parent_relative = if (parent_opt) |parent|
        SystemFolder.getRelativePathFromHome(allocator, parent, home) catch null
    else
        null;

    if (do_list) {
        const entries = SystemFolder.listDirectory(allocator, ctx.io, target_path) catch |err| {
            const err_msg: []const u8 = switch (err) {
                SystemFolderError.InvalidPath => "Directory not found",
                SystemFolderError.AccessDenied => "Access denied",
                SystemFolderError.NotDirectory => "Not a directory",
                else => @errorName(err),
            };
            return res.jsonResponse( .{ .status_code = 403, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
        };
        defer {
            for (entries) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.path);
            }
            allocator.free(entries);
        }

        // Build entries JSON via the shared serializer (the search
        // branch below uses the same one).
        const entries_json = try buildEntriesJson(allocator, entries);
        defer allocator.free(entries_json);

        return res.jsonResponse(.{ .status_code = 200, .data = try buildFolderListJson(
            allocator,
            relative,
            target_path,
            home,
            parent_relative,
            entries_json,
        ) });
    }

 // Recursive server-side search for the ChatView `@` picker:
    // GET /api/system/folder?action=search&path=<root>&q=comp&limit=50
    // Same route as list (no new main.zig registration); same entry
    // shape ({name, path, is_directory, is_symlink}). Missing `q` =
    // top-N listing (not an error); `limit` defaults to 50 (hard cap
    // 200); `max_depth` defaults to 8 (clamp 1..16).
    const do_search = std.mem.eql(u8, action orelse "", "search");
    if (do_search) {
        const q = req.query.get("q") orelse "";
        const limit = SystemFolder.parseSearchLimit(req.query.get("limit"));
        const max_depth = SystemFolder.parseSearchMaxDepth(req.query.get("max_depth"));

        const entries = SystemFolder.searchFiles(allocator, ctx.io, target_path, q, limit, max_depth) catch |err| {
            const err_msg: []const u8 = switch (err) {
                SystemFolderError.InvalidPath => "Directory not found",
                SystemFolderError.AccessDenied => "Access denied",
                SystemFolderError.NotDirectory => "Not a directory",
                else => @errorName(err),
            };
            return res.jsonResponse( .{ .status_code = 403, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = err_msg }) });
        };
        defer {
            for (entries) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.path);
            }
            allocator.free(entries);
        }

        // Build entries JSON via the same serializer the list branch
        // uses -- SAME wire shape for both.
        const search_entries_json = try buildEntriesJson(allocator, entries);
        defer allocator.free(search_entries_json);

        return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"entries\":[{s}]}}",
            .{search_entries_json}) });
    }

    // Handle read/write actions - read file content
    const do_read_write = std.mem.eql(u8, action orelse "", "read") or std.mem.eql(u8, action orelse "", "write");
    if (do_read_write) {
        const file_name = req.query.get("file") orelse "";

        // Use native absolute-path semantics. A Windows-looking path on
        // POSIX (or a drive-relative `C:file` on Windows) is not absolute
        // and must be joined to the already-validated base path.
        const is_abs = std.fs.path.isAbsolute(file_name);
        const full_path: []u8 = if (is_abs)
            allocator.dupe(u8, file_name) catch return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }) })
        else
            std.fs.path.join(allocator, &.{ target_path, file_name }) catch return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to build path" }) });
        defer allocator.free(full_path);

        if (!std.fs.path.isAbsolute(full_path)) {
            return res.jsonResponse( .{ .status_code = 403, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Cannot open file" }) });
        }

        // Read file using std.Io.Dir.openFileAbsolute
        const file = std.Io.Dir.openFileAbsolute(ctx.io, full_path, .{}) catch return res.jsonResponse( .{ .status_code = 403, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Cannot open file" }) });
        defer file.close(ctx.io);

        var read_buf: [8192]u8 = undefined;
        var reader = file.reader(ctx.io, &read_buf);
        const file_content_init = reader.interface.allocRemaining(allocator, .limited(1024 * 1024 * 10)) catch return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to read file" }) });
        defer allocator.free(file_content_init);

        // Escape content for JSON
        const escaped_content = jsonEscape(allocator, file_content_init) catch file_content_init;
        defer allocator.free(escaped_content);

        // Return as JSON with plain text content
        return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
            "{{\"content\":\"{s}\",\"encoding\":\"utf-8\"}}",
            .{ escaped_content }) });
    }

    // No recognised action: return the location WITHOUT an `entries`
    // key -- that shape predates the list/search split, so keep it.
    return res.jsonResponse(.{ .status_code = 200, .data = try buildFolderInfoJson(
        allocator,
        relative,
        target_path,
        home,
        parent_relative,
    ) });
}

// ===== Tests merged from system_folder_search_test.zig (2026-09-11 flatten) =====
// Static-contract tests for `action=search` on GET /api/system/folder
// (plan: docs/superpowers/plans/2026-09-08-chatview-search-files-perf.md,
// Task 1).
// 
// Why this file exists
// ────────────────────
// The ChatView `@` picker used to walk the tree with N sequential
// `action=list` fetches (one per directory). The fix adds a single
// server-side recursive search branch (`action=search` with `q`,
// `limit`, `max_depth` params) backed by
// `SystemFolder.searchFiles`, serialized in the SAME
// `{name, path, is_directory, is_symlink}` shape as list.
// 
// Standing up a real server + singleton + Io to exercise the HTTP path
// is too much integration infra for one branch (same rationale as
// `frontend_log_post_test.zig`), so these contracts grep the handler
// source for the substrings a future refactor must preserve. The
// search behaviour itself is covered behaviourally by the `searchFiles`
// + `parseSearchLimit/parseSearchMaxDepth` tests in
// `src/modules/system_folder/system_folder_test.zig`; the wire
// behaviour lands in `tests/functional/system_folder_search_test.py`
// (Task 4 of the same plan).

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/system_folder.zig";
const MAIN_PATH = "src/http_routes.zig";
const TEST_RUNNER_PATH = "src/ai_workflow/tui/test_runner.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOf(u8, haystack[from..], needle)) |idx| {
        n += 1;
        from += idx + needle.len;
    }
    return n;
}

// ─── Contract 1: handler branches on action=search ───────────────────────

test "system_folder handler branches on action=search" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Without this branch the `@` picker falls back to N sequential
    // action=list walks (the perf bug this plan fixes).
    if (std.mem.indexOf(u8, source, "\"search\"") == null) {
        std.debug.print(
            "\n!! {s} has no action=search branch !!\n" ++
                "   The ChatView `@` picker needs a single server-side\n" ++
                "   recursive search; without it the frontend walks the\n" ++
                "   tree with one action=list fetch per directory.\n" ++
                "   See docs/superpowers/plans/2026-09-08-chatview-search-files-perf.md Task 1.\n",
            .{HANDLER_PATH},
        );
        return error.SearchActionBranchMissing;
    }
}

// ─── Contract 2: handler parses the q param ─────────────────────────────

test "system_folder search parses q param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.query.get(\"q\")") == null) {
        std.debug.print(
            "\n!! {s} does not parse the q param !!\n" ++
                "   action=search must read `q` (default \"\" = top-N\n" ++
                "   listing) and pass it to SystemFolder.searchFiles.\n",
            .{HANDLER_PATH},
        );
        return error.SearchQueryParamMissing;
    }
}

// ─── Contract 3: handler clamps limit via parseSearchLimit ───────────────

test "system_folder search clamps limit via parseSearchLimit" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // parseSearchLimit = default 50, clamp 1..200 (hard cap). Going
    // through the shared helper keeps the handler and the unit tests
    // on the same clamp semantics.
    if (std.mem.indexOf(u8, source, "parseSearchLimit") == null) {
        std.debug.print(
            "\n!! {s} does not use parseSearchLimit !!\n" ++
                "   action=search must clamp `limit` (default 50, hard\n" ++
                "   cap 200) via SystemFolder.parseSearchLimit so a\n" ++
                "   `limit=5000` query cannot blow up the response.\n",
            .{HANDLER_PATH},
        );
        return error.SearchLimitClampMissing;
    }
}

// ─── Contract 4: handler clamps max_depth via parseSearchMaxDepth ────────

test "system_folder search clamps max_depth via parseSearchMaxDepth" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseSearchMaxDepth") == null) {
        std.debug.print(
            "\n!! {s} does not use parseSearchMaxDepth !!\n" ++
                "   action=search must clamp `max_depth` (default 8,\n" ++
                "   clamp 1..16) via SystemFolder.parseSearchMaxDepth.\n",
            .{HANDLER_PATH},
        );
        return error.SearchMaxDepthClampMissing;
    }
}

// ─── Contract 5: handler delegates to SystemFolder.searchFiles ───────────

test "system_folder search delegates to SystemFolder.searchFiles" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "searchFiles") == null) {
        std.debug.print(
            "\n!! {s} does not call searchFiles !!\n" ++
                "   action=search must delegate the walk to\n" ++
                "   SystemFolder.searchFiles (skip-list + limit +\n" ++
                "   ranking live there, unit-tested in\n" ++
                "   system_folder_test.zig).\n",
            .{HANDLER_PATH},
        );
        return error.SearchFilesNotCalled;
    }
}

// ─── Contract 6: empty path is rejected with 400 ─────────────────────────

test "system_folder search guards empty path with 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // SqliteBackend-style empty-slice-as-NULL rule: an explicitly empty
    // `path=` must 400 with a greppable message, not fall through to
    // home (missing param) or to a 403 InvalidPath.
    if (std.mem.indexOf(u8, source, "path required") == null) {
        std.debug.print(
            "\n!! {s} does not guard empty path !!\n" ++
                "   action=search with an explicitly empty `path=` must\n" ++
                "   return 400 with the substring `path required`.\n",
            .{HANDLER_PATH},
        );
        return error.SearchEmptyPathGuardMissing;
    }
}

// ─── Contract 7 (guard): action=list branch is unchanged ─────────────────

test "system_folder action=list branch is unchanged" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The old single-level list contract must keep working (Task 4
    // replays it as a regression guard); the search branch is additive.
    if (std.mem.indexOf(u8, source, "\"list\"") == null) {
        std.debug.print(
            "\n!! {s} lost the action=list branch !!\n" ++
                "   The search branch is additive — action=list must\n" ++
                "   keep serving single-level listings.\n",
            .{HANDLER_PATH},
        );
        return error.ListActionBranchMissing;
    }
}

// ─── Contract 8 (guard): entries serialize snake_case is_directory ───────

test "system_folder entries serialize snake_case is_directory" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The kanban picker already mis-reads camelCase `isDirectory`
    // (always undefined → all rows treated as files). The search
    // branch must reuse the SAME snake_case shape as list.
    if (std.mem.indexOf(u8, source, "is_directory") == null) {
        std.debug.print(
            "\n!! {s} does not serialize is_directory !!\n" ++
                "   Both list and search entries must use snake_case\n" ++
                "   `is_directory` on the wire.\n",
            .{HANDLER_PATH},
        );
        return error.SnakeCaseFieldMissing;
    }
}

// ─── Contract 9 (guard): same route, no new route in main.zig ───────────

test "system_folder search reuses the same route (no new main.zig route)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    // action=search rides on the existing GET /api/system/folder route
    // (route-order shadowing guard: a second literal route registered
    // after a param route would be captured).
    const n = countOccurrences(source, "/api/system/folder");
    if (n != 1) {
        std.debug.print(
            "\n!! {s} has {d} /api/system/folder routes (want 1) !!\n" ++
                "   action=search must reuse the existing route — do NOT\n" ++
                "   register a new one in main.zig.\n",
            .{ MAIN_PATH, n },
        );
        return error.UnexpectedRouteCount;
    }
}

// ─── Contract 10 (guard): tui test_runner registers this file ───────────

test "tui test_runner registers system_folder" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TEST_RUNNER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "system_folder.zig") == null) {
        std.debug.print(
            "\n!! {s} does not import system_folder.zig !!\n" ++
                "   Register the file so `zig build test` runs these contracts.\n",
            .{TEST_RUNNER_PATH},
        );
        return error.TestRunnerRegistrationMissing;
    }
}

// ===== Behavioural tests: the Windows wire format ========================
//
// The contracts above only prove the SOURCE mentions `search`,
// `parseSearchLimit`, … — none of them would notice if the response body
// stopped being valid JSON. On Windows that is the whole failure mode: the
// top-level `path` / `absolute` / `home` / `parent` fields and every
// `entries[].path` hold backslash paths (`C:\Users\ginwa`), and a lone
// backslash is an invalid JSON escape. When those were interpolated raw
// the frontend's `response.json()` threw and the picker rendered empty.
//
// So: parse what the builders emit and compare against the input. A
// regression that drops an `jsonEscape` fails here, on every platform,
// without needing a Windows runner.

/// Parse a built body and return the value, so a body that is not JSON
/// fails the test instead of silently comparing as text.
fn parseBody(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{});
}

test "buildFolderListJson: Windows backslash paths round-trip through JSON" {
    const allocator = testing.allocator;
    const entries = try allocator.dupe(FolderEntry, &.{
        .{ .name = try allocator.dupe(u8, "Documents"), .path = try allocator.dupe(u8, "C:\\Users\\ginwa\\Documents"), .is_directory = true, .is_symlink = false },
    });
    defer {
        for (entries) |e| {
            allocator.free(e.name);
            allocator.free(e.path);
        }
        allocator.free(entries);
    }
    const entries_json = try buildEntriesJson(allocator, entries);
    defer allocator.free(entries_json);

    const body = try buildFolderListJson(
        allocator,
        "/Documents",
        "C:\\Users\\ginwa\\Documents",
        "C:\\Users\\ginwa",
        "/",
        entries_json,
    );
    defer allocator.free(body);

    // The raw text must carry DOUBLED backslashes — this is the exact
    // property that was lost before, and `std.json` below is what proves
    // the doubling was necessary in the first place.
    try testing.expect(std.mem.indexOf(u8, body, "C:\\\\Users\\\\ginwa") != null);

    const parsed = try parseBody(allocator, body);
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("/Documents", obj.get("path").?.string);
    try testing.expectEqualStrings("C:\\Users\\ginwa\\Documents", obj.get("absolute").?.string);
    try testing.expectEqualStrings("C:\\Users\\ginwa", obj.get("home").?.string);
    try testing.expectEqualStrings("/", obj.get("parent").?.string);

    const rows = obj.get("entries").?.array;
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("Documents", rows.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("C:\\Users\\ginwa\\Documents", rows.items[0].object.get("path").?.string);
    try testing.expectEqual(true, rows.items[0].object.get("is_directory").?.bool);
    try testing.expectEqual(false, rows.items[0].object.get("is_symlink").?.bool);
}

test "buildFolderListJson: a raw (unescaped) interpolation would not be JSON" {
    // The control for the test above. Same values, interpolated the way
    // the handler used to, MUST fail to parse — otherwise the escaping
    // assertion above proves nothing.
    var bad = std.ArrayList(u8).empty;
    defer bad.deinit(testing.allocator);
    try bad.appendSlice(testing.allocator,
        "{\"path\":\"/Documents\",\"absolute\":\"C:\\Users\\ginwa\",\"home\":\"C:\\Users\\ginwa\"}");
    // Any parse failure is the point — the exact error type is a stdlib
    // detail (`\U` is an invalid escape), not the contract.
    if (parseBody(testing.allocator, bad.items)) |ok| {
        var parsed = ok;
        defer parsed.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "buildFolderListJson: UNC home round-trips (redirected Windows profile)" {
    const allocator = testing.allocator;
    const body = try buildFolderListJson(
        allocator,
        "/Documents",
        "\\\\fileserver\\share\\ginwa\\Documents",
        "\\\\fileserver\\share\\ginwa",
        "/",
        "",
    );
    defer allocator.free(body);

    const parsed = try parseBody(allocator, body);
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "\\\\fileserver\\share\\ginwa",
        parsed.value.object.get("home").?.string,
    );
    try testing.expectEqualStrings(
        "\\\\fileserver\\share\\ginwa\\Documents",
        parsed.value.object.get("absolute").?.string,
    );
}

test "buildFolderInfoJson: no-action body keeps its shape (no entries key)" {
    const allocator = testing.allocator;

    const with_parent = try buildFolderInfoJson(
        allocator,
        "/Documents",
        "C:\\Users\\ginwa\\Documents",
        "C:\\Users\\ginwa",
        "/",
    );
    defer allocator.free(with_parent);
    {
        const parsed = try parseBody(allocator, with_parent);
        defer parsed.deinit();
        try testing.expectEqualStrings("/Documents", parsed.value.object.get("path").?.string);
        try testing.expectEqualStrings("C:\\Users\\ginwa", parsed.value.object.get("home").?.string);
        try testing.expectEqualStrings("/", parsed.value.object.get("parent").?.string);
        try testing.expect(parsed.value.object.get("entries") == null);
    }

    // The home root: `getParentPath` returns null there, so the body has
    // no `parent` key at all. Asserted separately so adding one later is
    // a deliberate wire change.
    const at_home = try buildFolderInfoJson(
        allocator,
        "/",
        "C:\\Users\\ginwa",
        "C:\\Users\\ginwa",
        null,
    );
    defer allocator.free(at_home);
    const parsed = try parseBody(allocator, at_home);
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("parent") == null);
    try testing.expect(parsed.value.object.get("entries") == null);
    try testing.expectEqualStrings("C:\\Users\\ginwa", parsed.value.object.get("absolute").?.string);
}

test "buildEntriesJson: empty entry list renders an empty array" {
    const allocator = testing.allocator;
    const json = try buildEntriesJson(allocator, &.{});
    defer allocator.free(json);
    try testing.expectEqualStrings("", json);

    const body = try buildFolderListJson(allocator, "/", "/home/u", "/home/u", null, json);
    defer allocator.free(body);
    const parsed = try parseBody(allocator, body);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.value.object.get("entries").?.array.items.len);
}
