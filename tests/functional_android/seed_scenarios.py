"""One seeder per scenario: the rows that make the phone render that case.

These write straight into the harness instance's own `agent.db`, which is how
the desktop suite works too and for the same reason: the harness's stub LLM
points at a dead port, so no real turn can complete, and the shapes worth
covering — a tool card, a document turn, a reasoning fold, an attachment — are
not producible by an error turn.

Two deliberate choices:

**Every id is named, not generated.** `message_id()` gives each row a
zero-padded suffix, so string order is seeding order. The phone asks for
`sort_by=id&direction=asc` (its own comment records why `id` and not
`created_at`), so a scheme that sorted out of order would render every
conversation backwards — and a generated id would also be one the instrumented
side cannot name in an assertion.

**Content is a marker, not prose.** The instrumented assertions are on test
tags, which are built from ids; whether `ToolOutput` decodes a shell envelope
correctly is a question about strings, and the 1019-test JVM suite already
answers it directly and needs no device. This suite's job is the one thing that
suite cannot do: prove a real payload survives the real client and reaches the
real renderer. Keeping the division that way means a content string here can
change without breaking anything, and it also means this file cannot accidentally
pin a renderer decision in two places.
"""

from __future__ import annotations

import json
import sqlite3
from typing import Callable

from db_seed import DbSeed, TINY_PNG_DATA_URL

from payloads import (
    PRESENT_FILES_RESULT,
    PRESENT_FILES_TOOL_NAME,
    REAL_HTML_DOCUMENT_TURN,
)
from scenarios import ROWS, SCENARIOS, message_id

#: The shell tool's result envelope, in the JSON shape the tool-output schema
#: defines. Lifted from `tests/functional_ui/chatview_ui_test.py`, where it was
#: proven to render the Bash card on the web — the phone parses the same
#: envelope in `ToolOutput`, so the payload that is known-good there is the
#: honest one to reuse here.
SHELL_ENVELOPE = json.dumps(
    {
        "tool": "bash",
        "parameters": {"command": "ls"},
        "success": True,
        "data": {
            "command": "ls",
            "stdout": "file1.txt\nfile2.txt\nfile3.txt",
            "stderr": "",
            "exit_code": 0,
            "truncated": False,
            "timeout": False,
            "stdout_lines": 3,
            "stderr_lines": 0,
        },
        "error": None,
        "v": 1,
    }
)


def _bash_call(call_id: str) -> dict:
    """An assistant tool call, in the OpenAI shape the column stores."""
    return {
        "id": call_id,
        "type": "function",
        "function": {"name": "bash", "arguments": {"command": "ls"}},
    }


def _present_files_call(call_id: str) -> dict:
    return {
        "id": call_id,
        "type": "function",
        "function": {
            "name": PRESENT_FILES_TOOL_NAME,
            "arguments": {"files": ["/home/me/report.md", "/home/me/shot.png"]},
        },
    }


# ─── the seeders ──────────────────────────────────────────────────────────


def seed_empty(seed: DbSeed, conn: sqlite3.Connection, session_id: str) -> None:
    """A session with nothing in it — the empty-state branch."""


def seed_exchange(seed: DbSeed, conn: sqlite3.Connection, session_id: str) -> None:
    """One user turn and one reply: the smallest transcript that renders."""
    seed.seed_user_message(
        conn, session_id, "FN_EXCHANGE_USER",
        message_id=message_id(session_id, 1),
    )
    seed.seed_assistant_message(
        conn, session_id, "FN_EXCHANGE_ASSISTANT",
        message_id=message_id(session_id, 2),
    )


def seed_multiturn(seed: DbSeed, conn: sqlite3.Connection, session_id: str) -> None:
    """Four exchanges, alternating, 30s apart.

    Explicit `created_at` values because the row's own timestamp is what the
    *web* client orders by — a seeded transcript with no timestamps collapses to
    a single instant and only `id` order is left. The phone reads `id`, but the
    same rows should be coherent for whichever client reads them.
    """
    stamps = DbSeed.baseline_timestamps(count=8, interval_seconds=30)
    for turn in range(4):
        seed.seed_user_message(
            conn, session_id, f"FN_MULTITURN_USER_{turn + 1}",
            created_at=stamps[turn * 2],
            message_id=message_id(session_id, turn * 2 + 1),
        )
        seed.seed_assistant_message(
            conn, session_id, f"FN_MULTITURN_ASSISTANT_{turn + 1}",
            created_at=stamps[turn * 2 + 1],
            message_id=message_id(session_id, turn * 2 + 2),
        )


def seed_toolcalls(seed: DbSeed, conn: sqlite3.Connection, session_id: str) -> None:
    """A reply that is nothing but a tool call, with no result yet.

    `finish_reason="tool_calls"` and empty text is what production writes for an
    unanswered call, and it is the branch the collapsed summary line renders.
    """
    seed.seed_user_message(
        conn, session_id, "FN_TOOLCALLS_USER",
        message_id=message_id(session_id, 1),
    )
    seed.seed_assistant_message(
        conn, session_id, "",
        finish_reason="tool_calls",
        tool_calls=[_bash_call("call_fn_toolcalls")],
        message_id=message_id(session_id, 2),
    )


def seed_toolresult(seed: DbSeed, conn: sqlite3.Connection, session_id: str) -> None:
    """The call, and the row carrying its output."""
    seed.seed_user_message(
        conn, session_id, "FN_TOOLRESULT_USER",
        message_id=message_id(session_id, 1),
    )
    seed.seed_assistant_message(
        conn, session_id, "",
        finish_reason="tool_calls",
        tool_calls=[_bash_call("call_fn_toolresult")],
        message_id=message_id(session_id, 2),
    )
    seed.seed_tool_result(
        conn, session_id, "call_fn_toolresult", "bash", SHELL_ENVELOPE,
        message_id=message_id(session_id, 3),
    )


