//! Tests for the mcp-http-hello-world test MCP server.
//!
//! TDD: this file was written BEFORE `index.ts` (the impl). The first
//! `npm test` run failed RED — vitest ran the test, the test called
//! `spawn("node", ["dist/index.js", ...])`, and the spawn failed with
//! ENOENT because `dist/index.js` didn't exist (the impl + tsc compile
//! hadn't happened yet). The second run after landing `index.ts` +
//! `npm run build` passes GREEN.
//!
//! The wire test exercises the FULL MCP Streamable HTTP roundtrip:
//!   1. Spawn the compiled binary on a free port.
//!   2. Wait for the "listening on" stderr line (proves the server bound).
//!   3. POST a `tools/list` JSON-RPC request to `/mcp` and assert the
//!      response contains the 3 registered tools.
//!   4. POST a `tools/call` for `print_hello` with `{"name": "world"}`
//!      and assert the response text is `"Hello world"`.
//!   5. POST a `tools/call` for `print_name` and assert the response
//!      text identifies this server.
//!   6. Kill the subprocess (always, even on assertion failure).
//!
//! This is a single test (not six) because the test is about the wire
//! — once the binary is up, the JSON-RPC roundtrip is one logical
//! operation. Splitting into per-method tests would just add spawn
//! overhead without giving us any extra coverage at the transport
//! layer.
//!
//! The end-to-end test through a real pabrik HTTP client lives at
//! `tests/functional/mcp_http_test.py` — that one boots a real pabrik
//! binary, configures an `mcp_servers.url` pointing at this server,
//! and asserts the agent's spec-compliant client can talk to it. This
//! vitest test is the server-side smoke test; the python test is the
//! client-side spec-compliance smoke test.

import { describe, it, expect, afterEach } from "vitest";
import { spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:net";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BINARY_PATH = resolve(__dirname, "dist/index.js");

/** Find a free TCP port by binding to port 0, reading the assigned port,
 * then releasing the socket. Returns the port number. */
async function getFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.unref(); // don't keep the test process alive
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (addr === null || typeof addr === "string") {
        server.close();
        reject(new Error("getFreePort: could not determine assigned port"));
        return;
      }
      const port = addr.port;
      server.close(() => resolve(port));
    });
  });
}

/** Spawn the binary, return when it prints `listening on` to stderr.
 * Throws on timeout or spawn failure.
 *
 * Default readiness is generous (15s): under `zig build` this test runs
 * while the box is saturated (zig compiling pabrik.exe + parallel pnpm
 * installs), and cold node + MCP-SDK import can take several seconds
 * when CPU-starved — 5s flaked in CI with an alive-but-silent process
 * and empty stderr (i.e. still starting, not crashed). */
async function spawnAndWaitForReady(port: number, timeoutMs = 15000): Promise<ChildProcess> {
  const proc = spawn("node", [BINARY_PATH, String(port)], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const stderrBuf: Buffer[] = [];
  proc.stderr?.on("data", (c: Buffer) => {
    stderrBuf.push(c);
    if (Buffer.concat(stderrBuf).toString("utf8").includes("listening on")) {
      // resolved below
    }
  });

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      proc.kill("SIGKILL");
      reject(new Error(
        `mcp-http-hello-world did not print 'listening on' within ${timeoutMs}ms\n` +
        `stderr so far:\n${Buffer.concat(stderrBuf).toString("utf8")}`,
      ));
    }, timeoutMs);

    const onData = (c: Buffer) => {
      stderrBuf.push(c);
      const all = Buffer.concat(stderrBuf).toString("utf8");
      if (all.includes("listening on")) {
        clearTimeout(timer);
        proc.stderr?.off("data", onData);
        resolve(proc);
      }
    };
    proc.stderr?.on("data", onData);

    proc.on("error", (err) => {
      clearTimeout(timer);
      reject(new Error(
        `mcp-http-hello-world spawn failed: ${err.message}\n` +
        `Did you run \`npm run build\`? Expected binary at ${BINARY_PATH}.`,
      ));
    });

    proc.on("exit", (code) => {
      if (code !== 0 && code !== null) {
        clearTimeout(timer);
        reject(new Error(
          `mcp-http-hello-world exited early with code ${code}\n` +
          `stderr:\n${Buffer.concat(stderrBuf).toString("utf8")}`,
        ));
      }
    });
  });
}

/** Send a JSON-RPC request via HTTP POST to the test server, return the
 * parsed JSON response. Handles BOTH response shapes per the Streamable
 * HTTP spec: `application/json` (single JSON object) and
 * `text/event-stream` (SSE stream — last `data:` event carries the
 * final JSON-RPC response).
 *
 * The SSE parsing is a small subset of the spec — we read events
 * separated by `\n\n`, take the `data:` field, concatenate multi-`data:`
 * lines with `\n`, and use the LAST event's data as the final response.
 * This is the same logic the pabrik Zig client will implement in
 * mcp_http.zig's SseEvent parser (Task 2 of the plan). */
