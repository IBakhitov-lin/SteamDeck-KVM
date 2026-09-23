# НАЗНАЧЕНИЕ ЭТОГО МОДУЛЯ — DTO состояния клиента Steam Deck для окна и журнала
"""
client_status_dto.py

Одна форма состояния на всех читателей: окно на Deck'е, текстовое меню в терминале, проверки.
Пока состояние жило разрозненными полями командира, окно собирало его заново и неизбежно
расходилось бы с тем, что пишет журнал.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field

# Состояния — закрытый список: окно переводит их в слова, и незнакомое состояние оно показало
# бы пустой строкой. Добавляешь состояние — добавь его слово в окно в том же изменении.
STARTING = "starting"          # служба поднимается
WAITING_PC = "waiting_pc"      # знакомого компьютера в сети не слышно
PC_OFF = "pc_off"              # компьютер слышен, но сервер на нём выключен
CONNECTING = "connecting"      # идёт соединение
CONNECTED = "connected"        # связь есть
DISPLAY_OFF = "display_off"    # экран Deck'а погас, связь снята намеренно
NO_UINPUT = "no_uinput"        # нет доступа к виртуальным устройствам ядра

STATES = (STARTING, WAITING_PC, PC_OFF, CONNECTING, CONNECTED, DISPLAY_OFF, NO_UINPUT)


@dataclass
class ClientStatusDTO:
    version: str = "0.0.0"
    state: str = STARTING
    pc_name: str | None = None
    pc_address: str | None = None
    paired: bool = False
    mode: str = "unknown"
    pointer: str = "abs"
    display_on: bool = True
    on_screen: bool = False
    captured: bool = False          # игра спрятала курсор: смещения без края, на ПК не уходит
    held_keys: list = field(default_factory=list)
    update_available: str | None = None
    updating: bool = False
    update_error: str | None = None
    last_error: str | None = None

    def to_dict(self) -> dict:
        return asdict(self)
