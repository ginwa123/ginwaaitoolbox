import { writeFileSync, appendFileSync } from "fs";

const LOG_PATH = "/tmp/tui.log";

export function log(message: string): void {
  const timestamp = new Date().toISOString();
  const entry = `[${timestamp}] ${message}\n`;
  console.log(entry.trim());
  try {
    appendFileSync(LOG_PATH, entry);
  } catch (e) {
    console.log("LOG ERROR:", e);
  }
}

export function logError(message: string, error?: unknown): void {
  const errorStr = error ? ` - ${String(error)}` : "";
  log(`ERROR: ${message}${errorStr}`);
}

export function logStartup(): void {
  log("TUI started");
}

export function logIpcSend(message: string): void {
  log(`IPC SEND: ${message}`);
}

export function logIpcReceive(response: string): void {
  const truncated = response.length > 200 ? response.slice(0, 200) + "..." : response;
  log(`IPC RECEIVE: ${truncated}`);
}
