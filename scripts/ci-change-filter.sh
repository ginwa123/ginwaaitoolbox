#!/usr/bin/env bash
# Decide whether a change set needs the HEAVY half of the pipeline.
#
# WHY THIS EXISTS
# ---------------
# Every heavy job in .github/workflows/ci.yml (3 backend cells, 9
# functional shards, 2 android jobs) takes 20-50 minutes and none of
# them can be affected by a prose edit. This script answers one question
# from the changed-file list, and the `changes` job turns the answer into
# a boolean the heavy jobs gate on.
#
# It does NOT use `on: paths-ignore`, which is the zero-code way to do
# this, because that makes GitHub skip the ENTIRE workflow: there would
# be no run, so no `ci-ok` check, so a docs-only PR sits with a required
# check that never reports and cannot merge. Gating inside the workflow
# keeps one green run that says "nothing to build here".
#
# FAIL-OPEN, ALWAYS
# -----------------
# Every ambiguous path returns `heavy=true`: an unreadable diff, a base
# ref that is not in the shallow clone, a new branch, a file that matches
# no pattern. The cost of a wrong `true` is a slow green run; the cost of
# a wrong `false` is that nobody finds out the build is broken until it
# ships. The asymmetry is the whole design.
#
# USAGE
#   ci-change-filter.sh <base-sha> [head-sha]   -> prints heavy=true|false
#   ci-change-filter.sh --selftest              -> runs the classifier
#                                                  against fixtures
set -euo pipefail

# ── Classification ────────────────────────────────────────────────────────
#
# FORCE HEAVY: paths that change WHAT IS BUILT, or that are this pipeline's
# own source. A CI-only diff is the case people forget — skipping the build
# because the diff is "only .github" means a typo'd `runs-on:` ships
# unbuilt, and skipping the build because build.zig changed means the
# compile is never checked at all.
FORCE_HEAVY_PATTERNS=(
  '.github/workflows/**'
  '.github/actions/**'
  '.husky/**'
  'build.zig'
  'build.zig.zon'
  'scripts/ci-*'
  '**/requirements.txt'
  '**/*-lock.yaml'
  '**/package-lock.json'
  '**/pnpm-lock.yaml'
  '**/package.json'
  '**/gradle-wrapper.properties'
  '**/AndroidManifest.xml'
)

# DOC ONLY: paths that cannot change a build, a test verdict, or a binary.
# Deliberately narrow. `*.txt` is NOT here — tests/functional/
# requirements.txt is a txt file that decides which pytest plugins exist.
DOC_ONLY_PATTERNS=(
  '*.md'
  'docs/**'
  'LICENSE'
  'LICENSE.*'
  '.pabrik/**'
  '.github/ISSUE_TEMPLATE/**'
  '*.svg'
  '*.png'
  '*.jpg'
  '*.jpeg'
  '.gitattributes'
  '.gitignore'
)

# A hand-rolled matcher rather than `git ls-files` pathspecs, because a
# pathspec that matches nothing is silently fine and a mis-anchored one
# (`*.md` rooted instead of anywhere) is a filter that quietly stops
# matching. Four shapes, tested in this order:
#
#   `**/name`   name at any depth
#   `dir/**`    anything under dir, rooted (NOT `a/b/**` matching `x/a/b`)
#   `*glob*`    glob against the whole path OR the basename, so `*.md`
#               means "markdown anywhere" rather than "markdown at the root"
#   `name`      exact name at the root or at any depth
matches() {
  # $1 = pattern, $2 = path.
  #
  # Shell globs, not git pathspecs: `*` spans `/` inside a case pattern,
  # so `docs/**` covers `docs/plans/2026-09-29-wireframe.html` with no
  # recursion written by hand, and the whole matcher is four lines that
  # can be read in one go. A pathspec would be shorter still, but a
  # pathspec that matches nothing is silently fine and a mis-anchored one
  # is a filter that quietly stops filtering.
  local pattern="$1" path="$2"
  # `**/name` means "at any depth"; for matching purposes that is exactly
  # "also try the basename", which the second case below does anyway.
  case "$pattern" in
    '**/'*) pattern="${pattern#\*\*/}" ;;
  esac
  case "$path" in
    $pattern) return 0 ;;
  esac
  case "${path##*/}" in
    $pattern) return 0 ;;
  esac
  return 1
}

