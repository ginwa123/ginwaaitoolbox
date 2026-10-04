# Audit: `pabrik-tui` memory leak + typing/scrolling latency (rev 1)

**Goal:** explain why `pabrik-tui` leaks memory and why typing / mouse-wheel
scrolling feels slow, prove both with measurements, and fix the root causes.

**Status:** root-caused, fixed, and re-measured. Fixes + regression gates are in
this PR; §7 lists what is deliberately left out.

**Component:** `pabrik-tui` — `src/apps/cli/src/tui/`, `src/apps/cli/src/tui_main.zig`,
binary target `install:tui`. Zig 0.16, Bubble-Tea-style (`Model.update(Msg) → Cmd`,
`Model.view() → Frame`), single-threaded, poll-based streaming.

## 1. Executive summary

Three independent defects, all in the event loop / ownership layer:

| # | Defect | Symptom | Measured |
|---|---|---|---|
| **F1** | `main()` hands the TUI `init.arena.allocator()` — the *process-lifetime* arena, whose `free()` only ever reclaims the most recent allocation | unbounded RSS growth; eventually the machine swaps and everything slows down | **+1.76 MB/s while completely idle**; **+364 KB per keystroke** at 200×50; **+2.78 MB per keystroke** at 400×100 (16 MB → 442 MB in ~40 s of typing) |
| **F2** | `Reader.readSliceShort()` is used to drain stdin. Despite the name it keeps reading until its destination buffer is **completely full**, so each keypress is followed by further reads that wait for the tty's `VTIME` (100 ms) to expire | every keystroke and every wheel notch has a ~100 ms delay behind it | poll wakes **0.0 ms** after the keypress, the following read returns **108 ms** later ⇒ keystroke latency **p50 104 ms** |
| **F3** | The loop `read()` → (nothing) → `io.sleep(100 ms)` → tick → draw, with no `poll()` | keystrokes and ticks fight each other; latency floor, drifting 500 ms poll cadence | idle redraw cadence 10/s; latency unchanged (104 ms) even at 442 MB RSS, while per-draw CPU is only ~2.7 ms |
| **F7** | "Is this turn over?" was decided by scanning the **whole** polled array for *any* assistant row with `finish_reason="stop"` — but the poll returns the session's last 100 messages, including the *previous* turn's completed reply (found after the first pass, see §3.7) | **the second and every later turn in a session renders nothing** — no user message, no reply — while the desktop (SSE) shows the answer exists | fake-backend repro: turn 1 renders, turn 2's `SECOND-TURN-REPLY` never reaches the pty; the client stops polling ~500 ms after the send |

After the fixes (200×50 terminal, same pty harness):

| metric | before | after |
|---|---|---|
| RSS while idle | **+1 760 KB/s** | **+4 KB/s** |
| RSS per keystroke (200×50) | +364 KB | **+0.4 KB** |
| RSS per keystroke (400×100) | +2 785 KB | **~0 KB** |
| keystroke latency p50 / p90 | **104 ms / 110 ms** | **1.1 ms / 1.1 ms** |
| wheel-notch latency p50 | 104 ms | **2.2 ms** |
| RSS over a 15-keystroke × 8-round soak | 66 MB → 442 MB | 15.2 MB → 14.8 MB (flat) |

## 2. How it was measured

`pabrik-tui` refuses to start unless stdin is a TTY, and both symptoms only exist
at the terminal layer, so the probe drives the real binary inside a pty and samples
`/proc/<pid>/status`:

* **RSS** — sampled around idle periods and around keystrokes; the delta divided by
  the number of redraws gives bytes-per-frame.
* **Latency** — one key written to the pty, then the time until the app writes its
  next byte back (`select()` on the master). A control experiment with a trivial
  pty echo child measures **0.07 ms**, so the pty itself contributes nothing.
