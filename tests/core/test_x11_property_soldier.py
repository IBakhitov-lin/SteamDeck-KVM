# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Проверки чтения свойств X11 и датчика захвата курсора на поддельном сервере gamescope
"""
test_x11_property_soldier.py

Поддельный сервер отвечает байтами протокола X11 (порядок младшим байтом вперёд) по паре сокетов:
подключение, InternAtom, GetProperty. Проверяется разбор ответов солдатом и решение датчика
«захватила ли игра курсор». Настоящий gamescope проверяется только на Deck'е.
"""

from __future__ import annotations

import socket
import struct
import threading

from core.officers.intelligence.deck_session_sensor import STEAM_APP_ID, DeckSessionSensor
from core.soldiers.x11_property_soldier import X11PropertySoldier, list_displays, read_cookie

ROOT = 0x1A2


def _read(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError
        data += chunk
    return data


def fake_server(props, refuse=False, event_first=False):
    """Сокет клиента и поток сервера со свойствами {имя: (формат, байты)}.

    event_first — перед каждым ответом сервер шлёт событие MappingNotify, как настоящий X11 при
    смене раскладки, и ошибку с чужим номером запроса.
    """
    client, server = socket.socketpair()
    atoms = {}
    seq = [0]

    def serve():
        try:
            head = _read(server, 12)
            name_len, data_len = struct.unpack("<HH", head[6:10])
            _read(server, name_len + (-name_len % 4) + data_len + (-data_len % 4))
            if refuse:
                reason = b"No protocol specified"
                padded = reason + b"\0" * (-len(reason) % 4)
                server.sendall(struct.pack("<BBHHH", 0, len(reason), 11, 0, len(padded) // 4) + padded)
                return
            vendor = b"gamescope"
            body = struct.pack("<IIIIHHBBBBBBBB4x", 1, 0, 0, 0, len(vendor), 0xFFFF, 1, 1, 0, 0, 32, 32, 8, 255)
            body += vendor + b"\0" * (-len(vendor) % 4) + b"\0" * 8 + struct.pack("<I", ROOT) + b"\0" * 36
            server.sendall(struct.pack("<BxHHH", 1, 11, 0, len(body) // 4) + body)
            while True:
                req = _read(server, 4)
                opcode, _, size = struct.unpack("<BBH", req)
                rest = _read(server, size * 4 - 4)
                seq[0] += 1
                if event_first:
                    server.sendall(struct.pack("<BBHI", 34, 0, seq[0], 0x7FFFFFFF) + bytes(24))
                    server.sendall(struct.pack("<BBH", 0, 5, (seq[0] + 7) & 0xFFFF) + bytes(28))
                if opcode == 16:
                    n = struct.unpack("<H", rest[:2])[0]
                    name = rest[4:4 + n].decode()
                    atom = atoms.setdefault(name, 100 + len(atoms)) if name in props else 0
                    server.sendall(struct.pack("<BxHII", 1, seq[0], 0, atom) + b"\0" * 20)
                elif opcode == 20:
                    window, atom = struct.unpack("<II", rest[:8])
                    name = next((k for k, v in atoms.items() if v == atom), None)
                    fmt, value = props.get(name, (0, b"")) if window == ROOT else (0, b"")
                    count = len(value) // (fmt // 8) if fmt else 0
                    padded = value + b"\0" * (-len(value) % 4)
                    server.sendall(struct.pack("<BBHIIII12x", 1, fmt, seq[0], len(padded) // 4, 6, 0, count) + padded)
        except (ConnectionError, OSError):
            pass

    threading.Thread(target=serve, daemon=True).start()
    return client


def card(value):
    return 32, struct.pack("<I", value)


def text(value):
    return 8, value.encode() + b"\0"


def test_reads_root_cardinal_and_text_properties():
    x = X11PropertySoldier(0, connect=lambda d, t: fake_server({"GAMESCOPE_FOCUSED_APP": card(1245620),
                                                            "GAMESCOPE_FOCUS_DISPLAY": text(":1")}))
    assert x.root == ROOT
    assert x.cardinal("GAMESCOPE_FOCUSED_APP") == 1245620
    assert x.text("GAMESCOPE_FOCUS_DISPLAY") == ":1"
    assert x.cardinal("GAMESCOPE_CURSOR_VISIBLE_FEEDBACK") is None     # имени нет — свойства нет
    x.close()


def test_events_and_foreign_errors_between_replies_are_skipped():
    x = X11PropertySoldier(0, connect=lambda d, t: fake_server({"GAMESCOPE_FOCUSED_APP": card(7),
                                                                "GAMESCOPE_FOCUS_DISPLAY": text(":1")},
                                                               event_first=True))
    assert x.cardinal("GAMESCOPE_FOCUSED_APP") == 7
    assert x.text("GAMESCOPE_FOCUS_DISPLAY") == ":1"
    x.close()


def test_failure_pauses_questions_to_x11(tmp_path):
    calls = []

    def broken(display, auth):
        calls.append(display)
        raise ConnectionRefusedError("нет")
    proc = tmp_path / "proc" / "321"
    proc.mkdir(parents=True)
    (proc / "comm").write_text("steam\n")
    (proc / "environ").write_bytes(b"DISPLAY=:0\0")
    sensor = DeckSessionSensor(sys_root=str(tmp_path / "s"), proc_root=str(tmp_path / "proc"), x11_factory=broken)
    assert sensor.cursor_captured() is None
    assert sensor.cursor_captured() is None
    assert calls == [0]                   # второй вопрос в паузе после сбоя сервер не трогает


def test_refusal_is_a_clear_error():
    try:
        X11PropertySoldier(0, connect=lambda d, t: fake_server({}, refuse=True))
    except ConnectionRefusedError as error:
        assert "No protocol specified" in str(error)
    else:
        raise AssertionError("отказ сервера не поднят")


def test_cookie_for_own_display_wins(tmp_path):
    def entry(num, cookie):
        parts = [b"host", num, b"MIT-MAGIC-COOKIE-1", cookie]
        return struct.pack(">H", 256) + b"".join(struct.pack(">H", len(p)) + p for p in parts)
    path = tmp_path / "xauth"
    path.write_bytes(entry(b"1", b"one") + entry(b"0", b"zero"))
    assert read_cookie(str(path), 0) == b"zero"
    assert read_cookie(str(path), 5) == b"one"
    assert read_cookie(str(tmp_path / "нет"), 0) == b""


def test_list_displays(tmp_path):
    for name in ("X0", "X1", "X1-lock", "other"):
        (tmp_path / name).write_text("")
    assert list_displays(str(tmp_path)) == [0, 1]


# ---- датчик ------------------------------------------------------------------------------

def gamescope_world(tmp_path, root_props, mouse_props=None):
    proc = tmp_path / "proc" / "321"
    proc.mkdir(parents=True)
    (proc / "comm").write_text("steam\n")
    (proc / "environ").write_bytes(b"HOME=/home/deck\0DISPLAY=:0\0XAUTHORITY=/run/user/1000/xauth\0")
    servers = {0: root_props, 1: mouse_props or {}}

    def factory(display, auth):
        assert auth == "/run/user/1000/xauth"
        return X11PropertySoldier(display, connect=lambda d, t: fake_server(servers[d]))
    return DeckSessionSensor(sys_root=str(tmp_path / "sys"), proc_root=str(tmp_path / "proc"), x11_factory=factory)


def test_game_with_hidden_cursor_is_captured(tmp_path):
    sensor = gamescope_world(tmp_path,
                             {"GAMESCOPE_FOCUSED_APP": card(1245620), "GAMESCOPE_FOCUS_DISPLAY": text(":1"),
                              "GAMESCOPE_MOUSE_FOCUS_DISPLAY": text(":1")},
                             {"GAMESCOPE_CURSOR_VISIBLE_FEEDBACK": card(0)})
    assert sensor.cursor_captured() is True


def test_game_menu_with_visible_cursor_is_free(tmp_path):
    sensor = gamescope_world(tmp_path,
                             {"GAMESCOPE_FOCUSED_APP": card(1245620), "GAMESCOPE_MOUSE_FOCUS_DISPLAY": text(":1")},
                             {"GAMESCOPE_CURSOR_VISIBLE_FEEDBACK": card(1)})
    assert sensor.cursor_captured() is False


def test_steam_menu_is_never_captured(tmp_path):
    sensor = gamescope_world(tmp_path, {"GAMESCOPE_FOCUSED_APP": card(STEAM_APP_ID),
                                        "GAMESCOPE_CURSOR_VISIBLE_FEEDBACK": card(0)})
    assert sensor.cursor_captured() is False


def test_no_gamescope_means_no_answer(tmp_path):
    assert gamescope_world(tmp_path, {}).cursor_captured() is None
    empty = DeckSessionSensor(sys_root=str(tmp_path / "s"), proc_root=str(tmp_path / "нет"))
    assert empty.cursor_captured() is None
