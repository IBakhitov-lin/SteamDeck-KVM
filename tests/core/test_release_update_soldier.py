# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки поиска обновления клиента Steam Deck по выпускам GitHub
from __future__ import annotations

import json

from core import config_policy
from core.soldiers.release_update_soldier import ReleaseUpdateSoldier, parse_version


def release_json(tag, assets=None):
    return json.dumps({"tag_name": tag, "assets": assets or [],
                       "body": "## Мышь в игровом режиме\n- подробности"}).encode()


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
    assert found == {"version": "1.2.0", "notes": "Мышь в игровом режиме"}


def test_release_needs_no_files_for_the_deck():
    """Программа Deck'а берётся из архива исходного кода выпуска: отдельных файлов у выпуска для неё нет."""
    pages = {config_policy.releases_url(): release_json("v2.0.0", assets=[{"name": "SteamDeck-KVM-2.0.0-windows-x64-setup.exe"}])}
    assert ReleaseUpdateSoldier("1.0.0", fetch=fetcher(pages)).check()["version"] == "2.0.0"


def test_same_or_older_or_unreadable_release_is_not_offered():
    for tag in ("v1.0.0", "v0.9.0", "nightly"):
        pages = {config_policy.releases_url(): release_json(tag)}
        assert ReleaseUpdateSoldier("1.0.0", fetch=fetcher(pages)).check() is None


def test_network_failure_means_no_update_and_is_logged():
    lines = []

    def broken(url, timeout=20.0):
        raise OSError("сети нет")
    assert ReleaseUpdateSoldier("1.0.0", log=lines.append, fetch=broken).check() is None
    assert lines and "сети нет" in lines[0]
