# Clay Declarative DSL — SwiftUI/Jetpack Compose Style

## Goal

Create a fluent, declarative UI DSL for Clay UI in Zig with SwiftUI/Compose syntax:

```zig
UI(.{
    .id = .ID("SideBar"),
    .layout = .{
        .direction = .top_to_bottom,
        .sizing = .{ .w = .fixed(300), .h = .grow },
        .padding = .all(16),
    },
    .background_color = grey,
})({
    // Child elements here
});
```

## Design Decisions

| Decision | Choice |
|----------|--------|
| Syntax | `UI(.{config})({ children })` — Option A |
| Field naming | SwiftUI style: `.background_color`, `.sizing_w`, `.layout_direction` |
| Children | Blocks `({ ... })` — imperative code inside |
| Approach | Comptime-powered for type safety and validation |

## Architecture

```
src/apps/desktop/
├── clay_dsl/
│   ├── types.zig       # Config structs (Layout, Sizing, Padding, etc.)
│   ├── helpers.zig      # .fixed(), .grow(), .all() shorthand functions
│   ├── ids.zig          # .ID() function for element IDs
│   ├── ui.zig           # Main UI() callable struct
│   ├── element.zig      # Element functions (Text, Rectangle, etc.)
│   ├── children.zig     # #children helper
│   └── main.zig         # Re-exports + usage examples
├── clay_ui.zig          # Existing C wrapper (keep for compatibility)
└── main.zig             # Updated to use DSL
```

## Core Types (types.zig)

```zig
pub const Layout = struct {
    direction: Direction = .top_to_bottom,
    sizing: Sizing = .{},
    padding: Padding = .{},
    child_alignment: Alignment = .{},
    child_gap: f32 = 0,
    // ...
};

pub const Sizing = struct {
    w: SizingAxis = .auto,
    h: SizingAxis = .auto,
};

pub const SizingAxis = enum { auto, grow, fill, fixed: u32, percent: f32 };

pub const Padding = union(enum) {
    all: u32,
    sides: struct { x: u32, y: u32 },
    individual: struct { top: u32, right: u32, bottom: u32, left: u32 },
};

pub const Direction = enum { top_to_bottom, bottom_to_top, left_to_right, right_to_left };

pub const Alignment = struct {
    x: AlignmentX = .left,
    y: AlignmentY = .top,
};
```

## Helper Functions (helpers.zig)

```zig
pub fn fixed(comptime value: u32) SizingAxis { return .{ .fixed = value }; }
pub fn grow() SizingAxis { return .grow; }
pub fn fill() SizingAxis { return .fill; }
pub fn percent(comptime value: f32) SizingAxis { return .{ .percent = value }; }
pub fn auto() SizingAxis { return .auto; }

pub fn all(comptime value: u32) Padding { return .{ .all = value }; }
pub fn sides(comptime x: u32, y: u32) Padding { return .{ .sides = .{ .x = x, .y = y } }; }

pub const left = AlignmentX.left;
pub const center = AlignmentX.center;
pub const right = AlignmentX.right;
pub const top = AlignmentY.top;
pub const bottom = AlignmentY.bottom;
```

## ID Function (ids.zig)

```zig
pub const ID = struct {
    string: [:0]const u8,
    hash: u64,
    
    pub fn init(str: []const u8) ID {
        return .{
            .string = str,
            .hash = @import("clay").Clay__HashString(str, 0).id,
        };
    }
};

pub fn ID(str: []const u8) ID { return ID.init(str); }
```

## Main UI Callable (ui.zig)

```zig
pub const UI = struct {
    /// UI(.{config}) - returns ConfigBuilder
    pub fn call(comptime config: anytype) ConfigBuilder {
        return ConfigBuilder{ .config = config };
    }
};

pub const ConfigBuilder = struct {
    config: anytype,
    
    /// builder({children}) - generates element
    pub fn call(self: ConfigBuilder, comptime children: anytype) void {
        comptime generate_element(self.config, children);
    }
};

comptime {
    fn generate_element(comptime config: anytype, comptime children: anytype) void {
        // 1. Open element
        Clay__OpenElementWithId(ID(config.id));
        
        // 2. Configure with translated config
        Clay__ConfigureOpenElement(translate_config(config));
        
        // 3. Execute children block
        @compileLog("Running children...");  // placeholder
        children();
        
        // 4. Close element
        Clay__CloseElement();
    }
}
```

## Usage Examples

### Basic
```zig
UI(.{
    .id = .ID("AppBar"),
    .layout = .{
        .sizing = .{ .w = .fixed(400), .h = .fixed(60) },
    },
    .background_color = colors.blue,
})({});
```

### With Children
```zig
UI(.{
    .id = .ID("SideBar"),
    .layout = .{
        .direction = .top_to_bottom,
        .sizing = .{ .w = .fixed(300), .h = .grow },
        .padding = .all(16),
        .child_gap = 16,
    },
    .background_color = colors.grey,
})({
    UI(.{
        .id = .ID("Logo"),
        .layout = .{ .sizing = .{ .w = .fill, .h = .fixed(50) } },
    })({});
    
    UI(.{
        .id = .ID("Menu"),
        .layout = .{ .direction = .top_to_bottom, .child_gap = 8 },
    })({
        MenuItem("Home");
        MenuItem("Settings");
    });
});
```

### Text Element
```zig
Text("Hello World").color(colors.white).size(16);
```

## Implementation Phases

### Phase 1: Core Types & Helpers
- [ ] Create `types.zig` with Layout, Sizing, Padding, Direction, Alignment
- [ ] Create `helpers.zig` with .fixed(), .grow(), .all() etc.
- [ ] Create `ids.zig` with .ID() function

### Phase 2: Config Translation
- [ ] Create translation layer C config → DSL config
- [ ] Add .toClay() method to all types

### Phase 3: UI() Callable
- [ ] Create `ui.zig` with UI struct and ConfigBuilder
- [ ] Implement comptime element generation

### Phase 4: Element Functions
- [ ] Create `element.zig` with Text, Rectangle, etc.
- [ ] Add fluent methods (.color(), .size(), etc.)

### Phase 5: Integration
- [ ] Update main.zig to use DSL
- [ ] Verify build works
- [ ] Add comprehensive examples

## Risks

| Risk | Mitigation |
|------|------------|
| Comptime limitations with dynamic IDs | Use string literals only, validated at compile |
| Config translation complexity | Start simple, add features incrementally |
| Performance of comptime calls | Benchmark and optimize if needed |

## Open Questions

- None — all decisions captured above
