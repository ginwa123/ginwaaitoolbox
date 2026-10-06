---
name: zig-016-callee-frame-address-traps
description: Two Zig 0.16 traps that silently corrupt a ported test — a struct returned BY VALUE after its address was handed to a thread or to an Io reader/writer, and std.json's default .alloc_if_needed leaving strings pointing into the input buffer. Both present as "the healthy server never sent anything".
---

# Zig 0.16: two traps that look like a server bug

Both of these were found porting `tests/functional/*_test.py` → `.zig` and
both present identically: **the wire assertion fails against a server that
is demonstrably healthy**. That is what makes them expensive — the instinct
is to go debug the server.

## 1. Returning a struct BY VALUE after handing its address away

If a helper does any of these, it MUST return a POINTER (`gpa.create`):

```zig
// BROKEN — the returned copy has a different `stop` than the thread polls.
fn start(...) !ReadDeadline {
    var self: ReadDeadline = .{ .stop = .init(false), ... };
    self.thread = try std.Thread.spawn(.{}, watch, .{ stream, &self.stop, ms });
    return self;                       // copy
}
```

Same shape for a struct whose reader/writer was built over its OWN fields:

```zig
// BROKEN — reader.interface.buffer holds the address of the DEAD callee frame.
fn connect(...) !WsConn {
    var self: WsConn = .{ ... };
    self.reader = self.stream.reader(io, self.rd_buf[0..]);
    return self;
}
```

`gpa.create` also does NOT run field default initialisers — assign them
explicitly (`self.* = .{ .mutex = .init, ... }`) or an uninitialised
`Io.Mutex` parks a thread on a futex nobody will ever wake.

**Symptom of #1**: the watchdog thread polls a dead frame, never observes
the stop flag, so it runs its full budget and fires `shutdown(SHUT_RD)`
against a live connection. Reads then return nothing new forever. It looks
exactly like a server that accepted the handshake and then went quiet.

### How to prove it (cheap)
Print `std.debug.print` at the top of the thread body and at the point it
fires. "start" then "FIRING" with no other output between them, for a read
that returned in a millisecond, names the bug immediately.

## 2. `std.json` default parse borrows the input buffer

`std.json.ParseOptions.allocate` defaults to `.alloc_if_needed`, which
leaves a string that needs no escaping pointing INTO the input slice rather
than copying it into the parse's arena.

```zig
// BROKEN — `sa_json` is freed on return; the returned tree dangles.
fn parseSaValue() !std.json.Parsed(std.json.Value) {
    const sa_json = try std.json.Stringify.valueAlloc(gpa, SA, .{});
    defer gpa.free(sa_json);
    return std.json.parseFromSlice(std.json.Value, gpa, sa_json, .{});
}
```

Fix: `.{ .allocate = .alloc_always }`, and return the `Parsed` (which owns
the arena), not the `Value`.

**Symptom of #2**: a non-deterministic failure two steps later, in whatever
re-reads the file — here a `PUT /api/config/pabrik` **500**, which reads as
a server bug.

## Also worth knowing

- `Io.net.IpAddress.connect(io, .{ .timeout = ... })` PANICS on POSIX:
  `netConnectIpPosix` is `@panic("TODO implement netConnectIpPosix with
  timeout")`. Pass `.timeout = .none` (the default) and bound blocking
  reads some other way.
- There is NO WebSocket client in Zig 0.16's stdlib (`grep -ril websocket
  std/` finds nothing outside `std.Build`). A raw `Io.net.Stream` plus
  hand-rolled RFC 6455 framing is the only option — `Stream.reader` /
  `Stream.writer` give the same `Io.Reader` / `Io.Writer` interfaces.
- `Io.Reader.take(n)` REBASES into a fixed buffer and ASSERTS when `n`
  exceeds it; read frame headers length-first and check capacity explicitly
  rather than relying on `readVec`'s partial reads.
- `std.json.Stringify` on a struct emits an OBJECT. `python d["k"] = [d]`
  ports to a one-element ARRAY — parse `"[" ++ obj_json ++ "]"`, or the
  server's list parser 500s.