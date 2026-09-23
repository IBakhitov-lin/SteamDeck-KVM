# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Общие заглушки проверок: поддельные устройства ввода и датчик сеанса
"""
conftest.py

Проверки ядра идут на Windows, где нет ни интерфейса ядра Linux, ни композитора. Поэтому
устройства ввода подменяются записью событий, а датчик сеанса — объектом с заданными ответами.
Настоящий предмет при этом запускается целиком: подменяется только то, чего на этой машине нет.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


class FakeDevice:
    def __init__(self, name, keys=(), rels=(), abss=(), **_):
        self.name = name
        self.keys = tuple(keys)
        self.rels = tuple(rels)
        self.abss = tuple(abss)
        self.events = []
        self.closed = False

    def emit(self, etype, code, value):
        self.events.append((etype, code, value))

    def sync(self):
        self.events.append(("SYN",))

    def close(self):
        self.closed = True


class FakeSensor:
    def __init__(self, mode="desktop", display=True, size=(1280, 800), captured=None):
        self.mode = mode
        self.display = display
        self.size = size
        self.captured = captured

    def cursor_captured(self):
        return self.captured

    def screen_size(self):
        return self.size

    def display_on(self):
        return self.display

    def session_mode(self):
        return self.mode


@pytest.fixture
def fake_sensor():
    return FakeSensor()


@pytest.fixture(autouse=True)
def isolated_state(tmp_path, monkeypatch):
    """Состояние клиента — во временной папке: проверка не имеет права тронуть настоящее."""
    monkeypatch.setenv("STEAMDECK_KVM_STATE", str(tmp_path / "state"))
    monkeypatch.setenv("STEAMDECK_KVM_HOME", str(tmp_path / "home"))
    return tmp_path
