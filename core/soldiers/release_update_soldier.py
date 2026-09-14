# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Soldier проверки обновления клиента Steam Deck по выпускам GitHub
"""
release_update_soldier.py

Ответить на один вопрос: вышел ли выпуск новее установленной версии. Ставит новую версию
установщик (`apps/deck/install.sh --latest`), тот же, что при первой установке, — второго
способа разложить программу нет.

Как узнаётся последняя версия. Страница github.com/…/releases/latest перенаправляет на
…/releases/tag/vX.Y.Z — метка берётся из конечного адреса. Интерфейс api.github.com и сервис
raw.githubusercontent.com в части сетей недоступны, а github.com открывается и из браузера Deck'а.
"""

from __future__ import annotations

import re
import urllib.request

from core import config_policy

USER_AGENT = "SteamDeck-KVM-updater"


def parse_version(text: str):
    """«v1.2.3» → (1, 2, 3). Нечитаемое — None: сравнивать не с чем, обновления нет."""
    match = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", (text or "").strip())
    return tuple(int(part) for part in match.groups()) if match else None


def _default_resolve(url: str, timeout: float = 20.0) -> str:
    """Конечный адрес после перенаправлений."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 — адрес свой
        return response.geturl()


class ReleaseUpdateSoldier:
    def __init__(self, current_version: str, log=lambda text: None, resolve=None):
        self.current = current_version
        self.log = log
        self.resolve = resolve or _default_resolve

    # ---- проверка -------------------------------------------------------------

    def check(self):
        """Выпуск новее текущей версии либо None. Любой отказ сети — None и строка в журнал."""
        try:
            final = self.resolve(config_policy.releases_url())
        except Exception as error:  # сеть или отказ сервиса — обновления просто нет
            self.log("проверка обновлений не удалась: %s" % error)
            return None
        tag = final.rstrip("/").rsplit("/tag/", 1)[-1] if "/tag/" in final else ""
        latest = parse_version(tag)
        current = parse_version(self.current)
        if latest is None or current is None or latest <= current:
            return None
        return {"version": "%d.%d.%d" % latest, "notes": ""}
