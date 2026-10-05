---
name: porting-pytest-functional-to-zig
description: The procedure for porting a tests/functional/*_test.py suite to Zig in this repo — which harness seams exist, which Python idioms have no direct translation, and how to verify a port actually RAN rather than merely compiled.
---

# Porting a `tests/functional/*_test.py` suite to Zig

## When to Use

Any task of the form "port these N python functional tests to Zig" in
`tests/functional/`. Read `tests/functional/harness.zig` IN FULL first
(~2000 lines) plus three reference ports: `auth_test.zig` (plain CRUD),
`background_process_sse_test.zig` (streaming + threads), and
`cross_project_cwd_prompt_test.zig` (polling a write-behind endpoint).

## The harness seams that exist

- `Harness.boot(io, gpa, .{ .stub_llm_profile = true, .extra_args = &.{"--auth"} })`
- `h.http(io, METHOD, path, .{ .json_body, .params, .expect, .extra_headers, .assert_status })`
- `.assert_status = false` when the STATUS is the assertion — never copy
  the harness's HTTP client into a suite.
- `r.json()` → an OWNING `harness.Json`; accessors `doc.str/int/boolean/
  array/object/number/get` all return OPTIONALS. `boolean`, not `bool` —
  `bool` is a primitive name Zig will not let you shadow.
- `harness.harnessPath(gpa, h.temp_dir, parts)` for any path you PUT INTO a
  JSON body. `std.fs.path.isAbsolute("/tmp/x")` is FALSE on windows-2022,
  so a literal that is correct on Linux 400s elsewhere.
- `harness.makeScratchDir(gpa)` for suite fixtures — NOT `std.testing.tmpDir`
  (lands inside the git worktree) and NOT a hand-rolled `pabrik-func-`
  mkdtemp (the orphan reaper deletes it mid-test).
- `harness.runPabrikCommand(io, gpa, home, argv, timeout_ms)` — `argv` starts
  at the SUBCOMMAND; the harness prepends the binary.
- `.params` percent-encodes for you; never pre-encode.

## Python idioms with no direct translation

- A helper returning `r.json()` CANNOT return a `Json` — every accessor
  borrows from the owning parse. Return OWNED bytes, or the owning
  `Response` / `Parsed`, and let each call site `defer doc.deinit()`.
- `queue.Queue` → an `Io.Mutex`-guarded `ArrayList` that POPS, because
  `_drain_until` discards non-matching events. A "does the list contain a
  match?" scan passes vacuously in any test that drains first.
- `{p["id"]: p["position"] for p in ...}` → a helper returning the single
  integer, or a `StringHashMap` built inside the test.
- `python dict == dict` has no `std.json.Value` analogue; compare the named
  fields plus the length.
- `socket.settimeout` → no such thing on a Zig socket. Use a watchdog
  thread that `shutdown(.recv)`s. See the callee-frame-address skill for
  why that watchdog must be heap-allocated.
- `webbrowser`/`platform` gating in the Python had no Zig equivalent yet;
  a suite that is POSIX-only by construction (`terminal_ws`) is acceptable
  and should say so in its header.

## Fixture paths: `std.fs.path.delimiter` is NOT a separator

`std.fs.path.delimiter` is the PATH-LIST separator (`:` on POSIX, `;` on
Windows). `std.fs.path.sep` is the path separator. They are adjacent in
`std.fs.path` and read the same at a call site, so the wrong one is easy
to type and nothing catches it at compile time.

```zig
// BROKEN — writes /tmp/pabrik-fix-abc:glab.payload, not .../bin/glab.payload
std.fmt.allocPrint(gpa, "{s}{c}{s}.payload", .{ bindir, std.fs.path.delimiter, name })
```

**Symptom**: the fixture file lands somewhere no shell ever looks, the
fake CLI prints nothing, and every request fails a layer away with
`invalid JSON from glab mr view (0 bytes stdout)` — i.e. the suite looks
like a backend regression. Prefer `std.fs.path.join(gpa, &.{bindir, name})`
(or `harness.harnessPath`) over hand-rolled `allocPrint` joins; it cannot be
got wrong. `delimiter` is only correct when building a PATH STRING, which
is what `PathShadow` in `git_pr_status_test.zig` does with it.

## A stub SERVER struct must not be returned by value

A fixture that binds a socket and spawns a thread (`Io.net` + a canned
response, for a fake upstream) hits the callee-frame trap — see the
`zig-016-callee-frame-address-traps` skill. The repo's existing shape for
this is an OUT-PARAMETER rather than the `gpa.create` that skill
recommends:

```zig
var stub: Stub = undefined;
try stub.start(200, PAYLOAD);
defer stub.deinit();
```

That is `anthropic_chat_headers_test.zig`'s `startStub` signature. Use it
rather than `fn start(...) !Stub`, which hands the thread `&stub` on the
callee's stack and segfaults inside `Io.net.readVec` on the first accept.

## Verification — COMPILED is not RAN

A suite not listed in `root.zig`'s `suites` does not run, silently. Do NOT
edit `root.zig` if other agents are working concurrently. Instead:

1. `cp root.zig zz_<tag>_root.zig` and add the new `const`s + `suites`
   entries → `zig test --test-no-exec zz_<tag>_root.zig` proves it
   COMPILES.
2. Write a SECOND scratch root containing ONLY your suites, and
   `PABRIK_BIN=<abs path> zig test zz_<tag>_run.zig`. Running the full
   root boots every other agent's suite and takes forever.
3. Run it ≥3 times. SSE and WebSocket timing is where flakes live.
4. `ls -d /tmp/pabrik-func-* /tmp/pabrik-fix-* | wc -l` must be 0 after.
5. Delete both scratch files.
6. `zig fmt` your files — `zig fmt --check` is part of the gate.

A green run with NO `[DebugAllocator] (err): ... leaked` lines is the
proof the teardown is right; `errdefer` does not fire on a `return null`
success path.