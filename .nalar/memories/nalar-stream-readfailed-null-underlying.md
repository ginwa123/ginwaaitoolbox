# nalar — "ReadFailed with null underlying" is misleading; check body_err too

When the streaming code in `src/modules/agent/Agent.zig:1547` logs
`[STREAM] ReadFailed with null underlying (chunks=0, bytes=0)`,
the diagnostic code is **incomplete**, not the error itself.

## The two error fields

A Zig 0.16 `std.http.Client` connection has TWO distinct error
fields that can fire when the bodyReader returns `error.ReadFailed`:

| Field | Lives on | Set by | Meaning |
|---|---|---|---|
| `conn.stream_reader.err` | `Io.net.Stream.Reader` | `Io/net.zig:1306` when `io.vtable.netRead` fails | Transport-level error (RST, ECONNRESET, EPIPE, etc.) |
| `response.request.reader.body_err` | `http.Reader` | `chunkedStream` / `chunkedDiscard` in `std/http.zig:549,553,618,622` | HTTP-level error (HttpChunkInvalid, HttpChunkTruncated, HttpHeadersOversize) |

The current diagnostic at `Agent.zig:1540-1550` only checks the
transport-level field. **When the failure is HTTP-level
(chunked encoding issue), `stream_reader.err` stays null and the
log shows the misleading "null underlying" message.**

## Root cause of the bug

The user reported logs:
```
[info] [STREAM] Connected in 6s (HTTP 200)
[debug] [STREAM] Transfer: encoding=chunked, content_length=unknown
[info] [STREAM] bodyReader called: transfer_encoding=chunked, content_length=null
[err] [STREAM] ReadFailed with null underlying (chunks=0, bytes=0)
```

The chain that produces this:

1. `response.request.reader.bodyReader(...)` returns a chunked
   decoder wrapping the connection's reader.
2. The chunked decoder's first `chunkedStream` call enters the
   `.head` state and calls `in.fillMore()` to get the chunk header.
3. `in.fillMore()` calls `Io/net.zig:readVec` → `netRead`. The
   server **closed the connection cleanly** (TCP FIN) without
   sending any data → `netRead` returns 0 → `readVec` returns
   `error.EndOfStream`.
4. `chunkedReadEndless` re-throws `EndOfStream`. `chunkedStream`'s
   catch (`std/http.zig:548-551`) sets
   `reader.body_err = error.HttpChunkTruncated` and returns
   `error.ReadFailed`.
5. `readSliceShort` returns `ReadFailed` to Agent.zig.
6. Agent.zig checks `conn.stream_reader.err` → null (clean close,
   no transport error). Logs "null underlying". **Misses the
   real cause: `HttpChunkTruncated`**.

## Why the server sends 200 + chunked then closes cleanly

Several possible causes:

- The LLM server accepted the request and started streaming, then
  **panicked / OOM / crashed** before sending any data. With
  `Transfer-Encoding: chunked`, the first response chunk is the
  only output the client has any signal that the response started.
- A proxy in front of the server (CDN, API gateway, Cloudflare)
  killed the connection because:
  - Upstream is too slow to start streaming (524 timeout, etc.)
  - Body size limit was hit
  - Server's response header validation failed post-hoc
- The LLM server's response generator crashed but the HTTP layer
  still sent the headers (200 OK is sometimes sent optimistically
  before the body generator runs).
- The request body was so large (647KB in the user's logs) that
  the server queued it but aborted processing before any output.

## Fix the diagnostic

In `src/modules/agent/Agent.zig`, around line 1532, update the
catch for `error.ReadFailed` to ALSO check `body_err`:

```zig
if (err == error.ReadFailed) {
    const conn = response.request.connection orelse {
        self.log_msg(.err, "[STREAM] ReadFailed with no connection");
        return error.StreamInterrupted;
    };
    // Check BOTH layers: transport (RST/etc) AND HTTP (chunked issue).
    const http_err_opt: ?std.http.Reader.BodyError =
        response.request.reader.body_err;
    const transport_err_opt: ?std.Io.net.Stream.Reader.Error =
        conn.stream_reader.err;
    if (http_err_opt) |he| {
        self.log_fmt(.err, "[STREAM] http error: {s} (chunks={}, bytes={}, transport={?s})", .{
            @errorName(he), chunk_count, total_bytes_read,
            if (transport_err_opt) |t| @errorName(t) else null,
        });
    } else if (transport_err_opt) |te| {
        self.log_fmt(.err, "[STREAM] transport error: {s} (chunks={}, bytes={}, elapsed={}ms)", .{
            @errorName(te), chunk_count, total_bytes_read,
            elapsedMs(self.httpClient.io, stream_start),
        });
    } else {
        self.log_fmt(.err, "[STREAM] ReadFailed with null underlying and no body_err (chunks={}, bytes={})", .{
            chunk_count, total_bytes_read,
        });
    }
    // ... watchdog translation + return StreamInterrupted ...
}
```

## Add a regression test

A new test in `src/modules/agent/Agent_test.zig` (or similar) for
the streaming layer should:

1. Start a fake HTTP server that returns `200 OK` + `Transfer-Encoding: chunked`
   headers, then immediately `close()`s the socket.
2. Call `Agent.callStreaming(...)` and assert it returns
   `error.StreamInterrupted` AND that the diagnostic log contains
   `HttpChunkTruncated` (not `null underlying`).
3. This locks in the fix so future refactors of the catch block
   can't regress the diagnostic.

## When this bites

- Any user-visible report of `ReadFailed with null underlying` in
  the nalar backend logs — the real cause is almost always
  `HttpChunkTruncated` (server closed before sending data).
- Long-running streams that get cut off after the connection
  succeeds — could be the same root cause if a proxy fires a
  timeout before the LLM produces its first chunk.
- Any future code that needs to differentiate "the upstream is
  dead" (transport error) from "the upstream sent bad chunked
  encoding" (HTTP error). The two have different remediation
  paths (TCP keepalive vs retry the request).

## Related stdlib lines (verified in Zig 0.16)

- `/usr/local/lib/zig/std/Io/net.zig:1305-1307` — netRead sets
  `r.err` before returning ReadFailed
- `/usr/local/lib/zig/std/http.zig:548-551` — chunkedStream catches
  EndOfStream → HttpChunkTruncated + ReadFailed
- `/usr/local/lib/zig/std/http.zig:552-555` — chunkedStream catches
  other errors → body_err + ReadFailed
- `/usr/local/lib/zig/std/http.zig:331` — `body_err: ?BodyError = null`
- `/usr/local/lib/zig/std/http.zig:362-366` — BodyError variants
  (HttpChunkInvalid, HttpChunkTruncated, HttpHeadersOversize)