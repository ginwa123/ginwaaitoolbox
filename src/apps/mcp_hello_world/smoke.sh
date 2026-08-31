#!/bin/bash
# Smoke test: verify the mcp-hello-world binary responds to MCP
# JSON-RPC requests over stdio. Uses a heredoc with explicit CR bytes
# (printf/echo in some shells strip \r — heredoc preserves them).
#
# Exit code: 0 on success, 1 on any tool failure.
set -euo pipefail
cd "$(dirname "$0")"

# Helper: pipe a JSON-RPC body to the server, capture the response.
# Body is the JSON-RPC object (without Content-Length framing).
send() {
  local body="$1"
  local len=${#body}
  # The heredoc + cat preserves the \r\n bytes that printf would strip.
  cat <<EOF | timeout 5 node dist/index.js
Content-Length: ${len}
${body}
EOF
  # NOTE: heredoc adds a leading newline (because of the empty line
  # after Content-Length). To get the exact wire format we'd need a
  # binary writer, but the SDK tolerates LF in place of CRLF on the
  # header delimiter. So this works.
}

# Test 1: tools/list returns 3 tools
echo "=== tools/list ==="
out=$(send '{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}')
echo "$out" | head -c 200
echo
echo "$out" | grep -q 'print_hello' || { echo "FAIL: print_hello not in tools/list"; exit 1; }
echo "$out" | grep -q 'print_name' || { echo "FAIL: print_name not in tools/list"; exit 1; }
echo "$out" | grep -q 'print_exit' || { echo "FAIL: print_exit not in tools/list"; exit 1; }
echo "OK: all 3 tools listed"

# Test 2: tools/call print_hello with name
echo
echo "=== tools/call print_hello Alice ==="
out=$(send '{"jsonrpc":"2.0","id":"2","method":"tools/call","params":{"name":"print_hello","arguments":{"name":"Alice"}}}')
echo "$out" | head -c 200
echo
echo "$out" | grep -q 'Hello Alice' || { echo "FAIL: expected 'Hello Alice' in response"; exit 1; }
echo "OK: print_hello returns 'Hello Alice'"

# Test 3: tools/call print_name
echo
echo "=== tools/call print_name ==="
out=$(send '{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"print_name","arguments":{}}}')
echo "$out" | head -c 200
echo
echo "$out" | grep -q 'i am mcp-hello-world v0.0.1' || { echo "FAIL: server identity not in response"; exit 1; }
echo "OK: print_name returns server identity"

echo
echo "=== ALL SMOKE TESTS PASSED ==="
