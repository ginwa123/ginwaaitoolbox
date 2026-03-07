/**
 * AgentSelector - Grid of selectable agents for session creation
 */

import type { Component } from 'solid-js';
import { For } from 'solid-js';
import type { AgentConfig } from '~/types';
import { AgentCard } from './AgentCard';

interface AgentSelectorProps {
  readonly agents: readonly AgentConfig[];
  readonly selectedAgentId: string | null;
  readonly onSelectAgent: (agentId: string) => void;
}

export const AgentSelector: Component<AgentSelectorProps> = (props) => {
  return (
    <div class="w-full max-w-5xl mx-auto">
      <div class="text-center mb-8">
        <h2 class="text-2xl font-bold text-gray-900 dark:text-white mb-2">
          Choose an Agent
        </h2>
        <p class="text-gray-600 dark:text-gray-400">
          Select the best agent for your task. Each agent has specialized capabilities.
        </p>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <For each={props.agents}>
          {(agent) => (
            <AgentCard
              agent={agent}
              isSelected={props.selectedAgentId === agent.id}
              onSelect={() => props.onSelectAgent(agent.id)}
            />
          )}
        </For>
      </div>
    </div>
  );
};
