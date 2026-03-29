import { createSignal } from "solid-js";

const DEFAULT_PORT = 8080;

declare global {
  interface Window {
    __NALAR_PORT__?: number;
    __getNalarBaseUrl?: () => string;
  }
}

// Reactive baseUrl signal
const [baseUrl, setBaseUrl] = createSignal<string>("http://127.0.0.1:8080");
const [isLoading, setIsLoading] = createSignal(true);

// Initialize baseUrl from window (injected by Bun)
export function initBaseUrl(): void {
  const port = typeof window !== 'undefined' && window.__NALAR_PORT__
    ? window.__NALAR_PORT__
    : DEFAULT_PORT;
  
  setBaseUrl(`http://127.0.0.1:${port}`);
  setIsLoading(false);
  console.log("[baseUrl] Initialized:", baseUrl());
}

export { baseUrl, isLoading };
