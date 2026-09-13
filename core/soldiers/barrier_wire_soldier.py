# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — Soldier кадров протокола Barrier/Synergy поверх потока TCP
"""
barrier_wire_soldier.py

Протокол Deskflow передаёт сообщения кадрами: четыре байта длины, затем тело. Поток TCP
границ сообщений не знает — одно чтение приносит полтора кадра или три, и склейка идёт здесь.
"""

from __future__ import annotations

import struct

# Сообщение длиннее четырёх мегабайт в этом протоколе не бывает: самое крупное — буфер обмена,
# который клиент не принимает. Такая длина означает обрыв потока, а не настоящее сообщение.
MAX_FRAME = 4 * 1024 * 1024


class BarrierWireSoldier:
    """Чтение и запись сообщений: 4 байта длины, затем тело."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def feed(self, data):
        self.buf += data

    def messages(self):
        while len(self.buf) >= 4:
            size = struct.unpack(">I", self.buf[:4])[0]
            if size > MAX_FRAME:
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
