from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import asyncpg
import pytest
from fastapi.testclient import TestClient

from app.catalog_snapshot import encode_cursor, publish
from app.main import create_app

CONTRACTS = Path(__file__).resolve().parents[2] / "contracts"
API_KEY = "k" * 32


def _shape(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _shape(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_shape(value[0])] if value else []
    return "number" if isinstance(value, int) and not isinstance(value, bool) else type(value).__name__


@pytest.mark.asyncio
async def test_keyset_paging(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    existing = await conn.fetch("SELECT mbid, name, sort_name, ended FROM mb_artist")
    try:
        await conn.execute("DELETE FROM mb_artist")
        await conn.execute(
            "INSERT INTO mb_artist (mbid, name, sort_name, ended) "
            "SELECT lpad(to_hex(i), 32, '0')::uuid, 'PagingArtist ' || lpad(i::text, 6, '0'), "
            "'PagingArtist ' || lpad(i::text, 6, '0'), false FROM generate_series(1, 25001) AS i"
        )
        first_id = "00000000000000000000000000000001"
        await conn.execute("INSERT INTO our_genre (slug, name_en, name_ru, sort) VALUES ('rock', 'Rock', 'Рок', 1) ON CONFLICT DO NOTHING")
        await conn.execute("INSERT INTO artist_country (artist_mbid, iso, source) VALUES ($1::uuid, 'US', 'mb') ON CONFLICT DO NOTHING", first_id)
        await conn.execute("INSERT INTO artist_genre (artist_mbid, slug, source, score, is_primary) VALUES ($1::uuid, 'rock', 'mb', 10, true) ON CONFLICT DO NOTHING", first_id)
        await conn.execute("INSERT INTO artist_photos (artist_key, mbid, path, author, license) VALUES ('pagingartist 000001', $1::uuid, 'p.jpg', 'Author', 'CC') ON CONFLICT DO NOTHING", first_id)
        gen = await publish(postgres_url)
        client = TestClient(create_app(database_url=postgres_url, api_key=API_KEY))
        headers = {"x-apertonodo-key": API_KEY}

        resp1 = client.get("/v1/catalog/snapshot", params={"generation": gen}, headers=headers)
        assert resp1.status_code == 200
        d1 = resp1.json()
        assert len(d1["artists"]) == 10000 and d1["cursor"] is not None

        resp2 = client.get("/v1/catalog/snapshot", params={"generation": gen, "cursor": d1["cursor"]}, headers=headers)
        assert resp2.status_code == 200
        d2 = resp2.json()
        assert len(d2["artists"]) == 10000 and d2["cursor"] is not None

        resp3 = client.get("/v1/catalog/snapshot", params={"generation": gen, "cursor": d2["cursor"]}, headers=headers)
        assert resp3.status_code == 200
        d3 = resp3.json()
        assert len(d3["artists"]) == 5001 and d3["cursor"] is None

        all_artists = d1["artists"] + d2["artists"] + d3["artists"]
        assert len(all_artists) == 25001
        assert len({a["artist_id"] for a in all_artists}) == 25001
        all_names = [(a["name"], a["artist_id"]) for a in all_artists]
        assert all_names == sorted(all_names)

        contract = json.loads((CONTRACTS / "catalog-snapshot.response.json").read_text())
        assert _shape(d1) == _shape(contract)
    finally:
        await conn.execute("DELETE FROM mb_artist")
        if existing:
            await conn.executemany(
                "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $3, $4)",
                [(r["mbid"], r["name"], r["sort_name"], r["ended"]) for r in existing],
            )
        await conn.close()


@pytest.mark.asyncio
async def test_concurrent_publishes(postgres_url: str) -> None:
    conn = await asyncpg.connect(postgres_url)
    existing = await conn.fetch("SELECT mbid, name, sort_name, ended FROM mb_artist")
    try:
        await conn.execute("DELETE FROM mb_artist")
        await conn.execute(
            "INSERT INTO mb_artist (mbid, name, sort_name, ended) "
            "SELECT lpad(to_hex(i + 100000), 32, '0')::uuid, 'ConcArtist ' || lpad(i::text, 4, '0'), "
            "'ConcArtist ' || lpad(i::text, 4, '0'), false FROM generate_series(1, 50) AS i"
        )
        gen1, gen2 = await asyncio.gather(publish(postgres_url), publish(postgres_url))
        assert gen1 != gen2
        for gen in (gen1, gen2):
            rows = await conn.fetch("SELECT seq FROM catalog_snapshot_artist WHERE generation = $1 ORDER BY seq", gen)
            assert len(rows) == 50 and [r["seq"] for r in rows] == list(range(1, 51))
    finally:
        await conn.execute("DELETE FROM mb_artist")
        if existing:
            await conn.executemany(
                "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $3, $4)",
                [(r["mbid"], r["name"], r["sort_name"], r["ended"]) for r in existing],
            )
        await conn.close()


def test_http_route_guard_and_foreign_cursor(postgres_url: str) -> None:
    client = TestClient(create_app(database_url=postgres_url, api_key=API_KEY))
    assert client.get("/v1/catalog/snapshot").status_code == 401

    gen_a = asyncio.run(publish(postgres_url))
    gen_b = asyncio.run(publish(postgres_url))
    headers = {"x-apertonodo-key": API_KEY}
    assert client.get("/v1/catalog/snapshot", params={"generation": gen_a}, headers=headers).status_code == 200

    resp_foreign = client.get(
        "/v1/catalog/snapshot", params={"generation": gen_b, "cursor": encode_cursor(gen_a, 10, 2)}, headers=headers
    )
    assert resp_foreign.status_code == 410 and resp_foreign.json() == {"restart": True}
