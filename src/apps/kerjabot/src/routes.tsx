/**
 * Route definitions for Kerjabot
 */

import { lazy } from 'solid-js';
import type { RouteDefinition } from '@solidjs/router';

// Lazy load pages for code splitting
const HomePage = lazy(() => import('./pages/HomePage').then(m => ({ default: m.HomePage })));
const ChatPage = lazy(() => import('./pages/ChatPage').then(m => ({ default: m.ChatPage })));
const SettingsPage = lazy(() => import('./pages/SettingsPage').then(m => ({ default: m.SettingsPage })));

export const routes: RouteDefinition[] = [
  {
    path: '/',
    component: HomePage,
  },
  {
    path: '/chat/:id',
    component: ChatPage,
  },
  {
    path: '/settings',
    component: SettingsPage,
  },
];