any_match() {
  # $1 = path, rest = patterns
  local path="$1"; shift
  local pattern
  for pattern in "$@"; do
    if matches "$pattern" "$path"; then
      return 0
    fi
  done
  return 1
}

classify_path() {
  # Prints heavy=true for anything that is not provably prose.
  local path="$1"
  if any_match "$path" "${FORCE_HEAVY_PATTERNS[@]}"; then
    echo "heavy=true  ($path — changes the build or the pipeline itself)"
    return
  fi
  if any_match "$path" "${DOC_ONLY_PATTERNS[@]}"; then
    echo "doc"
    return
  fi
  echo "heavy=true  ($path — not a recognised documentation path)"
}

classify_list() {
  # Reads paths on stdin; prints `heavy=true|false` plus a per-file trace
  # on stderr so the `changes` job log says WHY it decided what it did.
  local path decision="false" trace
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    trace="$(classify_path "$path")"
    printf '  %s\n' "$trace" >&2
    case "$trace" in
      heavy=*) decision="true" ;;
    esac
  done
  echo "$decision"
}

# ── Modes ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  fail=0
  check() {
    local path="$1" want="$2" got
    got="$(classify_path "$path")"
    case "$got" in
      "$want"*) ;;
      *) echo "FAIL: $path -> '$got', wanted '$want'"; fail=1 ;;
    esac
  }
  check 'README.md'                                  'doc'
  check 'docs/ci.md'                                  'doc'
  check 'docs/plans/2026-09-27-wireframe.html'        'doc'
  check 'AGENTS.md'                                   'doc'
  check 'LICENSE'                                     'doc'
  check '.pabrik/skills/foo/SKILL.MD'                  'doc'
  check 'src/apps/desktop/src/foo.vue'                'heavy'
  check 'build.zig'                                   'heavy'
  check '.github/workflows/ci.yml'                    'heavy'
  check 'scripts/ci-release-body.md'                  'heavy'
  check 'tests/functional/requirements.txt'           'heavy'
  check 'src/apps/desktop/pnpm-lock.yaml'             'heavy'
  check 'docs/plans/plan.md'                           'doc'
  check 'tests/functional/README.md'                  'doc'
  if [ "$fail" -ne 0 ]; then
    echo 'ci-change-filter: SELFTEST FAILED'
    exit 1
  fi
  echo 'ci-change-filter: selftest ok'
  exit 0
fi

base="${1:-}"
head="${2:-HEAD}"

# No base to compare against: a brand new branch, a manual dispatch, or a
# caller that forgot to pass one. Nothing to prove, so build everything.
if [ -z "$base" ] || [ "$base" = "0000000000000000000000000000000000000000" ]; then
  echo 'no usable base ref — building everything' >&2
  echo 'heavy=true'
  exit 0
fi

if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  echo "base $base is not in this clone (shallow fetch?) — building everything" >&2
  echo 'heavy=true'
  exit 0
fi

# `--no-renames` is load-bearing, and the reason is the script's own
# fail-open rule. `diff.renames` defaults to true since Git 2.9, and with
# `--name-only` a rename prints ONLY the destination path -- so
# `git mv src/modules/foo/thing.zig docs/thing.md` yields one line,
# `docs/thing.md`, which classifies as documentation and skips the entire
# heavy half of the pipeline on a commit that deleted a Zig source file.
# With renames off, the same commit prints BOTH paths and the source one
# forces `heavy=true`.
changed="$(git diff --no-renames --name-only "$base" "$head" 2>/dev/null || true)"
if [ -z "$changed" ]; then
  # Either no changes, or `git diff` failed and swallowed the error. Both
  # are treated the same way on purpose: an unreadable answer is not an
  # answer.
  echo 'no changed files readable — building everything' >&2
  echo 'heavy=true'
  exit 0
fi

echo "changed files between $base and $head:" >&2
decision="$(printf '%s\n' "$changed" | classify_list)"
if [ "$decision" = "true" ]; then
  echo 'decision: run the heavy jobs' >&2
else
  echo 'decision: documentation only — skipping the heavy jobs' >&2
fi
echo "heavy=$decision"
