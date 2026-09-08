"""Проверка клиента deck-kvm: разбор протокола и совместимость с Deskflow.

Тест 1 — против поддельного сервера: во что превращаются сообщения протокола
на уровне событий ядра.
Тест 2 — против настоящего deskflow-core: рукопожатие.
Тест 3 — починки по итогам ревью 08.09.2026, каждая своим пунктом.
"""
import importlib.util
import os
import socket
import struct
import sys
import threading
import time
import types

# --- заглушки для Linux-специфики, чтобы модуль импортировался на Windows ---
fake_fcntl = types.ModuleType("fcntl")
fake_fcntl.ioctl = lambda *a, **k: 0
sys.modules.setdefault("fcntl", fake_fcntl)

ЗДЕСЬ = os.path.dirname(os.path.abspath(__file__))
ПУТЬ = os.path.join(ЗДЕСЬ, "deck-kvm.py")
if not os.path.exists(ПУТЬ):
    ПУТЬ = "/var/lib/deck-kvm/deck-kvm.py"
SPEC = importlib.util.spec_from_file_location("deckkvm", ПУТЬ)
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


class FakeDevice:
    def __init__(self, name, keys=(), rels=(), abss=(), **kw):
        self.name = name
        self.abss = tuple(abss)
        self.events = []

    def emit(self, etype, code, value):
        self.events.append((etype, code, value))

    def sync(self):
        self.events.append(("SYN",))

    def close(self):
        pass


mod.VirtualDevice = FakeDevice
mod.detect_screen = lambda: (1280, 800)

FAILURES = []


def check(condition, label):
    print(("  OK      " if condition else "  ПРОВАЛ  ") + label)
    if not condition:
        FAILURES.append(label)


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


def kvm(pointer="abs"):
    return mod.DeckKVM("127.0.0.1", 1, "steamdeck", lambda t: None, pointer=pointer)


# ---------------------------------------------------------------- тест 1
def test_against_fake_server():
    print("Тест 1 — разбор сообщений против поддельного сервера")
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
        # вход на экран в точке (100, 50), Shift уже зажат на ноутбуке
        conn.sendall(frame(b"CINN" + struct.pack(">hhih", 100, 50, 1, 0x0001)))
        conn.sendall(frame(b"DMMV" + struct.pack(">hh", 640, 400)))
        conn.sendall(frame(b"DMDN" + bytes([1])))
        conn.sendall(frame(b"DMUP" + bytes([1])))
        conn.sendall(frame(b"DMWM" + struct.pack(">hh", 0, 120)))
        conn.sendall(frame(b"DKDN" + struct.pack(">HHH", ord("a"), 0, 30)))
        conn.sendall(frame(b"DKUP" + struct.pack(">HHH", ord("A"), 1, 30)))
        conn.sendall(frame(b"DKDN" + struct.pack(">HHH", 0xEF53, 0, 40)))
        conn.sendall(frame(b"DKUP" + struct.pack(">HHH", 0xEF53, 0, 40)))
        conn.sendall(frame(b"DMRM" + struct.pack(">hh", -5, 7)))
        time.sleep(0.4)
        conn.sendall(frame(b"COUT"))
        time.sleep(0.3)
        conn.sendall(frame(b"CBYE"))
        time.sleep(0.2)
        conn.close()

    thread = threading.Thread(target=server, daemon=True)
    thread.start()

    client = mod.DeckKVM("127.0.0.1", port, "steamdeck", lambda t: None)
    try:
        client.session()
    except Exception:
        pass
    thread.join(timeout=5)

    hb = seen.get("helloback", b"")
    check(hb[:7] == b"Barrier", "HelloBack повторяет имя протокола сервера")
    check(hb[7:11] == struct.pack(">hh", 1, 6), "HelloBack объявляет версию 1.6")
    check(hb[11:] == struct.pack(">I", 9) + b"steamdeck", "HelloBack несёт имя экрана")

    dinf = seen.get("dinf", b"")
    check(dinf[:4] == b"DINF", "на QINF отвечает DINF")
    check(
        struct.unpack(">hhhhhhh", dinf[4:]) == (0, 0, 1280, 800, 0, 640, 400),
        "DINF сообщает размер экрана 1280x800",
    )
    check(seen.get("calv") == b"CALV", "на CALV отвечает CALV")

    m, kb = client.mouse.events, client.kbd.events
    check((mod.EV_ABS, mod.ABS_X, mod._DEV and 16383) in m or
          any(e[0] == mod.EV_ABS and e[1] == mod.ABS_X for e in m),
          "положение курсора идёт абсолютными осями")
    check((mod.EV_KEY, mod.BTN_LEFT, 1) in m, "левая кнопка нажимается")
    check((mod.EV_KEY, mod.BTN_LEFT, 0) in m, "левая кнопка отпускается")
    check((mod.EV_REL, mod.REL_WHEEL, 1) in m, "колесо даёт один щелчок на 120")
    check((mod.EV_REL, mod.REL_X, -5) in m, "относительное движение проходит как есть")

    check((mod.EV_KEY, mod.K["A"], 1) in kb, "«a» даёт физическую клавишу A")
    check((mod.EV_KEY, mod.K["A"], 0) in kb, "«A» на отпускании закрывает ту же клавишу")
    check(mod.KEYMAP[ord("ф")] == mod.K["A"] and mod.KEYMAP[ord("ы")] == mod.K["S"]
          and mod.KEYMAP[ord("й")] == mod.K["Q"], "кириллица ложится на позиции ЙЦУКЕН")
    check((mod.EV_KEY, mod.K["RIGHT"], 1) in kb, "стрелка вправо доходит")
    check(client.pressed == {} and client.mods == set(),
          "после COUT ни одна клавиша не осталась зажатой")


