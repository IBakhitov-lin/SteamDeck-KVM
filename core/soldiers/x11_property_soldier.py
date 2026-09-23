# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Soldier чтения свойств корневого окна X11 без сторонних библиотек
"""
x11_property_soldier.py

Композитор игрового режима gamescope сообщает о себе свойствами корневого окна своих серверов
Xwayland: какая игра в фокусе, на каком сервере мышь, виден ли курсор. Читать их нужно из
службы, а ставить на Deck библиотеку X11 нельзя — SteamOS перезаписывает системный раздел
обновлением. Поэтому здесь ровно три запроса протокола X11 — подключение, имя свойства,
значение свойства, — написанные по спецификации X11R7 (глава «Connection Setup», запросы
InternAtom и GetProperty).

Служба читает свойства в том же потоке, что ведёт мышь и клавиатуру, поэтому таймаут короткий
и стоит ещё до подключения. Способ подключения передаётся параметром: проверки подставляют
поддельный сервер.
"""

from __future__ import annotations

import os
import socket
import struct

_COOKIE = b"MIT-MAGIC-COOKIE-1"


def _pad(size):
    return (4 - size % 4) % 4


def read_cookie(path, display):
    """Ключ MIT-MAGIC-COOKIE-1 для номера экрана из файла Xauthority; нет — пустой ключ."""
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except (OSError, TypeError):
        return b""
    number = str(display).encode()
    fallback = b""
    pos = 0
    try:
        while pos + 2 <= len(data):
            pos += 2                                   # семейство адреса
            fields = []
            for _ in range(4):                         # адрес, номер экрана, имя ключа, ключ
                size = struct.unpack(">H", data[pos:pos + 2])[0]
                fields.append(data[pos + 2:pos + 2 + size])
                pos += 2 + size
            _, num, name, cookie = fields
            if name != _COOKIE:
                continue
            if num == number:
                return cookie
            fallback = fallback or cookie
    except struct.error:
        pass
    return fallback


def connect_unix(display, timeout):
    """Сокет сервера X11 с таймаутом, поставленным до подключения."""
    path = "/tmp/.X11-unix/X%d" % display
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(path)
    except OSError:
        sock.close()
        # Xwayland слушает и абстрактный сокет с тем же именем — он есть, даже если файла нет.
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(chr(0) + path)
    return sock


class X11PropertySoldier:
    """Одно подключение к серверу X11: только чтение свойств корневого окна."""

    def __init__(self, display, xauthority=None, connect=None, timeout=0.3):
        self.display = int(display)
        self.sock = (connect or connect_unix)(self.display, timeout)
        self.sock.settimeout(timeout)
        self._atoms = {}
        self._seq = 0
        cookie = read_cookie(xauthority, self.display) if xauthority else b""
        name = _COOKIE if cookie else b""
        head = struct.pack("<BxHHHHxx", 0x6C, 11, 0, len(name), len(cookie))
        self.sock.sendall(head + name + b"\0" * _pad(len(name)) + cookie + b"\0" * _pad(len(cookie)))
        reply = self._read(8)
        body = self._read(struct.unpack("<H", reply[6:8])[0] * 4)
        if reply[0] != 1:
            self.close()
            raise ConnectionRefusedError("X11 отказал: %s" % body[:reply[1]].decode("ascii", "replace"))
        vendor_len = struct.unpack("<H", body[16:18])[0]
        formats = body[21]
        offset = 32 + vendor_len + _pad(vendor_len) + 8 * formats
        self.root = struct.unpack("<I", body[offset:offset + 4])[0]

    def _read(self, size):
        data = b""
        while len(data) < size:
            chunk = self.sock.recv(size - len(data))
            if not chunk:
                raise ConnectionError("X11 закрыл соединение")
            data += chunk
        return data

    def _send(self, payload):
        self._seq = (self._seq + 1) & 0xFFFF
        self.sock.sendall(payload)

    def _reply(self):
        """Ответ на последний запрос. Ошибка сервера (первый байт 0) — None: свойства нет.

        События (первый байт 2 и больше) сервер шлёт и без подписки — MappingNotify при смене
        раскладки; они пропускаются. Номер запроса сверяется: чужой ответ сдвинул бы все следующие.
        """
        while True:
            head = self._read(32)
            kind = head[0]
            if kind >= 2:
                continue
            seq = struct.unpack("<H", head[2:4])[0]
            if kind == 0:
                if seq == self._seq:
                    return None, head
                continue
            extra = self._read(struct.unpack("<I", head[4:8])[0] * 4)
            if seq == self._seq:
                return head, extra

    def atom(self, name):
        """Номер имени свойства; 0 — такого имени сервер не знает, значит и свойства нет."""
        if name in self._atoms:
            return self._atoms[name]
        raw = name.encode("ascii")
        size = (8 + len(raw) + _pad(len(raw))) // 4
        self._send(struct.pack("<BBHHxx", 16, 1, size, len(raw)) + raw + b"\0" * _pad(len(raw)))
        head, _ = self._reply()
        value = struct.unpack("<I", head[8:12])[0] if head else 0
        if value:
            self._atoms[name] = value
        return value

    def _property(self, name):
        atom = self.atom(name)
        if not atom:
            return None
        self._send(struct.pack("<BBHIIIII", 20, 0, 6, self.root, atom, 0, 0, 64))
        head, data = self._reply()
        if head is None:
            return None
        fmt = head[1]
        count = struct.unpack("<I", head[16:20])[0]
        if fmt == 0 or count == 0:
            return None
        return fmt, data[:count * (fmt // 8)]

    def cardinal(self, name):
        """Первое число 32-битного свойства; нет свойства — None."""
        found = self._property(name)
        if not found or found[0] != 32:
            return None
        return struct.unpack("<I", found[1][:4])[0]

    def text(self, name):
        """Строковое свойство без завершающего нуля; нет свойства — None."""
        found = self._property(name)
        if not found:
            return None
        return found[1].split(b"\0", 1)[0].decode("utf-8", "replace")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def list_displays(root="/tmp/.X11-unix"):
    """Номера серверов X11 по сокетам в папке, по возрастанию."""
    try:
        names = os.listdir(root)
    except OSError:
        return []
    return sorted(int(name[1:]) for name in names if name.startswith("X") and name[1:].isdigit())
