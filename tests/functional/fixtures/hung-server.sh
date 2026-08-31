#!/usr/bin/env bash
# hung-server.sh — a test fixture that simulates a hung MCP stdio server.
#
# Behavior: reads ONE line from stdin (discards it) then sleeps forever
# without writing anything to stdout. This is the worst-case "hung child"
# shape the MCP stdio transport's deadline/cancel-callback plumbing
# (plan 2026-08-28-fix-mcp-stdio-blocking) is designed to recover from
# within ~30s instead of blocking the workflow indefinitely.
#
# Wire shape: when run as an MCP stdio child, the parent sends a
# Content-Length framed JSON-RPC tools/list request on stdin. We read
# ONE line (the request, header + body) and discard it. We never write
# to stdout. The parent's `recv()` will block forever waiting for the
# first byte — until the deadline fires (30s default) or the cancel
# callback returns true.
#
# Tests that use this fixture:
#   tests/functional/mcp_stdio_hang_test.py — verifies the workflow
#   resumes within the deadline budget instead of hanging the suite.

set -eu

# Read ONE line from stdin and discard it. Then sleep forever.
# The parent expects a JSON response on stdout — we never provide one.
read -r _discarded || true

# Loop sleeping — a single `sleep infinity` would also work, but
# breaking it into short slices makes SIGKILL cleanup faster if a
# test mistakenly uses SIGTERM (we don't today; the registry's
# `child.kill` uses SIGKILL on POSIX).
while true; do
    sleep 3600
done
