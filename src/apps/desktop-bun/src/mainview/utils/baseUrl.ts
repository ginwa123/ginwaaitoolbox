/**
 * Backend URL utility
 *
 * Provides the base URL for connecting to the backend server.
 */
import { createSignal } from 'solid-js';
import { log } from './logger';

// Default port - must match Zig backend (default 8080)
const DEFAULT_PORT = 8080;

const [baseUrl] = createSignal<string>(`http://127.0.0.1:${DEFAULT_PORT}`);
const [port] = createSignal<number>(DEFAULT_PORT);

export function initBaseUrl(): void {
  log.info(`[baseUrl] Using port: ${DEFAULT_PORT}`);
}

export { baseUrl, port };
