# Apertonodo

English | [Русский](README.ru.md)

Apertonodo is a self-hosted music server. Apertono is its Android app.
You search a catalog, press Play, and the music starts. Your own music folder
works too.

Apertonodo contains no music sources; extensions are installed by the user.
The list of extensions: [github.com/apertono/extensions](https://github.com/apertono/extensions).

- **Catalog.** Search by artist, album and song through MusicBrainz.
  Covers come from the Cover Art Archive.
- **Your folder.** Put music files into a folder on the server; the app plays them.
- **Extensions.** Where the music comes from is decided by small separate services.
  Three come with the install: `folder` (your music folder), `archive` (Internet Archive) and
  `lyrics` (LRCLIB lyrics). More extensions, including source extensions: https://github.com/apertono/extensions
- **Accounts.** Every person has a name and a password. No ads, no telemetry.

## Status: beta

Version 0.9.0 is a beta (a GitHub pre-release). What works: search in the catalog,
Play, your music folder, extensions, accounts, playlists and history.

Not ready yet:

- Automatic update of the app works only from this version on: older builds do not look for updates.
- iPhone app: coming later. For now Android only.
- Extensions are added on the server, not from the app: `./scripts/extension.sh add <name>`.
- Search ranking is sometimes inaccurate.
- The week-long listening test has not been passed yet.

## Requirements

Server:

- Linux, x86_64
- Docker with Docker Compose v2 (check: `docker compose version`)
- `git` and `curl`

Phone: Android 7.0 or newer (the app's `minSdk` is 24).

## Install the server

```bash
git clone https://github.com/reynikman/apertonodo
cd apertonodo
./scripts/install.sh
```

The script does this, in order:

1. checks that Docker Compose works;
2. creates `.env` from `.env.example` with random secrets (API key, database
   password, password of the first user) and makes it readable only by you;
3. starts the server with `docker compose up -d --build`;
4. waits up to 120 seconds for `GET /v1/health`;
5. creates the first user `admin` and prints the address, the name and the password.

The first build downloads images and takes a few minutes. Save the password it prints.
It is also written in `.env`.

If `.env` already exists, the script keeps it and uses its secrets: if the first run stopped halfway, just run it again.
Check that the server is alive: `curl http://localhost:8088/v1/health`.

By default the server searches the online MusicBrainz and writes one line at start:
`catalog: no local MusicBrainz copy, using online MusicBrainz`.

If the app says "The catalog is not responding" (the server log: `catalog search failed: TimeoutError`), the machine cannot reach `musicbrainz.org` (it is blocked in some
countries). Set `MUSICBRAINZ_PROXY` in `.env` to an HTTP(S) proxy that can, then `docker compose up -d api`.

## Install the app

1. Open the **Releases** page of this repository and download the latest `.apk`.
2. Open the file on the phone and allow installation from this source.
   The app's package name is `app.apertono.player`.
3. Start Apertono. Enter the server address (`http://<server address>:8088`),
   the name `admin` and the password printed by `install.sh`.

The phone must reach the server: the same Wi-Fi, or a public address behind a
reverse proxy (below).

## Your music

`install.sh` creates the folder `./music` next to `docker-compose.yml`. Put music
files there; they appear in the app. To use another folder, set `MUSIC_PATH=/path/to/music`
in `.env` and run `docker compose up -d`.

## Extensions

The server asks extensions where to find music. Each one is added with one command, run in the
folder with `docker-compose.yml`; the command downloads the extension (into `./extensions`), updates `.env`
and starts it. Run again, it changes nothing. `install.sh` has already done this for all three.

| Extension | What it does | Add | Remove |
|---|---|---|---|
| `folder` | plays your music folder | `./scripts/extension.sh add folder` | `./scripts/extension.sh remove folder` |
| `archive` | plays from Internet Archive | `./scripts/extension.sh add archive` | `./scripts/extension.sh remove archive` |
| `lyrics` | song lyrics from LRCLIB | `./scripts/extension.sh add lyrics` | `./scripts/extension.sh remove lyrics` |

`./scripts/extension.sh list` shows which are on. More extensions, including source extensions:
https://github.com/apertono/extensions (the same command adds them; read what its page says about your
responsibility first).

Updated from an older version where `folder` and `lyrics` were part of `docker-compose.yml`: run
`./scripts/extension.sh add folder` and `./scripts/extension.sh add lyrics` once.
The extension contract is in `contracts/extension-api.md`.

## Reverse proxy

To open the server from the internet, put it behind a reverse proxy with HTTPS.
The server port (`APERTONO_PORT`, 8088) serves plain HTTP without encryption: at home over the local network that is fine, from the internet only through a proxy with TLS.
What the proxy must do and an nginx example: [docs/reverse-proxy.md](docs/reverse-proxy.md).

## Update

```bash
git pull
docker compose up -d --build
```

Your accounts and library stay in the database volume. `.env` is not changed.

## Backup

Everything people created (accounts, library, playlists, history) is in the database.
Music files are not in the archive: copy your music folder yourself.

```bash
docker compose exec -T api cat /app/scripts/backup.sh > backup.sh
docker compose exec -T -e APERTONODO_PG_BIN=/usr/local/bin postgres sh -s -- \
    --database-url postgresql://music@/music --directory /tmp/backup < backup.sh
docker compose cp postgres:/tmp/backup ./backup
```

Details and how to check a restore: [docs/backup.md](docs/backup.md).

## License

MIT, see `LICENSE`. Licenses of third-party components: `THIRD_PARTY_NOTICES.md`.
