// Functional wire tests for FOLDER mode of POST /api/git/file/diffs.
//
// LIST mode (`git_file_diffs_test.zig`) still needs the caller to fetch
// `GET /api/git/changes` first and then post the file list. FOLDER mode drops
// that round trip: the client sends a folder and the server enumerates the
// changed paths itself, so a panel renders 50 changed files with ONE request
// instead of 50 `GET /api/git/file/diff` calls.
//
// Fixture repo — under `pabrik-fix-` (see `git_file_diffs_test.zig` for why
// neither the harness tempdir nor `std.testing.tmpDir` is usable):
//   <repo>/src/committed.txt   committed, then modified        → unstaged
//   <repo>/src/staged.txt      committed, modified, `git add`ed → staged
//   <repo>/src/fresh.txt       untracked INSIDE src/  → synthetic new-file diff
//   <repo>/docs/readme.txt     committed, then modified → unstaged, OUTSIDE src/
//   <repo>/top.txt             committed, then modified → unstaged, at the root
//   <repo>/clean/untouched.txt committed, never touched → no diff at all
//
// The `clean/` directory is the load-bearing one: a folder with nothing
// changed must answer `{"diffs": []}` with 200. The old "empty request is a
// 400" rule belongs to LIST mode; a 400 here pushes the frontend into its
// per-file fallback and restarts the request flood.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// Run `git` with a fixed identity so the fixture never depends on the
/// machine's global git config (which CI does not set).
fn git(cwd: []const u8, args: []const []const u8) !void {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, "git");
    try full.append(gpa, "-c");
    try full.append(gpa, "user.email=t@t");
    try full.append(gpa, "-c");
    try full.append(gpa, "user.name=t");
    try full.appendSlice(gpa, args);

    var child = try std.process.spawn(io, .{ .argv = full.items, .cwd = .{ .path = cwd } });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git {s} failed with rc={d}\n", .{ args[args.len - 1], code });
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("git {s} died by signal\n", .{args[args.len - 1]});
            return error.TestUnexpectedResult;
        },
    }
}

fn writeFileAt(dir: std.Io.Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io, parent);
    }
    var f = try dir.createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

fn buildFolderCwd(scratch: []const u8) ![]u8 {
    const repo = try std.fs.path.join(gpa, &.{ scratch, "folder-diff-proj" });
    errdefer gpa.free(repo);

    try std.Io.Dir.cwd().createDirPath(io, repo);
    var repo_dir = try std.Io.Dir.cwd().openDir(io, repo, .{});
    defer repo_dir.close(io);

    try git(scratch, &.{ "init", "--initial-branch=main", "--quiet", repo });

    for ([_]struct { []const u8, []const u8 }{
        .{ "src/committed.txt", "keep\nold\n" },
        .{ "src/staged.txt", "keep\nold\n" },
        .{ "docs/readme.txt", "keep\nold\n" },
        .{ "top.txt", "keep\nold\n" },
        .{ "clean/untouched.txt", "never touched\n" },
    }) |seed| {
        try writeFileAt(repo_dir, seed[0], seed[1]);
    }
    try git(repo, &.{ "add", "-A" });
    try git(repo, &.{ "commit", "--quiet", "-m", "base" });

    try writeFileAt(repo_dir, "src/committed.txt", "keep\nnew\n");
    try writeFileAt(repo_dir, "src/staged.txt", "keep\nnew\n");
    try git(repo, &.{ "add", "src/staged.txt" });
    try writeFileAt(repo_dir, "docs/readme.txt", "keep\nnew\n");
    try writeFileAt(repo_dir, "top.txt", "keep\nnew\n");
    try writeFileAt(repo_dir, "src/fresh.txt", "brand new\n");

    return repo;
}

fn bootWithRepo(h: *Harness, scratch: *[]u8, repo: *[]u8) !void {
    try harness.requirePabrikBin(io, gpa);
    h.* = try Harness.boot(io, gpa, .{});

    scratch.* = harness.makeScratchDir(gpa) catch |err| {
        h.deinit(io) catch {};
        return err;
    };
    repo.* = buildFolderCwd(scratch.*) catch |err| {
        harness.cleanupExtraDir(io, gpa, scratch.*);
        h.deinit(io) catch {};
        return err;
    };
}

