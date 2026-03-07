/**
 * HomePage - Landing page with agent selector
 */

import type { Component } from 'solid-js';
import { createSignal } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { AgentSelector } from '~/components/agents';
import { getAllAgents, getAgentById } from '~/services';
import { sessionStore } from '~/store/sessionStore';

export const HomePage: Component = () => {
  const navigate = useNavigate();
  const [selectedAgentId, setSelectedAgentId] = createSignal<string | null>(null);
  const agents = getAllAgents();

  const handleSelectAgent = (agentId: string) => {
    setSelectedAgentId(agentId);
    
    // Create a new session with the selected agent
    const agent = getAgentById(agentId);
    if (agent) {
      const session = sessionStore.addSession({
        name: `Chat with ${agent.name}`,
        agentType: agent.type,
        description: `New session with ${agent.name}`,
      });
      
      // Navigate to the chat page
      navigate(`/chat/${session.id}`);
    }
  };

  return (
    <div class="min-h-full flex flex-col items-center justify-center p-6">
      <div class="text-center mb-8">
        <h1 class="text-4xl font-bold text-gray-900 dark:text-white mb-4">
          Welcome to Kerjabot
        </h1>
        <p class="text-lg text-gray-600 dark:text-gray-400 max-w-2xl mx-auto">
          Your AI agent orchestration platform. Select an agent below to start a conversation,
          or choose the best agent for your specific task.
        </p>
      </div>

      <AgentSelector
        agents={agents}
        selectedAgentId={selectedAgentId()}
        onSelectAgent={handleSelectAgent}
      />

      <div class="mt-12 text-center text-sm text-gray-500 dark:text-gray-400">
        <p>Each agent has specialized capabilities for different types of tasks.</p>
        <p class="mt-1">You can switch agents at any time during a conversation.</p>
      </div>
    </div>
  );
};
