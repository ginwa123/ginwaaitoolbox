//! mcp-http-hello-world — a tiny test MCP server.
//!
//! Self-test target for nalar's MCP Streamable HTTP client. Sibling of
//! `mcp-hello-world` (the stdio fixture) — same 3 tools, different
//! transport. Built from the same `@modelcontextprotocol/sdk` v1.30
//!
//! Tools registered (same shape as the stdio binary so the agent's
//! spec-compliance smoke test works for both transports):
//!   - print_hello(name?: string) -> "Hello {name || world}"
//!   - print_name() -> "i am mcp-http-hello-world v0.0.1"
//!   - print_exit() -> "exiting"  (no-op in HTTP — no process to exit,
//!     see the stdio binary's `process.exit` after flushing the response)

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import * as http from "node:http";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { z } from "zod";

const SERVER_NAME = "mcp-http-hello-world";
const SERVER_VERSION = "0.0.1";
const DEFAULT_PORT = 3000;

/** Parse + validate the port from process.argv. Exit(2) on bad input. */
function parsePort(): number {
  const raw = process.argv[2] ?? process.env.PORT ?? String(DEFAULT_PORT);
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error(
      `mcp-http-hello-world: invalid port: "${raw}" (expected integer 1..65535)`,
    );
    process.exit(2);
  }
  return port;
}

/** Build a fresh McpServer with the 3 hello-world tools. Used per-request
 * so the SDK's stateless transport pattern works (no shared mutable state
 * between requests). The tool handlers themselves are pure (no closure
 * over per-request state) so this is safe. */
function getServer(): McpServer {
  const mcp = new McpServer({ name: SERVER_NAME, version: SERVER_VERSION });
  mcp.tool(
    "print_hello",
    "Print a greeting. Optional argument `name` (string) — defaults to `world`.",
    { name: z.string().optional() },
    async (args: { name?: string }) => ({
      content: [{ type: "text", text: `Hello ${args?.name ?? "world"}` }],
    }),
  );
  mcp.tool(
    "print_name",
    "Print this server's name and version. Takes no arguments.",
    async () => ({
      content: [
        { type: "text", text: `i am ${SERVER_NAME} v${SERVER_VERSION}` },
      ],
    }),
  );
  mcp.tool(
    "print_exit",
    "Print a goodbye message. (No-op in HTTP mode — there's no child process to exit. The stdio binary's print_exit actually exits; the HTTP fixture just returns the same text.)",
    async () => ({ content: [{ type: "text", text: "exiting" }] }),
  );
  return mcp;
}

async function main(): Promise<void> {
  const port = parsePort();

  const server = http.createServer(async (req, res) => {
    try {
      // Per-request server + transport (stateless pattern, matches the
      // SDK's `examples/server/simpleStatelessStreamableHttp.js`). Each
      // request gets a fresh McpServer + StreamableHTTPServerTransport;
      // no session is shared between requests because 2026-07-28
      // stateless mode has no session at all.
      const mcp = getServer();
      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined, // 2026-07-28: no protocol-level session.
      });
      await mcp.connect(transport);
      // No pre-parsed body — let the SDK read the raw stream. Passing
      // a Buffer here confuses the SDK's JSON parser (it tries to
      // JSON.parse a Buffer and gets a "Parse error: Invalid JSON-RPC
      // message" 400 response).
      await transport.handleRequest(req, res);
      res.on("close", () => {
        transport.close();
        mcp.close();
      });
    } catch (err) {
      // Spec says "the HTTP response body MAY comprise a JSON-RPC error
      // response that has no id" when something blows up.
      console.error(
        `mcp-http-hello-world: handleRequest error: ${err instanceof Error ? err.message : String(err)}`,
      );
      if (!res.headersSent) {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            jsonrpc: "2.0",
            id: null,
            error: { code: -32603, message: "Internal server error" },
          }),
        );
      }
    }
  });

  // Spec: "When running locally, servers SHOULD bind only to localhost".
  // Production servers may bind 0.0.0.0; the test fixture stays on 127.0.0.1.
  server.listen(port, "127.0.0.1", () => {
    // Stderr line that the functional test + vitest both wait for.
    console.error(
      `mcp-http-hello-world listening on http://127.0.0.1:${port}/mcp`,
    );
  });

  // Graceful shutdown.
  const shutdown = (sig: string) => {
    console.error(`mcp-http-hello-world: ${sig} received, closing server`);
    server.close(() => process.exit(0));
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

/** True only when this file is the process entry point.
 *
 * A listening server has no business starting just because something imported
 * this module, and that hazard is not hypothetical: Node resolves an
 * unresolvable bare specifier against the nearest package's `main`, so vite's
 * optional-dependency probe `require("fsevents")` landed here, ran main() under
 * vitest's own argv, and died with `invalid port: "run"` before vitest printed
 * its banner. Gating on the entry point makes the module inert for every
 * importer rather than only the one that tripped over it.
 *
 * realpathSync on both sides because the zig wrapper invokes us through a
 * `bin/../../src/...` argv[1] and Node resolves symlinks when it loads us. */
function isEntryPoint(): boolean {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  main().catch((err) => {
    console.error(
      `mcp-http-hello-world: fatal: ${err instanceof Error ? err.stack : String(err)}`,
    );
    process.exit(1);
  });
}
