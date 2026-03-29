const PROCESS_NAME = "nalar";
const DEFAULT_PORT = 8080;

let cachedPort: number | null = null;

export function resetDiscoveryCache(): void {
  cachedPort = null;
}

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

export async function findNalarPort(): Promise<number> {
  // Return cached port if already discovered
  if (cachedPort !== null) {
    return cachedPort;
  }

  try {
    // Read /proc to find nalar processes
    const procPath = "/proc";
    const entries = await Array.fromDirstream(procPath);

    for (const entry of entries) {
      if (!entry.isDirectory()) continue;

      const pid = entry.name;
      if (!/^\d+$/.test(pid)) continue;

      try {
        const cmdlinePath = `${procPath}/${pid}/cmdline`;
        const cmdline = await Bun.file(cmdlinePath).text();
        const port = parsePortFromCmdline(cmdline);

        if (port !== null) {
          cachedPort = port;
          return port;
        }
      } catch {
        // Process may have exited, skip
      }
    }
  } catch {
    // /proc not available (Windows/macOS), use default
  }

  cachedPort = DEFAULT_PORT;
  return DEFAULT_PORT;
}
