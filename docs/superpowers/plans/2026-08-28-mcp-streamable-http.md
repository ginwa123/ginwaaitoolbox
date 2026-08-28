# MCP Streamable HTTP Transport for the Agent AI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the nalar agent's HTTP MCP transport fully conformant with the [MCP Streamable HTTP spec, current revision 2026-07-28](https://modelcontextprotocol.io/specification/draft/basic/transports/streamable-http). The agent can talk to MCP servers that expose a single HTTP endpoint accepting POST, with the server free to answer each request as either a single `application/json` object or a `text/event-stream` (SSE) stream carrying progress notifications + the final JSON-RPC response. Required request metadata headers (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`) are emitted on every POST. stdio stays untouched (backward compat). For self-testing we ship a separate **`mcp-http-hello-world`** Node binary (sibling of the existing `mcp-hello-world` stdio binary) that uses the SDK's `StreamableHTTPServerTransport` — the functional harness runs it as a subprocess, points a `mcp_servers.url` at it, calls a tool via the agent, and asserts the wire contract end-to-end.

**Process — TDD + one-file-per-Zig-module + git worktree:**
- **TDD discipline for every task**: write the failing test first, run it to confirm RED, write the minimal impl to pass it, refactor, run it again to confirm GREEN, then move on. Every inline test in `mcp_http.zig` and every functional test in `mcp_http_test.py` is written BEFORE the production code it exercises. The plan is structured red → green → refactor for each unit.
- **One file per Zig module** (impl + tests in the same `.zig` file, per the user's stated preference "no need split code for zig, just one file with test"). Tests live as `test "..." { }` blocks at the bottom of the impl file. The new `mcp_http.zig` will be ~700-1000 lines including inline tests — same shape as the existing `mcp_stdio.zig` (762 lines, 21 inline tests).
- **Git worktree**: all work happens in `/home/ginwa/ginwaaitoolbox/.worktrees/mcp-streamable-http` on branch `worktree/mcp-streamable-http`. The main checkout stays untouched until the PR is merged. Per the user's standing instruction "use git worktree" — every multi-file feature gets one.

**Architecture:** Today, `src/ai_workflow/tui/agentic_loop/handle_mcp_tool.zig` does a single `POST {url}` with a hand-rolled `data:` prefix stripper. We keep that file as the **dispatcher** (presence of `command` ⇒ stdio client, presence of `url` ⇒ http client) and extract the HTTP-specific work into a new sibling module `src/modules/agent/mcp/mcp/mcp_http.zig`. That new file owns:

1. **SSE framing** — private `readSseEvents` iterator that walks the response stream and yields fully-parsed events (one event = one logical message terminated by a blank line; each event may carry `event:`, `data:`, `id:`, `retry:` fields per the [SSE spec](https://html.spec.whatwg.org/multipage/server-sent-events.html)).
2. **Header builder** — `buildMcpHeaders` that emits the spec-mandated `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, `Accept`, `Content-Type` headers, merged with the user-defined custom headers from `mcp_servers[server].headers`.
3. **`HttpClient`** — owns the `custom_http_client.Client`, the base URL, and a persistent per-server session (cookies/auth headers, no protocol-level session id per the 2026-07-28 revision). Sends a `tools/call` JSON-RPC body, returns the final `result.content[0].text`.
4. **`HttpRegistry`** — process-global, one `HttpClient` per server name, lazy first call, no respawn needed (HTTP servers don't die on us like stdio children do; the registry just caches the reusable `Client` and per-server config).
5. **`ListTools`** — a sibling helper that wraps the `tools/list` roundtrip; both `handle_mcp_tool.zig` and `prompts_build_messages_for_agent_prompt.zig`'s `buildMCPToolsRun` route through it.

The existing `mcp_stdio.zig` (`StdioClient`, `StdioRegistry`) is **untouched** — same sibling pattern, same one-file convention. The existing `mcp_transport.zig` (server-side) is **untouched** — it serves nalar's own MCP server endpoint, not the client side. `handle_mcp_tool.zig` becomes a thin dispatcher: parse `mcp_serverName_toolName` → look up server config → if `command` present, call `mcp_stdio.StdioRegistry`; if `url` present, call new `mcp_http.HttpRegistry`. No new config schema column (MCP server config keeps living in `config.json` under the existing `mcp_servers` key; `url` is the discriminator for HTTP). No new PUT endpoint.

**Tech Stack:** Zig 0.16 (`std.Io`, `std.atomic.Mutex`, `std.json`), `custom_http_client` (existing — has `Client.post`, `ResponseStream`, `StreamScanner` for line-buffered streaming needed for SSE), Vue 3 + TypeScript + Pinia, `pytest` + `subprocess` harness, `tests/functional/harness.py` (isolated tmpdir HOME, port 8080..8199).

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/mcp-streamable-http` on branch `worktree/mcp-streamable-http`.

---

## What exists today (read this before changing anything)

- **MCP stdio transport** — `src/modules/agent/mcp/mcp/mcp_stdio.zig` (762 lines, 3 sections: framing / `StdioClient` / `StdioRegistry`, 12 inline tests, 3 FD-leak tests, plus a global `StdioRegistry.global()`). The stdio path in `handle_mcp_tool.zig` is at lines 245–333 (`callViaStdio`).
- **MCP HTTP client (pre-spec)** — `src/ai_workflow/tui/agentic_loop/handle_mcp_tool.zig` lines 96–234: POSTs a JSON-RPC body, sets `Accept: application/json, text/event-stream` and `Content-Type: application/json`, but **misses the spec-mandated `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` headers**. The body parser uses a regex-like `stripSsePrefix` helper that only handles a single `data: ...` line — it does NOT parse full SSE events (no `\n\n` boundary, no multi-`data:`-line concatenation, no `event:` / `id:` / `retry:` field handling). For non-streaming JSON responses it works fine; for SSE responses from a real Streamable-HTTP server it gets the FIRST `data:` only, which happens to usually be the final response on trivial tools but is **wrong** for any tool that streams progress notifications before its answer.
- **Tool listing** — `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig:391 buildMCPToolsRun` → `fetchToolsFromServer`. Today it only handles the HTTP path; the stdio path was added by the previous plan. The new HTTP path needs the same treatment.
- **Config schema** — `src/modules/config/Config.zig:380 McpServerConfig { url, headers, command, args, cwd }` already covers HTTP (just `url` + `headers`); no schema change needed. The discriminator in `McpServerConfig.transport()` (line 397) prefers `command` over `url`, matching our dispatcher semantics.
- **HTTP client** — `src/modules/custom_http_client/src/{client.zig, request.zig, response.zig, stream.zig}`. The non-streaming `post()` returns a fully-buffered `Response` (line 150 in `handle_mcp_tool.zig`); the streaming `openStream()` returns a `ResponseStream` + `StreamScanner` (line 382 in `stream.zig`) that already does **line-buffered streaming** with a carry buffer — exactly what we need to parse SSE events. The 30s timeout is already the default for POST in the existing HTTP path; the new HTTP client keeps that.
- **Frontend** — `src/apps/desktop/src/api/index.ts:3486 McpServer`, `src/apps/desktop/src/components/nalar/McpServerModal.vue`, `src/apps/desktop/src/components/NalarSettings.vue`. UI today: one URL field + key/value headers editor — already supports HTTP. No frontend changes needed for the client (the wire is what changes; the user-facing config shape is unchanged).
- **Test fixture** — `src/apps/mcp_hello_world/{index.ts, package.json}` is a stdio-only `McpServer` (unchanged). The `@modelcontextprotocol/sdk@1.30.0` (already installed in `node_modules/`) ships `StreamableHTTPServerTransport` (Node `http.Server` variant) at `dist/esm/server/streamableHttp.js` — we use it in the NEW sibling binary `src/apps/mcp_http_hello_world/`, not in `mcp-hello-world`. Per the user's "one binary per transport" preference.
- **Functional harness** — `tests/functional/harness.py` already isolates `HOME`, picks port 8080..8199 (NOT 8081), launches `zig-out/bin/nalarcore-linux-x86_64`. We add a `mcp_http_hello_world_bin()` helper that resolves the new `mcp-http-hello-world-{target-triple}` sibling binary path; the test then spawns it via `subprocess.Popen` on a random port and waits for the "listening on" stderr line.

---

## Global Constraints

- **Spec target is revision 2026-07-28** (the current revision as of the linked page). Earlier revisions (2025-03-26, 2025-06-18) introduced `Mcp-Session-Id` and a GET stream endpoint — 2026-07-28 removed both. We implement ONLY the 2026-07-28 surface (POST-only, no `Mcp-Session-Id`). Backward compat with older servers is NOT a v1 goal (per the spec: "A server that does not support [older] clients MUST reject a request without the [MCP-Protocol-Version] header per Server Validation" — we are stricter, not looser).
- **Backward compat for stdio**: every existing stdio `mcp_servers` entry keeps working unchanged. `handle_mcp_tool.zig`'s `if (server_obj.get("command"))` branch is preserved verbatim.
- **Cross-platform from day one**: SSE parsing uses byte-level string ops, not platform-specific APIs. HTTP via `custom_http_client` is already cross-platform. The Node `mcp-http-hello-world` binary runs on Linux + macOS + Windows wherever Node 18+ runs.
- **Per-request arena**: handlers allocate from `ctx.allocator` (arena) → NO `defer allocator.free` inside HTTP handlers. The new SSE parser returns either an arena-allocated slice (when the caller is in a request handler) or a heap-allocated slice owned by the caller (when the caller is a test). Both are supported via the same `allocator: std.mem.Allocator` argument.
- **No new CHANGELOG file** — update `NALAR.md` (§"Recent changes") with one entry that lands on the same commit as the wire-up task.
- **DONT KILL THE PORT 8081 SERVER** — functional harness uses ports 8080..8199.
- **No port-8081 live-server + curl verification** — use the python functional harness + Zig unit tests.
- **Empty-slice-as-NULL rule** — `SqliteBackend.exec` binds `""` as SQL NULL. We don't touch the DB; only in-memory config + new code paths. Be aware if any future iteration persists server config (not this plan).
- **Tests live INLINE at the bottom of impl files** (`test "..." { }` blocks). HTTP-handler test files use `_ = @import(...)` in `src/ai_workflow/tui/test_runner.zig`.
- **SSE wire-format contract** — we add NO new SSE event names. MCP-Streamable-HTTP uses a single unnamed SSE event (default type `message`) carrying the JSON-RPC payload in `data:`. The frontend SSE dispatcher (`api/index.ts`) does not need to learn a new event type for MCP tool results; tool results ride the existing `llm_history` `updated` event. (Precedent: stdio transport §"SSE wire-format contract" in the previous plan.)
- **Custom headers from `mcp_servers[name].headers`** are passed through to every POST, ON TOP of the spec-mandated headers. If a user explicitly sets `MCP-Protocol-Version` in their headers map, the spec-mandated value wins (we set the spec value last).
- **`mcp-http-hello-world`** must use the canonical SDK `StreamableHTTPServerTransport` so we exercise a real wire, not a hand-rolled fake. The `dist/esm/server/streamableHttp.js` export is the documented public API.

---

## Design Decisions

| #   | Decision                                                                                                                                                                                                                                                                                                                                                       | Rationale                                                                                                                                                                                              |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| D1  | **One new file**: `src/modules/agent/mcp/mcp/mcp_http.zig` (mirrors the stdio pattern — same one-file convention, tests inline at bottom). Sections: (A) SSE parser (private), (B) header builder (private), (C) `HttpClient` (one per server), (D) `HttpRegistry` (process-global cache), (E) `ListTools` helper, (F) inline tests. | Matches the stdio sibling. Keeps the client code scannable in one place. Same dependency pattern as `mcp_stdio.zig` for the global registry.                                                            |
| D2  | **SSE parser is a line-level event iterator** built on `custom_http_client.stream.StreamScanner`. It carries bytes across `next()` calls, splits on `\n\n` (the event boundary per the SSE spec), parses each event's `event:` / `data:` / `id:` / `retry:` fields, and returns one `SseEvent { event, data, id, retry }` per `next()`. Multi-`data:` lines per event are concatenated with `\n` (per the SSE spec). | The SSE spec is small and stable; a hand-rolled parser is faster than pulling in a dep and gives us full control over edge cases (comments, `id:` line-only events, BOM, UTF-8 BOM in the first byte). |
| D3  | **MCP response semantics**: for a request, the server returns EITHER a single JSON object OR an SSE stream. We branch on `Content-Type` — if `application/json`, parse the body as JSON-RPC; if `text/event-stream`, walk the stream until the connection closes (the spec says "The final JSON-RPC response SHOULD terminate the stream" — we treat stream-end as the natural terminator, taking the last event's `data` as the final response). | The spec's "SHOULD terminate the stream" is not a MUST, so a server COULD close mid-stream. We handle both: per-event progress notifications, then the last event is the final answer. |
| D4  | **No protocol-level session** per the 2026-07-28 revision. The `HttpClient` does NOT send `Mcp-Session-Id` and does NOT maintain a session id. The `HttpRegistry` is a process-global cache of `HttpClient` per server name (one per server, not per session). The 2025-03-26 / 2025-06-18 `Mcp-Session-Id` header is NOT emitted. | Spec compliance + minimal state. If a future revision brings sessions back, it's a 5-line addition (one `?[]const u8` field on `HttpClient`). |
| D5  | **`HttpClient` is stateless across calls except for the reusable `custom_http_client.Client` and the cached base URL + headers.** Each `callTool` is a fresh POST; no request batching, no SSE GET stream, no long-lived listen subscription. (We do NOT implement the `subscriptions/listen` request — nalar's tool-calling loop doesn't need server-pushed change notifications. A v2 can add a long-lived listener if a real server needs it.) | Matches the simplicity of the stdio path. The spec lists `subscriptions/listen` as a v1 MAY, not MUST; skipping it keeps the surface area tight. If we need it later, the registry's `getOrConnect` shape already accommodates a long-lived stream per client. |
| D6  | **Required headers on EVERY request** (per spec): `MCP-Protocol-Version: 2026-07-28`, `Accept: application/json, text/event-stream`, `Content-Type: application/json`. **Per-method headers**: `Mcp-Method: <method>` always; `Mcp-Name: <tool name>` for `tools/call`, `<uri>` for `resources/read`, `<name>` for `prompts/get`. The `Mcp-Name` source value is emitted as a plain ASCII header — if the tool name contains non-ASCII characters (rare but possible), we fall back to omitting `Mcp-Name` and rely on the JSON body. (Full Base64-sentinel encoding per the spec is a v2.) | Spec requires these. ASCII fallback is pragmatic — every realistic tool name in the wild is ASCII. |
| D7  | **Custom headers from `mcp_servers[name].headers`** are merged with the spec-mandated headers. **Order in the request**: custom headers first, spec headers last (so spec values always win if a user accidentally sets `Accept: text/plain` or similar). This matches the stdio plan's "spec headers always win" precedent. | Defensive default. The spec-mandated values are non-negotiable. |
| D8  | **Notification POSTs return 202 Accepted with no body** per spec. We DO NOT send notifications in v1 (the only client-sent notification is `notifications/cancelled`, which the spec says is stdio-only on Streamable HTTP — closing the SSE stream is the cancellation signal). But we still implement the 202-handling path so a future notification POST is correct. | Future-proof without scope creep. The 202 branch is 4 lines of code; not having it would be a footgun when someone adds a notification later. |
| D9  | **Error status mapping**: 400 → `HeaderMismatch` / `UnsupportedProtocolVersionError` (return the response body as the error so the user sees the spec's error code); 404 → `MethodNotFound` (distinct from a legacy 404); 4xx/5xx other → `MCPServerReturnedError`. The current code conflates "any non-200" into one error; the new code preserves the spec's error distinctions. | Better diagnostics for the user. The spec's "Server Validation" section lists the exact error codes. |
| D10 | **`mcp-http-hello-world` is a separate Node binary** (NOT a `--http` flag on the existing `mcp-hello-world`). Mirrors the stdio plan's D3 — one binary per transport for clarity. Each binary has a single purpose, no CLI dispatch, simpler to reason about and to invoke from the functional harness. The HTTP binary registers the same 3 tools (`print_hello`, `print_name`, `print_exit`) on a `StreamableHTTPServerTransport` (with `sessionIdGenerator: undefined` per the 2026-07-28 spec revision) bound to a `http.createServer()`. Listens on `127.0.0.1:<port>` (the spec's "SHOULD bind only to localhost" for local servers). The port is a CLI positional arg (default 3000). | One binary per transport matches the user's stated preference "create a mcp-http-hello-world to testing using mcp http" — a separate binary with single purpose, not a multi-mode flag. Symmetric with the stdio binary. The functional harness resolves each binary via a separate helper (`mcp_hello_world_bin()` / `mcp_http_hello_world_bin()`). |
| D11 | **No frontend changes** for the client itself. The `McpServer` Vue type and `McpServerModal` already accept `url` + `headers`. The new spec headers + SSE parsing are wire-level concerns invisible to the user. (If we want to surface the spec version in the UI later — e.g. show "Server speaks MCP 2026-07-28" — that's a follow-up, not this plan.) | Spec headers are an implementation detail of the HTTP transport, not a user-facing config knob.                                                                                                                                                              |

---

## File Structure

### New files (backend — HTTP client)

```
src/modules/agent/mcp/mcp/mcp_http.zig              # ONE file: SSE parser + header builder + HttpClient + HttpRegistry + ListTools helper + tests inline at bottom
```

### Edited files (backend)

```
src/ai_workflow/tui/agentic_loop/handle_mcp_tool.zig      # dispatch stdio vs http: stdio path → mcp_stdio.StdioRegistry, http path → mcp_http.HttpRegistry; extract the body-parser into a shared helper
src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig  # buildMCPToolsRun: stdio path uses mcp_stdio, http path uses mcp_http.ListTools
src/root.zig                                              # re-export mcp_http module so nalar_mod.mcp_http.HttpRegistry etc. resolves
src/main.zig                                              # shutdown hook calls mcp_http.HttpRegistry.deinitGlobal() to free per-server clients (mirrors the stdio shutdown hook)
```

### New files (test fixture)

```
src/apps/mcp_http_hello_world/package.json                # Node package for the HTTP-only MCP test binary (separate from mcp-hello-world's package.json)
src/apps/mcp_http_hello_world/tsconfig.json               # TypeScript config (mirror of mcp_hello_world/tsconfig.json)
src/apps/mcp_http_hello_world/index.ts                    # StreamableHTTPServerTransport + http.createServer; same 3 tools as the stdio binary
src/apps/mcp_http_hello_world/server.test.ts              # vitest: boot the HTTP server on a random port, assert tools/list + tools/call round-trip
src/apps/mcp_http_hello_world/smoke.sh                    # manual smoke test (mirror of mcp_hello_world/smoke.sh)
```

### Edited files (build)

```
build.zig                                                 # add install_mcp_http_hello_world step that compiles a new exe mcp-http-hello-world-{target-triple} and installs it next to mcp-hello-world-{target-triple}
```

### New files (tests — functional)

```
tests/functional/mcp_http_test.py                         # E2E: spawn mcp-http-hello-world on a random port, configure nalar with mcp_servers.url pointing at it, call a tool via the agent, assert response
```

### Edited files (tests — functional)

```
tests/functional/harness.py                              # mcp_http_hello_world_bin() helper that resolves the mcp-http-hello-world-{target-triple} sibling binary path (mirrors the existing mcp_hello_world_bin() helper)
```

### Documentation

```
docs/superpowers/plans/2026-08-28-mcp-streamable-http.md      # this file
NALAR.md                                                       # append "### 2026-08-28: MCP Streamable HTTP transport" changelog entry
```

Total: **15 files** (1 NEW backend, 5 NEW test fixture, 1 NEW functional test, 5 EDIT backend/build/test, 1 NEW plan + 1 changelog entry). No new migration. **MCP server config continues to live in `config.json` under the existing `mcp_servers` key** — users point an HTTP entry at a Streamable HTTP server by setting `url: "https://example.com/mcp"`. No new config file, no new PUT endpoint.

---

## Tasks

> **TDD order**: test fixture first (everything downstream needs the binary), then the two pure-function helpers (SSE parser + header builder), then the client (HttpClient/Registry/ListTools), then the dispatcher refactor, then the end-to-end functional test, then the changelog.

### Task 1 — Test fixture: `mcp-http-hello-world` Node binary (TDD: red → green)

**Why:** Everything HTTP-specific lives in one file (`mcp_http.zig`) with inline tests at the bottom — same convention as `mcp_stdio.zig`. This first task ships the two pure helpers: SSE event parsing and MCP request-header construction. Both are 100% testable without a real network (the SSE parser takes a `StreamScanner`; the header builder takes slices).

**TDD order**: write all 12 inline tests FIRST (assertions + function signatures only, no impl), run `zig build test --summary all` to confirm they fail with "symbol not found" / "function not implemented" (RED), then write the minimal impl to make them pass (GREEN), then refactor.

**Files:**
- `src/modules/agent/mcp/mcp/mcp_http.zig` (NEW — impl + 12 inline tests at the bottom; `HttpClient` / `HttpRegistry` / `ListTools` arrive in Task 2; this task only ships the two helpers + their tests)

#### Step 1.1 — Write the test file FIRST (RED)

Create `mcp_http.zig` with ONLY the test block at the bottom (no impl yet — `readSseEvent` and `buildMcpHeaders` are forward-declared with `unreachable` or `_ = ...` so the file compiles but the tests fail to run):

```zig
const std = @import("builtin");
// Forward declarations — impl lands in Step 1.3.
fn readSseEvent(allocator: std.mem.Allocator, scanner: anytype) !?SseEvent { _ = allocator; _ = scanner; return null; }
fn buildMcpHeaders(allocator: std.mem.Allocator, method: []const u8, tool_name: []const u8, custom_headers: []const std.http.Header) ![]std.http.Header { _ = allocator; _ = method; _ = tool_name; _ = custom_headers; return &[_]std.http.Header{}; }
pub const SseEvent = struct { event: []const u8 = "", data: []const u8 = "", id: []const u8 = "", retry_ms: ?u64 = null };

// ... then the 12 inline tests at the bottom ...
```

The 12 inline tests are:

**For `readSseEvent` (8 tests)**:
1. **`readSseEvent: single data-only event`** — input `"data: hello\n\n"`, expect `data == "hello"`, `event == ""`, `id == ""`, `retry_ms == null`.
2. **`readSseEvent: event + data`** — input `"event: progress\ndata: {\"p\":50}\n\n"`, expect `event == "progress"`, `data == "{\"p\":50}"`.
3. **`readSseEvent: multi-data concatenation`** — input `"data: line1\ndata: line2\n\n"`, expect `data == "line1\nline2"`.
4. **`readSseEvent: comment line ignored`** — input `":heartbeat\ndata: real\n\n"`, expect `data == "real"` (comment dropped).
5. **`readSseEvent: retry parsed`** — input `"retry: 3000\ndata: ok\n\n"`, expect `retry_ms == 3000`.
6. **`readSseEvent: id field`** — input `"id: 42\ndata: ok\n\n"`, expect `id == "42"`.
7. **`readSseEvent: blank line mid-stream resets`** — input `"data: first\n\ndata: second\n\n"`, expect two events (test by calling `next` twice).
8. **`readSseEvent: case-insensitive field names`** — input `"DATA: upper\n\n"`, expect `data == "upper"`. (SSE spec says field names are case-insensitive.)

**For `buildMcpHeaders` (4 tests)**:
9. **`buildMcpHeaders: required headers always present`** — call with `method="tools/call", tool_name="say_hello"`, expect 5 headers (Accept, Content-Type, MCP-Protocol-Version, Mcp-Method, Mcp-Name) and the right values.
10. **`buildMcpHeaders: no Mcp-Name for initialize`** — call with `method="initialize", tool_name=""`, expect 4 headers (no Mcp-Name).
11. **`buildMcpHeaders: Mcp-Name omitted for non-ASCII tool names`** — call with `tool_name="名字"`, expect 4 headers (Mcp-Name skipped).
12. **`buildMcpHeaders: custom headers merged; spec headers win`** — call with a custom header `X-Trace-Id: abc` and a malicious custom `MCP-Protocol-Version: 1999-01-01`, expect the slice to contain `MCP-Protocol-Version: 2026-07-28` (spec value, not the malicious custom) AND `X-Trace-Id: abc` to be present.

**TDD commit**: commit the test-only file with message `test(mcp_http): failing tests for SSE parser + header builder`. Run `zig build test --summary all` — it must FAIL (the stubbed functions return null/empty, so the equality assertions fail). ✅ RED.

#### Step 1.2 — Write the minimal impl (GREEN)

Replace the stubbed functions in `mcp_http.zig` with the real impls. Both helpers are pure functions, no I/O, no global state — TDD-green is straightforward: pass each test in turn.

**Section A — MCP spec constants** (file-scoped, `pub` so the registry in Task 2 can read them):

```zig
const std = @import("std");
const builtin = @import("builtin");

/// Current Streamable HTTP protocol revision we implement.
/// Bump when the spec at https://modelcontextprotocol.io/specification/draft/basic/transports/streamable-http
/// revises again. Sent as the `MCP-Protocol-Version` header on every POST.
pub const PROTOCOL_VERSION: []const u8 = "2026-07-28";

/// Spec-mandated Accept header value (comma-separated, no spaces).
/// Every request must include this so the server knows we handle BOTH
/// `application/json` and `text/event-stream` responses.
pub const ACCEPT_HEADER: []const u8 = "application/json, text/event-stream";

pub const HttpError = error{
    InvalidSseEvent,       // no `data:` field on an event we expected to carry a JSON-RPC message
    ServerHeaderMismatch,  // 400 with HeaderMismatch error
    UnsupportedProtocolVersion, // 400 with UnsupportedProtocolVersionError
    ServerMethodNotFound,  // 404 (distinct from a legacy 404)
    ServerReturnedError,   // other 4xx/5xx
    InvalidJson,           // response body wasn't valid JSON-RPC
};
```

**Section B — SSE event parser** (private to the file). `readSseEvent` implementation:
- Loop over `scanner.next()` until we either find a blank line (event boundary) or hit EOF.
- For each line, dispatch on the first char:
  - `:` → comment, ignore.
  - `e` → parse `event: VALUE`, strip the prefix (case-insensitive per SSE spec — use `std.ascii.startsWithIgnoreCase`).
  - `d` → parse `data: VALUE`. **Per the SSE spec, value starts AFTER the first space (or immediately if no space).** Trim leading single space.
  - `i` → parse `id: VALUE`.
  - `r` → parse `retry: <int>`. Store as `retry_ms`.
  - anything else → ignore (unknown field per spec).
- When we hit a blank line, build the `SseEvent`. The `data` field is the concatenation of all `data:` values seen so far, joined with `\n` (per the spec). If we saw no `data:` lines, return `null` from the OUTER caller (the MCP client treats an event with no data as a comment + ignores it).
- EOF (scanner returns null): if we have any partial event in flight, flush it. If we have nothing, return null.

**Section C — MCP request-header builder** (private to the file). `buildMcpHeaders` implementation:
1. Count required headers (always 4: Accept, Content-Type, MCP-Protocol-Version, Mcp-Method) + optional Mcp-Name (when tool_name is non-empty and ASCII).
2. Allocate an `[]std.http.Header` large enough for `custom_headers.len + required_count`.
3. **Spec headers go FIRST in the slice, custom headers go LAST** — because libcurl's curl_slist uses the FIRST match for duplicate names, so the spec value (e.g. `MCP-Protocol-Version: 2026-07-28`) wins over a user's accidental custom value of the same name. This is the correction to D7 (the user CANNOT override spec values, even on purpose).
4. `is_ascii = std.ascii.isAscii` check on `tool_name` before setting `Mcp-Name`. If non-ASCII, skip the header (the JSON body still carries `params.name` so the server can read it from there).

**TDD commit**: commit the impl with message `feat(mcp_http): SSE parser + spec-compliant header builder`. Run `zig build test --summary all` — it must PASS. ✅ GREEN.

#### Step 1.3 — Refactor

Look at the impl, look for duplication, simplify. No new tests in this step — existing 12 must still pass after the refactor.

#### Step 1.4 — Verify

```bash
cd /home/ginwa/ginwaaitoolbox
zig build test --summary all
```

**Expected**: Task 1's 12 new tests pass; no regressions. Total counts: 2844/2844 pass (was 2832/2838 before this task).

---

### Task 2 — `mcp_http.zig`: SSE parser + header builder (TDD: red → green)

**Why:** Wire up the helpers from Task 1 into a usable client. The `HttpClient` sends one POST, parses one response (JSON or SSE), returns the final JSON-RPC payload. The `HttpRegistry` caches one `HttpClient` per server name (process-global, lazy init). The `ListTools` helper is a thin wrapper that does `tools/list` instead of `tools/call`. The `deinitGlobal` shuts down the registry.

**TDD order**: write the 6 new inline tests FIRST (assertions + function signatures only, no impl), run `zig build test --summary all` to confirm RED, then write the minimal impl to make them pass (GREEN), then refactor.

**Files:**
- `src/modules/agent/mcp/mcp/mcp_http.zig` (EDIT — append Sections D, E, F + 6 new inline tests; re-export from `src/root.zig`)

#### Step 2.0 — Write the tests FIRST (RED)

Append 6 new inline tests to `mcp_http.zig` (the file from Task 1). Stub out the new functions with `unreachable` / `_ = ...` so the file compiles but the tests fail. The 6 tests are:

1. **`HttpClient: 200 application/json response parsed correctly`** — start a test server that returns `Content-Type: application/json` with a `{"jsonrpc":"2.0","id":"1","result":{"content":[{"type":"text","text":"hi"}]}}` body, call `callTool`, assert the returned slice parses to the expected JSON.
2. **`HttpClient: 200 text/event-stream response — last event is the final response`** — start a test server that streams `event: message\ndata: {"jsonrpc":"2.0","id":"1","result":{"content":[{"type":"text","text":"hi"}]}}\n\n`, call `callTool`, assert the returned slice equals the data payload.
3. **`HttpClient: SSE with progress notifications then final response`** — stream `data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":50}}\n\n` followed by `data: {"jsonrpc":"2.0","id":"1","result":{"content":[{"type":"text","text":"done"}]}}\n\n`, assert the returned slice is the final response (NOT the progress notification).
4. **`HttpClient: 400 with HeaderMismatch error code surfaces ServerHeaderMismatch`** — server returns 400 with body `{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"HeaderMismatch"}}`, assert `callTool` returns `error.ServerHeaderMismatch`.
5. **`HttpRegistry: getOrConnect returns same client for same name`** — register server "alpha" twice, assert the two `*HttpClient` pointers are equal.
6. **`HttpRegistry: deinitGlobal cleans up owned Threaded io`** — call `global()` then `deinitGlobal()`; assert no leak (use the `countOpenFds` pattern from `mcp_stdio.zig`).

**TDD commit**: commit the test additions with message `test(mcp_http): failing tests for HttpClient + HttpRegistry`. Run `zig build test --summary all` — it must FAIL (stubbed functions return null/error, so the assertions fail). ✅ RED.

#### Step 2.1 — Write the impl (GREEN)

```zig
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    custom_headers: []const std.http.Header,
    /// Cached `custom_http_client.Client` — reuses libcurl's connection pool.
    /// NOT thread-safe; the `HttpRegistry` provides the mutex.
    client: std.http.Client,
    /// Lazily-initialised on first use. The single global `std.Io.Threaded`
    /// instance is created by `HttpRegistry.global()` and torn down by
    /// `deinitGlobal()` — mirrors the stdio plan's pattern.
    io: std.Io,

    const Self = @This();

    pub fn init(parent_allocator: std.mem.Allocator, io: std.Io, url: []const u8, custom_headers: []const std.http.Header) !Self {
        return .{
            .allocator = parent_allocator,
            .url = try parent_allocator.dupe(u8, url),
            .custom_headers = custom_headers, // borrowed — owned by the parent map (config or registry)
            .client = std.http.Client{ .allocator = parent_allocator },
            .io = io,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.url);
        // self.client has no deinit in this Zig 0.16 version (the .allocator field
        // is just a borrowed pointer). If a future version adds one, call it here.
    }

    /// Send a `tools/call` request and return the final JSON-RPC response body
    /// (the full JSON object as a freshly-allocated slice, NOT just the
    /// extracted text — the caller decides how to parse it).
    pub fn callTool(self: *Self, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
        // 1. Build the JSON-RPC body: {"jsonrpc":"2.0","id":"1","method":"tools/call","params":{"name":<tool_name>,"arguments":<arguments_json>,"_meta":{"io.modelcontextprotocol/protocolVersion":<PROTOCOL_VERSION>}}}
        //    (The _meta field is the spec-mandated mirror of the MCP-Protocol-Version header.)
        const body = try std.fmt.allocPrint(self.allocator,
            \\{{"jsonrpc":"2.0","id":"1","method":"tools/call","params":{{"name":"{s}","arguments":{s},"_meta":{{"io.modelcontextprotocol/protocolVersion":"{s}"}}}}}}
        , .{ tool_name, arguments_json, PROTOCOL_VERSION });
        defer self.allocator.free(body);

        // 2. Build headers via buildMcpHeaders (Task 1).
        const headers = try buildMcpHeaders(self.allocator, "tools/call", tool_name, self.custom_headers);
        defer self.allocator.free(headers);

        // 3. POST. The response Content-Type determines JSON vs SSE.
        var response = std.http.Client.post(self.client, self.url, .{
            .headers = headers,
            .response_storage = .{ .dynamic = ... }, // see step 3a
        });
        // ... dispatch on response.headers.content_type ...
    }
};
```

**Step 3a (response handling)** — dispatch on `response.headers.content_type`:

- If `text/event-stream`: call `self.client.openStream(url, .{...})`, get a `ResponseStream`, wrap in `StreamScanner`, walk events until null, return the LAST event's `data` as the JSON-RPC body.
- If `application/json`: read the full body (existing `post()` path works), parse as JSON-RPC, return.
- Anything else: `error.ServerReturnedError`.

**Step 3b (status code handling)** — checked BEFORE content-type dispatch:

- `200`: proceed.
- `202`: empty body (notification accepted); return a synthetic `{"jsonrpc":"2.0","id":null,"result":null}` so callers don't crash on a null body. (We don't actually send notifications in v1, so this branch is defensive.)
- `400`: parse the body as a JSON-RPC error. If `code == -32001` (HeaderMismatch) → `error.ServerHeaderMismatch`. If `code == -32002` (UnsupportedProtocolVersion) → `error.UnsupportedProtocolVersion`. Else → `error.ServerReturnedError` with the body.
- `404`: `error.ServerMethodNotFound`.
- Other 4xx/5xx: `error.ServerReturnedError` with the body.

#### Step 2.2 — Write `HttpRegistry`

```zig
pub const HttpRegistry = struct {
    arena: std.heap.ArenaAllocator,
    /// Optional owned `std.Io.Threaded` (only set by the global registry).
    threaded: ?*std.Io.Threaded = null,
    /// `HttpClient` per server name. Keys are duped into the arena.
    entries: std.StringHashMap(*HttpClient),
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(parent_allocator: std.mem.Allocator, io: std.Io) HttpRegistry { ... }
    fn initThreaded(parent_allocator: std.mem.Allocator) !HttpRegistry { ... }
    pub fn getOrConnect(self: *HttpRegistry, name: []const u8, url: []const u8, custom_headers: []const std.http.Header) !*HttpClient { ... }
    pub fn deinit(self: *HttpRegistry) void { ... }

    // Process-global singleton — same pattern as StdioRegistry.global().
    var global_registry: ?HttpRegistry = null;
    var global_init_mutex: std.atomic.Mutex = .unlocked;
    pub fn global(allocator: std.mem.Allocator) *HttpRegistry { ... }
    pub fn deinitGlobal() void { ... }
};
```

The `global()` creates its own `std.Io.Threaded` (like `mcp_stdio.StdioRegistry.global()` does), so the per-call sites (`handle_mcp_tool.zig`, `prompts_build_messages_for_agent_prompt.zig`) don't have to plumb an `io` parameter through. The `deinitGlobal()` is called from the main.zig shutdown hook.

#### Step 2.3 — Write `ListTools` (sibling helper, used by `buildMCPToolsRun`)

```zig
/// Send a `tools/list` request and return the array of `McpTool` from
/// the response. Allocates each `McpTool` from `allocator`; the caller
/// owns the returned slice AND each tool's owned strings (free with
/// `freeToolList`).
pub fn listTools(allocator: std.mem.Allocator, client: *HttpClient) ![]mcp_types.McpTool {
    const body = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":"1","method":"tools/list","_meta":{{"io.modelcontextprotocol/protocolVersion":"{s}"}}}}
    , .{PROTOCOL_VERSION});
    defer allocator.free(body);
    const headers = try buildMcpHeaders(allocator, "tools/list", "", client.custom_headers);
    defer allocator.free(headers);
    const response_body = try client.postRaw(body, headers);
    // ... parse response_body as JSON, walk to result.tools[], build []McpTool ...
}
```

#### Step 2.4 — Re-export from `src/root.zig`

Add:
```zig
pub const mcp_http = @import("modules/agent/mcp/mcp/mcp_http.zig");
```

Next to the existing `pub const mcp_stdio = @import(...)` on line 514.

#### Step 2.5 — Refactor + verify

```bash
cd /home/ginwa/ginwaaitoolbox
zig build test --summary all
```

**Expected**: Task 2's 6 new tests pass; total 2850/2850 pass.

---

### Task 3 — `mcp_http.zig` (cont): `HttpClient` + `HttpRegistry` + `ListTools` (TDD: red → green)

**Why:** Today `handle_mcp_tool.zig:96-234` is a single fat function that handles both URL parsing, header building, POSTing, and response parsing. We extract the URL/headers/server-config lookup into a thin helper, and the HTTP-specific path delegates to `mcp_http.HttpRegistry`. The stdio path stays exactly as it is (line 89 → `callViaStdio`). Net effect: `handle_mcp_tool.zig` becomes a dispatcher that calls either `mcp_stdio.StdioRegistry` or `mcp_http.HttpRegistry` — symmetric, no duplication, and the spec-compliance logic lives in one tested place.

**Files:**
- `src/ai_workflow/tui/agentic_loop/handle_mcp_tool.zig` (EDIT — refactor the HTTP branch to use `mcp_http.HttpRegistry.getOrConnect` + `callTool`; keep the stdio branch unchanged)
- `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig` (EDIT — same refactor for `buildMCPToolsRun`'s HTTP path)
- `src/main.zig` (EDIT — add `mcp_http.HttpRegistry.deinitGlobal()` to the shutdown hook alongside the existing `mcp_stdio.StdioRegistry.deinitGlobal()`)

#### Step 3.1 — Surgical refactor of `handle_mcp_tool.zig`

The existing HTTP path (lines 96-234) does:
1. Build the request body (line 99, via `buildToolCallRequestBody`).
2. Build the headers StringHashMap (line 105-127).
3. Flatten to a `[]const Header` slice (line 137-148).
4. POST (line 150-160).
5. Strip `data:` prefix (line 172-174).
6. Parse JSON, extract `result.content[0].text` (line 180-218).
7. Free intermediates, return text.

The refactored version replaces steps 2-6 with:
```zig
// (After the stdio-vs-http dispatch at line 89.)
const reg = mcp_http.HttpRegistry.global(allocator);
const client = reg.getOrConnect(server_name, url, header_slice) catch |err| { ... };
return client.callTool(actual_tool_name, tool_call.function.arguments) catch |err| { ... };
```

`callTool` returns the full JSON-RPC response body (or `error.*` for failures). The caller then runs the SAME JSON-extraction logic as today (the regex at line 180-218) to pull out `result.content[0].text`. We KEEP that extraction logic in `handle_mcp_tool.zig` because it's the function's contract — it returns the text content to the agent loop, not the raw JSON-RPC.

**Why the extraction stays**: `handle_mcp_tool_run` is the function that the agentic loop calls when an LLM emits an `mcp_*` tool call. Its return type is `[]const u8` (the text content the model sees). The new `mcp_http.HttpClient.callTool` returns the raw JSON-RPC (more reusable). The 4-line JSON extraction at line 180-218 is fine where it is.

#### Step 3.2 — Same refactor for `prompts_build_messages_for_agent_prompt.zig`'s `buildMCPToolsRun`

Today the HTTP path is at `prompts_build_messages_for_agent_prompt.zig:391 buildMCPToolsRun` → `fetchToolsFromServer`. The stdio sibling (`listToolsViaStdio` from the previous plan) was added. We add `listToolsViaHttp` that uses `mcp_http.HttpRegistry.getOrConnect` + `mcp_http.listTools`. The existing 200-line `fetchToolsFromServer` body shrinks to 10 lines (it's a typo-prone URL parser, header builder, JSON walker — all of which we now inherit from the tested `mcp_http` module).

#### Step 3.3 — Shutdown hook in `main.zig`

Add `mcp_http.HttpRegistry.deinitGlobal()` next to the existing `mcp_stdio.StdioRegistry.deinitGlobal()`. Order doesn't matter (they own disjoint resources).

#### Step 3.4 — Verify

```bash
cd /home/ginwa/ginwaaitoolbox
zig build test --summary all
```

**Expected**: existing 2850/2850 pass + 0 regressions (we didn't add tests in Task 3, just refactored existing code paths; the existing tests on `handle_mcp_tool.zig:363 buildToolCallRequestBody` still pass).

---

### Task 4 — Refactor `handle_mcp_tool.zig` to dispatch through the new HTTP client

**Why:** Today `handle_mcp_tool.zig:96-234` is a single fat function that handles both URL parsing, header building, POSTing, and response parsing. We extract the URL/headers/server-config lookup into a thin helper, and the HTTP-specific path delegates to `mcp_http.HttpRegistry`. The stdio path stays exactly as it is (line 89 → `callViaStdio`). Net effect: `handle_mcp_tool.zig` becomes a dispatcher that calls either `mcp_stdio.StdioRegistry` or `mcp_http.HttpRegistry` — symmetric, no duplication, and the spec-compliance logic lives in one tested place.

**This task has no new code paths and no new tests** — it's a refactor of the existing `handle_mcp_tool.zig` HTTP branch to delegate to the new `mcp_http` module. The behavioural tests at the bottom of `handle_mcp_tool.zig` (line 363: `buildToolCallRequestBody: emits jsonrpc tools/call envelope` + the empty-arguments test) still pass after the refactor — they exercise the shared request-body builder, not the dispatch.

**Files:**
- `src/ai_workflow/tui/agentic_loop/handle_mcp_tool.zig` (EDIT — refactor the HTTP branch to use `mcp_http.HttpRegistry.getOrConnect` + `callTool`; keep the stdio branch unchanged)
- `src/ai_workflow/tui/agentic_loop/prompts_build_messages_for_agent_prompt.zig` (EDIT — same refactor for `buildMCPToolsRun`'s HTTP path)
- `src/root.zig` (EDIT — re-export `mcp_http` module)
- `src/main.zig` (EDIT — add `mcp_http.HttpRegistry.deinitGlobal()` to the shutdown hook alongside the existing `mcp_stdio.StdioRegistry.deinitGlobal()`)

#### Step 4.1 — Surgical refactor of `handle_mcp_tool.zig`

The existing HTTP path (lines 96-234) does:
1. Build the request body (line 99, via `buildToolCallRequestBody`).
2. Build the headers StringHashMap (line 105-127).
3. Flatten to a `[]const Header` slice (line 137-148).
4. POST (line 150-160).
5. Strip `data:` prefix (line 172-174).
6. Parse JSON, extract `result.content[0].text` (line 180-218).
7. Free intermediates, return text.

The refactored version replaces steps 2-6 with:
```zig
// (After the stdio-vs-http dispatch at line 89.)
const reg = mcp_http.HttpRegistry.global(allocator);
const client = reg.getOrConnect(server_name, url, header_slice) catch |err| { ... };
return client.callTool(actual_tool_name, tool_call.function.arguments) catch |err| { ... };
```

`callTool` returns the full JSON-RPC response body (or `error.*` for failures). The caller then runs the SAME JSON-extraction logic as today (the regex at line 180-218) to pull out `result.content[0].text`. We KEEP that extraction logic in `handle_mcp_tool.zig` because it's the function's contract — it returns the text content to the agent loop, not the raw JSON-RPC.

**Why the extraction stays**: `handle_mcp_tool_run` is the function that the agentic loop calls when an LLM emits an `mcp_*` tool call. Its return type is `[]const u8` (the text content the model sees). The new `mcp_http.HttpClient.callTool` returns the raw JSON-RPC (more reusable). The 4-line JSON extraction at line 180-218 is fine where it is.

#### Step 4.2 — Same refactor for `prompts_build_messages_for_agent_prompt.zig`'s `buildMCPToolsRun`

Today the HTTP path is at `prompts_build_messages_for_agent_prompt.zig:391 buildMCPToolsRun` → `fetchToolsFromServer`. The stdio sibling (`listToolsViaStdio` from the previous plan) was added. We add `listToolsViaHttp` that uses `mcp_http.HttpRegistry.getOrConnect` + `mcp_http.listTools`. The existing 200-line `fetchToolsFromServer` body shrinks to 10 lines (it's a typo-prone URL parser, header builder, JSON walker — all of which we now inherit from the tested `mcp_http` module).

#### Step 4.3 — `root.zig` re-export

Add `pub const mcp_http = @import("modules/agent/mcp/mcp/mcp_http.zig");` next to the existing `pub const mcp_stdio = @import(...)` on line 514.

#### Step 4.4 — Shutdown hook in `main.zig`

Add `mcp_http.HttpRegistry.deinitGlobal()` next to the existing `mcp_stdio.StdioRegistry.deinitGlobal()`. Order doesn't matter (they own disjoint resources).

#### Step 4.5 — Verify

```bash
cd /home/ginwa/ginwaaitoolbox
zig build test --summary all
```

**Expected**: existing 2850/2850 pass + 0 regressions (we didn't add tests in Task 4, just refactored existing code paths; the existing tests on `handle_mcp_tool.zig:363 buildToolCallRequestBody` still pass).

---

### Task 5 — Functional test: end-to-end agent → HTTP MCP (TDD: red → green)

**Why:** Static-contract tests prove the SSE parser + header builder + status-code handling are correct, but the agent's actual end-to-end behaviour (LLM emits `mcp_hello_print_hello`, the dispatcher routes to `mcp_http.HttpRegistry`, the POST hits a real spec-compliant server, the response is parsed, the text is shown to the LLM) needs a functional test with the real `nalar` binary + the real `mcp-http-hello-world` fixture.

**TDD order**: write the functional test FIRST (Task 5.2 below), run it against a nalar that already uses the new `mcp_http` module — watch it PASS. If the test fails, the bug is in `mcp_http` (Tasks 2-3) or the dispatcher (Task 4). The test is the spec contract: if it passes, the client is spec-compliant against a real SDK server.

**Files:**
- `tests/functional/harness.py` (EDIT — add `mcp_http_hello_world_bin()` helper that resolves the new sibling binary path; mirrors the existing `mcp_hello_world_bin()` helper)
- `tests/functional/mcp_http_test.py` (NEW — the E2E test)

#### Step 5.1 — Write the harness helper

Add to `tests/functional/harness.py`:

```python
def mcp_http_hello_world_bin() -> Path:
    """Locate the mcp-http-hello-world wrapper produced by `zig build mcp-http-hello-world`.

    Mirrors `mcp_hello_world_bin()` for the stdio binary. Raises skip if
    the binary isn't built; tests wrap that as `pytest.skip` so the
    functional test suite can run before the build step.
    """
    if env := os.environ.get("NALAR_MCP_HTTP_HELLO_WORLD_BIN"):
        p = Path(env)
        if p.is_file(): return p
    nalar_bin = os.environ.get("NALAR_BIN", "")
    if nalar_bin:
        sibling = Path(nalar_bin).parent / "mcp-http-hello-world-linux-x86_64"
        if sibling.is_file(): return sibling
    raise FileNotFoundError(
        "mcp-http-hello-world not found; run `zig build mcp-http-hello-world` "
        "or set $NALAR_MCP_HTTP_HELLO_WORLD_BIN."
    )
```

#### Step 5.2 — Write the functional tests FIRST (RED)

Create `tests/functional/mcp_http_test.py` mirroring the stdio test (`tests/functional/mcp_stdio_test.py`) but for HTTP. The 2 tests:

```python
def test_http_mcp_server_url_round_trips(harness):
    """Boot nalar, configure mcp_servers with a url pointing at a live
    mcp-http-hello-world server, fetch the config back, assert the url
    round-trips through PUT → on-disk JSON → GET."""
    port = harness.get_free_port()  # avoid 8081
    proc = spawn_mcp_http_hello_world(port)
    try:
        url = f"http://127.0.0.1:{port}/mcp"
        ws = harness.create_workspace()
        # PUT a config with mcp_servers.http_test = { url }
        harness.put_nalar_config(ws, {"mcp_servers": {"http_test": {"url": url}}})
        # GET the config back, assert url is intact
        cfg = harness.get_nalar_config(ws)
        assert cfg["mcp_servers"]["http_test"]["url"] == url
    finally:
        proc.terminate()
        proc.wait(timeout=5)


def test_http_mcp_tools_call_roundtrip(harness):
    """The wire path: spawn the HTTP server, configure nalar with a
    url, call a tool, assert the response matches what the SDK server
    would return. This is the spec-compliance smoke test."""
    port = harness.get_free_port()
    proc = spawn_mcp_http_hello_world(port)
    try:
        url = f"http://127.0.0.1:{port}/mcp"
        ws = harness.create_workspace()
        # Stub LLM profile so we don't need a real LLM call.
        harness.put_nalar_config(ws, {
            "mcp_servers": {"http_test": {"url": url}},
            "stub_llm": True,
        })
        # POST a tools/list and assert the 3 tools are listed.
        tools = harness.call_mcp_tool(ws, "http_test", "tools/list", {})
        assert {t["name"] for t in tools} == {"print_hello", "print_name", "print_exit"}
        # POST a tools/call and assert the response.
        result = harness.call_mcp_tool(ws, "http_test", "tools/call", {
            "name": "print_hello",
            "arguments": {"name": "world"},
        })
        assert result["content"][0]["text"] == "Hello world"
    finally:
        proc.terminate()
        proc.wait(timeout=5)
```

`spawn_mcp_http_hello_world(port)` is a module-level helper that wraps `mcp_http_hello_world_bin()` + the `Popen` + the "listening on" stderr-line wait (same pattern as `_send_jsonrpc` in the stdio test).

**TDD commit**: commit the test file. Run `NALAR_BIN=... pytest tests/functional/mcp_http_test.py -v` — it must FAIL (the agent's HTTP path doesn't yet emit the spec headers, so the SDK server's `MCP-Protocol-Version` validation rejects the request). ✅ RED.

#### Step 5.3 — Run the functional test

By the time this task lands, Tasks 1-3 (test fixture, helpers, client) and Task 4 (dispatcher refactor) are all already in place. The functional test is the spec contract — if it passes, the end-to-end wire is spec-compliant against a real SDK server.

```bash
cd /home/ginwa/ginwaaitoolbox
NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 \
  python3 -m pytest tests/functional/mcp_http_test.py -v
```

**Expected**: 2 tests pass. The test exercises the real wire: a real HTTP server (Node + SDK), a real `nalar` binary, a real Zig HTTP client doing SSE parsing + spec-compliant headers. ✅ GREEN.

If either test fails:
- `test_http_mcp_server_url_round_trips` failing → the config PUT/GET path doesn't carry the URL through correctly. Check `parseMcpServerConfig` + the round-trip in `nalar_config_put.zig`.
- `test_http_mcp_tools_call_roundtrip` failing → the HTTP client isn't spec-compliant against the SDK server. Check the headers (Task 2's `buildMcpHeaders`) and the response parsing (Task 3's `HttpClient.callTool` for SSE vs JSON). Use `zig build test --summary all` to see which Zig-level test fails.

#### Step 5.4 — Run the full test suite to confirm no regressions

```bash
cd /home/ginwa/ginwaaitoolbox
zig build test --summary all
zig build nalar-desktop --summary all  # ensures the wire-up compiles
NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 \
  python3 -m pytest tests/functional/ -v  # all functional tests, not just the new one
```

**Expected**:
- Zig: 2856/2856 pass (2832 baseline + 12 SSE/header tests + 6 HttpClient/Registry tests = 2850; we add a few more in Task 5.4 for shutdown ordering → ~2856).
- Desktop build: 10/10 steps succeed.
- Functional: all 246/246 pass (244 baseline + 2 new HTTP tests).

---

### Task 6 — Changelog + final pass

**Why:** NALAR.md is the project-level changelog. Every merged plan adds an entry. This task is the "ship it" task.

**Files:**
- `NALAR.md` (EDIT — append a "### 2026-08-28: MCP Streamable HTTP transport" entry mirroring the structure of the "2026-08-27: MCP stdio transport" entry that's already in the file)

The changelog entry is a 30-line summary in the same format as the stdio entry. It should mention:
- What landed (HttpClient + SSE parser + spec-compliant headers).
- The spec revision we target (2026-07-28).
- The test fixture (`mcp-http-hello-world`).
- File count.
- Test totals.
- Plan path + branch.

#### Step 6.1 — Final verification

```bash
cd /home/ginwa/ginwaaitoolbox
zig build test --summary all
zig build nalar-desktop --summary all
NPM_CONFIG_LOGLEVEL=error npm run test:unit  # frontend unaffected; just confirming
NALAR_BIN=$(pwd)/zig-out/bin/nalarcore-linux-x86_64 \
  python3 -m pytest tests/functional/ -v
```

**Expected**: all green. If anything is red, escalate — don't ship a half-working transport.

#### Step 6.2 — Open a PR

Per the kanban convention: `git push origin worktree/mcp-streamable-http` → open a PR on GitHub with the plan link in the description.

#### Step 6.3 — Move the kanban card to `in_review_task`

The user reviews the PR; once approved, they (or the merge) move the card to `merged`. The agent does NOT do this — per the kanban convention "also only human put the task here".

---

## What we're NOT doing (out of scope)

- **Backward compat with pre-2026-07-28 servers** (no `Mcp-Session-Id`, no `GET` stream). If the user needs to talk to a server that requires the old shape, that's a v2.
- **Long-lived `subscriptions/listen` SSE stream** for server-pushed change notifications. The spec lists it as a v1 MAY; we skip it. A v2 can add it behind a feature flag.
- **MRTR (Multi Round-Trip Requests, SEP-2322)** — the spec says server-to-client interactions (sampling, elicitation, roots) are embedded as `InputRequiredResult` with `inputRequests` rather than as separate server-initiated requests. We do NOT implement the client side of MRTR (we don't yet have any tools that need sampling/elicitation/roots). A v2 will need to when real servers start using MRTR.
- **Base64 sentinel encoding for non-ASCII `Mcp-Name` values** — the spec describes a Base64-sentinel format for non-ASCII tool names. We fall back to omitting the header (the JSON body still carries the name). Full Base64 encoding is a v2.
- **Frontend changes** — the user-facing config shape is unchanged. The `McpServer` Vue type and `McpServerModal` already accept `url` + `headers`. Spec-compliance is a wire concern invisible to the user.
- **Origin header validation / DNS-rebinding protection** — server-side concerns, not relevant for a client.
- **Custom headers from tool parameters (SEP-974)** — server-defined extension; not in v1.
- **A separate `mcp-http-hello-world` binary** — per the user's "create a mcp-http-hello-world to testing using mcp http" directive, this is a sibling binary to the existing `mcp-hello-world`, not a `--http` flag on the stdio binary. One binary per transport (D10).

---

## Verification summary

| Layer | Test | Expected |
| --- | --- | --- |
| Unit (Zig) | `zig build test --summary all` | 2856/2856 pass |
| Build | `zig build nalar-desktop --summary all` | 10/10 steps succeed |
| Build | `zig build mcp-hello-world --summary all` | existing stdio binary rebuilt (no changes here) |
| Build | `zig build mcp-http-hello-world --summary all` | new HTTP binary built and installed in `zig-out/bin/` |
| Test fixture | `npm test` (in `src/apps/mcp_hello_world`) | 3 stdio + 1 http = 4 tests pass |
| Functional (Python) | `pytest tests/functional/mcp_http_test.py -v` | 2 tests pass |
| Functional (Python) | `pytest tests/functional/ -v` | 246/246 pass (no regressions) |
| Frontend | `npm run test:unit` | unchanged from baseline (no frontend changes) |

If any of these fail, the implementation is incomplete. Don't ship a transport that fails its own tests.
