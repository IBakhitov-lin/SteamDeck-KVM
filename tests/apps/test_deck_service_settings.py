# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки чтения настроек службы Steam Deck только из своего файла
"""
test_deck_service_settings.py

Прежний установщик сам писал в `/etc/deck-kvm.conf` строку `pointer=abs`, и служба брала её как
выбор человека: курсор в игровом режиме не двигался вовсе. Служба читает только свой файл.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVICE = ROOT / "apps" / "deck" / "steamdeck_kvm_service.py"


def service():
    spec = importlib.util.spec_from_file_location("steamdeck_kvm_service", SERVICE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_own_file_is_read(tmp_path):
    own = tmp_path / "settings.conf"
    own.write_text("server=192.168.0.11  # ПК\npointer=rel\n", encoding="utf-8")
    assert service().read_settings(own) == {"server": "192.168.0.11", "pointer": "rel"}


def test_no_own_file_no_settings(tmp_path):
    assert service().read_settings(tmp_path / "missing.conf") == {}


def test_legacy_file_is_never_opened():
    code = SERVICE.read_text(encoding="utf-8").split('"""', 2)[2]      # без паспорта модуля
    body = code.split("def read_settings", 1)[1].split("def load_palette", 1)[0]
    body = body.split('"""', 2)[2]                                      # без описания функции
    assert "/etc/" not in body
