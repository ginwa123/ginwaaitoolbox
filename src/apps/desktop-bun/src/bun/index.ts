import { BrowserWindow } from "electrobun/bun";
import { findNalarPort } from "./processDiscovery";

const DEV_SERVER_PORT = 5173;
const DEV_SERVER_URL = `http://localhost:${DEV_SERVER_PORT}`;
const NALAR_PORT = findNalarPort();

console.log(`[Desktop] Discovered nalar port: ${NALAR_PORT}`);

// Check if Vite dev server is running for HMR
async function getMainViewUrl(): Promise<string> {
  try {
    await fetch(DEV_SERVER_URL, { method: "HEAD" });
    console.log(`HMR enabled: Using Vite dev server at ${DEV_SERVER_URL}`);
    // Pass port as query parameter
    return `${DEV_SERVER_URL}?nalar_port=${NALAR_PORT}`;
  } catch {
    console.log("Vite dev server not running. Run 'bun run dev:hmr' for HMR support.");
  }
  return "views://mainview/index.html";
}

const mainWindow = new BrowserWindow({
  title: "Desktop Bun",
  url: await getMainViewUrl(),
});

console.log("Desktop Bun app started!");
