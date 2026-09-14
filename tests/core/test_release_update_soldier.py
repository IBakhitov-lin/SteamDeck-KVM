# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки поиска обновления клиента Steam Deck по выпускам GitHub
from __future__ import annotations

from core import config_policy
from core.soldiers.release_update_soldier import ReleaseUpdateSoldier, parse_version

REPO = "https://github.com/IBakhitov-lin/SteamDeck-KVM"


def resolver(final):
    def resolve(url, timeout=20.0):
        assert url == config_policy.releases_url()
        return final
    return resolve


def test_parse_version():
    assert parse_version("v1.2.3") == (1, 2, 3)
    assert parse_version("1.10.0") > parse_version("1.9.9")
    assert parse_version("не версия") is None


def test_release_page_is_on_github_com_not_api():
    """api.github.com и raw.githubusercontent.com в части сетей недоступны — только github.com."""
    assert config_policy.releases_url().startswith("https://github.com/")


def test_newer_release_is_found_by_redirect():
    found = ReleaseUpdateSoldier("1.0.0", resolve=resolver(REPO + "/releases/tag/v1.2.0")).check()
    assert found == {"version": "1.2.0", "notes": ""}


def test_same_older_or_unreadable_release_is_not_offered():
    for final in (REPO + "/releases/tag/v1.0.0", REPO + "/releases/tag/v0.9.0",
                  REPO + "/releases/tag/nightly", REPO + "/releases"):
        assert ReleaseUpdateSoldier("1.0.0", resolve=resolver(final)).check() is None


def test_network_failure_means_no_update_and_is_logged():
    lines = []

    def broken(url, timeout=20.0):
        raise OSError("сети нет")
    assert ReleaseUpdateSoldier("1.0.0", log=lines.append, resolve=broken).check() is None
    assert lines and "сети нет" in lines[0]
