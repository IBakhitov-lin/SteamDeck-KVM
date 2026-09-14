# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Постоянные клиента Steam Deck и пути его данных в одном месте
"""
config_policy.py

Порты, имя протокола, адрес выпусков и папки на диске Deck'а. Модуль лежит в корне `core/`
по исключению канона слоёв для политик конфигурации (`config_policy.py`) и суффикса роли
не несёт.

Почему данные разведены по трём папкам. Обновление заменяет программу целиком, и всё, что
лежит рядом с ней, пропадает вместе со старой версией. Поэтому программа, её состояние и
загрузки живут раздельно, по стандарту каталогов рабочего стола Linux:

1. `~/.local/share/steamdeck-kvm/` — программа: версии и указатель на текущую
2. `~/.local/state/steamdeck-kvm/` — состояние: номер Deck'а, знакомый компьютер, его адрес
3. `/var/lib/deck-kvm/` — место прежней установки от администратора; читается один раз
   при переезде, чтобы знакомство с компьютером пережило смену способа установки

Каждый путь переопределяется переменной окружения — так проверки работают во временной
папке, не трогая настоящих данных.
"""

from __future__ import annotations

import os
from pathlib import Path

KVM_PORT = 24800        # порт протокола Barrier/Synergy — его слушает Deskflow на ПК
BEACON_PORT = 24801     # рассылка знакомства: ПК вещает, Deck слушает
CONTROL_PORT = 24802    # окно на Deck'е спрашивает службу через этот порт, только локально
PROTOCOL = "DECKKVM2"
SCREEN_NAME = "steamdeck"

GITHUB_REPO = "IBakhitov-lin/SteamDeck-KVM"

# Последний выпуск узнаётся по перенаправлению страницы github.com/…/releases/latest на метку
# версии: api.github.com в части сетей недоступен, а github.com открывается и из браузера Deck'а.
UPDATE_CHECK_SECONDS = 6 * 3600

LEGACY_STATE_DIR = Path("/var/lib/deck-kvm")


def releases_url() -> str:
    return os.environ.get(
        "STEAMDECK_KVM_RELEASES_URL",
        f"https://github.com/{GITHUB_REPO}/releases/latest",
    )


def _xdg(variable: str, fallback: str) -> Path:
    value = os.environ.get(variable)
    return Path(value) if value else Path.home() / fallback


def state_dir() -> Path:
    override = os.environ.get("STEAMDECK_KVM_STATE")
    if override:
        return Path(override)
    return _xdg("XDG_STATE_HOME", ".local/state") / "steamdeck-kvm"


def repo_root() -> Path:
    """Корень дерева программы: здесь лежат `core/`, `apps/` и `VERSION`."""
    return Path(__file__).resolve().parents[1]


def app_version() -> str:
    try:
        return (repo_root() / "VERSION").read_text(encoding="utf-8").strip() or "0.0.0"
    except OSError:
        return "0.0.0"
