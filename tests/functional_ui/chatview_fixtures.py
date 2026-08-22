"""DB-seed helpers for chatview UI tests.

We do NOT use a real LLM to generate chat history. Each test opens a
Python `sqlite3` connection against the harness's isolated
``agent.db`` and INSERTs pre-shaped ``sessions`` + ``llm_history``
rows that simulate a real conversation (user prompts, assistant
replies, tool-call + tool-result pairs, reasoning traces, image
attachments, compaction cards, etc.).

The chatview's ``GET /api/llm/session/<id>/messages`` reads these
exact rows — so DB-seeding tests the *real* render path without
the cost/flakiness of a live agent loop.

⛔  Isolation invariants — INHERITED + NEW  ⛔

1. The DB path is always derived from ``temp_dir`` (the harness's
   already-validated isolated tmpdir). The harness's ``is_safe_tmp``
   is the gate that lets the tempdir exist; we re-validate here as
   belt-and-suspenders.

2. Inserts go through the harness's SQLite file. We never
   hard-code an absolute path to the developer's real ``$HOME`` —
   the path is always ``temp_dir / ".config" / "nalar" / "agent.db"``
   where ``temp_dir`` came from the harness fixture.

3. Connections are opened in read-write mode (we need to INSERT),
   but the file itself lives in an isolated tmpdir that the harness
   will rmtree on teardown. Nothing leaks to the real home.

4. Foreign keys are NOT enforced by SQLite on ``llm_history.session_id``
   (plain TEXT, no FK constraint — the link is enforced in app code).
   We don't need to seed ``sessions`` first to make ``llm_history``
   inserts work, but we do seed it so the chatview's ``onMounted``
   GET doesn't 404.

Production schema (verified against a freshly-migrated DB):

``llm_history`` columns:
  id, session_id, model, response_content, tool_calls_json, finish_reason,
  usage_json, created_at_nano (DATETIME), role, reasoning_content,
  is_feed_to_llm, agent, loop_index, temperature, is_thinking,
  parent_session_id, parent_id, prompt_tokens, completion_tokens,
  total_tokens, is_input, is_output, tool_name, diffview_before,
  diffview_after, image_url (singular TEXT, ``||``-delimited for multiple),
  tool_call_id, created_iso, is_loading, cache_creation_input_tokens,
  cache_read_input_tokens.

``sessions`` columns:
  id, name, status, cwd, workspace_id, created_at, updated_at,
  selected_profile_model, git_worktree_cwd, is_auto_retry_until_stop,
  last_finish_reason. (Older DBs may also have ``user_id`` — added
  by Migration 077. We don't depend on it being present.)
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator


# ============================================================================
# Reused imports
# ============================================================================

from harness import (
    REQUIRED_TMP_SUBSTR,
    is_safe_tmp,
)
from ui_harness import FunctionalHarnessError


# ============================================================================
# Constants
# ============================================================================

#: Tiny 1x1 transparent PNG, used as a placeholder image attachment when
#: a test wants to seed user-attached images without bringing in a
#: binary fixture. 67 bytes base64. Valid PNG bytes.
TINY_PNG_DATA_URL = (
    "data:image/png;base64,"
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
)

#: Default model — must be non-empty (the schema's ``model`` is NOT NULL).
DEFAULT_MODEL = "claude-sonnet-4-5"


# ============================================================================
# ChatviewSeed
# ============================================================================


class ChatviewSeed:
    """DB-seed helpers for the chatview UI tests.

    Each method INSERTs one row and returns the inserted primary key
    (a string like ``"msg_<uuid12>"`` for ``llm_history`` rows, or
    the caller-supplied ``session_id`` for ``sessions`` rows).

    Methods accept a ``sqlite3.Connection`` as their first argument —
    they do NOT manage connection lifecycle themselves. Use the
    ``connect()`` context manager (or your own connection) to drive
    the lifecycle.

    Example::

        seed = ChatviewSeed(h.temp_dir / ".config" / "nalar" / "agent.db")
        with seed.connect() as conn:
            sid = "sess_test_001"
            seed.seed_session(conn, sid, "Test Chat")
            seed.seed_user_message(conn, sid, "hi")
            seed.seed_assistant_message(conn, sid, "hello!")
        # Now navigate the browser to /app/chat/<sid> and assert.
    """

    def __init__(self, db_path: Path) -> None:
        # Belt-and-suspenders: re-validate the DB path is inside an
        # is_safe_tmp tempdir. The harness *already* validated this
        # when it allocated the tempdir, but a regression in the
        # harness would otherwise let a test write to the real home.
        # This check is the LAST line of defense.
        if not is_safe_tmp(str(db_path.parent), ""):
            raise FunctionalHarnessError(
                f"REFUSING to seed chatview DB at unsafe path: {db_path}\n"
                f"This path is NOT inside a nalar-func-* tmpdir. "
                f"The harness is supposed to allocate the tempdir; "
                f"if you see this error, the harness has a P0 bug. "
                f"DO NOT bypass this check."
            )
        # Sanity: the DB path should contain the `nalar-func-` substring
        # (catches ``str(db_path.parent)`` paths that pass the prefix
        # check but are not actually harness-allocated).
        if REQUIRED_TMP_SUBSTR not in str(db_path):
            raise FunctionalHarnessError(
                f"DB path {db_path!r} does not contain {REQUIRED_TMP_SUBSTR!r}. "
                f"This is not a harness-allocated tempdir — refusing to seed."
            )
        self.db_path = db_path

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        """Open a sqlite3 connection, commit on success, close on exit.

        Wraps the connection in a try/finally so an exception inside
        the ``with`` block rolls back the transaction (the connection
        is opened with ``isolation_level=None`` for explicit control).

        Usage::

            with seed.connect() as conn:
                seed.seed_user_message(conn, sid, "hi")
                # any exception inside rolls back automatically
        """
        conn = sqlite3.connect(str(self.db_path))
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    # ─── sessions ──────────────────────────────────────────────────────────

    def seed_session(
        self,
        conn: sqlite3.Connection,
        session_id: str,
        name: str = "Test Chat",
        status: str = "active",
        cwd: str | None = None,
    ) -> str:
        """INSERT a row into the ``sessions`` table.

        Returns the ``session_id`` (echoed back for chaining).
        """
        conn.execute(
            """
            INSERT OR IGNORE INTO sessions (id, name, status, cwd)
            VALUES (?, ?, ?, ?)
            """,
            (session_id, name, status, cwd),
        )
        return session_id

    # ─── llm_history helpers ───────────────────────────────────────────────

    def _gen_id(self) -> str:
        """Generate a unique ``llm_history.id`` string.

        Format: ``msg_<12 hex chars>``. The hex is from ``uuid4`` so
        collision risk across tests is negligible.
        """
        return "msg_" + uuid.uuid4().hex[:12]

    def _epoch_microseconds(self, created_at: str | None) -> int | None:
        """Convert a UTC ISO-8601 timestamp to ``created_at_nano`` (microseconds).

        ``created_at_nano`` is a DATETIME column; the production code
        writes it as a unix-timestamp-in-microseconds represented as
        a TEXT string (e.g. ``"1737500000000000"``). We pass the same
        shape so the chatview's ORDER BY works correctly.

        Returns ``None`` to let the column default to CURRENT_TIMESTAMP.
        """
        if created_at is None:
            return None
        # Parse the ISO string and convert to microseconds.
        dt = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        # ``.timestamp()`` returns float seconds; convert to integer
        # microseconds. SQLite's DATETIME affinity will compare this
        # lexically as a string, but the production code uses
        # ``created_at_nano`` as an integer-microsecond string so the
        # ordering works either way.
        return int(dt.timestamp() * 1_000_000)

    def seed_user_message(
        self,
        conn: sqlite3.Connection,
        session_id: str,
        text: str,
        image_urls: list[str] | None = None,
        created_at: str | None = None,
    ) -> str:
        """INSERT a row with ``role='user'`` (is_input=1).

        Args:
            conn: An open sqlite3 connection.
            session_id: The session this message belongs to.
            text: The user prompt text (goes into ``response_content``).
            image_urls: Optional list of data URLs for attached images.
                They are joined with ``||`` and stored in the singular
                ``image_url`` column (matching the production wire format).
            created_at: Optional UTC ISO-8601 string. If None, the column
                default (CURRENT_TIMESTAMP) is used.

        Returns:
            The inserted ``llm_history.id`` (e.g. ``"msg_a1b2c3d4e5f6"``).
        """
        msg_id = self._gen_id()
        image_url_value = "||".join(image_urls) if image_urls else None
        created_at_nano = self._epoch_microseconds(created_at)

        # Build the INSERT dynamically so we can omit NULL columns
        # (the schema allows NULL for everything except id/session_id/model).
        cols = ["id", "session_id", "model", "role", "response_content", "is_input"]
        vals: list[Any] = [
            msg_id, session_id, DEFAULT_MODEL, "user", text, 1,
        ]
        if image_url_value is not None:
            cols.append("image_url")
            vals.append(image_url_value)
        if created_at_nano is not None:
            cols.append("created_at_nano")
            vals.append(str(created_at_nano))

        placeholders = ", ".join(["?"] * len(cols))
        column_list = ", ".join(cols)
        conn.execute(
            f"INSERT INTO llm_history ({column_list}) VALUES ({placeholders})",
            vals,
        )
        return msg_id

    def seed_assistant_message(
        self,
        conn: sqlite3.Connection,
        session_id: str,
        text: str = "",
        finish_reason: str = "stop",
        tool_calls: list[dict[str, Any]] | None = None,
        reasoning_content: str | None = None,
        is_thinking: bool = False,
        created_at: str | None = None,
    ) -> str:
        """INSERT a row with ``role='assistant'`` (is_output=1).

        Args:
            conn: An open sqlite3 connection.
            session_id: The session this message belongs to.
            text: The assistant's response text (goes into
                ``response_content``). May be ``""`` when the row
                represents a tool-call-only response (no text yet).
            finish_reason: One of "stop", "tool_calls", "length", or
                "". Default ``"stop"``.
            tool_calls: Optional list of OpenAI-style tool call dicts:
                ``[{"id": "call_x", "type": "function", "function": {"name": "bash", "arguments": "json string"}}]``.
                The helper double-encodes ``arguments`` (production
                format) and stores the result in ``tool_calls_json``.
            reasoning_content: Optional thinking trace text. Goes into
                the ``reasoning_content`` column.
            is_thinking: Set True when ``reasoning_content`` was streamed
                (sets ``is_thinking=1`` so the frontend knows the
                reasoning block is the "live" trace).
            created_at: Optional UTC ISO-8601 string.

        Returns:
            The inserted ``llm_history.id``.
        """
        msg_id = self._gen_id()
        created_at_nano = self._epoch_microseconds(created_at)

        # Tool calls: serialize (arguments is double-encoded JSON).
        if tool_calls is not None:
            # Convert each tool call's arguments to a JSON string
            # (production wire format).
            tc_serialized = []
            for tc in tool_calls:
                if "function" in tc and "arguments" in tc["function"]:
                    args = tc["function"]["arguments"]
                    if not isinstance(args, str):
                        tc["function"]["arguments"] = json.dumps(args)
                tc_serialized.append(tc)
            tool_calls_json = json.dumps(tc_serialized)
        else:
            tool_calls_json = "[]"

        cols = [
            "id", "session_id", "model", "role", "response_content",
            "is_output", "finish_reason", "tool_calls_json",
        ]
        vals: list[Any] = [
            msg_id, session_id, DEFAULT_MODEL, "assistant", text,
            1, finish_reason, tool_calls_json,
        ]
        if reasoning_content is not None:
            cols.extend(["reasoning_content", "is_thinking"])
            vals.extend([reasoning_content, 1 if is_thinking else 0])
        if created_at_nano is not None:
            cols.append("created_at_nano")
            vals.append(str(created_at_nano))

        placeholders = ", ".join(["?"] * len(cols))
        column_list = ", ".join(cols)
        conn.execute(
            f"INSERT INTO llm_history ({column_list}) VALUES ({placeholders})",
            vals,
        )
        return msg_id

    def seed_tool_result(
        self,
        conn: sqlite3.Connection,
        session_id: str,
        tool_call_id: str,
        tool_name: str,
        content: str,
        created_at: str | None = None,
    ) -> str:
        """INSERT a row with ``role='tool'`` (is_input=1, tool result).

        The caller is expected to have already seeded a parent
        ``assistant`` row whose ``tool_calls_json`` contains a tool
        call with ``id == tool_call_id``. The chatview dispatches
        the rendering to the matching tool card based on
        ``tool_name``.

        Args:
            conn: An open sqlite3 connection.
            session_id: The session this message belongs to.
            tool_call_id: The id of the tool call in the parent
                assistant row's ``tool_calls_json`` array.
            tool_name: The tool name (e.g. ``"bash"``, ``"read_file"``).
            content: The tool's stdout/stderr (goes into
                ``response_content``).
            created_at: Optional UTC ISO-8601 string.

        Returns:
            The inserted ``llm_history.id``.
        """
        msg_id = self._gen_id()
        created_at_nano = self._epoch_microseconds(created_at)

        cols = [
            "id", "session_id", "model", "role", "response_content",
            "is_input", "tool_call_id", "tool_name",
        ]
        vals: list[Any] = [
            msg_id, session_id, DEFAULT_MODEL, "tool", content,
            1, tool_call_id, tool_name,
        ]
        if created_at_nano is not None:
            cols.append("created_at_nano")
            vals.append(str(created_at_nano))

        placeholders = ", ".join(["?"] * len(cols))
        column_list = ", ".join(cols)
        conn.execute(
            f"INSERT INTO llm_history ({column_list}) VALUES ({placeholders})",
            vals,
        )
        return msg_id

    def seed_system_message(
        self,
        conn: sqlite3.Connection,
        session_id: str,
        text: str,
        created_at: str | None = None,
    ) -> str:
        """INSERT a row with ``role='system'`` (is_input=1).

        Most tests don't need this — the chatview's API endpoint
        surfaces the system prompt only when ``is_feed_to_llm=1``
        and the system role is present. Useful for testing custom
        system-prompt rendering.
        """
        msg_id = self._gen_id()
        created_at_nano = self._epoch_microseconds(created_at)

        cols = ["id", "session_id", "model", "role", "response_content", "is_input"]
        vals: list[Any] = [msg_id, session_id, DEFAULT_MODEL, "system", text, 1]
        if created_at_nano is not None:
            cols.append("created_at_nano")
            vals.append(str(created_at_nano))

        placeholders = ", ".join(["?"] * len(cols))
        column_list = ", ".join(cols)
        conn.execute(
            f"INSERT INTO llm_history ({column_list}) VALUES ({placeholders})",
            vals,
        )
        return msg_id

    def seed_compaction_user_message(
        self,
        conn: sqlite3.Connection,
        session_id: str,
        summary: str,
        message_count: int = 5,
        compacted_session_id: str | None = None,
        model: str = "claude-sonnet-4-5",
        created_at: str | None = None,
    ) -> str:
        """INSERT a user row whose content is a ``<compact_messages>`` XML envelope.

        The chatview's ``isCompactionMessage()`` (ChatView.vue:467)
        triggers when ``content.trimStart().startsWith('<compact_messages>')``.
        When it does, the row is rendered as a ``<CompactionCard>``
        instead of a plain text bubble.

        The CompactionCard parser (preview/CompactionCard.vue:155-214)
        expects an XML envelope with three sections:

        - ``<metadata>``: with optional ``<session_id>``, ``<model>``,
          ``<compacted_at>``, ``<original_count>`` children
        - ``<message_index>``: with one ``<entry>`` per compacted
          message, each containing ``<id>``, ``<role>``, ``<preview>``,
          ``<tool_call_id>``, ``<tool_name>``
        - ``<summary>``: the compactor's structured output text

        The card header shows the count of ``<entry>`` elements
        (the "X messages compacted" chip). The summary is rendered
        in a collapsible ``<pre>`` block (collapsed by default).
        """
        ts_now = created_at or datetime.now(timezone.utc).isoformat()
        metadata_parts = [
            "<metadata>",
            f"  <compacted_at>{ts_now}</compacted_at>",
            f"  <original_count>{message_count}</original_count>",
        ]
        if compacted_session_id is not None:
            metadata_parts.append(f"  <session_id>{compacted_session_id}</session_id>")
        if model:
            metadata_parts.append(f"  <model>{model}</model>")
        metadata_parts.append("</metadata>")
        metadata_xml = "\n".join(metadata_parts)

        # Synthesize ``message_count`` placeholder entries. Each must
        # have a unique id (to be a valid XML list), a role, and a preview.
        entry_xml_parts = ["<message_index>"]
        for i in range(message_count):
            entry_xml_parts.append(
                f'  <entry>\n'
                f'    <id>msg_compacted_{i:03d}</id>\n'
                f'    <role>{"user" if i % 2 == 0 else "assistant"}</role>\n'
                f'    <preview>Compacted message {i + 1}</preview>\n'
                f'  </entry>'
            )
        entry_xml_parts.append("</message_index>")
        entries_xml = "\n".join(entry_xml_parts)

        # Escape the summary for XML (avoid breaking on <, >, &).
        escaped_summary = (
            summary.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        )
        summary_xml = f"<summary>{escaped_summary}</summary>"

        envelope_text = (
            f"<compact_messages>\n"
            f"{metadata_xml}\n"
            f"{entries_xml}\n"
            f"{summary_xml}\n"
            f"</compact_messages>"
        )

        return self.seed_user_message(
            conn,
            session_id,
            text=envelope_text,
            created_at=created_at,
        )

    # ─── Utility helpers ───────────────────────────────────────────────────

    @staticmethod
    def baseline_timestamps(
        base: datetime | None = None,
        count: int = 1,
        interval_seconds: int = 30,
    ) -> list[str]:
        """Generate a sequence of chronologically-ordered UTC ISO timestamps.

        Useful for tests that need to seed multiple messages in
        ``created_at`` order (the chatview reverses the API response
        so older messages appear at the top). Tests should pass the
        resulting list to ``seed_user_message``/``seed_assistant_message``
        in order.

        Args:
            base: Starting timestamp (default: now UTC).
            count: How many timestamps to generate.
            interval_seconds: Seconds between consecutive timestamps
                (default 30 — comfortably spaced so the chatview's
                time-formatting chip renders distinct values).

        Returns:
            A list of ISO-8601 strings, length ``count``.
        """
        if base is None:
            base = datetime.now(timezone.utc)
        return [
            (base + timedelta(seconds=i * interval_seconds)).isoformat()
            for i in range(count)
        ]


__all__ = [
    "ChatviewSeed",
    "TINY_PNG_DATA_URL",
    "DEFAULT_MODEL",
]
