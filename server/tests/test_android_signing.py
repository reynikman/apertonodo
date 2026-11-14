"""Persistent APK signing key (FT-775, Р-A106).

Without a persistent key the app cannot be updated in place: Android installs
an update only with the same signature. The key is stored in GitLab variables
(`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD`), it is not in the repository and must never be.
"""

from __future__ import annotations

import base64
import os
import stat
import subprocess
from pathlib import Path

import yaml
from not_in_slice import needs

pytestmark = needs("scripts/android_signing.sh", ".gitlab-ci.yml")

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "android_signing.sh"
SECRET = "s3cret-pass-не-печатать"


def _run(tmp_path: Path, env_extra: dict[str, str]) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if not k.startswith("ANDROID_")}
    env.update(env_extra)
    env["FLOWTUNE_ANDROID_DIR"] = str(tmp_path)
    return subprocess.run(
        ["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30
    )


def _key_env() -> dict[str, str]:
    return {
        "ANDROID_KEYSTORE_BASE64": base64.b64encode(b"fake-keystore-bytes").decode(),
        "ANDROID_KEYSTORE_PASSWORD": SECRET,
        "ANDROID_KEY_ALIAS": "apertono",
        "ANDROID_KEY_PASSWORD": SECRET,
    }


def test_writes_key_properties_from_env_without_printing_secret(tmp_path: Path) -> None:
    done = _run(tmp_path, _key_env())
    assert done.returncode == 0, done.stderr
    assert SECRET not in done.stdout + done.stderr, "key password leaked into log"

    props = (tmp_path / "key.properties").read_text()
    lines = dict(line.split("=", 1) for line in props.splitlines() if "=" in line)
    assert lines["keyAlias"] == "apertono"
    assert lines["storePassword"] == SECRET
    assert lines["keyPassword"] == SECRET
    store = (
        (tmp_path / "app" / lines["storeFile"])
        if not lines["storeFile"].startswith("/")
        else Path(lines["storeFile"])
    )
    assert store.read_bytes() == b"fake-keystore-bytes"
    for path in (tmp_path / "key.properties", store):
        assert stat.S_IMODE(path.stat().st_mode) & 0o077 == 0, (
            f"{path.name} is readable by others"
        )


def test_without_key_env_writes_nothing_and_says_so(tmp_path: Path) -> None:
    done = _run(tmp_path, {})
    assert done.returncode == 0, done.stderr
    assert not (tmp_path / "key.properties").exists()
    assert "no key" in done.stdout + done.stderr


def test_half_set_key_env_fails_loudly(tmp_path: Path) -> None:
    env = _key_env()
    del env["ANDROID_KEY_PASSWORD"]
    done = _run(tmp_path, env)
    assert done.returncode != 0, "incomplete key would silently produce an APK with disposable signature"
    assert not (tmp_path / "key.properties").exists()
    assert "ANDROID_KEY_PASSWORD" in done.stderr, "not specified which variable is missing"


def test_signed_apk_job_verifies_certificate() -> None:
    ci = yaml.safe_load((ROOT / ".gitlab-ci.yml").read_text())
    job = ci.get("mobile-signed-apk")
    assert job, "missing job that builds APK with persistent key"
    script = "\n".join(job.get("before_script", []) + job["script"])
    assert "android_signing.sh" in script
    assert "apksigner verify" in script and "--print-certs" in script, (
        "built APK signature is not verified"
    )
    assert "allowDebugSigning" not in script, "disposable key in signed build"
    assert job.get("resource_group") == "android-release-build"
    artifacts = job.get("artifacts", {}).get("paths", [])
    assert any(p.endswith(".apk") for p in artifacts)
    rules = job.get("rules", [])
    assert any(
        r.get("if", "").find("schedule") >= 0 and r.get("when") == "never"
        for r in rules
    )
    assert any(
        r.get("when") == "manual" or "CI_COMMIT_TAG" in r.get("if", "") for r in rules
    ), "signed build is manual or on release tag, not on every push"


def test_keystore_never_tracked() -> None:
    tracked = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True, check=True
    ).stdout.splitlines()
    assert not [
        p for p in tracked if p.endswith((".jks", ".keystore", "key.properties"))
    ]
