---
name: clay
description: Use Clay when users mention UI layout, flexbox layout, 2D UI systems, game UI, immediate mode UI, UI rendering, or building user interfaces. Apply when users want to create game UIs, dashboards, editors, tools, or any UI with complex layouts. Trigger on: "flexbox layout", "UI library", "game UI", "clay", "UI layout", "panel", "sidebar", "button", "text wrapping", "scrolling container", or any UI component request. Also triggers for Clay bindings in other languages (clay-zig, clay-rs, clay-odin, etc.).
version: 1.0.0
compatibility: ["c", "zig", "rust", "odin", "cpp", "csharp", "go"]
---

# Clay Skill

Create high-performance 2D UI layouts with Clay — a zero-dependency, renderer-agnostic UI library written in C.

## Overview

Clay is a **layout library**, not a rendering library. It outputs a sorted list of **render commands** that you feed to your renderer of choice.

```
┌─────────────────────────────────────────────────┐
│           Your Game / Application                │
├─────────────────────────────────────────────────┤
│                    clay.h                        │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────┐│
│  │  Layout    │  │  Element    │  │  Render  ││
│  │  Engine    │→ │  Declarations│→ │  Commands││
│  │  (Flexbox) │  │  (CLAY())  │  │  Array   ││
│  └─────────────┘  └─────────────┘  └──────────┘│
├─────────────────────────────────────────────────┤
│  Renderers: Raylib │ OpenGL │ SDL2 │ HTML/Wasm │
└─────────────────────────────────────────────────┘
```

**Key characteristics:**
- ~4k lines of C code, zero dependencies
- Microsecond layout performance
- 3.5MB static arena memory for ~8192 elements
- Flexbox-like layout model
- Compiles to ~15kb WebAssembly

## Quick Start Template

```c
#include "clay.h"

// Your renderer implements these types:
// - Clay_RenderCommand (rectangles, text, images)
// - Clay_RenderCommandArray

int main(void) {
    // 1. Setup memory arena
    uint32_t memorySize = Clay_MinMemorySize();
    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(
        memorySize,
        malloc(memorySize)
    );

    // 2. Initialize Clay
    Clay_Initialize(arena, (Clay_Dimensions){800, 600},
        Clay_ErrorHandler{ /* error callback */ });

    // 3. Set your text measuring function
    Clay_SetMeasureTextFunction(MeasureText, userData);

    // 4. Main loop
    while (running) {
        // Update Clay state
        Clay_SetLayoutDimensions((Clay_Dimensions){screenWidth, screenHeight});
        Clay_SetPointerState(mousePosition, isMouseDown);
        Clay_UpdateScrollContainers(true, scrollDelta, deltaTime);

        // Declare UI layout
        Clay_BeginLayout();
        MyUI();
        Clay_RenderCommandArray commands = Clay_EndLayout();

        // Render commands
        for (int i = 0; i < commands.length; i++) {
            RenderCommand(commands.internalArray[i]);
        }
    }

    return 0;
}
```

## Core Concepts

### 1. Layout Config

Controls size, position, and spacing of elements:

```c
Clay_LayoutConfig layout = {
    .layoutDirection = CLAY_TOP_TO_BOTTOM,  // or CLAY_LEFT_TO_RIGHT
    .sizing = {
        .width = CLAY_SIZING_GROW(0),       // Fill available space
        .height = CLAY_SIZING_FIXED(50)
    },
    .padding = CLAY_PADDING_ALL(16),        // Inner spacing
    .childGap = 8,                           // Space between children
    .childAlignment = {
        .x = CLAY_ALIGN_X_CENTER,
        .y = CLAY_ALIGN_Y_CENTER
    }
};
```

### 2. Sizing Modes

| Mode | Syntax | Behavior |
|------|--------|----------|
| **Fixed** | `CLAY_SIZING_FIXED(100)` | Exact size in pixels |
| **Grow** | `CLLAY_SIZING_GROW(min, max)` | Fill available space |
| **Fit** | `CLAY_SIZING_FIT(min, max)` | Size to fit children |
| **Percent** | `CLAY_SIZING_PERCENT(0.5)` | % of parent size |

### 3. Element Types

