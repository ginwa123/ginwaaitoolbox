


# nalarcore-cli

## Usage

```
nalarcore [options]
```

### Options

| Flag | Long form | Description |
|------|-----------|-------------|
| `-q <prompt>` | `--query <prompt>` | Send a query prompt |
| `-c <session_id>` | `--continue <session_id>` | Resume an existing session |
| `-h` | `--help` | Show help |
| `-v` | `--version` | Print version |

---

## Examples

**Run a one-shot query:**

```bash
nalarcore -q "What is the capital of France?"
```

**Continue a previous session:**

```bash
nalarcore -c abc123 -q "Now summarize that in one sentence."
```

**Start an interactive session:**

```bash
nalarcore
```

---

## Sessions

Sessions allow you to maintain context across multiple queries. When you run a query, a `session_id` is returned in the response. Pass it back with `-c` to continue that conversation thread.

```bash
# First query — note the session_id in the output
nalarcore -q "Explain recursion"
# → session: f7e3a1b2

# Follow-up in the same session
nalarcore -c f7e3a1b2 -q "Give me a Python example"
```

Session IDs are persistent and can be reused across terminal sessions.

