# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Soldier проверки обновления клиента Steam Deck по выпускам GitHub
"""
release_update_soldier.py

Ответить на один вопрос: вышел ли выпуск новее установленной версии. Ставит новую версию
установщик (`apps/deck/install.sh --latest`), тот же, что при первой установке, — второго
способа разложить программу нет.

Почему официальный интерфейс выпусков, а не git. Человеку на Deck'е git не нужен: обновление —
одна кнопка. Интерфейс работает без ключа (шестьдесят запросов в час на адрес).
"""

from __future__ import annotations

import json
import re
import urllib.request

from core import config_policy

USER_AGENT = "SteamDeck-KVM-updater"


def parse_version(text: str):
    """«v1.2.3» → (1, 2, 3). Нечитаемое — None: сравнивать не с чем, обновления нет."""
    match = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", (text or "").strip())
    return tuple(int(part) for part in match.groups()) if match else None


def _default_fetch(url: str, timeout: float = 20.0) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 — адрес свой
        return response.read()


class ReleaseUpdateSoldier:
    def __init__(self, current_version: str, log=lambda text: None, fetch=None):
        self.current = current_version
        self.log = log
        self.fetch = fetch or _default_fetch

    # ---- проверка -------------------------------------------------------------

    def check(self):
        """Выпуск новее текущей версии либо None. Любой отказ сети — None и строка в журнал."""
        try:
            release = json.loads(self.fetch(config_policy.releases_url()).decode("utf-8"))
        except Exception as error:  # сеть, лимит, неразборчивый ответ — обновления просто нет
            self.log("проверка обновлений не удалась: %s" % error)
            return None
        latest = parse_version(release.get("tag_name", ""))
        current = parse_version(self.current)
        if latest is None or current is None or latest <= current:
            return None
        notes = (release.get("body") or "").strip().splitlines()
        return {
            "version": "%d.%d.%d" % latest,
            "notes": notes[0].lstrip("#- ").strip() if notes else "",
        }
