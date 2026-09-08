#!/usr/bin/env python3
"""
deck-kvm — клиент общей клавиатуры и мыши для Steam Deck.

Говорит по протоколу Barrier/Synergy (сервер — Deskflow на ноутбуке),
а ввод отдаёт не композитору, а прямо ядру через /dev/uinput.
Поэтому работает одинаково в Desktop Mode, в Game Mode и внутри игр:
для системы это обычная USB-клавиатура и обычная мышь.

Зависимостей нет — только стандартная библиотека Python 3.
"""

import fcntl
import os
import re
import selectors
import socket
import struct
import sys
import time

# --------------------------------------------------------------------------
# Слой 1. Виртуальные устройства ядра (uinput)
# --------------------------------------------------------------------------

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

UINPUT_IOCTL_BASE = ord("U")


def _iow(nr: int, size: int) -> int:
    return (1 << 30) | (size << 16) | (UINPUT_IOCTL_BASE << 8) | nr


def _io(nr: int) -> int:
    return (UINPUT_IOCTL_BASE << 8) | nr


UI_SET_EVBIT = _iow(100, 4)
UI_SET_KEYBIT = _iow(101, 4)
UI_SET_RELBIT = _iow(102, 4)
UI_SET_ABSBIT = _iow(103, 4)
UI_DEV_CREATE = _io(1)
UI_DEV_DESTROY = _io(2)

_EVENT = struct.Struct("=qqHHi")          # struct input_event на 64-битном ядре
_DEV = struct.Struct("=80sHHHHi256i")     # struct uinput_user_dev


class VirtualDevice:
    """Одно виртуальное устройство ввода в ядре."""

    def __init__(self, name, keys=(), rels=(), abss=(), vendor=0x1209,
                 product=0x4B4D):
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
        blob = _DEV.pack(
            name.encode("utf-8")[:79], 0x03, vendor, product, 1, 0, *limits
        )
        os.write(self.fd, blob)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        time.sleep(0.05)  # дать udev увидеть устройство

    def emit(self, etype, code, value):
        os.write(self.fd, _EVENT.pack(0, 0, etype, code, value))

    def sync(self):
        self.emit(EV_SYN, SYN_REPORT, 0)

    def close(self):
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        except OSError:
            pass
        os.close(self.fd)


# --------------------------------------------------------------------------
# Слой 2. Таблица клавиш: KeyID протокола -> код клавиши ядра
# --------------------------------------------------------------------------

