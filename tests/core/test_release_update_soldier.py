# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки обновления из выпусков: выбор версии, контрольная сумма, безопасная распаковка
from __future__ import annotations

import hashlib
import io
import json
import os
import tarfile

import pytest

from core import config_policy
from core.soldiers import release_update_soldier as updater_module
from core.soldiers.release_update_soldier import ReleaseUpdateSoldier, parse_version, safe_extract


def tarball(files: dict) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for name, content in files.items():
            data = content.encode("utf-8")
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o755 if name.endswith(".sh") else 0o644
            tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def release_json(tag, archive_name="SteamDeck-KVM-1.2.0-steamos-x86_64.tar.gz", sums=True):
    assets = [{"name": archive_name, "browser_download_url": "http://x/archive"}]
    if sums:
        assets.append({"name": config_policy.CHECKSUMS_ASSET, "browser_download_url": "http://x/sums"})
    return json.dumps({"tag_name": tag, "assets": assets, "body": "## Мышь в игровом режиме\n- подробности"}).encode()


def fetcher(pages):
    def fetch(url, timeout=20.0):
        return pages[url]
    return fetch


def test_parse_version():
    assert parse_version("v1.2.3") == (1, 2, 3)
    assert parse_version("1.10.0") > parse_version("1.9.9")
    assert parse_version("не версия") is None


def test_newer_release_is_offered_with_notes():
    pages = {config_policy.releases_url(): release_json("v1.2.0")}
    found = ReleaseUpdateSoldier("1.0.0", fetch=fetcher(pages)).check()
    assert found["version"] == "1.2.0" and found["notes"] == "Мышь в игровом режиме"


def test_same_or_older_release_is_not_offered():
    for tag in ("v1.0.0", "v0.9.0"):
        pages = {config_policy.releases_url(): release_json(tag)}
        assert ReleaseUpdateSoldier("1.0.0", fetch=fetcher(pages)).check() is None


def test_release_without_checksums_is_skipped():
    pages = {config_policy.releases_url(): release_json("v2.0.0", sums=False)}
    assert ReleaseUpdateSoldier("1.0.0", fetch=fetcher(pages)).check() is None


def test_network_failure_means_no_update():
    def broken(url, timeout=20.0):
        raise OSError("сети нет")
    assert ReleaseUpdateSoldier("1.0.0", fetch=broken).check() is None


def test_checksum_mismatch_is_rejected(tmp_path):
    archive = tarball({"SteamDeck-KVM-1.2.0-steamos-x86_64/app/VERSION": "1.2.0"})
    pages = {"http://x/archive": archive, "http://x/sums": b"0" * 64 + b"  SteamDeck-KVM-1.2.0-steamos-x86_64.tar.gz\n"}
    soldier = ReleaseUpdateSoldier("1.0.0", fetch=fetcher(pages), home=tmp_path)
    release = {"version": "1.2.0", "archive_name": "SteamDeck-KVM-1.2.0-steamos-x86_64.tar.gz",
               "archive_url": "http://x/archive", "sums_url": "http://x/sums"}
    with pytest.raises(ValueError, match="сумма"):
        soldier.apply(release)
    assert not (tmp_path / "versions" / "1.2.0").exists(), "испорченная загрузка не разложена"


def test_apply_lays_version_beside_and_switches_pointer(tmp_path, monkeypatch):
    name = "SteamDeck-KVM-1.2.0-steamos-x86_64.tar.gz"
    archive = tarball({"SteamDeck-KVM-1.2.0-steamos-x86_64/app/VERSION": "1.2.0",
                       "SteamDeck-KVM-1.2.0-steamos-x86_64/app/apps/deck/install.sh": "echo"})
    digest = hashlib.sha256(archive).hexdigest()
    pages = {"http://x/archive": archive, "http://x/sums": ("%s  %s\n" % (digest, name)).encode()}
    switched = {}
    monkeypatch.setattr(updater_module, "switch_current", lambda home, target: switched.update(target=target))
    soldier = ReleaseUpdateSoldier("1.0.0", fetch=fetcher(pages), home=tmp_path)
    target = soldier.apply({"version": "1.2.0", "archive_name": name,
                            "archive_url": "http://x/archive", "sums_url": "http://x/sums"})
    assert (target / "VERSION").read_text() == "1.2.0"
    assert switched["target"] == target


def test_switch_current_is_atomic_symlink(tmp_path):
    old, new = tmp_path / "versions" / "1.0.0", tmp_path / "versions" / "1.2.0"
    old.mkdir(parents=True)
    new.mkdir(parents=True)
    try:
        updater_module.switch_current(tmp_path, old)
    except OSError as error:
        pytest.skip("на этой машине символические ссылки запрещены (%s) — на Deck'е они есть всегда" % error)
    updater_module.switch_current(tmp_path, new)
    assert os.path.realpath(tmp_path / "app") == os.path.realpath(new)


def test_path_traversal_archive_is_rejected(tmp_path):
    evil = tmp_path / "evil.tar.gz"
    evil.write_bytes(tarball({"../../вне.txt": "попытка выйти наружу"}))
    with pytest.raises(ValueError, match="выйти"):
        safe_extract(evil, tmp_path / "out")
    assert not (tmp_path.parent / "вне.txt").exists()
