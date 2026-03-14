/**
 * SessionList - List of sessions with selection
 */

import type { Component } from 'solid-js';
import { For, Show } from 'solid-js';
import { MessageSquare, Trash2 } from 'lucide-solid';
import type { SessionSummary } from '~/types';
import { SessionStatus, AgentType } from '~/types';
import { formatRelativeTime } from '~/utils';

interface SessionListProps {
  readonly sessions: readonly SessionSummary[];
  readonly activeSessionId: string | null;
  readonly onSelectSession: (id: string) => void;
  readonly onDeleteSession?: (id: string) => void;
}

export const SessionList: Component<SessionListProps> = (props) => {
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
    <div class="space-y-1">
      <For each={props.sessions}>
        {(session) => (
          <div
            class={`group flex items-center gap-3 p-3 rounded-lg cursor-pointer transition-colors ${
              props.activeSessionId === session.id
                ? 'bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800'
                : 'hover:bg-gray-100 dark:hover:bg-gray-700/50'
            }`}
            onClick={() => props.onSelectSession(session.id)}
          >
            {/* Status indicator */}
            <div class={`w-2 h-2 rounded-full ${getStatusIndicator(session.status)}`} />
            
            {/* Agent icon */}
            <div class={`w-6 h-6 rounded-full ${getAgentColor(session.agentType)} flex items-center justify-center flex-shrink-0`}>
              <MessageSquare class="w-3 h-3 text-white" />
            </div>
            
            {/* Session info */}
            <div class="flex-1 min-w-0">
              <p class="font-medium text-sm text-gray-900 dark:text-white truncate">
                {session.name}
              </p>
              <div class="flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                <span>{session.messageCount} messages</span>
                <Show when={session.lastMessageAt}>
                  <span>· {formatRelativeTime(session.lastMessageAt!)}</span>
                </Show>
              </div>
            </div>
            
            {/* Actions */}
            <Show when={props.onDeleteSession}>
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  props.onDeleteSession?.(session.id);
                }}
                class="opacity-0 group-hover:opacity-100 p-1.5 text-gray-400 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded transition-all"
                title="Delete session"
              >
                <Trash2 class="w-4 h-4" />
              </button>
            </Show>
          </div>
        )}
      </For>

      <Show when={props.sessions.length === 0}>
        <div class="text-center py-8 text-gray-400 dark:text-gray-500">
          <MessageSquare class="w-8 h-8 mx-auto mb-2 opacity-50" />
          <p class="text-sm">No sessions</p>
        </div>
      </Show>
    </div>
  );
};
