# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Commander сеанса Steam Deck с компьютером по протоколу Barrier/Synergy
"""
deck_client_commander.py

Держит связь с сервером Deskflow на компьютере и раздаёт работу: кадры читает солдат протокола,
перевод во ввод делает офицер, режим сеанса и экран отслеживает датчик, знакомство ведёт солдат
сети. Сам командир решает только порядок: куда подключаться, когда разорвать связь, когда
сменить способ движения курсора.

Alt+Tab в игровом режиме возвращает управление на компьютер: окон там нет, и сочетание
свободно. Deck не может приказать серверу сменить экран — он просит об этом приложение на
компьютере, а оно нажимает служебную клавишу сервера; связь при этом не рвётся. На рабочем
столе Alt+Tab доходит до окон Deck'а, среди них окно «Компьютер» — его выбор и есть возврат.

Два правила защиты живут здесь, потому что оба решают, БЫТЬ ли сеансу.

1. **Погас экран Deck'а — связь снимается.** Пока клиент подключён, сервер уводит курсор на его
   экран, как только мышь дошла до края. Если экран Deck'а погас, человек видит, что клавиатура
   и мышь «пропали» с компьютера. Разрыв связи возвращает курсор на компьютер сразу, а сервер
   перестаёт пускать его на Deck, пока экран снова не загорится.
2. **Незнакомый или выключенный компьютер не долбится.** Слышим маячок своего ПК с пометкой
   «выключен» — ждём, а не стучимся раз в секунду.

Сервер со своей стороны отсекает замолчавший клиент через девять секунд (Deskflow,
`kKeepAliveRate` 3 с × `kKeepAlivesUntilDeath` 3). Уснувший Deck поэтому уходит из сеанса сам;
погасший экран при живой связи — нет, и его ловит правило 1.
"""

from __future__ import annotations

import collections
import queue
import selectors
import socket
import struct
import threading
import time

from core import config_policy
from core.dto.client_status_dto import (
    CONNECTED, CONNECTING, DISPLAY_OFF, PC_OFF, WAITING_PC, ClientStatusDTO,
)
from core.officers.input_translation_officer import (
    KEYBOARD_CODES, MOUSE_BUTTONS, POINTER_ABS, POINTER_REL, InputTranslationOfficer, scan_to_key,
)
from core.officers.intelligence.deck_session_sensor import DESKTOP, DeckSessionSensor
from core.soldiers.barrier_wire_soldier import BarrierWireSoldier, i2, u2
from core.soldiers.virtual_device_soldier import ABS_X, ABS_Y, REL_HWHEEL, REL_WHEEL, REL_X, REL_Y

POINTER_AUTO = "auto"


class SessionEnded(Exception):
    """Сеанс закончен намеренно — не обрыв сети, повтор без разгона задержки."""


