"""Functional UI tests for nalar — boots a real nalar binary AND a Vite
dev server against isolated tempdirs, then drives the running web app
with Playwright Python.

Mirrors the isolation guarantees of `tests/functional/`:
  - Backend ``HOME`` is shadowed to a tempdir (never touches real ``$HOME``).
  - The backend's DB, config, and design files all live inside the tempdir.
  - Teardown rmtree's only the tempdir; the developer's real home is never
    touched (``is_safe_tmp`` is the single source of truth, reused from
    ``tests/functional/harness.py``).

The new dimension is the **frontend**:
  - Vite dev server is spawned alongside the backend.
  - ``VITE_API_PROXY_TARGET`` is set to the harness's chosen backend port,
    so the running web app's ``/api/*`` calls land on the test fixture
    (not on the developer's always-running dev :8081).
  - Playwright's browser context is isolated per test; screenshots go to
    an artifacts dir for post-mortem debugging.

See ``tests/functional_ui/README.md`` for usage and ``harness.py`` for the
safety invariants.
"""
