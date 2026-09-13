# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Sensor состояния Steam Deck: экран, его питание и режим сеанса
"""
deck_session_sensor.py

Пассивный наблюдатель: ничего не меняет, только отвечает на три вопроса.

1. **Какое разрешение у экрана** — из DRM ядра, без обращения к композитору
2. **Горит ли экран** — погасший экран при живой связи означает, что курсор уйдёт в чёрный
   прямоугольник и клавиатура с мышью пропадут с компьютера. Ответ «не знаю» считается
   «горит»: датчик, который ошибся в сторону «погас», разорвал бы рабочую связь
3. **Какой режим сеанса** — от него зависит, как двигать мышь

Почему режим решает способ движения мыши. Композитор игрового режима gamescope подписан
ТОЛЬКО на относительное движение указателя (`wlserver.cpp`, `wlserver_new_input`: слушается
`events.motion`, а `motion_absolute` — нет) и берёт из него НЕУСКОРЕННЫЕ смещения
(`wlserver_handle_pointer_motion` → `unaccel_dx`). Значит в игровом режиме абсолютные оси не
двигают курсор вовсе, зато относительные доходят один в один. Композитор рабочего стола KWin,
наоборот, ускоряет относительные смещения, и точное положение там даёт только абсолютная ось.

Корни `/sys` и `/proc` передаются параметрами: проверки подставляют поддельное дерево.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

GAME = "game"
DESKTOP = "desktop"
UNKNOWN = "unknown"

_DESKTOP_COMPOSITORS = {"kwin_wayland", "kwin_x11", "kwin"}
_GAME_COMPOSITORS = {"gamescope", "gamescope-wl"}


class DeckSessionSensor:
    def __init__(self, sys_root: str = "/sys", proc_root: str = "/proc"):
        self.sys_root = Path(sys_root)
        self.proc_root = Path(proc_root)

    def _connectors(self):
        base = self.sys_root / "class" / "drm"
        try:
            entries = sorted(os.listdir(base))
        except OSError:
            return []
        found = []
        for entry in entries:
            status = base / entry / "status"
            if not status.is_file():
                continue
            try:
                if status.read_text().strip() != "connected":
                    continue
            except OSError:
                continue
            found.append(base / entry)
        return found

    def screen_size(self):
        best = None
        for connector in self._connectors():
            try:
                first = (connector / "modes").read_text().splitlines()[0].strip()
            except (OSError, IndexError):
                continue
            match = re.match(r"^(\d+)x(\d+)", first)
            if match:
                width, height = int(match.group(1)), int(match.group(2))
                if best is None or width * height > best[0] * best[1]:
                    best = (width, height)
        return best or (1280, 800)

    def display_on(self) -> bool:
        """Горит ли хоть один подключённый экран. Нечем ответить — считается «горит»."""
        answers = []
        for connector in self._connectors():
            try:
                answers.append((connector / "dpms").read_text().strip().lower() == "on")
            except OSError:
                continue
        if answers:
            return any(answers)
        return True

    def session_mode(self) -> str:
        """Игровой режим, рабочий стол или неизвестно — по именам процессов композитора.

        Рабочий стол проверяется ПЕРВЫМ: игра, запущенная из рабочего стола с обёрткой
        gamescope, поднимает его процесс внутри KWin, и курсором там по-прежнему правит KWin.
        """
        names = set()
        try:
            pids = os.listdir(self.proc_root)
        except OSError:
            return UNKNOWN
        for pid in pids:
            if not pid.isdigit():
                continue
            try:
                names.add((self.proc_root / pid / "comm").read_text().strip())
            except OSError:
                continue
        if names & _DESKTOP_COMPOSITORS:
            return DESKTOP
        if names & _GAME_COMPOSITORS:
            return GAME
        return UNKNOWN
