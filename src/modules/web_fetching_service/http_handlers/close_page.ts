import { jsonResponse } from "./helpers";
import { pageSessions } from "./shared";

export async function closePagePost(pageId: string): Promise<Response> {
  const pageSession = pageSessions.get(pageId);
  if (!pageSession) {
    return jsonResponse(
      { success: false, error: "Page session not found" },
      404,
    );
  }

  try {
    await pageSession.page.close();
    pageSessions.delete(pageId);
    console.log(`[${pageId}] Page closed`);

    return jsonResponse({
      success: true,
      page_id: pageId,
    });
  } catch (error) {
    console.error(`Failed to close page ${pageId}:`, error);
    return jsonResponse(
      { success: false, error: "Failed to close page" },
      500,
    );
  }
}