async function jsonRpcRequest(
  baseUrl: string,
  body: unknown,
): Promise<{ status: number; json: any; contentType: string }> {
  const payload = JSON.stringify(body);
  const res = await fetch(`${baseUrl}/mcp`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json, text/event-stream",
      // MCP Streamable HTTP spec requires MCP-Protocol-Version on every
      // POST. The server (the SDK with strict spec compliance) returns
      // 400 Bad Request without it. We send it as a real spec-compliant
      // client would. We target revision 2025-11-25 (the latest
      // supported by @modelcontextprotocol/sdk v1.30.0 — the 2026-07-28
      // revision is not yet implemented by the SDK or any other client
      // in the ecosystem; this is the most recent spec the wire
      // actually exercises today).
      "MCP-Protocol-Version": "2025-11-25",
    },
    body: payload,
  });
  const contentType = res.headers.get("content-type") ?? "";
  const text = await res.text();

  if (contentType.startsWith("application/json")) {
    try {
      return { status: res.status, json: JSON.parse(text), contentType };
    } catch {
      throw new Error(
        `non-JSON body (status ${res.status}, content-type ${contentType}): ${text.slice(0, 500)}`,
      );
    }
  }

  if (contentType.startsWith("text/event-stream")) {
    // Parse the SSE stream. Events are separated by `\n\n`. Each event
    // is a sequence of `field: value` lines. Multi-`data:` lines are
    // concatenated with `\n`. The final JSON-RPC response is the LAST
    // event's `data:` field per the spec ("The final JSON-RPC response
    // SHOULD terminate the stream").
    const events = text.split("\n\n");
    let lastData: string | null = null;
    for (const rawEvent of events) {
      if (rawEvent.trim() === "") continue;
      const dataLines: string[] = [];
      for (const line of rawEvent.split("\n")) {
        if (line.startsWith(":")) continue; // SSE comment, ignore
        if (line.startsWith("data:")) {
          // Per SSE spec: value is everything after the first ':' minus
          // a single leading space (if present).
          let value = line.slice("data:".length);
          if (value.startsWith(" ")) value = value.slice(1);
          dataLines.push(value);
        }
        // ignore other fields (event:, id:, retry:) — we don't use them
      }
      if (dataLines.length > 0) {
        lastData = dataLines.join("\n");
      }
    }
    if (lastData === null) {
      throw new Error(
        `SSE stream with no data: events (status ${res.status}): ${text.slice(0, 500)}`,
      );
    }
    try {
      return { status: res.status, json: JSON.parse(lastData), contentType };
    } catch {
      throw new Error(
        `non-JSON SSE data (status ${res.status}): ${lastData.slice(0, 500)}`,
      );
    }
  }

  throw new Error(
    `unexpected content-type (status ${res.status}): ${contentType}\nbody: ${text.slice(0, 500)}`,
  );
}

describe("mcp-http-hello-world wire roundtrip", () => {
  let proc: ChildProcess | null = null;

  afterEach(() => {
    if (proc && proc.exitCode === null) {
      proc.kill("SIGKILL");
    }
    proc = null;
  });

  it("tools/list returns 3 tools, tools/call print_hello returns 'Hello world', tools/call print_name returns server identity", async () => {
    // Fail fast if the binary hasn't been built yet. TDD discipline: the
    // test is a contract; the build must produce the binary before the
    // test can pass. The zig build chain (build.zig) runs
    // `npm install` → `npm test` → `npm run build`, but we test this
    // file directly via `npm test` (TDD red/green) and want a real
    // failure when the impl hasn't been built.
    try {
      readFileSync(BINARY_PATH);
    } catch {
      throw new Error(
        `mcp-http-hello-world binary not found at ${BINARY_PATH}. ` +
        `Run \`npm run build\` (or \`zig build mcp-http-hello-world\`) first.`,
      );
    }

    const port = await getFreePort();
    proc = await spawnAndWaitForReady(port);
    const baseUrl = `http://127.0.0.1:${port}`;

    // 1. tools/list — assert all 3 tools are advertised.
    const list = await jsonRpcRequest(baseUrl, {
      jsonrpc: "2.0",
      id: "1",
      method: "tools/list",
      params: {},
    });
    expect(list.status).toBe(200);
    expect(list.json.jsonrpc).toBe("2.0");
    expect(list.json.id).toBe("1");
    const toolNames: string[] = (list.json.result?.tools ?? []).map(
      (t: any) => t.name,
    );
    expect(toolNames.sort()).toEqual(
      ["print_exit", "print_hello", "print_name"],
    );

    // 2. tools/call print_hello with name="world" — assert text content.
    const hello = await jsonRpcRequest(baseUrl, {
      jsonrpc: "2.0",
      id: "2",
      method: "tools/call",
      params: { name: "print_hello", arguments: { name: "world" } },
    });
    expect(hello.status).toBe(200);
    expect(hello.json.id).toBe("2");
    const helloText = hello.json.result?.content?.[0]?.text;
    expect(helloText).toBe("Hello world");

    // 3. tools/call print_name — assert server identity.
    const name = await jsonRpcRequest(baseUrl, {
      jsonrpc: "2.0",
      id: "3",
      method: "tools/call",
      params: { name: "print_name", arguments: {} },
    });
    expect(name.status).toBe(200);
    const nameText = name.json.result?.content?.[0]?.text;
    expect(nameText).toBe("i am mcp-http-hello-world v0.0.1");
  }, 30000); // 30s timeout — covers slow spawn under zig-build load + 3 roundtrips
});
