# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Sensor состояния Steam Deck: экран, его питание и режим сеанса
"""
deck_session_sensor.py

Пассивный наблюдатель: ничего не меняет, только отвечает на четыре вопроса.

1. **Какое разрешение у экрана** — из DRM ядра, без обращения к композитору
2. **Горит ли экран** — погасший экран при живой связи означает, что курсор уйдёт в чёрный
   прямоугольник и клавиатура с мышью пропадут с компьютера. Ответ «не знаю» считается
   «горит»: датчик, который ошибся в сторону «погас», разорвал бы рабочую связь
3. **Какой режим сеанса** — от него зависит, как двигать мышь
4. **Захватила ли игра курсор** — спрятанный курсор в игре значит, что мышь крутит камеру: курсор
   не должен упираться в край и уходить на компьютер (`cursor_captured`)

Почему режим решает способ движения мыши. Композитор игрового режима gamescope подписан
ТОЛЬКО на относительное движение указателя (`wlserver.cpp`, `wlserver_new_input`: слушается
`events.motion`, а `motion_absolute` — нет) и берёт из него НЕУСКОРЕННЫЕ смещения
(`wlserver_handle_pointer_motion` → `unaccel_dx`). Значит в игровом режиме абсолютные оси не
двигают курсор вовсе, зато относительные доходят один в один. Композитор рабочего стола KWin,
наоборот, ускоряет относительные смещения, и точное положение там даёт только абсолютная ось.

Корни `/sys` и `/proc` и подключение к X11 передаются параметрами: проверки подставляют поддельные.
"""

from __future__ import annotations

import os
import re
import time
from pathlib import Path

from core.soldiers.x11_property_soldier import X11PropertySoldier

GAME = "game"
DESKTOP = "desktop"
UNKNOWN = "unknown"

_DESKTOP_COMPOSITORS = {"kwin_wayland", "kwin_x11", "kwin"}
_GAME_COMPOSITORS = {"gamescope", "gamescope-wl"}
STEAM_APP_ID = 769          # номер самого клиента Steam в GAMESCOPE_FOCUSED_APP
ENV_CACHE_SECONDS = 10.0    # окружение Steam меняется только с перезапуском игрового режима
X11_RETRY_SECONDS = 5.0     # сервер X11 не ответил — не спрашивать его, пока не пройдёт пауза


class DeckSessionSensor:
    def __init__(self, sys_root: str = "/sys", proc_root: str = "/proc", x11_factory=None):
        self.sys_root = Path(sys_root)
        self.proc_root = Path(proc_root)
        self._x11_factory = x11_factory or (lambda display, auth: X11PropertySoldier(display, auth))
        self._x11 = {}
        self._env = ({}, -1e9)
        self._retry_at = 0.0
        self._clock = time.monotonic

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
                # Встроенная панель Deck'а стоит боком: ядро называет её 800x1280, а оба
                # композитора показывают 1280x800. Вертикальный размер ушёл бы серверу, и курсор
                # не доставал бы до правой трети экрана, а по вертикали сползал бы с модели.
                if "eDP" in connector.name and width < height:
                    width, height = height, width
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

    # ---- захват курсора игрой ------------------------------------------------

    def _x11_env(self):
        """DISPLAY и XAUTHORITY из окружения процесса Steam или gamescope — служба их не наследует.

        Обход /proc дорог для проверки четыре раза в секунду, поэтому найденное держится
        ENV_CACHE_SECONDS; пустой ответ не держится — игровой режим мог только что подняться.
        """
        env, when = self._env
        if env and self._clock() - when < ENV_CACHE_SECONDS:
            return env
        env = self._scan_env()
        self._env = (env, self._clock())
        return env

    def _scan_env(self):
        try:
            pids = os.listdir(self.proc_root)
        except OSError:
            return {}
        for pid in pids:
            if not pid.isdigit():
                continue
            try:
                name = (self.proc_root / pid / "comm").read_text().strip()
                if name not in ("steam", "gamescope", "gamescope-wl"):
                    continue
                raw = (self.proc_root / pid / "environ").read_bytes()
            except OSError:
                continue
            env = dict(item.split(b"=", 1) for item in raw.split(b"\0") if b"=" in item)
            found = {key: env[key.encode()].decode("utf-8", "replace")
                     for key in ("DISPLAY", "XAUTHORITY") if key.encode() in env}
            if found.get("DISPLAY"):
                return found
        return {}

    def _open(self, display, auth):
        if display not in self._x11:
            self._x11[display] = self._x11_factory(display, auth)
        return self._x11[display]

    def _drop(self, display):
        conn = self._x11.pop(display, None)
        if conn is not None:
            conn.close()
        # Сбой: поток службы ведёт и ввод, поэтому следующая попытка — только после паузы,
        # а окружение ищется заново — сервер мог смениться с перезапуском игрового режима.
        self._retry_at = self._clock() + X11_RETRY_SECONDS
        self._env = ({}, -1e9)

    def cursor_captured(self):
        """Спрятала ли игра курсор: True, False или None — ответить нечем.

        Ответ берётся у самого композитора игрового режима. gamescope пишет на корневое окно
        своего первого сервера Xwayland: `GAMESCOPE_FOCUSED_APP` — номер приложения в фокусе
        (769 — сам Steam), `GAMESCOPE_MOUSE_FOCUS_DISPLAY` — сервер, где сейчас мышь; а на
        корневое окно того сервера — `GAMESCOPE_CURSOR_VISIBLE_FEEDBACK`, 0 или 1
        (`steamcompmgr.cpp`, `MouseCursor::updateCursorFeedback`: курсор скрыт, если у игры
        пустая картинка курсора или он спрятан бездействием). Курсор «захвачен» — в фокусе не
        Steam и курсор не виден: это игра от третьего лица, где мышь крутит камеру. Меню Steam
        (Shift+Tab, кнопка Steam) и меню игры с курсором дают «не захвачен».
        """
        if self._clock() < self._retry_at:
            return None
        env = self._x11_env()
        display = env.get("DISPLAY", "")
        match = re.match(r"^:(\d+)", display)
        if not match:
            return None
        auth = env.get("XAUTHORITY")
        root_display = int(match.group(1))
        try:
            root = self._open(root_display, auth)
            focus_display = root.text("GAMESCOPE_FOCUS_DISPLAY")
            app = root.cardinal("GAMESCOPE_FOCUSED_APP")
            mouse = root.text("GAMESCOPE_MOUSE_FOCUS_DISPLAY") or focus_display or display
        except (OSError, ValueError, IndexError):
            self._drop(root_display)
            return None
        if focus_display is None and app is None:
            return None                      # это не сервер gamescope — сказать нечего
        if not app or app == STEAM_APP_ID:
            return False
        match = re.match(r"^:(\d+)", mouse)
        target = int(match.group(1)) if match else root_display
        try:
            visible = self._open(target, auth).cardinal("GAMESCOPE_CURSOR_VISIBLE_FEEDBACK")
        except (OSError, ValueError, IndexError):
            self._drop(target)
            return None
        if visible is None:
            return None
        return visible == 0

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
