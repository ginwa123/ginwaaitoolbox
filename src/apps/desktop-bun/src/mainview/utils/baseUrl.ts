/**
 * Backend URL utility
 *
 * Provides the base URL for connecting to the backend server.
 * The port is received via RPC from Bun.
 *
 * Flow:
 * 1. App starts with a default port (8081 - most common for nalar)
 * 2. Bun sends the actual port via RPC message
 * 3. baseUrl is updated to the correct value
 */
import { createSignal } from 'solid-js';

const DEFAULT_PORT = 8081; // Most common nalar port

// Reactive baseUrl signal
const [baseUrl, setBaseUrl] = createSignal<string>(`http://127.0.0.1:${DEFAULT_PORT}`);
const [isLoading, setIsLoading] = createSignal(true);
const [port, setPort] = createSignal<number>(DEFAULT_PORT);

/**
 * Initialize and listen for port updates from Bun via RPC.
 * Call this early in app init.
 */
export function initBaseUrl(): void {
  console.log(`[baseUrl] Starting with default port: ${DEFAULT_PORT}`);

  // Listen for backend-info event from Bun (sent via RPC)
  window.addEventListener('backend-info', ((e: CustomEvent<{ port: number; url: string }>) => {
    const { port: newPort, url } = e.detail;
    setPort(newPort);
    setBaseUrl(url);
    console.log(`[baseUrl] ✅ Updated from Bun via RPC: ${url}`);
    setIsLoading(false);
  }) as EventListener);

  // Mark as loaded after a short delay (Bun sends port within 2 seconds)
  setTimeout(() => {
    if (isLoading()) {
      console.log('[baseUrl] Using default port (no update from Bun)');
      setIsLoading(false);
    }
  }, 3000);
}

/**
 * Manually set the port (for testing or fallback)
 */
export function setBackendPort(newPort: number): void {
  const url = `http://127.0.0.1:${newPort}`;
  setPort(newPort);
  setBaseUrl(url);
  console.log(`[baseUrl] Manually set to: ${url}`);
  setIsLoading(false);
}

export { baseUrl, isLoading, port };
