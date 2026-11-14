#!/usr/bin/env bash
# Toolchain discovery for the Flutter client. Source it, do not execute it.
[[ ! -d "${HOME}/.pub-cache/bin" ]] || export PATH="${HOME}/.pub-cache/bin:${PATH}"

if [[ "$(uname -s)" == "Darwin" ]]; then
  [[ ! -d /opt/homebrew/opt/openjdk@17/bin ]] || export PATH="/opt/homebrew/opt/openjdk@17/bin:${PATH}"
  [[ ! -d /opt/homebrew/bin ]] || export PATH="/opt/homebrew/bin:${PATH}"
  if [[ -z "${JAVA_HOME:-}" && -x /opt/homebrew/opt/openjdk@17/bin/java ]]; then
    export JAVA_HOME=/opt/homebrew/opt/openjdk@17
  fi
  if [[ -z "${ANDROID_HOME:-}" && -d /opt/homebrew/share/android-commandlinetools ]]; then
    export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
  fi
fi

[[ -z "${ANDROID_HOME:-}" ]] || export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

if [[ -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME}/platform-tools" ]]; then
  export PATH="${ANDROID_HOME}/platform-tools:${PATH}"
fi
