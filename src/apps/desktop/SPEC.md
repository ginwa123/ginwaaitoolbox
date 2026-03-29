# SPEC.md — SolidJS + Tauri Desktop App

## 1. Concept & Vision

A minimal, high-performance desktop application built with SolidJS and Tauri. The interface embraces **dark brutalist** aesthetics — raw, unapologetic, with purposeful density. It feels like a tool built by engineers for engineers: no bloat, no unnecessary polish, just pure function wrapped in sharp, confident design.

## 2. Design Language

### Aesthetic Direction
**Dark Brutalist** — High contrast, sharp edges, monospace typography, minimal ornamentation. Inspired by terminal UIs, developer tooling, and brutalist architecture.

### Color Palette
| Role | Token | Value |
|------|-------|-------|
| Background | `--bg-base` | `#0a0a0a` |
| Surface | `--bg-surface` | `#141414` |
| Border | `--border` | `#2a2a2a` |
| Text Primary | `--text-primary` | `#e5e5e5` |
| Text Muted | `--text-muted` | `#737373` |
| Accent | `--accent` | `#facc15` |
| Accent Hover | `--accent-hover` | `#fde047` |
| Danger | `--danger` | `#ef4444` |

### Typography
- **Display/Headings:** `JetBrains Mono` — technical, precise, distinctive
- **Body:** `IBM Plex Sans` — clean, readable, professional
- **Monospace:** `JetBrains Mono` — code, labels, data

### Spatial System
- Base unit: `4px`
- Spacing scale: `4, 8, 12, 16, 24, 32, 48, 64`
- Border radius: `0` (sharp edges — brutalist)
- Border width: `1px`

### Motion Philosophy
- Minimal, functional transitions
- Hover states: `150ms ease-out`
- Page transitions: `200ms ease-out`
- No decorative animations — motion serves feedback only

### Visual Assets
- Icons: Lucide (outlined, 1.5px stroke)
- No images — pure geometric shapes and typography
- Decorative: subtle grid patterns, sharp dividers

## 3. Layout & Structure

### Page Structure
```
┌─────────────────────────────────────────────┐
│  HEADER — App title, window controls        │
├─────────────┬───────────────────────────────┤
│  SIDEBAR    │  MAIN CONTENT                 │
│  (240px)    │  (flex-1)                     │
│             │                               │
│  Nav items  │  Page-specific content        │
│             │                               │
├─────────────┴───────────────────────────────┤
│  FOOTER — Status bar, version info          │
└─────────────────────────────────────────────┘
```

### Responsive Strategy
- Desktop-first (primary use case for Tauri)
- Sidebar collapses to icon-only at `< 768px`
- Content area maintains minimum `320px` width

## 4. Features & Interactions

### Core Features
1. **Window Management** — Native title bar with minimize, maximize, close
2. **Navigation** — Sidebar with Sessions list
3. **Session Chat** — Click session in sidebar to view chat history with LLM messages
4. **Dark Theme** — Always dark, no toggle needed

### Interactions
| Element | Hover | Active | Disabled |
|---------|-------|--------|----------|
| Nav Item | `bg-surface` + left accent border | `bg-surface` + accent text | `opacity-50`, `cursor-not-allowed` |
| Button | Scale `1.02`, shadow | Scale `0.98` | `opacity-50`, `cursor-not-allowed` |
| Card | Subtle border highlight | — | — |

### States
- **Empty:** Centered message with muted text
- **Loading:** Pulsing skeleton bars
- **Error:** Red accent border + error message

## 5. Component Inventory

### NavItem
- Default: `bg-transparent`, `text-muted`, left border transparent
- Hover: `bg-surface`, `text-primary`, left border `accent`
- Active: `bg-surface`, `text-accent`, left border `accent` (2px)

### Button
- Primary: `bg-accent`, `text-black`
- Secondary: `bg-surface`, `border`, `text-primary`
- Hover: slight scale + shadow
- Disabled: `opacity-50`

### Card
- `bg-surface`, `border`, `p-4`
- Hover: border color shifts to accent

### Header
- Fixed height `48px`
- App title left-aligned
- Window controls right-aligned

### Footer
- Fixed height `32px`
- Version info, status indicators

### SessionChat
- Session header with name, agent type, ID
- Scrollable message list with role-based coloring
- Role icons: `>` (user), `◆` (assistant), `★` (system), `⚙` (tool)
- Role colors: blue (user), yellow (assistant), purple (system), green (tool)

## 6. Technical Approach

### Stack
- **Framework:** SolidJS 1.9+
- **Styling:** Tailwind CSS v4 (CSS-first config)
- **Desktop:** Tauri v2
- **Build:** Vite
- **Package Manager:** Bun

### File Structure
```
src/apps/desktop/
├── SPEC.md
├── package.json
├── vite.config.ts
├── tsconfig.json
├── index.html
├── src/
│   ├── App.tsx
│   ├── index.tsx
│   ├── app.css
│   ├── components/
│   │   ├── Header.tsx
│   │   ├── Sidebar.tsx
│   │   ├── Footer.tsx
│   │   └── NavItem.tsx
│   └── pages/
│       ├── Welcome.tsx
│       └── SessionChat.tsx
├── utils/
    ├── Cargo.toml
    ├── tauri.conf.json
    └── src/main.rs
```

### Routing
| Route | Component | Description |
|-------|-----------|-------------|
| `/` | `Welcome` | Welcome page with app info |
| `/session/:sessionId` | `SessionChat` | Session chat history with LLM messages |

### Architecture
- File-based routing via SolidJS Router
- Shared state via Context API
- Tauri commands for native features (future)
