// Shared types and session stores for HTTP handlers

import type { Browser, Page } from "cloakbrowser";

export interface BrowserSession {
  id: string;
  browser: Browser;
  created_at: Date;
  last_activity: Date;
}

export interface PageSession {
  id: string;
  page: Page;
  url: string;
  title: string;
  created_at: Date;
  last_activity: Date;
  browser_id: string; // Track which browser this page belongs to
}

// Global session stores - exported for use by handlers
export const browserSessions: Map<string, BrowserSession> = new Map();
export const pageSessions: Map<string, PageSession> = new Map();

// Update last activity helpers
export function updateBrowserActivity(browserId: string): void {
  const session = browserSessions.get(browserId);
  if (session) {
    session.last_activity = new Date();
  }
}

export function updatePageActivity(pageId: string): void {
  const session = pageSessions.get(pageId);
  if (session) {
    session.last_activity = new Date();
  }
}

// Cleanup thresholds (in milliseconds)
export const PAGE_IDLE_TIMEOUT = 10 * 60 * 1000; // 10 minutes
export const BROWSER_IDLE_TIMEOUT = 60 * 60 * 1000; // 1 hour