```c
// Basic rectangle with styling
CLAY(CLAY_ID("MyBox"),
    CLAY_LAYOUT({ .sizing = { .width = CLAY_SIZING_FIXED(100) } }),
    CLAY_BACKGROUND_COLOR({ 100, 100, 200, 255 }),
    CLAY_CORNER_RADIUS(8)
) {
    // Children go here
}

// Text element
CLAY_TEXT(CLAY_STRING("Hello World"), CLAY_TEXT_CONFIG({
    .fontSize = 24,
    .textColor = { 255, 255, 255, 255 }
}));

// Image element
CLAY_IMAGE(CLAY_ID("MyImage"), myImageData, CLAY_IMAGE_CONFIG({
    .sourceDimensions = { 64, 64 }
}));
```

### 4. Styling Options

```c
// Rectangle styling
CLAY_BACKGROUND_COLOR(Clay_Color{ r, g, b, a })
CLAY_CORNER_RADIUS(float radius)                    // All corners
CLAY_CORNER_RADIUS(Clay_CornerRadius{ tl, tr, bl, br })
CLLAY_BORDER({
    .width = { left, right, top, bottom, 0 },
    .color = { r, g, b, a }
})

// Text styling
CLAY_TEXT_CONFIG({
    .fontSize = 16,
    .textColor = { 0, 0, 0, 255 },
    .fontId = 0,
    .spacing = 2,
    .lineHeight = 1.4f
})
```

### 5. Layout Direction

```c
// Vertical stack (default)
CLAY(CLAY_ID("Container"), {
    .layout = {
        .layoutDirection = CLAY_TOP_TO_BOTTOM,
        .childGap = 8
    }
}) {
    CLAY_TEXT(...);
    CLAY_TEXT(...);
}

// Horizontal row
CLAY(CLAY_ID("Row"), {
    .layout = {
        .layoutDirection = CLAY_LEFT_TO_RIGHT,
        .childGap = 16
    }
}) {
    CLAY_TEXT(...);
    CLAY_TEXT(...);
}
```

## Common Patterns

### Pattern 1: Sidebar Layout

```c
void SidebarLayout(void) {
    CLAY(CLAY_ID("AppContainer"),
        CLAY_LAYOUT({
            .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_GROW(0) },
            .padding = CLAY_PADDING_ALL(16),
            .childGap = 16
        })
    ) {
        // Sidebar
        CLAY(CLAY_ID("SideBar"),
            CLAY_LAYOUT({
                .layoutDirection = CLAY_TOP_TO_BOTTOM,
                .sizing = { .width = CLAY_SIZING_FIXED(250), .height = CLAY_SIZING_GROW(0) },
                .padding = CLAY_PADDING_ALL(16),
                .childGap = 8,
                .childAlignment = { .x = CLAY_ALIGN_X_LEFT }
            }),
            CLAY_BACKGROUND_COLOR({ 40, 40, 50, 255 }),
            CLAY_CORNER_RADIUS(12)
        ) {
            CLAY_TEXT(CLAY_STRING("Menu"), CLAY_TEXT_CONFIG({
                .fontSize = 24, .textColor = WHITE
            }));
            // Menu items...
        }

        // Main content area
        CLAY(CLAY_ID("MainContent"),
            CLAY_LAYOUT({
                .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_GROW(0) },
                .padding = CLAY_PADDING_ALL(16)
            }),
            CLAY_BACKGROUND_COLOR({ 20, 20, 30, 255 }),
            CLAY_CORNER_RADIUS(12)
        ) {
            // Dynamic content...
        }
    }
}
```

### Pattern 2: Scrolling Container

```c
void ScrollableList(void) {
    Clay_ScrollContainerConfig config = {
        .verticalScrollbar = {
            .trackColor = { 50, 50, 50, 255 },
            .thumbColor = { 100, 100, 100, 255 },
            .thumbWidth = 8
        }
    };

    CLAY(CLAY_ID("ScrollContainer"), config,
        CLAY_LAYOUT({
            .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_GROW(0) },
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
            .childGap = 8
        }),
        CLAY_CLIP({ .vertical = true })
    ) {
        // Content auto-scrolls
        for (int i = 0; i < 50; i++) {
            CLAY(CLAY_IDI("ListItem", i),
                CLAY_LAYOUT({ .padding = CLAY_PADDING_ALL(12) }),
                CLAY_BACKGROUND_COLOR({ 30, 30, 40, 255 }),
                CLAY_CORNER_RADIUS(8)
            ) {
                CLAY_TEXT(CLAY_STRINGF("Item %d", i), ...);
            }
        }
    }
}
```

