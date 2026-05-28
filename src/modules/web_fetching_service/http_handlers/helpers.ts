/**
 * Helper utilities for HTTP handlers
 */

// JSON response helper
export function jsonResponse(data: unknown, status: number = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    },
  });
}

// ID generators
export function generateBrowserId(): string {
  return `browser_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

export function generatePageId(): string {
  return `page_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

export function getTempProfileDir(): string {
  return `/tmp/cloakbrowser-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}