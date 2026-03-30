---
name: agent-browser
description: "A powerful web research CLI for AI agents. Use for: (1) Web search — find answers, docs, tutorials, best practices. (2) Browser automation — navigate pages, extract data, fill forms. (3) Documentation lookup — research libraries, frameworks, APIs. Always prefer web search when local code lacks answers!"
---

# 🌐 Web Research & Browser Automation

This skill covers **two primary use cases**:
1. **🔍 Web Search** — Research topics, find docs, look up best practices
2. **🖥️ Browser Automation** — Automate web interactions, extract data

---

## 🔍 Part 1: Web Search (PRIMARY for Research!)

### When to Use Search
- ✅ When you need to find information not in local code
- ✅ When documentation is unclear → search for examples
- ✅ When researching libraries, frameworks, or tools
- ✅ When looking up best practices or patterns
- ✅ When debugging and need StackOverflow/GitHub solutions
- ✅ When local code lacks the answer

### Quick Search Commands

```bash
# Simple web search
agent-browser search "how to use React hooks"

# Search and browse to first result
agent-browser search "zig error handling best practices" --open

# Search with specific engine
agent-browser search "typescript generic constraints" --engine google

# Search within a site
agent-browser search "configuration" --site github.com/vercel/next.js
```

### Browse URLs

```bash
# Open and read a web page
agent-browser open https://example.com/docs

# Open with content extraction (simplified view)
agent-browser open https://react.dev/reference/react/useEffect --extract

# Search within a page after opening
agent-browser find text "installation" click
```

### Research Workflow

```bash
# 1. Search for the topic
agent-browser search "best practices for Zig comptime"

# 2. Open promising result
agent-browser open https://zig.godoc.org/

# 3. Extract relevant content
agent-browser snapshot -c

# 4. Find specific sections
agent-browser find text "comptime" text
```

---

## 🖥️ Part 2: Browser Automation

### Installation

```bash
npm install -g agent-browser
agent-browser install
agent-browser install --with-deps
```

### Quick Start (Automation)

```bash
agent-browser open <url>        # Navigate to page
agent-browser snapshot -i       # Get interactive elements with refs
agent-browser click @e1         # Click element by ref
agent-browser fill @e2 "text"   # Fill input by ref
agent-browser close             # Close browser
```

### Core Workflow (Automation)

1. Navigate: `agent-browser open <url>`
2. Snapshot: `agent-browser snapshot -i` (returns elements with refs like `@e1`, `@e2`)
3. Interact using refs from the snapshot
4. Re-snapshot after navigation or significant DOM changes

---

## 📚 Combined Research Examples

### Example 1: Research Library Documentation

```bash
# Find and read library docs
agent-browser search "zustand state management react"
agent-browser open https://zustand.docs.pmnd.rs/

# Navigate to relevant section
agent-browser find text "getting started" click
agent-browser snapshot -c

# Extract code examples
agent-browser find text "create" --role heading text
```

### Example 2: Debug with StackOverflow

```bash
# Search for error solution
agent-browser search "TypeError Cannot read property of undefined JavaScript"

# Open StackOverflow answer
agent-browser open https://stackoverflow.com/questions/...

# Find the accepted answer
agent-browser find text "Answer" click
agent-browser snapshot -c
```

### Example 3: Research Best Practices

```bash
# Search multiple topics in parallel using sub-agents
# Agent 1: agent-browser search "React Server Components best practices"
# Agent 2: agent-browser search "Next.js 14 app router migration guide"

# Then open most relevant pages
agent-browser open https://nextjs.org/docs/app/building-your-application/rendering
agent-browser snapshot -c
```

---

## Commands Reference

### 🔍 Search Commands

```bash
agent-browser search "<query>"                    # Web search
agent-browser search "<query>" --open           # Search and open first result
agent-browser search "<query>" --engine google  # Use specific engine
agent-browser search "<query>" --site example.com  # Search within site
```

