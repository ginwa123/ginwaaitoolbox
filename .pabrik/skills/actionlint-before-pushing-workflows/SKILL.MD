---
name: actionlint-before-pushing-workflows
description: ""
---
---
name: actionlint-before-pushing-workflows
description: Validate .github/workflows/*.yml with actionlint BEFORE git push — js-yaml passing means nothing; GitHub rejects invalid workflow syntax at parse time with a 0-second run, zero jobs, and no logs
tags: [workflow, fix, ci]
---

## When to Use
Any time you create or edit a file under `.github/workflows/`. Run actionlint before `git push`. Never trust "the YAML parses" (js-yaml / python-yaml) as validation — GitHub's parser is stricter.

## Context
- GitHub rejects invalid workflow syntax at parse time: the run appears for 0 seconds, has zero jobs, and produces NO logs to debug from. `gh run view --log-failed` returns nothing. This costs a full push cycle to discover.
- actionlint validates: expression syntax (${{ }}), `runs-on` types, `needs` graph, matrix shapes, `with:` keys against action metadata, shell quoting.
- Install once: `go install github.com/rhysd/actionlint/cmd/actionlint@latest` → binary at `~/go/bin/actionlint` (v1.7.12 as of 2026-08-24).

## Procedure
1. After editing any `.github/workflows/*.yml`, run: `~/go/bin/actionlint .github/workflows/<file>.yml`
2. Fix every reported error (warnings about untrusted inputs can be ignored for this repo).
3. Only then `git push`.

## Pitfalls
- `gh run view <id> --log-failed` on a parse-time-rejected run prints "no logs available" — there is nothing to debug after the fact. Prevention is the only cure.
- actionlint is NOT installed by default on this machine; the `go install` above takes ~30 s.

## Verification
- `actionlint` exits 0 with no output before pushing.

