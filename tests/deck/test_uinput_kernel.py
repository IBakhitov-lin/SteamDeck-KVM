# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверка на настоящем ядре Steam Deck: устройство создаётся, события читаются обратно
"""
test_uinput_kernel.py

Идёт только на самом Deck'е: нужен интерфейс ядра /dev/uinput с правом записи. На Windows и на
машине без доступа пропускается с названной причиной — пропуск не равен успеху.

Запуск на Deck'е из папки программы:
    python3 -m pytest tests/deck -q
"""

from __future__ import annotations

import os
import select
import struct
import sys
import time
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    not sys.platform.startswith("linux") or not os.access("/dev/uinput", os.W_OK),
    reason="нужен Linux с правом записи в /dev/uinput — проверка ядра идёт на самом Deck'е",
)

EVENT = struct.Struct("=qqHHi")


def event_node(name):
    for folder in Path("/sys/class/input").glob("event*"):
        try:
            if (folder / "device" / "name").read_text().strip() == name:
                return "/dev/input/" + folder.name
        except OSError:
            continue
    return None


def read_events(fd, timeout=1.0):
    events = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            data = os.read(fd, EVENT.size * 32)
            for offset in range(0, len(data), EVENT.size):
                _, _, etype, code, value = EVENT.unpack_from(data, offset)
                events.append((etype, code, value))
    return events


def test_keyboard_and_mouse_reach_kernel():
    from core.officers.input_translation_officer import KEYBOARD_CODES, K
    from core.soldiers.virtual_device_soldier import (
        ABS_X, EV_ABS, EV_KEY, EV_REL, REL_X, REL_Y, VirtualDeviceSoldier,
    )

    keyboard = VirtualDeviceSoldier("SteamDeck-KVM Test Keyboard", keys=KEYBOARD_CODES)
    mouse = VirtualDeviceSoldier("SteamDeck-KVM Test Mouse", keys=[0x110], rels=(REL_X, REL_Y), abss=(ABS_X, 1))
    try:
        time.sleep(0.5)
        nodes = event_node(keyboard.name), event_node(mouse.name)
        assert all(nodes), "ядро не показало созданные устройства"
        fds = [os.open(node, os.O_RDONLY | os.O_NONBLOCK) for node in nodes]
        try:
            keyboard.emit(EV_KEY, K["A"], 1)
            keyboard.sync()
            mouse.emit(EV_REL, REL_X, 5)
            mouse.emit(EV_ABS, ABS_X, 100)
            mouse.sync()
            assert (EV_KEY, K["A"], 1) in read_events(fds[0])
            got = read_events(fds[1])
            assert (EV_REL, REL_X, 5) in got and (EV_ABS, ABS_X, 100) in got, \
                "одно устройство принимает и смещения, и абсолютную ось"
        finally:
            for fd in fds:
                os.close(fd)
    finally:
        keyboard.close()
        mouse.close()
