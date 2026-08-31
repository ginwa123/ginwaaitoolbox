//! Tests for the mcp-hello-world tool handlers.
//!
//! TDD: these tests were written BEFORE the implementation in
//! index.ts. The first run failed RED (handlers didn't exist);
//! the second run after adding the handlers passes GREEN.
//!
//! We test the tool HANDLERS in isolation (not the full MCP server)
//! so the tests are fast and don't require spawning a child process.
//! The binary's end-to-end roundtrip is covered by the functional
//! test at tests/functional/mcp_stdio_test.py.

import { describe, it, expect } from "vitest";
import { createHelloWorldServer } from "./index.js";

describe("mcp-hello-world tool handlers", () => {
  it("print_hello with no name returns 'Hello world'", () => {
    const server = createHelloWorldServer();
    const result = server.handleToolCall("print_hello", {});
    expect(result.text).toBe("Hello world");
  });

  it("print_hello with name returns 'Hello {name}'", () => {
    const server = createHelloWorldServer();
    const result = server.handleToolCall("print_hello", { name: "Alice" });
    expect(result.text).toBe("Hello Alice");
  });

  it("print_hello with non-string name falls back to 'world'", () => {
    const server = createHelloWorldServer();
    // Defensive: a client might send a non-string for a string-typed param.
    const result = server.handleToolCall("print_hello", { name: 42 });
    expect(result.text).toBe("Hello world");
  });

  it("print_name returns server identity", () => {
    const server = createHelloWorldServer();
    const result = server.handleToolCall("print_name", {});
    expect(result.text).toBe("i am mcp-hello-world v0.0.1");
  });

  it("print_exit returns 'exiting'", () => {
    const server = createHelloWorldServer();
    // We don't actually call std.process.exit() in tests because that
    // would terminate the test runner. The handler returns the same
    // text; the real binary invokes exit() AFTER writing the response.
    const result = server.handleToolCall("print_exit", {});
    expect(result.text).toBe("exiting");
  });

  it("unknown tool throws an error", () => {
    const server = createHelloWorldServer();
    expect(() => server.handleToolCall("nonexistent", {})).toThrow(/Unknown tool/);
  });

  it("lists exactly 3 tools", () => {
    const server = createHelloWorldServer();
    const tools = server.listTools();
    expect(tools).toHaveLength(3);
    const names = tools.map((t) => t.name).sort();
    expect(names).toEqual(["print_exit", "print_hello", "print_name"]);
  });
});
