/**
 * Sidebar - Navigation sidebar with session list and agent selector
 */

import type { Component } from 'solid-js';
import { For, Show } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { Plus, MessageSquare, Settings, Bot } from 'lucide-solid';
import type { SessionSummary } from '~/types';
import { SessionStatus, AgentType } from '~/types';
import { formatRelativeTime } from '~/utils';

interface SidebarProps {
  readonly sessions: readonly SessionSummary[];
  readonly activeSessionId: string | null;
  readonly currentAgent: AgentType | null;
  readonly onSelectSession?: (id: string) => void;
  readonly onNewSession?: () => void;
  readonly onOpenSettings?: () => void;
  readonly backendConnected?: boolean;
}

export const Sidebar: Component<SidebarProps> = (props) => {
  const navigate = useNavigate();
  const getAgentColor = (agentType: AgentType): string => {
    const colors: Record<AgentType, string> = {
      [AgentType.General]: 'bg-blue-500',
      [AgentType.Exploration]: 'bg-purple-500',
      [AgentType.Planning]: 'bg-amber-500',
      [AgentType.Executing]: 'bg-emerald-500',
      [AgentType.Review]: 'bg-rose-500',
      [AgentType.Knowledge]: 'bg-cyan-500',
      [AgentType.Compaction]: 'bg-indigo-500',
      [AgentType.Agent]: 'bg-gray-500',
    };
    return colors[agentType] ?? 'bg-gray-500';
  };

  const getStatusIndicator = (status: SessionStatus): string => {
    switch (status) {
      case SessionStatus.Active:
        return 'bg-green-500';
      case SessionStatus.Paused:
        return 'bg-yellow-500';
      case SessionStatus.Error:
        return 'bg-red-500';
      case SessionStatus.Completed:
        return 'bg-gray-400';
      default:
        return 'bg-gray-300';
    }
  };

  return (
    <div class="flex flex-col h-full">
      {/* Logo and brand */}
      <div class="p-4 border-b border-gray-200 dark:border-gray-700">
        <div class="flex items-center gap-3">
          <div class="w-8 h-8 rounded-lg bg-gradient-to-br from-blue-500 to-purple-600 flex items-center justify-center">
            <Bot class="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 class="font-semibold text-gray-900 dark:text-white">Kerjabot</h1>
            <div class="flex items-center gap-2">
              <p class="text-xs text-gray-500 dark:text-gray-400">AI Agent Orchestrator</p>
              <Show when={props.backendConnected !== undefined}>
                <span class={`w-2 h-2 rounded-full ${props.backendConnected ? 'bg-green-500' : 'bg-red-500'}`} 
                      title={props.backendConnected ? 'Backend connected' : 'Backend disconnected'} />
              </Show>
            </div>
          </div>
        </div>
      </div>

      {/* New session button */}
      <div class="p-4">
        <button
          onClick={() => {
            if (props.onNewSession) {
              props.onNewSession();
            } else {
              navigate('/');
            }
          }}
          class="w-full flex items-center justify-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition-colors font-medium"
        >
          <Plus class="w-4 h-4" />
          New Session
        </button>
      </div>

      {/* Session list */}
      <div class="flex-1 overflow-y-auto px-3">
        <h2 class="px-3 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider mb-2">
          Sessions
        </h2>
        <For each={props.sessions}>
          {(session) => (
            <button
              onClick={() => {
                if (props.onSelectSession) {
                  props.onSelectSession(session.id);
                } else {
                  navigate(`/chat/${session.id}`);
                }
              }}
              class={`w-full text-left p-3 rounded-lg mb-1 transition-colors ${
                props.activeSessionId === session.id
                  ? 'bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800'
                  : 'hover:bg-gray-100 dark:hover:bg-gray-700/50'
              }`}
            >
              <div class="flex items-start gap-3">
                <div class={`w-2 h-2 rounded-full mt-2 ${getStatusIndicator(session.status)}`} />
                <div class="flex-1 min-w-0">
                  <p class="font-medium text-sm text-gray-900 dark:text-white truncate">
                    {session.name}
                  </p>
                  <div class="flex items-center gap-2 mt-1">
                    <div class={`w-3 h-3 rounded-full ${getAgentColor(session.agentType)}`} />
                    <span class="text-xs text-gray-500 dark:text-gray-400">
                      {session.messageCount} messages
                    </span>
                    <Show when={session.lastMessageAt}>
                      <span class="text-xs text-gray-400 dark:text-gray-500">
                        · {formatRelativeTime(session.lastMessageAt!)}
                      </span>
                    </Show>
                  </div>
                  <Show when={session.preview}>
                    <p class="text-xs text-gray-500 dark:text-gray-400 truncate mt-1">
                      {session.preview}
                    </p>
                  </Show>
                </div>
              </div>
            </button>
          )}
        </For>

        <Show when={props.sessions.length === 0}>
          <div class="text-center py-8 text-gray-400 dark:text-gray-500">
            <MessageSquare class="w-8 h-8 mx-auto mb-2 opacity-50" />
            <p class="text-sm">No sessions yet</p>
            <p class="text-xs mt-1">Create a new session to start</p>
          </div>
        </Show>
      </div>

      {/* Footer */}
      <div class="p-4 border-t border-gray-200 dark:border-gray-700">
        <button
          onClick={props.onOpenSettings}
          class="w-full flex items-center gap-2 px-3 py-2 text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
        >
          <Settings class="w-4 h-4" />
          <span class="text-sm">Settings</span>
        </button>
      </div>
    </div>
  );
};
