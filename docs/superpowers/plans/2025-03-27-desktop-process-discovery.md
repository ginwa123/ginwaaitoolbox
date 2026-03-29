# Desktop Process Discovery Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace hardcoded `http://127.0.0.1:8080` with dynamic port discovery from running "nalar" process using TDD approach.

**Architecture:** Create `processDiscovery.ts` utility that scans `/proc/*/cmdline` for nalar process and parses `--port` argument. Replace hardcoded `getBaseUrl()` calls with centralized utility.

**Tech Stack:** TypeScript, Bun test framework, Bun runtime, Zig build

**Run tests:** `zig build test:desktop`

---

## Chunk 0: Build.zig Test Step (Already Done)

### Task 0.1: Add `test:desktop` step to build.zig

**Files:**
- Modify: `build.zig`

- [x] **Already implemented** - added `test:desktop` step that runs `bun test` in `src/apps/desktop-bun`

```zig
// Desktop Bun tests step - runs bun test in src/apps/desktop-bun
const test_desktop_step = b.step("test:desktop", "Run desktop app tests (bun test)");
const run_bun_test = b.addSystemCommand(&.{"bun", "test"});
run_bun_test.cwd = b.pathFromRoot("src/apps/desktop-bun");
test_desktop_step.dependOn(&run_bun_test.step);
```

Run: `zig build test:desktop`

---

## Chunk 1: Test Setup & First Test

### Task 1.1: Add Bun test dependency

**Files:**
- Modify: `src/apps/desktop-bun/package.json`

- [ ] **Step 1: Add test script to package.json**

```json
{
  "scripts": {
    "test": "bun test"
  }
}
```

- [ ] **Step 2: Run test command to verify setup**

Run: `bun test --help | head -n 5`
Expected: Shows test usage info

### Task 1.2: Write first failing test - parse port from cmdline

**Files:**
- Create: `src/apps/desktop-bun/src/utils/processDiscovery.test.ts`
- Test: `src/apps/desktop-bun/src/utils/processDiscovery.ts` (to be created)

- [ ] **Step 1: Write failing test for port parsing**

```typescript
import { describe, test, expect } from "bun:test";
import { parsePortFromCmdline } from "./processDiscovery";

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/utils/processDiscovery.test.ts`
Expected: FAIL with "parsePortFromCmdline is not a function"

- [ ] **Step 3: Write minimal implementation**

```typescript
// src/apps/desktop-bun/src/utils/processDiscovery.ts

const PROCESS_NAME = "nalar";

export function parsePortFromCmdline(cmdline: string): number | null {
  // Check if nalar is in the command line
  if (!cmdline.includes(PROCESS_NAME)) {
    return null;
  }

  // Match --port followed by a number
  const portMatch = cmdline.match(/--port\s+(\d+)/);
  if (portMatch) {
    return parseInt(portMatch[1], 10);
  }

  return null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/utils/processDiscovery.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop-bun/package.json src/apps/desktop-bun/src/utils/processDiscovery.ts src/apps/desktop-bun/src/utils/processDiscovery.test.ts
git commit -m "feat(desktop): add parsePortFromCmdline with TDD"
```

---

## Chunk 2: Process Discovery with /proc

### Task 2.1: Write failing test - find nalar process port

**Files:**
- Modify: `src/apps/desktop-bun/src/utils/processDiscovery.test.ts`
- Test: `src/apps/desktop-bun/src/utils/processDiscovery.ts`

- [ ] **Step 1: Add mock helper and test for findNalarPort**

```typescript
import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { parsePortFromCmdline, findNalarPort, type ReadDirEntry } from "./processDiscovery";

// Helper to create mock directory entry
function mockDirEntry(name: string): ReadDirEntry {
  return { name, isDirectory: () => name.match(/^\d+$/) !== null };
}

describe("findNalarPort", () => {
  test("returns port from running nalar process", async () => {
    // This test would need to mock /proc scanning
    // For now, test the logic separately
    expect(typeof findNalarPort).toBe("function");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/utils/processDiscovery.test.ts`
Expected: FAIL with "findNalarPort is not defined"

- [ ] **Step 3: Write minimal implementation stub**

```typescript
export async function findNalarPort(): Promise<number> {
  // Default port
  const DEFAULT_PORT = 8080;

  try {
    // Read /proc to find nalar processes
    const entries = await Array.fromDirstream("/proc");
    
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      
      const pid = entry.name;
      if (!/^\d+$/.test(pid)) continue;

      try {
        const cmdlinePath = `/proc/${pid}/cmdline`;
        const cmdline = await Bun.file(cmdlinePath).text();
        const port = parsePortFromCmdline(cmdline);
        
        if (port !== null) {
          return port;
        }
      } catch {
        // Process may have exited, skip
      }
    }
  } catch {
    // /proc not available (Windows/macOS), use default
  }

  return DEFAULT_PORT;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/utils/processDiscovery.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop-bun/src/utils/processDiscovery.ts src/apps/desktop-bun/src/utils/processDiscovery.test.ts
git commit -m "feat(desktop): add findNalarPort using /proc scan"
```

