/**
 * Header - Top navigation header with title and actions
 */

import type { Component } from 'solid-js';
import { Show } from 'solid-js';
import { Bot, MoreVertical, Share, Download } from 'lucide-solid';
import type { AgentConfig, Session } from '~/types';
import { getAgentColorClass } from '~/services';

interface HeaderProps {
  readonly session: Session | null;
  readonly agent: AgentConfig | null;
  readonly onShare?: () => void;
  readonly onExport?: () => void;
  readonly onMenu?: () => void;
}

export const Header: Component<HeaderProps> = (props) => {
  return (
    <div class="flex items-center justify-between w-full">
      {/* Left side - Session info */}
      <div class="flex items-center gap-4">
        <Show
          when={props.session}
          fallback={
            <div>
              <h2 class="text-lg font-semibold text-gray-900 dark:text-white">
                Welcome to Kerjabot
              </h2>
              <p class="text-sm text-gray-500 dark:text-gray-400">
                Select an agent to start a new session
              </p>
            </div>
          }
        >
          {(session) => (
            <div class="flex items-center gap-3">
              <Show when={props.agent}>
                {(agent) => (
                  <div
                    class={`w-10 h-10 rounded-full flex items-center justify-center ${getAgentColorClass(
                      agent().type
                    )}`}
                  >
                    <Bot class="w-5 h-5 text-white" />
                  </div>
                )}
              </Show>
              <div>
                <h2 class="text-lg font-semibold text-gray-900 dark:text-white">
                  {session().name}
                </h2>
                <div class="flex items-center gap-2">
                  <Show when={props.agent}>
                    {(agent) => (
                      <span class="text-sm text-gray-500 dark:text-gray-400">
                        {agent().name}
                      </span>
                    )}
                  </Show>
                  <span class="text-xs px-2 py-0.5 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300">
                    {session().messageCount} messages
                  </span>
                </div>
              </div>
            </div>
          )}
        </Show>
      </div>

      {/* Right side - Actions */}
      <div class="flex items-center gap-2">
        <Show when={props.session}>
          <>
            <button
              onClick={props.onShare}
              class="p-2 text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
              title="Share session"
            >
              <Share class="w-5 h-5" />
            </button>
            <button
              onClick={props.onExport}
              class="p-2 text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
              title="Export session"
            >
              <Download class="w-5 h-5" />
            </button>
          </>
        </Show>
        <button
          onClick={props.onMenu}
          class="p-2 text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
          title="Menu"
        >
          <MoreVertical class="w-5 h-5" />
        </button>
      </div>
    </div>
  );
};