# Позиционная раскладка: имя клавиши -> код evdev
K = {
    "ESC": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9,
    "9": 10, "0": 11, "MINUS": 12, "EQUAL": 13, "BACKSPACE": 14, "TAB": 15,
    "Q": 16, "W": 17, "E": 18, "R": 19, "T": 20, "Y": 21, "U": 22, "I": 23,
    "O": 24, "P": 25, "LEFTBRACE": 26, "RIGHTBRACE": 27, "ENTER": 28,
    "LEFTCTRL": 29, "A": 30, "S": 31, "D": 32, "F": 33, "G": 34, "H": 35,
    "J": 36, "K": 37, "L": 38, "SEMICOLON": 39, "APOSTROPHE": 40, "GRAVE": 41,
    "LEFTSHIFT": 42, "BACKSLASH": 43, "Z": 44, "X": 45, "C": 46, "V": 47,
    "B": 48, "N": 49, "M": 50, "COMMA": 51, "DOT": 52, "SLASH": 53,
    "RIGHTSHIFT": 54, "KPASTERISK": 55, "LEFTALT": 56, "SPACE": 57,
    "CAPSLOCK": 58, "F1": 59, "F2": 60, "F3": 61, "F4": 62, "F5": 63, "F6": 64,
    "F7": 65, "F8": 66, "F9": 67, "F10": 68, "NUMLOCK": 69, "SCROLLLOCK": 70,
    "KP7": 71, "KP8": 72, "KP9": 73, "KPMINUS": 74, "KP4": 75, "KP5": 76,
    "KP6": 77, "KPPLUS": 78, "KP1": 79, "KP2": 80, "KP3": 81, "KP0": 82,
    "KPDOT": 83, "F11": 87, "F12": 88, "KPENTER": 96, "RIGHTCTRL": 97,
    "KPSLASH": 98, "SYSRQ": 99, "RIGHTALT": 100, "HOME": 102, "UP": 103,
    "PAGEUP": 104, "LEFT": 105, "RIGHT": 106, "END": 107, "DOWN": 108,
    "PAGEDOWN": 109, "INSERT": 110, "DELETE": 111, "MUTE": 113,
    "VOLUMEDOWN": 114, "VOLUMEUP": 115, "POWER": 116, "KPEQUAL": 117,
    "PAUSE": 119, "LEFTMETA": 125, "RIGHTMETA": 126, "COMPOSE": 127,
    "STOP": 128, "AGAIN": 129, "UNDO": 131, "FRONT": 132, "COPY": 133,
    "OPEN": 134, "PASTE": 135, "FIND": 136, "CUT": 137, "HELP": 138,
    "MENU": 139, "SLEEP": 142, "MAIL": 155, "BOOKMARKS": 156, "BACK": 158,
    "FORWARD": 159, "NEXTSONG": 163, "PLAYPAUSE": 164, "PREVIOUSSONG": 165,
    "STOPCD": 166, "HOMEPAGE": 172, "REFRESH": 173, "F13": 183, "F14": 184,
    "F15": 185, "F16": 186, "F17": 187, "F18": 188, "F19": 189, "F20": 190,
    "F21": 191, "F22": 192, "F23": 193, "F24": 194, "SEARCH": 217,
    "BRIGHTNESSDOWN": 224, "BRIGHTNESSUP": 225,
}

BTN_LEFT, BTN_RIGHT, BTN_MIDDLE, BTN_SIDE, BTN_EXTRA = 0x110, 0x111, 0x112, 0x113, 0x114

# Печатные символы латиницы -> физическая клавиша раскладки US.
# Верхний и нижний регистр дают одну и ту же клавишу: Shift сервер шлёт
# отдельным событием, ровно как настоящая клавиатура.
_ASCII = {
    "`": "GRAVE", "~": "GRAVE", "-": "MINUS", "_": "MINUS", "=": "EQUAL",
    "+": "EQUAL", "[": "LEFTBRACE", "{": "LEFTBRACE", "]": "RIGHTBRACE",
    "}": "RIGHTBRACE", "\\": "BACKSLASH", "|": "BACKSLASH", ";": "SEMICOLON",
    ":": "SEMICOLON", "'": "APOSTROPHE", '"': "APOSTROPHE", ",": "COMMA",
    "<": "COMMA", ".": "DOT", ">": "DOT", "/": "SLASH", "?": "SLASH",
    " ": "SPACE", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
    "&": "7", "*": "8", "(": "9", ")": "0",
}

# Кириллица -> физическая клавиша раскладки ЙЦУКЕН.
_CYRILLIC = {
    "й": "Q", "ц": "W", "у": "E", "к": "R", "е": "T", "н": "Y", "г": "U",
    "ш": "I", "щ": "O", "з": "P", "х": "LEFTBRACE", "ъ": "RIGHTBRACE",
    "ф": "A", "ы": "S", "в": "D", "а": "F", "п": "G", "р": "H", "о": "J",
    "л": "K", "д": "L", "ж": "SEMICOLON", "э": "APOSTROPHE", "ё": "GRAVE",
    "я": "Z", "ч": "X", "с": "C", "м": "V", "и": "B", "т": "N", "ь": "M",
    "б": "COMMA", "ю": "DOT",
}