/// Boot + the LIFO `defer` ladder that owns the buffers.
///
/// Defer order is loads-bearing: `free(scratch)` must run AFTER
/// `cleanupExtraDir(scratch)`, and `free(repo)` must run AFTER the HTTP calls
/// that still read `repo`. Registering a free before its reader segfaults
/// inside `isSafeTmp` on a dangling pointer.
const Fixture = struct {
    h: Harness,
    scratch: []u8,
    repo: []u8,

    fn init() !Fixture {
        var f: Fixture = undefined;
        try bootWithRepo(&f.h, &f.scratch, &f.repo);
        return f;
    }

    fn deinit(self: *Fixture) void {
        self.h.deinit(io) catch |err| std.debug.print("teardown: {s}\n", .{@errorName(err)});
        gpa.free(self.repo);
        harness.cleanupExtraDir(io, gpa, self.scratch);
        gpa.free(self.scratch);
    }
};

/// `{"path": ..., "folder": <folder>}` — folder mode, no file list.
fn folderBody(repo: []const u8, folder: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"path\":\"{s}\",\"folder\":\"{s}\"}}", .{ repo, folder });
}

fn postFolder(h: *Harness, body: []const u8, expect: []const u16) !harness.Response {
    return h.http(io, .POST, "/api/git/file/diffs", .{
        .json_body = body,
        .expect = expect,
        .timeout_s = 30.0,
    });
}

/// `(staged, path) -> diff_content` for a parsed `diffs` array.
///
/// The python used `{d["staged"], d["path"]: d["diff_content"] ...}`. A
/// `std.json.Value` cannot be a map key, so this keys on the FORMATTED
/// `"{staged}:{path}"` string instead — owned, and freed by the caller.
fn indexBySideAndPath(gpa_: std.mem.Allocator, diffs: []const std.json.Value) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(gpa_);
    errdefer {
        var it = map.keyIterator();
        while (it.next()) |k| gpa_.free(k.*);
        map.deinit();
    }
    for (diffs) |row| {
        const obj = switch (row) {
            .object => |o| o,
            else => return error.TestUnexpectedResult,
        };
        const path = obj.get("path") orelse return error.TestUnexpectedResult;
        const staged = obj.get("staged") orelse return error.TestUnexpectedResult;
        const key = switch (staged) {
            .bool => |b| try std.fmt.allocPrint(gpa_, "{s}:{s}", .{ if (b) "1" else "0", path.string }),
            else => return error.TestUnexpectedResult,
        };
        // First row wins; duplicates should not happen within one side.
        if (map.contains(key)) {
            gpa_.free(key);
            continue;
        }
        try map.put(key, obj.get("diff_content").?.string);
    }
    return map;
}

fn freeIndex(gpa_: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.keyIterator();
    while (it.next()) |k| gpa_.free(k.*);
    map.deinit();
}

fn expectRow(map: *const std.StringHashMap([]const u8), staged: bool, path: []const u8) ![]const u8 {
    const key = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ if (staged) "1" else "0", path });
    defer gpa.free(key);
    return map.get(key) orelse error.TestUnexpectedResult;
}

/// Collect the set of paths a response reported, as an owned StringHashMap.
fn pathSet(gpa_: std.mem.Allocator, diffs: []const std.json.Value) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(gpa_);
    errdefer {
        var it = set.keyIterator();
        while (it.next()) |k| gpa_.free(k.*);
        set.deinit();
    }
    for (diffs) |row| {
        const path = row.object.get("path") orelse return error.TestUnexpectedResult;
        try set.put(try gpa_.dupe(u8, path.string), {});
    }
    return set;
}

fn expectSameSet(got: *const std.StringHashMap(void), want: []const []const u8) !void {
    try testing.expectEqual(want.len, got.count());
    for (want) |w| try testing.expect(got.contains(w));
}

