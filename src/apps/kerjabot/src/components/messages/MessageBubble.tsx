/**
 * MessageBubble - Base message container with role-based styling
 */

import type { Component, JSX } from 'solid-js';
import { Role } from '~/types';

interface MessageBubbleProps {
  readonly role: Role;
  readonly children: JSX.Element;
  readonly class?: string;
}

export const MessageBubble: Component<MessageBubbleProps> = (props) => {
  const getRoleStyles = () => {
    switch (props.role) {
      case Role.User:
        return 'bg-blue-600 text-white ml-auto';
      case Role.Assistant:
        return 'bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700';
      case Role.System:
        return 'bg-gray-100 dark:bg-gray-700/50 text-gray-600 dark:text-gray-400 mx-auto';
      case Role.Tool:
        return 'bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800';
      default:
        return 'bg-gray-100 dark:bg-gray-800';
    }
  };

  const getAlignment = () => {
    switch (props.role) {
      case Role.User:
        return 'justify-end';
      case Role.Assistant:
      case Role.Tool:
        return 'justify-start';
      case Role.System:
        return 'justify-center';
      default:
        return 'justify-start';
    }
  };

  return (
    <div class={`flex ${getAlignment()} ${props.class ?? ''}`}>
      <div
        class={`max-w-[85%] sm:max-w-[75%] rounded-2xl px-4 py-3 ${getRoleStyles()}`}
      >
        {props.children}
      </div>
    </div>
  );
};
