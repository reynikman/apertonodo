# Lyrics extension API v1 — core ↔ info extension «lyrics»

Contract between the Apertonodo core and the lyrics extension (Р-A77, Р-A88: "information source", `kind: info`).
The extension answers one question — the words of this recording — from LRCLIB (`https://lrclib.net`, free,
no key). Transport, error shape and log rules are the same as `contracts/extension-api.md`.

## Endpoints

### `GET /v1/info`
`200 {"api": 1, "name": "lyrics", "version": "0.1.0", "kind": "info", "features": ["lyrics"]}`

### `GET /v1/health`
`200 {"ok": true}`. It does not call LRCLIB: a slow LRCLIB must not make the extension look dead.

### `POST /v1/lyrics`
Request: `{"artist": "…", "title": "…", "album": "…", "duration_s": 241}` — `artist` and `title` required,
non-empty; `album` and `duration_s` (integer 1–3600) optional. Missing `artist`/`title` → `400` or `422`.

Response `200`:
- `{"found": true, "instrumental": false, "plain": "…", "synced": "[00:12.34] …" | null}` — `synced` is LRC
  text with time marks, `null` when LRCLIB has only plain words;
- `{"found": true, "instrumental": true, "plain": null, "synced": null}` — a piece without words;
- `{"found": false}` — LRCLIB does not know this recording.

`503 {"error": "unavailable"}` — LRCLIB did not answer in time, answered 5xx, or asked to wait (429/503 with
`Retry-After`). Such an answer is never cached.

## Behaviour
- **Which LRCLIB call.** `album` and `duration_s` both present → `GET /api/get?artist_name&track_name&album_name&duration`
  (LRCLIB matches duration within ±2 s). Otherwise → `GET /api/search?artist_name&track_name`, and the first
  result with words (or instrumental) wins; when `duration_s` is given, only results within ±2 s of it count.
  LRCLIB `404` on `/api/get` and an empty search are `found: false`.
- **Cache** in `<data_dir>/lyrics.sqlite`, keyed by lower-cased, space-collapsed artist, title, album and
  duration. Found — kept forever (words of a recording do not change). Not found — kept 7 days, then asked again
  (LRCLIB grows). Survives a restart.
- **Waiting when asked.** After a `429`/`503` with `Retry-After: N` (seconds) the extension does not call LRCLIB
  for N seconds (no header — 60 s) and answers `503 unavailable` for anything not in the cache.
- **Politeness.** One LRCLIB request at a time, at least 200 ms between them (LRCLIB terms). Every request carries
  `User-Agent` from `LRCLIB_USER_AGENT` (default `Apertonodo-lyrics/0.1.0 (+https://github.com/reynikman/apertonodo)`).
- **Timeout** 5 s per LRCLIB request.
- **Logs** — `lyrics <outcome>` lines (`hit`, `found`, `not_found`, `unavailable`, `wait <N>s`) without artist,
  title, album or the words.

## Environment
`LRCLIB_URL` (default `https://lrclib.net`), `LRCLIB_USER_AGENT`, `LRCLIB_PROXY` (optional HTTP proxy),
`EXT_DATA_DIR` (default `/data`). Listens on port 8080 of the internal compose network only.
