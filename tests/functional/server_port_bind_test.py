"""Starting pabrik on an already-occupied port must fail cleanly.

Regression test for a bug that made the functional suite untrustworthy:
`Address.init` returns `error.BindFailed` when the port is taken, `try`
carried it out of `main`, and the process died on the runtime's error
path with **SIGSEGV (exit code -11)** plus a bare stack trace. The
harness reads that as `pabrik exited rc=-11 during boot` and reports it
as a crash of the binary, so an ordinary port collision — which the
harness can cause itself, see the RANDOM_PORT_* comment in harness.py —
looks like a memory-safety bug in an unrelated test.

Contract pinned here:
  * exit code is a plain positive non-zero (NOT a negative signal code),
  * stderr names the port and says the address is already in use,
  * no `BindFailed` stack trace (the operator message replaces it).

Run:
    zig build install:linux
    PABRIK_BIN=$(pwd)/zig-out/bin/pabrikcore-linux-x86_64 \\
        python3 -m pytest tests/functional/server_port_bind_test.py -v
"""

from __future__ import annotations

import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path

from harness import REQUIRED_TMP_SUBSTR, find_free_port_random, is_safe_tmp


def _squatter(port: int) -> socket.socket:
    """Bind + listen on ``port`` so pabrik's bind() must fail.

    SO_REUSEADDR matches what pabrik's own listener sets (kabelweb
    `http_server.zig` `setReuseAddr`), so the only thing standing between
    the two is that a bound-and-listening socket refuses a second bind.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(1)
    return s


def test_occupied_port_exits_nonzero_not_by_signal(default_pabrik_bin) -> None:
    """A taken port ⇒ rc > 0, never a negative (signal) code."""
    orig_home = os.environ.get("HOME", "")
    port = find_free_port_random()
    temp_dir = Path(tempfile.mkdtemp(prefix=REQUIRED_TMP_SUBSTR))
    assert is_safe_tmp(str(temp_dir), orig_home), f"mkdtemp produced {temp_dir}"

    env = {**os.environ, "HOME": str(temp_dir)}
    for key, sub in (
        ("XDG_CONFIG_HOME", ".config"),
        ("XDG_STATE_HOME", ".local/state"),
        ("XDG_DATA_HOME", ".local/share"),
        ("XDG_CACHE_HOME", ".cache"),
    ):
        (temp_dir / sub).mkdir(parents=True, exist_ok=True)
        env[key] = str(temp_dir / sub)

    squatter = _squatter(port)
    try:
        started = time.monotonic()
        proc = subprocess.run(
            [str(default_pabrik_bin), "--port", str(port)],
            capture_output=True,
            text=True,
            env=env,
            timeout=90,
        )
    finally:
        squatter.close()

    stderr = proc.stderr or ""
    # A negative returncode is Python's `-signal` convention: -11 SIGSEGV,
    # -6 SIGABRT. That is the whole bug — an expected operator error took
    # the process down the runtime's error path.
    assert proc.returncode > 0, (
        f"expected a plain non-zero exit on a taken port, got "
        f"{proc.returncode} (a negative value means it died from a "
        f"signal: {-proc.returncode})\n--- stderr ---\n{stderr[-2000:]}"
    )
    assert proc.returncode == 1, f"want exit 1, got {proc.returncode}\n{stderr[-2000:]}"
    assert "already in use" in stderr, (
        f"stderr should tell the operator the port is taken, got:\n{stderr[-2000:]}"
    )
    assert str(port) in stderr, f"stderr should name the port {port}:\n{stderr[-2000:]}"
    # The stack trace is what made this read as a crash; the operator
    # message should have replaced it.
    assert "BindFailed" not in stderr, (
        f"BindFailed stack trace should be replaced by an operator message:\n{stderr[-2000:]}"
    )
    # Sanity: the port really was still held for the whole attempt, so a
    # fast success cannot be mistaken for a pass.
    assert time.monotonic() - started < 90