// One POST on `folder: "src"` returns staged + unstaged + untracked.
test "folder_mode_returns_every_changed_file_under_the_folder_in_one_call" {
    var f = try Fixture.init();
    defer f.deinit();

    const body = try folderBody(f.repo, "src");
    defer gpa.free(body);

    var r = try postFolder(&f.h, body, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const diffs = doc.array("diffs") orelse return error.TestUnexpectedResult;
    var by_key = try indexBySideAndPath(gpa, diffs.items);
    defer freeIndex(gpa, &by_key);

    // The two sides the caller would otherwise have had to enumerate itself.
    try testing.expect(std.mem.indexOf(u8, try expectRow(&by_key, false, "src/committed.txt"), "+new") != null);
    try testing.expect(std.mem.indexOf(u8, try expectRow(&by_key, true, "src/staged.txt"), "+new") != null);
    // Untracked under src/ — `git diff` shows nothing for it, so this only
    // works if the server enumerated the path AND fell back to the synthetic
    // new-file diff. `-uall` on the status call is what surfaces the FILE
    // rather than the directory.
    try testing.expect(std.mem.indexOf(u8, try expectRow(&by_key, false, "src/fresh.txt"), "+brand new") != null);
}

// `folder: "src"` must not leak sibling or root-level changes.
test "folder_mode_excludes_files_outside_the_folder" {
    var f = try Fixture.init();
    defer f.deinit();

    const body = try folderBody(f.repo, "src");
    defer gpa.free(body);

    var r = try postFolder(&f.h, body, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const diffs = doc.array("diffs") orelse return error.TestUnexpectedResult;
    var got = try pathSet(gpa, diffs.items);
    defer {
        var it = got.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        got.deinit();
    }
    try expectSameSet(&got, &.{ "src/committed.txt", "src/staged.txt", "src/fresh.txt" });
}

// `folder: ""` is the whole repo, and reaches docs/ and the root.
test "empty_folder_string_means_the_whole_repo" {
    var f = try Fixture.init();
    defer f.deinit();

    const body = try folderBody(f.repo, "");
    defer gpa.free(body);

    var r = try postFolder(&f.h, body, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const diffs = doc.array("diffs") orelse return error.TestUnexpectedResult;
    var got = try pathSet(gpa, diffs.items);
    defer {
        var it = got.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        got.deinit();
    }
    try expectSameSet(&got, &.{
        "src/committed.txt",
        "src/staged.txt",
        "src/fresh.txt",
        "docs/readme.txt",
        "top.txt",
    });
}

// A folder with no changes is a real answer. A 400 would push the client into
// its per-file fallback and restart the request flood.
test "clean_folder_is_an_empty_list_not_a_400" {
    var f = try Fixture.init();
    defer f.deinit();

    const body = try folderBody(f.repo, "clean");
    defer gpa.free(body);

    var r = try postFolder(&f.h, body, &.{200});
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);

    var doc = try r.json();
    defer doc.deinit();
    const diffs = doc.array("diffs") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), diffs.items.len);
}

// The same file through both modes must produce byte-identical content.
test "folder_mode_matches_list_mode_content" {
    var f = try Fixture.init();
    defer f.deinit();

    const whole = try folderBody(f.repo, "");
    defer gpa.free(whole);
    var r = try postFolder(&f.h, whole, &.{200});
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();
    var folder_side = try indexBySideAndPath(gpa, doc.array("diffs").?.items);
    defer freeIndex(gpa, &folder_side);

    const list_body = try std.fmt.allocPrint(
        gpa,
        "{{\"path\":\"{s}\",\"files\":[" ++
            "{{\"file\":\"src/committed.txt\",\"staged\":false}}," ++
            "{{\"file\":\"docs/readme.txt\",\"staged\":false}}," ++
            "{{\"file\":\"top.txt\",\"staged\":false}}]}}",
        .{f.repo},
    );
    defer gpa.free(list_body);

    var lr = try postFolder(&f.h, list_body, &.{200});
    defer lr.deinit();
    var ldoc = try lr.json();
    defer ldoc.deinit();

    const rows = ldoc.array("diffs").?.items;
    try testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row| {
        const path = row.object.get("path").?.string;
        try testing.expectEqualStrings(
            row.object.get("diff_content").?.string,
            try expectRow(&folder_side, false, path),
        );
    }
}

// `folder` becomes a git pathspec; `..` would diff outside the repo.
test "folder_mode_rejects_a_parent_escaping_path" {
    var f = try Fixture.init();
    defer f.deinit();

    for ([_][]const u8{ "../..", "/etc" }) |bad| {
        const body = try folderBody(f.repo, bad);
        defer gpa.free(body);
        var r = try postFolder(&f.h, body, &.{400});
        defer r.deinit();
        try testing.expectEqual(@as(u16, 400), r.status);
    }
}

// Sending neither `files` nor `folder` is a 400, not a silent "no changes".
test "sending_neither_files_nor_folder_is_a_400" {
    var f = try Fixture.init();
    defer f.deinit();

    const body = try std.fmt.allocPrint(gpa, "{{\"path\":\"{s}\"}}", .{f.repo});
    defer gpa.free(body);

    var r = try postFolder(&f.h, body, &.{400});
    defer r.deinit();
    try testing.expectEqual(@as(u16, 400), r.status);
}
