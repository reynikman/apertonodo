# Apertonodo

[English](README.md) | Русский

Apertonodo — сервер музыки, который вы ставите у себя. Apertono — его приложение
для Android. Вы ищете песню в каталоге, нажимаете Play, и музыка играет. Своя папка
с музыкой тоже работает.

Apertonodo не содержит источников музыки; расширения ставит сам пользователь.
Список расширений: [github.com/apertono/extensions](https://github.com/apertono/extensions).

- **Каталог.** Поиск по исполнителям, альбомам и песням через MusicBrainz.
  Обложки берутся из Cover Art Archive.
- **Своя папка.** Положите файлы с музыкой в папку на сервере, приложение их проиграет.
- **Расширения.** Откуда берётся музыка, решают небольшие отдельные сервисы.
  Три идут с установкой: `folder` (ваша папка), `archive` (Internet Archive) и
  `lyrics` (тексты песен с LRCLIB). Другие расширения, в том числе источники: https://github.com/apertono/extensions
- **Учётные записи.** У каждого человека своё имя и пароль. Без рекламы и без телеметрии.

## Статус: бета

Версия 0.9.0 — бета (pre-release на GitHub). Работает: поиск в каталоге, Play, своя папка
с музыкой, расширения, учётные записи, плейлисты и история.

Что ещё не готово:

- Автообновление приложения работает только начиная с этой версии: старые сборки обновления не ищут.
- Приложение для iPhone — позже, пока только Android.
- Расширения добавляются на сервере, не из приложения: `./scripts/extension.sh add <имя>`.
- Ранжирование поиска бывает неточным.
- Неделя прослушивания ещё не пройдена.

## Что нужно

Сервер:

- Linux, x86_64
- Docker с Docker Compose v2 (проверка: `docker compose version`)
- `git` и `curl`

Телефон: Android 7.0 или новее (`minSdk` приложения — 24).

## Установка сервера

```bash
git clone https://github.com/reynikman/apertonodo
cd apertonodo
./scripts/install.sh
```

Скрипт делает по порядку:

1. проверяет, что Docker Compose работает;
2. создаёт `.env` из `.env.example` со случайными секретами (ключ API, пароль базы,
   пароль первого пользователя) и закрывает файл от чужих;
3. запускает сервер: `docker compose up -d --build`;
4. ждёт до 120 секунд ответа `GET /v1/health`;
5. создаёт первого пользователя `admin` и печатает адрес, имя и пароль.

Первая сборка скачивает образы и идёт несколько минут. Сохраните напечатанный пароль.
Он же записан в `.env`.

Если `.env` уже есть, скрипт его не меняет и берёт секреты из него: если первый запуск оборвался, просто запустите скрипт ещё раз.
Проверить, что сервер жив: `curl http://localhost:8088/v1/health`.

По умолчанию сервер ищет в онлайн-MusicBrainz и один раз при старте пишет в лог строку
`catalog: no local MusicBrainz copy, using online MusicBrainz`. Как поставить свою копию каталога,
описано позже.

Если приложение пишет «Каталог сейчас не отвечает» (в логе сервера `catalog search failed: TimeoutError`), машина не достаёт до `musicbrainz.org` (в некоторых странах он
закрыт). Впишите в `.env` `MUSICBRAINZ_PROXY` — HTTP(S)-прокси, через который он открывается, и выполните
`docker compose up -d api`.

## Установка приложения

1. Откройте страницу **Releases** этого репозитория и скачайте свежий `.apk`.
2. Откройте файл на телефоне и разрешите установку из этого источника.
   Имя пакета приложения — `app.apertono.player`.
3. Запустите Apertono. Введите адрес сервера (`http://<адрес сервера>:8088`),
   имя `admin` и пароль, который напечатал `install.sh`.

Телефон должен достать до сервера: одна сеть Wi-Fi или публичный адрес за обратным
прокси (ниже).

## Своя музыка

`install.sh` создаёт папку `./music` рядом с `docker-compose.yml`. Кладите туда файлы
с музыкой, они появятся в приложении. Другая папка — строка `MUSIC_PATH=/путь/к/музыке`
в `.env` и `docker compose up -d`.

## Расширения

Сервер спрашивает расширения, где искать музыку. Каждое добавляется одной командой в папке с
`docker-compose.yml`: команда скачивает расширение (в `./extensions`), правит `.env` и запускает его.
Повторный запуск ничего не меняет. Все три `install.sh` уже подключил.

| Расширение | Что делает | Добавить | Убрать |
|---|---|---|---|
| `folder` | играет вашу папку с музыкой | `./scripts/extension.sh add folder` | `./scripts/extension.sh remove folder` |
| `archive` | играет из Internet Archive | `./scripts/extension.sh add archive` | `./scripts/extension.sh remove archive` |
| `lyrics` | тексты песен с LRCLIB | `./scripts/extension.sh add lyrics` | `./scripts/extension.sh remove lyrics` |

`./scripts/extension.sh list` показывает, какие включены. Другие расширения, в том числе источники:
https://github.com/apertono/extensions (той же командой; сначала прочтите, что там сказано про вашу
ответственность).

Если вы обновляетесь с версии, где `folder` и `lyrics` были в `docker-compose.yml`: один раз выполните
`./scripts/extension.sh add folder` и `./scripts/extension.sh add lyrics`.
Договор расширения — `contracts/extension-api.md`.

## Обратный прокси

Чтобы открыть сервер из интернета, поставьте перед ним обратный прокси с HTTPS.
Порт сервера (`APERTONO_PORT`, 8088) отдаёт голый HTTP без шифрования: из дома по локальной сети можно, наружу — только через прокси с TLS.
Что прокси обязан делать и пример для nginx: [docs/reverse-proxy.md](docs/reverse-proxy.md).

## Обновление

```bash
git pull
docker compose up -d --build
```

Учётные записи и библиотека остаются в томе базы. `.env` не меняется.

## Резервная копия

Всё, что создали люди (учётные записи, библиотека, плейлисты, история), лежит в базе.
Файлов с музыкой в архиве нет: папку с музыкой копируйте сами.

```bash
docker compose exec -T api cat /app/scripts/backup.sh > backup.sh
docker compose exec -T -e APERTONODO_PG_BIN=/usr/local/bin postgres sh -s -- \
    --database-url postgresql://music@/music --directory /tmp/backup < backup.sh
docker compose cp postgres:/tmp/backup ./backup
```

Подробности и проверка восстановления: [docs/backup.md](docs/backup.md).

## Лицензия

MIT, см. `LICENSE`. Лицензии сторонних компонентов: `THIRD_PARTY_NOTICES.md`.