# Служебные клавиши протокола (KeyID из диапазона U+E000..U+EFFF)
_SPECIAL = {
    0xEF08: "BACKSPACE", 0xEF09: "TAB", 0xEF0D: "ENTER", 0xEF13: "PAUSE",
    0xEF14: "SCROLLLOCK", 0xEF15: "SYSRQ", 0xEF1B: "ESC", 0xEF20: "COMPOSE",
    0xEFFF: "DELETE", 0xEF50: "HOME", 0xEF51: "LEFT", 0xEF52: "UP",
    0xEF53: "RIGHT", 0xEF54: "DOWN", 0xEF55: "PAGEUP", 0xEF56: "PAGEDOWN",
    0xEF57: "END", 0xEF58: "HOME", 0xEF61: "SYSRQ", 0xEF63: "INSERT",
    0xEF65: "UNDO", 0xEF66: "AGAIN", 0xEF67: "MENU", 0xEF68: "FIND",
    0xEF69: "STOP", 0xEF6A: "HELP", 0xEF6B: "PAUSE", 0xEF7E: "RIGHTALT",
    0xEF7F: "NUMLOCK", 0xEF80: "SPACE", 0xEF89: "TAB", 0xEF8D: "KPENTER",
    0xEF95: "KP7", 0xEF96: "KP4", 0xEF97: "KP8", 0xEF98: "KP6", 0xEF99: "KP2",
    0xEF9A: "KP9", 0xEF9B: "KP3", 0xEF9C: "KP1", 0xEF9D: "KP5",
    0xEF9E: "KP0", 0xEF9F: "KPDOT", 0xEFBD: "KPEQUAL", 0xEFAA: "KPASTERISK",
    0xEFAB: "KPPLUS", 0xEFAC: "KPDOT", 0xEFAD: "KPMINUS", 0xEFAE: "KPDOT",
    0xEFAF: "KPSLASH", 0xEFB0: "KP0", 0xEFB1: "KP1", 0xEFB2: "KP2",
    0xEFB3: "KP3", 0xEFB4: "KP4", 0xEFB5: "KP5", 0xEFB6: "KP6",
    0xEFB7: "KP7", 0xEFB8: "KP8", 0xEFB9: "KP9",
    0xEFE1: "LEFTSHIFT", 0xEFE2: "RIGHTSHIFT", 0xEFE3: "LEFTCTRL",
    0xEFE4: "RIGHTCTRL", 0xEFE5: "CAPSLOCK", 0xEFE6: "CAPSLOCK",
    0xEFE7: "LEFTMETA", 0xEFE8: "RIGHTMETA", 0xEFE9: "LEFTALT",
    0xEFEA: "RIGHTALT", 0xEFEB: "LEFTMETA", 0xEFEC: "RIGHTMETA",
    0xEFED: "LEFTMETA", 0xEFEE: "RIGHTMETA", 0xEE20: "TAB",
    0xE001: "POWER", 0xE05F: "SLEEP", 0xE0A6: "BACK", 0xE0A7: "FORWARD",
    0xE0A8: "REFRESH", 0xE0A9: "STOP", 0xE0AA: "SEARCH", 0xE0AB: "BOOKMARKS",
    0xE0AC: "HOMEPAGE", 0xE0AD: "MUTE", 0xE0AE: "VOLUMEDOWN",
    0xE0AF: "VOLUMEUP", 0xE0B0: "NEXTSONG", 0xE0B1: "PREVIOUSSONG",
    0xE0B2: "STOPCD", 0xE0B3: "PLAYPAUSE", 0xE0B4: "MAIL",
    0xE0B8: "BRIGHTNESSDOWN", 0xE0B9: "BRIGHTNESSUP",
}


KEYMAP = {}
for _kid, _name in _SPECIAL.items():
    if _name in K:
        KEYMAP[_kid] = K[_name]
for _i in range(24):                       # F1..F24 идут подряд с 0xEFBE
    _n = "F%d" % (_i + 1)
    if _n in K:
        KEYMAP[0xEFBE + _i] = K[_n]