* **Draw rate / CPU** — `utime+stime` from `/proc/<pid>/stat`, and `wchan` sampling
  (the loop sits in `poll_schedule_timeout` ~90 % of samples when idle, at ~1 % CPU).

The probe is committed as `tests/functional/tui_perf_probe.py` (standalone) and
`tests/functional/tui_perf_test.py` (pytest gate, skips when `zig build install:tui`
has not run). It points the TUI at an unreachable backend, so it is hermetic: no
ports, no network, no state on disk (the TUI module performs no file I/O).

## 3. Findings

### F1 — the app allocator is the process-lifetime arena (the leak)

`tui_main.zig:39` (pre-fix):

```zig
const allocator = init.arena.allocator();   // std.process.Init.arena
```

`std.process.Init.arena` is documented as *"Permanent storage for the entire
process"* (`/usr/lib/zig/std/process.zig:33-35`), and `ArenaAllocator.free` is
documented as *"Calls to free an individual item only free the item if it was the
most recent allocation, otherwise calls to free do nothing"*
(`/usr/lib/zig/std/heap/ArenaAllocator.zig:1-4`, `:608-636`).

Every per-frame temporary therefore became permanent. The draw path alone retains
**two whole frame buffers per redraw**, because the frees are never in LIFO order:

1. `draw()` allocated `next` (a `width*height` cell buffer),
2. `frame.diff()` allocated its output buffer **after** `next`,
3. the previous reference frame was freed — no longer the most recent allocation,
4. `next` was freed via `defer` — not the most recent either, since a brand-new
   `prev_frame` had been allocated in between (pre-fix `program.zig:196-198`).

