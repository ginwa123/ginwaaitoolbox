//! System folder path utilities
//! 
//! Provides utilities for resolving paths relative to home directory.

const std = @import("std");
const builtin = @import("builtin");

/// Error set for system folder operations
pub const SystemFolderError = error{
    HomeNotFound,
    OutOfMemory,
    InvalidPath,
    AccessDenied,
    NotDirectory,
};

/// Directory entry for folder listing
pub const FolderEntry = struct {
    name: []const u8,
    path: []const u8,
    is_directory: bool,
    is_symlink: bool,
};

/// Namespace containing system folder utilities
pub const SystemFolder = struct {
    /// Get the relative path from home directory
    /// 
    /// If `full_path` starts with `home`, returns the portion after home.
    /// Otherwise, returns the original `full_path` unchanged.
    /// 
    /// Returns "/" if path equals home exactly.
    pub fn getRelativePathFromHome(allocator: std.mem.Allocator, full_path: []const u8, home: []const u8) SystemFolderError![]u8 {
        // Normalize home path (remove trailing slash or backslash).
        // Windows homes look like `C:\Users\ginwa` (or `C:/Users/ginwa`
        // under Git Bash) — strip one trailing separator of either kind.
        const normalized_home = if (home.len > 0 and (home[home.len - 1] == '/' or home[home.len - 1] == '\\'))
            home[0..home.len - 1]
        else
            home;

        // Normalize full_path to remove trailing slash/backslash (but keep
        // filesystem roots like `/`, `C:\`, `C:/` intact).
        const normalized_path = if (full_path.len > 1 and (full_path[full_path.len - 1] == '/' or full_path[full_path.len - 1] == '\\'))
            full_path[0..full_path.len - 1]
        else
            full_path;
        
        // Check if full_path starts with home
        if (!std.mem.startsWith(u8, normalized_path, normalized_home)) {
            // Path doesn't start with home, return absolute path unchanged
            return allocator.dupe(u8, full_path);
        }
        
        // Check if path equals home exactly
        const after_home = normalized_path[normalized_home.len..];
        
        if (after_home.len == 0) {
            // Path equals home exactly
            return allocator.dupe(u8, "/");
        }
        
        // Remove leading slash/backslash from the remainder
        // (Windows remainder looks like `\Documents` when home is
        // `C:\Users\ginwa`).
        const remainder = if (after_home.len > 0 and (after_home[0] == '/' or after_home[0] == '\\'))
            after_home[1..]
        else
            after_home;
        
        // Build result with leading slash
        const result = try std.fmt.allocPrint(allocator, "/{s}", .{remainder});
        return result;
    }
    
    /// Get home directory from environment
    ///
    /// On POSIX the canonical var is `HOME`. On native Windows
    /// (cmd/pwsh — NOT Git Bash, which sets HOME to %USERPROFILE%)
    /// `HOME` is typically unset; fall back to `USERPROFILE`
    /// (Windows' canonical user-home variable), then to
    /// `HOMEDRIVE`+`HOMEPATH`. Only used if HOME is missing or empty.
    /// Mirrors helpers.db_path.getDbPath / helpers.dir.getDataAppsDir
    /// (same HOME -> USERPROFILE chain).
    pub fn getHomeDirectory(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const env = environment orelse return SystemFolderError.HomeNotFound;
        if (env.get("HOME")) |h| {
            if (h.len > 0) return allocator.dupe(u8, h) catch return SystemFolderError.OutOfMemory;
        }
        if (env.get("USERPROFILE")) |u| {
            if (u.len > 0) return allocator.dupe(u8, u) catch return SystemFolderError.OutOfMemory;
        }
        // Last resort on Windows: HOMEDRIVE (e.g. "C:") + HOMEPATH (e.g. "\Users\ginwa")
        if (env.get("HOMEDRIVE")) |drive| {
            if (env.get("HOMEPATH")) |hpath| {
                if (drive.len > 0 and hpath.len > 0) {
                    const joined = std.fs.path.join(allocator, &.{ drive, hpath }) catch return SystemFolderError.OutOfMemory;
                    return joined;
                }
            }
        }
        // Compat: on POSIX an explicitly-set-but-empty HOME historically
        // succeeded with "" (see test "HOME=empty string still succeeds").
        // The fallback chain above already preferred USERPROFILE/HOMEDRIVE
        // when present, so reaching here means no fallback existed —
        // preserve the old behaviour by returning HOME verbatim (even "").
        if (env.get("HOME")) |h| {
            return allocator.dupe(u8, h) catch return SystemFolderError.OutOfMemory;
        }
        return SystemFolderError.HomeNotFound;
    }
    
    /// Get the current working directory
    pub fn getCurrentWorkingDirectory(allocator: std.mem.Allocator) ![]u8 {
        return std.process.getCwdAlloc(allocator);
    }
    
    /// Get relative path from home for current working directory
    pub fn getCwdRelativeToHome(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        const cwd = try getCurrentWorkingDirectory(allocator);
        defer allocator.free(cwd);

        return getRelativePathFromHome(allocator, cwd, home);
    }

    /// Resolve a relative path to absolute path (relative to home)
    pub fn resolvePath(allocator: std.mem.Allocator, relative_path: []const u8, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        // Check if path already starts with home directory (absolute path)
        if (std.mem.startsWith(u8, relative_path, home)) {
            return allocator.dupe(u8, relative_path);
        }

        // If path starts with /, it's an absolute Unix path - return as-is
        if (std.mem.startsWith(u8, relative_path, "/")) {
            return allocator.dupe(u8, relative_path);
        }

        // Windows absolute path: drive letter (`C:\...`, `C:/...`) or
        // UNC (`\\server\share`). Return as-is so `listDirectory` can
        // open it directly via `openDirAbsolute`.
        if (relative_path.len >= 2 and std.ascii.isAlphabetic(relative_path[0]) and relative_path[1] == ':') {
            return allocator.dupe(u8, relative_path);
        }
        if (std.mem.startsWith(u8, relative_path, "\\\\") or std.mem.startsWith(u8, relative_path, "//")) {
            return allocator.dupe(u8, relative_path);
        }

        // Otherwise treat as absolute path
        return allocator.dupe(u8, relative_path);
    }

    /// List directory contents (first level only)
    pub fn listDirectory(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) SystemFolderError![]FolderEntry {
        var entries = std.ArrayList(FolderEntry).empty;
        errdefer entries.deinit(allocator);

        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
            return SystemFolderError.InvalidPath;
        };
        defer std.Io.Dir.close(dir, io);

        // First pass: collect non-hidden dir/file children. Names are
        // duped (iterator buffers are reused on next()) so the git batch
        // below can hold them all at once. Dotfiles + non-dir/file kinds
        // (incl. symlinks — same as before) are dropped here, before git.
        const RawChild = struct {
            name: []u8,
            is_dir: bool,
        };
        var children = std.ArrayList(RawChild).empty;
        defer {
            for (children.items) |c| allocator.free(c.name);
            children.deinit(allocator);
        }
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            const name = entry.name;
            if (name.len == 0) break;

            // Skip hidden files/folders (starting with .)
            if (name.len > 0 and name[0] == '.') continue;

            const is_dir = entry.kind == .directory;
            const is_file = entry.kind == .file;

            if (!is_dir and !is_file) continue;
            const dup = allocator.dupe(u8, name) catch continue;
            children.append(allocator, .{ .name = dup, .is_dir = is_dir }) catch {
                allocator.free(dup);
                continue;
            };
        }

        // ONE `git check-ignore` for the whole directory (was: one spawn
        // per entry — ~30ms each on macOS). Null = git unavailable or not
        // a work tree -> treat all as not ignored. Spawn failures (e.g.
        // `git` not on PATH on Windows / Wine) are FALL-THROUGH-OK: the
        // entry is kept because we can't prove it's gitignored. The old
        // `catch continue` silently dropped every entry when git was
        // unavailable — which made listDirectory return `[]` for any
        // Windows / sandboxed environment.
        var batch_names = std.ArrayList([]const u8).empty;
        defer batch_names.deinit(allocator);
        for (children.items) |c| batch_names.append(allocator, c.name) catch break;
        const ignored = batchIgnoredNames(allocator, io, dir_path, batch_names.items);
        defer freeIgnored(allocator, ignored);

        // Second pass: drop gitignored rows, keep the rest.
        for (children.items) |c| {
            if (isIgnored(ignored, c.name)) continue;
            const entry_name = allocator.dupe(u8, c.name) catch continue;
            const full_path = std.fs.path.join(allocator, &.{ dir_path, c.name }) catch {
                allocator.free(entry_name);
                continue;
            };

            entries.append(allocator, FolderEntry{
                .name = entry_name,
                .path = full_path,
                .is_directory = c.is_dir,
                // Symlinks never reach here (kind filter above drops
                // them) — same as the old per-entry code where
                // `is_symlink` was always false for kept rows.
                .is_symlink = false,
            }) catch {
                allocator.free(entry_name);
                allocator.free(full_path);
                continue;
            };
        }

        // Sort: directories first, then files, alphabetically
        std.mem.sort(FolderEntry, entries.items, {}, struct {
            fn less(_: void, a: FolderEntry, b: FolderEntry) bool {
                if (a.is_directory != b.is_directory) {
                    return a.is_directory;
                }
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.less);

        return entries.toOwnedSlice(allocator);
    }

    /// Exact entry names never descended into (nor returned) by
    /// `searchFiles`. Single const array so `listDirectory` and search
    /// share it later. Case-sensitive exact match on the entry name.
    pub const search_skip_names: []const []const u8 = &.{
        "node_modules",
        "zig-out",
        ".zig-cache",
        "zig-cache",
        "target",
        "dist",
    };

    fn isSearchSkipped(name: []const u8) bool {
        // Dotfiles/dot-dirs skipped, mirroring listDirectory.
        if (name.len > 0 and name[0] == '.') return true;
        for (search_skip_names) |skip| {
            if (std.mem.eql(u8, name, skip)) return true;
        }
        return false;
    }

    /// Batch `git check-ignore` for every entry name in ONE directory.
    ///
    /// Why batched: the old code spawned one `git -C <dir> check-ignore
    /// <name>` per ENTRY. On macOS each spawn costs ~30ms (fork+exec +
    /// security policy), so a 300-file directory cost ~9-12s and blew the
    /// 5s functional perf budget (plus the 15s socket timeout on empty-q).
    /// One spawn per DIRECTORY (chunked at 500 names) drops the search
    /// fixture from ~312 spawns to ~5.
    ///
    /// Returns an owned slice of duped ignored basenames (caller frees via
    /// `freeIgnored`), or null when there is nothing ignored OR git is
    /// unavailable / the dir is not in a work tree / any error — the
    /// caller treats null as "none ignored" (same fall-through as the old
    /// per-entry spawn-failure path, so entries are kept, never dropped).
    ///
    /// Parsing note: stdout is split on `\n` (trailing `\r` trimmed for
    /// Windows git). A filename containing a literal newline would not
    /// round-trip — it then falls through to "not ignored" (entry kept),
    /// which is the safe direction.
    fn batchIgnoredNames(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir_path: []const u8,
        names: []const []const u8,
    ) ?[][]const u8 {
        if (names.len == 0) return null;
        var ignored = std.ArrayList([]const u8).empty;
        var offset: usize = 0;
        while (offset < names.len) {
            const end = @min(offset + 500, names.len);
            const chunk = names[offset..end];
            offset = end;
            var argv = std.ArrayList([]const u8).empty;
            defer argv.deinit(allocator);
            // `--` ends option parsing so names starting with `-` are
            // treated as paths (the old per-entry form had no `--` and
            // mis-checked such names as flags — this is strictly more
            // correct, same fall-through direction on error).
            argv.appendSlice(allocator, &.{ "git", "-C", dir_path, "check-ignore", "--" }) catch break;
            argv.appendSlice(allocator, chunk) catch break;
            const result = std.process.run(allocator, io, .{ .argv = argv.items }) catch continue;
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            // exit 0 = >=1 ignored (parse stdout); 1 = none ignored;
            // 128/fatal = not a repo -> none ignored (fall-through).
            if (result.term.exited != 0) continue;
            var it = std.mem.splitScalar(u8, result.stdout, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, "\r");
                if (trimmed.len == 0) continue;
                // git echoes the input basename for each ignored path.
                const dup = allocator.dupe(u8, trimmed) catch continue;
                ignored.append(allocator, dup) catch {
                    allocator.free(dup);
                    continue;
                };
            }
        }
        if (ignored.items.len == 0) {
            ignored.deinit(allocator);
            return null;
        }
        const out = ignored.toOwnedSlice(allocator) catch {
            for (ignored.items) |s| allocator.free(s);
            ignored.deinit(allocator);
            return null;
        };
        return out;
    }

    fn isIgnored(ignored: ?[][]const u8, name: []const u8) bool {
        const list = ignored orelse return false;
        for (list) |ig| {
            if (std.mem.eql(u8, ig, name)) return true;
        }
        return false;
    }

    fn freeIgnored(allocator: std.mem.Allocator, ignored: ?[][]const u8) void {
        const list = ignored orelse return;
        for (list) |s| allocator.free(s);
        allocator.free(list);
    }

    /// Case-insensitive ASCII substring check (mirrors the
    /// lessThanIgnoreCase sort used below).
    pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var ok = true;
            for (needle, 0..) |nc, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// Case-insensitive subsequence check (FileInput `matchesOutOfOrder`
    /// semantics): every needle char appears in haystack in order, gaps
    /// OK — so `tst` still matches `test`, `cmps` matches `components`.
    pub fn matchesSubsequenceIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        var hi: usize = 0;
        for (needle) |nc| {
            const lower_nc = std.ascii.toLower(nc);
            var found = false;
            while (hi < haystack.len) : (hi += 1) {
                if (std.ascii.toLower(haystack[hi]) == lower_nc) {
                    hi += 1;
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    /// Match rank: 0 = case-insensitive substring (best), 1 =
    /// subsequence-only. Null when the name does not match at all.
    /// Empty query matches everything at rank 0 (top-N listing).
    fn matchRank(name: []const u8, query: []const u8) ?u8 {
        if (query.len == 0) return 0;
        if (containsIgnoreCase(name, query)) return 0;
        if (matchesSubsequenceIgnoreCase(name, query)) return 1;
        return null;
    }

    /// Parse the `limit` query param: default 50, clamp 1..200 (hard cap),
    /// garbage → default. Pure helper so the HTTP layer is unit-testable.
    pub fn parseSearchLimit(raw: ?[]const u8) usize {
        const s = raw orelse "";
        const trimmed = std.mem.trim(u8, s, " \t");
        if (trimmed.len == 0) return 50;
        const n = std.fmt.parseInt(usize, trimmed, 10) catch return 50;
        if (n < 1) return 1;
        if (n > 200) return 200;
        return n;
    }

    /// Parse the `max_depth` query param: default 8, clamp 1..16,
    /// garbage → default. Pure helper so the HTTP layer is unit-testable.
    pub fn parseSearchMaxDepth(raw: ?[]const u8) usize {
        const s = raw orelse "";
        const trimmed = std.mem.trim(u8, s, " \t");
        if (trimmed.len == 0) return 8;
        const n = std.fmt.parseInt(usize, trimmed, 10) catch return 8;
        if (n < 1) return 1;
        if (n > 16) return 16;
        return n;
    }

    const SearchHit = struct {
        entry: FolderEntry,
        rank: u8,
    };

    /// Recursive file search under `root_path` (iterative stack, NOT
    /// recursion). Matching is on the entry BASENAME (not the full path).
    ///
    /// - `query`: case-insensitive substring first, subsequence fallback;
    ///   empty query matches everything (top-N listing).
    /// - `limit`: 0 → default 50; hard cap 200.
    /// - `max_depth`: 0 → default 8. Entries deeper than max_depth are
    ///   never visited; dirs AT max_depth are listed but not descended.
    ///   Root children are depth 1.
    /// - Skip-list (`search_skip_names`) + dotfiles are never descended
    ///   into nor returned. `entry.kind` is reused (no extra stat), so
    ///   symlinks are neither followed nor returned — same as
    ///   listDirectory.
    /// - `git check-ignore` semantics are identical to listDirectory
    ///   (batched `-C <parent> check-ignore -- <names...>`, spawn-failure
    ///   falls through to "not ignored").
    /// - Ranking: substring hits before subsequence hits, then
    ///   dirs-first, then lessThanIgnoreCase. Results truncated to limit.
    ///
    /// Caller owns the returned slice + each entry's name/path (free
    /// with the same pattern as listDirectory).
    pub fn searchFiles(
        allocator: std.mem.Allocator,
        io: std.Io,
        root_path: []const u8,
        query: []const u8,
        limit: usize,
        max_depth: usize,
    ) SystemFolderError![]FolderEntry {
        const cap: usize = if (limit == 0) 50 else if (limit > 200) 200 else limit;
        const depth_cap: usize = if (max_depth == 0) 8 else max_depth;

        var matches = std.ArrayList(SearchHit).empty;
        defer matches.deinit(allocator);

        const StackFrame = struct {
            path: []const u8,
            depth: usize,
        };
        var stack = std.ArrayList(StackFrame).empty;
        defer {
            for (stack.items) |frame| allocator.free(frame.path);
            stack.deinit(allocator);
        }

        const root_dup = allocator.dupe(u8, root_path) catch return SystemFolderError.OutOfMemory;
        stack.append(allocator, .{ .path = root_dup, .depth = 0 }) catch return SystemFolderError.OutOfMemory;

        while (stack.items.len > 0) {
            const frame = stack.pop().?;
            defer allocator.free(frame.path);

            var dir = std.Io.Dir.openDirAbsolute(io, frame.path, .{ .iterate = true }) catch continue;
            defer std.Io.Dir.close(dir, io);

            // First pass: collect candidates passing skip-list / kind /
            // depth (duped names — iterator buffers are reused on next()).
            // Depth + kind filter BEFORE git so the batch only sees rows
            // we would actually visit (same order as the old per-entry
            // code: skip -> kind -> depth -> git).
            const child_depth = frame.depth + 1;
            const RawChild = struct {
                name: []u8,
                is_dir: bool,
            };
            var children = std.ArrayList(RawChild).empty;
            defer {
                for (children.items) |c| allocator.free(c.name);
                children.deinit(allocator);
            }
            var iter = dir.iterate();
            while (iter.next(io) catch null) |entry| {
                const name = entry.name;
                if (name.len == 0) break;

                if (isSearchSkipped(name)) continue;

                const is_dir = entry.kind == .directory;
                const is_file = entry.kind == .file;
                if (!is_dir and !is_file) continue;

                if (child_depth > depth_cap) continue;

                const dup = allocator.dupe(u8, name) catch continue;
                children.append(allocator, .{ .name = dup, .is_dir = is_dir }) catch {
                    allocator.free(dup);
                    continue;
                };
            }

            // ONE `git check-ignore` for the whole directory (was: one
            // spawn per entry — ~30ms each on macOS, ~312 spawns for the
            // 300-file fixture). Null = git unavailable / not a work tree
            // -> none ignored (same fall-through as the old per-entry
            // spawn-failure path).
            var batch_names = std.ArrayList([]const u8).empty;
            defer batch_names.deinit(allocator);
            for (children.items) |c| batch_names.append(allocator, c.name) catch break;
            const ignored = batchIgnoredNames(allocator, io, frame.path, batch_names.items);
            defer freeIgnored(allocator, ignored);

            // Second pass: descend + match (identical semantics to the old
            // loop — non-matching dirs are still descended into since
            // their children may match).
            for (children.items) |c| {
                if (isIgnored(ignored, c.name)) continue;

                // Non-matching dirs are still descended into (their
                // children may match); non-matching files are dropped.
                if (c.is_dir and child_depth < depth_cap) {
                    const dir_path = std.fs.path.join(allocator, &.{ frame.path, c.name }) catch continue;
                    stack.append(allocator, .{ .path = dir_path, .depth = child_depth }) catch {
                        allocator.free(dir_path);
                        continue;
                    };
                }

                const rank = matchRank(c.name, query) orelse continue;
                const entry_name = allocator.dupe(u8, c.name) catch continue;
                const full_path = std.fs.path.join(allocator, &.{ frame.path, c.name }) catch {
                    allocator.free(entry_name);
                    continue;
                };
                matches.append(allocator, SearchHit{
                    .entry = FolderEntry{
                        .name = entry_name,
                        .path = full_path,
                        .is_directory = c.is_dir,
                        // Symlinks never reach here (kind filter above
                        // drops them) — same as the old per-entry code
                        // where `is_symlink` was always false for hits.
                        .is_symlink = false,
                    },
                    .rank = rank,
                }) catch {
                    allocator.free(entry_name);
                    allocator.free(full_path);
                    continue;
                };
            }
        }

        // Rank: substring hits first, then dirs-first, then
        // case-insensitive name order.
        std.mem.sort(SearchHit, matches.items, {}, struct {
            fn less(_: void, a: SearchHit, b: SearchHit) bool {
                if (a.rank != b.rank) return a.rank < b.rank;
                if (a.entry.is_directory != b.entry.is_directory) {
                    return a.entry.is_directory;
                }
                return std.ascii.lessThanIgnoreCase(a.entry.name, b.entry.name);
            }
        }.less);

        var out = std.ArrayList(FolderEntry).empty;
        const n = @min(cap, matches.items.len);
        for (matches.items[0..n]) |hit| {
            out.append(allocator, hit.entry) catch continue;
        }
        // Dropped tail keeps no ownership — free its strings; the
        // transferred head is owned by `out`. The `matches` backing
        // array itself is freed by the top-of-function defer.
        for (matches.items[n..]) |hit| {
            allocator.free(hit.entry.name);
            allocator.free(hit.entry.path);
        }

        return out.toOwnedSlice(allocator);
    }

    /// Get parent directory path
    pub fn getParentPath(allocator: std.mem.Allocator, dir_path: []const u8, environment: ?*const std.process.Environ.Map) SystemFolderError!?[]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        // Don't go above home. Compare normalized forms so
        // `C:\Users\ginwa\` (trailing separator) still matches home
        // `C:\Users\ginwa` on Windows.
        // Cross-platform rule (keeps POSIX tests green):
        // - trailing `\` is always stripped (Windows paths can appear in
        //   synthetic env maps on any OS; a POSIX filename ending in `\`
        //   is vanishingly rare);
        // - trailing `/` is stripped on Windows only, because the POSIX
        //   test "dir_path == home with trailing slash still returns
        //   parent" explicitly documents `/home/user/` -> parent `/home`.
        const norm_dir = if (dir_path.len > 1 and dir_path[dir_path.len - 1] == '\\')
            dir_path[0..dir_path.len - 1]
        else if (builtin.os.tag == .windows and dir_path.len > 1 and dir_path[dir_path.len - 1] == '/')
            dir_path[0..dir_path.len - 1]
        else
            dir_path;
        const norm_home = if (home.len > 1 and home[home.len - 1] == '\\')
            home[0..home.len - 1]
        else if (builtin.os.tag == .windows and home.len > 1 and home[home.len - 1] == '/')
            home[0..home.len - 1]
        else if (home.len == 1 and (home[0] == '/' or home[0] == '\\'))
            home[0..0] // root "/" normalizes to "" so "/"+trailing variants compare equal
        else
            home;
        // Also treat a single trailing `\` on a multi-char home (e.g.
        // `C:\Users\ginwa\`) as equal — covered by the first branch above
        // for dir; for home the `len > 1` backslash branch handles it.
        // Edge: home `\` alone (Windows root) normalizes to "" like POSIX.
        const norm_home_adj = if (home.len == 1 and home[0] == '\\') home[0..0] else norm_home;
        if (std.mem.eql(u8, norm_dir, norm_home_adj)) {
            return null;
        }
        // POSIX dirname handles `/`-separated paths (including a trailing
        // `/`, which it strips before finding the parent). It knows
        // nothing about `\`, so Windows paths on Linux/macOS fall through
        // to the manual split below.
        if (std.fs.path.dirname(dir_path)) |p| {
            return try allocator.dupe(u8, p);
        }
        // Manual Windows-separator parent: strip one trailing separator,
        // then cut at the last `/` or `\`. Drive roots (`C:\`, `C:/`, `/`,
        // `\`) have no parent -> null.
        var stripped = dir_path;
        if (stripped.len > 1 and (stripped[stripped.len - 1] == '/' or stripped[stripped.len - 1] == '\\')) {
            stripped = stripped[0..stripped.len - 1];
        }
        const last_sep: ?usize = blk: {
            const b = std.mem.lastIndexOfScalar(u8, stripped, '\\');
            const f = std.mem.lastIndexOfScalar(u8, stripped, '/');
            if (b != null and f != null) break :blk @max(b.?, f.?);
            break :blk b orelse f;
        };
        const idx = last_sep orelse return null;
        if (idx == 0) return null; // `/foo` -> parent is `/`, but bare `/` root -> null; `idx==0` means root-level
        if (idx == 2 and stripped.len >= 3 and std.ascii.isAlphabetic(stripped[0]) and stripped[1] == ':' and (stripped[2] == '/' or stripped[2] == '\\')) {
            // `C:\foo` -> parent is the drive root `C:\` (keep separator style of input)
            return try allocator.dupe(u8, stripped[0..3]);
        }
        // `C:` alone or empty prefix -> null
        if (idx == 0) return null;
        return try allocator.dupe(u8, stripped[0..idx]);
    }
};
