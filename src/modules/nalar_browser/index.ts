/**
 * Nalar Browser Service
 *
 * Anti-bot bypass stealth-browser service using CloakBrowser.
 * Uses native Bun HTTP server (no external framework).
 */

// Import from handler modules
import {
  closeBrowserPost,
  closePagePost,
  clickElementPost,
  fillInputPost,
  pressKeyPost,
  healthGet,
  jsonResponse,
  launchBrowserPost,
  openPagePost,
  snapshotPagePost,
  startCleanupCron,
} from "./http_handlers/mod";

async function handleRequest(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const pathname = url.pathname;

  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
      },
    });
  }

  // Health check
  if (pathname === "/health" && req.method === "GET") {
    return healthGet();
  }

  // Launch browser
  if (pathname === "/launch" && req.method === "POST") {
    return launchBrowserPost();
  }

  // Close browser
  if (pathname.startsWith("/close/") && req.method === "POST") {
    const browserId = pathname.slice(7);
    return closeBrowserPost(browserId);
  }

  // Page endpoint - open or operate on page
  if (pathname === "/page" && req.method === "POST") {
    const body = await req.json();
    const { browser_id, url } = body;

    return openPagePost(browser_id, url);
  }

  if (pathname.startsWith("/snapshot") && req.method === "POST") {
    const body = await req.json();
    const { page_id } = body;
    return snapshotPagePost(page_id);
  }

  // Click element by ref
  if (pathname.startsWith("/click") && req.method === "POST") {
    const body = await req.json();
    const { page_id, ref } = body;
    return clickElementPost(page_id, ref);
  }

  // Fill input by ref
  if (pathname.startsWith("/fill") && req.method === "POST") {
    const body = await req.json();
    const { page_id, ref, text } = body;
    return fillInputPost(page_id, ref, text);
  }

  // Press key
  if (pathname.startsWith("/press") && req.method === "POST") {
    const body = await req.json();
    const { page_id, ref, key } = body;
    return pressKeyPost(page_id, ref, key);
  }

  // Close page
  if (pathname.startsWith("/page/close/") && req.method === "POST") {
    const pageId = pathname.slice(12);
    return closePagePost(pageId);
  }

  // 404 not found
  return jsonResponse({ success: false, error: "Not found" }, 404);
}

// ============================================================================
// Server
// ============================================================================

const port = parseInt(Bun.argv[2] ?? "3000");

console.log(`
╔══════════════════════════════════════════════════════╗
║     Nalar Browser (anti-bot stealth Chromium)         ║
╠══════════════════════════════════════════════════════╣
║  Health:      GET  /health                           ║
║  Launch:      POST /launch                            ║
║  Close:       POST /close/:browser_id                 ║
║  Page:        POST /page  {browser_id, url}           ║
║  Snapshot:    POST /snapshot {page_id}               ║
║  Click:       POST /click  {page_id, ref}            ║
║  Fill:        POST /fill   {page_id, ref, text}       ║
║  Press:       POST /press  {page_id, ref?, key}       ║
║  Page Close:  POST /page/close/:page_id               ║
╚══════════════════════════════════════════════════════╝
`);

// Start cleanup cron (every 60 seconds)
startCleanupCron(60 * 1000);

Bun.serve({
  port,
  hostname: "0.0.0.0",
  fetch: handleRequest,
});

console.log(`🚀 Server running at http://0.0.0.0:${port}`);
