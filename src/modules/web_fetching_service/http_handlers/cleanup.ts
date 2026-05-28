/**
 * Session cleanup cronjob
 *
 * Closes idle pages after 10 minutes
 * Closes idle browsers after 1 hour (if no pages exist for that browser)
 */

import {
  browserSessions,
  pageSessions,
  PAGE_IDLE_TIMEOUT,
  BROWSER_IDLE_TIMEOUT,
} from "./shared";

export function startCleanupCron(intervalMs: number = 60 * 1000): NodeJS.Timeout {
  console.log(`🧹 Starting cleanup cron (every ${intervalMs / 1000}s)`);
  console.log(`   Page idle timeout: ${PAGE_IDLE_TIMEOUT / 1000}s`);
  console.log(`   Browser idle timeout: ${BROWSER_IDLE_TIMEOUT / 1000}s`);

  return setInterval(() => {
    cleanupIdleSessions();
  }, intervalMs);
}

function cleanupIdleSessions(): void {
  const now = new Date();
  let closedPages = 0;
  let closedBrowsers = 0;

  // Cleanup idle pages (older than 10 minutes)
  const pagesToClose: string[] = [];
  for (const [pageId, pageSession] of pageSessions) {
    const idleTime = now.getTime() - pageSession.last_activity.getTime();
    if (idleTime > PAGE_IDLE_TIMEOUT) {
      pagesToClose.push(pageId);
    }
  }

  for (const pageId of pagesToClose) {
    const pageSession = pageSessions.get(pageId);
    if (pageSession) {
      console.log(`[${pageId}] Closing idle page (idle ${Math.round((now.getTime() - pageSession.last_activity.getTime()) / 1000)}s)`);
      pageSession.page.close().catch((err) => {
        console.error(`[${pageId}] Error closing page:`, err);
      });
      pageSessions.delete(pageId);
      closedPages++;
    }
  }

  // Cleanup idle browsers (older than 1 hour AND no active pages for this browser)
  const browsersToClose: string[] = [];
  for (const [browserId, browserSession] of pageSessions) {
    // This doesn't make sense - let me fix this
  }

  // Actually, we need to check each browser for idle time AND whether it has pages
  for (const [browserId, browserSession] of browserSessions) {
    const idleTime = now.getTime() - browserSession.last_activity.getTime();

    // Check if this browser has any active pages
    const hasActivePages = Array.from(pageSessions.values()).some(
      (page) => page.browser_id === browserId,
    );

    // Only close if no pages exist AND browser is idle
    if (!hasActivePages && idleTime > BROWSER_IDLE_TIMEOUT) {
      browsersToClose.push(browserId);
    }
  }

  for (const browserId of browsersToClose) {
    const browserSession = browserSessions.get(browserId);
    if (browserSession) {
      console.log(`[${browserId}] Closing idle browser (idle ${Math.round((now.getTime() - browserSession.last_activity.getTime()) / 1000)}s)`);
      browserSession.browser.close().catch((err) => {
        console.error(`[${browserId}] Error closing browser:`, err);
      });
      browserSessions.delete(browserId);
      closedBrowsers++;
    }
  }

  if (closedPages > 0 || closedBrowsers > 0) {
    console.log(`   Cleaned up: ${closedPages} pages, ${closedBrowsers} browsers`);
  }
}