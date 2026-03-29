import { findNalarPort } from "./processDiscovery";

let cachedBaseUrl: string | null = null;

export function resetBaseUrlCache(): void {
  cachedBaseUrl = null;
}

export function setBaseUrlForTest(port: number): void {
  cachedBaseUrl = `http://127.0.0.1:${port}`;
}

export async function getBaseUrl(): Promise<string> {
  if (cachedBaseUrl === null) {
    const port = await findNalarPort();
    cachedBaseUrl = `http://127.0.0.1:${port}`;
  }
  return cachedBaseUrl;
}
