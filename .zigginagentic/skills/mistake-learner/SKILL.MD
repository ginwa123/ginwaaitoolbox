---
name: mistake-learner
description: "Automatically triggered whenever the AI makes a mistake in code syntax, queries, commands, or any technical output. Creates a persistent learning system that captures what went wrong and applies fixes to prevent recurrence. Use whenever you encounter compilation errors, runtime errors, query failures, or any error message."
---

# Mistake Learner

## Overview

Every mistake is a learning opportunity. This skill ensures the AI systematically captures, analyzes, and learns from its errors to continuously improve.

## When to Activate

This skill activates automatically when:
- You encounter a compilation error (syntax, type, import errors)
- You get a runtime error or exception
- A query fails (SQL, API, shell command)
- You receive any error message from a tool or system
- The user points out a mistake you made

## The Learning Protocol

### Step 1: Capture the Mistake

Create a learning entry immediately when any error occurs:

```
### Mistake Record
- **Error Type**: [syntax|type|logic|query|command|other]
- **Context**: [what you were trying to do]
- **Error Message**: [exact error message]
- **Location**: [file:line or command that failed]
- **What Went Wrong**: [brief explanation]
- **The Fix**: [what you changed to fix it]
- **Lesson Learned**: [generalizable takeaway]
- **Prevention**: [how to avoid this in the future]
```

### Step 2: Create/Update Learning File

Maintain a persistent learning file at `.ai-learning/mistakes.json` (or `.ai-learning/mistakes.md` for readability):

```json
{
  "mistakes": [
    {
      "id": "unique-id",
      "timestamp": "ISO-8601",
      "error_type": "syntax",
      "language": "zig",
      "context": "creating ArrayList",
      "error_message": "ArrayList.init is deprecated, use ArrayList.empty",
      "lesson": "Zig 0.15 changed ArrayList API - init() renamed to empty()",
      "prevention": "Always check for API changes when using new Zig versions"
    }
  ],
  "patterns": {
    "zig": ["ArrayList API changes", "format string changes", "allocator changes"],
    "sql": ["syntax errors", "type mismatches"],
    "shell": ["command not found", "path issues"]
  }
}
```

### Step 3: Analyze for Patterns

After each mistake, check if it matches any known pattern:
1. Look at existing entries in the learning file
2. If similar mistake exists, increment its occurrence count
3. If it's a new pattern, add it to the patterns list
4. Update any general prevention rules

### Step 4: Apply the Learning

Before similar tasks in the future:
1. Search the learning file for related mistakes
2. Apply the prevention rules proactively
3. Double-check the specific area where mistakes occurred
4. Test thoroughly in the affected area

## Example Mistakes to Learn From

### Programming Syntax
- Wrong function call syntax
- Incorrect API usage (deprecated methods)
- Type mismatches
- Missing imports or dependencies

### Query Errors
- SQL syntax errors
- Wrong query parameters
- Missing WHERE clauses
- Join mistakes

### Command Errors
- Wrong flag/argument
- Incorrect path
- Missing required arguments
- Permission issues

## Anti-Patterns to Avoid

1. **Don't just fix and forget** - Always record the lesson
2. **Don't dismiss the error** - Every error has a cause
3. **Don't repeat the same mistake** - Check the learning file before similar tasks
4. **Don't be vague** - Record specific error messages and exact fixes

## Key Principles

- **Immediate capture** - Record the mistake before moving on
- **Specific lessons** - Don't write generic "be more careful", write specific takeaways
- **Actionable prevention** - Write concrete steps to avoid the mistake
- **Pattern recognition** - Look for recurring issues across mistakes
- **Proactive checking** - Before similar tasks, consult the learning file

## Integration with Other Skills

- Works with **systematic-debugging** - Capture lessons from debugging sessions
- Works with **skill-creator** - Use mistake patterns to improve other skills
- Works with **verification-before-completion** - Double-check areas with past mistakes

## The Learning Mindset

Every error message is feedback. Every exception is teaching you something. The goal is to:
1. Make the mistake once
2. Record what you learned
3. Never make the same mistake twice

This creates a continuously improving system that gets better over time.