### Pattern 3: Interactive Button

```c
void Button(Clay_String text, Clay_Color bgColor, void (*onClick)(void)) {
    static Clay_ElementId hoveredId = { 0 };

    if (Clay_Hovered()) {
        CLAY(CLAY_STRINGE("Button"),
            CLAY_LAYOUT({ .padding = CLAY_PADDING_ALL(16) }),
            CLAY_BACKGROUND_COLOR(bgColor),
            CLAY_CORNER_RADIUS(8),
            CLAY_ON_HOVER(ButtonHoverHandler, NULL)
        ) {
            // Button was hovered this frame
        }
    } else {
        // Normal state
    }
}

// Usage
CLAY(CLAY_ID("MyButton"), ...) {
    Clay_OnHover(HandleClick, &buttonData);
    CLAY_TEXT(CLAY_STRING("Click me!"), textConfig);
}
```

### Pattern 4: Floating Tooltip

```c
void TooltipExample(void) {
    CLAY(CLAY_ID("ParentElement"), ...) {
        CLAY(CLAY_ID("Tooltip"),
            CLAY_LAYOUT({ .padding = CLAY_PADDING_ALL(8) }),
            CLAY_BACKGROUND_COLOR({ 0, 0, 0, 200 }),
            CLAY_CORNER_RADIUS(4),
            CLAY_FLOATING({
                .attachTo = CLAY_ATTACH_TO_PARENT,
                .zIndex = 1,
                .attachment = {
                    .element = CLAY_ATTACH_POINT_CENTER_BOTTOM,
                    .parent = CLAY_ATTACH_POINT_CENTER_TOP
                }
            })
        ) {
            CLAY_TEXT(CLAY_STRING("Tooltip text!"), textConfig);
        }
    }
}
```

### Pattern 5: Grid Layout

```c
void GridExample(void) {
    CLAY(CLAY_ID("Grid"),
        CLAY_LAYOUT({
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
            .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_GROW(0) },
            .childGap = 16
        })
    ) {
        // Create rows
        for (int row = 0; row < 3; row++) {
            CLAY(CLAY_IDI("GridRow", row),
                CLAY_LAYOUT({
                    .layoutDirection = CLAY_LEFT_TO_RIGHT,
                    .sizing = { .width = CLAY_SIZING_GROW(0) },
                    .childGap = 16
                })
            ) {
                // Create cells in row
                for (int col = 0; col < 4; col++) {
                    CLAY(CLAY_IDI("Cell", row * 4 + col),
                        CLAY_LAYOUT({
                            .sizing = {
                                .width = CLAY_SIZING_PERCENT(0.25f),
                                .height = CLAY_SIZING_FIXED(100)
                            }
                        }),
                        CLAY_BACKGROUND_COLOR({ 50, 50, 60, 255 }),
                        CLAY_CORNER_RADIUS(8)
                    ) {}
                }
            }
        }
    }
}
```

### Pattern 6: Modal/Dialog

```c
void ModalDialog(Clay_String title, Clay_String message) {
    CLAY(CLAY_ID("Backdrop"),
        CLAY_LAYOUT({ .sizing = { .width = CLAY_SIZING_GROW(0), .height = CLAY_SIZING_GROW(0) } }),
        CLAY_BACKGROUND_COLOR({ 0, 0, 0, 128 }),
        CLAY_FLOATING({
            .attachTo = CLAY_ATTACH_TO_ROOT,
            .zIndex = 100,
            .attachment = {
                .element = CLAY_ATTACH_POINT_CENTER,
                .parent = CLAY_ATTACH_POINT_CENTER
            }
        })
    ) {
        CLAY(CLAY_ID("Dialog"),
            CLAY_LAYOUT({
                .layoutDirection = CLAY_TOP_TO_BOTTOM,
                .sizing = { .width = CLAY_SIZING_FIXED(400), .height = CLAY_SIZING_FIT(100, 600) },
                .padding = CLAY_PADDING_ALL(24),
                .childGap = 16,
                .childAlignment = { .x = CLAY_ALIGN_X_CENTER }
            }),
            CLAY_BACKGROUND_COLOR({ 30, 30, 40, 255 }),
            CLAY_CORNER_RADIUS(16),
            CLAY_BORDER({ .width = CLAY_BORDER_WIDTH_ALL(2), .color = { 100, 100, 120, 255 } })
        ) {
            CLAY_TEXT(title, titleConfig);
            CLAY_TEXT(message, bodyConfig);
            // Buttons...
        }
    }
}
```

