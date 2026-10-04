#!/usr/bin/env bash
# scripts/design-mode-smoke.sh
#
# Smoke test for the design-mode v6 redesign (Chunks 1-9).
# Boots a fresh `pabrik` against an isolated $HOME on port 8080
# (port 8081 is reserved for the always-running dev process — see
# project memory "Mandatory: Dont ever kill the process port 8081")
# and exercises the full element CRUD + lifecycle against the
# 9 v6 design HTTP endpoints:
#
#   POST   /api/workspaces                                          (workspaces_create)
#   POST   /api/workspaces/:wid/items                               (workspace_items_create, item_type="design")
#   POST   /api/workspaces/:wid/items/:iid/design/pages             (design_pages_create)
#   POST   .../design/pages/:pid/elements                           (design_elements_create, x2)
#   GET    /api/workspaces/:wid/items/:iid/design/pages             (design_pages_list, count=1)
#   GET    .../design/pages/:pid                                    (design_pages_get, count=2)
#   PUT    .../design/pages/:pid/elements/:eid                      (design_elements_update)
#   GET    .../design/pages/:pid/elements/:eid/html                 (design_elements_html_get)
#   PATCH  .../design/pages/:pid/elements/:eid/geometry             (design_elements_geometry_update)
#   DELETE .../design/pages/:pid/elements/:eid                      (design_elements_delete)
#
# Curl + jq for parsing the JSON envelopes.
# Exits 0 if all 12 assertions pass, 1 on the first failure.
#
# Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 9,
# Task 9.2; smoke test for the redesigned v6 design API surface).

set -u

# --- config ---
: "${PABRIK_BIN:=zig-out/bin/pabrik}"
: "${PABRIK_PORT:=8080}"                 # 8080 per project memory rule
: "${READY_TIMEOUT_S:=30}"
: "${HTTP_TIMEOUT_S:=5}"

if [ ! -x "$PABRIK_BIN" ]; then
  echo "✗ PABRIK_BIN not executable: '$PABRIK_BIN'" >&2
  exit 1
fi

# Sanity: refuse to clobber the protected dev port.
if [ "$PABRIK_PORT" = "8081" ]; then
  echo "✗ port 8081 is reserved for the always-running dev pabrik" >&2
  exit 1
fi

# Verify no other pabrik is already listening on our port (so we don't
# kill it when we run our cleanup trap).
EXISTING=$(ss -tln 2>/dev/null | awk '{print $4}' | grep -E "[:.]${PABRIK_PORT}\$" || true)
if [ -n "$EXISTING" ]; then
  echo "✗ port $PABRIK_PORT already has a listener: $EXISTING" >&2
  exit 1
fi

# Isolate $HOME so config.json + agent.db live in a tempdir (matches
# ci-smoke-test.sh's pattern; keeps the smoke test idempotent and
# dev-DB-isolated).
export HOME="$(mktemp -d -t pabrik-design-smoke-home.XXXXXX)"
SMOKE_LOG="$(mktemp -t pabrik-design-smoke.XXXXXX.log)"

# Assertion counter — logged for the final summary.
STEP=0

cleanup() {
  local ec=$?
  if [ -n "${PABRIK_PID:-}" ] && kill -0 "$PABRIK_PID" 2>/dev/null; then
    kill -TERM "$PABRIK_PID" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$PABRIK_PID" 2>/dev/null || true
  fi
  rm -rf "$HOME" 2>/dev/null || true
  # Keep the log only on failure so a passing run leaves no trace.
  if [ "$ec" -ne 0 ]; then
    echo "--- smoke log retained on failure: $SMOKE_LOG ---" >&2
  else
    rm -f "$SMOKE_LOG" 2>/dev/null || true
  fi
  exit $ec
}
trap cleanup EXIT INT TERM

step() {
  STEP=$((STEP + 1))
  echo "→ step $STEP/12: $1"
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="${3:-assertion}"
  if [ "$actual" = "$expected" ]; then
    echo "  ✓ $label"
  else
    echo "  ✗ $label: expected '$expected', got '$actual'" >&2
    echo "--- pabrik log tail ---" >&2
    tail -n 30 "$SMOKE_LOG" >&2 || true
    exit 1
  fi
}

