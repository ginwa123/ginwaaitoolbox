"""Wire-level regression tests for system-folder path validation."""

from __future__ import annotations

from harness import FunctionalHarness


def test_relative_base_path_returns_400_without_killing_server(
    harness: FunctionalHarness,
) -> None:
    """Non-absolute cwd values must not reach an open*Absolute assertion."""
    cases = (
        {"action": "list", "path": "relative/path"},
        {"action": "search", "path": "relative/path", "q": "component"},
        {"action": "read", "path": "relative/path", "file": "README.md"},
        {"action": "list", "path": ""},
    )

    for params in cases:
        response = harness.http(
            "GET",
            "/api/system/folder",
            params=params,
            expect=400,
        )
        body = response.json()
        assert body["error"] == "path must be absolute", body
        assert body["details"] == "InvalidPath", body
        assert harness.health(), f"server died after params={params!r}"

    empty_search = harness.http(
        "GET",
        "/api/system/folder",
        params={"action": "search", "path": ""},
        expect=400,
    )
    assert empty_search.json()["error"] == "path required"
    assert harness.health(), "server died after rejecting an empty search path"

    foreign_file = f"C:pabrik-relative-{harness.pid or 0}.txt"
    read_response = harness.http(
        "GET",
        "/api/system/folder",
        params={
            "action": "read",
            "path": str(harness.temp_dir),
            "file": foreign_file,
        },
        expect=403,
    )
    assert read_response.json()["error"] == "Cannot open file"
    assert harness.health(), "server died after a drive-relative read path"
