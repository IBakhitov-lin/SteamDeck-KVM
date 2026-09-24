# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки командира сеанса: разговор с сервером, повторы, защита погасшего экрана
"""
test_deck_client_protocol.py

Слои: поведение и контракт протокола — функциональная глубина; рукопожатие с настоящим
deskflow-core — стык, идёт только если сервер установлен на машине.
"""

from __future__ import annotations

import os
import shutil
import socket
import struct
import threading
import time

import pytest

from conftest import FakeDevice, FakeSensor
from core.commanders import deck_client_commander as commander_module
from core.commanders.deck_client_commander import DeckClientCommander, SessionEnded
from core.dto.client_status_dto import CONNECTED, DISPLAY_OFF
from core.officers.input_translation_officer import KEYMAP, K, POINTER_ABS, POINTER_REL
from core.soldiers.virtual_device_soldier import (
    ABS_MAX, ABS_X, ABS_Y, BTN_LEFT, EV_ABS, EV_KEY, EV_REL, REL_WHEEL, REL_X,
)


def frame(payload):
    return struct.pack(">I", len(payload)) + payload


def recv_msg(sock):
    head = b""
    while len(head) < 4:
        chunk = sock.recv(4 - len(head))
        if not chunk:
            raise ConnectionError("нет данных")
        head += chunk
    size = struct.unpack(">I", head)[0]
    body = b""
    while len(body) < size:
        body += sock.recv(size - len(body))
    return body


def make(port=1, sensor=None, pointer="auto", hosts="127.0.0.1"):
    return DeckClientCommander(hosts, port, "steamdeck", lambda text: None, pointer=pointer,
                               sensor=sensor or FakeSensor(), device_factory=FakeDevice)


def test_conversation_with_fake_server():
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    seen = {}

    def server():
        conn, _ = listener.accept()
        conn.sendall(frame(b"Barrier" + struct.pack(">hh", 1, 6)))
        seen["helloback"] = recv_msg(conn)
        conn.sendall(frame(b"QINF"))
        seen["dinf"] = recv_msg(conn)
        conn.sendall(frame(b"CIAK"))
        conn.sendall(frame(b"CALV"))
        seen["calv"] = recv_msg(conn)
        conn.sendall(frame(b"CINN" + struct.pack(">hhih", 100, 50, 1, 0x0001)))
        conn.sendall(frame(b"DMMV" + struct.pack(">hh", 640, 400)))
        conn.sendall(frame(b"DMDN" + bytes([1])))
        conn.sendall(frame(b"DMUP" + bytes([1])))
        conn.sendall(frame(b"DMWM" + struct.pack(">hh", 0, 120)))
        conn.sendall(frame(b"DKDN" + struct.pack(">HHH", ord("a"), 0x0001, 30)))
        conn.sendall(frame(b"DKUP" + struct.pack(">HHH", ord("A"), 0x0001, 30)))
        conn.sendall(frame(b"DKDN" + struct.pack(">HHH", 0xEF53, 0, 0x14D)))  # → со скан-кодом Windows
        conn.sendall(frame(b"DKUP" + struct.pack(">HHH", 0xEF53, 0, 0x14D)))
        conn.sendall(frame(b"DMRM" + struct.pack(">hh", -5, 7)))
        time.sleep(0.4)
        conn.sendall(frame(b"COUT"))
        time.sleep(0.3)
        conn.sendall(frame(b"CBYE"))
        time.sleep(0.2)
        conn.close()

    thread = threading.Thread(target=server, daemon=True)
    thread.start()
    client = make(port=port)
    with pytest.raises(ConnectionResetError):
        client.session()
    thread.join(timeout=5)

    hello = seen["helloback"]
    assert hello[:7] == b"Barrier", "HelloBack повторяет имя протокола сервера"
    assert hello[7:11] == struct.pack(">hh", 1, 6), "HelloBack объявляет версию 1.6"
    assert hello[11:] == struct.pack(">I", 9) + b"steamdeck", "HelloBack несёт имя экрана"
    assert seen["dinf"][:4] == b"DINF"
    assert struct.unpack(">hhhhhhh", seen["dinf"][4:]) == (0, 0, 1280, 800, 0, 640, 400)
    assert seen["calv"] == b"CALV"

    mouse, keyboard = client.mouse.events, client.kbd.events
    assert any(event[0] == EV_ABS and event[1] == ABS_X for event in mouse), \
        "на рабочем столе положение идёт абсолютной осью"
    assert (EV_KEY, BTN_LEFT, 1) in mouse and (EV_KEY, BTN_LEFT, 0) in mouse
    assert (EV_REL, REL_WHEEL, 1) in mouse, "колесо даёт один щелчок на 120"
    assert (EV_REL, REL_X, -5) in mouse, "относительное движение проходит как есть"
    assert (EV_KEY, K["A"], 1) in keyboard and (EV_KEY, K["A"], 0) in keyboard
    assert KEYMAP[ord("ф")] == K["A"] and KEYMAP[ord("й")] == K["Q"], "кириллица на позициях ЙЦУКЕН"
    assert (EV_KEY, K["RIGHT"], 1) in keyboard
    assert client.officer.pressed == {} and client.officer.mods == set(), \
        "после COUT ни одна клавиша не осталась зажатой"
    key_lines = [line for line in client.lines if "клавиши приходят" in line]
    assert len(key_lines) == 1 and "физическими" in key_lines[0], "способ передачи клавиш назван один раз за сеанс"


