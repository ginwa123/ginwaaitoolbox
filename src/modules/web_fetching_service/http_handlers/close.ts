import { jsonResponse } from "./helpers";
import { browserSessions } from "./shared";

export async function closeBrowserPost(browserId: string): Promise<Response> {
  const session = browserSessions.get(browserId);
  if (!session) {
    return jsonResponse(
      { success: false, error: "Browser session not found" },
      404,
    );
  }

  try {
    await session.browser.close();
    browserSessions.delete(browserId);
    console.log(`[${browserId}] Browser closed`);

    return jsonResponse({
      success: true,
      browser_id: browserId,
    });
  } catch (error) {
    console.error(`Failed to close browser ${browserId}:`, error);
    return jsonResponse(
      { success: false, error: "Failed to close browser" },
      500,
    );
  }
}