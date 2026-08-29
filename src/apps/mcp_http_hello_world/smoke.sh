#!/bin/bash
# Smoke test: verify the mcp-http-hello-world binary responds to MCP
# JSON-RPC requests over the Streamable HTTP transport.
#
# Spins up the binary on a random port, curls the /mcp endpoint with a
# tools/list and two tools/call requests, asserts the responses, then
# kills the binary.
#
# Exit code: 0 on success, 1 on any tool failure.
set -euo pipefail
cd "$(dirname "$0")"

# Pick a random port in the dynamic range (49152..65535). curl can
# connect to 127.0.0.1 only; the binary binds to 127.0.0.1 per the
# spec's "SHOULD bind only to localhost" for local servers.
PORT="${PORT:-${1:-0}}"
if [ "$PORT" = "0" ]; then
  PORT=$(shuf -i 49152-65535 -n 1)
fi

# Start the binary in the background, capture stderr to a tmpfile so we
# can wait for the "listening on" line without spamming the terminal.
TMPDIR=$(mktemp -d)
ERRFILE="$TMPDIR/stderr"
node dist/index.js "$PORT" 2> "$ERRFILE" &
PID=$!
trap "kill -9 $PID 2>/dev/null || true; rm -rf $TMPDIR" EXIT

# Wait for "listening on" (up to 5s).
for i in $(seq 1 50); do
  if grep -q "listening on" "$ERRFILE" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: mcp-http-hello-world exited before listening"
    cat "$ERRFILE" || true
    exit 1
  fi
  sleep 0.1
done
if ! grep -q "listening on" "$ERRFILE" 2>/dev/null; then
  echo "FAIL: 'listening on' not seen within 5s"
  cat "$ERRFILE" || true
  exit 1
fi

BASE_URL="http://127.0.0.1:$PORT"
COMMON_HEADERS=(
  -H "Content-Type: application/json"
  -H "Accept: application/json, text/event-stream"
  -H "MCP-Protocol-Version: 2025-11-25"
)

# Test 1: tools/list returns 3 tools (response may be JSON or SSE; we
# grep the response body for tool names which appear in both formats).
echo "=== tools/list ==="
out=$(curl -sS -X POST "${COMMON_HEADERS[@]}" \
  -d '{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}' \
  "$BASE_URL/mcp")
echo "$out" | head -c 200
echo
echo "$out" | grep -q 'print_hello' || { echo "FAIL: print_hello not in tools/list"; exit 1; }
echo "$out" | grep -q 'print_name' || { echo "FAIL: print_name not in tools/list"; exit 1; }
echo "$out" | grep -q 'print_exit' || { echo "FAIL: print_exit not in tools/list"; exit 1; }
echo "OK: all 3 tools listed"

# Test 2: tools/call print_hello with name
echo
echo "=== tools/call print_hello Alice ==="
out=$(curl -sS -X POST "${COMMON_HEADERS[@]}" \
  -d '{"jsonrpc":"2.0","id":"2","method":"tools/call","params":{"name":"print_hello","arguments":{"name":"Alice"}}}' \
  "$BASE_URL/mcp")
echo "$out" | head -c 200
echo
echo "$out" | grep -q 'Hello Alice' || { echo "FAIL: expected 'Hello Alice' in response"; exit 1; }
echo "OK: print_hello returns 'Hello Alice'"

# Test 3: tools/call print_name
echo
echo "=== tools/call print_name ==="
out=$(curl -sS -X POST "${COMMON_HEADERS[@]}" \
  -d '{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"print_name","arguments":{}}}' \
  "$BASE_URL/mcp")
echo "$out" | head -c 200
echo
echo "$out" | grep -q 'i am mcp-http-hello-world v0.0.1' || { echo "FAIL: server identity not in response"; exit 1; }
echo "OK: print_name returns server identity"

echo
echo "=== ALL SMOKE TESTS PASSED ==="
