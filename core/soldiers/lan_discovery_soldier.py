# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Soldier знакомства Deck'а с компьютером по локальной сети и памяти о паре
"""
lan_discovery_soldier.py

ПК вещает, Deck слышит и отвечает. Порядок именно такой, а не обратный: если бы искал Deck, а
отвечал ПК, Windows потребовал бы входящего правила брандмауэра на порт поиска — то есть прав
администратора при установке. Исходящая рассылка с ПК правила не требует, а одиночный ответ
Deck'а Windows пропускает как ответ на собственную рассылку.

Адрес ПК берётся из ЗАГОЛОВКА полученного пакета, а не из его текста: смена адреса в роутере
ничего не ломает и настраивать нечего вовсе. Пара держится на НОМЕРЕ устройства, а не на
адресе: номер не меняется никогда, поэтому знакомство переживает переезд, смену роутера и
раздачу с телефона.

По этому же каналу ходят две просьбы, и обе принимаются только от своей пары:

1. **Deck → ПК «верни управление»** (`TOPC`): Alt+Tab в игре, окно «Компьютер» на рабочем столе,
   кнопка в окне. Уходит туда, откуда пришёл последний маячок, — в адрес и временный порт ПК:
   брандмауэр Windows пропускает это как ответ на его же рассылку, как и ответ на маячок.
2. **ПК → Deck «обновись»** (`UPDATE`): кнопка «Обновить» и уведомление на компьютере.
   Deck ставит последний выпуск с github.com сам — просьба не несёт ни адреса, ни файла, и
   подделать её значит лишь заставить Deck обновиться с официальной страницы.
"""

from __future__ import annotations

import os
import selectors
import shutil
import socket
import time
import uuid
from pathlib import Path

from core import config_policy

IDENTITY_FILE = "identity"      # номер этого Deck'а
PAIR_FILE = "pair"              # номер знакомого компьютера
LAST_SERVER_FILE = "last-server"  # последний адрес знакомого компьютера


def _path(name: str) -> Path:
    return config_policy.state_dir() / name


def _read_line(path: Path):
    # Нечитаемые байты заменяются, а не роняют службу: файл, записанный чужой программой или
    # испорченный наполовину, не должен оставлять Deck без связи. Номер устройства — латиница,
    # и замена его не портит.
    try:
        return path.read_bytes().decode("utf-8", errors="replace").strip() or None
    except OSError:
        return None


def _write_line(path: Path, value: str) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value + "\n", encoding="utf-8")
    except OSError:
        pass


def migrate_legacy_state(log=lambda text: None) -> int:
    """Перенести номер Deck'а и пару из прежней установки от администратора.

    Без переноса новая установка завела бы новый номер, компьютер не узнал бы Deck, и
    знакомство пришлось бы делать заново. Файлы прежней установки открыты на чтение всем,
    поэтому прав администратора перенос не требует. Уже существующее не перезаписывается:
    повторный переезд не должен откатить пару, заведённую после первого.
    """
    moved = 0
    for name in (IDENTITY_FILE, PAIR_FILE, LAST_SERVER_FILE):
        source = config_policy.LEGACY_STATE_DIR / name
        target = _path(name)
        if target.exists() or not source.is_file():
            continue
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            moved += 1
        except OSError:
            continue
    if moved:
        log("перенесено из прежней установки: %d файл(а) состояния" % moved)
    return moved


def device_id() -> str:
    """Постоянный номер этого Deck'а — заводится один раз и живёт вечно."""
    saved = _read_line(_path(IDENTITY_FILE))
    if saved:
        return saved
    fresh = uuid.uuid4().hex
    _write_line(_path(IDENTITY_FILE), fresh)
    return fresh


