from __future__ import annotations

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.migrate import apply


@pytest.mark.asyncio
async def test_ready_ok_with_postgres(postgres_url: str) -> None:
    """Only a server with a published MusicBrainz dump is ready (FT-024).

    The test prepares `mb_loads` itself: the database is shared, and adjacent
    tests leave either a load record or an empty table in it.
    """
    url = postgres_url
    await apply(url)
    client = TestClient(create_app(database_url=url))
    conn = await asyncpg.connect(url)
    try:
        await conn.execute("DELETE FROM mb_loads")
        empty = client.get("/v1/ready")
        assert empty.status_code == 503
        assert empty.json() == {"status": "not_ready"}
        load_id = await conn.fetchval(
            "INSERT INTO mb_loads (dump_date, row_counts, duration_ms)"
            " VALUES ('2026-01-01', '{}'::jsonb, 1) RETURNING id"
        )
        try:
            response = client.get("/v1/ready")
            assert response.status_code == 200
            assert response.json() == {"status": "ready"}
        finally:
            await conn.execute("DELETE FROM mb_loads WHERE id = $1", load_id)
    finally:
        await conn.close()
