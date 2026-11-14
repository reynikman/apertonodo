"""One heavy query does not switch MusicBrainz off for everybody (FT-878).

`asyncpg.QueryCanceledError` is our own `statement_timeout` in `local_search.search`:
"this query is too heavy", not "catalog is down". It must neither count as a failure
nor start the cooldown. Real failures (connection, `asyncio.TimeoutError`) work as
before, and when the cooldown starts, the failure counter is reset.

What these tests prove: counter and pause logic in the `/v1/search` handler with a
catalog port that raises the given errors. What they do not prove: that the real
catalog raises `QueryCanceledError` at all — that is `local_search`, not this block.
Time is driven through `app.state.catalog_skip_until`, no sleeping.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app.main import CATALOG_FAILURES_BEFORE_COOLDOWN, create_app

ROOT = Path(__file__).resolve().parents[2]
CATALOG = json.loads((ROOT / "contracts" / "fixtures" / "catalog.json").read_text())["tracks"]

QUERY = "zxqv unique heavy query"
OK = "ok"


class _ScriptedCatalog:
    """Catalog port that answers from a script: an exception to raise, or OK."""

    def __init__(self, *script: Any) -> None:
        self.script = list(script)
        self.calls = 0

    async def search(self, query: str, limit: int) -> list[dict[str, Any]]:
        step = self.script[self.calls] if self.calls < len(self.script) else OK
        self.calls += 1
        if step is OK:
            return []
        raise step


def _canceled() -> asyncpg.QueryCanceledError:
    return asyncpg.QueryCanceledError("canceling statement due to statement timeout")


def _down() -> OSError:
    return ConnectionRefusedError("catalog connection refused")


def _timeout() -> asyncio.TimeoutError:
    return asyncio.TimeoutError()


def _app(port: _ScriptedCatalog) -> Any:
    app = create_app(catalog=CATALOG, catalog_port=port)
    app.state.catalog_timeout_s = 1.0
    app.state.catalog_cooldown_s = 60.0
    return app


def _paused(app: Any) -> bool:
    return app.state.catalog_skip_until > time.monotonic()


def _search(client: TestClient) -> Any:
    return client.get("/v1/search", params={"q": QUERY})


def test_threshold_is_still_two() -> None:
    # The table below speaks of "two in a row"; if the constant moves, so must the card.
    assert CATALOG_FAILURES_BEFORE_COOLDOWN == 2


def test_two_canceled_queries_do_not_start_the_cooldown() -> None:
    port = _ScriptedCatalog(_canceled(), _canceled())
    app = _app(port)
    with TestClient(app) as client:
        first = _search(client)
        second = _search(client)
        assert not _paused(app), "QueryCanceledError started the cooldown"
        assert app.state.catalog_failures == 0
        third = _search(client)

    assert port.calls == 3, f"catalog was not asked after two canceled queries: {port.calls}"
    # The canceled query itself still answers without catalog, honestly.
    for response in (first, second):
        assert response.status_code == 503
        assert response.json() == {"status": "catalog_unavailable"}
    assert third.status_code == 200


@pytest.mark.parametrize("make_error", [_down, _timeout], ids=["connection", "timeout"])
def test_two_real_failures_start_the_cooldown(make_error: Any) -> None:
    port = _ScriptedCatalog(make_error(), make_error())
    app = _app(port)
    with TestClient(app) as client:
        _search(client)
        assert not _paused(app), "one real failure must not start the cooldown"
        _search(client)
        assert _paused(app), "two real failures in a row did not start the cooldown"
        response = _search(client)

    assert port.calls == 2, f"catalog was asked during the cooldown: {port.calls}"
    assert response.status_code == 503


def test_canceled_query_between_two_failures_neither_resets_nor_counts() -> None:
    port = _ScriptedCatalog(_down(), _canceled(), _down())
    app = _app(port)
    with TestClient(app) as client:
        _search(client)
        assert app.state.catalog_failures == 1
        _search(client)
        assert app.state.catalog_failures == 1, "canceled query changed the counter"
        assert not _paused(app)
        _search(client)
        assert _paused(app), "failure, canceled, failure must start the cooldown"
        _search(client)

    assert port.calls == 3


def test_counter_is_reset_when_the_cooldown_starts() -> None:
    port = _ScriptedCatalog(_down(), _down(), _down())
    app = _app(port)
    with TestClient(app) as client:
        _search(client)
        _search(client)
        assert _paused(app)
        assert app.state.catalog_failures == 0, "counter not reset when the pause started"
        # Cooldown is over (no sleeping: move the deadline into the past).
        app.state.catalog_skip_until = 0.0
        _search(client)
        assert app.state.catalog_failures == 1
        assert not _paused(app), "first real failure after the cooldown started a new one"
        _search(client)
        assert port.calls == 4, "catalog was not asked after the first failure post-cooldown"


def test_second_failure_after_the_cooldown_starts_a_new_one() -> None:
    port = _ScriptedCatalog(_down(), _down(), _down(), _down())
    app = _app(port)
    with TestClient(app) as client:
        _search(client)
        _search(client)
        app.state.catalog_skip_until = 0.0
        _search(client)
        _search(client)
        assert _paused(app), "two failures after the cooldown must start a new one"

    assert port.calls == 4


def test_success_resets_the_counter() -> None:
    port = _ScriptedCatalog(_down(), OK, _down())
    app = _app(port)
    with TestClient(app) as client:
        _search(client)
        assert app.state.catalog_failures == 1
        _search(client)
        assert app.state.catalog_failures == 0
        _search(client)
        assert app.state.catalog_failures == 1
        assert not _paused(app), "success did not reset: failure, ok, failure paused"

    assert port.calls == 3


def test_canceled_query_logs_only_the_class_name(caplog: pytest.LogCaptureFixture) -> None:
    secret_sql = "SELECT secret_column FROM secret_table WHERE name = 'zxqv-secret-song'"
    port = _ScriptedCatalog(asyncpg.QueryCanceledError(secret_sql))
    app = _app(port)
    with TestClient(app) as client:
        with caplog.at_level(logging.DEBUG):
            _search(client)

    lines = " ".join(
        record.getMessage() for record in caplog.records if record.name.startswith("apertonodo")
    )
    # Positive control: the failure is logged, by class name.
    assert "QueryCanceledError" in lines, lines
    assert "secret_table" not in lines and "zxqv-secret-song" not in lines
    assert "statement timeout" not in lines
    assert "zxqv unique" not in lines
    assert port.calls == 1
