import { BrowserWindow } from "electrobun/bun";
import { findNalarPort } from "./processDiscovery";
import type { DesktopRPC } from "../shared/rpc";

const DEV_SERVER_PORT = 5173;
const DEV_SERVER_URL = `http://localhost:${DEV_SERVER_PORT}`;

// Define RPC handlers for the web UI to call
const desktopRPC = BrowserWindow.defineRPC<DesktopRPC>({
  request: {
    async getNalarPort() {
      const port = findNalarPort();
      console.log(`[Bun RPC] getNalarPort() → ${port}`);
      return port;
    },
    async getNalarBaseUrl() {
      const port = findNalarPort();
      return `http://127.0.0.1:${port}`;
    },
  },
  send: {
    log({ msg, level = "info" }) {
      switch (level) {
        case "error": console.error("[Renderer]", msg); break;
        case "warn": console.warn("[Renderer]", msg); break;
        default: console.log("[Renderer]", msg);
      }
    },
  },
});

// Check if Vite dev server is running for HMR
async function getMainViewUrl(): Promise<string> {
  const channel = await (globalThis as any).Updater?.localInfo?.channel?.() ?? "prod";
  if (channel === "dev") {
    try {
      await fetch(DEV_SERVER_URL, { method: "HEAD" });
      console.log(`HMR enabled: Using Vite dev server at ${DEV_SERVER_URL}`);
      return DEV_SERVER_URL;
    } catch {
      console.log("Vite dev server not running. Run 'bun run dev:hmr' for HMR support.");
    }
  }
  return "views://mainview/index.html";
}

const mainWindow = new BrowserWindow({
  title: "Desktop Bun",
  url: await getMainViewUrl(),
  rpc: desktopRPC,
});

console.log("Desktop Bun app started!");
