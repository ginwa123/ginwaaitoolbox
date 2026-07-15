# nalar — Pre-existing cross-platform bug in `setReuseAddr`

## Symptom

On macOS, the GinwaServer (HTTP listener) crashes during `GinwaServer.init()` with:
```
thread N panic: reached unreachable code
src/.../std/posix.zig:1081:23 in setsockopt
    .INVAL => unreachable,
src/.../http_server.zig:88 in setReuseAddr
```

On Linux, the call doesn't crash (it silently sets a no-op-ish option), so this is invisible unless someone runs on macOS.

## Why

`src/modules/custom_http_server/src/http_server.zig:88` (pre-fix) had:

```zig
const opt: i32 = 1;
try posix.setsockopt(sock_fd, 1, 2, std.mem.asBytes(&opt));
```

The author meant `SOL_SOCKET, SO_REUSEADDR`. But `SO_REUSEADDR` is actually
`0x0004` on every POSIX (per `<sys/socket.h>`, exposed as
`std.os.<platform>.SO.REUSEADDR`). The hardcoded `1, 2` is `SOL_SOCKET,
SO_TYPE` — which is invalid as a *set* direction on a listen socket and
triggers `EINVAL`.

Zig 0.16's `posix.setsockopt` maps `.INVAL` to `@compileError`-time
`unreachable` (it's the "you passed the wrong constant at compile time"
diagnostic channel). The runtime path is therefore a guaranteed panic.

## Fix (commit `621fc704` on `feature/criteria-smoke-test`)

Use the stdlib's os-tagged constants:

```zig
const opt: i32 = 1;
try posix.setsockopt(
    sock_fd,
    @intCast(posix.SOL.SOCKET),    // 1 on Linux, 0xffff on macOS
    @intCast(posix.SO.REUSEADDR),  // 0x0004 on both
    std.mem.asBytes(&opt),
);
```

Verified: `scripts/ci-smoke-test.sh` passes on both Linux and macOS;
`zig build test --summary all` is 920/923 green (no regressions).

## How to avoid reintroducing

- **Never** hardcode `1, 2` (or any numeric literal) when calling
  `setsockopt` — these constants are OS-specific. Always use
  `std.posix.SOL.*` and `std.posix.SO.*`.
- **Always** run the criteria-pass smoke test (`scripts/ci-smoke-test.sh`)
  on macOS before pushing any HTTP-listener change. The Linux cell
  alone won't catch this class of bug.
- The Zig stdlib explicitly documents `posix.setsockopt` as "use
  `std.Io` instead" on Windows, and `INVAL → unreachable` everywhere
  else. If you pass the wrong constant, expect to learn about it via
  a panic, not a runtime error.

## Related memories

- `cross-check-claims-against-source.md` — verify the *diagnosis* is
  correct ("SO_TYPE on a listen socket returns EINVAL on macOS"
  was correct; "it worked because of SO_DEBUG acceptance" was a
  stub for the real reason — the call worked because nothing
  enforced correctness, not because it did the right thing).
- `nalar-fresh-db-migration-cascade.md` — the migration cascade
  bugs the smoke test also surfaced.
- `verification-before-completion.md` — "smoke test passes on
  Linux" is NOT a substitute for "smoke test passes on macOS".

## Where this lives

`src/modules/custom_http_server/src/http_server.zig:setReuseAddr`
(about line 88 before the fix, line 105 after).
