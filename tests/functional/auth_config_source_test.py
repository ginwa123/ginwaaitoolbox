"""Functional test: WHICH config does a chat turn run on when `--auth` is on?

Claim under test (user report, task_1791269107214_11):

    "i think its still use config.json even i use --auth"

README says the opposite — *"With `--auth`: `config.json` is ignored — each
user's config lives in the `users.config_json` DB column"*. The Settings
handlers (GET/PUT/DELETE `/api/config/pabrik`) do honour that, and
`user_config_test.py` pins them. This test asks the question those tests
never asked: which profile does the WORKFLOW actually call the LLM with?

Method — both configs define a profile with the SAME name (`stub`), and the
two definitions point at DIFFERENT endpoints:

  * `config.json`       -> profile "stub" -> `http://127.0.0.1:1` (never answers)
  * `users.config_json` -> profile "stub" -> a stub SSE server (records the request)

The session's `selected_profile_model` is `stub`, so whichever endpoint the
turn lands on names the config that won. Nothing else differs, so there is
no ambiguity: a hit on the stub proves the per-user row was used; a turn
that goes to `127.0.0.1:1` (or never leaves) proves `config.json` was used.

Run:
    uv run --with pytest pytest tests/functional/auth_config_source_test.py -v
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest

from harness import FunctionalHarness

# The profile NAME that exists in both configs; only the per-user definition
# points at the live stub, so the destination of the turn is the verdict.
PROFILE_NAME = "stub"
USER_MODEL = "user-config-model"
USER_KEY = "sk-user-config-key"

# Where `config.json`'s profile "stub" points: the harness writes
# `base_url: http://127.0.0.1:1`, a port that never answers. A turn that is
# dispatched here means config.json won.
GLOBAL_ENDPOINT = "127.0.0.1:1"


# ─── stub OpenAI-style SSE upstream ─────────────────────────────────────


def _text_sse(text: str) -> bytes:
    first = {
        "id": "chatcmpl-authcfg",
        "object": "chat.completion.chunk",
        "model": USER_MODEL,
        "choices": [
            {"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}
        ],
    }
    final = {
        "id": "chatcmpl-authcfg",
        "object": "chat.completion.chunk",
        "model": USER_MODEL,
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }
    body = "".join(f"data: {json.dumps(c)}\n\n" for c in (first, final))
    return (body + "data: [DONE]\n\n").encode()


class _StubState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.requests: list[dict[str, Any]] = []


class _StubHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args: Any) -> None:  # silence stderr noise
        pass

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw_body = self.rfile.read(length) if length else b""
        headers = {k.lower(): v for k, v in self.headers.items()}
        try:
            parsed = json.loads(raw_body.decode("utf-8", "replace") or "{}")
        except json.JSONDecodeError:
            parsed = {}
        with self.server.state.lock:  # type: ignore[attr-defined]
            self.server.state.requests.append(  # type: ignore[attr-defined]
                {"headers": headers, "json": parsed}
            )
        payload = _text_sse("hello from the per-user stub")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def _start_stub() -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _StubHandler)
    server.state = _StubState()  # type: ignore[attr-defined]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


# ─── auth-mode wire helpers (mirrors auth_test.py / user_config_test.py) ─


def _raw(method: str, port: int, path: str, *, body: Any = None, cookie: str | None = None):
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers: dict[str, str] = {}
    if body is not None:
        headers["Content-Type"] = "application/json"
    if cookie is not None:
        headers["Cookie"] = cookie
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, dict(resp.headers.items()), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict((e.headers.items() if e.headers else [])), e.read()


def _create_admin(bin_path: Path, home: Path, email: str, password: str) -> None:
    env = dict(os.environ)
    env["HOME"] = str(home)
    r = subprocess.run(
        [str(bin_path), "create-admin", "--email", email, "--password", password],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )
    assert r.returncode == 0, f"create-admin failed: {r.stderr[-2000:]}"


def _login(port: int, email: str, password: str) -> str:
    status, headers, body = _raw(
        "POST", port, "/api/auth/login", body={"email": email, "password": password}
    )
    assert status == 200, body[:400]
    set_cookie = headers.get("Set-Cookie") or headers.get("set-cookie") or ""
    assert "pabrik_session=" in set_cookie
    return set_cookie.split("pabrik_session=", 1)[1].split(";", 1)[0].strip()


# ─── the test ───────────────────────────────────────────────────────────


def test_auth_chat_turn_runs_on_the_users_config_not_config_json(
    default_pabrik_bin: Path,
) -> None:
    """A `--auth` chat turn must call the profile saved in `users.config_json`.

    `config.json` (seeded by the harness with profile `stub` ->
    `http://127.0.0.1:1`) and the user's row (profile `stub` -> the stub
    server) disagree on the endpoint. Pre-fix the workflow resolves `eff`
    from the process-global `getLlmConfig()` singleton, which was loaded
    from `config.json` at boot, so the turn is dispatched to
    `127.0.0.1:1` and the stub never sees it.
    """
    server = _start_stub()
    harness: FunctionalHarness | None = None
    try:
        stub_port = server.server_address[1]
        stub_url = f"http://127.0.0.1:{stub_port}/v1/chat/completions"

        # `stub_llm_profile=True` seeds config.json with profiles_models.stub
        # -> http://127.0.0.1:1 (the harness's documented never-answers stub).
        harness = FunctionalHarness.boot(
            default_pabrik_bin, extra_args=("--auth",), stub_llm_profile=True
        )
        _create_admin(default_pabrik_bin, harness.temp_dir, "admin@example.com", "supersecret123")
        token = _login(harness.port, "admin@example.com", "supersecret123")
        cookie = f"pabrik_session={token}"

        # 1. The user saves their profile through the real Settings wire.
        #    Under --auth this must land in users.config_json, never config.json.
        status, _, body = _raw(
            "PUT",
            harness.port,
            "/api/config/pabrik",
            cookie=cookie,
            body={
                "profiles": {
                    PROFILE_NAME: {
                        "model": USER_MODEL,
                        "base_url": stub_url,
                        "api_key": USER_KEY,
                        "url_style": "openai",
                        "thinking": "auto",
                        "temperature": "auto",
                    }
                },
                "active_profile": PROFILE_NAME,
            },
        )
        assert status == 200, f"PUT /api/config/pabrik failed: {status} {body[:400]!r}"

        # Positive control: the SAVE half already works per-user. If this
        # fails the test is measuring the wrong thing.
        status, _, body = _raw("GET", harness.port, "/api/config/pabrik", cookie=cookie)
        assert status == 200, body[:400]
        saved = json.loads(body)
        assert saved["profiles"][PROFILE_NAME]["base_url"] == stub_url, (
            "the per-user GET must already return the saved profile; "
            f"got {saved['profiles'][PROFILE_NAME]!r}"
        )
        assert saved["profiles"][PROFILE_NAME]["model"] == USER_MODEL, saved

        # 2. Send the exact sendChatMessage wire body the chatview sends.
        session_id = f"sess_auth_cfg_{int(time.time())}"
        status, _, body = _raw(
            "POST",
            harness.port,
            "/api/llm/session",
            cookie=cookie,
            body={
                "session_id": session_id,
                "queue_message": "say hi",
                "cwd_session": "",
                "allowed_tools": "all",
                "image_urls": "",
                "selected_profile_model": PROFILE_NAME,
                "is_auto_retry_until_stop": "",
            },
        )
        assert status in (200, 201, 500), f"POST /api/llm/session: {status} {body[:400]!r}"

        # 3. Poll for the turn's dispatch. The stub can only be hit if the
        #    per-user profile won; wait for the stub first, then fall back to
        #    the log so a failure is diagnosed as "went elsewhere", not "never ran".
        state: _StubState = server.state  # type: ignore[attr-defined]
        deadline = time.monotonic() + 25.0
        while time.monotonic() < deadline:
            with state.lock:
                if state.requests:
                    break
            time.sleep(0.25)

        # The LLM layer logs `[STREAM START] model=...` for every attempt
        # (the workflow's own CHECKPOINT lines go to the process-global log,
        # not the harness's captured one). Wait for a dispatch so a failure
        # is diagnosed as "went to the wrong endpoint", not "never ran".
        log_tail = harness.tail_log(8000)
        stream = re.search(r"\[STREAM START\] model=(\S+)", log_tail)
        assert stream is not None, (
            "the turn never reached a streaming LLM call, so this run proved "
            f"nothing about config sources.\n--- log tail ---\n{log_tail[-4000:]}"
        )
        model_used = stream.group(1)

        with state.lock:
            seen = list(state.requests)
        if not seen:
            # The turn ran — say WHERE it went, so the failure names the config
            # that won instead of just "assertion failed".
            went_to_global = GLOBAL_ENDPOINT in log_tail
            assert went_to_global, (
                f"the turn was dispatched (model={model_used!r}) but its "
                "endpoint is neither the per-user profile's stub nor "
                f"config.json's {GLOBAL_ENDPOINT} — inconclusive.\n"
                f"--- log tail ---\n{log_tail[-4000:]}"
            )
            raise AssertionError(
                "the chat turn was dispatched with model="
                f"{model_used!r} to config.json's endpoint {GLOBAL_ENDPOINT} "
                f"(see `Failed to connect to {GLOBAL_ENDPOINT}` in the log). "
                "The PER-USER profile's endpoint "
                f"{stub_url} received nothing, so the profile name "
                f"{PROFILE_NAME!r} resolved out of the process-global "
                "LlmConfig singleton (config.json) instead of "
                "users.config_json.\n"
                f"--- log tail ---\n{log_tail[-4000:]}"
            )

        for i, req in enumerate(seen):
            assert req["json"].get("model") == USER_MODEL, (
                f"stub request {i}: the wire model must come from the user's "
                f"config_json profile ({USER_MODEL!r}), got "
                f"{req['json'].get('model')!r}"
            )
            auth = req["headers"].get("authorization", "")
            assert USER_KEY in auth, (
                f"stub request {i}: the wire api_key must come from the user's "
                f"config_json profile, got {auth!r} / {req['headers']!r}"
            )
    finally:
        if harness is not None:
            try:
                harness.teardown()
            except Exception:
                pass
        server.shutdown()
        server.server_close()


def test_auth_web_status_reports_the_users_web_launch_flag(
    default_pabrik_bin: Path,
) -> None:
    """The request-scoped half: `web_launch_enabled` is per-user too.

    `GET /api/web/status` goes through `auth_common.requestUserConfig` (no
    session row exists for it), so this pins the other entry point of the
    one config-resolution module. config.json never sets the key, so the
    flag can only flip to `true` if the caller's `users.config_json` was
    read.
    """
    harness = FunctionalHarness.boot(
        default_pabrik_bin, extra_args=("--auth",), stub_llm_profile=True
    )
    try:
        _create_admin(default_pabrik_bin, harness.temp_dir, "admin@example.com", "supersecret123")
        token = _login(harness.port, "admin@example.com", "supersecret123")
        cookie = f"pabrik_session={token}"

        # Positive control: before the user saves anything the global config is
        # authoritative, so the flag is off.
        status, _, body = _raw("GET", harness.port, "/api/web/status", cookie=cookie)
        assert status == 200, body[:300]
        assert json.loads(body)["enabled"] is False, body[:300]

        # Turn it on in Settings — auth mode persists to users.config_json.
        # The profile rides along because the PUT validates api_key.
        status, _, body = _raw(
            "PUT",
            harness.port,
            "/api/config/pabrik",
            cookie=cookie,
            body={
                "profiles": {
                    PROFILE_NAME: {
                        "model": USER_MODEL,
                        "base_url": "http://127.0.0.1:1",
                        "api_key": USER_KEY,
                        "url_style": "openai",
                    }
                },
                "active_profile": PROFILE_NAME,
                "web_launch_enabled": True,
            },
        )
        assert status == 200, body[:300]
        # This API reports save outcomes in the `error` field (`error` ==
        # "Config saved successfully" on success — a rejection lands there
        # too, which is why the message is asserted rather than the status).
        put_body = json.loads(body)
        assert put_body.get("error") == "Config saved successfully", (
            f"the settings PUT did not report success: {put_body}"
        )

        status, _, body = _raw("GET", harness.port, "/api/web/status", cookie=cookie)
        assert status == 200, body[:300]
        enabled = json.loads(body)["enabled"]
        assert enabled is True, (
            "GET /api/web/status must report the CALLER's web_launch_enabled; "
            f"got {enabled!r}. It is still reading config.json, so the "
            "request-scoped resolution never reached users.config_json."
        )
    finally:
        try:
            harness.teardown()
        except Exception:
            pass
