# Kerjabot

A SolidJS + TypeScript + Tailwind CSS web application for AI agent orchestration.

## Features

- **Multi-Agent Support**: Choose from specialized agents (General, Exploration, Planning, Executing, Review, Knowledge, Compaction)
- **Real-time Chat**: Streamed message responses with typing indicators
- **Tool Visualization**: View tool calls and results with expandable details
- **Session Management**: Create, manage, and switch between conversation sessions
- **Responsive Design**: Works on desktop and mobile devices
- **Dark Mode**: Built-in dark mode support

## Tech Stack

- **Framework**: SolidJS
- **Language**: TypeScript
- **Styling**: Tailwind CSS
- **Routing**: @solidjs/router
- **State Management**: SolidJS Signals + TanStack Store
- **Icons**: lucide-solid

## Getting Started

### Prerequisites

- Node.js 18+
- npm or yarn

### Installation

```bash
# Navigate to the project directory
cd src/apps/kerjabot

# Install dependencies
npm install

# Start development server
npm run dev
```

The app will be available at `http://localhost:5173`

### Build for Production

```bash
npm run build
```

The built files will be in the `dist/` directory.

## Project Structure

```
src/
├── components/          # UI components
│   ├── layout/         # Layout components (AppLayout, Sidebar, Header)
│   ├── agents/         # Agent selection components
│   ├── messages/       # Message display components
│   ├── tools/          # Tool visualization components
│   └── input/          # Input components
├── pages/              # Page components
├── store/              # State management
├── services/           # API and business logic
├── types/              # TypeScript type definitions
├── utils/              # Utility functions
└── mocks/              # Mock data for development
```

## Available Agents

| Agent | Description | Best For |
|-------|-------------|----------|
| General | Versatile general-purpose agent | General tasks, coordination |
| Exploration | Codebase and file exploration | Understanding projects, discovery |
| Planning | Task planning and strategy | Breaking down complex tasks |
| Executing | Code implementation | Writing code, making changes |
| Review | Code and plan review | Quality assurance, verification |
| Knowledge | Information retrieval | Documentation, synthesis |
| Compaction | Conversation summarization | Managing long conversations |

## Development

### Adding a New Component

1. Create the component file in the appropriate `components/` subdirectory
2. Export it from the subdirectory's `index.ts`
3. Use functional components with TypeScript

### Adding a New Page

1. Create the page component in `pages/`
2. Add the route to `routes.tsx`
3. Export from `pages/index.ts`

### State Management

Use the store modules in `store/` for state management:

```typescript
import { sessionStore } from '~/store/sessionStore';
import { messageStore } from '~/store/messageStore';

// Access state
const sessions = sessionStore.sessions;
const activeSession = sessionStore.activeSession;

// Call actions
sessionStore.addSession({ name: 'New Session', agentType: AgentType.General });
messageStore.addUserMessage('Hello', sessionId);
```

## License

MIT
