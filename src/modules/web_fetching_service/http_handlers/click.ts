import { jsonResponse } from "./helpers";
import { pageSessions } from "./shared";

export async function clickElementPost(
  page_id: string,
  ref: string,
): Promise<Response> {
  try {
    if (!page_id) {
      return jsonResponse({ success: false, error: "Missing page_id" }, 400);
    }

    if (!ref) {
      return jsonResponse({ success: false, error: "Missing ref" }, 400);
    }

    const pageSession = pageSessions.get(page_id);
    if (!pageSession) {
      return jsonResponse(
        { success: false, error: "Page session not found" },
        404,
      );
    }

    const page = pageSession.page;

    // Click element by ref - arguments must be wrapped in object for playwright
    const clickResult = await page.evaluate(
      (args: { targetRef: string }) => {
        const { targetRef } = args;
        // Find the element with matching ref attribute or data-ref
        let element = document.querySelector(
          `[data-ref="${targetRef}"], [ref="${targetRef}"]`,
        );

        if (element) {
          element.click();
          return true;
        }

        // Fallback: find by text content match
        // The refs in snapshot correspond to text content, so we find the element with matching text
        const interactives = document.querySelectorAll<HTMLElement>(
          'a[href], button, input:not([type="hidden"]), select, textarea, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [onclick], [tabindex="0"], [contenteditable="true"]',
        );

        for (const el of interactives) {
          const style = getComputedStyle(el);
          if (style.display === "none" || style.visibility === "hidden") continue;

          const rect = el.getBoundingClientRect();
          if (rect.width === 0 || rect.height === 0) continue;

          let text =
            el.getAttribute("aria-label")?.trim() ||
            el.textContent?.trim().replace(/\s+/g, " ").slice(0, 60) ||
            "";

          if (text === targetRef.replace("e", "")) {
            el.click();
            return true;
          }
        }

        return false;
      },
      { targetRef: ref },
    );

    const title = await page.title();
    const url = page.url();

    return jsonResponse({
      success: true,
      page_id,
      ref,
      title,
      url,
    });
  } catch (error) {
    console.error("Failed to click element:", error);
    return jsonResponse(
      { success: false, error: "Failed to click element" },
      500,
    );
  }
}