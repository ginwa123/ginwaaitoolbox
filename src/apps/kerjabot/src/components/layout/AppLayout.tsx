/**
 * AppLayout - Main application layout with sidebar and content areas
 * Provides the structural foundation for all pages
 */

import type { Component, JSX } from 'solid-js';

interface AppLayoutProps {
  readonly sidebar: JSX.Element;
  readonly header: JSX.Element;
  readonly children: JSX.Element;
}

export const AppLayout: Component<AppLayoutProps> = (props) => {
  return (
    <div class="flex h-screen w-full bg-gray-50 dark:bg-gray-900">
      {/* Sidebar */}
      <aside class="w-64 flex-shrink-0 bg-white dark:bg-gray-800 border-r border-gray-200 dark:border-gray-700 flex flex-col">
        {props.sidebar}
      </aside>

      {/* Main content area */}
      <div class="flex-1 flex flex-col min-w-0">
        {/* Header */}
        <header class="h-16 flex-shrink-0 bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 flex items-center px-6">
          {props.header}
        </header>

        {/* Page content */}
        <main class="flex-1 overflow-auto p-6">
          {props.children}
        </main>
      </div>
    </div>
  );
};
