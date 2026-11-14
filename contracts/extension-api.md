# Extension API v1 — core ↔ music extension

Contract between the Apertonodo core (`server/`) and a music extension (Р-A88, `plan/p8-core.md`). The core
knows nothing about how an extension obtains a file: a folder on disk and a peer-to-peer engine look the same
from here. Conformance is checked by `scripts/extension_check.py --url <extension>`.

## Transport
- HTTP/1.1, JSON in UTF-8, base path `/v1`. An extension listens on the internal compose network only, without
  a host port; v1 has no authentication.
- The core is configured with `EXTENSIONS="<name>=<url>,<name>=<url>"`. `name` matches `[a-z][a-z0-9-]{0,31}`
  and prefixes every id the core stores: `<name>:<id>`.
- Errors are JSON `{"error": "<code>"}`: `400 bad_request` (or framework `422`), `404 unknown_id`,
  `416` for an unsatisfiable range, `503 unavailable` when the extension is up but cannot serve now.
- Logs of an extension follow `docs/logs.md`: no search text, titles, artist names, file names or addresses.

## Ids
An id is opaque to the core: `[A-Za-z0-9._~-]{1,200}` — no `:` and no `/`, so it can never be a link. The same
file keeps the same id across restarts of the extension: the core stores ids for pinned downloads, Opus
variants and "where this song played from".

## Endpoints

### `GET /v1/info`
`200 {"api": 1, "name": "folder", "version": "0.1.0", "kind": "music", "features": ["catalog", "pins"]}`
`kind` is `music` or `books` in v1 (`info` — lyrics and facts — comes in P10). `features` lists optional
endpoints a `music` extension implements: `catalog`, `has`, `pins`, `cover`. A `books` extension answers `info`, `health`,
`failed` and the book endpoints below, nothing else; its `features` is `[]`.

### `GET /v1/health`
`200 {"ok": true}` or `503 {"ok": false, "reason": "<short code>"}`.

### `POST /v1/find`
Request: `{"track": {"id": "<core track id>", "artist": "…", "title": "…", "album": "…", "duration_ms": 252000,
"recording_mbid": "…"}, "limit": 4}` — `artist` and `title` always present, the rest optional; `limit` 1–10.
Response `200 {"items": [{"id": "…", "confidence": 0.93, "format": "mp3", "size": 5001000, "quality": "lossy"}]}`
- best first, `confidence` not increasing, at most `limit` items, `[]` when nothing;
- `confidence` 0–1: how sure the extension is that this file is this recording. The core plays only
  `confidence >= 0.75`; anything lower never gets a playback token;
- `format`: `mp3 | flac | ogg | opus | m4a | wav`; `size` in bytes or `null` when unknown yet;
  `quality`: `lossy | lossless | hires | analog`;
- answers within 10 s — slow discovery returns what it has.

### `POST /v1/prepare`
Request `{"id": "…"}`. Response `200 {"state": "ready" | "preparing" | "failed", "format": "mp3", "size": 5001000}`,
with `"reason"` when failed: `not_found | wrong_track | no_audio | unavailable`.
- `ready` means the first bytes can be read now — not that the whole file is local;
- idempotent: calling again for a prepared id answers `ready` at once;
- `404 unknown_id` for an id this extension never issued;
- `ready` may carry an optional `"stats": {"peers": 7, "speed_bps": 180000, "have_pct": 3, "via": "link"}` —
  connected peers, bytes per second, percent of the needed file already present, and how it was obtained:
  `link | file | cache` (`cache`: the file was already whole at the extension). Any field may be missing or
  `null`; an extension without a swarm sends no block. The core need not understand it and only records it.

### `GET /v1/files/{id}`
The bytes of the file, as a stream that may begin **before** the extension has the whole file.
- `Range: bytes=a-b` (single range) → `206` with `Content-Range: bytes a-b/size` and exactly those bytes;
  no `Range` → `200` with the whole file; always `Accept-Ranges: bytes` and an `audio/*` `Content-Type`;
- bytes not available yet: the extension waits for them (up to 30 s), it never sends other bytes or zeros;
- `404 unknown_id`; `416` when `a` is past the end.

### `POST /v1/failed`
Request `{"id": "…", "reason": "wrong_track" | "no_audio" | "stalled" | "bad_audio"}` → `204`. Reported by the
core when a listener or the core found the file wrong. After it, `find` for the same track returns this id with
a lower `confidence` than before, or not at all.

### `POST /v1/pins` (feature `pins`)
Request `{"id": "…", "pinned": true}` → `204`. A pinned id is never evicted by the extension's own storage
policy (offline downloads). `pinned: false` releases it.

