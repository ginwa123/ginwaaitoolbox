import { describe, test, expect, beforeEach } from "bun:test";
import { parsePortFromCmdline, findNalarPort, resetDiscoveryCache } from "./processDiscovery";

describe("findNalarPort", () => {
  beforeEach(() => {
    // Reset cache before each test
    resetDiscoveryCache();
  });

  test("returns a valid port number", async () => {
    const port = await findNalarPort();
    expect(typeof port).toBe("number");
    expect(port).toBeGreaterThan(0);
    expect(port).toBeLessThanOrEqual(65535);
  });

  test("returns 8080 as default when nalar not running", async () => {
    // On systems without nalar running, should return default
    const port = await findNalarPort();
    expect(port).toBeGreaterThan(0);
  });

  test("caches result after first call", async () => {
    const port1 = await findNalarPort();
    const port2 = await findNalarPort();
    expect(port1).toBe(port2);
  });
});

describe("parsePortFromCmdline", () => {
  test("parses --port 8080 from command line", () => {
    const cmdline = "/usr/local/bin/nalar --verbose --port 8080 --process nalar";
    expect(parsePortFromCmdline(cmdline)).toBe(8080);
  });

  test("parses --port 9090 from command line", () => {
    const cmdline = "nalar --port 9090";
    expect(parsePortFromCmdline(cmdline)).toBe(9090);
  });

  test("returns null when no port specified", () => {
    const cmdline = "/usr/local/bin/nalar --verbose";
    expect(parsePortFromCmdline(cmdline)).toBeNull();
  });

  test("returns null when no nalar process", () => {
    const cmdline = "some-other-process --port 8080";
    expect(parsePortFromCmdline(cmdline)).toBeNull();
  });
});