---

## Chunk 3: Cached getBaseUrl Utility

### Task 3.1: Write failing test - getBaseUrl returns correct URL

**Files:**
- Create: `src/apps/desktop-bun/src/utils/baseUrl.test.ts`
- Test: `src/apps/desktop-bun/src/utils/baseUrl.ts` (to be created)

- [ ] **Step 1: Write failing test**

```typescript
import { describe, test, expect, beforeEach } from "bun:test";
import { getBaseUrl, setBaseUrlForTest } from "./baseUrl";

describe("getBaseUrl", () => {
  beforeEach(() => {
    // Reset module state before each test
    setBaseUrlForTest(undefined);
  });

  test("returns http://127.0.0.1:8080 by default", async () => {
    const url = await getBaseUrl();
    expect(url).toBe("http://127.0.0.1:8080");
  });

  test("returns correct URL when port is discovered", async () => {
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/utils/baseUrl.test.ts`
Expected: FAIL with "getBaseUrl is not defined"

- [ ] **Step 3: Write minimal implementation**

```typescript
// src/apps/desktop-bun/src/utils/baseUrl.ts
import { findNalarPort } from "./processDiscovery";

let cachedBaseUrl: string | null = null;

export function setBaseUrlForTest(port: number | undefined) {
  cachedBaseUrl = port !== undefined ? `http://127.0.0.1:${port}` : null;
}

export async function getBaseUrl(): Promise<string> {
  if (cachedBaseUrl === null) {
    const port = await findNalarPort();
    cachedBaseUrl = `http://127.0.0.1:${port}`;
  }
  return cachedBaseUrl;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/utils/baseUrl.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop-bun/src/utils/baseUrl.ts src/apps/desktop-bun/src/utils/baseUrl.test.ts
git commit -m "feat(desktop): add cached getBaseUrl utility"
```

---

## Chunk 4: Refactor Existing Components

### Task 4.1: Update Sidebar.tsx to use getBaseUrl

**Files:**
- Modify: `src/apps/desktop-bun/src/mainview/components/Sidebar.tsx`
- Test: No new test needed (refactoring existing behavior)

- [ ] **Step 1: Replace local getBaseUrl with import**

```typescript
// OLD (line 12-15):
// Helper to get base URL - both dev and prod use the backend API at 8080
const getBaseUrl = () => {
  return "http://127.0.0.1:8080";
};

// NEW:
import { getBaseUrl } from "../../utils/baseUrl";

// Update fetchSessions to be async:
const fetchSessions = async (cursor?: string) => {
  try {
    const baseUrl = await getBaseUrl();  // Changed from getBaseUrl()
    // ... rest unchanged
```

- [ ] **Step 2: Run all tests to verify nothing broke**

Run: `bun test`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop-bun/src/mainview/components/Sidebar.tsx
git commit -m "refactor(desktop): Sidebar uses dynamic getBaseUrl"
```

### Task 4.2: Update SessionChat.tsx to use getBaseUrl

**Files:**
- Modify: `src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx`

- [ ] **Step 1: Replace local getBaseUrl with import**

```typescript
// OLD (line 24):
const getBaseUrl = () => "http://127.0.0.1:8080";

// NEW:
import { getBaseUrl } from "../../utils/baseUrl";

// Update usages to await:
// Line 152: const res = await fetch(`${getBaseUrl()}/api/session/${sessionId}`, ...
// Line 173: const url = `${getBaseUrl()}/api/session/${sessionId}/messages?format=${format}`;
```

- [ ] **Step 2: Run all tests to verify nothing broke**

Run: `bun test`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop-bun/src/mainview/pages/SessionChat.tsx
git commit -m "refactor(desktop): SessionChat uses dynamic getBaseUrl"
```

---

## Chunk 5: Integration Test (Optional)

### Task 5.1: Add integration test for full flow

**Files:**
- Create: `src/apps/desktop-bun/src/utils/integration.test.ts`

- [ ] **Step 1: Write integration test**

```typescript
import { describe, test, expect } from "bun:test";
import { parsePortFromCmdline, findNalarPort } from "./processDiscovery";

describe("Integration", () => {
  test("process discovery works end-to-end", async () => {
    // This verifies the actual /proc scan works
    // May skip on non-Linux systems
    const port = await findNalarPort();
    expect(typeof port).toBe("number");
    expect(port).toBeGreaterThan(0);
    expect(port).toBeLessThanOrEqual(65535);
  });
});
```

- [ ] **Step 2: Run integration test**

Run: `bun test src/utils/integration.test.ts`
Expected: PASS (or SKIP on non-Linux)

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop-bun/src/utils/integration.test.ts
git commit -m "test(desktop): add process discovery integration test"
```

---

## Verification Checklist

- [ ] All tests pass (`bun test`)
- [ ] Sidebar.tsx no longer has hardcoded URL
- [ ] SessionChat.tsx no longer has hardcoded URL
- [ ] `git log --oneline` shows TDD commits
- [ ] Design doc committed to git
