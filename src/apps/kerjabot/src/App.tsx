/**
 * App - Root component with providers and routing
 */

import type { Component } from 'solid-js';
import { Router, useNavigate } from '@solidjs/router';
import { AppLayout, Sidebar, Header } from '~/components/layout';
import { sessionStore } from '~/store/sessionStore';
import { getAgentByType } from '~/services';
import { routes } from './routes';

const AppContent: Component = () => {
  const navigate = useNavigate();

  const activeSession = () => sessionStore.activeSession();
  const sessionSummaries = () => sessionStore.sessionSummaries();
  const activeSessionId = () => sessionStore.activeSessionId();

  const currentAgent = () => {
    const session = activeSession();
    if (!session) return null;
    return getAgentByType(session.agentType);
  };

  const handleNewSession = () => {
    navigate('/');
  };

  const handleSelectSession = (id: string) => {
    navigate(`/chat/${id}`);
  };

  const handleOpenSettings = () => {
    navigate('/settings');
  };

  return (
    <AppLayout
      sidebar={
        <Sidebar
          sessions={sessionSummaries()}
          activeSessionId={activeSessionId()}
          currentAgent={activeSession()?.agentType || null}
          onSelectSession={handleSelectSession}
          onNewSession={handleNewSession}
          onOpenSettings={handleOpenSettings}
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
      <Router>
        {routes}
      </Router>
    </AppLayout>
  );
};

export const App: Component = () => {
  return (
    <div class="h-screen w-full bg-gray-50 dark:bg-gray-900">
      <Router>
        <AppContent />
      </Router>
    </div>
  );
};
