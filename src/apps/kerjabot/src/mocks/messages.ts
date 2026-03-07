/**
 * Mock messages for development
 */

import type { Message, ToolMessage } from '~/types';
import { Role, SystemMessageLevel } from '~/types';

export const mockMessages: Message[] = [
  {
    id: 'msg_1',
    role: Role.System,
    content: 'Session started with General Agent',
    level: SystemMessageLevel.Info,
    timestamp: new Date(Date.now() - 1000 * 60 * 30),
    sessionId: 'sess_demo',
  },
  {
    id: 'msg_2',
    role: Role.User,
    content: 'Can you help me understand the project structure?',
    timestamp: new Date(Date.now() - 1000 * 60 * 25),
    sessionId: 'sess_demo',
  },
  {
    id: 'msg_3',
    role: Role.Assistant,
    content: 'I\'d be happy to help you understand the project structure! Let me explore the codebase for you.\n\nThe project appears to be a Kerjabot web application with the following structure:\n\n```\nsrc/\n├── components/\n│   ├── layout/\n│   ├── agents/\n│   ├── messages/\n│   ├── tools/\n│   └── input/\n├── pages/\n├── store/\n├── services/\n├── types/\n└── utils/\n```\n\nWould you like me to dive deeper into any specific part?',
    timestamp: new Date(Date.now() - 1000 * 60 * 24),
    sessionId: 'sess_demo',
    model: 'claude-3-sonnet',
    tokenCount: { prompt: 15, completion: 85, total: 100 },
  },
  {
    id: 'msg_4',
    role: Role.Tool,
    toolCallId: 'tool_1',
    toolName: 'list_dir',
    result: {
      success: true,
      output: 'components/\npages/\nstore/\nservices/\ntypes/\nutils/\nmocks/',
      duration: 150,
      timestamp: new Date(Date.now() - 1000 * 60 * 24),
    },
    timestamp: new Date(Date.now() - 1000 * 60 * 24),
    sessionId: 'sess_demo',
  } as ToolMessage,
  {
    id: 'msg_5',
    role: Role.User,
    content: 'What about the store directory? What state management are you using?',
    timestamp: new Date(Date.now() - 1000 * 60 * 20),
    sessionId: 'sess_demo',
  },
  {
    id: 'msg_6',
    role: Role.Assistant,
    content: 'The store directory uses SolidJS signals for reactive state management. Here\'s what I found:\n\n```typescript\n// sessionStore.ts - Manages session state\n// messageStore.ts - Manages message state with streaming support\n```\n\nBoth stores use functional programming patterns with readonly types and pure functions for state updates.',
    timestamp: new Date(Date.now() - 1000 * 60 * 19),
    sessionId: 'sess_demo',
    model: 'claude-3-sonnet',
    tokenCount: { prompt: 25, completion: 95, total: 120 },
  },
];
