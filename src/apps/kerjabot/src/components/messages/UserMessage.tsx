/**
 * UserMessage - User message display component
 */

import type { Component } from 'solid-js';
import { User } from 'lucide-solid';
import type { UserMessage as UserMessageType } from '~/types';
import { MessageBubble } from './MessageBubble';
import { formatDateTime } from '~/utils';

interface UserMessageProps {
  readonly message: UserMessageType;
}

export const UserMessage: Component<UserMessageProps> = (props) => {
  return (
    <div class="flex items-end gap-3">
      <div class="flex-1">
        <MessageBubble role={props.message.role}>
          <p class="whitespace-pre-wrap">{props.message.content}</p>
        </MessageBubble>
        <div class="flex justify-end mt-1">
          <span class="text-xs text-gray-400 dark:text-gray-500">
            {formatDateTime(props.message.timestamp)}
          </span>
        </div>
      </div>
      <div class="w-8 h-8 rounded-full bg-blue-600 flex items-center justify-center flex-shrink-0">
        <User class="w-4 h-4 text-white" />
      </div>
    </div>
  );
};
