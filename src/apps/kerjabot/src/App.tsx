/**
 * App - Root component with providers and routing
 */

import type { Component } from 'solid-js';
import { onMount } from 'solid-js';
import { Router, Route } from '@solidjs/router';
import { AppLayout, Sidebar, Header } from '~/components/layout';
import { sessionStore } from '~/store/sessionStore';
import { getAgentByType } from '~/services';
import { HomePage } from './pages/HomePage';
import { ChatPage } from './pages/ChatPage';
import { SettingsPage } from './pages/SettingsPage';

// Wrapper component that provides the layout with navigation
const LayoutWrapper: Component<{ children?: any }> = (props) => {
  const activeSession = () => sessionStore.activeSession();
  const sessionSummaries = () => sessionStore.sessionSummaries();
  const activeSessionId = () => sessionStore.activeSessionId();
  const backendConnected = () => sessionStore.backendConnected();

  const currentAgent = () => {
    const session = activeSession();
    if (!session) return null;
    return getAgentByType(session.agentType);
  };

  // Check backend connection on mount and load sessions
  onMount(async () => {
    await sessionStore.checkBackendConnection();
    if (sessionStore.backendConnected()) {
      await sessionStore.loadSessionsFromBackend();
    }
  });

  const handleSelectSession = (_id: string) => {
    // Navigation handled by Route component
  };

  const handleOpenSettings = () => {
    // Navigation handled by Route component
  };

  return (
    <AppLayout
      sidebar={
        <Sidebar
          sessions={sessionSummaries()}
          activeSessionId={activeSessionId()}
          currentAgent={activeSession()?.agentType || null}
          onSelectSession={handleSelectSession}
          onNewSession={() => {}}
          onOpenSettings={handleOpenSettings}
          backendConnected={backendConnected()}
        />
      }
      header={
        <Header
          session={activeSession()}
          agent={currentAgent()}
          onShare={() => console.log('Share clicked')}
          onExport={() => console.log('Export clicked')}
          onMenu={() => console.log('Menu clicked')}
        />
      }
    >
      {props.children}
    </AppLayout>
  );
};

export const App: Component = () => {
  return (
    <div class="h-screen w-full bg-gray-50 dark:bg-gray-900">
      <Router
        root={LayoutWrapper}
      >
        <Route path="/" component={HomePage} />
        <Route path="/chat/:id" component={ChatPage} />
        <Route path="/settings" component={SettingsPage} />
      </Router>
    </div>
  );
};
