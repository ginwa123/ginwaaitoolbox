"""Functional tests for `--auth` per-user config (users.config_json).

Boots a REAL nalar binary + REAL SQLite via the harness (never a live
dev server, never port 8081). Replays the EXACT wire flows the settings
page uses: GET /api/config/nalar, PUT /api/config/nalar, DELETE
/api/config/nalar/profiles/:name.

Covers:
  * AUTH-GET-DEFAULTS — fresh admin GETs defaults (no config_json yet).
  * AUTH-PUT-ISOLATION — user A and B have independent configs.
  * AUTH-FILE-UNTOUCHED — PUT in auth mode never writes config.json.
  * AUTH-UNAUTH — GET/PUT/DELETE without cookie -> 401.
  * AUTH-DELETE — DELETE removes the profile from the user's column.
  * OFF-MODE-REGRESSION — without --auth, PUT still writes config.json.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.request
import urllib.error
from pathlib import Path

import pytest

from harness import FunctionalHarness


def _raw(method: str, port: int, path: str, *, body=None, cookie: str | None = None):
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {}
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


def _boot_auth(bin_path: Path):
    return FunctionalHarness.boot(bin_path, extra_args=("--auth",))


def _create_admin(bin_path: Path, home: Path, email: str, password: str, *, force: bool = False):
    env = dict(os.environ)
    env["HOME"] = str(home)
    args = [str(bin_path), "create-admin", "--email", email, "--password", password]
    if force:
        args.append("--force")
    r = subprocess.run(args, capture_output=True, text=True, env=env, timeout=30)
    assert r.returncode == 0, f"create-admin failed: {r.stderr[-2000:]}"


def _login(port: int, email: str, password: str) -> str:
    status, headers, body = _raw(
        "POST", port, "/api/auth/login", body={"email": email, "password": password}
    )
    assert status == 200, body[:500]
    set_cookie = headers.get("Set-Cookie") or headers.get("set-cookie") or ""
    assert "nalar_session=" in set_cookie
    return set_cookie.split("nalar_session=", 1)[1].split(";", 1)[0].strip()


def _profile_body(name: str, model: str) -> dict:
    return {
        "profiles": {
            name: {
                "model": model,
                "base_url": "https://api.example.com",
                "thinking": "auto",
                "temperature": "auto",
                "url_style": "openai",
                "api_key": "k",
            }
        },
        "active_profile": name,
    }


def _config_file(home: Path) -> Path:
    """Where ``getDefaultConfigDir`` (Config.zig) actually writes config.json.

    Mirrors that function's platform switch:

      * macOS   — ``~/Library/Application Support/nalar``. ``XDG_CONFIG_HOME``
        is NOT consulted on this branch, so the harness's
        ``<home>/.config`` shadow is irrelevant.
      * Windows — ``%APPDATA%/nalar``, which the harness points at
        ``<home>/AppData/Roaming``.
      * else    — ``$XDG_CONFIG_HOME/nalar`` else ``$HOME/.config/nalar``; the
        harness points ``XDG_CONFIG_HOME`` at ``<home>/.config``.

    Derived from ``home`` alone rather than ``os.environ``: the harness only
    shadows the CHILD env on Linux/mac, and GitHub's runners export a real
    ``XDG_CONFIG_HOME`` that has nothing to do with the tempdir.

    Hardcoding ``<home>/.config`` made this pass on Linux and fail on macOS,
    where the assertion then read a path the server never wrote.
    """
    if sys.platform == "darwin":
        return Path(home) / "Library" / "Application Support" / "nalar" / "config.json"
    if os.name == "nt":
        return Path(home) / "AppData" / "Roaming" / "nalar" / "config.json"
    return Path(home) / ".config" / "nalar" / "config.json"


def test_auth_get_defaults(default_nalar_bin: Path):
    h = _boot_auth(default_nalar_bin)
    try:
        _create_admin(default_nalar_bin, h.temp_dir, "admin@example.com", "supersecret123")
        token = _login(h.port, "admin@example.com", "supersecret123")
        status, _, body = _raw("GET", h.port, "/api/config/nalar", cookie=f"nalar_session={token}")
        assert status == 200, body[:500]
        cfg = json.loads(body.decode())
        assert cfg.get("profiles") in (None, {})
    finally:
        h.teardown()


def test_auth_put_isolation(default_nalar_bin: Path):
    h = _boot_auth(default_nalar_bin)
    try:
        _create_admin(default_nalar_bin, h.temp_dir, "a@example.com", "supersecret123")
        _create_admin(default_nalar_bin, h.temp_dir, "b@example.com", "supersecret123", force=True)
        tok_a = _login(h.port, "a@example.com", "supersecret123")
        tok_b = _login(h.port, "b@example.com", "supersecret123")

        status, _, body = _raw(
            "PUT", h.port, "/api/config/nalar",
            body=_profile_body("alpha", "model-a"),
            cookie=f"nalar_session={tok_a}",
        )
        assert status == 200, body[:500]
        status, _, body = _raw(
            "PUT", h.port, "/api/config/nalar",
            body=_profile_body("beta", "model-b"),
            cookie=f"nalar_session={tok_b}",
        )
        assert status == 200, body[:500]

        status, _, body = _raw("GET", h.port, "/api/config/nalar", cookie=f"nalar_session={tok_a}")
        assert status == 200
        cfg_a = json.loads(body.decode())
        assert cfg_a["profiles"]["alpha"]["model"] == "model-a"
        assert "beta" not in cfg_a["profiles"]

        status, _, body = _raw("GET", h.port, "/api/config/nalar", cookie=f"nalar_session={tok_b}")
        assert status == 200
        cfg_b = json.loads(body.decode())
        assert cfg_b["profiles"]["beta"]["model"] == "model-b"
        assert "alpha" not in cfg_b["profiles"]
    finally:
        h.teardown()


def test_auth_put_leaves_config_file_untouched(default_nalar_bin: Path):
    h = _boot_auth(default_nalar_bin)
    try:
        _create_admin(default_nalar_bin, h.temp_dir, "admin@example.com", "supersecret123")
        token = _login(h.port, "admin@example.com", "supersecret123")
        cfg_path = _config_file(h.temp_dir)
        before = cfg_path.read_bytes() if cfg_path.exists() else None
        status, _, body = _raw(
            "PUT", h.port, "/api/config/nalar",
            body=_profile_body("alpha", "model-a"),
            cookie=f"nalar_session={token}",
        )
        assert status == 200, body[:500]
        after = cfg_path.read_bytes() if cfg_path.exists() else None
        assert after == before, "PUT in --auth mode must not touch config.json"
        # But the DB-backed GET reflects the save.
        status, _, body = _raw("GET", h.port, "/api/config/nalar", cookie=f"nalar_session={token}")
        assert status == 200
        assert json.loads(body.decode())["profiles"]["alpha"]["model"] == "model-a"
    finally:
        h.teardown()


def test_auth_unauth_config_endpoints_are_401(default_nalar_bin: Path):
    h = _boot_auth(default_nalar_bin)
    try:
        for method, path, body in (
            ("GET", "/api/config/nalar", None),
            ("PUT", "/api/config/nalar", {"active_profile": None}),
            ("DELETE", "/api/config/nalar/profiles/x", None),
        ):
            status, _, _ = _raw(method, h.port, path, body=body)
            assert status == 401, f"{method} {path} should be 401 without cookie"
        status, _, _ = _raw("GET", h.port, "/api/config/nalar", cookie="nalar_session=")
        assert status == 401
    finally:
        h.teardown()


def test_auth_delete_profile(default_nalar_bin: Path):
    h = _boot_auth(default_nalar_bin)
    try:
        _create_admin(default_nalar_bin, h.temp_dir, "admin@example.com", "supersecret123")
        token = _login(h.port, "admin@example.com", "supersecret123")
        cookie = f"nalar_session={token}"
        status, _, body = _raw(
            "PUT", h.port, "/api/config/nalar",
            body=_profile_body("todelete", "m"), cookie=cookie,
        )
        assert status == 200, body[:500]
        status, _, body = _raw("DELETE", h.port, "/api/config/nalar/profiles/todelete", cookie=cookie)
        assert status == 200, body[:500]
        status, _, body = _raw("GET", h.port, "/api/config/nalar", cookie=cookie)
        assert status == 200
        assert "todelete" not in (json.loads(body.decode()).get("profiles") or {})
    finally:
        h.teardown()


def test_off_mode_put_still_writes_file(harness: FunctionalHarness):
    cfg_path = _config_file(harness.temp_dir)
    before = cfg_path.read_bytes() if cfg_path.exists() else None
    r = harness.http("PUT", "/api/config/nalar", json_body=_profile_body("filemode", "mf"), expect=200)
    assert r.status == 200
    after = cfg_path.read_bytes() if cfg_path.exists() else None
    assert after is not None and after != before, "off-mode PUT must still write config.json"
    assert json.loads(after.decode())["profiles_models"]["filemode"]["model"] == "mf"
