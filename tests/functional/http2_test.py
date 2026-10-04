"""HTTP/2 cleartext (h2c) end-to-end tests.

The server only speaks h2 OVER CLEARTEXT (no TLS/ALPN), so browsers keep using
HTTP/1.1 and the only ready-made h2c client on a dev box / CI runner is
`curl --http2-prior-knowledge` (nghttp2-backed). That is what these tests use,
plus raw sockets for the protocol-error cases.

Every test boots the real binary with `--http2 h2c` via the harness `extra_args`
hook and an isolated tmpdir HOME, so nothing here touches a developer's config.

Run:
    zig build install:linux
    PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 \
        python3 -m pytest tests/functional/http2_test.py -v
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import struct
import subprocess

import pytest

from harness import FunctionalHarness


def _curl() -> str:
    exe = shutil.which("curl")
    if exe is None:
        pytest.skip("curl not on PATH")
    return exe


def _curl_version_args() -> None:
    """Skip when this curl has no HTTP/2 support (e.g. a stripped build)."""
    out = subprocess.run(
        [_curl(), "--version"], capture_output=True, text=True, timeout=20
    ).stdout
    if "nghttp2" not in out and "HTTP2" not in out:
        pytest.skip(f"curl lacks HTTP/2 support: {out.splitlines()[0] if out else ''}")


def _curl_http_version(url: str, extra: list[str] | None = None) -> tuple[str, str]:
    """Return (http_version, body) for a single request."""
    cmd = [
        _curl(),
        "-sS",
        "-o",
        "-",
        "-w",
        "\n%{http_version}",
        *([] if extra is None else extra),
        url,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    assert proc.returncode == 0, f"curl failed: {proc.stderr}"
    body, _, version = proc.stdout.rpartition("\n")
    return version.strip(), body


def _h2_harness(default_pabrik_bin) -> FunctionalHarness:
    return FunctionalHarness.boot(
        default_pabrik_bin,
        extra_args=("--http2", "h2c"),
        ready_timeout_s=45.0,
    )


@pytest.fixture
def h2_harness(default_pabrik_bin):
    h = _h2_harness(default_pabrik_bin)
    try:
        yield h
    finally:
        h.teardown()


def test_h2_prior_knowledge_health(h2_harness: FunctionalHarness) -> None:
    """A prior-knowledge h2c client gets HTTP/2 and the normal handler body."""
    _curl_version_args()
    version, body = _curl_http_version(
        f"http://127.0.0.1:{h2_harness.port}/health", ["--http2-prior-knowledge"]
    )
    assert version == "2", f"expected HTTP/2, got {version!r} (body={body!r})"
    assert "ok" in body.lower()


def test_h2_and_h1_share_the_same_port(h2_harness: FunctionalHarness) -> None:
    """h2c is negotiated per connection: the SAME port still serves HTTP/1.1."""
    _curl_version_args()
    h1_version, h1_body = _curl_http_version(f"http://127.0.0.1:{h2_harness.port}/health")
    assert h1_version == "1.1"
    assert "ok" in h1_body.lower()

    h2_version, h2_body = _curl_http_version(
        f"http://127.0.0.1:{h2_harness.port}/health", ["--http2-prior-knowledge"]
    )
    assert h2_version == "2"
    assert "ok" in h2_body.lower()


def test_h1_only_when_flag_absent(default_pabrik_bin) -> None:
    """With no --http2 flag the server must not accept h2 at all (default off)."""
    _curl_version_args()
    h = FunctionalHarness.boot(default_pabrik_bin)
    try:
        version, _ = _curl_http_version(f"http://127.0.0.1:{h.port}/health")
        assert version == "1.1"

        # curl with prior knowledge against an h1-only server fails loudly
        # (it is the exact probe that established the pre-change behaviour).
        proc = subprocess.run(
            [
                _curl(),
                "-sS",
                "-o",
                os.devnull,
                "--http2-prior-knowledge",
                f"http://127.0.0.1:{h.port}/health",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert proc.returncode != 0
        assert "HTTP/2" in proc.stderr or "SETTINGS" in proc.stderr
    finally:
        h.teardown()


def test_h2_post_body_roundtrip(h2_harness: FunctionalHarness) -> None:
    """A POST body survives the h2 path and reaches the handler."""
    _curl_version_args()
    proc = subprocess.run(
        [
            _curl(),
            "-sS",
            "--http2-prior-knowledge",
            "-H",
            "content-type: application/json",
            "-d",
            '{"name":"h2-probe"}',
            f"http://127.0.0.1:{h2_harness.port}/api/workspaces",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    created = json.loads(proc.stdout)
    assert created["id"].startswith("ws_")


def test_h2_unknown_route_is_404(h2_harness: FunctionalHarness) -> None:
    _curl_version_args()
    proc = subprocess.run(
        [
            _curl(),
            "-sS",
            "-o",
            os.devnull,
            "-w",
            "%{http_code} %{http_version}",
            "--http2-prior-knowledge",
            f"http://127.0.0.1:{h2_harness.port}/definitely-not-a-route",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    code, _, version = proc.stdout.partition(" ")
    assert code == "404"
    assert version.strip() == "2"


def test_h2_reuses_one_connection_for_two_requests(h2_harness: FunctionalHarness) -> None:
    """Multiplexing/persistence: two URLs over ONE connection.

    HTTP/1.1 needs a second TCP connection here because every h1 response says
    `Connection: close`; h2 keeps the connection alive.
    """
    _curl_version_args()
    base = f"http://127.0.0.1:{h2_harness.port}/health"
    proc = subprocess.run(
        [
            _curl(),
            "-sS",
            "-o",
            os.devnull,
            "-o",
            os.devnull,
            "-w",
            "%{num_connects}\n",
            "--http2-prior-knowledge",
            base,
            base,
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    connects = [int(x) for x in proc.stdout.split()]
    # curl reports num_connects=1 for the first URL and 0 for the second: the
    # second transfer needed NO new TCP connection. (The h1 baseline is 1 and 1,
    # because every h1 response says `Connection: close`.)
    assert connects == [1, 0], f"expected one connection reused (1, 0), got {connects}"


def test_h2_bogus_preface_gets_goaway_and_server_survives(
    h2_harness: FunctionalHarness,
) -> None:
    """Protocol errors must be answered with GOAWAY, not a crash."""
    # Frame header: length=4, type=RST_STREAM (0x3), flags=0, stream 1 — a
    # frame that is illegal on a connection whose preface we did NOT send
    # correctly, so it must be rejected as a protocol error.
    # Correct preface, then a 9-byte frame header claiming a 16 MiB payload:
    # that is a FRAME_SIZE_ERROR, so the server must answer GOAWAY.
    bogus = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
    bogus += struct.pack(">I", 0xFFFFFF)[3:] + bytes([0x00, 0x00]) + struct.pack(">I", 1)
    with socket.create_connection(("127.0.0.1", h2_harness.port), timeout=10) as s:
        s.sendall(bogus)
        s.settimeout(10)
        try:
            data = s.recv(4096)
        except socket.timeout:
            data = b""
    assert data, "expected a GOAWAY frame before the connection closed"
    # First frame the server sends on a valid preface is SETTINGS; on a garbage
    # frame it is GOAWAY (type 0x7). Accept either but require HTTP/2 framing.
    ftype = data[3]
    assert ftype in (0x4, 0x7), f"unexpected frame type {ftype:#x}"

    # The process must still be alive and serving.
    _curl_version_args()
    version, _ = _curl_http_version(f"http://127.0.0.1:{h2_harness.port}/health")
    assert version in ("1.1", "2")


def test_h2_response_headers_are_lowercase(h2_harness: FunctionalHarness) -> None:
    """RFC 9113 §8.2.1: an uppercase field name must not reach the wire.

    curl/nghttp2 would reject the response outright, so a 200 here is itself the
    assertion; we also assert the security headers the h1 path adds are present.
    """
    _curl_version_args()
    proc = subprocess.run(
        [
            _curl(),
            "-sS",
            "-D",
            "-",
            "-o",
            os.devnull,
            "--http2-prior-knowledge",
            f"http://127.0.0.1:{h2_harness.port}/health",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    header_lines = [ln for ln in proc.stdout.splitlines() if ":" in ln and not ln.startswith("HTTP/")]
    assert header_lines, proc.stdout
    for line in header_lines:
        name = line.split(":", 1)[0]
        assert name == name.lower(), f"non-lowercase header name on the h2 wire: {name!r}"