# ---------------------------------------------------------------- тест 2
def test_against_real_server(port=24801):
    print("Тест 2 — рукопожатие с настоящим deskflow-core")
    client = mod.DeckKVM("127.0.0.1", port, "steamdeck", print)
    got = {}
    original = mod.DeckKVM.handle

    def spy(self, wire, msg):
        got.setdefault("msgs", []).append(msg[:4])
        return original(self, wire, msg)

    mod.DeckKVM.handle = spy
    stop = time.monotonic() + 6

    def run():
        try:
            client.session()
        except Exception as err:
            got["error"] = err

    threading.Thread(target=run, daemon=True).start()
    while time.monotonic() < stop and b"CALV" not in got.get("msgs", []):
        time.sleep(0.2)
    msgs = got.get("msgs", [])
    mod.DeckKVM.handle = original
    check(bool(msgs), "сервер принял клиента и продолжил разговор")
    check(b"QINF" in msgs, "сервер запросил сведения об экране (QINF)")
    check(b"CALV" in msgs, "сервер шлёт keep-alive, значит клиент им опознан")
    print("     получено от сервера: %s" % b" ".join(sorted(set(msgs))).decode())


# ---------------------------------------------------------------- тест 3
def test_fixes():
    print("Тест 3 — починки по итогам ревью")

    # --- автоповтор клавиш ---
    c = kvm()
    c.handle_key(b"DKDN", b"DKDN" + struct.pack(">HHH", ord("a"), 0, 30))
    c.handle_key(b"DKRP", b"DKRP" + struct.pack(">HHHH", ord("a"), 0, 3, 30))
    repeats = [e for e in c.kbd.events if e[0] == mod.EV_KEY and e[2] == mod.KEY_REPEAT]
    check(len(repeats) == 3, "DKRP даёт события повтора со значением 2, а не 1")
    check(all(e[1] == mod.K["A"] for e in repeats), "повтор идёт по той же клавише")
    check(
        len([e for e in c.kbd.events if e[0] == mod.EV_KEY and e[2] == mod.KEY_DOWN]) == 1,
        "повторное нажатие ядру не шлётся — оно его всё равно отбросит",
    )

    c = kvm()
    c.handle_key(b"DKRP", b"DKRP" + struct.pack(">HHHH", ord("b"), 0, 2, 48))
    check(
        (mod.EV_KEY, mod.K["B"], mod.KEY_DOWN) in c.kbd.events,
        "повтор без предшествующего нажатия сначала нажимает клавишу",
    )

    # --- колесо: округление к нулю ---
    c = kvm()
    c.wheel(0, -40)
    check(
        not [e for e in c.mouse.events if e[0] == mod.EV_REL],
        "треть щелчка вниз не выдаёт целого щелчка",
    )
    c.wheel(0, -40)
    c.wheel(0, -40)
    down = [e for e in c.mouse.events if e[0] == mod.EV_REL and e[1] == mod.REL_WHEEL]
    check(down == [(mod.EV_REL, mod.REL_WHEEL, -1)],
          "три трети вниз дают ровно один щелчок вниз")
    c = kvm()
    for _ in range(3):
        c.wheel(0, 40)
    up = [e for e in c.mouse.events if e[0] == mod.EV_REL and e[1] == mod.REL_WHEEL]
    check(up == [(mod.EV_REL, mod.REL_WHEEL, 1)],
          "вверх ведёт себя симметрично вниз")

    # --- абсолютное положение ---
    c = kvm()
    check(c.mouse.abss == (mod.ABS_X, mod.ABS_Y), "мышь заявляет абсолютные оси")
    c.move_abs(0, 0)
    c.move_abs(1279, 799)
    c.move_abs(640, 400)
    abs_x = [e[2] for e in c.mouse.events if e[0] == mod.EV_ABS and e[1] == mod.ABS_X]
    check(abs_x[0] == 0, "левый край экрана — ноль оси")
    check(abs_x[1] == mod.ABS_MAX, "правый край экрана — предел оси")
    check(abs(abs_x[2] - mod.ABS_MAX // 2) <= 16, "середина экрана — середина оси")
    check(
        not [e for e in c.mouse.events if e[0] == mod.EV_REL],
        "абсолютное положение не превращается в смещения, ускорять нечего",
    )

    c = kvm(pointer="rel")
    check(c.mouse.abss == (), "в режиме rel абсолютных осей нет")
    c.move_abs(100, 100)
    check(
        any(e[0] == mod.EV_REL for e in c.mouse.events),
        "в режиме rel положение по-прежнему идёт смещениями",
    )

    # --- маска модификаторов ---
    c = kvm()
    c.handle(None, b"CINN" + struct.pack(">hhih", 10, 10, 1, 0x0001 | 0x0002))
    check(
        (mod.EV_KEY, mod.K["LEFTSHIFT"], mod.KEY_DOWN) in c.kbd.events
        and (mod.EV_KEY, mod.K["LEFTCTRL"], mod.KEY_DOWN) in c.kbd.events,
        "зажатые до перехода Shift и Ctrl нажимаются на Deck'е",
    )
    c.kbd.events.clear()
    c.sync_modifiers(0x0002)
    check(
        (mod.EV_KEY, mod.K["LEFTSHIFT"], mod.KEY_UP) in c.kbd.events
        and (mod.EV_KEY, mod.K["LEFTCTRL"], mod.KEY_DOWN) not in c.kbd.events,
        "снятый модификатор отпускается, оставшийся не передавливается",
    )
    c.kbd.events.clear()
    c.handle(None, b"CINN" + struct.pack(">hhih", 10, 10, 1, 0x1000))
    check(
        not [e for e in c.kbd.events if len(e) == 3 and e[1] == mod.K["CAPSLOCK"]],
        "замок CapsLock не досылается: он переключается, а не удерживается",
    )

    # --- сброс задержки переповторов ---
    c = kvm()
    calls = {"n": 0, "sleeps": []}

    def session_fail():
        calls["n"] += 1
        if calls["n"] > 6:
            raise KeyboardInterrupt
        raise OSError("нет сети")

    c.session = session_fail
    real_sleep = mod.time.sleep
    mod.time.sleep = lambda s: calls["sleeps"].append(s)
    try:
        c.run()
    except KeyboardInterrupt:
        pass
    mod.time.sleep = real_sleep
    check(calls["sleeps"][:4] == [1, 2, 4, 8], "задержка повторов растёт вдвое")
    check(max(calls["sleeps"]) <= 15, "задержка не превышает 15 секунд")

    c = kvm()
    state = {"n": 0}
    starts = []

    def session_long():
        state["n"] += 1
        starts.append(c.host)
        if state["n"] > 2:
            raise KeyboardInterrupt
        real_sleep(0.02)
        raise OSError("разрыв после долгой работы")

    c.hosts = ["первый", "второй"]
    c.session = session_long
    c.УДАЧНАЯ_СЕССИЯ = 0.01          # «долгая» сессия для теста — сотая секунды
    mod.time.sleep = lambda s: None
    try:
        c.run()
    except KeyboardInterrupt:
        pass
    mod.time.sleep = real_sleep
    check(starts[:2] == ["первый", "первый"],
          "после удачной сессии клиент держится того же адреса")


if __name__ == "__main__":
    test_against_fake_server()
    test_fixes()
    if "--real" in sys.argv:
        test_against_real_server()
    print()
    if FAILURES:
        print("ПРОВАЛЕНО пунктов: %d" % len(FAILURES))
        for f in FAILURES:
            print("  - " + f)
        sys.exit(1)
    print("Все проверки пройдены")
