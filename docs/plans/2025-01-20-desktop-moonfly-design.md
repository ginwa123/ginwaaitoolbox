# Desktop App Moonfly Theme Design

## Overview

Add a top app bar and left sidebar to the Desktop application using Uno Platform, themed with the Vim Moonfly dark color scheme.

## Layout Structure

```
┌──────────────────────────────────────────────────────────────┐
│  [App Bar]  nalarcore                           [─][□][✕]   │
├────────────────┬─────────────────────────────────────────────┤
│                │                                              │
│   [Sessions]   │           Main Content Area                 │
│                │                                              │
│                │     (Chat interface when Sessions selected) │
│                │                                              │
└────────────────┴─────────────────────────────────────────────┘
```

## Moonfly Color Palette (Dark Only)

| Element | Color Name | Hex |
|---------|------------|-----|
| App Bar Background | Black | `#1b1d22` |
| Sidebar Background | Dark Gray | `#323437` |
| Sidebar Item Hover | Gray | `#464b50` |
| Sidebar Item Selected | Teal accent | `#56b6c2` |
| Main Background | Black | `#1b1d22` |
| Text Primary | White | `#c5c8c9` |
| Text Secondary | Light Gray | `#8b9198` |
| Borders | Gray | `#464b50` |
| Accent (selected/active) | Teal | `#56b6c2` |

## Components

### App Bar
- Dark background (`#1b1d22`)
- App title "nalarcore" in white text (`#c5c8c9`)
- Standard window controls on right (minimize, maximize, close)
- Height: 48px

### Sidebar
- Width: 220px
- Background: `#323437`
- Single "Sessions" item with icon
- Full-width clickable area
- Hover: `#464b50` background
- Selected: `#56b6c2` left border accent (3px)

### Chat View
- Message bubbles with Moonfly syntax highlighting
- User messages: subtle background
- LLM responses: distinct styling
- Input area at bottom with send button

## Technical Approach

- **Framework**: Uno Platform with C# Markup
- **Navigation**: WinUI NavigationView or custom Grid-based layout
- **Styling**: Resource dictionaries with Moonfly color brushes
- **State**: MVVM pattern with CommunityToolkit.Mvvm

## Files to Modify

1. `src/apps/Desktop/Desktop/App.xaml` - Add Moonfly color resources
2. `src/apps/Desktop/Desktop/MainPage.xaml.cs` - Restructure with app bar + sidebar layout
3. `src/apps/Desktop/Desktop/ViewModels/MainViewModel.cs` - Add navigation state

## Files to Create

1. `src/apps/Desktop/Desktop/Views/SessionsView.xaml.cs` - Chat interface
2. `src/apps/Desktop/Desktop/Themes/MoonflyTheme.xaml` - Moonfly color palette
