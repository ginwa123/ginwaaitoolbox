import { launchPersistentContext } from "cloakbrowser";
import { generateBrowserId, getTempProfileDir, jsonResponse } from "./helpers";
import { browserSessions } from "./shared";

export async function launchBrowserPost(): Promise<Response> {
  try {
    if (browserSessions.size > 0) {
      const existingBrowserId = browserSessions.keys().next().value as
        | string
        | undefined;

      return jsonResponse({
        success: false,
        message: `Already running a browser + browserid: ${existingBrowserId}`,
        browserId: existingBrowserId,
      });
    }

    const browserId = generateBrowserId();
    const profileDir = getTempProfileDir();

    const browser = await launchPersistentContext({
      userDataDir: profileDir,
      headless: true,
      humanize: true,
      stealthArgs: true,
    });

    const now = new Date();
    browserSessions.set(browserId, {
      id: browserId,
      browser,
      created_at: now,
      last_activity: now,
    });

    console.log(`[${browserId}] Browser launched`);

    return jsonResponse({
      success: true,
      browser_id: browserId,
    });
  } catch (error) {
    console.error("Failed to launch browser:", error);
    return jsonResponse(
      { success: false, error: "Failed to launch browser" },
      500,
    );
  }
}
