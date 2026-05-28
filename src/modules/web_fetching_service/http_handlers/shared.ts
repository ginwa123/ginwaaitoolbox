// Shared types and session stores for HTTP handlers

import type { Browser, Page } from "cloakbrowser";

export interface BrowserSession {
  id: string;
  browser: Browser;
  created_at: Date;
}

export interface PageSession {
  id: string;
  page: Page;
  url: string;
  title: string;
  created_at: Date;
}

// Global session stores - exported for use by handlers
export const browserSessions: Map<string, BrowserSession> = new Map();
export const pageSessions: Map<string, PageSession> = new Map();