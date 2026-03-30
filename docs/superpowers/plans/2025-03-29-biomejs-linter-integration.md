# Biome.js Linter Integration Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate Biome.js as the linter and formatter for TypeScript/JavaScript files in the project, replacing ESLint/Prettier. Add build.zig integration for automated linting.

**Architecture:** Biome is a fast, unified toolchain for formatting and linting. We'll add it to the desktop-bun app's dependencies, create a configuration file, and wire up a `zig build lint` step that runs Biome on all TypeScript files.

**Tech Stack:** Biome, Bun, Zig Build

---

## Chunk 1: Project Setup & Configuration

### Task 1: Add Biome to package.json

**Files:**
- Modify: `src/apps/desktop-bun/package.json`

- [ ] **Step 1: Update package.json with Biome dependency**

```json
{
  "name": "desktop-bun",
  "version": "0.1.0",
  "type": "module",
  "description": "SolidJS + Electrobun Desktop Application with Tailwind CSS",
  "scripts": {
    "dev": "electrobun dev --watch",
    "dev:hmr": "concurrently \"bun run hmr\" \"bun run start\"",
    "hmr": "vite --port 5173",
    "build": "vite build && electrobun build",
    "build:canary": "vite build && electrobun build --env=canary",
    "lint": "biome check .",
    "lint:fix": "biome check --write .",
    "format": "biome format --write ."
  },
  "dependencies": {
    "@solidjs/router": "^0.15.3",
    "@tanstack/solid-virtual": "^3.13.23",
    "electrobun": "1.16.0",
    "solid-js": "^1.9.3"
  },
  "devDependencies": {
    "@biomejs/biome": "^1.9.0",
    "@tailwindcss/vite": "^4.2.2",
    "@types/bun": "latest",
    "autoprefixer": "^10.4.20",
    "concurrently": "^9.1.0",
    "postcss": "^8.5.1",
    "tailwindcss": "^4.0.6",
    "typescript": "^5.7.2",
    "vite": "^6.0.3",
    "vite-plugin-solid": "^2.11.0"
  }
}
```

- [ ] **Step 2: Run `bun install` to install Biome**

Run: `cd src/apps/desktop-bun && bun install`
Expected: Biome added to node_modules

---

### Task 2: Create Biome Configuration

**Files:**
- Create: `src/apps/desktop-bun/biome.json`

- [ ] **Step 1: Create biome.json with TypeScript/SolidJS configuration**

```json
{
  "$schema": "https://biomejs.dev/schemas/1.9.0/schema.json",
  "vcs": {
    "enabled": true,
    "clientKind": "git",
    "useIgnoreFile": true
  },
  "files": {
    "ignoreUnknown": true,
    "ignore": [
      "node_modules",
      "dist",
      "build",
      "electrobun",
      "target",
      "target-hmr"
    ]
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineEnding": "lf",
    "lineWidth": 100
  },
  "organizeImports": {
    "enabled": true
  },
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "suspicious": {
        "noExplicitAny": "off",
        "noArrayIndexKey": "off"
      },
      "style": {
        "noNonNullAssertion": "off",
        "useImportType": "off"
      },
      "correctness": {
        "noUnusedVariables": "warn"
      }
    }
  },
  "javascript": {
    "formatter": {
      "quoteStyle": "single",
      "semicolons": "always",
      "trailingCommas": "es5",
      "arrowParentheses": "always",
      "bracketSameLine": false,
      "bracketSpacing": true
    }
  },
  "overrides": [
    {
      "include": ["**/*.test.ts"],
      "linter": {
        "rules": {
          "suspicious": {
            "noExplicitAny": "off"
          }
        }
      }
    }
  ]
}
```

---

## Chunk 2: Build.zig Integration

### Task 3: Add lint build step to build.zig

**Files:**
- Modify: `build.zig` (add lint step after test steps, around line 180)

- [ ] **Step 1: Add lint and lint:fix build steps to build.zig**

Add these steps after the `test_desktop_step` definition:

