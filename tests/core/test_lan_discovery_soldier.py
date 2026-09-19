# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки знакомства Deck'а с компьютером и памяти о паре
from __future__ import annotations

import socket

from core import config_policy
from core.soldiers import lan_discovery_soldier as discovery_module
from core.soldiers.lan_discovery_soldier import LanDiscoverySoldier, device_id, migrate_legacy_state


def beacon(pc_id, name="DESKTOP-PC", state="on", knows="-"):
    return ("%s SERVER %s %s 24800 %s %s" % (config_policy.PROTOCOL, pc_id, name, state, knows)).encode()


def soldier():
    return LanDiscoverySoldier("steamdeck", lambda text: None, bind_port=0)


def test_first_beacon_pairs_and_remembers():
    s = soldier()
    try:
        assert s.accept(beacon("pc-1"), ("192.168.0.14", 50000)) is True
        assert s.peer == "pc-1" and s.address == "192.168.0.14" and s.server_on
        again = soldier()
        assert again.peer == "pc-1", "пара пережила перезапуск"
        assert LanDiscoverySoldier.recall() == "192.168.0.14"
        again.close()
    finally:
        s.close()


def test_stranger_pc_is_ignored_after_pairing():
    s = soldier()
    try:
        s.accept(beacon("pc-1"), ("192.168.0.14", 50000))
        assert s.accept(beacon("pc-2", name="СОСЕД"), ("192.168.0.99", 50000)) is False
        assert s.address == "192.168.0.14"
    finally:
        s.close()


def test_pc_busy_with_other_deck_is_not_taken():
    s = soldier()
    try:
        assert s.accept(beacon("pc-1", knows="чужой-deck"), ("192.168.0.14", 50000)) is False
        assert s.peer is None
    finally:
        s.close()


def test_address_change_is_followed_without_new_pairing():
    s = soldier()
    try:
        s.accept(beacon("pc-1"), ("192.168.0.14", 50000))
        s.accept(beacon("pc-1"), ("10.0.0.5", 50001))
        assert s.peer == "pc-1" and s.address == "10.0.0.5"
    finally:
        s.close()


def test_forget_keeps_own_number():
    s = soldier()
    try:
        own = s.id
        s.accept(beacon("pc-1"), ("192.168.0.14", 50000))
        s.forget()
        assert s.peer is None and LanDiscoverySoldier.recall() is None
        assert device_id() == own, "забывается пара, а не само устройство"
    finally:
        s.close()


def test_reply_goes_to_sender_port():
    listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    listener.bind(("127.0.0.1", 0))
    listener.settimeout(2)
    s = soldier()
    try:
        s.accept(beacon("pc-1"), listener.getsockname())
        reply, _ = listener.recvfrom(1024)
        parts = reply.decode().split()
        assert parts[:2] == [config_policy.PROTOCOL, "DECK"] and parts[2] == s.id
    finally:
        s.close()
        listener.close()


def test_legacy_state_is_migrated_once_and_not_overwritten(tmp_path, monkeypatch):
    legacy = tmp_path / "legacy"
    legacy.mkdir()
    (legacy / "identity").write_text("старый-номер\n", encoding="utf-8")
    (legacy / "pair").write_text("pc-1\n", encoding="utf-8")
    monkeypatch.setattr(config_policy, "LEGACY_STATE_DIR", legacy)
    assert migrate_legacy_state() == 2
    assert device_id() == "старый-номер", "номер Deck'а сохранён — компьютер его узнает"
    (legacy / "pair").write_text("pc-другой\n", encoding="utf-8")
    assert migrate_legacy_state() == 0, "повторный переезд не откатывает пару"
    assert (config_policy.state_dir() / discovery_module.PAIR_FILE).read_text(encoding="utf-8").strip() == "pc-1"


def test_unreadable_state_file_does_not_crash(tmp_path):
    """Регрессия: файл состояния в чужой кодировке ронял чтение и оставлял Deck без связи."""
    folder = config_policy.state_dir()
    folder.mkdir(parents=True, exist_ok=True)
    (folder / discovery_module.IDENTITY_FILE).write_bytes("номер".encode("cp1251") + b"\r\n")
    assert device_id(), "номер прочитан с заменой байтов, служба не упала"


def test_pc_languages_are_taken_from_beacon():
    s = soldier()
    try:
        s.accept(beacon("pc-1") + b" en-US,ru-RU", ("192.168.0.14", 50000))
        assert s.languages == "en-US,ru-RU"
        s.accept(beacon("pc-1"), ("192.168.0.14", 50000))
        assert s.languages == "en-US,ru-RU", "маячок прежнего ПК без языков не стирает известные"
    finally:
        s.close()
