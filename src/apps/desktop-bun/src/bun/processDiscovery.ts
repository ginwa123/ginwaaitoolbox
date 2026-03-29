import { readdirSync, readFileSync } from "fs";
import { join } from "path";

const PROCESS_NAME = "nalar";
const DEFAULT_PORT = 8080;

export function parsePortFromCmdline(cmdline: string): number | null {
  if (!cmdline.includes(PROCESS_NAME)) {
    return null;
  }
  const portMatch = cmdline.match(/--port\s+(\d+)/);
  if (portMatch) {
    return parseInt(portMatch[1], 10);
  }
  return null;
}

export function findNalarPort(): number {
  try {
    const procPath = "/proc";
    const entries = readdirSync(procPath, { withFileTypes: true });

    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      
      const pid = entry.name;
      if (!/^\d+$/.test(pid)) continue;

      try {
        const cmdlinePath = join(procPath, pid, "cmdline");
        // cmdline is null-separated, replace with space for parsing
        const cmdline = readFileSync(cmdlinePath, "utf-8").replace(/\0/g, " ");
        const port = parsePortFromCmdline(cmdline);

        if (port !== null) {
          console.log(`[processDiscovery] Found nalar on port ${port} (PID: ${pid})`);
          return port;
        }
      } catch {
        // Process may have exited, skip
      }
    }
  } catch (err) {
    console.error("[processDiscovery] Error scanning /proc:", err);
  }

  console.log(`[processDiscovery] nalar not found, using default port ${DEFAULT_PORT}`);
  return DEFAULT_PORT;
}
