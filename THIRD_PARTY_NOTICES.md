# Third-party notices

This repository's own source is MIT. Redistributed and linked components
keep their original licenses. This is an engineering inventory, not a legal opinion.

## License texts

| Component | Version | License | Notice |
|---|---|---|---|
| Apache License 2.0 | 2.0 | Apache-2.0 | `third_party/licenses/Apache-2.0.txt` |

Source extensions keep their own notices in their own folders.

## Python (server)

Direct dependencies declared in `server/pyproject.toml`.
Licenses are read from the installed package metadata (`pip show`).

| Component | License |
|---|---|
| [argon2-cffi](https://github.com/hynek/argon2-cffi) | MIT |
| [FastAPI](https://github.com/fastapi/fastapi) | MIT |
| [Uvicorn](https://github.com/Kludex/uvicorn) | BSD-3-Clause |
| [asyncpg](https://github.com/MagicStack/asyncpg) | Apache-2.0 |
| [httpx](https://github.com/encode/httpx) | BSD-3-Clause |
| [sentry-sdk](https://github.com/getsentry/sentry-python) | MIT |
| [pytest](https://github.com/pytest-dev/pytest) | MIT |
| [pytest-asyncio](https://github.com/pytest-dev/pytest-asyncio) | Apache-2.0 |

## Flutter (mobile)

Direct dependencies of `mobile/pubspec.yaml`; versions are from `mobile/pubspec.lock`, licenses from the
`LICENSE` file of the downloaded package.

| Component | Version | License |
|---|---|---|
| Flutter / Dart SDK (including `flutter_localizations`) | | BSD-3-Clause |
| [intl](https://pub.dev/packages/intl) | 0.20.3 | BSD-3-Clause |
| [cupertino_icons](https://pub.dev/packages/cupertino_icons) | 1.0.9 | MIT |
| [http](https://pub.dev/packages/http) | 1.6.0 | BSD-3-Clause |
| [just_audio](https://pub.dev/packages/just_audio) | 0.10.6 | MIT |
| [audio_service](https://pub.dev/packages/audio_service) | 0.18.19 | MIT |
| [shared_preferences](https://pub.dev/packages/shared_preferences) | 2.5.5 | BSD-3-Clause |
| [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) | 10.3.4 | BSD-3-Clause |
| [file_picker](https://pub.dev/packages/file_picker) | 13.1.0 | MIT |
| [sqflite](https://pub.dev/packages/sqflite) | 2.4.4 | BSD-2-Clause |
| [path_provider](https://pub.dev/packages/path_provider) | 2.1.6 | BSD-3-Clause |
| [crypto](https://pub.dev/packages/crypto) | 3.0.7 | BSD-3-Clause |
| [background_downloader](https://pub.dev/packages/background_downloader) | 9.5.9 | BSD-3-Clause |
| [connectivity_plus](https://pub.dev/packages/connectivity_plus) | 7.3.2 | BSD-3-Clause |
| [sqflite_common_ffi](https://pub.dev/packages/sqflite_common_ffi) (tests) | 2.4.3 | BSD-2-Clause |
| [flutter_lints](https://pub.dev/packages/flutter_lints) (lint only) | 6.0.0 | BSD-3-Clause |

## Fonts

| Font | License |
|---|---|
| [Onest](https://github.com/googlefonts/onest) (`mobile/fonts/OFL-Onest.txt`) | SIL OFL 1.1 |
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) (`mobile/fonts/OFL-JetBrainsMono.txt`) | SIL OFL 1.1 |

## Data

The app fetches data from public services at run time; none of it is shipped in this repository.

| Source | What is used | Terms |
|---|---|---|
| [MusicBrainz](https://musicbrainz.org/doc/MusicBrainz_Database) | Catalog (artists, releases, recordings): core data only | Core data CC0; supplementary data and the Live Data Feed are CC BY-NC-SA 3.0 and are not used |
| [Cover Art Archive](https://coverartarchive.org/) | Cover images | Rights stay with each image's rights holder; terms on the service site (not verified offline) |
| [LRCLIB](https://lrclib.net/) | Lyrics lookup by the lyrics extension | Terms on the service site (not verified offline) |
| [Internet Archive](https://archive.org/) | Items found by the archive extension | Each item carries its own license; terms on the service site |
| [Last.fm](https://www.last.fm/api) | Artist ranking and top tracks; an optional source | Last.fm API terms apply; used only with the server owner's own API key |
| [Wikimedia Commons](https://commons.wikimedia.org/) | Artist photos | Per-file license; shown only with the author and the license, as in the app |

## Runtime images

| Component | License |
|---|---|
| python:3.12-slim | PSF + Debian |
| postgres:16-alpine | PostgreSQL License |

Legal audio fixtures under `contracts/fixtures/audio/` are a separate rights
question from source-code licenses; they are used by tests and checks only.
