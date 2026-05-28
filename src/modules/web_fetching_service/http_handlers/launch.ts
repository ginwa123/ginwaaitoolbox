import { launchPersistentContext } from "cloakbrowser";
import {
  generateBrowserId,
  getTempProfileDir,
  jsonResponse,
} from "./helpers";
import { browserSessions } from "./shared";

export async function launchBrowserPost(): Promise<Response> {
  try {
    const browserId = generateBrowserId();
    const profileDir = getTempProfileDir();

    const browser = await launchPersistentContext({
      userDataDir: profileDir,
      headless: true,
      humanize: true,
      stealthArgs: true,
    });

    browserSessions.set(browserId, {
      id: browserId,
      browser,
      created_at: new Date(),
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