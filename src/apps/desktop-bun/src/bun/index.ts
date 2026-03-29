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
    return DEV_SERVER_URL;
  } catch {
    console.log("Vite dev server not running. Run 'bun run dev:hmr' for HMR support.");
  }
  return "views://mainview/index.html";
}

const mainWindow = new BrowserWindow({
  title: "Desktop Bun",
  url: await getMainViewUrl(),
});

// Expose functions to renderer via window
mainWindow.on("did-finish-load", () => {
  mainWindow.executeJavaScript(`
    window.__NALAR_PORT__ = ${NALAR_PORT};
    window.__getNalarBaseUrl = function() {
      return "http://127.0.0.1:${NALAR_PORT}";
    };
    console.log("[Desktop] Injected NALAR_PORT=${NALAR_PORT}");
  `);
});

console.log("Desktop Bun app started!");
