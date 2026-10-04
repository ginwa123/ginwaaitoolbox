"""Wire test: the `list_directory` tool no longer ABORTS the worker when the
LLM passes a RELATIVE path.

Crash being locked down (task_1790256349339_0)
=============================================
The model called `list_directory` with `{"path":"frontend/src"}`. The exec
wrapper forwarded that relative string straight into
`std.Io.Dir.openDirAbsolute`, whose precondition is
`assert(path.isAbsolute(...))`. In a Debug build that assertion is
`unreachable`, so instead of returning an error the process called
`std.process.abort()`:

    thread 4117285 panic: reached unreachable code
    /usr/lib/zig/std/Io/Dir.zig:486:11 in openDirAbsolute  assert(path.isAbsolute(absolute_path));
    list_directory.zig:68 in execute_list_directory
    tools_exec_list_directory.zig:34 in execListDirectory
    handle_tool.zig:301 in dispatchFromRegistry
    workflow.zig:1593 in runAgenticMultiStepnew
    tools_exec_spawn_sub_agent.zig:265 in runSubAgent
    === CRASH: received signal ABRT (signal number 6) ===

Because the abort happened INSIDE the worker thread (a sub-agent thread in
the reported trace), no `catch` up the stack could intercept it: the whole
`pabrik` process died mid-turn.

Why a wire test and not just the Zig unit tests
==============================================
`tools_exec_list_directory.zig` replays the exact arguments JSON in-process
(Zig tests). This test adds the two things only a real process round-trip
can prove:

  1. **The worker survives.** The pre-fix failure mode is SIGABRT, not an
     error value — only "is this PID still alive after the tool ran?"
     catches a regression that reintroduces a panic on this path.
  2. **Resolution targets the SESSION cwd.** The tool result must name the
     absolute path derived from the session's `cwd` (passed as
     `cwd_session`), because the fix resolves against `ctx.cwd` — not the
     server's process cwd.

Method: boot a real pabrik against an isolated tmpdir HOME, PUT a profile
whose `base_url` is a stub SSE upstream, then POST the real
`/api/llm/session` wire body. The stub answers the agent's first tool-bearing
request with an OpenAI-style `tool_calls` delta for `list_directory` with
`arguments = {"path":"frontend/src",...}` — byte-for-byte the call that
aborted the process — and answers the follow-up request (the one carrying
the tool result) with a plain stop message.

Run:
    PABRIK_BIN=<worktree>/zig-out/bin/pabrikcore-linux-x86_64 \
      python3 -m pytest tests/functional/agent_list_directory_relative_path_test.py -v
"""

from __future__ import annotations

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from harness import FunctionalHarness

# The relative path from the crash report, and the tool call id we can look
# for in the follow-up request (the one that carries the tool RESULT).
RELATIVE_PATH = "frontend/src"
TOOL_CALL_ID = "call_listdir_rel_1"

# Marker strings that appear in the process log only if the worker aborted.
CRASH_MARKERS = (
    "received signal ABRT",
    "reached unreachable code",
    "openDirAbsolute",
    "panic:",
)


def _tool_call_sse() -> bytes:
    """OpenAI-style SSE stream carrying a tool_call for list_directory.

    `arguments` is the EXACT JSON body the model sent when the worker died
    (`{"path":"frontend/src","hidden":false,"respect_ignore_files":true}`).
    """
    arguments = json.dumps(
        {"path": RELATIVE_PATH, "hidden": False, "respect_ignore_files": True}
    )
    first = {
        "id": "chatcmpl-stub-toolcall",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [
            {
                "index": 0,
                "delta": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": TOOL_CALL_ID,
                            "type": "function",
                            "function": {
                                "name": "list_directory",
                                "arguments": arguments,
                            },
                        }
                    ],
                },
                "finish_reason": None,
            }
        ],
    }
    final = {
        "id": "chatcmpl-stub-toolcall",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
    }
    body = "".join(
        f"data: {json.dumps(chunk)}\n\n" for chunk in (first, final)
    ) + "data: [DONE]\n\n"
    return body.encode()


def _text_sse(text: str) -> bytes:
    """OpenAI-style SSE stream carrying a plain assistant message."""
    first = {
        "id": "chatcmpl-stub-text",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [
            {
                "index": 0,
                "delta": {"role": "assistant", "content": text},
                "finish_reason": None,
            }
        ],
    }
    final = {
        "id": "chatcmpl-stub-text",
        "object": "chat.completion.chunk",
        "model": "stub-model",
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }
    return ("".join(
        f"data: {json.dumps(chunk)}\n\n" for chunk in (first, final)
    ) + "data: [DONE]\n\n").encode()


class _StubState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: list[bytes] = []
        self.tool_call_served = False

    def note(self, body: bytes) -> bool:
        """Record the request; return True if the tool call should be served.

        Served exactly once, and only for a tool-bearing agent request (the
        session auto-naming call carries no `tools` array). Any request that
        already carries the TOOL RESULT for our call gets a plain reply so
        the agentic loop can finish.
        """
        with self.lock:
            self.requests.append(body)
            if TOOL_CALL_ID.encode() in body:
                return False  # follow-up turn: tool result present
            if not self.tool_call_served and b"list_directory" in body and b'"tools"' in body:
                self.tool_call_served = True
                return True
            return False