def test_game_mode_moves_cursor_by_offsets_desktop_by_axis():
    """Регрессия: в игровом режиме абсолютная ось не двигала курсор вовсе (gamescope её не слушает)."""
    game = make(sensor=FakeSensor(mode="game"))
    assert game.officer.pointer == POINTER_REL
    assert game.mouse.abss == (ABS_X, ABS_Y), "оси объявлены: режим может смениться на ходу"
    game.handle(None, b"CINN" + struct.pack(">hhih", 100, 50, 1, 0))
    game.handle(None, b"DMMV" + struct.pack(">hh", 110, 60))
    assert not [e for e in game.mouse.events if e[0] == EV_ABS], "в игровом режиме абсолютной оси нет"
    assert (EV_REL, REL_X, 10) in game.mouse.events, "шаг курсора — смещение на разницу положений"

    desktop = make(sensor=FakeSensor(mode="desktop"))
    assert desktop.officer.pointer == POINTER_ABS
    desktop.handle(None, b"DMMV" + struct.pack(">hh", 1279, 0))
    assert (EV_ABS, ABS_X, ABS_MAX) in desktop.mouse.events


def test_mode_switch_on_the_fly_changes_pointer():
    sensor = FakeSensor(mode="desktop")
    client = make(sensor=sensor)
    sensor.mode = "game"
    client.watch_session(now=10_000)
    assert client.officer.pointer == POINTER_REL
    assert client.snapshot()["mode"] == "game"


def test_forced_pointer_setting_wins_over_mode():
    assert make(sensor=FakeSensor(mode="game"), pointer="abs").officer.pointer == POINTER_ABS
    forced_rel = make(sensor=FakeSensor(mode="desktop"), pointer="rel")
    assert forced_rel.officer.pointer == POINTER_REL and forced_rel.mouse.abss == ()


def test_display_off_ends_session_after_confirmation():
    sensor = FakeSensor(display=False)
    client = make(sensor=sensor)
    assert client.watch_session(now=1) is True, "одно мигание экрана связь не рвёт"
    assert client.watch_session(now=3) is False, "подтверждённо погасший экран снимает связь"
    sensor.display = True
    assert client.watch_session(now=5) is True, "экран загорелся — связь снова разрешена"


def test_run_does_not_connect_while_display_off(monkeypatch):
    client = make(sensor=FakeSensor(display=False))
    client.watch_session(now=1)
    client.watch_session(now=3)          # погасший экран подтверждён двумя замерами
    calls = {"sessions": 0, "waits": 0}
    monkeypatch.setattr(client, "session", lambda: calls.__setitem__("sessions", calls["sessions"] + 1))

    def fake_wait(_seconds):
        calls["waits"] += 1
        client._next_display_check = 0
        if calls["waits"] > 4:
            raise KeyboardInterrupt

    monkeypatch.setattr(client, "_wait", fake_wait)
    with pytest.raises(KeyboardInterrupt):
        client.run()
    assert calls["sessions"] == 0, "к серверу не подключаемся, пока экран Deck'а погас"
    assert client.status.state == DISPLAY_OFF


