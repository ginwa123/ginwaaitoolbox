"""Smoke test: pipe a tools/list + tools/call, verify the responses."""
import subprocess
import sys
import time
import os

def frame(body: str) -> bytes:
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body.encode()

req = (
    frame('{"jsonrpc":"2.0","id":"1","method":"tools/list"}')
    + frame('{"jsonrpc":"2.0","id":"2","method":"tools/call","params":{"name":"print_hello","arguments":{"name":"Alice"}}}')
    + frame('{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"print_name"}}')
)

p = subprocess.Popen(
    ["node", "dist/index.js"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    bufsize=0,
)
# Write the request and let the server process it. Then read stdout
# (don't close stdin — let the server keep running).
p.stdin.write(req)
p.stdin.flush()

# Read with a timeout, giving the server time to respond
import select
out_chunks = []
start = time.time()
while time.time() - start < 3:
    r, _, _ = select.select([p.stdout], [], [], 0.5)
    if r:
        chunk = p.stdout.read1(4096)
        if not chunk:
            break
        out_chunks.append(chunk)
    else:
        # No more data coming; we're done
        break

p.kill()
out = b"".join(out_chunks).decode(errors="replace")
print("=== STDOUT ===")
print(out[:1500])
print(f"\n=== EXIT CODE: {p.returncode} ===")
