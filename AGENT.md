# AGENT.md — Agent Behavior & Learning

> **This file defines how the agent behaves, learns, and improves over time.**

---

## Core Principle: Always Be Learning

Every mistake is a learning opportunity. The agent must:
1. **Capture** — Record every error immediately
2. **Solve** — Fix the immediate problem
3. **Document** — Write the solution to MEMORY.md
4. **Apply** — Consult MEMORY.md before similar tasks

---

## Learning Protocol

### When an Error Occurs

1. **STOP** — Do not fix until you capture the lesson
2. **Capture** — Record in MEMORY.md (see template below)
3. **Fix** — Solve the immediate problem
4. **Verify** — Confirm the fix works
5. **Apply** — You'll reference this in the future

### Mistake Template (Copy this format)

```
### [UNIQUE-ID] - [Brief Title]
**Date:** YYYY-MM-DD
**Error Type:** syntax | type | logic | query | command | other
**Context:** What you were trying to do

**Error Message:**
```
[Exact error text]
```

**Root Cause:** One-line explanation

**Fix:** What was changed to resolve it

**Prevention:**
- [ ] Specific actionable step to avoid this
- [ ] Check MEMORY.md before similar tasks

**Lessons:**
- [Generalizable takeaway]
```

---

## Key Rules

### Before Any Task
- [ ] Check MEMORY.md for relevant past mistakes
- [ ] Load required skills with `list_skills()` and `get_skill()`
- [ ] Classify complexity: Simple | Moderate | Complex

### Hard Rules
- **Never fix an error without first capturing it in MEMORY.md**
- **"Be more careful" is not a lesson** — Write the exact API, flag, or syntax
- **Same mistake twice** — The first capture was skipped or vague
- **Before similar tasks** — Always consult MEMORY.md first

---

## Integration

This AGENT.md works with:
- **MEMORY.md** — The learning database of past mistakes and solutions
- **CLAUDE.md** — Additional context (currently empty)
- **mistake-learner skill** — Detailed learning protocol

---

## Quick Reference

| Trigger | Action |
|---------|--------|
| Compilation error | Capture → Fix → Verify |
| Runtime failure | Capture → Fix → Verify |
| Tool error | Capture → Fix → Verify |
| Query failure | Capture → Fix → Verify |
| User reports mistake | Capture → Fix → Verify |
| About to guess | Re-load skills first |
| Stuck on problem | Re-load skills + check MEMORY.md |
