# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Soldier виртуального устройства ввода в ядре Linux через uinput
"""
virtual_device_soldier.py

Одно виртуальное устройство ввода: клавиатура или мышь, которую ядро считает настоящей. Ввод
идёт не композитору, а прямо ядру, поэтому одинаково работает в режиме рабочего стола, в
игровом режиме и внутри игр.

Интерфейс ядра подключается при СОЗДАНИИ устройства, а не при импорте модуля: константы
событий нужны проверкам на Windows, где интерфейса ядра нет, и импорт модуля не имеет права
ронять их прогон.
"""

from __future__ import annotations

import os
import struct
import time

EV_SYN, EV_KEY, EV_REL, EV_ABS = 0x00, 0x01, 0x02, 0x03
SYN_REPORT = 0
REL_X, REL_Y, REL_HWHEEL, REL_WHEEL = 0x00, 0x01, 0x06, 0x08
ABS_X, ABS_Y = 0x00, 0x01

# Абсолютные оси объявляются в условных единицах, а не в пикселях: экран Deck'а
# меняет разрешение при подключении дока, и привязка осей к пикселям означала бы
# пересоздание устройства на каждое переключение.
ABS_MAX = 32767

# Значение события клавиши. Повтор обязан идти РОВНО как 2: ядро отбрасывает
# повторное нажатие уже нажатой клавиши, и автоповтор, посланный единицей,
# не доходит вообще (input_handle_event пропускает только смену состояния).
KEY_UP, KEY_DOWN, KEY_REPEAT = 0, 1, 2

BTN_LEFT, BTN_RIGHT, BTN_MIDDLE, BTN_SIDE, BTN_EXTRA = 0x110, 0x111, 0x112, 0x113, 0x114

_UINPUT_IOCTL_BASE = ord("U")


def _iow(nr: int, size: int) -> int:
    return (1 << 30) | (size << 16) | (_UINPUT_IOCTL_BASE << 8) | nr


def _io(nr: int) -> int:
    return (_UINPUT_IOCTL_BASE << 8) | nr


UI_SET_EVBIT = _iow(100, 4)
UI_SET_KEYBIT = _iow(101, 4)
UI_SET_RELBIT = _iow(102, 4)
UI_SET_ABSBIT = _iow(103, 4)
UI_DEV_CREATE = _io(1)
UI_DEV_DESTROY = _io(2)

_EVENT = struct.Struct("=qqHHi")          # struct input_event на 64-битном ядре
_DEV = struct.Struct("=80sHHHHi256i")     # struct uinput_user_dev


class VirtualDeviceSoldier:
    """Одно виртуальное устройство ввода в ядре."""

    def __init__(self, name, keys=(), rels=(), abss=(), vendor=0x1209, product=0x4B4D):
        import fcntl  # только Linux: импорт здесь, чтобы модуль читался и на Windows

        self._fcntl = fcntl
        self.name = name
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        for code in keys:
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        if rels:
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_REL)
            for code in rels:
                fcntl.ioctl(self.fd, UI_SET_RELBIT, code)
        if abss:
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_ABS)
            for code in abss:
                fcntl.ioctl(self.fd, UI_SET_ABSBIT, code)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_SYN)
        # Порядок полей uinput_user_dev: absmax[64], absmin[64], absfuzz, absflat
        limits = [0] * 256
        for code in abss:
            limits[code] = ABS_MAX          # absmax
            limits[64 + code] = 0           # absmin
        blob = _DEV.pack(name.encode("utf-8")[:79], 0x03, vendor, product, 1, 0, *limits)
        os.write(self.fd, blob)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        time.sleep(0.05)  # дать udev увидеть устройство

    def emit(self, etype, code, value):
        os.write(self.fd, _EVENT.pack(0, 0, etype, code, value))

    def sync(self):
        self.emit(EV_SYN, SYN_REPORT, 0)

    def close(self):
        try:
            self._fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        except OSError:
            pass
        os.close(self.fd)
