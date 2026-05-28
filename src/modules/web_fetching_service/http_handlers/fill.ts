import { jsonResponse } from "./helpers";
import { pageSessions, updatePageActivity } from "./shared";

export async function fillInputPost(
  page_id: string,
  ref: string,
  text: string,
): Promise<Response> {
  try {
    if (!page_id) {
      return jsonResponse({ success: false, error: "Missing page_id" }, 400);
    }

    if (!ref) {
      return jsonResponse({ success: false, error: "Missing ref" }, 400);
    }

    if (!text) {
      return jsonResponse({ success: false, error: "Missing text" }, 400);
    }

    const pageSession = pageSessions.get(page_id);
    if (!pageSession) {
      return jsonResponse(
        { success: false, error: "Page session not found" },
        404,
      );
    }

    const page = pageSession.page;

    // Fill input by ref - arguments must be wrapped in object for playwright
    const result = await page.evaluate(
      (args: { targetRef: string; inputText: string }) => {
        const { targetRef, inputText } = args;
        let element: HTMLInputElement | HTMLTextAreaElement | HTMLElement | null = null;

        // First try to find by data-ref attribute
        element = document.querySelector(
          `[data-ref="${targetRef}"], [ref="${targetRef}"]`,
        ) as HTMLInputElement | HTMLTextAreaElement | null;

        // Fallback: find by ref number (e1, e2, etc) - try to match element by index
        if (!element) {
          const refNum = parseInt(targetRef.replace("e", ""));
          let count = 0;
          const interactives = document.querySelectorAll<HTMLElement>(
            'input:not([type="hidden"]), textarea, [role="textbox"], [contenteditable="true"]',
          );

          for (const el of interactives) {
            const style = getComputedStyle(el);
            if (style.display === "none" || style.visibility === "hidden") continue;

            const rect = el.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) continue;

            if (count === refNum - 1) {
              element = el;
              break;
            }
            count++;
          }
        }

        // Fallback: find input by Google-specific attributes
        if (!element) {
          // Google search box: name="q", aria-label="Telusuri"
          element = document.querySelector(
            'input[name="q"], textarea[name="q"], [aria-label*="Telusuri"], [role="searchbox"]',
          ) as HTMLInputElement | HTMLTextAreaElement | null;
        }

        // Fallback: find by text content match
        if (!element) {
          const interactives = document.querySelectorAll<HTMLElement>(
            'input:not([type="hidden"]), textarea, [role="textbox"], [contenteditable="true"]',
          );

          for (const el of interactives) {
            const style = getComputedStyle(el);
            if (style.display === "none" || style.visibility === "hidden") continue;

            const rect = el.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) continue;

            let text =
              el.getAttribute("aria-label")?.trim() ||
              el.getAttribute("placeholder")?.trim() ||
              el.getAttribute("name")?.trim() ||
              el.textContent?.trim().replace(/\s+/g, " ").slice(0, 60) ||
              "";

            if (text.includes(targetRef.replace("e", ""))) {
              element = el;
              break;
            }
          }
        }

        if (!element) {
          return { success: false, error: "Element not found" };
        }

        // Focus and type
        element.focus();

        // For contenteditable or role=textbox
        if (
          element.getAttribute("contenteditable") === "true" ||
          element.getAttribute("role") === "textbox"
        ) {
          element.textContent = inputText;
        } else {
          // For regular inputs/textarea, clear and type
          (element as HTMLInputElement | HTMLTextAreaElement).value = inputText;
        }

        element.dispatchEvent(new Event("input", { bubbles: true }));
        element.dispatchEvent(new Event("change", { bubbles: true }));

        return { success: true };
      },
      { targetRef: ref, inputText: text },
    );

    if (!result.success) {
      return jsonResponse(result, 400);
    }

    const title = await page.title();
    const url = page.url();

    // Update page activity
    updatePageActivity(page_id);

    return jsonResponse({
      success: true,
      page_id,
      ref,
      title,
      url,
    });
  } catch (error) {
    console.error("Failed to fill input:", error);
    return jsonResponse(
      { success: false, error: "Failed to fill input" },
      500,
    );
  }
}

export async function pressKeyPost(
  page_id: string,
  ref: string,
  key: string,
): Promise<Response> {
  try {
    if (!page_id) {
      return jsonResponse({ success: false, error: "Missing page_id" }, 400);
    }

    if (!key) {
      return jsonResponse({ success: false, error: "Missing key" }, 400);
    }

    const pageSession = pageSessions.get(page_id);
    if (!pageSession) {
      return jsonResponse(
        { success: false, error: "Page session not found" },
        404,
      );
    }

    const page = pageSession.page;

    if (ref) {
      // Press key on specific element
      await page.evaluate(
        (args: { targetRef: string; pressKey: string }) => {
          const { targetRef, pressKey } = args;
          const element = document.querySelector(
            `[data-ref="${targetRef}"], [ref="${targetRef}"]`,
          ) as HTMLElement | null;

          if (element) {
            element.focus();
            element.dispatchEvent(new KeyboardEvent("keydown", { key: pressKey, bubbles: true }));
            element.dispatchEvent(new KeyboardEvent("keyup", { key: pressKey, bubbles: true }));
            element.dispatchEvent(new KeyboardEvent("keypress", { key: pressKey, bubbles: true }));
          }
        },
        { targetRef: ref, pressKey: key },
      );
    } else {
      // Press key globally on page
      await page.keyboard.press(key);
    }

    const title = await page.title();
    const url = page.url();

    // Update page activity
    updatePageActivity(page_id);

    return jsonResponse({
      success: true,
      page_id,
      key,
      title,
      url,
    });
  } catch (error) {
    console.error("Failed to press key:", error);
    return jsonResponse(
      { success: false, error: "Failed to press key" },
      500,
    );
  }
}