for _c in "abcdefghijklmnopqrstuvwxyz":     # буквы латиницы
    KEYMAP[ord(_c)] = K[_c.upper()]
    KEYMAP[ord(_c.upper())] = K[_c.upper()]
for _c in "0123456789":                     # цифры верхнего ряда
    KEYMAP[ord(_c)] = K[_c]
for _c, _n in _ASCII.items():
    KEYMAP[ord(_c)] = K[_n]
for _c, _n in _CYRILLIC.items():
    KEYMAP[ord(_c)] = K[_n]
    KEYMAP[ord(_c.upper())] = K[_n]

# Все коды, которые может выдать виртуальная клавиатура
KEYBOARD_CODES = sorted(set(K.values()))
MOUSE_BUTTONS = {1: BTN_LEFT, 2: BTN_MIDDLE, 3: BTN_RIGHT, 4: BTN_SIDE, 5: BTN_EXTRA}

# Маска модификаторов протокола -> удерживаемая клавиша. Замки (CapsLock 0x1000,
# NumLock 0x2000, ScrollLock 0x4000) сюда НЕ входят намеренно: они переключаются,
# а не удерживаются, и «досылка» замка сбила бы состояние на самом Deck'е.
MODIFIER_MASK = {
    0x0001: K["LEFTSHIFT"],
    0x0002: K["LEFTCTRL"],
    0x0004: K["LEFTALT"],
    0x0008: K["LEFTMETA"],
    0x0010: K["LEFTMETA"],
    0x0020: K["RIGHTALT"],
}


# --------------------------------------------------------------------------
# Слой 3. Разбор кадров протокола
# --------------------------------------------------------------------------


