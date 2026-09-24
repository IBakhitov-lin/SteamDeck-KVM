# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки решения службы Steam Deck об обновлении: только по просьбе компьютера
"""
test_deck_service_update.py

Deck обновляется двумя путями: кнопкой в своём окне и по просьбе компьютера (его кнопка «Обновить»
и уведомление). Сам Deck ничего не ставит — обновление только по нажатию человека. Просьба исполняется в любом режиме: служба режима не проверяет.
Живая цепочка «просьба → служба → установщик → новая версия» — в песочнице `test_update_sandbox.py`.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVICE = ROOT / "apps" / "deck" / "steamdeck_kvm_service.py"


def service():
    spec = importlib.util.spec_from_file_location("steamdeck_kvm_service_update", SERVICE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_pc_request_updates_at_once():
    assert service().should_update(asked=True, updating=False)


def test_nothing_is_installed_without_a_request():
    assert not service().should_update(asked=False, updating=False)


def test_running_update_is_not_started_twice():
    assert not service().should_update(asked=True, updating=True)


def test_no_self_update_left_in_service():
    text = SERVICE.read_text(encoding="utf-8")
    assert "AUTO_UPDATE" not in text and "самообновление" not in text