## Element IDs

### Creating IDs

```c
CLAY(CLAY_ID("UniqueId"), ...)           // String ID
CLAY(CLAY_IDI("Item", index), ...)       // Indexed ID for lists
CLAY_AUTO_ID(... )                       // Auto-generated (not persistent)
```

### Checking IDs

```c
Clay_ElementId id = Clay_GetElementId(CLAY_STRING("Button"));
if (id.equals(hash)) { /* handle */ }
```

## Event Handling

### Pointer State

```c
Clay_SetPointerState((Clay_Vector2){x, y}, isPressed);

// Check if element is hovered
if (Clay_Hovered()) { /* element is hovered */ }

// Attach hover/click handlers
CLAY(..., CLAY_ON_CLICK(Handler, userData));
CLAY(..., CLAY_ON_HOVER(Handler, userData));
```

### Scroll Handling

```c
Clay_UpdateScrollContainers(
    true,                    // handle external scroll
    (Clay_Vector2){0, delta}, // scroll delta
    deltaTime               // time since last frame
);

// Get scroll offset for clipping
Clay_Vector2 scrollOffset = Clay_GetScrollOffset();
```

## Render Command Types

```c
typedef enum {
    CLAY_RENDER_COMMAND_TYPE_NONE,
    CLAY_RENDER_COMMAND_TYPE_RECTANGLE,
    CLAY_RENDER_COMMAND_TYPE_TEXT,
    CLAY_RENDER_COMMAND_TYPE_IMAGE,
    CLAY_RENDER_COMMAND_TYPE_SCISSOR_START,
    CLAY_RENDER_COMMAND_TYPE_SCISSOR_END,
    CLAY_RENDER_COMMAND_TYPE_CUSTOM
} Clay_RenderCommandType;
```

## Text Measuring

You must provide a text measuring function:

```c
Clay_Dimensions MeasureText(Clay_String text, Clay_TextConfig config, float *wrapWidth) {
    // Return { width, height } of measured text
    // wrapWidth contains max width before wrapping
    return (Clay_Dimensions){
        .width = MeasureStringWidth(text.chars, config->fontId),
        .height = config->fontSize * 1.2f  // line height
    };
}

Clay_SetMeasureTextFunction(MeasureText, NULL);
```

## Debug Mode

Enable built-in debug tools:

```c
Clay_SetDebugModeEnabled(true);  // Shows layout inspector overlay
```

## Tips for Better UIs

1. **Use consistent spacing** — define a spacing scale (8, 16, 24, 32)

2. **Group related elements** — wrap related items in containers

3. **Use fit sizing for dynamic content** — `CLAY_SIZING_FIT()` grows with children

4. **Handle scrolling efficiently** — only render visible items

5. **Use `CLAY_IDI` for lists** — indexed IDs prevent duplicate hash collisions

6. **Reset arena each frame** — `Clay_Initialize()` resets the memory arena

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Elements not visible | Check `.backgroundColor` alpha is 255 |
| Text overflowing | Ensure `.sizing.width` uses `GROW` or `PERCENT` |
| Scroll not working | Call `Clay_UpdateScrollContainers()` each frame |
| Text measure errors | Implement and register `MeasureText` function |
| Wrong z-order | Use `.floating.zIndex` for layered elements |
| Memory issues | Increase arena size if hitting limits |

## Resources

- **GitHub**: https://github.com/nicbarker/clay
- **Website**: https://clay-ui.com
- **Discord**: https://discord.gg clay-ui
- **Examples**: https://github.com/nicbarker/clay/tree/main/examples
- **Zig binding**: `sobesteding/raylib-zig` includes clay

## Bindings by Language

| Language | Binding |
|----------|---------|
| C | Native (clay.h) |
| Zig | `sobesteding/raylib-zig` |
| Rust | `joh1ahes/clay` |
| Odin | `bindings/odin/` |
| C# | `bindings/csharp/` |
| Go | `glay`, `goclay` |
| C++ | ClayMan wrapper |
