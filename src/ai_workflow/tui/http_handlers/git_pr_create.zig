const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

/// Create a pull request on the worktree at `worktree_path`.
/// Body: { "worktree_path": "...", "base": "main", "title": "...", "body": "..." }
///
/// Runs `gh pr create --base <base> --title <title> --body <body>` in the
/// worktree path. Returns the PR URL on success, or a structured error
/// with the `gh` stderr on failure (so the user can see what went wrong).
///
/// Per the project memory `zig-0.16-spawn-cwd-is-not-nullable.md`, the
/// `.cwd` field on `std.process.spawn` MUST be a `process.Child.Cwd`
/// tagged-union value — NOT `null` — so we use `.{ .path = ... }` to
/// run `gh` inside the worktree directory.
pub fn gitPrCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Parse JSON body using the Leaky variant — see memory
    // nalar-http-handler-thin-wrapper-pattern.md.
    const Body = struct {
        worktree_path: []const u8 = "",
        base: []const u8 = "main",
        title: []const u8 = "",
        body: []const u8 = "",
    };
    const parsed = std.json.parseFromSliceLeaky(Body, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }) });
    };

    if (parsed.worktree_path.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "worktree_path is required" }) });
    }
    if (parsed.title.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "title is required" }) });
    }

    // Run `gh pr create --base <base> --title <title> --body <body>`.
    // Capture stdout (the PR URL) and stderr (error details).
    const argv = &[_][]const u8{
        "gh", "pr", "create",
        "--base",      parsed.base,
        "--title",     parsed.title,
        "--body",      parsed.body,
    };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = parsed.worktree_path }, // see memory zig-0.16-spawn-cwd-is-not-nullable.md
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        // `gh` not found (FileNotFound from spawn) or other spawn-time
        // failure — return a clear 500 with a hint about `gh`.
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitPrCreateResponse(allocator, http_response.GitPrCreateResponse{
            .success = false,
            .pr_url = "",
            .error_message = try std.fmt.allocPrint(allocator, "{s} (is the gh CLI installed and on PATH?)", .{@errorName(err)}),
        }) });
    };

    // Read stdout + stderr in parallel (bounded to 64KB each, like
    // set_git_worktree.zig:160-190).
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    if (child.stdout) |pipe| {
        while (true) {
            const n = std.Io.File.readStreaming(pipe, io, &.{&read_buf}) catch break;
            if (n == 0) break;
            if (stdout_buf.items.len < 64 * 1024) {
                const take = @min(n, 64 * 1024 - stdout_buf.items.len);
                stdout_buf.appendSlice(allocator, read_buf[0..take]) catch break;
            }
        }
    }
    if (child.stderr) |pipe| {
        while (true) {
            const n = std.Io.File.readStreaming(pipe, io, &.{&read_buf}) catch break;
            if (n == 0) break;
            if (stderr_buf.items.len < 64 * 1024) {
                const take = @min(n, 64 * 1024 - stderr_buf.items.len);
                stderr_buf.appendSlice(allocator, read_buf[0..take]) catch break;
            }
        }
    }

    const term = child.wait(io) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "gh wait failed" }) });
    };
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                // Surface the gh CLI error verbatim so the user can debug
                // (e.g. "no commits between origin/main and worktree/feature-x").
                return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitPrCreateResponse(allocator, http_response.GitPrCreateResponse{
                    .success = false,
                    .pr_url = "",
                    .error_message = std.mem.trim(u8, stderr_buf.items, " \n\r"),
                }) });
            }
        },
        else => {
            return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "gh killed by signal" }) });
        },
    }

    // gh pr create prints the PR URL on stdout
    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitPrCreateResponse(allocator, http_response.GitPrCreateResponse{
        .success = true,
        .pr_url = std.mem.trim(u8, stdout_buf.items, " \n\r"),
        .error_message = "",
    }) });
}