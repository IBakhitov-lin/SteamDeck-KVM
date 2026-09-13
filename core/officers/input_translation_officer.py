# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Officer перевода сообщений протокола в нажатия и движения виртуальных устройств
"""
input_translation_officer.py

Решает, во что превращается сообщение сервера: какая клавиша ядра соответствует символу, каким
способом двигать курсор в текущем режиме, какие модификаторы должны быть зажаты прямо сейчас.

Два решения здесь выведены из замеров, а не из вкуса.

1. **Способ движения курсора зависит от режима сеанса.** В игровом режиме композитор слушает
   только относительное движение и не ускоряет его — курсор ведётся смещениями. На рабочем
   столе композитор ускоряет смещения, и точное положение даёт только абсолютная ось. Разбор —
   `deck_session_sensor.py`. До этого клиент всегда слал абсолютную ось, и в игровом режиме
   курсора не было вовсе.
2. **Модификаторы сверяются с сервером на КАЖДОМ нажатии, а не только при входе на экран.**
   Сервер присылает с нажатием маску модификаторов, которые у него зажаты. Если отпускание
   модификатора потерялось — например, комбинацию перехвата сервер забрал себе целиком, —
   на Deck'е он остаётся нажатым, и каждая следующая буква в игре приходит как `Win+буква`.
   Сверка по маске отпускает такой модификатор на первом же нажатии.
"""

from __future__ import annotations

from core.soldiers.barrier_wire_soldier import u2
from core.soldiers.virtual_device_soldier import (
    ABS_MAX, ABS_X, ABS_Y, BTN_EXTRA, BTN_LEFT, BTN_MIDDLE, BTN_RIGHT, BTN_SIDE,
    EV_ABS, EV_KEY, EV_REL, KEY_DOWN, KEY_REPEAT, KEY_UP, REL_HWHEEL, REL_WHEEL, REL_X, REL_Y,
)

POINTER_ABS = "abs"
POINTER_REL = "rel"

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


# Семьи модификаторов: бит маски протокола → все клавиши ядра, которыми этот модификатор
# может быть зажат. Маска говорит «Shift зажат», но не говорит, левый или правый.
MODIFIER_FAMILIES = {
    0x0001: {K["LEFTSHIFT"], K["RIGHTSHIFT"]},
    0x0002: {K["LEFTCTRL"], K["RIGHTCTRL"]},
    0x0004: {K["LEFTALT"]},
    0x0008: {K["LEFTMETA"], K["RIGHTMETA"]},
    0x0010: {K["LEFTMETA"], K["RIGHTMETA"]},
    0x0020: {K["RIGHTALT"]},
}
MODIFIER_CODES = set().union(*MODIFIER_FAMILIES.values())

# Столько смещений ядро принимает за одно событие; больше режется по частям.
_REL_STEP = 30000


