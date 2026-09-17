"""Graceful shutdown: Ctrl+C (SIGINT) and SIGTERM drain cleanly.

Regression test for "are we using graceful shutdown for backend":
before the fix, the foreground server installed no SIGINT/SIGTERM
handler, so Ctrl+C killed the process with the default disposition —
no listener close, no cron/SSE join, no SQLite deinit (rely on WAL
recovery), truncated in-flight responses.

After the fix, `main` installs `signal_handlers.installShutdownHandlers`
which calls `GinwaServer.shutdown()` (stop accept + unblock `listen()`)
so the existing `cronjob_manager.stop() / sse_manager.stop() / defer`
unwind runs. A second signal force-exits (130).

Method: boot a real binary via the functional harness (isolated tmpdir
HOME, random free port — never 8081), assert /health serves, send
SIGINT to the child pid, assert the process exits promptly with a
clean status (0, not -SIGINT/-SIGTERM/-SEGV), and assert the port stops
serving. SIGTERM path covered the same way (docker/systemd/`service
stop` send TERM).
"""

from __future__ import annotations

import os
import signal
import time
import urllib.error
import urllib.request


def _wait_exit(harness, timeout: float = 10.0) -> int | None:
    """Wait up to `timeout`s for harness.pid to exit; return waitpid status or None."""
    assert harness.pid is not None
    deadline = time.monotonic() + timeout
    status: int | None = None
    while time.monotonic() < deadline:
        try:
            wpid, status = os.waitpid(harness.pid, os.WNOHANG)
        except ChildProcessError:
            return status  # already reaped
        except OSError:
            pass
        else:
            if wpid == harness.pid:
                return status
        time.sleep(0.05)
    return None


def _port_serves(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2.0) as resp:
            return resp.status == 200
    except Exception:
        return False


def test_sigint_ctrl_c_shuts_down_gracefully(harness):
    """Ctrl+C (SIGINT) stops the server cleanly instead of killing it."""
    assert harness.health(), "server should serve /health before SIGINT"

    assert harness.pid is not None
    os.kill(harness.pid, signal.SIGINT)

    status = _wait_exit(harness, timeout=10.0)
    assert status is not None, "server did not exit within 10s of SIGINT (graceful shutdown hung?)"

    if os.WIFEXITED(status):
        code = os.WEXITSTATUS(status)
        # 0 = clean unwind through listen() return + defers; 130 = second-signal
        # force-exit path (acceptable, still graceful intent, never a crash).
        assert code in (0, 130), f"SIGINT exit code {code}, expected 0 (clean) or 130 (force)"
    elif os.WIFSIGNALED(status):
        sig = os.WTERMSIG(status)
        raise AssertionError(
            f"server died by signal {sig} after SIGINT — "
            "graceful handler did not run (default disposition killed it)"
        )
    else:
        raise AssertionError(f"unexpected waitpid status {status!r} after SIGINT")

    # Mark reaped so harness.teardown skips redundant kills (it tolerates
    # dead pids anyway, but this keeps the log clean).
    harness._stopped = True
    harness.pid = None

    assert not _port_serves(harness.port), "port should stop serving after graceful SIGINT shutdown"


def test_sigterm_shuts_down_gracefully(harness):
    """SIGTERM (docker/systemd/service stop) stops the server cleanly."""
    assert harness.health(), "server should serve /health before SIGTERM"

    assert harness.pid is not None
    os.kill(harness.pid, signal.SIGTERM)

    status = _wait_exit(harness, timeout=10.0)
    assert status is not None, "server did not exit within 10s of SIGTERM (graceful shutdown hung?)"

    if os.WIFEXITED(status):
        code = os.WEXITSTATUS(status)
        assert code in (0, 130), f"SIGTERM exit code {code}, expected 0 (clean) or 130 (force)"
    elif os.WIFSIGNALED(status):
        sig = os.WTERMSIG(status)
        raise AssertionError(
            f"server died by signal {sig} after SIGTERM — graceful handler did not run"
        )
    else:
        raise AssertionError(f"unexpected waitpid status {status!r} after SIGTERM")

    harness._stopped = True
    harness.pid = None

    assert not _port_serves(harness.port), "port should stop serving after graceful SIGTERM shutdown"