def test_retry_delay_doubles_and_is_capped(monkeypatch):
    client = make()
    delays, attempts = [], {"n": 0}

    def failing_session():
        attempts["n"] += 1
        if attempts["n"] > 6:
            raise KeyboardInterrupt
        raise OSError("нет сети")

    monkeypatch.setattr(client, "session", failing_session)
    monkeypatch.setattr(client, "_wait", lambda seconds: delays.append(seconds))
    with pytest.raises(KeyboardInterrupt):
        client.run()
    assert delays[:4] == [1, 2, 4, 8]
    assert max(delays) <= 15


def test_stable_session_keeps_same_address(monkeypatch):
    client = make(hosts=["первый", "второй"])
    starts, attempts = [], {"n": 0}

    def long_session():
        attempts["n"] += 1
        starts.append(client.host)
        if attempts["n"] > 2:
            raise KeyboardInterrupt
        time.sleep(0.02)
        raise OSError("разрыв после долгой работы")

    monkeypatch.setattr(client, "session", long_session)
    monkeypatch.setattr(client, "_wait", lambda seconds: None)
    client.STABLE_SESSION_SECONDS = 0.01
    with pytest.raises(KeyboardInterrupt):
        client.run()
    assert starts[:2] == ["первый", "первый"]


def test_forget_action_ends_session():
    class Discovery:
        peer, peer_name, address, seen, server_on, port = "pc", "ПК", "10.0.0.2", 0.0, True, 24800
        forgotten = False

        def forget(self):
            Discovery.forgotten = True

        def poll(self):
            pass

        @staticmethod
        def recall():
            return None

    client = DeckClientCommander([], 1, "steamdeck", lambda text: None, sensor=FakeSensor(),
                                 device_factory=FakeDevice, discovery=Discovery())
    assert client.request("forget") == (True, "принято")
    with pytest.raises(SessionEnded):
        client.run_actions(in_session=True)
    assert Discovery.forgotten


@pytest.mark.skipif(not os.path.exists(r"C:\Program Files\Deskflow\deskflow-core.exe")
                    and not shutil.which("deskflow-core"),
                    reason="на машине нет deskflow-core — стык с настоящим сервером проверить не на чем")