class LanDiscoverySoldier:
    """Слушает маячок своего компьютера, отвечает ему и помнит, с кем знаком."""

    def __init__(self, name, log, bind_port=None):
        self.name = name
        self.log = log
        self.id = device_id()
        self.peer = _read_line(_path(PAIR_FILE))   # номер своего ПК, если уже знакомы
        self.peer_name = None
        self.address = None
        self.port = config_policy.KVM_PORT
        self.server_on = False
        self.languages = None                        # языки клавиатуры компьютера: en-US,ru-RU
        # Выбор человека на компьютере: возвращает ли Alt+Tab на компьютер. Прежний компьютер поля
        # не шлёт — тогда включено, как было до настроек.
        self.flags = {"alttab": True}
        self.update_requested = False                # компьютер попросил обновиться
        self.version = ""                            # своя версия — в ответе на маячок
        self.reply_to = None                         # (адрес, порт) последнего маячка своего ПК
        self.seen = 0.0
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        port = config_policy.BEACON_PORT if bind_port is None else bind_port
        self.sock.bind(("", port))
        self.sock.setblocking(False)

    def poll(self):
        """Разобрать всё, что накопилось, и ответить. Не блокирует."""
        while True:
            try:
                data, sender = self.sock.recvfrom(1024)
            except (BlockingIOError, InterruptedError):
                return
            except OSError:
                return
            self.accept(data, sender)

    def accept(self, data: bytes, sender) -> bool:
        """Разобрать один маячок. Возвращает, признан ли он своим."""
        parts = data.decode("utf-8", "replace").split()
        # PROTOCOL UPDATE <номер ПК> — просьба компьютера обновиться; только от своей пары.
        if len(parts) >= 3 and parts[0] == config_policy.PROTOCOL and parts[1] == "UPDATE":
            if self.peer and parts[2] == self.peer:
                self.update_requested = True
                self.log("компьютер попросил обновиться")
                return True
            return False
        # PROTOCOL SERVER <номер ПК> <имя> <порт> <on|off> <номер знакомого Deck'а|-> [<языки ПК>] [<флаги>]
        if len(parts) < 6 or parts[0] != config_policy.PROTOCOL or parts[1] != "SERVER":
            return False
        pc_id, pc_name = parts[2], parts[3]
        pc_knows = parts[6] if len(parts) > 6 else "-"

        if self.peer and self.peer != pc_id:
            # Свой компьютер, потерявший память о паре, приходит с новым номером и «-» вместо номера
            # Deck'а — с того же адреса, куда Deck и так подключается. Такого не игнорируем: иначе
            # Deck уходил на запасной адрес, а компьютер навсегда оставался «ещё не знакомы».
            # Помнящий этот Deck по номеру — тоже свой. Прочие — чужие, молча мимо.
            same_machine = pc_knows == "-" and sender[0] == self.recall()
            if not (pc_knows == self.id or same_machine):
                return False
            self.log("свой компьютер сменил номер: %s → %s, адрес %s" % (self.peer, pc_id, sender[0]))
            self.peer = pc_id
            _write_line(_path(PAIR_FILE), pc_id)
        if not self.peer and pc_knows not in ("-", self.id):
            return False                      # этот ПК уже занят другим Deck'ом
        if not self.peer:
            self.peer = pc_id
            _write_line(_path(PAIR_FILE), pc_id)
            self.log("знакомство: компьютер «%s» номер %s, адрес %s" % (pc_name, pc_id, sender[0]))

        if sender[0] != self.address:
            if self.address:
                self.log("свой компьютер сменил адрес: %s" % sender[0])
            _write_line(_path(LAST_SERVER_FILE), sender[0])
        self.address = sender[0]
        self.peer_name = pc_name
        self.seen = time.monotonic()
        try:
            self.port = int(parts[4])
        except ValueError:
            pass
        self.server_on = parts[5] == "on"
        if len(parts) > 7 and parts[7] != "-":
            self.languages = parts[7]
        if len(parts) > 8:
            for pair in parts[8].split(","):
                name, _, value = pair.partition("=")
                if name in self.flags and value in ("0", "1"):
                    self.flags[name] = value == "1"
        self.reply_to = sender
        # Ответ идёт ровно туда, откуда пришёл маячок — в адрес И порт отправителя, а не на
        # порт рассылки. Порт у ПК временный, и именно на него брандмауэр Windows пропускает
        # ответ как продолжение своей же рассылки.
        # Пятым полем — своя версия: по ней компьютер видит, отстаёт ли Deck от выпуска.
        reply = "%s DECK %s %s %s" % (config_policy.PROTOCOL, self.id, self.name, self.version or "-")
        try:
            self.sock.sendto(reply.encode("utf-8"), sender)
        except OSError:
            pass
        return True

    def send_to_pc(self) -> bool:
        """Попросить свой компьютер вернуть управление. Возвращает, ушла ли просьба."""
        if not self.reply_to or time.monotonic() - self.seen > 15:
            return False
        try:
            self.sock.sendto(("%s TOPC %s" % (config_policy.PROTOCOL, self.id)).encode("utf-8"), self.reply_to)
        except OSError as error:
            self.log("просьба вернуть управление не ушла: %s" % error)
            return False
        return True

    def wait(self, timeout):
        """Подождать рассылку не дольше timeout секунд и разобрать её."""
        try:
            ready = selectors.DefaultSelector()
            ready.register(self.sock, selectors.EVENT_READ)
            ready.select(timeout=timeout)
            ready.close()
        except OSError:
            time.sleep(timeout)
        self.poll()

    def forget(self):
        """Забыть компьютер — следующий откликнувшийся станет новым.

        Номер самого Deck'а при этом остаётся: забывается ПАРА, а не устройство. Иначе
        компьютер, помнящий этот Deck, перестал бы узнавать его после переустановки.
        """
        self.peer = None
        self.peer_name = None
        self.address = None
        for name in (PAIR_FILE, LAST_SERVER_FILE):
            try:
                os.remove(_path(name))
            except OSError:
                pass

    @staticmethod
    def recall():
        return _read_line(_path(LAST_SERVER_FILE))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass
