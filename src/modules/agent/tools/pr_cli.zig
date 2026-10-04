const std = @import("std");
const pr_provider = @import("pr_provider.zig");

const PrProvider = pr_provider.PrProvider;

/// Fields requested from `gh pr view --json`. Kept here (not next to
/// the caller) so the argv builder and the parser it feeds cannot drift,
/// and so the GitLab builder below has an obvious sibling to read.
pub const GH_JSON_FIELDS = "number,title,url,state,mergeable,mergeStateStatus,headRefName,baseRefName,createdAt,updatedAt,mergedAt,closedAt,author,additions,deletions,changedFiles";

/// The command-line tool that owns a forge, plus the words its users
/// expect to read. Every user-facing string and every argv in the git
/// module is built from this one table, so `gh`/`glab` and PR/MR can
/// never drift apart between call sites — the failure mode where a
/// GitLab user is told to "check gh auth" for a `glab` failure.
pub const Cli = struct {
    /// Program to spawn.
    program: []const u8,
    /// Subcommand noun (`gh pr`, `glab mr`).
    noun: []const u8,
    /// Sentence-case name for prose ("pull request", "merge request").
    label: []const u8,
    /// Uppercase short form for headings ("PR", "MR").
    short: []const u8,
    /// Proper name of the forge, for error messages.
    forge: []const u8,
};

pub const GH_CLI: Cli = .{
    .program = "gh",
    .noun = "pr",
    .label = "pull request",
    .short = "PR",
    .forge = "GitHub",
};

pub const GLAB_CLI: Cli = .{
    .program = "glab",
    .noun = "mr",
    .label = "merge request",
    .short = "MR",
    .forge = "GitLab",
};

/// The CLI that owns `provider`, or null when the provider has none.
/// `generic` deliberately returns null: a forge we cannot identify has
/// no CLI to ask, and its diffs come from local git refs.
pub fn cliFor(provider: PrProvider) ?Cli {
    return switch (provider) {
        .github => GH_CLI,
        .gitlab => GLAB_CLI,
        .generic => null,
    };
}

/// Whether `provider` is served by a forge CLI. The one-liner callers
/// use when they need a "not supported here" branch without pulling the
/// whole `Cli` apart.
pub fn hasCli(provider: PrProvider) bool {
    return cliFor(provider) != null;
}

/// Upper bound on `viewArgv` output.
pub const view_argv_max = 6;

/// Build the read-only "show me this PR/MR" argv:
/// `<prog> <pr|mr> view [<ref>] <provider flags>`.
///
/// `prog` is an explicit parameter, NOT `cli.program`, because it is
/// the seam the test suite injects: a fixture script path has to be
/// spawnable under the GitHub/GitLab *vocabulary* without being the
/// real binary. Production passes `cliFor(provider).?.program`.
///
/// `ref` is "" for "the one for the current branch" (both CLIs resolve
/// that from the repo), otherwise a number, IID, URL or branch name
/// passed straight through. The two CLIs disagree on the JSON flag —
/// `gh` wants `--json <field list>`, `glab` wants `--output json` and
/// returns the whole object — so the flag pair is per-provider.
pub fn viewArgv(storage: [][]const u8, provider: PrProvider, prog: []const u8, ref: []const u8) ?[]const []const u8 {
    const c = cliFor(provider) orelse return null;
    if (storage.len < view_argv_max) return null;

    var n: usize = 0;
    storage[n] = prog;
    n += 1;
    storage[n] = c.noun;
    n += 1;
    storage[n] = "view";
    n += 1;
    if (ref.len > 0) {
        storage[n] = ref;
        n += 1;
    }
    switch (provider) {
        .github => {
            storage[n] = "--json";
            n += 1;
            storage[n] = GH_JSON_FIELDS;
            n += 1;
        },
        .gitlab => {
            storage[n] = "--output";
            n += 1;
            storage[n] = "json";
            n += 1;
        },
        // `cliFor` already returned null for this.
        .generic => unreachable,
    }
    return storage[0..n];
}

/// Upper bound on `createArgv` output.
pub const create_argv_max = 12;

/// Build the "open a new PR/MR" argv:
/// `<prog> <pr|mr> create --base/--target-branch … --title …`.
///
/// `prog` is explicit for the same test-injection reason as `viewArgv`.
/// `source_branch` is only consumed by the GitLab arm. `gh pr create`
/// infers the head from the worktree's checked-out branch and adding
/// `--head` there would change behaviour for every existing GitHub
/// caller, so it stays exactly as it was. `glab` has no such
/// inference — and, critically, without `--yes` it drops into an
/// interactive confirm prompt, which in a non-tty child process blocks
/// until the 60s timeout kills it. Both the source branch and `--yes`
/// are mandatory on the GitLab arm for that reason.
pub fn createArgv(
    storage: [][]const u8,
    provider: PrProvider,
    prog: []const u8,
    base: []const u8,
    source_branch: []const u8,
    title: []const u8,
    body: []const u8,
) ?[]const []const u8 {
    const c = cliFor(provider) orelse return null;
    if (storage.len < create_argv_max) return null;

    var n: usize = 0;
    storage[n] = prog;
    n += 1;
    storage[n] = c.noun;
    n += 1;
    storage[n] = "create";
    n += 1;
    switch (provider) {
        .github => {
            storage[n] = "--base";
            n += 1;
            storage[n] = base;
            n += 1;
            storage[n] = "--title";
            n += 1;
            storage[n] = title;
            n += 1;
            storage[n] = "--body";
            n += 1;
            storage[n] = body;
            n += 1;
        },
        .gitlab => {
            storage[n] = "--source-branch";
            n += 1;
            storage[n] = source_branch;
            n += 1;
            storage[n] = "--target-branch";
            n += 1;
            storage[n] = base;
            n += 1;
            storage[n] = "--title";
            n += 1;
            storage[n] = title;
            n += 1;
            storage[n] = "--description";
            n += 1;
            storage[n] = body;
            n += 1;
            storage[n] = "--yes";
            n += 1;
        },
        .generic => unreachable,
    }
    return storage[0..n];
}

/// Fields requested from `gh pr checks --json`. `bucket` earns its place:
/// `state` is free-form (`SUCCESS`, `FAILURE`, `NEUTRAL`), `bucket` is gh's own
/// rollup into pass/fail/pending/skipping/cancel, which a UI can switch on.
pub const GH_CHECKS_JSON_FIELDS = "bucket,name,state,link,workflow,startedAt,completedAt";

/// Upper bound on `checksArgv` output.
pub const checks_argv_max = 6;

/// `<gh> pr checks [<ref>] --json <field list>`.
///
/// Null for every provider but GitHub: glab has no `mr checks` (its CI surface
/// needs a pipeline id we do not have). The caller must turn that into "not
/// supported", not into an empty list — which reads as "everything passed".
pub fn checksArgv(storage: [][]const u8, provider: PrProvider, prog: []const u8, ref: []const u8) ?[]const []const u8 {
    switch (provider) {
        .github => {},
        .gitlab, .generic => return null,
    }
    if (storage.len < checks_argv_max) return null;

    var n: usize = 0;
    storage[n] = prog;
    n += 1;
    storage[n] = "pr";
    n += 1;
    storage[n] = "checks";
    n += 1;
    if (ref.len > 0) {
        storage[n] = ref;
        n += 1;
    }
    storage[n] = "--json";
    n += 1;
    storage[n] = GH_CHECKS_JSON_FIELDS;
    n += 1;
    return storage[0..n];
}

/// Upper bound on `runJobsArgv` output (prog, run, view, id, --json, jobs).
pub const run_jobs_argv_max = 6;

/// `<gh> run view <run_id> --json jobs` — the second hop behind the Checks tab.
/// `gh pr checks` reports jobs; only a run's step list answers "which task
/// failed". `jobs` only: the run's own fields are already on the check rows.
pub fn runJobsArgv(storage: [][]const u8, prog: []const u8, run_id: []const u8) ?[]const []const u8 {
    if (storage.len < run_jobs_argv_max) return null;
    if (run_id.len == 0) return null;

    var n: usize = 0;
    storage[n] = prog;
    n += 1;
    storage[n] = "run";
    n += 1;
    storage[n] = "view";
    n += 1;
    storage[n] = run_id;
    n += 1;
    storage[n] = "--json";
    n += 1;
    storage[n] = "jobs";
    n += 1;
    return storage[0..n];
}

/// `<run_id>` out of `…/actions/runs/<run_id>/job/<job_id>`. Borrows from
/// `link`. Null for a non-Actions check (CircleCI, a bot-posted status): there
/// is no run to drill into, which is "no steps", not "the lookup failed".
pub fn runIdFromJobLink(link: []const u8) ?[]const u8 {
    return digitsAfter(link, "/actions/runs/");
}

/// `<job_id>` at the tail of an Actions job link. How a check row finds its job
/// in `run view --json jobs` (whose jobs carry a `databaseId`).
pub fn jobIdFromJobLink(link: []const u8) ?[]const u8 {
    return digitsAfter(link, "/job/");
}

/// The digits right after `marker`, stopping at the first `/`, `?` or `#`.
/// Null when absent, empty, or non-numeric — a malformed link must not smuggle
/// a fragment through as an id.
fn digitsAfter(link: []const u8, marker: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, link, marker) orelse return null;
    const rest = link[at + marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const digits = rest[0..end];
    if (digits.len == 0) return null;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return digits;
}

/// Pick the URL out of a forge CLI's stdout after a successful create.
///
/// The naive read — "stdout is the URL" — is what `gh pr create` looks
/// like when it works, and it is wrong for `glab mr create`, which
/// prefixes a `Creating merge request for <branch> on <host>…` banner
/// before the link. Taking the whole blob would store that banner as
/// `pr_url` and every later `set_pull_request` would reject it as an
/// unparseable URL.
///
/// So: scan the lines bottom-up for the first one that parses as an
/// http(s) URL, and only fall back to the last non-empty line when
/// none does. Returns a slice borrowing from `stdout`.
pub fn extractCreatedUrl(stdout: []const u8) []const u8 {
    var last_non_empty: []const u8 = "";
    var it = std.mem.splitBackwardsAny(u8, stdout, "\n");
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (last_non_empty.len == 0) last_non_empty = line;
        if (isHttpUrl(line)) return line;
    }
    return last_non_empty;
}