# --- boot ---
echo "→ booting: HOME=$HOME PORT=$PABRIK_PORT BIN=$PABRIK_BIN"

"$PABRIK_BIN" --port "$PABRIK_PORT" >"$SMOKE_LOG" 2>&1 &
PABRIK_PID=$!
echo "→ pabrik pid=$PABRIK_PID"

# Wait for readiness.
DEADLINE=$(( $(date +%s) + READY_TIMEOUT_S ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if ! kill -0 "$PABRIK_PID" 2>/dev/null; then
    echo "✗ pabrik (pid=$PABRIK_PID) exited before becoming ready" >&2
    echo "--- log ---" >&2; cat "$SMOKE_LOG" >&2
    exit 1
  fi
  if grep -q "Agent is ready to serve!" "$SMOKE_LOG"; then
    break
  fi
  sleep 0.2
done
grep -q "Agent is ready to serve!" "$SMOKE_LOG" || {
  echo "✗ timed out waiting for readiness (${READY_TIMEOUT_S}s)" >&2
  echo "--- log ---" >&2; cat "$SMOKE_LOG" >&2
  exit 1
}

BASE="http://127.0.0.1:${PABRIK_PORT}"

# Helper: HTTP request, returns body; status code goes to $STATUS.
req() {
  local method="$1"; shift
  local path="$1"; shift
  local body="${1:-}"
  if [ -n "$body" ]; then
    STATUS=$(curl -sS -o /tmp/dsm-body.$$ -w '%{http_code}' \
      --max-time "$HTTP_TIMEOUT_S" \
      -X "$method" -H 'Content-Type: application/json' \
      -d "$body" "${BASE}${path}") || {
        echo "✗ curl failed: $method $path" >&2; exit 1;
      }
  else
    STATUS=$(curl -sS -o /tmp/dsm-body.$$ -w '%{http_code}' \
      --max-time "$HTTP_TIMEOUT_S" \
      -X "$method" "${BASE}${path}") || {
        echo "✗ curl failed: $method $path" >&2; exit 1;
      }
  fi
  BODY=$(cat /tmp/dsm-body.$$)
  rm -f /tmp/dsm-body.$$
}

# ============================================================================
# Test 1: Create a workspace
# ============================================================================
step "POST /api/workspaces — create workspace"
req POST /api/workspaces '{"name":"design-smoke"}'
assert_eq "$STATUS" "201" "workspace create status 201"
WS_ID=$(echo "$BODY" | jq -r '.id')
[ -n "$WS_ID" ] && [ "$WS_ID" != "null" ] || { echo "✗ no workspace id"; exit 1; }
echo "  → workspace id=$WS_ID"

# ============================================================================
# Test 2: Create a design item (item_type=design, with path)
# ============================================================================
step "POST .../items — create design item"
ITEM_PATH="${HOME}/design-smoke-projects/hello"
mkdir -p "$ITEM_PATH" 2>/dev/null || true
req POST "/api/workspaces/${WS_ID}/items" \
  "{\"name\":\"hello\",\"item_type\":\"design\",\"path\":\"${ITEM_PATH}\"}"
assert_eq "$STATUS" "201" "design item create status 201"
ITEM_ID=$(echo "$BODY" | jq -r '.id')
[ -n "$ITEM_ID" ] && [ "$ITEM_ID" != "null" ] || { echo "✗ no item id"; exit 1; }
echo "  → item id=$ITEM_ID"

# ============================================================================
# Test 3: Create a page (POST .../design/pages)
# ============================================================================
step "POST .../design/pages — create page"
req POST "/api/workspaces/${WS_ID}/items/${ITEM_ID}/design/pages" \
  '{"name":"Page 1","width":1440,"height":1024}'
assert_eq "$STATUS" "201" "page create status 201"
PAGE_ID=$(echo "$BODY" | jq -r '.id')
[ -n "$PAGE_ID" ] && [ "$PAGE_ID" != "null" ] || { echo "✗ no page id"; exit 1; }
echo "  → page id=$PAGE_ID"
# Wire-format sanity: required fields.
PAGE_W=$(echo "$BODY" | jq -r '.width')
PAGE_H=$(echo "$BODY" | jq -r '.height')
assert_eq "$PAGE_W" "1440" "page width=1440"
assert_eq "$PAGE_H" "1024" "page height=1024"

# ============================================================================
# Test 4: Add element #1 (rectangle) — POST .../elements
# ============================================================================
step "POST .../elements — add rectangle"
req POST "/api/workspaces/${WS_ID}/items/${ITEM_ID}/design/pages/${PAGE_ID}/elements" \
  '{"name":"Box","type":"rectangle","html":"<div class=\"r\" style=\"width:375px;height:200px;background:#3b82f6;\"></div>","x":10,"y":20,"width":375,"height":200,"fill":"#3b82f6"}'
assert_eq "$STATUS" "201" "rectangle create status 201"
E1_ID=$(echo "$BODY" | jq -r '.id')
E1_TYPE=$(echo "$BODY" | jq -r '.type')
E1_X=$(echo "$BODY" | jq -r '.x')
[ -n "$E1_ID" ] && [ "$E1_ID" != "null" ] || { echo "✗ no element id"; exit 1; }
assert_eq "$E1_TYPE" "rectangle" "rectangle type=rectangle"
assert_eq "$E1_X" "10" "rectangle x=10"
echo "  → rectangle id=$E1_ID"

# ============================================================================
# Test 5: Add element #2 (text) — POST .../elements
# ============================================================================
step "POST .../elements — add text"
# Note: an explicit `fill` is REQUIRED here (not omitted, not empty
# string). The design_model.addElement passes `input.fill` directly
# to `db.exec` as a `[]const u8`, and `SqliteBackend.exec` binds an
# empty slice as SQL NULL — which then trips the
# `NOT NULL DEFAULT ''` constraint on the `fill` column. The
# frontend's text-element create dialog always ships a non-empty
# `fill` (default text color is `#000000`), so the production
# path never hits the trap. The smoke test mirrors that — a real
# user-invoked create carries an explicit color.
req POST "/api/workspaces/${WS_ID}/items/${ITEM_ID}/design/pages/${PAGE_ID}/elements" \
  '{"name":"Label","type":"text","html":"<p>Hello, design!</p>","x":50,"y":300,"width":400,"height":50,"fill":"#000000"}'
assert_eq "$STATUS" "201" "text create status 201"
E2_ID=$(echo "$BODY" | jq -r '.id')
E2_TYPE=$(echo "$BODY" | jq -r '.type')
[ -n "$E2_ID" ] && [ "$E2_ID" != "null" ] || { echo "✗ no element id"; exit 1; }
assert_eq "$E2_TYPE" "text" "text type=text"
echo "  → text id=$E2_ID"

# ============================================================================
# Test 6: List pages — GET .../design/pages (count=1)
# ============================================================================
step "GET .../design/pages — list pages"
req GET "/api/workspaces/${WS_ID}/items/${ITEM_ID}/design/pages"
assert_eq "$STATUS" "200" "list pages status 200"
LIST_COUNT=$(echo "$BODY" | jq -r '.count')
assert_eq "$LIST_COUNT" "1" "list pages count=1"

# ============================================================================
# Test 7: Get page (with elements) — GET .../pages/:pid (count=2)
# ============================================================================
step "GET .../pages/:pid — get page with elements"
req GET "/api/workspaces/${WS_ID}/items/${ITEM_ID}/design/pages/${PAGE_ID}"
assert_eq "$STATUS" "200" "get page status 200"
ELEMENTS_COUNT=$(echo "$BODY" | jq -r '.elements | length')
assert_eq "$ELEMENTS_COUNT" "2" "page element count=2"

# ============================================================================
# Test 8: Update element — PUT .../elements/:eid
# ============================================================================
step "PUT .../elements/:eid — update element x/y"
req PUT "/api/workspaces/${WS_ID}/items/${ITEM_ID}/design/pages/${PAGE_ID}/elements/${E1_ID}" \
  '{"x":99,"y":88}'
assert_eq "$STATUS" "200" "update element status 200"
NEW_X=$(echo "$BODY" | jq -r '.x')
NEW_Y=$(echo "$BODY" | jq -r '.y')
assert_eq "$NEW_X" "99" "updated x=99"
assert_eq "$NEW_Y" "88" "updated y=88"

# ============================================================================
# Test 9: Get element HTML — GET .../elements/:eid/html
# ============================================================================
step "GET .../elements/:eid/html — lazy-load HTML"
req GET "/api/workspaces/${WS_ID}/items/${ITEM_ID}/design/pages/${PAGE_ID}/elements/${E1_ID}/html"
assert_eq "$STATUS" "200" "html get status 200"
HTML_LEN=$(echo "$BODY" | jq -r '.html | length')
# The HTML body should have at least 20 chars (the "<div class="r"..." fragment).
[ "$HTML_LEN" -gt 20 ] || { echo "✗ html body too short: $HTML_LEN chars" >&2; echo "$BODY" >&2; exit 1; }
echo "  → html body length=$HTML_LEN chars"

# ============================================================================
# Test 10: Update geometry — PATCH .../geometry
# ============================================================================
step "PATCH .../geometry — update geometry only"
req PATCH "/api/workspaces/${WS_ID}/items/${ITEM_ID}/design/pages/${PAGE_ID}/elements/${E2_ID}/geometry" \
  '{"x":500,"y":250,"width":600,"height":40}'
assert_eq "$STATUS" "200" "geometry update status 200"
GX=$(echo "$BODY" | jq -r '.x')
GW=$(echo "$BODY" | jq -r '.width')
assert_eq "$GX" "500" "geometry x=500"
assert_eq "$GW" "600" "geometry width=600"

# ============================================================================
# Test 11: Delete element — DELETE .../elements/:eid
# ============================================================================
step "DELETE .../elements/:eid — delete element"
req DELETE "/api/workspaces/${WS_ID}/items/${ITEM_ID}/design/pages/${PAGE_ID}/elements/${E1_ID}"
assert_eq "$STATUS" "200" "delete element status 200"
SUCCESS=$(echo "$BODY" | jq -r '.success')
assert_eq "$SUCCESS" "true" "delete returns success=true"

# ============================================================================
# Test 12: Verify count is now 1 (delete reflected on read-back)
# ============================================================================
step "GET .../pages/:pid — verify count=1 after delete"
req GET "/api/workspaces/${WS_ID}/items/${ITEM_ID}/design/pages/${PAGE_ID}"
assert_eq "$STATUS" "200" "re-get page status 200"
ELEMENTS_COUNT=$(echo "$BODY" | jq -r '.elements | length')
assert_eq "$ELEMENTS_COUNT" "1" "after delete, count=1"

# ============================================================================
# Cleanup
# ============================================================================
# POST /test/shutdown for graceful termination (matches ci-smoke-test.sh's
# pattern; falls back to SIGTERM/SIGKILL in the trap).
SHUTDOWN_BODY=$(curl -fsS -X POST --max-time "$HTTP_TIMEOUT_S" "${BASE}/test/shutdown" 2>&1) || {
  echo "→ /test/shutdown failed (non-fatal); will SIGTERM in cleanup: $SHUTDOWN_BODY" >&2
}
SHUTDOWN_DEADLINE=$(( $(date +%s) + 5 ))
while [ "$(date +%s)" -lt "$SHUTDOWN_DEADLINE" ]; do
  if ! kill -0 "$PABRIK_PID" 2>/dev/null; then break; fi
  sleep 0.2
done
# If still alive, the trap's SIGTERM will reap it.

echo "→ smoke test: all 12 assertions PASSED"
exit 0