At 200×50 a `Cell` is 8 bytes, so each frame buffer is 80 KB and the leak is
~160 KB per redraw — 1.6 MB/s at the idle tick rate of 10 draws/s, which is what
the probe measured (1.76 MB/s). Additional per-draw leak vectors fed the same
arena: `frame.diff`'s `std.Io.Writer.Allocating` growth, `wrapText`'s per-chunk
`dupe`s, and the per-message `iter_arena` in `App.onMessages` (a child arena
`deinit` on an arena parent is a no-op unless it is the parent's last allocation).

*Why typing leaked more than idling:* a keystroke redraw produces a bigger diff
(the input row changes), so more writer-growth allocations are interleaved — and
at 400×100 the same 2-frame-buffer leak is 4× larger. The leak is proportional to
**terminal area × number of redraws**, i.e. it grows with how much you use it.

### F2 — `readSliceShort` fills its whole buffer (the 100 ms floor)

`program.zig:117` (pre-fix) drained stdin with:

```zig
const n = stdin_reader.interface.readSliceShort(self.input_buf[self.input_len..]) catch 0;
```

Zig 0.16's `Reader.readSliceShort` (`/usr/lib/zig/std/Io/Reader.zig:675-694`) is:

```zig
while (true) {
    data[0] = buffer[i..];
    i += readVec(r, &data) ...;
    if (buffer.len - i == 0) return buffer.len;   // returns only when FULL
}
```

So asking it for the 256-byte input buffer means: read the keystroke, then keep
reading until 256 bytes arrive or the tty read fails. With the tty in raw mode
`VMIN=0/VTIME=1`, those follow-up reads only return when the 100 ms `VTIME` timer
expires ⇒ **108 ms per keypress**. A temporary in-process trace proved the order:

```
1789304529379 poll wait=99 ready=1 revents=1     <- poll woke immediately (0.0 ms)
1789304529487 read n=1                           <- read returned 108 ms later
1789304529488 poll wait=0 ready=0 revents=0
```

The fix is `readVec` (one read syscall, short reads allowed), which the rest of
this repo already uses where short reads matter (e.g. `mcp_stdio.zig`, which
documents the same hazard).

### F3 — read-then-sleep instead of poll (latency coupling + tick drift)

The pre-fix loop had no `poll()`: it blocked in `read()` and, when the read
reported nothing, slept a fixed 100 ms before emitting the tick. Consequences:
the tick cadence and input handling were serialized (a key arriving during the
sleep waited for it), and the 500 ms poll cadence was driven by a hardcoded
`TICK_MS` instead of real elapsed time. It also made F2 invisible: the loop
"worked", just 100 ms late.

### F4 — every redraw re-wrapped and re-allocated the whole visible viewport

`Viewport.render` walked the lines *twice* per frame (a backward sweep to find the
start row, then a forward render), and each walk called `wrapText`, which
allocated a chunk list **plus one `dupe` per chunk** — per line, per frame. Under
F1's arena none of those frees ever landed, so word-wrapping was both a CPU cost
and a leak vector. `wrappedHeightOf` allocated a whole chunk list merely to count
rows.

### F5 — one extra full-frame allocation + memcpy per draw

`draw()` finished by allocating a fresh `Frame` and `@memcpy`-ing the rendered
cells into it (pre-fix `program.zig:196-198`) instead of transferring ownership of
the frame it had just rendered. That is an extra 80 KB allocation plus an 80 KB
copy (10 000 cells) at 200×50, 10× per second while idle.

### F6 — O(n) scrollback trim per appended line

Once scrollback hit the 10 000-line cap, every further line did
`lines.orderedRemove(0)`, i.e. a `memmove` of the whole 10 000-entry array
(240 KB) per line — a 60-line streamed reply paid 60 full array shifts.

### F7 — the "turn is over" scan read the previous turn's stop

Reported after the first pass: *"next prompt response not showup in tui"* — turn 1
rendered (user → assistant → tool card → assistant), turn 2 showed neither the
user's message nor the reply, while the desktop client showed the answer existed.

`App.onMessages` decided the turn was over with:

```zig
if (self.is_streaming) {
    while (idx < arr.items.len) : (idx += 1) {
        ... if (assistant row has finish_reason == "stop") { self.is_streaming = false; break; }
    }
}
```

`transport.getMessages` polls `GET /api/llm/session/:id/messages?limit=100&direction=asc`,
so `arr` is the **whole session window** — it always contains the previous turn's
completed reply. On the first poll of turn 2 (≈500 ms after Enter) the scan found
turn 1's `stop`, set `is_streaming = false`, and `handleTick` stopped returning
`poll_messages` — so nothing else was ever fetched or rendered. Turn 1 only worked
because the array contained no earlier `stop`; every subsequent turn in a session
was dead. It also explains the missing *user* message: the queued row is inserted
by the backend worker, so if the first poll predates that insert, the single poll
the client ever made contained no news at all.

Reproduced deterministically with a fake backend serving two turns
(`tests/functional/tui_turn_streaming_test.py`): turn 1 renders, turn 2's
`SECOND-TURN-REPLY` never reaches the pty. Fix: decide "turn over" in the same
render pass and only for rows that are **new in this poll** — a stop row that has
already been rendered is history. The `finish_reason`-less legacy fallback ("the
last row is an assistant row") is scoped the same way.

Alongside it, a cosmetic bug visible in the same screenshot: the status bar was
written exactly once (`init` → `"new session"`), so it stayed `"new session"`
forever, and the left slot was overwritten with `"session {session_id}"` against
an id that already starts with `session-`, rendering
`session session-1789312667194`. `onSendOk` now writes the id once, in the right
slot, and leaves the app name alone.

### Ruled out (measured, not assumed)

* **CPU-bound rendering** — per-draw CPU is 2.0–2.7 ms at 400×100 and ~0.7 ms at
  200×50; latency was flat at 104 ms from 16 MB to 442 MB RSS, so the 100 ms was
  *latency*, not compute (F2/F3).
* **The pty or the harness** — a trivial pty echo child round-trips in 0.07 ms.
* **The key parser** — `key.zig` is a single forward pass over the read bytes, and
  every invalid byte is consumed (no permanently-unparseable input; the only stall
  needs a full 256-byte buffer holding an incomplete escape sequence).
* **The poll/render cadence under load** — after the fix, ticks are still serviced
  between input bursts because `wait_ms` drops to 0 as soon as the tick is due.
* **SSE** — `sse.zig` is dead code in production (only `transport.openEvents` is
  referenced, and only from tests); streaming is poll-based.
* **The message/poll path** — a fake backend returning identical payloads for 41
  polls grows RSS by ~3 KB/poll (noise); rendering 61 new rows costs ~1.4 MB total,
  which is the legitimately retained viewport text plus libcurl/libc pools.

## 4. Fixes applied

| File | Change |
|---|---|
| `src/apps/cli/src/tui_main.zig` | Use `init.gpa` (the general-purpose allocator) for the App/Program; keep `init.arena` only for the process-lifetime `cfg.cwd` string it was actually meant for. |
| `src/apps/cli/src/tui/program.zig` | Event loop waits in `poll()` for the next stdin byte **or** the next tick (whichever first); reads once with `readVec` (F2); passes real elapsed time to `.tick`; ticks are serviced between input bursts; `draw()` transfers frame ownership instead of allocating + copying (F5); `renderDiff` split out so the allocation behaviour is unit-testable. |
| `src/apps/cli/src/tui/terminal.zig` | Documented why `VMIN=0/VTIME=1` stays (with `readVec` the fallback timer can never fire; `VMIN=1` would hang on a stale readiness) and that it was *not* the cause of the old latency floor. |
| `src/apps/cli/src/tui/widgets.zig` | `wrapText` returns **borrowed subslices** instead of `dupe`s; the render path reuses one `wrap_scratch` chunk list across lines **and frames**; `wrappedHeight` counts rows without allocating; batched scrollback trim with `enforceCap()` (F6). |
| `src/apps/cli/src/tui/app.zig` | Calls `Viewport.enforceCap()`; the per-message render arena is `defer`-freed on every path. **F7:** the "turn over" decision moved into the render pass and is restricted to rows *new in this poll*, so a previous turn's `finish_reason="stop"` can no longer end the next one; `onSendOk` fixes the duplicated/stale status-bar text. |
| `tests/functional/tui_perf_probe.py`, `tests/functional/tui_perf_test.py` | New pty regression gate: idle leak < 256 KB/s, typing leak < 32 KB/key, keystroke p50 < 30 ms. Fails on the pre-fix binary (1 638 KB/s, 103.8 ms), passes now. |
| `tests/functional/tui_turn_streaming_test.py` | New pty regression gate for F7: a fake backend serves two turns and asserts both turns' user text and replies reach the terminal (fails pre-fix). |

Unit-level regression tests added next to the code they guard:

* `widgets.zig` — `wrapText` chunks are subslices of the input (no copies);
  `wrappedHeight` agrees with `wrapText`'s chunk count over a corpus of shapes
  (empty / short / long / hard-split / newline / whitespace-only × 9 widths);
  `Viewport.render` adds **0 bytes** of arena capacity on repeat frames (25 frames
  after a warm-up frame); `enforceCap` drops in batches and keeps scroll in range.
* `program.zig` — repeated `renderDiff` releases every frame buffer (leak-checked
  by `testing.allocator`); a second draw of an unchanged model emits only the
  cursor park (proves the swap keeps the *rendered* frame as the diff reference);
  `tickElapsedMs` saturates and clamps after a suspend.
* `app.zig` — a previous turn's `finish_reason="stop"` does not end the next turn
  (F7); a poll that raced ahead of the user-row insert keeps streaming; the
  `finish_reason`-less fallback is scoped to new rows too; the status bar shows
  the session id once, in the right slot.

## 5. Before / after (same harness, same machine, 200×50 unless noted)

```
BEFORE  idle        : +16 204 KB in 10.0 s  (+1 620 KB/s)
BEFORE  typing      : +364 KB per key       (400x100: +2 785 KB per key)
BEFORE  soak        : 16 MB -> 442 MB over 10 rounds x 15 keys/wheels
BEFORE  keystroke   : p50 104 ms, p90 110 ms      CPU/draw 2.7 ms
BEFORE  wheel       : p50 104 ms
AFTER   idle        : +4 KB/s
AFTER   typing      : +0.4 KB per key
AFTER   soak        : 15.2 MB -> 14.8 MB (flat)
AFTER   keystroke   : p50 1.1 ms, p90 1.1 ms  (400x100: p50 2.2 ms)
AFTER   wheel       : p50 2.2 ms
AFTER   fake backend: user + assistant + wrapped line + tool card all render,
                      RSS +880 KB across a 4-snapshot streaming session
```

## 6. Verification

```bash
zig build test:tui --summary all          # 169/169 pass
zig build install:tui                     # produces zig-out/bin/pabrik-tui
python3 tests/functional/tui_perf_probe.py --binary zig-out/bin/pabrik-tui
#   idle 4 KB/s · 0.4 KB/key · p50 1.1 ms · PASS
/home/ginwa/ginwaaitoolbox/.venv-func/bin/python -m pytest tests/functional/tui_perf_test.py -v
#   3 passed
/home/ginwa/ginwaaitoolbox/.venv-func/bin/python -m pytest tests/functional/tui_turn_streaming_test.py -v
#   2 passed — turn 2's user message and reply both render
python3 tests/functional/tui_perf_probe.py --binary <pre-fix binary>   # FAILs as expected
```

Interactive checks done through the pty harness: typing echoes and edits, PgUp/PgDn
and mouse-wheel scrolling move by the expected rows, `Ctrl-C` restores the terminal,
and a full send → poll → render cycle against a fake backend renders the user
message, the assistant reply, a wrapped long line and a tool card, with keystroke
latency staying ~1 ms throughout. A second fake-backend suite drives **two
consecutive turns** in one session and asserts both turns render (F7).

## 7. Follow-ups (deliberately not in this PR)

1. **The 500 ms poll runs a blocking HTTP GET on the UI thread** (`tui_main.zig:pollMessages`,
   15 s timeout). While streaming, a slow backend stalls input for up to 15 s. The
   clean fix is the SSE channel that `transport.openEvents`/`sse.zig` already
   implement (currently dead code), or moving the poll to a worker thread.
2. **`onMessages` re-parses the whole response body on every poll** (unbounded body
   size; `limit=100` is a row count, not a byte cap) and renders an assistant
   message after stripping thinking tags twice (`render_msg.zig`: `isThinkingOnly`
   then `stripThinkingTags`).
3. **`App.seen_ids` grows for the process lifetime** — it is never pruned even
   though the viewport drops old lines.
4. **Idle redraws** — the tick redraws even when nothing changed (1 % CPU, a few
   bytes to the terminal per tick). A dirty flag would make idle free; not needed
   for the reported symptoms.
5. **`pabrikcli`'s `main.zig:21` uses the same process arena.** It is a short-lived
   CLI, so it does not have this bug in practice, but it is the same trap.
6. **`VMIN=0/VTIME=1` remains a latent 100 ms trap for any future code path that
   reads stdin without polling first.**

## 8. Notes for the reviewer

* The `wrapText` contract changed: the returned chunks are now **borrowed
  subslices** of the input; only the outer slice is owned. Its tests were updated
  (`freeChunks`) and a new test asserts the slices point into the input.
* `Viewport.render` takes `*Viewport` (not `*const`) because it owns the reuse
  scratch list; that list is freed in `Viewport.deinit`.
* The TUI is POSIX-only (it already used `std.posix.termios`); `poll` and
  `TIOCGWINSZ` are Unix APIs, and Windows does not build the TUI today.
* The pty gate is skipped in CI (CI installs only the `pabrik` binary); run it
  locally after `zig build install:tui`.