class Wire:
    """Чтение и запись сообщений: 4 байта длины, затем тело."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def feed(self, data):
        self.buf += data

    def messages(self):
        while len(self.buf) >= 4:
            size = struct.unpack(">I", self.buf[:4])[0]
            if size > 4 * 1024 * 1024:
                raise ValueError("сообщение длиной %d байт — обрыв протокола" % size)
            if len(self.buf) < 4 + size:
                return
            body, self.buf = self.buf[4:4 + size], self.buf[4 + size:]
            yield body

    def send(self, payload):
        self.sock.sendall(struct.pack(">I", len(payload)) + payload)


def i2(data, off):
    return struct.unpack_from(">h", data, off)[0]


def u2(data, off):
    return struct.unpack_from(">H", data, off)[0]


def i4(data, off):
    return struct.unpack_from(">i", data, off)[0]


# --------------------------------------------------------------------------
# Слой 4. Клиент
# --------------------------------------------------------------------------


def detect_screen():
    """Разрешение активного экрана — из DRM, без обращения к композитору."""
    best = None
    try:
        base = "/sys/class/drm"
        for entry in sorted(os.listdir(base)):
            status = os.path.join(base, entry, "status")
            modes = os.path.join(base, entry, "modes")
            if not (os.path.exists(status) and os.path.exists(modes)):
                continue
            with open(status) as fh:
                if fh.read().strip() != "connected":
                    continue
            with open(modes) as fh:
                first = fh.readline().strip()
            m = re.match(r"^(\d+)x(\d+)", first)
            if m:
                w, h = int(m.group(1)), int(m.group(2))
                if best is None or w * h > best[0] * best[1]:
                    best = (w, h)
    except OSError:
        pass
    return best or (1280, 800)


class DeckKVM:
    def __init__(self, hosts, port, name, log, pointer="abs"):
        if isinstance(hosts, str):
            hosts = [hosts]
        self.hosts = [h.strip() for h in hosts if h.strip()]
        self.host = self.hosts[0]
        self.port, self.name, self.log = port, name, log
        self.pointer = pointer
        self.width, self.height = detect_screen()
        self.kbd = VirtualDevice("Deck KVM Keyboard", keys=KEYBOARD_CODES)
        # Абсолютные оси нужны потому, что ускорение указателя применяется ТОЛЬКО
        # к относительному движению: положение, посчитанное в пикселях и посланное
        # смещением, приезжает не туда, и ошибка накапливается. Относительные оси
        # оставлены рядом — по ним приходит DMRM, когда курсор захвачен игрой.
        self.mouse = VirtualDevice(
            "Deck KVM Mouse",
            keys=sorted(MOUSE_BUTTONS.values()),
            rels=(REL_X, REL_Y, REL_WHEEL, REL_HWHEEL),
            abss=(ABS_X, ABS_Y) if pointer == "abs" else (),
        )
        self.pressed = {}       # KeyButton сервера -> код клавиши ядра
        self.buttons = set()
        self.mods = set()       # модификаторы, удерживаемые по маске сервера
        self.cursor = None      # модель положения курсора (только для режима rel)
        self.wheel_acc = [0, 0]

    # ---- работа с устройствами -------------------------------------------

    def key(self, code, value):
        self.kbd.emit(EV_KEY, code, value)
        self.kbd.sync()

    def button(self, code, down):
        self.mouse.emit(EV_KEY, code, KEY_DOWN if down else KEY_UP)
        self.mouse.sync()
        (self.buttons.add if down else self.buttons.discard)(code)

    def move_rel(self, dx, dy):
        if dx:
            self.mouse.emit(EV_REL, REL_X, dx)
        if dy:
            self.mouse.emit(EV_REL, REL_Y, dy)
        if dx or dy:
            self.mouse.sync()
            if self.cursor is not None:
                self.cursor = (self.cursor[0] + dx, self.cursor[1] + dy)

    def move_abs(self, x, y):
        """Положение экрана в условных единицах абсолютных осей."""
        if self.pointer != "abs":
            return self._move_abs_through_rel(x, y)
        self.mouse.emit(EV_ABS, ABS_X, self._scale(x, self.width))
        self.mouse.emit(EV_ABS, ABS_Y, self._scale(y, self.height))
        self.mouse.sync()
        self.cursor = (x, y)

    @staticmethod
    def _scale(value, size):
        span = max(1, size - 1)
        return max(0, min(ABS_MAX, value * ABS_MAX // span))

    def _move_abs_through_rel(self, x, y):
        """Запасной путь, когда абсолютные оси отключены настройкой."""
        if self.cursor is None:
            self.recalibrate()
        dx, dy = x - self.cursor[0], y - self.cursor[1]
        while dx or dy:                     # ядро не примет больше 32767 за раз
            sx = max(-30000, min(30000, dx))
            sy = max(-30000, min(30000, dy))
            dx -= sx
            dy -= sy
            self.move_rel(sx, sy)
        self.cursor = (x, y)

    def recalibrate(self):
        """Прижать курсор к левому верхнему углу и считать его нулём."""
        self.cursor = None
        for _ in range(3):
            self.move_rel(-30000, -30000)
        self.cursor = (0, 0)

    def sync_modifiers(self, mask):
        """Привести удерживаемые модификаторы к состоянию, названному сервером.

        Клавиша, зажатая на ноутбуке ДО перехода на экран Deck'а, отдельным
        событием нажатия сюда не придёт — она есть только в этой маске.
        """
        want = {code for bit, code in MODIFIER_MASK.items() if mask & bit}
        for code in self.mods - want:
            self.key(code, KEY_UP)
        for code in want - self.mods:
            self.key(code, KEY_DOWN)
        self.mods = want

    def release_all(self):
        for code in list(self.pressed.values()):
            self.key(code, KEY_UP)
        self.pressed.clear()
        for code in self.mods:
            self.key(code, KEY_UP)
        self.mods = set()
        for code in list(self.buttons):
            self.button(code, False)

    # ---- разбор сообщений -------------------------------------------------

    def handle(self, wire, msg):
        code = msg[:4]

        if code == b"CALV":
            wire.send(b"CALV")
        elif code == b"CNOP":
            pass
        elif code == b"QINF":
            self.width, self.height = detect_screen()
            wire.send(
                b"DINF" + struct.pack(
                    ">hhhhhhh", 0, 0, self.width, self.height, 0,
                    self.width // 2, self.height // 2,
                )
            )
        elif code == b"CIAK":
            pass
        elif code == b"CINN":
            x, y = i2(msg, 4), i2(msg, 6)
            mask = u2(msg, 12) if len(msg) >= 14 else 0
            if self.pointer != "abs":
                self.recalibrate()
            self.move_abs(x, y)
            self.sync_modifiers(mask)
            self.log("экран Deck активен, курсор здесь")
        elif code == b"COUT":
            self.release_all()
            self.log("управление вернулось на ноутбук")
        elif code == b"DMMV":
            self.move_abs(i2(msg, 4), i2(msg, 6))
        elif code == b"DMRM":
            self.move_rel(i2(msg, 4), i2(msg, 6))
        elif code == b"DMDN":
            btn = MOUSE_BUTTONS.get(msg[4])
            if btn:
                self.button(btn, True)
        elif code == b"DMUP":
            btn = MOUSE_BUTTONS.get(msg[4])
            if btn:
                self.button(btn, False)
        elif code == b"DMWM":
            self.wheel(i2(msg, 4), i2(msg, 6))
        elif code in (b"DKDN", b"DKRP", b"DKUP", b"DKDL"):
            self.handle_key(code, msg)
        elif code in (b"DSOP", b"CROP", b"CSEC", b"CCLP", b"DCLP", b"LSYN",
                      b"SECN", b"DDRG", b"DFTR"):
            pass  # буфер обмена и передача файлов не поддерживаются
        elif code == b"CBYE":
            raise ConnectionResetError("сервер закрыл сессию")
        elif code in (b"EBSY", b"EUNK", b"EBAD", b"EICV"):
            raise ConnectionResetError("сервер отверг клиента: %s" % code.decode())

    def wheel(self, dx, dy):
        """Щелчок колеса — 120 условных единиц; остаток копится до следующего.

        Деление берётся С ОКРУГЛЕНИЕМ К НУЛЮ, а не divmod: тот округляет
        к минус бесконечности, и любое отрицательное значение меньше щелчка
        выдавало бы полный щелчок вниз сразу, а такое же положительное — ничего.
        """
        for axis, delta, rel in ((0, dy, REL_WHEEL), (1, dx, REL_HWHEEL)):
            self.wheel_acc[axis] += delta
            notches = int(self.wheel_acc[axis] / 120)
            if notches:
                self.wheel_acc[axis] -= notches * 120
                self.mouse.emit(EV_REL, rel, notches)
                self.mouse.sync()

    def handle_key(self, code, msg):
        key_id = u2(msg, 4)
        button = u2(msg, 8) if len(msg) >= 10 else 0
        if code == b"DKUP":
            target = self.pressed.pop(button, None) or KEYMAP.get(key_id)
            if target:
                self.key(target, KEY_UP)
            return
        if code == b"DKRP":
            repeats = u2(msg, 8)
            button = u2(msg, 10) if len(msg) >= 12 else button
            target = self.pressed.get(button) or KEYMAP.get(key_id)
            if target is None:
                return
            if button not in self.pressed:  # повтор пришёл без нажатия
                self.pressed[button] = target
                self.key(target, KEY_DOWN)
            for _ in range(max(1, repeats)):
                self.key(target, KEY_REPEAT)
            return
        target = KEYMAP.get(key_id)
        if target is None:
            return
        self.pressed[button] = target
        self.key(target, KEY_DOWN)

    # ---- сессия -----------------------------------------------------------

    def session(self):
        sock = socket.create_connection((self.host, self.port), timeout=10)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        wire = Wire(sock)
        self.log("подключён к %s:%d" % (self.host, self.port))

        hello = None
        sel = selectors.DefaultSelector()
        sel.register(sock, selectors.EVENT_READ)
        last_seen = time.monotonic()
        try:
            while True:
                if not sel.select(timeout=1.0):
                    if time.monotonic() - last_seen > 12:
                        raise ConnectionResetError("сервер молчит 12 секунд")
                    continue
                data = sock.recv(65536)
                if not data:
                    raise ConnectionResetError("соединение закрыто")
                last_seen = time.monotonic()
                wire.feed(data)
                for msg in wire.messages():
                    if hello is None:
                        hello = msg[:7]
                        wire.send(
                            hello + struct.pack(">hh", 1, 6)
                            + struct.pack(">I", len(self.name))
                            + self.name.encode("utf-8")
                        )
                        self.log(
                            "рукопожатие: %s, экран назван «%s», %dx%d"
                            % (hello.decode("ascii", "replace"), self.name,
                               self.width, self.height)
                        )
                        continue
                    self.handle(wire, msg)
        finally:
            sel.close()
            self.release_all()
            sock.close()

    # Сессия, продержавшаяся дольше этого, считается удачной: адрес верный,
    # и разгонять задержку повторов заново незачем.
    УДАЧНАЯ_СЕССИЯ = 30

    def run(self):
        delay = 1
        index = 0
        while True:
            self.host = self.hosts[index % len(self.hosts)]
            started = time.monotonic()
            try:
                self.session()
            except KeyboardInterrupt:
                raise
            except Exception as err:  # обрыв сети — не повод умирать
                # session() выходит только исключением, поэтому сброс задержки
                # живёт ЗДЕСЬ: строка после вызова была бы недостижимой.
                if time.monotonic() - started >= self.УДАЧНАЯ_СЕССИЯ:
                    delay = 1               # адрес рабочий, его и держим
                else:
                    index += 1              # пробуем следующий из списка
                self.log("нет связи с %s (%s), повтор через %d с"
                         % (self.host, err, delay))
                time.sleep(delay)
                delay = min(delay * 2, 15)

    def close(self):
        self.release_all()
        self.kbd.close()
        self.mouse.close()


# --------------------------------------------------------------------------


def read_config(path):
    cfg = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip().lower()] = v.strip()
    except OSError:
        pass
    return cfg


def main():
    cfg = read_config(os.environ.get("DECK_KVM_CONFIG", "/etc/deck-kvm.conf"))
    host = os.environ.get("DECK_KVM_SERVER") or cfg.get("server")
    port = int(os.environ.get("DECK_KVM_PORT") or cfg.get("port", 24800))
    name = os.environ.get("DECK_KVM_NAME") or cfg.get("name", "steamdeck")
    pointer = (os.environ.get("DECK_KVM_POINTER") or cfg.get("pointer", "abs")).lower()
    if pointer not in ("abs", "rel"):
        pointer = "abs"
    if len(sys.argv) > 1:
        host = sys.argv[1]
    if not host:
        print("не задан адрес ноутбука: укажите его в /etc/deck-kvm.conf "
              "строкой server=192.168.0.14", file=sys.stderr)
        return 2
    hosts = [h for h in host.split(",") if h.strip()]

    def log(text):
        print("[deck-kvm] %s" % text, flush=True)

    if not os.path.exists("/dev/uinput"):
        os.system("modprobe uinput >/dev/null 2>&1")
    if not os.access("/dev/uinput", os.W_OK):
        print("нет доступа к /dev/uinput — служба должна работать от root",
              file=sys.stderr)
        return 3

    kvm = DeckKVM(hosts, port, name, log, pointer=pointer)
    log("экран %dx%d, указатель %s, ждём ноутбук %s"
        % (kvm.width, kvm.height,
           "абсолютный" if pointer == "abs" else "относительный",
           ", ".join(hosts)))
    try:
        kvm.run()
    except KeyboardInterrupt:
        pass
    finally:
        kvm.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
