import { createSignal } from "solid-js";
import { getRpc } from "../main";

// Reactive baseUrl signal - initialized from Bun via RPC
const [baseUrl, setBaseUrl] = createSignal<string>("http://127.0.0.1:8080");
const [isLoading, setIsLoading] = createSignal(true);
const [isInitialized, setIsInitialized] = createSignal(false);

// Initialize baseUrl from Bun via RPC (call once at app startup)
export async function initBaseUrl(): Promise<void> {
  if (isInitialized()) return;
  
  try {
    const rpc = getRpc();
    const url = await rpc.request.getNalarBaseUrl();
    setBaseUrl(url);
    console.log("[baseUrl] Initialized:", url);
  } catch (err) {
    console.error("[baseUrl] Failed to get from Bun, using default:", err);
  } finally {
    setIsLoading(false);
    setIsInitialized(true);
  }
}

export { baseUrl, isLoading };
