const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const http_response = @import("http_response.zig");
const ai_workflow = root_mod.ai_workflow;
const httpz = http_server.httpz;

/// Git status endpoint - returns current branch and status for a directory
pub fn gitStatusHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const io = ctxTui.io;


            // Get path from query parameter
            const query = req.query() catch {
                res.status = 400;
                res.body = try http_response.makeGitStatusErrorResponse(alloc, "Missing path parameter");
                return;
            };
            const path_param = query.get("path") orelse {
                res.status = 400;
                res.body = try http_response.makeGitStatusErrorResponse(alloc, "Missing path parameter");
                return;
            };

            // Check if we're in a git repo by running git rev-parse --git-dir with -C
            const git_check = std.process.run(alloc, io, .{
                .argv = &.{ "git", "-C", path_param, "rev-parse", "--git-dir" },
            }) catch |err| {
                res.status = 500;
                res.body = try http_response.makeGitStatusErrorResponse(alloc, @errorName(err));
                return;
            };

            // Determine if it's a git repo based on rev-parse exit code
            const is_git_repo = git_check.term.exited == 0;

            // If not a git repo, return early
            if (!is_git_repo) {
                const response = http_response.GitStatusResponse{
                    .is_git_repo = false,
                };
                res.status = 500;
                res.body = try http_response.makeGitStatusResponse(alloc, response);
                return;
            }

            // Get current branch using: git -C <path> branch --show-current
            const branch_result = std.process.run(alloc, io, .{
                .argv = &.{ "git", "-C", path_param, "branch", "--show-current" },
            }) catch |err| {
                res.status = 500;
                res.body = try http_response.makeGitStatusErrorResponse(alloc, @errorName(err));
                return;
            };

            // Get status using: git -C <path> status --porcelain
            const status_result = std.process.run(alloc, io, .{
                .argv = &.{ "git", "-C", path_param, "status", "--porcelain" },
            }) catch |err| {
                res.status = 500;
                res.body = try http_response.makeGitStatusErrorResponse(alloc, @errorName(err));
                return;
            };

            // Parse branch name
            const branch_name = std.mem.trim(u8, branch_result.stdout, " \n\r");

            // Check if there are changes
            const has_changes = status_result.stdout.len > 0;

            // Build response
            const is_clean = !has_changes;
            const status_text: []const u8 = if (has_changes) "modified" else "clean";

            const response = http_response.GitStatusResponse{
                .is_git_repo = true,
                .branch = branch_name,
                .has_changes = has_changes,
                .is_clean = is_clean,
                .status = status_text,
            };

            res.status = 200;
            res.body = try http_response.makeGitStatusResponse(alloc, response);
        }
    }
}