### `GET /v1/catalog` (feature `catalog`)
`200`, `Content-Type: application/x-ndjson`, one JSON object per line:
`{"artist": "…", "title": "…", "album": "…", "popularity": 12, "genre": "heavy-metal"}` — everything the
extension can play now; `album` and `genre` optional, `popularity` an integer ≥ 0 (higher plays more surely).
`genre` is one word of `contracts/genres.txt`, exactly as written there (lowercase): the extension maps its own sections to these words itself; a
line it cannot place goes without `genre`, never with a word outside the list. The core builds "what is
playable" and its genre screens from these lines. The answer is a stream: an extension with a large index sends
lines as it reads them, not after collecting them in memory. Without the feature — `404`.

### `POST /v1/has` (feature `has`)
Request `{"pairs": [{"artist": "…", "title": "…"}]}` — 1–50 pairs. Response `200 {"hits": [true, false, …]}`:
one boolean per pair, in the same order — `true` when the extension could play this song now, by the same
rule that puts a line into its `catalog`. A pair with an empty `artist` or `title` is `false`; a repeated pair is
answered again in its place. Asked when the core shows a list of songs (an artist's top, a search answer) to mark the ones
nothing would play. Answers within 2 s; more than 50 pairs or none — `400 bad_request` (or `422`); cannot answer
now — `503 unavailable`, and the core shows the songs as playable rather than hide them.

### `POST /v1/cover` (feature `cover`)
Request `{"artist": "…", "title": "…"}` — an album, both strings non-empty. Response `200` with the image bytes
and an `image/*` `Content-Type` (at most 10 MiB), or `404 {"error": "not_found"}` when the extension has no
picture for it. The core asks only when the cover archive has none and the album is playable; extensions are
asked in the order of `EXTENSIONS`, the first image wins. Answers within 60 s (the picture may have to be taken
out of a release first). The core shrinks and stores the image itself; nothing is sent to the client but its own
`/v1/covers` path.

## Book endpoints (`kind: "books"`)
A book is a set of audio files (parts) that a book extension found as one item. The core turns the file list
into parts itself (natural order of names, Р-A106); names never leave the server.

### `POST /v1/books/find`
Request `{"query": "…", "limit": 20}` — `query` 2–200 characters, `limit` 1–50.
Response `200 {"items": [{"id": "…", "title": "…", "author": "…", "narrator": "…", "year": 2011,
"size": 734003200, "language": "ru", "popularity": 12}]}`
- `title` always present; `author`, `narrator` strings (may be empty); `year` and `size` integers or `null`;
- `language`: two lowercase letters (ISO 639-1) or `null` — `null` means `ru` (Р-A105); the core does not
  store it in v1 (filter by language comes with the languages card);
- `popularity`: integer ≥ 1 or `null` when unknown; items nobody can serve now are not returned;
- best first, at most `limit` items, `[]` when nothing; only books — no music; the core drops items under
  5 MiB or over 20 GiB (a known `size` only), so an extension need not send them;
- answers within 10 s, `503 unavailable` when the source cannot be asked now.

### `POST /v1/books/files`
Request `{"id": "…"}`. Response `200 {"state": "ready" | "preparing" | "failed", "files": [{"index": 0,
"name": "01 Глава первая.mp3", "size": 52428800}]}`
- `files` lists every file of the item, `index` integers ≥ 0 and unique; it may be `[]` while `preparing`;
  the core does not wait inside the call — on `preparing` it asks again later and the book is not on the shelf
  until `ready`;
- the core keeps audio files only (`mp3 m4a m4b aac ogg opus flac`, by name) and refuses an item with more
  than 3000 of them; `size` is bytes > 0, a file without it is skipped;
- `ready` means every `index` can be read with `GET /v1/books/file`; idempotent like `prepare`;
- `failed` carries `"reason"`: `not_found | no_audio | unavailable`; `404 unknown_id` for a foreign id.

### `GET /v1/books/file/{id}/{index}`
The bytes of one file, with the same rules as `GET /v1/files/{id}` (single `Range`, `206`/`200`, waits for bytes
up to 30 s, never sends other bytes); `404 unknown_id` for an unknown id or `index`.

`POST /v1/failed` is shared: for a book `reason` is `no_audio | stalled | bad_audio` and the id is the book id.

## What the core keeps
Tokens, sessions, the stream cache, Opus variants, the download queue and pins — keyed by `<name>:<id>`. The
client API (`/v1/playback`, `/v1/stream/{token}`) is unchanged: `token`, `state`, `track`, no extension ids.
For books the core stores `books.asset_key = <name>:<id>`; `asset_hint` holds the same id in v1 (the extension
needs nothing else to find the item again). The client book API (`/v1/books/*` of the core, contract Д5а) never
shows extension ids, file names or indexes.