/// Whether `s` is a bare `http(s)://…` URL with a non-empty host.
/// Deliberately strict: a progress line like "✓ Created merge request
/// for branch-x!" is not a URL, and neither is an ANSI-decorated one.
pub fn isHttpUrl(s: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, s, "://") orelse return false;
    if (scheme_end == 0) return false;
    const scheme = s[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;
    const after = s[scheme_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    return slash > 0;
}

// ─── Tests ───────────────────────────────────────────────────────────────

fn expectArgv(got: ?[]const []const u8, expected: []const []const u8) !void {
    const argv = got orelse return error.NullArgv;
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, have| try std.testing.expectEqualStrings(want, have);
}

test "cliFor maps providers onto their CLI, and generic onto none" {
    try std.testing.expectEqual(GH_CLI.program, cliFor(.github).?.program);
    try std.testing.expectEqualStrings("pr", cliFor(.github).?.noun);
    try std.testing.expectEqual(GLAB_CLI.program, cliFor(.gitlab).?.program);
    try std.testing.expectEqualStrings("mr", cliFor(.gitlab).?.noun);
    try std.testing.expectEqualStrings("merge request", cliFor(.gitlab).?.label);
    try std.testing.expectEqualStrings("MR", cliFor(.gitlab).?.short);
    try std.testing.expectEqualStrings("GitLab", cliFor(.gitlab).?.forge);
    try std.testing.expect(cliFor(.generic) == null);
    try std.testing.expect(!hasCli(.generic));
    try std.testing.expect(hasCli(.github) and hasCli(.gitlab));
}

test "viewArgv builds `gh pr view` with --json and no ref" {
    var storage: [view_argv_max][]const u8 = undefined;
    try expectArgv(viewArgv(&storage, .github, "gh", ""), &.{ "gh", "pr", "view", "--json", GH_JSON_FIELDS });
}

test "viewArgv builds `glab mr view` with --output json and no ref" {
    var storage: [view_argv_max][]const u8 = undefined;
    try expectArgv(viewArgv(&storage, .gitlab, "glab", ""), &.{ "glab", "mr", "view", "--output", "json" });
}

test "viewArgv passes a number / IID / URL / branch through verbatim" {
    var storage: [view_argv_max][]const u8 = undefined;
    try expectArgv(viewArgv(&storage, .github, "gh", "42"), &.{ "gh", "pr", "view", "42", "--json", GH_JSON_FIELDS });
    try expectArgv(viewArgv(&storage, .gitlab, "glab", "7"), &.{ "glab", "mr", "view", "7", "--output", "json" });
    try expectArgv(viewArgv(&storage, .gitlab, "glab", "https://gitlab.com/g/s/r/-/merge_requests/7"), &.{ "glab", "mr", "view", "https://gitlab.com/g/s/r/-/merge_requests/7", "--output", "json" });
    try expectArgv(viewArgv(&storage, .github, "gh", "feature-x"), &.{ "gh", "pr", "view", "feature-x", "--json", GH_JSON_FIELDS });
}

test "viewArgv returns null for a provider with no CLI" {
    var storage: [view_argv_max][]const u8 = undefined;
    try std.testing.expect(viewArgv(&storage, .generic, "gh", "") == null);
}

test "createArgv keeps the historical `gh pr create` shape" {
    var storage: [create_argv_max][]const u8 = undefined;
    try expectArgv(createArgv(&storage, .github, "gh", "main", "worktree/x", "T", "B"), &.{ "gh", "pr", "create", "--base", "main", "--title", "T", "--body", "B" });
}

test "createArgv for gitlab passes --source-branch and --yes" {
    // --yes is load-bearing: without it glab blocks on an interactive
    // confirm in a non-tty child and the create burns its 60s budget.
    var storage: [create_argv_max][]const u8 = undefined;
    try expectArgv(createArgv(&storage, .gitlab, "glab", "main", "worktree/x", "T", "B"), &.{ "glab", "mr", "create", "--source-branch", "worktree/x", "--target-branch", "main", "--title", "T", "--description", "B", "--yes" });
}

test "createArgv returns null for a provider with no CLI" {
    var storage: [create_argv_max][]const u8 = undefined;
    try std.testing.expect(createArgv(&storage, .generic, "gh", "main", "b", "T", "B") == null);
}

test "extractCreatedUrl takes the URL past a glab preamble" {
    // The exact shape `glab mr create` prints: banner, blank line, link.
    const stdout =
        \\Creating merge request for worktree/x on gitlab.com
        \\
        \\https://gitlab.com/group/sub/repo/-/merge_requests/7
        \\
    ;
    try std.testing.expectEqualStrings("https://gitlab.com/group/sub/repo/-/merge_requests/7", extractCreatedUrl(stdout));
}

test "extractCreatedUrl still works for a bare gh-style URL" {
    try std.testing.expectEqualStrings("https://github.com/acme/app/pull/42", extractCreatedUrl("https://github.com/acme/app/pull/42\n"));
    try std.testing.expectEqualStrings("https://github.com/acme/app/pull/42", extractCreatedUrl("https://github.com/acme/app/pull/42"));
}

test "extractCreatedUrl falls back to the last non-empty line" {
    // No URL anywhere: better to hand the caller whatever the CLI last
    // said than to store "" and lose the whole answer.
    try std.testing.expectEqualStrings("done", extractCreatedUrl("creating...\ndone\n\n"));
    try std.testing.expectEqualStrings("", extractCreatedUrl("\n\n  \n"));
}

test "isHttpUrl accepts http(s) with a host and rejects prose" {
    try std.testing.expect(isHttpUrl("https://gitlab.com/g/s/r/-/merge_requests/7"));
    try std.testing.expect(isHttpUrl("http://git.corp.example.com/a/b/pull/9"));
    try std.testing.expect(!isHttpUrl("Creating merge request for worktree/x"));
    try std.testing.expect(!isHttpUrl("://gitlab.com/a"));
    try std.testing.expect(!isHttpUrl("https:///a/b"));
    try std.testing.expect(!isHttpUrl("gitlab.com/a/b"));
}

test "checksArgv builds `gh pr checks` with --json and no ref" {
    var storage: [checks_argv_max][]const u8 = undefined;
    try expectArgv(checksArgv(&storage, .github, "gh", ""), &.{ "gh", "pr", "checks", "--json", GH_CHECKS_JSON_FIELDS });
}

test "checksArgv passes a number / URL / branch through verbatim" {
    var storage: [checks_argv_max][]const u8 = undefined;
    try expectArgv(checksArgv(&storage, .github, "gh", "42"), &.{ "gh", "pr", "checks", "42", "--json", GH_CHECKS_JSON_FIELDS });
    try expectArgv(checksArgv(&storage, .github, "gh", "https://github.com/acme/app/pull/42"), &.{ "gh", "pr", "checks", "https://github.com/acme/app/pull/42", "--json", GH_CHECKS_JSON_FIELDS });
}

test "checksArgv refuses every forge but GitHub" {
    // glab has no `mr checks`; returning null is what lets the handler
    // answer 422 ("not supported") instead of 200 with zero checks,
    // which a UI reads as "everything passed".
    var storage: [checks_argv_max][]const u8 = undefined;
    try std.testing.expect(checksArgv(&storage, .gitlab, "glab", "7") == null);
    try std.testing.expect(checksArgv(&storage, .generic, "gh", "") == null);
}

test "runJobsArgv builds `gh run view <id> --json jobs`" {
    var storage: [run_jobs_argv_max][]const u8 = undefined;
    try expectArgv(runJobsArgv(&storage, "gh", "37146940187"), &.{ "gh", "run", "view", "37146940187", "--json", "jobs" });
}

test "runJobsArgv rejects an empty run id and an undersized buffer" {
    var storage: [run_jobs_argv_max][]const u8 = undefined;
    try std.testing.expect(runJobsArgv(&storage, "gh", "") == null);
    var tiny: [run_jobs_argv_max - 1][]const u8 = undefined;
    try std.testing.expect(runJobsArgv(&tiny, "gh", "1") == null);
}

test "runIdFromJobLink pulls the run id out of an Actions job link" {
    try std.testing.expectEqualStrings("37146940187", runIdFromJobLink("https://github.com/acme/app/actions/runs/37146940187/job/111272848907").?);
    // Trailing query/fragment and a missing /job segment both terminate
    // the id the same way.
    try std.testing.expectEqualStrings("12", runIdFromJobLink("https://github.com/acme/app/actions/runs/12?checkSuite=1").?);
    try std.testing.expectEqualStrings("7", runIdFromJobLink("https://github.com/acme/app/actions/runs/7").?);
}

test "runIdFromJobLink returns null for a link that is not an Actions job" {
    // An external check has no run to drill into — the caller must read
    // this as "no steps", never as "the lookup failed".
    try std.testing.expect(runIdFromJobLink("https://circleci.com/gh/acme/app/1") == null);
    try std.testing.expect(runIdFromJobLink("https://api.github.com/repos/acme/app") == null);
    try std.testing.expect(runIdFromJobLink("") == null);
    // Present marker, non-numeric segment: a malformed link must not
    // smuggle "abc" through as a run id.
    try std.testing.expect(runIdFromJobLink("https://github.com/a/b/actions/runs/abc/job/1") == null);
    try std.testing.expect(runIdFromJobLink("https://github.com/a/b/actions/runs//job/1") == null);
}

test "jobIdFromJobLink pulls the job id, and only from an Actions link" {
    try std.testing.expectEqualStrings("111272848907", jobIdFromJobLink("https://github.com/acme/app/actions/runs/37146940187/job/111272848907").?);
    try std.testing.expectEqualStrings("9", jobIdFromJobLink("https://github.com/a/b/actions/runs/1/job/9?checkSuite=2").?);
    // A link with no job segment has no job to match a run against.
    try std.testing.expect(jobIdFromJobLink("https://github.com/acme/app/actions/runs/37146940187") == null);
    try std.testing.expect(jobIdFromJobLink("https://circleci.com/gh/acme/app/1") == null);
    try std.testing.expect(jobIdFromJobLink("") == null);
}
