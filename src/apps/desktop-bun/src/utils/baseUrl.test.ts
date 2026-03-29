import { describe, test, expect, beforeEach } from "bun:test";
import { getBaseUrl, setBaseUrlForTest, resetBaseUrlCache } from "./baseUrl";
import { resetDiscoveryCache } from "./processDiscovery";

describe("getBaseUrl", () => {
  beforeEach(() => {
    // Reset both caches before each test
    resetBaseUrlCache();
    resetDiscoveryCache();
  });

  test("returns http://127.0.0.1:8080 by default", async () => {
    const url = await getBaseUrl();
    expect(url).toBe("http://127.0.0.1:8080");
  });

  test("returns correct URL when port is set", async () => {
    setBaseUrlForTest(9090);
    const url = await getBaseUrl();
    expect(url).toBe("http://127.0.0.1:9090");
  });

  test("caches result after first call", async () => {
    const url1 = await getBaseUrl();
    const url2 = await getBaseUrl();
    expect(url1).toBe(url2);
  });
});