```zig
    // Biome lint step - runs biome check on TypeScript files
    const lint_step = b.step("lint", "Run Biome linter on TypeScript/JS files");
    const run_biome_lint = b.addSystemCommand(&.{"bun", "run", "lint"});
    run_biome_lint.cwd = .{ .cwd_relative = "src/apps/desktop-bun" };
    lint_step.dependOn(&run_biome_lint.step);

    // Biome lint:fix step - runs biome check --write
    const lint_fix_step = b.step("lint:fix", "Run Biome linter with auto-fix on TypeScript/JS files");
    const run_biome_lint_fix = b.addSystemCommand(&.{"bun", "run", "lint:fix"});
    run_biome_lint_fix.cwd = .{ .cwd_relative = "src/apps/desktop-bun" };
    lint_fix_step.dependOn(&run_biome_lint_fix.step);

    // Biome format step
    const format_step = b.step("format", "Format TypeScript/JS files with Biome");
    const run_biome_format = b.addSystemCommand(&.{"bun", "run", "format"});
    run_biome_format.cwd = .{ .cwd_relative = "src/apps/desktop-bun" };
    format_step.dependOn(&run_biome_format.step);
```

Locate this section in build.zig (around line 178):
```zig
    // Desktop Bun tests step - runs bun test in src/apps/desktop-bun
    const test_desktop_step = b.step("test:desktop", "Run desktop app tests (bun test)");
    const run_bun_test = b.addSystemCommand(&.{"bun", "test"});
    run_bun_test.cwd = .{ .cwd_relative = "src/apps/desktop-bun" };
    test_desktop_step.dependOn(&run_bun_test.step);
```

And add the lint steps right after `test_desktop_step`.

- [ ] **Step 2: Verify build.zig syntax**

Run: `zig build --help 2>&1 | grep -E "lint|format"`
Expected: Shows lint, lint:fix, and format steps

---

## Chunk 3: First Run & Verification

### Task 4: Run Biome and fix initial issues

**Files:**
- Modify: Various TypeScript files (as needed based on lint output)

- [ ] **Step 1: Install dependencies**

Run: `cd src/apps/desktop-bun && bun install`
Expected: Biome installed, visible in package.json

- [ ] **Step 2: Run initial lint check**

Run: `cd src/apps/desktop-bun && bun run lint 2>&1 | head -n 50`
Expected: List of lint warnings/errors

- [ ] **Step 3: Run lint:fix to auto-fix issues**

Run: `cd src/apps/desktop-bun && bun run lint:fix`
Expected: Files modified, lint errors resolved

- [ ] **Step 4: Verify lint passes**

Run: `cd src/apps/desktop-bun && bun run lint`
Expected: No errors (warnings OK)

- [ ] **Step 5: Commit initial setup**

```bash
git add src/apps/desktop-bun/biome.json src/apps/desktop-bun/package.json build.zig
git commit -m "feat: add Biome.js linter integration

- Add biome.json with TypeScript/SolidJS configuration
- Add lint, lint:fix, format build steps to build.zig
- Add npm scripts for Biome commands"
```

---

## Chunk 4: CI/CD Integration (Optional Enhancement)

### Task 5: Add Git pre-commit hook (optional)

**Files:**
- Create: `.husky/pre-commit` (if husky is desired)

- [ ] **Step 1: Document usage in README or project docs**

Add to `src/apps/desktop-bun/README.md` or main project README:
```markdown
## Linting & Formatting

This project uses Biome.js for linting and formatting.

### Commands

```bash
# Install dependencies (includes Biome)
cd src/apps/desktop-bun && bun install

# Run linter
bun run lint

# Auto-fix lint issues
bun run lint:fix

# Format code
bun run format
```

### Zig Build Commands

```bash
# Run linter via Zig build
zig build lint

# Auto-fix lint issues via Zig build
zig build lint:fix

# Format code via Zig build
zig build format
```
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Add Biome to package.json | `src/apps/desktop-bun/package.json` |
| 2 | Create biome.json config | `src/apps/desktop-bun/biome.json` |
| 3 | Add build.zig steps | `build.zig` |
| 4 | Run and verify | All TS/JS files |
| 5 | Update docs | README (optional) |

## Verification Commands

```bash
# After all tasks complete:
zig build lint              # Should run Biome linter
zig build lint:fix          # Should auto-fix and show changes
zig build format            # Should format code

# Direct bun commands:
cd src/apps/desktop-bun && bun run lint
cd src/apps/desktop-bun && bun run lint:fix
cd src/apps/desktop-bun && bun run format
```

---

## Dependencies

- **Biome:** `@biomejs/biome@^1.9.0`
- **Runtime:** Bun (already in project)
- **Build:** Zig 0.15.2 (already in project)
