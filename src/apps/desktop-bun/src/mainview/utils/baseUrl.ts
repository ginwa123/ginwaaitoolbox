import { createSignal } from 'solid-js';

const DEFAULT_PORT = 8080;

// Reactive baseUrl signal
const [baseUrl, setBaseUrl] = createSignal<string>('http://127.0.0.1:8080');
const [isLoading, setIsLoading] = createSignal(true);

// Initialize baseUrl from URL query parameter (set by Bun)
export function initBaseUrl(): void {
  // Get port from URL query parameter (e.g., ?nalar_port=8081)
  const urlParams = new URLSearchParams(window.location.search);
  const port = urlParams.get('nalar_port');

  if (port) {
    setBaseUrl(`http://127.0.0.1:${port}`);
    console.log(`[baseUrl] Initialized from URL: ${baseUrl()}`);
  } else {
    setBaseUrl(`http://127.0.0.1:${DEFAULT_PORT}`);
    console.log(`[baseUrl] Initialized with default: ${baseUrl()}`);
  }
  setIsLoading(false);
}

export { baseUrl, isLoading };