class InputTranslationOfficer:
    def __init__(self, keyboard, mouse, width, height, pointer=POINTER_ABS):
        self.kbd = keyboard
        self.mouse = mouse
        self.width, self.height = width, height
        self.pointer = pointer
        self.pressed = {}       # KeyButton сервера -> код клавиши ядра
        self.buttons = set()
        self.mods = set()       # модификаторы, зажатые по маске сервера
        self.cursor = None      # модель положения курсора (для смещений)
        self.target = None      # последнее положение, названное сервером
        self.wheel_acc = [0, 0]
        self.on_screen = False

    # ---- настройка -----------------------------------------------------------

    def set_screen(self, width, height):
        self.width, self.height = width, height

    def set_pointer(self, pointer) -> bool:
        """Сменить способ движения курсора. Возвращает, изменился ли он.

        Модель положения при смене сбрасывается: абсолютная ось и смещения ведут разные
        курсоры разных композиторов, и старая модель новому не соответствует. Если курсор
        сейчас на экране Deck'а, он переставляется на последнее положение от сервера.
        """
        if pointer == self.pointer:
            return False
        self.pointer = pointer
        self.cursor = None
        if self.on_screen and self.target is not None:
            if pointer == POINTER_REL:
                self.recalibrate()
            self.move_abs(*self.target)
        return True

    # ---- устройства ----------------------------------------------------------

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
                # Композитор не пускает курсор за край экрана, и модель обязана делать то же:
                # иначе после упора в край она уезжает, а настоящий курсор стоит.
                x = max(0, min(self.width - 1, self.cursor[0] + dx))
                y = max(0, min(self.height - 1, self.cursor[1] + dy))
                self.cursor = (x, y)

    def move_abs(self, x, y):
        """Поставить курсор в точку экрана Deck'а — способом, подходящим режиму."""
        self.target = (x, y)
        if self.pointer != POINTER_ABS:
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
        if self.cursor is None:
            self.recalibrate()
        dx, dy = x - self.cursor[0], y - self.cursor[1]
        while dx or dy:
            sx = max(-_REL_STEP, min(_REL_STEP, dx))
            sy = max(-_REL_STEP, min(_REL_STEP, dy))
            dx -= sx
            dy -= sy
            self.move_rel(sx, sy)
        self.cursor = (x, y)

    def recalibrate(self):
        """Прижать курсор к левому верхнему углу и считать его нулём.

        Композитор упирает курсор в угол сам, поэтому после прижатия модель и настоящий
        курсор совпадают точно — без чтения положения, которого клиенту никто не отдаёт.
        """
        self.cursor = None
        for _ in range(3):
            self.move_rel(-_REL_STEP, -_REL_STEP)
        self.cursor = (0, 0)

    # ---- модификаторы --------------------------------------------------------

    def sync_modifiers(self, mask):
        """Привести зажатые модификаторы к маске сервера.

        Модификатор бывает зажат двумя путями: маской (клавиша зажата на ПК ДО перехода на
        экран Deck'а — отдельного нажатия не придёт) и обычным нажатием. Сверяются оба:
        модификатор, которого нет в маске, отпускается, как бы он ни был зажат.
        """
        held = set(self.pressed.values())
        want = set()
        for bit, family in MODIFIER_FAMILIES.items():
            if not mask & bit:
                continue
            if family & held:
                continue                       # уже зажат обычным нажатием
            want.add(min(family))              # левый вариант семьи
        wanted_families = set().union(*(f for b, f in MODIFIER_FAMILIES.items() if mask & b))

        for button, code in list(self.pressed.items()):
            if code in MODIFIER_CODES and code not in wanted_families:
                self.key(code, KEY_UP)
                del self.pressed[button]
        for code in self.mods - want:
            if code not in set(self.pressed.values()):
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

    # ---- экран ----------------------------------------------------------------

    def enter(self, x, y, mask):
        self.on_screen = True
        if self.pointer != POINTER_ABS:
            self.recalibrate()
        self.move_abs(x, y)
        self.sync_modifiers(mask)

    def leave(self):
        self.on_screen = False
        self.release_all()

    # ---- колесо и клавиши -----------------------------------------------------

    def wheel(self, dx, dy):
        """Щелчок колеса — 120 условных единиц; остаток копится до следующего.

        Деление берётся С ОКРУГЛЕНИЕМ К НУЛЮ, а не divmod: тот округляет к минус
        бесконечности, и любое отрицательное значение меньше щелчка выдавало бы полный
        щелчок вниз сразу, а такое же положительное — ничего.
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
        mask = u2(msg, 6) if len(msg) >= 8 else None
        if code == b"DKUP":
            button = u2(msg, 8) if len(msg) >= 10 else 0
            target = self.pressed.pop(button, None) or KEYMAP.get(key_id)
            if target:
                self.key(target, KEY_UP)
            return
        if code == b"DKRP":
            repeats = u2(msg, 8) if len(msg) >= 10 else 1
            button = u2(msg, 10) if len(msg) >= 12 else 0
            target = self.pressed.get(button) or KEYMAP.get(key_id)
            if target is None:
                return
            if button not in self.pressed:     # повтор пришёл без нажатия
                self._sync_before(target, mask)
                self.pressed[button] = target
                self.key(target, KEY_DOWN)
            for _ in range(max(1, repeats)):
                self.key(target, KEY_REPEAT)
            return
        button = u2(msg, 8) if len(msg) >= 10 else 0
        target = KEYMAP.get(key_id)
        if target is None:
            return
        self._sync_before(target, mask)
        self.pressed[button] = target
        self.key(target, KEY_DOWN)

    def _sync_before(self, target, mask):
        """Сверить модификаторы перед обычной клавишей. Перед самим модификатором — нет:
        маска при его нажатии описывает состояние ДО него, и сверка отпустила бы его же."""
        if mask is None or target in MODIFIER_CODES:
            return
        self.sync_modifiers(mask)

    def held_keys(self):
        """Что сейчас зажато — для окна состояния и журнала."""
        names = {code: name for name, code in K.items()}
        codes = set(self.pressed.values()) | self.mods
        return sorted(names.get(code, str(code)) for code in codes)