class DeckClientCommander:
    # Сессия, продержавшаяся дольше этого, считается удачной: адрес верный,
    # и разгонять задержку повторов заново незачем.
    STABLE_SESSION_SECONDS = 30
    MODE_CHECK_SECONDS = 2.0
    DISPLAY_CHECK_SECONDS = 1.0
    # Экран гаснет и тут же загорается при смене режима и подключении дока; разрыв по одному
    # замеру рвал бы связь на каждом таком мигании.
    DISPLAY_OFF_CONFIRMATIONS = 2
    SERVER_SILENCE_SECONDS = 12
    # Захват курсора игрой проверяется часто: меню Steam открыли — курсор должен сразу стать
    # свободным, иначе человек упрётся в край, которого на экране уже нет.
    CAPTURE_CHECK_SECONDS = 0.25
    # Пока игра держит курсор, серверу объявлен большой экран, а курсор сервера возвращается
    # в его центр, не доходя до края: край — это переход на компьютер и упор камеры.
    VIRTUAL_SIZE = 16000
    RECENTER_AT = 3000

    def __init__(self, hosts, port, name, log, pointer=POINTER_AUTO, discovery=None,
                 sensor=None, device_factory=None, layouts=None):
        if isinstance(hosts, str):
            hosts = [hosts]
        self.hosts = [host.strip() for host in hosts if host and host.strip()]
        self.discovery = discovery
        self.host = self.hosts[0] if self.hosts else None
        self.port, self.name = port, name
        self._log = log
        self.pointer_setting = pointer
        self.sensor = sensor or DeckSessionSensor()
        width, height = self.sensor.screen_size()
        if device_factory is None:
            from core.soldiers.virtual_device_soldier import VirtualDeviceSoldier
            device_factory = VirtualDeviceSoldier
        self.kbd = device_factory("SteamDeck-KVM Keyboard", keys=KEYBOARD_CODES)
        # Абсолютные оси объявлены всегда, кроме явного выбора смещений: способ движения
        # выбирается по режиму на ходу, и устройство обязано уметь оба.
        self.mouse = device_factory(
            "SteamDeck-KVM Mouse",
            keys=sorted(MOUSE_BUTTONS.values()),
            rels=(REL_X, REL_Y, REL_WHEEL, REL_HWHEEL),
            abss=() if pointer == POINTER_REL else (ABS_X, ABS_Y),
        )
        self.mode = self.sensor.session_mode()
        self.officer = InputTranslationOfficer(self.kbd, self.mouse, width, height, pointer=self._choose_pointer())
        self.lines = collections.deque(maxlen=200)
        self.actions = queue.Queue()
        self.lock = threading.Lock()
        self.status = ClientStatusDTO(version=config_policy.app_version(), mode=self.mode,
                                      pointer=self.officer.pointer)
        self._display_off_count = 0
        self._keys_logged = False
        self.layouts = layouts
        self._languages_applied = None
        self._next_mode_check = 0.0
        self._next_display_check = 0.0
        self._next_capture_check = 0.0
        self.captured = False
        self._wire = None
        self._server_pos = None
        self._awaiting_centre = False
        self._announced_virtual = False
        self._stale_until_inside = False
        self._swallowed = set()          # скан-коды проглоченных клавиш: их отпускание тоже не уходит

    # ---- журнал и состояние ---------------------------------------------------

    def log(self, text):
        line = "%s  %s" % (time.strftime("%H:%M:%S"), text)
        with self.lock:
            self.lines.append(line)
        self._log(text)

    def set_status(self, **fields):
        with self.lock:
            for key, value in fields.items():
                setattr(self.status, key, value)

    def snapshot(self) -> dict:
        with self.lock:
            data = self.status.to_dict()
            data["log"] = list(self.lines)[-40:]
        if self.discovery:
            data["alt_tab"] = self.discovery.flags.get("alttab", True)
            data["paired"] = bool(self.discovery.peer)
            data["pc_name"] = data["pc_name"] or self.discovery.peer_name
            data["pc_address"] = data["pc_address"] or self.discovery.address or self.discovery.recall()
        return data

    # ---- выбор способа движения -----------------------------------------------

    @property
    def width(self):
        return self.officer.width

    @property
    def height(self):
        return self.officer.height

    def _choose_pointer(self):
        if self.pointer_setting in (POINTER_ABS, POINTER_REL):
            return self.pointer_setting
        # На рабочем столе — абсолютная ось: KWin ускоряет смещения, и курсор уплывал бы.
        # Везде ещё — смещения: игровой режим понимает только их, и берёт без ускорения.
        return POINTER_ABS if self.mode == DESKTOP else POINTER_REL

    def watch_session(self, now=None):
        """Сверить режим сеанса и экран. Вызывается из цикла сеанса и цикла ожидания."""
        now = time.monotonic() if now is None else now
        if now >= self._next_mode_check:
            self._next_mode_check = now + self.MODE_CHECK_SECONDS
            mode = self.sensor.session_mode()
            if mode != self.mode:
                self.log("режим сеанса: %s → %s" % (self.mode, mode))
                self.mode = mode
            if self.officer.set_pointer(self._choose_pointer()):
                self.log("курсор теперь ведётся %s" % (
                    "абсолютной осью" if self.officer.pointer == POINTER_ABS else "смещениями"))
            self.set_status(mode=self.mode, pointer=self.officer.pointer)
            self._follow_pc_languages()
        if now >= self._next_display_check:
            self._next_display_check = now + self.DISPLAY_CHECK_SECONDS
            on = self.sensor.display_on()
            self._display_off_count = 0 if on else self._display_off_count + 1
            self.set_status(display_on=on)
        if now >= self._next_capture_check:
            self._next_capture_check = now + self.CAPTURE_CHECK_SECONDS
            self._watch_capture()
        return self._display_off_count < self.DISPLAY_OFF_CONFIRMATIONS

    # ---- захват курсора игрой -------------------------------------------------

    def _watch_capture(self):
        """Игра спрятала курсор — захват; показала (меню Steam, меню игры) — отпустить.

        Ответ датчика «не знаю» (сбой X11) состояния не меняет: отпускание посреди игры бросило
        бы камеру, а ложный захват на рабочем столе исключён проверкой режима.
        """
        if self.mode == DESKTOP or self.officer.pointer != POINTER_REL:
            want = False
        else:
            answer = getattr(self.sensor, "cursor_captured", lambda: None)()
            if answer is None:
                return
            want = bool(answer)
        if want == self.captured:
            return
        self.captured = want
        self.set_status(captured=want)
        self.log("игра %s курсор — %s" % (
            "захватила" if want else "отпустила",
            "мышь крутит камеру без упора в край, на компьютер курсор не уходит (выход — Alt+Tab или кнопка)"
            if want else "курсор свободен, край экрана снова ведёт на компьютер"))
        if self._wire is None:
            return
        if want:
            self._announce_shape()
        else:
            # Курсор остаётся там, где был: модель положения велась и в захвате. Спрятанный
            # бездействием курсор игра не двигала, и прыжок в центр был бы лишним.
            cursor = self.officer.cursor
            if cursor is None:
                self.officer.recalibrate()
                cursor = (self.width // 2, self.height // 2)
                self.officer.move_abs(*cursor)
            self._announce_shape(cursor)
            self._stale_until_inside = True

    def _shape(self, cursor=None):
        if self.captured:
            size = self.VIRTUAL_SIZE
            return size, size, size // 2, size // 2
        mx, my = cursor if cursor is not None else (self.width // 2, self.height // 2)
        return self.width, self.height, mx, my

    def _announce_shape(self, cursor=None):
        """Сообщить серверу форму экрана и где курсор. Deskflow принимает её в любой момент
        сеанса (`ClientProxy1_0::parseMessage`, DINF → `handleShapeChanged`) и ставит свой
        курсор туда, куда сказал клиент; кадры, посланные до этого, ещё идут от старой точки."""
        width, height, mx, my = self._shape(cursor)
        self._wire.send(b"DINF" + struct.pack(">hhhhhhh", 0, 0, width, height, 0, mx, my))
        self._announced_virtual = self.captured
        if self.captured:
            self._awaiting_centre = True

    def _captured_move(self, x, y):
        """Положение от сервера в захвате — только разница с прошлым, сырым смещением.

        После объявления нового центра кадры сервера ещё какое-то время идут от старой точки.
        Переход на новый центр виден по самому кадру: он близко к центру, а старые — дальше
        порога. До перехода новый центр не объявляется повторно: лишний DINF сбил бы отсчёт.
        """
        centre = self.VIRTUAL_SIZE // 2
        near = abs(x - centre) < self.RECENTER_AT // 2 and abs(y - centre) < self.RECENTER_AT // 2
        if self._awaiting_centre and near:
            self._awaiting_centre = False
            base = (centre, centre)
        else:
            base = self._server_pos or (x, y)
        dx, dy = x - base[0], y - base[1]
        self._server_pos = (x, y)
        if abs(dx) < self.RECENTER_AT and abs(dy) < self.RECENTER_AT:
            self.officer.move_rel_raw(dx, dy)
        far = abs(x - centre) > self.RECENTER_AT or abs(y - centre) > self.RECENTER_AT
        if far and not self._awaiting_centre:
            self._announce_shape()

    def _follow_pc_languages(self):
        """Раскладки Deck'а — по языкам компьютера: клавиши приходят физическими."""
        languages = self.discovery.languages if self.discovery else None
        if not languages or languages == self._languages_applied:
            return
        self._languages_applied = languages
        if self.layouts is None:
            from core.soldiers.keyboard.keyboard_layout_soldier import KeyboardLayoutSoldier
            self.layouts = KeyboardLayoutSoldier()
        try:
            changed = self.layouts.apply(languages)
        except OSError as error:
            self.log("раскладки не записаны: %s" % error)
            return
        if "desktop" in changed:
            self.log("раскладки рабочего стола — как на компьютере (%s), переключение Alt+Shift" % languages)
        if "game" in changed:
            self.log("раскладки игрового режима — как на компьютере (%s); вступят после перезапуска игрового режима"
                     % languages)

    # ---- действия из окна ------------------------------------------------------

    def request(self, name):
        """Принять действие из окна. Выполняется в потоке службы, а не в потоке запроса."""
        if name == "forget" and not self.discovery:
            return False, "поиск по сети выключен — забывать нечего"
        if name == "to_pc" and self.status.state != CONNECTED:
            return False, "компьютер не подключён"
        self.actions.put(name)
        return True, "принято"

    def run_actions(self, in_session=False):
        while True:
            try:
                name = self.actions.get_nowait()
            except queue.Empty:
                return
            if name == "to_pc":
                self.return_to_pc("окно Deck'а")
            if name == "forget" and self.discovery:
                self.discovery.forget()
                self.set_status(pc_name=None, pc_address=None, paired=False)
                self.log("компьютер забыт — следующий откликнувшийся в сети станет знакомым")
                if in_session:
                    raise SessionEnded("компьютер забыт")

    def return_to_pc(self, source):
        """Попросить компьютер вернуть клавиатуру и мышь. Связь не рвётся."""
        if self.discovery and self.discovery.send_to_pc():
            self.log("возврат на компьютер: %s" % source)
        else:
            self.log("возврат на компьютер (%s) не ушёл: маячка компьютера нет дольше 15 секунд" % source)

    def _alt_tab_returns(self):
        """Alt+Tab возвращает на компьютер только в игровом режиме и если это не выключено на ПК."""
        flags = self.discovery.flags if self.discovery else {}
        return self.mode != DESKTOP and flags.get("alttab", True)

    # ---- разбор сообщений -----------------------------------------------------

    def handle(self, wire, msg):
        code = msg[:4]
        officer = self.officer

        if code == b"CALV":
            wire.send(b"CALV")
        elif code in (b"CNOP", b"CIAK"):
            pass
        elif code == b"QINF":
            width, height = self.sensor.screen_size()
            officer.set_screen(width, height)
            self._wire = wire
            self._announce_shape()
        elif code == b"CINN":
            mask = u2(msg, 12) if len(msg) >= 14 else 0
            x, y = i2(msg, 4), i2(msg, 6)
            if self._announced_virtual:
                # Сервер считал экран большим: точка входа — в его масштабе, переводится в настоящий.
                x = x * self.width // self.VIRTUAL_SIZE
                y = y * self.height // self.VIRTUAL_SIZE
            self._wire = wire
            officer.enter(x, y, mask)
            if self.captured:
                # Сервер ставит курсор у края, откуда пришёл: его курсор уводится в центр большого
                # экрана, иначе первое же движение назад вернуло бы управление на компьютер.
                self._server_pos = None
                self._announce_shape()
            elif self._announced_virtual:
                self._announce_shape((x, y))
            self.set_status(on_screen=True, held_keys=officer.held_keys())
            self.log("экран Deck'а активен, курсор здесь")
        elif code == b"COUT":
            officer.leave()
            self.set_status(on_screen=False, held_keys=[])
            self.log("управление вернулось на компьютер")
        elif code == b"DMMV":
            x, y = i2(msg, 4), i2(msg, 6)
            if self.captured:
                self._captured_move(x, y)
            elif self._stale_until_inside and not (0 <= x < self.width and 0 <= y < self.height):
                pass            # кадр в масштабе большого экрана, посланный до отпускания
            else:
                self._stale_until_inside = False
                officer.move_abs(x, y)
        elif code == b"DMRM":
            if self.captured:
                officer.move_rel_raw(i2(msg, 4), i2(msg, 6))
            else:
                officer.move_rel(i2(msg, 4), i2(msg, 6))
        elif code in (b"DMDN", b"DMUP"):
            button = MOUSE_BUTTONS.get(msg[4])
            if button:
                officer.button(button, code == b"DMDN")
        elif code == b"DMWM":
            officer.wheel(i2(msg, 4), i2(msg, 6))
        elif code in (b"DKDN", b"DKRP", b"DKUP", b"DKDL"):
            if code == b"DKDN" and not self._keys_logged and len(msg) >= 10:
                self._keys_logged = True
                physical = scan_to_key(u2(msg, 8)) is not None
                self.log("клавиши приходят %s" % ("физическими — язык выбирает раскладка Deck'а, Alt+Shift"
                                                  if physical else "символами — сервер не прислал скан-код"))
            if code == b"DKRP":
                button = u2(msg, 10) if len(msg) >= 12 else 0     # у повтора скан-код за числом повторов
            else:
                button = u2(msg, 8) if len(msg) >= 10 else 0
            if code == b"DKDN" and self._is_alt_tab(msg) and self._alt_tab_returns():
                self._swallowed.add(button)
                self.return_to_pc("Alt+Tab в игре")
                return
            if code in (b"DKUP", b"DKRP") and button in self._swallowed:
                if code == b"DKUP":
                    self._swallowed.discard(button)
                return
            officer.handle_key(code, msg)
            self.set_status(held_keys=officer.held_keys())
        elif code in (b"DSOP", b"CROP", b"CSEC", b"CCLP", b"DCLP", b"LSYN", b"SECN", b"DDRG", b"DFTR"):
            pass  # буфер обмена и передача файлов не поддерживаются
        elif code == b"CBYE":
            raise ConnectionResetError("сервер закрыл сессию")
        elif code in (b"EBSY", b"EUNK", b"EBAD", b"EICV"):
            raise ConnectionResetError("сервер отверг клиента: %s" % code.decode())

    @staticmethod
    def _is_alt_tab(msg):
        """Tab при зажатом Alt: по скан-коду Tab (0x0F), без него — по символу Tab."""
        if len(msg) < 8:
            return False
        key_id, mask = u2(msg, 4), u2(msg, 6)
        button = u2(msg, 8) if len(msg) >= 10 else 0
        is_tab = (button & 0xFF) == 0x0F if button else key_id in (0xEF09, 0xEE20)
        return is_tab and bool(mask & 0x0004)

    # ---- сеанс ------------------------------------------------------------------

    def session(self):
        self.set_status(state=CONNECTING, last_error=None)
        sock = socket.create_connection((self.host, self.port), timeout=10)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        wire = BarrierWireSoldier(sock)
        self.log("подключён к %s:%d" % (self.host, self.port))

        hello = None
        self._keys_logged = False
        sel = selectors.DefaultSelector()
        sel.register(sock, selectors.EVENT_READ)
        last_seen = time.monotonic()
        try:
            while True:
                # Отвечать на маячок надо и во время сеанса: иначе окно на ПК через пятнадцать
                # секунд напишет, что Deck пропал.
                if self.discovery:
                    self.discovery.poll()
                self.run_actions(in_session=True)
                if not self.watch_session():
                    raise SessionEnded("экран Deck'а погас — связь снята, курсор вернулся на компьютер")
                if not sel.select(timeout=0.5):
                    if time.monotonic() - last_seen > self.SERVER_SILENCE_SECONDS:
                        raise ConnectionResetError("сервер молчит %d секунд" % self.SERVER_SILENCE_SECONDS)
                    continue
                data = sock.recv(65536)
                if not data:
                    raise ConnectionResetError("соединение закрыто")
                last_seen = time.monotonic()
                wire.feed(data)
                for msg in wire.messages():
                    if hello is None:
                        hello = msg[:7]
                        wire.send(hello + struct.pack(">hh", 1, 6)
                                  + struct.pack(">I", len(self.name)) + self.name.encode("utf-8"))
                        self.set_status(state=CONNECTED, pc_address=self.host)
                        self.log("рукопожатие: %s, экран «%s», %dx%d, курсор %s"
                                 % (hello.decode("ascii", "replace"), self.name, self.width, self.height,
                                    "абсолютной осью" if self.officer.pointer == POINTER_ABS else "смещениями"))
                        continue
                    self.handle(wire, msg)
        finally:
            sel.close()
            self._wire = None
            self._server_pos = None
            self._awaiting_centre = False
            self._announced_virtual = False
            self._stale_until_inside = False
            self.officer.leave()
            self.set_status(on_screen=False, held_keys=[])
            sock.close()

    def pick_host(self, index):
        """Куда стучаться сейчас. Живая рассылка старше и настройки, и памяти."""
        if self.discovery:
            self.discovery.poll()
            fresh = time.monotonic() - self.discovery.seen < 15
            if self.discovery.address and fresh:
                self.set_status(pc_name=self.discovery.peer_name, pc_address=self.discovery.address)
                if not self.discovery.server_on:
                    self.set_status(state=PC_OFF)
                    return None          # компьютер рядом, но сервер выключен — не долбимся
                self.port = self.discovery.port
                return self.discovery.address
        if self.hosts:
            return self.hosts[index % len(self.hosts)]
        if self.discovery:
            return self.discovery.recall()
        return None

    def _wait(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.run_actions()
            self.watch_session()
            if self.discovery:
                self.discovery.wait(min(0.5, max(0.0, deadline - time.monotonic())))
            else:
                time.sleep(min(0.5, max(0.0, deadline - time.monotonic())))

    def run(self):
        delay = 1
        index = 0
        while True:
            self.run_actions()
            if not self.watch_session():
                self.set_status(state=DISPLAY_OFF)
                self._wait(1)
                continue
            target = self.pick_host(index)
            if target is None:
                if self.status.state != PC_OFF:
                    self.set_status(state=WAITING_PC)
                self._wait(3)
                continue
            self.host = target
            started = time.monotonic()
            try:
                self.session()
            except KeyboardInterrupt:
                raise
            except SessionEnded as reason:
                self.log(str(reason))
                delay = 1
                continue
            except Exception as error:  # обрыв сети — не повод умирать
                # session() выходит только исключением, поэтому сброс задержки живёт ЗДЕСЬ:
                # строка после вызова была бы недостижимой.
                if time.monotonic() - started >= self.STABLE_SESSION_SECONDS:
                    delay = 1               # адрес рабочий, его и держим
                else:
                    index += 1              # пробуем следующий из списка
                self.set_status(state=WAITING_PC, last_error=str(error))
                self.log("нет связи с %s (%s), повтор через %d с" % (self.host, error, delay))
                self._wait(delay)
                delay = min(delay * 2, 15)

    def close(self):
        self.officer.release_all()
        self.kbd.close()
        self.mouse.close()
