import { generatePageId, jsonResponse } from "./helpers";
import { browserSessions, pageSessions } from "./shared";

export async function openPagePost(
  browser_id: string,
  url: string,
): Promise<Response> {
  try {
    if (!browser_id) {
      return jsonResponse({ success: false, error: "Missing browser_id" }, 400);
    }

    if (!url) {
      return jsonResponse({ success: false, error: "Missing url" }, 400);
    }

    if (!browser_id) {
      return jsonResponse({ success: false, error: "Missing session_id" }, 400);
    }

    const browserSession = browserSessions.get(browser_id);
    if (!browserSession) {
      return jsonResponse(
        { success: false, error: "Browser session not found" },
        404,
      );
    }

    const page = await browserSession.browser.newPage();
    const response = await page.goto(url, {
      waitUntil: "domcontentloaded",
      timeout: 30000,
    });

    // Small delay for humanize effect
    await page.waitForTimeout(500);

    const newPageId = generatePageId();
    const pageUrl = page.url();
    const pageTitle = await page.title();
    const now = new Date();

    pageSessions.set(newPageId, {
      id: newPageId,
      page,
      url: pageUrl,
      title: pageTitle,
      created_at: now,
      last_activity: now,
      browser_id,
    });

    // Update browser activity
    browserSession.last_activity = now;

    console.log(`[${browser_id}] Page opened: ${newPageId}`);

    return jsonResponse({
      success: true,
      session_id: browser_id,
      page_id: newPageId,
      url: pageUrl,
      title: pageTitle,
      status: response?.status(),
    });
  } catch (error) {
    console.error("Page action failed:", error);
    return jsonResponse({ success: false, error: "Page action failed" }, 500);
  }
}