def test_handshake_with_real_deskflow(tmp_path):
    import subprocess

    port = 24890
    screens = tmp_path / "screens.conf"
    screens.write_text("section: screens\n\tpc:\n\tsteamdeck:\nend\nsection: links\n\tpc:\n\t\tright = steamdeck\n"
                       "\tsteamdeck:\n\t\tleft = pc\nend\n", encoding="utf-8")
    settings = tmp_path / "server.conf"
    settings.write_text("[core]\ncoreMode=server\ncomputerName=pc\nport=%d\n[security]\ntlsEnabled=false\n"
                        "[server]\nexternalConfig=true\nexternalConfigFile=%s\n" % (port, screens.as_posix()),
                        encoding="utf-8")
    exe = r"C:\Program Files\Deskflow\deskflow-core.exe"
    server = subprocess.Popen([exe, "server", "--new-instance", "-s", str(settings)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    try:
        time.sleep(3)
        client = make(port=port)
        seen = []
        original = client.handle
        client.handle = lambda wire, msg: (seen.append(msg[:4]), original(wire, msg))
        thread = threading.Thread(target=lambda: _swallow(client.session), daemon=True)
        thread.start()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and b"CALV" not in seen:
            time.sleep(0.2)
        assert b"QINF" in seen, "сервер запросил сведения об экране"
        assert client.status.state == CONNECTED, "рукопожатие принято"
    finally:
        server.kill()


def _swallow(function):
    try:
        function()
    except Exception:
        pass


def test_deck_layouts_follow_pc_languages_once():
    class Discovery:
        peer, peer_name, address, seen, server_on, port = "pc", "ПК", "10.0.0.2", 0.0, True, 24800
        languages = "en-US,ru-RU"

        def poll(self):
            pass

    class Layouts:
        calls = []

        def apply(self, languages):
            Layouts.calls.append(languages)
            return ["game", "desktop"]

    client = DeckClientCommander([], 1, "steamdeck", lambda text: None, sensor=FakeSensor(),
                                 device_factory=FakeDevice, discovery=Discovery(), layouts=Layouts())
    client.watch_session(now=100.0)
    client.watch_session(now=200.0)
    assert Layouts.calls == ["en-US,ru-RU"], "одни и те же языки применяются один раз"
    assert any("Alt+Shift" in line for line in client.lines)
    assert any("после перезапуска игрового режима" in line for line in client.lines)


# ---- захват курсора игрой и Alt+Tab ---------------------------------------------------------

class FakeWire:
    def __init__(self):
        self.sent = []

    def send(self, payload):
        self.sent.append(payload)

    def shapes(self):
        return [struct.unpack(">hhhhhhh", p[4:]) for p in self.sent if p[:4] == b"DINF"]


def rel_moves(device):
    return [(code, value) for etype, *rest in device.events if etype == EV_REL
            for code, value in [rest] if code in (0, 1)]


def captured_client():
    sensor = FakeSensor(mode="game", captured=False)
    client = make(sensor=sensor)
    wire = FakeWire()
    client.handle(wire, b"QINF")
    client.handle(wire, b"CINN" + struct.pack(">hhih", 0, 400, 1, 0))
    sensor.captured = True
    client._next_capture_check = 0
    client.watch_session(now=10.0)
    return client, sensor, wire


def test_game_capture_announces_big_screen_centred():
    client, _, wire = captured_client()
    assert client.captured and client.status.captured
    size, centre = client.VIRTUAL_SIZE, client.VIRTUAL_SIZE // 2
    assert wire.shapes()[-1] == (0, 0, size, size, 0, centre, centre)


def test_captured_moves_go_raw_without_edge_and_recentre():
    client, _, wire = captured_client()
    centre = client.VIRTUAL_SIZE // 2
    client.mouse.events.clear()
    # Далеко вправо: реальный экран кончился бы на 1280, игра получает все смещения.
    x = centre
    shapes = len(wire.shapes())
    for _ in range(40):
        x += 100
        client.handle(wire, b"DMMV" + struct.pack(">hh", x, centre))
        if len(wire.shapes()) > shapes:        # сервер принял новый центр и ведёт курсор от него
            shapes, x = len(wire.shapes()), centre
    moved = sum(value for code, value in rel_moves(client.mouse) if code == 0)
    assert moved == 4000, moved
    # Курсор сервера ушёл от центра дальше порога — центр объявлен заново, края сервер не увидит.
    assert wire.shapes()[-1][5:] == (centre, centre)


def test_frames_around_recentre_give_true_motion_and_one_announce():
    client, _, wire = captured_client()
    centre = client.VIRTUAL_SIZE // 2
    client.handle(wire, b"DMMV" + struct.pack(">hh", centre + 5, centre))     # сервер перешёл на центр
    far = centre + client.RECENTER_AT + 10
    client.handle(wire, b"DMMV" + struct.pack(">hh", far, centre))            # быстрый рывок → новый центр
    announced = len(wire.shapes())
    client.mouse.events.clear()
    # Сервер ещё не принял новый центр: кадры от старой точки — настоящее движение, DINF не повторяется.
    client.handle(wire, b"DMMV" + struct.pack(">hh", far + 20, centre))
    client.handle(wire, b"DMMV" + struct.pack(">hh", far + 40, centre))
    # Сервер принял новый центр: кадр рядом с центром — смещение от центра, а не откат назад.
    client.handle(wire, b"DMMV" + struct.pack(">hh", centre + 15, centre))
    assert [v for c, v in rel_moves(client.mouse) if c == 0] == [20, 20, 15]
    assert len(wire.shapes()) == announced


def test_unknown_answer_keeps_capture_without_camera_jerk():
    client, sensor, wire = captured_client()
    client.mouse.events.clear()
    sensor.captured = None                                   # сбой чтения X11
    client._next_capture_check = 0
    client.watch_session(now=20.0)
    assert client.captured and rel_moves(client.mouse) == []


def test_release_keeps_cursor_in_place_and_drops_stale_frames():
    client, sensor, wire = captured_client()
    client.handle(wire, b"DMMV" + struct.pack(">hh", client.VIRTUAL_SIZE // 2 + 5, client.VIRTUAL_SIZE // 2))
    client.handle(wire, b"DMMV" + struct.pack(">hh", client.VIRTUAL_SIZE // 2 + 105, client.VIRTUAL_SIZE // 2))
    place = client.officer.cursor
    sensor.captured = False
    client._next_capture_check = 0
    client.watch_session(now=20.0)
    assert not client.captured
    assert wire.shapes()[-1] == (0, 0, 1280, 800, 0) + place
    client.handle(wire, b"DMMV" + struct.pack(">hh", 8050, 8010))           # кадр до отпускания
    assert client.officer.cursor == place
    client.handle(wire, b"DMMV" + struct.pack(">hh", 100, 100))
    assert client.officer.cursor == (100, 100)


def test_release_while_on_pc_tells_server_real_screen():
    client, sensor, wire = captured_client()
    client.handle(wire, b"COUT")
    sensor.captured = False
    client._next_capture_check = 0
    client.watch_session(now=20.0)
    assert wire.shapes()[-1][:4] == (0, 0, 1280, 800)
    client.handle(wire, b"CINN" + struct.pack(">hhih", 0, 300, 1, 0))
    assert client.officer.cursor == (0, 300)


def test_desktop_never_captures():
    client = make(sensor=FakeSensor(mode="desktop", captured=True))
    client._next_capture_check = 0
    client.watch_session(now=1.0)
    assert not client.captured


def test_entering_while_captured_goes_straight_to_centre():
    client, _, wire = captured_client()
    client.handle(wire, b"COUT")
    wire.sent.clear()
    client.handle(wire, b"CINN" + struct.pack(">hhih", 0, 400, 1, 0))
    centre = client.VIRTUAL_SIZE // 2
    assert wire.shapes() == [(0, 0, client.VIRTUAL_SIZE, client.VIRTUAL_SIZE, 0, centre, centre)]


class FakeDiscoveryToPc:
    """Знакомство без сети: считает просьбы «верни управление» и несёт флаги компьютера."""

    def __init__(self, alttab=True):
        self.flags = {"alttab": alttab}
        self.asked = 0
        self.peer = self.peer_name = self.address = None
        self.languages = None

    def send_to_pc(self):
        self.asked += 1
        return True

    def recall(self):
        return None


def alt_tab(client, wire):
    client.handle(wire, b"CINN" + struct.pack(">hhih", 0, 400, 1, 0x0004))
    client.handle(wire, b"DKDN" + struct.pack(">HHH", 0xEF09, 0x0004, 0x0F))


def test_alt_tab_in_game_asks_pc_to_take_control_back_without_dropping_session():
    """В игре окон нет: Alt+Tab — просьба компьютеру вернуть управление; Tab в игру не уходит."""
    client = make(sensor=FakeSensor(mode="game"))
    client.discovery = FakeDiscoveryToPc()
    wire = FakeWire()
    alt_tab(client, wire)
    assert client.discovery.asked == 1
    assert K["TAB"] not in client.officer.pressed.values()
    client.handle(wire, b"DKUP" + struct.pack(">HHH", 0xEF09, 0x0004, 0x0F))
    assert not client._swallowed, "отпускание проглоченного Tab тоже проглочено и забыто"


def test_alt_tab_on_desktop_reaches_deck_windows():
    """На рабочем столе Alt+Tab — клавиши для окон Deck'а; среди них окно «Компьютер»."""
    client = make(sensor=FakeSensor(mode="desktop"))
    client.discovery = FakeDiscoveryToPc()
    alt_tab(client, FakeWire())
    assert K["TAB"] in client.officer.pressed.values() and client.discovery.asked == 0


def test_alt_tab_switched_off_on_pc_reaches_the_game():
    client = make(sensor=FakeSensor(mode="game"))
    client.discovery = FakeDiscoveryToPc(alttab=False)
    alt_tab(client, FakeWire())
    assert K["TAB"] in client.officer.pressed.values() and client.discovery.asked == 0


def test_window_button_to_pc_needs_connection():
    client = make()
    client.discovery = FakeDiscoveryToPc()
    ok, _ = client.request("to_pc")
    assert not ok and client.discovery.asked == 0
    client.set_status(state="connected")
    ok, _ = client.request("to_pc")
    client.run_actions()
    assert ok and client.discovery.asked == 1
