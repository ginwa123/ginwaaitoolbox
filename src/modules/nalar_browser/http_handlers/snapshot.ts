import { jsonResponse } from "./helpers";
import { pageSessions, updatePageActivity } from "./shared";

export async function snapshotPagePost(page_id: string): Promise<Response> {
  try {
    if (!page_id) {
      return jsonResponse({ success: false, error: "Missing page_id" }, 400);
    }

    const pageSession = pageSessions.get(page_id);
    if (!pageSession) {
      return jsonResponse(
        { success: false, error: "Page session not found" },
        404,
      );
    }

    const page = pageSession.page;
    const tree = await page.evaluate(() => {
      const interactives = document.querySelectorAll<HTMLAnchorElement>(
        'a[href], button, input:not([type="hidden"]), select, textarea, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [onclick], [tabindex="0"], [contenteditable="true"]',
      );

      const seen = new Set();
      const lines = [];
      let refNum = 1;

      for (const el of interactives) {
        // Skip hidden elements
        const style = getComputedStyle(el);
        if (style.display === "none" || style.visibility === "hidden") continue;

        const rect = el.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0) continue;

        const tag = el.tagName?.toLowerCase();

        // Get visible text
        let text =
          el.getAttribute("aria-label")?.trim() ||
          el.getAttribute("aria-labelledby") ||
          el.textContent?.trim().replace(/\s+/g, " ").slice(0, 60) ||
          "";

        if (!text) continue;

        // Deduplicate
        if (
          seen.has(text) &&
          tag !== "input" &&
          tag !== "select" &&
          tag !== "textarea"
        )
          continue;
        seen.add(text);

        // Only include href for links (most useful for LLM)
        const entry = { ref: `e${refNum++}`, text: text.slice(0, 60) };
        if (tag === "a" && el.href) {
          entry.href = el.href;
        }

        lines.push(entry);
      }

      return lines;
    });

    const title = await page.title();
    const url = page.url();

    // Update page activity
    updatePageActivity(page_id);

    return jsonResponse({
      success: true,
      page_id,
      url,
      title,
      tree,
    });
  } catch (error) {
    console.error("Failed to parse request body:", error);
    return jsonResponse(
      { success: false, error: "Failed to parse request body" },
      500,
    );
  }
}