# Apertonodo 0.9.0 (beta)

This is a beta, published as a GitHub pre-release.

Apertonodo is a self-hosted music server; Apertono is its Android app. Apertonodo contains no
music sources; extensions are added by the user with `./scripts/extension.sh add <name>`
([github.com/apertono/extensions](https://github.com/apertono/extensions)).

## What works

Search in the catalog, Play, your music folder, extensions, accounts, playlists and history.

## Not ready yet

- Automatic update of the app works only from this version on: older builds do not look for updates.
- iPhone app: coming later. For now Android only.
- Extensions are added on the server, not from the app: `./scripts/extension.sh add <name>`.
- Search ranking is sometimes inaccurate.
- The week-long listening test has not been passed yet.

## Install

Server: see the README (`./scripts/install.sh`). Phone: download the `.apk` from this release.