class _StubHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args: Any) -> None:  # silence stderr noise
        pass

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b""
        serve_tool_call = self.server.state.note(body)  # type: ignore[attr-defined]
        raw = _tool_call_sse() if serve_tool_call else _text_sse("listed the directory")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def _start_stub() -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _StubHandler)
    server.state = _StubState()  # type: ignore[attr-defined]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def _wait_for_tool_row(
    harness: FunctionalHarness, session_id: str, timeout_s: float = 60.0
) -> dict[str, Any] | None:
    """Poll the session-messages endpoint until the list_directory result lands.

    `handle_tool` writes a PLACEHOLDER row (empty `content`) before dispatch
    and fills it in afterwards, so a row with this `tool_name` alone is not
    proof the tool ran — we wait for the content to appear.
    """
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        r = harness.http(
            "GET",
            f"/api/llm/session/{session_id}/messages",
            params={"sort_by": "created_at", "direction": "asc", "limit": 100},
            expect=200,
        )
        for m in r.json().get("messages", []):
            if m.get("tool_name") != "list_directory":
                continue
            if (m.get("content") or "").strip():
                return m
        # A dead worker never fills the row — fail fast instead of burning
        # the whole timeout on a crashed process.
        if not harness.health():
            return None
        time.sleep(0.5)
    return None


def test_list_directory_relative_path_does_not_abort_worker(default_pabrik_bin: Any) -> None:
    """The exact crash call, end-to-end: worker alive + path resolved."""
    server = _start_stub()
    harness = FunctionalHarness.boot(default_pabrik_bin, stub_llm_profile=True)
    try:
        stub_port = server.server_address[1]
        stub_url = f"http://127.0.0.1:{stub_port}/v1/chat/completions"

        # 1. Point a profile at the stub (mirrors anthropic_chat_headers_test).
        harness.http(
            "PUT",
            "/api/config/pabrik",
            json_body={
                "api_endpoint": stub_url,
                "api_key": "sk-stub-test",
                "model": "stub-model",
                "url_style": "openai",
                "profiles": {
                    "rel-stub": {
                        "model": "stub-model",
                        "base_url": stub_url,
                        "api_key": "sk-stub-test",
                        "url_style": "openai",
                    },
                },
                "active_profile": "rel-stub",
            },
            expect=200,
        )

        # 2. Workspace holding <cwd>/frontend/src/index.ts — the layout the
        #    crashed session had. Lives under the harness tmpdir, never /tmp
        #    bare (teardown only rmtree's the validated tempdir).
        ws = Path(harness.temp_dir) / "rel-path-ws"
        (ws / RELATIVE_PATH).mkdir(parents=True, exist_ok=True)
        (ws / RELATIVE_PATH / "index.ts").write_text("export const x = 1;\n")

        # 3. Start a real worker turn — the sendChatMessage wire body.
        session_id = f"sess_listdir_rel_{int(time.time())}"
        harness.http(
            "POST",
            "/api/llm/session",
            json_body={
                "session_id": session_id,
                "queue_message": "list the frontend/src directory",
                "cwd_session": str(ws),
                "allowed_tools": "list_directory",
                "image_urls": "",
                "selected_profile_model": "rel-stub",
                "is_auto_retry_until_stop": "",
            },
            expect=(200, 201, 500),
        )

        # 4. Wait for the tool result row.
        row = _wait_for_tool_row(harness, session_id)
        state: _StubState = server.state  # type: ignore[attr-defined]
        with state.lock:
            tool_call_served = state.tool_call_served

        # The process must still be alive: pre-fix this aborted.
        log_tail = harness.tail_log(4000)
        assert harness.health(), (
            "pabrik died during the turn — the relative-path abort is back.\n"
            f"--- log tail ---\n{log_tail[-4000:]}"
        )
        for marker in CRASH_MARKERS:
            assert marker not in log_tail, (
                f"log contains crash marker {marker!r}:\n{log_tail[-4000:]}"
            )

        assert tool_call_served, (
            "the stub never served the list_directory tool call, so this run "
            f"proved nothing.\n--- log tail ---\n{log_tail[-4000:]}"
        )
        assert row is not None, (
            "no list_directory tool result row appeared within 60s.\n"
            f"--- log tail ---\n{log_tail[-4000:]}"
        )

        # 5. The result is the resolved ABSOLUTE path under the session cwd,
        #    and the listing succeeded (not an error envelope).
        envelope = json.loads(row["content"])
        assert envelope["tool"] == "list_directory", envelope
        assert envelope["success"] is True, (
            f"tool returned an error envelope instead of a listing: {envelope}"
        )
        expected_dir = str(ws / RELATIVE_PATH)
        assert envelope["data"]["path"] == expected_dir, (
            f"relative path must resolve against the SESSION cwd {expected_dir!r}, "
            f"got {envelope['data']['path']!r}"
        )
        names = [e["name"] for e in envelope["data"]["entries"]]
        assert "index.ts" in names, f"expected index.ts in the listing, got {names}"

        # 6. Params echo what the model sent (the relative form is preserved
        #    on the wire even though the listing used the absolute path).
        assert envelope["parameters"]["path"] == RELATIVE_PATH, envelope["parameters"]
    finally:
        try:
            harness.teardown()
        except Exception:
            pass
        server.shutdown()
