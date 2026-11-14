"""FT-875: Play по номеру записи MusicBrainz, когда песни нет в памяти и в `tracks`.

`POST /v1/playback` знает песни из памяти и таблицы `tracks`. Номер записи со стороны
(рекомендации LongplayAtlas) там не лежит, но копия MusicBrainz его знает: `mb_recording`
плюс имя из `mb_artist`. Каждая строка таблицы «Пограничные случаи» карточки — свой тест.

Источник — настоящее fake-расширение на loopback (как в test_extension_play.py): оно знает
только «Slipknot - Duality», поэтому песня из копии называется так же. Сети нет.

Чего тесты не доказывают: скорость запроса по `mbid` на десятках миллионов строк
(это один запрос по первичному ключу, смотрит ревью) и боевой Play на телефоне.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

import asyncpg
import pytest
from fake_extension import make_fake_extension, running_extension
from fastapi.testclient import TestClient

from app.main import create_app
from app.migrate import apply

MBID = "0c0c0c0c-1111-4111-8111-000000000875"
ARTIST = "0a0a0a0a-2222-4222-8222-000000000875"
UNKNOWN = "0d0d0d0d-3333-4333-8333-000000000875"
TITLE = "Duality"
NAME = "Slipknot"
LENGTH = 252000
FIELDS = {"id", "title", "artist", "duration_ms", "artwork_url"}


def _run(url: str, sql: str, *args: Any) -> list[asyncpg.Record]:
    async def go() -> list[asyncpg.Record]:
        conn = await asyncpg.connect(url)
        try:
            return await conn.fetch(sql, *args)
        finally:
            await conn.close()

    return asyncio.run(go())


def _clean(url: str) -> None:
    _run(url, "TRUNCATE mb_recording, mb_artist CASCADE")
    _run(url, "DELETE FROM tracks WHERE id = $1", uuid.UUID(MBID))


@pytest.fixture
def db(postgres_url: str) -> Iterator[str]:
    asyncio.run(apply(postgres_url))
    _clean(postgres_url)
    try:
        yield postgres_url
    finally:
        _clean(postgres_url)


def _artist(url: str, name: str = NAME) -> None:
    _run(
        url,
        "INSERT INTO mb_artist (mbid, name, sort_name, ended) VALUES ($1, $2, $2, false)",
        uuid.UUID(ARTIST), name,
    )


def _recording(
    url: str, *, title: str = TITLE, artist: str | None = ARTIST, length: int | None = LENGTH,
    mbid: str = MBID,
) -> None:
    _run(
        url,
        "INSERT INTO mb_recording (mbid, artist_mbid, title, length_ms) VALUES ($1, $2, $3, $4)",
        uuid.UUID(mbid), uuid.UUID(artist) if artist else None, title, length,
    )


def _copy(url: str, **kwargs: Any) -> None:
    _artist(url)
    _recording(url, **kwargs)


@contextmanager
def _play_client(url: str, catalog: list[dict[str, Any]] | None = None) -> Iterator[TestClient]:
    with running_extension(make_fake_extension()) as ext:
        app = create_app(database_url=url, catalog=catalog or [], extensions={"fake": ext})
        with TestClient(app) as client:
            yield client


def _play(client: TestClient, track_id: str) -> Any:
    return client.post("/v1/playback", json={"track_id": track_id})


# Строка 1: номер есть в mb_recording, в tracks нет.
def test_number_from_copy_plays_with_title_and_artist(db: str) -> None:
    _copy(db)
    with _play_client(db) as client:
        played = _play(client, MBID)
    assert played.status_code == 200, played.text
    body = played.json()
    assert body["state"] == "ready" and body["token"]
    assert set(body["track"]) == FIELDS
    assert body["track"]["id"] == MBID
    assert body["track"]["title"] == TITLE
    assert body["track"]["artist"] == NAME
    assert body["track"]["duration_ms"] == LENGTH
    assert body["track"]["artwork_url"] == ""
    for leak in ("magnet", "info_hash", "fake:"):
        assert leak not in played.text


# Строка 2: номер есть и в tracks — берётся из tracks, копия не спрашивается.
def test_tracks_table_wins_over_copy(db: str) -> None:
    _run(
        db,
        "INSERT INTO tracks (id, title, artist, duration_ms, artwork_url, canonical_key)"
        " VALUES ($1, $2, $3, $4, '', $5)",
        uuid.UUID(MBID), TITLE, NAME, 111000, f"ft875:{MBID}",
    )
    _copy(db, title="Copy Title", length=222000)
    with _play_client(db) as client:
        played = _play(client, MBID)
    assert played.status_code == 200, played.text
    track = played.json()["track"]
    assert (track["title"], track["duration_ms"]) == (TITLE, 111000), track


# Строка 3: номера нет нигде — 404 как сейчас (при других строках в копии).
def test_unknown_number_is_not_found(db: str) -> None:
    _copy(db)
    with _play_client(db) as client:
        played = _play(client, UNKNOWN)
    assert played.status_code == 404, played.text


# Строка 4: копии нет — таблиц нет или пустые: 404, не 500.
def test_empty_copy_is_not_found(db: str) -> None:
    with _play_client(db) as client:
        played = _play(client, MBID)
    assert played.status_code == 404, played.text


def test_missing_copy_tables_is_not_found_not_500(db: str) -> None:
    _copy(db)
    _run(db, "ALTER TABLE mb_recording RENAME TO mb_recording_hidden")
    try:
        with _play_client(db) as client:
            played = _play(client, MBID)
    finally:
        _run(db, "ALTER TABLE mb_recording_hidden RENAME TO mb_recording")
    assert played.status_code == 404, played.text


# Строка 5: нет artist_mbid или имени исполнителя — не играть, 404.
@pytest.mark.parametrize("case", ["no-artist-mbid", "artist-row-missing", "artist-name-empty"])
def test_recording_without_artist_does_not_play(db: str, case: str) -> None:
    if case == "no-artist-mbid":
        _recording(db, artist=None)
    elif case == "artist-row-missing":
        _recording(db)
    else:
        _artist(db, name="")
        _recording(db)
    with _play_client(db) as client:
        played = _play(client, MBID)
    assert played.status_code == 404, played.text
    assert "token" not in played.json()


# Строка 6: length_ms пуст — duration_ms 0, Play идёт.
def test_missing_length_plays_with_zero_duration(db: str) -> None:
    _copy(db, length=None)
    with _play_client(db) as client:
        played = _play(client, MBID)
    assert played.status_code == 200, played.text
    assert played.json()["track"]["duration_ms"] == 0
    assert played.json()["track"]["title"] == TITLE


# Строка 7: второй Play того же номера — копия не спрашивается (трек уже в памяти).
# Доказано без подмены функций: после первого Play строки копии удалены,
# второй Play обязан обойтись памятью.
def test_second_play_does_not_ask_the_copy_again(db: str) -> None:
    _copy(db)
    with _play_client(db) as client:
        first = _play(client, MBID)
        assert first.status_code == 200, first.text
        _run(db, "TRUNCATE mb_recording, mb_artist CASCADE")
        second = _play(client, MBID)
    assert second.status_code == 200, second.text
    assert second.json()["track"] == first.json()["track"]


# Строка 8: без входа / без ключа — 401, как у всех /v1/*.
@pytest.mark.real_auth
def test_play_by_number_needs_a_key(db: str) -> None:
    _copy(db)
    app = create_app(database_url=db, catalog=[], api_key="ft875-key-" + "0" * 24)
    with TestClient(app) as client:
        played = _play(client, MBID)
    assert played.status_code == 401, played.text


# Строка 9: fixture-трек с тем же номером — fixture главнее.
def test_fixture_track_beats_copy(db: str) -> None:
    fixture = {"id": MBID, "title": TITLE, "artist": NAME, "duration_ms": 1, "artwork_url": ""}
    _copy(db, title="Copy Title", length=222000)
    with _play_client(db, catalog=[fixture]) as client:
        played = _play(client, MBID)
    assert played.status_code == 200, played.text
    track = played.json()["track"]
    assert (track["title"], track["duration_ms"]) == (TITLE, 1), track


# Договор: ни номера записи, ни названия в логах (приватность, tests/test_privacy.py).
def test_play_by_number_logs_neither_number_nor_title(
    db: str, caplog: pytest.LogCaptureFixture
) -> None:
    _copy(db)
    with caplog.at_level(logging.DEBUG):
        with _play_client(db) as client:
            played = _play(client, MBID)
            assert played.status_code == 200, played.text
    for word in (MBID, TITLE, NAME):
        assert word not in caplog.text, f"logged {word}"
