/**
 * App - Root component with providers and routing
 */

import type { Component } from 'solid-js';
import { Router, useNavigate, useLocation } from '@solidjs/router';
import { AppLayout, Sidebar, Header } from '~/components/layout';
import { sessionStore } from '~/store/sessionStore';
import { getAgentByType } from '~/services';
import { routes } from './routes';

// Wrapper component that provides the layout with navigation
const LayoutWrapper: Component = () => {
  const navigate = useNavigate();
  const location = useLocation();

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

  // Get the current route component to render
  const CurrentRoute = () => {
    const path = location.pathname;
    
    // Find matching route
    for (const route of routes) {
      if (route.path === path) {
        const RouteComponent = route.component as Component;
        return <RouteComponent />;
      }
      // Handle dynamic routes like /chat/:id
      if (route.path.includes(':')) {
        const routePattern = route.path.replace(/:\w+/g, '[^/]+');
        const regex = new RegExp(`^${routePattern}$`);
        if (regex.test(path)) {
          const RouteComponent = route.component as Component;
          return <RouteComponent />;
        }
      }
    }
    return null;
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
      <CurrentRoute />
    </AppLayout>
  );
};

export const App: Component = () => {
  return (
    <div class="h-screen w-full bg-gray-50 dark:bg-gray-900">
      <Router>
        <LayoutWrapper />
      </Router>
    </div>
  );
};
