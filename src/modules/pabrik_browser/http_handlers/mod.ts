// HTTP Handlers barrel export
export { healthGet } from "./health";
export { launchBrowserPost } from "./launch";
export { closeBrowserPost } from "./close";
export { openPagePost } from "./page";
export { snapshotPagePost } from "./snapshot";
export { clickElementPost } from "./click";
export { fillInputPost, pressKeyPost } from "./fill";
export { closePagePost } from "./close_page";
export { startCleanupCron } from "./cleanup";

// Re-export shared types and session stores
export {
  browserSessions,
  pageSessions,
  type BrowserSession,
  type PageSession,
} from "./shared";

// Re-export helpers
export {
  jsonResponse,
  generateBrowserId,
  generatePageId,
  getTempProfileDir,
} from "./helpers";