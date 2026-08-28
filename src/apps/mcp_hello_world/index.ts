//! mcp-hello-world — a tiny test MCP server.
//!
//! Self-test target for nalar's MCP stdio transport. Uses the
//! canonical `@modelcontextprotocol/sdk` (TypeScript) because the
//! majority of real-world MCP servers are written in TS.
//!
//! Registers 3 tools that exercise different parts of the stdio
//! pipeline: print_hello (basic request/response), print_name
//! (server identity), print_exit (process exit for cleanup tests).

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

export const SERVER_NAME = "mcp-hello-world";
export const SERVER_VERSION = "0.0.1";

/** Result of a single tool call. */
export interface ToolResult {
  text: string;
}

/** Public surface for unit testing. */
export interface HelloWorldServer {
  handleToolCall(name: string, args: Record<string, unknown>): ToolResult;
  listTools(): Array<{ name: string; description: string }>;
}

/**
 * Pure factory: returns the tool handlers. NOT wired to the MCP
 * transport — that's `start()` below. Tests exercise the handlers
 * directly without spawning a child process.
 */
export function createHelloWorldServer(): HelloWorldServer {
  const tools = [
    {
      name: "print_hello",
      description:
        "Print a greeting. Optional argument `name` (string) — defaults to `world`.",
      handle: (args: Record<string, unknown>): ToolResult => {
        const raw = args.name;
        const target = typeof raw === "string" && raw.length > 0 ? raw : "world";
        return { text: `Hello ${target}` };
      },
    },
    {
      name: "print_name",
      description: "Print this server's name and version. Takes no arguments.",
      handle: (_args: Record<string, unknown>): ToolResult => ({
        text: `i am ${SERVER_NAME} v${SERVER_VERSION}`,
      }),
    },
    {
      name: "print_exit",
      description:
        "Print a goodbye message and exit the process (code 0). Used to verify child cleanup.",
      handle: (_args: Record<string, unknown>): ToolResult => {
        return { text: "exiting" };
      },
    },
  ];

  const byName = new Map(tools.map((t) => [t.name, t]));

  return {
    handleToolCall(name, args) {
      const tool = byName.get(name);
      if (!tool) {
        throw new Error(`Unknown tool: ${name}`);
      }
      return tool.handle(args);
    },
    listTools() {
      return tools.map((t) => ({ name: t.name, description: t.description }));
    },
  };
}

/** Type for the SDK's tool callback `extra` parameter. */
interface ToolExtra {
  request?: {
    params?: {
      name?: string;
      arguments?: Record<string, unknown>;
    };
  };
}

/** Top-level entry point: connect the MCP server to stdio and run forever. */
async function start(): Promise<void> {
  const handlers = createHelloWorldServer();
  const mcp = new McpServer({
    name: SERVER_NAME,
    version: SERVER_VERSION,
  });

  // Zod schema for print_hello's optional `name` argument. The SDK
  // validates incoming args against this schema and passes the
  // parsed object as the first arg to our callback. The other two
  // tools take no args and use an empty object schema.
  const helloSchema = {
    name: z.string().optional(),
  };

  for (const t of handlers.listTools()) {
    if (t.name === "print_hello") {
      mcp.tool(
        t.name,
        t.description,
        helloSchema,
        async (args: { name?: string }) => {
          const r = handlers.handleToolCall(t.name, args ?? {});
          return { content: [{ type: "text", text: r.text }] };
        },
      );
    } else {
      mcp.tool(
        t.name,
        t.description,
        async (extra: unknown) => {
          // No args; the SDK only invokes the callback with `extra` for
          // schemaless tools. We ignore `extra` and use our handler.
          const r = handlers.handleToolCall(t.name, {});
          if (t.name === "print_exit") {
            // Exit AFTER the response has been flushed. setImmediate
            // schedules the exit on the next event-loop tick — the
            // SDK writes the response synchronously to stdout before
            // our callback returns, so by the time setImmediate
            // fires, the JSON-RPC response is already in the kernel
            // buffer.
            setImmediate(() => process.exit(0));
          }
          return { content: [{ type: "text", text: r.text }] };
        },
      );
    }
  }

  const transport = new StdioServerTransport();
  await mcp.connect(transport);

  // Wait for stdin EOF / transport close. The SDK handles this
  // internally; awaiting a never-resolving promise keeps the event
  // loop alive.
  await new Promise<void>(() => {});
}

start().catch((err) => {
  console.error("mcp-hello-world: fatal:", err);
  process.exit(1);
});