### 🌐 Navigation

```bash
agent-browser open <url>              # Navigate to URL
agent-browser open <url> --extract    # Open with content extraction
agent-browser back                     # Go back
agent-browser forward                  # Go forward
agent-browser reload                   # Reload page
agent-browser close                    # Close browser
```

### 📸 Snapshot (Page Analysis)

```bash
agent-browser snapshot            # Full accessibility tree
agent-browser snapshot -i         # Interactive elements only (recommended)
agent-browser snapshot -c         # Compact output
agent-browser snapshot -d 3       # Limit depth to 3
agent-browser snapshot -s "#main" # Scope to CSS selector
agent-browser snapshot --json     # JSON output for parsing
```

### 🎯 Interactions (use @refs from snapshot)

```bash
agent-browser click @e1           # Click
agent-browser dblclick @e1       # Double-click
agent-browser focus @e1           # Focus element
agent-browser fill @e2 "text"     # Clear and type
agent-browser type @e2 "text"     # Type without clearing
agent-browser press Enter         # Press key
agent-browser scroll down 500     # Scroll page
agent-browser check @e1           # Check checkbox
agent-browser select @e1 "value"  # Select dropdown
```

### 🔎 Find Elements

```bash
agent-browser find role button click --name "Submit"
agent-browser find text "Sign In" click
agent-browser find label "Email" fill "user@test.com"
agent-browser find text "installation" text  # Get text content
agent-browser find first ".item" click
agent-browser find nth 2 "a" text
```

### 📊 Get Information

```bash
agent-browser get text @e1        # Get element text
agent-browser get html @e1        # Get innerHTML
agent-browser get value @e1       # Get input value
agent-browser get attr @e1 href   # Get attribute
agent-browser get title           # Get page title
agent-browser get url             # Get current URL
agent-browser get count ".item"   # Count matching elements
```

### ⏳ Wait

```bash
agent-browser wait @e1                     # Wait for element
agent-browser wait 2000                    # Wait milliseconds
agent-browser wait --text "Success"        # Wait for text
agent-browser wait --url "/dashboard"      # Wait for URL pattern
agent-browser wait --load networkidle      # Wait for network idle
```

### 📷 Screenshots & PDF

```bash
agent-browser screenshot              # Screenshot to stdout
agent-browser screenshot path.png     # Save to file
agent-browser screenshot --full      # Full page
agent-browser pdf output.pdf          # Save as PDF
```

---

## Research Tips

### For Best Results:
1. **Start with search** — find the most relevant page first
2. **Use `--extract`** when opening docs for cleaner content
3. **Use compact snapshot** (`-c`) for quick page overview
4. **Use `find text` to locate** specific sections in long docs
5. **Combine with sub-agents** — search multiple topics in parallel

### When NOT to Use Search:
- ❌ When the answer is clearly in local code → use `lsp_*` tools
- ❌ When you've already found the answer
- ❌ For simple file operations → use `read_file`, `search`

### When TO Use Search:
- ✅ Library documentation unclear → search for examples
- ✅ Unknown error → search StackOverflow
- ✅ Best practices needed → search blogs/Reddit
- ✅ Library version compatibility → search changelogs
- ✅ Tutorial needed → search YouTube/Medium/Dev.to

---

## Debugging

```bash
agent-browser open example.com --headed              # Show browser window
agent-browser console                                # View console messages
agent-browser errors                                 # View page errors
agent-browser highlight @e1                          # Highlight element
agent-browser screenshot                            # Take screenshot
```

---

## Troubleshooting

- If search returns unexpected results, try different keywords
- Use `--open` to automatically navigate to first result
- If element not found, re-snapshot after page changes
- Use `--headed` to see browser for debugging

---

## Options

- `--session <name>` — isolated session
- `--json` — JSON output for parsing
- `--full` — full page screenshot
- `--headed` — show browser window
- `--timeout` — command timeout in ms
- `--extract` — extract readable content