def seed_markdown(seed: DbSeed, conn: sqlite3.Connection, session_id: str) -> None:
    """A reply with a heading, a table and a fenced block."""
    body = (
        "FN_MARKDOWN_HEADING\n"
        "\n"
        "## FN_MARKDOWN_H2\n"
        "\n"
        "- FN_MARKDOWN_ITEM\n"
        "\n"
        "```bash\nls -la\n```\n"
    )
    seed.seed_user_message(
        conn, session_id, "FN_MARKDOWN_USER",
        message_id=message_id(session_id, 1),
    )
    seed.seed_assistant_message(
        conn, session_id, body,
        message_id=message_id(session_id, 2),
    )


def seed_images(seed: DbSeed, conn: sqlite3.Connection, session_id: str) -> None:
    """A user turn with two attachments.

    Two rather than one so a count of one cannot pass by accident, and because
    `||`-joining is the part of the wire format that is easy to get wrong.
    """
    seed.seed_user_message(
        conn, session_id, "FN_IMAGES_USER",
        image_urls=[TINY_PNG_DATA_URL, TINY_PNG_DATA_URL],
        message_id=message_id(session_id, 1),
    )
    seed.seed_assistant_message(
        conn, session_id, "FN_IMAGES_ASSISTANT",
        message_id=message_id(session_id, 2),
    )


def seed_reasoning(seed: DbSeed, conn: sqlite3.Connection, session_id: str) -> None:
    """A reply with a thinking trace behind it, which starts folded."""
    seed.seed_user_message(
        conn, session_id, "FN_REASONING_USER",
        message_id=message_id(session_id, 1),
    )
    seed.seed_assistant_message(
        conn, session_id, "FN_REASONING_ASSISTANT",
        reasoning_content="FN_REASONING_TRACE " + ("thinking " * 40),
        is_thinking=True,
        message_id=message_id(session_id, 2),
    )


def seed_html(seed: DbSeed, conn: sqlite3.Connection, session_id: str) -> None:
    """The document turn: prose, then a real `<html>` document.

    The payload is the real one, not an approximation — see `payloads.py`. This
    is the scenario with no JVM equivalent at all: `HtmlPreview` sizes its frame
    from a script inside a `WebView`, and Robolectric's `WebView` is a shadow
    that never runs one, so only a device can show that the document was drawn.
    """
    seed.seed_user_message(
        conn, session_id, "FN_HTML_USER",
        message_id=message_id(session_id, 1),
    )
    seed.seed_assistant_message(
        conn, session_id, REAL_HTML_DOCUMENT_TURN,
        message_id=message_id(session_id, 2),
    )


def seed_presentfiles(seed: DbSeed, conn: sqlite3.Connection, session_id: str) -> None:
    """`present_files`, whose card is the only path through the binary exchange.

    Worth its own scenario because `HttpsBinaryExchange` is a separate class with
    its own copy of the connection policy: a file download that disagreed with
    the API calls about plain HTTP would be invisible in every other scenario.
    """
    seed.seed_user_message(
        conn, session_id, "FN_PRESENTFILES_USER",
        message_id=message_id(session_id, 1),
    )
    seed.seed_assistant_message(
        conn, session_id, "",
        finish_reason="tool_calls",
        tool_calls=[_present_files_call("call_fn_presentfiles")],
        message_id=message_id(session_id, 2),
    )
    seed.seed_tool_result(
        conn, session_id, "call_fn_presentfiles", PRESENT_FILES_TOOL_NAME,
        PRESENT_FILES_RESULT,
        message_id=message_id(session_id, 3),
    )


SEEDERS: dict[str, Callable[[DbSeed, sqlite3.Connection, str], None]] = {
    "empty": seed_empty,
    "exchange": seed_exchange,
    "multiturn": seed_multiturn,
    "toolcalls": seed_toolcalls,
    "toolresult": seed_toolresult,
    "markdown": seed_markdown,
    "images": seed_images,
    "reasoning": seed_reasoning,
    "html": seed_html,
    "presentfiles": seed_presentfiles,
}


def seed_all(seed: DbSeed, conn: sqlite3.Connection) -> dict[str, str]:
    """Seed every scenario into one database; return scenario name -> session id.

    One database for all ten, not ten databases: the instrumented side runs once
    per Gradle invocation and each of its tests opens its own session id, so the
    scenarios cannot collide — and booting a server per scenario would cost a
    build, an install and a device handshake each time.

    Every seeder is checked against the `ROWS`/`SEEDERS` tables as it runs, so a
    seeder that forgets a row fails here rather than as an unexplained missing
    tag on a device.
    """
    if set(SEEDERS) != set(SCENARIOS):
        raise AssertionError(
            f"SEEDERS and SCENARIOS disagree: {sorted(set(SEEDERS) ^ set(SCENARIOS))}"
        )

    for name, session_id in SCENARIOS.items():
        seed.seed_session(conn, session_id, f"FN {name}")

        before = conn.execute(
            "SELECT COUNT(*) FROM llm_history WHERE session_id = ?", (session_id,)
        ).fetchone()[0]
        SEEDERS[name](seed, conn, session_id)
        written = conn.execute(
            "SELECT COUNT(*) FROM llm_history WHERE session_id = ?", (session_id,)
        ).fetchone()[0] - before

        if written != ROWS[name]:
            raise AssertionError(
                f"scenario {name!r} wrote {written} rows, ROWS says {ROWS[name]}"
            )

    return dict(SCENARIOS)
